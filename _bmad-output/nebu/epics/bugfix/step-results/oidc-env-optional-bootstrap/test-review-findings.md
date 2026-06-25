# Test Review Findings — oidc-env-optional-bootstrap

Date: 2026-06-24

## MAJOR Findings (4)

**MAJOR-1 — AC1 tautological test (oidc_optional_env_test.exs)**
The AC1 test only calls `Application.delete_env` and asserts nil — trivially passes in :test mode regardless of the `runtime.exs` raise. Zero meaningful coverage for the actual `|| raise(...)` removal.
Fix: Add a shell-level smoke test that runs `MIX_ENV=prod` without `NEBU_OIDC_ISSUER` and asserts exit 0.

**MAJOR-2 — AC label mismatch in oidc_optional_env_test.exs**
Describe block at line 209 is labelled "AC3" but tests OidcPlug fail-closed behavior — which is the negative case of AC2 (not story AC3 = Bootstrap stores audience). Breaks traceability at epic close.
Fix: Relabel to AC2 negative path.

**MAJOR-3 — Missing fail-closed test: oidc_config_source seam entirely absent**
No test for the case where neither the seam nor Application env provides issuer/audience — e.g. during bootstrap before server_config is populated. If OidcPlug crashes rather than returning 401, no test catches it.
Fix: Add one test case with `Application.delete_env(:nebu_http, :oidc_config_source)`.

**MAJOR-4 — AC4 E2E scenarios never execute in CI**
Self-skip on missing env vars means all AC4 locked-field scenarios skip in standard `make test-integration`. Needs dedicated Compose profile with `NEBU_OIDC_ISSUER` pre-set.
Fix: Add `make test-e2e-env-locked` Compose override target, OR accept and create follow-up story.

## MINOR Findings (3)

MINOR-1: Empty-draft no-overwrite test has no corresponding AC — add annotation.
MINOR-2: JwksCache.refresh/1 is overspecified vs AC5 — mark as design contract test.
MINOR-3: Informational, no action.
