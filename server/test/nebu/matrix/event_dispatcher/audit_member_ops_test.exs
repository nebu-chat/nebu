defmodule Nebu.Matrix.EventDispatcher.AuditMemberOpsTest do
  use ExUnit.Case, async: false

  # ─── Bug regression (merge room-management-elixir → full-elixir-stack) ───────
  #
  # admin_add_room_member/3 emits audit action "member_added" and
  # admin_remove_room_member/3 emits "member_removed", but the
  # Nebu.Compliance.AuditWriter @known_actions allowlist did NOT include those
  # actions. As a result the REAL AuditWriter rejects the write with
  # {:error, :audit_unknown_action} and no audit_log row is persisted — a broken
  # audit trail for admin-initiated membership changes.
  #
  # Unlike audit_room_ops_test.exs (which injects a FakeAuditWriter spy and only
  # proves log/6 is CALLED), this regression test exercises the REAL
  # Nebu.Compliance.AuditWriter so the allowlist rejection actually manifests.
  # We inject a FakeRepo so the AuditWriter's persisted rows are observable, then
  # assert exactly one row with the expected action/actor/target is written.
  #
  # These tests FAIL against the current code (allowlist lacks both actions →
  # AuditWriter returns {:error, :audit_unknown_action}, inserts nothing) and pass
  # once "member_added"/"member_removed" are added to @known_actions.
  #
  # async: false — Horde.Registry, Horde.DynamicSupervisor, Application.put_env and
  # :NebuTxnDedup are process-global resources. Room GenServers are stopped on_exit.

  alias Nebu.Matrix.EventDispatcher.Server

  # ─── FakeRepo (mirrors audit_writer_test.exs) ────────────────────────────────
  #
  # Records every audit row the REAL Nebu.Compliance.AuditWriter inserts.

  defmodule FakeRepo do
    @moduledoc "In-process fake for Nebu.Repo. Test-private."

    def transaction(fun) when is_function(fun, 0) do
      result = fun.()
      {:ok, result}
    end

    def insert(struct, _opts \\ []) do
      bucket = Application.get_env(:compliance, :__test_fake_repo_bucket__)
      if bucket, do: Agent.update(bucket, fn rows -> [struct | rows] end)
      {:ok, struct}
    end

    def insert!(struct, opts \\ []) do
      {:ok, s} = insert(struct, opts)
      s
    end
  end

  # ─── FakeDB (mirrors audit_room_ops_test.exs) ────────────────────────────────

  defmodule FakeDB do
    def load_members(room_id) do
      case :ets.lookup(:audit_member_ops_test_db, {:room, room_id}) do
        [] ->
          {:error, :not_found}

        [{_, created_at_ms}] ->
          members =
            :ets.match(:audit_member_ops_test_db, {{:member, room_id, :"$1"}, :active})

          pl_json =
            case :ets.lookup(:audit_member_ops_test_db, {:power_levels, room_id}) do
              [{_, json}] -> json
              [] -> "{}"
            end

          {:ok, Enum.map(members, fn [uid] -> uid end), created_at_ms, pl_json}
      end
    end

    def insert_room(room_id) do
      now_ms = System.system_time(:millisecond)
      :ets.insert(:audit_member_ops_test_db, {{:room, room_id}, now_ms})
      {:ok, now_ms}
    end

    def insert_member(room_id, user_id) do
      :ets.insert(:audit_member_ops_test_db, {{:member, room_id, user_id}, :active})
      :ok
    end

    def delete_member(room_id, user_id) do
      :ets.delete(:audit_member_ops_test_db, {:member, room_id, user_id})
      :ok
    end

    def insert_event(event) do
      :ets.insert(:audit_member_ops_test_db, {{:event, event["event_id"]}, event})
      :ok
    end

    # story power-levels-enforcement (D10): the room process writes a power-level change through ONE call; the fake models the
    # transaction with its own column write AND event insert (a failure of either is the change's failure)
    def apply_power_levels_change(room_id, json, event) do
      with :ok <- set_power_levels(room_id, json), do: insert_event(event)
    end

    def set_power_levels(room_id, power_levels_json) do
      :ets.insert(:audit_member_ops_test_db, {{:power_levels, room_id}, power_levels_json})
      :ok
    end

    def load_room_settings(_room_id), do: {:ok, 0}

    def get_room_status(_room_id), do: {:ok, "active"}

    # rooms_db_module() denormalisation writes — no-ops for unit tests (no live Repo).
    def update_room_name(_room_id, _name), do: :ok
    def update_room_type(_room_id, _type), do: :ok

    # admin_remove_room_member → leave_room consults get_personal_room_id/1 for the
    # personal-room leave guard. Return :none so the guard never blocks the test.
    def get_personal_room_id(_user_id), do: {:ok, :none}

    # Story create-room-presets-power-levels-topic (AC16, DATA adaptation of the fake): join_room/2 decides on the join rule and the latest
    # membership of the user (D1) and reads both through the injected modules. This suite is about the AUDIT rows, not about who may join:
    # the fake serves the join rule of a private room (`invite`, what createRoom's default preset writes) and "never a member before".
    # Nobody gets in without the invitation that admin_add_room_member/3 establishes first (the FakeInviteDB below remembers it).
    def get_generic_state_events(_room_id) do
      {:ok, [%{type: "m.room.join_rules", state_key: "", content_json: ~s({"join_rule":"invite"}), sender: "@admin:test.local", event_id: "$jr:test.local", origin_server_ts: 1}]}
    end

    def get_member_membership(_room_id, _user_id), do: {:ok, nil}
    # story sync-membership-partition (D13, DATA adaptation): the join decision also reads the latest member event (never a member event here)
    def latest_member_event(_room_id, _user_id), do: {:ok, nil}
  end

  # ─── FakeInviteDB (mirrors audit_room_ops_test.exs) ──────────────────────────

  defmodule FakeInviteDB do
    # Story create-room-presets-power-levels-topic (AC16, DATA adaptation of the fake): the invitation the force-add establishes must be
    # PENDING for the join that follows (invite-only rooms, D1), and accepted by it.
    def insert_invitation(room_id, _inviter, invitee), do: (:ets.insert(:audit_member_ops_test_db, {{:invite, room_id, invitee}, :pending}); :ok)
    def accept_invitation(room_id, invitee), do: (:ets.insert(:audit_member_ops_test_db, {{:invite, room_id, invitee}, :accepted}); :ok)
    def reject_invitation(room_id, invitee), do: (:ets.insert(:audit_member_ops_test_db, {{:invite, room_id, invitee}, :rejected}); :ok)

    def get_pending_invite_rooms_for_user(invitee) do
      {:ok, :ets.match(:audit_member_ops_test_db, {{:invite, :"$1", invitee}, :pending}) |> List.flatten()}
    end

    # story sync-membership-partition (D13, DATA adaptation): the pending row WITH invited_at (this suite has no member events)
    def pending_invitation(room_id, invitee) do
      case :ets.lookup(:audit_member_ops_test_db, {:invite, room_id, invitee}) do
        [{_, :pending}] -> {:ok, 1}
        _ -> {:ok, nil}
      end
    end
  end

  # ─── Setup / Teardown ────────────────────────────────────────────────────────

  setup do
    if :ets.info(:audit_member_ops_test_db) != :undefined do
      :ets.delete(:audit_member_ops_test_db)
    end

    :ets.new(:audit_member_ops_test_db, [:named_table, :public, :set])

    {:ok, bucket} = Agent.start_link(fn -> [] end)

    Application.put_env(:room_manager, :db_module, FakeDB)
    Application.put_env(:event_dispatcher, :user_store_module, Nebu.Test.NoOpUserStore)
    Application.put_env(:event_dispatcher, :messages_db_module, FakeDB)
    Application.put_env(:event_dispatcher, :rooms_db_module, FakeDB)
    Application.put_env(:event_dispatcher, :invite_db_module, FakeInviteDB)
    Application.put_env(:event_dispatcher, :server_name, "test.local")

    # Use the REAL Nebu.Compliance.AuditWriter so the @known_actions allowlist
    # rejection actually manifests. config/test.exs globally wires
    # :compliance, :audit_writer → NoOpAuditWriter (which writes nothing), so we
    # MUST override it here, otherwise the FakeRepo never sees any row and the
    # test would pass vacuously regardless of the allowlist.
    Application.put_env(:compliance, :audit_writer, Nebu.Compliance.AuditWriter)
    # Point the real AuditWriter's repo at the FakeRepo so persisted rows are observable.
    Application.put_env(:compliance, :repo, FakeRepo)
    Application.put_env(:compliance, :__test_fake_repo_bucket__, bucket)

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
      Application.delete_env(:compliance, :repo)
      Application.delete_env(:compliance, :__test_fake_repo_bucket__)

      if :ets.info(:audit_member_ops_test_db) != :undefined do
        :ets.delete(:audit_member_ops_test_db)
      end

      if :ets.whereis(:NebuTxnDedup) != :undefined do
        :ets.delete_all_objects(:NebuTxnDedup)
      end
    end)

    {:ok, bucket: bucket}
  end

  defp build_stream, do: %{http_request_headers: %{}}

  defp stop_room(room_id) do
    case Nebu.Matrix.Room.RoomSupervisor.lookup_room(room_id) do
      {:ok, pid} -> if Process.alive?(pid), do: (try do GenServer.stop(pid, :normal, 5_000) catch :exit, _ -> :ok end)
      _ -> :ok
    end
  end

  defp audit_rows(bucket), do: Agent.get(bucket, & &1)

  # ─── AC3: admin_add_room_member persists a "member_added" audit row ──────────

  describe "Server.admin_add_room_member/3 — audit row persisted via real AuditWriter" do
    test "writes one audit_log row action=member_added, actor=admin, target=room", %{
      bucket: bucket
    } do
      admin_id = "@admin:test.local"
      target_user = "@bob:test.local"

      create_resp =
        Server.create_room(
          %Core.CreateRoomRequest{creator_id: admin_id, name: "Member Audit Room"},
          build_stream()
        )

      room_id = create_resp.room_id
      on_exit(fn -> stop_room(room_id) end)

      # Clear the room_created audit row written during create_room.
      Agent.update(bucket, fn _ -> [] end)

      assert {:ok, ^room_id} =
               Server.admin_add_room_member(room_id, target_user, admin_id)

      # admin_add_room_member wraps the authorized join path, which legitimately
      # also emits a "room_joined" audit row. Assert on the member_added row
      # specifically rather than the total count.
      member_rows = Enum.filter(audit_rows(bucket), &(&1.action == "member_added"))

      assert length(member_rows) == 1,
             ~s|expected exactly one "member_added" audit_log row after admin_add_room_member, got #{length(member_rows)} | <>
               "(the AuditWriter @known_actions allowlist must include \"member_added\")"

      [row] = member_rows
      assert row.action == "member_added", "got action=#{inspect(row.action)}"
      assert row.actor_user_id == admin_id, "actor must be the admin, got #{inspect(row.actor_user_id)}"
      assert row.target_id == room_id, "target must be the room, got #{inspect(row.target_id)}"
    end
  end

  # ─── AC3: admin_remove_room_member persists a "member_removed" audit row ─────

  describe "Server.admin_remove_room_member/3 — audit row persisted via real AuditWriter" do
    test "writes one audit_log row action=member_removed, actor=admin, target=room", %{
      bucket: bucket
    } do
      admin_id = "@admin:test.local"
      target_user = "@bob:test.local"

      create_resp =
        Server.create_room(
          %Core.CreateRoomRequest{creator_id: admin_id, name: "Member Remove Room"},
          build_stream()
        )

      room_id = create_resp.room_id
      on_exit(fn -> stop_room(room_id) end)

      # Add the target so there is a membership to remove.
      assert {:ok, ^room_id} =
               Server.admin_add_room_member(room_id, target_user, admin_id)

      # Clear room_created + member_added audit rows; we only assert on the removal.
      Agent.update(bucket, fn _ -> [] end)

      assert :ok = Server.admin_remove_room_member(room_id, target_user, admin_id)

      # Assert on the member_removed row specifically (the leave path may emit
      # additional audit rows in future without invalidating this regression).
      member_rows = Enum.filter(audit_rows(bucket), &(&1.action == "member_removed"))

      assert length(member_rows) == 1,
             ~s|expected exactly one "member_removed" audit_log row after admin_remove_room_member, got #{length(member_rows)} | <>
               "(the AuditWriter @known_actions allowlist must include \"member_removed\")"

      [row] = member_rows
      assert row.action == "member_removed", "got action=#{inspect(row.action)}"
      assert row.actor_user_id == admin_id, "actor must be the admin, got #{inspect(row.actor_user_id)}"
      assert row.target_id == room_id, "target must be the room, got #{inspect(row.target_id)}"
    end
  end
end
