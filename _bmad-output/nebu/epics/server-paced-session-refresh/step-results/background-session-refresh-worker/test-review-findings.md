# Pre-dev Test Review — refresh_worker_test.exs

Gate status: CLEAN (0 MAJOR). All AC1-AC7 + both Oracle spec-parity requirements covered with genuine black-box integration tests. AC8 is design-only per story text.

## MINOR findings (non-blocking, recommended for dev-story to address if natural)

1. No crash/restart test for RefreshWorker mirroring `session_expiry_worker_test.exs` (codebase consistency; worker is stateless so not correctness-critical).
2. No decrypt-failure test for the stored `oidc_refresh_token` (fail-closed + continue iterating other rows) — pre-existing gap pattern also in `login_refresh_test.exs`.
3. No concurrent-refresh idempotency test for the ADR-020 cluster-safety race (two nodes racing to refresh same row).

## Positive notes
- AC5 multi-cycle test genuinely loops 3 cycles, recomputes cap fresh each iteration, threads rotated access_token forward correctly.
- AC3 TOCTOU test forces the race deterministically (delete happens inside the `:matrix_oidc_refresh_override` seam callback itself, not via sleep/timing).
- AC7 test genuinely decouples from the worker's own timer (never sends `:refresh` to the worker under test).
- Tests are true black-box integration tests (real SSO login, real DB rows, real HTTP assertions) — not tautological.

Verdict: not blocked. Proceed to dev-story.
