# Test Review Report — admin-liveview-session-refresh (RED-phase ATDD)

**Files reviewed:**
- server/test/nebu/admin/admin_token_refresh_test.exs
- server/test/nebu/admin/admin_keepalive_test.exs

## AC coverage matrix

| AC | Test(s) | Verdict |
|---|---|---|
| AC1 (RED repro: idle LiveView dies at id_token.exp despite valid RT) | admin_token_refresh_test.exs:420-500 | Covered |
| AC2 (idle LiveView survives via keepalive-driven refresh) | admin_token_refresh_test.exs:502-555 | Covered |
| AC3 (recommendation, not independently testable) | Exercised indirectly by AC4's tests | N/A as expected — not flagged |
| AC4 (keepalive minimal + secure + auth-gated + no new business logic) | admin_keepalive_test.exs — all 4 tests (lines 99-224) | Covered |
| AC5 (HTTP-path regression unchanged) | Pre-existing AC3/AC5/AC6 tests, untouched | Covered |

All five ACs have at least one test.

## Findings

**MINOR-1** — AC1's "advance the clock" technique re-invokes `on_mount/4` directly with a mutated
session map rather than driving a real running LiveView process lifecycle. Documented rationale
present in test comments; faithful proxy but doesn't prove a *running* socket observes expiry
mid-session. Kept MINOR only to flag for future readers.

**MINOR-2** — Hand-built partial `%Phoenix.LiveView.Socket{endpoint: ...}` struct
(admin_token_refresh_test.exs:471). Low risk today; latent fragility if `on_mount` starts reading
other socket fields. Recommend a clarifying comment.

**INFO (8)** — module attribute duplication (`@refresh_window`) test/prod; intentional
double-assertion pattern in AC1 test; no hard waits/non-deterministic assertions; no brittle
selectors; GenServer crash/restart correctly scoped N/A (JwksCache not touched, refresh state lives
in signed session cookie); UI-adjacent auth-gate endpoint fully covered (real route, real pipeline,
non-admin rejection, no-PII response); good edge-case coverage (revoked RT, downgraded claim,
online-mode-no-RT); legitimate session-seam usage, no cookie forging.

## Summary
- MAJOR: 0
- MINOR: 2 (test maintainability only, not coverage gaps)
- INFO: 8 (mostly positive confirmations)

**Verdict: CLEAN — proceed to dev-story.** No blocking gaps. Well-constructed RED-phase ATDD suite.
