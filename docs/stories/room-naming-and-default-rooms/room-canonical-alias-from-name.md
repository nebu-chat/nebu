---
story_id: room-canonical-alias-from-name
title: "Generate a canonical room alias from the room name on creation"
epic: room-naming-and-default-rooms
status: done
security_review: required
created: 2026-06-23
branch: bugfix/room-names
---

## Summary

When a room is created with a name like "general", no human-friendly alias is ever produced — the
room is only addressable by its opaque id `!…:localhost`. We want the create path to derive a
canonical alias `#general:localhost` from the name (set `m.room.canonical_alias` and register the
alias so it resolves), so the room is identifiable by name in Element and the Admin UI.

Currently **no** code creates `m.room.canonical_alias` or any `#localpart:server` alias on room
creation (`event_dispatcher/server.ex` only writes create / member / power_levels / name). Canonical
alias is only *read* in sync/space-hierarchy code.

## User Story

As a user (or admin) creating a room named "general" on server "localhost",
I want the room to get the canonical alias `#general:localhost`,
so that the room is addressable and displayed by a readable alias, not just its opaque id.

## Acceptance Criteria

1. **Given** a room is created with name "general" on server `localhost`,
   **When** creation completes,
   **Then** an `m.room.canonical_alias` state event with `content.alias == "#general:localhost"` is
   written, **And** the alias resolves to the room id via the alias→room lookup
   (`GET /_matrix/client/v3/directory/room/{alias}` if that endpoint is in scope, otherwise the
   internal alias store), **And** sync exposes the canonical alias for the room.

2. **Given** the desired localpart already exists as an alias (collision),
   **When** the room is created,
   **Then** a deterministic, unique alias is produced (e.g. `#general-2:localhost`) — creation never
   fails and never registers a duplicate alias.

3. **Given** a name with characters not valid in a Matrix alias localpart (spaces, uppercase, emoji,
   `:`/`#`/`/`),
   **When** the alias is derived,
   **Then** the localpart is sanitised to a spec-valid alias (e.g. "Team Rocket!" → `#team-rocket`),
   the `m.room.name` is still the original unsanitised name, and if no usable localpart can be
   derived the room is created **without** an alias (non-fatal) rather than crashing.

4. **Given** an admin creates a room via the Admin UI,
   **When** it is created,
   **Then** the alias is generated through the same path (the Admin UI create flow benefits too).

5. **Backwards compat:** creating a room with **no** name produces no alias and behaves exactly as
   today.

## Acceptance Tests

### Tests written FIRST (before implementation code):

1. **`create_room generates canonical alias from name`** — ExUnit
   - Given: create room name "general", server name "localhost"
   - Then: `m.room.canonical_alias` content alias == `#general:localhost`; alias store resolves it to
     the room id.

2. **`alias localpart is sanitised`** — ExUnit (table/property cases)
   - "General" → `#general:localhost`; "Team Rocket!" → `#team-rocket:localhost`; an all-invalid name
     → no alias, room still created.

3. **`alias collision yields a unique alias`** — ExUnit
   - Given: `#general:localhost` already registered
   - When: another room named "general" is created
   - Then: a distinct, valid alias is registered; the first alias still resolves to the first room.

4. **`Matrix client sees canonical alias`** — ExUnit `:integration` (sync) and, if user-visible in
   Element, a Playwright + Cucumber scenario showing the room appears by its alias/name.

> **Oracle Gate:** this is a Matrix-spec feature — consult `nebu-agent-oracle` for the exact
> `m.room.canonical_alias` content shape, alias grammar (`#localpart:domain`, sigil rules, localpart
> charset), uniqueness/registration semantics, and whether/how the room-directory alias endpoints are
> in Nebu's MVP scope before writing tests.

## Technical Requirements

- Derive the alias localpart from the name: lowercase, replace runs of invalid chars with `-`, trim
  leading/trailing `-`, bound the length. The server domain comes from the configured server name
  (the same source used to mint `!…:localhost` ids / user ids — do not hardcode "localhost").
- Persist/register the alias so it resolves to the room id (reuse or add an alias store; check for any
  existing alias-resolution table/code before adding a new one). Enforce uniqueness at the store
  level (unique constraint) and handle collisions deterministically.
- Emit `m.room.canonical_alias` via the same signed/persisted/fanned-out state-event path used for
  `m.room.name` in `create_room`. Keep ordering after `m.room.name`.
- Alias generation must be **non-fatal**: a failure to derive/register an alias logs a warning and
  leaves the room created (mirrors how name/type persistence failures are handled today).
- Depends on / layers cleanly over `admin-room-creator-provisioning` (do that first so the create
  path is sound).

### Security notes (SEC Gate)

- The name is **external input**: sanitise to a strict alias localpart allowlist — never interpolate
  into SQL (bind params) and never let it inject sigils/`:`/path separators into the alias.
- Uniqueness enforced server-side (DB constraint) to prevent alias hijacking/overwrite of an existing
  room's alias.
- New SQL migration (if an alias table is added) is in security scope.

## Out of Scope

- Renaming a room updating its alias, alias deletion/management UI — a later story if needed.
