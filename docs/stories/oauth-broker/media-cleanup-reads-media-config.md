---
story_id: media-cleanup-reads-media-config
title: "MediaCleanupWorker reads deleted_days / infected_days from media_config (follow-up du), fail-safe, effective defaults unchanged"
type: bugfix
severity: low
epic: oauth-broker
status: done
security_review: required
matrix: false
ui: false
created: 2026-10-16
branch: feature/migrate-to-oauth2
---

# Story: the retention windows of the Admin media settings must take effect (follow-up `du`)

Found by the security review of media-retention-audit-atomic (Kassandra LOW-1, pre-existing): `deleted_days` / `infected_days` are stored in `media_config`, audited atomically, shown in the Admin form
("Deleted media retention (days)", "Infected media retention (days)") and described in 07-deployment, but `Nebu.Workers.MediaCleanupWorker` (the daily hard-delete cron of the `:deleted` / `:infected` rows) reads
`Application.get_env(:nebu, :media_cleanup)` (`config.exs`: 30 / 7). The value the admin edits has no effect. `released_delete_after_days` IS read by its worker (`MediaReleasedAutoDeleteWorker`, `Config.get/0`).

## Decision: (a) wire the worker to `media_config` (not (b) relabel the fields)

Reason: the form, the audit (a shortening needs a durable audit row), the break-glass docs and the strict admin gate all exist because the value is meant to steer deletion; relabelling would keep an audited, gated,
destructive-sounding control that does nothing and leave the retention of infected evidence / deleted media un-configurable at runtime (the app-env value is not settable on a release). (b) would remove the only
operator control. The risk of (a) is data destruction by a mis-read value, handled by D3-D5.

## Decisions

- **D1 (single owner, strict read).** `Nebu.Media.Config.retention_days/0` returns `{:ok, %{deleted_days: n, infected_days: n}}` or `{:error, :unavailable | :invalid}`. The worker calls it at EVERY run (a daily cron: no cache, no
  restart needed; a change takes effect at the next run, also on every node). It deliberately does not use `Config.get/0`: `get/0` turns an unreadable table into the DEFAULT values (and the 60 s refresh replaces a good cache by the
  defaults when one read fails). For a destructive worker "I could not read the admin's value" must never become "use 30 days" when the admin chose 365: it must delete nothing.
- **D2 (defaults = today's effective behaviour).** Effective retention without an admin value is 30 days (`:deleted`) and **7 days** (`:infected`) (the worker's `config.exs` values since story 8a; 07-deployment says "30 / 7").
  `Nebu.Media.Config` had `infected_days` 90 (story 9a: "existing infected-record retention default", factually wrong: the existing one was 7), so with the wiring an untouched instance would silently KEEP infected files
  83 days longer. The catalogue default becomes 7 (the Admin form shows the truth), the `config :nebu, :media_cleanup` block (dead after the change) goes. **Owner decision pending:** story 9a's rationale ("kept well clear of
  `deleted_days` given its compliance-evidence role") suggests the owner may WANT 90 for infected evidence; that is a conscious retention increase, one default (and a docs line) to flip. This story does not make it.
- **D3 (fail-safe).** `{:error, _}` (table unreadable, loader raised, repo not running) or an invalid value: the two fresh-candidate phases (`:deleted`, `:infected`) are skipped for this run, one ERROR line without values
  (`retention config unavailable, nothing deleted`), the job returns `:ok` (no retry storm: the next daily run tries again). The completion ("reaper") phase still runs: it only finishes rows that are ALREADY `:hard_deleted`
  (ADR-032 steps 2/3) and deletes nothing new.
- **D4 (valid range).** An integer from 0 to 3650 (the Admin form bounds and `Config.upsert/3`'s non-negative rule). A negative, > 3650, non-integer or non-numeric stored value is `:invalid`: skip as in D3 (a hand-edited row
  can neither delete early nor crash `($1 || ' days')::interval` with an interval overflow). `0` keeps its documented meaning "shortest retention: delete at the next run" (the admin gate / audit exist for it; ADR-033 text:
  "`deleted_days` / `infected_days` of 0 destroy ..."), unlike `released_delete_after_days` where 0 = off.
- **D5 (units).** Days, bound as the string of the integer to `($1 || ' days')::interval` exactly as before (no seconds / hours anywhere); the audit metadata `retention_days` of `media_hard_deleted` is the value used.
- **D6 (operations).** The run logs the effective values once at INFO (`retention deleted_days=N infected_days=N`, non-sensitive) so an operator can see what the run used. **Behaviour change for running instances:** values an
  admin already SAVED (they had no effect so far) become effective at the next run; 07-deployment gets a pre-upgrade check (`SELECT key, value FROM media_config WHERE key IN ('deleted_days','infected_days')`).
- Unchanged: `released_delete_after_days` and its worker; the atomic audit rules of media-retention-audit-atomic (a shortening needs the audit row; the cache refresh after commit); `Config.get/0` and the form.

## Acceptance Criteria

1. With no `media_config` rows the worker deletes `:deleted` rows older than 30 days and `:infected` rows older than 7 days and keeps younger ones (unchanged behaviour); `Config.get().infected_days` is 7.
2. With `deleted_days` / `infected_days` set in `media_config` (e.g. 10 / 3) the worker deletes by these windows (older -> hard-deleted, younger -> kept) and the audit `retention_days` is the configured value.
3. A change of the stored value takes effect at the next run without a restart (two runs with different loader values in one process).
4. Unreadable config (loader error / raise / non-map), or an invalid value (negative, 3651, huge, `"abc"`, `nil`, a float): nothing is deleted from the `:deleted` / `:infected` phases (no transition, no storage delete), the reaper phase still
   completes an intermediate `:hard_deleted` row, the job returns `:ok`, the log has no value.
5. `0` deletes every row of that state whose ledger time is in the past (documented semantic), 3650 is accepted.
6. The worker no longer reads `Application.get_env(:nebu, :media_cleanup)` (a test sets it to 1 day and the worker still uses 30 / 7).
7. `Config.retention_days/0` unit tests (defaults, overrides, string values, errors, invalid ranges, no cache involved) and `Config` catalogue default `infected_days` 7.
8. Docs: 07-deployment (the "known gap" sentence becomes the behaviour; pre-upgrade check), follow-ups `du` closed, owner question about 90 recorded.

## Acceptance Tests

- `server/test/nebu/workers/media_cleanup_worker_test.exs` (setup moved to the `media_config_loader` seam, new describe "retention from media_config"): AC1-AC6.
- `server/test/nebu/media/config_test.exs` / new `server/test/nebu/media/config_retention_days_test.exs`: AC7.

## Result (2026-10-16)

- ATDD: `config_retention_days_test` (unit + real rows), worker unit tests (setup moved to the loader seam, 15 new), worker integration tests against the real DB, docs test. test-review: 3 MAJOR (a vacuous fixture after the default change, a silent no-op cleanup under FORCE RLS, the unit of the window unpinned) + 7 MINOR applied. Dev: `Nebu.Media.Config.retention_days/0`, the fail-safe `perform/1`, writer range 0..3650 (Kassandra L-1), hint texts on the form (L-2), docs. code-review: 0 MAJOR, 5 MINOR applied (stale prose, building-blocks, ERROR line, follow-up `ej`). Kassandra: CLEAN, 3 LOW fixed, 4 INFO. UX: 0 blocking.
- Behaviour change for running instances: (1) none for an instance without stored values (30 / 7 as before); (2) the Admin form now shows 7 (was 90) for `infected_days`; (3) values an admin saved earlier become effective at the next run (pre-upgrade SELECT in 07-deployment, manual group E); (4) a damaged value stops the cleanup (ERROR line) instead of being guessed.
- Owner decision (follow-up `eh`): keep 7 days as the default for infected evidence or raise it (story 9a's rationale suggested a longer one).
