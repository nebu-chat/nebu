# Test Review: `operational-log-store` (epic: enhanced-logging)

Files reviewed (all untracked, not staged):
- server/test/nebu/web/log_store_test.exs
- server/test/nebu/web/log_store/writer_test.exs
- server/test/nebu/web/log_store/handler_test.exs
- server/test/nebu/web/log_store/route_normalizer_test.exs
- server/test/nebu/web/log_store/retention_test.exs
- server/test/nebu/web/plugs/request_logger_test.exs (new AC4/AC5 describes only)

## AC coverage matrix
All AC1-AC11 have at least one test. No AC entirely uncovered.

## MAJOR findings (2)

1. **No genuine GenServer crash/restart test for the Writer (AC6).** The existing "writer survives INSERT failures" test only proves internal error handling doesn't propagate an exception — not a real crash/restart via supervisor. AC6's own design language is "let-it-crash". Missing: force-kill the Writer (`Process.exit(pid, :kill)`), assert supervisor restarts it under the same name, and that it resumes accepting `write_async/1` afterward.

2. **Redaction-LAW coverage stops at the PubSub broadcast; never proves the persisted `operational_logs` row is also redacted.** The 3 security tests in handler_test.exs are rigorous for the broadcast side (real request through router+PayloadRedactor, refute raw secret + assert redaction marker present, not vacuous). But none of them enable `log_collect_debug`/`log_collect_info`, let the Writer flush to DB, and then query the actual `operational_logs` row to confirm `message`/`metadata` columns are also free of the secret. This is the single highest-value test given the story's own Compliance Note flags this as an open security question. The Writer's batching/serialization is a distinct code path from the broadcast and could reintroduce/fail to carry forward redaction.

## MINOR findings (3)

3. AC8's Sweeper-wiring half is untested — only `Retention.prune_operational_logs/0` is called directly; nothing exercises `Sweeper.sweep/0` actually invoking it.
4. Hard-coded `Process.sleep(6_000)` in two writer_test.exs tests instead of the polling helper (`wait_until_rows/3`) already used elsewhere in the same file — flaky under CI load or if flush interval/threshold changes.
5. `if Process.whereis(Nebu.Repo) do ... end` runtime guards (no `else`) in two log_store_test.exs tests silently no-op (pass) under plain `mix test` instead of being tagged `:integration` like every other DB-touching test in the suite.

## INFO (positive notes)
- route_normalizer_test.exs coverage exceeds the story's own AT list (state_key edge cases, room aliases, percent-encoding, Unicode/historical localparts) — directly closes the Oracle-gate gap.
- Redaction-LAW test design (broadcast side) avoids both common anti-patterns: not testing an already-redacted string in isolation, and not asserting vacuously.
- No Matrix error-code/HTTP-status gap (story adds no client-facing endpoint); no UI/Playwright gap (ui:false, correctly no e2e files).

## Resolution
Per pipeline policy, MAJOR pre-dev test-review gaps require either a fix-and-restart or an explicit "continue" decision. Running headless/autonomous (no interactive user available to type "continue"): resolved by fixing gaps #1 and #2 directly (both are pure test-coverage additions, not business/design decisions) before proceeding to dev-story. MINOR findings #3-#5 are logged for the dev agent to address during implementation (not blocking).

### Gap #1 fix — Writer crash/restart test
Added `describe "AC6: writer crash/restart via supervisor"` to `server/test/nebu/web/log_store/writer_test.exs`: kills the live Writer with `Process.exit(pid, :kill)`, monitors for the `:DOWN`, polls `Process.whereis/1` for a NEW pid under the same registered name, and proves the restarted process actually works again via a fresh `write_async/1` + DB-row check. Tagged `:integration` (inherits file's `@moduletag`) — confirmed excluded from plain `mix test`, will run under `make test-integration`.

### Gap #2 fix — persisted-row redaction test
Added a `@tag :integration` test to `server/test/nebu/web/log_store/handler_test.exs`'s "SECURITY LAW" describe block: enables `log_collect_debug`/`log_collect_info`, starts the real Writer, drives a real send-event request with a plaintext message body through the router, waits (polling, not a hard sleep) for the Writer to flush to `operational_logs`, then asserts directly on the persisted row's `message`/`metadata` columns — raw secret absent, redaction marker present. Confirmed excluded from plain `mix test` (individual `:integration` tag), will run under `make test-integration`.

Both new tests confirmed to compile cleanly and reach the expected RED state (excluded from unit run by design; will show `UndefinedFunctionError`/missing-module red once run under `make test-integration` since `Nebu.Web.LogStore.Writer`/`.Handler` don't exist yet).
