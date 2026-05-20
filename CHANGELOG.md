# Changelog

All notable changes to Nebu are documented in this file.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.0.0/)  
Versioning: [Semantic Versioning](https://semver.org/spec/v2.0.0.html)

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
