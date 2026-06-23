Feature: Matrix Session Refresh — Long-Lived Element Sessions
  As a Matrix chat user logging in to Element Web via OIDC (Authorization Code + PKCE)
  I want my session to stay alive for many hours without interruption
  So that I am not force-logged-out a few minutes after the OIDC access token expires

  # Story: e2e-session-refresh-suites (epic fix-short-oidc-sessions) — completes AC8 of
  # oidc-session-refresh at the browser level.
  # Spec:  Matrix Client-Server API v1.18 §refreshing-access-tokens (added v1.3).
  #
  # OIDC login is Authorization Code + PKCE via Dex — NO ROPC / grant_type=password
  # (project OIDC testing standard). Reuses fixtures/dex-auth.ts loginViaOidcBrowser +
  # getApiSession — no cookie forging, no DB seeding.
  #
  # @pending-feature — BLOCKED ON CLIENT CAPABILITY, not on Nebu.
  # Verified 2026-06-23 against the e2e Element Web v1.12.15 build: in the Matrix SSO
  # loginToken flow Element does NOT send `refresh_token: true` on POST /login, so Nebu
  # correctly returns the OIDC JWT (the AC7 fallback) and the live client token is the JWT —
  # no opaque session / no refresh token is exercised through this client. (Confirmed: zero
  # "matrix session created" server logs and the live mxMatrixClientPeg access token is a JWT.)
  # The Nebu opaque-token + POST /v3/refresh server path IS covered end-to-end by the ExUnit
  # integration suite (server/test/nebu/matrix/login_refresh_test.exs), which sends
  # refresh_token:true explicitly. Un-pend these once the bundled Matrix client requests
  # refresh tokens (newer Element, or a client configured to opt in) — the step definitions
  # are complete and ready (live-token assertions, revoke-driven soft-logout, short-TTL via
  # `make test-e2e-refresh`). Tracked as a follow-up; see the story's Dev Notes.

  Background:
    Given the Nebu stack is running
    And alex has no cached session

  @ac8-refresh-token-issued @pending-feature
  Scenario: Element receives an opaque (non-JWT) Matrix access token on login
    When alex logs in to Element Web via Dex SSO with "alex@example.com"
    Then the stored Matrix access token is an opaque token, not a JWT
    And Element has a refreshable Matrix session

  @ac8-session-refresh @pending-feature @short-ttl
  Scenario: Session survives past the access-token lifetime via silent refresh
    Given the Nebu stack uses a short Matrix session lifetime
    And alex logs in to Element Web via Dex SSO with "alex@example.com"
    And the room list is visible
    When the Matrix session lifetime elapses
    And alex reloads Element Web after the lifetime has elapsed
    Then alex is NOT redirected to the Dex login page
    And the room list is still visible

  @ac8-soft-logout @pending-feature @short-ttl
  Scenario: A revoked session soft-logs-out instead of hard kicking the user
    Given alex logs in to Element Web via Dex SSO with "alex@example.com"
    And the room list is visible
    When alex's Matrix session is revoked server-side
    And alex reloads Element Web after the lifetime has elapsed
    Then Element shows a soft-logout state or returns to the sign-in screen
