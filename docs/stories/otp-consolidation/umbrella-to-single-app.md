---
story_id: umbrella-to-single-app
title: "OTP Consolidation — Umbrella to Single Application with Matrix/Media/Admin Domains"
epic: otp-consolidation
status: done
security_review: required
created: 2026-06-17
branch: feature/otp-consolidation
---

## Summary

The full-elixir-stack migration left the `core/` codebase as a **nine-app Mix umbrella**
(`nebu_db`, `signature`, `permissions`, `presence`, `compliance`, `session_manager`,
`room_manager`, `event_dispatcher`, `nebu_http`). Nebu does not need an umbrella: one
deployment artefact, one team, one release cycle (ADR-019). This story consolidates the
umbrella into a **single OTP application** (`:nebu` / `Nebu.Application`) and restructures
the modules into the three feature-domain namespaces from ADR-020 — `Nebu.Matrix.*`,
`Nebu.Media.*`, `Nebu.Admin.*` — plus the cross-cutting `Nebu.Web.*`, `Nebu.Compliance.*`,
and top-level `Nebu.Repo` / `Nebu.Release`. Each feature domain gets a Public-API module.

No business logic changes — only the file structure, the supervisor hierarchy, the module
names, and the config app-namespace.

## User Story

As a Nebu contributor / BMAD agent,
I want one OTP application with a flat, domain-namespaced `lib/nebu/` structure,
So that the codebase matches ADR-019/ADR-020, is searchable in one step, and has one
`mix.exs`, one `Application`, and one supervisor tree.

## Domain Mapping (umbrella app → target namespace)

| Umbrella app | Current module(s) | Target namespace |
|---|---|---|
| `nebu_db` | `Nebu.Repo`, `Nebu.Release`, `Nebu.DBHelpers`, `Nebu.DB.Application` | top-level `Nebu.Repo`, `Nebu.Release`, `Nebu.DBHelpers` (drop `Nebu.DB.Application`) |
| `signature` | `Nebu.Signature.*` | `Nebu.Matrix.Signature.*` |
| `permissions` | `Nebu.Permissions.*` | `Nebu.Matrix.Permissions.*` |
| `presence` | `Nebu.Presence.*` | `Nebu.Matrix.Presence.*` |
| `session_manager` | `Nebu.Session.*` | `Nebu.Matrix.Session.*` |
| `room_manager` | `Nebu.Room.*` | `Nebu.Matrix.Room.*` |
| `event_dispatcher` | `Nebu.Event.*`, `Nebu.EventDispatcher.*`, `Nebu.Health.*`, `Nebu.NodeRegistration`, `Nebu.BuildInfo`, `Nebu.{Profile,Receipt,Search,Admin}.DB`, `Nebu.Grpc.*`, proto stubs | `Nebu.Matrix.*` (dispatch, event, profile/receipt/search DB), `Nebu.Health.*` + `Nebu.BuildInfo` + `Nebu.NodeRegistration` stay top-level (infra), gRPC under `Nebu.Matrix.Grpc.*` |
| `compliance` | `Compliance.*` | `Nebu.Compliance.*` |
| `nebu_http` (Matrix) | `NebuHttp.Matrix`, `NebuHttp.MatrixPublic`, `NebuHttp.OidcMetadata`, `NebuHttp.Router.Protected` | `Nebu.Matrix.Http.*` |
| `nebu_http` (Media) | `NebuHttp.Media.*`, `NebuHttp.Router.Media` | `Nebu.Media.*` |
| `nebu_http` (Admin) | `NebuHttp.Admin.*`, `NebuHttp.AdminEndpoint` | `Nebu.Admin.*` |
| `nebu_http` (shared) | `NebuHttp.Router`, `NebuHttp.Plugs.*`, `NebuHttp.TokenDenylist`, `NebuHttp.JwksCache`, `NebuHttp.Application` | `Nebu.Web.*` (router, plugs, denylist, jwks); `Nebu.Application` (the merged Application) |

Public-API modules to add: `Nebu.Matrix`, `Nebu.Media`, `Nebu.Admin` — the only entry
points other domains may call (ADR-020).

> The implementer may refine the mapping where it makes a module land more naturally,
> as long as the three feature namespaces + Public-API rule hold and the build stays green.

## Acceptance Criteria

1. **Given** the `core/` project, **When** `find core -name mix.exs -not -path "*/deps/*" -not -path "*/_build/*"` is run, **Then** exactly one file is returned (`core/mix.exs`).
2. **Given** the `core/` project, **When** searched, **Then** there is no `core/apps/` directory and no second `use Application` module — exactly one `Nebu.Application`.
3. **Given** `core/mix.exs`, **When** inspected, **Then** it declares a single app `:nebu` (no `apps_path:`), the union of all former apps' deps (deduplicated, highest version wins), and a single `releases: [nebu: ...]` without an `applications:` umbrella list.
4. **Given** the running app, **When** it boots, **Then** the merged `Nebu.Application` supervisor starts all former children (Repo, libcluster, Presence manager, Session ETS store, Horde room registry + supervisor, compliance workers, JWKS cache, Finch, Phoenix.PubSub, AdminEndpoint, Health server, gRPC server, Bandit) with no duplicate registered-name collisions, and the boot-time ETS tables (`:NebuSessions`, `:NebuPresence`, `:NebuTxnDedup`), `:pg` scope, and `:nebu_signing_key` persistent_term are created exactly once.
5. **Given** the code, **When** searched, **Then** the `app_dir`/`otp_app`-bound config (the Ecto `Nebu.Repo` and the Phoenix `NebuHttp.AdminEndpoint`, plus `Nebu.Release`'s `@app`) is unified under the single `:nebu` app key. The remaining per-domain config keys (`:nebu_http`, `:signature`, `:compliance`, `:event_dispatcher`, `:presence`, `:session_manager`, `:room_manager`) are **retained as logical namespaces** — a deliberate decision because two DI-seam keys collide across domains (`:db_module` in room vs session; `:pg_store_module` in event_dispatcher vs session, with different default modules), so a blind unification would silently cross-wire test injections. `Application.get_env` reads these regardless of app-start status, and they emit no warning at release boot (verified). External keys `:libcluster`, `:ex_aws`, `:phoenix` are unchanged.
6. **Given** the code, **When** searched, **Then** feature-domain modules live under `Nebu.Matrix.*`, `Nebu.Media.*`, `Nebu.Admin.*`; the Public-API modules `Nebu.Matrix`, `Nebu.Media`, `Nebu.Admin` exist; no `NebuHttp.*`, `Compliance.*` (bare), `Nebu.Room.*`, `Nebu.Session.*`, `Nebu.Presence.*`, `Nebu.Event.*` modules remain.
7. **Given** the container build, **When** `make build-core` is run, **Then** `mix compile --warnings-as-errors` succeeds.
8. **Given** the container test run, **When** `make test-unit-elixir` is run, **Then** the full ExUnit suite passes (the same tests that passed before, moved to `core/test/` and renamed to the new modules).
9. **Given** `core/Dockerfile`, **When** inspected, **Then** the per-app `COPY apps/*/mix.exs` lines are gone (single `COPY mix.exs mix.lock ./`) and `mix release` still produces a valid `nebu` release.
10. **Given** `Makefile` and `docker-compose*.yml`, **When** inspected, **Then** umbrella paths (e.g. proto output `core/apps/event_dispatcher/lib/pb`) point at the new single-app locations and the stack still starts via `make dev` / `make redeploy`.

## Acceptance Tests

### Tests written FIRST (before implementation code):

The **existing ExUnit suite is the acceptance test for this refactor** — it is a
structure/rename change with no behavior change, so a green suite under the new module
names proves equivalence. Concretely:

1. **Full suite green after rename** — ExUnit (`make test-unit-elixir`)
   - Given: the consolidated single-app `core/` with all tests moved to `core/test/` and updated to the new module names.
   - When: `mix test --warnings-as-errors` runs in the build container.
   - Then: every test that passed pre-refactor passes — same count, zero failures, zero warnings.

2. **Boot / supervisor application test** — ExUnit (existing `application_test.exs`, updated)
   - Given: the merged `Nebu.Application`.
   - When: the application starts (test env).
   - Then: the supervisor children list matches the test's expectation, no `{:already_started, _}` / duplicate-name crashes, and the boot ETS tables + `:pg` scope + signing-key persistent_term exist.

3. **Crash/restart resilience (Horde room registry)** — ExUnit (existing room GenServer crash test, updated to `Nebu.Matrix.Room.*`)
   - Given: a room process registered in `Nebu.Matrix.Room.Registry` under the merged supervisor.
   - When: `Process.exit(pid, :kill)`.
   - Then: Horde restarts/migrates the process and room state is recovered — proving the merged supervisor tree preserves the Horde topology.

4. **Smoke: Matrix `/_matrix/client/versions` + Media + Admin reachable** — integration (existing router tests, updated namespaces)
   - Given: the single Bandit listener with `Nebu.Web.Router` forwarding into Matrix/Media/Admin.
   - When: the protocol smoke tests run.
   - Then: Matrix versions endpoint, a media endpoint, and the admin endpoint all respond as before.

## Implementation Notes

- **Module names are decoupled from file paths in Elixir** — references are textual, so a
  rename is a global text substitution per module prefix; verify with `mix compile` after
  each domain.
- **Recommended order:** (a) de-umbrella keeping current names + unify config to `:nebu` →
  green checkpoint; (b) rename per domain into `Nebu.Matrix/Media/Admin/Web/Compliance` +
  add Public-API modules → green. Two commits under this story are acceptable.
- **Supervisor merge:** preserve dependency-startup order (Repo → ETS/pg/key → domain
  child supervisors → web listener). Keep per-domain child supervisors
  (`Nebu.Matrix.Supervisor`, etc.) — idiomatic, not an umbrella.
- **Watch for named-process collisions:** the former per-app `*.Supervisor` names collapse;
  `:pg.start_link/0` and the ETS guards already handle double-start — keep exactly one of each.
- **Config worker-injection seams** (`config :compliance, :workers, []`,
  `:nebu_http, start_jwks_cache/start_finch/start_admin_endpoint`) must keep working under
  the `:nebu` key so the children-count assertions in the unit suite stay valid.
- **No `Ecto.Schema` / Repository / Service layer** introduced (ADR-018). SQL stays inline.
- DoD: commit ADR-019 + ADR-020 (done in scaffold) and the adapted `ARCHITECTURE.md` /
  `CLAUDE.md` — but the `ARCHITECTURE.md`/`CLAUDE.md`/`README` rewrite + Go-doc removal is
  the **next story** (`docs-go-removal`); this story owns code + the two ADRs only.
