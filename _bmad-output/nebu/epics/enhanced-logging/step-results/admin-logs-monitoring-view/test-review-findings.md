# Test-Review Findings — admin-logs-monitoring-view (pre-dev)

Files reviewed: server/test/nebu/admin/logs_live_test.exs, server/test/nebu/admin/logs_live/trace_map_bubble_test.exs

## Independent verification of ATDD self-reports
(a) PubSub bare-map shape — CONFIRMED. handler.ex safe_broadcast/1 broadcasts a bare map, not
    a {:operational_log_entry, entry} tuple. Story Dev Notes are wrong; tests correctly follow real code.
(b) metadata gap — CONFIRMED (with correction). request_logger.ex only calls
    Logger.metadata(request_id:, route_template:) — method/status/duration_ms never reach the
    `metadata` column, only into `message` via inspect/1. This blocks AC6 (status badge/method/path/
    duration) but does NOT block AC7 (severity sort uses the already-correct top-level `level` field —
    correction to ATDD's self-report).

## MAJOR findings (5)

1. **No Playwright/Gherkin E2E coverage** for this ui:true story. e2e/features/admin/ has no
   logs*.feature. RESOLUTION: adding e2e/features/admin/logs-monitoring.feature now (fixed directly,
   pure test-coverage addition, no design decision).

2. **AC1 "Endpoints" bubble dimension untested** in logs_live_test.exs — only level/source bubbles
   are exercised through LogsLive's actual grouping logic; endpoint dimension only unit-tested in
   isolation via trace_map_bubble_test.exs. RESOLUTION: adding endpoint-bubble assertion to Test 1
   (fixed directly).

3. **AC3 vs AC5 contradiction** — AC3 mandates client-side-only filtering (no server round-trip,
   no phx-click handle_event); AC5/Dev Notes describe :filter mode as "on click, toggles filter state
   in the LiveView via a phx-click event." Tests 1/2 as originally generated call render_click and
   assert LiveView state changes, including a factually wrong inline comment claiming "no server
   round-trip occurs" while calling render_click (which IS a server round-trip in Phoenix.LiveViewTest).
   RESOLUTION (fixed directly, not blocked — this is resolvable via a known, unambiguous Phoenix
   idiom, not a genuine open design tradeoff): trace_map_bubble/1 in :filter mode binds phx-click to
   Phoenix.LiveView.JS commands (JS.toggle_attribute for aria-pressed, JS.toggle_class / a small
   companion inline script for row show/hide per Dev Notes item 3's explicitly allowed escape hatch)
   — NOT JS.push, so no handle_event/state round-trip occurs. This satisfies AC3 to the letter while
   still using "phx-click" as AC5 describes (phx-click carries a JS command, not a push). Because
   Phoenix.LiveViewTest cannot execute real browser JS, the true runtime toggle behavior is NOT
   verifiable via ExUnit — Tests 1/2 are corrected to assert only the static HTML contract needed for
   the client-side JS to function (data-filter-dimension/data-filter-value attributes, default
   aria-pressed="false", chip-row container present) and the new E2E Playwright test (see finding 1)
   is the authoritative verification of the real click-to-filter behavior. Dev-story must implement
   trace_map_bubble/1 using JS commands only, not a handle_event="toggle_filter" push.

4. **Confirmed metadata gap blocks AC6** — RequestLogger/Handler never populate metadata.status/
   method/duration_ms (see verification above). RECOMMENDED FIX for dev-story (not a test-file fix —
   this is implementation guidance carried forward): have RequestLogger's before_send callback call
   Logger.metadata(method:, status:, duration_ms:) before Logger.info(base_fields), so Handler's
   existing metadata-capture path naturally persists/broadcasts these fields structurally. Do NOT
   have LogsLive regex-parse the inspect/1 message string — fragile and contradicts Dev Notes intent.
   This touches already-committed operational-log-store code but is an unambiguous bug/gap with a
   clear fix, not a design tradeoff — dev-story should apply it directly.

5. **AC4 chip-removal (×) interaction untested** — Test 1 only asserts the chip row renders with
   matching text; no test clicks a chip's × and verifies that filter is removed distinctly from
   re-clicking the bubble. RESOLUTION: adding a chip-removal test (fixed directly).

## MINOR findings (4)
1. Test 4's status badge regex OR (~r/🟢|2xx/) is weaker than AC13's "never color-only" — should be
   AND (icon AND text), matching Test 8's pattern. Fixed directly alongside MAJOR #2/#5 edits.
2. Test 1's exact-count assertion on the real shared "operational_logs" PubSub topic risks flakiness
   if another concurrent test broadcasts a matching level=error/source=http entry. Left as-is (low risk,
   full-suite runs are already tolerant per accepted baseline flake list) — not worth further test
   rework at this stage.
3. Tests 7/10's invented "pause_live_updates"/"resume_live_updates" event names are self-flagged
   @moduletag :proposed_contract — dev-story should treat as a proposal, confirm or rename during
   implementation, not a fixed contract.
4. AC16 (DaisyUI class usage) has no automated test coverage — acceptable, deferred to UX Gate
   (Step 5b) visual/accessibility review.

## INFO (4)
1. ATDD's two self-reported findings both independently verified accurate.
2. No crash/restart test for LogsLive — correctly so, it's per-connection LiveView state, not a
   registered GenServer (consistent with AuditLogLive/BootstrapLive precedent).
3. AC17/AC18 are scope/dependency statements, not independently testable — AC18 implicitly covered
   by Test 12's real integration test.
4. Test 12's eventually/2 poll helper (bounded, 25ms/20 attempts) is an acceptable non-hard-wait pattern.

## Disposition
5 MAJOR: #1, #2, #5 fixed directly as pure test-coverage additions (no design decision). #3 fixed
directly via known Phoenix.LiveView.JS-commands idiom (reconciles AC3/AC5, not a genuine open design
tradeoff — auto-resolved per this pipeline run's headless-mode rule for unambiguous bugs/gaps).
#4 is implementation guidance carried forward into dev-story's brief (RequestLogger/Handler metadata
fix), not a test-file change.
4 MINOR: #1 fixed directly (regex tightened); #2-#4 logged, not blocking.
