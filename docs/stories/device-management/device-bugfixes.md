---
id: device-bugfixes
epic: device-management
status: review
security_review: required
baseline_commit: 786a9fad
---

# Bug Fixes: Device Management UI Link + keys/signatures/upload Stub

## Story

**As** an admin navigating the Admin UI,
**I want** to click on a user in the users list to open their device management detail page,
**so that** I can see, rename, and revoke their devices.

**And as** an Element Web client registering a device,
**I want** `POST /_matrix/client/v3/keys/signatures/upload` to return a valid response,
**so that** the client does not error out during the key-registration flow.

## Background

Two regressions were discovered after the `device-management` epic (S1–S4) was committed:

1. **Admin UI link missing:** `UsersController.show/2` and `show.html.heex` exist and implement the full per-user device management page (S4). However, `templates/users/index.html.heex` renders `user.user_id` as plain text — no `<a href>` to `/admin/users/:user_id`. The show page is completely unreachable via the UI.

2. **`keys/signatures/upload` 404:** Element Web calls `POST /_matrix/client/v3/keys/signatures/upload` after device registration (cross-signing bootstrap flow). This route is not declared in `server/lib/nebu/web/router/protected.ex`, so Plug returns a raw 404. Per ADR-011, E2EE cross-signing is excluded; a stub returning `200 {"failures": {}}` is the correct server response.

## Acceptance Criteria

### Bug 1 — Admin UI Link

- **AC1:** `GET /admin/users` renders each user's `user_id` as a hyperlink (`<a>`) pointing to `/admin/users/<uri-encoded-user_id>`.
- **AC2:** Clicking the link navigates to the user detail page (`GET /admin/users/:user_id`) which shows the device table (S4 AC1).
- **AC3:** The link is keyboard-navigable (standard `<a href>` — no JS required).
- **AC4:** Usernames that contain URL-unsafe characters (e.g. `@user:localhost`) are correctly percent-encoded in the href.

### Bug 2 — keys/signatures/upload

- **AC5:** `POST /_matrix/client/v3/keys/signatures/upload` (authenticated) returns HTTP 200 with body `{"failures": {}}`.
- **AC6:** The endpoint requires a valid Bearer token (same OidcPlug pipeline as all protected routes).
- **AC7:** An unauthenticated request returns 401 (OidcPlug handles this before the route).

## Acceptance Tests

### Tests written FIRST (before implementation code):

1. **[AC1/AC2/AC4] Admin users index renders user_id links** — ExUnit (Plug.Test / :integration)
   - Given: at least one user exists in the DB
   - When: GET /admin/users (with valid admin session cookie)
   - Then: response body contains `<a href="/admin/users/` with the user's user_id percent-encoded

2. **[AC1/AC4] URL-encoding of special chars in user_id** — ExUnit (unit / Plug.Test)
   - Given: user_id = `@testuser:localhost`
   - When: rendered in the index template
   - Then: href = `/admin/users/%40testuser%3Alocalhost`

3. **[AC5/AC6] keys/signatures/upload happy path** — ExUnit (:integration, Plug.Test)
   - Given: valid Bearer token
   - When: POST /_matrix/client/v3/keys/signatures/upload with any JSON body
   - Then: 200 + `{"failures": {}}`

4. **[AC7] keys/signatures/upload unauthenticated** — ExUnit (:integration, Plug.Test)
   - Given: no / invalid Bearer token
   - When: POST /_matrix/client/v3/keys/signatures/upload
   - Then: 401 M_UNKNOWN_TOKEN (OidcPlug rejects before route)

## Dev Notes

- Fix 1: `server/lib/nebu/admin/templates/users/index.html.heex` line 16 — wrap `{user.user_id}` in `<a href={"/admin/users/" <> URI.encode(user.user_id, &URI.char_unreserved?(&1))} class="text-primary">`. Note: `text-primary` was chosen over `link link-primary` for consistency with the rooms/spaces index styling (UX gate recommendation).
- Fix 2: `server/lib/nebu/web/router/protected.ex` — add `post "/client/v3/keys/signatures/upload"` stub (after `keys/upload`, before `GET /devices`) returning `send_json(conn, 200, %{"failures" => %{}})`.
- Tests for Bug 1 can live in `server/test/nebu/admin/users_controller_test.exs` (existing file, add new `describe "index"` or extend it).
- Tests for Bug 2 can live in `server/test/nebu/matrix/device_keys_test.exs` or a new `signatures_upload_test.exs` in `server/test/nebu/matrix/`.

## Tasks/Subtasks

- [x] Fix 1: Wrap user_id in anchor tag in index.html.heex (AC1/AC2/AC3/AC4)
  - [x] Add `:admin_users_loader` seam to `UsersController.load_users/0`
  - [x] Wrap `{user.user_id}` in `<a href>` with `URI.encode/2` percent-encoding
- [x] Fix 2: Add `POST /client/v3/keys/signatures/upload` stub route (AC5/AC6/AC7)
  - [x] Add route in `protected.ex` after `keys/upload`, returning `{"failures": {}}`
- [x] Verify all 6 acceptance tests pass with 0 warnings (`make test-unit-elixir`)

## Dev Agent Record

### Implementation Plan

Two minimal, targeted fixes with no new dependencies:

**Bug 1 (Admin UI Link):**
1. Added `:admin_users_loader` test seam to `UsersController.load_users/0` — checks `Application.get_env(:nebu_http, :admin_users_loader)` before falling back to the DB query. Mirrors the existing pattern used by `list_devices/1`, `do_rename_device/3`, and `do_delete_device/2`.
2. Wrapped `{user.user_id}` in `index.html.heex` with `<a href={"/admin/users/" <> URI.encode(user.user_id, &URI.char_unreserved?(&1))} class="text-primary">`. Uses `URI.char_unreserved?/1` (same encoder as `enc/1` in the controller) so `@user:localhost` → `%40user%3Alocalhost`. `text-primary` chosen over `link link-primary` for consistency with rooms/spaces index (UX gate recommendation).

**Bug 2 (keys/signatures/upload 404):**
Added `post "/client/v3/keys/signatures/upload"` stub in `protected.ex` between the `/keys/upload` handler and the `/devices` GET, returning `send_json(conn, 200, %{"failures" => %{}})`. OidcPlug at the top of the protected pipeline handles auth rejection (401) before the route is reached (AC6/AC7). Follows the same pattern as the existing `/keys/device_signing/upload` stub.

### Completion Notes

- 942/942 tests pass (up from 936 before this story), 2 skipped, 200 excluded, 0 compiler warnings.
- All 6 new acceptance tests green: 4 from `UsersIndexLinkTest` (AC1–AC4) and 2 authenticated + 2 unauthenticated from `SignaturesUploadTest` (AC5–AC7; the 2 AC7 tests were already passing before Fix 2, now confirmed with the full route in place).
- No new dependencies introduced.

## File List

- `server/lib/nebu/admin/users_controller.ex` — added `:admin_users_loader` seam to `load_users/0`
- `server/lib/nebu/admin/templates/users/index.html.heex` — wrapped `user.user_id` in `<a href>` with percent-encoding (`class="text-primary"`)
- `server/lib/nebu/web/router/protected.ex` — added `POST /client/v3/keys/signatures/upload` stub route
- `server/test/nebu/admin/users_index_link_test.exs` — pre-staged ATDD tests (AC1–AC4), now passing
- `server/test/nebu/web/signatures_upload_test.exs` — pre-staged ATDD tests (AC5–AC7), now passing (moved from `test/nebu/matrix/` per domain-mirror convention)
- `e2e/features/admin/users.feature` — added `@ac-users-link` scenario for UI link navigation guard
- `e2e/step-definitions/admin/users.steps.ts` — added step definitions for `@ac-users-link` scenario

## Change Log

- 2026-06-28: Implemented Bug 1 (Admin UI link) and Bug 2 (keys/signatures/upload stub); all 6 acceptance tests green, 0 regressions.
- 2026-06-28: Review cycle 1 fixes — updated Dev Notes CSS class, fixed on_exit/async comments, added @moduletag :integration, moved signatures_upload_test.exs to test/nebu/web/, added Playwright/Gherkin E2E scenario for users link navigation.
