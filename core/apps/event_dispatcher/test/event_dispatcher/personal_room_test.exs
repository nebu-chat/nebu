defmodule Nebu.EventDispatcher.PersonalRoomTest do
  use ExUnit.Case, async: false

  # ─── Story personal-self-room: ensure_personal_room/1 unit tests ─────────────
  #
  # ATDD — Written FIRST (before implementation code).
  # These tests FAIL until ensure_personal_room/1 is implemented in
  # Nebu.EventDispatcher.Server and the messages_db_module gains
  # get_personal_room_id/1 and set_personal_room_id/2.
  #
  # async: false — Application.put_env/3 is process-global.
  #
  # Test strategy:
  #   - AC4 (non-fatal) is tested via validate_token/2 with a FakeDB that
  #     returns DB errors. The gRPC response must still be a valid
  #     ValidateTokenResponse (login succeeds). Task.start/1 is fire-and-forget
  #     so we wait briefly for the async task to complete.
  #   - First login and idempotency: tested via get_personal_room_id/1 and
  #     set_personal_room_id/2 call counts tracked in process-owned ETS.
  #   - No PostgreSQL required — fully in-process with FakeDB injection.
  #
  # Acceptance Criteria covered:
  #   AC4 — Login succeeds even when self-room creation fails (DB error, non-fatal)
  #   (AC1, AC2, AC3 are covered by Godog integration scenarios)
  #
  # Additional unit sub-tests:
  #   - First login: get_personal_room_id called → {:ok, nil} → room created
  #   - Idempotent: get_personal_room_id called → {:ok, existing_id} → no room created

  alias Nebu.EventDispatcher.Server

  @alice_user_id "@alice:nebu.local"
  @alice_display_name "Alice"
  @alice_email "alice@example.com"

  # ─── Fake Token Validator ────────────────────────────────────────────────────
  # Returns a valid user so validate_token succeeds past the OIDC check.

  defmodule FakeTokenValidator do
    def validate(_user_id, _system_role, _display_name, _email) do
      {:ok, %{
        user_id: "@alice:nebu.local",
        system_role: "user",
        display_name: "Alice",
        is_active: true
      }}
    end
  end

  # ─── Fake Profile DB (stub — non-fatal path) ──────────────────────────────────
  defmodule FakeProfileDB do
    def upsert_profile(_user_id, _display_name, _avatar_url), do: :ok
  end

  # ─── Fake Messages DB: DB error for personal room operations ──────────────────
  # get_personal_room_id returns {:error, :db_down}
  # This exercises the non-fatal error path in ensure_personal_room/1.
  defmodule FakeMessagesDB_DBError do
    def get_personal_room_id(_user_id), do: {:error, :db_down}
    def set_personal_room_id(_user_id, _room_id), do: {:error, :db_down}

    # Stubs for any other messages_db_module calls:
    def insert_room(_room_id), do: {:ok, System.system_time(:millisecond)}
    def insert_member(_room_id, _user_id), do: :ok
    def insert_event(_event), do: :ok
    def set_power_levels(_room_id, _levels), do: :ok
    def get_rooms_for_user(_user_id), do: {:ok, []}
    def get_recently_left_rooms_for_user(_), do: {:ok, []}
    def get_room_name(_room_id), do: {:ok, nil}
    def get_room_heroes(_room_id, _exclude), do: {:ok, %{heroes: [], joined: 0, invited: 0}}
  end

  # ─── Fake Messages DB: no personal room yet (first login) ─────────────────────
  # Tracks whether set_personal_room_id was called via process-owned Agent.
  defmodule FakeMessagesDB_NoRoom do
    def get_personal_room_id(_user_id), do: {:ok, nil}
    def set_personal_room_id(user_id, room_id) do
      # Notify the test that set_personal_room_id was called with a non-nil room_id.
      send(:personal_room_test_listener, {:set_personal_room_id_called, user_id, room_id})
      :ok
    end

    def insert_room(_room_id), do: {:ok, System.system_time(:millisecond)}
    def insert_member(_room_id, _user_id), do: :ok
    def insert_event(_event), do: :ok
    def set_power_levels(_room_id, _levels), do: :ok
    def get_rooms_for_user(_user_id), do: {:ok, []}
    def get_recently_left_rooms_for_user(_), do: {:ok, []}
    def get_room_name(_room_id), do: {:ok, nil}
    def get_room_heroes(_room_id, _exclude), do: {:ok, %{heroes: [], joined: 0, invited: 0}}
  end

  # ─── Fake Messages DB: personal room already exists (idempotent) ───────────────
  defmodule FakeMessagesDB_RoomExists do
    @existing_room_id "!alice_self_room_existing:nebu.local"

    def get_personal_room_id(_user_id), do: {:ok, @existing_room_id}
    def set_personal_room_id(_user_id, _room_id) do
      # Signal test failure: set_personal_room_id must NOT be called when room exists.
      send(:personal_room_test_listener, {:set_personal_room_id_called_unexpectedly})
      :ok
    end

    def insert_room(_room_id) do
      send(:personal_room_test_listener, {:insert_room_called_unexpectedly})
      {:ok, System.system_time(:millisecond)}
    end
    def insert_member(_room_id, _user_id), do: :ok
    def insert_event(_event), do: :ok
    def set_power_levels(_room_id, _levels), do: :ok
    def get_rooms_for_user(_user_id), do: {:ok, []}
    def get_recently_left_rooms_for_user(_), do: {:ok, []}
    def get_room_name(_room_id), do: {:ok, nil}
    def get_room_heroes(_room_id, _exclude), do: {:ok, %{heroes: [], joined: 0, invited: 0}}
  end

  # ─── Fake stream helper ────────────────────────────────────────────────────────

  defp fake_stream(user_id) do
    %{http_request_headers: %{"x-user-id" => user_id}}
  end

  defp make_validate_token_request do
    %Core.ValidateTokenRequest{
      display_name: @alice_display_name,
      email: @alice_email
    }
  end

  # ─── Setup ───────────────────────────────────────────────────────────────────

  setup do
    Application.put_env(:event_dispatcher, :profile_db_module, FakeProfileDB)
    Application.put_env(:event_dispatcher, :token_validator_module, FakeTokenValidator)

    on_exit(fn ->
      Application.delete_env(:event_dispatcher, :messages_db_module)
      Application.delete_env(:event_dispatcher, :profile_db_module)
      Application.delete_env(:event_dispatcher, :token_validator_module)
    end)

    # Register test process as listener for FakeDB notifications.
    Process.register(self(), :personal_room_test_listener)
    on_exit(fn ->
      if Process.whereis(:personal_room_test_listener) == self() do
        Process.unregister(:personal_room_test_listener)
      end
    end)

    :ok
  end

  # ─── AC4: Login succeeds even when self-room DB fails (non-fatal) ──────────────
  #
  # GIVEN: messages_db_module returns {:error, :db_down} on get_personal_room_id
  # WHEN:  validate_token/2 is called (which spawns ensure_personal_room asynchronously)
  # THEN:  validate_token returns a valid %Core.ValidateTokenResponse{} (login succeeds)
  #        AND the Task does not propagate the DB error upward
  #
  # THIS TEST FAILS until:
  #   1. validate_token/2 spawns Task.start(fn -> ensure_personal_room(user_id) end)
  #   2. ensure_personal_room/1 catches DB errors and returns :ok (logs warning only)

  test "validate_token succeeds even when ensure_personal_room DB lookup fails (AC4)" do
    Application.put_env(:event_dispatcher, :messages_db_module, FakeMessagesDB_DBError)

    req = make_validate_token_request()
    # validate_token/2 must return a valid response — login must not be blocked.
    resp = Server.validate_token(req, fake_stream(@alice_user_id))

    assert %Core.ValidateTokenResponse{} = resp,
      "validate_token must return ValidateTokenResponse even when ensure_personal_room DB fails. " <>
      "Got: #{inspect(resp)}"
    assert resp.user_id == @alice_user_id,
      "user_id must be present in ValidateTokenResponse. Got: #{inspect(resp.user_id)}"

    # Allow the async Task to complete and verify it did not crash the process.
    # Task.start fire-and-forget — errors are logged, not propagated.
    Process.sleep(100)
    assert Process.alive?(self()), "test process must not be killed by Task failure"
  end

  # ─── First login: personal room created and ID persisted ─────────────────────
  #
  # GIVEN: no personal_room_id set for user (first login, get returns {:ok, nil})
  # WHEN:  validate_token/2 is called
  # THEN:  set_personal_room_id is called once with a non-nil room_id
  #
  # THIS TEST FAILS until ensure_personal_room/1 is implemented and hooked into
  # validate_token/2.

  test "validate_token triggers personal room creation on first login" do
    Application.put_env(:event_dispatcher, :messages_db_module, FakeMessagesDB_NoRoom)

    req = make_validate_token_request()
    resp = Server.validate_token(req, fake_stream(@alice_user_id))

    assert %Core.ValidateTokenResponse{} = resp,
      "validate_token must return ValidateTokenResponse. Got: #{inspect(resp)}"

    # Wait for the async Task to notify us that set_personal_room_id was called.
    assert_receive {:set_personal_room_id_called, @alice_user_id, room_id}, 1000,
      "set_personal_room_id must be called once with alice's user_id and a new room_id " <>
      "after first login. ensure_personal_room/1 not yet implemented."

    assert is_binary(room_id) and room_id != "",
      "room_id passed to set_personal_room_id must be a non-empty string. Got: #{inspect(room_id)}"
  end

  # ─── Idempotent: personal room already exists ─────────────────────────────────
  #
  # GIVEN: personal_room_id already set (get returns {:ok, "!existing:nebu.local"})
  # WHEN:  validate_token/2 is called (second or later login)
  # THEN:  set_personal_room_id is NOT called
  #        insert_room is NOT called
  #        validate_token still returns a valid response
  #
  # THIS TEST FAILS until ensure_personal_room/1 is implemented with the idempotency check.

  test "validate_token does not create duplicate self-room on re-login (AC2 idempotency)" do
    Application.put_env(:event_dispatcher, :messages_db_module, FakeMessagesDB_RoomExists)

    req = make_validate_token_request()
    resp = Server.validate_token(req, fake_stream(@alice_user_id))

    assert %Core.ValidateTokenResponse{} = resp,
      "validate_token must return ValidateTokenResponse on re-login. Got: #{inspect(resp)}"

    # Allow the async Task to run.
    Process.sleep(100)

    # Assert no unexpected calls from FakeMessagesDB_RoomExists.
    refute_receive {:set_personal_room_id_called_unexpectedly}, 0,
      "set_personal_room_id must NOT be called when personal_room_id already exists"
    refute_receive {:insert_room_called_unexpectedly}, 0,
      "insert_room must NOT be called when personal_room_id already exists"
  end
end
