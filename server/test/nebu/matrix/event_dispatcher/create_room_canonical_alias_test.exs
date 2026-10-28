defmodule Nebu.Matrix.EventDispatcher.CreateRoomCanonicalAliasTest do
  use ExUnit.Case, async: false

  # ─── Story: room-canonical-alias-from-name ──────────────────────────────────
  #
  # When a room is created WITH a name (e.g. "general") on server "localhost", the
  # create path must:
  #   1. derive a spec-valid alias localpart from the name,
  #   2. register the alias `#localpart:server` in the room_aliases store (uniqueness
  #      enforced by the store — collisions append `-2`, `-3`, … deterministically),
  #   3. emit an `m.room.canonical_alias` state event (state_key "", content
  #      %{"alias" => "#localpart:server"}) AFTER the m.room.name event.
  #
  # The whole alias step is NON-FATAL: a derivation/registration/DB failure logs a
  # warning and leaves the room created. A room with NO name gets NO alias (backwards
  # compat).
  #
  # These tests are written FIRST (ATDD gate) and FAIL until the story lands.
  #
  # Strategy mirrors create_room_test.exs / create_room_creator_provisioning_test.exs:
  #   - call EventDispatcher.Server.create_room/2 directly (synchronous unary).
  #   - inject FakeDB for room_manager + messages/rooms DB seams (no Repo).
  #   - inject a FakeAliasDB for the NEW alias_db_module() seam so we can assert the
  #     room_aliases insert + collision handling without a live Repo.
  #
  # async: false — Horde, :pg, Application.put_env and :NebuTxnDedup are process-global.

  alias Nebu.Matrix.EventDispatcher.Server

  @ets :create_room_canonical_alias_test_db

  # ─── FakeDB — ETS-backed Room DB (no Repo) ───────────────────────────────────
  defmodule FakeDB do
    @ets :create_room_canonical_alias_test_db

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

    def insert_event(event) do
      :ets.insert(@ets, {{:event, event["event_id"]}, event})
      :ok
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

    def delete_room(room_id) do
      :ets.insert(@ets, {{:deleted_room, room_id}, true})
      :ets.delete(@ets, {:room, room_id})
      :ets.match_delete(@ets, {{:member, room_id, :_}, :_})
      :ok
    end

    def load_room_settings(_room_id), do: {:ok, 0}
    def get_room_status(_room_id), do: {:ok, "active"}
    def check_room_status_for_update(_room_id), do: {:ok, "active"}
  end

  # ─── FakeAliasDB — ETS-backed room_aliases store ─────────────────────────────
  #
  # insert_room_alias/3 simulates the unique PRIMARY KEY on `alias`: a second insert
  # of the same alias returns {:error, :conflict}; the server must then try the next
  # candidate (#localpart-2, …). Resolution is via lookup_alias/1.
  defmodule FakeAliasDB do
    @ets :create_room_canonical_alias_test_db

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

  # ─── FailingAliasDB — insert_room_alias always errors (non-fatal path) ───────
  defmodule FailingAliasDB do
    def insert_room_alias(_alias, _room_id, _created_at),
      do: {:error, %{__struct__: Postgrex.Error, message: "alias insert failed (simulated)"}}

    defdelegate lookup_alias(alias_str), to: FakeAliasDB
  end

  defmodule NoOpAuditWriter do
    def log(_, _, _, _, _, _, _ \\ nil), do: :ok
  end

  # ─── Setup / Teardown ────────────────────────────────────────────────────────

  setup do
    if :ets.info(@ets) != :undefined, do: :ets.delete(@ets)
    :ets.new(@ets, [:named_table, :public, :set])

    Application.put_env(:room_manager, :db_module, FakeDB)
    Application.put_env(:event_dispatcher, :messages_db_module, FakeDB)
    Application.put_env(:event_dispatcher, :rooms_db_module, FakeDB)
    Application.put_env(:event_dispatcher, :alias_db_module, FakeAliasDB)
    Application.put_env(:event_dispatcher, :user_store_module, Nebu.Test.NoOpUserStore)
    Application.put_env(:event_dispatcher, :server_name, "localhost")
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
      Application.delete_env(:event_dispatcher, :messages_db_module)
      Application.delete_env(:event_dispatcher, :rooms_db_module)
      Application.delete_env(:event_dispatcher, :alias_db_module)
      Application.delete_env(:event_dispatcher, :user_store_module)
      Application.delete_env(:event_dispatcher, :server_name)
      Application.delete_env(:compliance, :audit_writer)

      if :ets.info(@ets) != :undefined, do: :ets.delete(@ets)

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

  defp canonical_alias_events(room_id) do
    :ets.match(@ets, {{:event, :_}, :"$1"})
    |> Enum.map(fn [e] -> e end)
    |> Enum.filter(&(&1["type"] == "m.room.canonical_alias" and &1["room_id"] == room_id))
  end

  defp registered_aliases do
    :ets.match(@ets, {{:alias, :"$1"}, :"$2"})
    |> Enum.map(fn [a, r] -> {a, r} end)
  end

  # ─── AC1: canonical alias derived from name, emitted + registered ────────────

  describe "create_room derives and registers a canonical alias (AC1)" do
    test "name \"general\" → #general:localhost emitted and resolvable" do
      request = %Core.CreateRoomRequest{creator_id: "@alice:localhost", name: "general"}

      response = Server.create_room(request, build_stream())
      track_room(response.room_id)
      room_id = response.room_id

      events = canonical_alias_events(room_id)
      assert length(events) == 1, "expected exactly one m.room.canonical_alias event"
      assert hd(events)["state_key"] == ""
      assert hd(events)["content"]["alias"] == "#general:localhost"

      # Alias store resolves the alias to this room id.
      assert FakeAliasDB.lookup_alias("#general:localhost") == {:ok, room_id}
    end
  end

  # ─── AC3: localpart sanitisation (table cases) ───────────────────────────────

  describe "alias localpart is sanitised from the name (AC3)" do
    test "\"General\" → #general:localhost (lowercased)" do
      response = Server.create_room(%Core.CreateRoomRequest{creator_id: "@a:localhost", name: "General"}, build_stream())
      track_room(response.room_id)
      assert hd(canonical_alias_events(response.room_id))["content"]["alias"] == "#general:localhost"
    end

    test "\"Team Rocket!\" → #team-rocket:localhost" do
      response = Server.create_room(%Core.CreateRoomRequest{creator_id: "@a:localhost", name: "Team Rocket!"}, build_stream())
      track_room(response.room_id)
      assert hd(canonical_alias_events(response.room_id))["content"]["alias"] == "#team-rocket:localhost"
    end

    # Story create-room-input-validation (D5c): the cap counts code points, not bytes (255 x 3-byte characters = 765 bytes is fine)
    test "a 255 code point name of 3-byte characters is accepted; it has no usable alias localpart" do
      name = String.duplicate("日", 255)
      response = Server.create_room(%Core.CreateRoomRequest{creator_id: "@a:localhost", name: name}, build_stream())
      track_room(response.room_id)

      assert [{_, ^name}] = :ets.lookup(@ets, {:room_name, response.room_id})
      assert canonical_alias_events(response.room_id) == []
    end

    test "all-invalid name (emoji-only) → no alias, room still created" do
      response = Server.create_room(%Core.CreateRoomRequest{creator_id: "@a:localhost", name: "🎉🎉🎉"}, build_stream())
      track_room(response.room_id)

      # room exists, m.room.name still written with the original name
      assert is_binary(response.room_id) and response.room_id != ""
      assert [{_, "🎉🎉🎉"}] = :ets.lookup(@ets, {:room_name, response.room_id})

      # but NO canonical_alias event and NO registered alias
      assert canonical_alias_events(response.room_id) == []
      assert registered_aliases() == []
    end

    # Story create-room-input-validation (D5c): a name is capped at 255 code points (400 M_INVALID_PARAM above), so the longest
    # name that can reach the alias derivation is 255 characters; it still exceeds the 240-byte localpart budget of "localhost".
    test "an over-long name is bounded so the full alias is <= 255 bytes" do
      long = String.duplicate("a", 255)
      response = Server.create_room(%Core.CreateRoomRequest{creator_id: "@a:localhost", name: long}, build_stream())
      track_room(response.room_id)

      [event] = canonical_alias_events(response.room_id)
      alias_str = event["content"]["alias"]
      assert byte_size(alias_str) <= 255
      assert String.starts_with?(alias_str, "#")
      assert String.ends_with?(alias_str, ":localhost")
    end
  end

  # ─── AC2: collision yields a deterministic distinct alias ────────────────────

  describe "alias collision yields a unique alias (AC2)" do
    test "a second \"general\" room registers #general-2:localhost; first alias unchanged" do
      r1 = Server.create_room(%Core.CreateRoomRequest{creator_id: "@a:localhost", name: "general"}, build_stream())
      track_room(r1.room_id)

      r2 = Server.create_room(%Core.CreateRoomRequest{creator_id: "@b:localhost", name: "general"}, build_stream())
      track_room(r2.room_id)

      refute r1.room_id == r2.room_id

      # first alias still maps to the first room
      assert FakeAliasDB.lookup_alias("#general:localhost") == {:ok, r1.room_id}

      # second room got a distinct valid alias mapped to the second room
      alias2 = hd(canonical_alias_events(r2.room_id))["content"]["alias"]
      assert alias2 != "#general:localhost"
      assert alias2 == "#general-2:localhost"
      assert FakeAliasDB.lookup_alias(alias2) == {:ok, r2.room_id}
    end

    test "a third \"general\" room registers #general-3:localhost" do
      r1 = Server.create_room(%Core.CreateRoomRequest{creator_id: "@a:localhost", name: "general"}, build_stream())
      track_room(r1.room_id)
      r2 = Server.create_room(%Core.CreateRoomRequest{creator_id: "@b:localhost", name: "general"}, build_stream())
      track_room(r2.room_id)
      r3 = Server.create_room(%Core.CreateRoomRequest{creator_id: "@c:localhost", name: "general"}, build_stream())
      track_room(r3.room_id)

      alias3 = hd(canonical_alias_events(r3.room_id))["content"]["alias"]
      assert alias3 == "#general-3:localhost"
      assert FakeAliasDB.lookup_alias(alias3) == {:ok, r3.room_id}
    end
  end

  # ─── AC5: no name → no alias (backwards compat) ──────────────────────────────

  describe "no name → no alias (backwards compat, AC5)" do
    test "room with no name produces no canonical_alias event and no registration" do
      response = Server.create_room(%Core.CreateRoomRequest{creator_id: "@a:localhost"}, build_stream())
      track_room(response.room_id)

      assert is_binary(response.room_id) and response.room_id != ""
      assert canonical_alias_events(response.room_id) == []
      assert registered_aliases() == []
    end

    test "room with empty-string name produces no alias" do
      response = Server.create_room(%Core.CreateRoomRequest{creator_id: "@a:localhost", name: ""}, build_stream())
      track_room(response.room_id)

      assert canonical_alias_events(response.room_id) == []
      assert registered_aliases() == []
    end
  end

  # ─── AC3 (non-fatal): alias registration DB error → room still created ───────

  describe "alias step is non-fatal (AC3)" do
    setup do
      Application.put_env(:event_dispatcher, :alias_db_module, FailingAliasDB)
      :ok
    end

    test "alias-registration DB error leaves the room created (no raise, no alias event)" do
      response = Server.create_room(%Core.CreateRoomRequest{creator_id: "@a:localhost", name: "general"}, build_stream())
      track_room(response.room_id)

      # room created successfully despite the alias DB error
      assert is_binary(response.room_id) and response.room_id != ""
      assert [{_, "general"}] = :ets.lookup(@ets, {:room_name, response.room_id})

      # registration failed → no canonical_alias event emitted
      assert canonical_alias_events(response.room_id) == []
    end
  end

  # ─── Pure derivation function (unit, table cases) ────────────────────────────
  #
  # derive_alias_localpart/1 is the pure sanitiser. Tested directly so the rules are
  # pinned independent of the create path.

  describe "derive_alias_localpart/1 (pure)" do
    test "lowercases and trims" do
      assert Server.derive_alias_localpart("General") == {:ok, "general"}
    end

    test "replaces runs of invalid chars with a single dash, trims edges" do
      assert Server.derive_alias_localpart("Team Rocket!") == {:ok, "team-rocket"}
      assert Server.derive_alias_localpart("  hello   world  ") == {:ok, "hello-world"}
      assert Server.derive_alias_localpart("a@@@b") == {:ok, "a-b"}
    end

    test "keeps spec-allowed localpart chars [a-z0-9._=\\-+]" do
      assert Server.derive_alias_localpart("a.b_c=d+f-g") == {:ok, "a.b_c=d+f-g"}
    end

    # `/` is intentionally NOT in the allowlist: it mis-routes in the
    # /directory/room/{alias} path, so it folds to a dash (interop hardening).
    test "folds slash to a dash (not kept)" do
      assert Server.derive_alias_localpart("a/b") == {:ok, "a-b"}
      assert Server.derive_alias_localpart("foo/bar/baz") == {:ok, "foo-bar-baz"}
    end

    # Leading/trailing dots are trimmed; a dots-only name yields no alias.
    test "trims leading/trailing dots (interop hardening)" do
      assert Server.derive_alias_localpart("...general...") == {:ok, "general"}
      assert Server.derive_alias_localpart(".hidden") == {:ok, "hidden"}
      assert Server.derive_alias_localpart("trailing.") == {:ok, "trailing"}
    end

    test "all-invalid input returns :none" do
      assert Server.derive_alias_localpart("🎉🎉") == :none
      assert Server.derive_alias_localpart("   ") == :none
      assert Server.derive_alias_localpart("") == :none
    end

    # Punctuation-only / dot-only localparts are interop hazards → no alias.
    test "punctuation-only or dots-only input returns :none" do
      assert Server.derive_alias_localpart("...") == :none
      assert Server.derive_alias_localpart("___") == :none
      assert Server.derive_alias_localpart("===") == :none
      assert Server.derive_alias_localpart(".") == :none
    end
  end
end
