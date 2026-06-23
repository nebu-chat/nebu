# 2 Architecture Constraints

## Technical Constraints

| Constraint | Rationale |
|---|---|
| Two runtime components only: Elixir release, PostgreSQL (plus MinIO for media + an OIDC provider) | One single Elixir/OTP application (ADR-019/020/021); eliminates Redis, NATS, Kafka and the former Go layer; reduces ops surface |
| OIDC-only authentication | No local auth path, no password hashing, no brute-force guards at app level - IdP owns identity |
| Docker Compose as sole supported deployment target | Kubernetes is possible but unsupported; reduces target complexity for primary audience |
| Matrix Client-Server API compatibility | Incompatibilities with Element/FluffyChat are treated as bugs (NFR-M1, NFR-M2) |
| Apache 2.0 license for all dependencies | No AGPLv3, BSL, or SSPL dependencies permitted |
| TLS 1.3 on all external connections | Mandatory for client↔server; optional but recommended internally |
| Migrations are raw SQL run by the Elixir release | `Nebu.Release.migrate/0` applies raw-SQL migrations before the app boots (ADR-018); migration SQL is the only canonical data model — no ORM, no golang-migrate |
| ETS replaces Redis | Session state, since-token cursors, and presence state in ETS (in-memory) with PostgreSQL checkpoint |
| pg Process Groups replace NATS/Kafka | Pub/sub fanout via Elixir pg groups; no external message broker |
| No federation (MVP) | Matrix Server-Server API is explicitly excluded; ~40% complexity reduction; architecturally prepared for Phase 3 |

## Organizational Constraints

| Constraint | Rationale |
|---|---|
| Agent-driven development (BMAD Method) | All stories pass through SM → ATDD → Dev → Test Review → Code Review → Security Review gates |
| Open-source quality standard | Code must withstand external review; no insider-only patterns |
| Changelog required at every release | Documented migration path for operators; backward-compat minor updates |

## Component Version Pins

| Component | Version | Notes |
|---|---|---|
| Elixir | 1.19 | `elixir:1.19-alpine` base image; single Mix app `:nebu` |
| Erlang/OTP | 27 | Bundled with Elixir 1.19; native Ed25519/X25519 via `:crypto` |
| Bandit + Plug | current | HTTP server for Matrix C-S API and media |
| Phoenix LiveView | 1.8 / 1.2 | Admin UI (`Nebu.Admin.*`) |
| Alpine | 3.23 | Builder and runtime must match to avoid OpenSSL crashes |
| PostgreSQL | 16 | `postgres:16-alpine` |

_Source: `_bmad-output/planning-artifacts/architecture.md`, §Technical Constraints & Dependencies, §Pinned Versions_
