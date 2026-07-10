---
name: project-enhanced-logging-epic
description: Status and structure of the enhanced-logging epic (Nebu) as of the operational-log-store story review, cycle 0
metadata:
  type: project
---

The `enhanced-logging` epic (branch `feature/enhanced-logging`) has at least 5
planned stories: `matrix-payload-debug-logging` (first, shipped),
`operational-log-store` (second, in code review cycle 0 as of 2026-07-05 —
foundation story: `operational_logs` table, central `:logger` handler,
`Nebu.Web.LogStore.{Handler,Writer,Retention,RouteNormalizer,PolicyCache}`,
Sweeper retention wiring, 5 new `server_config` policy keys),
`admin-logs-monitoring-view`, `admin-logs-retention-settings`,
`war-room-mode` (all three explicitly depend on `operational-log-store`).

`matrix-payload-debug-logging` explicitly excludes (separate future stories):
the DEBUG-logging enable/disable toggle (env/admin-UI) and the health-check
noise filter — AC9 scope discipline. Payload logging is gated purely on the
ambient `Logger.level()` for now. `operational-log-store` is the story that
actually adds that toggle, via `server_config` (`log_collect_info`,
`log_collect_debug`, + 3 retention keys), read through a `persistent_term`
cache (`Nebu.Web.LogStore.PolicyCache`) to avoid a real connection-pool
reentrancy deadlock the integration suite surfaced (`Handler.log/2` runs
synchronously inside `Nebu.Repo.QueryTelemetry`'s own telemetry callback).

**Why:** Two-category redaction (credentials/secrets AND chat message content)
is a hard compliance LAW for this project (ADR-022 / `Nebu.Compliance`,
GDPR-equivalent for message content) — see [[feedback_no_sensitive_data_in_logs_law]]
in the main project memory. `operational-log-store` is EXPLICITLY separate
from `Nebu.Compliance.AuditLog` (mutable/pruneable diagnostics vs.
tamper-evident/immutable compliance record) — don't conflate the two when
reviewing later stories.

**How to apply:** When reviewing later stories in this epic
(`admin-logs-monitoring-view`, `admin-logs-retention-settings`,
`war-room-mode`), check whether they reuse `Nebu.Web.LogStore`'s public API
(`get_policy/0`, `get_logs/1`, the `Writer`'s buffering seam for
`war_room_id`) rather than reimplementing, and specifically re-verify:
- `route_template` is actually populated as a structured column for the rows
  these later stories will query/group by — as of cycle 0 it is NOT for
  HTTP-sourced entries (see [[feedback_logger_metadata_vs_report_content]]),
  and `txn_id`/`device_id`/`event_type` still leak raw into `route_template`
  (see [[feedback_redaction_wiring_gap]] — same "Oracle MUST list checked
  item-by-item" discipline, now for route/ID placeholders, not just
  credential keys).
- Whether cycle-0's MAJOR findings (route_template persistence, route
  normalizer placeholder coverage) got fixed before these later stories
  started building on top of them.

As of cycle 0 code review of `operational-log-store`: 2 MAJOR findings (both
concrete, verified functional gaps a downstream story would silently inherit),
3 MINOR findings (2 of which are pre-dev test-review MINORs that were
explicitly deferred to dev-story and never actually fixed — see
[[feedback_test_review_minors_not_carried_through]]). Redaction pass-through
into the new central `:logger` handler (the single most security-critical
check for this story) was verified genuinely correct — both the PubSub
broadcast and the actual persisted DB row.


**Update (admin-logs-monitoring-view, cycle 4 code review, 2026-07-05):**
`operational-log-store` has apparently merged (LogsLive successfully calls
`Nebu.Web.LogStore.get_logs/1`/`get_policy/0`, and `handler_test.exs`/
`writer_test.exs` exist and are referenced as already-shared-state test
files). `admin-logs-monitoring-view` itself reached cycle 4 (crash fix +
test-isolation fix) with 3 new MAJOR findings in this cycle's code review:
(1) [[feedback_liveview_navigation_scoped_js_wiring]] — the cycle-3
MutationObserver filter-reapply fix doesn't survive sidebar navigation from
Dashboard/AuditLog (same `live_session`), (2) [[feedback_fix_lacks_direct_regression_test]]
— the `request_logger.ex` metadata fix (AC6) has no test proving the actual
produced shape, (3) unbounded server-side/DOM growth on the live-update path
(`entries_by_request`/`row_order`/`row_meta`/the `:rows` stream itself have
no `:limit`/eviction — only the initial 200-row DB seed is capped), despite
the story's own Dev Notes explicitly calling out this exact risk. Also note:
`server/lib/nebu/repo/query_telemetry.ex` (which `Handler.source_from_meta/1`
depends on for "ecto"-source classification) is present on disk but
UNTRACKED/uncommitted as of this review — worth checking it actually landed
before `admin-logs-retention-settings`/`war-room-mode` build on top of it.
**Update (admin-logs-monitoring-view, cycle 6 re-verification, 2026-07-05):**
All 3 cycle-4 MAJOR findings CONFIRMED RESOLVED by direct code/test reading:
M1 ([[feedback_liveview_navigation_scoped_js_wiring]]) — `document.body`
observer fix is correct, though still no E2E regression coverage for the
actual live-nav trigger. M2 ([[feedback_fix_lacks_direct_regression_test]])
— now has a genuine end-to-end regression test in `request_logger_test.exs`
(real HTTP request through the router, real PubSub subscribe, asserts on the
real broadcast entry's metadata). M3 (unbounded row growth) — `@max_rows 200`
+ `maybe_evict_oldest_row/1` evicts by `first_seq` (arrival order, not
severity) correctly, proven by a 205-broadcast regression test in
`logs_live_test.exs`; `@level_counts`/`@source_counts`/`@endpoint_counts` are
deliberately left uncapped but are bounded-by-design (fixed key sets /
`RouteNormalizer.normalize_route/1`'s finite placeholder vocabulary), not an
actual leak. Dev agent also found and fixed a 4th, more severe latent bug:
`Handler.source_from_meta/1` keyed off a bare `:module` metadata key that
real `Logger.*` macro calls never set (only `:mfa`) — meaning `source`
silently resolved to `"unknown"` for ALL real HTTP/Ecto traffic in
production (only passed in tests because fixtures hand-set `source: "http"`
directly, never exercising the classification function against real
metadata shape). Confirmed empirically correct (see addendum in
[[feedback_logger_metadata_vs_report_content]]) and confirmed no other code
relied on the old always-"unknown" behavior. Overall cycle 6 verdict: CLEAN,
modulo the M1 test-coverage MINOR carried forward.

**Update (trace-map-filter-reset-bugfix, cycle 1 reverify, 2026-07-06):**
Bug-fix story off the `admin-logs-monitoring-view` epic — Trace Map filter
was client-side-only (AC3 of that story) and got silently reset by any
unrelated re-render. Cycle 0 code review found 3 MAJOR (M1 multi-select-
within-a-dimension reintroduces the bug, M2 popstate->sync_filters crashes
sibling admin LiveViews with no mounted-view guard, M3 AC2 e2e test
intercepted the wrong transport — WebSocket route on a ThrottledLongPoll-only
admin UI, see [[feedback_e2e_socket_delay_wrong_transport]]) + 4 MINOR. Cycle
1 reverify: all 3 MAJOR independently confirmed genuinely fixed (list-based
`@active_filters` per dimension with membership checks everywhere; M2 fixed
via a dedicated `#trace-map-sync-anchor` DOM marker existence-guard in
`pushFilterSyncToServer`, see [[feedback_shared_livesession_global_pushevent]];
M3's test now intercepts `/admin/live/longpoll`, confirmed to match the real
`Nebu.Admin.Endpoint` socket mount). 3 of 4 MINORs fully resolved; 1 new
residual half-fix found: the "off"-tier URL-seeding bypass guard was added to
`active_filters_from_params/2` (mount-time seed) but not to the sibling
`handle_event("sync_filters", ...)` (popstate wholesale-replace) path — see
[[feedback_policy_guard_fixed_one_entry_point_only]]. No new MAJOR found.

**Update (trace-map-filter-reset-bugfix, cycle 2 reverify, 2026-07-06):** The
cycle-1 residual MINOR (sync_filters bypassing the off-tier `level_off?/2`
guard) is now genuinely fixed — `handle_event("sync_filters", ...)` reads
`socket.assigns.policy` and applies the identical
`Enum.reject(&level_off?(policy, &1))` to the `level` dimension only
(endpoint/source correctly left unguarded — confirmed via `Nebu.Web.LogStore`
that only `level` has an off-tier policy concept). New regression test
directly exercises the `sync_filters` handle_event clause with a raw
`"debug"` scalar and a real `server_config` write, asserting both immediate
and post-broadcast `aria-pressed="false"` — verified this test fails without
the fix (aria-pressed is driven purely by `@active`, independent of `@off`,
in `trace_map_bubble.ex`). However: a THIRD write site for the same
`@active_filters["level"]` state — `handle_event("toggle_filter", ...)` /
`toggle_filter_value/3`, the direct bubble-click path — still has NO
`level_off?/2` guard at all, and it's the most directly reachable of the
three (a bare `socket.main.pushEvent("toggle_filter", {dimension: "level",
value: "debug"})` from devtools needs no URL-crafting or navigation). Flagged
as a new MINOR this cycle (not yet fixed) — this is the SAME recurring class
of bug for a third time in one story; see updated
[[feedback_policy_guard_fixed_one_entry_point_only]].
