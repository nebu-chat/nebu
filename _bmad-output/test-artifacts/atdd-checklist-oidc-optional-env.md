---
stepsCompleted:
  - step-01-preflight-and-context
  - step-02-generation-mode
  - step-03-test-strategy
  - step-04-generate-tests
  - step-04a-api-tests
  - step-04b-e2e-tests
  - step-05-validate-and-complete
lastStep: step-05-validate-and-complete
lastSaved: '2026-06-24'
storyId: oidc-optional-env
storyKey: oidc-optional-env
storyFile: docs/stories/room-names/oidc-optional-env.md
atddChecklistPath: _bmad-output/test-artifacts/atdd-checklist-oidc-optional-env.md
generatedTestFiles:
  - server/test/nebu/web/oidc_optional_env_test.exs
  - server/test/nebu/admin/bootstrap_oidc_audience_test.exs
  - e2e/features/admin/bootstrap-env-locked-fields.feature
  - e2e/step-definitions/admin/bootstrap-env-locked-fields.steps.ts
inputDocuments:
  - server/config/runtime.exs
  - server/lib/nebu/web/plugs/oidc_plug.ex
  - server/lib/nebu/admin/bootstrap_live.ex
  - server/lib/nebu/admin/auth.ex
  - server/lib/nebu/web/jwks_cache.ex
  - server/test/nebu/web/oidc_plug_test.exs
  - server/test/nebu/admin/admin_bootstrap_live_test.exs
  - server/test/nebu/admin/bootstrap_oidc_flow_test.exs
  - e2e/features/admin/bootstrap.feature
  - e2e/step-definitions/admin/bootstrap.steps.ts
  - _bmad/tea/config.yaml
---

# ATDD Checklist — oidc-optional-env (bugfix/room-names)

**Story:** Server starts without OIDC env vars; Bootstrap stores/promotes oidc_audience;
Bootstrap fields locked when set via env var; JwksCache nil-issuer guard.

**Date:** 2026-06-24
**Stack:** fullstack (Elixir/OTP + Playwright+Gherkin)
**TDD Phase:** RED ✅ (all target tests failing; 7 failures confirmed)

---

## Test Files Generated

### Backend (ExUnit)

| File | ACs Covered | Status |
|---|---|---|
| `server/test/nebu/web/oidc_optional_env_test.exs` | AC1, AC2, AC3, AC5, AC6 | RED ✅ |
| `server/test/nebu/admin/bootstrap_oidc_audience_test.exs` | AC3 (UI), AC4 | RED ✅ |

### E2E (Playwright+Gherkin)

| File | ACs Covered | Status |
|---|---|---|
| `e2e/features/admin/bootstrap-env-locked-fields.feature` | AC4 (env-lock UI) | RED ✅ |
| `e2e/step-definitions/admin/bootstrap-env-locked-fields.steps.ts` | AC4 (env-lock UI) | RED ✅ |

---

## AC Coverage Matrix

| AC | Description | Test | Type | Failing? |
|---|---|---|---|---|
| AC1 | Server boots without OIDC env vars (no raise) | `OidcOptionalEnvTest` AC1 describe block | ExUnit | Trivially passes in :test — boot-level raise is in prod/dev guard. Documented as invariant. |
| AC2 | OidcPlug reads issuer/audience from server_config fallback | `OidcOptionalEnvTest` AC2 describe block | ExUnit | ✅ FAILING (`:oidc_config_source` seam not implemented) |
| AC3 (fail-closed) | OidcPlug rejects tokens when neither env nor DB has issuer | `OidcOptionalEnvTest` AC3 describe block | ExUnit | Currently passes (MEDIUM-3 exists); regression guard |
| AC3 (bootstrap) | Bootstrap wizard step 2 collects oidc_audience | `BootstrapOidcAudienceTest` AC3 describe block | ExUnit (LiveView) | ✅ FAILING (field not in form) |
| AC4 (bootstrap promote) | bootstrap_confirm_claim promotes oidc_audience | `BootstrapOidcAudienceTest` AC4 describe block | ExUnit | ✅ FAILING (key not in promote list) |
| AC4 (env-lock UI) | Bootstrap OIDC fields disabled when set via env | `bootstrap-env-locked-fields.feature` | Playwright+Gherkin | ✅ FAILING (step bodies throw RED PHASE) |
| AC5 | JwksCache starts without crashing when issuer is nil | `OidcOptionalEnvTest` AC5 describe block | ExUnit | ✅ FAILING (`refresh/1` not yet on JwksCache) |
| AC6 | Regression: env-var-only deployments unaffected | `OidcOptionalEnvTest` AC6 describe block | ExUnit | Passes (regression guard for implementation) |

---

## Test Run Results (red phase confirmation)

```
Result: 832/839 passed, 2 skipped, 142 excluded
Failed: 7 tests

1. OidcOptionalEnvTest — AC2 (server_config fallback, issuer+audience)
2. OidcOptionalEnvTest — AC2 (server_config fallback, issuer from env + audience from DB)
3. OidcOptionalEnvTest — AC5 (JwksCache.refresh/1 API)
4. BootstrapOidcAudienceTest — AC3 (oidc_audience field in step-2 HTML)
5. BootstrapOidcAudienceTest — AC3 (save_step writes oidc_audience to draft)
6. BootstrapOidcAudienceTest — AC4 (server_config contains oidc_audience after confirm)
7. BootstrapOidcAudienceTest — AC4 (empty draft does not overwrite existing config)
```

---

## Notes for Dev Phase

1. **AC1 (runtime.exs):** Change `raise("NEBU_OIDC_ISSUER is not set")` →
   `System.get_env("NEBU_OIDC_ISSUER")` (no raise). The nil will be handled by OidcPlug's
   DB fallback (AC2) and the fail-closed guard (AC3/MEDIUM-3).

2. **AC2 (OidcPlug fallback):** Add `Nebu.Web.OidcConfig` GenServer/ETS cache. OidcPlug's
   `oidc_issuer/0` and `oidc_audience/0` private functions must check the
   `:oidc_config_source` seam (or call `Nebu.Web.OidcConfig.get/0`) when Application env
   is nil. Cache must be invalidated on server_config writes.

3. **AC3 (BootstrapLive step 2):** Add `oidc_audience` text input to the step-2 HEEx template.
   Update `save_oidc/2` to `put_draft("oidc_audience", audience)`.

4. **AC4 (Auth.do_complete_bootstrap/2):** Add `"oidc_audience"` to the promoted keys list at
   line ~1122 in `server/lib/nebu/admin/auth.ex`.

5. **AC4 (env-lock UI):** `BootstrapLive.mount/3` must read which OIDC env vars are set and
   pass `oidc_env_locked: %{issuer: bool, audience: bool, client_id: bool}` as a socket
   assign. The step-2 template renders `disabled` on locked inputs and shows a
   "(set via env)" label. Add `GET /admin/api/bootstrap/oidc-env-locked` endpoint.

6. **AC5 (JwksCache):** Guard `do_fetch/1` in `init/1` — when issuer is nil, return `{:ok, []}`
   without fetching. Add `def refresh(server \\ __MODULE__)` that sends a `:refresh` message
   and waits for the next `keys/0` call to return the fresh set.
