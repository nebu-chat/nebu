---
story_id: stackit-objectstore-integration
title: "Media Gateway: StackIT Object Store Integration"
epic: media-gateway-stackit-objectstore-support
status: done
security_review: required
created: 2026-05-26
branch: feature/media-gateway-support-for-stackit-objectstore
target_release: 0.2.2
---

## Summary

The Media Gateway (`media/`) is fully functional in the local dev stack (MinIO as S3 proxy) but is completely absent from the StackIT deployment. The `cloud-init.tftpl` template only knows `gateway`, `core`, `dex`, `element`, and `proxy` — no `media` service.

This story adds StackIT Object Store support (S3-compatible, path-style URLs) and integrates the Media Gateway into the StackIT OpenTofu deployment as an optional, conditionally deployed service.

## User Story

As a StackIT operator deploying Nebu, I want to enable the Media Gateway with StackIT Object Store as the storage backend, so that Matrix media uploads/downloads work in production without running a MinIO container or managing local disk storage.

## Acceptance Criteria

1. **AC1 — BucketLookupPath**: `minio.New()` in `media/cmd/media/main.go` uses `BucketLookup: minio.BucketLookupPath` instead of the default `BucketLookupAuto`, eliminating DNS-based virtual-hosted-style URL probing on StackIT Object Store.
2. **AC2 — Deployment variables**: `deploy/tofu/examples/stackit/variables.tf` contains the 7 new variables: `enable_media_gateway`, `s3_access_key`, `s3_secret_key`, `s3_endpoint`, `s3_bucket`, `media_cpu_limit`, `media_memory_limit`.
3. **AC3 — Precondition guard**: `server.tf` includes a `precondition` that fails with a clear message if `enable_media_gateway = true` but `s3_access_key` or `s3_secret_key` is empty.
4. **AC4 — templatefile() extension**: All 7 new variables are passed to `templatefile()` in `server.tf`.
5. **AC5 — cloud-init media service**: When `enable_media_gateway = true`, the rendered `docker-compose.yml` includes the `media` service with S3 credentials via Docker Secrets, correct environment variables, healthcheck, and resource limits.
6. **AC6 — cloud-init S3 secrets**: When `enable_media_gateway = true`, `write_files` creates `/opt/nebu/.secrets/s3_access_key` and `/opt/nebu/.secrets/s3_secret_key` (permissions `0600`); the `secrets:` block in the compose YAML references them.
7. **AC7 — nginx media routing**: When `enable_media_gateway = true` and `tls_mode` is `alb` or `acme`, the nginx config includes a `location /_matrix/media/` block that proxies to `media:8009` (ALB mode) or `http://127.0.0.1:8009` (ACME mode), with `client_max_body_size 50m`.
8. **AC8 — Optional bucket resource**: `main.tf` includes the `stackit_objectstorage_bucket.nebu_media` resource with `count = var.enable_media_gateway ? 1 : 0`.
9. **AC9 — Local dev unaffected**: `make test-unit-go` passes without regression. The `BucketLookupPath` change is backwards-compatible with MinIO (local dev) since MinIO supports path-style URLs equally well.
10. **AC10 — Disabled by default**: `enable_media_gateway` defaults to `false`; all media-related blocks are skipped when it is false.

## Acceptance Tests

### Tests written FIRST (before implementation):

1. **`TestSelectStorer_BucketLookupPath`** — Go unit test (`media/cmd/media/main_test.go`)
   - Given: `mediaConfig` with `storageBackend = "minio"`, valid endpoint/key/secret/bucket, `minioUseSSL = false`
   - When: `selectStorer(cfg)` is called
   - Then: The returned `*storage.MinIOStorer` has a non-nil `Client` AND the underlying `minio.Client` was constructed with `BucketLookup = minio.BucketLookupPath`

   **Implementation note:** The minio client exposes `BucketLookup` via `client.core.lookup` (private). Test approach: construct client via `selectStorer`, then verify by calling `client.BucketExists` against a path-style URL — OR simpler: use a `httptest.Server` that asserts the request path is `/bucket/` (path-style), not `bucket.host/` (virtual-hosted). Alternatively, since `minio.Options` is a struct, expose a testable helper `newMinioClient(opts minio.Options)` and assert in unit test that `BucketLookupPath` is set. The simplest approach: add a `bucketLookup` field assertion by calling `selectStorer` and checking the concrete client type has the correct lookup — use the exported `minio.Client.BucketLookup()` if available, or verify indirectly via a mock HTTP server.

   **Practical test strategy:** Use `httptest.NewServer` and pass its URL as `minioEndpoint`. Make a call through the storer that triggers a bucket operation. Verify the HTTP request path is `/nebu-media/` (path-style) not a virtual-hosted URL.

2. **Infra-only ACs (AC2–AC10) are verified by `tofu validate` + manual `tofu plan` review** — no executable unit test harness exists for HCL templates. The dev agent must verify correctness by running `tofu validate` in the stackit module directory after changes.

## Technical Requirements

### 1. Go Change — `media/cmd/media/main.go`

**Exact change** (line 376, `selectStorer` function):

```go
// BEFORE
client, err := minio.New(cfg.minioEndpoint, &minio.Options{
    Creds:  credentials.NewStaticV4(cfg.minioAccessKey, cfg.minioSecretKey, ""),
    Secure: cfg.minioUseSSL,
})

// AFTER
client, err := minio.New(cfg.minioEndpoint, &minio.Options{
    Creds:        credentials.NewStaticV4(cfg.minioAccessKey, cfg.minioSecretKey, ""),
    Secure:       cfg.minioUseSSL,
    BucketLookup: minio.BucketLookupPath,
})
```

**Why:** StackIT Object Store uses path-style URLs (`endpoint/bucket/key`). The default `BucketLookupAuto` first tries DNS-based virtual-hosted URLs (`bucket.endpoint/key`), fails on DNS lookup, then falls back to path-style — this fallback is slow and fragile. `BucketLookupPath` forces path-style directly. MinIO in dev also supports path-style, so no regression.

**Test file:** `media/cmd/media/main_test.go` — existing test `TestMain_StorageBackend_Minio_EnvVars` (line 62) tests that `*storage.MinIOStorer` is returned with correct bucket. Add a new test `TestSelectStorer_BucketLookupPath` that verifies path-style lookup is used.

### 2. Tofu Variables — `deploy/tofu/examples/stackit/variables.tf`

Add after the `element_memory_limit` variable block (after line 93):

```hcl
variable "enable_media_gateway" {
  description = "When true, deploys the Media Gateway as a Docker service. Requires s3_access_key, s3_secret_key, s3_bucket."
  type        = bool
  default     = false
}

variable "s3_access_key" {
  description = "Access key for the S3-compatible object store (StackIT Object Store or MinIO). Required when enable_media_gateway = true."
  type        = string
  sensitive   = true
  default     = ""
}

variable "s3_secret_key" {
  description = "Secret key for the S3-compatible object store. Required when enable_media_gateway = true."
  type        = string
  sensitive   = true
  default     = ""
}

variable "s3_endpoint" {
  description = "S3-compatible object store endpoint (without https://, e.g. 'object.storage.eu01.onstackit.cloud'). Required when enable_media_gateway = true."
  type        = string
  default     = "object.storage.eu01.onstackit.cloud"
}

variable "s3_bucket" {
  description = "S3 bucket name for media storage. Required when enable_media_gateway = true."
  type        = string
  default     = "nebu-media"
}

variable "media_cpu_limit" {
  description = "CPU limit for the media gateway container."
  type        = string
  default     = "0.50"
}

variable "media_memory_limit" {
  description = "Memory limit for the media gateway container."
  type        = string
  default     = "256m"
}
```

### 3. Tofu Server — `deploy/tofu/examples/stackit/server.tf`

**a) Extend `templatefile()` call** (after `enable_element_web = var.enable_element_web` on line 133):

```hcl
    # Media Gateway — StackIT Object Store
    enable_media_gateway = var.enable_media_gateway
    s3_access_key        = var.s3_access_key
    s3_secret_key        = var.s3_secret_key
    s3_endpoint          = var.s3_endpoint
    s3_bucket            = var.s3_bucket
    media_cpu_limit      = var.media_cpu_limit
    media_memory_limit   = var.media_memory_limit
```

**b) Add `precondition` inside the `lifecycle` block** (after the existing `enable_element_web` precondition at line 151):

```hcl
    precondition {
      condition     = !var.enable_media_gateway || (length(var.s3_access_key) > 0 && length(var.s3_secret_key) > 0)
      error_message = "s3_access_key and s3_secret_key are required when enable_media_gateway = true."
    }
```

### 4. cloud-init Template — `deploy/tofu/examples/stackit/cloud-init.tftpl`

**a) Secrets files** — add in the `write_files:` block, after the `internal_secret` entry (after line 26):

```yaml
%{ if enable_media_gateway ~}
  - path: /opt/nebu/.secrets/s3_access_key
    owner: root:root
    permissions: "0600"
    content: "${s3_access_key}"

  - path: /opt/nebu/.secrets/s3_secret_key
    owner: root:root
    permissions: "0600"
    content: "${s3_secret_key}"
%{ endif ~}
```

**b) Docker Compose secrets block** — extend the `secrets:` block in docker-compose.yml section (after `internal_secret:` at line 379):

```yaml
%{ if enable_media_gateway ~}
        s3_access_key:
          file: .secrets/s3_access_key
        s3_secret_key:
          file: .secrets/s3_secret_key
%{ endif ~}
```

**c) Media service** — add in the `services:` block, after the `gateway:` service (after line 461, before `%{ if enable_element_web ~}`):

```yaml
%{ if enable_media_gateway ~}

        media:
          image: $${NEBU_IMAGE_REGISTRY}/nebu-media:$${NEBU_VERSION}
          restart: unless-stopped
          depends_on:
            gateway:
              condition: service_healthy
          secrets:
            - s3_access_key
            - s3_secret_key
          environment:
            NEBU_SERVER_NAME: $${NEBU_SERVER_NAME}
            NEBU_DB_URL: $${NEBU_DB_URL}
            NEBU_STORAGE_BACKEND: "minio"
            NEBU_MINIO_ENDPOINT: "${s3_endpoint}"
            NEBU_MINIO_ACCESS_KEY_FILE: "/run/secrets/s3_access_key"
            NEBU_MINIO_SECRET_KEY_FILE: "/run/secrets/s3_secret_key"
            NEBU_MINIO_BUCKET: "${s3_bucket}"
            NEBU_MINIO_USE_SSL: "true"
            NEBU_OIDC_ISSUER: $${NEBU_OIDC_ISSUER}
            NEBU_OIDC_CLIENT_ID: $${NEBU_OIDC_CLIENT_ID}
            NEBU_TRUSTED_PROXY: $${NEBU_TRUSTED_PROXY}
          ports:
            - "127.0.0.1:8009:8009"
          healthcheck:
            test: ["CMD", "curl", "-f", "http://localhost:8009/health"]
            interval: 10s
            timeout: 5s
            retries: 3
            start_period: 10s
          deploy:
            resources:
              limits:
                cpus: '${media_cpu_limit}'
                memory: ${media_memory_limit}
%{ endif ~}
```

**Port binding note:** Use `127.0.0.1:8009:8009` (loopback only) — not `0.0.0.0:8009:8009`. Port 8009 is accessed internally via nginx proxy only; no security group change is needed. This is consistent with the ACME mode pattern where `element` binds to `127.0.0.1:7070:80`.

**d) nginx routing — ALB mode** — in the `nginx-proxy.conf` block (`tls_mode == "alb"`), add after the `dex` location and before the `enable_element_web` conditional (around line 200). The `/_matrix/media/` location must be placed BEFORE the catch-all `/_matrix/` block to take precedence:

```nginx
%{ if enable_media_gateway ~}

          location /_matrix/media/ {
              proxy_pass         http://media:8009;
              proxy_http_version 1.1;
              proxy_set_header   Host              $host;
              proxy_set_header   X-Real-IP         $remote_addr;
              proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
              proxy_set_header   X-Forwarded-Proto https;
              client_max_body_size 50m;
          }
%{ endif ~}
```

**e) nginx routing — ACME mode** — in the `sites-available/nebu` block (`tls_mode == "acme"`), add similarly before the `/_matrix/` block. Proxy target uses the container hostname `media:8009` is NOT valid here (ACME mode uses system nginx, not Docker-networked nginx). Use `http://127.0.0.1:8009` with port published on loopback:

```nginx
%{ if enable_media_gateway ~}

          location /_matrix/media/ {
              proxy_pass         http://127.0.0.1:8009;
              proxy_http_version 1.1;
              proxy_set_header   Host              $host;
              proxy_set_header   X-Real-IP         $remote_addr;
              proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
              proxy_set_header   X-Forwarded-Proto https;
              client_max_body_size 50m;
          }
%{ endif ~}
```

**CRITICAL: nginx location ordering.** In ALB mode, the existing `enable_element_web` block defines `location /_matrix/ { proxy_pass http://gateway:8008; }` as a prefix match. nginx uses longest-prefix-wins, so `/_matrix/media/` (more specific) naturally takes priority over `/_matrix/` — but only if both are present. When `enable_element_web = false`, there is no `/_matrix/` location in the ALB config — the catch-all `location /` handles everything. Verify the template renders correctly for all 4 combinations: `(enable_media_gateway=true|false) × (enable_element_web=true|false)`.

### 5. Optional Bucket Resource — `deploy/tofu/examples/stackit/main.tf`

Add after the `provider "stackit"` block:

```hcl
# ── StackIT Object Storage (optional) ────────────────────────────────────────
# Creates the S3 bucket for media storage when enable_media_gateway = true.
# Note: StackIT Object Store credentials (s3_access_key / s3_secret_key) are
# NOT the same as the service account key (stackit_key_path). They are created
# separately in the STACKIT portal under Object Storage > Credentials.
resource "stackit_objectstorage_bucket" "nebu_media" {
  count      = var.enable_media_gateway ? 1 : 0
  project_id = var.stackit_project_id
  name       = var.s3_bucket
}
```

## File List

All files that need to be modified:

| File | Change Type | Change |
|---|---|---|
| `media/cmd/media/main.go` | UPDATE | Add `BucketLookup: minio.BucketLookupPath` to `minio.Options` in `selectStorer()` |
| `media/cmd/media/main_test.go` | UPDATE | Add `TestSelectStorer_BucketLookupPath` test |
| `deploy/tofu/examples/stackit/variables.tf` | UPDATE | Add 7 new variables after `element_memory_limit` |
| `deploy/tofu/examples/stackit/server.tf` | UPDATE | Extend `templatefile()` call + add precondition in lifecycle |
| `deploy/tofu/examples/stackit/cloud-init.tftpl` | UPDATE | Secrets files + compose secrets block + media service + nginx routing (both ALB and ACME modes) |
| `deploy/tofu/examples/stackit/main.tf` | UPDATE | Add `stackit_objectstorage_bucket.nebu_media` resource |

## Dev Agent Guardrails

### Critical: cloud-init Template Variable Escaping

The `cloud-init.tftpl` template uses OpenTofu `templatefile()` interpolation. Two different escaping styles are used:
- `${variable}` — OpenTofu/Terraform interpolation (replaced at `tofu apply` time by the caller's variable)
- `$${ENV_VAR}` — escaped dollar sign, rendered literally as `${ENV_VAR}` in the output YAML (these are Docker Compose environment variable references resolved at `docker compose up` time, not by OpenTofu)

**Rule:** StackIT Object Store config values (`s3_endpoint`, `s3_bucket`, `media_cpu_limit`, `media_memory_limit`) use `${...}` because they are OpenTofu vars. Runtime Docker env vars (`NEBU_SERVER_NAME`, `NEBU_DB_URL`, `NEBU_OIDC_ISSUER`, `NEBU_OIDC_CLIENT_ID`, `NEBU_TRUSTED_PROXY`) use `$${...}`.

Look at the existing `gateway:` and `core:` service blocks (lines 406–461) for the exact pattern.

### Critical: nginx Location Ordering

In the ALB nginx config, `/_matrix/media/` must appear BEFORE `/_matrix/` when both are present. Since nginx uses longest-prefix match, the order in the config file does not affect routing — but the template must ensure `/_matrix/media/` is inside or before the `%{ if enable_element_web ~}` block that defines `/_matrix/`. Place the media location block before the `enable_element_web` conditional.

In ACME mode (`/etc/nginx/sites-available/nebu`), system nginx proxies directly to Docker containers via loopback ports. Media uses `127.0.0.1:8009` (port published via `127.0.0.1:8009:8009` in compose). Gateway uses `127.0.0.1:8008`. Element uses `127.0.0.1:7070`.

### Critical: Do Not Open Port 8009 in Security Groups

`security-groups.tf` defines the allowed inbound rules. Port 8009 is media-internal only — accessed via nginx proxy. Do NOT add `8009` to any security group ingress rule. This is equivalent to how `8008` (gateway) is handled in ALB mode (ALB forwards to 8008, no direct SG rule for 8008 from internet).

### Critical: NEBU_OIDC_CLIENT_ID for Media

The Media Gateway validates OIDC JWTs. It uses `NEBU_OIDC_CLIENT_ID` as the audience claim. In the StackIT deployment, set this to the same `oidc_client_id` as the gateway (env var `$${NEBU_OIDC_CLIENT_ID}` resolved from `.env` at Docker Compose runtime). This is correct because both gateway and media share the same Dex/OIDC client in the current deployment model.

### Critical: `NEBU_MINIO_ACCESS_KEY_FILE` vs `NEBU_MINIO_ACCESS_KEY`

The media container reads credentials from files (Docker Secrets). Env vars are `NEBU_MINIO_ACCESS_KEY_FILE` and `NEBU_MINIO_SECRET_KEY_FILE` (not `NEBU_MINIO_ACCESS_KEY` / `NEBU_MINIO_SECRET_KEY`). This is already handled in the spec above — ensure you use the `_FILE` variants.

Verify in `media/cmd/media/main.go` that `NEBU_MINIO_ACCESS_KEY_FILE` is already supported (it reads the file path and calls `readSecretFile`). If not present, add it as part of this story.

### Do Not Change

- `docker-compose.yml` (local dev) — keep MinIO as the local backend unchanged
- Security group definitions (`security-groups.tf`) — no changes needed
- Any existing variable defaults that affect current deployments
- The `nginx-proxy.conf` ALB base config structure — only add new `location` blocks inside the existing `server {}` block

### Validation Command

After making all HCL changes:
```bash
cd deploy/tofu/examples/stackit && tofu validate
```

This requires a Tofu binary. If not available locally, the CI pipeline runs validation. The `tofu validate` only checks syntax and type constraints — it does not require provider credentials.

## Context: Why Path-Style Matters

`minio.BucketLookupAuto` (the default) first tries a DNS lookup for `bucket.endpoint`. For `NEBU_MINIO_BUCKET=nebu-media` and `NEBU_MINIO_ENDPOINT=object.storage.eu01.onstackit.cloud`, it would try `nebu-media.object.storage.eu01.onstackit.cloud` — which does not exist in StackIT's DNS. `minio-go` then falls back to path-style after the DNS probe fails. This works but adds latency on every first request and can cause issues in restricted network environments. `BucketLookupPath` eliminates the probe entirely.

MinIO (used in local dev via `docker-compose.yml`) supports path-style by default (`MINIO_DOMAIN` is not set), so this change is fully backwards-compatible.

## Dev Agent Record

### Status
review

### Implementation Notes

- **AC1 (BucketLookupPath):** Added `BucketLookup: minio.BucketLookupPath` to `minio.Options` in `selectStorer()` in `media/cmd/media/main.go`. The test `TestSelectStorer_BucketLookupPath` uses reflect+unsafe to read the private `lookup` field of `*minio.Client` and asserts it equals `minio.BucketLookupPath` (2). Test now GREEN.
- **AC2 (variables.tf):** Added 7 new variables after `element_memory_limit`: `enable_media_gateway` (bool, default false), `s3_access_key` (sensitive string), `s3_secret_key` (sensitive string), `s3_endpoint`, `s3_bucket`, `media_cpu_limit`, `media_memory_limit`.
- **AC3 (precondition):** Added lifecycle precondition in `server.tf`: `!var.enable_media_gateway || (length(var.s3_access_key) > 0 && length(var.s3_secret_key) > 0)`.
- **AC4 (templatefile extension):** All 7 new variables passed to `templatefile()` in `server.tf`.
- **AC5 (media service):** Added `%{ if enable_media_gateway ~}` block in cloud-init.tftpl after the gateway service with correct env vars, Docker Secrets, healthcheck, resource limits, and loopback port binding `127.0.0.1:8009:8009`.
- **AC6 (S3 secrets):** Added `write_files` entries for `/opt/nebu/.secrets/s3_access_key` and `/opt/nebu/.secrets/s3_secret_key` (permissions 0600), and extended the `secrets:` block in the compose YAML.
- **AC7 (nginx routing):** Added `/_matrix/media/` location block (with `client_max_body_size 50m`) in BOTH ALB mode (proxy to `http://media:8009`) and ACME mode (proxy to `http://127.0.0.1:8009`), placed BEFORE the `enable_element_web` conditional to ensure it takes precedence.
- **AC8 (bucket resource):** Added `stackit_objectstorage_bucket.nebu_media` resource in `main.tf` with `count = var.enable_media_gateway ? 1 : 0`.
- **AC9 (local dev unaffected):** `make test-unit-go` passes — 22 media tests green, all gateway tests green, no regressions.
- **AC10 (disabled by default):** `enable_media_gateway` defaults to `false`.
- **MINOR-1 fix:** Added explanatory comment to the httptest server in `TestSelectStorer_BucketLookupPath`.

### Files Changed

| File | Change |
|---|---|
| `media/cmd/media/main.go` | Added `BucketLookup: minio.BucketLookupPath` to `minio.Options` |
| `media/cmd/media/main_test.go` | Added comment to httptest server (MINOR-1); test was pre-existing RED |
| `deploy/tofu/examples/stackit/variables.tf` | Added 7 new variables |
| `deploy/tofu/examples/stackit/server.tf` | Extended templatefile() call + added precondition |
| `deploy/tofu/examples/stackit/cloud-init.tftpl` | 4 changes: secret files, compose secrets block, media service, nginx routing (ALB + ACME) |
| `deploy/tofu/examples/stackit/main.tf` | Added stackit_objectstorage_bucket.nebu_media resource |
