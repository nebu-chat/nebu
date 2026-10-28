# Code review cycle 0 — media-config-tolerant-loader (0 MAJOR, 6 MINOR, 8 INFO)
M1 Moduledoc config.ex ~91-98: new "## Tolerant per-row decode" heading sits inside the seams bullet list; move after the list.
M2 Writer/reader bounds asymmetric: reader treats >=19 digit strings as damaged; validate_value/2 (plain integer keys, released_delete_after_days) and controller validate_released_delete_after_days accept any integer >= 0 -> a saved 10^18+ is read as damaged right after a successful save. Cap writer (10^18-1 or sane limit) + controller cap for released_delete_after_days + test.
M3 do_upsert_sequential/3 `_ ->` branch (loader answered non-map / :error) records the DEFAULT as audit old_value; use :unknown + test (check existing fixtures expecting the default).
M4 Warning copy (index.html.heex:25) overpromises: "Saving this form rewrites the settings shown here" is false for damaged keys the form does not carry (alert thresholds, scan_kill_switch...) -> stay damaged, SQL only; and a plain Save of damaged deleted_days/infected_days silently writes the shown default (30/7) and resumes irreversible cleanup. Fix copy: saving writes the shown value and resumes cleanup; name keys that need SQL; add short break-glass SQL line in 07-deployment.md for those keys.
M5 Dev Record File List incomplete: e2e feature/steps/db.ts, and the drive-by edit of media_cleanup_reads_media_config_docs_test.exs (eh row). List them (AC9 adaptations).
M6 No test pins the widened strict parser ({1,6} -> {1,18}): "0000000" now reads as 0 days (destructive reader). Add test in config_retention_days_test.exs for "0000000"/"0003650" OR keep strict parser at 6 digits via separate rule (decide + document).
INFO: I1 do_refresh on :error replaces good cache with all defaults incl. empty mime_denylist (pre-existing); I2 parse_nonneg typed ints any size (seam only); I3 e2e waits <=75s for TTL; I4-I8 fine.

# UX gate (0 blocking violations), advisories
A1 role="alert" on persistent server-rendered notice: convention in repo is role="status" (or role="note"); change (e2e selector is data-testid; controller tests may assert role=alert -> update tests).
A2 copy does not say why unreadable (non-numeric or out of allowed range); do not echo the value.
A3 keys not on the form cannot be repaired by Save: split list into form keys / not-on-form keys with text "not editable here; repair via database"; add test.
A4 "cleanup paused" sentence unconditional: show only if deleted_days or infected_days is in the list, name the key.
A5 render keys as <code> in a <ul>/separate <code>, short lead sentence + list; keep data-testid and the words "paused" + key names for e2e.
A6 optional warning prefix consistency (aria-hidden) — skip unless trivial. A7 contrast unverified (same DaisyUI alert-warning pattern).
