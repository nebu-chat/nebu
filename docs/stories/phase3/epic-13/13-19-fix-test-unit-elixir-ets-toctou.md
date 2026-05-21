---
status: in-progress
epic: 13
story: 19
security_review: not-needed
matrix: false
ui: false
atdd: not-applicable
---

# Story 13.19: Fix test-unit-elixir - TOCTOU race in ETS on_exit cleanup

Status: in-progress

## Story

As a developer running `make test-unit-elixir`,
I want `TestArchiveRoom Story 9-9 AC5` to pass reliably,
so that the CI pipeline does not fail intermittently on a test cleanup race.

**Size:** XS

---

## Background & Motivation

`archive_room_test.exs` uses a named ETS table (`:double_archive_test_db`) in a
`describe` block. The `on_exit` callback uses a guard before deleting:

```elixir
on_exit(fn ->
  if :ets.info(:double_archive_test_db) != :undefined do
    :ets.delete(:double_archive_test_db)   # ← line 562
  end
end)
```

ExUnit dispatches `on_exit` callbacks from a **separate process**, not the test process.
With `max_cases: 28` (parallel app compilation), the teardown of one test can race with
the setup or teardown of the next test in the same describe block:

1. Test N on_exit: `:ets.info(...)` → `:some_info` (table exists) → guard passes
2. Test N+1 setup: deletes and recreates the table
3. Test N on_exit: `:ets.delete(...)` → **ArgumentError** - table no longer owned by this process

The `if :ets.info / :ets.delete` guard is a TOCTOU (Time-Of-Check Time-Of-Use) pattern.
It cannot prevent the race; it only narrows the window.

**Fix:** replace the guard with `try/rescue ArgumentError` - delete unconditionally and
swallow the error if the table is already gone.

---

## Acceptance Criteria

**AC1 - `on_exit` uses try/rescue instead of guard:**
Given `archive_room_test.exs` setup in the describe block,
When the `on_exit` callback runs,
Then it wraps `:ets.delete` in `try/rescue ArgumentError` (no guard check).

**AC2 - `make test-unit-elixir` passes consistently:**
Given the updated test,
When `make test-unit-elixir` is run (including with `max_cases: 28`),
Then exit code is 0 across multiple runs with no ArgumentError in output.

---

## Acceptance Tests

### Tests written FIRST (before implementation code):

1. `ArchiveRoomTest - Story 9-9 AC5` - ExUnit (already failing intermittently - this IS the regression)
   - Given: ETS table `:double_archive_test_db` created in setup
   - When: `on_exit` fires from a separate process
   - Then: no ArgumentError - cleanup succeeds even if table was already deleted

The test already exists and fails intermittently. Fixing the `on_exit` IS the fix.

---

## Implementation Notes

In `archive_room_test.exs` around line 558–563, replace:

```elixir
on_exit(fn ->
  Application.delete_env(:event_dispatcher, :admin_db_module)

  if :ets.info(:double_archive_test_db) != :undefined do
    :ets.delete(:double_archive_test_db)
  end
end)
```

With:

```elixir
on_exit(fn ->
  Application.delete_env(:event_dispatcher, :admin_db_module)

  try do
    :ets.delete(:double_archive_test_db)
  rescue
    ArgumentError -> :ok
  end
end)
```

No changes to production code.
