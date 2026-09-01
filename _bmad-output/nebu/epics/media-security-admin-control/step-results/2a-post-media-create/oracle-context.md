## Oracle Gate — 2a-post-media-create

Source: CS API v1.18, `POST /_matrix/media/v1/create` (added v1.7, no MSC label remains).
Confirmed against local spec bundle (`client-server-api/index.html` #post_matrixmediav1create).

### MUST requirements
1. No request parameters or request body — spec text literally: "No request parameters or request body." Story AC6 (silently ignore stray query params) is a Nebu addition, not spec-mandated, but does not conflict.
2. Requires authentication: Yes. Rate-limited: Yes (standard boilerplate — satisfied here by AC3's pending-count 429, not a separate IP bucket; spec's own prose ties the 429 to *this* pending-upload limit, not a generic token bucket).
3. 200 response body MUST include both `content_uri` (Required) and `unused_expires_at` (present in spec's schema, described as SHOULD-include but modeled as always-present integer in the example — story's "both required" is the safe interpretation).
4. `unused_expires_at`: server sets it, recommended default 24h — matches story AC2/AC6 exactly (no client `expires_at` input exists in spec at all).
5. Server SHOULD cap concurrent *pending media uploads* per user, defined precisely as: mxc created AND (not yet uploaded) AND (not yet expired) — matches story AC3's `:reserved`-state count. On exceeding: 429 `M_LIMIT_EXCEEDED`.
6. 403 response: "The user does not have permission to upload the content" — errcode `M_FORBIDDEN`, example message "Cannot upload this content". Matches story AC4.
7. `mxc://` URI construction: `mxc://<server_name>/<media_id>` per Matrix Content URI section — matches story AC5. No federation implication needs handling since Nebu is local-only (ADR-021).

### Spec-defined error codes / status codes to test-cover
- `200` — success, body `{content_uri, unused_expires_at}` (both fields).
- `403 M_FORBIDDEN` — no upload permission. Body: `{errcode, error}`.
- `429 M_LIMIT_EXCEEDED` — pending-upload cap exceeded. Body: `{errcode, error, retry_after_ms}` — `retry_after_ms` is part of the spec's own `RateLimitError` schema (integer, ms), not a Nebu invention. Story AC3 correctly requires it.
- `401 M_MISSING_TOKEN` / `M_UNKNOWN_TOKEN` — standard auth gate (not endpoint-specific in spec, handled by existing OidcPlug pipeline).
- No `201`, no `404`, no `409` apply to `/create` itself (those belong to the sibling `PUT /upload/{serverName}/{mediaId}` — Story 2b, out of scope here).
- Query-parameter tolerance (AC6, silently ignoring stray params) is a Nebu robustness choice, not a spec requirement — do not test it as if it were spec-mandated, but it's harmless to keep.

### Verdict
Story's ACs 1–7 are fully spec-aligned; no corrections needed (the 2026-07-01 Oracle epic review already fixed the historical draft's gaps — this story correctly incorporates all of them: no client expires_at, mandatory unused_expires_at in response, pending-count 429 with retry_after_ms, 403 M_FORBIDDEN). Confirmed 200 (not 201) is correct.
