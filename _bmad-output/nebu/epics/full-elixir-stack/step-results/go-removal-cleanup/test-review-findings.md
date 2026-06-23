# Pre-Dev Test Review — go-removal-cleanup

Date: 2026-06-17
Reviewer: nebu-pipeline (test-review gate)
Verdict: **PASS — 0 MAJOR, 2 MINOR, 2 INFO**

This is a deletion + cutover story. Its acceptance tests are infrastructure
assertions (no .go files, CI green, no Go services in compose), not new
behavioral tests. Behavioral parity of the Elixir stack was already proven by
the `elixir-stack-regression` story (DONE, committed 59571cda). The test-review
therefore checks AC→verification coverage, not new ExUnit/Godog tests.

## AC → Verification Coverage

| AC | Requirement | Verification | Status |
|----|-------------|--------------|--------|
| 1 | No `.go` files remain | `test/smoke/no-go-files.sh` (RED now: 374 files, exit 1) | COVERED (automated, CI gate) |
| 2 | No gateway/media in docker-compose | grep assertion at ci-gate + `make test-compose-ports` (core serves public ports) | COVERED |
| 3 | No Go steps in CI | grep assertion (`go build/go test/govulncheck/make test-unit-go/make build-gateway`) + CI runs green | COVERED |
| 4 | OpenTofu Go-gateway targets removed | grep assertion + `make test-iac-validate` (`test-load-syntax`) | COVERED |
| 5 | renovate.json: no Go module rules | grep assertion | COVERED |
| 6 | Makefile: removed-or-deprecation-error | smoke assertion: `make test-unit-go`/`make build-gateway` prints the deprecation error | COVERED |
| 7 | CI green, no slowdown | ci-gate (Elixir build + unit-elixir) + story-6 regression suite | COVERED (slowdown bound is observational, not unit-testable) |

Every AC has at least one verification. No AC has zero coverage → no MAJOR finding.

## Cutover safety (the real risk in this story — high blast radius)

The deletion is mechanically safe ONLY if these are handled in dev-story. These
are NOT new test gaps — they are deferred items from earlier stories that land
here. Dev must prove each by re-running unit-elixir + (where possible) the
regression suite:

- **C1 — Schema migrations.** `gateway/migrations/*.sql` are golang-migrate
  files applied by the Go gateway (`NEBU_DB_URL_MIGRATE` + golang-migrate iofs).
  Per ADR-018 migrations are the SOLE canonical data model. Deleting `gateway/`
  removes the ONLY migration runner. Dev MUST re-home the migration mechanism to
  the Elixir side (Ecto.Migrator via a release task, or equivalent) and prove the
  schema still provisions. **If this is not done, the stack cannot start on a
  fresh DB → would be a CRITICAL deletion bug.** Verification: stack comes up on
  a clean volume; `make test-compose-ports` / regression suite green.
- **C2 — Public ports / live path.** Today `gateway` publishes 8008 (Matrix) +
  8080 (admin); `core` publishes only 4000. After Go removal, `core` MUST serve
  the public Matrix + media + admin endpoints. Verify no port regression and the
  OidcPlug (full token validation: alg-allowlist, fail-closed iss/aud,
  TokenDenylist, RateLimit) is on the live request path — NO window of unverified
  tokens. The `NEBU_OIDC_VALIDATION_DISABLED` Go toggle becomes moot once Go is
  gone.
- **C3 — Admin session cutover.** Phoenix LiveView admin (Phoenix session) must
  work end-to-end against the Elixir stack with real Dex Auth-Code + PKCE — no
  cookie forging. (AC4 of admin-ui-migration was explicitly deferred here.)

## MINOR

- **M-1 (AT#2 references a non-existent `make ci` target).** The story's
  Acceptance Test #2 invokes `make ci`, but no `ci` target exists in the
  Makefile (only discrete `test-unit-*`, `test-integration*`, `test-e2e*`).
  Dev should either add a thin `ci` aggregate target OR the ci-gate runs the
  discrete targets and the AT is satisfied by them. Non-blocking — the intent
  (full suite green) is met by ci-gate.
- **M-2 (smoke test excludes node_modules/vendor).** Correct per the AC literal
  (`-not -path "*/vendor/*"`), but worth a comment that any genuine source `.go`
  outside those paths still fails the gate (it does — verified RED on 374 files).

## INFO

- I-1 — `docker/Dockerfile.ci.go` is a CI builder image; it is a `.go` file by
  the smoke test's literal match and must also be removed/renamed (it is, in
  fact, a Dockerfile with a `.go` suffix — confirm it is deleted or renamed so
  the smoke gate passes).
- I-2 — `proto/`: keep `.proto` sources + Elixir stubs; delete only `*.pb.go` /
  `*_grpc.pb.go`. The smoke test enforces this automatically.

## Gate decision

PASS. No MAJOR. Proceed to dev-story. Dev MUST treat C1/C2/C3 as
build-breaking acceptance criteria, not optional cleanup.
