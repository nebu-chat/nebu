# Security Review — stackit-objectstore-integration

**Diff scope:** Staged diff for story `stackit-objectstore-integration` (epic `media-gateway-stackit-objectstore-support`). Integrates the Media Gateway into the StackIT OpenTofu deployment with StackIT Object Store as the S3 backend. Touches: `media/cmd/media/main.go` (BucketLookupPath), `media/cmd/media/main_test.go` (test only), `deploy/tofu/examples/stackit/{variables.tf, server.tf, main.tf, cloud-init.tftpl}`. Pipeline-state and story docs are non-code artefacts (out of scope).
**Date:** 2026-05-26
**Reviewer:** Kassandra (nebu-agent-kassandra) — security-review.md
**Story flag:** `security_review: required`
**Branch:** feature/media-gateway-support-for-stackit-objectstore

---

## Executive Summary

The change set is small, surgical, and follows the existing Docker Secrets pattern that the gateway and core services use for `internal_secret`. The Go change is one line and backwards-compatible; the IaC change adds an optional, opt-in path that defaults to `enable_media_gateway = false`. Secret handling at every layer (cloud-init write, Docker Secrets mount, Go-side `NEBU_MINIO_ACCESS_KEY_FILE` resolution, log redaction) follows the project's established conventions.

The known recurring patterns from MEMORY that COULD apply here were specifically checked:

1. **MinIO `mc` entrypoint argv leak (Epic 12)** — N/A: no `mc` entrypoint shell, credentials are mounted as Docker Secrets and consumed via `NEBU_MINIO_ACCESS_KEY_FILE` / `NEBU_MINIO_SECRET_KEY_FILE`, never expanded into argv.
2. **OIDC fail-open at startup (Epic 12)** — N/A: media service inherits the existing `NEBU_OIDC_ISSUER`-required logic; the new compose block passes the required env var.
3. **XFF rate-limit spoofing (Epic 12)** — pre-existing whole-stack issue with ALB-in-front topology, unchanged by this story (see MEDIUM-1 below).
4. **`uploader_user_id` ≠ Matrix user ID (Epic 12)** — pre-existing, partially closed in 12.9, unchanged.
5. **Caller-controlled `system_role` (Epic 14)** — N/A: no proto / RPC changes.
6. **`/admin/*` security headers carve-out (Epic 14)** — N/A: media endpoints are not admin endpoints; CSP / X-Frame-Options live in the media service handler chain (Story 12.7 hardening), not in nginx.
7. **DSN composition with externally-generated passwords (Epic 13)** — N/A: no DSN composition added; existing `pg_password` substitution unchanged.
8. **`deletion_protection = false` hardcoded defaults (Epic 13)** — see LOW-3 below.
9. **Singleton-list passthrough into ACL/SG inputs (Epic 13)** — N/A: no ACL / SG inputs touched.
10. **nginx catch-all `/` swallowing gateway paths (Epic 13)** — verified clean: `/_matrix/media/` is a longer prefix than `/_matrix/` and `/` (longest-prefix-match wins in nginx). See INFO-1.

No exploitable CRITICAL or HIGH vulnerability was found in the staged diff. Three MEDIUM-severity defense-in-depth concerns and several LOW advisories are documented below.

---

## Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| 1 | MEDIUM | `deploy/tofu/examples/stackit/main.tf:32-39` (`stackit_objectstorage_bucket.nebu_media`) | Bucket has no `prevent_destroy` lifecycle and no explicit ACL/versioning/encryption config — `tofu destroy` (or accidental tf removal) will delete the production media bucket and all stored media. | Add `lifecycle { prevent_destroy = true }` for prod, OR gate via a `production = true` variable. Document that all StackIT buckets default to private + server-side encrypted (verify against StackIT docs at apply time). |
| 2 | MEDIUM | `deploy/tofu/examples/stackit/server.tf:160-170` (precondition) | Precondition does not validate that `s3_endpoint` actually uses HTTPS / that `NEBU_MINIO_USE_SSL=true` matches the endpoint scheme. An operator passing `s3_endpoint = "http://intra.example.com"` (or any non-TLS endpoint while `NEBU_MINIO_USE_SSL` is hardcoded to `"true"` in cloud-init) creates a confusing failure mode where the operator may be tempted to "fix" it by adding `NEBU_MINIO_USE_SSL=false` — silently downgrading transport for S3 creds. | Add precondition: `condition = !var.enable_media_gateway || !startswith(var.s3_endpoint, "http://")` with error message clarifying that the endpoint must be a hostname only (no scheme), and SSL is always true in StackIT mode. Alternatively, validate against an allowlist of known StackIT endpoints. |
| 3 | MEDIUM | `deploy/tofu/examples/stackit/cloud-init.tftpl:212-223` and `:326-337` (nginx `/_matrix/media/` block) | The new `/_matrix/media/` proxy block has neither nginx-level rate-limit (limit_req zone) nor request_size limits beyond `client_max_body_size`. The media service has its own Go-level rate-limiter (Story 12.10), but with `NEBU_TRUSTED_PROXY=true` the trust chain is `client → ALB → nginx → media`. Pre-existing pattern across all gateway routes, but worth flagging as the media routes are now newly reachable. | Defense-in-depth: add a single `limit_req_zone $binary_remote_addr zone=media:10m rate=10r/s;` at `http {}` level and `limit_req zone=media burst=20 nodelay;` in the media location block. Or accept as pre-existing for the rest of the stack and document. |
| 4 | LOW | `deploy/tofu/examples/stackit/cloud-init.tftpl:28-39` (write_files for s3 secrets) | The `content: "${s3_access_key}"` YAML-substitutes without escaping. StackIT-generated access/secret keys are typically base64-URL/hex and contain only `[A-Za-z0-9+/=]` — no YAML-unsafe characters. But if a future credential ever contains `"` or `\` or a newline (unlikely but possible after rotation if the operator pastes from a corrupted source), the YAML scalar would break the cloud-init parse — server reprovision would silently fail. | Use literal `\|` block scalar instead of quoted form, OR add `pre_validation` HCL check that the secret matches `^[A-Za-z0-9+/=_-]+$`. Aligns with the existing `internal_secret` pattern (which has the same theoretical issue but is hex-only by construction). |
| 5 | LOW | `deploy/tofu/examples/stackit/cloud-init.tftpl:25` (write_files: `permissions: "0600"`) | The cloud-init secret files (`/opt/nebu/.secrets/s3_access_key`, `s3_secret_key`) are written with `permissions: "0600"` but their parent directory `.secrets` is `chmod 0700` only later in `runcmd` (line 681). Between write_files and runcmd, the parent dir could be world-readable depending on system umask — files themselves are 0600 so contents are protected, but the directory listing leaks credential filename presence. Pre-existing pattern for `internal_secret`, repeated here. | Move `mkdir -p /opt/nebu/.secrets && chmod 0700 /opt/nebu/.secrets` into a `bootcmd` (runs before write_files) or use cloud-init's explicit `path` permissions on directories. Same fix applies to internal_secret — out of scope but on the watch list. |
| 6 | LOW | `deploy/tofu/examples/stackit/main.tf:32-39` (`stackit_objectstorage_bucket.nebu_media`) | No explicit versioning, public-access-block, or object-lock configuration on the bucket. Relies entirely on StackIT defaults (which are private by default per StackIT docs). | Add `force_destroy = false` (default OK), and if the StackIT provider supports `acl = "private"`, `versioning = true`, `block_public_access = true`, configure them explicitly. Track StackIT provider feature additions. |
| 7 | LOW | `deploy/tofu/examples/stackit/cloud-init.tftpl:520` (`NEBU_STORAGE_BACKEND: "minio"`) | Hardcoded to `"minio"` — this is correct (StackIT Object Store is S3-compatible and the minio-go SDK is used), but the variable naming and value choice may confuse operators who expect `"s3"` or `"stackit_objectstorage"`. Not a security issue, but an operational confusion risk that could lead to misconfigured environment variables (e.g., operator manually adds `NEBU_S3_ACCESS_KEY=...` thinking the prefix changed). | Documentation only — add a comment in `variables.tf` explaining that `NEBU_STORAGE_BACKEND=minio` is the correct value for any S3-compatible store, including StackIT. |

---

## Detail

### Finding #1 — `prevent_destroy` missing on `stackit_objectstorage_bucket` [MEDIUM]

The new bucket resource has no `lifecycle { prevent_destroy = true }`. A `tofu destroy`, a `tofu apply` after `var.enable_media_gateway` is flipped to `false`, or any state surgery that removes this resource will delete the bucket and all media files stored in it. For Stackit this is permanent: there is no managed snapshot mechanism for Object Storage buckets in the way RDS / PostgresFlex offers point-in-time restore.

This pattern recurs across IaC reviews (see MEMORY: "`deletion_protection = false` hardcoded defaults — 13"). The recommendation there was that database-bearing IaC resources should default to deletion protection. The same principle applies to data-bearing object stores.

Note: code-review-findings.md INFO-4 already flagged this. Promoting to MEDIUM because the consequence is irrecoverable data loss for the entire customer media history, not just a configuration inconvenience.

**Remediation:**
```hcl
resource "stackit_objectstorage_bucket" "nebu_media" {
  count      = var.enable_media_gateway ? 1 : 0
  project_id = var.stackit_project_id
  name       = var.s3_bucket

  lifecycle {
    prevent_destroy = true
  }
}
```

If a destroy IS needed, the operator can explicitly comment out the `prevent_destroy` block on a controlled change.

### Finding #2 — Endpoint scheme not validated [MEDIUM]

`NEBU_MINIO_USE_SSL: "true"` is hardcoded in the cloud-init compose block (line 525), but `var.s3_endpoint` is a free-form string with default `object.storage.eu01.onstackit.cloud` (no scheme, as expected by `minio.New`). If an operator overrides `s3_endpoint` to include a scheme (e.g., `http://internal-minio` for a self-hosted variant), `minio.New(endpoint, ...)` will choke or behave unexpectedly, and the hardcoded `Secure: true` won't help if the URL is malformed.

More importantly, if a customer ever wants a non-TLS endpoint (against guidance), the only way to make it work is to add an env-var override in cloud-init or fork the template — both increase the risk of inadvertently downgrading transport. The current precondition (`length > 0`) silently accepts garbage.

**Remediation:** Add to `server.tf` precondition:

```hcl
condition = !var.enable_media_gateway || (
  length(var.s3_access_key) > 0 &&
  length(var.s3_secret_key) > 0 &&
  length(var.s3_bucket) > 0 &&
  length(var.s3_endpoint) > 0 &&
  !startswith(var.s3_endpoint, "http://") &&
  !startswith(var.s3_endpoint, "https://")
)
error_message = "s3_access_key/s3_secret_key/s3_bucket/s3_endpoint required when enable_media_gateway=true. s3_endpoint must be a hostname (no scheme); SSL is always enforced."
```

### Finding #3 — nginx `/_matrix/media/` lacks rate-limit + size hardening [MEDIUM]

The new nginx location block has:
- `client_max_body_size 50m` — matches `NEBU_MEDIA_MAX_UPLOAD_BYTES` default (good).
- No `limit_req` zone — relies entirely on the Go-side rate limiter (10 req/s upload, 100 req/s download).
- No `proxy_read_timeout` / `proxy_send_timeout` override — inherits the 90s from the server-level config, which is appropriate for `/sync` long-poll but excessive for media.

The Go-side rate limiter trusts XFF (per `NEBU_TRUSTED_PROXY=true`), which is correct for this topology. BUT: the rightmost-XFF logic combined with ALB → nginx → media chain means that `$remote_addr` at the media service is nginx's IP, and the XFF chain becomes `<client>, <ALB>`. The Go rate-limiter takes the rightmost entry — which is the ALB IP — and effectively rate-limits the entire fleet of clients against one bucket.

This is the **exact pattern flagged in MEMORY as "XFF rate-limit spoofing on directly-exposed services" (Epic 12) — except the inverse problem**: instead of spoofing, all clients are coalesced into one rate-limit bucket. Effective rate limit becomes (10 req/s × 1 ALB-IP) for the entire deployment.

This is pre-existing for the gateway service (port 8008) which has the same Go-side rate-limiter and the same nginx topology. Not introduced by this story, but the story DOES newly expose port 8009 behind the same broken chain.

**Remediation options (in increasing order of effort):**
- (Quick) Add nginx-level `limit_req_zone $binary_remote_addr zone=media:10m rate=10r/s;` at the `http {}` level in cloud-init.tftpl, and `limit_req zone=media burst=20 nodelay;` in the media location block. nginx sees the real client IP (via ALB's XFF or via `set_real_ip_from`-based real_ip module if configured).
- (Proper) Add nginx `real_ip_module` config: `set_real_ip_from <ALB-CIDR>; real_ip_header X-Forwarded-For;` so that `$remote_addr` becomes the real client IP, and the Go-side rate-limiter then sees `client, ALB → client → ALB` — the rightmost is still ALB, but at this point either nginx's limit_req has already shed load OR move to leftmost-after-trusted-hops parsing in the Go limiter.
- (Bigger refactor) The same `NEBU_TRUSTED_PROXY` issue applies to the whole stack; track as a cross-cutting follow-up story.

For THIS story, the minimum mitigation is the nginx-level `limit_req`. The Go-side limiter is best-effort.

### Finding #4 — YAML scalar escaping for s3 secrets [LOW]

`content: "${s3_access_key}"` in YAML is a double-quoted scalar. If `s3_access_key` contains a `"`, `\`, or `\n`, the YAML is broken and cloud-init fails. StackIT Object Store credentials are alphanumeric+`+/=` and don't trigger this — but a future credential format change, a clipboard mishap, or a rotation that pastes a `\r\n` would silently break server provisioning.

Same pattern is already in use for `internal_secret` (line 26) and `pg_password` (line 51) — pre-existing, not regressed by this story. Track as a category fix.

**Remediation:** Use literal block scalar form:
```yaml
- path: /opt/nebu/.secrets/s3_access_key
  owner: root:root
  permissions: "0600"
  content: |
    ${s3_access_key}
```
Note: this introduces a trailing newline, which `readSecretFile()` strips via `strings.TrimSpace` — so safe for the Go consumer.

### Finding #5 — `.secrets` directory permissions race [LOW]

write_files runs before runcmd. The secret files are written at write_files time with `permissions: "0600"`, but the parent directory `/opt/nebu/.secrets` does not exist at write_files time — cloud-init creates it implicitly with the system umask (typically 0755 on cloud-init-managed root filesystems). The `chmod 0700 /opt/nebu/.secrets` runs later in runcmd.

Between write_files (T+0) and runcmd (T+~30s on a fresh instance), the directory is 0755 — directory listing leaks credential filename presence (`ls /opt/nebu/.secrets/` reveals `s3_access_key`, `s3_secret_key`, `internal_secret`). The file contents are still 0600-protected. Window is short, attacker would need local execution to exploit, no remote attack surface.

Pre-existing pattern for `internal_secret` — repeated here. Not regressed by this story.

**Remediation:** Use cloud-init `bootcmd` (which runs before write_files) or add an explicit directory write_files block.

### Finding #6 — Explicit bucket security config not set [LOW]

Relies on StackIT default of private + server-side encrypted. Worth confirming explicitly via either StackIT documentation reference in code comments OR (when StackIT provider supports it) explicit resource attributes. Today's StackIT-Tofu provider does NOT expose `acl` / `versioning` / `block_public_access` on the bucket resource, so the bucket is private + non-versioned + no object-lock by default — adequate for MVP but not best-in-class.

### Finding #7 — `NEBU_STORAGE_BACKEND: "minio"` naming confusion [LOW]

Operational risk only — could lead operators to misconfigure variable prefixes. Add documentation comment in `variables.tf` clarifying that `minio` is the correct backend name for any S3-compatible store including StackIT Object Storage.

---

## Verified Clean (positive findings)

The following potential vulnerability surfaces were checked and found correctly handled:

- **Plaintext secrets in logs:** No `slog`, `fmt.Print`, or error wrapping in `selectStorer` or upstream config-load code includes `cfg.minioAccessKey` or `cfg.minioSecretKey`. `fmt.Errorf("minio client init: %w", err)` wraps only the SDK's `minio.New` error, which is credential-free.
- **Secrets in argv:** Docker Secrets are mounted as files (`/run/secrets/s3_access_key`) and read by `readSecretFile()` — never expanded into shell argv. The Epic-12 `mc` entrypoint anti-pattern (MEMORY: "MinIO mc entrypoint secret leak via argv") does NOT apply.
- **Secrets in tfstate:** The `stackit_objectstorage_bucket` resource stores only `project_id` + `name` — no credentials. Credentials live in `var.s3_access_key` / `var.s3_secret_key` (sensitive=true) and are passed via `templatefile()` directly into cloud-init.
- **`sensitive = true` flagged:** Both `s3_access_key` and `s3_secret_key` variables correctly carry `sensitive = true` — tofu plan output redacts them.
- **OIDC fail-open:** Media service inherits `NEBU_OIDC_ISSUER`-required logic from main.go (verified at line 215-219); the compose block passes the required env var. Story 12.8 hardening is in effect.
- **Auth bypass on `/_matrix/media/`:** No new routes added. The existing media handler chain has authMW wrapping the v1 endpoints; v3 `/upload` carries its own OIDC verifier; v3 `/download` and `/thumbnail` are unauthenticated by Matrix spec design but rate-limited.
- **CSRF:** N/A — media endpoints are bearer-token-authenticated, not cookie-authenticated.
- **JWT validation flaws:** No JWT validation code touched.
- **SQL injection:** No SQL touched; no migrations added.
- **XSS / Content-Disposition:** No `Content-Type` handling code touched. The Epic-12 hardening for `attachment` disposition and `nosniff` header remains in effect.
- **Path traversal:** No file-path handling code touched.
- **Body-size limit:** `client_max_body_size 50m` at nginx + `NEBU_MEDIA_MAX_UPLOAD_BYTES=52428800` at Go layer — aligned.
- **Rate limits:** Go-side rate-limiter is wrapped on all media routes. nginx-level limit is missing (see MEDIUM-3).
- **Weak crypto:** No crypto code touched.
- **Hardcoded secrets:** None. All values flow through Tofu variables with `sensitive = true`.
- **Security headers:** No HTML endpoints added. The existing `X-Content-Type-Options` / CSP / X-Frame-Options on media download responses are unchanged.
- **`BucketLookupPath` change in main.go:** Reviewed — this is a transport-layer optimization (forces path-style S3 URLs). It does not change auth semantics, does not change request signing (still SigV4 via `credentials.NewStaticV4`), does not change TLS posture. Backwards-compatible with MinIO (which supports path-style equally). No security implication.
- **Reflection-on-private-field test (`media/cmd/media/main_test.go`):** Test code only. `unsafe.Pointer` is restricted to test scope. Acceptable test-only practice per Go community convention; the comparison-with-reference-client robustness pattern guards against silent false positives if the SDK renames the field.

---

## Information / Notes

- **INFO-1:** nginx location-block ordering verified safe — `/_matrix/media/` (length 14) takes precedence over `/_matrix/` (length 9) and `/` (length 1) under nginx's longest-prefix-match. No catch-all carve-out needed.
- **INFO-2:** `enable_media_gateway = true` + `tls_mode = "none"` leaves the media service running on `127.0.0.1:8009` with no public ingress. Not a security issue (less surface), but worth a precondition or doc note (code-review-findings.md INFO-3 already flagged).
- **INFO-3:** Pre-existing `uploader_user_id ≠ Matrix user ID` issue (MEMORY pattern from Epic 12, partially closed in Story 12.9) is NOT introduced by this story but is now exposed in StackIT production for the first time. The audit-trail correlation defeat will only become visible once StackIT deployments start running. Track via Story 12.9 follow-up; out of scope for this review.
- **INFO-4:** Pre-existing XFF rate-limit coalescing across the whole stackit stack (gateway + media share the same issue) — see MEDIUM-3. Not regressed.

---

## Summary

- **CRITICAL: 0** — no commit-blocking finding
- **HIGH: 0** — no commit-blocking finding
- **MEDIUM: 3** — advisory, address before epic-end (recommended before merge to develop)
- **LOW: 4** — advisory, hardening opportunities

**Verdict:** APPROVED (no CRITICAL or HIGH findings)

The story is safe to commit. Operators deploying this should be informed of MEDIUM-1 (`prevent_destroy` on bucket) and MEDIUM-2 (endpoint scheme validation) before first production deploy. MEDIUM-3 (nginx-level rate-limit) is a stack-wide hardening item that this story merely participates in — not a regression.

---

## Recommendations for Pipeline

1. **For this story:** Merge approved. Consider quick follow-up patches for MEDIUM-1 (one-line lifecycle block) and MEDIUM-2 (precondition tightening) before tagging v0.2.2.
2. **For the epic:** Add nginx-level `limit_req` to the next iteration as a stack-wide hardening story (covers gateway + media + admin together).
3. **For MEMORY:** Add new pattern to MEMORY.md:

> | New IaC data-bearing resources missing `prevent_destroy` | media-gateway-stackit-objectstore | `stackit_objectstorage_bucket.nebu_media` shipped without `prevent_destroy = true` — accidental destroy or var-flip removes all customer media. Rule: every Tofu resource that holds customer data (PostgresFlex, ObjectStorage buckets, S3 buckets, RDS, EFS) MUST have `prevent_destroy = true` by default. Override only via explicit `production = false` variable. Companion to "deletion_protection = false hardcoded defaults" Epic 13 pattern. |
