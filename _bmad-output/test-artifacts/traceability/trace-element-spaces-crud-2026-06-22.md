# Traceability — Element Web (Matrix client) E2E coverage for Spaces CRUD

**Date:** 2026-06-22
**Author:** Murat (Master Test Architect)
**Scope (requested):** Do the Playwright `element-web` E2E tests cover Spaces **create /
join / leave / delete**, and what is missing?
**Oracle:** epic `spaces-elixir` (S1–S5) + `docs/stories/phase3/spaces-spec.md`;
Matrix client-server API scope in `CLAUDE.md`.

## Framing

A Matrix Space **is a room** (`m.room.create.content.type = "m.space"`). "Create / join /
leave" a Space use the *same* client endpoints as rooms (`createRoom`, `join`, leave via
membership). **There is no "delete" in the Matrix client API at all** — no delete endpoint
is in scope (`CLAUDE.md`), so "delete a Space" is N/A at the client/Element level (the
nearest server-side concept is the Admin UI's *archive room*, rooms only).

## Element-web Spaces feature inventory

- `e2e/features/element/spaces/create-room-in-space.feature` — 2 scenarios
  (`@bug-room-in-space @regression`): the just-fixed regression (commit 652d9c00) that
  `createRoom` must honour `initial_state` so a room created **inside** a Space gets its
  `m.space.parent` edge. Steps: `e2e/step-definitions/element/create-room-in-space.steps.ts`.
- `e2e/features/element/room/{create,join,leave,upgrade}.feature` — **plain rooms**, not Spaces.
- `e2e/features/admin/spaces.feature` — Admin LiveView (list / create / add child /
  auto-join toggle), **not** the Matrix/Element browser path.

## Traceability matrix

| Operation | Element-web (browser) test? | Evidence | Verdict |
|---|---|---|---|
| **Create room *inside* a Space** | ✅ Yes — 2 scenarios | `create-room-in-space.feature` (pure `createRoom` contract + full Element UI); asserts server-side `m.space.parent` edge | **COVERED** |
| **Create a Space** (as a tested behaviour) | ⚠️ Partial | `creates a Space named … via Element Web` and `createSpaceViaApi` exist **only as preconditions** for the room-in-space scenario; **no assertion** the Space itself was created / appears in the Space sidebar. (Matrix-API level is covered by ExUnit `:integration`, S1 AC1; Admin UI create by `admin/spaces.feature`.) | **GAP** (no standalone browser test, unlike `room/create.feature`) |
| **Join a Space** | ❌ No | No `element/spaces/join.feature`. Restricted join rule (MSC3083, spaces-spec §3.4 / §"POST …/join") — a core Space behaviour — is **not** exercised at browser level. `room/join.feature` covers plain-room invite-accept only. | **GAP** |
| **Leave a Space** | ❌ No | No `element/spaces/leave.feature`. (Leave-a-space == leave-a-room; `room/leave.feature` covers a plain room only.) | **GAP** |
| **Delete a Space** | ➖ N/A | No delete endpoint in Matrix client scope. Admin archive is rooms-only. | **N/A** (don't write one at element level) |
| **Render Space hierarchy** (`GET /hierarchy`) | ❌ No browser test | S3 covered by ExUnit; no Element scenario rendering the Space sidebar tree | GAP (read, out of requested CRUD scope) |

## Quality-gate decision: **CONCERNS**

The requested matrix is **not** fully covered at the Element/browser level:

- The only element Spaces feature is the **create-room-in-space regression** — narrow and
  bug-driven, not lifecycle coverage.
- **Join (esp. restricted join rule), Leave** have **zero** browser-level coverage.
- **Create a Space** has no standalone browser test with assertions (only used as a
  precondition).
- **Delete** is correctly absent — not a Matrix client operation.

Server/API behaviour for Spaces (S1–S5) is covered by ExUnit `:integration` tests, so this
is a **browser-level (Element) E2E gap**, not a total absence of coverage.

## Recommended new element-web scenarios (mirror `room/*.feature`)

1. `element/spaces/create.feature` — create a Space via Element ("New Space" flow) →
   assert it appears in the Space sidebar (mirror `room/create.feature`'s sidebar+header
   assertions). **P1**
2. `element/spaces/join.feature` —
   (a) join a public Space; **(b) restricted join**: a Space member can join a
   `join_rule: restricted` child room, a non-member is `403`-blocked. **P1** (restricted
   join is the highest-value Space-specific behaviour and currently untested end-to-end).
3. `element/spaces/leave.feature` — leave a Space via Element → Space gone from sidebar. **P2**
4. (Optional, read) `element/spaces/hierarchy.feature` — Space sidebar renders child tree
   via `GET /hierarchy`. **P2**
5. **Delete:** none at element level (N/A).
