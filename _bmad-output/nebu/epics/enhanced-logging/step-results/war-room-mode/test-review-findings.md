# Test Quality Review — war-room-mode (RED-phase ATDD)

## Action taken during review
MAJOR-1 (missing WarRoom GenServer crash/restart + genuine boot-time-load coverage)
FIXED DIRECTLY — added crash/restart describe block to war_room_test.exs (mirrors
Writer's own AC6 crash/restart pattern), fixed a BEAM atom-length compile error from
an overly long test description in the process. Re-verified RED against real
Postgres: war_room_test.exs 14/14 fail correctly; log_store_test.exs and
logs_live_test.exs show zero regressions to pre-existing tests. e2e feature verified
via `npx bddgen` (steps resolve, no missing/mismatched step text).

## AC coverage: AC1-AC12 all covered (see table in full agent report — carried in
pipeline-state.yaml log). AC2's DB-level partial-unique-index backstop explicitly
tested independent of the app-level check. AC4's redaction-under-war-room
specifically regression-tested (not just baseline assumption).

## Remaining findings (not auto-fixed — no design decision needed to defer)
- MINOR-1: no negative test for AC3 required-param omission (error shape not yet
  specified in design-decisions.md — dev-story should pick one, test can follow).
- MINOR-2: AC8's numeric enforcement (max_entries<=100/max_duration_s<=300 for
  /sync scope) has no test — only the warning text is asserted. Consistent with
  sibling admin-logs-retention-settings's own client-side-only precedent; flagged
  for dev-story to confirm this is deliberately advisory-only, not a hard invariant.
- MINOR-3: duration-timer test uses Process.sleep(1500) instead of a deterministic
  sync — reasonable margin, low flake risk, not auto-fixed (would require
  hard-coding an internal message shape before the module exists).
- INFO-1: no direct test that an HTTP response stays 200 when WarRoom is
  unavailable/crashed mid-request — indirectly covered by existing tests that call
  Handler.log/2 without WarRoom running at all (any crash-on-absence bug would
  already break many pre-existing tests). Worth a dedicated resilience test in a
  future cycle.
- INFO-2: Playwright layer has no hard-wait/brittle-selector issues (all
  data-testid + polling expects). Matrix spec surface correctly scoped per
  oracle-context.md (no M_* codes tested, correctly — admin-only feature).

Conclusion: CLEAN to proceed to dev-story (1 MAJOR fixed, MINOR/INFO items are
non-blocking judgment calls consistent with sibling stories' own precedent).
