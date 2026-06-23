---
story_id: admin-ui-migration
title: "Admin UI Migration — Phoenix LiveView"
epic: full-elixir-stack
status: done
security_review: required
created: 2026-06-17
branch: feature/full-elixir-stack
---

## Summary

Migrate the Admin UI from Go templates (Go admin backend) to Phoenix LiveView. The result is a reactive
server-side-rendered UI — state changes pushed as DOM diffs via WebSocket — without a SPA build pipeline.
After this story the Go admin backend container is removed from `docker-compose.yml`.

Features to port: Room Management (auto-join toggle, room list), User Overview (OIDC-imported users),
Bootstrap Wizard (instance setup steps).

## User Story

As a Nebu instance admin,
I want the Admin UI served by Phoenix LiveView,
So that the UI is reactive without a SPA build pipeline and the Go admin backend can be removed.

## Acceptance Criteria

1. **Given** an admin user navigates to `/admin`,
   **When** they are authenticated via OIDC (admin claim present in token),
   **Then** the Phoenix LiveView admin dashboard renders with the same feature set as the Go-template Admin UI:
   Room Management, User Overview, Bootstrap Wizard.

2. **Given** an admin uses the Room Management LiveView,
   **When** they change the auto-join status of a room via the toggle,
   **Then** the change is reflected in the UI immediately (LiveView DOM-diff push) without a full page reload,
   and the change is persisted to the database.

3. **Given** a non-admin user (no admin claim in OIDC token) navigates to `/admin`,
   **When** their claims are checked by the LiveView mount guard,
   **Then** `403 Forbidden` is returned (or redirect to `/admin/login`) — admin gate is preserved.

4. **Given** the Go admin backend container,
   **When** this story is complete,
   **Then** it is removed from `docker-compose.yml`; all `/admin/*` routes are served by Phoenix.

5. **Given** the existing Admin UI Playwright + Gherkin E2E test suite,
   **When** run against the Phoenix LiveView Admin UI,
   **Then** all previously passing scenarios still pass (no regression).

6. **Given** the Bootstrap Wizard is accessed for the first time on a fresh installation,
   **When** an admin completes all wizard steps,
   **Then** the wizard behaves identically to the Go-template version (same step sequence, same persistence).

## Acceptance Tests

### Tests written FIRST (before implementation code):

1. **`e2e/features/admin-ui-liveview.feature`** — Playwright + Cucumber scenario
   - Given: admin session via real OIDC Authorization Code + PKCE flow (Dex)
   - When: `/admin/rooms` is visited
   - Then: room list renders with room names and auto-join toggles visible

2. **`e2e/features/admin-ui-room-toggle.feature`** — Playwright + Cucumber scenario
   - Given: admin session; room "general" exists with auto-join disabled
   - When: admin clicks the auto-join toggle for "general"
   - Then: toggle updates in-place (no full reload); database reflects the change; page refresh still shows toggle on

3. **`e2e/features/admin-ui-auth-gate.feature`** — Playwright + Cucumber scenario
   - Given: non-admin user (no admin claim)
   - When: navigates to `/admin`
   - Then: receives `403` or is redirected to an error page

4. **`test/admin_liveview_unit_test.exs`** — ExUnit + Phoenix.LiveViewTest
   - Given: LiveView mounted with admin assigns
   - When: `handle_event("toggle_auto_join", %{"room_id" => id}, socket)` is called
   - Then: `socket.assigns.rooms` is updated and a DB call to `update_auto_join` is made

## Implementation Notes

- Add `phoenix` and `phoenix_live_view` to the `nebu_http` OTP app (or a dedicated `nebu_admin` app)
- Phoenix LiveView requires a `Phoenix.PubSub` — reuse the existing `pg`-backed PubSub already in the umbrella
- Admin auth gate: implement as a `on_mount` hook that checks `conn.assigns.current_user.admin == true`
- UI feature parity required; visual design can differ from Go templates but must be WCAG AA compliant
- TailwindCSS + DaisyUI are the approved UI libraries (as per existing Admin UI)
- Bootstrap Wizard: the multi-step state is stored in LiveView socket assigns + a DB-backed `bootstrap_state` table
- Do NOT use Next.js, React, or any SPA framework — Phoenix LiveView only
- OIDC testing: Authorization Code + PKCE only (per CLAUDE.md); no `grant_type=password`

## Tasks / Subtasks

- [x] Add `phoenix`, `phoenix_live_view`, `phoenix_pubsub`, `phoenix_html` deps to `nebu_http`; regenerate `mix.lock`; add `lazy_html` (test-only) for `Phoenix.LiveViewTest`.
- [x] Create `NebuHttp.AdminEndpoint` (Phoenix.Endpoint, `server: false`) + `Phoenix.PubSub` (`NebuHttp.PubSub`) child; start both under the Application (gated by `:start_admin_endpoint`).
- [x] Mount the `/admin` subtree into the existing Bandit listener by dispatching from `NebuHttp.Router` to `NebuHttp.AdminEndpoint.call/2` (preserving `path_info`, no `forward` prefix-strip).
- [x] Implement the admin gate: `NebuHttp.Admin.Auth` `on_mount {:require_admin}` (AC3, redirects non-admins to `/admin/login`) + the `fetch_current_user` plug; admin-claim derivation mirrors Go `MatchesAdminGroupClaim` (inline-SQL `server_config.admin_group_claim`).
- [x] `NebuHttp.Admin.RoomsLive` (AC1 + AC2): inline-SQL room list, per-row `data-room-id`/`data-auto-join` + `phx-click="toggle_auto_join"` toggle; `handle_event` updates assigns AND writes via the `:admin_auto_join_writer` seam (default = inline `UPDATE rooms SET is_auto_join = $1 WHERE room_id = $2`).
- [x] `NebuHttp.Admin.UsersLive` (AC1): inline-SQL read-only user overview.
- [x] `NebuHttp.Admin.BootstrapLive` (AC6): 4-step wizard (instance → OIDC → claims → finish), draft persisted to `bootstrap_draft`, finished into `server_config` + `bootstrap_completed` (inline SQL).
- [x] Layouts + vendored LiveView JS client (`phoenix.min.js` + `phoenix_live_view.min.js` + `app.js`) and a dependency-free WCAG-AA `app.css` under `priv/static`.
- [x] Make `core/apps/nebu_http/test/nebu_http/admin_liveview_unit_test.exs` green (added the single required `@endpoint` attribute).
- [x] Bind the three new `.feature` files via `npx bddgen` (steps resolve; full browser run is the CI gate).
- [~] AC4 cutover (remove Go admin handlers / route all `/admin/*` to Phoenix) — PARTIAL: LiveView pages + gate are served by `core`; full cutover deferred (see Completion Notes) because the Go OIDC login/session flow must move to Phoenix first.

## Dev Agent Record

### Completion Notes

- **Rooms PK column:** `room_id` (verified in `gateway/migrations/000001_init.up.sql`; `is_auto_join BOOLEAN NOT NULL DEFAULT false` is on the same `rooms` table). Inline write: `UPDATE rooms SET is_auto_join = $1 WHERE room_id = $2`.
- **PubSub:** the umbrella had NO prior `Phoenix.PubSub` / `:pg`-backed PubSub. A single local `Phoenix.PubSub` (`NebuHttp.PubSub`) is started in the Application (the Implementation-Notes assumption of an existing PubSub was incorrect; documented here).
- **Admin gate:** `on_mount {NebuHttp.Admin.Auth, :require_admin}` reads `current_user` from the LiveView session; `%{"admin" => true}` continues, anything else halts with a redirect to `/admin/login` (AC3). `admin` is derived (parity with Go `MatchesAdminGroupClaim`) from the configured `admin_group_claim` (`server_config`, default `instance_admin`).
- **ADR-018:** every read/write is inline SQL via `Ecto.Adapters.SQL.query/3` against `Nebu.Repo`. No Ecto.Schema / Changeset / Query builder / repository / service layer. SQL is duplicated per-file by design.
- **AC2 test seam:** the auto-join write is dispatched through the `:admin_auto_join_writer` app-env boundary (default = real inline SQL), matching the established `media/db.ex` pattern; the unit test installs a function-backed fake. The SQL stays inline in `RoomsLive`; only its execution point is injectable.
- **`@endpoint` in the unit test:** `Phoenix.LiveViewTest.live_isolated/3` reads `@endpoint` from the caller module at compile time and raises without it. The staged RED test had no `@endpoint`, so it could never go green regardless of implementation; the single required `@endpoint NebuHttp.AdminEndpoint` attribute was added (no behavioural change to the assertions).
- **AC4 — deferral with justification:** there is NO separate Go "admin" container to remove — the Go admin backend is compiled into the `gateway` binary. The Elixir `NebuHttp.Router` already forwards `/admin` to the Phoenix endpoint (the LiveView pages + gate are served by `core`). The full cutover (gateway proxies `/admin/*` to `core` and the Go admin handlers are deleted) is blocked on porting the Go OIDC Authorization-Code + PKCE login/callback/session flow to Phoenix: the Go `admin_session` cookie (HMAC-signed with the internal secret) and the Phoenix session cookie (signed with `secret_key_base`) are not interchangeable, so a proxied LiveView cannot read the Go session to know the operator is an admin. Cutting over without porting login would break the shared E2E "operator is logged in as admin" flow. Matrix/media routing is untouched. Tracked as a follow-up.
- **Verification:** `mix compile --warnings-as-errors` clean; `mix test --warnings-as-errors` green — `nebu_http` 76 passed (incl. `admin_liveview_unit_test.exs`), umbrella room/event apps 264 passed, others green, 0 failures. `npx bddgen` binds all three new admin-ui feature files. Pre-existing `Nebu.Repo not started` log noise is unrelated (documented known-RED).

### File List

- `core/apps/nebu_http/mix.exs` (modified — phoenix/live_view/pubsub/html + lazy_html test dep)
- `core/mix.lock` (modified — regenerated)
- `core/config/config.exs` (modified — AdminEndpoint base config + Phoenix json_library)
- `core/config/test.exs` (modified — start_admin_endpoint + AdminEndpoint test secret)
- `core/config/runtime.exs` (modified — AdminEndpoint secret_key_base in prod/dev)
- `core/apps/nebu_http/lib/nebu_http/application.ex` (modified — PubSub + AdminEndpoint children)
- `core/apps/nebu_http/lib/nebu_http/router.ex` (modified — /admin dispatch to AdminEndpoint)
- `core/apps/nebu_http/lib/nebu_http/admin_endpoint.ex` (new)
- `core/apps/nebu_http/lib/nebu_http/admin/router.ex` (new)
- `core/apps/nebu_http/lib/nebu_http/admin/auth.ex` (new)
- `core/apps/nebu_http/lib/nebu_http/admin/rooms_live.ex` (new)
- `core/apps/nebu_http/lib/nebu_http/admin/users_live.ex` (new)
- `core/apps/nebu_http/lib/nebu_http/admin/bootstrap_live.ex` (new)
- `core/apps/nebu_http/lib/nebu_http/admin/layouts.ex` (new)
- `core/apps/nebu_http/lib/nebu_http/admin/login_controller.ex` (new)
- `core/apps/nebu_http/priv/static/assets/app.css` (new)
- `core/apps/nebu_http/priv/static/assets/app.js` (new)
- `core/apps/nebu_http/priv/static/assets/phoenix.min.js` (new — vendored)
- `core/apps/nebu_http/priv/static/assets/phoenix_live_view.min.js` (new — vendored)
- `core/apps/nebu_http/test/nebu_http/admin_liveview_unit_test.exs` (modified — added required `@endpoint`)
- `docker-compose.yml` (modified — AC4 transitional-state documentation on the `core` service)

### Change Log

- 2026-06-17 — Implemented Phoenix LiveView Admin UI (Rooms/Users/Bootstrap) in `nebu_http`, mounted on the shared Bandit listener with an `on_mount` admin gate. Unit + full nebu_http suite green. AC4 full cutover deferred (login-flow port prerequisite) with documented justification.

## Status

review
