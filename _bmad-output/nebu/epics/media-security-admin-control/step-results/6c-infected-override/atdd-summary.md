# ATDD Summary — 6c-infected-override

**Files touched:**
- `server/test/nebu/media_admin_actions_test.exs` — 12 unit tests for `admin_override_infected/3` (Acceptance Tests 1-12), helpers: `insert_infected_file!`, `grant_override_role!`, `insert_admin_without_grant!`, `cleanup_user!`
- `server/test/nebu/media/state_machine_test.exs` — extended `@full_guard_table`'s `infected` key from `[:deleted]` to `[:deleted, :released]`
- `server/test/nebu/admin/media_live_test.exs` — 6 LiveView tests (Acceptance Tests 13-18), new describe block `"6c: infected override (media_admin_override)"`, helpers `admin_conn_for_live_as/2`, `sent_admin_conn_as/2` (real-router convention, not `live_isolated/3` — 6a's file's own moduledoc documents `live_isolated/3` doesn't work here due to `handle_params/3` requiring router mounting)

**Verification:** 98 tests, 19 failures (12 new unit + 1 modified guard-table + 6 new LiveView), 0 regressions to 79 previously-green tests.

Failure-reason breakdown:
- 3 plain assertion failures: guard table not extended, `allowed?(:infected,:released)` false, `media_infected_override` missing from `@known_actions`
- 16 Postgrex undefined_column errors: `users.media_admin_override` column doesn't exist yet (migration not landed) — deliberate, documented RED reason
- Compiler warning: `Nebu.Media.admin_override_infected/3 is undefined or private`

No implementation code, migration, or LiveView handler added.
