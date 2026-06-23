# 3 Context and Scope

## Business Context

Nebu is a self-hosted, Matrix-compatible enterprise chat server. It replaces Slack/Teams for
organizations requiring data sovereignty. The system boundary is a single Nebu instance (one
operator deploys it for their organization). No federation means no cross-instance communication
at the protocol level.

**External actors:**

| Actor | Interface | Protocol |
|---|---|---|
| Matrix clients (Element, FluffyChat, Cinny, …) | Matrix Client-Server API | HTTPS / WSS, TLS 1.3 |
| OIDC identity provider (Keycloak, Azure AD, Dex, Google) | OIDC Authorization Code + PKCE | HTTPS |
| Operator (admin UI) | Admin web UI + Admin API | HTTPS, session cookie |
| Monitoring systems (Prometheus, Grafana) | `/metrics` endpoint | HTTP |
| Compliance officer | Admin UI + Compliance API | HTTPS, JWT + session |

## System Context Diagram

```
  ┌──────────────────┐          ┌──────────────────────────────────────────┐
  │  Matrix Clients  │◄────────►│           Nebu Instance                  │
  │  Element, Cinny  │  HTTPS   │                                          │
  │  FluffyChat, …   │  TLS 1.3 │  ┌────────────────────────────────────┐ │
  └──────────────────┘          │  │  Elixir/OTP application (:nebu)     │ │
                                │  │  Bandit/Plug HTTP · Phoenix LiveView│ │
  ┌──────────────────┐          │  │  Nebu.Matrix · Nebu.Media           │ │
  │  OIDC Provider   │◄────────►│  │  Nebu.Admin  · Nebu.Web             │ │
  │  Keycloak / Dex  │  OIDC    │  │  Horde · ETS · pg groups            │ │
  │  Azure AD        │          │  └───────┬────────────────────┬───────┘ │
                                │          │ PostgreSQL protocol  │ S3      │
  ┌──────────────────┐          │  ┌───────▼──────────┐  ┌────────▼──────┐ │
  │  Admin / Ops     │◄────────►│  │  PostgreSQL 16+  │  │  MinIO / S3   │ │
  │  Browser UI      │  HTTPS   │  │  event log ·     │  │  media blobs  │ │
  │  Prometheus      │  HTTP    │  │  audit · schema  │  │  (encrypted)  │ │
  └──────────────────┘          │  └──────────────────┘  └───────────────┘ │
                                └──────────────────────────────────────────┘
```

The whole HTTP surface (Matrix C-S API, media, Admin UI) and all stateful chat logic run
**in-process** within the single Elixir/OTP application — there is no separate gateway process and
no inter-process boundary. The domain namespaces (`Nebu.Matrix`, `Nebu.Media`, `Nebu.Admin`,
`Nebu.Web`) call each other as plain function calls on one BEAM node.

## Technical Context

**Internal communication boundaries:**

| Boundary | Protocol | Direction |
|---|---|---|
| HTTP layer (`Nebu.Web`/`Nebu.Matrix.Http*`) → domain (`Nebu.Matrix`/`Nebu.Media`/`Nebu.Admin`) | In-process function calls (one BEAM node) | Synchronous; no network hop |
| Elixir app → PostgreSQL | PostgreSQL wire protocol (TLS) via `Nebu.Repo` (Ecto pool) | Read/Write for all business logic, sessions, media keys, migrations |
| `Nebu.Media` → MinIO / S3 | S3 API (ExAws/Finch, TLS) | Media blob storage (encrypted at rest) |

> **Historical note:** ADR-005 originally defined a gRPC streaming boundary between a stateless Go
> gateway and the Elixir server. The Go layer was removed (ADR-021) and consolidated into the single
> Elixir/OTP application; the former gRPC command/DTO layer survives only as an in-process module
> (`Nebu.Matrix.EventDispatcher.Server` + generated `Core.*` structs) that the HTTP routers call
> directly. A network gRPC listener on port 9000 still starts but nothing dials it (vestige).

**Not in scope (explicit exclusions):**
- `/_matrix/federation/*` - no Server-Server API
- `/_matrix/identity/*` - no identity server
- `/_matrix/key/*` - no key server for federation
- E2EE key distribution (keys/upload acknowledged as stubs; no real E2EE in MVP)

_Source: `_bmad-output/planning-artifacts/architecture.md`, §Context, §Architektur-Grenzen; `README.md`, §Architecture_
