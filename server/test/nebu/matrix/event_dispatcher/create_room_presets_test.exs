defmodule Nebu.Matrix.EventDispatcher.CreateRoomPresetsTest do
  @moduledoc """
  Story `create-room-presets-power-levels-topic` (epic oauth-broker, follow-ups `ec`, `ef`, `ea`), unit part (no PostgreSQL):
  `Server.create_room/2` honours `preset` / `visibility` (D2, D4, D6), `topic` (D5), `power_level_content_override` (D7, D8) and
  writes the whole spec chain (alias -> preset events -> `initial_state` -> name -> topic -> derived alias) with ONE strictly
  increasing timestamp chain (D3). The HTTP side (join enforcement, summary, audit rows, real power levels) is
  `create_room_presets_http_test.exs`; the PUT content rule is in `set_room_state_test.exs`; the join decision in `join_room_test.exs`.

  Style as the sibling `create_room_input_validation_test.exs` (same fakes, same conventions):

    * Every rejection is asserted through `Nebu.Matrix.Http.call_core/1` = the public `{:error, {http_status, errcode, message}}` mapping.
    * Requests are built with `struct/2`, never with a `%Core.CreateRoomRequest{preset: ...}` literal: the fields `preset`, `visibility`
      and `power_level_content_override` do not exist yet, a literal would abort the compilation of the whole file; `struct/2` makes only
      the tests fail.
    * The FakeDB stamps every inserted event with a monotonic insertion sequence (`__seq`). `origin_server_ts` is only millisecond
      granular, so ORDER is asserted on `__seq`; the timestamp chain (D3) is asserted as "strictly greater than the predecessor in
      `__seq` order", which is exactly what makes `ORDER BY origin_server_ts DESC` deterministic.
    * No helper returns "the" event of a type from the ETS :set: events are counted, looked up by event id or picked by CONTENT.
    * `async: false` - Horde, `:pg`, `Application.put_env` and the `:NebuTxnDedup` ETS table are process-global.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Nebu.Matrix.EventDispatcher.Server
  alias Nebu.Matrix.Http

  @ets :create_room_presets_test_db
  @server "test.local"
  @creator "@alice:test.local"
  @other "@bob:test.local"

  # ─── FakeDB: ETS-backed Room DB, per-test failure switches, insertion sequence ───
  defmodule FakeDB do
    @ets :create_room_presets_test_db

    def load_members(room_id) do
      case :ets.lookup(@ets, {:room, room_id}) do
        [] ->
          {:error, :not_found}

        [{_, created_at_ms}] ->
          members = :ets.match(@ets, {{:member, room_id, :"$1"}, :active})

          pl_json =
            case :ets.lookup(@ets, {:power_levels, room_id}) do
              [{_, json}] -> json
              [] -> "{}"
            end

          {:ok, Enum.map(members, fn [uid] -> uid end), created_at_ms, pl_json}
      end
    end

    def insert_room(room_id) do
      now_ms = System.system_time(:millisecond)
      :ets.insert(@ets, {{:room, room_id}, now_ms})
      {:ok, now_ms}
    end

    def insert_member(room_id, user_id) do
      :ets.insert(@ets, {{:member, room_id, user_id}, :active})
      :ok
    end

    def delete_member(room_id, user_id) do
      :ets.delete(@ets, {:member, room_id, user_id})
      :ok
    end

    # `{:fail_insert, type}` -> the reason makes persisting that event type fail.
    def insert_event(%{"type" => type} = event) when is_binary(type) do
      case :ets.lookup(@ets, {:fail_insert, type}) do
        [{_, reason}] ->
          {:error, reason}

        [] ->
          seq = :ets.update_counter(@ets, :event_seq, {2, 1}, {:event_seq, 0})
          :ets.insert(@ets, {{:event, event["event_id"]}, Map.put(event, "__seq", seq)})
          :ok
      end
    end

    # story power-levels-enforcement (D10): the room process writes a power-level change through ONE call; the fake models the
    # transaction with its own column write AND event insert (a failure of either is the change's failure)
    def apply_power_levels_change(room_id, json, event) do
      with :ok <- set_power_levels(room_id, json), do: insert_event(event)
    end

    def set_power_levels(room_id, power_levels_json) do
      :ets.insert(@ets, {{:power_levels, room_id}, power_levels_json})
      :ok
    end

    def update_room_name(room_id, name) do
      :ets.insert(@ets, {{:room_name, room_id}, name})
      :ok
    end

    def update_room_type(room_id, room_type) do
      :ets.insert(@ets, {{:room_type, room_id}, room_type})
      :ok
    end

    # D9: rooms.topic is NOT written (the column is dead). A write would show up here (the real Room.DB has no such function either).
    def update_room_topic(room_id, topic) do
      :ets.insert(@ets, {{:rooms_topic_call, make_ref()}, {room_id, topic}})
      :ok
    end

    def delete_room(room_id) do
      :ets.insert(@ets, {{:deleted_room, room_id}, true})
      :ets.delete(@ets, {:room, room_id})
      :ets.match_delete(@ets, {{:member, room_id, :_}, :_})
      :ets.match_delete(@ets, {{:alias, :_}, room_id})
      :ok
    end

    def get_room_create_event(room_id) do
      :ets.match(@ets, {{:event, :_}, :"$1"})
      |> Enum.map(fn [e] -> e end)
      |> Enum.find(&(&1["room_id"] == room_id and &1["type"] == "m.room.create"))
      |> case do
        nil -> {:error, :not_found}
        create -> {:ok, create["content"]}
      end
    end

    def load_room_settings(_room_id), do: {:ok, 0}
    def get_room_status(_room_id), do: {:ok, "active"}
    def check_room_status_for_update(_room_id), do: {:ok, "active"}
  end

  defmodule FakeAliasDB do
    @ets :create_room_presets_test_db

    def insert_room_alias(alias_str, room_id, _created_at) do
      case :ets.lookup(@ets, {:alias, alias_str}) do
        [] ->
          :ets.insert(@ets, {{:alias, alias_str}, room_id})
          :ok

        _existing ->
          {:error, :conflict}
      end
    end

    def lookup_alias(alias_str) do
      case :ets.lookup(@ets, {:alias, alias_str}) do
        [{_, room_id}] -> {:ok, room_id}
        [] -> {:error, :not_found}
      end
    end
  end

  # D6: the directory flag goes through admin_db_module().update_room_visibility/2 (set_room_visibility/3). Calls recorded, failure switch.
  defmodule FakeAdminDB do
    @ets :create_room_presets_test_db

    def update_room_visibility(room_id, visibility) do
      :ets.insert(@ets, {{:visibility_call, make_ref()}, {room_id, visibility}})

      case :ets.lookup(@ets, :fail_visibility) do
        [{_, reason}] -> {:error, reason}
        [] -> :ok
      end
    end
  end

  defmodule SpyAuditWriter do
    @ets :create_room_presets_test_db

    def log(actor, action, target_type, target_id, metadata, outcome, _detail \\ nil) do
      :ets.insert(@ets, {{:audit, make_ref()}, {actor, action, target_type, target_id, metadata, outcome}})
      :ok
    end
  end

  setup do
    if :ets.info(@ets) != :undefined, do: :ets.delete(@ets)
    :ets.new(@ets, [:named_table, :public, :set])

    snapshot =
      for {app, key} <- [
            {:room_manager, :db_module},
            {:event_dispatcher, :messages_db_module},
            {:event_dispatcher, :rooms_db_module},
            {:event_dispatcher, :alias_db_module},
            {:event_dispatcher, :admin_db_module},
            {:event_dispatcher, :user_store_module},
            {:event_dispatcher, :server_name},
            {:compliance, :audit_writer}
          ],
          do: {app, key, Application.fetch_env(app, key)}

    Application.put_env(:room_manager, :db_module, FakeDB)
    Application.put_env(:event_dispatcher, :messages_db_module, FakeDB)
    Application.put_env(:event_dispatcher, :rooms_db_module, FakeDB)
    Application.put_env(:event_dispatcher, :alias_db_module, FakeAliasDB)
    Application.put_env(:event_dispatcher, :admin_db_module, FakeAdminDB)
    Application.put_env(:event_dispatcher, :user_store_module, Nebu.Test.NoOpUserStore)
    Application.put_env(:event_dispatcher, :server_name, @server)
    Application.put_env(:compliance, :audit_writer, SpyAuditWriter)

    case :pg.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    if :ets.whereis(:NebuTxnDedup) != :undefined, do: :ets.delete_all_objects(:NebuTxnDedup)

    on_exit(fn ->
      for {app, key, previous} <- snapshot do
        case previous do
          {:ok, value} -> Application.put_env(app, key, value)
          :error -> Application.delete_env(app, key)
        end
      end

      if :ets.info(@ets) != :undefined, do: :ets.delete(@ets)
      if :ets.whereis(:NebuTxnDedup) != :undefined, do: :ets.delete_all_objects(:NebuTxnDedup)
    end)

    :ok
  end

  # ─── helpers ─────────────────────────────────────────────────────────────────

  defp stream, do: %{http_request_headers: %{}}
  defp rand, do: Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
  defp alias_for(localpart), do: "#" <> localpart <> ":" <> @server

  defp track_room(room_id) do
    case Nebu.Matrix.Room.RoomSupervisor.lookup_room(room_id) do
      {:ok, pid} ->
        on_exit(fn -> if Process.alive?(pid), do: (try do GenServer.stop(pid, :normal, 5_000) catch :exit, _ -> :ok end) end)

      _ ->
        :ok
    end
  end

  defp req(attrs), do: struct(Core.CreateRoomRequest, Keyword.merge([creator_id: @creator], attrs))

  defp create(attrs) do
    result = Http.call_core(fn -> Server.create_room(req(attrs), stream()) end)

    case result do
      {:ok, resp} -> track_room(resp.room_id)
      _ -> :ok
    end

    result
  end

  defp create_ok(attrs, label \\ "create") do
    case create(attrs) do
      {:ok, resp} -> resp
      other -> flunk("#{label}: expected the room to be created, got #{inspect(other)}")
    end
  end

  # `{status, errcode}` and nothing left behind (no room, not even a created-then-cleaned-up one)
  defp assert_rejected(attrs, errcode, label, status \\ 400) do
    before = room_snapshot()

    case create(attrs) do
      {:error, {^status, ^errcode, message}} ->
        assert is_binary(message) and message != "", "#{label}: a fixed, non-empty message"
        assert room_snapshot() == before, "#{label}: rejected BEFORE a room is created (no new room, no create-then-cleanup)"
        message

      {:ok, resp} ->
        flunk("#{label}: expected #{status} #{errcode}, but the room #{resp.room_id} was created")

      other ->
        flunk("#{label}: expected #{status} #{errcode}, got #{inspect(other)}")
    end
  end

  defp room_snapshot,
    do: {Enum.sort(:ets.match(@ets, {{:room, :"$1"}, :_})), Enum.sort(:ets.match(@ets, {{:deleted_room, :"$1"}, true}))}

  defp deleted_rooms, do: :ets.match(@ets, {{:deleted_room, :"$1"}, true}) |> List.flatten()

  defp events(room_id) do
    :ets.match(@ets, {{:event, :_}, :"$1"})
    |> Enum.map(fn [ev] -> ev end)
    |> Enum.filter(&(&1["room_id"] == room_id))
  end

  defp state_events(room_id, type, state_key \\ ""),
    do: events(room_id) |> Enum.filter(&(&1["type"] == type and &1["state_key"] == state_key)) |> Enum.sort_by(& &1["__seq"])

  # the content of the ONE event of a type (state_key ""): fails when there is none or several
  defp only_content(room_id, type) do
    assert [event] = state_events(room_id, type), "exactly one #{type} event expected, got #{length(state_events(room_id, type))}"
    event["content"]
  end

  defp seq_of(room_id, type, state_key \\ "") do
    assert [ev] = state_events(room_id, type, state_key)
    ev["__seq"]
  end

  defp room_name(room_id), do: (case :ets.lookup(@ets, {:room_name, room_id}) do [{_, n}] -> n; [] -> :unset end)
  defp audits(action), do: :ets.match(@ets, {{:audit, :_}, {:"$1", action, :"$2", :"$3", :"$4", :_}})
  defp visibility_calls, do: :ets.match(@ets, {{:visibility_call, :_}, :"$1"}) |> List.flatten()
  defp rooms_topic_calls, do: :ets.match(@ets, {{:rooms_topic_call, :_}, :"$1"}) |> List.flatten()

  defp persisted_power_levels(room_id) do
    [{_, json}] = :ets.lookup(@ets, {:power_levels, room_id})
    Jason.decode!(json)
  end

  defp default_levels_with_creator, do: Nebu.Matrix.Room.PowerLevels.default_levels() |> Map.put("users", %{@creator => 100})

  defp initial_state(entries), do: Jason.encode!(entries)
  defp entry(type, content, key \\ ""), do: %{"type" => type, "state_key" => key, "content" => content}

  defp pg_error(marker) do
    %Postgrex.Error{
      message: "simulated 22P05 #{marker}",
      postgres: %{
        code: :untranslatable_character,
        pg_code: "22P05",
        severity: "ERROR",
        message: "unsupported Unicode escape sequence",
        where: "JSON data, line 1: {\"topic\": \"#{marker}\"...}"
      }
    }
  end

  defp capture_create(attrs) do
    ref = make_ref()
    log = capture_log(fn -> send(self(), {ref, create(attrs)}) end)
    assert_received {^ref, result}
    {log, result}
  end

  # ─── AC3 / D2: the preset events ─────────────────────────────────────────────

  describe "AC3 - preset events (D2 table)" do
    @invite_triple {"invite", "shared", "can_join"}
    @public_triple {"public", "shared", "forbidden"}

    test "every preset / visibility combination writes exactly the D2 events (sender = creator, state_key \"\")" do
      for {label, attrs, {join_rule, history, guest}} <- [
            {"no preset, no visibility", [], @invite_triple},
            {"preset nil, visibility nil", [preset: nil, visibility: nil], @invite_triple},
            {"private_chat", [preset: "private_chat"], @invite_triple},
            {"trusted_private_chat (same events as private_chat)", [preset: "trusted_private_chat"], @invite_triple},
            {"public_chat", [preset: "public_chat"], @public_triple},
            {"visibility public without preset -> public_chat", [visibility: "public"], @public_triple},
            {"visibility private without preset -> private_chat", [visibility: "private"], @invite_triple},
            {"visibility public + private_chat -> invite (the preset wins)", [visibility: "public", preset: "private_chat"], @invite_triple},
            {"visibility public + trusted_private_chat -> invite", [visibility: "public", preset: "trusted_private_chat"], @invite_triple},
            {"visibility private + public_chat -> public (the preset wins)", [visibility: "private", preset: "public_chat"], @public_triple}
          ] do
        resp = create_ok(attrs, label)

        for {type, content} <- [
              {"m.room.join_rules", %{"join_rule" => join_rule}},
              {"m.room.history_visibility", %{"history_visibility" => history}},
              {"m.room.guest_access", %{"guest_access" => guest}}
            ] do
          assert [event] = state_events(resp.room_id, type), "#{label}: exactly one #{type} event"
          assert event["content"] == content, "#{label}: #{type}"
          assert event["sender"] == @creator, "#{label}: #{type} sender"
          assert event["state_key"] == "", "#{label}: #{type} state_key"
        end
      end
    end

    test "Element's private-room request (private_chat + guest_access / history_visibility / encryption entries): invite rule, the entries win, one event per type" do
      resp =
        create_ok(
          preset: "private_chat",
          visibility: "private",
          name: "Private #{rand()}",
          initial_state_json:
            initial_state([
              entry("m.room.guest_access", %{"guest_access" => "can_join"}),
              entry("m.room.history_visibility", %{"history_visibility" => "invited"}),
              entry("m.room.encryption", %{"algorithm" => "m.megolm.v1.aes-sha2"})
            ])
        )

      assert only_content(resp.room_id, "m.room.join_rules") == %{"join_rule" => "invite"}
      assert only_content(resp.room_id, "m.room.history_visibility") == %{"history_visibility" => "invited"}
      assert only_content(resp.room_id, "m.room.guest_access") == %{"guest_access" => "can_join"}
      assert state_events(resp.room_id, "m.room.encryption") == [], "ADR-011: encryption stays skipped"
    end

    test "Element's public-room request: preset public_chat + visibility public + room_alias_name: public / shared / forbidden, the alias as before" do
      localpart = "pub-" <> rand()
      resp = create_ok(preset: "public_chat", visibility: "public", room_alias_name: localpart, name: "Public Room")

      assert only_content(resp.room_id, "m.room.join_rules") == %{"join_rule" => "public"}
      assert only_content(resp.room_id, "m.room.history_visibility") == %{"history_visibility" => "shared"}
      assert only_content(resp.room_id, "m.room.guest_access") == %{"guest_access" => "forbidden"}
      assert only_content(resp.room_id, "m.room.canonical_alias") == %{"alias" => alias_for(localpart)}
    end

    test "an initial_state entry for (type, \"\") replaces the preset event (the preset event is NOT written): one event of the type, the entry's" do
      resp =
        create_ok(
          preset: "private_chat",
          initial_state_json: initial_state([entry("m.room.join_rules", %{"join_rule" => "public"})])
        )

      assert only_content(resp.room_id, "m.room.join_rules") == %{"join_rule" => "public"}
      # the other preset types are not suppressed by it
      assert only_content(resp.room_id, "m.room.history_visibility") == %{"history_visibility" => "shared"}
      assert only_content(resp.room_id, "m.room.guest_access") == %{"guest_access" => "can_join"}
    end

    test "an initial_state entry WITHOUT a state_key key counts as state_key \"\" and replaces the preset event" do
      resp =
        create_ok(
          preset: "private_chat",
          initial_state_json: Jason.encode!([%{"type" => "m.room.join_rules", "content" => %{"join_rule" => "public"}}])
        )

      assert only_content(resp.room_id, "m.room.join_rules") == %{"join_rule" => "public"}
    end

    test "an initial_state entry with a NON-EMPTY state_key does not suppress the preset event (state_key \"\" is still written)" do
      resp =
        create_ok(
          preset: "private_chat",
          initial_state_json: initial_state([entry("m.room.join_rules", %{"join_rule" => "public"}, "some-key")])
        )

      assert only_content(resp.room_id, "m.room.join_rules") == %{"join_rule" => "invite"}
      assert [%{"content" => %{"join_rule" => "public"}}] = state_events(resp.room_id, "m.room.join_rules", "some-key")
    end

    test "an initial_state entry of a SKIPPED type does not count as a replacement of anything (m.room.encryption / m.room.power_levels entries leave the presets alone)" do
      resp =
        create_ok(
          preset: "public_chat",
          initial_state_json:
            initial_state([
              entry("m.room.encryption", %{"algorithm" => "m.megolm.v1.aes-sha2"}),
              entry("m.room.power_levels", %{"users_default" => 100})
            ])
        )

      assert only_content(resp.room_id, "m.room.join_rules") == %{"join_rule" => "public"}
      assert only_content(resp.room_id, "m.room.history_visibility") == %{"history_visibility" => "shared"}
      assert only_content(resp.room_id, "m.room.guest_access") == %{"guest_access" => "forbidden"}
    end

    test "a failing preset event write is a 500 and the half-created room is cleaned up, for each of the three preset events" do
      for type <- ["m.room.join_rules", "m.room.history_visibility", "m.room.guest_access"] do
        :ets.delete_all_objects(@ets)
        :ets.insert(@ets, {{:fail_insert, type}, :simulated_db_down})

        assert {:error, {500, _errcode, _}} = create(preset: "private_chat", name: "Fails #{type}"), type
        assert [room_id] = deleted_rooms(), "#{type}: the orphan room is deleted"
        assert :ets.lookup(@ets, {:room, room_id}) == []
      end
    end

    test "a failing preset write releases the alias registered at step 4: the orphan cleanup leaves no room_aliases row behind" do
      localpart = "orphan-" <> rand()
      :ets.insert(@ets, {{:fail_insert, "m.room.join_rules"}, :simulated_db_down})

      assert {:error, {500, _, _}} = create(room_alias_name: localpart, preset: "private_chat", name: "Orphan")
      assert [_room_id] = deleted_rooms()
      assert :ets.lookup(@ets, {:alias, alias_for(localpart)}) == [], "the explicit alias is free again"
    end

    test "the join rule is fatal even when only the preset can set it: a failing m.room.join_rules write with initial_state that replaces the OTHER two types still 500s" do
      :ets.insert(@ets, {{:fail_insert, "m.room.join_rules"}, :simulated_db_down})

      assert {:error, {500, _, _}} =
               create(
                 preset: "public_chat",
                 initial_state_json:
                   initial_state([
                     entry("m.room.history_visibility", %{"history_visibility" => "shared"}),
                     entry("m.room.guest_access", %{"guest_access" => "forbidden"})
                   ])
               )

      assert [_room_id] = deleted_rooms()
    end
  end

  # ─── AC4 / D3: order and timestamps ──────────────────────────────────────────

  describe "AC4 - one strictly increasing timestamp chain for the steps 4-7" do
    test "alias, preset events, 64 initial_state entries, name, topic: spec order, strictly increasing origin_server_ts, top-level values win" do
      localpart = "chain-" <> rand()

      fillers = for i <- 1..61, do: entry("m.test.filler", %{"i" => i}, "k#{i}")

      entries =
        [
          entry("m.room.history_visibility", %{"history_visibility" => "invited"}),
          entry("m.room.name", %{"name" => "Entry name"}),
          entry("m.room.topic", %{"topic" => "Entry topic"})
        ] ++ fillers

      assert length(entries) == 64

      resp =
        create_ok(
          room_alias_name: localpart,
          preset: "public_chat",
          name: "Top name",
          topic: "Top topic",
          initial_state_json: initial_state(entries)
        )

      room = resp.room_id

      # --- spec order (by insertion sequence) ---
      creator_join = seq_of(room, "m.room.member", @creator)

      assert seq_of(room, "m.room.create") < creator_join
      assert creator_join < seq_of(room, "m.room.power_levels")
      assert seq_of(room, "m.room.power_levels") < seq_of(room, "m.room.canonical_alias")
      assert seq_of(room, "m.room.canonical_alias") < seq_of(room, "m.room.join_rules")
      assert seq_of(room, "m.room.join_rules") < seq_of(room, "m.room.guest_access"), "preset order: join_rules, history_visibility, guest_access"

      entry_seqs =
        events(room)
        |> Enum.filter(fn ev ->
          ev["type"] == "m.test.filler" or
            (ev["type"] == "m.room.history_visibility") or
            (ev["type"] == "m.room.topic" and ev["content"]["topic"] == "Entry topic") or
            (ev["type"] == "m.room.name" and ev["content"]["name"] == "Entry name")
        end)
        |> Enum.map(& &1["__seq"])

      assert length(entry_seqs) == 64, "all 64 entries are applied"
      assert seq_of(room, "m.room.guest_access") < Enum.min(entry_seqs), "preset events come before every initial_state entry"

      assert [name_event] = events(room) |> Enum.filter(&(&1["type"] == "m.room.name" and &1["content"]["name"] == "Top name"))
      assert [topic_event] = events(room) |> Enum.filter(&(&1["type"] == "m.room.topic" and &1["content"]["topic"] == "Top topic"))

      assert Enum.max(entry_seqs) < name_event["__seq"], "name after every initial_state entry"
      assert name_event["__seq"] < topic_event["__seq"], "topic after the name"

      # --- the timestamp chain: from step 4 (the explicit alias) on, STRICTLY increasing in insertion order ---
      chain =
        events(room)
        |> Enum.filter(&(&1["__seq"] >= seq_of(room, "m.room.canonical_alias")))
        |> Enum.sort_by(& &1["__seq"])

      assert length(chain) == 1 + 2 + 64 + 2, "alias + 2 preset events (history_visibility is replaced by the entry) + 64 entries + name + topic"

      chain
      |> Enum.map(& &1["origin_server_ts"])
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [previous, next] ->
        assert next > previous, "origin_server_ts must be strictly increasing along the chain, got #{previous} then #{next}"
      end)

      # --- the latest value per slot, by origin_server_ts ---
      latest = fn type, content_key ->
        events(room) |> Enum.filter(&(&1["type"] == type)) |> Enum.max_by(& &1["origin_server_ts"]) |> get_in(["content", content_key])
      end

      assert latest.("m.room.name", "name") == "Top name"
      assert latest.("m.room.topic", "topic") == "Top topic"
      assert [%{"content" => %{"history_visibility" => "invited"}}] = state_events(room, "m.room.history_visibility"), "the entry replaced the preset event"
      assert room_name(room) == "Top name"
    end

    test "the top-level name and topic beat the initial_state name and topic in every one of 25 runs (no luck of the millisecond)" do
      for _ <- 1..25 do
        resp =
          create_ok(
            name: "Top",
            topic: "Top topic",
            initial_state_json:
              initial_state([
                entry("m.room.name", %{"name" => "Entry"}),
                entry("m.room.topic", %{"topic" => "Entry topic"})
              ])
          )

        for {type, key, expected} <- [{"m.room.name", "name", "Top"}, {"m.room.topic", "topic", "Top topic"}] do
          [first, second] = events(resp.room_id) |> Enum.filter(&(&1["type"] == type)) |> Enum.sort_by(& &1["__seq"])
          assert first["content"][key] != expected
          assert second["content"][key] == expected
          assert second["origin_server_ts"] > first["origin_server_ts"], "#{type}: the top-level write must be strictly later than the initial_state entry"
        end
      end
    end

    test "alias -> remaining preset events -> the initial_state entry that replaced the third one: strictly increasing in insertion order, 20 runs" do
      for _ <- 1..20 do
        localpart = "ts-" <> rand()

        resp =
          create_ok(
            room_alias_name: localpart,
            preset: "private_chat",
            initial_state_json: initial_state([entry("m.room.join_rules", %{"join_rule" => "public"})])
          )

        # the join_rules preset event is replaced by the entry: alias, history_visibility, guest_access (preset), join_rules (entry)
        chain =
          [
            state_events(resp.room_id, "m.room.canonical_alias"),
            state_events(resp.room_id, "m.room.history_visibility"),
            state_events(resp.room_id, "m.room.guest_access"),
            state_events(resp.room_id, "m.room.join_rules")
          ]
          |> Enum.map(fn [event] -> event end)

        assert Enum.map(chain, & &1["__seq"]) == Enum.sort(Enum.map(chain, & &1["__seq"])), "emitted in this order"

        chain
        |> Enum.map(& &1["origin_server_ts"])
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.each(fn [previous, next] -> assert next > previous end)

        assert hd(state_events(resp.room_id, "m.room.join_rules"))["content"] == %{"join_rule" => "public"}
      end
    end

    test "without room_alias_name the derived canonical alias comes after the name AND the topic, with a strictly greater timestamp" do
      for _ <- 1..20 do
        name = "Derived " <> rand()
        resp = create_ok(name: name, topic: "t #{rand()}")

        [alias_event] = state_events(resp.room_id, "m.room.canonical_alias")
        [name_event] = state_events(resp.room_id, "m.room.name")
        [topic_event] = state_events(resp.room_id, "m.room.topic")

        assert name_event["__seq"] < topic_event["__seq"]
        assert topic_event["__seq"] < alias_event["__seq"]
        assert topic_event["origin_server_ts"] > name_event["origin_server_ts"]
        assert alias_event["origin_server_ts"] > topic_event["origin_server_ts"]
      end
    end
  end

  # ─── AC5 / D4: preset / visibility validation ────────────────────────────────

  describe "AC5 - preset / visibility validation (core part)" do
    test "an unknown preset string is 400 M_INVALID_PARAM, no room" do
      for preset <- ["private", "Public_Chat", "", "PRIVATE_CHAT", " public_chat", "public_chat ", "public"] do
        assert_rejected([preset: preset], "M_INVALID_PARAM", "preset #{inspect(preset)}")
      end
    end

    test "a non-string preset is 400 M_BAD_JSON, no room" do
      for preset <- [5, true, false, %{}, ["public_chat"], 1.5] do
        assert_rejected([preset: preset], "M_BAD_JSON", "preset #{inspect(preset)}")
      end
    end

    test "an unknown visibility string is 400 M_INVALID_PARAM, no room" do
      for visibility <- ["hidden", "", "PUBLIC", "public ", "private_chat"] do
        assert_rejected([visibility: visibility], "M_INVALID_PARAM", "visibility #{inspect(visibility)}")
      end
    end

    test "a non-string visibility is 400 M_BAD_JSON, no room" do
      for visibility <- [1, true, false, [], %{}, 1.5] do
        assert_rejected([visibility: visibility], "M_BAD_JSON", "visibility #{inspect(visibility)}")
      end
    end

    test "nil (null / absent) for either is accepted: the defaults" do
      resp = create_ok(preset: nil, visibility: nil)
      assert only_content(resp.room_id, "m.room.join_rules") == %{"join_rule" => "invite"}
    end

    test "the client-facing messages are fixed text: the offending value is never echoed" do
      marker = "zzpreset" <> rand()
      refute assert_rejected([preset: marker], "M_INVALID_PARAM", "preset marker") =~ marker
      refute assert_rejected([visibility: marker], "M_INVALID_PARAM", "visibility marker") =~ marker
    end

    test "D11 first failure: an invalid preset together with a taken room_alias_name is M_INVALID_PARAM (the alias pre-check is the last read)" do
      taken = "taken-" <> rand()
      :ets.insert(@ets, {{:alias, alias_for(taken)}, "!first:test.local"})

      assert_rejected([preset: "bogus", room_alias_name: taken], "M_INVALID_PARAM", "invalid preset + taken alias")
      assert_rejected([visibility: "bogus", room_alias_name: taken], "M_INVALID_PARAM", "invalid visibility + taken alias")
      assert_rejected([room_alias_name: taken], "M_ROOM_IN_USE", "the taken alias alone")
    end

    test "D11 order: name, topic, creation_content, room_version, alias, initial_state aliases, preset / visibility, override shape, lock-out, taken alias" do
      taken = "d11-taken-" <> rand()
      :ets.insert(@ets, {{:alias, alias_for(taken)}, "!first:test.local"})
      bad_pl = %{"ban" => "x"}
      lock_out = %{"state_default" => 101}

      for {label, attrs, errcode} <- [
            {"a name error (256 code points) beats a topic error (42)", [name: String.duplicate("a", 256), topic: 42], "M_INVALID_PARAM"},
            {"a topic error beats an invalid room_version", [topic: 42, room_version: "11"], "M_BAD_JSON"},
            {"a topic that is too long beats an invalid room_version", [topic: String.duplicate("t", 1025), room_version: "11"], "M_INVALID_PARAM"},
            {"an invalid initial_state topic entry beats an invalid room_version", [room_version: "11", initial_state_json: initial_state([entry("m.room.topic", %{"topic" => 42})])], "M_BAD_JSON"},
            {"a top-level topic error beats an initial_state topic error", [topic: 42, initial_state_json: initial_state([entry("m.room.topic", %{"topic" => String.duplicate("t", 1025)})])], "M_BAD_JSON"},
            {"a topic error beats creation_content errors (distinct errcodes)", [topic: String.duplicate("t", 1025), creation_content_json: Jason.encode!(%{"x" => "a\u0000b"})], "M_INVALID_PARAM"},
            {"an invalid room_version beats an invalid preset", [room_version: "11", preset: "bogus"], "M_UNSUPPORTED_ROOM_VERSION"},
            {"a bad room_alias_name beats a preset of the wrong type (distinct errcodes)", [room_alias_name: "a:b", preset: 5], "M_INVALID_PARAM"},
            {"an initial_state alias error beats an invalid preset", [room_alias_name: "ok-#{rand()}", initial_state_json: initial_state([entry("m.room.canonical_alias", %{"alias" => "#other:" <> @server})]), preset: "bogus"], "M_BAD_ALIAS"},
            {"an invalid preset beats a bad override", [preset: "bogus", power_level_content_override: bad_pl], "M_INVALID_PARAM"},
            {"an invalid visibility beats a bad override", [visibility: "bogus", power_level_content_override: bad_pl], "M_INVALID_PARAM"},
            {"a bad override shape beats a lock-out", [power_level_content_override: Map.merge(bad_pl, lock_out)], "M_BAD_JSON"},
            {"a bad override shape beats a taken alias", [room_alias_name: taken, power_level_content_override: bad_pl], "M_BAD_JSON"},
            {"a lock-out beats a taken alias", [room_alias_name: taken, power_level_content_override: lock_out], "M_INVALID_ROOM_STATE"},
            {"the taken alias alone", [room_alias_name: taken], "M_ROOM_IN_USE"}
          ] do
        assert_rejected(attrs, errcode, label)
      end
    end
  end

  # ─── AC6 / D6: visibility is stored (unit part) ──────────────────────────────

  describe "AC6 - visibility stores the directory flag through the audited set_room_visibility/3" do
    test "visibility public: ONE update_room_visibility call and ONE room_visibility_changed row with the creator as actor" do
      resp = create_ok(visibility: "public", name: "Listed")

      assert visibility_calls() == [{resp.room_id, "public"}]

      assert [[@creator, "room", room_id, %{"visibility" => "public"}]] = audits("room_visibility_changed")
      assert room_id == resp.room_id
    end

    test "visibility private, absent and nil write nothing and audit nothing" do
      for attrs <- [[visibility: "private"], [], [visibility: nil]] do
        create_ok(attrs)
      end

      assert visibility_calls() == []
      assert audits("room_visibility_changed") == []
    end

    test "a failing visibility write: the room IS created, the warning is value-free (room id, error class, no database text)" do
      marker = "mkvis" <> rand()
      :ets.insert(@ets, {:fail_visibility, pg_error(marker)})

      {log, result} = capture_create(visibility: "public", name: "Marker #{rand()}")

      assert {:ok, resp} = result
      assert :ets.lookup(@ets, {:room, resp.room_id}) != [], "the room exists"
      assert deleted_rooms() == []
      assert log =~ resp.room_id
      assert log =~ "postgres 22P05"
      refute String.downcase(log) =~ marker
    end

    test "Admin create_room visibility public: join rule public, the core writes the flag, EXACTLY ONE audit row" do
      assert {:ok, room_id} = Nebu.Matrix.create_room(@creator, name: "Admin Public " <> rand(), visibility: "public")
      track_room(room_id)

      assert only_content(room_id, "m.room.join_rules") == %{"join_rule" => "public"}
      assert visibility_calls() == [{room_id, "public"}], "one flag write: the wrapper must not write a second time"
      assert length(audits("room_visibility_changed")) == 1, "one audit row, not two"
      assert [[@creator, "room", ^room_id, %{"visibility" => "public"}]] = audits("room_visibility_changed")
    end

    test "Nebu.Matrix.create_room with visibility private and with the default: join rule invite, no flag write" do
      for opts <- [[visibility: "private"], []] do
        assert {:ok, room_id} = Nebu.Matrix.create_room(@creator, [name: "Admin Private " <> rand()] ++ opts)
        track_room(room_id)
        assert only_content(room_id, "m.room.join_rules") == %{"join_rule" => "invite"}
      end

      assert visibility_calls() == []
      assert audits("room_visibility_changed") == []
    end

    test "Nebu.Matrix.create_room with an invalid visibility is {:error, :invalid_visibility} and creates no room (unchanged)" do
      before = room_snapshot()
      assert {:error, :invalid_visibility} = Nebu.Matrix.create_room(@creator, name: "Bogus", visibility: "bogus")
      assert room_snapshot() == before
    end

    test "Nebu.Matrix.create_space (a private Space) writes the invite join rule and no flag" do
      assert {:ok, room_id} = Nebu.Matrix.create_space(@creator, "Space " <> rand())
      track_room(room_id)

      assert only_content(room_id, "m.room.join_rules") == %{"join_rule" => "invite"}
      assert only_content(room_id, "m.room.power_levels") == default_levels_with_creator(), "no override: default levels with the creator at 100"
      assert visibility_calls() == []
    end
  end

  # ─── AC7 / D5: topic (core) ──────────────────────────────────────────────────

  describe "AC7 - the top-level topic" do
    test "topic \"Weekly sync\" writes exactly {topic, m.topic text/plain}, sender creator, state_key \"\"" do
      resp = create_ok(topic: "Weekly sync")

      assert [event] = state_events(resp.room_id, "m.room.topic")
      assert event["content"] == %{"topic" => "Weekly sync", "m.topic" => %{"m.text" => [%{"body" => "Weekly sync", "mimetype" => "text/plain"}]}}
      assert event["sender"] == @creator
      assert rooms_topic_calls() == [], "D9: rooms.topic is not written"
    end

    test "a multibyte topic is stored verbatim (the m.topic body equals the topic)" do
      topic = "Räume für Größe " <> rand()
      resp = create_ok(topic: topic)
      content = only_content(resp.room_id, "m.room.topic")
      assert content["topic"] == topic
      assert content["m.topic"] == %{"m.text" => [%{"body" => topic, "mimetype" => "text/plain"}]}
    end

    test "the CORE treats a nil topic as absent (null vs absent cannot be told apart in the request struct): the router answers a present null with 400 before the core is called (HTTP test)" do
      resp = create_ok(topic: nil)
      assert state_events(resp.room_id, "m.room.topic") == []
    end

    test "the request struct carries the new fields (req/1 uses struct/2, which silently drops unknown keys: without this guard the other tests would test nothing)" do
      request = %Core.CreateRoomRequest{}

      for key <- [:preset, :visibility, :power_level_content_override, :topic] do
        assert Map.has_key?(request, key), "Core.CreateRoomRequest has the field #{key}"
      end
    end

    test "topic absent: no top-level topic event; an initial_state topic entry stays the current (only) topic" do
      resp = create_ok([])
      assert state_events(resp.room_id, "m.room.topic") == []

      resp = create_ok(initial_state_json: initial_state([entry("m.room.topic", %{"topic" => "from the entry"})]))
      assert only_content(resp.room_id, "m.room.topic") == %{"topic" => "from the entry"}
    end

    test "topic \"\" WRITES {\"topic\": \"\"} (no m.topic block) and overrides an initial_state topic entry" do
      resp = create_ok(topic: "")
      assert only_content(resp.room_id, "m.room.topic") == %{"topic" => ""}

      resp = create_ok(topic: "", initial_state_json: initial_state([entry("m.room.topic", %{"topic" => "entry topic"})]))
      assert [entry_event, top_event] = state_events(resp.room_id, "m.room.topic")
      assert entry_event["content"] == %{"topic" => "entry topic"}
      assert top_event["content"] == %{"topic" => ""}
      assert top_event["origin_server_ts"] > entry_event["origin_server_ts"]
    end

    test "1024 code points are accepted (multibyte: more than 1024 bytes), 1025 are 400 M_INVALID_PARAM, no room" do
      for topic <- [String.duplicate("t", 1024), String.duplicate("ä", 1024)] do
        resp = create_ok(topic: topic)
        assert only_content(resp.room_id, "m.room.topic")["topic"] == topic
      end

      assert byte_size(String.duplicate("ä", 1024)) == 2048
      assert_rejected([topic: String.duplicate("t", 1025)], "M_INVALID_PARAM", "1025 ASCII")
      assert_rejected([topic: String.duplicate("ä", 1025)], "M_INVALID_PARAM", "1025 multibyte")
    end

    test "a topic with a NUL and a non-string topic (42, true, false, {}, [\"x\"], 1.5) are 400 M_BAD_JSON, no room" do
      for {label, topic} <- [nul: "a\u0000b", number: 42, boolean: true, false: false, object: %{}, list: ["x"], float: 1.5] do
        assert_rejected([topic: topic], "M_BAD_JSON", "topic #{label}")
      end
    end

    test "the client-facing messages are fixed text: the topic is never echoed" do
      marker = "zztopic" <> rand()
      refute assert_rejected([topic: marker <> String.duplicate("t", 1025)], "M_INVALID_PARAM", "marker topic") =~ marker
      refute assert_rejected([topic: marker <> "\u0000"], "M_BAD_JSON", "marker topic NUL") =~ marker
    end

    test "a failing m.room.topic write is NON-fatal like the name: the room is created, the warning is value-free" do
      marker = "mktopic" <> rand()
      :ets.insert(@ets, {{:fail_insert, "m.room.topic"}, pg_error(marker)})

      {log, result} = capture_create(topic: marker, name: "Name stays")
      assert {:ok, resp} = result
      assert state_events(resp.room_id, "m.room.topic") == []
      assert [_] = state_events(resp.room_id, "m.room.name"), "the name write is independent"
      assert deleted_rooms() == []
      assert log =~ resp.room_id
      assert log =~ "postgres 22P05"
      refute String.downcase(log) =~ marker
    end

    test "a failing name write does not stop the topic (both non-fatal, independent)" do
      :ets.insert(@ets, {{:fail_insert, "m.room.name"}, :simulated_db_down})
      capture_log(fn -> send(self(), {:result, create(name: "Name fails", topic: "Topic ok")}) end)
      assert_received {:result, {:ok, resp}}
      assert state_events(resp.room_id, "m.room.name") == []
      assert only_content(resp.room_id, "m.room.topic")["topic"] == "Topic ok"
    end
  end

  # ─── AC8 / D5: the content rule for initial_state topic entries ──────────────

  describe "AC8 - m.room.topic entries of initial_state follow the same content rule" do
    defp topic_entry(content), do: initial_state([entry("m.room.topic", content)])

    test "{\"topic\": \"\"}, {} and {\"topic\": null} are accepted (200)" do
      for content <- [%{"topic" => ""}, %{}, %{"topic" => nil}] do
        resp = create_ok([initial_state_json: topic_entry(content)], inspect(content))
        assert only_content(resp.room_id, "m.room.topic") == content
      end
    end

    test "a non-string topic is 400 M_BAD_JSON, 1025 code points 400 M_INVALID_PARAM; no room" do
      for {label, value} <- [number: 42, boolean: true, object: %{}, list: ["x"]] do
        assert_rejected([initial_state_json: topic_entry(%{"topic" => value})], "M_BAD_JSON", "topic #{label}")
      end

      assert_rejected([initial_state_json: topic_entry(%{"topic" => String.duplicate("t", 1025)})], "M_INVALID_PARAM", "1025 code points")
      resp = create_ok(initial_state_json: topic_entry(%{"topic" => String.duplicate("ä", 1024)}))
      assert only_content(resp.room_id, "m.room.topic")["topic"] == String.duplicate("ä", 1024)
    end

    test "a malformed m.topic is 400 M_BAD_JSON: \"x\", {\"m.text\": \"x\"}, {\"m.text\": [5]}, {\"m.text\": [{\"body\": 5}]}, a non-string mimetype" do
      for {label, m_topic} <- [
            string: "x",
            number: 5,
            list: [],
            m_text_string: %{"m.text" => "x"},
            m_text_object: %{"m.text" => %{"body" => "x"}},
            m_text_number_entry: %{"m.text" => [5]},
            m_text_string_entry: %{"m.text" => ["x"]},
            body_number: %{"m.text" => [%{"body" => 5}]},
            body_missing: %{"m.text" => [%{"mimetype" => "text/plain"}]},
            body_null: %{"m.text" => [%{"body" => nil}]},
            mimetype_number: %{"m.text" => [%{"body" => "a", "mimetype" => 5}]},
            second_entry_bad: %{"m.text" => [%{"body" => "ok"}, %{"body" => 7}]}
          ] do
        assert_rejected([initial_state_json: topic_entry(%{"topic" => "t", "m.topic" => m_topic})], "M_BAD_JSON", "m.topic #{label}")
      end
    end

    test "an m.text body of 4097 code points is 400 M_INVALID_PARAM, 4096 are accepted (also in the second entry)" do
      body = fn n -> %{"topic" => "t", "m.topic" => %{"m.text" => [%{"body" => String.duplicate("b", n)}]}} end

      assert_rejected([initial_state_json: topic_entry(body.(4097))], "M_INVALID_PARAM", "4097 code points")

      assert_rejected(
        [initial_state_json: topic_entry(%{"topic" => "t", "m.topic" => %{"m.text" => [%{"body" => "ok"}, %{"body" => String.duplicate("b", 4097)}]}})],
        "M_INVALID_PARAM",
        "4097 code points in the second text"
      )

      resp = create_ok(initial_state_json: topic_entry(body.(4096)))
      assert only_content(resp.room_id, "m.room.topic") == body.(4096)
    end

    test "the m.text list is capped at 8 entries (Nebu policy, review cycle 1, F-10): 9 is 400 M_INVALID_PARAM, 8 are accepted" do
      texts = fn n -> for i <- 1..n, do: %{"body" => "t#{i}", "mimetype" => "text/plain"} end
      content = fn n -> %{"topic" => "t", "m.topic" => %{"m.text" => texts.(n)}} end

      assert_rejected([initial_state_json: topic_entry(content.(9))], "M_INVALID_PARAM", "9 texts")
      assert_rejected([initial_state_json: topic_entry(content.(40))], "M_INVALID_PARAM", "40 texts")
      resp = create_ok(initial_state_json: topic_entry(content.(8)))
      assert only_content(resp.room_id, "m.room.topic") == content.(8)
    end

    test "{\"m.text\": []}, an absent / null m.topic and an m.topic that differs from topic are accepted and stored as sent" do
      for content <- [
            %{"topic" => "t", "m.topic" => %{"m.text" => []}},
            %{"topic" => "t", "m.topic" => nil},
            %{"topic" => "t", "m.topic" => %{}},
            %{"topic" => "plain", "m.topic" => %{"m.text" => [%{"body" => "something else", "mimetype" => "text/plain"}]}},
            %{"topic" => "t", "m.topic" => %{"m.text" => [%{"body" => "html", "mimetype" => "text/html"}, %{"body" => "x"}]}}
          ] do
        resp = create_ok([initial_state_json: topic_entry(content)], inspect(content))
        assert only_content(resp.room_id, "m.room.topic") == content
      end
    end

    test "a topic entry with a NON-EMPTY state_key is not a room topic: the content rule does not apply to it" do
      resp = create_ok(initial_state_json: initial_state([entry("m.room.topic", %{"topic" => 42}, "other-key")]))
      assert [%{"content" => %{"topic" => 42}}] = state_events(resp.room_id, "m.room.topic", "other-key")
    end
  end

  # ─── AC9 / D7: power_level_content_override, merge ───────────────────────────

  describe "AC9 - power_level_content_override is merged (shallow) at spec step 3" do
    test "no override, a nil override and an empty override: the content is today's default levels with the creator at 100, written once" do
      assert default_levels_with_creator() |> Map.take(~w(ban kick invite redact state_default events_default users_default)) ==
               %{"ban" => 50, "kick" => 50, "invite" => 0, "redact" => 50, "state_default" => 50, "events_default" => 0, "users_default" => 0}

      for {label, attrs} <- [absent: [], nil: [power_level_content_override: nil], empty: [power_level_content_override: %{}]] do
        resp = create_ok(attrs, label)
        assert only_content(resp.room_id, "m.room.power_levels") == default_levels_with_creator(), to_string(label)
        assert persisted_power_levels(resp.room_id) == default_levels_with_creator(), to_string(label)
      end
    end

    test "Element's Space request (events_default 100, invite 50): default levels with those two keys replaced, event and json equal" do
      resp =
        create_ok(
          creation_content_json: Jason.encode!(%{"type" => "m.space"}),
          room_type: "m.space",
          preset: "private_chat",
          power_level_content_override: %{"events_default" => 100, "invite" => 50}
        )

      expected = default_levels_with_creator() |> Map.merge(%{"events_default" => 100, "invite" => 50})

      assert [event] = state_events(resp.room_id, "m.room.power_levels")
      assert event["content"] == expected
      assert event["sender"] == @creator
      assert persisted_power_levels(resp.room_id) == expected
    end

    test "a users override REPLACES the default users map (shallow merge): the creator is listed again or falls back to users_default" do
      resp = create_ok(power_level_content_override: %{"users" => %{@creator => 100, @other => 50}})
      assert only_content(resp.room_id, "m.room.power_levels")["users"] == %{@creator => 100, @other => 50}

      # without the creator the creator falls back to users_default 0: the preset events are then out of reach -> AC11
      assert_rejected([power_level_content_override: %{"users" => %{@other => 50}}], "M_INVALID_ROOM_STATE", "users without the creator")
    end

    test "an events override replaces the default (empty) events map and is stored as sent; users_default / users stay default" do
      resp = create_ok(power_level_content_override: %{"events" => %{"m.room.name" => 100, "m.room.topic" => 50}})
      content = only_content(resp.room_id, "m.room.power_levels")
      assert content["events"] == %{"m.room.name" => 100, "m.room.topic" => 50}
      assert content["users"] == %{@creator => 100}
      assert content == Map.put(default_levels_with_creator(), "events", %{"m.room.name" => 100, "m.room.topic" => 50})
    end

    test "unknown top-level keys are kept as sent (forward compatibility), notifications are stored" do
      override = %{"org.example.x" => 1, "org.example.nested" => %{"a" => [1, 2]}, "notifications" => %{"room" => 20}}
      resp = create_ok(power_level_content_override: override)
      assert only_content(resp.room_id, "m.room.power_levels") == Map.merge(default_levels_with_creator(), override)
    end

    test "overridable scalar keys: ban, kick, invite, redact, state_default, events_default, users_default (negative and large values included)" do
      override = %{"ban" => 75, "kick" => 60, "invite" => 25, "redact" => 10, "state_default" => 40, "events_default" => 5, "users_default" => 20}
      resp = create_ok(power_level_content_override: override)
      assert only_content(resp.room_id, "m.room.power_levels") == Map.merge(default_levels_with_creator(), override)
    end

    test "an override that only restricts LATER actions is applied as is (kick 101, invite 100, users_default 100): the room is created" do
      for override <- [%{"kick" => 101}, %{"invite" => 100}, %{"users_default" => 100}, %{"ban" => 101, "redact" => 101}, %{"events_default" => 100}] do
        resp = create_ok([power_level_content_override: override], inspect(override))
        assert only_content(resp.room_id, "m.room.power_levels") == Map.merge(default_levels_with_creator(), override)
      end
    end

    test "the override is applied once, BEFORE the other state events: one m.room.power_levels event, before the alias and presets" do
      resp = create_ok(room_alias_name: "pl-" <> rand(), preset: "public_chat", power_level_content_override: %{"events_default" => 100})
      assert [_] = state_events(resp.room_id, "m.room.power_levels")
      assert seq_of(resp.room_id, "m.room.power_levels") < seq_of(resp.room_id, "m.room.canonical_alias")
      assert seq_of(resp.room_id, "m.room.power_levels") < seq_of(resp.room_id, "m.room.join_rules")
    end
  end

  # ─── AC10 / D7: override validation ──────────────────────────────────────────

  describe "AC10 - override validation (400 M_BAD_JSON before any room exists)" do
    @max_int 9_007_199_254_740_991

    test "a non-object override (\"x\", [], 5, true, 1.5) is 400 M_BAD_JSON; nil is absent" do
      for value <- ["x", [], 5, true, false, 1.5, ["ban", 50]] do
        assert_rejected([power_level_content_override: value], "M_BAD_JSON", "override #{inspect(value)}")
      end

      create_ok(power_level_content_override: nil)
    end

    test "the rejected shapes of the story, one by one" do
      for {label, override} <- [
            ban_string: %{"ban" => "50"},
            ban_float: %{"ban" => 50.5},
            ban_whole_float: %{"ban" => 50.0},
            ban_bool: %{"ban" => true},
            kick_out_of_range: %{"kick" => @max_int + 1},
            kick_out_of_range_negative: %{"kick" => -@max_int - 1},
            events_list: %{"events" => []},
            events_string: %{"events" => "x"},
            events_empty_key: %{"events" => %{"" => 50}},
            events_value_string: %{"events" => %{"m.room.name" => "50"}},
            events_value_float: %{"events" => %{"m.room.name" => 50.5}},
            events_key_over_255_bytes: %{"events" => %{String.duplicate("e", 256) => 50}},
            users_bad_key: %{"users" => %{"not-a-user" => 50}},
            users_value_string: %{"users" => %{"@a:test.local" => "100"}},
            users_list: %{"users" => []},
            users_value_float: %{"users" => %{"@a:test.local" => 1.0}},
            users_bad_value_bool: %{"users" => %{"@a:test.local" => true}},
            notifications_value_string: %{"notifications" => %{"room" => "50"}},
            notifications_not_an_object: %{"notifications" => 5},
            notifications_list: %{"notifications" => [5]},
            ban_null: %{"ban" => nil},
            users_null: %{"users" => nil},
            events_null: %{"events" => nil},
            notifications_null: %{"notifications" => nil},
            events_inner_null: %{"events" => %{"m.room.name" => nil}},
            users_inner_null: %{"users" => %{"@a:test.local" => nil}},
            notifications_inner_null: %{"notifications" => %{"room" => nil}},
            users_default_below_range: %{"users_default" => -9_007_199_254_740_992},
            events_default_list: %{"events_default" => []},
            state_default_object: %{"state_default" => %{}},
            invite_string: %{"invite" => "0"},
            redact_float: %{"redact" => 1.5}
          ] do
        assert_rejected([power_level_content_override: override], "M_BAD_JSON", "override #{label}")
      end
    end

    test "the canonical-JSON boundaries are accepted: 9007199254740991 and -9007199254740991" do
      for value <- [@max_int, -@max_int] do
        resp = create_ok([power_level_content_override: %{"ban" => value}], "ban #{value}")
        assert only_content(resp.room_id, "m.room.power_levels")["ban"] == value
      end
    end

    test "a non-local but well-formed user id in users is accepted (harmless without federation)" do
      resp = create_ok(power_level_content_override: %{"users" => %{@creator => 100, "@someone:elsewhere.example" => 50}})
      assert only_content(resp.room_id, "m.room.power_levels")["users"]["@someone:elsewhere.example"] == 50
    end

    test "other keys are bounded by the existing depth (32) / NUL rules: an unknown key nesting 33 levels or containing a NUL is 400 M_BAD_JSON" do
      nested = fn levels -> Enum.reduce(2..levels, %{}, fn _, acc -> %{"a" => acc} end) end

      assert_rejected([power_level_content_override: %{"org.example.deep" => nested.(33)}], "M_BAD_JSON", "33 levels")
      assert_rejected([power_level_content_override: %{"org.example.nul" => "a\u0000b"}], "M_BAD_JSON", "NUL in a value")
      assert_rejected([power_level_content_override: %{"org.example.nul\u0000" => 1}], "M_BAD_JSON", "NUL in a key")
      create_ok(power_level_content_override: %{"org.example.deep" => nested.(31)})
    end

    test "the messages are fixed text: no client value (a user id, a key, a value) is echoed" do
      marker = "zzmark" <> rand()

      for {label, override} <- [
            value: %{"ban" => marker},
            events_key: %{"events" => %{marker => "x"}},
            events_value: %{"events" => %{"m.room.name" => marker}},
            users_key: %{"users" => %{"@" <> marker <> ":test.local" => "x"}},
            users_bad_key: %{"users" => %{marker => 5}},
            notifications_value: %{"notifications" => %{"room" => marker}},
            lock_out_user: %{"users" => %{"@" <> marker <> ":test.local" => 100}}
          ] do
        message =
          case create(power_level_content_override: override) do
            {:error, {400, errcode, message}} when errcode in ["M_BAD_JSON", "M_INVALID_ROOM_STATE"] -> message
            other -> flunk("#{label}: expected a 400, got #{inspect(other)}")
          end

        refute message =~ marker, "#{label}: the message must not echo the client value"
      end
    end
  end

  # ─── AC11 / D7: the creator lock-out ─────────────────────────────────────────

  describe "AC11 - the creator lock-out is 400 M_INVALID_ROOM_STATE (checked before the room exists)" do
    test "a creator who cannot reach state_default: users[creator] 0, state_default 101, users {} with users_default 0" do
      for {label, override} <- [
            demoted_creator: %{"users" => %{@creator => 0}},
            state_default_101: %{"state_default" => 101},
            empty_users_map: %{"users_default" => 0, "users" => %{}},
            creator_at_49: %{"users" => %{@creator => 49}},
            negative_creator: %{"users" => %{@creator => -1}}
          ] do
        assert_rejected([power_level_content_override: override], "M_INVALID_ROOM_STATE", label |> to_string())
      end
    end

    test "events[type] is the required level when it is an integer, else state_default: the creator exactly at the level is fine" do
      create_ok(power_level_content_override: %{"state_default" => 100})
      # story power-levels-enforcement (D12, AC16 re-pin): the default `events` map puts m.room.history_visibility (a preset event)
      # at 100, so a creator at 50 is locked out by events[type] unless the override replaces the map; with `"events": {}`
      # state_default (50) is the required level again and the creator exactly at it is fine
      assert_rejected([power_level_content_override: %{"users" => %{@creator => 50}}], "M_INVALID_ROOM_STATE", "50 < events[history_visibility] 100 (D12)")
      create_ok(power_level_content_override: %{"users" => %{@creator => 50}, "events" => %{}})
      assert_rejected([power_level_content_override: %{"users" => %{@creator => 49}, "events" => %{}}], "M_INVALID_ROOM_STATE", "49 < 50")
    end

    test "events m.room.topic 101 is refused when a top-level topic is written, accepted without one" do
      override = %{"events" => %{"m.room.topic" => 101}}
      assert_rejected([topic: "x", power_level_content_override: override], "M_INVALID_ROOM_STATE", "with a topic")
      assert_rejected([topic: "", power_level_content_override: override], "M_INVALID_ROOM_STATE", "with the empty topic (it is written too)")
      create_ok(power_level_content_override: override)
    end

    test "events m.room.name 101 is refused when a name is written (the spec's own example), accepted without one" do
      override = %{"events" => %{"m.room.name" => 101}}
      assert_rejected([name: "A name", power_level_content_override: override], "M_INVALID_ROOM_STATE", "with a name")
      create_ok(power_level_content_override: override)
    end

    test "events m.room.canonical_alias 101: refused with room_alias_name and with a derived alias, accepted with neither" do
      override = %{"events" => %{"m.room.canonical_alias" => 101}}
      assert_rejected([room_alias_name: "la-" <> rand(), power_level_content_override: override], "M_INVALID_ROOM_STATE", "explicit alias")
      assert_rejected([name: "Derived " <> rand(), power_level_content_override: override], "M_INVALID_ROOM_STATE", "derived alias")
      create_ok(power_level_content_override: override)
    end

    test "events join_rules / history_visibility / guest_access 101 are refused, also with a replacing initial_state entry" do
      for type <- ["m.room.join_rules", "m.room.history_visibility", "m.room.guest_access"] do
        override = %{"events" => %{type => 101}}
        assert_rejected([power_level_content_override: override], "M_INVALID_ROOM_STATE", "#{type}: preset")

        content =
          case type do
            "m.room.join_rules" -> %{"join_rule" => "public"}
            "m.room.history_visibility" -> %{"history_visibility" => "shared"}
            "m.room.guest_access" -> %{"guest_access" => "forbidden"}
          end

        assert_rejected(
          [power_level_content_override: override, initial_state_json: initial_state([entry(type, content)])],
          "M_INVALID_ROOM_STATE",
          "#{type}: the replacing initial_state entry"
        )
      end
    end

    # story power-levels-enforcement (D7, AC16 re-pin): m.room.power_levels is no longer a skipped type: its entry counts (the
    # creator must reach events["m.room.power_levels"] of the levels before it); m.room.encryption stays skipped
    test "every applied initial_state entry counts (power_levels too), skipped types (encryption) do not" do
      assert_rejected(
        [power_level_content_override: %{"events" => %{"m.test.custom" => 101}}, initial_state_json: initial_state([entry("m.test.custom", %{"a" => 1}, "k")])],
        "M_INVALID_ROOM_STATE",
        "applied entry"
      )

      create_ok(power_level_content_override: %{"events" => %{"m.test.custom" => 101}})

      create_ok(
        power_level_content_override: %{"events" => %{"m.room.encryption" => 101}},
        initial_state_json: initial_state([entry("m.room.encryption", %{"algorithm" => "m.megolm.v1.aes-sha2"})])
      )

      assert_rejected(
        [power_level_content_override: %{"events" => %{"m.room.power_levels" => 101}}, initial_state_json: initial_state([entry("m.room.power_levels", %{"users_default" => 100})])],
        "M_INVALID_ROOM_STATE",
        "an applied power_levels entry needs events[m.room.power_levels]"
      )

      create_ok(power_level_content_override: %{"events" => %{"m.room.power_levels" => 101}})
    end

    test "an m.space.parent entry counts although its guard may skip it (events m.space.parent 101 + an entry is refused)" do
      assert_rejected(
        [power_level_content_override: %{"events" => %{"m.space.parent" => 101}}, initial_state_json: initial_state([entry("m.space.parent", %{"via" => ["test.local"]}, "!parent:test.local")])],
        "M_INVALID_ROOM_STATE",
        "m.space.parent entry"
      )
    end

    test "later actions only (kick 101, invite 100, users_default 100, events_default 100) are applied: 200" do
      for override <- [%{"kick" => 101}, %{"invite" => 100}, %{"users_default" => 100}, %{"events_default" => 100}] do
        create_ok([power_level_content_override: override, name: "Later #{rand()}", topic: "t"], inspect(override))
      end
    end

    test "a demoted creator with per-type events exceptions that cover every state event written is applied as is" do
      override = %{
        "users" => %{@creator => 0},
        "events" => %{"m.room.join_rules" => 0, "m.room.history_visibility" => 0, "m.room.guest_access" => 0, "m.room.name" => 0, "m.room.topic" => 0, "m.room.canonical_alias" => 0}
      }

      resp = create_ok(power_level_content_override: override, name: "Demoted #{rand()}", topic: "t")
      assert only_content(resp.room_id, "m.room.power_levels")["users"] == %{@creator => 0}
    end

    test "a lock-out creates NOTHING: no room, event, alias or flag write, nothing deleted (pure validation)" do
      assert_rejected([power_level_content_override: %{"state_default" => 101}, visibility: "public", name: "Nope", room_alias_name: "lo-" <> rand()], "M_INVALID_ROOM_STATE", "full request")
      assert :ets.match(@ets, {{:event, :_}, :_}) == []
      assert :ets.match(@ets, {{:alias, :_}, :_}) == []
      assert visibility_calls() == []
      assert audits("room_visibility_changed") == []
    end
  end

  # ─── AC12 / D8: initial_state m.room.power_levels ────────────────────────────
  #
  # story power-levels-enforcement (D7, follow-up `er`, AC16 re-pin): the entry was SKIPPED (documented deviation) and is now
  # APPLIED at step 6 as a full replacement through the room-process power-level writer; the "skipped" warning is gone.

  describe "AC12 - an initial_state m.room.power_levels entry is applied (story power-levels-enforcement, D7)" do
    test "200, the levels are EXACTLY the entry's (a second event), the column too; no skipped warning, no content in the log" do
      marker = "mkpl" <> rand()
      content = %{"users_default" => 100, "org.example.marker" => marker}

      {log, result} = capture_create(initial_state_json: initial_state([entry("m.room.power_levels", content)]))

      assert {:ok, resp} = result
      assert [step3, applied] = state_events(resp.room_id, "m.room.power_levels")
      assert step3["content"] == default_levels_with_creator()
      assert applied["content"] == content
      assert persisted_power_levels(resp.room_id) == content
      refute log =~ "forbidden type", "the entry is not skipped any more"
      refute log =~ marker, "no entry content in the log"
    end

    test "with an override AND a power_levels entry the entry wins (step 6 after step 3, no merge)" do
      resp =
        create_ok(
          power_level_content_override: %{"events_default" => 100},
          initial_state_json: initial_state([entry("m.room.power_levels", %{"users_default" => 100})])
        )

      assert [step3, applied] = state_events(resp.room_id, "m.room.power_levels")
      assert step3["content"] == Map.put(default_levels_with_creator(), "events_default", 100)
      assert applied["content"] == %{"users_default" => 100}
      assert persisted_power_levels(resp.room_id) == %{"users_default" => 100}
    end
  end

  # ─── AC13: Admin / Space / personal paths (unit part) ────────────────────────

  describe "AC13 - the Admin and Space paths keep the default levels" do
    test "Nebu.Matrix.create_room and create_space: default levels with the admin at 100 (no override ever sent), derived alias unchanged" do
      assert {:ok, room_id} = Nebu.Matrix.create_room(@creator, name: "Admin Derived " <> rand())
      track_room(room_id)
      assert only_content(room_id, "m.room.power_levels") == default_levels_with_creator()
      assert [%{"content" => %{"alias" => alias_str}}] = state_events(room_id, "m.room.canonical_alias")
      assert alias_str =~ ~r/^#admin-derived-/

      assert {:ok, space_id} = Nebu.Matrix.create_space(@creator, "Admin Space " <> rand())
      track_room(space_id)
      assert only_content(space_id, "m.room.power_levels") == default_levels_with_creator()
    end

    test "the room_created audit row of the Admin path keeps its metadata keys" do
      assert {:ok, room_id} = Nebu.Matrix.create_room(@creator, name: "Audited " <> rand())
      track_room(room_id)

      assert [[@creator, "room", ^room_id, metadata]] = audits("room_created")
      assert metadata == %{"is_direct" => false}, "the full key set of today: no preset / topic / visibility / override key joins it"
    end

    test "a client create with every new key keeps the audit metadata to is_direct and alias (no topic, preset, visibility or override in the audit row)" do
      localpart = "audit-keys-" <> rand()

      resp =
        create_ok(
          room_alias_name: localpart,
          preset: "public_chat",
          visibility: "public",
          topic: "A topic",
          power_level_content_override: %{"events_default" => 100}
        )

      assert [[@creator, "room", _, metadata]] = Enum.filter(audits("room_created"), fn [_, _, target, _] -> target == resp.room_id end)
      assert metadata == %{"is_direct" => false, "alias" => alias_for(localpart)}
    end
  end

  # ─── AC14: value-free logs ───────────────────────────────────────────────────

  describe "AC14 - the new failure logs are value-free" do
    test "a failing preset event write: the log names the room id, the event type and the error class, never the database text / a client value" do
      marker = "mkpreset" <> rand()
      :ets.insert(@ets, {{:fail_insert, "m.room.guest_access"}, pg_error(marker)})

      {log, result} = capture_create(preset: "private_chat", name: "Fails", power_level_content_override: %{"org.example.marker" => marker})

      assert {:error, {500, _, _}} = result
      assert [room_id] = deleted_rooms()
      assert log =~ room_id
      assert log =~ "m.room.guest_access"
      assert log =~ "postgres 22P05"
      refute String.downcase(log) =~ marker
    end

    test "a rejected override logs no user id, key or value of the override; an accepted one neither" do
      marker = "mkoverride" <> rand()

      {log, result} = capture_create(power_level_content_override: %{"users" => %{"@" <> marker <> ":test.local" => "x"}, "events" => %{marker => 5}, "org.example.#{marker}" => marker})
      assert {:error, {400, "M_BAD_JSON", _}} = result
      refute String.downcase(log) =~ marker

      {log, result} = capture_create(power_level_content_override: %{"users" => %{@creator => 100, "@" <> marker <> ":test.local" => 50}, "org.example.#{marker}" => marker})
      assert {:ok, _} = result
      refute String.downcase(log) =~ marker, "the accepted override is not logged either"
    end

    test "a rejected topic logs no topic (too long, NUL, wrong type)" do
      marker = "mkrejtopic" <> rand()

      for topic <- [marker <> String.duplicate("t", 1025), marker <> "\u0000"] do
        {log, result} = capture_create(topic: topic)
        assert {:error, {400, _, _}} = result
        refute String.downcase(log) =~ marker
      end
    end
  end
end
