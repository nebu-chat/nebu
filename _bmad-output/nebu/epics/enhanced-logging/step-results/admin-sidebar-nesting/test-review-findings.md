# Test Review — admin-sidebar-nesting (RED-phase ATDD) — 2026-07-07

Verdict: 2 MAJOR, 3 MINOR (request changes before dev-story)

## MAJOR-1 — AC5/AC6 integration test cannot pass against a correct implementation (broken Floki selector)
`server/test/nebu/admin/layouts_nested_nav_test.exs:490` — `find_all(&1, "> a, > button")`:
Floki 0.38.4 silently treats a leading child combinator as a DESCENDANT selector, so
`top_level_keys` includes nested `role-mapping`/`claim-mapping` even when correctly nested;
`refute "role-mapping" in top_level_keys` then fails on the CORRECT implementation.
Fix: full-path child-combinator selector, e.g.
`nav[aria-label="Admin navigation"] > ul[role="list"] > li > a, ... > li > button`,
or walk the `{tag, attrs, children}` tuples manually.

## MAJOR-2 — Gherkin scenario 4 contradicts the pinned default-expanded contract
`e2e/features/admin/admin-sidebar-nesting.feature:78-87` — clicks the "logs" toggle then
expects children to become VISIBLE, but the pinned contract (`:expanded` default true;
scenario 2 line 67 asserts initial aria-expanded="true") means the first click COLLAPSES.
Also the final `URL contains "/admin/logs"` assertion is vacuous. Fix: drop the toggle
click (children visible by default) or collapse-then-expand explicitly; navigate from a
non-logs page and assert the exact URL after clicking `logs-monitoring`.

## MINOR-1 — Tab operability untested (AC9 / story Acceptance Test 8)
`e2e/step-definitions/admin/admin-sidebar-nesting.steps.ts:67-72` uses programmatic
`.focus()` instead of real Tab keypresses; no Tab-into-expanded-children assertion.

## MINOR-2 — Loose aria-current assertion
`layouts_nested_nav_test.exs:264` accepts `aria-current in [nil, ""]` — empty string is
invalid ARIA; pin to `nil` (attribute absent).

## MINOR-3 — Toggle steps never assert button role in the browser
Add one `getByRole('button', { name: ... })` resolution in scenario 1 (data-navkey
locating stays per AC11).

## INFO
- No hard waits/non-determinism; async false + on_exit cleanup correct.
- GenServer crash test correctly absent (pure UI story).
- Patterns verified against codebase (build_admin_conn, :nebu_http seam, reused steps).
- AC coverage otherwise complete incl. Design-Update Trace-Map child (own describe block).
