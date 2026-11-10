# test-lint — integration-test-flakes-fix: 7 scenarios, 4 ExUnit tests, 0 e2e files
JUDGE | docs/stories/bugfix/integration-test-flakes-fix.md | cannot map scenario to a test automatically: "A war room detail URL is built from the textual uuid (A)" | check by reading the tests
JUDGE | docs/stories/bugfix/integration-test-flakes-fix.md | cannot map scenario to a test automatically: "enable_rate_limit/0 restores the clock seam exactly (B)" | check by reading the tests
JUDGE | docs/stories/bugfix/integration-test-flakes-fix.md | cannot map scenario to a test automatically: "tick/0 waits for the wall clock to pass the newest event, with a time budget (C)" | check by reading the tests
JUDGE | docs/stories/bugfix/integration-test-flakes-fix.md | cannot map scenario to a test automatically: "Test cleanup really restores server_config and audit state (D)" | check by reading the tests
JUDGE | docs/stories/bugfix/integration-test-flakes-fix.md | cannot map scenario to a test automatically: "Admin LiveView suites set their own bootstrap precondition (E)" | check by reading the tests
JUDGE | docs/stories/bugfix/integration-test-flakes-fix.md | cannot map scenario to a test automatically: "Listing and count assertions are independent of other rows (F)" | check by reading the tests
JUDGE | docs/stories/bugfix/integration-test-flakes-fix.md | cannot map scenario to a test automatically: "Perf-budget tests are an opt-in target (J)" | check by reading the tests

## Manual judgement of the JUDGE items (orchestrator, test-only bugfix)

The seven scenarios are bug reproductions, not new behaviour; the "test" of a scenario is the reproduction run recorded in `repro-evidence.md`:
A: war_room_test.exs:1079 with a forced uuid default (3 modes); B: `rate_limit_helper_restore_test.exs` (red first: ToDevice leak reproduced);
C: `moderation_tick_test.exs` (red first: `MatchError :timeout`); D/E/F: the changed suites run alone on a fresh DB (before: orig copies / triage isolation logs);
J: `make test-perf` selects exactly the :perf tests, `make test-integration` excludes them. Verdict: no gaps.
