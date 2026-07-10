# CI-Gate E2E Triage — admin-sidebar-nesting (2026-07-07)

## Verdict
- Elixir integration (official ci-gate, `make test-integration`): ✓ exit 0 (fresh stack)
- Unit suite: ✓ 1411/1411
- Playwright admin-ui project: **story scenarios 4/4 PASS**; 32 unexpected failures
  elsewhere — ALL pre-existing, evidence below. Story proceeds per the Step-1d rule
  (pre-existing failures are documented, not story-blocking).

## Harness was dead before this story (fixed here)
The whole Playwright suite crashed AT SETUP since ≤2026-07-06 18:55 (stale
`.last-run.json`, same signature): Playwright's transform compiled the static import of
`fixtures/dex-preflight.mjs` (via the `.ts` facade, committed 2026-07-01) to CJS, Node
executes `.mjs` as native ESM → "ReferenceError: exports is not defined in ES module
scope" → 0 tests ran. Nobody saw suite rot because `make test-integration` (the
pipeline's official CI gate) only runs the Elixir integration suite.
**Fix in this story:** `e2e/fixtures/dex-preflight.ts` now loads the `.mjs` via dynamic
`import()` (native ESM loader, untransformed). `npm run typecheck` clean.

## Triage of the 32 pre-existing failures
1. **Realm drift (majority: add-user-autocomplete, member_management, users,
   device-management, create_room, sso_schemes, war-room, bootstrap, claim-mapping…):**
   specs expect `@alex:localhost` etc.; the compose stack (as provisioned by the
   integration run) contains `@alex<suffix>:test.local` users. The suite's stack
   expectations and the default compose env have drifted — spec-vs-environment issue,
   live UI verified working (users page renders rows; nav, pages load).
2. **Stale trace-map specs:** `logs-monitoring.feature` and
   `logs-trace-map-filter-persistence.feature` were last updated BEFORE yesterday's
   `trace-map-hierarchy` commit (cb291bd2) restructured the Endpoints section into a
   disclosure tree — they assert the old flat-bubble UI. `logs-trace-map-hierarchy`'s
   own spec fails on timing/suite conditions, but the behavior is live-verified OK
   (domain header click → aria-expanded=true, chevron ▼, leaves revealed — checked via
   real browser on the CI-built image).
   These specs cover the exact UI Phil has ordered REPLACED by the trace-map-leitstand
   redesign; they will be rewritten/retired by the `trace-map-leitstand` story.
3. **Story's own scenarios:** all 4 `admin-sidebar-nesting.feature` scenarios PASS
   against the same stack (keyboard Space/Enter toggling, selector continuity,
   default-expanded + exact-URL navigation).

## Live verification (real browser, CI-built image)
- Sidebar: Logs group expanded with Live Stream / Trace Map / War Room / Configuration;
  Configuration group nested; toggle collapses/expands (a11y tree confirms).
- /admin/logs: heading "Endpoints" visible; domain header expansion works.
- /admin/users: rows render.

## Follow-up (out of story scope)
E2E suite rehab: realm/user-fixture drift vs compose env + stale trace-map specs.
Recommend folding the stale-spec retirement into `trace-map-leitstand` and the realm
drift into the existing e2e-test-rehab epic backlog.
