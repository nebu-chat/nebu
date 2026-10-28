defmodule Nebu.Matrix.EventDispatcher.CreateRoomInitialStateTest do
  use ExUnit.Case, async: false

  # ─── Bug fix — createRoom honours the Matrix CS `initial_state` array ─────────
  #
  # Regression: POST /createRoom silently dropped `initial_state`, so a room created
  # inside a Space carried no m.space.parent and ended up orphaned in the user's
  # home area. These unit-level tests drive Server.create_room/2 directly with a
  # FakeDB (no PostgreSQL) and assert that each initial_state entry is persisted as a
  # signed state event on the new room.
  #
  # Coverage:
  #   - Happy path: m.space.parent + a restricted m.room.join_rules are persisted
  #     with the creator as sender (creator-authored room setup).
  #   - Multiple types Element sends (encryption, guest_access, history_visibility).
  #   - Duplicate state_key: later entry wins (array order).
  #   - Security guard: initial_state may NOT clobber m.room.create or forge another
  #     user's m.room.member, and may NOT set m.room.power_levels.
  #   - Regression: no initial_state behaves exactly as before; unknown/empty is a
  #     no-op (room still created).
  #
  # async: false — Horde, :pg, Application.put_env and the :NebuTxnDedup ETS table
  # are process-global. Mirrors spaces_create_room_test.exs.

  alias Nebu.Matrix.EventDispatcher.Server

  defmodule NoOpAuditWriter do
    def log(_, _, _, _, _, _, _ \\ nil), do: :ok
  end

  # ETS-backed fake satisfying the Room DB surface used by create_room/2.
  defmodule FakeDB do
    def load_members(room_id) do
      case :ets.lookup(:create_room_initial_state_db, {:room, room_id}) do
        [] -> {:error, :not_found}
        [{_, created_at_ms}] ->
          members = :ets.match(:create_room_initial_state_db, {{:member, room_id, :"$1"}, :active})
          pl_json =
            case :ets.lookup(:create_room_initial_state_db, {:power_levels, room_id}) do
              [{_, json}] -> json
              [] -> "{}"
            end
          {:ok, Enum.map(members, fn [uid] -> uid end), created_at_ms, pl_json}
      end
    end

    def insert_room(room_id) do
      now_ms = System.system_time(:millisecond)
      :ets.insert(:create_room_initial_state_db, {{:room, room_id}, now_ms})
      {:ok, now_ms}
    end

    def insert_member(room_id, user_id) do
      :ets.insert(:create_room_initial_state_db, {{:member, room_id, user_id}, :active})
      :ok
    end

    def delete_member(room_id, user_id) do
      :ets.delete(:create_room_initial_state_db, {:member, room_id, user_id})
      :ok
    end

    # Story create-room-initial-state-conformance (D5): a test can make persisting one event type fail.
    def insert_event(%{"type" => type} = event) when is_binary(type) do
      case :ets.lookup(:create_room_initial_state_db, {:fail_insert, type}) do
        [{_, true}] -> {:error, :simulated_db_failure}
        _ -> do_insert_event(event)
      end
    end

    def delete_room(room_id) do
      :ets.insert(:create_room_initial_state_db, {{:deleted_room, room_id}, true})
      :ok
    end

    defp do_insert_event(event) do
      # Capture a monotonic insertion sequence alongside each event so tests can
      # assert the emit ORDER deterministically — origin_server_ts is only
      # millisecond-granular and ties between rapidly-emitted events.
      seq = :ets.update_counter(:create_room_initial_state_db, :event_seq, {2, 1}, {:event_seq, 0})

      :ets.insert(
        :create_room_initial_state_db,
        {{:event, event["event_id"]}, Map.put(event, "__seq", seq)}
      )

      :ok
    end

    # MINOR-1 — existence check used by check_parent_space_membership/2 on the
    # m.space.parent guard. A space is "known" iff its m.room.create event was
    # persisted (mirrors the production Room.DB query against the events table).
    def get_room_create_event(room_id) do
      case state_events(room_id, "m.room.create") do
        [create | _] -> {:ok, create["content"]}
        [] -> {:error, :not_found}
      end
    end

    defp state_events(room_id, type) do
      :ets.match(:create_room_initial_state_db, {{:event, :_}, :"$1"})
      |> Enum.map(fn [ev] -> ev end)
      |> Enum.filter(fn ev -> ev["room_id"] == room_id and ev["type"] == type end)
    end

    # story power-levels-enforcement (D10): the room process writes a power-level change through ONE call; the fake models the
    # transaction with its own column write AND event insert (a failure of either is the change's failure)
    def apply_power_levels_change(room_id, json, event) do
      with :ok <- set_power_levels(room_id, json), do: insert_event(event)
    end

    def set_power_levels(room_id, power_levels_json) do
      :ets.insert(:create_room_initial_state_db, {{:power_levels, room_id}, power_levels_json})
      :ok
    end

    def update_room_type(room_id, room_type) do
      :ets.insert(:create_room_initial_state_db, {{:room_type, room_id}, room_type})
      :ok
    end

    def update_room_name(room_id, name) do
      :ets.insert(:create_room_initial_state_db, {{:room_name, room_id}, name})
      :ok
    end

    def load_room_settings(_room_id), do: {:ok, 0}
    def get_room_status(_room_id), do: {:ok, "active"}
    def check_room_status_for_update(_room_id), do: {:ok, "active"}
  end

  setup do
    if :ets.info(:create_room_initial_state_db) != :undefined do
      :ets.delete(:create_room_initial_state_db)
    end

    :ets.new(:create_room_initial_state_db, [:named_table, :public, :set])

    Application.put_env(:room_manager, :db_module, FakeDB)
    Application.put_env(:event_dispatcher, :user_store_module, Nebu.Test.NoOpUserStore)
    Application.put_env(:event_dispatcher, :messages_db_module, FakeDB)
    Application.put_env(:event_dispatcher, :rooms_db_module, FakeDB)
    Application.put_env(:event_dispatcher, :server_name, "test.local")
    Application.put_env(:compliance, :audit_writer, NoOpAuditWriter)

    case :pg.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    if :ets.whereis(:NebuTxnDedup) != :undefined do
      :ets.delete_all_objects(:NebuTxnDedup)
    end

    on_exit(fn ->
      Application.delete_env(:room_manager, :db_module)
      Application.delete_env(:event_dispatcher, :user_store_module)
      Application.delete_env(:event_dispatcher, :messages_db_module)
      Application.delete_env(:event_dispatcher, :rooms_db_module)
      Application.delete_env(:event_dispatcher, :server_name)
      Application.delete_env(:compliance, :audit_writer)

      if :ets.info(:create_room_initial_state_db) != :undefined do
        :ets.delete(:create_room_initial_state_db)
      end

      if :ets.whereis(:NebuTxnDedup) != :undefined do
        :ets.delete_all_objects(:NebuTxnDedup)
      end
    end)

    :ok
  end

  defp build_stream, do: %{http_request_headers: %{}}

  defp track_room(room_id) do
    case Nebu.Matrix.Room.RoomSupervisor.lookup_room(room_id) do
      {:ok, pid} ->
        on_exit(fn -> if Process.alive?(pid), do: (try do GenServer.stop(pid, :normal, 5_000) catch :exit, _ -> :ok end) end)
        :ok

      _ ->
        :ok
    end
  end

  # All persisted events for a room, in no particular order.
  defp events(room_id) do
    :ets.match(:create_room_initial_state_db, {{:event, :_}, :"$1"})
    |> Enum.map(fn [ev] -> ev end)
    |> Enum.filter(fn ev -> ev["room_id"] == room_id end)
  end

  # State events of a given type/state_key on a room (there may be more than one
  # persisted; we want all of them so we can assert dedupe/last-wins).
  defp state_events(room_id, type, state_key \\ "") do
    events(room_id)
    |> Enum.filter(fn ev -> ev["type"] == type and ev["state_key"] == state_key end)
  end

  # The monotonic insertion sequence (set by FakeDB.insert_event) of the single
  # state event of this type/state_key — used to assert relative emit ORDER.
  defp seq_of(room_id, type, state_key \\ "") do
    [ev] = state_events(room_id, type, state_key)
    ev["__seq"]
  end

  # ─── Happy path — m.space.parent + restricted join_rules persisted ───────────
  describe "create_room/2 — initial_state honoured" do
    test "m.space.parent and restricted m.room.join_rules are persisted as creator state events" do
      # The legit owner flow: the creator first creates (and is joined to) the
      # parent Space, then links a child room into it via initial_state. The
      # MINOR-1 m.space.parent membership guard (mirrored from set_room_state/2)
      # passes because the creator IS a member of this Space, so the edge persists.
      space_resp =
        Server.create_room(
          %Core.CreateRoomRequest{
            creator_id: "@alice:test.local",
            name: "Parent Space",
            room_type: "m.space"
          },
          build_stream()
        )

      track_room(space_resp.room_id)
      space_id = space_resp.room_id

      req = %Core.CreateRoomRequest{
        creator_id: "@alice:test.local",
        name: "Child Room",
        initial_state_json:
          Jason.encode!([
            %{
              "type" => "m.space.parent",
              "state_key" => space_id,
              "content" => %{"via" => ["test.local"], "canonical" => true}
            },
            %{
              "type" => "m.room.join_rules",
              "content" => %{
                "join_rule" => "restricted",
                "allow" => [%{"type" => "m.room_membership", "room_id" => space_id}]
              }
            }
          ])
      }

      resp = Server.create_room(req, build_stream())
      track_room(resp.room_id)

      [parent] = state_events(resp.room_id, "m.space.parent", space_id)
      assert parent["sender"] == "@alice:test.local",
             "initial_state must be applied as the creator"
      assert parent["content"]["via"] == ["test.local"]
      assert parent["content"]["canonical"] == true
      # The state event is signed via the same path as set_room_state.
      assert is_map(parent["signatures"]) and Map.has_key?(parent["signatures"], "nebu")

      [join_rules] = state_events(resp.room_id, "m.room.join_rules")
      assert join_rules["content"]["join_rule"] == "restricted"
      assert join_rules["sender"] == "@alice:test.local"
    end

    test "guest_access + history_visibility are persisted; m.room.encryption is rejected (ADR-011)" do
      req = %Core.CreateRoomRequest{
        creator_id: "@alice:test.local",
        name: "Encrypted Room",
        initial_state_json:
          Jason.encode!([
            %{"type" => "m.room.encryption", "content" => %{"algorithm" => "m.megolm.v1.aes-sha2"}},
            %{"type" => "m.room.guest_access", "content" => %{"guest_access" => "forbidden"}},
            %{
              "type" => "m.room.history_visibility",
              "content" => %{"history_visibility" => "shared"}
            }
          ])
      }

      resp = Server.create_room(req, build_stream())
      track_room(resp.room_id)

      # ADR-011 managed-decryption model: m.room.encryption must NEVER be persisted, even
      # via createRoom initial_state — a single persisted encryption event would flip the
      # room to client-side E2EE and the server could no longer read its content. It is in
      # @initial_state_forbidden_types, so it is skipped (logged) like m.room.member/create.
      assert state_events(resp.room_id, "m.room.encryption") == []

      # The other (non-privileged, non-encryption) types Element sends are still honored.
      [guest] = state_events(resp.room_id, "m.room.guest_access")
      assert guest["content"]["guest_access"] == "forbidden"

      [hist] = state_events(resp.room_id, "m.room.history_visibility")
      assert hist["content"]["history_visibility"] == "shared"
    end

    test "duplicate state_key — both entries are applied in array order (later wins on read)" do
      req = %Core.CreateRoomRequest{
        creator_id: "@alice:test.local",
        name: "Dup Room",
        initial_state_json:
          Jason.encode!([
            %{"type" => "m.room.topic", "content" => %{"topic" => "first"}},
            %{"type" => "m.room.topic", "content" => %{"topic" => "second"}}
          ])
      }

      resp = Server.create_room(req, build_stream())
      track_room(resp.room_id)

      topics = state_events(resp.room_id, "m.room.topic")
      # Both entries are emitted (the append-only event log keeps both); the
      # last entry in array order wins on read. Tie-break on the deterministic
      # insertion sequence (__seq) rather than origin_server_ts — the two events
      # are emitted in the same millisecond, so a ts-based max is a coin flip.
      assert length(topics) == 2
      latest = Enum.max_by(topics, & &1["__seq"])
      assert latest["content"]["topic"] == "second"
    end
  end

  # ─── Security guards — initial_state cannot clobber privileged events ────────
  describe "create_room/2 — initial_state security guards" do
    # story power-levels-enforcement (D7, AC16 re-pin of the escalation part of the next test): an m.room.power_levels entry that
    # grants more than the creator has is refused BEFORE the room exists (400 M_INVALID_ROOM_STATE), nothing is written
    test "an initial_state m.room.power_levels entry cannot escalate: a user above the creator is 400 M_INVALID_ROOM_STATE, no event" do
      req = %Core.CreateRoomRequest{
        creator_id: "@alice:test.local",
        name: "Guarded Room",
        initial_state_json:
          Jason.encode!([
            %{"type" => "m.room.power_levels", "content" => %{"users" => %{"@alice:test.local" => 100, "@evil:test.local" => 101}}}
          ])
      }

      error = assert_raise Nebu.Matrix.Error, fn -> Server.create_room(req, build_stream()) end
      assert error.errcode == "M_INVALID_ROOM_STATE"
      assert error.message == "The initial power levels cannot grant more than the room creator has"
    end

    # story power-levels-enforcement (D7, AC16 re-pin): an m.room.power_levels entry is no longer skipped but APPLIED as a v10 change
    # by the creator, so the escalation guard for it is the change rule (next test); this test keeps the two skipped types and still
    # pins that no second, forged levels event exists
    # story state-writer-redaction (D10 (b), AC15 (e) re-pin): an m.room.member entry for another user was SKIPPED, it is refused now (stricter Nebu rule)
    test "an initial_state m.room.member entry for another user is refused before the room exists" do
      req = %Core.CreateRoomRequest{
        creator_id: "@alice:test.local",
        name: "Guarded Room",
        initial_state_json: Jason.encode!([%{"type" => "m.room.member", "state_key" => "@evil:test.local", "content" => %{"membership" => "join"}}])
      }

      error = assert_raise Nebu.Matrix.Error, fn -> Server.create_room(req, build_stream()) end
      assert error.message == "The initial state contains a state key of another user"
      assert error.errcode == "M_INVALID_ROOM_STATE"
    end

    test "initial_state cannot forge m.room.member or m.room.create" do
      req = %Core.CreateRoomRequest{
        creator_id: "@alice:test.local",
        name: "Guarded Room",
        initial_state_json:
          Jason.encode!([
            # (story state-writer-redaction, AC15 (e): a member entry for ANOTHER user is a 400 now, see the next test)
            # Attempt to rewrite the create event.
            %{
              "type" => "m.room.create",
              "content" => %{"creator" => "@evil:test.local", "room_version" => "1"}
            },
            # A legitimate entry alongside the malicious ones still applies.
            %{"type" => "m.room.topic", "content" => %{"topic" => "ok"}}
          ])
      }

      resp = Server.create_room(req, build_stream())
      track_room(resp.room_id)

      # No forged member for @evil.
      assert state_events(resp.room_id, "m.room.member", "@evil:test.local") == [],
             "initial_state must not be able to forge another user's membership"

      # Exactly one m.room.create exists and it is the server-authoritative one.
      creates = state_events(resp.room_id, "m.room.create")
      assert length(creates) == 1
      [create] = creates
      assert create["content"]["creator"] == "@alice:test.local"
      assert create["content"]["room_version"] == "10"

      # Bugfix sync-state-events-missing-fields (AC2 addendum): set_power_levels now
      # emits a real backing event (mirroring emit_membership_event/3's pattern), so
      # the room's authoritative m.room.power_levels event IS now a real event in
      # this FakeDB — exactly ONE, written by the server during create_room/2 itself,
      # with the creator as sender. initial_state must not be able to inject a
      # SECOND, forged m.room.power_levels event escalating @evil.
      power_levels_events = state_events(resp.room_id, "m.room.power_levels")

      assert length(power_levels_events) == 1,
             "initial_state must not be able to add a forged/duplicate m.room.power_levels event, " <>
               "got: #{inspect(power_levels_events)}"

      [authoritative_pl] = power_levels_events

      assert authoritative_pl["sender"] == "@alice:test.local",
             "the only m.room.power_levels event must be the server-authoritative one (creator-sent)"

      refute get_in(authoritative_pl["content"], ["users", "@evil:test.local"]) == 100,
             "initial_state must not be able to escalate @evil's power level"

      # The legitimate entry still went through.
      [topic] = state_events(resp.room_id, "m.room.topic")
      assert topic["content"]["topic"] == "ok"
    end
  end

  # ─── Regression — no initial_state behaves exactly as before ─────────────────
  describe "create_room/2 — regression (no/empty initial_state)" do
    test "no initial_state field still creates the room with only base events" do
      req = %Core.CreateRoomRequest{
        creator_id: "@bob:test.local",
        name: "Plain Room"
        # initial_state_json defaults to ""
      }

      resp = Server.create_room(req, build_stream())
      track_room(resp.room_id)

      assert resp.room_id =~ ~r/^!.+:test\.local$/

      # m.room.create exists; no space.parent / join_rules from a missing array.
      assert length(state_events(resp.room_id, "m.room.create")) == 1
      assert state_events(resp.room_id, "m.space.parent", "!whatever:test.local") == []
      # Story create-room-presets-power-levels-topic (AC16, adapted): a request without preset / visibility is a `private_chat`, whose
      # join rule `invite` is written by createRoom itself now (D2). The assertion changes from "no join_rules event at all" to "no
      # join_rules event that came from a missing initial_state array": the only one is the preset's, in the state_key "".
      assert [%{"content" => %{"join_rule" => "invite"}, "state_key" => ""}] = state_events(resp.room_id, "m.room.join_rules")
    end

    test "empty initial_state array is a no-op (room still created)" do
      req = %Core.CreateRoomRequest{
        creator_id: "@bob:test.local",
        name: "Empty IS Room",
        initial_state_json: Jason.encode!([])
      }

      resp = Server.create_room(req, build_stream())
      track_room(resp.room_id)

      assert length(state_events(resp.room_id, "m.room.create")) == 1
    end

    test "malformed initial_state JSON is a no-op (room still created)" do
      req = %Core.CreateRoomRequest{
        creator_id: "@bob:test.local",
        name: "Bad IS Room",
        initial_state_json: "not-json{"
      }

      resp = Server.create_room(req, build_stream())
      track_room(resp.room_id)

      assert length(state_events(resp.room_id, "m.room.create")) == 1
    end
  end

  # ─── MINOR-4 (a) — emit ORDER invariant ──────────────────────────────────────
  #
  # Matrix CS §createRoom ordering: m.room.create → creator m.room.member →
  # m.room.power_levels → initial_state → m.room.name/topic. A future reorder
  # (e.g. moving apply_initial_state before the creator join, or after name) must
  # regress this test. Since bugfix sync-state-events-missing-fields, power_levels
  # IS also a real event (set_power_levels now emits one, AC2 addendum) — this test
  # only asserts the chain it originally covered (create < member < initial_state
  # entry < name); it does not additionally assert power_levels' own position.
  describe "create_room/2 — initial_state emit order" do
    test "initial_state events are emitted after create/member and before m.room.name" do
      req = %Core.CreateRoomRequest{
        creator_id: "@alice:test.local",
        name: "Ordered Room",
        initial_state_json:
          Jason.encode!([
            %{"type" => "m.room.topic", "content" => %{"topic" => "ordered"}}
          ])
      }

      resp = Server.create_room(req, build_stream())
      track_room(resp.room_id)

      create_seq = seq_of(resp.room_id, "m.room.create")
      member_seq = seq_of(resp.room_id, "m.room.member", "@alice:test.local")
      topic_seq  = seq_of(resp.room_id, "m.room.topic")
      name_seq   = seq_of(resp.room_id, "m.room.name")

      # create is the very first event in the room timeline (spec §8.5.1).
      assert create_seq < member_seq,
             "m.room.create must precede the creator's m.room.member"

      # initial_state is applied AFTER create + creator-join …
      assert member_seq < topic_seq,
             "initial_state must be emitted after the creator m.room.member"

      # … and BEFORE m.room.name (so a reorder that moves initial_state after the
      # name write — or the name write before initial_state — regresses here).
      assert topic_seq < name_seq,
             "initial_state must be emitted before m.room.name"
    end
  end

  # ─── MINOR-4 (b) — m.space.parent membership guard on the initial_state path ──
  #
  # Mirrors set_room_state/2's check_parent_space_membership/2: an m.space.parent
  # entry pointing at a Space the creator is NOT a member of (or that does not
  # exist) is SKIPPED (best-effort, no crash); one pointing at a Space the creator
  # IS a member of persists.
  describe "create_room/2 — m.space.parent membership guard" do
    test "m.space.parent to a non-existent / non-member space is skipped; to a joined space it persists" do
      # A Space the creator owns/belongs to — create it the real way so its Room
      # GenServer is running with @alice as a member (fetch_room_state in the guard
      # reads .members from this live process, and FakeDB has its m.room.create).
      space_resp =
        Server.create_room(
          %Core.CreateRoomRequest{
            creator_id: "@alice:test.local",
            name: "Alice's Space",
            room_type: "m.space"
          },
          build_stream()
        )

      track_room(space_resp.room_id)
      member_space = space_resp.room_id

      # A Space that was never created here → unknown to FakeDB.get_room_create_event,
      # so the creator cannot be a member → guard must reject.
      non_member_space = "!stranger:test.local"

      req = %Core.CreateRoomRequest{
        creator_id: "@alice:test.local",
        name: "Child Room",
        initial_state_json:
          Jason.encode!([
            %{
              "type" => "m.space.parent",
              "state_key" => non_member_space,
              "content" => %{"via" => ["test.local"], "canonical" => true}
            },
            %{
              "type" => "m.space.parent",
              "state_key" => member_space,
              "content" => %{"via" => ["test.local"], "canonical" => true}
            }
          ])
      }

      resp = Server.create_room(req, build_stream())
      track_room(resp.room_id)

      # Rejected: no m.space.parent edge to the space the creator is not a member of.
      assert state_events(resp.room_id, "m.space.parent", non_member_space) == [],
             "m.space.parent to a space the creator is not a member of must be skipped"

      # Allowed: the legitimate owner flow still links the child to the owned Space.
      [parent] = state_events(resp.room_id, "m.space.parent", member_space)
      assert parent["sender"] == "@alice:test.local"
      assert parent["content"]["canonical"] == true
    end
  end

  # ─── Story create-room-initial-state-conformance ─────────────────────────────

  describe "validate_initial_state/1 (D1, run by the HTTP layer before a room exists)" do
    test "valid shapes are :ok (nil, [], entries with and without state_key)" do
      assert :ok == Server.validate_initial_state(nil)
      assert :ok == Server.validate_initial_state([])

      assert :ok ==
               Server.validate_initial_state([
                 %{"type" => "m.room.topic", "content" => %{"topic" => "t"}},
                 %{"type" => "m.space.parent", "state_key" => "!s:x", "content" => %{}}
               ])
    end

    test "a non-array, a non-object entry, a bad type, a bad state_key or a bad content are :malformed" do
      bad = [
        %{"type" => "m.room.topic"},
        "x",
        7,
        true,
        [nil],
        ["x"],
        [%{"content" => %{}}],
        [%{"type" => 123, "content" => %{}}],
        [%{"type" => "", "content" => %{}}],
        [%{"type" => "m.t", "state_key" => 5, "content" => %{}}],
        [%{"type" => "m.t", "state_key" => nil, "content" => %{}}],
        [%{"type" => "m.t"}],
        [%{"type" => "m.t", "content" => nil}],
        [%{"type" => "m.t", "content" => "x"}],
        [%{"type" => "m.t", "content" => [1]}]
      ]

      for input <- bad do
        assert {:error, :malformed} == Server.validate_initial_state(input), "expected :malformed for #{inspect(input)}"
      end
    end

    test "a NUL character in the type, the state_key or anywhere in the content (key, value, nested, list) is :malformed" do
      nul = <<0>>

      bad = [
        [%{"type" => "m.t" <> nul, "content" => %{}}],
        [%{"type" => "m.t", "state_key" => "k" <> nul, "content" => %{}}],
        [%{"type" => "m.t", "content" => %{"a" => "x" <> nul}}],
        [%{"type" => "m.t", "content" => %{("a" <> nul) => 1}}],
        [%{"type" => "m.t", "content" => %{"a" => %{"b" => ["ok", "y" <> nul]}}}]
      ]

      for input <- bad, do: assert({:error, :malformed} == Server.validate_initial_state(input), "NUL in #{inspect(input)}")
      assert :ok == Server.validate_initial_state([%{"type" => "m.t", "content" => %{"a" => "fine", "n" => 1, "l" => [nil, true]}}])
    end

    test "more than 64 entries are :too_many, exactly 64 are :ok" do
      entry = fn i -> %{"type" => "m.t", "state_key" => "#{i}", "content" => %{}} end
      assert :ok == Server.validate_initial_state(Enum.map(1..64, entry))
      assert {:error, :too_many} == Server.validate_initial_state(Enum.map(1..65, entry))
    end

    test "the cap is checked before the entry shapes (65 malformed entries are :too_many, not :malformed)" do
      assert {:error, :too_many} == Server.validate_initial_state(List.duplicate("x", 65))
    end
  end

  describe "create_room/2 — forbidden types (D3)" do
    test "m.room.tombstone and m.room.third_party_invite are not persisted, the other entries and the room are" do
      req = %Core.CreateRoomRequest{
        creator_id: "@alice:test.local",
        name: "No Tombstone",
        initial_state_json:
          Jason.encode!([
            %{"type" => "m.room.tombstone", "content" => %{"body" => "moved", "replacement_room" => "!x:test.local"}},
            %{"type" => "m.room.third_party_invite", "state_key" => "tok", "content" => %{"display_name" => "x"}},
            %{"type" => "m.room.topic", "content" => %{"topic" => "kept"}}
          ])
      }

      resp = Server.create_room(req, build_stream())
      track_room(resp.room_id)

      assert state_events(resp.room_id, "m.room.tombstone") == []
      assert state_events(resp.room_id, "m.room.third_party_invite", "tok") == []
      assert [_] = state_events(resp.room_id, "m.room.topic")
    end
  end

  describe "create_room/2 — m.room.name in initial_state keeps rooms.name in sync (D4)" do
    test "without a top-level name the entry sets the state event AND the denormalised rooms.name" do
      req = %Core.CreateRoomRequest{
        creator_id: "@alice:test.local",
        name: "",
        initial_state_json: Jason.encode!([%{"type" => "m.room.name", "content" => %{"name" => "From initial_state"}}])
      }

      resp = Server.create_room(req, build_stream())
      track_room(resp.room_id)

      assert [ev] = state_events(resp.room_id, "m.room.name")
      assert ev["content"]["name"] == "From initial_state"
      assert [{_, "From initial_state"}] = :ets.lookup(:create_room_initial_state_db, {:room_name, resp.room_id})
    end

    test "a top-level name is emitted after the entry and wins in the state AND in rooms.name" do
      req = %Core.CreateRoomRequest{
        creator_id: "@alice:test.local",
        name: "Top level B",
        initial_state_json: Jason.encode!([%{"type" => "m.room.name", "content" => %{"name" => "Entry A"}}])
      }

      resp = Server.create_room(req, build_stream())
      track_room(resp.room_id)

      names = state_events(resp.room_id, "m.room.name")
      assert length(names) == 2
      assert Enum.min_by(names, & &1["__seq"])["content"]["name"] == "Entry A"
      assert Enum.max_by(names, & &1["__seq"])["content"]["name"] == "Top level B"
      assert [{_, "Top level B"}] = :ets.lookup(:create_room_initial_state_db, {:room_name, resp.room_id})
    end

    # Story create-room-input-validation (D5c): a NON-NULL, non-string `name` (42, true, {}, []) in an m.room.name entry is now
    # 400 M_BAD_JSON (it used to be persisted as is; see create_room_input_validation_test.exs). The entries that remain valid and
    # must not touch the denormalised rooms.name are the ones WITHOUT a name: `{}` and `{"name": null}`.
    test "an m.room.name entry without a name ({} or null) does not touch rooms.name" do
      for content <- [%{}, %{"name" => nil}] do
        req = %Core.CreateRoomRequest{
          creator_id: "@alice:test.local",
          name: "",
          initial_state_json: Jason.encode!([%{"type" => "m.room.name", "content" => content}])
        }

        resp = Server.create_room(req, build_stream())
        track_room(resp.room_id)

        assert :ets.lookup(:create_room_initial_state_db, {:room_name, resp.room_id}) == [], "content #{inspect(content)}"
      end
    end
  end

  describe "create_room/2 — exact duplicate entries (Kassandra delta gate X5-1)" do
    test "two byte-identical entries create the room (the second is dropped, no event id collision) and the state event exists once" do
      entry = %{"type" => "m.room.topic", "state_key" => "", "content" => %{"topic" => "same"}}

      req = %Core.CreateRoomRequest{
        creator_id: "@alice:test.local",
        name: "Dupes",
        initial_state_json: Jason.encode!(List.duplicate(entry, 5))
      }

      resp = Server.create_room(req, build_stream())
      track_room(resp.room_id)

      assert [_one] = state_events(resp.room_id, "m.room.topic")
      assert :ets.match(:create_room_initial_state_db, {{:deleted_room, :"$1"}, true}) == []
    end
  end

  describe "create_room/2 — a failing entry fails the creation (D5)" do
    test "a DB error persisting one entry raises, the half-created room is deleted, no later entry or m.room.name is written" do
      :ets.insert(:create_room_initial_state_db, {{:fail_insert, "m.room.topic"}, true})

      req = %Core.CreateRoomRequest{
        creator_id: "@alice:test.local",
        name: "Doomed Room",
        initial_state_json:
          Jason.encode!([
            %{"type" => "m.room.guest_access", "content" => %{"guest_access" => "forbidden"}},
            %{"type" => "m.room.topic", "content" => %{"topic" => "fails"}},
            %{"type" => "m.room.history_visibility", "content" => %{"history_visibility" => "shared"}}
          ])
      }

      error = assert_raise Nebu.Matrix.Error, fn -> Server.create_room(req, build_stream()) end
      assert error.status == Nebu.Matrix.Status.internal(), "a persistence failure is a server error (500), not a client error"
      assert error.message =~ "m.room.topic"

      assert [[room_id]] = :ets.match(:create_room_initial_state_db, {{:deleted_room, :"$1"}, true}),
             "the orphan room must be cleaned up"

      assert state_events(room_id, "m.room.history_visibility") == [], "the entries after the failing one are not applied"
      assert state_events(room_id, "m.room.name") == [], "m.room.name is not written after a failed entry"
    end

    test "a skipped entry (forbidden type, m.space.parent guard) is NOT a failure: the room is created" do
      req = %Core.CreateRoomRequest{
        creator_id: "@alice:test.local",
        name: "Skips are fine",
        initial_state_json:
          Jason.encode!([
            %{"type" => "m.room.encryption", "content" => %{"algorithm" => "m.megolm.v1.aes-sha2"}},
            %{"type" => "m.space.parent", "state_key" => "!stranger:test.local", "content" => %{"via" => ["test.local"]}}
          ])
      }

      resp = Server.create_room(req, build_stream())
      track_room(resp.room_id)

      assert resp.room_id =~ ~r/^!/
      assert :ets.match(:create_room_initial_state_db, {{:deleted_room, :"$1"}, true}) == []
    end
  end

  describe "create_room/2 — order with several entries (AC7)" do
    test "entries are emitted in array order, between the creator's power levels and m.room.name" do
      req = %Core.CreateRoomRequest{
        creator_id: "@alice:test.local",
        name: "Ordered Many",
        initial_state_json:
          Jason.encode!([
            %{"type" => "m.room.guest_access", "content" => %{"guest_access" => "forbidden"}},
            %{"type" => "m.room.history_visibility", "content" => %{"history_visibility" => "shared"}},
            %{"type" => "m.room.topic", "content" => %{"topic" => "t"}}
          ])
      }

      resp = Server.create_room(req, build_stream())
      track_room(resp.room_id)

      seqs =
        Enum.map(["m.room.create", "m.room.power_levels", "m.room.guest_access", "m.room.history_visibility", "m.room.topic", "m.room.name"], fn t ->
          seq_of(resp.room_id, t)
        end)

      assert seqs == Enum.sort(seqs), "create < power_levels < initial_state in array order < name, got #{inspect(seqs)}"
    end
  end
end
