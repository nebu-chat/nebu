> **Editorial note (added during dev-story code-review cycle 1 follow-up):**
> This file previously contained a raw JSONL agent transcript instead of the
> human-readable report below — the actual report was the transcript's last
> assistant message; it has been extracted here verbatim.
>
> All 4 MINOR findings below were raised during the **pre-implementation
> ATDD test-review step** (RED phase, before `trace_map.ex`/`app.js` existed).
> All 4 were fixed by the ATDD author in the SAME test-review fix cycle,
> before dev-story implementation began — see `e2e/features/admin/logs-trace-map-zoom-pan.feature`'s
> own `# test-review MINOR-1/2/3/4` comments and the corresponding scenarios
> (`Alternate keyboard zoom key bindings are also wired`; `A longer,
> intentional drag started on a node still does not pan the map`; the
> `movedAtLeastOnce` check in `assertSaturatesWithRoomToSpare`,
> `e2e/step-definitions/admin/logs-trace-map-zoom-pan.steps.ts`; and the
> substring-match Tab-focus step). A later code-review pass appears to have
> re-read this same raw/stale artifact and re-flagged these 4 already-fixed
> items as new findings — re-verified against the current tree during that
> follow-up and confirmed still fixed, with the full E2E + unit suite green.

## Test Review Report — `enhanced-logging/trace-map-zoom-pan`

**Verdict: CLEAN (0 MAJOR), 4 MINOR, 5 INFO**

### Scope reviewed (staged, `git diff --staged --name-status`)
- `/Users/philippbeyerlein/dev/01_gitlab/1200_philippb/open-chat/docs/stories/enhanced-logging/trace-map-zoom-pan.md`
- `/Users/philippbeyerlein/dev/01_gitlab/1200_philippb/open-chat/e2e/features/admin/logs-trace-map-zoom-pan.feature`
- `/Users/philippbeyerlein/dev/01_gitlab/1200_philippb/open-chat/e2e/step-definitions/admin/logs-trace-map-zoom-pan.steps.ts`
- `/Users/philippbeyerlein/dev/01_gitlab/1200_philippb/open-chat/server/test/nebu/admin/logs_live/trace_map_zoom_pan_test.exs`

Cross-referenced against `/Users/philippbeyerlein/dev/01_gitlab/1200_philippb/open-chat/server/test/nebu/admin/logs_live/trace_map_leitstand_test.exs`, `/Users/philippbeyerlein/dev/01_gitlab/1200_philippb/open-chat/e2e/step-definitions/admin/logs-trace-map.steps.ts`, `/Users/philippbeyerlein/dev/01_gitlab/1200_philippb/open-chat/server/lib/nebu/admin/logs_live/trace_map.ex`, and the design spec's 2026-07-09 addenda.

---

### AC coverage matrix (all 9 ACs have ≥1 test — no MAJOR gap)

| AC | ExUnit | E2E tag(s) |
|---|---|---|
| AC1 wheel zoom, cursor-centered | — | `@ac1-wheel-zoom` (3 scenarios) |
| AC2 drag-pan, node-click disambiguation | — | `@ac2-drag-pan` (2 scenarios) |
| AC3 zoom/pan bounds | — | `@ac3-zoom-bounds` (4 scenarios) |
| AC4 reset control | 2 tests | `@ac4-reset` (2 scenarios) |
| AC5 keyboard a11y | 1 test | `@ac5-keyboard` (6 scenarios) |
| AC6 patch-survival | — (deliberately, see below) | `@ac6-patch-survival` |
| AC7 CSP/no inline JS | 2 refute-assertions embedded in AC4/AC1 tests | `@ac7-csp` |
| AC8 no regressions | 2 tests (regression guard) | `@ac8-no-regression` (3 scenarios) |
| AC9 not persisted | 1 test | `@ac9-not-persisted` |

---

### ATDD contract — explicit evaluation of the 5 flagged items

**1. Testid naming (`trace-map-zoom-controls`/`-zoom-in`/`-zoom-out`/`-zoom-reset`)** — INFO, sound. Matches the page's existing flat kebab-case `trace-map-*` convention (`trace-map-resizer`, `trace-map-level-pill`, `trace-map-legend-row`, etc.). `role="group"` on the container mirrors the existing `role="group"` used for the level-filter pills group. No issue.

**2. SVG `tabindex="0"` + extended `aria-label` — conflict check** — INFO, confirmed no conflict. Grepped `trace_map_leitstand_test.exs` and both `e2e/step-definitions/admin/logs-trace-map*.steps.ts` files for any exact-match assertion on the SVG root's `aria-label`: none exists. Existing aria-label assertions in `trace_map_leitstand_test.exs` (lines ~1044–1186) target the **node**/**resizer** aria-labels, not the SVG root, and all use `=~` substring matching, never `==`. The new test's own assertion (`aria_label =~ "Service health map"`) is itself substring-based, so an appended suffix ("...Use arrow keys to pan, +/- to zoom...") is compatible with every existing test in the suite.

**3. Numeric bounds sanity check (MIN=1.0, MAX=4.0, step 0.1, pan step 32, clamp `px∈[0,1560-1560/zoom]`, `py∈[0,1300-1300/zoom]`)** — INFO, confirmed sound. Worked the algebra against the current viewBox (`-780 -650 1560 1300`): the clamp's right edge `x_left_max + width = (780 - 1560/zoom) + 1560/zoom = 780` and bottom edge similarly `= 650` — i.e. **at any zoom level the pan clamp allows the visible window to reach exactly, but never exceed, the full viewBox extent**. This means a domain node at `R1=300` or a crowded satellite as far as `R1+R2≈560` (per the 2026-07-09 addenda) is always reachable by panning, even at `MAX_ZOOM=4.0` (visible window 390×325) where it would not be visible from the *default* (nebu-centered) pan position — that's the intended UX (zoom-then-pan-to-inspect), not a bug. Math checks out; no unsound bound.

**4. AC6 unit-test → E2E deviation** — INFO, sound reasoning, arguably cheaper than the story's own dev-notes suggestion. The story's dev notes literally suggest `act do page.waitFor 500 end` (a hard sleep) to trigger the tick; the shipped E2E scenario instead reuses the existing `"a request to {string} has been recorded"` step (`e2e/step-definitions/admin/logs-monitoring.steps.ts:87-98`), which performs a real HTTP GET, producing a genuine `RequestLogger` PubSub broadcast → real LiveView patch while the page stays mounted, then polls for the stream line via `expect(...).toBeVisible({ timeout: 10_000 })` — no fixed sleep anywhere in the new step file (`grep -nE "waitForTimeout|setTimeout|waitFor\("` on `logs-trace-map-zoom-pan.steps.ts` → 0 matches). This is strictly better than the story's own suggested approach and correctly avoids the "zero-diff no-op tick" risk called out in the feature file's own comment.

**5. Do the 4 RED ExUnit tests pin something a correct implementation will satisfy?** — INFO, verified empirically, no trap. Ran the file for real inside `elixir:1.20-alpine` (matching the project's `DOCKER_ELIXIR` build container):

```
Result: 3/7 passed
Failed: 4 tests
```

The 4 failures are exactly: AC4 reset-button-exists, AC4 focus-ring/no-phx-click, AC1/AC5 zoom-controls-group-exists, AC5 SVG-tabindex/aria-label — all failing with plain "expected X to exist" / "expected tabindex=0" assertions against markup that genuinely doesn't exist yet (`grep` on `server/lib/nebu/admin/logs_live/trace_map.ex` confirms the SVG currently has `aria-label="Service health map"` with no `tabindex`, and no zoom-control testids anywhere in the file). Each assertion is directly satisfiable by implementing exactly the pinned contract — no assertion depends on an unreachable value or a self-contradictory expectation. The 3 passing tests (AC8 regression guard ×2, AC9) correctly already pass, since they pin pre-existing markup unrelated to this story's changes.

---

### MINOR findings

1. **AC5 alternate key bindings untested.** The AC text specifies `+`/`=` or `PageUp` to zoom in, `-`/`_` or `PageDown` to zoom out. The E2E steps (`logs-trace-map-zoom-pan.steps.ts:304-337`) only ever press `'+'` and `'-'`; `PageUp`/`PageDown`/`=`/`_` are never exercised. A correct implementation that only wires `+`/`-` (dropping the alternates) would pass every current test while violating the letter of AC5.

2. **Only a sub-threshold ("accidental") drag on a node is tested, not a larger intentional one.** `logs-trace-map-zoom-pan.feature:94-100` / the `pixels: number` step (`.steps.ts:266-283`) is only ever invoked with `3` pixels — explicitly below the dev-notes' 5px click/drag threshold. AC8 states "Dragging on a node (with intent to filter) does not pan the map" without a magnitude qualifier; a naive implementation that applies a uniform 5px distance threshold everywhere (rather than truly flagging `skipPan = true` on any `pointerdown` over a node, per the dev notes) would satisfy the current 3px test while still panning on a deliberate 50–80px drag started on a node. No scenario exercises that case.

3. **Boundary-saturation scenarios are vacuous-pass-prone in isolation.** `Scenario: Zoom-out saturates at the minimum bound` (feature file lines 109-114) and `Scenario: Pan saturates at a boundary once zoomed in` (117-122), taken alone, would also pass against a **completely non-functional** zoom-out/pan-right key handler: since the scenario starts at the exact value it expects to end at (default zoom, or nebu already fully visible), a "nothing happened" trace produces the same asserted outcome as "saturated correctly." This is mitigated in this suite — `Scenario: Keyboard zoom and pan controls` (137-148) and `Scenario: Pan saturates...`'s sibling `Scenario: On-screen zoom in/out buttons work via mouse click` (72-78) both independently prove the keys/buttons actually move the viewport — but the two saturation scenarios themselves don't carry that proof. Recommend adding an explicit "value actually changed from the pre-press reading" assertion to `assertSaturatesWithRoomToSpare` (`.steps.ts:392-401`) for defense-in-depth.

4. **Stricter equality in the Tab-focus step than in the ExUnit label assertion.** `"the operator presses Tab until the Trace Map {string} button is focused"` (`.steps.ts:465-482`) requires `document.activeElement?.textContent?.trim() === expectedName` (exact match), while the ExUnit AC4 test uses `Floki.text(button) =~ "Reset view"` (substring match) and the moduledoc explicitly says the exact string was chosen so `getByRole(... {name: "Reset view"})` and the Floki assertion "agree." If the dev adds any icon/decorative glyph inside the `<button>`, this step's exact match would break while the ExUnit test and `getByRole` accessible-name computation (which also normalizes/trims) would not necessarily. Risk is low given every other button on this page (`trace-map-level-pill`, `trace-map-clear-all`, `trace-map-filter-chip-remove`) is plain-text-only with no icon, but worth a note for the dev.

---

### Standard checks
- Hard waits: none found in the new step-definitions file (verified via grep for `waitForTimeout`/`setTimeout`/`page.waitFor(`).
- Selectors: `data-testid` + `role`/`aria-label`, plus one reused pre-existing DOM id (`#trace-map-map-wrap`) and one reused pre-existing testid (`trace-map-stream-line`) — not brittle, consistent with the page's established convention.
- GenServer crash/restart test: N/A — story is `matrix: false`, pure client-JS + static markup, no new server-owned state (AC9 explicitly forbids any).
- UI story Playwright coverage: present — 14 `@pending-feature`-tagged scenarios in `e2e/features/admin/logs-trace-map-zoom-pan.feature`, following this epic's established RED-phase tagging convention.
- Matrix spec/HTTP status codes: N/A — no new Matrix endpoint or HTTP surface is introduced by this story.
- AC8 regression-guard tests: non-vacuous — pin exact counts (`6` legend rows, `4` level pills) and exact attribute values (`viewbox == "-780 -650 1560 1300"`, `role`, `preserveaspectratio`), not tautological checks.
- Keyboard scenarios use real `page.keyboard.press(...)` calls (`+`, `-`, `ArrowRight`, `ArrowLeft`, `Tab`, `Enter`), not synthetic dispatch.
- CSP guard: genuine — ExUnit `refute attr(button, "phx-click")` / `refute attr(button, "onclick")` on all three new buttons, plus a dedicated `@ac7-csp` E2E scenario asserting the page itself doesn't scroll on wheel-over-map.
- No duplicate/ambiguous step text vs. `logs-trace-map.steps.ts` (checked via diff of step-pattern sets — zero overlap).
