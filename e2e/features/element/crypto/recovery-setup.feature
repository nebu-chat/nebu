Feature: Element cross-signing / recovery setup completes without error
  As the Element e2e suite
  I want a Gherkin scenario that drives Element's recovery / cross-signing bootstrap
  to completion (not cancel it)
  So that the client-crypto-setup fix is proven in a real browser — Element completes
  setup without "Schlüssel können nicht eingerichtet werden" / "could not set up keys".

  # Story: element-cross-signing-recovery-scenario (epic e2e-test-rehab).
  #
  # Existing login steps deliberately SKIP/CANCEL the recovery/verification screen
  # (assertNoKeySetupError + dismiss). This scenario is the inverse: it walks the
  # "Set up recovery" flow THROUGH to completion and asserts success — the durable
  # ATDD coverage for client-crypto-setup.
  #
  # OIDC login is Authorization Code + PKCE via Dex (fixtures/dex-auth.ts
  # loginViaOidcBrowser) — NO ROPC / grant_type=password, NO cookie forging, NO DB
  # seeding (CLAUDE.md project E2E standard).
  #
  # AC3 hardening: after the UI walk, the captured token sidecar (getApiSession) is
  # used to POST /keys/query and assert the server echoes the cross-signing maps
  # (master_keys / self_signing_keys / user_signing_keys). This API read-back is the
  # version-stable proof even when the recovery-UI selectors drift between Element
  # releases — the recovery-UI walk is authored from Element 1.12.15 knowledge.
  #
  # @ci — full green run is delegated to amd64 CI (sibling story
  # e2e-browser-ci-and-dex-reliability added the element-web CI job + env-tunable
  # timeouts). Local Dex is arm64-emulated and slow; the recovery-UI selectors are
  # refined in CI. Run locally with: cd e2e && npx playwright test --project=element-web
  # --grep @recovery-setup

  Background:
    Given the Nebu stack is running
    And alex has no cached session

  @recovery-setup @ci
  Scenario: alex sets up recovery to completion without a key-setup error
    Given alex is logged in to Element Web via Dex SSO with "alex@example.com"
    When alex opens Encryption settings and starts "Set up recovery"
    And alex walks the recovery-key generation dialog to completion
    Then recovery setup succeeds without a key-setup error
    And the server echoes alex's cross-signing keys on /keys/query
