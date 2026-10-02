# Changelog

All notable changes to Nebu are documented in this file.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.0.0/)  
Versioning: [Semantic Versioning](https://semver.org/spec/v2.0.0.html)

---

## [Unreleased]

### Changed

- **SSO Redirect Schemes — bootstrap-only config**: `NEBU_SSO_REDIRECT_SCHEMES` environment variable has been removed. All SSO redirect scheme configuration is now bootstrap-only: configure additional trusted schemes via the Admin UI at `/admin/config` after bootstrap. The hardcoded default now correctly lists `element`, `schildichat`, and `im.fluffychat.auth` (previously included inaccurate scheme names `io.element.fluffychat` and bare `fluffychat`, which do not match any real Matrix client's registered URI scheme).
- **⚠ BREAKING (dev/local only) — dev Dex's issuer is now a public hostname**: the bundled development Dex instance (`dev/dex/config.yaml`) now advertises `http://dex.localtest.me:5556/dex` as its `issuer`, instead of the Docker-Compose-internal `http://dex:5556/dex`. This fixes the MSC2965 `auth_metadata` endpoint (and every other OIDC discovery field) advertising a hostname only reachable from inside the compose network — browsers and Matrix clients could never actually reach it. `dex.localtest.me` resolves to `127.0.0.1` via public DNS (the `*.localtest.me` wildcard convention), so no `/etc/hosts` edit is needed in the common case; see README.md / `docs/getting-started.md` for the DNS-rebind-protection fallback on networks where it is blocked.
  - **Impact for already-bootstrapped local/dev deployments using Dex:** the stored `server_config.oidc_issuer` still has the old `http://dex:5556/dex` value. After upgrading, Dex mints tokens with `iss = http://dex.localtest.me:5556/dex`, and the server's strict `iss` claim check (`Nebu.Web.Plugs.OidcPlug`) will reject every existing Bearer token and admin login with `bad_issuer`.
  - **Remediation:** per ADR-022 (OIDC is bootstrap-only — no env var to patch), there is no Admin-UI-driven fix for the stored issuer value today. Simplest fix: update the persisted row directly — `docker compose exec postgres psql -U nebu -d nebu -c "UPDATE server_config SET value = 'http://dex.localtest.me:5556/dex', set_at = (EXTRACT(EPOCH FROM NOW())*1000)::bigint WHERE key = 'oidc_issuer';"` — then restart the server (`make redeploy`). Alternatively, discard the local dev database entirely and re-run the Bootstrap Wizard from scratch (`make dev-reset-db`).
  - This only affects local/dev environments using the bundled Dex; it does not affect real IdPs (Keycloak, etc.), which already configure their own public-reachable issuer independently of this change.

---

## [0.2.1] – 2026-05-20

### Fixed

- **Stackit deployment — Matrix SSO redirect URI**: `ssoCallbackURL` now respects `NEBU_TRUSTED_PROXY=true` and trusts `X-Forwarded-Proto: https` from nginx, building `https://` redirect URIs instead of `http://` when behind a TLS-terminating reverse proxy. Refactored `isRequestSecure` into `internal/middleware` (shared with admin auth handler).
- **Stackit deployment — database migrations**: migration SQL (`000001_init.up.sql`) now grants `SELECT`, `INSERT`, `UPDATE`, `DELETE` on all application tables and sequences to `nebu_app` after creation. Required when running migrations as a dedicated `nebu_migrate` role (dual-role deployment). Function grants are scoped explicitly to avoid errors from extension-owned functions (`set_user`, `pg_stat_*`).
- **Stackit deployment — PostgresFlex ACL**: database ACL now includes the VM's floating IP (`stackit_public_ip.nebu.ip/32`) alongside the VPC CIDR. Docker container traffic reaches PostgresFlex via the public IP, not via internal Stackit routing.
- **Stackit deployment — runtime environment variables**: `NEBU_ENV`, `NEBU_KEY_ENCRYPTION_KEY`, and `NEBU_TRUSTED_PROXY` are now provisioned via `cloud-init` from Terraform variables (`nebu_env`, `key_encryption_key`). Previously required manual post-deploy configuration. `NEBU_TRUSTED_PROXY` is derived automatically from `enable_tls`.
- **Stackit deployment — Dex static users**: additional demo users (`alice@example.com`, `bob@example.com`, `compliance@example.com`) can now be provisioned via optional `dex_user1_password_hash`, `dex_user2_password_hash`, `dex_compliance_password_hash` Terraform variables. Users are gated behind `%{ if ... != null }` to keep existing deployments unchanged.
- **Secret scan**: `terraform.tfstate.*.backup` (numbered OpenTofu state backups) added to `.gitignore`; accidentally committed backup removed from tracking.

---

## [0.2.0] – 2026-05-20

### Added

- **Element Web integration** (Stackit deployment): optional `enable_element_web` Terraform variable deploys Element Web as a Docker service alongside Nebu. Includes nginx routing, CORS precondition enforcing `enable_tls`, and an `element_url` Terraform output.
- **Certbot-managed TLS** (Stackit): replaced ACME DNS-01 challenge with certbot HTTP-01 on the VM. Removes `vancluever/acme` and `hashicorp/tls` Terraform providers; auto-renewal via systemd timer baked into `cloud-init`.
- **Stackit Logs integration**: optional `enable_logs` / `logs_retention_days` Terraform variables ship `nebu.service` logs to Stackit Observability.
- **Stackit network resources**: dedicated Tofu-managed network, security groups, and ALB configuration extracted into separate `network.tf`, `alb.tf`, `dns.tf`, `database.tf`, and `logs.tf` modules.
- **PII encryption at rest** (`pii_encryption_key` variable): 64-character hex key validated at plan time; injected into the gateway via environment override in `cloud-init`.
- **`m.login.token` advertisement**: login flow now advertises `m.login.token` alongside `m.login.sso`, preventing redundant SSO re-initiation in Element Web 1.12+.

### Fixed

- **SSO URL fragment handling**: login tokens are now inserted before the URL fragment (`#`) in redirect URLs, fixing broken redirects in hash-based SPA routers (Element Web, Cinny).
- **Gateway migration squash** (story 13-14): consolidated 49 schema migrations into a single seed migration `000001_init.up.sql`, resolving role-dependency failures on Stackit PostgresFlex and other managed PostgreSQL services where `nebu_migrate` / `nebu` roles are provisioned outside of migrations.
- **Element Web nginx routing** (security): added `/api/v1/` gateway proxy block and WebSocket upgrade headers to the Element location block; previously, these API calls were silently unreachable from Element Web.
- **E2E bootstrap tests**: fixed `PROJECT_ROOT` path resolution (was 3 levels up — pointed to `e2e/` instead of project root, causing all database resets to silently fail); fixed `DEX_ISSUER_URL` undefined-at-module-load-time `ReferenceError` in step definitions.
- **WCAG AA contrast** (Admin UI): `primary-content` token `#fff7ed → #1c1917` (5.98:1 contrast ratio), `error-content` token `#450a0a → #000000` (5.9:1); removed duplicate `role=region` / `aria-label` landmark on the dashboard live-metrics div (WCAG SC 4.1.2).
- Removed redundant `--quiet` flag from Makefile E2E targets for consistent log output across CI and local runs.

### Changed

- Stackit PostgreSQL default CPU flavor updated to 2 cores in Terraform variable defaults.
- Docker Compose `healthcheck` for Element Web container uses `nginx:alpine`-bundled `wget` (no curl dependency).

---

## [0.1.0] – 2026-05-17

First official release of Nebu — enterprise Matrix chat server.

### Highlights

**Matrix Client-Server API** — login, logout, sync, send, createRoom, join, profile, presence, receipts, typing, media upload/download/thumbnails, push rules, devices, account_data, tags, public rooms, event context, notifications, moderation, room state, joined members, aliases, MSC2965 OIDC discovery endpoints.

**Core architecture** — stateless Go API Gateway + Elixir/OTP Core (Horde, libcluster, ETS) communicating via gRPC. PostgreSQL 16 as append-only event log. No Redis, no NATS, no Kafka.

**Authentication** — OIDC-only (Authorization Code + PKCE). MSC2965 `auth_issuer` / `auth_metadata` discovery. Dex sidecar mode for dev; Keycloak / Azure AD / Google Workspace compatible.

**Admin UI** — Bootstrap Wizard (first-run setup), dashboard with SSE live metrics, user management, room management, compliance access requests, audit log viewer, server configuration, role mapping, OIDC user directory search.

**OIDC user directory** — OIDC endpoint (Dex/Keycloak) for live user search + SCIM 2.0 RFC 7644 bulk import (Azure AD / Okta).

**Security** — Ed25519 message signatures and X25519 encryption key pairs per user; rate limiting (5 tiers); CSRF double-submit cookie; security headers (CSP, HSTS, X-Frame-Options); body size limits; Slowloris protection.

**Compliance** — Four-eyes approval for compliance access, signed JSON/PDF export, GDPR Article 17 right-to-erasure, audit log retention scheduler.

**Full-text search** — PostgreSQL `tsvector`-based message search.

**Media Gateway** — AES-256-GCM encrypted upload/download, MinIO S3-compatible backend.

**Deployment** — Kubernetes/Helm, AWS ECS Fargate, Stackit VM + Docker Compose. Let's Encrypt TLS via ACME DNS-01 for Stackit deployment.

**CI/CD** — GitHub Actions + GitLab CI dual-host pipeline. Secret scanning (gitleaks). SemVer release stage (Kaniko).

**License** — Apache 2.0.
