## Code Review Findings — Cycle 0

**0 MAJOR, 6 MINOR, 5 INFO. All 10 ACs satisfied.**

### MINOR Findings to Fix:

**MINOR-1** — `reflect` and `unsafe` imports in wrong group in `media/cmd/media/main_test.go` — they are stdlib and belong in the first stdlib import group, not a separate group.

**MINOR-2** — Reflection-on-unexported-field test is fragile across SDK upgrades. Consider a relative comparison approach instead (construct a BucketLookupAuto client as control, verify the selectStorer result differs — avoids hard-coding field name).

**MINOR-3** — Misleading nginx comment in ACME block (line ~327 in cloud-init.tftpl): "path-style S3 routing" should be "proxy to media container on loopback (port published by Docker)". Also add equivalent comment to ALB block for symmetry.

**MINOR-4** — Precondition in server.tf does not validate `s3_bucket` or `s3_endpoint`. Add validation:
```hcl
condition = !var.enable_media_gateway || (
  length(var.s3_access_key) > 0 &&
  length(var.s3_secret_key) > 0 &&
  length(var.s3_bucket) > 0 &&
  length(var.s3_endpoint) > 0
)
```

**MINOR-5** — Media healthcheck uses `curl` (`["CMD", "curl", "-f", "http://localhost:8009/health"]`) which may not be available in a slim/distroless image. Check what base image the media gateway uses. Either use `/healthcheck` binary (like gateway) or `wget -qO- http://localhost:8009/health || exit 1` for Alpine.

**MINOR-6** — Missing `NEBU_MINIO_REGION` env var in media service. StackIT Object Store works without explicit region but minio-go defaults to `us-east-1`. Investigate if this is intentional. If the existing codebase doesn't set it anywhere for minio, that's fine and should be documented as INFO. Skip if dev confirms region is not needed.

### INFO (no action required):
- INFO-1: s3_endpoint default locks to eu01 region — acceptable, mentioned in description
- INFO-2: memory_limit 256m may be tight for thumbnail generation — operational
- INFO-3: enable_media_gateway + tls_mode=none leaves media unreachable — document or add precondition
- INFO-4: stackit_objectstorage_bucket lifecycle — may want prevent_destroy = true
- INFO-5: httptest server comment confirmed adequate
