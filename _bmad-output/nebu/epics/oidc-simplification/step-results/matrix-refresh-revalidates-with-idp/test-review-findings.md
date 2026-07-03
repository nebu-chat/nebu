# Test Review Report — server/test/nebu/matrix/login_refresh_test.exs (staged diff)

**Scope confirmed:** `git diff --staged` shows exactly one file, +348/-0 lines — purely additive, the 14 pre-existing tests are byte-for-byte unchanged. 7 new tests target AC1–AC4/AC6 of `matrix-refresh-revalidates-with-idp`.

## AC coverage

| AC | Covered? | Test(s) |
|---|---|---|
| AC1 (contact IdP token endpoint before rotation) | Yes | seam receives the **decrypted plaintext** OIDC RT, proving decrypt-then-redeem happens before rotation |
| AC2 (fail-closed on IdP rejection) | Yes | rejection → 401 + old AT invalidated + retry still 401; second test asserts `soft_logout: true` parity |
| AC2 (deprovisioning via fresh id_token) | Yes | flips `is_active` directly (isolates the NEW re-check logic from the old hard-delete `deactivate_user` path) |
| AC3 (lifetime from fresh id_token, same function as login) | Yes | short 30s-out fresh `exp` via seam → asserts `expires_in_ms <= 31_000` |
| AC4 (OIDC RT rotation persisted / carried over) | Yes | new RT → stored encrypted column changes/decrypts to new value; nil RT → encrypted column unchanged |
| AC5 (shared exchange function) | N/A — architecture-only, correctly not tested at HTTP level (INFO, not a gap) |
| AC6 (regression: happy path + existing tests green) | Yes | full happy-path e2e test + all pre-existing 14 tests untouched |

No AC is missing test coverage. MAJOR-clean.

## Hard waits / non-determinism / brittle selectors

None found. No `Process.sleep`/`:timer.sleep` anywhere. Time-based conditions made deterministic via direct DB manipulation or injected `exp` claims. `send`/`assert_received` used correctly (seam fun runs synchronously in-process). No CSS/DOM selectors (N/A, HTTP-level suite).

## GenServer crash/restart

N/A — `matrix_sessions` is a Postgres table via inline SQL, not GenServer state.

## UI / Playwright

N/A — story is not `ui: true`.

## Matrix spec error codes / HTTP status codes

Good coverage beyond happy path: 401 `M_UNKNOWN_TOKEN` for unknown/used RT, rotated-then-used old RT, IdP rejection (new), deprovisioning (new), deactivated-user RT reuse. `soft_logout: true` parity explicitly asserted for the new IdP-rejection path. 400 `M_MISSING_PARAM` pre-existing, correctly not duplicated.

## Seam sanity-check — `:matrix_oidc_refresh_override` vs. existing `:admin_oidc_refresh_override`

Verified against `admin/auth.ex` `exchange_refresh_token/1` (~239-260): identical 1-arity shape (decrypted RT in, `{:ok, claims, new_rt}` or `{:error, reason}` out). Seam name does not exist in `server/lib/` today (grep-confirmed) — consistent with RED-phase framing; explicitly specified in the story's AC5 text, not hallucinated. AC3's "same function" requirement is checkable against real code (`session_expires_at/1`, http_public.ex:467-478). AC4's storage requirement targets `MatrixSessionStore.rotate_tokens/1`'s already-existing but never-populated `:new_oidc_refresh_token` param.

## Overall classification

**0 MAJOR, 0 MINOR.** All findings are INFO/confirmatory:
- INFO: AC5 correctly has no dedicated test (by design) — verified at code-review/architecture time only.
- INFO: `soft_logout: true` assertion on IdP-rejection path is a nice spec-parity addition beyond AC2's literal wording.
- INFO: seam name/shape confirmed as a faithful, implementable mirror of the existing admin/auth.ex pattern, not hallucinated.

**Verdict: CLEAN.**
