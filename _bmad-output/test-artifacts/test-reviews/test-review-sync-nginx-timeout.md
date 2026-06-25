---
stepsCompleted: ['step-01-load-context', 'step-02-discover-tests', 'step-03-quality-evaluation', 'step-03f-aggregate-scores']
lastStep: 'step-03f-aggregate-scores'
lastSaved: '2026-06-25'
story: 'sync-nginx-timeout'
epic: 'element-compat'
reviewer: 'Master Test Architect (TEA)'
verdict: 'CONCERNS — 2 MAJOR findings must be resolved before dev closes the story'
---

# Test Quality Review — `sync-nginx-timeout`

**Story**: Fix /sync 504 Gateway Timeout  
**File reviewed**: `server/test/nebu/matrix/matrix_client_compat_test.exs`  
**Review date**: 2026-06-25  
**Verdict**: CONCERNS — 2 MAJOR findings, 2 MINOR, 2 INFO

---

## Coverage Map (AC → Test)

| AC | Description | Test(s) present | Coverage |
|---|---|---|---|
| AC1 | Max long-poll cap reduced 30 000 → 25 000 ms | 4 AC4 unit tests (indirectly) + server.ex cap (NOT tested) | PARTIAL — see MAJOR-1 |
| AC2 | `get_initial_sync` uses `Task.async_stream` | 1 integration test (shape only) | INSUFFICIENT — see MAJOR-2 |
| AC3 | Short-timeout long-poll returns < 1 500 ms | 1 integration timing test | ADEQUATE with caveats — see MINOR-1 |
| AC4 | `parse_timeout/1` caps at 25 000 ms | 4 pure unit tests | ADEQUATE |

---

## Findings

### MAJOR-1 — AC1 cap is only half-tested: the `server.ex` clamp is not covered

**Severity**: MAJOR — blocks story completion  
**AC**: AC1

**Evidence**: The story dev notes explicitly state:

> "The long-poll timeout cap lives in TWO places: `server.ex` line ~2365 (`timeout_ms |> max(0) |> min(30_000)`) and `protected.ex` line ~1102 (`v |> max(0) |> min(30_000)`). Both must change to `min(25_000)`."

Current production code confirms both clamps exist at their stated 30 000 values:
- `server/lib/nebu/web/router/protected.ex:1102` — `v |> max(0) |> min(30_000)` (the `parse_timeout/1` function)
- `server/lib/nebu/matrix/event_dispatcher/server.ex:2365` — `timeout_ms = request.timeout_ms |> max(0) |> min(30_000)` (inside `get_sync_delta`)

The AC4 unit tests only exercise `Protected.parse_timeout/1` (the HTTP-layer clamp). If a dev changes `protected.ex` but forgets `server.ex`, all four AC4 unit tests pass — yet the server still holds for up to 30 000 ms and the 504 problem is not fixed.

**Required fix**: Add an integration test that explicitly passes `timeout=26000` (or any value > 25 000) and verifies the sync returns within ≤ 26 500 ms (i.e., well before 30 000 ms). This directly observes the server-internal clamp in `get_sync_delta` and would catch a missed change in `server.ex`.

Alternatively, if the dev notes' recommendation is to keep the `server.ex` clamp as a belt-and-suspenders guard after `parse_timeout` already caps at 25 000 (so the value passed to `get_sync_delta` is always ≤ 25 000), document that reasoning explicitly and add a comment-level assertion in the test for AC4 that references the second cap site.

---

### MAJOR-2 — AC2 integration test verifies shape, not parallelism

**Severity**: MAJOR — blocks story completion  
**AC**: AC2

**Evidence**: The current AC2 test:

```elixir
test "initial sync (no since) returns 200 with next_batch and rooms map (AC2)", %{token: token} do
  _room1 = create_sync_room(token, "sync-room-A")
  _room2 = create_sync_room(token, "sync-room-B")
  _room3 = create_sync_room(token, "sync-room-C")

  conn = call(:get, "/_matrix/client/v3/sync", nil, auth(token))
  # … shape assertions only
end
```

This test would pass equally well against the current sequential `Enum.flat_map` implementation (which is intentionally NOT yet changed). The test verifies correctness of the response shape but provides no evidence that parallelism was actually introduced — which is the entire architectural change of AC2.

The test cannot detect a bug where the dev forgets `Task.async_stream` and leaves `Enum.flat_map`. It also cannot detect a bug where `Task.async_stream` is introduced with a `max_concurrency: 1` (effectively sequential).

**Why this matters beyond style**: The BMAD TDD standard for this project says: "A failing test written first forces the correct design." The parallelism change is the design — the test must fail to expose a correct-design requirement. A shape-only test allows sequential implementations to remain green forever.

**Required fix**: The test must verify that concurrent room fetching actually occurs. Two acceptable approaches:

**Option A — Timing gate** (sufficient given the story goal is timeout prevention):

```elixir
test "initial sync parallelises room fetching — returns all rooms quickly (AC2)", %{token: token} do
  # Create enough rooms that sequential fetching would be measurably slower.
  # 5 rooms × ~100ms each (GenServer + DB call) = ~500ms sequential vs ~100ms parallel.
  # Use at least 5 rooms, assert completion well within a sequential upper bound.
  room_ids = Enum.map(1..5, fn i -> create_sync_room(token, "sync-room-#{i}") end)

  t0 = System.monotonic_time(:millisecond)
  conn = call(:get, "/_matrix/client/v3/sync", nil, auth(token))
  elapsed = System.monotonic_time(:millisecond) - t0

  assert conn.status == 200
  body = json(conn)
  assert length(Map.keys(body["rooms"]["join"])) >= 5
  # Shape assertions...
  # Timing assertion: if sequential, 5 rooms × typical GenServer call should take > 500ms.
  # Parallel with max_concurrency: 10 should complete all in ~1 slowest room's time.
  # This is environment-dependent — see MINOR-1 for the CI flakiness caveat.
  assert elapsed < 2000, "Initial sync with 5 rooms took #{elapsed}ms — parallel fetch expected to be much faster"
end
```

**Option B — Telemetry / process count** (more robust but higher implementation cost):

Instrument `get_initial_sync` with `:telemetry` events that emit the concurrency level, and assert in the test that > 1 task was active simultaneously. This is the gold standard but requires telemetry instrumentation that does not currently exist.

For this story, Option A (timing gate with ≥ 5 rooms and a reasonable upper bound) is the minimum acceptable approach. The current 3-room test with no timing assertion does not satisfy AC2 in a way that could catch a regression.

---

### MINOR-1 — AC3 timing assertion (`elapsed < 1500`) is fragile on overloaded CI hosts

**Severity**: MINOR  
**AC**: AC3

**Evidence**: The AC3 test measures wall-clock time from `System.monotonic_time/1`. The assertion `elapsed < 1500` (giving 1000ms of headroom over the 500ms timeout) is reasonable on a dedicated machine but may flap on an overloaded shared CI container where:

- The BEAM scheduler itself may not wake the test process for 200–400ms after the process unblocks.
- The integration stack (Bandit + PostgreSQL + OTP full tree) may be competing for CPU during the same test run.

The story doc's own threshold (`< 1.5 seconds` for a `timeout=500` poll) already bakes in a 3× safety margin, which is appropriate. The issue is that there is no comment documenting the chosen margin, making it look like an arbitrary number to future readers.

**Required fix (MINOR)**: Add an inline comment explaining the margin:

```elixir
# timeout=500 → server holds at most 500ms. We allow 3× headroom (1500ms) for
# BEAM scheduler overhead and CI host jitter. If this flaps, investigate CI
# host load or increase to 2500ms — NOT the implementation.
assert elapsed < 1500, "sync with timeout=500 took #{elapsed}ms — should be < 1500ms"
```

Also consider whether the test should run with `async: false` isolation (it is already in the integration describe block which uses `@describetag :integration` — confirm that the ExUnit configuration for `:integration` tests disables async, as the timing assertion is sensitive to parallel test pollution).

---

### MINOR-2 — `parse_timeout/1` visibility change is a mandatory implementation prerequisite not verified by tests

**Severity**: MINOR  
**AC**: AC4

**Evidence**: AC4 unit tests call `Protected.parse_timeout("25000")` — which requires `parse_timeout/1` to be promoted from `defp` to `def`. The current code has `defp parse_timeout` (line 1098, `protected.ex`). If a dev changes the cap to 25 000 but forgets to promote visibility, the tests themselves will produce a compile error `Protected.parse_timeout/1 is undefined or private`, which is a confusing failure mode rather than a meaningful test failure.

The tests will, in effect, enforce the visibility change indirectly — but only at compile time, not as a meaningful "this AC is met" signal.

**Required fix**: Add a comment to the describe block explaining the prerequisite:

```elixir
# NOTE: parse_timeout/1 must be promoted from defp to def (with @doc false) for
# these tests to compile. This is part of AC4 — unit-testability is the design goal.
describe "parse_timeout/1 — server-enforced cap at 25_000ms (AC4)" do
```

This is a documentation/clarity fix, not a missing test. The current test set for AC4 is otherwise complete and well-structured.

---

### INFO-1 — AC2 test does not assert `state` and `timeline` sub-keys consistently across all rooms

**Severity**: INFO  
**AC**: AC2

The AC2 test asserts `room["state"]`, `room["timeline"]`, and `room["timeline"]["events"]` for each room in the joined map. However, `room["state"]` is asserted as `is_map` while the Matrix spec shape for `/sync` room state is actually a nested object with a `events` list (same as timeline). If the implementation wraps state differently, the assertion `is_map(room["state"])` will pass but clients will fail.

Compare: the story's AC acceptance test spec says `rooms.join` contains rooms each with `state`, `timeline` keys — but the actual Matrix `/sync` spec shape is `state: {events: [...]}` and `timeline: {events: [...], limited: bool, prev_batch: ...}`.

This is an INFO because the existing tests may be consistent with what the current `sync_response` helper in `Nebu.Matrix.Http` actually produces — but it is worth verifying.

**Suggestion**: Review `Nebu.Matrix.Http.sync_response/2` to confirm the key shapes and tighten the assertions to match the actual emitted structure (e.g., `assert is_list(room["state"]["events"])`).

---

### INFO-2 — No regression test for AC1 boundary: `timeout=24999` must NOT be clamped

**Severity**: INFO  
**AC**: AC1, AC4

The existing AC4 tests correctly verify values at and above 25 000 are clamped, and values below are passed through. However, the boundary value `24999` is only tested in the "values below 25_000 are passed through" test, which also includes `0`, `100`, and `10000`. The critical boundary at `24999` is already there — this is informational only.

However: there is no test for `timeout=25001` via the HTTP integration path (i.e., passing it through the full `GET /sync?timeout=25001` route). The unit test covers the parser; an end-to-end assertion that `?timeout=25001` results in a response within 26 000ms would complete the AC1 coverage. This links back to MAJOR-1's recommendation.

---

## Summary Score

| Dimension | Score | Rationale |
|---|---|---|
| AC Coverage | 60/100 | AC2 shape-only; AC1 server.ex clamp uncovered |
| Determinism | 80/100 | Timing tests have adequate margins but lack explanatory comments |
| Isolation | 90/100 | Unique user suffixes, integration tests correctly separated |
| Maintainability | 85/100 | Clear describe block names; visibility prerequisite undocumented |

**Gate decision**: FAIL — MAJOR-1 and MAJOR-2 must be resolved before dev closes the story.

---

## Reviewer Questions — Answers

**Q1: Do the 4 AC4 tests cover AC1 adequately?**

No — they cover the HTTP-layer parser (`protected.ex`) but not the server-internal clamp (`server.ex`). AC1 is not fully covered until a test observable at the server level confirms the hold time is bounded at 25 000 ms. See MAJOR-1.

**Q2: Is the AC2 integration test adequate — does it verify parallel fetch?**

No. It verifies the response shape of an initial sync with 3 rooms, which passes equally against the current sequential `Enum.flat_map`. It does not verify that `Task.async_stream` is in place. See MAJOR-2.

**Q3: Is the AC3 timing test deterministic enough for CI?**

Adequate but fragile. The 3× margin (`500ms timeout → 1500ms assertion`) is reasonable; the missing element is an inline comment documenting the reasoning, and confirmation that `:integration` tests run with `async: false`. See MINOR-1.

**Q4: Should we also test `since` being unknown (fallback to initial sync)?**

Yes, as an INFO-level gap. The dev notes state: "`get_sync_delta` falls back to `get_initial_sync` on `{:error, :not_found}`" (the `fallback_to_initial` path). A test for this would be an `@tag :integration` test that passes a fabricated/stale `since` token and asserts that the response is a full snapshot (not an empty delta). This is not a blocker for this story — the `get_sync_delta` fallback path is pre-existing behaviour — but it closes a coverage gap if that code path is touched during the AC1 server.ex clamp change.

**Q5: Are there missing coverage areas?**

Yes — see MAJOR-1 (server.ex clamp) and MAJOR-2 (parallelism observable behaviour). Additionally, no test covers a user with 0 rooms (edge case for `get_initial_sync` returning an empty `rooms.join` map). This is INFO level.
