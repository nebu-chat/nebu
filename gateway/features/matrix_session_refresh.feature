Feature: Matrix Session Refresh — Opaque Tokens & Long-Lived Sessions
  As a Matrix chat user (Element Web / FluffyChat)
  I want my session to stay alive for many hours without interruption
  So that I don't get force-logged-out every few minutes and lose my chat context

  # Story: oidc-session-refresh (bugfix/fix-short-oidc-sessions)
  # Spec:   Matrix Client-Server API v1.18 §refreshing-access-tokens (added v1.3)
  #
  # RED PHASE: All scenarios MUST FAIL until:
  #   1. matrix_sessions table migration exists
  #   2. MatrixSessionStore (CRUD + RotateTokens + grace period) is implemented
  #   3. POST /login issues opaque tokens when refresh_token=true
  #   4. POST /_matrix/client/v3/refresh endpoint is registered (outside jwtMiddleware)
  #   5. JWTMiddleware handles opaque tokens: expiry check + soft_logout flag

  Background:
    Given the docker compose stack is started
    And kai is authenticated via OIDC

  # ─── AC1 ─────────────────────────────────────────────────────────────────────
  # Login with refresh_token:true issues opaque tokens (no dots, 64 hex chars each)

  Scenario: AC1_Login_WithRefreshFlag_ReturnsOpaqueTokens — POST /login with refresh_token:true returns opaque AT+RT
    When I POST /login with the Dex token and request a refresh token
    Then the response status is 200
    And the response body contains "access_token"
    And the response body contains "refresh_token"
    And the response body contains "expires_in_ms"
    And the access_token is an opaque hex string with no dots
    And the refresh_token is an opaque hex string with no dots
    And the expires_in_ms is greater than zero
    And the response body contains "user_id"
    And the response body contains "device_id"

  # ─── AC7 ─────────────────────────────────────────────────────────────────────
  # Backward compatibility: login WITHOUT refresh_token flag returns JWT as before

  Scenario: AC7_Login_WithoutRefreshFlag_ReturnsJWT — POST /login without refresh_token:true returns JWT (backward compat)
    # kai is already authenticated in Background via iPostLoginWithDexToken (no refresh flag)
    # The access_token stored in lastAccessToken must be a JWT (contains dots)
    Then the last login access_token is a JWT containing dots
    And the last login response has no refresh_token field
    And the last login response has no expires_in_ms field

  # ─── AC2 ─────────────────────────────────────────────────────────────────────
  # POST /refresh with valid Nebu refresh token returns new opaque tokens

  Scenario: AC2_Refresh_WithValidRT_ReturnsNewOpaqueTokens — POST /refresh returns 200 with new AT and RT
    Given I have a Nebu session with opaque access token and refresh token
    When I POST /_matrix/client/v3/refresh with the current refresh token
    Then the response status is 200
    And the response body contains "access_token"
    And the response body contains "expires_in_ms"
    And the new access_token is an opaque hex string with no dots
    And the new expires_in_ms is greater than zero

  # ─── AC3 ─────────────────────────────────────────────────────────────────────
  # New access token returned from /refresh works for /sync and /whoami

  Scenario: AC3_NewAccessToken_WorksForSync — new AT from /refresh is immediately usable for GET /sync
    Given I have a Nebu session with opaque access token and refresh token
    When I POST /_matrix/client/v3/refresh with the current refresh token
    Then the response status is 200
    And I capture the new access token from the refresh response
    When I call GET /_matrix/client/v3/sync with the new access token
    Then the response status is 200

  Scenario: AC3_NewAccessToken_WorksForWhoami — new AT from /refresh is immediately usable for GET /whoami
    Given I have a Nebu session with opaque access token and refresh token
    When I POST /_matrix/client/v3/refresh with the current refresh token
    Then the response status is 200
    And I capture the new access token from the refresh response
    When I call GET /_matrix/client/v3/account/whoami with the new access token
    Then the response status is 200
    And the response body contains "user_id"

  # ─── AC4 ─────────────────────────────────────────────────────────────────────
  # Old refresh token remains valid until the new tokens are first used (grace period)
  # Spec: MUST — matrix.org §refreshing-access-tokens

  Scenario: AC4_OldRT_ValidDuringGracePeriod_BeforeNewTokensUsed — old RT can refresh again before new AT/RT are used
    Given I have a Nebu session with opaque access token and refresh token
    And I capture the current refresh token as RT_A
    When I POST /_matrix/client/v3/refresh with RT_A
    Then the response status is 200
    # Grace period: new tokens (AT_B, RT_B) exist but have NOT been used yet
    # RT_A must still be valid for another refresh
    When I POST /_matrix/client/v3/refresh with RT_A again
    Then the response status is 200

  Scenario: AC4_OldRT_RevokedAfterNewATIsUsed — old RT is revoked once new AT is used for the first time
    Given I have a Nebu session with opaque access token and refresh token
    And I capture the current refresh token as RT_A
    When I POST /_matrix/client/v3/refresh with RT_A
    Then the response status is 200
    And I capture the new access token from the refresh response
    # Use new AT for the first time → this marks RT_A as consumed
    When I call GET /_matrix/client/v3/account/whoami with the new access token
    Then the response status is 200
    # Now RT_A must be revoked
    When I POST /_matrix/client/v3/refresh with RT_A again
    Then the response status is 401
    And the response body has errcode "M_UNKNOWN_TOKEN"

  # ─── AC5 ─────────────────────────────────────────────────────────────────────
  # Expired opaque access token returns 401 M_UNKNOWN_TOKEN with soft_logout:true

  Scenario: AC5_ExpiredOpaqueAT_ReturnsSoftLogout — expired opaque AT yields 401 with soft_logout:true
    Given I have an opaque access token that is already expired in the database
    When I call GET /_matrix/client/v3/sync with the expired access token
    Then the response status is 401
    And the response body has errcode "M_UNKNOWN_TOKEN"
    And the response body contains "soft_logout"
    And the soft_logout field is true

  # ─── AC6 ─────────────────────────────────────────────────────────────────────
  # Invalid, unknown, or already-replaced refresh tokens return 401

  Scenario: AC6_UnknownRT_Returns401 — POST /refresh with completely unknown RT returns 401
    When I POST /_matrix/client/v3/refresh with body {"refresh_token":"0000000000000000000000000000000000000000000000000000000000000000"}
    Then the response status is 401
    And the response body has errcode "M_UNKNOWN_TOKEN"

  Scenario: AC6_UsedAndReplacedRT_Returns401 — POST /refresh with an already-replaced RT returns 401
    Given I have a Nebu session with opaque access token and refresh token
    And I capture the current refresh token as RT_A
    When I POST /_matrix/client/v3/refresh with RT_A
    Then the response status is 200
    And I capture the new access token from the refresh response
    # Activate new tokens (consumes RT_A)
    When I call GET /_matrix/client/v3/account/whoami with the new access token
    Then the response status is 200
    # RT_A is now dead — a second use must fail
    When I POST /_matrix/client/v3/refresh with the old refresh token RT_A
    Then the response status is 401
    And the response body has errcode "M_UNKNOWN_TOKEN"

  # ─── Spec Edge Cases ─────────────────────────────────────────────────────────
  # Matrix spec v1.18 §9.5.2: POST /refresh requires no Authorization header

  Scenario: Spec_Refresh_RequiresNoAuthHeader — POST /refresh works without Authorization header
    Given I have a Nebu session with opaque access token and refresh token
    When I POST /_matrix/client/v3/refresh with the current refresh token and no Authorization header
    Then the response status is 200
    And the response body contains "access_token"

  Scenario: Spec_Refresh_MissingBody_Returns400 — POST /refresh with missing/empty body returns 400
    When I POST /_matrix/client/v3/refresh with an empty body
    Then the response status is 400

  Scenario: Spec_Refresh_MissingRefreshTokenField_Returns400 — POST /refresh with body missing refresh_token field returns 400
    When I POST /_matrix/client/v3/refresh with body {"wrong_field":"value"}
    Then the response status is 400
