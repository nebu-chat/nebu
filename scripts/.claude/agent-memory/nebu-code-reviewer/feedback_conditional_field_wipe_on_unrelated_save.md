---
name: feedback-conditional-field-wipe-on-unrelated-save
description: Admin settings forms where a field's <input> is server-conditionally rendered on that SAME field's own enabled/disabled state — saving while disabled silently wipes stored value via absent-param-means-blank logic
metadata:
  type: feedback
---

When a HEEx template renders a group's inputs only `:if={@state.<x>_enabled}` (the input
doesn't exist in the DOM at all while disabled — not just CSS-hidden), and the controller's
per-field validation treats a MISSING param the same as an explicitly blank one (e.g.
`String.trim(params["x_days"] || "")`), then ANY form submission made while `<x>` is
disabled will silently overwrite `<x>`'s previously-stored value with "no limit"/blank —
even if the operator only intended to change a DIFFERENT, unrelated field/level in the
same form. Found in `admin-logs-retention-settings` (server/lib/nebu/admin/logs_controller.ex
`validate_level/2`): toggling DEBUG only, while INFO was off with a previously-configured
5-day retention, wiped INFO's retention to unlimited on save.

**Why:** the underlying policy/pruning logic is often independent of the "enabled" flag
(e.g. `Nebu.Web.LogStore.Retention.prune_operational_logs/0` prunes by retention days/count
regardless of `log_collect_info`), so a wiped-to-unlimited value has a real, delayed
operational consequence (unbounded growth) that won't surface until the level is
re-enabled — easy to miss in review and in tests, since tests tend to submit forms with all
fields present/explicit rather than a partial submission for an already-disabled sibling.

**How to apply:** whenever reviewing a multi-section admin settings controller where each
section's retention/config inputs are conditionally rendered on that section's own toggle
state, explicitly check: does saving section B while section A is disabled preserve A's
previously stored values, or does A's absent-from-DOM fields get treated as "blank ⇒
reset"? Look for (or ask for) a test that seeds a stored value for a disabled section, then
submits a save touching only a different section, and asserts the disabled section's value
survived unchanged. Absence of such a test is itself a signal to check the logic by hand.
Related: [[feedback_test_review_minors_not_carried_through]], [[feedback_fix_lacks_direct_regression_test]].

**Cycle-1 update (2026-07-05):** dev-story's fix was verified correct — `validate_level/2`
now branches on the `enabled` flag (not on param presence) before including the
`log_retention_<level>_days`/`_max_count` keys in the returned changes map, so it is also
robust against the JS layer's `display:none` toggle-off (which leaves stale field values
in the DOM/POST body rather than removing the nodes — see
`server/priv/static/assets/app.js`'s `toggleLogsConfigLevel`). A genuine regression test
was added (`describe "AT5 ..."`, seeds a stored value for the disabled level, submits a
save touching only the other level, asserts the disabled level's stored value survived) —
confirmed it would fail against the pre-fix code. This is the pattern working as intended;
see [[feedback_fix_lacks_direct_regression_test]] for the counter-example where a fix
shipped without such a test.
