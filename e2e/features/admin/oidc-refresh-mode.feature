Feature: Admin UI — Configurable OIDC refresh mode (online vs offline_access)
  As a Nebu operator
  I want to choose, transparently, whether the Matrix and admin OIDC clients request offline_access
  So that I can avoid forcing a security-sensitive long-lived refresh token where my IdP requires special approval

  # ATDD — Written FIRST (before implementation code).
  # Story: oidc-refresh-mode-config (epic: fix-short-oidc-sessions)
  #
  # AC6 (transparency): the bootstrap wizard AND the /admin/config page expose, per client,
  # a refresh-mode selector (offline | online) with hint text that surfaces the Dex caveat:
  #   "Dex issues a refresh token only with offline_access → online disables refresh on Dex."
  # AC4: the bootstrap choice is promoted into server_config on completion.
  # AC5: the choice is changeable later at /admin/config with no redeploy.
  #
  # OIDC: Authorization Code + PKCE (S256) via the live IdP only — NO ROPC, NO cookie
  # forging, NO DB seeding (CLAUDE.md UI standard).
  #
  # These run in the default admin-ui suite (deterministic — no token-timing). The bootstrap
  # scenario self-skips when the shared stack is already bootstrapped (a truly fresh instance
  # only exists pre-global-setup); the promotion logic is unit-covered by
  # bootstrap_refresh_mode_promotion_test.exs. The refresh-mode selectors live on the wizard's
  # claim-mapping step (bootstrap_live.ex), not the OIDC step.
  #
  # Test framework: playwright-bdd + Cucumber (admin-ui project).
  # Step definitions: e2e/step-definitions/admin/oidc-refresh-mode.steps.ts

  Background:
    Given the Nebu stack is running

  @oidc-refresh-mode
  Scenario: Bootstrap wizard shows both refresh-mode selectors with the Dex caveat
    Given a fresh, un-bootstrapped Nebu instance
    When the operator reaches the refresh-mode step of the bootstrap wizard
    Then a Matrix refresh-mode selector offering "offline" and "online" is shown
    And an admin refresh-mode selector offering "offline" and "online" is shown
    And the Matrix mode is preselected to "offline"
    And the admin mode is preselected to "online"
    And the hint explains that Dex issues a refresh token only with offline_access

  @oidc-refresh-mode
  Scenario: Admin config page lets an operator change both refresh modes at runtime
    Given the operator is logged in to the admin UI
    When the operator opens the configuration page
    Then a Matrix refresh-mode selector offering "offline" and "online" is shown
    And an admin refresh-mode selector offering "offline" and "online" is shown
    And the hint explains that Dex issues a refresh token only with offline_access
    When the operator sets the admin refresh mode to "offline"
    Then the admin refresh mode is persisted as "offline"
