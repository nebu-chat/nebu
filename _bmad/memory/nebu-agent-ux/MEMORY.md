# Memory

## Stack Reality (CRITICAL — corrects the old sanctum)
The Admin UI is **NOT** Go Templates in `gateway/`. It is **Phoenix LiveView +
dead-controller HEEx** under `server/lib/nebu/admin/`, Tailwind + DaisyUI theme
**`nebu`** (ADR-021 Pure Elixir, single OTP app). Two render modes coexist:
true LiveViews (`dashboard_live.ex`, `audit_log_live.ex`) and dead-controller
HEEx pages with POST forms (users/rooms/spaces). Strict CSP
(`script-src 'self'`, no inline JS) → interactivity via `phx-*`; destructive
confirmations today use `window.confirm()` via `data-confirm` in `app.js`, but
NEW LiveViews should use CSP-safe `phx-click` LiveView modals.

## Component Library
Tailwind + DaisyUI. `btn`/`btn-sm`/`btn-active`/`btn-outline` for toggleable filter bubbles (see `TraceMapBubble`), `badge`/`badge-outline` for chips, `card`/`bg-base-200` for form panels.

## Template Conventions
**Correction (2026-07-06): this sanctum was inherited from a different (Go-based) project.** The stack described in CREED.md's Dominion section ("Go Templates", `gateway/internal/admin/`) is WRONG for this repo. Actual stack: **Phoenix LiveView + HEEx**, admin UI lives at `server/lib/nebu/admin/`. Static/controller pages use `*_html.ex` + `templates/**/*.html.heex`; live pages (`LogsLive`, `DashboardLive`, `BootstrapLive`, `AuditLogLive`) are `Phoenix.LiveView` modules with inline `~H` templates. Shared chrome is `Nebu.Admin.Layouts` (`:live` layout = topbar + left sidebar, `@active_nav` highlights the current item). Sidebar nav is currently a FLAT list (`layouts.ex` `nav_item`s) — no nested/collapsible tree exists yet, even for logically-nested items like `/admin/config/role-mapping`.
Client JS lives directly in `server/priv/static/assets/app.js` (committed as source, not bundled from a separate `assets/js/` — only CSS goes through a build step via `assets/package.json`'s `tailwindcss` script). CSP is `script-src 'self'`, no `unsafe-inline` — LiveView `phx-click` bound to `Phoenix.LiveView.JS.dispatch/2` custom events, picked up by named `wire*` functions in `app.js` (e.g. `wireTraceMapFilters`), is the established pattern for client-only interactions that must not round-trip to the server.
## PRD Accessibility Requirements (hard constraints, every session)
- **NFR-A1:** Admin UI meets **WCAG 2.1 Level AA** — legal minimum for DE/EU
  public bodies. Blocking, not advisory.
- **NFR-A2:** Fully keyboard-navigable, no mouse dependency.
- **NFR-A3:** Screen-reader usable — semantic HTML + ARIA where needed.
- UX-shaping companions: all admin actions audited (FR35, append-only Ed25519
  NFR-S3); four-eyes + documented reason + 24h timebox (FR30-32); roles
  `instance_admin`/`compliance_officer` via OIDC (FR4); URL-addressable state,
  no LocalStorage (FR50/NFR-O4); DE+EN from OIDC claim/profile (NFR-L1).

## Component Library (DaisyUI theme `nebu`, real classes in use)
- Tokens in `server/assets/tailwind.config.js`: primary `#f97316`, base-100
  `#111827` (page), base-200 `#1f2937` (surface/sidebar/cards), base-300
  `#374151` (hover/border), base-content `#f9fafb`; success/warning/error/info.
  Single dark theme, `data-theme="nebu"`.
- Buttons `btn btn-primary`/`btn-error`/`btn-ghost` (+`btn-sm`/`btn-xs`).
- Badges `badge badge-{success,warning,error,ghost}` (`badge-sm`).
- Tables: two conventions — plain `table w-full` (users/rooms) vs
  `table table-zebra` in `overflow-x-auto` (config/compliance/audit). Prefer
  zebra+overflow for new tables. `<th scope="col">` present on users/rooms,
  MISSING on config/compliance/audit.
- Forms: `form-control` label wrapper, `input input-bordered`,
  `select select-bordered`, hint via `label-text-alt`, hidden `_csrf_token`,
  pseudo-DELETE via hidden `_method`.
- Cards: `card bg-base-200` + `card-body`; big numbers via `text-display`.
- Flash: inline `alert alert-success`/`alert-error` with `role="status"`/
  `role="alert"` — duplicated per template, NOT a shared component.
- MISSING today (greenfield): modal/dialog component, toast system,
  pagination UI (keyset cursor exists in `admin/db.ex`, unsurfaced).
- Fonts: Inter (sans), JetBrains Mono (mono — IDs/hashes), self-hosted, no CDN.

## Template Conventions
- Per-resource `*_html.ex` (`use Phoenix.Component` + `embed_templates`);
  templates in `admin/templates/<resource>/{index,show,new}.html.heex`.
  LiveViews inline `~H`.
- Shell: `layouts.ex` — topbar `h-12 bg-base-300`, sidebar
  `nav.w-60 bg-base-200`, `main#main-content.overflow-auto.p-6`, skip-link,
  `role=banner/main`. Nav via `nav_item/1` + `@active_nav` + `aria-current` +
  `data-navkey`. `layouts.ex:45-55` handles BOTH LiveView (`assign_new`) and
  dead-controller (`Map.put_new`) renders.
- Helper fns colocated in `*_html.ex` (e.g. `status_badge_class/1`).
- Control flow `:if=`/`:for=`, interpolation `{...}`; IDs URL-encoded.
- `/admin/config` (ADR-022 bootstrap-only: env read-once prefill, explicit
  Save, no auto-save) is the template for new settings pages.

## Playwright Patterns
- **playwright-bdd** (`createBdd`) over Playwright. Config
  `e2e/playwright.config.ts`. Projects: `admin-ui` (`features/admin/**`),
  `element-web`, `website`. `workers:1`, `fullyParallel:false` (shared DB).
- Base URL admin: `NEBU_ADMIN_URL ?? http://localhost:8008`.
- Steps `e2e/step-definitions/{admin,element,common,website}/*.steps.ts`;
  fixtures `e2e/fixtures/` (`nebu-fixtures.ts`, `dex-auth.ts`, `users.ts`).
- Admin login: `Given('the operator is logged in as admin')`
  (bootstrap.steps.ts); real Dex OIDC PKCE flow, no cookie forging.
- Selectors: `getByRole` primary + `data-role`/`data-page`/`data-section`/
  `data-status` hooks baked into templates AS acceptance guards.
  **Do not rename/remove these hooks — additive only.** Default tag filter
  excludes `@pending-feature` and `@short-ttl`.

## Known Accessibility Gaps
_Pages or components with known accessibility issues to watch._
- **Established rule, reaffirmed 2026-07-20:** any poll-driven, appear/disappear
  status content in the admin UI (precedent: `WarRoomIndicator`'s topbar pill,
  `layouts.ex:138`; `MediaAttentionBadge`'s nav badge, `layouts.ex:212`) MUST carry
  `role="status"` (implicit `aria-live="polite"` + `aria-atomic="true"`) plus an
  sr-only text equivalent when the visible content is abbreviated/iconic. This is
  written into `layouts.ex`'s own UX-gate comments as a hard rule, not a nice-to-
  have. Story 10b's `ClamAVStatusIndicator`/`MediaHealthLive` ClamAV-status section
  (poll-ticked the same way) shipped WITHOUT this — flagged blocking in that
  story's UX audit gate. Check every new poll-ticked status section against this
  rule before sign-off.

## Known Correctness Gaps (non-a11y)
- **CONFIRMED BUG (2026-07-06, live-reproduced):** `/admin/logs` Trace Map filter bubbles lose their `aria-pressed`/`btn-active` state (and the actual row filtering) within ~10-15s of live traffic, even with zero War Room session active. Root cause: `TraceMapBubble.trace_map_bubble` calls in `logs_live.ex` never pass an `active` attr, so the component's `@active` is a permanent `false` — filter "pressed" state lives ONLY in client-DOM (`aria-pressed`, `btn-active` class), set by `app.js`'s `wireTraceMapFilters`. Every new log entry re-renders the bubble list (count badges change), and the server-rendered patch for that comprehension item overwrites the button's attributes back to the `active:false` baseline, wiping the click. Confirmed via Playwright: clicked a bubble (`aria-pressed` → `true`), waited 12s under live traffic, `aria-pressed` was back to `"false"` and all 107 rows visible (filter silently cleared). Fix direction: stop layering client-only toggle state on a DOM node whose siblings churn every render — either move filter state into real LiveView assigns driven by URL query params (`push_patch` + `handle_params/3`), or restructure so the live count badge is a sibling node outside the toggle button so the button itself never gets re-patched.
## Known Accessibility Gaps (watch these)
- `<th>` without `scope` on config/compliance/audit tables.
- Inputs with only `aria-label`, no visible `<label for>` (spaces create,
  config scopes).
- No focus management for dynamic content; no `aria-live` region for
  LiveView-updated flashes; no modal a11y (no modals exist yet).
