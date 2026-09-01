# Oracle Gate — 2b-put-media-upload

## Endpoint: PUT /_matrix/media/v3/upload/{serverName}/{mediaId} (added v1.7)

MUST requirements (spec v1.18, `#put_matrixmediav3uploadservernamemediaid`):
- Rate-limited: Yes. Requires authentication: Yes.
- Permits uploading content to an mxc:// URI created earlier via POST /_matrix/media/v1/create.
- `Content-Type` header: Optional (changed in v1.12 — explicitly optional with default).
  Defaults to `application/octet-stream` if not set. Clients SHOULD supply it but MUST NOT
  be required to.
- `mediaId` (path, required), `serverName` (path, required) — from the mxc:// URI.
- `filename` (query, optional) — name of the file being uploaded.
- Request body: raw bytes, `application/octet-stream`.
- 200 response body: `{}` (empty object) — no content_uri echo.

## Spec-defined error codes / status codes (MUST test-cover)

- **200** — upload successful, body `{}`.
- **403 M_FORBIDDEN** — user lacks permission. Spec lists 3 reasons (any can apply):
  server doesn't permit file type; user reached upload quota; **request comes from a
  different user than the one that called POST /_matrix/media/v1/create**. Story 2b's
  AC3 only implements the "different user" case — file-type and quota reasons are out
  of this story's scope (denylist is Story 9c, quota is Story 2a's max_pending_per_user,
  not re-checked here).
- **404 M_NOT_FOUND** — invalid MXC ID. Spec lists 2 reasons: MXC ID was not created
  via /create (no matching row); MXC ID has expired. Story's AC4 matches exactly.
- **409 M_CANNOT_OVERWRITE_MEDIA** — media ID already has content (i.e. not in a state
  where content acceptance is still valid). Story's AC5 matches.
- **413** — uploaded content too large for the server (no errcode mandated in spec body
  table, but Nebu's existing sync-upload path uses M_TOO_LARGE per project convention —
  story's AC6 follows existing convention, consistent with prior stories in this epic).
- **429** — rate-limited (out of scope for this story's logic — handled generically by
  `Nebu.Web.Plugs.RateLimit`, already wired in the route per Technical Requirements).

## Edge cases confirmed as spec-consistent (no gaps found)

- Ownership check (403) is evaluated independent of current row state — spec's 403
  reason #3 ("different user") doesn't carve out an exception for terminal states, so
  AC3's "even :released/:infected → 403 for wrong user" is spec-compliant, not an
  over-extension.
- 404 "expired" reason is Nebu's own `unused_expires_at` mechanism (spec says "MXC ID
  has expired" without prescribing the exact means) — the live-check-not-cron-dependent
  requirement (AC4) is an implementation detail spec is silent on but does not forbid.
- Spec's 403 "file type" and "quota" reasons are NOT part of this story — do not
  conflate with AC3. If test coverage is added for those, they belong to Stories 9c
  (mime denylist) and 2a (pending-count quota), not 2b.

## Verdict

Story 2b's route, header/param handling, and all 5 response codes (200/403/404/409/413)
match the Matrix CS API spec v1.18 verbatim. No spec gaps found. Proceed to ATDD.
