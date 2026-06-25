# 4 Solution Strategy

## Core Architectural Decisions

### Technology Choices

| Goal | Technology Choice | Rationale |
|---|---|---|
| Single application runtime (HTTP + stateful chat logic) | Elixir/OTP 1.19 (Erlang/OTP 27) | OTP Supervisor trees, Horde CRDT clustering, ETS in-memory state; one BEAM node serves everything |
| HTTP surface (Matrix C-S API + media) | Bandit + Plug | Pure-Elixir HTTP server; in-process dispatch to domain functions |
| Admin UI | Phoenix HTTP controllers + Phoenix LiveView (Dashboard, AuditLog, Bootstrap) | Server-rendered admin pages on the same Bandit listener; CRUD pages use PRG HTTP controllers, real-time pages remain LiveViews |
| Reliable event log + schema authority | PostgreSQL 16 | Append-only event log, raw-SQL migrations via `Nebu.Release.migrate/0` (ADR-018), RLS policies |
| No Redis | ETS (Elixir built-in) | Session state, since-token cursors - eliminates a stateful dependency |
| No NATS/Kafka | pg Process Groups (Elixir built-in) | Pub/sub fanout - eliminates an external broker |
| Auth | OIDC-only (Authorization Code + PKCE), Assent/JOSE | No local accounts, no password hashing; IdP owns identity lifecycle |

### Key Architectural Patterns

**1. Single Elixir/OTP application, in-process domains (ADR-019/020/021)**

Nebu is one Mix app (`:nebu`, `Nebu.Application`, one supervisor tree). The HTTP surface and all
stateful chat logic live in the same BEAM node, split into module namespaces: `Nebu.Matrix.*`
(Matrix C-S API + rooms via Horde, sessions via ETS + PostgreSQL, presence, permissions, Ed25519
signing, event dispatch, sync, and the `Nebu.Matrix.Http*` surface), `Nebu.Media.*` (upload/
download/crypto/storage against S3/MinIO), `Nebu.Admin.*` (Phoenix HTTP controller + LiveView Admin UI + admin OIDC
login), `Nebu.Web.*` (shared HTTP plumbing: the single Bandit listener's router + plugs, JWKS cache,
token denylist), and `Nebu.Compliance.*` (audit log). The HTTP layer calls domain functions
directly — there is no inter-process hop. PostgreSQL is append-only for events and audit logs.

**2. In-process command/DTO layer (amended ADR-005)**

ADR-005 originally chose a gRPC server-streaming EventBus + unary fallback for a gateway↔core
network boundary. With the Go gateway removed, that boundary no longer exists: the HTTP routers
call the domain functions in-process. A gRPC server module
(`Nebu.Matrix.EventDispatcher.Server`) plus the generated `Core.*` protobuf structs survive as the
in-process command/DTO layer the routers invoke directly. A gRPC network listener on port 9000
still starts but nothing dials it (vestige, slated for a future cleanup).

**3. Content-Hash Event IDs (Matrix Room Version 6+)**

Event IDs are computed as `$<base64url(SHA-256(canonical_json(event)))>` - tamper-evident,
federation-compatible, reproducible at recovery. No UUID generation.

**4. Raw-SQL migrations applied by the release (ADR-018)**

There is no ORM and no golang-migrate. Migrations are raw SQL applied by `Nebu.Release.migrate/0`
before the application boots; the migration SQL is the only canonical data model.

**5. Server-side session and media key escrow**

Matrix sessions are opaque tokens stored server-side (decoupled from OIDC token lifetime); media
objects are AES-256-GCM encrypted at rest with per-object keys stored in PostgreSQL (managed E2EE
key escrow, ADR-011).

**6. BEAM-native clustering**

Horizontal scaling uses libcluster + Horde + `pg` Process Groups — no Redis, no NATS, no Kafka.
Room GenServers migrate across nodes via the Horde CRDT registry; node registration uses a
pre-shared secret (`Nebu.NodeRegistration`).

**7. Locality of Behavior — No Domain Model, No ORM (ADR-018)**

SQL is written inline in each endpoint/controller implementation file. No `Ecto.Schema`, no Repository
pattern, no Service layer (`Nebu.Repo` is the Ecto connection pool only). The raw-SQL migrations are
the sole canonical data model. This keeps every endpoint fully self-contained: handler, auth check,
SQL, and response shape are all visible in one file — optimized for LLM-assisted development (BMAD
methodology) where minimizing context-graph depth reduces hallucination risk and speeds review.
SQL duplication across files is a deliberate property of this strategy, not technical debt.

_Source: `_bmad-output/planning-artifacts/architecture.md`, §Core Architectural Decisions, §Implementation Patterns & Consistency Rules; ADR-018, ADR-019, ADR-020, ADR-021_
