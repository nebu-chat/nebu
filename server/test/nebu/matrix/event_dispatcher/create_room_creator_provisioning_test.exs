defmodule Nebu.Matrix.EventDispatcher.CreateRoomCreatorProvisioningTest do
  use ExUnit.Case, async: false

  # ─── Story: admin-room-creator-provisioning ──────────────────────────────────
  #
  # Bug: when an instance admin (whose Matrix id has no `users` row) creates a room
  # via the Admin UI, the creator-join violates FK room_members_user_id_fkey and
  # raises, leaving an orphan room (blank name, 0 members → "stale").
  #
  # These tests are written FIRST (ATDD gate) and FAIL until the fix lands.
  #
  # Strategy mirrors create_room_test.exs:
  #   - call EventDispatcher.Server.create_room/2 directly (synchronous unary).
  #   - inject FakeDB for room_manager + messages/rooms DB seams (no Repo).
  #   - inject a FakeUserStore for the NEW user_store_module() seam so we can assert
  #     the creator-provisioning upsert (idempotent, role "user") happens before the
  #     creator-join — without a live Repo.
  #   - AC3: a FailingMemberDB makes the creator-join fail AFTER m.room.create; assert
  #     the orphan room is cleaned up (delete_room/1 called) and a clean error surfaces.
  #
  # NOTE (test scope): these tests use injected DB seams (FakeDB / FailingMemberDB), so
  # there is no live foreign key here. The actual room_members_user_id_fkey failure path
  # — the real FK violation an unprovisioned creator triggers — is exercised end-to-end by
  # the Playwright E2E scenario (e2e/features/admin/create_room.feature), not by this file.
  #
  # async: false — Horde, :pg, Application.put_env and :NebuTxnDedup are process-global.

  alias Nebu.Matrix.EventDispatcher.Server

  @ets :create_room_provisioning_test_db

  # ─── FakeUserStore — records upsert_user/2 calls in ETS ──────────────────────
  #
  # Satisfies the Nebu.Matrix.Session.UserStore behaviour shape (upsert_user/2).
  # Records every call so tests can assert the creator is provisioned with role
  # "user" exactly once. Simulates idempotency: a pre-seeded {:user_role, id} entry
  # is preserved (never downgraded) — the upsert never overwrites an existing role.
  defmodule FakeUserStore do
    @ets :create_room_provisioning_test_db

    def upsert_user(user_id, system_role) do
      # record the call (append)
      calls = :ets.lookup(@ets, :upsert_calls) |> Enum.flat_map(fn {_, c} -> c end)
      :ets.insert(@ets, {:upsert_calls, calls ++ [{user_id, system_role}]})

      # idempotent role behaviour: only set role if not already present (never downgrade)
      case :ets.lookup(@ets, {:user_role, user_id}) do
        [] -> :ets.insert(@ets, {{:user_role, user_id}, system_role})
        _existing -> :ok
      end

      {:ok, user_id}
    end
  end

  # ─── FakeDB — ETS-backed Room DB (no Repo) ───────────────────────────────────
  defmodule FakeDB do
    @ets :create_room_provisioning_test_db

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

    # NEW seam used for orphan cleanup (AC3). Deletes the room + its members/events.
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

  # ─── FailingMemberDB — like FakeDB but insert_member fails (AC3) ─────────────
  #
  # Simulates the production FK violation: insert_member returns {:error, _} AFTER
  # m.room.create has already been written. Room.Server.join/2 then returns the
  # error and create_room must clean up the orphan room. delegates everything else
  # to FakeDB.
  defmodule FailingMemberDB do
    defdelegate load_members(room_id), to: FakeDB
    defdelegate insert_room(room_id), to: FakeDB
    defdelegate delete_member(room_id, user_id), to: FakeDB
    defdelegate insert_event(event), to: FakeDB
    defdelegate set_power_levels(room_id, pl), to: FakeDB
    defdelegate update_room_name(room_id, name), to: FakeDB
    defdelegate update_room_type(room_id, t), to: FakeDB
    defdelegate delete_room(room_id), to: FakeDB
    defdelegate load_room_settings(room_id), to: FakeDB
    defdelegate get_room_status(room_id), to: FakeDB
    defdelegate check_room_status_for_update(room_id), to: FakeDB

    def insert_member(_room_id, _user_id),
      do: {:error, %{__struct__: Postgrex.Error, message: "FK violation (simulated)"}}
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
    Application.put_env(:event_dispatcher, :user_store_module, FakeUserStore)
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
      Application.delete_env(:event_dispatcher, :messages_db_module)
      Application.delete_env(:event_dispatcher, :rooms_db_module)
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

  defp upsert_calls do
    :ets.lookup(@ets, :upsert_calls) |> Enum.flat_map(fn {_, c} -> c end)
  end

  # ─── AC1: unregistered creator is provisioned, room created fully ────────────

  describe "create_room provisions an unregistered creator (AC1)" do
    test "returns {:ok, room_id}, provisions creator with role \"user\", room is named, creator is member" do
      creator_id = "@kai:test.local"

      request = %Core.CreateRoomRequest{
        creator_id: creator_id,
        name: "general",
        is_direct: false
      }

      response = Server.create_room(request, build_stream())
      track_room(response.room_id)
      room_id = response.room_id

      assert is_binary(room_id) and room_id != ""

      # Creator provisioned exactly once, with the normal "user" role (NEVER instance_admin).
      calls = upsert_calls()
      assert {creator_id, "user"} in calls,
             "expected creator provisioned with role \"user\", got: #{inspect(calls)}"

      refute Enum.any?(calls, fn {_id, role} -> role == "instance_admin" end),
             "creator-provisioning must NEVER grant instance_admin"

      # rooms.name persisted = "general"
      assert [{_, "general"}] = :ets.lookup(@ets, {:room_name, room_id})

      # creator is an active member
      state = Nebu.Matrix.Room.Server.get_state(room_id)
      assert MapSet.member?(state.members, creator_id)

      # m.room.name event written
      name_events =
        :ets.match(@ets, {{:event, :_}, :"$1"})
        |> Enum.map(fn [e] -> e end)
        |> Enum.filter(&(&1["type"] == "m.room.name" and &1["room_id"] == room_id))

      assert length(name_events) == 1, "expected exactly one m.room.name event for #{room_id}"
      assert hd(name_events)["content"]["name"] == "general"

      # creator m.room.member join event written
      member_join =
        :ets.match(@ets, {{:event, :_}, :"$1"})
        |> Enum.map(fn [e] -> e end)
        |> Enum.filter(fn e ->
          e["type"] == "m.room.member" and e["room_id"] == room_id and
            e["state_key"] == creator_id and e["content"]["membership"] == "join"
        end)

      assert length(member_join) >= 1, "expected a creator m.room.member join event"
    end

    test "provisioning happens BEFORE the creator-join (creator ends up a member)" do
      # If provisioning ran after the join (or not at all), the real FK would block
      # the join. With the seam we assert ordering indirectly: creator is a member
      # AND was provisioned.
      creator_id = "@unregistered:test.local"
      request = %Core.CreateRoomRequest{creator_id: creator_id, name: "ops"}

      response = Server.create_room(request, build_stream())
      track_room(response.room_id)

      assert {creator_id, "user"} in upsert_calls()
      state = Nebu.Matrix.Room.Server.get_state(response.room_id)
      assert MapSet.member?(state.members, creator_id)
    end
  end

  # ─── AC2: idempotent for an already-registered creator ───────────────────────

  describe "create_room is idempotent for an already-registered creator (AC2)" do
    test "existing users row is not duplicated and its role is not downgraded" do
      creator_id = "@alex:test.local"
      # Pre-seed an existing role (e.g. an instance_admin who already has a row).
      :ets.insert(@ets, {{:user_role, creator_id}, "instance_admin"})

      request = %Core.CreateRoomRequest{creator_id: creator_id, name: "general"}
      response = Server.create_room(request, build_stream())
      track_room(response.room_id)

      # upsert was called with "user" (idempotent ON CONFLICT semantics), but the
      # pre-existing role must be preserved — FakeUserStore models ON CONFLICT not
      # overwriting the role.
      assert {creator_id, "user"} in upsert_calls()

      assert [{_, "instance_admin"}] = :ets.lookup(@ets, {:user_role, creator_id}),
             "existing role must NOT be downgraded by the creator-provisioning upsert"

      # only a single role row exists for this id (no duplication)
      role_rows = :ets.match(@ets, {{:user_role, creator_id}, :"$1"})
      assert length(role_rows) == 1
    end
  end

  # ─── AC3: no orphan room when a post-create step fails ───────────────────────

  describe "create_room leaves no orphan room when a post-create step fails (AC3)" do
    setup do
      # Swap in the DB whose insert_member fails AFTER m.room.create is written.
      Application.put_env(:room_manager, :db_module, FailingMemberDB)
      Application.put_env(:event_dispatcher, :messages_db_module, FailingMemberDB)
      Application.put_env(:event_dispatcher, :rooms_db_module, FailingMemberDB)
      :ok
    end

    test "the just-created room is cleaned up and a clean error is raised (not an uncaught Postgrex crash)" do
      creator_id = "@kai:test.local"
      request = %Core.CreateRoomRequest{creator_id: creator_id, name: "general"}

      # create_room must surface a clean Nebu.Matrix.Error (mapped to a Matrix
      # error envelope by the HTTP layer), NOT crash with MatchError / Postgrex.Error.
      assert_raise Nebu.Matrix.Error, fn ->
        Server.create_room(request, build_stream())
      end

      # No orphan room left: delete_room/1 was invoked for the room that failed.
      deleted = :ets.match(@ets, {{:deleted_room, :"$1"}, true}) |> Enum.map(fn [r] -> r end)
      assert deleted != [], "expected the orphan room to be cleaned up via delete_room/1"

      # And the rooms entry is gone (Admin UI list query would return nothing).
      rooms_left = :ets.match(@ets, {{:room, :"$1"}, :_}) |> Enum.map(fn [r] -> r end)
      assert rooms_left == [], "no rooms row may remain after a failed create"
    end
  end
end
