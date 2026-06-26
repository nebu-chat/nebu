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

    def insert_event(event) do
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
        on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal, 5_000) end)
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
    test "initial_state cannot forge m.room.member, m.room.create, or m.room.power_levels" do
      req = %Core.CreateRoomRequest{
        creator_id: "@alice:test.local",
        name: "Guarded Room",
        initial_state_json:
          Jason.encode!([
            # Attempt to forge another user as a member.
            %{
              "type" => "m.room.member",
              "state_key" => "@evil:test.local",
              "content" => %{"membership" => "join"}
            },
            # Attempt to rewrite the create event.
            %{
              "type" => "m.room.create",
              "content" => %{"creator" => "@evil:test.local", "room_version" => "1"}
            },
            # Attempt to escalate power levels.
            %{
              "type" => "m.room.power_levels",
              "content" => %{"users" => %{"@evil:test.local" => 100}}
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

      # No power_levels emitted through initial_state — only the authoritative one,
      # which is written via set_power_levels (not as an event in this FakeDB), so
      # there must be ZERO m.room.power_levels events from the initial_state path.
      assert state_events(resp.room_id, "m.room.power_levels") == [],
             "initial_state must not be able to set power levels"

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
      assert state_events(resp.room_id, "m.room.join_rules") == []
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
  # regress this test. power_levels is set via set_power_levels (not an event), so
  # the assertable event chain is: create < member < initial_state entry < name.
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
end
