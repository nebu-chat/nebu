# Test-Review (Step 3, pre-dev gate) — fix-bootstrap-admin-session-identity

Reviewed: `git diff --staged` — two files:
- `server/test/nebu/admin/bootstrap_admin_session_identity_test.exs` (new, 404 lines)
- `server/test/nebu/admin/admin_create_room_test.exs` (modified, +123 lines, new AC3 describe block)

Context: RED-phase ATDD tests, independently confirmed failing for the right reason (8/14 RED,
6/14 intentional GREEN — see atdd-summary.md). Not re-flagging "tests fail" as an issue.

## AC coverage check

| AC | Covered? | Test(s) |
|---|---|---|
| AC1 | Yes | 3 tests: matrix_user_id present, equals `UserId.from_claims/2`, matches subsequent normal-login |
| AC2 | Yes | 2 tests: preferred_username honoured (RED), sub-fallback baseline (GREEN, correctly labeled "sanity") |
| AC3 | Yes | 2 tests in admin_create_room_test.exs: bug repro (RED) + post-fix-shape contrast (GREEN) |
| AC4 | Yes | 1 test: sub/email/admin preserved |
| session_exp pin (non-AC, flagged during grounding) | Yes | 2 tests: near-term exp floors (RED), no-exp default unchanged (GREEN) |
| cache-timing edge (non-AC, flagged during grounding) | Yes | 1 test: non-default oidc_user_id_claim honoured in same flow (RED) |

Every AC has at least one test. No gaps.

## AC3 real-path verification (checklist item: does the test exercise the REAL pipeline or take a
shortcut that could pass even if routing were broken?)

Verified by reading `server/lib/nebu/admin/rooms_controller.ex`:
- `create/2` action (line 86): `actor = actor_id(conn)` — computed from `conn.assigns[:current_user]`
  (i.e., whatever the real session/plug pipeline produced), THEN passed to `do_create_room/2`.
- `do_create_room/2` (line 468): checks the `:admin_room_creator` seam only as the FINAL step,
  after `actor_id/1` has already run. The seam replaces only the Matrix room-creation call (avoids
  needing a live Matrix room process in a unit test) — it does NOT replace `actor_id/1` or any
  session/routing logic.

The new AC3 test drives the actual `Nebu.Admin.Endpoint.call/2` → Router → `RoomsController.create/2`
with a real Plug session (via `Nebu.Admin.Endpoint.admin_session/2` + `fetch_session/1` +
`put_session/3`, all real Plug/Endpoint APIs — confirmed via grep against
`server/lib/nebu/admin/endpoint.ex:77`). The `assert_receive {:create_room_called, actor_id}`
captures the value `actor_id/1` genuinely computed. **This is a sound, non-shortcut test** — it
would correctly fail if `actor_id/1`, the router, or the session pipeline were broken, not just if
the seam wiring were broken.

## Seam/API existence check (checklist item: hallucinated APIs?)

All seams referenced were verified to exist via direct grep/read against production code:
- `Nebu.Matrix.OidcClaimCache.reset_for_test/0` — exists (`oidc_claim_cache.ex:154-158`)
- `Application.put_env(:matrix, :oidc_claim_reader, ...)` — exists, read at
  `oidc_claim_cache.ex:221`
- `Application.get_env(:nebu_http, :admin_room_creator)` — exists (`rooms_controller.ex:469`)
- `Nebu.Admin.Endpoint.admin_session/2` — exists (`endpoint.ex:77`)
- `:admin_bootstrap_store` dispatcher shape (`:load_draft`/`:put_draft`/`:clear_draft`/
  `:put_config`/`:bootstrap_completed?`) — matches the dispatcher contract used throughout
  `auth.ex` (`bootstrap_store/2` call sites)

No hallucinated APIs found.

## Crash/restart requirement

Not applicable, correctly. This story touches a stateless HTTP request handler
(`bootstrap_confirm_claim/2`) over a signed session + DB-backed draft/config reads/writes — no
GenServer state of its own is introduced or modified. The `OidcClaimCache` GenServer's own
crash/restart semantics are pre-existing and out of scope (covered elsewhere, presumably
`oidc_claim_cache_test.exs`). The new test file's moduledoc states this reasoning explicitly and
it is accurate.

## UI / Matrix-spec-error-code requirements

- `ui:false` — no Playwright requirement. Confirmed no admin LiveView/template changes in the diff.
- Not a new Matrix endpoint or spec-facing behavior — this is an internal admin-session-shape bug.
  AC3's test does assert both the HTTP redirect (302 to `/admin/rooms/...`) AND the downstream
  `actor_id` value — covers both the request-completes-successfully path and the actual regression
  assertion, not just one.

## Hard waits / non-determinism / brittleness

None found. `assert_receive {:create_room_called, actor_id}, 500` uses a bounded timeout on an
explicit message (not a hard `Process.sleep`), which is the standard, non-flaky ExUnit pattern for
async message assertions. No time-based sleeps, no brittle DOM/CSS selectors (no UI in this diff),
no reliance on real wall-clock timing beyond the `session_exp` arithmetic tests, which use
`System.system_time(:second)` bracketing (`before`/`after` bounds) rather than exact-equality on a
live clock — sound.

## Findings

**MAJOR: none.**

**MINOR:**
1. `admin_create_room_test.exs`'s new AC3 tests hardcode a literal
   `"01923abf-raw-oidc-sub-value"` as the fixture `sub`, then assert
   `Nebu.Matrix.UserId.valid?(actor_id)` on the (buggy) result. Since that literal happens to
   already satisfy the Matrix user_id localpart grammar after sanitization, the `valid?/1`
   assertion doesn't add discriminating power beyond the `refute actor_id == sub-value` check —
   it's a nice-to-have belt-and-suspenders assertion, not a gap, but worth a one-line comment
   noting why it's included (defends against a *different* future regression: a broken sanitizer
   producing an ill-formed id) so a future reader doesn't mistake it for redundant.

**INFO:**
1. The `sanitize_expected/1` helper in `bootstrap_admin_session_identity_test.exs` duplicates
   `Nebu.Matrix.UserId`'s private sanitization regex as a second copy for the cache-timing test's
   expected value. This is a reasonable, explicitly-documented choice (comment says "mirrors
   UserId's own sanitize/1 ... without duplicating UserId's regex verbatim as a magic string" —
   though it does in fact duplicate the regex) — low risk since `UserId.sanitize/1` is stable and
   this is test-only code, but flagging for awareness: if `UserId`'s sanitization rules ever
   change, this test helper must be updated in lockstep or it will silently start asserting the
   OLD sanitization behavior.
2. Two background ATDD agent runs converged on writing the same test content concurrently during
   this pipeline run (process artifact, documented in atdd-summary.md) — no duplicate/conflicting
   code landed in the final file state; purely a pipeline-orchestration note, not a test-quality
   issue.

## Verdict

**CLEAN — 0 MAJOR.** 1 MINOR (cosmetic comment suggestion, does not block dev-story), 2 INFO
(awareness notes). Proceeding to Step 4 (dev-story) without blocking. The MINOR finding can be
folded into the dev-story pass or left as-is; it does not require its own fix cycle since it's a
comment/documentation nit on an already-correct assertion, not a coverage or correctness gap.
