defmodule Nebu.Matrix.EventDispatcher.SetRoomStateTest do
  use ExUnit.Case, async: false

  # ─── Spaces S2 — generic state-event write (set_room_state/2) ─────────────────
  #
  # Story: spaces-elixir / s2-space-state-events.
  #
  # Backend unit tests for the generic Matrix state PUT handler. They drive
  # Server.set_room_state/2 directly, injecting a FakeRoomRegistry (room state +
  # power levels) and a FakeDB (captures emitted events + name writes) so NO live
  # PostgreSQL / Horde is needed.
  #
  # Covers (Acceptance Tests 2,3,4,5,6):
  #   - allowlist: m.space.child/parent + the room-state allowlist accepted;
  #     m.room.member / m.room.power_levels / m.room.create → 403 (SECURITY).
  #   - power-level check: sender PL >= state_default; non-member / under-PL → 403.
  #   - m.space.parent: parent must exist (404) and sender must be a member of it (403).
  #   - m.room.name via generic PUT also persists rooms.name (update_room_name).
  #   - empty content (unlink) is accepted.
  #   - server-authoritative top-level fields (sender/type/room_id) built server-side.
  #
  # async: false — Application.put_env, :pg and :persistent_term are process-global.

  alias Nebu.Matrix.EventDispatcher.Server

  @signing_key_seed :crypto.strong_rand_bytes(32)

  defmodule NoOpAuditWriter do
    def log(_, _, _, _, _, _, _ \\ nil), do: :ok
  end

  # FakeRoomRegistry: get_state/1 returns the room's in-memory state from ETS.
  # Rooms registered via register_room/3 in the tests; unknown rooms raise :noproc
  # (mirrors a not-started Room GenServer so the parent-space "non-existent" path
  # can be exercised through the DB existence check, not the registry).
  defmodule FakeRoomRegistry do
    def get_state(room_id) do
      case :ets.lookup(:set_room_state_reg, {:room, room_id}) do
        [{_, state}] -> state
        [] -> exit({:noproc, {GenServer, :call, [room_id]}})
      end
    end
  end

  # FakeDB: captures insert_event payloads + update_room_name calls, and answers
  # get_room_create_event/1 for parent-space existence checks.
  defmodule FakeDB do
    def insert_event(event) do
      :ets.insert(:set_room_state_db, {{:event, event["event_id"]}, event})
      :ok
    end

    def update_room_name(room_id, name) do
      :ets.insert(:set_room_state_db, {{:room_name, room_id}, name})
      :ok
    end

    # Parent-space existence: a room "exists" iff a create event was registered.
    def get_room_create_event(room_id) do
      case :ets.lookup(:set_room_state_db, {:create, room_id}) do
        [{_, content}] -> {:ok, content}
        [] -> {:error, :not_found}
      end
    end
  end

  setup do
    for tab <- [:set_room_state_reg, :set_room_state_db] do
      if :ets.info(tab) != :undefined, do: :ets.delete(tab)
      :ets.new(tab, [:named_table, :public, :set])
    end

    # Signing key for emit_state_event/5.
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519, @signing_key_seed)
    :persistent_term.put(:nebu_signing_key, {pub, priv})

    Application.put_env(:event_dispatcher, :room_registry_module, FakeRoomRegistry)
    Application.put_env(:event_dispatcher, :messages_db_module, FakeDB)
    Application.put_env(:event_dispatcher, :rooms_db_module, FakeDB)
    Application.put_env(:event_dispatcher, :server_name, "test.local")
    Application.put_env(:compliance, :audit_writer, NoOpAuditWriter)

    case :pg.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    on_exit(fn ->
      Application.delete_env(:event_dispatcher, :room_registry_module)
      Application.delete_env(:event_dispatcher, :messages_db_module)
      Application.delete_env(:event_dispatcher, :rooms_db_module)
      Application.delete_env(:event_dispatcher, :server_name)
      Application.delete_env(:compliance, :audit_writer)

      for tab <- [:set_room_state_reg, :set_room_state_db] do
        if :ets.info(tab) != :undefined, do: :ets.delete(tab)
      end
    end)

    :ok
  end

  # Register a room into the fake registry with the given members + power_levels.
  defp register_room(room_id, members, power_levels) do
    state = %{members: MapSet.new(members), power_levels: power_levels}
    :ets.insert(:set_room_state_reg, {{:room, room_id}, state})
  end

  # Mark a room as existing for the parent-space existence check.
  defp register_create(room_id) do
    :ets.insert(:set_room_state_db, {{:create, room_id}, %{"creator" => "@x:test.local"}})
  end

  defp pl_with(user_levels) do
    Nebu.Matrix.Room.PowerLevels.default_levels()
    |> Map.put("users", user_levels)
  end

  defp stream, do: %{http_request_headers: %{}}

  defp emitted_event(room_id, type, state_key) do
    :ets.match(:set_room_state_db, {{:event, :_}, :"$1"})
    |> Enum.map(fn [ev] -> ev end)
    |> Enum.find(fn ev ->
      ev["room_id"] == room_id and ev["type"] == type and ev["state_key"] == state_key
    end)
  end

  defp req(room_id, sender, type, state_key, content) do
    %Core.SetRoomStateRequest{
      room_id: room_id,
      sender_id: sender,
      event_type: type,
      state_key: state_key,
      content_json: Jason.encode!(content)
    }
  end

  # ─── AC2/AC3 — allowlist accepts m.space.child; event built server-side ──────
  describe "set_room_state/2 — m.space.child (allowlisted)" do
    test "authorized member sets m.space.child → returns event_id; server-built fields" do
      room = "!space:test.local"
      register_room(room, ["@admin:test.local"], pl_with(%{"@admin:test.local" => 100}))

      resp =
        Server.set_room_state(
          req(room, "@admin:test.local", "m.space.child", "!child:test.local", %{
            "via" => ["nebu.local"],
            "suggested" => false
          }),
          stream()
        )

      assert %Core.SetRoomStateResponse{event_id: eid} = resp
      assert is_binary(eid) and eid != ""

      ev = emitted_event(room, "m.space.child", "!child:test.local")
      assert ev != nil, "m.space.child event must be emitted"
      # Server-authoritative top-level fields.
      assert ev["sender"] == "@admin:test.local"
      assert ev["type"] == "m.space.child"
      assert ev["room_id"] == room
      assert is_integer(ev["origin_server_ts"])
      assert ev["content"]["via"] == ["nebu.local"]
    end

    test "empty content (unlink) is accepted → 200 with event_id" do
      room = "!space:test.local"
      register_room(room, ["@admin:test.local"], pl_with(%{"@admin:test.local" => 100}))

      resp =
        Server.set_room_state(
          req(room, "@admin:test.local", "m.space.child", "!child:test.local", %{}),
          stream()
        )

      assert %Core.SetRoomStateResponse{event_id: eid} = resp
      assert eid != ""
      assert emitted_event(room, "m.space.child", "!child:test.local") != nil
    end
  end

  # ─── AC1 — power-level / membership check ────────────────────────────────────
  describe "set_room_state/2 — authorization" do
    test "non-member → permission_denied" do
      room = "!space:test.local"
      register_room(room, ["@admin:test.local"], pl_with(%{"@admin:test.local" => 100}))

      assert_raise Nebu.Matrix.Error, fn ->
        Server.set_room_state(
          req(room, "@stranger:test.local", "m.space.child", "!c:test.local", %{}),
          stream()
        )
      end
    end

    test "member with insufficient PL (< state_default) → permission_denied" do
      room = "!space:test.local"
      # @bob is a member but only has users_default (0) < state_default (50).
      register_room(room, ["@admin:test.local", "@bob:test.local"], pl_with(%{"@admin:test.local" => 100}))

      assert_raise Nebu.Matrix.Error, fn ->
        Server.set_room_state(
          req(room, "@bob:test.local", "m.space.child", "!c:test.local", %{}),
          stream()
        )
      end
    end
  end

  # ─── AC2 — allowlist rejects server-authoritative state types (SECURITY) ─────
  describe "set_room_state/2 — allowlist (security boundary)" do
    for forbidden <- ["m.room.member", "m.room.power_levels", "m.room.create"] do
      test "rejects #{forbidden} → permission_denied even for a PL-100 member" do
        room = "!space:test.local"
        register_room(room, ["@admin:test.local"], pl_with(%{"@admin:test.local" => 100}))

        assert_raise Nebu.Matrix.Error, fn ->
          Server.set_room_state(
            req(room, "@admin:test.local", unquote(forbidden), "", %{"x" => 1}),
            stream()
          )
        end

        # And nothing was emitted.
        assert emitted_event(room, unquote(forbidden), "") == nil
      end
    end

    test "rejects an arbitrary non-allowlisted type → permission_denied" do
      room = "!space:test.local"
      register_room(room, ["@admin:test.local"], pl_with(%{"@admin:test.local" => 100}))

      assert_raise Nebu.Matrix.Error, fn ->
        Server.set_room_state(
          req(room, "@admin:test.local", "com.evil.custom", "", %{}),
          stream()
        )
      end
    end
  end

  # ─── AC4 — m.space.parent requires membership of the (existing) parent space ──
  describe "set_room_state/2 — m.space.parent (security check)" do
    test "sender member of parent space → 200 stored" do
      child = "!child:test.local"
      parent = "!parent:test.local"
      register_room(child, ["@admin:test.local"], pl_with(%{"@admin:test.local" => 100}))
      register_room(parent, ["@admin:test.local"], pl_with(%{"@admin:test.local" => 100}))
      register_create(parent)

      resp =
        Server.set_room_state(
          req(child, "@admin:test.local", "m.space.parent", parent, %{"via" => ["nebu.local"]}),
          stream()
        )

      assert %Core.SetRoomStateResponse{event_id: eid} = resp
      assert eid != ""
      assert emitted_event(child, "m.space.parent", parent) != nil
    end

    test "sender NOT a member of the parent space → permission_denied" do
      child = "!child:test.local"
      parent = "!parent:test.local"
      register_room(child, ["@admin:test.local"], pl_with(%{"@admin:test.local" => 100}))
      # parent exists but @admin is not a member of it.
      register_room(parent, ["@owner:test.local"], pl_with(%{"@owner:test.local" => 100}))
      register_create(parent)

      assert_raise Nebu.Matrix.Error, fn ->
        Server.set_room_state(
          req(child, "@admin:test.local", "m.space.parent", parent, %{}),
          stream()
        )
      end

      assert emitted_event(child, "m.space.parent", parent) == nil
    end

    test "parentSpaceId references a non-existent room → not_found" do
      child = "!child:test.local"
      register_room(child, ["@admin:test.local"], pl_with(%{"@admin:test.local" => 100}))
      # parent NOT registered (no create event, not in registry) → 404.

      assert_raise Nebu.Matrix.Error, fn ->
        Server.set_room_state(
          req(child, "@admin:test.local", "m.space.parent", "!ghost:test.local", %{}),
          stream()
        )
      end
    end
  end

  # ─── AC5 — m.room.name via generic PUT denormalises rooms.name ───────────────
  describe "set_room_state/2 — m.room.name denormalisation" do
    test "writing m.room.name updates rooms.name via update_room_name/2" do
      room = "!room:test.local"
      register_room(room, ["@admin:test.local"], pl_with(%{"@admin:test.local" => 100}))

      resp =
        Server.set_room_state(
          req(room, "@admin:test.local", "m.room.name", "", %{"name" => "Renamed"}),
          stream()
        )

      assert %Core.SetRoomStateResponse{} = resp
      assert :ets.lookup(:set_room_state_db, {:room_name, room}) == [{{:room_name, room}, "Renamed"}]
    end

    test "m.space.child does NOT touch rooms.name" do
      room = "!room:test.local"
      register_room(room, ["@admin:test.local"], pl_with(%{"@admin:test.local" => 100}))

      Server.set_room_state(
        req(room, "@admin:test.local", "m.space.child", "!c:test.local", %{}),
        stream()
      )

      assert :ets.lookup(:set_room_state_db, {:room_name, room}) == []
    end
  end
end
