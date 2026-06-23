# Test Quality Review — matrix-api-migration (RED-phase ATDD)

**Gate verdict: PASS — no blocking MAJOR. Proceed to dev-story.**

## AC coverage
- AC1 (contract parity all endpoints): YES — matrix_router_test covers every endpoint.
- AC2 (50 concurrent /sync within 500ms): YES — sync_concurrent_test.
- AC3 (Go removed from compose → core:4000): INFO — pure wiring, exercised by Godog against core:4000.
- AC4 (existing Godog suite passes): YES — feature reuses existing step defs.
- AC5 (MSC2965 discovery from NEBU_OIDC_ISSUER): YES — 4 unit + 3 Godog.
- AC6 (reverse proxy → core:4000, Element Web E2E): INFO — manual/infra only.
No AC has zero coverage.

## Auth-bypass guard — COVERED (good)
matrix_router_test proves forwarded /_matrix with no Bearer → 401 M_MISSING_TOKEN; garbage Bearer → 401 M_UNKNOWN_TOKEN. Discovery endpoints are the only unauthenticated /_matrix paths. This is the regression guard the story needed (no auth-bypass window).

## Findings
- MAJOR: none.
- MINOR-1: sync_concurrent_test `await_budget = max(remaining,50)+200` slack / comment overstates that Task.await is the timing gate — the 500ms guarantee rests on the post-hoc `elapsed` assertion (correct). Reword comment / drop +200.
- MINOR-2 (CARRY-OVER, blocking per coordinator): JWT alg-confusion (MEDIUM-2) and fail-closed iss/aud (MEDIUM-3) are NOT tested anywhere. Add 4 unit tests to oidc_plug_test.exs: `alg:none → 401`, `HS256-signed-with-pubkey-as-secret → 401`, `wrong iss → 401`, `wrong/missing aud → 401`. AND ensure OidcPlug actually enforces strict alg allowlist + fail-closed iss/aud during dev.
- INFO-1: 500ms wall-clock may flake under CI contention (fix = CI resources, not assertion).
- INFO-2: logout happy-path only.
- INFO-3: no Playwright E2E for AC6 (Element Web); Godog is the guard.

## Other checks
- ADR-018: PASS — tests use event_dispatcher injection seams + Plug.Test; no Repo/Schema.
- Crash/restart: N/A — stateless Plug.Router reusing existing GenServers.
- No DB-seeding / cookie-forging: PASS — state built via real router calls; JWTs signed with in-test RSA key, verified through real OidcPlug.
- Red-phase validity: confirmed failing-first.

## Dev-phase directives derived
1. Route discovery endpoints (auth_issuer/auth_metadata) BEFORE the OidcPlug gate (unauthenticated, like Go).
2. Login handler must convert malformed JSON body → 400 M_NOT_JSON itself (Plug.Parsers would otherwise raise 500).
3. Enforce + test MEDIUM-2 (strict alg allowlist) and MEDIUM-3 (fail-closed iss/aud) in OidcPlug; add the 4 tests above.
