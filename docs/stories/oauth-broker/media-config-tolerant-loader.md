---
story_id: media-config-tolerant-loader
title: "A damaged media_config row no longer masks every media setting as its default (follow-up ej): per-row tolerant decode (bad row skipped, key logged, never the value) and a text warning on the Admin media settings form"
type: bugfix
severity: low
epic: oauth-broker
status: done
security_review: required
matrix: false
ui: true
created: 2026-10-16
branch: feature/migrate-to-oauth2
---

# Story: one damaged `media_config` row must not reset ALL media settings to their defaults (follow-up `ej`)

Found by the code review of media-cleanup-reads-media-config (M5, pre-existing). As an instance admin I want a damaged stored media setting to affect only that one setting, and to be told on the
media settings page which setting is damaged, so that the other settings (MIME denylist, upload limits, retention windows) keep the values I chose and a paused media cleanup is not invisible.

## Root cause (verified in the code, 2026-10-16)

`server/lib/nebu/media/config.ex`:

- `default_loader/0` (line ~809) runs `SELECT key, value FROM media_config` and decodes EVERY row inline with `decode_value/2`. For the eleven `@nonneg_int_keys` and `released_delete_after_days`
  `decode_value/2` is a bare `String.to_integer/1` (lines ~851-852). One damaged row (`deleted_days = 'abc'`, `'90 '`, `'90d'`, `'1e3'`; realistic after the documented break-glass `UPDATE media_config SET value = ...`
  in `docs/architecture/07-deployment.md` line 220) raises `ArgumentError` inside the `Map.new/2`.
- The rescue that catches it is `default_loader/0`'s OWN `rescue e -> Logger.warning(... inspect(e)); %{}` (not `safe_load/0`'s, as the follow-up says; same effect): the loader returns `%{}` for the
  whole table. `do_refresh/0` then caches `build_catalog(%{})` = ALL 15 defaults, on every node, re-done on every 60 s TTL tick.
- Effect: `get/0` returns the defaults for every key. Security-relevant: `Nebu.Media.mime_denylist_rejected?/1` (`server/lib/nebu/media.ex` ~181) reads `mime_denylist` = `""` = denylist OFF; the upload / scan
  size limits, stall limit, alert thresholds revert too. The Admin form (`Nebu.Admin.MediaSettingsController.index/2`, `state_from_config(Config.get())`) shows 30 / 7 etc., while the cleanup worker's STRICT
  `retention_days/0` (its own SQL, story media-cleanup-reads-media-config) returns `{:error, :invalid}` and deletes nothing. The admin cannot see the problem, and re-submitting the shown value writes nothing:
  `changed_keys/2` compares against the (defaulted) `Config.get()`, so `deleted_days = 30` "did not change" and the damaged row stays.
- Second raise site: `build_catalog/1` -> `coerce_value/2` (lines ~764-769) also calls `String.to_integer/1` on a binary. It is reached with binaries via the `:media_config_source` / `:media_config_loader`
  seams (the real loader has already decoded). It is NOT rescued: in `do_refresh/0` (GenServer `init/1`, `handle_call(:refresh)`, `:ttl_tick`) it crashes the cache holder, and in `get/0` it raises into the caller.
- `do_upsert_sequential/3` (non-retention keys) calls the same loader for the audit `old_value`: with one damaged row every old value is the default (wrong audit `old_value`). The retention keys already read
  the old value per key under the lock (`read_old_value_locked/2`, `ArgumentError -> :unknown`): fine, keep.
- `server/lib/nebu/media/storage_config.ex` `default_loader/0` (line ~1012) is NOT affected: it reads ONE typed row (`id = 1`, real column types, `use_ssl` boolean), there is no per-row text decode, and a
  corrupted ciphertext is already handled per field by `decrypt_secret/1`. Out of scope (no change). (`split_endpoint/2`'s `String.to_integer` works on a write-validated endpoint; also out of scope.)
- `retention_days/0` (strict, own SQL, own `parse_retention_days/1`) is correct and stays unchanged.

## Decisions

- **D1 (decode per row, one owner).** One private function (e.g. `decode_rows/1 :: map -> {decoded_map, damaged_keys}`) decodes a STRING-keyed map of stored values row by row. A row that cannot be decoded is
  left OUT of the decoded map (so `build_catalog/1` uses that key's default) and its key goes into `damaged_keys`. It is idempotent on already-typed values (an integer stays an integer), so it is applied to
  whatever a loader / source returned: the real loader, the `:media_config_loader` seam and the `:media_config_source` seam. `default_loader/0` returns the RAW rows (no decode); `safe_load/0`,
  `do_upsert_sequential/3` and the `:media_config_source` branch of `get/0` all go through the decode. `coerce_value/2` then only sees valid values and can no longer raise (keep it total: no
  `String.to_integer/1` left in the read path except behind a successful `\A[0-9]+\z` match).
- **D2 (what is "damaged").**
  - the eleven `@nonneg_int_keys`: an integer `>= 0`, or a string of plain decimal digits (`\A[0-9]{1,18}\z`: no sign, no space, no fraction, no exponent; leading zeros allowed). Anything else (`"abc"`, `"-5"`,
    `" 12"`, `"1e3"`, `"1.5"`, `nil`, a float, an oversized digit string) is damaged. A negative stored value used to decode to a negative integer; `upsert/3` never writes one, so treating it as damaged is the
    fail-safe reading.
  - `deleted_days` / `infected_days` additionally must be `<= 3650` (`@retention_days_max`), exactly the range `retention_days/0` accepts: the form warning then appears exactly when the cleanup is paused.
  - `released_delete_after_days`: `""` / `nil` = `nil` (off, unchanged), else as a non-negative integer.
  - `webhook_url` (`""` = nil), `mime_denylist`, `scan_kill_switch`: decoded as today (plain string pass-through, never damaged by this story). Re-validating them on read (SSRF / token syntax / enum) is out of scope.
  - unknown keys: still ignored silently by `build_catalog/1` (`Map.take`, rolling-deploy rule of story 9a); they are NOT reported as damaged.
- **D3 (log the key, never the value).** For each damaged key one `Logger.warning` line with the key only, e.g. `Nebu.Media.Config: stored media_config value is invalid, using the default key="deleted_days"`.
  Never the stored value, never `inspect` of an exception or of the row (the existing `inspect(e)` in `default_loader/0`'s and `safe_load/0`'s rescue must not be reached by a damaged row any more; when they are
  reached for another reason they keep their current text). To avoid one line per key per node every 60 s, the refresh logs only when the damaged set CHANGES compared with the previous refresh (newly damaged keys:
  warning; a key that recovered: one info line `... value readable again key=...`, also key only).
- **D4 (the problem is visible, `damaged_keys/0`).** New public function `Nebu.Media.Config.damaged_keys/0 :: [String.t()]` (sorted, string keys of the catalog). The refresh stores it in the same ETS table
  next to the catalog (e.g. `{:damaged_keys, keys}`); without a running cache it is computed from a fresh load; with the `:media_config_source` seam it is computed from the source map. It never contains a value. A refresh whose whole-table read FAILS (the loader raises or answers no map: DB down) keeps the previous damaged set and logs no "readable again" line (an unreadable table is not a recovery of a row; clarification D3/D4, test review m4).
  `get/0`'s shape and contract stay unchanged (15 atom keys, every key present).
- **D5 (Admin warning).** `Nebu.Admin.MediaSettingsController.render_settings/3` assigns `:damaged_media_keys` from `Config.damaged_keys/0` (every render: index, failed save, storage actions). The template
  `server/lib/nebu/admin/templates/media_settings/index.html.heex` shows, above the media policy form, ONE text warning in an element with `role="status"` and `data-testid="media-config-damaged"` when the list
  is non-empty. Fixed copy (no stored value, no exception text), the keys as plain text, e.g.: "Some stored media settings could not be read and their default values are in effect: deleted_days. While
  deleted_days or infected_days is unreadable, the automatic cleanup of deleted and infected media is paused. Saving this form rewrites the settings shown here." The meaning is in the TEXT (not only the
  alert colour; the existing `alert alert-warning` class may be used for styling). Not shown when nothing is damaged. A damaged key that this form does not expose (`mime_denylist` cannot be damaged by D2;
  the alert thresholds / `scan_kill_switch` are not on the form) is still named; no repair control for those keys in this story.
- **D6 (save repairs a damaged row).** `changed_keys/2` treats a key that is in `Config.damaged_keys/0` and in the submitted form as CHANGED even when its submitted value equals the shown default, so a plain
  "Save" writes it through `Config.upsert/3` (normal gate, validation, audit). For `deleted_days` / `infected_days` the existing atomic path applies unchanged: the old value under the lock is `:unknown`; when the
  audit row can be written the save succeeds (audit `old_value` = `:unknown`), when it cannot the guard refuses it (`:unknown` is never a lengthening) with the existing generic "Failed to save media settings"
  flash. After a successful save the refresh empties the list and the warning disappears. For the non-retention keys `do_upsert_sequential/3` records `old_value: :unknown` (not the default) for a damaged key.
- **Unchanged:** `retention_days/0` and the cleanup worker (still refuse on a damaged value, D3 of media-cleanup-reads-media-config); the writer validation; the RLS policies; the TTL / `:pg` mechanism; a whole-table
  read failure (DB down) still yields the defaults as today (follow-up territory, see media-cleanup-reads-media-config D1); no migration; `StorageConfig`.

## Acceptance Criteria

1. **Per-row tolerance (seam).** With the `:media_config_loader` seam returning `%{"deleted_days" => "abc", "mime_denylist" => "application/x-msdownload", "max_upload_size_bytes" => "1000", "infected_days" => 3}`,
   after `Config.refresh/0` `Config.get/0` returns `deleted_days: 30` (default), `mime_denylist: "application/x-msdownload"`, `max_upload_size_bytes: 1000`, `infected_days: 3` (the other rows keep their
   values) and `Config.damaged_keys/0 == ["deleted_days"]`; the cache holder process is still alive.
2. **Damaged forms (seam, table-driven).** Each of `"abc"`, `"-5"`, `" 12"`, `"12 "`, `"1e3"`, `"1.5"`, `""` (for a non-nilable integer key), `nil`, `1.5`, `-1` and a 30-digit string for an integer key is
   skipped (default in `get/0`, key in `damaged_keys/0`); `"0"`, `"007"`, `0` and `3650` (retention keys) are accepted; `"3651"` for `deleted_days` / `infected_days` is damaged, for `max_stall_ms` it is valid;
   `released_delete_after_days` `""` / `nil` is `nil` and not damaged, `"x"` is damaged.
3. **No raise in `build_catalog`.** The `:media_config_source` seam returning `%{"max_stall_ms" => "abc"}` makes `get/0` return the default `max_stall_ms` (no raise) and `damaged_keys/0 == ["max_stall_ms"]`;
   a loader seam with a binary value no longer crashes `init/1` / `refresh/0` / the TTL tick (the GenServer pid is unchanged after `refresh/0`).
4. **Logging (seam, `capture_log`).** A refresh with a damaged `deleted_days = "secret-ish-value-123"` logs exactly one warning containing `deleted_days` and NOT containing `secret-ish-value-123` (nor any
   other stored value); a second refresh with the same damaged set logs no new warning for it; a refresh after the row became valid logs one line naming the key, again without a value.
5. **Real DB (`:integration`, rows seeded with `T.privileged_sql!`, cleanup in `on_exit` like `config_retention_days_test.exs`).** Rows `deleted_days = 'abc'`, `mime_denylist = 'application/x-msdownload'`,
   `max_pending_per_user = '5'` with NO loader seam: after `Config.refresh/0` `get/0` has `deleted_days: 30`, the stored denylist and `max_pending_per_user: 5`, `damaged_keys/0 == ["deleted_days"]`,
   `Nebu.Media.mime_denylist_rejected?("application/x-msdownload")` is `true`, and `Config.retention_days/0` is still `{:error, :invalid}` (unchanged strict read).
6. **Repair through the write path (`:integration`).** With `deleted_days = 'abc'` stored, `Config.upsert("deleted_days", 30, actor)` succeeds, the row becomes `'30'`, `damaged_keys/0 == []`,
   `retention_days/0` is `{:ok, %{deleted_days: 30, ...}}`, and the `media_config_updated` audit row's metadata has `old_value` "unknown" and never `abc`. For a non-retention key (`max_stall_ms = 'abc'`
   repaired via `upsert/3`) the audit `old_value` is "unknown" too, not the default.
7. **Admin warning (ui:true, controller test).** `GET /admin/media/settings` with a damaged `deleted_days` (source seam or real row) renders one element with `role="status"` and `data-testid="media-config-damaged"`
   whose TEXT names `deleted_days`, says the default is in effect and that the media cleanup is paused, and does not contain the stored value; the form fields still show the effective values (30 for
   `deleted_days`, the stored values of the other keys). With no damaged key the element is absent. The warning conveys its meaning in text, not by colour alone (no colour-only indicator, no icon-only
   indicator); it is above the form so it is read before the fields.
8. **Save repairs (controller test).** With `deleted_days` damaged, POSTing the form unchanged (`deleted_days = 30`, the shown default) calls `Config.upsert("deleted_days", 30, actor)` (it is no longer
   filtered out as "unchanged"), the other unchanged keys are still not written, the redirect shows "Media settings saved" and the next GET shows no `media-config-damaged` element. When the atomic path
   refuses (audit unavailable), the existing generic "Failed to save media settings" flash appears and the warning stays.
9. **No regressions.** The existing suites `server/test/nebu/media/config_test.exs`, `config_retention_days_test.exs`, `config_retention_atomic_test.exs`, `mime_denylist_test.exs`,
   `server/test/nebu/admin/media_settings_controller_test.exs`, `media_settings_retention_atomic_test.exs` and the media worker tests pass unchanged (or with seam fixtures adapted only where they relied on
   the loader returning pre-decoded values; such adaptations are listed in the dev record).
10. **Docs.** `docs/stories/oauth-broker/follow-ups.md` row `ej` closed with a reference to this story; `docs/architecture/07-deployment.md` break-glass sentence (line ~220) adds that the value must be plain
    digits and that a wrong value shows a warning on `/admin/media/settings` and keeps that key at its default (cleanup paused for `deleted_days` / `infected_days`); `05-building-blocks.md` `Nebu.Media.Config`
    entry mentions `damaged_keys/0`.

## Acceptance Tests

- New `server/test/nebu/media/config_tolerant_loader_test.exs` (`use ExUnit.Case, async: false`, seams `:media_config_loader` / `:media_config_source` reset in `on_exit`, a `describe ... @describetag :integration`
  block with real rows via `Nebu.OAuth.TestSupport.privileged_sql!/2` as in `config_retention_days_test.exs`): AC1-AC6.
- `server/test/nebu/admin/media_settings_controller_test.exs` (new describe "damaged media_config row"): AC7, AC8 (the controller tests already use the `:media_config_source` / `:media_config_writer` seams).
- Docs assertions (if the epic keeps docs tests, e.g. `server/test/nebu/oauth/*_docs_test.exs`): AC10.

## Tasks

- [x] `config.ex`: `default_loader/0` returns raw rows; add the per-row `decode_rows/1` (D1/D2); use it in `safe_load/0`, the source branch of `get/0`, `do_upsert_sequential/3` (old value `:unknown` for a damaged key).
- [x] `config.ex`: store / expose `damaged_keys/0` (ETS entry written by `do_refresh/0`), log on change only, key only (D3/D4); moduledoc "Interface" + seams paragraph updated.
- [x] `config.ex`: `coerce_value/2` total (no raise).
- [x] Controller: assign `:damaged_media_keys` in `render_settings/3`; `changed_keys/2` includes damaged submitted keys (D5/D6).
- [x] Template: the `role="status"` warning block (D5).
- [x] Tests (AC1-AC9), docs (AC10).

## Dev Notes / Guardrails

- **Pipeline-protected:** `server/lib/`, `server/test/` only inside a `nebu-pipeline` run (CLAUDE.md). ADR-018: inline SQL stays in `Nebu.Media.Config`, no repository layer. ADR-020: the controller already calls
  `Nebu.Media.Config` directly (established pattern of story 9b, see its moduledoc "Persistence seam"); add only `damaged_keys/0` to that surface.
- **No sensitive data in logs (LAW):** the stored value of a damaged row is never logged, never rendered, never in a flash or an audit row (audit `old_value: :unknown`). Do not `inspect` the row, the decode
  exception or the map. Keys are not sensitive.
- **Fail-safe:** a damaged retention row must keep pausing the cleanup (no change to `retention_days/0` or the worker). Do not "repair" a row on read (no write in the read path).
- **Do not break the 9a rolling-deploy rule:** unknown keys are ignored, never reported, never crash.
- **ETS table is `:protected`:** only the GenServer writes `{:damaged_keys, _}`; readers use `:ets.lookup/2` with the same rescue as `read_from_ets/0`.
- **Seam fixtures:** some existing tests feed the `:media_config_loader` seam with typed values (integers) and others with strings; the decode is idempotent on valid typed values, so they should pass
  unchanged. A test that relied on a negative integer being accepted by `get/0` would now see the default (D2): adapt it and note it.
- **`retention_days/0`'s own parser** (`parse_retention_days/1`) and the new decode must agree on the retention range (0..3650, digits only); consider reusing one private predicate for the two retention keys.
- **Test DB:** `media_config` has FORCE RLS (`media_config_update_mutable`); seed damaged rows with `T.privileged_sql!` as the existing integration tests do, and restore / delete them in `on_exit`.
- References: `server/lib/nebu/media/config.ex` (`default_loader/0`, `safe_load/0`, `build_catalog/1`, `coerce_value/2`, `decode_value/2`, `do_upsert_sequential/3`, `read_old_value_locked/2`,
  `retention_days/0`); `server/lib/nebu/admin/media_settings_controller.ex` (`index/2`, `changed_keys/2`, `render_settings/3`); `server/lib/nebu/admin/templates/media_settings/index.html.heex` (flash block,
  lines 8-16, flash pattern); `server/lib/nebu/media.ex` `mime_denylist_rejected?/1`; `docs/stories/oauth-broker/media-cleanup-reads-media-config.md` (D1, D3, D4);
  `docs/stories/oauth-broker/media-retention-audit-atomic.md`; `docs/architecture/07-deployment.md` line ~220 (break-glass `UPDATE`).

## Dev Agent Record

### Agent Model Used

Claude Sonnet 5.5

### Completion Notes List

- `Nebu.Media.Config`: `default_loader/0` returns the RAW rows (`:error` when the read fails); ONE per-row decode (`decode_rows/1` / `decode_row/2`, total, idempotent) is
  applied in `safe_load`-based paths (`do_refresh/0`, `get/0` without a cache, `damaged_keys/0`), the source seam of `get/0` and `do_upsert_sequential/3`
  (damaged key -> audit `old_value: :unknown`). `safe_load/0` answers `{:ok, map} | :error`; a failed whole-table read keeps the previous damaged set and logs no
  "readable again" line. `coerce_value/2` is total (falls back to the key default). The ETS entry `{:damaged_keys, keys}` is written together with the catalog in one
  `:ets.insert/2`; the refresh logs only the change (warning per new key, info per recovered key, key only). `parse_retention_days/1` (strict reader) and the tolerant
  decode share `parse_nonneg/1` (plain digits, 1-18; the strict reader's former `{1,6}` digit bound is now `{1,18}`: a leading-zero string such as `0003650` is now
  accepted by both, as both then agree on D2).
- Controller: `:damaged_media_keys` assigned in `render_settings/3`; `changed_keys/3` treats a damaged submitted key as changed. Template: `role="alert"` block
  `data-testid="media-config-damaged"` above the form. Docs: follow-ups `ej` closed, 07-deployment break-glass row + retention paragraph, 05-building-blocks `damaged_keys/0`.
- Test adaptation (one): in `config_tolerant_loader_test.exs` the AC4 recovery test used `deleted_days = "7741"` as the "readable again" value; 7741 > 3650 is damaged by D2, so
  it is not a recovery. Changed to `"2741"` (and the matching `refute`).
- Results: tolerant-loader + docs + controller tests 106/106; `test/nebu/{media,admin,workers,oauth}` + `release_test.exs` with `--include integration` 5023/5041, the 18
  failures are all in the known-flaky list (RoomsFallbackNameTest, TraceMapNodeControlsTest, TemporaryCaptureManagerTest, WarRoomTest), none touch media config.
  `mix compile --force --warnings-as-errors` clean.

### Review cycle 1 (code review 0 MAJOR / 6 MINOR, UX advisories, Kassandra CLEAN)

- M1 moduledoc: the "Tolerant per-row decode" section now sits after the seams list, before the atomic-audit section.
- M2 bounds: `validate_value/2` caps plain integer keys and `released_delete_after_days` at 999_999_999_999_999_999 (what the decode reads back); the controller caps
  `released_delete_after_days` at the same value (the other form fields already had `@bounds`). Tests: unit (refused above, accepted/read back at the cap), integration
  (saved cap is not damaged), controller (cap accepted, one above refused before any write).
- M3: `do_upsert_sequential/3` records audit `old_value: :unknown` when the loader answered no map (was the default). No existing fixture relied on the default. Integration test added.
- M4 + Kassandra L-1 + UX A1-A5: the warning is `role="status"` (persistent notice), keys in `<ul>` of `<code>`, the reason ("not a whole number in the allowed range", never the
  value), the cleanup-paused sentence only when `deleted_days` / `infected_days` is damaged (names only the damaged ones) and states that saving writes the shown value and
  resumes the cleanup, keys the form does not carry in a separate "Not editable on this form (repair in the database, see Break-glass)" list. New assigns
  `:damaged_form_keys`, `:damaged_other_keys`, `:damaged_retention_keys`. 07-deployment: break-glass SQL line for the keys the form does not carry, "saving resumes the cleanup".
  AC7 now reads `role="status"`; controller test, e2e step and feature comment updated accordingly.
- M6: decision: keep the strict reader at `{1,18}` digits (shared `parse_nonneg/1`); pinned by tests in `config_retention_days_test.exs` (`"0000000"` = 0, `"0003650"` = 3650, 19 digits
  and `"0003651"` invalid) and documented as accepted in 07-deployment (Kassandra INFO-2).
- Follow-up rows `ek` (keep last-known-good catalog on a failed read) and `el` (optional hardening) added to follow-ups.md.
- Test adaptations (ATDD contract changes), all deliberate: (1) `config_tolerant_loader_test.exs` recovery test `"7741"` -> `"2741"` (7741 > 3650 is damaged, D2); (2) the controller test
  assertion `role="alert"` -> `role="status"` for the damaged block (UX A1), plus the e2e step `toHaveAttribute('role', 'status')`; (3) cycle 0 drive-by: `media_cleanup_reads_media_config_docs_test.exs`
  (the `eh` follow-up row assertion) was adapted for AC9 because the retention paragraph / `ej` row text changed.
- Results: staged tests + `test/nebu/{media,workers,oauth}` + admin media-settings / retention-atomic / gate tests + `release_test.exs`, `--include integration`: 3814 passed, 0 failed,
  5 skipped, 2 excluded. `mix compile --force --warnings-as-errors` clean. `npx bddgen` exit 0 (the e2e `tsc --noEmit` reports only pre-existing errors in other fixtures/node_modules, none in the new files).

### File List

- server/lib/nebu/media/config.ex
- server/lib/nebu/admin/media_settings_controller.ex
- server/lib/nebu/admin/templates/media_settings/index.html.heex
- server/test/nebu/media/config_tolerant_loader_test.exs (ATDD; recovery value 7741 -> 2741; cycle 1: bound-symmetry and old_value tests)
- server/test/nebu/media/media_config_tolerant_loader_docs_test.exs (ATDD)
- server/test/nebu/media/config_retention_days_test.exs (cycle 1: widened strict parser pinned)
- server/test/nebu/media/media_cleanup_reads_media_config_docs_test.exs (ATDD-stage AC9 adaptation: the `eh` row assertion)
- server/test/nebu/admin/media_settings_controller_test.exs (ATDD; cycle 1: role=status, copy tests, released_delete_after_days cap)
- e2e/features/admin/media-config-damaged.feature (ATDD; cycle 1: role comment)
- e2e/step-definitions/admin/media-config-damaged.steps.ts (ATDD; cycle 1: role status)
- e2e/fixtures/db.ts (ATDD: media_config row helpers)
- docs/architecture/05-building-blocks.md
- docs/architecture/07-deployment.md
- docs/stories/oauth-broker/follow-ups.md (`ej` closed, `ek`, `el` added)
- docs/stories/oauth-broker/media-config-tolerant-loader.md

### Change Log

- 2026-10-16: tolerant per-row decode, `damaged_keys/0`, Admin warning, repair on plain save, docs (follow-up `ej`).
- 2026-10-16: review cycle 1: writer/reader bound symmetry, audit old_value unknown on an unreadable table, warning rewritten (role=status, key lists, conditional paused sentence), strict-parser widening pinned, follow-ups ek/el.
