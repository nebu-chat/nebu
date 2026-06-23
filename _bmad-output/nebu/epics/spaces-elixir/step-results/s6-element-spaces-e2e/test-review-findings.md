# Pre-Dev Test Review — s6-element-spaces-e2e (2026-06-22)

**Verdict:** AC coverage COMPLETE (AC1–AC5 each have ≥1 mapped test). 2 MAJOR + 4 MINOR test-correctness findings. No coverage gaps.

## AC Coverage Matrix
| AC | Covered by | Result |
|----|-----------|--------|
| AC1 create UI | create.feature "Create a private Space" + ElementSpacePage.createPrivateSpace() | COVERED |
| AC2 public join | join.feature scenario 1 (createSpaceViaApi preset public_chat) | COVERED |
| AC3a restricted member join | join.feature scenario 2 (createRestrictedRoomViaApi) | COVERED |
| AC3b non-member 403 | join.feature scenario 3 (direct API, @pending-feature) | COVERED + correctly @pending-feature |
| AC4 leave UI | leave.feature (right-click .mx_SpaceButton → Leave space) | COVERED |
| AC5 hierarchy | hierarchy.feature (2 children via m.space.child PUTs, landing view) | COVERED |

## Findings (carry into dev-story as required fixes)

### MAJOR-1 — Duplicate step registration (ambiguous-step → bddgen compile failure)
`'the Space {string} appears in alex's Space panel'` registered as `Then` in `create.steps.ts:62` AND `Given` in `leave.steps.ts:112`. playwright-bdd has ONE global registry (`steps: 'step-definitions/**/*.ts'`) → ambiguous step error blocks AC1, AC2, AC4 from compiling.
**Fix:** extract shared Space-panel assertion into `e2e/step-definitions/element/spaces/spaces-common.steps.ts`, register once; or rename the leave precondition step text.

### MAJOR-2 — Duplicate step registration
`'kai has created a Space {string} and alex is a member via the API'` registered in BOTH `join.steps.ts:187` and `leave.steps.ts:87`. Same ambiguous-step failure; blocks AC3a + AC4. The leave.steps.ts comment ("re-declared since step files are independent") is WRONG — registry is global.
**Fix:** host the shared precondition + the inline-duplicated `createSpaceViaApi` helper in `spaces-common.steps.ts`; register once.

### MINOR-1 — `setTimeout(resolve, 10)` micro hard-wait in `hierarchy.steps.ts:187` (timestamp uniqueness). Replace with a static suffix (`-2`).
### MINOR-2 — Conditional `if (await joinBtn.isVisible())` in `join.steps.ts:172,247` silently passes if no join button. Use `waitFor({state:'visible'})` instead.
### MINOR-3 — `lastJoinResponseStatus` module-level mutable (`join.steps.ts:323`), no per-scenario reset. Reset at start of the When step or use world state.
### MINOR-4 — 403 assertion checks HTTP status only (`join.steps.ts:358`); also assert `body.errcode === 'M_FORBIDDEN'` before removing @pending-feature.

## Gate-relevant assessments
- OIDC: PASS — real Auth Code + PKCE via shared login step. No ROPC, no cookie forging, no DB seeding.
- Hard waits: PASS except MINOR-1.
- @pending-feature: CORRECT — used once (AC3b non-member 403), auto-excluded by `tags: 'not @pending-feature'`.
- Selectors: ACCEPTABLE (aria-label / page-object, consistent with existing ElementSpacePage).

**Note:** Both MAJORs are deterministic compile-blockers with explicit fixes, NOT coverage gaps. dev-story MUST resolve them (suite cannot run otherwise) and they are passed forward as required fixes.
