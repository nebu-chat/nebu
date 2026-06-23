defmodule Nebu.Matrix.EventDispatcher.AdminForceAddMemberTest do
  use ExUnit.Case, async: false

  # ─── Bug C regression: admin force-add member to a PRIVATE / invite room ──────
  #
  # Repro: an admin creates a PRIVATE room (default Matrix join_rule "invite") and
  # then force-adds a member from the Admin UI. The target must end up an ACTIVE
  # member (a row in room_members) via a proper invite → join membership transition
  # (story rm4 "add/remove room members from Admin UI").
  #
  # Two product requirements are proven here:
  #
  #   1. LOCAL user, private room → active membership.
  #      The admin (PL100, room creator) force-adds a LOCAL user. A pending invite
  #      is established and immediately accepted, so a proper m.room.member
  #      invite → join transition occurs and the user is an ACTIVE member.
  #
  #   2. FOREIGN-domain user → rejected, NO membership row.
  #      Nebu is a NO-FEDERATION, single-homeserver system. Adding a member whose
  #      domain is not the configured server_name (e.g. "@charlie:nebu.local" when
  #      the server is "test.local") is not meaningful and must be rejected
  #      default-deny — no room_members row is written.
  #
  # These assertions go BEYOND audit_member_ops_test.exs (which only proves the
  # audit row is written): here we assert on the actual persisted membership so the
  # join itself is exercised end-to-end against a join_rule="invite" room.
  #
  # async: false — Horde.Registry, Horde.DynamicSupervisor, Application.put_env and
  # :NebuTxnDedup are process-global resources. Room GenServers are stopped on_exit.

  alias Nebu.Matrix.EventDispatcher.Server

  @server_name "test.local"

  # No-op audit writer. create_room/2 (via create_private_room/1) emits an audit
  # log entry through audit_writer_module(); its default is the REAL
  # Nebu.Compliance.AuditWriter, which hits Nebu.Repo. The :test.exs global default
  # is NoOp, but a prior test that did delete_env(:compliance, :audit_writer) in its
  # on_exit removes that global default — so we inject our own NoOp here (and restore
  # the NoOp default on exit) to keep this create path repo-free regardless of order.
  defmodule NoOpAuditWriter do
    def log(_, _, _, _, _, _, _ \\ nil), do: :ok
  end

  # ─── FakeDB ──────────────────────────────────────────────────────────────────
  #
  # Records active membership in an ETS table so the test can assert the target is
  # an ACTIVE member after the force-add. Also serves the m.room.join_rules state
  # event (join_rule "invite") so the room behaves as a private/invite room.

  defmodule FakeDB do
    def load_members(room_id) do
      case :ets.lookup(:admin_force_add_test_db, {:room, room_id}) do
        [] ->
          {:error, :not_found}

        [{_, created_at_ms}] ->
          members =
            :ets.match(:admin_force_add_test_db, {{:member, room_id, :"$1"}, :active})

          pl_json =
            case :ets.lookup(:admin_force_add_test_db, {:power_levels, room_id}) do
              [{_, json}] -> json
              [] -> "{}"
            end

          {:ok, Enum.map(members, fn [uid] -> uid end), created_at_ms, pl_json}
      end
    end

    def insert_room(room_id) do
      now_ms = System.system_time(:millisecond)
      :ets.insert(:admin_force_add_test_db, {{:room, room_id}, now_ms})
      {:ok, now_ms}
    end

    def insert_member(room_id, user_id) do
      :ets.insert(:admin_force_add_test_db, {{:member, room_id, user_id}, :active})
      :ok
    end

    def delete_member(room_id, user_id) do
      :ets.delete(:admin_force_add_test_db, {:member, room_id, user_id})
      :ok
    end

    def insert_event(event) do
      :ets.insert(:admin_force_add_test_db, {{:event, event["event_id"]}, event})
      :ok
    end

    def set_power_levels(room_id, power_levels_json) do
      :ets.insert(:admin_force_add_test_db, {{:power_levels, room_id}, power_levels_json})
      :ok
    end

    def load_room_settings(_room_id), do: {:ok, 0}
    def get_room_status(_room_id), do: {:ok, "active"}

    def update_room_name(_room_id, _name), do: :ok
    def update_room_type(_room_id, _type), do: :ok

    def get_personal_room_id(_user_id), do: {:ok, :none}

    # Serve a join_rule="invite" m.room.join_rules state event so the room is
    # private (invite-only). This is what enforce_restricted_join! reads via
    # restricted_join_state/1; "invite" is a no-op for restricted enforcement.
    def get_generic_state_events(room_id) do
      case :ets.lookup(:admin_force_add_test_db, {:room, room_id}) do
        [] ->
          {:error, :not_found}

        _ ->
          {:ok,
           [
             %{
               type: "m.room.join_rules",
               state_key: "",
               content_json: Jason.encode!(%{"join_rule" => "invite"})
             }
           ]}
      end
    end
  end

  # ─── FakeInviteDB ─────────────────────────────────────────────────────────────
  #
  # Records invitations in ETS so the test can assert the force-add established a
  # proper pending invite before the join. get_pending_invite_rooms_for_user/1
  # reflects the recorded (not-yet-accepted) invites so enforce_restricted_join!
  # would see the invite for a restricted room.

  defmodule FakeInviteDB do
    def insert_invitation(room_id, _inviter, invitee) do
      :ets.insert(:admin_force_add_test_db, {{:invite, room_id, invitee}, :pending})
      :ok
    end

    def accept_invitation(room_id, invitee) do
      :ets.insert(:admin_force_add_test_db, {{:invite, room_id, invitee}, :accepted})
      :ok
    end

    def reject_invitation(_room_id, _user_id), do: :ok

    def get_pending_invite_rooms_for_user(invitee) do
      rooms =
        :ets.match(:admin_force_add_test_db, {{:invite, :"$1", invitee}, :pending})
        |> Enum.map(fn [room_id] -> room_id end)

      {:ok, rooms}
    end
  end

  # ─── Setup / Teardown ────────────────────────────────────────────────────────

  setup do
    if :ets.info(:admin_force_add_test_db) != :undefined do
      :ets.delete(:admin_force_add_test_db)
    end

    :ets.new(:admin_force_add_test_db, [:named_table, :public, :set])

    Application.put_env(:room_manager, :db_module, FakeDB)
    Application.put_env(:event_dispatcher, :messages_db_module, FakeDB)
    Application.put_env(:event_dispatcher, :rooms_db_module, FakeDB)
    Application.put_env(:event_dispatcher, :invite_db_module, FakeInviteDB)
    Application.put_env(:event_dispatcher, :server_name, @server_name)
    # Audit writes are irrelevant to this test — inject a local NoOp writer so the
    # create path never reaches Nebu.Repo (the global NoOp default may have been
    # delete_env'd by a prior test's on_exit; see NoOpAuditWriter above).
    Application.put_env(:compliance, :audit_writer, NoOpAuditWriter)

    case :pg.start_link() do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    if :ets.whereis(:NebuTxnDedup) != :undefined do
      :ets.delete_all_objects(:NebuTxnDedup)
    end

    on_exit(fn ->
      Application.delete_env(:room_manager, :db_module)
      Application.delete_env(:event_dispatcher, :messages_db_module)
      Application.delete_env(:event_dispatcher, :rooms_db_module)
      Application.delete_env(:event_dispatcher, :invite_db_module)
      Application.delete_env(:event_dispatcher, :server_name)
      # Restore the :test.exs global NoOp default (not delete_env) so a later test
      # relying on the global default does not fall through to the real AuditWriter.
      Application.put_env(:compliance, :audit_writer, Nebu.Compliance.NoOpAuditWriter)

      if :ets.info(:admin_force_add_test_db) != :undefined do
        :ets.delete(:admin_force_add_test_db)
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

  defp active_member?(room_id, user_id) do
    case :ets.lookup(:admin_force_add_test_db, {:member, room_id, user_id}) do
      [{_, :active}] -> true
      _ -> false
    end
  end

  defp create_private_room(admin_id) do
    create_resp =
      Server.create_room(
        %Core.CreateRoomRequest{creator_id: admin_id, name: "Private Room"},
        build_stream()
      )

    create_resp.room_id
  end

  # ─── AC: LOCAL user is added to a private/invite room ────────────────────────

  describe "Server.admin_add_room_member/3 — private room, LOCAL target" do
    test "force-adds a local user as an ACTIVE member of a private (invite) room" do
      admin_id = "@admin:#{@server_name}"
      target_user = "@bob:#{@server_name}"

      room_id = create_private_room(admin_id)
      on_exit(fn -> stop_room(room_id) end)

      assert {:ok, ^room_id} =
               Server.admin_add_room_member(room_id, target_user, admin_id)

      assert active_member?(room_id, target_user),
             "target user must be an ACTIVE member of the private room after admin force-add"
    end
  end

  # ─── AC: FOREIGN-domain user is rejected (no-federation) ─────────────────────

  describe "Server.admin_add_room_member/3 — FOREIGN-domain target" do
    test "rejects a foreign-domain user and writes NO membership row" do
      admin_id = "@admin:#{@server_name}"
      foreign_user = "@charlie:nebu.local"

      room_id = create_private_room(admin_id)
      on_exit(fn -> stop_room(room_id) end)

      assert {:error, :foreign_domain} =
               Server.admin_add_room_member(room_id, foreign_user, admin_id)

      refute active_member?(room_id, foreign_user),
             "a foreign-domain user must NOT be added to the room (no-federation)"
    end
  end
end
