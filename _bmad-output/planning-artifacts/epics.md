---
stepsCompleted: ['step-01-validate-prerequisites', 'step-02-design-epics', 'step-03-epic-1', 'step-03-epic-2', 'step-03-epic-3', 'step-03-epic-4', 'step-03-epic-5', 'step-03-epic-6', 'step-03-epic-7', 'step-03-epic-8', 'step-03-epic-9', 'step-03-epic-10', 'step-03-epic-11', 'step-03-epic-12', 'step-01-epic-16-requirements-validated', 'step-03-epic-16']
epic16_requirements:
  fr:
    - 'FR-16.1: GitLab CI-Pipeline baut die Website mit EasyWebsite aus MD-Files und deployt auf GitLab Pages'
    - 'FR-16.2: Landing Page präsentiert Nebu (Value Proposition, Tech Stack, Stakeholder-Personas)'
    - 'FR-16.3: arc42 Dokumentation (Sektionen 01–12 aus docs/architecture/) ist als Website-Bereich integriert'
    - 'FR-16.4: Alle ADRs (ADR-001 bis ADR-015) sind als eigener Bereich browsebar'
    - 'FR-16.5: Navigation ermöglicht schnelles Auffinden von Architecture Docs, ADRs und Betreiber-Infos'
    - 'FR-16.6: Operator Getting-Started Guide (Docker Compose, OIDC-Setup, First Login) ist Teil der Site'
    - 'FR-16.7: Die Website ist unter der Custom Domain nebuchat.eu mit TLS erreichbar'
  nfr:
    - 'NFR-16.1: Website baut in GitLab CI in < 5 Minuten'
    - 'NFR-16.2: Docs-Inhalte werden direkt aus docs/ bezogen — keine Inhalts-Duplikation im Repo'
    - 'NFR-16.3: Website ist ohne JavaScript navigierbar (statisches HTML)'
    - 'NFR-16.4: TLS-Zertifikat für nebuchat.eu via GitLab Pages Let Encrypt'
  technical:
    - 'EasyWebsite (https://easywebsite.opencode.de) als Generator-Tool'
    - 'GitLab Pages als Hosting-Plattform'
    - '.gitlab-ci.yml Pipeline-Definition erforderlich'
    - 'Custom Domain nebuchat.eu mit DNS CNAME auf GitLab Pages Endpunkt'
    - 'Basis: bestehende arc42 Docs aus docs/architecture/'
inputDocuments:
  - '_bmad-output/planning-artifacts/prd.md'
  - '_bmad-output/planning-artifacts/architecture.md'
  - '_bmad-output/planning-artifacts/ux-design-specification.md'
---

# Nebu — Epic Planning (Phase 3)

> Epics 1–12 (Phase 1 & 2) archived to `_bmad-output/archived-artifacts/epics-phase1-2.md`.

---

## Epic 13: Operators Can Deploy Nebu to Production and Validate Scalability

**Goal:** Nebu kann mit Infrastructure-as-Code (OpenTofu) auf drei Zielplattformen deployt werden: AWS (ECS + RDS), Stackit (VM + Docker Compose) und Kubernetes (Helm). Lastverhalten und horizontale Skalierung sind mit k6-Tests validiert.

**Pre-Epic-TODO:** ADR-014 erstellen (Deployment-Strategie: OpenTofu Projekt-Layout, Secrets-Management pro Platform, State-Backend-Wahl) — vor Story 13.1.

---

### Story 13.1: OpenTofu Project Structure + Shared Modules

As a system operator,
I want an OpenTofu project under `deployment/` with shared modules for network, database, and compute,
So that all three target platforms share reusable infrastructure primitives.

**Size:** M

**Acceptance Criteria:**

**Given** the repository is cloned,
**When** `ls deployment/` is inspected,
**Then** the following directories exist: `deployment/modules/` (shared: `network`, `database`, `compute`, `secrets`), `deployment/aws/`, `deployment/stackit/`, `deployment/k8s/`

**Given** `deployment/modules/database/main.tf` exists,
**When** `tofu validate` runs inside `deployment/aws/`,
**Then** validation succeeds with 0 errors

**Given** `deployment/README.md` exists,
**When** it is inspected,
**Then** it documents: prerequisites, backend configuration, per-platform quick start (3 commands each), secrets management strategy

**Given** the OpenTofu project,
**When** `tofu fmt -check -recursive deployment/` runs,
**Then** exit code is 0 (all files formatted correctly)

---

### Story 13.2a: AWS Networking Module (VPC, Subnets, Security Groups)

As a system operator,
I want an OpenTofu networking module under `deployment/modules/network/` that provisions the AWS network foundation,
So that all subsequent AWS resources (RDS, ECS, ALB) can be built on a validated, reusable network layer.

**Size:** S
**security_review:** not-needed

**Acceptance Criteria:**

**Given** `deployment/modules/network/main.tf` exists,
**When** `tofu plan` runs inside `deployment/aws/`,
**Then** the plan shows VPC, 2 public subnets, 2 private subnets, NAT Gateway, and security groups for ALB, ECS, and RDS — no errors

**Given** `deployment/modules/network/outputs.tf`,
**When** `tofu output` runs after apply,
**Then** VPC ID and all Subnet IDs are printed

**Given** `deployment/aws/`,
**When** `tofu validate` and `tofu fmt -check` run,
**Then** both exit with code 0

---

### Story 13.2b: AWS RDS PostgreSQL 16 + ECS Cluster

As a system operator,
I want OpenTofu to provision RDS PostgreSQL 16 Multi-AZ and an ECS Fargate cluster with task definition skeletons,
So that the database and compute infrastructure are ready for Nebu service deployment.

**Size:** S
**security_review:** not-needed

**Acceptance Criteria:**

**Given** `deployment/aws/main.tf` references the networking module from 13.2a,
**When** `tofu plan` runs,
**Then** the plan shows RDS PostgreSQL 16 Multi-AZ instance in private subnets and an ECS Fargate cluster — no errors

**Given** the RDS configuration,
**When** it is inspected,
**Then** DB credentials are sourced by reference from AWS Secrets Manager (the Secret resource is created in story 13.2c — this story uses a data reference or placeholder ARN)

**Given** the ECS task definition skeletons for gateway and core,
**When** they are inspected,
**Then** they contain placeholder container images and the correct task role ARN structure

**Given** `tofu apply` completes,
**When** `aws ecs describe-clusters` runs,
**Then** the cluster status is ACTIVE

---

### Story 13.2c: AWS ECS Task Definitions (gateway+core) + ALB + Secrets Manager + Runbook

As a system operator,
I want complete ECS Task Definitions, an Application Load Balancer, and AWS Secrets Manager secrets provisioned via OpenTofu,
So that Nebu is fully deployed on AWS and reachable via HTTPS.

**Size:** S
**security_review:** required

**Acceptance Criteria:**

**Given** the ECS Task Definitions for gateway and core,
**When** they are inspected,
**Then** all `NEBU_*` environment variables are sourced from AWS Secrets Manager, CPU/Memory are correctly configured, and the health check points to `/_matrix/client/v3/versions` on port 8008

**Given** the ALB configuration,
**When** it is inspected,
**Then** an HTTPS listener on port 443 forwards to the gateway Target Group on port 8008, and an HTTP listener on port 80 redirects to HTTPS

**Given** the AWS Secrets Manager secrets,
**When** they are inspected,
**Then** secrets for DB password, internal secret, and OIDC client secret are provisioned and referenced by the ECS task definitions (not hardcoded)

**Given** a deployed AWS stack,
**When** `curl https://<alb-dns>/_matrix/client/v3/versions` is called,
**Then** a valid Matrix versions response is returned

**Given** `deployment/aws/RUNBOOK.md`,
**When** it is read,
**Then** it covers: initial deploy, rolling update (ECS), secret rotation, teardown

---

### Story 13.3a: Stackit VM Provisioning + Networking (OpenTofu)

As a system operator,
I want an OpenTofu configuration under `deployment/stackit/` that provisions a Stackit VM with Floating IP and security groups,
So that the compute and network infrastructure for EU-hosted deployment is ready for Docker Compose bootstrap.

**Size:** S
**security_review:** not-needed

**Acceptance Criteria:**

**Given** `deployment/stackit/main.tf` is configured with a Stackit API token,
**When** `tofu plan` runs,
**Then** the plan shows a VM (Ubuntu 24.04 LTS, 4 vCPU / 8 GB), a Floating IP, and a Security Group with ports 443 and 22 open inbound — no errors

**Given** `deployment/stackit/outputs.tf`,
**When** `tofu output` runs after apply,
**Then** `floating_ip` and `vm_id` are printed

**Given** `tofu apply` completes,
**When** SSH is tested with the provisioned key,
**Then** SSH access to the VM via the Floating IP succeeds

---

### Story 13.3b: cloud-init Docker Compose Bootstrap + Runbook

As a system operator,
I want a cloud-init script injected by OpenTofu that installs Docker, bootstraps `.secrets/`, and starts Nebu via `docker compose up -d` on first boot,
So that Nebu is operational on the Stackit VM without manual steps after `tofu apply`.

**Size:** S
**security_review:** optional

**Acceptance Criteria:**

**Given** the cloud-init script embedded in `deployment/stackit/main.tf`,
**When** the VM boots for the first time,
**Then** Docker and Docker Compose are installed, `.secrets/` contents are injected from OpenTofu variables, and `docker compose up -d` starts automatically via systemd

**Given** `tofu apply` completes and the VM has finished its first boot,
**When** `docker compose ps` is run on the VM,
**Then** all Nebu services (gateway, core, postgres, keycloak) show as running and healthy

**Given** the deployed VM with TLS configured,
**When** `curl https://<floating-ip>/_matrix/client/v3/versions` is called,
**Then** a valid Matrix versions response is returned

**Given** `deployment/stackit/RUNBOOK.md`,
**When** it is read,
**Then** it covers: first deploy, update strategy (`docker compose pull && docker compose up -d`), and Postgres volume backup

---

### Story 13.4a: Helm Chart Core Templates (Deployment, Service, ConfigMap)

As a platform engineer,
I want the core Helm chart templates — Deployment, Service, and ConfigMap — under `deployment/k8s/helm/nebu/`,
So that the foundational Kubernetes resources for Nebu gateway and core can be rendered and linted without errors.

**Size:** S
**security_review:** not-needed

**Acceptance Criteria:**

**Given** `deployment/k8s/helm/nebu/Chart.yaml`, `values.yaml`, and `values-dev.yaml` exist,
**When** `helm lint deployment/k8s/helm/nebu/` runs,
**Then** exit code is 0 with 0 warnings

**Given** the Helm chart templates,
**When** `helm template deployment/k8s/helm/nebu/` runs,
**Then** valid YAML is rendered without errors, including separate Deployments for gateway and core, a ClusterIP Service for gateway, and a ConfigMap for `NEBU_*` environment variables

**Given** `values.yaml`,
**When** it is inspected,
**Then** the following are configurable: image tags (gateway, core), replica counts (gateway, core independently), NEBU_OIDC_ISSUER, NEBU_SERVER_NAME, and resource limits

---

### Story 13.4b: Helm Chart Ingress, PVC, Secrets, HPA

As a platform engineer,
I want Helm chart templates for Ingress, PersistentVolumeClaim, Kubernetes Secrets, and HorizontalPodAutoscaler,
So that production-grade Nebu deployments support TLS ingress, persistent storage, secret management, and autoscaling.

**Size:** S
**security_review:** optional

**Acceptance Criteria:**

**Given** the Ingress template,
**When** `helm template` renders it,
**Then** the Ingress hostname and TLS secret name are configurable via `values.yaml` and no hardcoded values appear

**Given** the Secret template,
**When** it is inspected,
**Then** DB credentials and internal secret are referenced by Kubernetes Secret name (not hardcoded in `values.yaml`)

**Given** the HorizontalPodAutoscaler template for gateway,
**When** it is enabled via `values.yaml`,
**Then** `helm lint` still passes with 0 warnings

**Given** the PersistentVolumeClaim template,
**When** `postgres.external: false` is set in `values.yaml`,
**Then** a PVC for Postgres is rendered; when `postgres.external: true`, no PVC is rendered

---

### Story 13.4c: OpenTofu K8s Provider + kind Smoke Test + Runbook

As a platform engineer,
I want `deployment/k8s/main.tf` with a Kubernetes/Helm provider and a validated smoke test against a local `kind` cluster,
So that operators can provision Nebu on any Kubernetes cluster via `tofu apply`.

**Size:** S
**security_review:** not-needed

**Acceptance Criteria:**

**Given** `deployment/k8s/main.tf` with a configured Kubernetes provider,
**When** `tofu plan` runs against a local `kind` cluster,
**Then** the plan shows a `helm_release` resource for Nebu — no errors

**Given** a local `kind` cluster,
**When** `helm install nebu deployment/k8s/helm/nebu/ -f deployment/k8s/helm/nebu/values-dev.yaml` runs,
**Then** all Nebu pods reach `Running` state within 3 minutes

**Given** `deployment/k8s/RUNBOOK.md`,
**When** it is read,
**Then** it covers: `helm upgrade`, rollback, and HPA configuration

---

### Story 13.5: Load Test — Gold Tier (1000 Concurrent Users, Multi-Gateway)

As a system operator,
I want a k6 load test scenario that validates Nebu under Gold Tier load (1000 concurrent users across 2 gateway instances),
So that I can verify horizontal scalability before production deployment.

**Size:** M

**Acceptance Criteria:**

**Given** `k6/scenarios/gold-tier.js` exists,
**When** `k6 run k6/scenarios/gold-tier.js --vus 1000 --duration 5m` runs against a 2-gateway stack,
**Then** p95 latency for `PUT /send` is < 500 ms and error rate is < 1%

**Given** the load test results,
**When** the k6 summary is inspected,
**Then** the following are reported: p50/p95/p99 latency for sync, send, login; total requests/sec; error rate per endpoint

**Given** a 2-gateway Docker Compose override (`docker-compose.scale.yml`),
**When** `docker compose -f docker-compose.yml -f docker-compose.scale.yml up --scale gateway=2` runs,
**Then** both gateway instances register with Core via PSK and share load

**Given** the load test README (`k6/README.md`),
**When** it is read,
**Then** it documents: test setup, expected results for Silver (500 VU) and Gold (1000 VU) tiers, how to run against AWS/Stackit deployments

---

### Story 13.6: Horizontal Scaling Validation — Core Clustering (libcluster + Horde)

As a system operator,
I want to validate that 2 Core nodes in a Horde cluster correctly hand off Room GenServers when one node is terminated,
So that horizontal Core scaling is proven safe before production use.

**Size:** M

**Acceptance Criteria:**

**Given** a 2-core Docker Compose configuration,
**When** both cores are running and a Room GenServer is active on Core 1,
**Then** `docker stop nebu-core-1` causes the Room GenServer to migrate to Core 2 within 10 seconds

**Given** the Room GenServer is migrated to Core 2,
**When** a new message is sent to that room via the Gateway,
**Then** the message is accepted and delivered correctly (no data loss)

**Given** a Godog scenario `gateway/features/core_clustering.feature`,
**When** `make test-integration` runs against the 2-core stack,
**Then** the scenario "Core node failover preserves room state" passes

**Given** `deployment/k8s/helm/nebu/values.yaml`,
**When** `core.replicaCount` is set to 2,
**Then** libcluster discovers both Core pods via Kubernetes DNS and forms a cluster (logged: `[libcluster] Connected to nebu-core-1`)

---

### Story 13.7: MSC2965 OIDC Discovery Endpoints — auth_issuer + auth_metadata

As a Matrix client user,
I want Nebu to respond to the MSC2965 OIDC discovery endpoints (`auth_issuer` and `auth_metadata`),
So that OIDC-aware clients like Element Web can discover the OIDC configuration without showing a "misconfigured server" error.

**Size:** S
**security_review:** not-needed

**Pre-Story:** Konsultiere `/agent-oracle` für die korrekte MSC2965-Spezifikation: erwartetes Response-Format beider Endpoints, Unterschied zwischen `unstable/org.matrix.msc2965/` und stabilen v1.x-Pfaden, und ob Nebu beide Pfadvarianten bedienen soll.

**Background:**
Element Web (und andere OIDC-aware Clients) senden beim Start folgende Requests:
```
GET /_matrix/client/unstable/org.matrix.msc2965/auth_issuer
GET /_matrix/client/unstable/org.matrix.msc2965/auth_metadata
```
Antworten mit 404 lösen einen "Dein Nebu ist falsch konfiguriert"-Fehler im Element-UI aus.
`auth_issuer` gibt die OIDC-Issuer-URL zurück; `auth_metadata` gibt die OIDC-Discovery-Metadaten (`.well-known/openid-configuration`) zurück oder leitet darauf hin.

**Acceptance Criteria:**

**Given** `GET /_matrix/client/unstable/org.matrix.msc2965/auth_issuer`,
**When** the endpoint is called (no auth required),
**Then** the response is `200 OK` with JSON body `{"issuer": "<NEBU_OIDC_ISSUER>"}` — the value of the configured `NEBU_OIDC_ISSUER` environment variable

**Given** `GET /_matrix/client/unstable/org.matrix.msc2965/auth_metadata`,
**When** the endpoint is called (no auth required),
**Then** the response is `200 OK` with the OIDC discovery document fetched from `<NEBU_OIDC_ISSUER>/.well-known/openid-configuration` (proxied or cached)

**Given** the oracle audit of MSC2965,
**When** stable path variants (`/_matrix/client/v1/auth_issuer` etc.) are also required by the spec,
**Then** both the `unstable/org.matrix.msc2965/` and the stable paths are registered (same handlers)

**Given** Element Web is opened and pointed at Nebu,
**When** the initial client startup requests complete,
**Then** no "misconfigured server" error appears and `auth_issuer` + `auth_metadata` return `200` in the browser console

**Given** the OIDC provider is temporarily unreachable (for `auth_metadata` proxy),
**When** the endpoint is called,
**Then** the response is `503 M_UNAVAILABLE` — not a 500 crash

**Given** a Godog scenario `gateway/features/oidc_discovery.feature`,
**When** `make test-integration` runs,
**Then** the following scenarios pass:
  - "auth_issuer returns configured OIDC issuer URL"
  - "auth_metadata returns valid OIDC discovery document"
  - "Both endpoints require no authentication"

---

## Epic 14: Admin — Claim Lock, OIDC User Import, and GDPR Compliance

**Goal:** Der `matrix_user_id_claim` kann nach dem Bootstrap nicht mehr geändert werden (verhindert Datenmigrationsfehler); Admins können OIDC-User aktiv importieren oder die User-Suche mit dem OIDC-User-Verzeichnis verbinden; DSGVO-konforme Löschung ist end-to-end verifiziert.

**Pre-Epic-TODO:** SCIM 2.0 Unterstützung vs. OIDC-API-Direktanbindung entscheiden (ADR-015: OIDC User Directory Integration Strategy) — vor Story 14.2.

---

### Story 14.1a: Core — FAILED_PRECONDITION for matrix_user_id_claim Post-Bootstrap

As an instance admin,
I want the Core `UpdateServerConfig` gRPC RPC to reject changes to `matrix_user_id_claim` after bootstrap is completed,
So that the server-side enforcement prevents accidental corruption of Matrix User IDs regardless of which client calls the API.

**Size:** S
**security_review:** required

**Acceptance Criteria:**

**Given** `bootstrap_completed_at IS NOT NULL` in the server config,
**When** `UpdateServerConfig` gRPC is called with a `matrix_user_id_claim` field in the request,
**Then** the RPC returns `FAILED_PRECONDITION` and the database is not modified

**Given** `bootstrap_completed_at IS NULL` (not yet bootstrapped),
**When** `UpdateServerConfig` gRPC is called with a `matrix_user_id_claim` field,
**Then** the update is accepted and saved normally

**Given** a post-bootstrap config update that changes only non-claim fields (e.g., `oidc_issuer`),
**When** `UpdateServerConfig` gRPC is called,
**Then** the update succeeds — the lock applies only to `matrix_user_id_claim`

**Given** ExUnit tests for the Core `UpdateServerConfig` handler,
**When** `make test-unit-elixir` runs,
**Then** the following test cases pass: claim-change blocked post-bootstrap, claim-change allowed pre-bootstrap, other fields changeable post-bootstrap

---

### Story 14.1b: Gateway API Validation + Admin UI Read-Only Display

As an instance admin,
I want the Gateway API to return a clear 400 error when `matrix_user_id_claim` is changed post-bootstrap, and the Admin UI to display the field as read-only,
So that admins receive immediate, actionable feedback without needing to understand the underlying gRPC error.

**Size:** S
**security_review:** required

**Acceptance Criteria:**

**Given** bootstrap has been completed (`bootstrap_completed_at IS NOT NULL`),
**When** `PATCH /api/v1/admin/config` is called with a `matrix_user_id_claim` value,
**Then** the server returns `400 M_FORBIDDEN` with `error: "matrix_user_id_claim cannot be changed after bootstrap"` (mapped from Core's `FAILED_PRECONDITION`)

**Given** an admin navigates to the Claim Mapping settings page in the Admin UI after bootstrap,
**When** the page loads,
**Then** `matrix_user_id_claim` is displayed as read-only text (not an editable `<input>`) and an info banner reads: "This claim cannot be changed after bootstrap."

**Given** the Bootstrap Wizard Step 3 (Claim Mapping),
**When** it renders,
**Then** an info text is shown: "The Matrix User ID claim cannot be changed after completing setup."

**Given** a Godog scenario in `gateway/features/claim_lock.feature`,
**When** `make test-integration` runs,
**Then** a POST-bootstrap PATCH attempt returns 400 and a pre-bootstrap PATCH succeeds

---

### Story 14.2a: Server Config Schema — oidc_directory_enabled + oidc_directory_endpoint

As an instance admin,
I want `oidc_directory_enabled` and `oidc_directory_endpoint` fields in the server config,
So that the OIDC directory integration can be toggled and configured without code changes.

**Size:** S
**security_review:** not-needed

**Acceptance Criteria:**

**Given** a new database migration,
**When** it runs,
**Then** `oidc_directory_enabled BOOLEAN DEFAULT FALSE` and `oidc_directory_endpoint TEXT` columns are added to the `server_config` table

**Given** `GET /api/v1/admin/config`,
**When** the endpoint is called,
**Then** `oidc_directory_enabled` and `oidc_directory_endpoint` are included in the response

**Given** `PATCH /api/v1/admin/config` with both fields,
**When** the request is processed,
**Then** the values are persisted and returned correctly in a subsequent GET

**Given** the Admin UI Config page,
**When** it loads,
**Then** a toggle for `oidc_directory_enabled` and a text field for `oidc_directory_endpoint` are displayed; the endpoint field is visible only when the toggle is enabled

**Given** a Godog scenario for the config round-trip,
**When** `make test-integration` runs,
**Then** the scenario "set oidc_directory_enabled + endpoint, read back" passes

---

### Story 14.2b: Gateway OIDC Directory Service + Cache + Rate Limit

As an instance admin,
I want the Gateway to fetch the OIDC user directory from the configured endpoint with caching and rate limiting,
So that Admin UI user searches can include OIDC users without overloading the OIDC provider.

**Size:** S
**security_review:** required

**Acceptance Criteria:**

**Given** `gateway/internal/admin/oidc_directory.go` is implemented,
**When** `oidc_directory_enabled: true` and the endpoint is reachable,
**Then** the service fetches the user list via HTTP Bearer auth, caches the result for 30 seconds, and enforces a rate limit of 5 requests per second per admin session

**Given** the OIDC endpoint is unreachable,
**When** the directory service is called,
**Then** it returns an empty list and logs a warning — no error is propagated to the caller

**Given** the configured `oidc_directory_endpoint` does not use HTTPS,
**When** the service validates the configuration,
**Then** the endpoint is rejected with a validation error

**Given** Go unit tests for the OIDC directory service,
**When** `make test-unit-go` runs,
**Then** the following test cases pass: cache hit (no second HTTP call), cache miss (HTTP call made), unreachable endpoint (empty list returned), rate limit enforcement

---

### Story 14.2c: Admin UI User Search OIDC Integration + "Not yet logged in" Badge

As an instance admin,
I want the Admin UI user search to merge results from the Nebu DB and the OIDC directory,
So that I can find and preview OIDC users who have never logged into Nebu.

**Size:** S
**security_review:** not-needed

**Acceptance Criteria:**

**Given** `oidc_directory_enabled: true`,
**When** an admin searches for a user who exists in the OIDC directory but has never logged into Nebu,
**Then** the user appears in the search results with a "Not yet logged in" badge and their Matrix User ID is shown as a computed preview (not yet stored in the DB)

**Given** `oidc_directory_enabled: false`,
**When** user search runs,
**Then** only Nebu DB users are returned — backward-compatible behavior with no OIDC calls made

**Given** the OIDC provider is temporarily unavailable,
**When** user search runs with directory integration enabled,
**Then** the search returns Nebu DB results only and shows a non-blocking warning banner: "OIDC directory temporarily unavailable"

**Given** a Playwright+Gherkin scenario in `e2e/features/oidc_directory_search.feature`,
**When** `make test-integration` runs,
**Then** the scenario "search finds OIDC-only user with Not yet logged in badge" passes

---

### Story 14.3a: BulkImportUsers gRPC RPC + Core Provisioning

As an instance admin,
I want a `BulkImportUsers` gRPC RPC in Core that provisions users from OIDC claim maps with the same flow as first login,
So that bulk user import produces identical user records to organic first-login provisioning.

**Size:** S
**security_review:** required

**Acceptance Criteria:**

**Given** `proto/core_service.proto` is updated,
**When** `make proto` runs,
**Then** `BulkImportUsers(BulkImportUsersRequest) returns (BulkImportUsersResponse)` is generated without errors; the request contains a list of OIDC claim maps and the response contains `imported`, `skipped`, and `failed` counts

**Given** `BulkImportUsers` is called with a list of OIDC user claim maps,
**When** Core processes each user,
**Then** for each user: a user record is created in PostgreSQL, Ed25519 + X25519 keypairs are generated, PII is encrypted — identical to the flow in `validate_token/2`

**Given** a user already exists in the Nebu DB (e.g., previously logged in),
**When** their claims appear in the import list,
**Then** their record is skipped (no duplicate, no error) and the response shows `skipped: N`

**Given** ExUnit tests for the Core handler,
**When** `make test-unit-elixir` runs,
**Then** the following test cases pass: single user import, duplicate skip, bulk import of 10 users, keypair generation correctness

---

### Story 14.3b: Bootstrap Wizard Step 4 UI — Preview + Import

As an instance admin,
I want a new Bootstrap Wizard Step 4 "User Import" that shows a preview of OIDC users and lets me trigger bulk import,
So that I can pre-provision all users during the initial setup without leaving the wizard.

**Size:** S
**security_review:** not-needed

**Acceptance Criteria:**

**Given** the Bootstrap Wizard renders,
**When** the admin reaches Step 4 (after Claim Mapping),
**Then** the "User Import" step is displayed with a "Import from OIDC" button

**Given** the admin clicks "Import from OIDC",
**When** the OIDC user list is fetched via the service from story 14.2b,
**Then** a preview table is shown with: display name, email, and computed Matrix User ID for each user

**Given** the preview table is shown,
**When** the admin clicks "Import all" or "Import selected",
**Then** `POST /api/v1/admin/bootstrap/import-users` is called and the result (imported/skipped/failed counts) is displayed

**Given** the OIDC provider does not expose a user list endpoint,
**When** the wizard renders Step 4,
**Then** the button is disabled and a message reads: "Provider does not support user listing"

**Given** a Playwright+Gherkin scenario in `e2e/features/bootstrap_import.feature`,
**When** `make test-integration` runs,
**Then** the scenarios "wizard step 4 displayed", "preview table loaded", and "import button clicked" pass

---

### Story 14.3c: SCIM 2.0 User Fetch + Progress Tracking

As an instance admin,
I want the import endpoint to support SCIM 2.0 user fetch and a live progress indicator during import,
So that large user imports from enterprise directories are reliable and observable.

**Size:** S
**security_review:** required

**Acceptance Criteria:**

**Given** `scim_enabled: true`, `scim_base_url`, and `scim_bearer_token` are configured in the server config,
**When** `POST /api/v1/admin/bootstrap/import-users` is called,
**Then** users are fetched via `GET /Users` (SCIM 2.0 RFC 7644) instead of the OIDC directory endpoint, and are imported with the same Core provisioning flow

**Given** an import is running,
**When** `GET /api/v1/admin/bootstrap/import-status` is polled,
**Then** the response contains `{imported, total, failed}` with the current live counts

**Given** the Bootstrap Wizard Step 4 import UI,
**When** an import is in progress,
**Then** a progress bar with live `imported / total` counts is shown (via SSE or polling)

**Given** Go unit tests for the SCIM fetch and mapping,
**When** `make test-unit-go` runs,
**Then** the following test cases pass: SCIM user fetch, SCIM-to-Nebu claim mapping, progress endpoint returns correct counts during import

---

### Story 14.4: GDPR Right to Erasure — End-to-End Verification

As a compliance officer,
I want to verify that deleting a user in Nebu correctly erases all PII and key material end-to-end,
So that GDPR Article 17 (Right to Erasure) can be attested with evidence.

**Size:** M
**security_review:** required

**Acceptance Criteria:**

**Given** a user exists with: display name, avatar URL, Ed25519 key, X25519 key, encrypted PII, session records, compliance access requests, and sent messages,
**When** `DELETE /api/v1/admin/users/{userId}` is called (or the equivalent DSGVO deletion flow),
**Then** the following are verified in a Godog scenario:
  - `users.display_name` → anonymized (`Deleted User`)
  - `users.avatar_url` → NULL
  - `user_keys.ed25519_public_key` → NULL / deleted
  - `user_keys.x25519_public_key` → NULL / deleted
  - `operational_pii` → record deleted or all fields NULLed
  - `sessions` → all sessions invalidated and deleted
  - `events` content NOT modified (messages remain for room history — by design, per ADR-007)
  - `audit_log` contains a `gdpr_deletion` event for the user

**Given** the deleted user's Matrix User ID (`@alice:nebu.example`),
**When** `GET /_matrix/client/v3/profile/@alice:nebu.example` is called,
**Then** `displayname` returns `"Deleted User"` and `avatar_url` is absent

**Given** the deletion has been performed,
**When** the deleted user attempts to log in via OIDC,
**Then** login fails with `403 M_USER_DEACTIVATED` (the Matrix User ID is permanently deactivated)

**Given** a Godog scenario `gateway/features/gdpr_deletion.feature`,
**When** `make test-integration` runs,
**Then** all GDPR deletion scenarios pass (including the room-history-preservation assertion)

**Given** `docs/compliance/gdpr-deletion-runbook.md`,
**When** it is read,
**Then** it documents: deletion procedure, evidence items for GDPR audit, known limitations (messages in room history are not deleted — per Matrix spec design)

---

## Epic 15: Matrix Spaces and Room Moderator Feature Completeness

**Goal:** Nebu implementiert Matrix Spaces vollständig (MSC1772 + MSC2946 + MSC3083); Room Moderator Features werden mit /agent-oracle auf Vollständigkeit geprüft und fehlende Endpoints implementiert. Element Web und FluffyChat können Spaces erstellen, navigieren und nutzen.

**Pre-Epic-TODO:** /agent-oracle Audit der Room Moderator Features (Story 15-0) — dieser Audit bestimmt den Scope von Story 15-11 bis 15-N.

---

### Story 15.0: Oracle Audit — Room Moderator Feature Completeness

As a developer,
I want to run `/agent-oracle` against the current implementation to identify which Room Moderator API endpoints are missing or incomplete,
So that Story 15-11 has a clear, spec-backed scope.

**Size:** S

**Acceptance Criteria:**

**Given** the current gateway routes and Core handlers,
**When** `/agent-oracle` audits all room moderation endpoints (kick, ban, unban, forget, redact, power level changes, invite accept/reject, room alias management),
**Then** a gap report is produced in `_bmad-output/implementation-artifacts/oracle-room-moderator-audit-{date}.md`

**Given** the gap report,
**When** it is reviewed,
**Then** each finding is classified as: PASS (implemented + spec-correct), DEVIATION (implemented but wrong), MISSING (not implemented), OUT-OF-SCOPE (not planned for Nebu)

**Given** the gap report is committed,
**When** Story 15-11 is created,
**Then** its acceptance criteria are derived directly from the oracle report's DEVIATION and MISSING findings

---

### Story 15.1: createRoom Extension — creation_content.type: m.space

As a Matrix client user,
I want to create a Space by passing `creation_content.type: "m.space"` to `POST /createRoom`,
So that my Space appears in Element Web's Space sidebar.

**Size:** S
**security_review:** not-needed

**Acceptance Criteria:**

**Given** a `POST /_matrix/client/v3/createRoom` request with `creation_content: { "type": "m.space" }`,
**When** the request is processed,
**Then** the room is created and the stored `m.room.create` event has `content.type: "m.space"`

**Given** a `/sync` response for the Space creator,
**When** `rooms.join[spaceId].state.events` is inspected,
**Then** the `m.room.create` event contains `content.type: "m.space"`

**Given** `POST /createRoom` without `creation_content.type`,
**When** the request is processed,
**Then** behavior is unchanged (no `type` field in `m.room.create`) — backward compatible

**Given** `creation_content.type` is an unknown string (e.g., `"m.custom.type"`),
**When** the request is processed,
**Then** the room is created successfully (forward-compatible — only `"m.space"` has special Nebu semantics)

**Given** `creation_content.type: "m.space"` and no `power_level_content_override`,
**When** the room is created,
**Then** the default power levels include: `events["m.space.child"]: 50`, `events["m.space.parent"]: 50`

---

### Story 15.2: PostgreSQL Index for Space BFS

As a developer,
I want database indexes optimized for the BFS traversal algorithm used in `GET /hierarchy`,
So that Space hierarchy queries are fast even for deep or wide Space trees.

**Size:** S
**security_review:** not-needed

**Acceptance Criteria:**

**Given** `gateway/migrations/000046_space_hierarchy_index.up.sql` exists,
**When** the migration runs,
**Then** the following indexes are created:
  - `idx_events_space_child` on `events (room_id, state_key) WHERE event_type = 'm.space.child'`
  - `idx_events_space_parent` on `events (state_key) WHERE event_type = 'm.space.parent'`

**Given** the migration runs on an existing database with events,
**When** `EXPLAIN ANALYZE` runs on a Space child lookup query,
**Then** the query plan uses `idx_events_space_child` (Index Scan, not Seq Scan)

**Given** `gateway/migrations/000046_space_hierarchy_index.down.sql` exists,
**When** it runs,
**Then** both indexes are dropped cleanly

---

### Story 15.3: m.space.child State Event — Whitelist + Core Validation

As a Space admin,
I want to manage child rooms in a Space via `PUT /rooms/{spaceId}/state/m.space.child/{childRoomId}`,
So that I can build and maintain Space hierarchies.

**Size:** M
**security_review:** optional

**Acceptance Criteria:**

**Given** `gateway/internal/middleware/state_event_whitelist.go`,
**When** it is inspected,
**Then** `"m.space.child"` is in the allowed state event types list

**Given** a PUT request to `/state/m.space.child/{childRoomId}` with valid content `{"via": ["nebu.example"], "suggested": false}`,
**When** the request is processed by a user with Power Level ≥ state_default in the Space,
**Then** the event is stored and appears in subsequent `/sync` responses

**Given** a PUT request with `content: {}` (empty — removes child link),
**When** the request is processed,
**Then** the event is stored with empty content (effectively unlinking the child) — no error

**Given** a PUT request with `content: {"via": []}` (empty via — invalid),
**When** Core validates the event,
**Then** the response is `400 M_BAD_JSON` with `error: "via must not be empty"`

**Given** a PUT request with `order: "abc\x01def"` (non-ASCII characters),
**When** Core validates the event,
**Then** the response is `400 M_BAD_JSON` with `error: "order contains invalid characters"`

**Given** a user with Power Level < state_default,
**When** they attempt to set `m.space.child`,
**Then** the response is `403 M_FORBIDDEN`

---

### Story 15.4: m.space.parent State Event — Whitelist + Security Check

As a room admin,
I want to link my room to a parent Space via `PUT /rooms/{roomId}/state/m.space.parent/{parentSpaceId}`,
So that clients can show the room as part of the Space hierarchy.

**Size:** M
**security_review:** required

**Acceptance Criteria:**

**Given** `gateway/internal/middleware/state_event_whitelist.go`,
**When** it is inspected,
**Then** `"m.space.parent"` is in the allowed state event types list

**Given** a PUT request with `content: {"via": ["nebu.example"], "canonical": true}` by a user who is a member of both the child room and the parent Space with sufficient PL,
**When** the request is processed,
**Then** the event is stored and `403` is NOT returned

**Given** a PUT request by a user who has sufficient PL in the child room but is NOT a member of the parent Space,
**When** Core validates the event,
**Then** the response is `403 M_FORBIDDEN` with `error: "Sender is not a member of the parent space"`

**Given** a PUT request where `parentSpaceId` references a room that does not exist,
**When** Core validates the event,
**Then** the response is `404 M_NOT_FOUND`

**Given** a PUT request with `content: {}` (removes parent link),
**When** the request is processed,
**Then** the event is stored with empty content — no security check required for removal

---

### Story 15.5a: Core — check_join_allowed Restricted Rule (ExUnit)

As a Space admin,
I want `RoomGenServer.check_join_allowed/2` to correctly evaluate `join_rule: "restricted"` using ETS membership lookups,
So that the Core enforcement logic is unit-tested in isolation before integration tests are added.

**Size:** S
**security_review:** required

**Acceptance Criteria:**

**Given** `RoomGenServer.check_join_allowed/2` is called with `join_rule: "restricted"` and a user who is a member of the Space referenced in the `allow` array,
**When** the join is evaluated,
**Then** the result is `:ok` and the membership check is performed via `SessionManager.is_member?/2` (ETS lookup, no DB roundtrip)

**Given** the same restricted room and a user who is NOT a member of the Space in the `allow` array,
**When** the join is evaluated and the user has no pending invitation,
**Then** the result is `{:error, :forbidden}`

**Given** a user with a pending invitation to the restricted room,
**When** the join is evaluated regardless of Space membership,
**Then** the result is `:ok` — invitations override the restricted rule

**Given** `allow[].type` contains an unknown type (not `"m.room_membership"`),
**When** the join is evaluated,
**Then** the unknown entry is ignored (no grant, no error)

**Given** ExUnit tests for `check_join_allowed/2`,
**When** `make test-unit-elixir` runs,
**Then** all four cases above pass: Space member joins, non-member rejected, invitation overrides, unknown type ignored

---

### Story 15.5b: Integration Test — Restricted Join Godog Scenario

As a Space admin,
I want Godog integration scenarios that verify the full HTTP-level restricted join flow end-to-end,
So that the gateway + core interaction is continuously tested in CI.

**Size:** S
**security_review:** not-needed

**Acceptance Criteria:**

**Given** `gateway/features/restricted_join.feature` exists,
**When** `make test-integration` runs,
**Then** the following scenarios pass:
  - "Space member joins restricted room without invitation" → 200 OK
  - "Non-Space member cannot join restricted room" → 403 M_FORBIDDEN
  - "User with invitation joins restricted room despite not being Space member" → 200 OK

**Given** the Godog step definitions for the restricted join scenarios,
**When** they are inspected,
**Then** no cookie forging or DB seeding shortcuts are used — real Matrix API calls are made via the full gateway + core stack

---

### Story 15.6a: Proto — GetSpaceHierarchy RPC + Message Types

As a developer,
I want the `GetSpaceHierarchy` RPC and its message types defined in the proto contract and generated for both Go and Elixir,
So that Gateway and Core can be implemented against a stable, compiled interface.

**Size:** S
**security_review:** not-needed

**Acceptance Criteria:**

**Given** `proto/core_service.proto` is updated,
**When** `make proto` runs,
**Then** `GetSpaceHierarchyRequest`, `SpaceSummaryRoom`, `GetSpaceHierarchyResponse`, and the `GetSpaceHierarchy` RPC are generated for Go and Elixir without errors

**Given** the generated Go stubs,
**When** `go build ./...` runs,
**Then** the build succeeds with no errors

**Given** the generated Elixir stubs,
**When** `mix compile` runs,
**Then** compilation succeeds with no errors

---

### Story 15.6b: Core — SpaceHierarchy BFS Module (ExUnit)

As a Matrix client,
I want the `Nebu.RoomManager.SpaceHierarchy` module to implement BFS traversal over `m.space.child` state events with visibility filtering and pagination,
So that the hierarchy logic is unit-tested in isolation before the gRPC handler wires it up.

**Size:** S
**security_review:** not-needed

**Acceptance Criteria:**

**Given** `Nebu.RoomManager.SpaceHierarchy.get_hierarchy/3` is called with a Space root and a user ID,
**When** the Space has 3 child rooms (2 regular, 1 sub-space with 2 children),
**Then** the BFS response contains all 6 rooms in correct BFS order with `room_type: "m.space"` for the sub-space

**Given** `max_depth: 1`,
**When** the Space has sub-spaces,
**Then** only direct children are returned (sub-space itself included, its children are not)

**Given** `suggested_only: true`,
**When** only 2 of 5 children have `"suggested": true`,
**Then** only those 2 children are returned

**Given** the BFS traversal encounters a private room the requesting user cannot see,
**When** that room is traversed,
**Then** the room is excluded from the response but its children are still traversed

**Given** `limit: 2` and 5 total rooms,
**When** the BFS runs,
**Then** a pagination token is returned and providing it as `from_token` resumes the traversal from the correct position

**Given** ExUnit tests for `SpaceHierarchy`,
**When** `make test-unit-elixir` runs,
**Then** all test cases above pass

---

### Story 15.6c: Core — gRPC Handler + Pagination Token

As a Matrix client,
I want the Core gRPC handler for `GetSpaceHierarchy` to delegate to the BFS module and serialize BFS state as an opaque pagination token,
So that paginated hierarchy requests resume correctly without re-traversing already-visited nodes.

**Size:** S
**security_review:** not-needed

**Acceptance Criteria:**

**Given** `Nebu.Server.handle/2` receives a `GetSpaceHierarchy` request,
**When** it is processed,
**Then** the handler delegates to `SpaceHierarchy.get_hierarchy/3` and serializes the BFS cursor state as an opaque Base64 token in `next_batch_token`

**Given** a `GetSpaceHierarchy` request with a non-empty `from_token`,
**When** the handler processes it,
**Then** the BFS state is deserialized from the token and traversal continues from the correct position

**Given** the space root room does not exist,
**When** `GetSpaceHierarchy` is called,
**Then** the RPC returns `NOT_FOUND`

**Given** ExUnit integration tests for the handler,
**When** `make test-unit-elixir` runs,
**Then** the following test cases pass: 2-page pagination (correct rooms on each page), empty space (0 children), space root not found → NOT_FOUND

---

### Story 15.7: GET /hierarchy — Go Gateway Handler + Pagination

As a Matrix client,
I want the Go Gateway to expose `GET /_matrix/client/v1/rooms/{roomId}/hierarchy` with correct query parameter handling,
So that Element Web and FluffyChat can retrieve Space hierarchies.

**Size:** M
**security_review:** optional

**Acceptance Criteria:**

**Given** `gateway/cmd/gateway/main.go`,
**When** it is inspected,
**Then** the route `GET /_matrix/client/v1/rooms/:roomId/hierarchy` is registered with the auth middleware

**Given** a GET request to `/hierarchy` with `limit=10&max_depth=2&suggested_only=true`,
**When** the handler processes the request,
**Then** the query parameters are correctly passed to the `GetSpaceHierarchyRequest` gRPC call

**Given** `suggested_only=not-a-bool` in the query string,
**When** the handler processes the request,
**Then** the response is `400 M_BAD_PARAM`

**Given** `limit=-1` in the query string,
**When** the handler processes the request,
**Then** the response is `400 M_BAD_PARAM`

**Given** `limit=2000` (exceeds server maximum of 1000),
**When** the handler processes the request,
**Then** the server caps the limit to 1000 (no error — server-side clamp per spec)

**Given** the Core response includes `next_batch_token`,
**When** the Gateway formats the JSON response,
**Then** the response matches the Matrix spec format with `rooms: [...]` and `next_batch: "<token>"`

**Given** the user is not a member of the requested Space and the Space is not public,
**When** `GET /hierarchy` is called,
**Then** the response is `403 M_FORBIDDEN`

---

### Story 15.8: Capabilities Update — Room Versions 6–10

As a Matrix client,
I want `GET /_matrix/client/v3/capabilities` to advertise Room Versions 6 through 10 with default version 10,
So that Element Web shows Restricted Room join rule options in the Room Settings.

**Size:** S
**security_review:** not-needed

**Acceptance Criteria:**

**Given** `GET /_matrix/client/v3/capabilities`,
**When** the response is inspected,
**Then** `capabilities.m.room_versions` contains:
  - `default: "10"`
  - `available: {"6": "stable", "7": "stable", "8": "stable", "9": "stable", "10": "stable"}`

**Given** a Godog scenario `gateway/features/capabilities.feature`,
**When** `make test-integration` runs,
**Then** the scenario "Capabilities advertise room versions 6–10" passes

**Given** the previous capabilities response (before this story),
**When** compared to the new response,
**Then** `m.change_password: { "enabled": false }` is unchanged — no regressions

---

### Story 15.9a: Playwright E2E — Space erstellen + Sidebar-Anzeige

As a Space admin,
I want Playwright+Gherkin E2E scenarios that prove a Space can be created via the Matrix client and appears correctly in the Space sidebar,
So that Space creation is continuously validated in CI against a real stack.

**Size:** S
**security_review:** not-needed

**Acceptance Criteria:**

**Given** `e2e/features/spaces_create.feature` exists,
**When** `make test-integration` runs (Playwright+Cucumber),
**Then** the following scenarios pass:
  - "Admin creates a Space and verifies it appears in the Space sidebar"
  - "Space sidebar distinguishes Spaces from regular rooms"

**Given** the Playwright scenario for Space creation,
**When** it runs,
**Then** no cookie forging or DB seeding shortcuts are used — the test uses real OIDC login and real Matrix API calls

**Given** the E2E scenarios pass,
**When** the CI pipeline runs,
**Then** the Playwright+Cucumber job is green with all `spaces_create.feature` scenarios in the report

---

### Story 15.9b: Playwright E2E — Kind-Raum hinzufügen + Restricted Join

As a Space admin,
I want Playwright+Gherkin E2E scenarios that prove a child room can be added to a Space and that restricted join rules work correctly via a real browser session,
So that the full Space membership flow is continuously tested in CI.

**Size:** S
**security_review:** not-needed

**Acceptance Criteria:**

**Given** `e2e/features/spaces_restricted.feature` exists and depends on Space creation from story 15.9a,
**When** `make test-integration` runs (Playwright+Cucumber),
**Then** the following scenarios pass:
  - "Admin adds a child room to the Space via Room Settings"
  - "Space member joins restricted room without explicit invitation"
  - "Non-Space member cannot join restricted room"

**Given** the Playwright scenarios for restricted join,
**When** they run,
**Then** no cookie forging or DB seeding shortcuts are used — real OIDC login and real Matrix API calls are made

**Given** the E2E scenarios pass,
**When** the CI pipeline runs,
**Then** the Playwright+Cucumber job is green with all `spaces_restricted.feature` scenarios in the report

---

### Story 15.10a: Admin UI — /admin/spaces List Page

As an instance admin,
I want a `/admin/spaces` page in the Admin UI that lists all Spaces on the server with search and pagination,
So that I can get an overview of all Spaces without using a Matrix client.

**Size:** S
**security_review:** not-needed

**Acceptance Criteria:**

**Given** I navigate to `/admin/spaces` in the Admin UI,
**When** the page loads,
**Then** a table of all Spaces is displayed with columns: Space name, member count, child room count

**Given** I type a search term into the search field,
**When** the debounced search fires,
**Then** the table filters to matching Spaces

**Given** there are more Spaces than the page size,
**When** I click "Load more",
**Then** additional Spaces are appended to the list

**Given** there are no Spaces on the server,
**When** the page loads,
**Then** a "No spaces found" empty state is displayed

**Given** a Playwright+Gherkin scenario in `e2e/features/admin_spaces_list.feature`,
**When** `make test-integration` runs,
**Then** the scenario "navigate to /admin/spaces, spaces list displayed" passes

---

### Story 15.10b: Admin UI — Space Detail + Kind-Verwaltung

As an instance admin,
I want a Space detail panel that shows Space metadata and child rooms, with the ability to add and remove child rooms,
So that I can maintain Space structure directly from the Admin UI.

**Size:** S
**security_review:** optional

**Acceptance Criteria:**

**Given** I click on a Space in the `/admin/spaces` list,
**When** the detail panel opens,
**Then** Space name, topic, member count, and a list of child rooms with their `suggested` flag are displayed

**Given** I click "Add Child Room" in the detail panel and select a room from the search results,
**When** I confirm the action,
**Then** `PUT /state/m.space.child/{childRoomId}` is called with `{"via": [...], "suggested": false}` and the child list refreshes

**Given** I click the remove button next to a child room,
**When** I confirm the removal,
**Then** `PUT /state/m.space.child/{childRoomId}` is called with empty content and the child is removed from the list

**Given** Playwright+Gherkin scenarios in `e2e/features/admin_spaces_detail.feature`,
**When** `make test-integration` runs,
**Then** the following scenarios pass: view detail, add child, remove child

---

### Story 15.11: Admin API — /api/admin/v1/spaces CRUD

As an instance admin,
I want REST endpoints for Space management in the Admin API,
So that automation tools and external integrations can manage Spaces programmatically.

**Size:** M
**security_review:** required

**Acceptance Criteria:**

**Given** the Admin API OpenAPI spec is updated,
**When** `make gen-api` runs,
**Then** the following routes are generated: `GET /api/admin/v1/spaces`, `GET /api/admin/v1/spaces/{spaceId}`, `POST /api/admin/v1/spaces/{spaceId}/children`, `DELETE /api/admin/v1/spaces/{spaceId}/children/{childId}`

**Given** `GET /api/admin/v1/spaces`,
**When** the endpoint is called with a valid admin token,
**Then** a paginated list of all rooms with `room_type: "m.space"` is returned

**Given** `POST /api/admin/v1/spaces/{spaceId}/children` with `{"room_id": "!childId:nebu.example", "suggested": true}`,
**When** the endpoint is called,
**Then** Core sets `m.space.child` state event in the Space on behalf of the admin user — identical to the Matrix client flow

**Given** `DELETE /api/admin/v1/spaces/{spaceId}/children/{childId}`,
**When** the endpoint is called,
**Then** Core sets `m.space.child` state event with empty content (removes the link)

**Given** a Godog scenario `gateway/features/admin_spaces_api.feature`,
**When** `make test-integration` runs,
**Then** all CRUD scenarios pass including the auth check (non-admin returns 403)

---

### Story 15.12: Room Moderator Gap Fixes (Oracle-Driven)

As a Matrix client user,
I want all Room Moderator API endpoints identified by the oracle audit (Story 15-0) to be correctly implemented,
So that room moderation works fully with Element Web and FluffyChat.

**Size:** M (scope refined after Story 15-0 oracle audit)
**security_review:** required

**Acceptance Criteria:**

**Given** the oracle audit report from Story 15-0,
**When** all DEVIATION and MISSING findings are addressed,
**Then** a follow-up oracle audit returns 0 DEVIATION and 0 MISSING findings for room moderator endpoints

**Given** each fixed endpoint,
**When** a Godog or Element Web E2E scenario covers it,
**Then** the scenario is green in CI

**Note:** Concrete acceptance criteria for this story are defined after Story 15-0 is complete.

---

## Epic 16: Nebu Project Website — nebuchat.eu

**Goal:** Eine öffentlich zugängliche Projekt-Website unter `nebuchat.eu`, gebaut mit EasyWebsite Easy Mode (`opencode`-Theme + CSS-Variablen-Overrides für Nebu-Branding), die Nebu präsentiert, die arc42-Architektur-Dokumentation zugänglich macht und Betreibern den Einstieg ermöglicht. Die Website lebt unter `website/` im Haupt-Repo (nebu-chat). Kein Node.js/Next.js — EasyWebsite Easy Mode.

**Pre-Epic-TODO:** Nebu Brand-Farbe(n) für CSS-Variable-Overrides festlegen — muss vor Story 16.2 entschieden sein.

**Technology Decision:** EasyWebsite Easy Mode + `opencode`-Theme. CSS-Variablen-Overrides für Logo und Primärfarbe. Kein Developer Mode (kein Next.js-Projekt im Repo). Separates Repo erst wenn eine eigenständige Nebu-Chat-App entsteht.

---

### Story 16.1: EasyWebsite Setup + GitLab CI Pipeline

As a developer,
I want EasyWebsite configured with the `opencode` theme under `website/` in the monorepo, with a `pages` job in `.gitlab-ci.yml`,
So that the foundation is in place for all subsequent content stories to deploy without pipeline changes.

**Size:** S
**security_review:** not-needed

**Acceptance Criteria:**

**Given** the nebu-chat repository,
**When** `ls website/` is inspected,
**Then** the following structure exists:
- `website/dokument/` — EasyWebsite content root
- `website/dokument/index.md` — Placeholder home page with heading "Nebu"
- `website/dokument/_meta.yaml` — Navigation configuration

**Given** the EasyWebsite configuration file under `website/`,
**When** it is inspected,
**Then** `theme: opencode` is configured

**Given** `.gitlab-ci.yml` at the repo root,
**When** it is inspected,
**Then** a `pages` job is defined that:
- builds EasyWebsite from `website/`
- writes output to `public/` (GitLab Pages convention)
- only runs on the `main` branch

**Given** a commit to `main`,
**When** the CI pipeline completes,
**Then** the GitLab Pages URL returns HTTP 200, the placeholder page renders with the opencode theme, and there are no browser console errors

**Given** the `pages` job in CI,
**When** it completes,
**Then** total job duration is < 5 minutes (NFR-16.1)

**Given** the EasyWebsite build output,
**When** inspected,
**Then** the site is statically rendered HTML — no server-side execution required (NFR-16.3)

---

### Story 16.2: Landing Page + Nebu Brand Identity

As a visitor to nebuchat.eu,
I want a landing page that clearly presents what Nebu is and why it matters, styled with Nebu's logo and brand colors,
So that I immediately understand if Nebu solves my problem.

**Size:** M
**security_review:** not-needed

**Acceptance Criteria:**

**Given** `website/dokument/index.md` with landing page content,
**When** the page is rendered,
**Then** the following sections are present:
- Hero with core message (e.g. "Self-hosted Matrix chat — your data, your rules")
- Value propositions: Matrix-compatible, data-sovereign, no Redis/NATS/Kafka, Apache 2.0
- Tech stack overview (Go + Elixir/OTP)
- Stakeholder personas (Operator Marcus, End User Leila, Compliance Officer, Admin Kai)
- Links to Getting Started guide and Architecture documentation

**Given** `website/dokument/assets/nebu-logo.svg` exists,
**When** the site renders,
**Then** the Nebu logo appears in the header (via the `logo` property in the theme configuration)

**Given** a CSS override file (e.g. `website/dokument/custom.css`) with Nebu brand color variables,
**When** the site renders,
**Then** the primary color is no longer `#1544ff` (opencode default) but reflects the defined Nebu brand color

**Given** a Playwright screenshot test `e2e/features/website_smoke.feature`,
**When** `make test-integration` runs,
**Then** the scenario "Landing page renders with Nebu logo and custom primary color" passes — catching CSS variable regressions on future changes

---

### Story 16.3: Architecture Documentation — arc42 + ADRs

As a developer or architect evaluating Nebu,
I want all arc42 sections (01–12) and ADRs (ADR-001 to ADR-015) browseable on the website,
So that I can understand Nebu's architecture and key decisions without digging through the Git repo.

**Size:** M
**security_review:** not-needed

**Acceptance Criteria:**

**Given** the `pages` CI job in `.gitlab-ci.yml`,
**When** it is inspected,
**Then** it copies `docs/architecture/` to `website/dokument/architecture/` before running the EasyWebsite build — no committed copy under `website/`, `docs/architecture/` remains the single source of truth (NFR-16.2)

**Given** `website/dokument/_meta.yaml`,
**When** the site renders,
**Then** an "Architecture" section appears in the sidebar with:
- sub-entries for arc42 sections 01–12
- a dedicated "Architecture Decision Records" sub-section listing all 15 ADRs

**Given** a visitor navigates to `/architecture/`,
**When** the page renders,
**Then** all 12 arc42 sections are linked and render without 404 errors

**Given** a visitor navigates to `/architecture/adr/`,
**When** the page renders,
**Then** all 15 ADRs (ADR-001 to ADR-015) are listed and each opens without 404 errors

**Given** `docs/architecture/adr/ADR-001-elixir-otp.md` is updated in the repo,
**When** the CI pipeline runs on `main`,
**Then** the updated content appears on the website — no manual copy required

---

### Story 16.4: Operator Getting-Started Guide

As an operator wanting to self-host Nebu,
I want a step-by-step Getting Started guide on the website,
So that I can get Nebu running with Docker Compose and OIDC and complete my first login in under 30 minutes.

**Size:** S
**security_review:** not-needed

**Acceptance Criteria:**

**Given** `website/dokument/getting-started/index.md`,
**When** it is rendered,
**Then** it contains the following sections:
- Prerequisites (Docker, Docker Compose, OIDC provider or Keycloak)
- Clone + Setup (`git clone`, `make setup`)
- Configuration (OIDC_ISSUER, DB_URL, secrets)
- First Start (`make dev`)
- Verification (health check URL, first Matrix client login)
- Common Troubleshooting (≥ 3 common failure scenarios with resolution steps)

**Given** `website/dokument/_meta.yaml`,
**When** the site renders,
**Then** "Getting Started" appears as a top-level navigation entry

**Given** a new operator with no prior Nebu knowledge,
**When** they follow the guide end-to-end,
**Then** they can reach the Admin UI and complete the first OIDC login without consulting additional documentation — validated via a manual usability pass by Phil before the story is marked done

---

### Story 16.5: Custom Domain nebuchat.eu + TLS

As a visitor,
I want the Nebu project website to be reachable at https://nebuchat.eu,
So that the site has a professional, memorable URL with valid TLS.

**Size:** S
**security_review:** not-needed

**Acceptance Criteria:**

**Given** the GitLab Pages Custom Domain configuration for the project,
**When** it is inspected,
**Then** `nebuchat.eu` is listed as a verified custom domain with a Let's Encrypt TLS certificate (NFR-16.4)

**Given** the DNS configuration for nebuchat.eu,
**When** a DNS lookup for `nebuchat.eu` is performed,
**Then** a CNAME record points to the GitLab Pages endpoint (or an A record if CNAME is not permitted at the apex)

**Given** the site is deployed and DNS has propagated,
**When** `https://nebuchat.eu` is visited in a browser,
**Then** the Nebu landing page renders with a valid TLS certificate and no certificate warnings

**Given** `http://nebuchat.eu` (without TLS),
**When** visited,
**Then** the request redirects to `https://nebuchat.eu`

**Given** the GitLab Pages deployment,
**When** the CI pipeline completes,
**Then** the website is accessible at both the GitLab Pages default URL and `https://nebuchat.eu`

**Note:** DNS configuration (CNAME/A record) must be set by the domain owner in the nebuchat.eu registrar. Story acceptance requires DNS propagation to complete.

---

## Epic: full-elixir-stack — Consolidation to Pure Elixir/OTP (Remove Go Layer)

**Goal:** Remove the Go gateway and media gateway entirely. All Matrix Client-Server API endpoints, the media gateway, and the Admin UI migrate to Elixir/OTP (Plug + Bandit + Phoenix LiveView). OIDC token validation moves into the Elixir request pipeline via `assent`. Result: one deployment artefact, one toolchain, zero gRPC hops on the hot path.

**ADR:** `tmp/no-go-adr.md` (Status: Accepted, 2026-06-17)

**Branch:** `feature/full-elixir-stack`

**Implementation order (dependency-driven):**
1. `elixir-http-foundation` — Bandit + Plug pipeline skeleton (no Go replacement yet)
2. `oidc-middleware-migration` — `assent` OIDC validation Plug, replace Go OIDC
3. `matrix-api-migration` — All `/_matrix/client/v3/*` in Elixir, remove Go gateway
4. `media-gateway-migration` — Upload/download/Range/S3-stream/URL-preview in Elixir, remove Go media gateway
5. `admin-ui-migration` — Phoenix LiveView Admin UI, remove Go admin backend
6. `go-removal-cleanup` — Delete Go source, Dockerfiles, CI steps, OpenTofu Go targets

---

### Story: elixir-http-foundation

As a Nebu operator,
I want the Elixir/OTP core to expose a Plug + Bandit HTTP server with baseline middleware,
So that subsequent stories can add routes incrementally without setting up the HTTP layer from scratch.

**Size:** S
**security_review:** not-needed

**Acceptance Criteria:**

1. **Given** `make dev` brings up the stack,
   **When** `GET http://core:4000/health` is called,
   **Then** `200 OK` with body `{"status":"ok"}` is returned by Bandit (not by Go).

2. **Given** any HTTP request to Bandit,
   **When** it is processed,
   **Then** the response includes a `X-Request-Id` header with a UUID-v4 value.

3. **Given** any HTTP request to Bandit,
   **When** it is processed,
   **Then** a structured log line is emitted at `info` level containing `method`, `path`, `status`, `duration_ms`, and `request_id`.

4. **Given** a request from a browser (CORS preflight `OPTIONS` with `Origin: http://localhost`),
   **When** it arrives at Bandit,
   **Then** the response includes `Access-Control-Allow-Origin` and `Access-Control-Allow-Methods` headers.

5. **Given** the Elixir umbrella project,
   **When** it compiles,
   **Then** Bandit starts on port `4000` and Cowboy is not a dependency.

**Acceptance Tests:**

### Tests written FIRST (before implementation code):

1. **`test/http_foundation_test.exs`** — ExUnit integration test (hits real Bandit)
   - Given: Bandit started on port 4000
   - When: `GET /health`
   - Then: `200`, body `%{"status" => "ok"}`, `X-Request-Id` header present

2. **`test/cors_plug_test.exs`** — ExUnit unit test (Plug.Test)
   - Given: OPTIONS preflight with `Origin: http://localhost`
   - When: routed through the Plug pipeline
   - Then: response contains CORS allow headers

---

### Story: oidc-middleware-migration

As a Nebu user,
I want my Bearer token to be validated by the Elixir layer directly against the OIDC provider's JWKS endpoint,
So that OIDC validation no longer requires a trust delegation from Go.

**Size:** M
**security_review:** required

**Acceptance Criteria:**

1. **Given** a valid Keycloak-issued Bearer token,
   **When** a protected endpoint is called in Elixir,
   **Then** the request proceeds and the user's Matrix ID is available in `conn.assigns.current_user`.

2. **Given** an expired Bearer token,
   **When** a protected endpoint is called,
   **Then** `401 Unauthorized` with `{"errcode":"M_UNKNOWN_TOKEN","error":"Access token has expired"}` is returned.

3. **Given** a tampered (invalid signature) Bearer token,
   **When** a protected endpoint is called,
   **Then** `401 Unauthorized` with `M_UNKNOWN_TOKEN` is returned.

4. **Given** no `Authorization` header,
   **When** a protected endpoint is called,
   **Then** `401 Unauthorized` with `{"errcode":"M_MISSING_TOKEN","error":"Missing access token"}` is returned.

5. **Given** the OIDC provider's JWKS endpoint,
   **When** the application starts,
   **Then** the JWKS keys are fetched and cached; cache TTL is configurable via `NEBU_OIDC_JWKS_TTL` (default: 300s).

6. **Given** the Go gateway is still running,
   **When** this story is complete,
   **Then** Go's OIDC middleware is disabled (pass-through) — all token validation happens in Elixir.

**Acceptance Tests:**

### Tests written FIRST (before implementation code):

1. **`test/oidc_plug_test.exs`** — ExUnit unit test (Plug.Test, mocked JWKS)
   - Given: mock JWKS returns a valid public key
   - When: request with a validly-signed JWT arrives
   - Then: `conn.assigns.current_user` is set, request passes through

2. **`test/oidc_plug_expired_test.exs`** — ExUnit unit test
   - Given: expired JWT (exp in the past)
   - When: routed through the OIDC Plug
   - Then: `401` with `M_UNKNOWN_TOKEN`

3. **`gateway/features/oidc-middleware-migration.feature`** — Godog integration test
   - Given: real Keycloak token obtained via Authorization Code + PKCE
   - When: `GET /_matrix/client/v3/sync` is called with that token via Elixir
   - Then: `200` (or valid Matrix error), Go OIDC middleware is bypassed

---

### Story: matrix-api-migration

As a Matrix client,
I want all `/_matrix/client/v3/*` endpoints served directly from Elixir/OTP,
So that the `/sync` long-polling connection is a BEAM process with no Go→Elixir gRPC hop.

**Size:** L
**security_review:** required

**Acceptance Criteria:**

1. **Given** all Matrix endpoints listed in CLAUDE.md (login, logout, sync, send, messages, createRoom, join, typing, receipt, profile, presence, MSC2965),
   **When** each is called via the Elixir router,
   **Then** each returns the same response shape as the previous Go implementation (contract parity).

2. **Given** a Matrix client with 1000 concurrent `/sync` long-polling connections,
   **When** measured over 60 seconds,
   **Then** median latency for event delivery is ≤ the baseline measured against the Go gateway (no regression).

3. **Given** the Go gateway container,
   **When** this story is complete,
   **Then** the Go gateway is removed from `docker-compose.yml` and the routing goes directly to Elixir.

4. **Given** the existing Godog integration test suite,
   **When** run against the Elixir router,
   **Then** all previously passing scenarios still pass.

5. **Given** the MSC2965 OIDC discovery endpoints (`/auth_issuer`, `/auth_metadata`),
   **When** called via the Elixir router,
   **Then** they return the correct issuer and metadata from `NEBU_OIDC_ISSUER`.

**Acceptance Tests:**

### Tests written FIRST (before implementation code):

1. **`gateway/features/matrix-api-migration.feature`** — Godog integration test (one scenario per endpoint group)
   - Given: Elixir router handling requests (Go gateway removed from compose)
   - When: each Matrix endpoint is exercised
   - Then: response shape matches Matrix spec

2. **`test/sync_bandit_test.exs`** — ExUnit concurrent connection test
   - Given: 50 clients with open `/sync` connections
   - When: a message is sent to a room
   - Then: all 50 clients receive the event within 500ms

---

### Story: media-gateway-migration

As a Matrix client,
I want media upload and download handled directly by Elixir,
So that media access control is a local function call (no cross-process gRPC hop) and there is one fewer Go service.

**Size:** M
**security_review:** required

**Acceptance Criteria:**

1. **Given** an authenticated user uploads a file via `PUT /_matrix/media/v3/upload`,
   **When** the request is processed by the Elixir media handler,
   **Then** the file is stored in S3/MinIO and a `mxc://` URI is returned.

2. **Given** a room member requests `GET /_matrix/media/v3/download/{serverName}/{mediaId}`,
   **When** the handler checks room membership (local call within OTP),
   **Then** the file is streamed directly from S3 via `ExAws.S3` with no RAM buffering.

3. **Given** a `Range: bytes=0-1023` header in a download request,
   **When** processed by Bandit,
   **Then** `206 Partial Content` is returned with the correct byte range.

4. **Given** a non-member user requests `GET /_matrix/media/v3/download/{serverName}/{mediaId}`,
   **When** membership is checked,
   **Then** `403 Forbidden` with `M_FORBIDDEN` is returned.

5. **Given** a URL preview request `GET /_matrix/media/v3/preview_url?url=<url>`,
   **When** processed via `Finch`,
   **Then** OG-meta tags (`og:title`, `og:description`, `og:image`) are extracted and returned.

6. **Given** the Go media gateway container,
   **When** this story is complete,
   **Then** it is removed from `docker-compose.yml`.

**Acceptance Tests:**

### Tests written FIRST (before implementation code):

1. **`gateway/features/media-upload-download.feature`** — Godog integration test
   - Given: authenticated user, running S3/MinIO
   - When: upload via Elixir handler
   - Then: `mxc://` URI returned; download returns same bytes

2. **`test/media_range_request_test.exs`** — ExUnit unit test (Plug.Test)
   - Given: Range header `bytes=0-99`
   - When: download handler processes it
   - Then: `206` with 100 bytes

3. **`test/media_access_control_test.exs`** — ExUnit unit test
   - Given: non-member user
   - When: download attempted
   - Then: `403 M_FORBIDDEN`

---

### Story: admin-ui-migration

As a Nebu instance admin,
I want the Admin UI served by Phoenix LiveView,
So that the UI is reactive without a SPA build pipeline and the Go admin backend can be removed.

**Size:** L
**security_review:** required

**Acceptance Criteria:**

1. **Given** an admin user navigates to `/admin`,
   **When** they are authenticated via OIDC (admin claim present),
   **Then** the Phoenix LiveView admin dashboard renders with the same feature set as the Go-template Admin UI: Room Management, User Overview, Bootstrap Wizard.

2. **Given** an admin uses the Room Management LiveView,
   **When** they change the auto-join status of a room,
   **Then** the change is immediately reflected in the UI (LiveView DOM diff push) without a full page reload.

3. **Given** a non-admin user navigates to `/admin`,
   **When** their OIDC claims are checked,
   **Then** `403 Forbidden` is returned (admin claim gate preserved).

4. **Given** the Go admin backend container,
   **When** this story is complete,
   **Then** it is removed from `docker-compose.yml` and all Admin UI routes are served by Phoenix.

5. **Given** the existing Admin UI Playwright+Gherkin E2E test suite,
   **When** run against the Phoenix LiveView Admin UI,
   **Then** all previously passing scenarios still pass.

**Acceptance Tests:**

### Tests written FIRST (before implementation code):

1. **`e2e/features/admin-ui-liveview.feature`** — Playwright + Cucumber scenario
   - Given: admin session (real OIDC Authorization Code + PKCE flow)
   - When: `/admin/rooms` is visited
   - Then: room list renders; auto-join toggle works; update is reflected without reload

2. **`e2e/features/admin-ui-auth-gate.feature`** — Playwright + Cucumber scenario
   - Given: non-admin user
   - When: navigates to `/admin`
   - Then: `403` or redirect to error page

3. **`test/admin_liveview_unit_test.exs`** — ExUnit + LiveView test helpers
   - Given: LiveView mount with mock assigns
   - When: toggle event fired
   - Then: LiveView assigns updated, DB call triggered

---

### Story: elixir-stack-regression

As a Nebu operator,
I want a comprehensive end-to-end regression suite executed against the pure Elixir stack (Go gateway and media gateway already removed from compose),
So that we have documented proof that no Matrix API contract, media flow, Admin UI flow, or OIDC flow regressed during the migration.

**Size:** M
**security_review:** not-needed

**Acceptance Criteria:**

1. **Given** the full stack running with Go removed (`docker-compose.yml` has no `gateway` or `media` service),
   **When** the complete Matrix user journey is exercised (login → create room → invite → send message → `/sync` receives event → read receipt → typing indicator → logout),
   **Then** every step returns the correct Matrix-spec response and the Godog suite exits `0`.

2. **Given** an authenticated user,
   **When** they upload an image via `PUT /_matrix/media/v3/upload` and immediately download it,
   **Then** the downloaded bytes are identical to the uploaded bytes (no corruption); a Range request returns `206` with the correct slice.

3. **Given** an admin user,
   **When** they complete the full Admin UI flow in a real browser (Room Management → toggle auto-join → User Overview → confirm user count),
   **Then** all Playwright + Gherkin scenarios that passed against the Go Admin UI pass against the Phoenix LiveView Admin UI.

4. **Given** a URL preview request for a well-known URL with OG tags,
   **When** `GET /_matrix/media/v3/preview_url?url=<url>` is called,
   **Then** `og:title` and `og:description` are present in the response.

5. **Given** an OIDC token issued by Dex (Authorization Code + PKCE),
   **When** it is presented to any protected endpoint,
   **Then** the Elixir OIDC Plug validates it correctly and the request succeeds (no fallback to Go).

6. **Given** the `make test-integration` target,
   **When** executed after Go removal,
   **Then** it exits `0` — all Godog scenarios and Playwright E2E scenarios are green.

7. **Given** a load scenario of 200 concurrent `/sync` long-polling clients,
   **When** 50 messages are broadcast to a shared room over 60 seconds,
   **Then** median event-delivery latency is ≤ 150ms (BEAM baseline, no gRPC hop).

**Acceptance Tests:**

### Tests written FIRST (before implementation code):

1. **`gateway/features/elixir-regression-matrix.feature`** — Godog integration test
   - Full Matrix user journey: login → createRoom → send → sync → receipt → typing → logout
   - Run against Elixir-only stack (`NEBU_BASE_URL=http://core:4000`)
   - All steps must be green; any `501 Not Implemented` is a blocker

2. **`gateway/features/elixir-regression-media.feature`** — Godog integration test
   - Upload JPEG → download → verify bytes identical
   - Range request `bytes=0-99` → `206` with 100 bytes
   - URL preview → `og:title` present
   - Non-member download → `403 M_FORBIDDEN`

3. **`e2e/features/elixir-regression-admin.feature`** — Playwright + Cucumber scenario
   - Admin login (real OIDC PKCE flow) → Room Management → toggle auto-join → User Overview → count
   - All previous Admin UI scenarios replayed against Phoenix LiveView

4. **`test/regression_sync_load_test.exs`** — ExUnit load test
   - 200 concurrent `/sync` clients, 50 broadcast messages
   - Median latency ≤ 150ms measured via `:timer.tc`

---

### Story: go-removal-cleanup

As a Nebu contributor,
I want all Go source code, Docker images, CI steps, and deployment targets removed,
So that the repository has a single Elixir/OTP artefact and toolchain.

**Size:** S
**security_review:** not-needed

**Acceptance Criteria:**

1. **Given** the repository root,
   **When** `find . -name "*.go" | grep -v vendor` is executed,
   **Then** the output is empty (no Go source files remain).

2. **Given** `docker-compose.yml`,
   **When** inspected,
   **Then** no `gateway` or `media` Go-based services appear; only `core` (Elixir), `postgres`, `dex`, and a reverse proxy.

3. **Given** the CI pipeline (`.gitlab-ci.yml` or `.github/workflows/`),
   **When** inspected,
   **Then** no `go build`, `go test`, `govulncheck`, or Go-related steps remain.

4. **Given** the OpenTofu deployment manifests,
   **When** inspected,
   **Then** all Go-gateway container targets (AWS ECS task defs, Stackit docker-compose, Helm chart) reference only the single Elixir container.

5. **Given** `Renovate` configuration,
   **When** inspected,
   **Then** Go module update rules are removed; only Elixir/Mix + PostgreSQL remain.

6. **Given** `make test-unit-go` and `make build-gateway` targets in the Makefile,
   **When** the Makefile is inspected,
   **Then** they are removed or return a clear deprecation error if accidentally called.

7. **Given** the full CI pipeline,
   **When** it runs after this story is merged,
   **Then** it completes green in ≤ the baseline CI time minus the Go build time.

**Acceptance Tests:**

### Tests written FIRST (before implementation code):

1. **Shell assertion in CI** — `test/smoke/no-go-files.sh`
   - When: executed in the repo root
   - Then: exits 0 if `find . -name "*.go" | grep -v vendor` returns empty; exits 1 otherwise

2. **`make ci`** — full pipeline run
   - Given: all Go artefacts removed
   - When: `make ci` runs
   - Then: exits 0, no Go-related step failures

---
