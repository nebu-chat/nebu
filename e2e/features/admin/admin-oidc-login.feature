Feature: Admin OIDC Login — Authorization Code + PKCE (Elixir)
  As the Nebu operator
  I want to log into the Phoenix LiveView Admin UI with my OIDC identity
  So that the Admin UI is usable after the Go gateway is removed

  # ATDD — Written FIRST (before implementation code).
  # Story: go-removal-cleanup (epic: full-elixir-stack)
  #
  # Context: the deleted Go gateway (gateway/internal/admin/auth.go) owned the admin
  # OIDC Authorization-Code + PKCE login: login-start (PKCE verifier + challenge,
  # state, nonce), and /admin/callback (token exchange, ID-token verify, nonce check,
  # admin-claim gate, session mint). After Go removal, the Elixir admin had only an
  # on_mount gate that READS current_user — nothing wrote it, and /admin/login/start
  # redirected to itself (infinite loop). This story implements the full flow in Elixir
  # (NebuHttp.Admin.Auth + LoginController), reusing OidcPlug.verify_token + JwksCache.
  #
  # OIDC: Authorization Code + PKCE (S256) via Dex only — NO ROPC, NO cookie forging,
  # NO DB seeding (CLAUDE.md UI standard). The admin "kai" carries the instance_admin
  # group claim; the non-admin "alex" does not.
  #
  # Test framework: playwright-bdd + Cucumber (admin-ui project).
  # Step definitions: e2e/step-definitions/admin/admin-oidc-login.steps.ts

  Background:
    Given the Nebu stack is running
    And bootstrap has been completed

  @go-removal-cleanup @admin-oidc-login
  Scenario: Admin completes the OIDC Authorization-Code + PKCE login and reaches the dashboard
    Given the operator is not logged in to the admin UI
    When the operator starts the admin SSO login
    Then the browser is redirected to the Dex login page for the admin flow
    When the operator authenticates at Dex as the admin user
    Then the operator lands in the Phoenix LiveView admin area
    And the admin session cookie is set

  @go-removal-cleanup @admin-oidc-login
  Scenario: login-start carries PKCE challenge, state and nonce to the provider
    Given the operator is not logged in to the admin UI
    When the operator starts the admin SSO login
    Then the Dex authorization request includes a PKCE S256 challenge, a state and a nonce

  @go-removal-cleanup @admin-oidc-login @ac-admin-gate
  Scenario: A non-admin OIDC user is denied at the admin callback
    Given the operator is not logged in to the admin UI
    When the operator starts the admin SSO login
    And the operator authenticates at Dex as a non-admin user
    Then the admin login is rejected with a forbidden response or redirected back to the admin login

  @go-removal-cleanup @admin-oidc-login @ac-csrf
  Scenario: A callback with a mismatched state is rejected (CSRF protection)
    When a forged admin callback with an invalid state is requested
    Then the admin callback is rejected as a bad request
