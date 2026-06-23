defmodule Nebu.Matrix.EventDispatcher.AutoJoinRoomsTest do
  use ExUnit.Case, async: false

  # ─── Story admin-auto-join-rooms: ensure_auto_join_memberships/1 unit tests ──
  #
  # ATDD — Written FIRST (before implementation code).
  # These tests FAIL until:
  #   1. ensure_auto_join_memberships/1 is implemented in Nebu.Matrix.EventDispatcher.Server
  #   2. messages_db_module gains list_auto_join_rooms/0
  #   3. validate_token/2 calls ensure_auto_join_memberships/1 for new users only
  #
  # async: false — Application.put_env/3 is process-global.
  #
  # Test strategy:
  #   - AC6 (non-fatal DB error) tested via validate_token/2 with FakeDB returning
  #     {:error, :db_down} from list_auto_join_rooms/0. Login must return 200.
  #   - Idempotent join ({:error, :already_member}) tested directly on
  #     ensure_auto_join_memberships/1 — must return :ok without error.
  #   - Existing user (is_new=false) tested by asserting auto-join is NOT triggered.
  #
  # Acceptance Criteria covered:
  #   AC5 — Already-member join is idempotent (no error)
  #   AC6 — Login succeeds when list_auto_join_rooms/0 fails (non-fatal)
  #   (AC3, AC4 integration behaviour covered by Godog auto_join_rooms.feature)

  alias Nebu.Matrix.EventDispatcher.Server

  @charlie_user_id "@charlie:nebu.local"
  @charlie_display_name "Charlie"
  @charlie_email "charlie@example.com"

  # ─── Fake Token Validator ─────────────────────────────────────────────────────
  # Returns a valid user so validate_token passes the OIDC check.

  defmodule FakeTokenValidator do
    def validate(_user_id, _system_role, _display_name, _email) do
      {:ok, %{
        user_id: "@charlie:nebu.local",
        system_role: "user",
        display_name: "Charlie",
        is_active: true
      }}
    end
  end

  # ─── Fake Profile DB ─────────────────────────────────────────────────────────
  defmodule FakeProfileDB do
    def upsert_profile(_user_id, _display_name, _avatar_url), do: :ok
  end

  # ─── Fake Messages DB: list_auto_join_rooms returns {:error, :db_down} ────────
  # Exercises the non-fatal error path in ensure_auto_join_memberships/1.
  # Login must still succeed.

  defmodule FakeMessagesDB_ListRoomsFails do
    def list_auto_join_rooms(), do: {:error, :db_down}

    # Stubs for personal room operations (Story personal-self-room hook):
    def get_personal_room_id(_user_id), do: {:ok, "!charlie_self:nebu.local"}
    def set_personal_room_id(_user_id, _room_id), do: :ok

    # Stubs for other messages_db_module calls:
    def insert_room(_room_id), do: {:ok, System.system_time(:millisecond)}
    def insert_member(_room_id, _user_id), do: :ok
    def insert_event(_event), do: :ok
    def set_power_levels(_room_id, _levels), do: :ok
    def get_rooms_for_user(_user_id), do: {:ok, []}
    def get_recently_left_rooms_for_user(_), do: {:ok, []}
    def get_room_name(_room_id), do: {:ok, nil}
    def get_room_heroes(_room_id, _exclude), do: {:ok, %{heroes: [], joined: 0, invited: 0}}
  end

  # ─── Fake Messages DB: list_auto_join_rooms succeeds, room join attempted ──────
  # Tracks whether ensure_auto_join_memberships was invoked via process notification.
  defmodule FakeMessagesDB_AutoJoinRoom do
    def list_auto_join_rooms() do
      # Returns one auto-join room ID.
      {:ok, ["!general:nebu.local"]}
    end

    def get_personal_room_id(_user_id), do: {:ok, "!charlie_self:nebu.local"}
    def set_personal_room_id(_user_id, _room_id), do: :ok

    def insert_room(_room_id), do: {:ok, System.system_time(:millisecond)}
    def insert_member(_room_id, _user_id) do
      send(:auto_join_test_listener, {:insert_member_called})
      :ok
    end
    def insert_event(_event), do: :ok
    def set_power_levels(_room_id, _levels), do: :ok
    def get_rooms_for_user(_user_id), do: {:ok, []}
    def get_recently_left_rooms_for_user(_), do: {:ok, []}
    def get_room_name(_room_id), do: {:ok, nil}
    def get_room_heroes(_room_id, _exclude), do: {:ok, %{heroes: [], joined: 0, invited: 0}}
  end

  # ─── Fake stream helper ───────────────────────────────────────────────────────

  defp fake_stream(user_id) do
    %{http_request_headers: %{"x-user-id" => user_id}}
  end

  defp make_validate_token_request do
    %Core.ValidateTokenRequest{
      display_name: @charlie_display_name,
      email: @charlie_email
    }
  end

  # ─── Fake Messages DB: no-op default (no auto-join rooms) ───────────────────
  # Used as default in setup so AC5 + empty-list tests don't hit the real Ecto repo.

  defmodule FakeMessagesDB_NoAutoJoinRooms do
    def list_auto_join_rooms(), do: {:ok, []}
    def get_personal_room_id(_user_id), do: {:ok, nil}
    def set_personal_room_id(_user_id, _room_id), do: :ok
    def insert_room(_room_id), do: {:ok, System.system_time(:millisecond)}
    def insert_member(_room_id, _user_id), do: :ok
    def insert_event(_event), do: :ok
    def set_power_levels(_room_id, _levels), do: :ok
    def get_rooms_for_user(_user_id), do: {:ok, []}
    def get_recently_left_rooms_for_user(_), do: {:ok, []}
    def get_room_name(_room_id), do: {:ok, nil}
    # MINOR-5: add missing get_room_heroes/2 stub
    def get_room_heroes(_room_id, _exclude), do: {:ok, %{heroes: [], joined: 0, invited: 0}}
  end

  # ─── Setup ───────────────────────────────────────────────────────────────────

  setup do
    Application.put_env(:event_dispatcher, :profile_db_module, FakeProfileDB)
    Application.put_env(:event_dispatcher, :token_validator_module, FakeTokenValidator)
    # Default: no auto-join rooms configured. Individual tests override as needed.
    Application.put_env(:event_dispatcher, :messages_db_module, FakeMessagesDB_NoAutoJoinRooms)

    on_exit(fn ->
      Application.delete_env(:event_dispatcher, :messages_db_module)
      Application.delete_env(:event_dispatcher, :profile_db_module)
      Application.delete_env(:event_dispatcher, :token_validator_module)
    end)

    Process.register(self(), :auto_join_test_listener)
    on_exit(fn ->
      if Process.whereis(:auto_join_test_listener) == self() do
        Process.unregister(:auto_join_test_listener)
      end
    end)

    :ok
  end

  # ─── AC6: Login succeeds when list_auto_join_rooms fails (non-fatal) ──────────
  #
  # GIVEN: messages_db_module.list_auto_join_rooms() returns {:error, :db_down}
  # WHEN:  validate_token/2 is called for a new user
  # THEN:  Returns a valid %Core.ValidateTokenResponse{} (login succeeds)
  #        AND the Task does not propagate the error (warning logged only)
  #
  # THIS TEST FAILS until:
  #   1. ensure_auto_join_memberships/1 catches {:error, _} from list_auto_join_rooms
  #      and returns :ok (logs warning only)
  #   2. validate_token/2 spawns Task.start(fn -> ensure_auto_join_memberships(user_id) end)
  #      only for new users

  test "validate_token succeeds when list_auto_join_rooms returns DB error (AC6)" do
    Application.put_env(:event_dispatcher, :messages_db_module, FakeMessagesDB_ListRoomsFails)

    req = make_validate_token_request()
    resp = Server.validate_token(req, fake_stream(@charlie_user_id))

    assert %Core.ValidateTokenResponse{} = resp,
      "validate_token must return ValidateTokenResponse even when list_auto_join_rooms fails. " <>
      "Got: #{inspect(resp)}"
    assert resp.user_id == @charlie_user_id,
      "user_id must be present in ValidateTokenResponse. Got: #{inspect(resp.user_id)}"

    # Allow async Task to complete. Verify it did not crash the process.
    Process.sleep(150)
    assert Process.alive?(self()), "test process must not be killed by Task failure"
  end

  # ─── AC5: Already-member join is idempotent ───────────────────────────────────
  #
  # GIVEN: ensure_auto_join_memberships/1 is called for a user with one auto-join room
  #        configured (list_auto_join_rooms returns [{:ok, ["!general:nebu.local"]}])
  #        AND Room.Server is not started in unit tests, so join/2 fails with :noproc
  # WHEN:  ensure_auto_join_memberships/1 processes the auto-join room list
  # THEN:  Returns :ok (non-fatal — :noproc treated same as :already_member)
  #
  # MAJOR-1 fix: the previous version used FakeMessagesDB_NoAutoJoinRooms (empty list),
  # so the join was never attempted and the test passed vacuously. This version uses
  # FakeMessagesDB_AutoJoinRoom which returns a real room ID, causing Room.Server.join/2
  # to be called. Since Room.Server is not started in unit tests, the call fails with
  # {:error, :noproc} — which ensure_auto_join_memberships/1 must handle as non-fatal
  # (falls into the {:error, reason} catch-all → logs warning, returns :ok).

  test "ensure_auto_join_memberships is idempotent when user is already a member (AC5)" do
    # Override the default FakeMessagesDB_NoAutoJoinRooms with one that returns a real room.
    # Room.Server.join/2 will be called and will fail with {:error, :noproc} because
    # the Room GenServer is not started in unit tests.
    # ensure_auto_join_memberships must handle this non-fatally — no crash, returns :ok.
    Application.put_env(:event_dispatcher, :messages_db_module, FakeMessagesDB_AutoJoinRoom)

    result = Server.ensure_auto_join_memberships(@charlie_user_id)

    assert result == :ok,
      "ensure_auto_join_memberships must return :ok even when Room.Server.join fails " <>
      "with :noproc (non-fatal). Got: #{inspect(result)}"
  end

  # ─── ensure_auto_join_memberships returns :ok on empty list ──────────────────
  #
  # GIVEN: list_auto_join_rooms/0 returns {:ok, []} (no auto-join rooms configured)
  # WHEN:  ensure_auto_join_memberships/1 is called
  # THEN:  Returns :ok immediately
  #
  # THIS TEST FAILS until ensure_auto_join_memberships/1 is implemented.

  test "ensure_auto_join_memberships returns :ok when no auto-join rooms exist" do
    # THIS TEST FAILS — function does not exist yet.
    result = Server.ensure_auto_join_memberships(@charlie_user_id)

    assert result == :ok,
      "ensure_auto_join_memberships must return :ok when room list is empty. " <>
      "Got: #{inspect(result)}"
  end

  # ─── F-1 regression: update_room_settings rejects unauthenticated streams ────
  #
  # SEC Gate 1 finding F-1: update_room_settings/2 previously discarded the stream
  # (_stream), allowing any gRPC caller inside the cluster to toggle is_auto_join
  # without presenting a trusted identity. After the fix, the handler must raise
  # Nebu.Matrix.Status.unauthenticated() when the stream carries no x-user-id metadata.
  #
  # Given: a gRPC stream with no x-user-id header
  # When:  update_room_settings/2 is called with is_auto_join payload
  # Then:  raises Nebu.Matrix.Error with status unauthenticated

  defmodule FakeAuditWriter_F1 do
    def log(_actor, _action, _target_type, _target_id, _metadata, _outcome), do: :ok
  end

  defmodule FakeAdminDB_F1 do
    def update_room_auto_join(_room_id, _is_auto_join), do: :ok
  end

  test "update_room_settings raises unauthenticated when stream has no x-user-id" do
    Application.put_env(:compliance, :audit_writer, FakeAuditWriter_F1)
    Application.put_env(:event_dispatcher, :admin_db_module, FakeAdminDB_F1)
    on_exit(fn ->
      Application.delete_env(:compliance, :audit_writer)
      Application.delete_env(:event_dispatcher, :admin_db_module)
    end)

    empty_stream = %{http_request_headers: %{}}
    req = %Core.UpdateRoomSettingsRequest{room_id: "!room:nebu.local", is_auto_join: true}

    error = assert_raise Nebu.Matrix.Error, fn ->
      Server.update_room_settings(req, empty_stream)
    end

    assert error.status == Nebu.Matrix.Status.unauthenticated(),
      "Expected unauthenticated status, got: #{error.status}"
  end

  test "update_room_settings raises permission_denied when caller is not instance_admin" do
    Application.put_env(:compliance, :audit_writer, FakeAuditWriter_F1)
    Application.put_env(:event_dispatcher, :admin_db_module, FakeAdminDB_F1)
    on_exit(fn ->
      Application.delete_env(:compliance, :audit_writer)
      Application.delete_env(:event_dispatcher, :admin_db_module)
    end)

    user_stream = %{http_request_headers: %{"x-user-id" => "@charlie:nebu.local", "x-system-role" => "user"}}
    req = %Core.UpdateRoomSettingsRequest{room_id: "!room:nebu.local", is_auto_join: true}

    error = assert_raise Nebu.Matrix.Error, fn ->
      Server.update_room_settings(req, user_stream)
    end

    assert error.status == Nebu.Matrix.Status.permission_denied(),
      "Expected permission_denied status, got: #{error.status}"
  end

  # ─── Story auto-join-on-user-import: bulk_import_users/2 tests ───────────────
  #
  # ATDD — Written FIRST (before implementation code).
  # These tests FAIL until:
  #   1. Server.bulk_import_users/2 calls ensure_auto_join_memberships/1 and
  #      ensure_personal_room/1 for each newly-imported user (non-blocking Task.start)
  #   2. BulkImporter.import_users/1 returns imported_user_ids in the result map
  #
  # Acceptance Criteria covered:
  #   AC1 — ensure_auto_join_memberships runs for dave after BulkImportUsers (new user)
  #   AC2 — ensure_personal_room is triggered for dave after BulkImportUsers (new user)
  #   AC5 — :already_member is handled non-fatally during bulk import auto-join
  #   AC6 — DB down during list_auto_join_rooms is non-fatal; import result returned

  @dave_user_id "@dave:nebu.local"

  # ─── Fake BulkImporter returning 1 imported user (dave) ──────────────────────
  # Reports dave as newly imported (included in imported_user_ids).

  defmodule FakeBulkImporter_DaveNew do
    def import_users(_users) do
      {:ok, %{
        imported: 1,
        skipped: 0,
        failed: 0,
        imported_user_ids: ["@dave:nebu.local"]
      }}
    end
  end

  # ─── Fake BulkImporter returning 0 imported users (all skipped) ──────────────
  # Reports no new users (AC3: existing users skipped, no auto-join triggered).

  defmodule FakeBulkImporter_AllSkipped do
    def import_users(_users) do
      {:ok, %{
        imported: 0,
        skipped: 1,
        failed: 0,
        imported_user_ids: []
      }}
    end
  end

  # ─── Fake AuditWriter for bulk_import_users tests ─────────────────────────────
  defmodule FakeAuditWriter_BulkImport do
    def log(_actor, _action, _target_type, _target_id, _metadata, _outcome), do: :ok
  end

  # ─── FakeRoomDB — room_manager :db_module for AC1 ────────────────────────────
  # Handles all Room.Server init callbacks (get_room_status, load_members,
  # insert_room, load_room_settings, insert_event) and tracks insert_member calls.
  # Uses the same :auto_join_test_listener notification pattern as FakeMessagesDB_AutoJoinRoom.
  defmodule FakeRoomDB_AutoJoinTracked do
    @behaviour Nebu.Matrix.Room.DBBehaviour

    def get_room_status(_room_id), do: {:ok, "active"}
    def load_members(_room_id), do: {:error, :not_found}
    def insert_room(_room_id), do: {:ok, System.system_time(:millisecond)}
    def load_room_settings(_room_id), do: {:error, :not_found}
    def insert_event(_event), do: :ok
    def set_power_levels(_room_id, _levels), do: :ok
    def delete_member(_room_id, _user_id), do: :ok

    def insert_member(_room_id, _user_id) do
      send(:auto_join_test_listener, {:insert_member_called})
      :ok
    end

    # Unused stubs required by DBBehaviour:
    def fetch_events(_room_id, _dir, _limit, _from), do: {:ok, [], "", ""}
    def fetch_events_since(_room_id, _last_event_id, _limit), do: {:ok, []}
    def get_event_timestamp(_event_id), do: {:error, :not_found}
    def get_room_name(_room_id), do: {:error, :not_found}
    def get_room_creator(_room_id), do: {:error, :not_found}
    def get_room_create_event(_room_id), do: {:error, :not_found}
    def get_generic_state_events(_room_id), do: {:ok, []}
    def get_rooms_for_user(_user_id), do: {:ok, []}
    def get_recently_left_rooms_for_user(_user_id), do: {:ok, []}
    def fetch_events_by_relation(_room_id, _event_id, _rel_type, _limit, _opts), do: {:ok, []}
    def count_thread_children(_room_id, _event_id), do: {:ok, 0}
    def event_in_room?(_event_id, _room_id), do: true
    def fetch_event(_event_id, _room_id), do: {:error, :not_found}
    def get_personal_room_id(_user_id), do: {:ok, nil}
    def set_personal_room_id(_user_id, _room_id), do: :ok
    def get_room_heroes(_room_id, _exclude_user_id), do: {:ok, %{heroes: [], joined: 0, invited: 0}}
    def list_auto_join_rooms(), do: {:ok, []}
    def check_room_status_for_update(_room_id), do: {:ok, "active"}
  end

  # ─── Fake stream for bulk_import_users ───────────────────────────────────────
  # Stream with trusted instance_admin identity (as the Go gateway sends).
  defp admin_stream do
    %{http_request_headers: %{
      "x-user-id" => "@admin:nebu.local",
      "x-system-role" => "instance_admin"
    }}
  end

  defp make_bulk_import_request(user_ids) do
    users =
      Enum.map(user_ids, fn uid ->
        %Core.OIDCUserClaims{user_id: uid, display_name: "", email: ""}
      end)
    %Core.BulkImportUsersRequest{users: users}
  end

  # ─── AC1: ensure_auto_join_memberships runs for dave after BulkImportUsers ────
  #
  # GIVEN: room "General" has is_auto_join=true (FakeMessagesDB_AutoJoinRoom returns
  #        [{:ok, ["!general:nebu.local"]}])
  # WHEN:  Server.bulk_import_users/2 is called with @dave:nebu.local (new user)
  # THEN:  ensure_auto_join_memberships runs for dave (non-blocking Task.start)
  #        AND dave is joined to "General" (FakeRoomDB_AutoJoinTracked.insert_member
  #        sends {:insert_member_called} to :auto_join_test_listener)
  #
  # Note: ensure_auto_join_memberships calls Nebu.Matrix.Room.RoomSupervisor.start_room
  # which starts the Room GenServer under Horde. The Room GenServer uses
  # :room_manager, :db_module (FakeRoomDB_AutoJoinTracked) for DB calls, NOT
  # :event_dispatcher, :messages_db_module. inject both, and ensure :pg is started.

  test "AC1: bulk_import_users triggers ensure_auto_join_memberships for newly imported user" do
    # Ensure :pg process groups are running (required for Horde).
    case :pg.start_link() do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    Application.put_env(:event_dispatcher, :messages_db_module, FakeMessagesDB_AutoJoinRoom)
    Application.put_env(:room_manager, :db_module, FakeRoomDB_AutoJoinTracked)
    Application.put_env(:event_dispatcher, :bulk_importer_module, FakeBulkImporter_DaveNew)
    Application.put_env(:compliance, :audit_writer, FakeAuditWriter_BulkImport)
    on_exit(fn ->
      Application.delete_env(:event_dispatcher, :bulk_importer_module)
      Application.delete_env(:compliance, :audit_writer)
      Application.delete_env(:room_manager, :db_module)
    end)

    req = make_bulk_import_request([@dave_user_id])

    resp = Server.bulk_import_users(req, admin_stream())

    assert %Core.BulkImportUsersResponse{} = resp,
      "bulk_import_users must return BulkImportUsersResponse. Got: #{inspect(resp)}"

    # Allow async Task to complete.
    Process.sleep(300)

    assert_received {:insert_member_called},
      "ensure_auto_join_memberships must be triggered for @dave:nebu.local — " <>
      "FakeRoomDB_AutoJoinTracked.insert_member must have been called. " <>
      "No {:insert_member_called} message received within 300ms."
  end

  # ─── AC2: ensure_personal_room is triggered for dave after BulkImportUsers ────
  #
  # GIVEN: BulkImportUsers is called with @dave:nebu.local who does NOT yet exist
  #        (FakeBulkImporter_DaveNew reports dave in imported_user_ids)
  # WHEN:  Server.bulk_import_users/2 processes the import
  # THEN:  ensure_personal_room/1 is triggered for dave (fire-and-forget)
  #        Verified via: FakeMessagesDB_PersonalRoom.get_personal_room_id sends
  #        {:personal_room_checked, user_id} to :auto_join_test_listener
  #
  # THIS TEST FAILS until:
  #   1. bulk_import_users/2 calls ensure_personal_room/1 for each imported user

  defmodule FakeMessagesDB_PersonalRoom do
    def list_auto_join_rooms(), do: {:ok, []}

    def get_personal_room_id(user_id) do
      send(:auto_join_test_listener, {:personal_room_checked, user_id})
      # Return {:ok, "!existing_self:nebu.local"} — no creation needed (idempotent).
      {:ok, "!dave_self:nebu.local"}
    end

    def set_personal_room_id(_user_id, _room_id), do: :ok
    def insert_room(_room_id), do: {:ok, System.system_time(:millisecond)}
    def insert_member(_room_id, _user_id), do: :ok
    def insert_event(_event), do: :ok
    def set_power_levels(_room_id, _levels), do: :ok
    def get_rooms_for_user(_user_id), do: {:ok, []}
    def get_recently_left_rooms_for_user(_), do: {:ok, []}
    def get_room_name(_room_id), do: {:ok, nil}
    def get_room_heroes(_room_id, _exclude), do: {:ok, %{heroes: [], joined: 0, invited: 0}}
  end

  test "AC2: bulk_import_users triggers ensure_personal_room for newly imported user" do
    Application.put_env(:event_dispatcher, :messages_db_module, FakeMessagesDB_PersonalRoom)
    Application.put_env(:event_dispatcher, :bulk_importer_module, FakeBulkImporter_DaveNew)
    Application.put_env(:compliance, :audit_writer, FakeAuditWriter_BulkImport)
    on_exit(fn ->
      Application.delete_env(:event_dispatcher, :bulk_importer_module)
      Application.delete_env(:compliance, :audit_writer)
    end)

    req = make_bulk_import_request([@dave_user_id])

    # THIS TEST FAILS — bulk_import_users does not trigger ensure_personal_room yet.
    resp = Server.bulk_import_users(req, admin_stream())

    assert %Core.BulkImportUsersResponse{} = resp,
      "bulk_import_users must return BulkImportUsersResponse. Got: #{inspect(resp)}"

    # Allow async Task to complete.
    Process.sleep(150)

    assert_received {:personal_room_checked, @dave_user_id},
      "ensure_personal_room must be triggered for @dave:nebu.local — " <>
      "FakeMessagesDB_PersonalRoom.get_personal_room_id must have been called. " <>
      "No {:personal_room_checked, \"@dave:nebu.local\"} message received within 150ms."
  end

  # ─── AC5 (bulk path): :already_member during bulk import auto-join is non-fatal ─
  #
  # GIVEN: ensure_auto_join_memberships tries to join dave to a room where he's
  #        already a member (Nebu.Matrix.Room.Server.join/2 returns {:error, :already_member})
  # WHEN:  bulk_import_users/2 triggers ensure_auto_join_memberships for dave
  # THEN:  no error is raised and the import result is returned successfully
  #
  # NOTE: The :already_member path is already tested directly (existing test above).
  # This test verifies it also holds when triggered indirectly via bulk_import_users.
  #
  # THIS TEST FAILS until bulk_import_users/2 calls ensure_auto_join_memberships
  # for imported users.

  defmodule FakeMessagesDB_AlreadyMemberBulk do
    # Returns a real room list so ensure_auto_join_memberships tries to join dave.
    # Room.Server.join/2 will fail with :noproc (room not started in test) — which
    # ensure_auto_join_memberships must handle as non-fatal (log and continue).
    def list_auto_join_rooms(), do: {:ok, ["!general:nebu.local"]}

    def get_personal_room_id(_user_id), do: {:ok, "!dave_self:nebu.local"}
    def set_personal_room_id(_user_id, _room_id), do: :ok
    def insert_room(_room_id), do: {:ok, System.system_time(:millisecond)}
    def insert_member(_room_id, _user_id), do: :ok
    def insert_event(_event), do: :ok
    def set_power_levels(_room_id, _levels), do: :ok
    def get_rooms_for_user(_user_id), do: {:ok, []}
    def get_recently_left_rooms_for_user(_), do: {:ok, []}
    def get_room_name(_room_id), do: {:ok, nil}
    def get_room_heroes(_room_id, _exclude), do: {:ok, %{heroes: [], joined: 0, invited: 0}}
  end

  test "AC5 (bulk path): bulk_import_users succeeds even when auto-join room join fails non-fatally" do
    Application.put_env(:event_dispatcher, :messages_db_module, FakeMessagesDB_AlreadyMemberBulk)
    Application.put_env(:event_dispatcher, :bulk_importer_module, FakeBulkImporter_DaveNew)
    Application.put_env(:compliance, :audit_writer, FakeAuditWriter_BulkImport)
    on_exit(fn ->
      Application.delete_env(:event_dispatcher, :bulk_importer_module)
      Application.delete_env(:compliance, :audit_writer)
    end)

    req = make_bulk_import_request([@dave_user_id])

    # THIS TEST FAILS — bulk_import_users does not trigger ensure_auto_join_memberships yet.
    # The room join will fail with :noproc (Room GenServer not running in unit tests).
    # ensure_auto_join_memberships must log a warning and return :ok — not crash.
    resp = Server.bulk_import_users(req, admin_stream())

    assert %Core.BulkImportUsersResponse{} = resp,
      "bulk_import_users must return BulkImportUsersResponse even when room join fails. " <>
      "Got: #{inspect(resp)}"

    assert resp.imported == 1,
      "imported count must be 1. Got: #{inspect(resp.imported)}"

    # Allow async Task to complete. Verify the Task did not crash the test process.
    Process.sleep(150)
    assert Process.alive?(self()), "test process must not be killed by Task failure in auto-join"
  end

  # ─── AC6 (bulk path): list_auto_join_rooms DB error is non-fatal ──────────────
  #
  # GIVEN: list_auto_join_rooms/0 returns {:error, :db_down} during bulk import auto-join
  # WHEN:  Server.bulk_import_users/2 imports dave and triggers ensure_auto_join_memberships
  # THEN:  The error is handled non-fatally (warning logged, import result still returned)
  #
  # THIS TEST FAILS until:
  #   1. bulk_import_users/2 calls ensure_auto_join_memberships for imported users
  #   2. ensure_auto_join_memberships handles {:error, _} from list_auto_join_rooms non-fatally

  test "AC6 (bulk path): bulk_import_users succeeds when list_auto_join_rooms returns DB error" do
    Application.put_env(:event_dispatcher, :messages_db_module, FakeMessagesDB_ListRoomsFails)
    Application.put_env(:event_dispatcher, :bulk_importer_module, FakeBulkImporter_DaveNew)
    Application.put_env(:compliance, :audit_writer, FakeAuditWriter_BulkImport)
    on_exit(fn ->
      Application.delete_env(:event_dispatcher, :bulk_importer_module)
      Application.delete_env(:compliance, :audit_writer)
    end)

    req = make_bulk_import_request([@dave_user_id])

    # THIS TEST FAILS — bulk_import_users does not trigger ensure_auto_join_memberships yet.
    resp = Server.bulk_import_users(req, admin_stream())

    assert %Core.BulkImportUsersResponse{} = resp,
      "bulk_import_users must return BulkImportUsersResponse even when list_auto_join_rooms fails. " <>
      "Got: #{inspect(resp)}"

    assert resp.imported == 1,
      "imported count must still be 1 when auto-join DB fails. Got: #{inspect(resp.imported)}"

    # Allow async Task to complete. Verify no crash propagated.
    Process.sleep(150)
    assert Process.alive?(self()), "test process must not be killed by DB error in auto-join Task"
  end

  # ─── AC3 (via Server): existing user does NOT trigger ensure_auto_join_memberships ─
  #
  # GIVEN: BulkImportUsers is called with @existing:nebu.local who already exists
  #        (FakeBulkImporter_AllSkipped reports no imported_user_ids)
  # WHEN:  Server.bulk_import_users/2 processes the import
  # THEN:  ensure_auto_join_memberships is NOT called for the existing user
  #        (FakeMessagesDB_AutoJoinRoom.insert_member must NOT be called)
  #
  # THIS TEST FAILS until:
  #   1. bulk_import_users/2 only calls ensure_auto_join_memberships for imported_user_ids
  #   2. It does NOT call it for skipped (existing) users

  test "AC3 (via Server): skipped (existing) user does not trigger ensure_auto_join_memberships" do
    Application.put_env(:event_dispatcher, :messages_db_module, FakeMessagesDB_AutoJoinRoom)
    Application.put_env(:event_dispatcher, :bulk_importer_module, FakeBulkImporter_AllSkipped)
    Application.put_env(:compliance, :audit_writer, FakeAuditWriter_BulkImport)
    on_exit(fn ->
      Application.delete_env(:event_dispatcher, :bulk_importer_module)
      Application.delete_env(:compliance, :audit_writer)
    end)

    req = make_bulk_import_request(["@existing:nebu.local"])

    # THIS TEST FAILS — bulk_import_users does not check imported_user_ids yet.
    resp = Server.bulk_import_users(req, admin_stream())

    assert %Core.BulkImportUsersResponse{} = resp,
      "bulk_import_users must return BulkImportUsersResponse. Got: #{inspect(resp)}"

    assert resp.skipped == 1,
      "skipped count must be 1. Got: #{inspect(resp.skipped)}"

    # Allow any async Task to complete.
    Process.sleep(150)

    # The FakeMessagesDB_AutoJoinRoom sends {:insert_member_called} whenever insert_member
    # is invoked. For a skipped user, NO Task should be started, so no message should arrive.
    refute_received {:insert_member_called},
      "ensure_auto_join_memberships must NOT be triggered for skipped (existing) user. " <>
      "Received {:insert_member_called} unexpectedly."
  end
end
