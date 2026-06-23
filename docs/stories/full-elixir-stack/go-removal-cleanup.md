---
story_id: go-removal-cleanup
title: "Go Removal & Cleanup — Delete Go Source, Dockerfiles, CI Steps, OpenTofu Targets"
epic: full-elixir-stack
status: done
security_review: required
created: 2026-06-17
branch: feature/full-elixir-stack
---

## Summary

With all Go-implemented features now running in Elixir (Stories 1–5 done), this story removes all Go
artefacts from the repository: source code, Dockerfiles, Makefile targets, CI pipeline steps,
OpenTofu deployment manifests for Go containers, and Renovate Go module update rules.
Result: one deployment artefact, one Dockerfile, one toolchain.

## User Story

As a Nebu contributor,
I want all Go source code, Docker images, CI steps, and deployment targets removed,
So that the repository has a single Elixir/OTP artefact and toolchain.

## Acceptance Criteria

1. **Given** the repository root,
   **When** `find . -name "*.go" -not -path "*/vendor/*"` is executed,
   **Then** the output is empty (no Go source files remain in the repo).

2. **Given** `docker-compose.yml`,
   **When** inspected,
   **Then** no `gateway` or `media` Go-based services appear; only `core` (Elixir), `postgres`, `dex`, and the reverse proxy.

3. **Given** the CI pipeline (`.gitlab-ci.yml` or `.github/workflows/`),
   **When** inspected,
   **Then** no `go build`, `go test`, `govulncheck`, `make test-unit-go`, or `make build-gateway` steps remain.

4. **Given** the OpenTofu deployment manifests under `deployment/`,
   **When** inspected,
   **Then** all Go-gateway container targets (AWS ECS task definitions for `gateway`, Stackit docker-compose `gateway` service, Helm chart `gateway` deployment) are removed; only the single Elixir `core` container target remains.

5. **Given** the `renovate.json` (or `.renovaterc`) configuration,
   **When** inspected,
   **Then** Go module (`go.mod`, `go.sum`) update rules are removed; only Elixir/Mix + PostgreSQL update rules remain.

6. **Given** the `Makefile`,
   **When** `make test-unit-go` or `make build-gateway` is executed,
   **Then** the target either no longer exists or prints a clear deprecation error: `Error: Go layer has been removed in the full-elixir-stack migration. See docs/stories/full-elixir-stack/go-removal-cleanup.md`.

7. **Given** the full CI pipeline,
   **When** it runs after this story is merged to `main`,
   **Then** it completes green in ≤ the pre-migration baseline CI time minus the Go build/test time (i.e., no slowdown).

## Acceptance Tests

### Tests written FIRST (before implementation code):

1. **`test/smoke/no-go-files.sh`** — Shell smoke test (runs in CI)
   - When: executed in the repo root
   - Then: exits `0` if `find . -name "*.go" -not -path "*/vendor/*"` returns empty
   - Then: exits `1` with a list of found `.go` files if any remain (CI gate)

2. **`make ci`** — Full pipeline run (existing CI target)
   - Given: all Go artefacts removed, Elixir serving all routes
   - When: `make ci` runs (unit tests + integration tests + E2E tests)
   - Then: exits `0`; no Go-related step failures; no `command not found: go` errors

## Deletion Checklist

The following must be deleted or updated (not an exhaustive list — check `git ls-files` for remaining Go files):

- `gateway/` — entire directory (Go API gateway source)
- `media/` — entire directory (Go media gateway source)
- `gateway/Dockerfile` and `media/Dockerfile`
- `gateway/go.mod`, `gateway/go.sum`
- `docker-compose.yml` — remove `gateway` and `media` services
- `.gitlab-ci.yml` / `.github/workflows/` — remove Go build/test/lint jobs
- `Makefile` — remove `build-gateway`, `test-unit-go`, `gen-api`, `make build-media` targets
- `renovate.json` — remove Go module rules
- `deployment/aws/ecs/gateway-task-def.json` (and similar)
- `deployment/stackit/docker-compose.yml` — remove `gateway` service
- `deployment/k8s/helm/` — remove `gateway` Deployment, Service, Ingress templates
- `proto/` — remove Go-generated stubs (`*.pb.go`, `*_grpc.pb.go`); keep `.proto` sources and Elixir stubs

## Implementation Notes

- Run `git ls-files | grep "\.go$"` to find all tracked Go files before starting
- The `proto/*.proto` source files are kept — they define the data model and may be useful as reference
- Only Go-generated stubs (`_pb.go`, `_grpc.pb.go`) are deleted from `proto/`
- The `buf.gen.yaml` Go plugin configuration is removed; the Elixir plugin configuration remains
- After deletion, run `make redeploy` and verify the stack comes up with no Go containers
- Confirm with `docker ps` that no Go-based containers are running

## Admin OIDC Login — migrated to Elixir (coverage-gap closure)

The deleted Go gateway (`gateway/internal/admin/auth.go`) owned the admin OIDC
Authorization-Code + PKCE login. Deleting it left the Elixir admin with only an
on_mount gate that READS `current_user` and a `/admin/login/start` that redirected to
itself (infinite loop) — the Admin UI was unusable. This story therefore re-implements
the full flow in Elixir rather than deferring it:

- `NebuHttp.Admin.Auth.login_start/2` — PKCE verifier (32 CSPRNG bytes) + S256
  challenge + CSRF state + OIDC nonce, stashed in the signed Phoenix session; 302 to the
  IdP `authorization_endpoint` (resolved via `NebuHttp.OidcMetadata` discovery).
- `NebuHttp.Admin.Auth.callback/2` — constant-time state validation (fail-closed),
  PKCE code exchange at the provider `token_endpoint`, ID-token verification via the
  shared `NebuHttp.Plugs.OidcPlug.verify_token/2` (alg allowlist, JWKS signature,
  fail-closed iss, exp, sub, + admin-client audience override), nonce binding, admin
  group-claim gate, Phoenix session mint (`renew: true`, capped at min(idToken.exp, 8h)).
- `NebuHttp.Admin.Auth.logout/2` — drops the session.
- Config: `NEBU_ADMIN_OIDC_CLIENT_ID` / `..._CLIENT_SECRET[_FILE]` / `..._REDIRECT_URI`
  / `..._SCOPE` (runtime.exs). docker-compose uses the dedicated `nebu-admin` Dex client.
  The obsolete `NEBU_ADMIN_OIDC_LOGIN_URL` is removed. `security_review` reclassified to
  `required` for this addition.

### Tests — executed vs deferred

- **Executed:** `admin_oidc_login_test.exs` (13 ExUnit tests) — PKCE S256 derivation,
  state freshness, forged/mismatched/expired state rejection, missing-code bounce,
  ID-token verify via the shared path, audience-override cross-audience rejection,
  admin-gate allow/deny, session-expiry cap, on_mount expiry enforcement, logout.
  All green. Existing `oidc_plug_test.exs` still green (verify_token/2 backward-compat).
- **Deferred (live stack down in this environment):** the real Dex Authorization-Code +
  PKCE browser E2E — authored as `e2e/features/admin/admin-oidc-login.feature` +
  `e2e/step-definitions/admin/admin-oidc-login.steps.ts` (NO cookie forging, NO DB
  seeding). It exercises the HTTP token-exchange + discovery legs that ExUnit cannot
  cover without a network. Must be run against the running stack at CI.
