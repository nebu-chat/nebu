# ADR-020: Clustering Strategy & Module Architecture

## Status

Accepted - 2026-06-17

Extends: ADR-019 (the single-app decision stays valid; this ADR adds the clustering
context and the Public-API rule)

## Context

Nebu has horizontal scalability as an explicit non-functional requirement. At the same
time the architecture should stay as simple as possible — no premature complexity for
scaling tiers not yet reached.

Two decisions are coupled and therefore handled in one ADR:

1. **Module structure** — how are the three main domains (Matrix, Media, Admin)
   organized?
2. **Clustering** — how does Nebu scale horizontally when a single node is no longer
   enough?

## Decision

### Module structure: single app, domain namespaces

Nebu is one OTP application (ADR-019) with clearly separated module namespaces:

```
lib/nebu/
├── application.ex        ← central supervisor tree
├── repo.ex               ← Ecto (migrations + connection pool)
├── matrix/               ← Nebu.Matrix.*  — Matrix Client-Server API + chat logic
├── media/                ← Nebu.Media.*   — Media gateway
├── admin/                ← Nebu.Admin.*   — Admin UI (Phoenix LiveView)
├── web/                  ← Nebu.Web.*     — shared HTTP plumbing
└── compliance/           ← Nebu.Compliance.* — audit log (cross-cutting)
```

Each of the three feature domains has a **Public-API module** as the only allowed entry
point for other domains:

```elixir
# Only allowed call from Admin → Matrix
Nebu.Matrix.force_join(user_id, room_id)

# Never directly:
Nebu.Matrix.Membership.force_join(user_id, room_id)   # internal module
```

### Clustering: BEAM-native, three tiers

Scaling happens via BEAM clustering. No external message broker, no Redis pub/sub. OTP
primitives are the clustering infrastructure.

**Tier 1 — Single Node** (starting state)
- One Docker container, one BEAM node.
- Capacity: ~10,000–50,000 concurrent users depending on hardware.
- No clustering configuration active, but the code is clustering-ready.

**Tier 2 — BEAM Cluster** (horizontal scaling)
- 2–N identical nodes, all running the same OTP application.
- `libcluster` for automatic node discovery (Kubernetes, ECS, DNS).
- `Horde` for cluster-wide process registry and distributed supervisor.
- `pg` for pub/sub across node boundaries (built into OTP — no extra dependency).
- Load balancer with sticky sessions for `/sync` connections.
- Capacity: ~100,000+ concurrent users.

**Tier 3 — Dedicated Media Nodes** (only on a measurable I/O bottleneck)
- `Nebu.Media` is extracted into a separate OTP release.
- Dedicated nodes exclusively for media upload/download.
- Implemented only when measurements show media I/O is the actual bottleneck.
- Media is the only extraction candidate — Matrix and Admin always stay together.

## Rationale

### Why single app instead of umbrella

Umbrella organizes code, not deployments. All umbrella apps run in the same BEAM
process on the same node — an umbrella cannot be partially deployed without building
separate releases. For Tier 2 (identical nodes in a cluster) umbrella gives no
advantage. For Tier 3 (dedicated media nodes) you need a separate repository, not an
umbrella. Single app with module namespaces achieves the same organizational goal
without overhead.

### Why Public-API modules instead of free access

Without enforced compile boundaries (no umbrella), BMAD agents could accidentally call
internal modules of other domains. Public-API modules are a checkable convention:
Kassandra can flag any direct call into `Nebu.Matrix.*` (except `Nebu.Matrix` itself)
from another domain as a finding.

### Why BEAM clustering instead of an external broker

`pg` (built into OTP) transparently delivers pub/sub messages across node boundaries.
Redis as a pub/sub broker would be an external dependency doing the same job — with
extra ops effort, an extra failure source, and without the benefit of native BEAM
integration. Horde provides distributed process registry and supervision — also
without an external dependency.

### Why media is the only extraction candidate

Matrix-Core and Admin share OTP state intensively: room processes, session state,
membership checks. Splitting them would force message passing where direct function
calls suffice today. Media, by contrast, is functionally isolated — a media request
needs only a membership check (may this user see this medium?), solvable via a simple
DB query or a remote GenServer call. Media is the only candidate whose extraction does
not destabilize the rest.

## Clustering Implementation (Tier 2)

### libcluster — node discovery

Strategy is selected via the `CLUSTER_STRATEGY` env var: `gossip` (UDP multicast,
Docker Compose default), `kubernetes` (`Cluster.Strategy.Kubernetes.DNS`, Helm/K8s),
or unset (single-node, no libcluster). See `server/config/runtime.exs`.

### Horde — distributed process registry

```elixir
{Horde.Registry, name: Nebu.Matrix.Room.Registry, keys: :unique, members: :auto}
{Horde.DynamicSupervisor, name: Nebu.Matrix.Room.HordeSupervisor,
  strategy: :one_for_one, members: :auto}
```

`members: :auto` means Horde detects new cluster nodes automatically via `libcluster`.

### pg — pub/sub across node boundaries

```elixir
:pg.join(scope, {:room, room_id}, self())
:pg.get_members(scope, {:room, room_id}) |> Enum.each(&send(&1, {:matrix_event, event}))
```

No difference in code between single-node and cluster — `pg` abstracts the node
boundary completely.

### Sticky sessions for /sync

`/sync` is a long-poll connection. The load balancer must always route the same client
to the same node while the session is active. After a node failure Horde takes over the
room processes — the client reconnects and lands on another node.

## Rejected Alternatives

- **Umbrella with three apps** — rejected. No advantage over single app with namespaces
  for Tiers 1 and 2; for Tier 3 a separate repository is the right answer.
- **Redis as pub/sub broker** — rejected. `pg` is built into OTP, cluster-transparent,
  no external dependency. Redis was explicitly removed from the stack (ADR-002).
- **Kafka / NATS as event bus** — rejected. External brokers for a use case fully
  covered by OTP primitives.
- **Immediate extraction of Media as a separate service** — rejected. Premature
  optimization. Tier 3 is decided by measurement, not upfront.

## Consequences

### Positive

- Clustering-ready from the start without an architecture rebuild for Tier 2.
- No external message broker — less ops effort, fewer failure sources.
- Clear domain boundaries via Public-API modules without umbrella overhead.
- Media extraction is a defined, documented path for Tier 3.
- Node failure is tolerated — Horde migrates processes automatically.

### Negative / consciously accepted

- **Sticky sessions required** for `/sync`. Round-robin alone is insufficient.
- **Horde as a dependency** — an actively maintained Hex package, but external. A
  hand-rolled distributed registry would be significantly more work without payoff.
- **Media extraction requires later rework** — the membership check in Media becomes a
  remote call on extraction. Documented and known — no hidden risk.

## Related ADRs

- ADR-019 — Single OTP Application (this ADR extends it).
- ADR-021 — Elixir Consolidation / Go Removal — BEAM clustering is only possible because
  the whole stack is consolidated on Elixir/OTP.
- ADR-002 — No Redis / No NATS.
- ADR-004 — Horde Registry.
- ADR-018 — No Domain Model / Locality of Behavior — Public-API modules are compatible
  with No-Domain-Model since they are only function delegation, not an ORM.

## References

- [libcluster](https://github.com/bitwalker/libcluster)
- [Horde](https://github.com/derekkraan/horde)
- [pg](https://www.erlang.org/doc/man/pg.html)
