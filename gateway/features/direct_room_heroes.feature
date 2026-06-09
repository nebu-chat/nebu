Feature: DM Room Names — Populate Matrix Sync Heroes
  # ATDD — Written FIRST (before implementation code).
  # Story: direct-room-heroes (epic: room-naming-and-default-rooms)
  #
  # DM rooms without an explicit m.room.name currently appear as "Empty Room" in
  # Matrix clients because Nebu does not populate summary["m.heroes"] in sync.
  #
  # These tests assert the expected behaviour after implementation. They FAIL
  # until heroes computation is added to the Elixir Core (event_dispatcher/server.ex)
  # and the proto SyncRoom message gains the heroes/joined_member_count/invited_member_count
  # fields, and sync.go attaches Summary to syncJoinedRoom.
  #
  # Spec references (Oracle, 2026-05-28):
  #   - Matrix CS API §11.2.2 — Room Summary / m.heroes
  #   - §11.2.2.5 — Hero computation rules (joined first, invited second, cap 5, excl. syncing user)
  #   - m.joined_member_count, m.invited_member_count always accompany heroes
  #   - Named rooms (m.room.name non-empty): summary SHOULD be absent (omitempty pointer)
  #   - Delta sync: summary MAY be omitted when heroes/counts unchanged

  Scenario: [AC1] 1-on-1 DM room shows the other participant as hero
    # P0 — Core ATDD gate: bob syncs into a DM room with alice.
    # summary["m.heroes"] must contain alice's MXID; heroes excludes the syncing user.
    # WILL FAIL until proto SyncRoom has heroes field + Elixir computes heroes.
    Given the docker compose stack is started
    And alice is authenticated via OIDC
    And bob is authenticated via OIDC
    When alice creates a DM room with bob
    And bob calls GET /sync with timeout 0
    Then the sync response status is 200
    And bob's sync response contains a summary for the DM room
    And the DM room summary has m.heroes containing "@alice:localhost"
    And the DM room summary does not contain "@bob:localhost" in m.heroes
    And the DM room summary has m.joined_member_count 2

  Scenario: [AC2] 3-person DM room shows both other participants as heroes
    # P0 — charlie syncs into a 3-person DM room with alice and bob.
    # m.heroes must contain alice and bob (order may vary); charlie is excluded.
    # WILL FAIL until Elixir hero computation is implemented.
    Given the docker compose stack is started
    And alice is authenticated via OIDC
    And bob is authenticated via OIDC
    And charlie is authenticated via OIDC
    When alice creates a group DM room with bob and charlie
    And charlie calls GET /sync with timeout 0
    Then the sync response status is 200
    And charlie's sync response contains a summary for the group DM room
    And the group DM room summary has m.heroes containing "@alice:localhost"
    And the group DM room summary has m.heroes containing "@bob:localhost"
    And the group DM room summary does not contain "@charlie:localhost" in m.heroes
    And the group DM room summary has m.joined_member_count 3

  Scenario: [AC3] Named room has no summary heroes in sync
    # P1 — rooms with an explicit m.room.name must not send summary.heroes.
    # summary key must be absent or heroes must be empty — explicit name takes precedence.
    # WILL FAIL until Go sync.go uses omitempty pointer for Summary on named rooms.
    Given the docker compose stack is started
    And alice is authenticated via OIDC
    And bob is authenticated via OIDC
    When alice creates a named room "Team" with bob
    And alice calls GET /sync with timeout 0
    Then the sync response status is 200
    And the "Team" room in alice's sync response has no summary heroes

  Scenario: [AC4] Initial sync populates heroes for all unnamed DM rooms
    # P0 — initial sync (no ?since) must populate summary.heroes for all unnamed rooms.
    # WILL FAIL until Elixir sends heroes in GetInitialSyncResponse.
    Given the docker compose stack is started
    And alice is authenticated via OIDC
    And bob is authenticated via OIDC
    And charlie is authenticated via OIDC
    When alice creates a DM room with bob
    And alice creates a second DM room with charlie
    And alice calls GET /sync with timeout 0
    Then the sync response status is 200
    And alice's first DM room has summary.m.heroes populated
    And alice's second DM room has summary.m.heroes populated

  Scenario: [Oracle edge] Delta sync omits summary when heroes unchanged
    # P2 — spec allows omitting summary in delta when nothing changed.
    # After an initial sync, a subsequent delta with no membership changes
    # SHOULD omit the summary key entirely for unchanged rooms.
    # WILL FAIL until Elixir delta-sync logic only sends summary on change.
    Given the docker compose stack is started
    And alice is authenticated via OIDC
    And bob is authenticated via OIDC
    When alice creates a DM room with bob
    And alice calls GET /sync with timeout 0
    Then the sync response status is 200
    And alice captures the sync next_batch token
    When alice calls GET /sync with the captured since token
    Then the incremental sync response status is 200
    And the DM room in the incremental sync response has no summary key

  Scenario: [Oracle edge] Unauthenticated sync returns 401 M_MISSING_TOKEN
    # P2 — Spec §11.2.2: authentication required for sync; confirmed by Oracle.
    # Matrix spec §5.3: no token provided → M_MISSING_TOKEN (not M_UNKNOWN_TOKEN).
    Given the docker compose stack is started
    When an unauthenticated client calls GET /sync
    Then the response status is 401
    And the response body has errcode "M_MISSING_TOKEN"
