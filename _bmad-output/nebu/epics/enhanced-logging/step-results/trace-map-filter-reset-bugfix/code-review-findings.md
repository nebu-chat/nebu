# Code Review — trace-map-filter-reset-bugfix (cycle 2 reverify)

0 MAJOR. Cycle-1's `sync_filters` fix (off-tier `level_off?/2` rejection) CONFIRMED correct and
complete: exactly mirrors `active_filters_from_params/2`'s guard, `policy` is populated at mount
so no nil-crash risk, applied only to `level` (the only dimension with off-tier semantics — verified
against `Nebu.Web.LogStore`), and the new regression test genuinely exercises the real
`handle_event("sync_filters", ...)` clause and would fail without the fix.

1 MINOR (new this cycle — third occurrence of the same bug class):

`handle_event("toggle_filter", %{"dimension" => dimension, "value" => value}, socket)` →
`toggle_filter_value/3` (`server/lib/nebu/admin/logs_live.ex:380-384, 523-527`) writes
`@active_filters` from client-pushed input with NO `level_off?/2` rejection at all — unlike both
`active_filters_from_params/2` (mount, cycle-0 fix) and `sync_filters` (popstate, cycle-1/2 fix).
This is actually the MOST directly reachable of the three entry points (the normal click path,
requiring no URL-crafting or back/forward navigation): a crafted
`socket.main.pushEvent("toggle_filter", {dimension: "level", value: "debug"})` from devtools still
lets an operator mark an off-tier level as `aria-pressed="true"` server-side. Same impact class as
the already-accepted cycle-1 MINOR (cosmetic/accessibility inconsistency — off-tier entries are
never collected so no rows are affected, and `btn-active`/`btn-outline` classing stays correct
since it's independently guarded by `not @off`; only `aria-pressed`/screen-reader semantics is
wrong).

This is now the THIRD entry point found missing this same guard across 3 review cycles (mount →
fixed cycle 0/1, sync_filters → fixed cycle 1/2, toggle_filter → found cycle 2). Whack-a-mole
pattern. **Fix by centralizing**, not by patching a 4th site later: extract a single helper (e.g.
`reject_off_tier_level(values, policy)` or apply the guard inside `normalize_filter_values/2` if a
`policy` arg can be threaded through cleanly) that all three write paths — `active_filters_from_params/2`,
`sync_filters`, and `toggle_filter_value/3` — call, so a future 4th entry point can't reintroduce
the same gap. Add a regression test for `toggle_filter` specifically (mirroring the `sync_filters`
off-tier test added in cycle 2), proving a `toggle_filter` push with an off-tier level value does
not result in that value being stored as active.

INFO (accepted, no action needed):
- Staged diff spans cycles 0-2 (nothing committed yet) — reviewer scoped this cycle's delta by
  diffing against the cycle-1 findings doc's quoted "before" snippet instead. No scope creep found.
- `remove_filter` correctly needs no guard (removal-only, can't add an off value).

## After fixing

Apply the centralized guard fix + toggle_filter regression test. Recompile, re-run
`logs_live_test.exs` + full unit suite, confirm 0 regressions. Small, targeted fix — no new manual
live verification required (cycle-1's manual checks already covered the higher-risk M1/M2 surfaces
and remain unaffected).
