defmodule Nebu.Admin.AdminMemberManagementTest do
  use ExUnit.Case, async: false

  # ─── Story rm4-admin-member-management ──────────────────────────────────────
  #
  # ATDD — written FIRST (RED before the admin add/remove delegates existed).
  #
  # Verifies the admin-scoped membership write path on the Matrix public API:
  #
  #   Nebu.Matrix.admin_add_room_member/3 / admin_remove_room_member/3
  #     → Nebu.Matrix.EventDispatcher.Server.admin_add_room_member/3 /
  #       admin_remove_room_member/3
  #
  # These wrap the SAME join/leave write path the client flow uses (so an
  # m.room.member join/leave event is emitted and `room_members` is updated),
  # plus a `member_added` / `member_removed` audit row with the acting admin as
  # the actor.
  #
  # Test strategy mirrors audit_room_ops_test.exs / join_room_test.exs:
  #   - FakeDB (ETS) satisfies the Room.DB behaviour — no PostgreSQL.
  #   - FakeAuditWriter spies on log/7 via send to the test pid.
  #   - membership is asserted against the FakeDB ETS table the way the real
  #     join/leave write path updates it (insert_member / delete_member).
  #   - async: false — Horde + Application.put_env + :NebuTxnDedup are global.

  alias Nebu.Matrix.EventDispatcher.Server

  @server "test.local"
  @admin "@admin:test.local"
  @charlie "@charlie:test.local"

  # ─── FakeAuditWriter ─────────────────────────────────────────────────────────

  defmodule FakeAuditWriter do
    def log(actor, action, target_type, target_id, metadata, outcome, error_detail \\ nil) do
      test_pid = Application.get_env(:compliance, :__audit_test_pid__)

      if test_pid && Process.alive?(test_pid) do
        send(test_pid, {:audit_log, actor, action, target_type, target_id, metadata, outcome, error_detail})
      end

      :ok
    end
  end

  # ─── FakeDB (ETS-backed Room.DB) ─────────────────────────────────────────────

  defmodule FakeDB do
    @tab :admin_member_mgmt_test_db

    def load_members(room_id) do
      case :ets.lookup(@tab, {:room, room_id}) do
        [] ->
          {:error, :not_found}

        [{_, created_at_ms}] ->
          members = :ets.match(@tab, {{:member, room_id, :"$1"}, :active})

          pl_json =
            case :ets.lookup(@tab, {:power_levels, room_id}) do
              [{_, json}] -> json
              [] -> "{}"
            end

          {:ok, Enum.map(members, fn [uid] -> uid end), created_at_ms, pl_json}
      end
    end

    def insert_room(room_id) do
      now_ms = System.system_time(:millisecond)
      :ets.insert(@tab, {{:room, room_id}, now_ms})
      {:ok, now_ms}
    end

    def insert_member(room_id, user_id) do
      :ets.insert(@tab, {{:member, room_id, user_id}, :active})
      :ok
    end

    def delete_member(room_id, user_id) do
      :ets.delete(@tab, {:member, room_id, user_id})
      :ok
    end

    def insert_event(event) do
      :ets.insert(@tab, {{:event, event["event_id"]}, event})
      :ok
    end

    def set_power_levels(room_id, power_levels_json) do
      :ets.insert(@tab, {{:power_levels, room_id}, power_levels_json})
      :ok
    end

    def load_room_settings(_room_id), do: {:ok, 0}
    def get_room_status(_room_id), do: {:ok, "active"}
  end

  # ─── FakeInviteDB ────────────────────────────────────────────────────────────

  defmodule FakeInviteDB do
    def accept_invitation(_room_id, _user_id), do: :ok
    def insert_invitation(_room_id, _inviter, _invitee), do: :ok
    def reject_invitation(_room_id, _user_id), do: :ok
    def get_pending_invite_rooms_for_user(_user_id), do: {:ok, []}
  end

  # ─── Setup / Teardown ────────────────────────────────────────────────────────

  setup do
    if :ets.info(:admin_member_mgmt_test_db) != :undefined do
      :ets.delete(:admin_member_mgmt_test_db)
    end

    :ets.new(:admin_member_mgmt_test_db, [:named_table, :public, :set])

    Application.put_env(:room_manager, :db_module, FakeDB)
    Application.put_env(:event_dispatcher, :user_store_module, Nebu.Test.NoOpUserStore)
    Application.put_env(:event_dispatcher, :messages_db_module, FakeDB)
    # FB-E5-03: route the leave path's rooms_db_module() through FakeDB. FakeDB does
    # NOT export auto_join_room?/1, so maybe_record_auto_join_opt_out's
    # function_exported?/3 guard short-circuits — no Nebu.Repo hit.
    Application.put_env(:event_dispatcher, :rooms_db_module, FakeDB)
    Application.put_env(:event_dispatcher, :invite_db_module, FakeInviteDB)
    Application.put_env(:event_dispatcher, :server_name, @server)
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
      Application.delete_env(:event_dispatcher, :invite_db_module)
      Application.delete_env(:event_dispatcher, :server_name)
      Application.delete_env(:compliance, :audit_writer)
      Application.delete_env(:compliance, :__audit_test_pid__)

      if :ets.info(:admin_member_mgmt_test_db) != :undefined do
        :ets.delete(:admin_member_mgmt_test_db)
      end

      if :ets.whereis(:NebuTxnDedup) != :undefined do
        :ets.delete_all_objects(:NebuTxnDedup)
      end
    end)

    :ok
  end

  defp build_stream, do: %{http_request_headers: %{}}

  defp stop_room(room_id) do
    case Nebu.Matrix.Room.RoomSupervisor.lookup_room(room_id) do
      {:ok, pid} -> if Process.alive?(pid), do: GenServer.stop(pid, :normal, 5_000)
      _ -> :ok
    end
  end

  # Creates a real room (m.room.create + creator membership) via the authorized
  # path and drains the room_created audit message from the mailbox.
  defp create_room!(creator) do
    # Empty name: create_room only persists rooms.name (a real-Repo write) when a name
    # is supplied. The membership/audit assertions do not depend on the name, so we skip
    # it to stay PostgreSQL-free (FakeDB pattern, mirroring join_room_test.exs).
    resp = Server.create_room(%Core.CreateRoomRequest{creator_id: creator, name: ""}, build_stream())
    room_id = resp.room_id
    on_exit(fn -> stop_room(room_id) end)

    receive do
      {:audit_log, _, "room_created", _, _, _, _, _} -> :ok
    after
      0 -> :ok
    end

    room_id
  end

  defp member?(room_id, user_id) do
    case :ets.lookup(:admin_member_mgmt_test_db, {:member, room_id, user_id}) do
      [{_, :active}] -> true
      _ -> false
    end
  end

  # ─── AC2/AC7: admin add → member joined + member_added audit ──────────────────

  describe "admin_add_room_member/3" do
    test "adds the target as a member and emits a member_added audit row (admin actor)" do
      room_id = create_room!(@admin)

      assert {:ok, _} = Nebu.Matrix.admin_add_room_member(room_id, @charlie, @admin)

      assert member?(room_id, @charlie),
             "expected @charlie to be a current member after admin add"

      assert_receive {:audit_log, @admin, "member_added", "room", ^room_id, metadata, "success", _},
                     500,
                     "expected a member_added audit row with the admin as actor"

      assert metadata["user_id"] == @charlie
    end

    # AC5 — malformed user id is rejected BEFORE any write (no membership, no audit).
    test "rejects a malformed user id without touching membership or audit" do
      room_id = create_room!(@admin)

      assert {:error, :invalid_user_id} = Nebu.Matrix.admin_add_room_member(room_id, "not-a-user", @admin)

      refute member?(room_id, "not-a-user")
      refute_receive {:audit_log, _, "member_added", _, _, _, _, _}, 200
    end
  end

  # ─── AC4/AC7: admin remove → member left + member_removed audit ───────────────

  describe "admin_remove_room_member/3" do
    test "removes the target member and emits a member_removed audit row (admin actor)" do
      room_id = create_room!(@admin)
      assert {:ok, _} = Nebu.Matrix.admin_add_room_member(room_id, @charlie, @admin)
      assert member?(room_id, @charlie)

      # drain the member_added message
      receive do
        {:audit_log, _, "member_added", _, _, _, _, _} -> :ok
      after
        0 -> :ok
      end

      assert :ok = Nebu.Matrix.admin_remove_room_member(room_id, @charlie, @admin)

      refute member?(room_id, @charlie),
             "expected @charlie to no longer be a current member after admin remove"

      assert_receive {:audit_log, @admin, "member_removed", "room", ^room_id, metadata, "success", _},
                     500,
                     "expected a member_removed audit row with the admin as actor"

      assert metadata["user_id"] == @charlie
    end

    # AC6 — self-removal is rejected server-side; the admin stays joined, no audit.
    test "rejects self-removal: admin stays a member, no member_removed audit" do
      room_id = create_room!(@admin)
      assert member?(room_id, @admin), "creator must be a member to test self-removal"

      assert {:error, :self_removal} = Nebu.Matrix.admin_remove_room_member(room_id, @admin, @admin)

      assert member?(room_id, @admin),
             "admin must remain a member after a rejected self-removal"

      refute_receive {:audit_log, _, "member_removed", _, _, _, _, _}, 200
    end
  end
end
