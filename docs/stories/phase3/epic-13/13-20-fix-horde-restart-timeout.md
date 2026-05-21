---
status: done
epic: 13
story: 20
security_review: not-needed
matrix: false
ui: false
atdd: not-applicable
---

# Story 13.20: Fix test-unit-elixir - Horde restart timeout too tight under CI load

Status: done

## Story

As a developer running `make test-unit-elixir`,
I want `PowerLevelEnforcementTest - crash/restart` to pass reliably,
so that the CI pipeline does not fail on a Horde restart race.

**Size:** XS

---

## Background & Motivation

`power_level_enforcement_test.exs` crash/restart test kills the room GenServer and waits for
Horde to restart it via `await_new_pid/2`. The helper polls `lookup_room` 500 times × 10ms = 5000ms.

Under CI load (`max_cases: 8`, all apps running tests concurrently), Horde's restart can exceed
5000ms, causing the test to flunk with:

```
Horde did not restart room crash-pl-6115 within 5000ms
```

This is not a logic bug - the restart happens, just slightly too late for the timeout.

**Fix:** double the poll count: 500 → 1000 iterations (5000ms → 10000ms). The poll interval
(10ms) stays the same; only the ceiling increases. ExUnit's default timeout is 60s so there
is no risk of hitting the module-level timeout.

---

## Acceptance Criteria

**AC1 - `await_new_pid` polls up to 10000ms:**
Given `power_level_enforcement_test.exs`,
When `await_new_pid/2` iterates through all retries,
Then the flunk message reads "within 10000ms" and the loop runs 1000 iterations.

**AC2 - `make test-unit-elixir` passes:**
Given the updated test,
When `make test-unit-elixir` is run,
Then exit code is 0 with no Horde timeout failures.

---

## Acceptance Tests

The failing test IS the regression: `PowerLevelEnforcementTest` line 459, seen in CI with
`max_cases: 8`. No new test file needed.
