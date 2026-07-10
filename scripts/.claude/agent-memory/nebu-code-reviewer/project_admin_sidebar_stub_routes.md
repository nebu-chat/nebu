---
name: admin-sidebar-stub-routes
description: enhanced-logging admin-sidebar-nesting added stub routes /admin/logs/trace-map + /admin/logs/war-room pointing at LogsLive; they inherit the wrong active_nav until repointed
metadata:
  type: project
---

`admin-sidebar-nesting` (enhanced-logging, reviewed cycle 0 2026-07-07) added two
stub `live` routes in `server/lib/nebu/admin/router.ex`:
`/admin/logs/trace-map` and `/admin/logs/war-room`, both → `LogsLive, :index`.

Because `LogsLive` mount hardcodes `active_nav: "logs-monitoring"`, visiting either
stub highlights the "Live Stream" child, NOT "Trace Map"/"War Room".

**Why:** AC7 only required "clicking child items does not error" — correct
per-page highlighting is out of scope and deferred to the pages' own stories.
**How to apply:** When reviewing `trace-map-leitstand` and `war-room-dedicated-page`,
verify each repoints its route to a real view AND sets `active_nav` to
`"logs-trace-map"` / `"logs-war-room"` respectively (the nav child keys already
exist in `Nebu.Admin.Layouts` `@logs_nav_children`). Related: the coordination
contract in the story's Dev Notes item 5.
