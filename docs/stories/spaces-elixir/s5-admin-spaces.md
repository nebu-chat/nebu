---
story_id: spaces-elixir-s5-admin-spaces
title: "Spaces S5: Admin UI for Spaces (list/create/edit/child-mgmt) + auto-join spaces (Elixir port of epic-15 admin stories + auto-join-spaces)"
type: feature
severity: high
epic: spaces-elixir
status: review
security_review: required
created: 2026-06-21
branch: feature/spaces-elixir
matrix: false
ui: true
---

## Summary

Give operators full Space management in the Admin UI — list, create, edit (name/topic),
manage child rooms (add/remove), and toggle auto-join — exactly the way regular rooms are
managed today (`Nebu.Admin.RoomsLive`). Also implement auto-join for Spaces so flagged
Spaces are auto-joined by new users on first login. Ports epic-15 admin stories
(admin-ui-spaces-list-page, admin-ui-space-detail-child-management, admin-api-spaces-crud)
+ the room-naming-and-default-rooms `auto-join-spaces` story.

Builds on S1 (room_type) + S2 (m.space.child via state PUT) + S3 (hierarchy). Mirrors the
existing rooms admin: `RoomsLive`, `Nebu.Admin.DB` (list_rooms/get_room/update_room_auto_join),
and the auto-join machinery (`ensure_auto_join_memberships`, `list_auto_join_rooms`,
`update_room_settings` with `is_auto_join`).

## Story

As an instance admin,
I want to create, list, edit, manage child rooms of, and flag-as-auto-join Spaces in the
Admin UI just like regular rooms,
So that I can organise the instance into Slack-style workspaces without leaving the admin
panel and have new users land in the right Spaces automatically.

## Acceptance Criteria

**AC1 — Spaces list page (`/admin/spaces`):** a LiveView lists all rooms with
`room_type = 'm.space'` (name, member count, child count, auto-join toggle), mirroring
`RoomsLive`. Sidebar nav has a "Spaces" entry. Admin-gated (require_admin on_mount).

**AC2 — Create Space:** a "Create Space" action takes a name → calls createRoom with
`creation_content.type = "m.space"` (S1) → the new Space appears in the list. (Reuse the
Matrix create path; the admin acts as the creator.)

**AC3 — Space detail + edit (`/admin/spaces/:space_id`):** shows the Space's name/topic,
its child rooms (resolved from m.space.child / hierarchy), and lets the admin edit name and
topic (via the S2 state PUT for m.room.name / m.room.topic, or the existing admin update
path). Changes persist and re-render.

**AC4 — Child management:** the detail page lets the admin add a child room (writes
m.space.child for the child via S2 state PUT) and remove one (writes empty m.space.child =
unlink). The child list re-renders in place.

**AC5 — Auto-join toggle for Spaces:** the Space detail page has an auto-join toggle
(reusing the rooms `is_auto_join` mechanism). Toggling persists via `update_room_settings`
(spaces are rooms) and is audited (same as rooms — the existing audit on is_auto_join).

**AC6 — Auto-join spaces on first login:** new users (first login, is_new) are
auto-joined to every Space flagged `is_auto_join = true`. Implement
`list_auto_join_spaces()` (`room_type = 'm.space' AND is_auto_join = true AND status =
'active'`) and `ensure_auto_join_space_memberships(user_id)`, called on first login
alongside the existing room auto-join. Scope the existing `list_auto_join_rooms()` to
NON-spaces (`room_type IS NULL OR room_type != 'm.space'`) so rooms and spaces don't
double-process.

**AC7 — Security/authorization:** all admin space operations require an authenticated admin
(require_admin); the create/edit/child writes are performed as the admin identity (no
privilege bypass); auto-join membership changes are audited. A non-admin cannot reach the
spaces admin pages (redirect to /admin/login, like the other admin pages).

## Acceptance Tests (TDD — written FIRST)
1. SpacesLive list renders only room_type='m.space' rooms; non-admin redirected — ExUnit (LiveView) + on_mount gate test
2. Create Space → createRoom m.space → appears in list — ExUnit / :integration
3. Space detail edit name/topic persists — ExUnit / :integration
4. add child (m.space.child written) + remove child (empty content unlink) → child list updates — ExUnit / :integration
5. auto-join toggle persists + audited — ExUnit
6. list_auto_join_spaces returns only auto-join spaces; list_auto_join_rooms excludes spaces; ensure_auto_join_space_memberships joins new user to flagged spaces — ExUnit :integration
7. E2E (Playwright+Gherkin): admin creates a Space, adds a child, toggles auto-join — `e2e/features/admin/spaces.feature` (browser flow, mirrors the rooms admin E2E)

## Dev Notes

### Files likely changed
- `core/lib/nebu/admin/spaces_live.ex` (NEW) — list + detail LiveView, mirror RoomsLive
  (master/detail, toggles, create action). `/admin/spaces` + `/admin/spaces/:space_id`.
- `core/lib/nebu/admin/router.ex` — add the two live routes inside the `:admin` live_session.
- `core/lib/nebu/admin/layouts.ex` — add a "Spaces" sidebar nav item.
- `core/lib/nebu/admin/db.ex` — `list_spaces/4` (room_type='m.space'), `get_space/1`,
  reuse `update_room_auto_join/2`; a children query (m.space.child for a space) — reuse the
  S3 `Room.DB.get_space_children/1` via the Matrix public API.
- `core/lib/nebu/matrix/event_dispatcher/server.ex` — `list_auto_join_spaces/0` +
  `ensure_auto_join_space_memberships/1`, called on first login next to
  `ensure_auto_join_memberships/1`; scope `list_auto_join_rooms` SQL to non-spaces.
- `core/lib/nebu/matrix/room/db.ex` — `list_auto_join_spaces` SQL + scope `list_auto_join_rooms`.
- Child add/remove + name/topic edit go through the S2 `set_room_state` / existing admin
  update path (do NOT add a second unauthorised write path — reuse the authorized one;
  the admin must have power in the space, OR use the admin/system path consistently with
  how the rooms admin edits work today).
- `e2e/features/admin/spaces.feature` + step definitions (NEW) — admin space create/child/
  auto-join browser flow (mirror the auto-join-rooms / rooms admin E2E pattern).
- `core/test/nebu/admin/…` + `core/test/nebu/matrix/…` — tests 1–6.

### Constraints / security (required)
- Admin-gated like all admin pages (require_admin on_mount → non-admin redirected). AC7.
- auto-join is security-relevant (the rooms auto-join audit precedent): persist via the
  audited `update_room_settings` path; emit audit_log on toggle.
- Space child writes reuse the S2 authorized set_room_state (allowlist + PL), or the
  admin/system-authorised path — do NOT introduce an unauthenticated/unauthorised write.
- ADR-018 inline SQL (parameterised); ADR-020 (admin → Nebu.Matrix public API for
  create/state, not internal submodules); LiveView state via assigns; let-it-crash.
- Apply the room-management UX conventions (accessibility) the existing rooms admin follows.

### Reference (old Go stories — parity only, do NOT port Go)
`git show origin/feature/epic-15:docs/stories/matrix-spaces/admin-ui-spaces-list-page.md`
`git show origin/feature/epic-15:docs/stories/matrix-spaces/admin-ui-space-detail-child-management.md`
`git show origin/feature/epic-15:docs/stories/matrix-spaces/admin-api-spaces-crud.md`
`git show origin/feature/epic-15:docs/stories/matrix-spaces/auto-join-spaces.md`

## Dev Agent Record

### Status
review

### Implementation Plan / Decisions

- **SpacesLive** (`core/lib/nebu/admin/spaces_live.ex`, NEW): one LiveView with two
  view modes (list + detail) mirroring `RoomsLive`. List = create form + table
  (name → detail link, member count, child count, per-space auto-join switch). Detail
  = name/topic edit form, child list with add/remove, auto-join switch. `view_mode` is
  driven by `params["space_id"]` (route) in production; a `space_detail` session key
  selects detail in `live_isolated` unit tests. Deliberately does NOT define
  `handle_params/3` (that forces router-mounting and breaks `live_isolated`, the
  RoomsLive unit-test pattern) — `mount/3` reads the route param directly.
- **Authorized write path (AC7, ADR-020):** all Space writes route through `Nebu.Matrix`
  (the Matrix domain's only public surface), never Matrix internals:
  - create → `Nebu.Matrix.create_space/2` (EventDispatcher createRoom,
    `creation_content.type=m.space`, admin becomes creator → power level 100)
  - name/topic + child add/remove → `Nebu.Matrix.set_space_state/5` = the **S2
    authorized `set_room_state`** path (allowlist + membership + power-level check;
    `m.room.name`/`m.room.topic`; `m.space.child` with content / empty-content unlink).
    No second/unauthorised write path.
  - auto-join toggle → `Nebu.Matrix.set_room_auto_join/3` → the **audited** write in
    `EventDispatcher.Server.set_room_auto_join/3` (same `update_room_auto_join` +
    `room_auto_join_changed` audit log the rooms `update_room_settings` path emits) (AC5).
  - children read → `Nebu.Matrix.get_space_children/1` (S3 helper).
  The acting identity is `current_user["matrix_user_id"]`, added to the admin session in
  `Nebu.Admin.Auth.put_current_user/2`, derived via `Nebu.Matrix.UserId.from_claims/2`
  (the same claims `/login` + `OidcPlug` use) so admin writes are attributed to the
  operator's real Matrix user and the S2 authorization applies.
- **admin/db.ex:** `list_spaces/4` (scoped `room_type='m.space'`, member + linked-child
  counts), `get_space/1` (name/topic/status/member/auto-join). Inline parameterised SQL
  (ADR-018), mirroring `list_rooms/4` / `get_room/1`. Reuses `update_room_auto_join/2`.
- **Auto-join spaces (AC6):** `Room.DB.list_auto_join_spaces/0`
  (`room_type='m.space' AND is_auto_join AND status='active'`) + scoped
  `list_auto_join_rooms/0` to NON-spaces (`room_type IS NULL OR != 'm.space'`) so the two
  paths are disjoint. `EventDispatcher.Server.ensure_auto_join_space_memberships/1`
  (non-fatal, mirrors `ensure_auto_join_memberships/1`; tolerates fakes lacking
  `list_auto_join_spaces/0` via `function_exported?`) called on first login (`is_new`) and
  bulk-import right next to the room auto-join. `list_auto_join_spaces` added to
  `Room.DBBehaviour` as an `@optional_callbacks` so pre-S5 fakes still compile.
- Routes added inside the `:admin` live_session (`/admin/spaces`, `/admin/spaces/:space_id`);
  "Spaces" sidebar nav item added to `layouts.ex`.

### TDD — RED → GREEN

Tests written FIRST; observed RED for the right reasons during development
(missing `list_auto_join_spaces/0`, missing `SpacesLive`/handlers, missing on_mount
attribution), then GREEN:

- `core/test/nebu/admin/spaces_live_test.exs` — 10 LiveView tests: list renders spaces,
  create → appears, auto-join toggle persists via the audited writer, name/topic edit
  writes `m.room.name`+`m.room.topic` via the authorized state writer, add/remove child
  writes non-empty / empty `m.space.child`, non-admin mount → `/admin/login` (on_mount
  gate asserted directly). Uses injectable app-env seams (`:admin_spaces_creator`,
  `:admin_spaces_state_writer`, `:admin_spaces_auto_join_writer`) — the RoomsLive
  `:admin_auto_join_writer` pattern; no live Repo/Matrix needed.
- `core/test/nebu/matrix/event_dispatcher/auto_join_spaces_test.exs` — 4 tests:
  empty/error/`:noproc` non-fatal; `validate_token` triggers
  `ensure_auto_join_space_memberships` for a new user (full DBBehaviour fake).
- `core/test/nebu/matrix/room/auto_join_spaces_db_test.exs` — 3 `:integration` tests
  (SQL scoping: spaces-only / rooms-exclude-spaces / disjoint) — verified on the live
  stack (excluded from the unit run).

Unit run: `mix test test/nebu/admin/ test/nebu/matrix/ --warnings-as-errors`
→ **535/577 passed** (the +10 new unit tests green; the 42 failures are pre-existing
DB-less CreateRoom/UpgradeRoom/Join/AuditRoomOps tests — identical 42 on the unmodified
baseline, i.e. zero regressions). E2E not run here (verified later on the redeployed stack).

### E2E

- `e2e/features/admin/spaces.feature` (NEW) + `e2e/step-definitions/admin/spaces.steps.ts`
  (NEW): admin reaches /admin/spaces, creates a Space, adds a child, toggles auto-join
  (Playwright + Cucumber, mirrors the rooms / auto-join-rooms admin E2E). Failing-first;
  run against the redeployed stack.

### File List

**New**
- `core/lib/nebu/admin/spaces_live.ex`
- `core/test/nebu/admin/spaces_live_test.exs`
- `core/test/nebu/matrix/event_dispatcher/auto_join_spaces_test.exs`
- `core/test/nebu/matrix/room/auto_join_spaces_db_test.exs`
- `e2e/features/admin/spaces.feature`
- `e2e/step-definitions/admin/spaces.steps.ts`

**Modified**
- `core/lib/nebu/matrix.ex` — public API: `create_space/2`, `set_space_state/5`,
  `get_space_children/1`, `list_auto_join_spaces/0`,
  `ensure_auto_join_space_memberships/1`, `set_room_auto_join/3`
- `core/lib/nebu/matrix/event_dispatcher/server.ex` —
  `ensure_auto_join_space_memberships/1`, `set_room_auto_join/3`; first-login +
  bulk-import call sites
- `core/lib/nebu/matrix/room/db.ex` — `list_auto_join_spaces/0`; scoped
  `list_auto_join_rooms/0` to non-spaces
- `core/lib/nebu/matrix/room/db_behaviour.ex` — optional `list_auto_join_spaces/0` callback
- `core/lib/nebu/admin/db.ex` — `list_spaces/4`, `get_space/1` (+ row mappers)
- `core/lib/nebu/admin/auth.ex` — `matrix_user_id` in the admin session
- `core/lib/nebu/admin/router.ex` — `/admin/spaces` + `/admin/spaces/:space_id` routes
- `core/lib/nebu/admin/layouts.ex` — "Spaces" sidebar nav item

### Change Log
- Spaces S5 implemented: Admin Spaces UI (list/create/edit/child-mgmt) + auto-join spaces.
  Status ready-for-dev → review.
