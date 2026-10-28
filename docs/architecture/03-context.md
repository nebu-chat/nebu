# 3 Context and Scope

## Business Context

Nebu is a self-hosted, Matrix-compatible enterprise chat server. It replaces Slack/Teams for
organizations requiring data sovereignty. The system boundary is a single Nebu instance (one
operator deploys it for their organization). No federation means no cross-instance communication
at the protocol level.

**External actors:**

| Actor | Interface | Protocol |
|---|---|---|
| Matrix clients (Element, FluffyChat, Cinny, …) | Matrix Client-Server API (incl. OAuth-aware `POST /logout` and the newly routed `POST /logout/all`) + OAuth 2.0 metadata/DCR. Story oauth-legacy-coexistence (ADR-033 C1-C20): `GET /login` advertises `oauth_aware_preferred` and `org.matrix.msc3824.delegated_oidc_compatibility` (both `true`, on the `m.login.sso` flow only) while, and only while, OAuth is offered (same predicate as `auth_metadata` answering 200); `GET /login/sso/redirect[/{idpId}]` honours the `action` query parameter (`login` / `register`, stable or `org.matrix.msc3824.action`; `register` becomes `prompt=create` towards the IdP when it supports it); `DELETE /devices/{id}` and `POST /delete_devices` answer `403 M_FORBIDDEN` to OAuth sessions (device deletion for OAuth sessions happens on the account page, see the end-user row below). Story oauth-account-management (ADR-033 A1-A27, A14): `POST /keys/device_signing/upload` answers an OAuth caller that REPLACES existing cross-signing keys with a `401` UIA challenge `flows: [{"stages": ["m.oauth"]}]` whose `params["m.oauth"].url` is `<issuer>/account?action=org.matrix.cross_signing_reset` (the user approves the pending request on the account page, the client retries with `auth: {"session": ...}`); legacy callers keep today's `403`; `auth_metadata` additionally carries `account_management_uri` and `account_management_actions_supported`. Legacy (IdP-JWT / opaque) and OAuth clients are served in parallel, each session only ever uses the API that issued it | HTTPS / WSS, TLS 1.3 |
| OIDC identity provider (Keycloak, Azure AD, Dex, Google) | OIDC Authorization Code + PKCE (identity auth only; also used for the account page sign-in and re-authentication through the same shared callback, `max_age=0`; `prompt=login`, or `prompt=create` for a client `action=register` when the IdP lists it in `prompt_values_supported`) | HTTPS |
| Third-party OAuth 2.0 clients (app registration) | Dynamic Client Registration endpoint; authorization endpoint `GET /oauth2/authorize` (browser redirect flow, Nebu delegates the login to the OIDC provider and returns a Nebu authorization code); token endpoint `POST /oauth2/token` (`authorization_code` + `refresh_token` grants, client auth `none`, Nebu-signed ES256 id_token); `GET /oauth2/jwks` (signing keys); `GET /.well-known/openid-configuration` (Nebu's own OIDC discovery document under the issuer, story oauth-token-endpoint). revocation endpoint `POST /oauth2/revoke` (RFC 7009, story oauth-token-revocation-logout: no client authentication, `200 {}` for any well-formed or unknown token, live even while `oauth_enabled=false`). Token, JWKS, openid-configuration and revoke answer CORS `*` without credentials | HTTPS |
| End users in a browser (account management page) | Story oauth-account-management (ADR-033 A1-A27): `GET /account` (every action, selected by `action` / `device_id`), `GET /account/reauth`, `POST /account/devices/delete`, `POST /account/cross_signing_reset/approve` and `.../decline`, `POST /account/logout`. Server-rendered HTML on the Nebu origin (standalone renderer, strict CSP, no script), live only under the same predicate as `auth_metadata` 200 (`404`/`503` page otherwise). The user signs in with the corporate IdP (shared callback, state tag `o2.acct.`, `prompt=login` + `max_age=0`) and gets a short-lived DB-backed browser session (hashed cookie, NOT a Matrix device); POSTs are CSRF-protected, destructive actions need a fresh IdP re-authentication. Actions: `org.matrix.profile` (read only), `org.matrix.devices_list`, `org.matrix.device_view`, `org.matrix.device_delete`, `org.matrix.cross_signing_reset`. No CORS. The reverse proxy must route `/account` and `/account/*` to the server (follow-up m) | HTTPS (browser navigation), session cookie |
| Operator (admin UI) | Admin web UI + Admin API + OAuth approvals | HTTPS, session cookie |
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
  │  OIDC Provider   │◄────────►│  │  Nebu.Admin  · Nebu.OAuth           │ │
  │  Keycloak / Dex  │  OIDC    │  │  Nebu.Web · Horde · ETS · pg groups │ │
  │  Azure AD        │          │  └───────┬────────────────────┬───────┘ │
                                │          │ PostgreSQL protocol  │ S3      │
  ┌──────────────────┐          │  ┌───────▼──────────┐  ┌────────▼──────┐ │
  │  Admin / Ops     │◄────────►│  │  PostgreSQL 16+  │  │  MinIO / S3   │ │
  │  Browser UI      │  HTTPS   │  │  event log ·     │  │  media blobs  │ │
  │  Prometheus      │  HTTP    │  │  oauth_* state · │  │  (encrypted)  │ │
  │                  │          │  │  audit · schema  │  │  (encrypted)  │ │
  └──────────────────┘          │  └──────────────────┘  └───────────────┘ │
                                │                                          │
  ┌──────────────────┐          │  OAuth 2.0 Authorization Server          │
  │  Third-party     │◄────────►│  (broker model, ADR-033)                 │
  │  OAuth Clients   │  HTTPS   │  RFC 8414, RFC 7591 DCR, authorize, token│
  │                  │          │  (ES256 id_token), JWKS, openid-config,  │
  │  (App Reg.)      │          │  revoke (RFC 7009), /account page        │
  └──────────────────┘          └──────────────────────────────────────────┘
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

> **Historical note (ADR-005 → ADR-021):** ADR-005 originally defined a gRPC streaming boundary
> between a stateless Go gateway and the Elixir server. The Go layer was removed (ADR-021,
> `full-elixir-stack` / `otp-consolidation` epics) and gRPC was fully removed in the `grpc-removal`
> epic (2026-06-22): `:grpc`/`:protobuf` deps deleted, no network listener on any port.
> The command/DTO layer survives in-process as `Nebu.Matrix.EventDispatcher.Server` (plain Elixir
> module) and `Core.*` (plain `defstruct` DTOs in `server/lib/pb/`), called directly by the HTTP
> routers. `Nebu.Matrix.Error` / `Nebu.Matrix.Status` replace the former `GRPC.RPCError` /
> `GRPC.Status`.

**Not in scope (explicit exclusions):**
- `/_matrix/federation/*` - no Server-Server API
- `/_matrix/identity/*` - no identity server
- `/_matrix/key/*` - no key server for federation
- E2EE key distribution (keys/upload acknowledged as stubs; no real E2EE in MVP)

_Source: `_bmad-output/planning-artifacts/architecture.md`, §Context, §Architektur-Grenzen; `README.md`, §Architecture_
