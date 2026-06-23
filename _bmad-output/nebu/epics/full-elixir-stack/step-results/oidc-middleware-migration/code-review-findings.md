# Code Review — oidc-middleware-migration (Cycle 1 RE-REVIEW)

VERDICT: CLEAN — all cycle-0 findings resolved, no new MAJOR/CRITICAL, no regressions.

## Cycle-0 findings — resolution status

- **MAJOR-1** (auth bypass): RESOLVED. docker-compose.yml has no active
  `NEBU_OIDC_VALIDATION_DISABLED` key (only explanatory comments). Go's
  `JWTMiddleware` defaults to full verification (`validationDisabled = false`).
  Go stays the OIDC authority until matrix-api-migration wires forwarding.
- **MINOR-1**: RESOLVED. `gateway/internal/middleware/oidc_passthrough_test.go`
  adds white-box tests for `oidcValidationDisabled()` (default-off + env parsing,
  trim/case) and `decodeUnverifiedClaims` (valid 3-seg; 2-seg/garbage/non-base64/
  non-JSON/empty → nil).
- **MINOR-2**: RESOLVED. Feature tagged `@wip`; integration runner filters
  `~@wip` (`gateway/test/integration/main_test.go`). 5 scenarios no longer report
  as passing.
- **MINOR-3**: RESOLVED. `check_exp/1` catch-all `{:error, :missing_exp}` rejects
  tokens with no/non-integer `exp` → M_UNKNOWN_TOKEN; test present.
- **MINOR-4**: RESOLVED. `check_subject/1` requires `is_binary(sub) and sub != ""`,
  else `{:error, :missing_subject}` → M_UNKNOWN_TOKEN; missing-sub + empty-sub
  tests present.
- **MINOR-5**: RESOLVED. `JwksCache.do_fetch/1` returns `{:ok, keys} | :error`;
  `handle_info(:refresh)` keeps `state.keys` on `:error`; retention test with
  deterministic `wait_until` present.
- **MINOR-6**: N/A (info only).

## New findings: none

Minor non-findings (deliberate & correct): `init/1` falls back to `[]` on
first-fetch failure (no last-known-good exists yet); `http_fetch` treats an
unconfigured `oidc_jwks_uri` as `{:ok, []}` (distinguishes "nothing to fetch"
from "fetch failed").

## Unit gates
build OK · go middleware ok · nebu_http 23 passed (4 new) · elixir umbrella exit 0 (--warnings-as-errors)
