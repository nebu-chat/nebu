---
story_id: oidc-bootstrap-only-config
title: "OIDC bootstrap-only config: remove all NEBU_OIDC_*/NEBU_ADMIN_OIDC_* env vars, single client (ADR-022)"
type: refactor
severity: high
epic: oidc-bootstrap-only
status: done
security_review: required
created: 2026-06-28
branch: feature/device-management
---

## Summary

Implement **ADR-022**: OIDC is configured **exclusively through the Bootstrap Wizard**
(persisted in `server_config`, read via the existing DB-backed `Nebu.Web.OidcConfig` ETS
cache + `Nebu.Web.JwksCache` DB-fallback). **Remove the environment-variable OIDC config
path entirely** — no `NEBU_OIDC_*` and no `NEBU_ADMIN_OIDC_*` configuration. Collapse to a
**single OIDC client** that serves both Matrix Bearer-token validation and admin operator
login.

This is a **mechanical removal**, not new infrastructure: the DB path already exists and
ships today (server_config storage, OidcConfig/JwksCache caches, atomic cache refresh on
bootstrap completion, `pg` cluster invalidation). The work is deleting the env-first
branches in the consumers and the env-lock UI in the wizard, then collapsing the second
(admin) client.

Read `docs/architecture/adr/ADR-022-oidc-bootstrap-only-configuration.md` first — it is the
binding decision record.

## Motivation

The env-first + DB-fallback dual path was the single largest source of E2E test variance
(the env-locked-fields wizard mode → conditionally-skipped scenarios) and a recurring
bug class (wrong-client redirect, env-fallback form edge cases, dual-source drift). One
config path = one tested path.

## Non-Goals (explicit, per ADR-022)

- **No headless access_token concept** (future epic). Do not add any token-minting path.
- **No bootstrap-via-API.** First-run config is the interactive wizard only.
- **No second/admin client.** Single client only (a future optional second client is a
  separate ADR if ever needed).

## Acceptance Criteria

**AC1 — runtime.exs env reads removed:** `server/config/runtime.exs` no longer reads any
`NEBU_OIDC_*` or `NEBU_ADMIN_OIDC_*` variable. The corresponding Application env keys
(`:oidc_issuer`, `:oidc_audience`, `:oidc_jwks_uri`, `:matrix_oidc_client_id/secret`,
`:oidc_extra_scopes`, `:admin_oidc_client_id/secret/redirect_uri/scope`) are removed or no
longer populated from env. (`NEBU_OIDC_JWKS_TTL` for cache TTL and
`NEBU_INTERNAL_SECRET*`/`NEBU_PII_ENCRYPTION_KEY` are NOT OIDC config and stay.)

**AC2 — OidcPlug reads DB only:** `OidcPlug.oidc_issuer/0` and `oidc_audience/0` resolve
solely from `Nebu.Web.OidcConfig.get()` (no `Application.get_env(:nebu_http, :oidc_issuer)`
branch). Fail-closed unchanged: when `server_config` has no issuer/audience, every Bearer
token is rejected `401 M_UNKNOWN_TOKEN`.

**AC3 — JwksCache reads DB only:** `JwksCache` resolves the JWKS URI and issuer (for
discovery) solely from `OidcConfig` (no env branch). Empty config → empty key set →
fail-closed at OidcPlug.

**AC4 — SsoLogin reads DB only, single client:** `SsoLogin` resolves issuer and client
credentials solely from `server_config` (the bootstrap client). The env (`:matrix_oidc_*`)
and admin-client fallbacks are removed. Matrix SSO mints tokens with the single client.

**AC5 — Admin.Auth reads DB only, single client:** `Admin.Auth.oidc_config/1` resolves
issuer + client_id + client_secret solely from `server_config` (normal mode) / the draft
(bootstrap mode); no env fallback. `bootstrap_operator_client/1` uses the
wizard-configured (draft) client directly — the admin-client env branch is removed. The
`/admin/callback` redirect_uri is registered on the single client.

**AC6 — Wizard fields always editable + required:** In `bootstrap_live.ex`, the
`env_oidc_issuer/0`, `env_oidc_audience/0`, `env_oidc_client_id/0`, `env_oidc_jwks_uri/0`
helpers and the `disabled={env_oidc_* != nil}` rendering + `(set via env)` indicators are
removed. `oidc_issuer`, `oidc_client_id`, `oidc_client_secret`, `oidc_audience`,
`oidc_jwks_uri` are always editable and **required** (no `env_fallback`).

**AC7 — Dev stack single client + no OIDC env:** `dev/dex/config.yaml` has ONE client
(keep id `nebu-gateway`) registering all three redirect URIs (Matrix SSO redirect, Element
`auth.html`, `/admin/callback`); the `nebu-admin` client is removed. `docker-compose.yml`
`server` service drops every `NEBU_OIDC_*` and `NEBU_ADMIN_OIDC_*` variable.
(`NEBU_OIDC_JWKS_TTL` may stay as a cache-tuning knob, NOT as OIDC config — confirm it is
not an issuer/audience/client value.)

**AC8 — Fail-closed before bootstrap (regression):** On a fresh DB with no bootstrap and
**no OIDC env**, the server boots cleanly; a Matrix Bearer request → `401`; the admin UI
redirects to `/bootstrap`. (Proves the server does not require OIDC config at boot.)

**AC9 — Works after bootstrap via single client:** After the wizard completes, Matrix
Bearer tokens validate (issuer/audience/jwks from server_config) and admin operator login
succeeds — both against the one client. (ExUnit integration proves the resolution paths;
full-browser E2E is verified centrally by the human operator, not in this pipeline.)

**AC10 — Docs updated:** `CLAUDE.md` env-var section no longer lists `NEBU_OIDC_*` as
config and the OIDC line changes from "validated at boot" to "set via the bootstrap wizard
(`server_config`), validated per-operation, fail-closed until bootstrapped"; reference
ADR-022. Any `deploy/helm` / compose docs that template OIDC env are updated to say
"configure via bootstrap wizard".

**AC11 — Env-coupled tests removed/updated:** Delete `bootstrap-env-locked-fields.feature`
+ its step definitions (the env-lock mode no longer exists). Update or remove
`oidc_optional_env_test.exs` and the env-lock assertions in `bootstrap_live_test.exs` so
the suite reflects the single editable mode. No test may set `NEBU_OIDC_*` to drive
behavior.

## Persistence Strategy

**Option B — PostgreSQL (already in place).** OIDC config lives in `server_config`; the
`OidcConfig` (issuer/audience/jwks_uri) and `JwksCache` (keys) ETS caches are warmed at
boot from the DB, refreshed atomically on bootstrap completion, and invalidated across the
cluster via `pg` (ADR-020). No new GenServer state is introduced.

**Crash/restart:** `OidcConfig.init/1` and `JwksCache.init/1` re-read from `server_config`
on start, so a node restart (or Horde migration) recovers config from the DB. Keep/extend
the existing tests proving a fresh boot against a bootstrapped DB warms issuer/audience/keys
(no env needed).

## Acceptance Tests

### Tests written FIRST (before implementation code):

1. **OidcPlug fail-closed with empty server_config (no env)** — ExUnit (`Plug.Test` + the
   `:oidc_config_source` seam returning `%{issuer: nil, audience: nil}`)
   - Given: no OIDC config in server_config, no env
   - When: Bearer request hits a protected route
   - Then: `401` (`issuer_not_configured` / `audience_not_configured` path)

2. **OidcPlug accepts when server_config provides issuer/audience** — ExUnit
   - Given: `:oidc_config_source` seam returns a configured issuer+audience, valid JWK in
     `:oidc_jwks`
   - When: a token with matching `iss`/`aud` arrives
   - Then: `:ok`, `current_user` assigned — proving DB-only resolution

3. **OidcPlug ignores env (regression for removal)** — ExUnit
   - Given: `:oidc_issuer` Application env is set to a bogus value BUT the
     `:oidc_config_source` seam returns the real issuer
   - When: token with the real (DB) issuer arrives
   - Then: `:ok` — proving env is no longer consulted (this test fails RED before the env
     branch is removed, green after)

4. **SsoLogin resolves client + issuer from server_config only** — ExUnit
   (`:sso_bootstrap_reader` seam)
   - Given: server_config has oidc_client_id/secret/issuer, env has none
   - Then: `oidc_config`/`resolve_client_credentials` return the DB values; with env set to
     a different value, the DB value still wins (env ignored)

5. **Admin.Auth.oidc_config resolves from server_config only** — ExUnit
   (`:admin_oidc_config_reader` seam)
   - Given: server_config has the client, no admin env
   - Then: returns `{:ok, %{client_id, client_secret, issuer, scope}}`; bootstrap mode uses
     the draft client

6. **Bootstrap wizard renders all OIDC fields editable + required** — ExUnit LiveView test
   (or step) — no `disabled` attribute on issuer/client_id/audience/jwks; submitting an
   empty audience or jwks_uri is rejected as required

7. **Server boots with zero OIDC env + empty server_config** — ExUnit
   - Given: no OIDC Application env, no server_config OIDC keys
   - Then: OidcConfig/JwksCache start, caches hold nil, no crash (fail-closed at request
     time, not boot time)

## Implementation Notes (non-binding map — from the ADR-022 blast-radius analysis)

- `config/runtime.exs:~35-65` (Matrix OIDC) + `:~176-190` (admin OIDC) — delete env reads.
- `web/plugs/oidc_plug.ex:~467-479` — `oidc_issuer/0`/`oidc_audience/0` → `OidcConfig.get()` only.
- `web/jwks_cache.ex:~163-209` — drop env in `http_fetch`/`discover_jwks_uri_and_fetch`.
- `matrix/sso_login.ex:~354-400` — `oidc_config/0` + `resolve_client_credentials/0` DB-only,
  single client.
- `admin/auth.ex:~777-860` — `oidc_config/1` + `bootstrap_operator_client/1` DB/draft-only.
- `admin/bootstrap_live.ex:~123-182, ~357-381, ~462-541` — remove env helpers + disabled
  rendering; fields always required.
- `dev/dex/config.yaml` — single `nebu-gateway` client, 3 redirect URIs; remove `nebu-admin`.
- `docker-compose.yml` server env — remove NEBU_OIDC_*/NEBU_ADMIN_OIDC_*.
- Keep the cache-refresh-on-bootstrap hook (`auth.ex do_complete_bootstrap ~1234-1326`) intact.

## Security Review Scope (Kassandra — required)

Touches `web/` auth plumbing, `:crypto` (token verification, secret decryption), admin
auth, and OIDC validation. Verify: **fail-closed preserved** (no path lets an unconfigured
or misconfigured server accept tokens); issuer/audience/alg/exp/nonce/PKCE checks unchanged;
client secret stays encrypted at rest (no plaintext in logs); the single client's widened
redirect-URI allowlist is still exact-matched by the IdP and Nebu still validates
state/PKCE/nonce; no env-removal introduces a default-open fallback.
