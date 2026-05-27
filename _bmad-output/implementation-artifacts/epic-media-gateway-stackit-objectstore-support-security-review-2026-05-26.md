# Epic `media-gateway-stackit-objectstore-support` — SEC Gate 2 Security Review

**Date:** 2026-05-26
**Reviewer:** Kassandra (`nebu-agent-kassandra`) — `references/epic-review.md`
**Branch:** `feature/media-gateway-support-for-stackit-objectstore`
**Diff base:** `bd8af58415e9faeb77166746ac31aa6dc6b95a75`
**Diff HEAD:** `b18f470f` (post-story-close commit)
**Effective epic commit:** `e7fc4d14` — `feat: Media Gateway StackIT Object Store support`

## Scope

- Epic: `media-gateway-stackit-objectstore-support` (single-story epic — story `stackit-objectstore-integration`)
- Stories covered: `stackit-objectstore-integration` (only)
- Per-story review reference: `_bmad-output/implementation-artifacts/stackit-objectstore-security-review-2026-05-26.md` (0 CRITICAL, 0 HIGH, 3 MEDIUM, 4 LOW — APPROVED)

**Code-bearing files in the epic diff:**

- `media/cmd/media/main.go` (+3 / −2) — MinIO client `BucketLookup: minio.BucketLookupPath`
- `media/cmd/media/main_test.go` (+107 / 0) — `TestSelectStorer_BucketLookupPath` (reflect+unsafe, test-only)
- `deploy/tofu/examples/stackit/main.tf` (+11) — optional `stackit_objectstorage_bucket.nebu_media`
- `deploy/tofu/examples/stackit/variables.tf` (+44) — 7 new variables (`enable_media_gateway`, `s3_*`, resource limits)
- `deploy/tofu/examples/stackit/server.tf` (+18) — `templatefile()` passthrough, precondition guard
- `deploy/tofu/examples/stackit/cloud-init.tftpl` (+82) — Docker Secrets, media compose service, nginx routing

**Non-code artefacts** (excluded): pipeline-state.yaml, sprint-status.yaml, code/test review markdowns, MEMORY.md, session log, story file, arc42 update, architecture doc.

---

## Process

1. Loaded `references/epic-review.md` and `references/security-review.md` to align scope.
2. Re-derived the actual epic commit (`e7fc4d14`) — the wider base→HEAD range provided spans unrelated develop-branch commits (Matrix SSO bootstrap-DB fix `bfd4884f`, OIDC extra-scopes `53904df6`, two terraform refactors); these are out of scope for this epic.
3. Re-reviewed all six code-bearing files against the full security-review.md scope.
4. Searched for cross-cutting / architectural risk specific to a single-story epic: combinations of `enable_media_gateway` × `tls_mode` × `enable_element_web` × `oidc_mode` × `NEBU_TRUSTED_PROXY`.
5. Re-checked MEMORY.md patterns relevant to this surface (MinIO secrets, XFF rate-limiting, IaC `prevent_destroy`, nginx catch-all swallow, tfstate sensitivity).
6. Sanity-checked that the per-story review's 3 MEDIUM findings are still open (none were promoted to follow-up stories yet) and that they do not promote to HIGH at the epic level.

---

## Findings

| # | Severity | Story | Location | Vulnerability | Status |
|---|----------|-------|----------|---------------|--------|
| E-1 | MEDIUM | stackit-objectstore | `deploy/tofu/examples/stackit/main.tf:32-39` | Bucket lacks `lifecycle { prevent_destroy = true }` — `tofu destroy` or `enable_media_gateway = false` re-apply will permanently delete the production media bucket. | Carried from per-story (MEDIUM-1). Still open. |
| E-2 | MEDIUM | stackit-objectstore | `deploy/tofu/examples/stackit/server.tf:160-170` | Precondition does not validate `s3_endpoint` scheme — operator pasting `http://…` or a scheme-prefixed value silently breaks SigV4 or invites SSL-downgrade workarounds. | Carried from per-story (MEDIUM-2). Still open. |
| E-3 | MEDIUM | stackit-objectstore | `deploy/tofu/examples/stackit/cloud-init.tftpl:215-223` and `:329-337` | New `/_matrix/media/` nginx location has no `limit_req` zone — combined with `NEBU_TRUSTED_PROXY=true` and ALB-in-front topology, the Go-side rate-limiter coalesces all clients into one bucket (rightmost-XFF is the ALB IP). | Carried from per-story (MEDIUM-3). Still open. |
| E-4 | LOW | stackit-objectstore | `deploy/tofu/examples/stackit/cloud-init.tftpl:28-39` | `content: "${s3_access_key}"` uses YAML double-quoted scalar — `"` / `\` / `\n` in a future credential would break cloud-init parse silently. | Carried from per-story (LOW-1). |
| E-5 | LOW | stackit-objectstore | `deploy/tofu/examples/stackit/cloud-init.tftpl:25-39` | `.secrets` directory `chmod 0700` runs in `runcmd`, but write_files creates files (0600) before the directory is locked down — short window where `ls /opt/nebu/.secrets/` leaks filename presence. | Carried from per-story (LOW-2). |
| E-6 | LOW | stackit-objectstore | `deploy/tofu/examples/stackit/main.tf:32-39` | No explicit `acl = "private"`, `versioning`, or `block_public_access` — relies on StackIT defaults (private + non-versioned + no object-lock). | Carried from per-story (LOW-3). |
| E-7 | LOW | stackit-objectstore | `deploy/tofu/examples/stackit/cloud-init.tftpl:520` | `NEBU_STORAGE_BACKEND: "minio"` for StackIT Object Store — naming may confuse operators who expect `"s3"` / `"stackit"`. Operational, not exploitable. | Carried from per-story (LOW-4). |

**No new findings beyond the per-story review.** All 3 MEDIUM and 4 LOW findings are pre-existing from SEC Gate 1.

---

## Detail

### Findings E-1 – E-7

All seven findings have full detail (vulnerability, exploit path, remediation HCL/YAML snippets) in the per-story review at `_bmad-output/implementation-artifacts/stackit-objectstore-security-review-2026-05-26.md` lines 46–143. Not duplicated here to keep this document focused on epic-level new analysis.

---

## Cross-Cutting / Epic-Level Analysis

The task brief asked for five specific focus areas. Each was checked; results below.

### 1. Attack surface from media service + nginx/gateway combination

**Result: clean (no new exploitable surface).**

The media container is published as `127.0.0.1:8009:8009` (loopback only). External traffic reaches the media service only via:

| `tls_mode` | Path |
|---|---|
| `alb` | Stackit ALB → nginx (port 80, Docker network) → `http://media:8009` |
| `acme` | Public TCP → certbot/nginx (port 80/443) → `http://127.0.0.1:8009` |
| `none` | No nginx — media is NOT externally reachable. Functional gap, not a security risk. |

Verified clean:
- No new `0.0.0.0:8009` binding. The host port is loopback-only.
- The Docker Compose network exposes port 8009 to the `gateway`, `core`, and `nginx` services internally, which is intended.
- The nginx `/_matrix/media/` location matches BEFORE `/_matrix/` and BEFORE `/` (catch-all) under nginx's longest-prefix-match rule. There is no path-confusion route precedence bug.
- Stackit ALB → VM:80 routing is unchanged by this story. The ALB's target group still points at the VM nginx, not at port 8009.

### 2. Auth bypass / routing confusion between `/_matrix/media/` and `/_matrix/`

**Result: clean.** Verified by manual trace:

```
/_matrix/media/v3/upload     → matches /_matrix/media/  → media:8009  (auth: handler-side OIDC verifier)
/_matrix/media/v3/download   → matches /_matrix/media/  → media:8009  (auth: spec-defined unauth)
/_matrix/client/v3/login     → matches /_matrix/   (if enable_element_web=true) OR / (catch-all)  → gateway:8008
/_matrix/client/v3/sync      → same as above → gateway:8008
/admin/                      → matches /admin/    (if enable_element_web=true) OR / (catch-all) → gateway:8008
```

There is no path under `/_matrix/media/` served by the gateway in Nebu's current design, so the prefix carve-out is total. No risk of accidentally bypassing gateway auth middleware via the media route. The media service maintains its own auth chain (Story 12.7/12.8 hardening — bearer-token OIDC verification on upload, unauthenticated download per Matrix spec, both rate-limited).

When `enable_element_web=false`, the nginx config is:
- `/_matrix/media/` → media (if `enable_media_gateway=true`)
- `/` (catch-all) → gateway

This means `/_matrix/client/v3/login`, `/admin/`, etc. fall through to the catch-all. Functionally correct; no auth bypass.

### 3. Credentials handling in IaC — tfstate exposure, `sensitive=true`

**Result: acceptable for MVP; documented pre-existing risk.**

| Layer | Storage | Status |
|---|---|---|
| `var.s3_access_key`, `var.s3_secret_key` | tfvars / env | `sensitive = true` set — tfplan/console redacts. Verified at `variables.tf:99-104` and `:106-111`. |
| `stackit_objectstorage_bucket.nebu_media.*` (bucket resource attributes) | tfstate | Only `project_id` and `name` — no credentials. Verified. |
| `stackit_server.nebu.user_data` (rendered cloud-init) | tfstate | **Contains rendered s3 credentials inline.** Same pattern as `internal_secret`, `oidc_client_secret`, `pg_password`, `pii_encryption_key`, `key_encryption_key`. Already documented in `server.tf:36-39`. |

The `user_data` attribute contains rendered cloud-init which includes the s3 secrets as `content:` lines in the write_files block. Stackit's Terraform provider does not mark `user_data` as sensitive on the underlying resource, so it appears in tfstate in plaintext.

This is **pre-existing**: the same risk applies to all eight other secret-bearing variables already in this template. The mitigation is explicit and on record at `server.tf:36-39`:

> SECURITY NOTE: cloud-init template including secrets is stored in Terraform state. Use encrypted state backend (Stackit Object Storage with server-side encryption) in production.

The epic introduces **two more variables** (`s3_access_key`, `s3_secret_key`) into the same pattern. No regression, but the existing mitigation note should explicitly call out the new variables. **LOW**, advisory.

**Tooling check — `tofu plan` output:** Variables are correctly `sensitive = true`, so `tofu plan` shows `(sensitive value)` for both. Pipeline logs of `tofu plan` will not leak the credentials. Verified.

**Tooling check — `tofu show` / `tofu state pull`:** Will reveal the credentials. This is the documented risk and the standard mitigation (encrypted state backend) covers it.

**Verdict: no new CRITICAL/HIGH, no commit-blocking finding.** The epic does NOT introduce a new tfstate-leak class — it extends an existing class. The story's MEDIUM findings already capture the operationally-relevant new concerns.

### 4. Docker Secrets pattern correctness

**Result: clean.** Verified line-by-line:

| Check | Status |
|---|---|
| `write_files` block writes `s3_access_key` and `s3_secret_key` to `/opt/nebu/.secrets/` | OK — lines 28-39 of cloud-init.tftpl. |
| File permissions `0600`, owner `root:root` | OK — explicit. |
| Docker Compose top-level `secrets:` block declares `s3_access_key` and `s3_secret_key` with `file: .secrets/s3_access_key` and `.secrets/s3_secret_key` | OK — lines 419-424. Paths are relative to docker-compose.yml location (`/opt/nebu/`). |
| `media` service `secrets:` list mounts both | OK — lines 514-516. |
| `media` service environment uses `NEBU_MINIO_ACCESS_KEY_FILE: "/run/secrets/s3_access_key"` and `NEBU_MINIO_SECRET_KEY_FILE: "/run/secrets/s3_secret_key"` | OK — lines 524-525. Docker Secret mount path is `/run/secrets/<secret_name>` (Docker default, not configurable). |
| Go consumer `readSecretFile()` (existing) at `media/cmd/media/main.go` | OK — strips whitespace, returns plain string. Used to populate `cfg.minioAccessKey`. |
| No env-var fallback that exposes the raw secret | OK — `NEBU_MINIO_ACCESS_KEY` is not set in the compose block; only the `_FILE` variant. Avoids the "leaked-via-env" pattern. |
| `minio.New()` uses `credentials.NewStaticV4(cfg.minioAccessKey, cfg.minioSecretKey, "")` — no global session token, no rotation hook | OK for MVP. Static creds rotation is operator-initiated (write new secret file → restart container). |

**One LOW-severity observation (carried as E-5):** the directory `chmod 0700` happens later in `runcmd`, leaving a small window where the parent dir is umask-default. File contents are 0600-protected during the window — only listing is exposed. Pre-existing pattern; not a regression.

**Pattern alignment check (per MEMORY):** "MinIO `mc` entrypoint argv leak" (Epic 12) — N/A here. No `mc` entrypoint shell; credentials never expanded into argv. Confirmed clean.

### 5. New nginx `/_matrix/media/` route — rate-limiting & body-size

**Result: 1 MEDIUM (carried), otherwise clean.**

| Check | Status |
|---|---|
| `client_max_body_size 50m` on the new location | OK — matches `NEBU_MEDIA_MAX_UPLOAD_BYTES=52428800` Go-side default (Story 12.6). |
| `limit_req_zone` / `limit_req` at nginx layer | **Missing** (MEDIUM-3 / E-3). Relies entirely on Go-side rate-limiter, which the `NEBU_TRUSTED_PROXY` + ALB topology degrades to one shared bucket. |
| `proxy_read_timeout` / `proxy_send_timeout` override for media | Missing — inherits server-level 90s. Acceptable for `/sync`, slightly excessive for media; not a security issue. |
| `proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for` | OK — chain-preserving. |
| `proxy_set_header X-Forwarded-Proto https` | OK — explicit (mitigates the open-redirect / cookie-secure-flag class for any future media response). |
| `proxy_set_header Host $host` | OK. |
| WebSocket upgrade headers (`Upgrade`, `Connection`) | Not set — media service does not use WebSockets, so omission is correct. |
| TLS termination at nginx (tls_mode = "acme") | Plain HTTP between nginx and media on loopback — OK, never leaves the VM. |
| TLS at ALB (tls_mode = "alb") | Stackit ALB → VM:80 in plaintext on the Stackit internal network — pre-existing concern, not regressed. Documented at `server.tf:53-55`. |

**Pattern alignment check (per MEMORY):** "XFF rate-limit spoofing" (Epic 12) — does NOT apply here as the inverse exact problem (all clients coalesced into ALB-IP bucket). Captured in E-3.

### 6. Additional epic-level checks performed

| Concern | Result |
|---|---|
| Cross-story auth chain (auth in story 1 bypassed in story 5) | N/A — single-story epic. |
| Migration chain integrity (SQL data evolution across stories) | N/A — no SQL migrations in this epic. |
| Architectural pattern emergence (anti-pattern at scale) | Three repeated IaC patterns flagged: (a) data-bearing resources lacking `prevent_destroy` — already in MEMORY post-Epic 13; (b) `tfstate` cloud-init secret embedding — pre-existing, acknowledged in server.tf comments; (c) write_files-before-runcmd directory-permission race — pre-existing pattern for `internal_secret`. |
| Test-only `unsafe.Pointer` in `main_test.go` | OK — confined to `_test.go` files via Go toolchain. `unsafe` package import is not present in `main.go`. No production code touched by reflection trick. |
| Backwards-compatibility of `BucketLookupPath` change | OK — MinIO upstream supports path-style equally; AWS S3 supports both with virtual-hosted being the default. This is a transport-layer change (URL form), not an auth or signing change. SigV4 signing on `*minio.Client` uses the resolved URL, so signature integrity is unaffected. No security implication. |
| New Tofu provider dependency `stackit_objectstorage_bucket` | Same Stackit provider already in use; no new supply-chain edge. |

---

## Accepted Risks

None. All MEDIUM/LOW findings remain open as advisory items (per the per-story review's standing).

---

## Follow-up Stories Required

**None mandatory for this epic to merge.**

The three MEDIUM findings (E-1, E-2, E-3) are advisory at SEC Gate severity definitions — they require specific conditions or chaining to exploit (defense-in-depth weaknesses). The per-story Kassandra verdict was APPROVED, and the epic review concurs: no CRITICAL or HIGH was found.

**Strongly recommended follow-up patches** (operator-facing, low risk, single-line each):

1. **E-1 patch** (1 line in `main.tf`): add `lifecycle { prevent_destroy = true }` to the bucket resource. Prevents irrecoverable data loss on operator error or `tofu destroy`.
2. **E-2 patch** (1 line in `server.tf` precondition): forbid `s3_endpoint` starting with `http://` or `https://`. Prevents silent SSL-downgrade workarounds.

These are recommended **before** tagging the next release (`v0.2.2` or wherever this epic lands). The pipeline pre-merge gate is PASS regardless.

**Recommended cross-cutting follow-up** (separate epic, not blocking):

3. **E-3 cross-cutting**: add nginx-level `limit_req_zone $binary_remote_addr zone=nebu:10m rate=10r/s` at the `http {}` level and apply `limit_req` to all proxied locations (gateway, media, dex, element). Couples with `set_real_ip_from <ALB-CIDR>; real_ip_header X-Forwarded-For;` to make the limit operate on real client IPs. This is a whole-stack hardening — track as a dedicated security story, not as part of this epic.

---

## Summary

- **CRITICAL: 0**
- **HIGH: 0**
- **MEDIUM: 3** (all carried from per-story review; none new)
- **LOW: 4** (all carried from per-story review; none new)

**New findings beyond per-story:** 0.
**Follow-up stories required (CRITICAL/HIGH only):** 0.
**Accepted risks:** 0.

**Epic security gate: PASS.**

The epic is safe to merge to `develop`. CRITICAL/HIGH = 0 means the SEC Gate 2 mandatory threshold is not triggered. The three MEDIUM findings are advisory hardening items that should ideally land as quick follow-up patches before the next release tag, but they do not block this epic from being marked `done`.

---

## Notes for the Audit Trail

- The diff range provided by the pipeline (`bd8af58415e9faeb77166746ac31aa6dc6b95a75..HEAD`) spans more than just this epic (Matrix SSO bootstrap-DB fix, OIDC extra-scopes, Stackit TLS-mode refactor are also present). Those changes were excluded from this review as they are not part of the `media-gateway-stackit-objectstore-support` epic. They were already SEC-reviewed in their respective branches (`bugfix/custom-scopes-in-matrix-sso` and `bugfix/stackit-deployment`).
- The actual single epic commit is `e7fc4d14`, with `1b5f8ffa` and `b18f470f` as pipeline state housekeeping.
- This review file's existence is required even at 0 new findings for SEC Gate 2 audit-trail continuity (per `references/epic-review.md` line 11).
