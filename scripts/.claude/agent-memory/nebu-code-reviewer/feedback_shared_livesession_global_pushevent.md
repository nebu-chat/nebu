---
name: shared-livesession-global-pushevent
description: A window-level app.js listener (popstate/etc) that unconditionally pushEvent's to socket.main crashes sibling LiveViews in the same live_session that lack a handler for that event
metadata:
  type: feedback
---

Companion to [[liveview-navigation-scoped-js-wiring]]. Same root fact —
`DashboardLive`, `AuditLogLive`, `LogsLive` all live in ONE `live_session
:admin` and the sidebar uses `<.link navigate>` (client-side live nav, no
page reload, boot() runs once) — but the FAILURE is the opposite direction.

**The bug pattern:** a global listener bound once at `boot()` (e.g.
`window.addEventListener("popstate", ...)`) that unconditionally does
`liveSocket.main.pushEvent("click", document.body, null, "<event>", ...)`
will push `<event>` to WHATEVER LiveView is currently `socket.main`, not
just the page it was written for. If the operator has live-navigated to a
sibling LiveView in the same live_session (Dashboard/AuditLog — which here
define ONLY `mount/3`+`render/1`, NO `handle_event/3` at all) and then hits
browser back/forward, the push lands on a handler-less LiveView →
UndefinedFunctionError → the LiveView process crashes and remounts.

Found in `enhanced-logging/trace-map-filter-reset-bugfix` (cycle 0 review):
`pushFilterSyncToServer()` in the `popstate` handler pushes `sync_filters`
(only `LogsLive` handles it). Guarded only by `socket && socket.main &&
typeof socket.main.pushEvent === "function"` — NO page/element check.

**How to apply:** whenever a global (window/document) app.js listener pushes
a named LiveView event, verify EVERY LiveView reachable in the same
live_session either handles that event or the push is guarded by a
page-scoped check (e.g. `document.querySelector('[data-testid="trace-map-bubble"]')`
or `location.pathname`). Also check the target LiveViews actually define a
matching `handle_event` clause — LiveView injects NO default; an unmatched
event crashes the socket. The ExUnit tests that simulate the push via
`render_click(view, "<event>", ...)` always target the RIGHT view, so they
never catch this cross-view case.
