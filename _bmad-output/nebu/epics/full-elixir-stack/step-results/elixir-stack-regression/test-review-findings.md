# TEA Test-Review — elixir-stack-regression (PASS, 0 MAJOR)

## AC coverage matrix
| AC | Covered by | Verdict |
|----|-----------|---------|
| AC1 full journey, 501=CI-block | elixir-regression-matrix.feature FullJourney + no-501 tracker | PASS |
| AC2 SHA-256 roundtrip + Range 206/CL=100 | elixir-regression-media.feature RoundTrip + Range | PASS |
| AC3 admin UI flow (toggle, user count) | elixir-regression-admin.feature (playwright-bdd) | PASS (MINOR-1) |
| AC4 preview og:title+og:description | media Preview scenario | PASS |
| AC5 Dex Bearer validated, no 401 valid | media scenarios + load-test JWT + missing-token 401 | PASS |
| AC6 make test-integration exits 0 | meta, satisfied by others green | PASS |
| AC7 200 clients/50 msg, median<=150ms, zero drop | regression_sync_load_test.exs | PASS |

Every AC has a test → no MAJOR on coverage.

## Determinism / measurement — all pass
- No Process.sleep / no time.Sleep substituting for synchronization. Journey synchronizes via /sync long-poll (legit), not fixed wait.
- AC7 load test measures via System.monotonic_time; Task.await 30s budget is documented failsafe, not the gate.
- AC7 asserts BOTH median<=150ms AND total_delivered==10,000 (zero-drop). Delivery only counts if body contains event_id/payload (genuine drop detection).

## Godog Strict-mode integrity — pass
- Every reused step has exactly one existing definition; every new step registered (initializeElixirRegressionSteps + initializeElixirRegressionMediaSteps wired in steps_test.go). No duplicate registrations. No @wip/@pending on regression scenarios.

## Spec error/edge coverage — strong
login missing-type→400; bad token→403 M_FORBIDDEN; send missing-msgtype→400; typing-true-no-timeout→400; missing-token→401 M_MISSING_TOKEN; non-member download→403 M_FORBIDDEN; idempotent re-send same event_id + exactly once; m.receipt in ephemeral AND absent from timeline.

## Admin e2e — no forging/seeding confirmed (Auth Code + PKCE via Dex).

## Findings
**MAJOR:** None.

**MINOR-1** — AC3 User-Overview assertion degrades to renderedRows>0 fallback if no count element exists; the count-vs-rows parity (real regression signal) only enforced when a count element happens to exist. Recommend data-testid="user-count" on LiveView. (Coverage-strength gap, test-only story.)

**MINOR-2** — AC1 login-missing-type / send-missing-msgtype / typing-no-timeout assert `contains "errcode"` (any errcode + 400), not the exact M_BAD_JSON / M_MISSING_PARAM from Oracle. Bad-creds and missing-token DO pin exact errcode. Tighten for symmetry. Low risk.

**MINOR-3** — Range fixture is synthetic JPEG; Content-Type: image/jpeg assertion depends on server echoing request Content-Type vs sniffing. Acceptable for parity; flagged so a future sniffing change surfaces here.

**INFO-1** — Journey 501-gate covers only new-step calls; reused steps (createRoom/invite/send) assert status 200 independently, so a 501 there still fails the scenario via a different assertion. Coverage intact.

**INFO-2** — Green-not-red expected & acceptable for a GATE story (endpoints already migrated). Genuine red-phase pressure is in regression_sync_load_test.exs (:pg fan-out must deliver to all 200 or zero-drop fails).

## Verdict: PASS — no MAJOR. 3 MINOR / 2 INFO are coverage-tightening suggestions, none blocking.
