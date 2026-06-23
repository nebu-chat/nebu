# Oracle Gate — Matrix Content-Repository Parity (media-gateway-migration)

Reconstructed from coordinator-provided oracle-gate flags (the original sub-agent's
output was not persisted to disk). Matrix Client-Server API v1.18 content-repository module.

## Scope of this story

- Targets the **deprecated `/_matrix/media/v3/`** endpoints only.
- Authenticated `/_matrix/client/v1/media/...` endpoints are an **open follow-up**, NOT in scope here.

## Endpoints (Matrix v1.18 content-repository)

| Method | Path | Notes |
|---|---|---|
| PUT | `/_matrix/media/v3/upload` | Returns `{"content_uri":"mxc://<server>/<mediaId>"}`. Requires auth. |
| GET | `/_matrix/media/v3/download/{serverName}/{mediaId}` | Streams bytes. |
| GET | `/_matrix/media/v3/download/{serverName}/{mediaId}/{fileName}` | Same, with download filename. |
| GET | `/_matrix/media/v3/thumbnail/{serverName}/{mediaId}` | Query: `width`, `height`, `method` (`crop`/`scale`). |
| GET | `/_matrix/media/v3/preview_url` | Query: `url`, `ts`. Returns OG-meta JSON. |

## Spec MUSTs / parity rules (honor these)

1. **Content-Disposition is a v1.12 MUST.** Download/thumbnail responses MUST include a
   `Content-Disposition` header. For `application/octet-stream` and most types use
   `attachment`; for a known-safe inline-renderable allowlist (image/*, video/*, audio/*,
   text/plain, application/pdf etc. per spec) `inline` is permitted. Always include the header.
   The legacy Go handler may have omitted it — INCLUDE it now.

2. **Content-Type** MUST be returned matching the stored media type. Combine with
   `X-Content-Type-Options: nosniff` (already a project standard) to prevent sniffing.

3. **`mxc://` URI** format: `mxc://<server_name>/<media_id>`. media_id is an opaque
   server-generated identifier (cryptographically random per Implementation Notes).

4. **Range requests** — `206 Partial Content` with `Content-Range: bytes <start>-<end>/<total>`
   and `Accept-Ranges: bytes`. Malformed/unsatisfiable ranges → `416 Range Not Satisfiable`.

5. **preview_url** — returns OG meta as a flat JSON object (`og:title`, `og:description`,
   `og:image`, optionally `matrix:image:size`). `og:image` if present should be an mxc URI
   in full spec; for this story extracting the OG tags as JSON satisfies AC5.

6. **Error format** — Matrix standard error JSON `{"errcode":"...","error":"..."}`.
   Common: `M_NOT_FOUND` (unknown media), `M_TOO_LARGE` (over upload limit → 413),
   `M_FORBIDDEN`, `M_UNKNOWN` / `M_UNRECOGNIZED`.

7. **Upload size limit** — server advertises `m.upload.size` via
   `/_matrix/media/v3/config`; over-limit uploads return `413 M_TOO_LARGE`. Enforce a
   body-size limit on upload (security: missing body-size limit).

## Nebu-specific deviations (deliberate, NOT spec violations)

- **AC4 room-membership 403 is a Nebu EXTENSION, not a Matrix MUST.** In the Matrix spec
  media is NOT room-scoped — any authenticated user can download any media id. Nebu adds a
  room-membership access-control check returning
  `403 {"errcode":"M_FORBIDDEN","error":"You are not a member of this room"}`.
  This is intentional project policy; do not "fix" it to match spec. Implemented as a local
  OTP call (`RoomManager.member?/2`) replacing the former gRPC `CheckMembership`.

## Security flags carried into review

- **preview_url needs SSRF guarding** (Kassandra concern): block fetches to private/loopback/
  link-local/metadata IP ranges, enforce scheme allowlist (http/https), cap redirects and
  response body size, set timeouts. The `url` query param is fully attacker-controlled.
- **Path traversal**: media_id / serverName must not be usable to traverse S3 keys or FS paths.
- **Body-size limit** on upload (M_TOO_LARGE / 413).
- **Range-header abuse**: reject overlapping/huge/negative ranges; 416 on unsatisfiable.
- **Content-type sniffing**: nosniff + correct Content-Type + Content-Disposition.
- **Crypto correctness** for encrypted media (ADR-011 managed E2EE key escrow): AES-GCM
  parity with the Go `media/internal/crypto` implementation.
