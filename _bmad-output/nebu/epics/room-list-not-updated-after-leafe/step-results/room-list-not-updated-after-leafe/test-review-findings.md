## Test Quality Review — bugfix/room-list-not-updated-after-leave

**Verdict: PASS** — 0 MAJOR, 3 MINOR, 3 INFO. All 5 ACs covered.

### MINOR Findings
1. AC4+AC5 covered only at ExUnit level (no Gherkin) — intentional, documented trade-off
2. Hard waits `time.Sleep(500ms)` in retry loops — condition-based, bounded, acceptable
3. `http.NewRequest` reuse across retries — no current impact (GET, no body)

### INFO Findings
1. `wait_for_registry` 10ms×20 polling — accepted Horde pattern
2. AC5 second test minimal assertion — intent should be commented
3. No negative-path Gherkin (M_FORBIDDEN, M_NOT_FOUND) — out of scope for bugfix
