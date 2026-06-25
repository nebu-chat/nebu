---
stepsCompleted:
  - step-01-preflight-and-context
  - step-02-generation-mode
  - step-03-test-strategy
  - step-04-generate-tests
  - step-04c-aggregate
lastStep: step-04c-aggregate
lastSaved: '2026-06-25'
storyId: admin-liveview-to-http
storyKey: admin-liveview-to-http
storyFile: ''
atddChecklistPath: _bmad-output/test-artifacts/atdd-checklist-admin-liveview-to-http.md
generatedTestFiles:
  - server/test/nebu/admin/admin_http_controllers_test.exs
inputDocuments:
  - server/lib/nebu/admin/router.ex
  - server/lib/nebu/admin/endpoint.ex
  - server/lib/nebu/admin/users_live.ex
  - server/lib/nebu/admin/rooms_live.ex
  - server/lib/nebu/admin/spaces_live.ex
  - server/lib/nebu/admin/claim_mapping_live.ex
  - server/lib/nebu/admin/compliance_live.ex
  - server/lib/nebu/admin/config_live.ex
  - server/test/nebu/admin/rooms_live_visibility_test.exs
  - server/test/nebu/admin/rooms_live_member_management_test.exs
  - server/test/nebu/admin/rooms_live_create_archive_test.exs
  - server/test/nebu/admin/config_live_refresh_mode_test.exs
  - server/test/nebu/admin/bootstrap_confirm_http_test.exs
---

# ATDD Checklist: Admin LiveView-to-HTTP Controller Migration

## TDD Red Phase — Complete

All red-phase acceptance test scaffolds generated and written to disk.
Tests are **active** (not skipped) per the Nebu ATDD standard — they fail
immediately because the controller modules and HTTP routes do not yet exist.

## Stack & Generation Mode

- **Detected stack**: fullstack (Elixir/Phoenix backend + Playwright E2E)
- **Test type**: ExUnit / Phoenix.ConnTest (HTTP controller tests)
  - No Playwright/Gherkin needed: story is a backend routing refactor
  - No LiveViewTest: story explicitly requires non-WebSocket routes
- **Generation mode**: AI generation (clear CRUD criteria, standard PRG pattern)
- **Execution mode**: sequential

## Test File

`server/test/nebu/admin/admin_http_controllers_test.exs`
`Nebu.Admin.HttpControllersTest`

## TDD Status

- **Total tests**: 21
- **Failing (RED)**: 11 (all POST-mutation and controller-specific tests)
- **Passing against current LiveViews**: 10 (GET routes that LiveView already serves — correct behavior, will remain green after conversion)
- **All tests compile without warnings**: ✅

## Acceptance Criteria Coverage

| AC | Description | Test | Status |
|----|-------------|------|--------|
| AC1 | All converted CRUD pages serve HTML over GET/POST, no 101 WS upgrade | `AC1/AC2 — GET /admin/users returns 200 HTML with data-page=users, no WS upgrade` | 🔴 FAIL |
| AC2 | Users page renders identically to UsersLive | (same test as AC1) | 🔴 FAIL |
| AC3 | Rooms list renders with GET `?status=<filter>` | `AC3 — GET /admin/rooms?status=active returns 200 HTML` | 🟡 PASS (LiveView serves it) |
| AC4 | Auto-join toggle POST → redirect to /admin/rooms | `AC4 — POST /admin/rooms/:id/auto-join calls writer and redirects` | 🔴 FAIL |
| AC5 | Room detail GET + visibility save POST → redirect with flash | `AC5 — GET /admin/rooms/:id returns 200 HTML with visibility form` + `AC5 — POST /admin/rooms/:id/settings` | 🔴 FAIL |
| AC6 | Archive POST → redirect with flash | `AC6 — POST /admin/rooms/:id/archive redirects with 'Room archived' flash` | 🔴 FAIL |
| AC7 | Add member POST validates user_id; remove via _method=DELETE | `AC7 add-member — invalid Matrix user_id returns 200 with error` + success + delete | 🔴 FAIL |
| AC8 | Spaces pages analogous to Rooms | `AC8 — GET /admin/spaces returns 200 HTML` + detail | 🟡 PASS (LiveView serves it) |
| AC9 | Config page GET works | `AC9 — GET /admin/config returns 200 HTML (no WS)` | 🟡 PASS (ConfigLive serves it) |
| AC10 | Claim Mapping GET + POST with inline validation | `AC10 — GET /admin/config/claim-mapping` + `POST with empty field shows inline error` | 🟡/🔴 |
| AC11 | Compliance page GET renders requests table | `AC11 — GET /admin/compliance returns 200 HTML with requests table` | 🟡 PASS (ComplianceLive serves it) |
| AC12 | Router: live/3 replaced by get/3+post/3+delete/3 | Covered by all route tests above | 🔴 FAIL (impl missing) |
| AC13 | Auth gate: non-admin GET redirects to /admin/login | Three unauthenticated GET tests | 🟡 PASS (LiveView on_mount redirects) |
| AC14 | Longpoll transport present on Admin socket | `AC14 — Endpoint has longpoll transport declared` | 🟡 PASS (longpoll already wired) |
| AC16 | Flash via put_flash/3 on conn before redirect | `AC16 — flash is set via put_flash/3 before redirect` | 🔴 FAIL |
| AC17 | Add-member input is plain text, no phx-change | `AC17 — room detail add-member form uses plain text input, no phx-change` | 🔴 FAIL |

## Why the Tests Fail (RED)

The following controller modules **do not exist**:
- `Nebu.Admin.UsersController` — needed for `GET /admin/users`
- `Nebu.Admin.RoomsController` — needed for `GET /admin/rooms`, `GET /admin/rooms/:id`, `POST /admin/rooms/:id/auto-join`, `POST /admin/rooms/:id/settings`, `POST /admin/rooms/:id/archive`, `POST /admin/rooms/:id/members`, `DELETE /admin/rooms/:id/members/:user_id`
- `Nebu.Admin.SpacesController` — needed for spaces routes
- `Nebu.Admin.ClaimMappingController` — needed for `POST /admin/config/claim-mapping`
- `Nebu.Admin.ComplianceController` — needed for `GET /admin/compliance`

The router still has all of these as `live/3` inside `live_session :admin`. A LiveView `get` request returns a 200 HTML page (initial dead render), but:
1. It doesn't set `data-page="users"` in a format the new tests expect (for Users specifically)
2. POST routes to LiveView paths return 404 (no POST handler exists for live routes)
3. The flash PRG pattern doesn't work via LiveView

## Test Seams Used

Following ADR-018 / established project pattern (function-backed app-env seams):

| Seam | Arity | Used in |
|------|-------|---------|
| `:admin_auto_join_writer` | `fn(actor, room_id, value)` | AC4 |
| `:admin_room_visibility_writer` | `fn(actor, room_id, visibility)` | AC5 |
| `:admin_room_archiver` | `fn(actor, room_id)` | AC6, AC16 |
| `:admin_member_adder` | `fn(room_id, user_id, actor)` | AC7 (success) |
| `:admin_member_remover` | `fn(room_id, user_id, actor)` | AC7 (delete) |

## Implementation Guidance

To make these tests green, the dev step must:

1. **Create controller modules** in `server/lib/nebu/admin/`:
   - `users_controller.ex` — `index/2` action (GET)
   - `rooms_controller.ex` — `index/2`, `detail/2`, `auto_join/2`, `settings/2`, `archive/2`, `unarchive/2`, `add_member/2`, `remove_member/2`
   - `spaces_controller.ex` — analogous to rooms
   - `claim_mapping_controller.ex` — `index/2` (GET), `save/2` (POST)
   - `compliance_controller.ex` — `index/2` (GET)

2. **Update the router** (`server/lib/nebu/admin/router.ex`):
   - Replace `live "/rooms", RoomsLive, :index` with `get/post/delete` routes
   - Add `:require_admin_plug` plug for HTTP routes (mirrors on_mount gate)
   - Retain `live_session :admin` for Dashboard, AuditLog, Bootstrap

3. **Add `:require_admin_plug`** to `Nebu.Admin.Auth`:
   - A `Plug` behavior implementation that reads the session and redirects non-admins to `/admin/login`

4. **Templates** — each controller action renders a `.html.heex` template or inline `render/2` function returning HTML with the required data attributes and form controls.

5. **Flash**: use `Plug.Conn.put_session(conn, "_flash", %{"info" => "..."})` or Phoenix's `put_flash/3` on the conn before `redirect/2`.

## Next Steps

1. Implement controllers and routes (see Implementation Guidance above)
2. Run `make test-unit-elixir` — all 11 failing tests should become green
3. The 10 tests that currently pass must remain green (no regression)
4. Run `make test-unit-elixir` with zero failures before marking story `review`
