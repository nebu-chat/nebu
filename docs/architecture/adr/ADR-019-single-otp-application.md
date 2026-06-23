# ADR-019: Single OTP Application — No Umbrella

## Status

Accepted - 2026-06-17

Extended by: ADR-020 (adds the clustering context and the module/domain layout)

## Context

After the consolidation of the Go layer onto Elixir (full-elixir-stack epic; see
ADR-001 and ADR-021), Nebu consists entirely of Elixir/OTP. During that migration
the implementing BMAD agent created **one OTP application per domain** — a nine-app
umbrella (`nebu_db`, `signature`, `permissions`, `presence`, `compliance`,
`session_manager`, `room_manager`, `event_dispatcher`, `nebu_http`). This matches the
umbrella-project pattern common in large Elixir codebases.

Nebu has the following constraints:

- **One deployment artifact** — one Docker container, one OTP release.
- **One team** — no need for independent compile boundaries between teams.
- **One release cycle** — no domain-specific deployments.
- **BMAD-assisted development** — LLM agents work more effectively with a flat,
  searchable structure.

An umbrella is overkill for these constraints and adds complexity without payoff.

## Decision

Nebu uses **one single OTP application** (`:nebu` / `Nebu.Application`). No umbrella.
Domains are structured as **module namespaces** under `lib/nebu/`, not as separate
OTP applications.

```
lib/
└── nebu/
    ├── application.ex        ← one central supervisor tree
    ├── repo.ex               ← Ecto Repo (migrations + connection pool only)
    ├── matrix/               ← Nebu.Matrix.*  — Matrix Client-Server API + chat logic
    ├── media/                ← Nebu.Media.*   — Media gateway
    ├── admin/                ← Nebu.Admin.*   — Admin UI (Phoenix LiveView)
    ├── web/                  ← Nebu.Web.*     — shared HTTP plumbing (router, plugs)
    └── compliance/           ← Nebu.Compliance.* — audit log (cross-cutting)
```

## Rationale

### The deployment unit is the OTP application

An OTP application is the unit that is started, stopped and supervised. Multiple OTP
applications make sense when they can be deployed or stopped independently. For Nebu
this is never the case — Media, Matrix API and Admin UI always start and stop
together.

### Modules are the right structuring level

Elixir modules are namespaces with functions — they create no runtime boundaries, no
supervisor hierarchies, no deployment overhead. `Nebu.Matrix.Room` and
`Nebu.Media.Upload` live in the same OTP application and can call each other directly
without message passing or API contracts.

### Umbrella adds complexity without value

An umbrella means multiple `mix.exs` files with their own deps, multiple
`application.ex` files with their own supervisors, explicit inter-app dependency
declarations, and a more complex CI pipeline. This overhead is justified when teams
deploy independently or have different release cycles. Neither is true for Nebu.

### Searchability and BMAD compatibility

A flat module structure under `lib/nebu/` is easier for LLM agents to navigate than a
nested umbrella with several `apps/` directories. `grep -r "Nebu.Matrix" lib/` finds
all relevant modules in one step.

## Rejected Alternatives

- **Umbrella with one app per domain** — rejected. Adds complexity without value for
  Nebu's constraints. Compile boundaries between domains are not a goal.
- **Umbrella with Web/Core split** — rejected. The web layer and core share OTP state
  (ETS, pub/sub, room processes). A hard boundary would force message passing where a
  direct function call suffices.
- **Micro-services (multiple OTP releases)** — rejected. Contradicts the goal of
  architectural simplification. Nebu is not a micro-service system.

## Consequences

### Positive

- One `mix.exs`, one `application.ex`, one supervisor tree.
- Direct function calls between domains — no message-passing overhead.
- Simpler CI pipeline.
- LLM agents navigate a single `lib/nebu/` structure.
- `mix compile`, `mix test`, `mix release` work without an umbrella context.

### Negative / consciously accepted

- **No hard compile boundaries.** A module can call another without an explicit
  dependency declaration. Mitigation: architecture conventions instead of technical
  boundaries — the Public-API rule (see ADR-020), enforced by Kassandra in review.
- **The supervisor tree grows in one file.** Mitigation: per-domain child supervisors
  as modules (e.g. `Nebu.Matrix.Supervisor`), not as separate apps.

## Guidelines for Contributors and BMAD Agents

1. **No umbrella.** New domains are module namespaces under `lib/nebu/`, never a new
   OTP application.
2. **No new `mix.exs`.** There is exactly one `mix.exs` at the project root (`server/`).
3. **No new `Application` module.** There is exactly one `Nebu.Application` with one
   central supervisor tree.
4. **Child supervisors are allowed and encouraged.** `Nebu.Matrix.Supervisor` etc. as
   modules started by the root supervisor — idiomatic, not an umbrella.

## Related ADRs

- ADR-001 — Elixir/OTP.
- ADR-020 — Clustering Strategy & Module Architecture (extends this ADR with the
  clustering context and the Public-API rule).
- ADR-021 — Elixir Consolidation / Go Removal (this ADR defines the internal structure
  of the resulting Elixir application).
- ADR-018 — No Domain Model / Locality of Behavior (both principles target a flat,
  searchable structure).
