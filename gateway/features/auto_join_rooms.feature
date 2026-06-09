Feature: Admin Auto-Join Rooms — New User Auto-Membership
  # ATDD — Written FIRST (before implementation code).
  # Story: admin-auto-join-rooms (epic: room-naming-and-default-rooms)
  #
  # Rooms flagged with is_auto_join=true in the DB cause newly provisioned users
  # to be automatically joined at first login. Existing users are NOT re-joined.
  # Auto-join failure is non-fatal: login always succeeds.
  #
  # Spec references (Oracle):
  #   - POST /_matrix/client/v3/login: triggers auto-join for new users
  #   - GET  /_matrix/client/v3/sync:  rooms.join must include auto-joined rooms
  #   - m.room.member: membership="join", state_key=<user_id>
  #
  # These tests FAIL until:
  #   1. Migration 000003_auto_join_rooms adds is_auto_join column
  #   2. list_auto_join_rooms/0 is implemented in Nebu.Room.DB
  #   3. ensure_auto_join_memberships/1 is called from validate_token/2 for new users
  #   4. Nebu.Room.Server.join/2 handles {:error, :already_member} idempotently

  Scenario: [AC3] New user is automatically joined to auto-join room on first login
    # P0 — Core ATDD gate: new user provisioned by validate_token is joined to
    # every room with is_auto_join=true before sync is called.
    Given the docker compose stack is started
    And room "general" exists with is_auto_join set to true
    And charlie is a new user who has never logged in
    When charlie logs in via OIDC
    Then the login response status is 200
    And the login response contains an access_token
    When charlie calls GET /sync with timeout 0
    Then the sync response status is 200
    And the sync rooms.join contains room "general" for charlie

  Scenario: [AC4] Existing user is NOT re-joined to auto-join room on re-login
    # P0 — Re-login must not change existing membership.
    # ensure_auto_join_memberships is only called when is_new=true from TokenValidator.
    Given the docker compose stack is started
    And room "general" exists with is_auto_join set to true
    And alice is a user who has logged in before and is already a member of "general"
    When alice logs in again via OIDC
    Then the login response status is 200
    When alice calls GET /sync with timeout 0
    Then the sync response status is 200
    And alice's room membership in "general" is unchanged from before login

  Scenario: [AC5] Auto-join is idempotent — no error when user is already a member
    # P1 — Pre-invited user logs in for the first time: is_new=true but already a member.
    # Nebu.Room.Server.join/2 must return {:error, :already_member} and the helper
    # treats it as :ok (no duplicate membership event, no error logged as warning).
    Given the docker compose stack is started
    And room "general" exists with is_auto_join set to true
    And charlie is a new user who has been pre-invited to "general" before first login
    When charlie logs in via OIDC
    Then the login response status is 200
    And the login response contains an access_token
    When charlie calls GET /sync with timeout 0
    Then the sync response status is 200
    And charlie has exactly one membership event in "general"

  Scenario: [AC6] Login succeeds even when auto-join DB query fails
    # P0 — Non-fatal: DB failure in list_auto_join_rooms must not block login.
    # Login returns 200 with access_token regardless of auto-join outcome.
    # (DB error path is unit-tested in ExUnit; this scenario validates the
    # integration contract: POST /login always returns 200.)
    Given the docker compose stack is started
    And charlie is a new user who has never logged in
    When charlie logs in via OIDC
    Then the login response status is 200
    And the login response contains an access_token
    And the login response contains a device_id
    And the login response contains a user_id

  Scenario: [Oracle edge] Unauthenticated sync returns 401 M_MISSING_TOKEN
    # P2 — Spec compliance: auto-join rooms must not be accessible without auth.
    # Matrix spec §5.3: no token provided → M_MISSING_TOKEN (not M_UNKNOWN_TOKEN).
    Given the docker compose stack is started
    When an unauthenticated client calls GET /sync
    Then the response status is 401
    And the response body has errcode "M_MISSING_TOKEN"

  Scenario: [Oracle edge] Auto-join room appears in sync rooms.join with m.room.member event
    # P1 — Spec compliance: after auto-join, rooms.join must include an m.room.member
    # event with membership="join" and state_key=<user_id> for the joined user.
    Given the docker compose stack is started
    And room "general" exists with is_auto_join set to true
    And charlie is a new user who has never logged in
    When charlie logs in via OIDC
    Then the login response status is 200
    When charlie calls GET /sync with timeout 0
    Then the sync response status is 200
    And charlie's sync rooms.join["general"] state contains an m.room.member event
    And charlie's m.room.member event has membership "join"
    And charlie's m.room.member event has state_key "@carol:localhost"
