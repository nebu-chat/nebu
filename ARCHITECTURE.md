# Nebu — Architecture

This document describes Nebu's high-level architecture principles. It is the primary
reference for contributors and BMAD agents. The full rationale for each decision lives in
the ADRs under `docs/architecture/adr/`.

---

## Stack Overview

```
                    Load Balancer
                   /      |      \
         Node A (BEAM)  Node B  Node C        ← Tier 2: cluster (libcluster + Horde + pg)
              \           |       /
               BEAM Cluster
                         |
              Elixir/OTP — single application (:nebu)
        ┌──────────────┬──────────────┬─────────────┐
   Nebu.Matrix     Nebu.Media     Nebu.Admin     Nebu.Web
  (Plug+Bandit)   (Plug+Bandit)  (Phoenix LV)   (router/plugs)
        └──────────────┴──────────────┴─────────────┘
                         │
               ┌─────────┴─────────┐
          PostgreSQL           S3 / MinIO
```

Go is **not** part of the stack (ADR-021). Everything runs in one Elixir/OTP application.

---

## Principle 1: Single OTP Application with Module Namespaces

Nebu is **one OTP application** (`:nebu` / `Nebu.Application`) with clearly separated
feature domains as module namespaces. **No umbrella project** (ADR-019).

```
server/lib/
└── nebu/
    ├── application.ex        ← the one supervisor tree (Nebu.Supervisor)
    ├── stateful_supervisor.ex← isolates crash-prone Presence/Session/Horde rooms
    ├── repo.ex  release.ex   ← Ecto Repo (pool) + raw-SQL migration runner
    ├── matrix/               ← Nebu.Matrix.*  — Matrix Client-Server API + chat logic
    ├── media/                ← Nebu.Media.*   — media gateway
    ├── admin/                ← Nebu.Admin.*   — Admin UI (Phoenix LiveView)
    ├── web/                  ← Nebu.Web.*     — shared HTTP router + plugs
    ├── compliance/           ← Nebu.Compliance.* — audit log (cross-cutting)
    └── health/ … build_info.ex node_registration.ex  ← infra
```

### Public-API rule

Each feature domain has a **public-API module** (`Nebu.Matrix`, `Nebu.Media`,
`Nebu.Admin`). Other domains may call **only** that module — never internal submodules.

```elixir
# ✓ Allowed: a cross-domain call through the public API
Nebu.Matrix.force_join(user_id, room_id)

# ✗ Forbidden: reaching into another domain's internal module
Nebu.Matrix.Room.Membership.force_join(user_id, room_id)
```

Kassandra checks this rule in code review.

### Media as an extraction candidate

`Nebu.Media` is built so it can be extracted into a separate OTP release if measurements
ever show media I/O is the bottleneck (Tier 3). Matrix and Admin stay together. The
extraction is measurement-driven — not upfront. → ADR-020.

---

## Principle 2: Clustering-ready from the start

Nebu is clustering-ready from Tier 1. The code behaves identically on a single node and
in a cluster.

| Tier | Configuration | Capacity | Trigger |
|---|---|---|---|
| 1 | Single node | ~10k–50k concurrent users | starting state |
| 2 | BEAM cluster (N nodes) | ~100k+ | measurable CPU/RAM limit |
| 3 | Dedicated media nodes | unbounded media I/O | media is the measured bottleneck |

`libcluster` (node discovery), `Horde` (cluster-wide registry + distributed supervisor),
`pg` (cluster-transparent pub/sub, built into OTP). No Redis, no Kafka, no external
broker. → ADR-020.

---

## Principle 3: No Domain Model — Locality of Behavior

No ORM, no domain model, no repository pattern. REST requests translate directly to SQL,
inline in the handler. Migration files under `server/priv/migrations/*.up.sql` are the sole
canonical data model. SQL duplication is a deliberate property, not a refactoring target.
→ ADR-018.

---

## Principle 4: No Federation by Design

Nebu does not implement Matrix federation. The server talks only to clients, never to
other homeservers. A deliberate simplification for closed enterprise environments.

---

## Principle 5: Compliance-Native

- Audit log in PostgreSQL (`Nebu.Compliance`), with row-level security.
- No E2EE in the current version — messages are organizational property (ADR-011 roadmap).
- OIDC-first via Keycloak/Dex — no standalone password management.

---

## Database & HTTP layers

| Component | Use |
|---|---|
| `Ecto.Migration` (via `Nebu.Release`) | raw-SQL schema versioning, RLS |
| `Ecto.Repo` | connection-pool management only |
| `Postgrex` | direct SQL execution in handlers |
| `Ecto.Schema` / `Ecto.Query` | **not used** |
| Bandit + Plug | HTTP/1.1 + HTTP/2 server (Matrix API & media) |
| Phoenix LiveView | Admin UI only (no Phoenix for the Matrix API) |
| Assent + JOSE | OIDC token validation against the IdP |
| Finch | outbound HTTP (URL preview) |
| ExAws S3 | media storage (S3/MinIO) with streaming |

> A gRPC server module (`Nebu.Matrix.EventDispatcher.Server` + generated `Core.*` structs)
> remains as the in-process command/DTO layer the HTTP routers call. It is **not** an
> inter-process boundary anymore (ADR-021 / amended ADR-005); the network listener on port
> 9000 is a vestige slated for a future cleanup story.

---

## What BMAD agents must know

1. **No umbrella.** New domain = module under `lib/nebu/`, no new `mix.exs`, no new `Application`.
2. **Public-API rule.** Cross-domain calls only via `Nebu.Matrix`, `Nebu.Media`, `Nebu.Admin`.
3. **No ORM.** SQL inline in handlers. No `Ecto.Schema`.
4. **SQL duplication is not a finding.** Do not propose "extract to a repository."
5. **Migrations are the reference.** Read the relevant migration before implementing an endpoint.
6. **Cluster primitives.** Register processes via `Horde`; pub/sub via `pg`.
7. **One supervisor.** Add children to `Nebu.Application` (or a per-domain child supervisor) — never a new OTP application.

→ See `docs/architecture/adr/ADR-019`, `ADR-020`, `ADR-021`, `ADR-018`.
