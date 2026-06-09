Feature: Personal Self-Room at First Login
  # ATDD — Written FIRST (before implementation code).
  # Story: personal-self-room (epic: room-naming-and-default-rooms)
  #
  # When a user logs in for the first time via OIDC, the server must automatically
  # create a personal self-room named after their Matrix localpart.
  # The room must appear in GET /sync under rooms.join with a correct m.room.name
  # state event. Creation is idempotent — re-login never creates a duplicate.
  #
  # Spec references (Oracle):
  #   - GET /_matrix/client/v3/sync: rooms.join[roomId].state.events
  #   - m.room.name: type="m.room.name", state_key="", content.name=<localpart>
  #   - m.room.member: membership="join", state_key=<user_id>
  #
  # These tests FAIL until ensure_personal_room/1 is implemented in the Core
  # and the migration 000002_personal_room_id is applied.

  Scenario: [AC1] Personal self-room is created on first login and visible in sync
    # P0 — Core ATDD gate: validate_token spawns ensure_personal_room,
    # which creates the room in the DB and emits m.room.name.
    Given the docker compose stack is started
    And alice is a new user who has never logged in
    When alice logs in via OIDC
    Then the login response status is 200
    And the login response contains an access_token
    When alice calls GET /sync with timeout 0
    Then the sync response status is 200
    And the sync rooms.join contains exactly one self-room for alice
    And alice's self-room state contains an m.room.name event with name "alice"
    And alice's self-room state contains an m.room.member event with membership "join" for alice

  Scenario: [AC2] Self-room creation is idempotent on re-login
    # P0 — Re-login must not create a duplicate self-room.
    # personal_room_id FK in users table prevents duplicates;
    # ensure_personal_room checks it before creating.
    Given the docker compose stack is started
    And alice is a user who has logged in before (self-room already exists)
    When alice logs in again via OIDC
    Then the login response status is 200
    When alice calls GET /sync with timeout 0
    Then the sync response status is 200
    And alice's rooms.join contains exactly one self-room (no duplicates)

  Scenario: [AC3] Sync response contains m.room.name with correct state_key and name
    # P0 — Matrix spec §m.room.name: state_key MUST be "" (empty string).
    # content.name MUST equal the Matrix localpart (alice, not @alice:nebu.local).
    Given the docker compose stack is started
    And alice is authenticated via OIDC
    When alice calls GET /sync with timeout 0
    Then the sync response status is 200
    And alice's self-room m.room.name event has state_key ""
    And alice's self-room m.room.name event has content.name "alice"

  Scenario: [AC4] Login succeeds even when self-room creation fails (DB error)
    # P0 — Non-fatal: ensure_personal_room failure must not block login.
    # This scenario is covered by the ExUnit unit test (TestEnsurePersonalRoom_NonFatalOnDBError)
    # at the Elixir level. At the integration level we verify the login contract:
    # POST /login always returns 200 with access_token regardless of room creation outcome.
    Given the docker compose stack is started
    And alice is a new user who has never logged in
    When alice logs in via OIDC
    Then the login response status is 200
    And the login response contains an access_token
    And the login response contains a device_id
    And the login response contains a user_id

  Scenario: [Oracle edge] Unauthenticated sync returns 401 M_MISSING_TOKEN
    # P2 — Spec compliance: missing Authorization on GET /sync → 401 M_MISSING_TOKEN.
    # Matrix spec §5.3: no token provided → M_MISSING_TOKEN (not M_UNKNOWN_TOKEN).
    Given the docker compose stack is started
    When an unauthenticated client calls GET /sync
    Then the response status is 401
    And the response body has errcode "M_MISSING_TOKEN"
