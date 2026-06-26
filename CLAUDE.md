# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**Nebu** (short for Nebuchadnezzar, the ship of the free from The Matrix film) – An enterprise-grade, Matrix Client-Server API compatible chat server. Apache 2.0 licensed, no federation, horizontally scalable. Designed to replace Slack/Teams with full data sovereignty.

The entire stack is Elixir/OTP (ADR-021 — Go was removed in the `full-elixir-stack`
epic). The codebase is a **single OTP application** (ADR-019), not an umbrella.

## Tech Stack

| Layer | Technology |
|---|---|
| Application | Elixir/OTP 1.19+ — single OTP app (`:nebu` / `Nebu.Application`) |
| HTTP / Web | Bandit + Plug (Matrix API & media); Phoenix LiveView (Admin UI) |
| Database | PostgreSQL 16+ |
| Migrations | Raw SQL via `Nebu.Release.migrate/0` (Ecto for the connection pool only) |
| Sessions / Cache | ETS (Elixir built-in) — kein Redis |
| Pub/Sub | pg Process Groups (built-in) — kein NATS |
| Clustering | libcluster + Horde |

## Architecture

**One Elixir/OTP application** (`server/`, app `:nebu`), no umbrella (ADR-019), with three
feature-domain module namespaces plus shared/cross-cutting namespaces, all under one
supervisor tree (`Nebu.Application` → `Nebu.Supervisor`):

- **`Nebu.Matrix`** — Matrix Client-Server API + all stateful chat logic: rooms (Horde
  GenServers), sessions (ETS + PostgreSQL), presence, permissions, signing, event
  dispatch, sync, and the Matrix HTTP surface (`Nebu.Matrix.Http*`).
- **`Nebu.Media`** — media gateway (upload/download/crypto/storage via ExAws/Finch).
- **`Nebu.Admin`** — Admin UI (Phoenix LiveView) + admin OIDC login + admin DB queries.
- **`Nebu.Web`** — shared HTTP plumbing: the single Bandit listener's top router, plugs
  (OIDC, rate limit, request id/logger), JWKS cache, token denylist.
- **`Nebu.Compliance`** — audit log (cross-cutting).
- Top-level infra: `Nebu.Repo`, `Nebu.Release`, `Nebu.Health.*`, `Nebu.NodeRegistration`.

**Public-API rule (ADR-020):** other domains may only call `Nebu.Matrix`, `Nebu.Media`,
`Nebu.Admin` — never another domain's internal submodules. PostgreSQL is the append-only
event log + schema owner (migrations via `Nebu.Release`, ADR-018). No Redis. No NATS. No Kafka.

> `Nebu.Matrix.EventDispatcher.Server` + the `Core.*` structs are the **in-process**
> command/DTO layer the HTTP routers call directly. They were once a gRPC service; the
> `grpc-removal` epic (ADR-021) removed the last of it — no `:grpc`/`:protobuf` deps, no
> `use GRPC.Server`, no network listener. `Server` is a plain module raising
> `Nebu.Matrix.Error` (status via `Nebu.Matrix.Status`), and `Core.*` (`server/lib/pb/`)
> are plain Elixir structs. `Nebu.Matrix.Http.call_core/1` maps a raised
> `Nebu.Matrix.Error` to the Matrix HTTP error envelope.

## Directory Structure

```
server/                     ← the single Elixir/OTP application (app :nebu)
  mix.exs                   ← one mix.exs (no apps_path, no umbrella)
  lib/
    nebu/
      application.ex        ← Nebu.Application — one supervisor tree
      stateful_supervisor.ex← isolates crash-prone Presence/Session/Horde rooms
      repo.ex  release.ex   ← Ecto Repo (pool) + raw-SQL migration runner
      matrix/               ← Nebu.Matrix.* — Matrix API + rooms/sessions/presence/…
      media/                ← Nebu.Media.* — media gateway
      admin/                ← Nebu.Admin.* — Admin LiveView UI + admin DB
      web/                  ← Nebu.Web.* — router, plugs, jwks, token denylist
      compliance/           ← Nebu.Compliance.* — audit log
      health/  node_registration.ex  build_info.ex   ← infra
    pb/                     ← Core.* plain-struct DTOs (in-process command/response shapes)
  priv/
    migrations/             ← canonical SQL schema (ADR-018) — run by Nebu.Release
    static/                 ← Admin UI assets (served by Nebu.Admin.Endpoint)
  test/nebu/{matrix,media,admin,web,compliance}/  ← tests mirror the domains
proto/                      ← historical .proto (no longer generated from — grpc-removal/ADR-021)
docs/
  architecture/             ← arc42 sections, ADRs
  stories/                  ← BMAD epics & stories
```

## Commands

All builds run via Docker containers — no local Elixir or buf installation required.

### Elixir/OTP server (via build container)

```bash
make build-server                 # mix compile inside the build container
make test-unit-elixir             # mix test in container
```

### Local Development (Docker)

```bash
make dev                          # docker compose up (server, postgres, dex/keycloak, minio)
make setup                        # first-time setup: generate .secrets/internal_secret + test keys
make test-integration             # full stack + Godog Gherkin tests
make redeploy                     # rebuild + restart the server Docker image/container
```

**After committing code changes, always use `make redeploy`** — not `make build-server`.

- `make build-server` only runs `mix compile` inside a throw-away container — it does NOT build a Docker image.
- `make redeploy` rebuilds the `server` image docker compose uses and recreates the container.

Environment variables (prefix: `NEBU_`):
- `NEBU_DB_URL` — PostgreSQL connection string (migrations: `NEBU_DB_URL_MIGRATE` fallback)
- `NEBU_POSTGRES_SSL` — set to `"true"` to enable SSL on the PostgreSQL connection (both runtime Repo and migrations); default `"false"`. Use this instead of `?ssl=true` / `?sslmode=require` URL parameters.
- `NEBU_OIDC_ISSUER` / `NEBU_OIDC_AUDIENCE` — OIDC provider config (validated at boot)
- `NEBU_PII_ENCRYPTION_KEY` — 32-byte hex key for PII-at-rest encryption
- `NEBU_INTERNAL_SECRET_FILE` — path to shared node-registration / admin-key-base secret file

## Matrix API Scope

**Implemented (MVP target):**
- `POST /_matrix/client/v3/login`
- `POST /_matrix/client/v3/logout`
- `GET  /_matrix/client/v3/sync`
- `PUT  /_matrix/client/v3/rooms/{roomId}/send/{eventType}/{txnId}`
- `GET  /_matrix/client/v3/rooms/{roomId}/messages`
- `POST /_matrix/client/v3/createRoom`
- `POST /_matrix/client/v3/join/{roomIdOrAlias}`
- `PUT  /_matrix/client/v3/rooms/{roomId}/typing/{userId}`
- `POST /_matrix/client/v3/rooms/{roomId}/receipt/{receiptType}/{eventId}`
- `GET/PUT /_matrix/client/v3/profile/{userId}`
- `GET  /_matrix/client/v3/presence/{userId}/status`
- `GET  /_matrix/client/unstable/org.matrix.msc2965/auth_issuer` (MSC2965 OIDC discovery — also stable `v1/` path)
- `GET  /_matrix/client/unstable/org.matrix.msc2965/auth_metadata` (MSC2965 OIDC discovery — also stable `v1/` path)
- `POST /_matrix/client/v3/keys/upload` · `POST /_matrix/client/v3/keys/query` — device-key **directory** (PostgreSQL-backed, `Nebu.Matrix.DeviceKeyStore`). Stores/serves public device + one-time + fallback keys so clients (Element) register a device cleanly. **Not E2EE** — orthogonal to encryption (ADR-011).
- `GET  /_matrix/client/v3/devices` · `GET /_matrix/client/v3/devices/{deviceId}` — device list for the current user
- `GET  /_matrix/client/v3/account/whoami` (returns `device_id` for opaque sessions)

**E2EE stays OFF (ADR-011):** `m.room.encryption` is rejected/skipped in every state-write path (direct state-PUT → `403 M_FORBIDDEN`; `createRoom` `initial_state` and room-upgrade `copy_state_events` → skipped). The device-key directory does **not** enable encryption.

**Intentionally excluded:** All `/_matrix/federation/*`, `/_matrix/identity/*`, `/_matrix/key/*` (no federation by design).

## Resolved Architecture Decisions

All major decisions are documented in `_bmad-output/planning-artifacts/architecture.md`.
ADRs are tracked in `docs/architecture/adr/`:

| ADR | Decision |
|---|---|
| 001 | Elixir/OTP (not Erlang) — libcluster, Mix tooling |
| 002 | No Redis, No NATS — ETS + pg Process Groups replace both |
| 003 | Content-Hash Event-ID (Matrix Room Version 6+) |
| 004 | Horde Registry + DynamicSupervisor for Room GenServers |
| 005 | gRPC Server-Streaming EventBus + Unary fallback — **superseded by ADR-021 / `grpc-removal` epic** (gRPC fully removed; the command layer is in-process plain modules) |
| 006 | message_buffer drain strategy (linear MVP, AIMD Phase 2) |
| 007 | Ed25519 (signing) + X25519 (encryption) — two key pairs per user |
| 008 | Node registration: PSK via Compose secrets (MVP) → Ephemeral mTLS (Phase 2) |
| 009 | OpenAPI Spec-First with oapi-codegen |
| 010 | Full-Text Search strategy (deferred) |
| 011 | Managed E2EE key escrow (server-side decryption model) |
| 012 | Upstream repo = reference implementation only; no official deployments; example-only CI credentials |
| 014 | Deployment strategy and IaC: OpenTofu (MPL-2.0) with AWS (ECS Fargate), Stackit (VMs + Docker Compose + ALB), Kubernetes/Helm |
| 015 | OIDC User Directory Integration: two complementary protocols — OIDC directory endpoint (Dex/Keycloak, user search) + SCIM 2.0 RFC 7644 (Azure AD/Okta, bulk import) |
| 016 | Git Branching and Release Strategy: simplified Git Flow (`main` + `develop` + …) — **Superseded by ADR-017** |
| 017 | Simplified main-only branching: `main` is the single long-lived branch; `feature/*`, `bugfix/*`, `release/*`, `hotfix/*` all branch from and merge to `main`. No `develop`. `main` builds dev-* images. |
| 018 | No Domain Model — Locality of Behavior: no ORM, no Repository pattern, no Service layer. SQL inline in each endpoint file. Migration SQL is the only canonical data model. Deliberate adaptation for LLM-assisted development (BMAD). |
| 019 | Single OTP Application — no umbrella. One `mix.exs`, one `Nebu.Application`, one supervisor tree. Domains are module namespaces under `lib/nebu/`. |
| 020 | Clustering Strategy & Module Architecture — `Nebu.Matrix`/`Media`/`Admin` domains with a Public-API rule (only these modules are callable cross-domain); BEAM-native scaling (libcluster + Horde + pg). |
| 021 | Elixir Consolidation / Go Removal — Go gateway + media gateway removed; whole stack is one Elixir/OTP app. gRPC fully removed (`grpc-removal` epic): no `:grpc`/`:protobuf` deps, the command layer is in-process plain modules + `Core.*` plain structs; native `Nebu.Matrix.Error`/`Status` replaces `GRPC.RPCError`/`GRPC.Status` (supersedes ADR-005). |

## Named Epic Convention (from v0.3.0+)

Stories and epics no longer use numeric identifiers. Each feature is its own named epic — a short, lowercase, hyphen-separated domain identifier:

| Was | Now |
|---|---|
| `epic-16`, `16-1`, `16-2` | `matrix-presence`, story files: `typing-indicators.md`, `read-receipts.md` |
| Story ID `14-4` | Story slug `gdpr-erasure` in epic `gdpr-compliance` |

**File locations:**
- Stories: `docs/stories/<epic-name>/<story-slug>.md`
- Pipeline state: `_bmad-output/nebu/epics/<epic-name>/pipeline-state.yaml`
- Sprint status: `_bmad-output/nebu/epics/<epic-name>/sprint-status.yaml`
- Step results: `_bmad-output/nebu/epics/<epic-name>/step-results/<story-slug>/`

**Git branches (ADR-017):**
- Feature epics live in `feature/<epic-name>` branches (branched from `main`)
- Stable releases are tagged on `main` — never on feature branches

**Existing numbered epics 1–16** (in `docs/stories/mvp/`, `phase2/`, `phase3/`) remain unchanged. Do not renumber or move them.

**Tooling:**
```
/nebu-release new-epic <name>     — create feature/<name> branch + scaffold dirs
/nebu-pipeline --epic <name>      — run a single story in named epic
/nebu-pipeline-epic --epic <name> — run all stories in named epic
/nebu-release close               — merge release/* or hotfix/* → main, tag
```

## BMAD Workflow

This project uses BMAD agents for structured development. The pipeline is:

```
bmad-create-story → bmad-testarch-atdd → bmad-dev-story → bmad-testarch-test-review → bmad-code-review → security-review*
     (SM)              (TEA)               (Dev)              (TEA)                     (Review)         (conditional)
```

`*` — Per-story security review runs conditional (see Gate 4 below); epic-end security review is mandatory.

### Gate 1 — Story Creation (`/bmad-create-story`)

**Owner: Bob (SM)**

After the story file is created and before it moves to `ready-for-dev`:

1. Story file must contain the **"Acceptance Tests"** section (see Testing Conventions below)
2. Run **`/bmad-testarch-atdd`** to generate failing acceptance tests from the story's acceptance criteria
3. The generated failing tests are committed alongside the story — implementation starts against them

**When to skip atdd:** Pure infrastructure stories with no observable behavior (e.g., Dockerfile changes, migration-only). All other stories require it.

### Gate 2 — Implementation (`/bmad-dev-story`)

**Owner: Amelia (Dev)**

The Red-Green-Refactor cycle:

1. Failing tests from Gate 1 are already present — do not write new implementation code before running them
2. Implement until all acceptance tests pass (no new code without a failing test)
3. For complex test scenarios or edge cases: invoke **`/bmad-tea`** as a test design partner
4. Run `make test-unit-elixir` before marking story as `review`

### Gate 3 — Code Review (`/bmad-code-review`)

**Owner: Code Review Agent**

Before marking a story `done`, the code reviewer MUST invoke **`/bmad-testarch-test-review`** and include its findings in the review report.

The test review checks:
- Every Acceptance Criterion has at least one test
- No hard waits, no hidden assertions, tests are deterministic
- GenServer state stories have a crash/restart test
- No cookie forging or DB-seeding shortcuts in E2E tests

**MAJOR finding if:** Any acceptance criterion has zero test coverage.

### Gate 4 — Security Review (SEC Gate 1 + SEC Gate 2)

**Owner: Code Review Agent / Pipeline**

Added 2026-04-20 after security audit found CRITICAL/HIGH findings that passed through Gates 1–3 across four epics.

**SEC Gate 1 — Per-story (conditional):**

Each story file declares in its frontmatter:

```
---
security_review: required | optional | not-needed
---
```

- `required` — pipeline runs a security-focused `/bmad-code-review` pass in a fresh subagent after Gate 3. CRITICAL/HIGH block the commit.
- `optional` — user decides per-invocation.
- `not-needed` — skipped.
- Flag missing → auto-classified `required` if the staged diff touches `server/lib/nebu/web/` (plugs/router/auth), `server/lib/nebu/admin/`, `server/lib/nebu/matrix/{signature,permissions,session}/`, the Bandit/router wiring in `server/lib/nebu/application.ex`, new SQL migrations under `server/priv/migrations/`, or Elixir code using `:crypto` / external input.

**SEC Gate 2 — Epic-end (mandatory):**

Before the retrospective, `/bmad-pipeline` runs a whole-epic security review against `git diff <epic-base>..HEAD`. The output is saved as `_bmad-output/implementation-artifacts/epic-{N}-security-review-{YYYY-MM-DD}.md` — always, even at zero findings (audit trail). CRITICAL/HIGH must become follow-up stories (or be explicitly accepted as a risk with written justification) before the epic is marked `done`.

**Security scope (both gates, identical prompt):** SQL injection, XSS, CSRF on state-changing endpoints, auth bypass (missing middleware, IDOR), timing attacks on secret comparison, open redirects, missing body-size limits, missing rate limits, weak crypto primitives (md5/sha1/DES), plaintext secrets in logs, missing security headers, path traversal, JWT validation flaws (alg confusion, missing exp/aud/nonce).

### Epic Completion — Traceability

At the end of each epic, run **`/bmad-testarch-trace`** to generate the requirements-to-tests traceability matrix. Gate: ≥80% P0+P1 coverage before epic is marked `done`.

## MCP Tools & Testing Conventions

### Context7 — Current Library Docs
Use the `context7` MCP server before implementing any story that touches external libraries or APIs. Load current docs first, do not rely on training data alone.

**When to use:**
- Any story using `assent` (OIDC), `bandit`/`plug`, `phoenix`/`phoenix_live_view`, `ecto`/`postgrex`, `ex_aws`/`finch`, OTP `:crypto`/`:pg`, `horde`/`libcluster`, Dex API, Tailwind, DaisyUI, Playwright
- When API behavior is unclear or a library version has changed

**How:** Call `mcp__context7__resolve-library-id` → `mcp__context7__query-docs` before writing implementation code.

### Playwright — HTML/UI E2E Tests
Use the `playwright` MCP server for all E2E tests that involve HTML pages, forms, buttons, or browser navigation (Admin UI, Bootstrap Wizard, Dashboard, Matrix web client flows).

**Split:**
- **Playwright + Cucumber/Gherkin** → browser-level tests (HTML pages, form submits, button clicks, redirects, Matrix web client E2E)
- **ExUnit `:integration` tests (`Plug.Test` / `:httpc` against the running stack)** → HTTP/protocol-level tests (Matrix Client-Server API, media endpoints). These live in `server/test/` and run via `make test-integration`. (The former Go/Godog HTTP harness was removed with the Go stack — ADR-021.)

**E2E test format (mandatory):** All Playwright E2E tests MUST be written as Gherkin feature files with a Cucumber-based framework (`playwright-bdd` or `@cucumber/cucumber` + Playwright). Plain `.spec.ts` files without a `.feature` counterpart are not accepted.

Structure:
```
e2e/features/<feature>.feature   ← Gherkin scenarios (written first, failing)
e2e/steps/<feature>.steps.ts     ← Cucumber step definitions
```

**Why:** HTTP-level navigation of Authorization Code flows is complex and brittle. Playwright handles real browser flows correctly. Gherkin keeps scenarios readable and directly traceable to acceptance criteria.

**Migration note:** Existing `.spec.ts` files are being migrated to the Gherkin format. New stories must use `.feature` + step definitions from day one — no new plain `.spec.ts` files.

### TDD/ATDD — Tests First, Always

**The Nebu TDD Standard: write the failing test before writing implementation code. This applies to ALL story types, not just UI.**

**Why:** Story 3-8 (sync.Map → 3 review rounds) and recurring MAJOR findings in Epic 4 code reviews show that tests written after the fact do not catch architectural mistakes early enough. A failing test written first forces the correct design.

#### For Elixir GenServer / ETS / Horde Stories:

Write **ExUnit tests first** (failing), then implement:

1. **Happy-path test**: `send_event/5` returns `{:ok, event_id}` — write before the function exists
2. **Crash/restart test**: `Process.exit(pid, :kill)` → state recovered via Horde — write before Horde supervision exists
3. **Persistenz-Strategie** (mandatory for any story with GenServer state):
   - Describe how this state survives a restart
   - Option A: ETS (volatile, recovered via Horde migration) — add crash test
   - Option B: PostgreSQL (persistent, read on start) — add read-on-start test
   - Option C: Stateless — no restart test needed

#### For Matrix API Endpoint Stories:

Write the **ExUnit `:integration` test first** (failing), then implement:

1. Write a `@moduletag :integration` ExUnit test in `server/test/nebu/matrix/` driving the Plug router (happy path + one error case)
2. The handler returns `501 Not Implemented` (or `M_UNRECOGNIZED`) initially
3. Implement the handler until the integration test is green
4. Add edge-case unit tests (`Plug.Test` conn helpers, pure ExUnit)
5. **Additionally:** if the API behavior is visible through a web client (send message, join room, sync, etc.), also write a Playwright+Gherkin scenario in `e2e/features/` that tests through a real browser session.

#### For Admin UI Stories (HTML/browser) and Matrix Web Client Stories:

Write **Gherkin feature file first** (failing), then implement:

1. Write `e2e/features/<feature>.feature` (Gherkin scenarios) before any HEEx/LiveView template code
2. Write `e2e/steps/<feature>.steps.ts` (Cucumber step definitions) — initially failing
3. Use real browser flows — no cookie forging, no DB seeding shortcuts
4. Tests run against the real running stack (no mocks) via `playwright-bdd` or `@cucumber/cucumber` + Playwright

**Epic 3 retrospective:** Story 3-8 went through 3 code review rounds because an upfront acceptance test would have revealed the restart-resilience requirement. Story 3-15 forged cookies instead of testing real flows because the test was written last.

### Story Acceptance Test Requirement

Every story document MUST contain an **"Acceptance Tests"** section (written by the story creator, before implementation):

```
## Acceptance Tests

### Tests written FIRST (before implementation code):

1. [Test name] — [ExUnit / Godog (.feature) / Playwright+Cucumber (.feature + .steps.ts)]
   - Given: [starting state]
   - When: [action]
   - Then: [expected outcome]

2. [Crash/Restart test — required for all GenServer state stories]
   - Given: [service running with state]
   - When: [Process.exit(:kill) / service restart]
   - Then: [state recovered / correctly migrated]
```

**Code Review gate:** Does every Acceptance Criterion have at least one test? If not, the story is not done.

### TEA Skills — Quick Reference

| When | Skill | Who | Mandatory |
|---|---|---|---|
| After story created, before dev starts | `/bmad-testarch-atdd` | SM/Dev | **Yes** |
| During implementation, for complex tests | `/bmad-tea` | Dev | On demand |
| During code review | `/bmad-testarch-test-review` | Reviewer | **Yes** |
| End of epic | `/bmad-testarch-trace` | SM | **Yes** |
| End of epic | `/bmad-generate-arc42` | SM | **Yes** |
| When test strategy needed for a new epic | `/bmad-testarch-test-design` | SM/Arch | On demand |
| When NFRs need validation | `/bmad-testarch-nfr` | Dev/Arch | On demand |

See **BMAD Workflow** section above for the full gate sequence.

### OIDC / Auth Testing Standard
All Gherkin tests involving OIDC must use Authorization Code + PKCE. ROPC is not supported by Dex v2.41+. Never use `grant_type=password` shortcuts in E2E tests.

## Elixir Conventions
- **Single OTP app, no umbrella (ADR-019):** one `mix.exs`, one `Nebu.Application`. Never add a new `mix.exs`, a new `use Application`, or an `apps/` dir. New domains are module namespaces under `lib/nebu/`.
- **Public-API rule (ADR-020):** cross-domain calls go only through `Nebu.Matrix`, `Nebu.Media`, `Nebu.Admin` — never another domain's internal submodules.
- **No domain model (ADR-018):** SQL inline in the handler (`Postgrex.query`/`Nebu.Repo`); no `Ecto.Schema`, no Repository/Service layer. SQL duplication is intentional, not a finding.
- GenServer state: immer via handle_* callbacks, nie direkt.
- Fehler: let it crash + Supervisor, kein defensive try/rescue.
- Supervisor-Strategien: one_for_one default, begründe Abweichungen.
- **Cluster-ready primitives (ADR-020):** register processes via `Horde` (not a local `Registry`); for cluster-critical pub/sub use `pg`, not local `Phoenix.PubSub` alone. Code must behave identically on a single node and in a cluster.