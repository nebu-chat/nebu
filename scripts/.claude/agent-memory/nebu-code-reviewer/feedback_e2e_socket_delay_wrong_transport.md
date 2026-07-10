---
name: e2e-socket-delay-wrong-transport
description: Admin app.js forces ThrottledLongPoll transport (no websocket) — an e2e AC-guard that page.routeWebSocket(/admin/live/websocket/) to inject latency is INERT and silently vacuous
metadata:
  type: feedback
---

Nebu's admin `app.js` `boot()` builds `new LiveSocket("/admin/live", Socket,
{ transport: ThrottledLongPoll, ... })` — the admin LiveView connection is
FORCED longpoll (`/admin/live/longpoll`), there is NO websocket connection.

**The bug pattern:** an e2e step that injects artificial latency via
`page.routeWebSocket(/\/admin\/live\/websocket/, ...)` matches nothing, so
the delay never applies and any "no perceptible lag despite a slow socket"
AC guard passes VACUOUSLY. Found in
`enhanced-logging/trace-map-filter-reset-bugfix`: the AC2 regression
scenario's "the admin LiveView socket is artificially delayed by N seconds"
Given targets `/admin/live/websocket` (inert) AND throttles a `push_patch`
round trip that the shipped mechanism no longer makes (the toggle is now
client-side `JS.dispatch` + fire-and-forget `JS.push`). Doubly inert.

**How to apply:** any admin e2e latency/interception must target the LONGPOLL
transport, not websocket. When you see `routeWebSocket` in an admin-facing
scenario, flag it — it almost certainly matches nothing. Also re-check that
throttled-round-trip AC guards still correspond to a round trip the shipped
code actually performs; a mechanism swap (patch/handle_params -> JS.push/
client-side pushState) can leave the guard testing a phantom.
