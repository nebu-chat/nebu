# Code Review — element-startup-stubs

**Reviewer:** Nebu Code Reviewer
**Date:** 2026-06-25
**Scope:** 6 new Element-startup stub routes in `Nebu.Web.Router.Protected` + 12 regression tests
**Verdict:** APPROVE (no CRITICAL/MAJOR). 2 MINOR, 2 INFO.

## Files reviewed

- `server/lib/nebu/web/router/protected.ex` (lines 161–201 — 6 new routes + updated comment)
- `server/test/nebu/matrix/matrix_client_compat_test.exs` (12 new `@tag :red_phase` tests)
- `server/lib/nebu/web/router.ex` (routing/forward order — verification)
- `server/lib/nebu/matrix/http.ex` (`send_json/3`, `error/4` helpers — verification)

## Acceptance Criteria coverage

| AC | Endpoint | Expected | Route present | Test (gate) | Test (contract) | Result |
|----|----------|----------|:---:|:---:|:---:|:---:|
| 1 | `GET /thirdparty/protocols` | `200 {}` | L168 | L129 | L349 | PASS |
| 2 | `GET /voip/turnServer` | `404 M_NOT_FOUND "No TURN server configured"` | L174 | L137 | L357 | PASS |
| 3 | `GET /room_keys/version` | `404 M_NOT_FOUND "No backup found"` | L180 | L145 | L367 | PASS |
| 4 | `GET .../msc3814.v1/dehydrated_device` | `404 M_NOT_FOUND "No dehydrated device found"` | L186 | L153 | L377 | PASS |
| 5 | `GET .../msc4143/rtc/transports` | `404 M_NOT_FOUND "No RTC transports"` | L192 | L161 | L387 | PASS |
| 6 | `POST /keys/device_signing/upload` | `200 {}` | L199 | L169 | L397 | PASS |
| 7 | All protected (401 M_MISSING_TOKEN w/o Bearer) | — | OidcPlug in pipeline | L129–173 (6 gate tests) | — | PASS |
| 8 | No regressions | — | — | — | — | PASS (see below) |

**Every AC has at least one test. AC 1–6 each have BOTH an auth-gate test and a contract test; AC 7 is covered by the 6 dedicated no-Bearer tests. Error strings are pinned exactly to the AC text.**

## Checklist results

- **All 6 routes return correct status + body:** Confirmed. Bodies and error strings match the ACs verbatim. `send_json/3` (`http.ex:84`) sets `application/json` and `Jason.encode!`s the body correctly.
- **Updated comment accurate:** Confirmed. The old comment ("…room_keys/version, voip/turnServer, thirdparty/protocols, dehydrated_device … are left unimplemented") was removed; the new comment no longer makes that false claim. INFO-1 below.
- **Routes before `match _`:** Confirmed — routes at L168–201, catch-all at L998. No shadowing.
- **Correct router (Protected, not Public):** Confirmed. All 6 sit in `Nebu.Web.Router.Protected`, whose pipeline runs `Nebu.Web.Plugs.OidcPlug` (L26). The top router forwards `/_matrix` to Protected (router.ex:131) and the exact-prefix public forwards (login, refresh, auth_issuer/metadata, profile, media, versions) do not match any of the 6 paths — notably the `msc2965` forwards are exact-prefix and do not shadow `msc4143`/`msc3814`. So all 6 require a valid Bearer.
- **Security (read-only stubs):** No injection surface — all 6 handlers ignore request body/params and return constant responses. No user input is reflected, logged, or interpolated. `device_signing/upload` is a deliberate no-op store (ADR-011 managed-E2EE model) — acceptable for a stub; see INFO-2.
- **Regressions:** None. Routes are additive; no existing handler, helper, or route order changed. The 1 MB body cap (JsonBody) and security headers still apply via the top router.

## Findings

### MINOR-1 — Error envelopes built inline instead of via the `error/4` helper
The four 404 stubs (`voip/turnServer`, `room_keys/version`, `dehydrated_device`, `rtc/transports`) construct `send_json(conn, 404, %{"errcode" => ..., "error" => ...})` inline. The same file already exposes and uses the `error(conn, status, errcode, message)` helper (`http.ex:91`) 13 times for exactly this shape. The produced body is byte-identical, so this is purely a style/consistency nit — e.g. `error(conn, 404, "M_NOT_FOUND", "No backup found")`. Not blocking.

### MINOR-2 — `:red_phase` tag will linger after green
All 12 new tests carry `@tag :red_phase`. They were authored red-first (correct TDD), but now that the routes exist they pass. If `:red_phase` is excluded from the default `make test-unit-elixir` run (common ATDD convention), these regression tests would silently stop running. Recommend dropping the `:red_phase` tag now that the story is green, or confirming the tag is included in the unit run. Verify before marking done.

### INFO-1 — Comment correctness confirmed
The pre-existing comment that listed these endpoints as "left unimplemented" was the exact stale statement the story aimed to fix; it is now removed and replaced with per-route rationale comments. Good.

### INFO-2 — `device_signing/upload` is a no-op store by design
`POST /keys/device_signing/upload` returns `200 {}` without persisting the uploaded cross-signing keys. This is intentional per ADR-011 (server-side/managed E2EE) and matches the existing `/keys/upload` and `/keys/query` stubs in the same file. Not a finding — flagged only so the no-op is a conscious, documented decision and a future real-E2EE story revisits it.

## Test-review (bmad-testarch-test-review principles)

- **Every AC has a test:** Yes (table above). No AC has zero coverage → no MAJOR.
- **No hard waits / hidden assertions / non-determinism:** The 12 new tests are pure `Plug.Test` calls against the router with deterministic constant assertions. No `Process.sleep`, no timing. Good.
- **No cookie forging / DB-seeding shortcuts:** The auth-gate tests send no Bearer (testing the 401 path); the contract tests mint a real RS256-signed JWT against a generated JWK and a test issuer/audience via `setup_oidc_keys` — the real OidcPlug verification path, not a forged session. Good.
- **GenServer crash/restart test:** N/A — these are stateless constant-response handlers (no GenServer state). Correctly omitted per the project's Persistence-Strategy Option C (stateless).
- **Pre-dev test-review carryover (error-string pinning, MINOR):** Confirmed acceptable — the implementation uses the AC-specified strings and the contract tests assert them exactly.

## Recommendation

Ship. Address MINOR-2 (drop/verify `:red_phase` so the regression tests stay in the unit run) before marking the story `done`; MINOR-1 is optional polish.
