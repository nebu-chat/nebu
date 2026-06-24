---
story_id: admin-room-creator-provisioning
title: "Admin-created rooms keep their name (provision the creator + harden createRoom)"
epic: room-naming-and-default-rooms
status: done
security_review: required
created: 2026-06-23
branch: bugfix/room-names
---

## Summary

**Bug.** When an instance admin creates a room via the Admin UI (e.g. name "general"), the
room is afterwards shown as the raw room id `!124f102042dbf55c:localhost` and badged
**"Stale"** instead of showing "general" as an active room.

**Verified root cause (reproduced against the live stack):**

The Admin UI passes the admin's own Matrix id as the room `creator_id`
(`socket.assigns.actor_id`, e.g. `@kai:localhost`). `Nebu.Matrix.EventDispatcher.Server.create_room/2`
runs in this order: persist `m.room.create` → **join the creator** (`Room.Server.join/2` →
`insert_member` INSERT into `room_members`) → power levels → `m.room.name` + `update_room_name`.

The admin's id is **not present in the `users` table** (the Admin-UI OIDC login path does not
provision a `users` row, unlike the Matrix `oidc_plug` path). The creator-join therefore violates
FK `room_members_user_id_fkey` and **raises `Postgrex.Error`**. The `rescue` clause in
`Nebu.Matrix.create_room/2` only rescues `Nebu.Matrix.Error`, so the `Postgrex.Error` aborts the
flow **after** `m.room.create` is written but **before** the creator membership, power levels and
`m.room.name` are written.

Net result: an orphan room with no name (→ displays the raw id) and zero members (→
`room_effective_status("active", 0) == "stale"`). Confirmed inverse: creating the same room as the
already-registered `@alex:localhost` persists `rooms.name` and one member correctly.

## User Story

As an instance admin,
I want a room I create in the Admin UI to immediately show the name I typed and be a normal active
room I am a member of,
so that I am not left with an unnamed, member-less "stale" room id.

## Acceptance Criteria

1. **Given** an instance admin whose Matrix id has **no** `users` row,
   **When** they create a room named "general" via `Nebu.Matrix.create_room/2`,
   **Then** the creator is provisioned into `users` (idempotent upsert) so the creator-join
   succeeds, **And** `rooms.name` = "general", **And** the creator is an active member
   (`room_members` row with `left_at IS NULL`), **And** the `m.room.name` and creator
   `m.room.member` (join) events are both written.

2. **Given** the same admin id already exists in `users`,
   **When** they create a room,
   **Then** the existing `users` row is not duplicated or downgraded (upsert is idempotent; role
   preserved).

3. **Given** room creation where a step **after** `m.room.create` fails (e.g. the creator-join still
   errors for an unexpected reason),
   **Then** `create_room` does **not** leave a half-created room behind that the Admin UI would show
   as a nameless "stale" id — the create either completes fully or surfaces a clear error without an
   orphan row (transactional rollback / cleanup of the just-inserted `rooms` + `m.room.create` row).

4. **Given** the Admin UI room list,
   **When** a room created via the Admin UI is listed,
   **Then** it shows the typed name and "Active" badge (member_count ≥ 1) — never the raw id +
   "Stale" purely because of the creator-provisioning gap.

5. **Regression guard:** the existing orphan room `!124f102042dbf55c:localhost` scenario
   (creator not in `users`) no longer produces a nameless/stale room.

## Acceptance Tests

### Tests written FIRST (before implementation code):

1. **`create_room provisions an unregistered creator`** — ExUnit (`event_dispatcher` or
   `Nebu.Matrix` test, against Repo or injected DB seam)
   - Given: a creator id that has no `users` row
   - When: `Nebu.Matrix.create_room(creator_id, name: "general", visibility: "private")`
   - Then: returns `{:ok, room_id}`, `rooms.name == "general"`, creator is an active member, and
     both the creator `m.room.member` join and `m.room.name` events exist.

2. **`create_room is idempotent for an already-registered creator`** — ExUnit
   - Given: creator already in `users` with `system_role`
   - When: create a room
   - Then: succeeds; the `users` row count for that id stays 1 and its role is unchanged.

3. **`create_room leaves no orphan room when a post-create step fails`** — ExUnit
   - Given: a DB seam where the creator-join fails *after* `m.room.create`
   - When: `create_room` runs
   - Then: no `rooms` row / `m.room.create` event for that room remains (or the operation is fully
     rolled back) — the Admin UI list query returns nothing for it.

4. **`Admin UI shows created room name, not the id`** — Playwright + Cucumber E2E
   (`e2e/features/admin-create-room.feature` + steps)
   - Given: an authenticated instance admin (real OIDC Auth Code + PKCE flow) whose id is not
     pre-seeded as a Matrix user
   - When: they open "Create room", type "general", submit
   - Then: the room list / detail shows "general" with an "Active" status — not `!…:localhost` or
     "Stale".

## Technical Requirements

- **Provision the creator inside the create path.** Before the creator-join, ensure the creator
  exists in `users` via the existing idempotent upsert
  (`Nebu.Matrix.Session.UserStore.upsert_user/2`, `INSERT … ON CONFLICT DO …`). Prefer doing this in
  the authorized command path so both the Admin UI and the Matrix `POST /createRoom` flow are
  covered. Decide and document the `system_role` used for a creator with no prior row (do **not**
  silently grant elevated privileges — default to a normal `user` role; never downgrade an existing
  admin row).
- **Make `create_room` not leak orphan rooms.** Either wrap the create→join→name writes so a failure
  after `m.room.create` rolls back / cleans up the `rooms` row and `m.room.create` event, or broaden
  the error handling so a DB failure is surfaced as a clean `{:error, _}` without leaving a nameless
  stale room. The current `rescue e in Nebu.Matrix.Error` does not catch `Postgrex.Error`.
- **Consider the deeper fix too:** the Admin-UI OIDC login path provisions no `users` row (contrast
  `Nebu.Web.Plugs.OidcPlug.provision/2`). Provisioning the admin actor at login would also fix this
  and any other write keyed on the admin's Matrix id. Evaluate and, if low-risk, include it; the
  creator-provisioning in `create_room` is the mandatory defense-in-depth fix.
- **Cluster-safe / idempotent** (ADR-020): upsert must be safe under concurrent first-create races.
- **No new domain model** (ADR-018): inline SQL / existing UserStore helpers, no Ecto schema.

### Security notes (SEC Gate)

- Creator-provisioning must **not** be an authorization bypass: a created `users` row gets the normal
  `user` role, never `instance_admin`, regardless of who calls `create_room`.
- `creator_id` is bound as a query parameter, never interpolated (no SQL injection).
- Verify no path lets a Matrix client provision an arbitrary other user id via this code.

## Out of Scope

- Canonical room aliases (`#general:localhost`) — separate story `room-canonical-alias-from-name`.
- Add-user autocomplete — separate story `admin-add-user-autocomplete`.

## Notes

- **Accepted limitation (correlated-failure cleanup):** the orphan-room cleanup in
  `create_room/2` is best-effort. If `delete_room/1` itself fails (e.g. the same DB outage that
  caused the create to fail), the half-created `rooms` row may persist and the original error is
  still surfaced. A fully transactional create (m.room.create + membership + name in one DB
  transaction) is out of scope, because the `rooms` row is inserted in the Room GenServer `init/1`
  (Horde), not in the event-write transaction. This residual is accepted for this story.
