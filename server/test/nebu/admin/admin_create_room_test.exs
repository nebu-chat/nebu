defmodule Nebu.Admin.AdminCreateRoomTest do
  use ExUnit.Case, async: false

  # ─── Story rm3-admin-create-archive (AC2/AC4) ────────────────────────────────
  #
  # Verifies the admin "Create room" path through the Matrix public API
  # `Nebu.Matrix.create_room/2`:
  #   - the creator becomes the room creator (m.room.create) and first member
  #     (m.room.member join) — AC4
  #   - visibility "public" is persisted (rooms.visibility) via the audited
  #     set_room_visibility path — AC2
  #   - a `room_created` audit row is written with the admin actor — AC4
  #
  # ATDD: written FIRST, expected to FAIL until Nebu.Matrix.create_room/2 exists.
  #
  # async: false — Horde, :pg, Application.put_env, ETS are process-global.
  #
  # Test seams mirror create_room_test.exs / audit_archive_ops_test.exs:
  #   - :room_manager/:db_module + :event_dispatcher/:messages_db_module → FakeDB (no Postgres)
  #   - :event_dispatcher/:admin_db_module → FakeAdminDB (captures update_room_visibility)
  #   - :compliance/:audit_writer → FakeAuditWriter (Process.send spy)

  alias Nebu.Matrix

  # Spy that records every audit log/6 (and log/7) to the test pid.
  defmodule FakeAuditWriter do
    def log(actor, action, target_type, target_id, metadata, outcome, error_detail \\ nil) do
      pid = Application.get_env(:compliance, :__audit_test_pid__)

      if pid && Process.alive?(pid) do
        send(pid, {:audit_log, actor, action, target_type, target_id, metadata, outcome, error_detail})
      end

      :ok
    end
  end

  # ETS-backed Room.DB fake (subset used by create_room/2) — no Postgres.
  defmodule FakeDB do
    def load_members(room_id) do
      case :ets.lookup(:admin_create_room_test_db, {:room, room_id}) do
        [] ->
          {:error, :not_found}

        [{_, created_at_ms}] ->
          members = :ets.match(:admin_create_room_test_db, {{:member, room_id, :"$1"}, :active})

          pl_json =
            case :ets.lookup(:admin_create_room_test_db, {:power_levels, room_id}) do
              [{_, json}] -> json
              [] -> "{}"
            end

          {:ok, Enum.map(members, fn [uid] -> uid end), created_at_ms, pl_json}
      end
    end

    def insert_room(room_id) do
      now_ms = System.system_time(:millisecond)
      :ets.insert(:admin_create_room_test_db, {{:room, room_id}, now_ms})
      {:ok, now_ms}
    end

    def insert_member(room_id, user_id) do
      :ets.insert(:admin_create_room_test_db, {{:member, room_id, user_id}, :active})
      :ok
    end

    def delete_member(room_id, user_id) do
      :ets.delete(:admin_create_room_test_db, {:member, room_id, user_id})
      :ok
    end

    def insert_event(event) do
      :ets.insert(:admin_create_room_test_db, {{:event, event["event_id"]}, event})
      send_to_test({:event_inserted, event["type"], event["state_key"], event["sender"]})
      :ok
    end

    def set_power_levels(room_id, json) do
      :ets.insert(:admin_create_room_test_db, {{:power_levels, room_id}, json})
      :ok
    end

    def update_room_name(room_id, name) do
      :ets.insert(:admin_create_room_test_db, {{:room_name, room_id}, name})
      :ok
    end

    def update_room_type(_room_id, _type), do: :ok

    def load_room_settings(_room_id), do: {:ok, 0}
    def get_room_status(_room_id), do: {:ok, "active"}
    def check_room_status_for_update(_room_id), do: {:ok, "active"}

    defp send_to_test(msg) do
      pid = Application.get_env(:event_dispatcher, :__create_room_test_pid__)
      if pid && Process.alive?(pid), do: send(pid, msg)
      :ok
    end
  end

  # Captures the visibility write driven by set_room_visibility/3 → admin_db.
  defmodule FakeAdminDB do
    def update_room_visibility(room_id, visibility) do
      :ets.insert(:admin_create_room_test_db, {{:visibility, room_id}, visibility})
      pid = Application.get_env(:event_dispatcher, :__create_room_test_pid__)
      if pid && Process.alive?(pid), do: send(pid, {:visibility_written, room_id, visibility})
      :ok
    end
  end

  setup do
    if :ets.info(:admin_create_room_test_db) != :undefined do
      :ets.delete(:admin_create_room_test_db)
    end

    :ets.new(:admin_create_room_test_db, [:named_table, :public, :set])

    Application.put_env(:room_manager, :db_module, FakeDB)
    Application.put_env(:event_dispatcher, :user_store_module, Nebu.Test.NoOpUserStore)
    Application.put_env(:event_dispatcher, :messages_db_module, FakeDB)
    Application.put_env(:event_dispatcher, :rooms_db_module, FakeDB)
    Application.put_env(:event_dispatcher, :admin_db_module, FakeAdminDB)
    Application.put_env(:event_dispatcher, :server_name, "test.local")
    Application.put_env(:event_dispatcher, :__create_room_test_pid__, self())
    Application.put_env(:compliance, :audit_writer, FakeAuditWriter)
    Application.put_env(:compliance, :__audit_test_pid__, self())

    case :pg.start_link() do
      {:ok, _} -> :ok
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
      Application.delete_env(:event_dispatcher, :admin_db_module)
      Application.delete_env(:event_dispatcher, :server_name)
      Application.delete_env(:event_dispatcher, :__create_room_test_pid__)
      Application.delete_env(:compliance, :audit_writer)
      Application.delete_env(:compliance, :__audit_test_pid__)

      if :ets.info(:admin_create_room_test_db) != :undefined do
        :ets.delete(:admin_create_room_test_db)
      end

      if :ets.whereis(:NebuTxnDedup) != :undefined do
        :ets.delete_all_objects(:NebuTxnDedup)
      end
    end)

    :ok
  end

  defp stop_room(room_id) do
    case Nebu.Matrix.Room.RoomSupervisor.lookup_room(room_id) do
      {:ok, pid} ->
        if Process.alive?(pid),
          do: Horde.DynamicSupervisor.terminate_child(Nebu.Matrix.Room.HordeSupervisor, pid)

      _ ->
        :ok
    end
  end

  describe "Nebu.Matrix.create_room/2 — admin create path (AC2/AC4)" do
    test "creates a public room: create + member-join events, visibility, audit row" do
      admin = "@admin:test.local"

      assert {:ok, room_id} = Matrix.create_room(admin, name: "General", visibility: "public")
      on_exit(fn -> stop_room(room_id) end)

      assert is_binary(room_id) and room_id != ""

      # AC4 — the admin is the creator (m.room.create) and first member (m.room.member join).
      assert_receive {:event_inserted, "m.room.create", "", ^admin}, 500
      state = Nebu.Matrix.Room.Server.get_state(room_id)
      assert MapSet.member?(state.members, admin)

      # AC2 — visibility "public" persisted via the audited set_room_visibility path.
      assert_receive {:visibility_written, ^room_id, "public"}, 500

      # AC4 — a room_created audit row with the admin actor.
      assert_receive {:audit_log, ^admin, "room_created", "room", ^room_id, _meta, "success", _}, 500
    end

    test "private (default) does not write visibility but still creates + audits" do
      admin = "@admin:test.local"

      assert {:ok, room_id} = Matrix.create_room(admin, name: "Secret")
      on_exit(fn -> stop_room(room_id) end)

      assert_receive {:event_inserted, "m.room.create", "", ^admin}, 500
      assert_receive {:audit_log, ^admin, "room_created", "room", ^room_id, _meta, "success", _}, 500

      # private is the default — no visibility flip.
      refute_received {:visibility_written, _, _}
    end

    test "an invalid visibility is rejected before any room is created (default-deny)" do
      assert {:error, :invalid_visibility} =
               Matrix.create_room("@admin:test.local", name: "Nope", visibility: "bogus")

      refute_received {:event_inserted, "m.room.create", _, _}
      refute_received {:audit_log, _, "room_created", _, _, _, _, _}
    end
  end
end
