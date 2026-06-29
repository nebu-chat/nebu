# ADR-022: OIDC Configuration from Bootstrap Wizard Only (No Environment Variables)

## Status

Accepted - 2026-06-28

Builds on: ADR-015 (OIDC User Directory Integration), ADR-018 (migrations/DB as the
canonical data model). Relates to: ADR-020 (cluster-aware config propagation).

## Context

OIDC is Nebu's only authentication mechanism — it secures both the **Matrix
Client-Server API** (Bearer-token validation in `Nebu.Web.OidcPlug`) and the **Admin UI**
(operator login via the Authorization Code + PKCE flow). Historically Nebu configured OIDC
through **two parallel, overlapping mechanisms**:

1. **Environment variables** read at boot in `config/runtime.exs`:
   `NEBU_OIDC_ISSUER`, `NEBU_OIDC_AUDIENCE`, `NEBU_OIDC_JWKS_URI`, `NEBU_OIDC_CLIENT_ID`,
   `NEBU_OIDC_CLIENT_SECRET`, `NEBU_OIDC_EXTRA_SCOPES`, plus a **separate admin client**:
   `NEBU_ADMIN_OIDC_CLIENT_ID`, `NEBU_ADMIN_OIDC_CLIENT_SECRET`,
   `NEBU_ADMIN_OIDC_REDIRECT_URI`, `NEBU_ADMIN_OIDC_SCOPE`.
2. **The Bootstrap Wizard** — the first-run operator flow that writes OIDC config into the
   `server_config` table, read at runtime through the DB-backed cache
   (`Nebu.Web.OidcConfig` ETS cache + `Nebu.Web.JwksCache` DB-fallback), refreshed
   atomically on bootstrap completion and propagated across the cluster via `pg`.

Every consumer therefore resolved config with an **env-first, DB-fallback** precedence
(`OidcPlug.oidc_issuer/0`, `JwksCache.http_fetch/0`, `SsoLogin.resolve_client_credentials/0`,
`Admin.Auth.oidc_config/1`). This dual path carried significant, recurring cost:

- **Test-variance explosion.** When OIDC env vars were set (exactly how `make dev` and the
  E2E stack ran), the wizard rendered its OIDC fields **disabled + pre-filled**
  (`bootstrap_live.ex` `disabled={env_oidc_issuer() != nil}`), creating an
  *env-locked-fields* mode distinct from the editable mode. This produced an entire family
  of conditionally-skipped E2E scenarios (`bootstrap-env-locked-fields.feature`) that only
  ran under one env matrix and skipped under the other — the single largest source of
  by-design test skips in the suite.
- **A whole class of integration bugs.** Two clients with different redirect URIs
  (`nebu-gateway` for Matrix SSO, `nebu-admin` for `/admin/callback`) plus an env-vs-draft
  precedence created the *bootstrap operator-login used the wrong client* bug
  (`Unregistered redirect_uri`), the profile-scope bug, and the env-fallback complexity in
  the wizard's form handling.
- **Two sources of truth.** The same value (e.g. the issuer) could be set in env *and* in
  `server_config`, with non-obvious precedence — hard to reason about, hard to test, and a
  trap during deployment.

The DB-backed path is already complete and battle-tested: `server_config` storage, the
`OidcConfig`/`JwksCache` caches, atomic refresh on bootstrap completion, and `pg`-based
cluster invalidation all exist and ship today. The env path is the redundant half.

## Decision

**OIDC is configured exclusively through the Bootstrap Wizard, persisted in
`server_config`. The environment-variable configuration path is removed.** There are no
`NEBU_OIDC_*` or `NEBU_ADMIN_OIDC_*` configuration variables.

**A single OIDC client** serves both surfaces. The wizard configures one client
(`issuer`, `client_id`, `client_secret`, `audience`, `jwks_uri`, claim mappings, refresh
mode); the same client validates Matrix Bearer tokens **and** authenticates the admin
operator login. The IdP-side client registers all Nebu redirect URIs (Matrix SSO redirect,
Element auth callback, and `/admin/callback`). The separate admin OIDC client is removed.

Specifically:

1. **Runtime config** (`config/runtime.exs`): remove all `NEBU_OIDC_*` / `NEBU_ADMIN_OIDC_*`
   reads. OIDC config is never sourced from the environment.
2. **Consumers read DB only.** `OidcPlug.oidc_issuer/0` + `oidc_audience/0`,
   `JwksCache` URI/issuer resolution, `SsoLogin` client-credential resolution, and
   `Admin.Auth.oidc_config/1` resolve solely from the `server_config`-backed
   `OidcConfig`/`JwksCache` caches (and bootstrap draft during the bootstrap flow). The
   env-first branches are deleted.
3. **Wizard fields are always editable + required.** The `env_oidc_*` helpers and the
   `disabled={...}` env-lock rendering in `bootstrap_live.ex` are removed; `audience` and
   `jwks_uri` are unconditionally required (no env fallback).
4. **Fail-closed until bootstrapped** (unchanged, now the only behavior). Before bootstrap,
   `server_config` has no OIDC keys, the caches hold `nil`, and `OidcPlug` rejects every
   Bearer token (`401 M_UNKNOWN_TOKEN`) while the admin UI redirects to `/bootstrap`. The
   server still **boots** without OIDC config — config is validated per-operation, not at
   boot.
5. **Single client.** Drop the `admin_oidc_*` Application keys and the second Dex client;
   dev `dev/dex/config.yaml` collapses `nebu-gateway` + `nebu-admin` into one client with
   all redirect URIs registered. The bootstrap-mode operator login uses the
   wizard-configured (draft) client directly — eliminating the env-vs-draft client
   mismatch that caused the `Unregistered redirect_uri` bug class.

### Explicit non-goal (future direction)

A **headless access-token concept** — letting both the admin API and the Matrix API be
driven without an interactive browser OIDC flow (for automation / headless operators) — is
a recognized future direction but is **out of scope here**. Likewise, **bootstrap-via-API**
is *not* required: first-run configuration is the interactive wizard only. This ADR is
written so the bootstrap-only design does not preclude a later access-token epic
(access tokens would be an *additional* credential path layered on top of the
DB-configured OIDC client, not a reintroduction of env-based OIDC config).

## Consequences

### Positive

- **One source of truth, one config path.** OIDC config lives only in `server_config`,
  set through one flow. No precedence rules, no env-vs-DB ambiguity.
- **Test-variance collapses.** The env-locked-fields mode disappears entirely; the wizard
  has exactly one rendering (editable). The `bootstrap-env-locked-fields.feature`
  scenarios and the env-conditional skips they caused are removed, not worked around.
- **A class of bugs is eliminated by construction** — wrong-client redirect, env-fallback
  form edge cases, and dual-source drift can no longer occur.
- **Simpler deployment story.** Operators do not template OIDC secrets into env/Helm;
  they run the wizard once. Fewer secrets in the deployment surface.
- **Single client** means one set of redirect URIs and one secret to manage.

### Negative / accepted trade-offs

- **No separate admin/Matrix client isolation.** A single client cannot give the admin UI
  and the Matrix gateway distinct secrets or audiences (least-privilege separation). For a
  self-hosted, single-organization product this is an acceptable simplification; a future
  ADR may reintroduce an *optional* second client (configured via the wizard, never env) if
  a deployment needs credential isolation.
- **No env-based override for ops.** Post-bootstrap OIDC changes require re-running the
  relevant wizard step (or an admin settings flow), not an env edit + restart. This is the
  intended trade — config changes are auditable DB writes, not ambient process state.
- **Migration for existing env-configured deployments.** Any deployment currently relying
  on `NEBU_OIDC_*` must complete the bootstrap wizard (or seed `server_config`) once. Since
  Nebu has no official deployments yet (ADR-012), the practical blast radius is the dev/CI
  stack and reference docs.

### Security notes (reviewed at SEC Gate)

- Fail-closed remains the default: missing config → all tokens rejected. No path weakens
  this.
- The client secret continues to be stored encrypted at rest (AES-256-GCM) in the draft
  and `server_config`; removing env does not move secrets to plaintext.
- Collapsing to one client widens that client's redirect-URI allowlist; the IdP must still
  exact-match registered redirect URIs, and Nebu continues to validate `state`/PKCE/nonce.

## Implementation

Mechanical removal, not new infrastructure — the DB path already exists. Touch points:
`config/runtime.exs`, `web/plugs/oidc_plug.ex`, `web/jwks_cache.ex`, `matrix/sso_login.ex`,
`admin/auth.ex`, `admin/bootstrap_live.ex`, `docker-compose.yml`, `dev/dex/config.yaml`,
plus docs (`CLAUDE.md` — "validated at boot" → "set via bootstrap, validated
per-operation, fail-closed until bootstrapped") and the env-coupled tests
(`bootstrap-env-locked-fields.feature` removed; `oidc_optional_env_test.exs` /
`bootstrap_live_test.exs` updated). Delivered via `/nebu-pipeline` with ATDD + Kassandra
SEC Gate (touches `web/` auth + `:crypto` + admin).

## Related ADRs

- ADR-015 — OIDC User Directory Integration (the OIDC protocols Nebu speaks).
- ADR-018 — No Domain Model; migrations / `server_config` as canonical data model.
- ADR-020 — Clustering & Module Architecture (the `pg`-based `OidcConfig` cache invalidation).
- ADR-012 — Reference implementation only, no official deployments (bounds the migration impact).
