Feature: Admin UI — Silent OIDC Session Refresh (Elixir)
  As a Nebu operator using the Phoenix LiveView Admin UI
  I want my admin session to stay alive for hours of normal use
  So that I'm not bounced to the login screen every few minutes against a real Keycloak

  # ATDD — Written FIRST (before implementation code).
  # Story: admin-oidc-session-refresh (epic: fix-short-oidc-sessions)
  #
  # The bug: against a Keycloak with a short access-token lifetime (e.g. 60s) the admin
  # session dies after that lifetime because the Elixir admin flow discards the OIDC
  # refresh token and caps the session at min(id_token.exp, now+8h) — so the 8h cap is
  # dead code and there is no refresh. This scenario proves AC4: an operator doing normal
  # Admin UI navigation stays authenticated WELL PAST the access-token lifetime, without
  # being redirected to /admin/login.
  #
  # OIDC: Authorization Code + PKCE (S256) via the live IdP only — NO ROPC, NO cookie
  # forging, NO DB seeding (CLAUDE.md UI standard). The silent refresh happens on HTTP
  # round-trips (dead renders / navigation / page loads) because cookies cannot be set
  # over the LiveView websocket.
  #
  # @short-ttl: these timing scenarios need a stack started with a short
  # NEBU_ADMIN_SESSION_TTL_SECONDS + admin_oidc_refresh_mode=offline (Dex issues a refresh
  # token only with offline_access). They run ONLY via `make test-e2e-refresh`; the default
  # run excludes @short-ttl (playwright.config.ts E2E_TAGS) since the shared stack caps at 8h.
  #
  # Test framework: playwright-bdd + Cucumber (admin-ui project).
  # Step definitions: e2e/step-definitions/admin/admin-session-refresh.steps.ts

  Background:
    Given the Nebu stack is running
    And bootstrap has been completed
    And the admin OIDC client has a short access-token lifetime

  @admin-oidc-session-refresh @short-ttl
  Scenario: Operator stays authenticated past the short OIDC access-token lifetime
    Given the operator is logged in to the admin UI
    When the access-token lifetime elapses
    And the operator navigates the Admin UI
    Then the operator is still authenticated in the admin area
    And the operator was not redirected to the admin login page

  @admin-oidc-session-refresh @short-ttl
  Scenario: The session survives multiple navigations across several token lifetimes
    Given the operator is logged in to the admin UI
    When the operator navigates the Admin UI repeatedly across several access-token lifetimes
    Then the operator is still authenticated in the admin area
    And the operator was not redirected to the admin login page
