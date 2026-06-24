---
story_id: admin-add-user-autocomplete
title: "Admin UI: autocomplete existing users in add-user fields (rooms + spaces)"
epic: room-naming-and-default-rooms
status: done
security_review: required
created: 2026-06-23
branch: bugfix/room-names
---

## Summary

The "Add user" input on the room detail page (`rooms_live.ex`) and the equivalent member/child input
on the Spaces page (`spaces_live.ex`) are plain free-text fields (`placeholder="@user:server"`). An
admin must type a full Matrix id from memory. We want the field to suggest matching existing users as
the admin types. `Nebu.Admin.DB.list_users/3` already has a `_search` parameter that is currently
ignored.

## User Story

As an instance admin adding a member to a room or space,
I want the user field to suggest existing users as I type,
so that I can pick a real user without remembering the exact Matrix id.

## Acceptance Criteria

1. **Given** the admin is on a room detail page and focuses the "Add user" field,
   **When** they type at least N characters (e.g. 2),
   **Then** a list of matching existing users (by user id, and display name if available) is shown,
   **And** selecting a suggestion fills the field with that user's Matrix id.

2. **Given** a typed query matching no user,
   **When** the suggestions update,
   **Then** an empty/"no matches" state is shown and the admin can still submit a raw id (the field
   remains free-text — autocomplete is assistive, not a hard constraint).

3. **Given** the admin selects a suggested user and submits,
   **Then** the existing add-member flow runs unchanged (`Nebu.Matrix.admin_add_room_member/3`).

4. **Given** the Spaces UI add-member / add-child input,
   **Then** the same autocomplete behaviour is available there (users for member-add; the story scope
   for the child-room field is users — child-room id autocomplete is out of scope unless trivial).

5. **Given** any user-search query,
   **Then** the search is server-side, parameter-bound (no SQL injection), capped (LIMIT), and does
   not leak PII beyond what the Admin users list already shows.

## Acceptance Tests

### Tests written FIRST (before implementation code):

1. **`list_users honours the search term`** — ExUnit
   - Given: users `@alex:localhost`, `@alice:test.local`, `@bob:localhost`
   - When: `Nebu.Admin.DB.list_users(limit, cursor, "al")`
   - Then: returns alex + alice (prefix/substring match, parameter-bound), excludes bob; result
     capped by `limit`.

2. **`user-search is injection-safe`** — ExUnit
   - Given: search term `"'; DROP TABLE users;--"`
   - Then: query runs safely (bound param), returns no rows, table intact.

3. **`Admin add-user autocomplete suggests and selects a user`** — Playwright + Cucumber E2E
   (`e2e/features/admin-add-user-autocomplete.feature` + steps), real OIDC admin session
   - Given: admin on a room detail page with seeded users
   - When: they type "al" into "Add user"
   - Then: a suggestion list shows matching users; selecting one fills the field with the full id;
     submitting adds the member.

4. **`Spaces add-user autocomplete`** — Playwright + Cucumber E2E (same pattern on the Spaces page).

## Technical Requirements

- **Search query:** implement the ignored `_search` in `Nebu.Admin.DB.list_users/3` (and/or add a
  dedicated `search_users/2`) — `ILIKE` against `user_id` (and display name if cheaply available),
  parameter-bound, `LIMIT`-capped, `is_active`-aware. No PII decryption beyond what the users list
  already exposes.
- **LiveView wiring:** drive suggestions from the LiveView (`phx-change`/`phx-debounce`) into a
  dropdown rendered in the HEEx, or a native `<datalist>` populated from a search event. Prefer the
  LiveView-driven approach for debounce + ranking; keep it accessible (keyboard navigable, ARIA per
  the Nebu Admin UI accessibility constraints). The submit path is unchanged.
- **Two call sites:** `rooms_live.ex` add-member form and `spaces_live.ex` add-member form. Factor the
  suggestion UI/handler so both reuse it.
- Behaviour must be identical single-node and clustered (ADR-020) — the query hits PostgreSQL, no
  node-local state.
- **No new domain model** (ADR-018): inline SQL in the admin DB module.

### UX Gate

- Accessibility is a hard constraint (PRD): the suggestion list must be keyboard-operable, have
  appropriate ARIA roles/`aria-activedescendant`, and not trap focus. UX gate (`nebu-agent-ux`) and a
  Playwright a11y check apply.

### Security notes (SEC Gate)

- Search term is external input — bind as a query parameter; escape `%`/`_` ILIKE wildcards if needed
  to avoid unintended broad matches. Never interpolate into SQL.
- Endpoint/event is admin-only (reuse the existing admin auth on the LiveView) — a non-admin must not
  reach the user-search.
- Cap result size (LIMIT) to avoid enumeration/DoS; do not return more user data than the existing
  Admin users page.

## Out of Scope

- Child-room id autocomplete in Spaces (only the user fields are in scope).
- A general Matrix user-directory (`/user_directory/search`) — this is Admin-UI assist only.
