# Test Review — 6c-infected-override (pre-dev, RED-phase ATDD)

**Scope:** staged files only (`git diff --staged`):
- `server/test/nebu/media_admin_actions_test.exs` (UPDATE, +334 lines — Acceptance Tests 1-12)
- `server/test/nebu/media/state_machine_test.exs` (UPDATE, guard-table edge `infected: [:deleted]` → `infected: [:deleted, :released]`)
- `server/test/nebu/admin/media_live_test.exs` (UPDATE, +~250 lines — Acceptance Tests 13-18, `describe "6c: infected override"`)

**Context:** RED-phase ATDD, not yet validated by a green run. No implementation code, migration, or
LiveView handler exists yet. Verified against the story file
(`docs/stories/media-security-admin-control/6c-infected-override.md`) and its 18 Acceptance Tests,
and cross-checked against sibling story `6a-routine-state-actions` (status: done) for repo-convention
consistency (LiveView test approach, focus-handling limitations, Playwright expectations).

---

## AC Coverage Matrix

| AC | Requirement | Test(s) | Verdict |
|---|---|---|---|
| AC1 | Only `:infected` overridable; reject 8 named states + writes-nothing | AT1, AT8, AT9, AT10 (unit) + guard-table table-driven test (state_machine_test.exs) + AT13/14 (LiveView) | Covered, with one gap (see MINOR-1) |
| AC2 | Mandatory server-side reason (empty/whitespace/nil) before any write | AT5, AT6, AT7 (unit) + AT17 (LiveView) | Covered |
| AC3 | Sole entry point via `StateMachine.transition/4`; metadata has `reason`+`original_signature` | AT2 (metadata shape) | Covered for metadata shape; "sole entry point" / no-direct-StateMachine-call architectural rule has no automated grep test (see INFO-1) |
| AC4 | Audit entry on success with actor/target/metadata; none on rejection | AT3 (success) + AT5-9,11 (rejection-writes-nothing) | Covered |
| AC5 | `media_infected_override` in `@known_actions` | AT4 | Covered |
| AC6 | Distinct `media_admin_override` grant, UI-hidden + server-re-checked | AT11, AT12 (unit) + AT13, AT14 (LiveView) | Covered, thoroughly (positive+negative, unit+UI) |
| AC7 | CSP-safe modal, literal warning text, mandatory reason input, focus/Escape behavior | AT15, AT16, AT18 (LiveView) | Covered for markup/text/Escape/state; focus-trap and never-default-focused have zero automated coverage (see INFO-2, consistent with 6a precedent) |
| AC8 | No caching/pre-filling of a previous reason on a fresh override | — | No dedicated test (see MINOR-2) |

---

## Findings

### MINOR-1 — AC1's `:hard_deleted` source state untested at the `admin_override_infected/3` level

AC1 explicitly lists 8 states that must reject the override: `:released`, `:admin_blocked`,
`:quarantined`, `:scanning`, `:deleted`, `:hard_deleted`, `:reserved`, `:scan_failed`.

`media_admin_actions_test.exs` Acceptance Test 8 covers `:released` and Acceptance Test 9's
table-driven loop covers `:quarantined, :scanning, :admin_blocked, :deleted, :scan_failed, :reserved`
— 7 of the 8 states. `:hard_deleted` is not exercised through `Media.admin_override_infected/3`
anywhere in this file, even though the test's own docstring claims "table-driven over every
non-`:infected` state." (This mirrors the story's own Acceptance Tests section, which enumerates the
same 6 states in Acceptance Test 9's text — the omission originates in the story, not a slip by
whoever wrote the test.)

Mitigating factor: `state_machine_test.exs`'s pre-existing table-driven test
(`"allowed_transitions/1 and allowed?/2 match the full guard table for every state"`) does assert
`refute StateMachine.allowed?(:hard_deleted, :released)` as part of iterating `@all_states --
expected_tos` for every guard-table key, so the *guard-table-level* negative case for
`:hard_deleted -> :released` is covered. What's missing is the same assertion one layer up — that
`admin_override_infected/3` itself (not just the raw guard table) propagates the rejection and
writes neither a `media_state_transitions` row nor an `audit_log` entry for this specific state,
exactly as is asserted for the other 7 states.

Recommendation: either add `:hard_deleted` to Acceptance Test 9's `for from_state <- [...]` list (one
line), or explicitly note in the story/tests why it's excluded (e.g. if there's a reason
`:hard_deleted` is considered out of scope — nothing in the story suggests that). Low risk given the
guard-table coverage, but worth closing for AC1 to be fully, literally satisfied.

### MINOR-2 — AC8 ("no reason caching/pre-filling") has no dedicated regression test

Per the task brief's own framing, this is plausible to leave uncovered by a dedicated test since the
design (per the story's Technical Requirements: `open_override_confirm` always
`assign(socket, ..., override_reason: "")`) has no caching mechanism to begin with — there is no
stateful reason store to fail to clear. However, none of AT13-18 actually seed a *second*,
independent `:infected` classification of the *same* `media_id` (e.g., released once, then
re-flagged infected again by a later rescan) and confirm the modal opens with a blank reason on that
second pass. The current tests only ever exercise a single override per row.

This is acceptable to ship as-is (the task brief explicitly permits "adequately covered by
absence-of-caching-mechanism reasoning" for this AC), but flagging it as a known soft spot: if a
future refactor introduces per-`media_id` reason memoization for UX convenience (e.g., "remember what
I typed last time"), no test in this suite would catch the regression against AC8. A follow-up test
seeding a second `:infected` row reusing the same `media_id` string pattern (post-override,
re-inserted with a fresh `scan_metadata`) and asserting the reopened modal's reason field is empty
would close this gap outright, if the team wants belt-and-suspenders coverage rather than
design-level reasoning alone.

### INFO-1 — AC3's "sole entry point" / no-direct-`StateMachine`-call rule has no grep-based invariant test

The repo already has a precedent for this shape of architectural rule: `state_machine_test.exs`'s
neighbor, `server/test/nebu/media/state_machine_invariant_test.exs`
(`Nebu.Media.StateMachine.MutationInvariant`), grep-scans `server/lib/` to prove no file other than
`state_machine.ex` issues a direct `UPDATE ... media_files ... SET state`. There is no equivalent
static check proving `Nebu.Admin.MediaLive` never calls `Nebu.Media.StateMachine` directly (bypassing
`Nebu.Media`'s public API, ADR-020) — for either 6a's four actions or 6c's override. This is
consistent with 6a's own precedent (also enforced only by code review / Dev Agent Guardrails prose,
not a test), so it is not a regression introduced by this story's tests specifically. Not blocking;
noting for awareness since two stories in a row now rely on this rule staying true by convention
rather than by a checked invariant.

### INFO-2 — AC7 focus-trap / focus-never-default-on-confirm-button has zero automated coverage

AT16 and AT18 (and 6a's own equivalent Delete-confirm tests) explicitly document, in an inline
comment, that real focus movement is a client-side DOM effect that `Phoenix.LiveViewTest` cannot
observe (no real browser/DOM), and that this part of the spec is "verified by code inspection, not by
this test." This is the same, already-accepted limitation from 6a (merged, status: done) — 6c is
consistent with it, not introducing a new gap. Flagging only because it means the "confirm button
never default-focused" and "focus-trap" clauses of AC7 are not mechanically enforced anywhere in this
repo for either story; if a Playwright suite is ever added for `/admin/media` (see UI-coverage note
below), these would be natural candidates for real-DOM assertions.

### INFO-3 — No Playwright/e2e coverage; consistent with repo convention for this admin surface

`ui: true` is set in the story frontmatter, and the repo does have a Playwright suite
(`e2e/features/`, `e2e/step-definitions/`) with one existing feature for this same LiveView
(`e2e/features/admin/admin-media-overview.feature`, covering Story 5a's read-only table). Neither 6a
(merged) nor this 6c update add anything to `e2e/`. Given `Nebu.Admin.MediaLive` has no fake-DB seam
(ADR-018 — inline SQL) and every single test in `media_live_test.exs` already requires a live
Postgres connection and mounts through the real Phoenix router (not `live_isolated/3`, per this file's
own moduledoc correction), the existing LiveView test suite already exercises this feature about as
close to true integration as ExUnit can get. Since 6a set this precedent and shipped without
Playwright additions, 6c following the same pattern is a consistency call, not a deviation — treating
this as informational, not a MAJOR gap, matching how 6a was itself accepted.

---

## Test-Quality Checklist

- **Hard waits / non-deterministic assertions:** none found. No `Process.sleep`/`:timer.sleep`
  anywhere in the diff. Synchronization with the LiveView process is done via round-trip `render/1`
  calls (documented pattern, e.g. the 5b describe block's `row_html = view |> element(...) |>
  render()` comment explicitly calls out why this avoids a race/sleep).
- **Brittle selectors:** none found. All new selectors are stable, ID/attribute-based
  (`#media-override-confirm-modal`, `[phx-click=open_override_confirm][phx-value-media_id='#{id}']`),
  mirroring 6a's own `#delete-trigger-#{id}` / `#media-delete-confirm-modal` convention rather than
  fragile text/position-based lookups.
- **GenServer crash/restart test:** N/A — no new GenServer introduced by this story.
- **Error codes / edge cases:** thorough — empty/whitespace/nil reason (3 separate cases, not
  collapsed into one), 7-of-8 invalid source states (see MINOR-1), forbidden-without-grant paired
  with a positive control, allowlist regression guard as a standalone assertion (not just an indirect
  pass-through), and a documented, deliberate correction of the story's own Acceptance Test 9 text
  gap is *not* present here (unlike 6a's AT12, which the dev of that story corrected against a
  story-vs-real-guard-table mismatch) — 6c's AT9 just quietly omits `:hard_deleted` without comment.
- **RED-phase documentation:** exemplary — both test files carry detailed moduledoc/inline comments
  explaining exactly why each test is expected to fail right now (`UndefinedFunctionError` vs.
  Postgrex "column does not exist" at seeding time vs. plain assertion failure), distinguishing
  legitimate documented RED from an accidental compile break, consistent with this epic's established
  standard (4a/2e precedent cited directly in the comments).

---

## Overall Assessment

No MAJOR findings. All 8 ACs have at least one test; the one real coverage gap (MINOR-1,
`:hard_deleted` untested at the public-API level for AC1) is a 1-line fix inherited from a gap in the
story's own Acceptance Tests text, and is already mitigated one layer down by the guard-table-level
table-driven test. MINOR-2 (AC8 no dedicated fresh-reason test) is explicitly acceptable per the
review brief's own allowance for design-level reasoning. The two INFO items are pre-existing,
already-accepted repo conventions (6a precedent), not regressions introduced by this diff.

**Recommendation: proceed to dev-story.** Optionally fold MINOR-1 in as a 1-line addition to
Acceptance Test 9's `for from_state <- [...]` list if the team wants AC1 literally airtight before
implementation; not a blocker either way.
