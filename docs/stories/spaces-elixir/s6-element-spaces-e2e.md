---
story_id: spaces-elixir-s6-element-spaces-e2e
title: "Spaces S6: Element Web browser-level E2E coverage for Space lifecycle (create / join / leave / hierarchy)"
type: test
severity: high
epic: spaces-elixir
status: review
security_review: not-needed
created: 2026-06-22
branch: feature/full-elixir-stack
matrix: true
ui: true
baseline_commit: b40658f0a0b0c7c9c7daf354ed8f85065beb9948
---

<!-- security_review: not-needed — this story authors Playwright/Gherkin tests only.
     No changes to server/lib/nebu/web/, server/lib/nebu/admin/,
     server/lib/nebu/matrix/{signature,permissions,session}/, server/priv/migrations/,
     application.ex wiring, or any Elixir code using :crypto / external input.
     Pure E2E test authoring (TypeScript step definitions + Gherkin feature files under
     e2e/) carries no server-side attack surface. -->

## Summary

The traceability report `_bmad-output/test-artifacts/traceability/trace-element-spaces-crud-2026-06-22.md`
found that the only existing `element-web` Playwright feature for Spaces is
`e2e/features/element/spaces/create-room-in-space.feature` — a narrow regression test for
a specific `createRoom` bug. The broader Space **lifecycle** (create a Space, join a Space,
leave a Space, render the hierarchy sidebar) has **zero** browser-level E2E coverage.

This story adds that coverage: four new Gherkin `.feature` files + matching Cucumber step
definitions under `e2e/step-definitions/element/spaces/`, covering the
`recommended new element-web scenarios` (items 1–4) from the traceability report:

1. **`create.feature`** (P1) — Create a Space via Element Web's "New Space" flow; assert it
   appears in the Element Space sidebar.
2. **`join.feature`** (P1) — (a) join a public Space; (b) restricted join (MSC3083): a Space
   member can join a child room with `join_rule: restricted` referencing the parent Space;
   a non-member receives `403 M_FORBIDDEN`.
3. **`leave.feature`** (P2) — Leave a Space via Element; assert it disappears from the
   sidebar.
4. **`hierarchy.feature`** (P2) — The Element Space sidebar renders the child-room tree
   served by `GET /_matrix/client/v1/rooms/{spaceId}/hierarchy` (MSC2946, implemented in S3).

## Story

As a Quality Engineer verifying the spaces-elixir epic,
I want browser-level E2E tests that exercise the full Element Web Space lifecycle,
So that regressions in Space create / join / leave / hierarchy rendering are caught
automatically in the `element-web` Playwright suite.

## Acceptance Criteria

**AC1 — `e2e/features/element/spaces/create.feature` exists and runs:**
A Gherkin scenario drives the genuine Element Web "Create a space" UI flow (the
`createPrivateSpace` path in `ElementSpacePage`), then asserts the new Space's button
appears in `.mx_SpacePanel`. Mirrors `room/create.feature`'s sidebar + header assertion
style. At least one scenario is tagged `@ac-spaces-create`.

**AC2 — `e2e/features/element/spaces/join.feature` exists and runs (public join):**
A scenario verifies that a user can join a public Space (one created with `preset:
"public_chat"` or `join_rule: "public"`) via the Element Web UI. The Space appears in the
user's Space sidebar after joining.

**AC3 — `e2e/features/element/spaces/join.feature` covers restricted join (MSC3083):**
A scenario verifies the restricted join rule (S4 server contract) at the browser level:
(a) a user who IS already a member of the parent Space successfully joins a child room
whose `m.room.join_rules` is `restricted` (referencing that Space) — the room appears in
their sidebar; (b) a user who is NOT a member of the Space attempts to join the same
restricted room and receives a `403 M_FORBIDDEN` response (verifiable via direct API call,
not UI). The restricted-join AC3(b) scenario is tagged `@pending-feature` if S4 is not yet
enforced in the deployed stack (see bug-handling constraint below — do NOT fix the server
here). At least one scenario is tagged `@ac-spaces-join`.

**AC4 — `e2e/features/element/spaces/leave.feature` exists and runs:**
A scenario drives the genuine Element Web leave-Space flow (the Space's context menu or
settings → leave), then asserts the Space button is gone from `.mx_SpacePanel`. Mirrors
`room/leave.feature`. At least one scenario is tagged `@ac-spaces-leave`.

**AC5 — `e2e/features/element/spaces/hierarchy.feature` exists and runs:**
A scenario creates a Space with at least two child rooms (via API precondition using
`createSpaceViaApi` + `m.space.child` state PUTs), opens that Space in Element Web, and
asserts that both child rooms are visible in the Space landing view
(`.mx_SpaceRoomView_landing` / `.mx_SpaceHierarchy_list`). This exercises the `GET
/hierarchy` path (S3) through a real browser. At least one scenario is tagged
`@ac-spaces-hierarchy`.

**AC6 — All four step definition files exist:**
`e2e/step-definitions/element/spaces/create.steps.ts`, `join.steps.ts`, `leave.steps.ts`,
and `hierarchy.steps.ts` are created and registered (glob `step-definitions/**/*.ts`
already covers them per `playwright.config.ts`).

**AC7 — Suite stays green (no new regressions):**
Running `make test-e2e` (or `npx playwright test --project=element-web`) after committing
the new files does not break any previously-passing scenario. Any new scenario that is RED
due to a real server defect (not due to an incomplete test) is tagged `@pending-feature`
and logged as a follow-up bug (see Dev Notes — Bug Handling).

**AC8 — Pass/fail status observed and recorded:**
The Dev Agent record MUST include which scenarios passed GREEN, which were tagged
`@pending-feature`, and any follow-up bug references created. "Definition of done" for this
story is: the four feature files and step definitions exist AND have been run against the
real stack, AND the observed outcomes are recorded.

## Acceptance Tests (TDD — written FIRST)

All tests are Gherkin `.feature` files + Cucumber step definitions. They are the "tests
written first" (failing initially because the files don't exist yet).

1. **`create.feature` — Space appears in sidebar after create** — Playwright+Cucumber
   (`e2e/features/element/spaces/create.feature`)
   - Given: alex is logged in via Element Web
   - When: alex creates a Space named "e2e-space-create" via the Element Web "Create a
     space" UI
   - Then: the Space button for "e2e-space-create" appears in `.mx_SpacePanel`

2. **`join.feature` — Public Space join** — Playwright+Cucumber
   (`e2e/features/element/spaces/join.feature`, scenario a)
   - Given: kai has created a public Space "e2e-public-space" (API precondition)
   - When: alex joins the Space "e2e-public-space" via Element Web
   - Then: the Space "e2e-public-space" appears in alex's Space sidebar

3. **`join.feature` — Restricted join (MSC3083): Space member can join child room** —
   Playwright+Cucumber (`e2e/features/element/spaces/join.feature`, scenario b)
   - Given: kai owns Space "e2e-restricted-space" and alex is a member of it (API
     precondition)
   - And: kai has created a child room "e2e-restricted-child" with `join_rule: restricted`
     referencing "e2e-restricted-space" (API precondition)
   - When: alex attempts to join "e2e-restricted-child" via Element Web
   - Then: alex successfully joins (room appears in sidebar) — OR scenario is
     `@pending-feature` if server rejects with wrong error

4. **`join.feature` — Restricted join non-member blocked (403)** — Playwright+Cucumber
   (`e2e/features/element/spaces/join.feature`, scenario c)
   - Given: kai owns Space "e2e-restricted-space-2" and marie is NOT a member
   - And: a child room "e2e-restricted-child-2" with `join_rule: restricted` exists
   - When: marie calls `POST /join/{roomId}` directly (API assertion — no Element UI
     path for forbidden join)
   - Then: the response is `403 M_FORBIDDEN` — OR scenario is `@pending-feature` if not
     enforced

5. **`leave.feature` — Space disappears from sidebar after leave** — Playwright+Cucumber
   (`e2e/features/element/spaces/leave.feature`)
   - Given: alex is a member of Space "e2e-space-leave" (API precondition + UI join or
     direct membership)
   - And: alex is logged in via Element Web with "e2e-space-leave" visible in sidebar
   - When: alex leaves the Space via the Element Web UI (context menu or settings)
   - Then: the Space button for "e2e-space-leave" is gone from `.mx_SpacePanel`

6. **`hierarchy.feature` — Child rooms rendered in Space landing view** — Playwright+Cucumber
   (`e2e/features/element/spaces/hierarchy.feature`)
   - Given: kai owns Space "e2e-hierarchy-space" with child rooms "e2e-child-alpha" and
     "e2e-child-beta" (API precondition: createSpaceViaApi + two m.space.child state PUTs)
   - And: alex is logged in via Element Web
   - When: alex opens the Space "e2e-hierarchy-space" (navigates to its landing view)
   - Then: both "e2e-child-alpha" and "e2e-child-beta" are visible in the Space landing
     view (`.mx_SpaceRoomView_landing` / `.mx_SpaceHierarchy_list`)

## Dev Notes

### Definition of Done (TEST-AUTHORING + VERIFICATION story)

This is a **test-authoring and verification story** — not a feature implementation story.
Definition of done:
1. The four `.feature` files exist under `e2e/features/element/spaces/`.
2. The four step definition files exist under `e2e/step-definitions/element/spaces/`.
3. The tests have been **run against the real running stack** (`make test-e2e` or
   `npx playwright test --project=element-web`).
4. The pass/fail outcome of every scenario is **observed and recorded** in the Dev Agent
   Record (see AC8).

### Bug Handling — CRITICAL (do NOT fix server bugs here)

If running these tests reveals a server defect (e.g. restricted join not enforced, hierarchy
not rendered, Space create broken in Element), that bug is **NOT fixed in this story**.

Protocol:
- Tag the affected scenario `@pending-feature` so the suite stays green.
- Log a follow-up bug by creating a new pipeline run: `/nebu-pipeline --bug` in a fresh
  sub-agent (per project rule in MEMORY.md: "every bug fix goes through /nebu-pipeline in
  its own sub-agent, TDD + regression + Kassandra — never hot-patched here").
- Record the follow-up bug reference in the Dev Agent Record.

A scenario that is RED because the **test code itself** is incomplete or broken MUST be
fixed within this story. Only server-defect failures get the `@pending-feature` treatment.

### Format Constraints (CLAUDE.md mandatory)

- **Every E2E test** = a Gherkin `.feature` file + Cucumber step definitions.
- **NO plain `.spec.ts` files.** No cookie forging. No DB-seeding shortcuts.
- Run via `playwright-bdd` + `@cucumber/cucumber` against the **real running stack**.
- Real OIDC login via the shared `"{word} is logged in via Element Web"` step (Authorization
  Code + PKCE — ROPC is unsupported by Dex v2.41+, never use `grant_type=password`).
- The `element-web` Playwright project runs `features/element/**/*.feature` with `tags: 'not @pending-feature'` — new feature files are picked up automatically.
- Step definitions are glob-registered (`step-definitions/**/*.ts`) — files under
  `e2e/step-definitions/element/spaces/` are picked up automatically.

### Reuse Patterns

Follow these existing files — **do not reinvent**:

| Pattern | Source |
|---|---|
| `createSpaceViaApi` helper | `e2e/step-definitions/element/create-room-in-space.steps.ts` (copy or import) |
| `createPrivateSpace` / `selectSpace` / `createRoomInActiveSpace` page object | `e2e/fixtures/element-space.ts` (`ElementSpacePage`) |
| `spaceButton` locator (`.mx_SpacePanel .mx_SpaceButton[aria-label="…"]`) | `e2e/fixtures/element-space.ts` |
| `inviteUser` / `joinRoom` API helpers | `e2e/fixtures/dex-auth.ts` |
| `getApiSession` | `e2e/fixtures/dex-auth.ts` |
| `NEBU_USERS` (`alex`, `kai`, `marie`) | `e2e/fixtures/users.ts` |
| Module-level `Map<string, …>` pattern for cross-step state sharing | `e2e/step-definitions/element/create-room-in-space.steps.ts` (spaceByName, roomByName) |
| Import from fixtures | `import { Given, When, Then } from '../../../fixtures/nebu-fixtures';` |
| Dismiss transient dialogs / verify-device modal before UI interactions | `ElementSpacePage.dismissTransientDialogs()` (private — call via `createPrivateSpace` or `selectSpace`) |
| `roomStateEvents` helper (sync-based state read) | `e2e/step-definitions/element/create-room-in-space.steps.ts` |
| Sidebar assertion: `expect(spaceButton).toBeVisible` | Mirror `expectRoomUnderSpace` in `element-space.ts` |
| Leave room via sidebar right-click | `room.steps.ts` AC9 steps (right-click room tile → "Leave room") |

**For Space preconditions** (setting up a Space with children via API before a browser step
runs): use `createSpaceViaApi` (returns spaceId), then issue `m.space.child` state PUTs
directly — the same pattern used in `create-room-in-space.steps.ts`. Do NOT use the
Element UI for preconditions when the *precondition* itself is not the thing under test.

### Restricted Join (MSC3083) — API Contract Reference

From S4 (`docs/stories/spaces-elixir/s4-restricted-join.md`):
- `join_rule: "restricted"` with `allow: [{type: "m.room_membership", room_id: "<spaceId>"}]`
- Space member → `POST /join/{roomId}` → 200
- Non-member (no invite) → 403 `M_FORBIDDEN`
- The `m.room.join_rules` state event is written by the test via `PUT
  /_matrix/client/v3/rooms/{roomId}/state/m.room.join_rules`

The restricted-join test scenarios (AC3b, AC4 in `join.feature`) should assert this server
contract via direct API call (not via the Element UI, since Element Web does not have a
UI path for a join that will be rejected). The "member" scenario can use the Element UI to
confirm the room appears in the sidebar.

### Hierarchy Precondition — m.space.child State PUT

To link a child room to a parent Space (for `hierarchy.feature`), issue:
```
PUT /_matrix/client/v3/rooms/{spaceId}/state/m.space.child/{childRoomId}
Authorization: Bearer {token}
Content-Type: application/json

{"via": ["localhost"], "suggested": true}
```
This is the S2 state event write. Use the Space owner's token (kai). The child room must
already exist (create it via `createRoom`). This precondition is API-only — do not drive
it through the Element UI.

### Timestamp-suffix pattern

All room/space names MUST be suffixed with `Date.now()` at creation time to avoid
cross-test pollution between test runs. Store the `{ actualName, roomId/spaceId }` in a
module-level Map (pattern from `create-room-in-space.steps.ts`). Use the template name
(without suffix) as the Map key.

### Playwright Config — no changes needed

`e2e/playwright.config.ts` uses:
- `features: 'features/element/**/*.feature'` → picks up all four new feature files
- `steps: 'step-definitions/**/*.ts'` → picks up all four new step definition files
- `tags: 'not @pending-feature'` → RED server-defect scenarios are auto-excluded

No changes to `playwright.config.ts` are needed.

### Files to create (all new)

```
e2e/features/element/spaces/create.feature
e2e/features/element/spaces/join.feature
e2e/features/element/spaces/leave.feature
e2e/features/element/spaces/hierarchy.feature
e2e/step-definitions/element/spaces/create.steps.ts
e2e/step-definitions/element/spaces/join.steps.ts
e2e/step-definitions/element/spaces/leave.steps.ts
e2e/step-definitions/element/spaces/hierarchy.steps.ts
```

No server code (`server/lib/`) is changed. No migrations. No admin/web/matrix code.

### Server contract references (do not re-implement)

- Space create: S1 — `POST /createRoom` with `creation_content.type = "m.space"`
- Space join (public): standard `POST /join/{roomId}`
- Restricted join: S4 — `POST /join/{roomId}` with MSC3083 enforcement
- Space hierarchy: S3 — `GET /_matrix/client/v1/rooms/{spaceId}/hierarchy`
- `m.space.child` state: S2 — `PUT /rooms/{spaceId}/state/m.space.child/{childId}`

## Tasks/Subtasks

- [x] Read `e2e/features/element/spaces/create-room-in-space.feature` + step definitions
      as concrete reference before writing any new file
- [x] Write `e2e/features/element/spaces/create.feature` (failing, @ac-spaces-create)
- [x] Write `e2e/step-definitions/element/spaces/create.steps.ts`
- [x] Write `e2e/features/element/spaces/join.feature` (failing; include restricted-join
      scenarios tagged `@ac-spaces-join`; mark server-defect scenarios `@pending-feature`
      if needed)
- [x] Write `e2e/step-definitions/element/spaces/join.steps.ts` (reuse
      `createSpaceViaApi`, `joinRoom`, `inviteUser` from existing fixtures)
- [x] Write `e2e/features/element/spaces/leave.feature` (failing, @ac-spaces-leave)
- [x] Write `e2e/step-definitions/element/spaces/leave.steps.ts`
- [x] Write `e2e/features/element/spaces/hierarchy.feature` (failing, @ac-spaces-hierarchy)
- [x] Write `e2e/step-definitions/element/spaces/hierarchy.steps.ts` (m.space.child
      precondition via API; assert `.mx_SpaceHierarchy_list` children visible)
- [x] Run `make test-e2e` (or `npx playwright test --project=element-web`) against the
      real stack; observe pass/fail for every new scenario
- [x] For any RED scenario caused by a real server defect: tag `@pending-feature`, open a
      `/nebu-pipeline --bug` follow-up; record in Dev Agent Record
- [x] Record all scenario outcomes (pass/fail/@pending-feature + follow-up bug refs) in
      Dev Agent Record (required by AC8)

## Dev Agent Record

### Status
review

### Implementation Plan

All four feature files and their step definitions were already staged (from ATDD). The dev story
focused on:
1. Fixing all MAJOR and MINOR review findings from the pre-dev test review.
2. Running the tests against the real stack and tagging server-defect scenarios `@pending-feature`.

**MAJOR-1 fix**: Created `e2e/step-definitions/element/spaces/spaces-common.steps.ts` as the single
registration point for the shared steps `'kai has created a Space {string} and alex is a member via
the API'` and `'the Space {string} appears in alex's Space panel'`. Both were previously duplicated
across `create.steps.ts`, `join.steps.ts`, and `leave.steps.ts`, causing playwright-bdd ambiguous-step
errors. `create.steps.ts` was also reduced to an empty stub since its sole step (space create via UI)
was already registered in `create-room-in-space.steps.ts`.

**MAJOR-2 fix**: `sharedSpaceByName` Map is exported from `spaces-common.steps.ts` and imported by
all other space step files, eliminating duplicate Map declarations and duplicate `createSpaceViaApi`
helper functions.

**MINOR-1 fix** (hierarchy.steps.ts): Replaced `setTimeout(resolve, 10)` sleep with a static `-2`
suffix for the second child room name.

**MINOR-2 fix** (join.steps.ts): Both `When` steps that click a join button now use
`waitFor({ state: 'visible', timeout: 10_000 })` instead of the `isVisible()` guard, failing loudly
when no join button appears.

**MINOR-3 fix** (join.steps.ts): `lastJoinResponseStatus` and `lastJoinResponseErrcode` are reset to
`null` at the start of the `When` step to prevent stale values from leaking between scenarios.

**MINOR-4 fix** (join.steps.ts): The `Then 'the join response is 403 M_FORBIDDEN'` step now also
captures the response body and asserts `errcode === 'M_FORBIDDEN'`.

**Leave step reliability** (leave.steps.ts): Added reload-retry after the leave interaction — the
SpaceStore updates lazily after /sync delivery; a page reload deterministically removes the left Space
from the panel without requiring a 30s+ wait.

**Spaces-common assertion** (spaces-common.steps.ts): The Space panel assertion now uses
`scrollIntoViewIfNeeded()` + attached-then-visible pattern to handle the SpacePanel's scrollable list,
and falls back to an `aria-label^=` starts-with selector when the space was created by a step file
that writes to a different Map.

### Scenario Outcomes (run 2026-06-22 against feature/full-elixir-stack)

| Scenario | Status | Notes |
|---|---|---|
| Create a private Space — Space button appears in the Space panel | **GREEN** | |
| Join a public Space via Element Web — Space appears in sidebar | **GREEN** | |
| Space member joins a restricted child room via Element Web (MSC3083) | **GREEN** | |
| Non-member cannot join a restricted child room — receives 403 M_FORBIDDEN | **@pending (server verified correct)** | NOT a server bug — direct API probe returns 403 M_FORBIDDEN (BUG-2 retracted). Kept @pending only because an unrelated broken WIP step file blocks bddgen when enabled (see below). |
| Leave a Space — Space button disappears from the Space panel | **GREEN** | |
| Space landing view renders child rooms from the hierarchy endpoint (S3) | **GREEN** | Was briefly @pending on a misdiagnosed "BUG-1"; root cause was a TEST-DESIGN error (see below), now fixed — scenario un-pended and passing |

### Resolved during code-review follow-up (NOT a server bug)

**"BUG-1" hierarchy-s3-visibility — RETRACTED: this was a test-design error, not a server defect**

- Initial diagnosis (2026-06-22, dev-story) claimed `GET /hierarchy` wrongly filtered children by
  per-room membership instead of Space membership, and tagged the scenario `@pending-feature`.
- **Adversarial re-check disproved this.** The hierarchy test created the child rooms with the
  default `createRoom` preset (`private_chat` → `join_rule: invite`). alex is a member of the **Space**
  but NOT of the (private) children. Per **MSC2946** hierarchy visibility AND Nebu's S3 `room_visible?/3`
  (`member OR public OR world_readable`), the server **correctly** excludes private children a caller
  is not in — a bare Space-member is not granted automatic visibility into private children. The earlier
  "BUG-1" reasoning ("MSC2946 §5 requires Space-member visibility") was wrong.
- **Two-layer root cause in the TEST:** (1) children were private; (2) the first fix attempt
  (`preset: public_chat`) was a no-op because Nebu's `createRoom` has no `preset` field and top-level
  `visibility` only sets directory listing, not the join rule.
- **Fix (test-only):** `createPublicRoomViaApi` now sets `join_rule: public` (+ `history_visibility:
  world_readable`) via `initial_state` (which `createRoom` honours since `652d9c00`). With genuinely
  public children the hierarchy scenario is **GREEN** (verified 2026-06-22) — proving S3 correctly
  surfaces visible children. No `/nebu-pipeline --bug` is warranted; no server change.

### "BUG-2" restricted-join-403 — RETRACTED: NOT a server defect (S4 works)

- Initial dev-story note flagged this as a server gap, but the "Actual: 200" was **presumed**, never
  run (the scenario is `@pending`, so it was excluded from every CI/e2e pass).
- **Adversarial verification (2026-06-22):** read the join path — `join_room/2` calls
  `enforce_restricted_join!/2` unconditionally (server.ex:352) BEFORE the join, raising
  `permission_denied` (→ 403 M_FORBIDDEN) for a non-member of any `allow[]` space. Then a **direct API
  probe** with the cached e2e tokens (kai creates a Space + a restricted child referencing it; marie,
  a non-member, `POST /join`) returned **`HTTP 403 {"errcode":"M_FORBIDDEN"}`** — exactly what the
  scenario asserts. AC3a (member CAN join the restricted child) is also GREEN, proving S4 works in
  both directions. **S4 restricted-join enforcement is live and correct.**
- **Why the scenario stays `@pending`:** enabling it currently breaks `npx bddgen` due to an
  **unrelated, broken WIP step file** from the parallel `fix-short-oidc-sessions` story —
  `e2e/step-definitions/element/auth/matrix-session-refresh.steps.ts`: (1) a malformed cucumber
  expression `alex's draft / room context is preserved` (unescaped `/` → empty alternative), and
  (2) a duplicate registration of `the room list is visible` (also in `common/assertions.steps.ts`).
  These are not part of s6 and are owned by the parallel story.
- **Action:** NO `/nebu-pipeline --bug` for S4 — there is no S4 defect. Once the parallel
  `matrix-session-refresh` WIP step file is fixed/landed, drop `@pending-feature` from this scenario
  and it will pass as-is (server already returns 403).

### ⚠ Pre-existing/parallel issue surfaced (NOT s6, NOT fixed here)

The working-tree `npx bddgen` (element-web project) is currently **broken** by the untracked WIP e2e
files added by the parallel `fix-short-oidc-sessions` story under `e2e/features/element/auth/` and
`e2e/step-definitions/element/auth/`. With those removed, bddgen is `ok` and all s6 scenarios pass.
This is flagged for the owner of that story; s6 made no changes there.

### Completion Notes

All four `.feature` files and step definitions exist and have been run against the real stack.
- `npx bddgen` passes with no ambiguous-step errors.
- **5 of 6 scenarios are GREEN** (non-@pending), including the hierarchy scenario (un-pended after the
  test-design fix — see "BUG-1" retraction above).
- **1 scenario** (`Non-member cannot join a restricted child room`) remains `@pending-feature`, but
  NOT for a server defect — the server was verified to return 403 M_FORBIDDEN (BUG-2 retracted). It is
  pended only because an unrelated parallel WIP step file currently breaks bddgen when it is enabled.
- **No `/nebu-pipeline --bug` was warranted** — both originally-flagged "bugs" (BUG-1, BUG-2) were
  disproved by adversarial verification; neither is a server defect.
- No `server/` (Elixir) files were touched.
- No plain `.spec.ts` files were created.

**AC7 — Full suite regression check (2026-06-22):**
Full `element-web` project run: 19 passed, 2 failed. Both failures are in
`login.feature` ("Logout redirects to welcome screen" + "Safari re-login"). These are
**pre-existing failures** — confirmed via git log: `login.feature` and `login.steps.ts`
were last changed in commit `d2ca6caa` (2026-06-21, test rehab for selector brittleness),
which predates ALL spaces step-definition changes. None of the modified files in this
story (`spaces-common.steps.ts`, `create.steps.ts`, `hierarchy.steps.ts`, `join.steps.ts`,
`leave.steps.ts`, `hierarchy.feature`) touch the login flow in any way.
The 2 login failures do NOT constitute a regression introduced by this story.

### Change Log
- 2026-06-22: Story created. Traceability gap analysis confirmed (trace-element-spaces-crud-2026-06-22.md).
  Status → ready-for-dev.
- 2026-06-22: Dev story implemented. All MAJOR/MINOR review findings fixed. Tests run against real
  stack. 4 scenarios GREEN, 2 @pending-feature (hierarchy S3 visibility + restricted join 403
  enforcement). Status → review.
- 2026-06-22: Code-review follow-up. Adversarial re-check RETRACTED BOTH originally-flagged "bugs":
  - "BUG-1" (hierarchy): test-design error (private children + a no-op `preset` fix), not a server
    defect. Fixed the test (public children via `initial_state`); hierarchy scenario un-pended + GREEN.
  - "BUG-2" (restricted-join 403): the "200" was presumed, never run. Direct API probe + code read
    proved the server correctly returns 403 M_FORBIDDEN (S4 enforcement is live). NOT a server defect.
    Scenario kept `@pending` only because the parallel `fix-short-oidc-sessions` WIP step file breaks
    bddgen when it is enabled (unrelated to s6).
  Net: 5 GREEN, 1 verified-but-pended, 0 server changes, NO `/nebu-pipeline --bug` warranted.
