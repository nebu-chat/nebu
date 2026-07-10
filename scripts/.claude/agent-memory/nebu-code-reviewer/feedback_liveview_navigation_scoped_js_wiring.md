---
name: feedback-liveview-navigation-scoped-js-wiring
description: MutationObserver/DOM-dependent JS wiring that only runs once at boot() breaks when LiveView client-side "live navigation" (same live_session) skips a full page reload
metadata:
  type: feedback
---

Nebu's admin `app.js` wires several DOM patterns because the admin CSP
(`script-src 'self'`, no `unsafe-inline`) rules out inline `<script>` tags,
so all LiveView-adjacent JS lives in `priv/static/assets/app.js`'s `boot()`,
called once on `document.addEventListener("DOMContentLoaded", boot)`.

**The bug pattern:** a `boot()`-time helper that does
`document.getElementById("some-live-view-specific-container")` and bails
(`if (!container) return;`) when absent, guarded by a "wire once ever" flag
(`window.__xyzWired`), will NEVER get (re-)wired for a user who arrives at
that LiveView via `<.link navigate="...">` from ANOTHER LiveView in the
SAME `live_session` block — Phoenix LiveView's "live navigation" between
routes in one `live_session` reuses the existing socket/DOM and does NOT
re-fire `DOMContentLoaded`. If the container didn't exist on whatever page
the browser tab ORIGINALLY loaded (e.g. the operator's first page after
login was Dashboard, not this LiveView), the container-dependent wiring is
permanently skipped for that tab, even after navigating to the page where
it's needed.

Found in `enhanced-logging/admin-logs-monitoring-view` cycle 4: a cycle-3 fix
added a `MutationObserver` on `#request-rows` (`wireTraceMapRowObserver`,
nested inside `wireTraceMapFilters()`'s own "wire once" guard) to reapply
the client-side Trace Map filter to newly-streamed rows. `DashboardLive`,
`AuditLogLive`, and `LogsLive` all share one `live_session :admin` block, and
the sidebar nav uses `<.link navigate=...>` — so navigating Dashboard →
Logs via the sidebar (the normal way an operator gets there) never re-runs
`boot()`, and `#request-rows` didn't exist when `boot()` DID run (on
whatever page was first loaded), so the observer never attaches. This
silently reintroduces the exact bug the cycle-3 fix was written to solve,
and none of the ExUnit tests (can't run browser JS) or the Playwright e2e
scenarios (every scenario does a fresh `page.goto()`/direct navigation, never
a sidebar click from another admin page) can catch it.

**Why:** page-agnostic listeners in the same file (`wireDetailPanelFocus` on
`document.body`, `wireLiveUpdatesPause` on `document`/scroll-target-checked-
at-event-time) survive live navigation fine because they don't require their
target element to exist AT WIRE TIME — only container-specific `getElementById`
+ early-return patterns are fragile this way. The dev agent's own comments
claimed parity with `wireDetailPanelFocus` as precedent, but that comparison
doesn't hold — the wiring granularity is different.

**How to apply:** when reviewing any new `app.js` MutationObserver/DOM-lookup
wiring for a LiveView-backed admin page, check (a) is the target container
looked up once behind a "wire once ever" guard, and (b) is that LiveView in
the same `live_session` as other admin LiveViews reachable via `<.link
navigate>` from a state where the container wouldn't yet exist. If both are
true, flag as MAJOR — this is a real, repeatable regression class in this
codebase (this is the SECOND time in one story that DOM-patch/observer timing
assumptions caused a filter-reapplication bug — see also the cycle-3 fix this
one was supposed to have been analogous to). The fix is either: re-run the
container lookup on every LiveView mount signal (e.g. a `phx-hook`
`mounted()`/`updated()` callback tied to the actual template element, not a
free-standing `boot()`-time observer), or observe a page-agnostic ancestor
(like `document.body`) instead of the specific by-id container.

## Update (2026-07-05, cycle 6 re-verify): fix confirmed correct, but still zero regression coverage

The cycle-5 fix to `wireTraceMapRowObserver()` (`server/priv/static/assets/app.js`)
— switching the `MutationObserver` target from `document.getElementById("request-rows")`
to `document.body` with `{childList: true, subtree: true}` — is CONFIRMED
CORRECT by direct code reading in cycle 6: it now matches `wireDetailPanelFocus`'s
already-working `document.body` pattern exactly, is container-existence-agnostic,
and `applyTraceMapFilters()` is idempotent so over-firing is safe (just wasteful).

BUT: the E2E suite's `"the operator navigates to {string}"` step
(`e2e/step-definitions/admin/bootstrap.steps.ts`) is `page.goto(...)` — a hard
navigation — for EVERY scenario in `logs-monitoring.feature`. There is still no
Playwright scenario that reproduces the actual bug trigger (arrive at
Dashboard/AuditLog first, then click a sidebar `<.link navigate>` into
`/admin/logs` within the same `live_session`, THEN stream in a new row). This
is the SAME gap noted when the bug was first found in cycle 4 — three review
cycles later (3 → 4/5 fix attempt → 6 re-verify) there is still no automated
guard against this exact regression class recurring a third time. Classified
MINOR in cycle 6 (code is correct now) but flag as a candidate for promotion to
MAJOR if this file's `boot()`-time wiring breaks again without one.

**How to apply:** when this pattern recurs, push back on "verified by code
reading" as sufficient — ask whether a live-nav-via-sidebar-click E2E step
exists yet, and if not, treat repeated recurrence (2+) as justification to
require one rather than re-accepting a manual-trace-only fix again.
