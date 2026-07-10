# Memory

## PRD Accessibility Requirements
_Filled during First Breath — the specific requirements from the PRD. Hard constraints for every session._

## Component Library
Tailwind + DaisyUI. `btn`/`btn-sm`/`btn-active`/`btn-outline` for toggleable filter bubbles (see `TraceMapBubble`), `badge`/`badge-outline` for chips, `card`/`bg-base-200` for form panels.

## Template Conventions
**Correction (2026-07-06): this sanctum was inherited from a different (Go-based) project.** The stack described in CREED.md's Dominion section ("Go Templates", `gateway/internal/admin/`) is WRONG for this repo. Actual stack: **Phoenix LiveView + HEEx**, admin UI lives at `server/lib/nebu/admin/`. Static/controller pages use `*_html.ex` + `templates/**/*.html.heex`; live pages (`LogsLive`, `DashboardLive`, `BootstrapLive`, `AuditLogLive`) are `Phoenix.LiveView` modules with inline `~H` templates. Shared chrome is `Nebu.Admin.Layouts` (`:live` layout = topbar + left sidebar, `@active_nav` highlights the current item). Sidebar nav is currently a FLAT list (`layouts.ex` `nav_item`s) — no nested/collapsible tree exists yet, even for logically-nested items like `/admin/config/role-mapping`.
Client JS lives directly in `server/priv/static/assets/app.js` (committed as source, not bundled from a separate `assets/js/` — only CSS goes through a build step via `assets/package.json`'s `tailwindcss` script). CSP is `script-src 'self'`, no `unsafe-inline` — LiveView `phx-click` bound to `Phoenix.LiveView.JS.dispatch/2` custom events, picked up by named `wire*` functions in `app.js` (e.g. `wireTraceMapFilters`), is the established pattern for client-only interactions that must not round-trip to the server.

## Playwright Patterns
_Base URL, auth helper, selector conventions, test file organization._

## Known Accessibility Gaps
_Pages or components with known accessibility issues to watch._

## Known Correctness Gaps (non-a11y)
- **CONFIRMED BUG (2026-07-06, live-reproduced):** `/admin/logs` Trace Map filter bubbles lose their `aria-pressed`/`btn-active` state (and the actual row filtering) within ~10-15s of live traffic, even with zero War Room session active. Root cause: `TraceMapBubble.trace_map_bubble` calls in `logs_live.ex` never pass an `active` attr, so the component's `@active` is a permanent `false` — filter "pressed" state lives ONLY in client-DOM (`aria-pressed`, `btn-active` class), set by `app.js`'s `wireTraceMapFilters`. Every new log entry re-renders the bubble list (count badges change), and the server-rendered patch for that comprehension item overwrites the button's attributes back to the `active:false` baseline, wiping the click. Confirmed via Playwright: clicked a bubble (`aria-pressed` → `true`), waited 12s under live traffic, `aria-pressed` was back to `"false"` and all 107 rows visible (filter silently cleared). Fix direction: stop layering client-only toggle state on a DOM node whose siblings churn every render — either move filter state into real LiveView assigns driven by URL query params (`push_patch` + `handle_params/3`), or restructure so the live count badge is a sibling node outside the toggle button so the button itself never gets re-patched.
