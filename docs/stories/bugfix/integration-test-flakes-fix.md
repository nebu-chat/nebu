---
story: integration-test-flakes-fix
epic: bugfix
status: done
security_review: none
matrix: false
ui: false
---

# Bugfix — flaky / order-dependent integration tests (triage stories A-F and J)

Triage report of the `oauth-pages-redesign` epic (19 full `make test-integration` runs): most red tests in the full runs are test defects (shared state, order, timing),
not product defects. Test-only change under `server/test` plus the Makefile test target; `server/lib` is not touched.

## Problem

1. (A) `LogsLive.WarRoomTest` interpolates a raw 16-byte uuid binary into a URL: the route 404s for path-unsafe bytes, the 404 message is invalid UTF-8 and
   aborts the ExUnit CLI formatter (run ends without a summary); for `?`/`#` bytes the page mounts without the session and `Floki.text(nil)` raises.
2. (B) `enable_rate_limit/0` of `to_device_oauth_test_support.exs` resets the limiter (frozen clock `1_000_000`) before `put_env_restoring`, so on_exit (LIFO) puts the frozen
   clock back: no per-IP bucket refills for the rest of the run, later suites get 429.
3. (C) `ModerationTestSupport.tick/0` waits on the globally newest event with 300 x 1 ms sleeps and returns `:timeout` under load (about 12 modules match `:ok = tick()`).
4. (D) Cleanup by `DELETE FROM server_config` / `audit_log` deletes nothing (FORCE row level security, no DELETE policy): values leak to later tests and the live stack.
5. (E) Admin LiveView suites need `server_config.bootstrap_completed = 'true'`, which only an earlier test sets.
6. (F) Tests assert counts / first pages of shared tables (`list_users(500)`, war room list, room names reused on a reused DB, Oban job timing, single-active war room session,
   long transaction timeout).
7. (J) Perf-budget / throughput tests (`RegressionSyncLoadTest`, `MemberSliceGateTest` throughput) fail on slow hosts and run in `make test-integration`.

## Acceptance criteria

```gherkin
Scenario: A war room detail URL is built from the textual uuid (A)
  Given a war room session row
  When the test requests its detail page
  Then the id in the URL is the textual uuid (Ecto.UUID.load!), never raw bytes
  And a missing meta panel fails the test with a readable message instead of Floki.text(nil)

Scenario: enable_rate_limit/0 restores the clock seam exactly (B)
  Given a test that called enable_rate_limit/0
  When it has finished
  Then :rate_limit_clock_fn is the value it had before the test (unset), and the bucket table is empty

Scenario: tick/0 waits for the wall clock to pass the newest event, with a time budget (C)
  Given events stamped ahead of the wall clock
  When tick/0 is called
  Then it returns :ok once the wall clock is past the newest event ts, within a seconds-scale deadline, and flunks with the gap in ms otherwise

Scenario: Test cleanup really restores server_config and audit state (D)
  Given tests that write server_config keys or audit rows
  When they clean up
  Then the previous value is restored (upsert to the neutral value / privileged sql), not a silently ineffective DELETE

Scenario: Admin LiveView suites set their own bootstrap precondition (E)
  Given a fresh database
  When TraceMapNodeControlsTest, LogsLive.WarRoomTest or LayoutsWarRoomIndicatorTest run alone
  Then they do not redirect to /admin/bootstrap

Scenario: Listing and count assertions are independent of other rows (F)
  Given a database with thousands of users, sessions, events and log rows from other tests and the live stack
  When the listing / count tests run
  Then they look up their own rows (search / own ids / future-dated seeds) instead of assuming a first page or exact counts

Scenario: Perf-budget tests are an opt-in target (J)
  When make test-integration runs
  Then tests tagged :perf are excluded
  And make test-perf runs exactly those tests (same container, same stack)
```

## Out of scope

G (`RoomsFallbackNameTest`, feature not implemented, stays red), H (DB error on token lookup answered with 401), I (`/sync` range-scan row bound): product follow-up stories.

## Notes

- No `server/lib` change, no migration. A test-only change: the "failing test first" of each item is the reproduction of its defect (isolation runs).
