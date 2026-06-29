# 7 Deployment View

## Docker Compose Stack (Development + Production)

All builds run via Docker containers - no local Elixir or build-tool installation required.

```yaml
# Simplified docker-compose.yml topology
services:
  server:         # The single Elixir/OTP release (port 4000: health + Matrix C-S API incl.
                  #   /_matrix/media/v3/* + Admin UI /admin/*). This is the whole application.
  postgres:       # PostgreSQL 16 (port 5432)
  dex:            # OIDC provider for development (port 5556)
  minio:          # MinIO S3-compatible object store (port 9000: API; port 9001: console) - Story 12.1
  createbuckets:  # Init container: creates nebu-media bucket + nebu-app IAM user+policy - Story 12.1/12.3
  # gateway:      # REMOVED (ADR-021): the Go gateway is gone — the Elixir server IS the application.
  # media:        # REMOVED (ADR-021): the Go media gateway is gone — the server serves media in-process.
```

**One container, all surfaces (ADR-019/020/021):** There is no Go container. The single Elixir `server`
service serves the Matrix C-S API, the Matrix media API (`/_matrix/media/v3/*` and
`/_matrix/client/v1/media/*`), and the Admin UI (`/admin/*`) on the same Bandit port
4000. The Admin UI uses Phoenix HTTP controllers (PRG pattern) for CRUD pages and Phoenix LiveView for
real-time pages (Dashboard, AuditLog, Bootstrap Wizard). `server` is wired with the MinIO Docker secrets (`NEBU_MINIO_ACCESS_KEY_FILE` /
`NEBU_MINIO_SECRET_KEY_FILE`), the `NEBU_MINIO_*` env vars, and `depends_on` on `minio` (healthy) and
`createbuckets` (completed). ExAws config in `server/config/runtime.exs` reads the file-based MinIO
credentials. Media access control is a local `room_members` SQL call inside the app — no cross-process
hop.

**Admin login owned in Elixir:** The admin OIDC Authorization-Code + PKCE login lives in
`Nebu.Admin.Auth` (`/admin/login/start`, `/admin/callback`, `/admin/logout`). ADR-022: it uses the
**single** wizard-configured OIDC client (the same client that validates Matrix Bearer tokens); there is
no separate admin client and no `NEBU_ADMIN_OIDC_*` env. The `/admin/callback` redirect_uri is a fixed,
server-controlled target derived from `:server_name` + `:admin_session_secure`. The session is the signed
Phoenix `secret_key_base` cookie (http_only, secure, SameSite=Lax), capped at min(idToken.exp, now+8h).

## OIDC Configuration Sourcing (ADR-022 — Bootstrap-Only)

**OIDC is configured EXCLUSIVELY through the Bootstrap Wizard, persisted in `server_config`.** There are
no `NEBU_OIDC_*` / `NEBU_ADMIN_OIDC_*` configuration environment variables. The server boots without OIDC
config and fails closed (config validated per-operation, not at boot): before bootstrap every Bearer token
is rejected `401 M_UNKNOWN_TOKEN` and the admin UI redirects to `/bootstrap`. A **single** OIDC client
serves both Matrix Bearer validation and admin operator login.

| Scenario | Source of truth | Behavior |
|---|---|---|
| First-boot (pre-bootstrap) | none | Server boots; all Bearer tokens 401; admin → `/bootstrap`. |
| Bootstrap wizard step 2 | operator input → `server_config` | Collects issuer, the single client id/secret, audience, JWKS URI (all required). Completion promotes `bootstrap_draft` → `server_config`; `OidcConfig`/`JwksCache` caches refresh; `:pg` invalidates peer nodes. |
| Post-bootstrap | `server_config` (via `OidcConfig` cache) | OidcPlug / SsoLogin / Admin.Auth / MSC2965 discovery resolve issuer/audience/JWKS-URI/client from the cache. |

**Component: `Nebu.Web.OidcConfig`** — to avoid a per-request DB lookup on the OIDC hot path, config from
`server_config` is cached in the named ETS table `:nebu_http_oidc_config` (read_concurrency: true). The
GenServer loads on boot from `server_config` (`oidc_issuer`, `oidc_audience`, `oidc_jwks_uri`), refreshes
on wizard completion (`OidcConfig.refresh/0`), is cluster-aware via `:pg` (ADR-020, M-3), and returns
`nil` for any unset key.

**Resolution logic (ADR-022 — server_config only, fail-closed):**

```
issuer / audience (OidcPlug, SsoLogin, Admin.Auth, discovery):
  OidcConfig.get() → ETS cache (may be nil) → if nil, fail closed (401 / 503 / redirect)

JWKS URI (JwksCache):
  OidcConfig.jwks_uri() → ETS cache → if nil, auto-discover from issuer's
    /.well-known/openid-configuration → if still nil, no keys → all tokens rejected

single client id/secret (SsoLogin, Admin.Auth):
  server_config.oidc_client_id + AES-256-GCM-decrypted oidc_client_secret → if unset, fail closed
```

**Bootstrap Wizard form (ADR-022):** Step 2 collects `oidc_issuer`, `oidc_client_id`,
`oidc_client_secret`, `oidc_audience`, and `oidc_jwks_uri`. All fields are **always editable and
required** — there is no env-lock/`disabled` mode (the former env-locked-fields behavior is removed).
The client secret is stored AES-256-GCM encrypted at rest.

On step 3 (finalization), the wizard persists all collected values (including `oidc_audience` and
`oidc_jwks_uri`) into `server_config` atomically. It then calls `OidcConfig.refresh/0` to invalidate
the ETS cache and trigger cluster-wide reloads.

**Security notes:**

- **Fail-closed on missing config:** If bootstrap completes without an audience or JWKS URI (when env vars
  are also absent), the OIDC plug correctly enters a fail-closed state and rejects all tokens with 401.
  The Bootstrap Wizard validates this at form submission (AC2, AC5) to prevent completing into a broken state.
- **Env vars override DB:** When `NEBU_OIDC_*` env vars are set, they always take precedence over the
  `server_config` values. This ensures that operators can lock OIDC config at deployment time and prevent
  accidental misconfiguration via the Bootstrap Wizard.
- **Cluster coherency:** All nodes in a cluster refresh their ETS caches within milliseconds after a wizard
  completion, ensuring consistent OIDC enforcement across the cluster.

**Port map:**

| Service | External Port | Purpose |
|---|---|---|
| Elixir application (`server`) | 4000 | Matrix C-S API + `/_matrix/media/v3/*` + Admin UI `/admin/*` + health/info |
| Elixir application (`server`) | 9000 | Vestigial gRPC listener (nothing dials it; amended ADR-005) — internal network only |
| PostgreSQL | 5432 | Database (internal Docker network only) |
| Dex (dev) | 5556 | OIDC provider (development only) |
| MinIO S3 API | 9000 | Object storage API (S3-compatible) - local dev only |
| MinIO Console | 9001 | Object storage management UI - local dev only |

## Network Boundaries

```
External boundary (exposed to clients):
  Internet → [TLS 1.3] → Elixir application (Port 4000)

Internal boundary (Docker network, not exposed):
  Elixir application → [TLS] → PostgreSQL  (Port 5432)
  Elixir application → [S3/TLS] → MinIO    (Port 9000)
  (HTTP surface → domain logic is an in-process function call within the one app — no network hop)
```

## Makefile Targets

```makefile
make setup              # Generate .secrets/internal_secret, MinIO credentials, and dev credentials
make dev                # docker compose up (server, postgres, dex, minio)
make dev-reset-db       # Drop + recreate the database, apply the single seed migration (WARNING: destroys all data)
make build-server       # Docker multi-stage build for the Elixir application
make test-unit-elixir   # mix test in container
make test-integration   # Full Docker Compose stack + Godog Gherkin tests
```

## Database Migration Strategy (Story 13-14)

### Squashed Seed Migration

The application ships a **single seed migration** (raw SQL, e.g. `000001_init.up.sql`) that represents the complete current schema in its final state. The previous 49 incremental migration files (000002–000049) have been deleted. Migrations are applied by `Nebu.Release.migrate/0` (raw SQL run by the release before the app boots, ADR-018) — there is no golang-migrate and no ORM.

**Rationale:** Incremental migrations accumulated role-specific ownership transfers (`ALTER TABLE … OWNER TO nebu_migrate`) and backward-compatibility grants (`GRANT EXECUTE … TO nebu`) that required the `nebu_migrate` and `nebu` PostgreSQL roles to exist before migrations ran. On managed database services (Stackit PostgresFlex, AWS Aurora Serverless v2) where the runtime role cannot run `CREATE ROLE` DDL, this caused fresh deployments to fail at migration 24.

**Single-role model:** The squashed migration is designed to run as `nebu_app` (the runtime DB user). All objects are created by `nebu_app`; no ownership transfers or legacy grants are needed.

**Key characteristics of the seed migration:**

- Contains all 26+ tables, indexes, triggers, functions, and RLS policies in final state
- No references to `nebu_migrate` in ownership transfers or function grants
- No `GRANT EXECUTE … TO nebu` (legacy backward-compat grants removed)
- `NEBU_DB_URL` (pointing to `nebu_app`) is used for both migrations and runtime on fresh deployments; `NEBU_DB_URL_MIGRATE` is still accepted for backward compatibility but is no longer required

**The down migration** drops all tables and functions in reverse dependency order. Extensions (`pgcrypto`, `uuid-ossp`) are intentionally NOT dropped - they may be shared at the PostgreSQL server level.

**Local dev reset:**

```bash
make dev-reset-db   # docker compose down --volumes → recreate postgres → start server (runs migration on boot)
                    # WARNING: destroys all local data
```

After reset, `Nebu.Release.migrate/0` runs at boot and `GET /ready` reflects the applied schema version.

### Stackit PostgresFlex Role Provisioning

The Stackit OpenTofu module (`deploy/tofu/examples/stackit/database.tf`) provisions three PostgresFlex users:

| User | Purpose |
|---|---|
| `nebu_app` | Runtime role: owns all objects in the squashed migration; used for both migrations and application queries |
| `nebu_migrate` | Kept for backward compatibility with existing deployments that pass `NEBU_DB_URL_MIGRATE`. No longer required for fresh deployments. |
| `nebu` (legacy) | Placeholder required by the original migration history's `GRANT EXECUTE … TO nebu` statements. Not needed for fresh deployments using the squashed migration. |

On fresh Stackit deployments, only `nebu_app` is used. The `nebu_migrate` and `nebu` users are provisioned to avoid breaking existing environments that may reference them, but they do not connect at runtime.

## Multi-Stage Dockerfile

There is a single image — the Elixir/OTP release. No Go build stage exists anymore (ADR-021).

**Elixir application pattern:**
```dockerfile
FROM elixir:1.19-alpine AS builder
RUN MIX_ENV=prod mix release

FROM alpine:3.23 AS runtime
COPY --from=builder /app/_build/prod/rel/nebu ./
# Nebu.Release.migrate/0 runs raw-SQL migrations on boot, then the supervisor tree starts.
ENTRYPOINT ["./bin/nebu", "start"]
```

## Health Checks

```yaml
server:
  healthcheck:
    test: ["CMD", "curl", "-f", "http://localhost:4000/health"]
    interval: 10s
    timeout: 5s
    retries: 3
    start_period: 30s
  restart: always
```

Docker Compose uses liveness (`GET :4000/health`). Because everything runs in one node, there is no
gateway↔core stream-health signal to derive readiness from — the former GRÜN/GELB/ROT status applied
only to the removed gateway↔core gRPC boundary (ADR-021). `GET :4000/health` reports node and cluster
status (see Server Clustering).

## Secret Management

Secrets are never passed as environment variables directly. They are mounted via Docker Compose
secrets and referenced via `NEBU_*_FILE` environment variables pointing to the mounted file:

```bash
make setup   # generates .secrets/internal_secret, .secrets/minio_root_user,
             # .secrets/minio_root_password, .secrets/minio_app_access_key,
             # and .secrets/minio_app_secret_key via openssl rand
# docker-compose.yml mounts all five as Docker secrets
# Gateway reads internal secret via NEBU_INTERNAL_SECRET_FILE=/run/secrets/internal_secret
# MinIO reads root credentials via MINIO_ROOT_USER_FILE / MINIO_ROOT_PASSWORD_FILE
# Media Gateway reads app credentials via NEBU_MINIO_ACCESS_KEY_FILE / NEBU_MINIO_SECRET_KEY_FILE
# createbuckets creates the nebu-app MinIO user and attaches the nebu-app-policy (PutObject+GetObject only)
# WARNING: These are example credentials for local development only.
# Replace before first production start.
```

### MinIO IAM Hardening (Story 12.3)

The media gateway uses a dedicated `nebu-app` MinIO user with a least-privilege IAM policy:

```json
{
  "Statement": [{
    "Effect": "Allow",
    "Action": ["s3:PutObject", "s3:GetObject"],
    "Resource": ["arn:aws:s3:::nebu-media/*"]
  }]
}
```

Intentionally absent: `s3:DeleteObject` (soft-delete only), `s3:ListBucket` (prevents enumeration), `s3:*` (no admin ops from app). The `createbuckets` init container creates and attaches this policy at startup. The media gateway runs as this user, never as the MinIO root. Root credentials are never passed to the media gateway.

Policy source: `dev/minio/nebu-app-policy.json`.

_Source: `_bmad-output/planning-artifacts/architecture.md`, §Infrastructure & Deployment, §Build-Container-Strategie, §Resilienz & Selbst-Heilung_

---

## Production Deployment (OpenTofu IaC)

Story 13-1 introduces a production-grade Infrastructure-as-Code layer under `deploy/`. Three target platforms are supported - see [ADR-014](adr/ADR-014-deployment-strategy-iac.md) for the full decision rationale.

> **IaC predates ADR-021 — updating to single-container topology is tracked follow-up.** The OpenTofu
> modules and Helm chart described below were authored when Nebu was a two-container deployment
> (`gateway` + `core`). They still provision a `gateway` service/deployment and a separate
> `media` service. Those resources now map onto the **single Elixir application container** (the
> `server` image), which serves the Matrix API, media, and Admin UI on port 4000; references to a "Go
> gateway", a separate "media gateway", port 8008, and the gateway↔core gRPC hop are historical and
> will be collapsed when the IaC is regenerated for the consolidated topology. Read the platform
> sections below with that mapping in mind.

### deploy/ Directory Structure

```
deploy/
  tofu/
    modules/
      nebu-shared/    # Shared variables, validations, outputs (no provider resources)
      nebu-aws/       # AWS: ECS Fargate + RDS + S3 + ACM (Story 13-2)
      nebu-stackit/   # STACKIT: VMs + Docker Compose + ALB + DBaaS (Story 13-3)
      nebu-k8s/       # Kubernetes: Helm Release wrapper (Story 13-4)
    examples/
      aws/            # AWS quick-start root module
      stackit/        # STACKIT quick-start root module
      k8s/            # Kubernetes quick-start root module
  helm/
    nebu/             # Standalone Helm Chart (usable without OpenTofu)
```

### Platform Targets

| Platform | Mechanism | Database | Backend |
|---|---|---|---|
| AWS | ECS Fargate + Aurora Serverless v2 | AWS Aurora PostgreSQL 16 (Serverless v2) | S3 + DynamoDB |
| STACKIT | VMs + Docker Compose + ALB | STACKIT PostgresFlex (managed PostgreSQL 16) | STACKIT Object Storage (S3-compatible) |
| Kubernetes | Helm Chart (`deploy/helm/nebu/`) | External (operator-provided) | S3-compatible or PostgreSQL |

### Local IaC Validation

```bash
make test-iac-validate   # tofu fmt -check + tofu validate (all examples, no cloud credentials)
```

Equivalent CI gate: `validate-iac` job in `.gitlab-ci.yml` (runs on every push touching `deploy/**`).

### Shared Module: nebu-shared

`deploy/tofu/modules/nebu-shared/` defines shared input variables consumed by all platform modules: `nebu_version`, `domain_name`, `admin_email`, `postgres_db_name`, `image_registry`. All variables carry validation constraints (non-empty checks, semver regex for `nebu_version`).

### AWS Networking Module (nebu-aws)

`deploy/tofu/modules/nebu-aws/network.tf` provisions the AWS network foundation: one VPC, two public and two private subnets across two AZs, a single NAT Gateway (cost-optimized; one per AZ for HA production), and scoped security groups for ALB (80/443 from internet), ECS (ports 8008 + 9000 from ALB SG), and RDS (5432 from ECS SG only, egress limited to VPC CIDR). Resource names incorporate the `environment` variable (e.g. `nebu-prod-alb-sg`) for multi-environment deployments.

### AWS Database Module (nebu-aws - database.tf)

`deploy/tofu/modules/nebu-aws/database.tf` provisions the Aurora Serverless v2 layer (Story 13-8 - replaces the previous RDS Multi-AZ `aws_db_instance`):

- `aws_db_subnet_group` - uses private subnets from network.tf (no public access); retained as Aurora clusters also require DB subnet groups
- `aws_rds_cluster` - Aurora PostgreSQL 16.6, `engine_mode = "provisioned"` (Serverless v2 requirement - NOT `"serverless"`), storage encrypted, 7-day automated backups. Serverless v2 scaling is controlled by the `serverlessv2_scaling_configuration` block:
  - `min_capacity = 0` (default dev) - scales to zero and auto-pauses after 1 hour idle (`seconds_until_auto_pause = 3600`). Set `min_capacity = 0.5` for production to avoid cold-start latency.
  - `max_capacity = 4` (default) - sufficient for expected Nebu MVP load (approx. 2 vCPU equivalent). Increase for high-traffic production.
- `aws_rds_cluster_instance` - one instance per cluster, `instance_class = "db.serverless"` (required for Serverless v2); Performance Insights enabled explicitly (7-day retention).
- DB master password: `var.db_password` (sensitive, minimum 8 chars). Secrets Manager integration is provided via `secrets.tf`.
- `db_endpoint` output references `aws_rds_cluster.this.endpoint` (writer endpoint) - Aurora clusters expose a dedicated writer endpoint; the reader endpoint is separate and not used for Nebu's primary DB connection.

Key variables: `aurora_min_capacity` (default `0`), `aurora_max_capacity` (default `4`), `db_password`, `skip_final_snapshot` (default `true` for dev). The former `db_instance_class` and `enable_performance_insights` variables have been removed - Aurora Serverless v2 uses a fixed `db.serverless` class and enables Performance Insights by default.

**Cost model:** Aurora Serverless v2 charges per ACU-second consumed. At `min_capacity = 0`, a completely idle cluster costs near zero (vs. ~$50–100/month for the previous always-on `db.t3.medium` Multi-AZ instance).

### AWS ALB Module (nebu-aws - alb.tf)

`deploy/tofu/modules/nebu-aws/alb.tf` provisions the internet-facing Application Load Balancer:

- `aws_lb` - internet-facing ALB, placed in public subnets, `drop_invalid_header_fields = true` (header injection protection)
- `aws_lb_target_group.gateway` - target type `ip` (required for Fargate awsvpc networking), port 8008, health check on `GET /_matrix/client/v3/versions` (HTTP 200)
- `aws_lb_listener.https` - port 443, TLS policy `ELBSecurityPolicy-TLS13-1-2-2021-06` (TLS 1.3 minimum), ACM certificate via `var.acm_certificate_arn`, forwards to gateway target group
- `aws_lb_listener.http_redirect` - port 80, permanent `HTTP_301` redirect to HTTPS/443; no plaintext traffic ever reaches the gateway

Module outputs added: `alb_dns_name`, `alb_zone_id` (for Route 53 ALIAS records).

Key variable: `acm_certificate_arn` - required for `tofu apply`; empty string is accepted for `tofu validate` only.

### AWS Secrets Manager Module (nebu-aws - secrets.tf)

`deploy/tofu/modules/nebu-aws/secrets.tf` provisions all Nebu runtime credentials as individual Secrets Manager secrets under the `nebu/${environment}/` namespace:

| Secret path | Purpose |
|---|---|
| `nebu/{env}/db_url` | Full PostgreSQL DSN (used by gateway + server) |
| `nebu/{env}/db_password` | RDS master password (plain string; kept separate for RDS rotation support) |
| `nebu/{env}/internal_secret` | PSK for gateway ↔ server node registration (ADR-008) |
| `nebu/{env}/oidc_client_secret` | OIDC client secret for identity provider registration |
| `nebu/{env}/oidc_issuer` | OIDC issuer URL |
| `nebu/{env}/release_cookie` | Erlang distribution cookie for OTP cluster authentication |

All `aws_secretsmanager_secret_version` resources are provisioned with `PLACEHOLDER_*` initial values and `lifecycle { ignore_changes = [secret_string] }` - preventing `tofu apply` from overwriting operator-rotated values. Operators must set real values before go-live (see RUNBOOK.md).

### AWS Compute Module (nebu-aws - compute.tf)

`deploy/tofu/modules/nebu-aws/compute.tf` provisions the full ECS Fargate compute layer:

- `aws_ecs_cluster` - Fargate cluster with Container Insights enabled (`"nebu-${environment}"`)
- `aws_iam_role.ecs_task_execution` - Task execution role with `AmazonECSTaskExecutionRolePolicy` + inline policy for `secretsmanager:GetSecretValue` scoped to `arn:aws:secretsmanager:*:*:secret:nebu/${environment}/*` (least-privilege; no wildcard resource)
- `aws_cloudwatch_log_group` - `/ecs/nebu-{env}-gateway` and `/ecs/nebu-{env}-server`, 30-day retention
- `aws_ecs_task_definition.gateway` - image `{registry}/nebu-gateway:{version}`, CPU 256 / Memory 512, port 8008, health check `GET /_matrix/client/v3/versions`, `secrets` field references individual Secrets Manager ARNs for `NEBU_DB_URL`, `NEBU_OIDC_ISSUER`, `NEBU_OIDC_CLIENT_SECRET`, `NEBU_INTERNAL_SECRET`
- `aws_ecs_task_definition.server` - image `{registry}/nebu-server:{version}`, CPU 256 / Memory 512, port 9000, health check `GET /health`, `secrets` field references for `DATABASE_URL`, `RELEASE_COOKIE`, `NEBU_INTERNAL_SECRET`
- `aws_ecs_service.gateway` - Fargate service in private subnets, attached to the ALB target group (port 8008), `lifecycle { ignore_changes = [task_definition, desired_count] }` for GitOps rolling deployments
- `aws_ecs_service.server` - Fargate service in private subnets (no ALB attachment; accessed by gateway via gRPC on port 9000 within the VPC)

**Security invariants:** No `environment` field used for secrets in any task definition - all sensitive values are injected exclusively via the `secrets` field with Secrets Manager ARNs. IAM permissions are scoped to the namespace `nebu/${environment}/*` only.

Key variables: `aws_region` (CloudWatch Logs), `image_registry`, `nebu_version`, `acm_certificate_arn`, `ecs_desired_count` (default 1).

Module outputs: `ecs_cluster_arn`, `db_endpoint`, `task_execution_role_arn`, `alb_dns_name`, `alb_zone_id`.

### AWS Deployment Topology (Complete)

```
Internet
  │ HTTPS/443 (TLS 1.3)
  ▼
aws_lb (ALB, internet-facing)
  │ port 443 → aws_lb_listener.https → aws_lb_target_group.gateway (port 8008)
  │ port 80  → aws_lb_listener.http_redirect (HTTP 301 → HTTPS)
  ▼
aws_ecs_service.gateway (private subnets, ECS Fargate, no public IP)
  │ gRPC port 9000 (VPC-internal, ECS SG)
  ▼
aws_ecs_service.server (private subnets, ECS Fargate, no public IP)
  │ port 5432 (private subnets, RDS SG)
  ▼
aws_rds_cluster (Aurora PostgreSQL 16, Serverless v2, private subnets)
  ├── aws_rds_cluster_instance (db.serverless - scales 0–4 ACUs)
  └── writer endpoint: aws_rds_cluster.this.endpoint (port 5432)

Secrets Manager (nebu/{env}/*) ──► ECS task execution role (secretsmanager:GetSecretValue)
                                        │
                              injected into gateway + server containers
                              via ECS secrets field at task start
```

Day-2 operations (rolling updates, secret rotation, teardown) are documented in `deploy/tofu/examples/aws/RUNBOOK.md`.

### Stackit VM + Networking Module (nebu-stackit - 13-3a)

`deploy/tofu/examples/stackit/main.tf` provisions the STACKIT compute and network foundation:

- `stackit_network` - private routed network with configurable CIDR (`var.network_cidr`, default `10.0.0.0/24`)
- `stackit_security_group` + rules - stateful SG with inbound rules for 443 (HTTPS), 8008 (Matrix API), 22 (SSH); egress unrestricted
- `stackit_network_interface` - VM NIC attached to the network and SG
- `stackit_key_pair` - account-level SSH key pair (global resource; no `project_id`)
- `stackit_server` - Ubuntu 24.04 LTS VM; machine type via `var.vm_plan_id` (default `g2i.2`); AZ via `var.availability_zone` (default `eu01-1`)
- `stackit_public_ip` - Floating IP associated to the VM NIC. If the VM is recreated, re-attach manually via STACKIT portal or `stackit beta network-interface public-ip attach`
- `stackit_loadbalancer` - ALB with `PROTOCOL_TCP` listener on port 443 → target pool on VM port 8008; health check is TCP-only (no HTTP path checks); plan via `var.alb_plan_id` (default `p10`)

**HTTPS at ALB (upgrade path):** `enable_beta_resources = true` is already set in the provider block. Once `stackit` provider >= 0.96 exposes `PROTOCOL_HTTPS` in its stable schema, change the listener protocol to `PROTOCOL_HTTPS` and set `certificate_reference.name = var.stackit_tls_certificate_arn` (Stackit-managed certificate ARN). Until then, TLS is terminated at the gateway on port 8008.

**Authentication:** provider uses `service_account_key_path` (JSON key file) instead of a token. Path configured via `var.stackit_key_path` (sensitive).

Key variables: `stackit_project_id`, `stackit_key_path`, `ssh_public_key`, `ubuntu_image_id`, `network_cidr`, `availability_zone`, `vm_plan_id`, `alb_plan_id`, `stackit_tls_certificate_arn`.

### Stackit Managed Database (nebu-stackit - Story 13-8)

`deploy/tofu/examples/stackit/main.tf` provisions a dedicated STACKIT PostgresFlex instance alongside the application VM. This replaces the previous `postgres:16-alpine` container bundled in docker-compose.

**Resources provisioned:**

- `stackit_postgresflex_instance.nebu` - managed PostgreSQL 16 cluster with daily automated backups (`0 2 * * *` UTC), configurable replicas (`var.postgres_replicas`, default `1`; use `3` for production HA), and ACL locked to the VM's private network CIDR (`var.network_cidr`) - no public exposure
- `stackit_postgresflex_user.nebu` (`nebu_app`) - application user with `["login"]` role; owns the `nebu` database
- `stackit_postgresflex_user.keycloak` (`keycloak_app`) - dedicated Keycloak user with `["login"]` role; owns the `keycloak` database. Using separate DB users per application is a defence-in-depth measure: a compromise of the Nebu application user does not grant access to Keycloak data.
- `stackit_postgresflex_database.nebu` - `nebu` database, owner `nebu_app`
- `stackit_postgresflex_database.keycloak` - `keycloak` database, owner `keycloak_app`

PostgresFlex connection details (`host`, `port`, `username`, `password`) are computed by the provider after instance creation and passed directly into the cloud-init template as `pg_*` / `kc_*` variables. The password is **not** exposed as a Tofu output - operators retrieve it from Terraform state or via the STACKIT portal.

**Stackit Sizing Variables:**

| Variable | Default | Production recommendation |
|---|---|---|
| `postgres_replicas` | `1` | `3` (HA replication) |
| `postgres_cpu` | `1` | 2+ (depending on load) |
| `postgres_ram` | `4` GB | 8+ GB |
| `postgres_storage_size` | `20` GB | 50+ GB |

### Stackit Media Gateway Support (nebu-stackit - Media Gateway StackIT ObjectStore Story)

`deploy/tofu/examples/stackit/` now supports an optional Media Gateway deployment using StackIT Object Storage (S3-compatible) as the storage backend. Media Gateway is controlled by the `enable_media_gateway` variable.

**Resources provisioned when `enable_media_gateway = true`:**

- `stackit_objectstorage_bucket` - optionally creates an S3 bucket in StackIT Object Storage (if not already present)
- Docker Secrets for S3 credentials (`s3_access_key`, `s3_secret_key`) written to `/opt/nebu/.secrets/` with mode `0600`
- `media` Docker Compose service on port 8009 (exposed on loopback `127.0.0.1:8009` only)
- nginx routing rules for `/_matrix/media/` → media service (both TLS and non-TLS modes)

**Configuration Variables:**

| Variable | Type | Default | Purpose |
|---|---|---|---|
| `enable_media_gateway` | bool | `false` | Deploy the media gateway service |
| `s3_access_key` | string (sensitive) | `""` | Access key for StackIT Object Store (required when enabled) |
| `s3_secret_key` | string (sensitive) | `""` | Secret key for StackIT Object Store (required when enabled) |
| `s3_endpoint` | string | `"object.storage.eu01.onstackit.cloud"` | S3 endpoint hostname (without `https://` prefix) |
| `s3_bucket` | string | `"nebu-media"` | S3 bucket name for media storage |
| `media_cpu_limit` | string | `"0.50"` | CPU limit for media gateway container |
| `media_memory_limit` | string | `"256m"` | Memory limit for media gateway container |

**Media Gateway Environment Variables (set via cloud-init):**

The media service receives the following configuration:

```
NEBU_SERVER_NAME           — From Stackit deployment
NEBU_DB_URL                — PostgresFlex connection string
NEBU_STORAGE_BACKEND       — Fixed: "minio" (StackIT Object Store is MinIO-compatible)
NEBU_MINIO_ENDPOINT        — From s3_endpoint variable
NEBU_MINIO_ACCESS_KEY_FILE — /run/secrets/s3_access_key (Docker Secret)
NEBU_MINIO_SECRET_KEY_FILE — /run/secrets/s3_secret_key (Docker Secret)
NEBU_MINIO_BUCKET          — From s3_bucket variable
NEBU_MINIO_USE_SSL         — "true" (StackIT Object Store requires TLS)
NEBU_OIDC_ISSUER           — From deployment configuration
NEBU_OIDC_CLIENT_ID        — From deployment configuration
NEBU_TRUSTED_PROXY         — For X-Forwarded-* header handling via nginx
```

**S3 Client Configuration (media/cmd/media/main.go):**

Media storage uses path-style bucket lookup for StackIT Object Store compatibility, translating bucket references to path-style S3 URLs (`https://endpoint/bucket/key`) instead of virtual-hosted URLs. (In the consolidated topology this is `Nebu.Media.Storage` via ExAws/Finch inside the single application; the historical IaC variables still describe a separate media service.)

**nginx Routing (when `enable_media_gateway = true`):**

| TLS mode | nginx behaviour |
|---|---|
| `enable_tls = true` (with ACME) | `https://<server_name>/_matrix/media/` → `http://media:8009` via Docker network |
| `enable_tls = false` | `http://<server_name>:8008/_matrix/media/` → `http://127.0.0.1:8009` on loopback (no TLS termination) |

Both routes set `client_max_body_size 50m` to allow large file uploads.

**Lifecycle - When Media Gateway is Disabled:**

When `enable_media_gateway = false` (default), no S3 buckets are created and the media service is absent from the docker-compose.yml. Operators can enable it later by setting `enable_media_gateway = true` and re-applying the Tofu configuration.

### Stackit OIDC Deployment Profiles (nebu-stackit - Story 13-9)

The Stackit deployment supports two OIDC profiles selected via `var.oidc_mode`:

| `oidc_mode` | Bundled IdP | Use case |
|---|---|---|
| `"dex"` | Dex IdP sidecar (`dexidp/dex:v2.45.1`) | Test, demo, integration environments |
| `"external"` _(default)_ | None | Production - operator provides an external OIDC provider |

**`"dex"` profile:**
- Dex runs as a Docker Compose sidecar on port 5556 with a static in-memory config (no database).
- `/opt/nebu/dex/config.yaml` is written at boot (mode `0600`) with a static client (`nebu-gateway`) and a static password user (`operator@example.com`).
- `effective_oidc_issuer` is auto-derived as `http://<server_name>:5556/dex`; the gateway resolves Dex via Docker hairpin NAT (Linux SNAT/masquerade - no extra routing required).
- A conditional SG rule `inbound_dex` opens port 5556 to `var.dex_allowed_cidr` (default `0.0.0.0/0` for demos; restrict to VPN/developer CIDR in shared environments).
- `var.dex_static_password_hash` (required when `oidc_mode = "dex"`) must be a bcrypt hash (`$2a$`/`$2b$`/`$2y$` prefix). Generate with: `htpasswd -bnBC 12 '' 'yourpassword' | tr -d ':' | sed 's/$2y/$2a/'`.
- Expected `docker compose ps` output: `dex` (healthy), `server` (healthy), `gateway` (healthy).

**`"external"` profile:**
- No bundled IdP is deployed.
- `var.oidc_issuer` (required, non-empty) is passed directly into `.env` as `NEBU_OIDC_ISSUER`.
- `var.oidc_client_secret` must match the secret registered in the external OIDC provider.
- Expected `docker compose ps` output: `server` (healthy), `gateway` (healthy).

**Keycloak is fully removed in both profiles.** `stackit_postgresflex_user.keycloak` and `stackit_postgresflex_database.keycloak` no longer exist. There are no Keycloak-specific docker-compose services or secrets.

**New variables (Story 13-9):**

| Variable | Type | Default | Purpose |
|---|---|---|---|
| `oidc_mode` | string | `"external"` | Profile selection; validated against `["dex", "external"]` |
| `dex_allowed_cidr` | string | `"0.0.0.0/0"` | Source CIDR for SG rule on Dex port 5556 (dex mode only) |
| `dex_static_password_hash` | string (sensitive) | `null` | bcrypt hash for Dex static user; required when `oidc_mode = "dex"` |

A `lifecycle { precondition }` block on `stackit_server.nebu` enforces: `oidc_mode == "dex" → dex_static_password_hash != null` and `oidc_mode == "external" → length(oidc_issuer) > 0`.

### DNS Mode - `dns_mode` variable (nebu-aws + nebu-stackit - Story 13-10)

Both the AWS and Stackit deployment examples support a `dns_mode` variable that controls whether OpenTofu creates DNS records automatically or leaves DNS registration to the operator.

| `dns_mode` | AWS behaviour | Stackit behaviour |
|---|---|---|
| `"external"` _(default)_ | No DNS resources created. `dns_name` output holds the ALB DNS hostname for manual CNAME/ALIAS registration. | No DNS resources created. `dns_name` output holds the floating IP for manual A-record registration. |
| `"default"` | Creates `data.aws_route53_zone` + `aws_route53_record` (ALIAS A-record) in Route 53, guarded by `count = 1`. Requires the hosted zone for `var.domain_name` to exist in the AWS account with an exact name match. | Creates `stackit_dns_zone` + `stackit_dns_record_set.nebu` (A-record) for `var.server_name → floating IP`, guarded by `count = 1`. |

Default is `"external"` to prevent accidental DNS changes on existing deployments.

**Stackit-only: `dex_subdomain_enabled`**

When `dns_mode = "default"` and `dex_subdomain_enabled = true`, an additional `stackit_dns_record_set.dex` resource creates a `dex.<server_name>` A-record pointing to the same floating IP. This lays groundwork for future host-based Dex routing (see story 13-9 dev notes). The variable is validated - setting it to `true` when `dns_mode = "external"` raises a validation error at plan time.

**Stackit-only: `dns_contact_email`**

An optional `dns_contact_email` variable (default `""`) sets the `contact_email` on the `stackit_dns_zone` resource. When empty, the field is omitted via null-coalescing (`var.dns_contact_email != "" ? var.dns_contact_email : null`).

**AWS: `dns_name` output**

A new `deploy/tofu/examples/aws/outputs.tf` exports `dns_name = module.nebu_aws.alb_dns_name`. Operators using `dns_mode = "external"` run `tofu output dns_name` to retrieve the ALB hostname to register as a CNAME. Note: CNAME is not supported at the zone apex - use Route 53 ALIAS or an ALIAS/ANAME record at your DNS provider for apex domains.

**RUNBOOK coverage:** Both `deploy/tofu/examples/aws/RUNBOOK.md` and `deploy/tofu/examples/stackit/RUNBOOK.md` include a "DNS Configuration" section describing both modes, manual registration steps for `external` mode, and import instructions for existing Stackit DNS zones.

**New variables (Story 13-10):**

| Variable | Example | Type | Default | Purpose |
|---|---|---|---|---|
| `dns_mode` | AWS + Stackit | string | `"external"` | DNS record creation mode; validated against `["default", "external"]` |
| `dex_subdomain_enabled` | Stackit only | bool | `false` | Create `dex.<server_name>` DNS record when `dns_mode = "default"` |
| `dns_contact_email` | Stackit only | string | `""` | Contact email for Stackit DNS zone (omitted when empty) |

### Stackit cloud-init Bootstrap (nebu-stackit - 13-3b, updated 13-8, 13-9)

`deploy/tofu/examples/stackit/cloud-init.tftpl` is rendered by `templatefile()` in `main.tf` and injected as `user_data` (base64-encoded) into the VM at provision time. On first boot, the VM:

1. Applies OS security patches (`package_upgrade: true`)
2. Installs Docker CE + Docker Compose plugin via the official Docker apt repository
3. Writes `/opt/nebu/` directory tree (permissions `0700`) with:
   - `.secrets/internal_secret` (mode `0600`, quoted scalar - no trailing newline)
   - `.env` (mode `0600`) - runtime secrets injected from OpenTofu variables (OIDC secrets, admin credentials, etc.). `NEBU_DB_URL`, `NEBU_DB_URL_MIGRATE`, and `NEBU_POSTGRES_SSL` are set directly in the `docker-compose.yml` `environment:` block — not in `.env` — so DB connection config is visible in compose without shell-variable expansion.
   - `/opt/nebu/dex/config.yaml` (mode `0600`, `oidc_mode = "dex"` only) - Dex static configuration
   - `docker-compose.yml` (mode `0640`) - two or three services: `server`, `gateway`, and conditionally `dex` (when `oidc_mode = "dex"`). No `postgres` service (managed PostgresFlex); no `keycloak` service.
4. Installs `/etc/systemd/system/nebu.service` - `Type=simple`, no `-d` flag; systemd owns the process lifecycle with `Restart=on-failure RestartSec=10`
5. Starts Docker (`systemctl start docker.service && sleep 2`) before starting `nebu.service`

**Changes in Story 13-9:**
- `keycloak` docker-compose service removed in both profiles - Keycloak is no longer deployed
- `KC_DB_PASSWORD` removed from `.env` - no Keycloak credentials
- Conditional Dex `write_files` entry and `dex:` service block added (guarded by `%{ if oidc_mode == "dex" ~}` template directive)
- `templatefile()` call no longer passes `kc_user`/`kc_password`; now passes `oidc_mode` and `dex_static_password_hash`
- `local.effective_oidc_issuer` computed in `main.tf` - auto-set to `http://<server_name>:5556/dex` for dex mode; uses `var.oidc_issuer` for external mode

**Changes in Media Gateway StackIT ObjectStore Story:**
- S3 credential `write_files` blocks added (guarded by `%{ if enable_media_gateway ~}` template directive)
  - `.secrets/s3_access_key` (mode `0600`)
  - `.secrets/s3_secret_key` (mode `0600`)
- Conditional `media:` service block added to `docker-compose.yml` with StackIT Object Store configuration
  - Image: `${NEBU_IMAGE_REGISTRY}/nebu-media:${NEBU_VERSION}`
  - Restart policy: `unless-stopped`
  - Depends on: `gateway` service (healthy)
  - Port binding: `127.0.0.1:8009:8009` (loopback only; gateway and nginx access via Docker network)
  - Health check: `wget -qO- http://localhost:8009/health` (10s interval, 5s timeout, 3 retries, 10s start grace)
  - Resource limits: CPU and memory configurable via `media_cpu_limit` and `media_memory_limit` variables
- `media` secrets block added to the secrets section (S3 credentials)
- nginx routing updated: conditionally adds `location /_matrix/media/` proxy blocks (both TLS and non-TLS modes)
  - Sets `client_max_body_size 50m` for large file uploads
  - Preserves `Host`, `X-Real-IP`, `X-Forwarded-For`, `X-Forwarded-Proto` headers
- `templatefile()` call now passes `enable_media_gateway`, `s3_access_key`, `s3_secret_key`, `s3_endpoint`, `s3_bucket` variables

**Changes in Story 13-15:**
- Conditional `element` Docker service added (guarded by `%{ if enable_element_web ~}` template directive); see below for full details
- `/opt/nebu/element-config.json` write_files block added (conditional on `enable_element_web`)
- nginx routing updated: added `/api/v1/` → gateway and `location /` → Element blocks; WebSocket `Upgrade`/`Connection` headers added to the Element location

**Changes in Bug 5-30 (OIDC extra scopes configurable):**
- `NEBU_OIDC_EXTRA_SCOPES` env var added to `.env` in the cloud-init template with profile-conditional values:
  - `oidc_mode = "dex"`: `groups offline_access` (required for Dex group claims + refresh tokens)
  - `oidc_mode = "external"`: `""` (empty — external providers such as Keycloak may reject non-standard scopes)
- `docker-compose.yml` (local dev): `NEBU_OIDC_EXTRA_SCOPES=groups offline_access` added for the dev Dex environment
- The gateway reads `NEBU_OIDC_EXTRA_SCOPES` as the env-var fallback; a `server_config` / `bootstrap_draft` DB key `oidc_extra_scopes` takes unconditional precedence when present (see §8 Cross-Cutting Concepts — "Configurable OIDC Extra Scopes")

**Changes in Bug postgres-ssl-env-var (PostgreSQL SSL via separate env var):**
- `NEBU_POSTGRES_SSL: "true"` added to the `server:` service `environment:` block in `docker-compose.yml` (Stackit cloud-init template). Managed PostgreSQL services (Stackit PostgresFlex) require TLS; setting it here keeps the connection URL clean.
- `NEBU_DB_URL` and `NEBU_DB_URL_MIGRATE` moved from `.env` (shell-variable `$${…}` references) into the `environment:` block as literal values — no `${}` indirection needed anymore.
- `server/config/runtime.exs`: `Nebu.Repo` config gains `ssl: System.get_env("NEBU_POSTGRES_SSL", "false") == "true"`. URL query parameters `?ssl=true` / `?sslmode=require` are no longer used or needed.
- `server/lib/nebu/release.ex`: `postgres_ssl_opts/0` helper reads the same `NEBU_POSTGRES_SSL` env var and appends `[ssl: true|false]` to the Postgrex start opts used by the migration runner (`Nebu.Release.migrate/0`).

**Security invariants:**
- `pg_password` appears only inside `.env` (mode `0600`), never in plain environment variables or log output
- `dex_static_password_hash` is written only to `/opt/nebu/dex/config.yaml` (mode `0600`)
- ACL on PostgresFlex is set to `[var.network_cidr]` - never `0.0.0.0/0`
- `stackit_postgresflex_user.nebu.password` is stored in Terraform state - operators MUST use encrypted Stackit Object Storage backend (see `RUNBOOK.md`)
- `/opt/nebu/` is `0700` (root-only); `docker-compose.yml` is `0640`
- `nebu_version` variable rejects `"latest"` - a specific semver tag is required
- `oidc_client_secret` must not contain `"` or `\` characters (YAML interpolation constraint, enforced by variable validation)

Day-2 operations (updates, OIDC profile switching, backup, teardown) are documented in `deploy/tofu/examples/stackit/RUNBOOK.md`.

### Element Web Client (nebu-stackit - Story 13-15)

`deploy/tofu/examples/stackit/` supports an optional Element Web Matrix client deployment controlled by the `enable_element_web` variable. This allows end-users to access Nebu via a browser without installing a separate client.

**Variable:**

| Variable | Type | Default | Purpose |
|---|---|---|---|
| `enable_element_web` | bool | `false` | Deploy `vectorim/element-web:v1.12.15` as a Docker Compose service and configure nginx routing |

**CORS constraint - `enable_tls = true` is required:**

When `enable_element_web = true` but `enable_tls = false`, Element Web runs on port 7070 and the gateway runs on port 8008 - different ports mean different origins. Browsers enforce the Same-Origin Policy: every Matrix API call from Element triggers a CORS preflight that fails because the gateway does not emit `Access-Control-Allow-Origin` for the Element origin. **All Matrix API calls from Element silently fail.**

When `enable_tls = true`, nginx terminates TLS and serves both services under a single origin (`https://<server_name>`), eliminating the CORS problem entirely.

A `lifecycle { precondition }` block in `deploy/tofu/examples/stackit/server.tf` enforces this constraint:

```hcl
condition     = !var.enable_element_web || var.enable_tls
error_message = "enable_element_web requires enable_tls = true ..."
```

`tofu apply` fails immediately if an operator sets `enable_element_web = true` with `enable_tls = false`.

**Docker service topology (when `enable_element_web = true`):**

```
vectorim/element-web:v1.12.15
  image:    vectorim/element-web:v1.12.15
  ports:    127.0.0.1:7070:80  (loopback only - nginx is the public entry point)
  volumes:  /opt/nebu/element-config.json:/app/config.json:ro
  depends_on: gateway (service_healthy)
  healthcheck: wget -qO- http://localhost/
```

Element binds to loopback only (`127.0.0.1:7070`) - it is never reachable directly from the internet. Port 7070 is intentionally absent from the Stackit security group rules. Only nginx (port 443) is the public entry point.

**nginx routing table (when `enable_tls = true` AND `enable_element_web = true`):**

| Path prefix | Proxied to | Purpose |
|---|---|---|
| `/_matrix/` | `http://127.0.0.1:8008` | Matrix Client-Server API |
| `/.well-known/matrix/` | `http://127.0.0.1:8008` | Matrix server discovery |
| `/admin/` | `http://127.0.0.1:8008` | Nebu Admin UI and API |
| `/api/v1/` | `http://127.0.0.1:8008` | Internal/compliance API |
| `/dex/` | `http://127.0.0.1:5556` | Dex IdP (only when `oidc_mode = "dex"`) |
| `/` | `http://127.0.0.1:7070` | Element Web client (catch-all) |

The `location /` block for Element is always listed last - nginx evaluates prefix locations in longest-match order, ensuring Matrix API paths are never accidentally routed to Element.

The Element location includes WebSocket upgrade headers (`Upgrade`, `Connection`) to support future Matrix `/sync` long-polling and WebSocket transports.

**`element-config.json` - Security hardening:**

`/opt/nebu/element-config.json` is written by cloud-init at boot time with values interpolated from OpenTofu variables:

```json
{
  "m.homeserver": { "base_url": "https://<server_name>", "server_name": "<server_name>" },
  "brand": "Nebu",
  "disable_custom_urls": true,
  "disable_guests": true,
  "disable_3pid_login": true,
  "default_federate": false,
  "settingDefaults": {
    "UIFeature.registration": false,
    "UIFeature.passwordReset": false,
    "UIFeature.identityServer": false,
    "UIFeature.thirdPartyId": false
  },
  "sso_redirect_options": { "immediate": false }
}
```

`disable_custom_urls: true` prevents users from pointing Element at a different server. `UIFeature.registration` and `UIFeature.passwordReset` are disabled because Nebu uses OIDC-only authentication. The file is absent when `enable_element_web = false`.

**`element_url` output:**

`deploy/tofu/examples/stackit/outputs.tf` exposes an `element_url` output:

| Condition | Output |
|---|---|
| `enable_element_web = true` AND `enable_tls = true` | `https://<server_name>/` |
| `enable_element_web = true` AND `enable_tls = false` | `http://<server_name>:7070/` (blocked by precondition) |
| `enable_element_web = false` | `"disabled"` |

**`terraform.tfvars.example` documentation section:**

```hcl
# ── Element Web client ──────────────────────────────────────────────────────
# REQUIRES enable_tls = true - a lifecycle precondition blocks `tofu apply` if
# this constraint is violated. Without nginx (TLS), Element runs on port 7070
# while the gateway is on port 8008 - different origins cause CORS preflight
# failures for all Matrix API requests from Element.
#
# When enable_tls = true (required): nginx serves Element at / and proxies
# Matrix API paths (/_matrix/, /.well-known/matrix/, /admin/) to the gateway
# (port 8008). Element binds to 127.0.0.1:7070 (loopback only).
# enable_element_web = false
```

### Helm Chart

`deploy/helm/nebu/` is a standalone Helm Chart usable independently of OpenTofu.

**Kubernetes resource topology (Story 13-4a + 13-4b):**

| Resource | Name pattern | Conditional | Purpose |
|---|---|---|---|
| Deployment | `{release}-nebu-gateway` | always | Application pod (historical name; runs the single Elixir release); loads ConfigMap + optional Secret via `envFrom` |
| Deployment | `{release}-nebu-server` | always | Elixir/OTP server |
| Service (ClusterIP) | `{release}-nebu-gateway` | always | Port 8008 → gateway pods |
| Service (ClusterIP) | `{release}-nebu-server` | always | Port 9000 (gRPC) + 4000 (HTTP) → server pods |
| ConfigMap | `{release}-nebu-config` | always | `NEBU_OIDC_ISSUER`, `NEBU_SERVER_NAME`, `NEBU_CORE_GRPC_ADDR` (non-secret) |
| Ingress | `{release}-nebu` | `ingress.enabled: true` | nginx Ingress with configurable hostname and optional TLS secret |
| PersistentVolumeClaim | `{release}-nebu-postgres` | `postgres.external: false` | Postgres storage when running in-cluster |
| HorizontalPodAutoscaler | `{release}-nebu-gateway` | `autoscaling.gateway.enabled: true` | CPU-based HPA for gateway Deployment |

`NEBU_CORE_GRPC_ADDR` is derived deterministically from the release name as `{release}-nebu-server:9000` - rendered by the ConfigMap template, not a values entry.

> **ADR-022 note (OIDC is bootstrap-configured):** As of ADR-022 the application reads **no** OIDC config
> from the environment. The `NEBU_OIDC_*` / `NEBU_ADMIN_OIDC_*` values still rendered by the Helm chart and
> Tofu modules below are **ignored at runtime** — OIDC (issuer, audience, JWKS URI, the single client
> id/secret, claim mappings) is configured once via the **Bootstrap Wizard** (`server_config`). These IaC
> artifacts are pending a follow-up cleanup to drop the OIDC env entirely; operators should configure OIDC
> through the wizard, not via these env values.

**Secret management (ExistingSecret pattern):**

The chart never creates a Kubernetes Secret. Sensitive `NEBU_*` variables (`NEBU_DB_URL`, `NEBU_INTERNAL_SECRET`) must be stored in a pre-existing Kubernetes Secret, created out-of-band by the operator (OIDC is configured via the Bootstrap Wizard per ADR-022, not via a `NEBU_OIDC_CLIENT_SECRET` env):

```bash
kubectl create secret generic nebu-sensitive \
  --from-literal=NEBU_DB_URL='postgres://user:pass@host:5432/nebu' \
  --from-literal=NEBU_INTERNAL_SECRET='<64-char-random-hex>' \
  --from-literal=NEBU_OIDC_CLIENT_SECRET='<secret>'
```

The Secret name is referenced in `values.yaml` as `existingSecret.name`. When set, the gateway Deployment loads it via `envFrom.secretRef`. If the name is empty, no Secret is mounted and the gateway will fail to start - this is intentional (GitOps pre-deploy pattern) and documented in NOTES.txt.

Image tags must be set independently per component. Omitting either tag causes `helm install` to fail with an explicit error - preventing silent deployment of unversioned images.

```bash
# Minimal production install:
helm install nebu deploy/helm/nebu/ \
  --set gateway.image.tag=1.0.0 \
  --set server.image.tag=1.0.0 \
  --set config.oidcIssuer=https://your-idp.example.com \
  --set config.serverName=your-server-name \
  --set existingSecret.name=nebu-sensitive

# With Ingress + HPA:
helm install nebu deploy/helm/nebu/ \
  --set gateway.image.tag=1.0.0 \
  --set server.image.tag=1.0.0 \
  --set existingSecret.name=nebu-sensitive \
  --set ingress.enabled=true \
  --set ingress.hostname=nebu.example.com \
  --set ingress.tls.secretName=nebu-tls \
  --set autoscaling.gateway.enabled=true
```

### OpenTofu Kubernetes Wrapper (nebu-k8s - Story 13-4c)

`deploy/tofu/modules/nebu-k8s/` is a thin OpenTofu wrapper around a single `helm_release` resource. It manages the Nebu Helm release on any Kubernetes cluster. The Kubernetes and Helm providers must be configured in the calling root module.

**Module interface:**

| Variable | Type | Default | Purpose |
|---|---|---|---|
| `release_name` | string | `"nebu"` | Helm release name |
| `chart_path` | string | required | Path to the Nebu Helm chart directory |
| `namespace` | string | `"nebu"` | Kubernetes namespace (created if absent) |
| `gateway_image_tag` | string | required | Container image tag for the gateway component |
| `server_image_tag` | string | required | Container image tag for the server component |
| `ingress_enabled` | bool | `false` | Enable the Ingress resource |
| `helm_timeout` | number | `300` | Seconds to wait for all pods to reach Ready state |
| `values_files` | list(string) | `[]` | Extra values files; must be non-empty absolute paths |

`wait = true` is set explicitly - `tofu apply` blocks until all pods are Ready or `helm_timeout` seconds elapse. This prevents silent partial deployments.

`values_files` paths must be absolute (use `"${path.module}/..."` in the calling root module) - relative paths are resolved from the `tofu apply` working directory, not the module directory.

**Quick-start example (`deploy/tofu/examples/k8s/`):**

```hcl
module "nebu_k8s" {
  source = "../../modules/nebu-k8s"

  chart_path        = var.chart_path
  namespace         = var.namespace
  gateway_image_tag = var.gateway_image_tag
  server_image_tag  = var.server_image_tag
  ingress_enabled   = var.ingress_enabled
  values_files      = ["${path.module}/../../../helm/nebu/values-dev.yaml"]
}
```

**Local smoke test (kind):**

```bash
# 1. Start a local kind cluster
kind create cluster --name nebu-dev

# 2. Validate IaC configuration (no cluster required)
make test-iac-validate

# 3. Install via Helm directly (fastest smoke test path)
helm install nebu deploy/helm/nebu/ \
  -f deploy/helm/nebu/values-dev.yaml \
  --set gateway.image.tag=dev \
  --set server.image.tag=dev

# 4. Wait for pods
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=nebu --timeout=180s -n default

# 5. Teardown
kind delete cluster --name nebu-dev
```

Full operator procedures (upgrade, rollback, HPA configuration, teardown) are in `deploy/tofu/examples/k8s/RUNBOOK.md`.

---

## Load Test Topology (Story 13-5)

`docker-compose.scale.yml` is a Compose override that removes the fixed host-port binding from the gateway service so Docker Compose can start multiple replicas without port conflicts.

### Multi-Gateway Scale-Up

```bash
# Start full stack with 2 gateway replicas
docker compose -f docker-compose.yml -f docker-compose.scale.yml up \
  --scale gateway=2 --build -d --wait
```

Both replicas connect to the same Server instance via `server:9000` (gRPC) and share the `internal_secret` PSK. For 2-server clustering, see Story 13-6 below.

```
k6 load generator
  │ HTTP  (nebu_default Docker network)
  ▼
[gateway replica 1] ──gRPC:9000──▶ server
[gateway replica 2] ──gRPC:9000──▶ server
                                     │
                                     ▼
                               PostgreSQL 16
```

---

## Server Clustering (Story 13-6): libcluster + Horde Failover

The Elixir Server supports horizontal scaling via libcluster for node discovery and Horde for distributed Room GenServer supervision. When a Server node fails, Horde automatically restarts Room GenServers on the surviving node within seconds (no manual intervention).

### Architecture

```
[gateway] ──gRPC:9000──▶ [server (nebu@server)]   ←── Horde CRDT cluster ───▶ [server2 (nebu@server2)]
                               │                                                    │
                          Room GenServers                                   Room GenServers
                           (Horde Registry)                               (Horde Registry)
                               │                                                    │
                               └───────────────┬──────────────────────────────────┘
                                               ▼
                                        PostgreSQL 16
```

When `server` (nebu@server) is stopped:
1. Horde CRDT reconciliation detects the node departure
2. Room GenServers that were running on `server` are restarted on `server2`
3. Horde Registry re-registers the rooms under `server2`'s node
4. Gateway's next gRPC call succeeds (Room GenServer is alive on `server2`)

### Clustering Strategies

| Environment | Strategy | Discovery |
|---|---|---|
| Docker Compose | `Cluster.Strategy.Gossip` | UDP broadcast (port 45892) within Docker network |
| Kubernetes | `Cluster.Strategy.Kubernetes.DNS` | Headless Service DNS lookup (`server-headless`) |

### Environment Variables

| Variable | Purpose | Example |
|---|---|---|
| `CLUSTER_STRATEGY` | Selects libcluster strategy (`gossip` / `kubernetes`) | `gossip` |
| `RELEASE_NODE` | Erlang node name for distribution | `nebu@server` |
| `RELEASE_DISTRIBUTION` | Erlang distribution mode (`name` = long names) | `name` |
| `CLUSTER_NODES` | Comma-separated peer list (informational; Gossip discovers dynamically) | `nebu@server` |

### Local 2-Server Stack

```bash
# Start full stack with 2 Server nodes + scaled gateways
docker compose -f docker-compose.yml -f docker-compose.scale.yml up -d

# Simulate node failure (AC1 test)
docker stop $(docker compose -f docker-compose.yml -f docker-compose.scale.yml ps --format json | jq -r 'select(.Service=="server") | .Name')

# Verify room availability after failover (rooms migrate to server2 within 10 seconds)
```

The `docker-compose.scale.yml` override adds:
- `server` service: sets `RELEASE_NODE=nebu@server` and `CLUSTER_STRATEGY=gossip`
- `server2` service: same image, `RELEASE_NODE=nebu@server2`, connects to server1 via Gossip multicast

### Kubernetes Clustering

When `server.replicaCount > 1` in `values.yaml`, the Helm chart automatically injects:
- `CLUSTER_STRATEGY=kubernetes` → activates `Cluster.Strategy.Kubernetes.DNS`
- `RELEASE_NODE=nebu@$(MY_POD_IP)` → unique long-form node name per pod
- `RELEASE_DISTRIBUTION=name` → enables Erlang long-name distribution
- `KUBERNETES_SERVICE_NAME` pointing to the headless Service (`server-headless`)

A headless Service (`server-deployment-headless`) is automatically provisioned alongside the standard ClusterIP Service when `replicaCount > 1`. The headless Service returns A records for each pod, enabling libcluster to discover peers via DNS.

### Health Endpoint - Cluster Status

`GET http://server:4000/health` now includes `cluster_nodes` in its JSON response:

```json
{
  "status": "UP",
  "node": "nebu@server",
  "cluster_nodes": ["nebu@server2"],
  "components": { ... }
}
```

`cluster_nodes` is an empty list in single-node mode (no libcluster configured).

### Erlang Cookie (Security)

Erlang distribution requires all nodes in a cluster to share the same cookie. In production deployments:
- **Docker Compose:** uses Erlang's default auto-generated cookie (acceptable for dev; nodes on the same Docker network)
- **Kubernetes/AWS:** `RELEASE_COOKIE` is injected from Secrets Manager (see AWS secrets.tf) to ensure all Server pods use the same pre-shared cookie
- **STACKIT:** operators must set a consistent `RELEASE_COOKIE` in the cloud-init bootstrap across all Server VMs

### k6 Scenario Files

| File | Tier | VUs | Duration | Send p95 threshold |
|---|---|---|---|---|
| `k6/scenarios/gold-tier.js` | Gold | 1000 | 5 min | < 500 ms |
| `k6/scenarios/silver-tier.js` | Silver | 500 | 5 min | < 800 ms |

Each scenario exercises three endpoints per VU per iteration: `POST /_matrix/client/v3/login`, `GET /_matrix/client/v3/sync`, `PUT /_matrix/client/v3/rooms/{roomId}/send/m.room.message/{txnId}`.

Custom metrics reported: `nebu_login_duration`, `nebu_sync_duration`, `nebu_send_duration` (each as a Trend with p50/p95/p99), plus per-endpoint error rates. See `k6/README.md` for full operator instructions.

### CI Syntax Gate

```bash
make test-load-syntax   # k6 inspect (both scenarios) + docker compose config --quiet
```

This gate runs as part of `make test-iac-validate` (no running stack required).

---

## Release Pipeline (Story 13-11)

Story 13-11 introduces a versioned release track that runs alongside the existing SHA-tagged build track. The two tracks are intentionally separate and do not interfere with each other.

### Two-Track Image Strategy

| Track | Trigger | Image tag pattern | Purpose |
|---|---|---|---|
| Build (existing) | Every push / MR | `gateway:<SHA>`, `server:<SHA>` | Feeds integration tests; ephemeral |
| Release (new) | SemVer Git tag (`v*.*.* `) | `nebu-gateway:<semver>`, `nebu-server:<semver>` | Production images; referenced by operators |

**Image naming:** Release images use the `nebu-gateway` / `nebu-server` prefix (not `gateway` / `server` as in build images). This distinguishes them at the registry level and prevents accidental cross-track references.

**Version stripping convention:** Git tag `v1.0.0` → image tag `1.0.0` (the `v` prefix is stripped in both the CI pipeline and the `make release` target).

### CI Release Stage

Two Kaniko jobs in the new `release` stage of `.gitlab-ci.yml`:

```yaml
release-gateway-image:   # → <CI_REGISTRY_IMAGE>/nebu-gateway:<semver>
release-server-image:    # → <CI_REGISTRY_IMAGE>/nebu-server:<semver>
```

Both jobs:
- Are gated by `if: '$CI_COMMIT_TAG =~ /^v\d+\.\d+\.\d+$/'` - stable SemVer only; RC/beta tags (`v1.0.0-rc1`) are excluded
- Set `interruptible: false` and `needs: []` - run independently of branch-only build/integration jobs
- Use `--cache=false` - no reuse of branch-build Kaniko cache layers, ensuring deterministic and reproducible production images
- Pass `GIT_COMMIT`, `BUILD_TIME`, and `RELEASE_VERSION` as `--build-arg` to the Dockerfile

The `workflow:` block in `.gitlab-ci.yml` has been extended to allow tag pipelines:

```yaml
workflow:
  rules:
    - if: '$CI_COMMIT_TAG =~ /^v\d+\.\d+\.\d+$/'   # NEW: SemVer tag pipelines
    - if: '$CI_PIPELINE_SOURCE == "merge_request_event"'
    ...
```

### Makefile Release Targets

```makefile
make release TAG=v1.0.0       # Build gateway + server release images locally
make release-push TAG=v1.0.0  # Push to registry (requires docker login)

# Full release workflow:
TAG=v1.0.0 make release release-push
```

`make release` validates that `TAG` matches `vN.N.N` before building. `CI_REGISTRY_IMAGE` defaults to `registry.gitlab.com/philippb/open-chat` and can be overridden for forks.

### Operator Integration

Operators reference release images via the `nebu_version` variable in OpenTofu or image tags in Helm:

**OpenTofu (all three platforms):**
```hcl
nebu_version   = "1.0.0"   # strips 'v' prefix; matches image tag
image_registry = "registry.gitlab.com/myorg/open-chat"
# → pulls: <image_registry>/nebu-gateway:1.0.0 and nebu-server:1.0.0
```

**Helm:**
```bash
helm install nebu deploy/helm/nebu/ \
  --set gateway.image.tag=1.0.0 \
  --set server.image.tag=1.0.0 \
  --set image.registry=registry.gitlab.com/myorg/open-chat \
  --set existingSecret.name=nebu-sensitive
```

The `nebu_version` variable in the `nebu-shared` shared module already enforces a semver regex and rejects `"latest"` - this constraint remains in force for all release images.

_Source: Story 13-11 staged changes - `.gitlab-ci.yml`, `Makefile`, `deploy/helm/nebu/values.yaml`, `deploy/tofu/examples/*/terraform.tfvars.example`; Story 13-14 (squashed seed migration - single `000001_init.up.sql`, `make dev-reset-db` target, Stackit `nebu_migrate`/`nebu_legacy` backward-compat users)_
