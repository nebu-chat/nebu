Oracle findings — story 9c-mime-denylist-enforcement, matrix-spec v1.18, client-server-api/index.html

## Q1 — Applicable spec rules

- Endpoints: `POST /_matrix/media/v3/upload` (line 34559) and `PUT /_matrix/media/v3/upload/{serverName}/{mediaId}` (line 34784, added v1.7)
- No event types involved — pure media-repo HTTP endpoints, not room events
- Content-Type header: **Optional** on both endpoints; **MUST default to `application/octet-stream`** if absent (changed in v1.12) — a denylist check MUST account for the defaulted value, not just an explicit header
- **Spec-defined rejection code for "server does not permit the file type" is `403 M_FORBIDDEN`** on BOTH endpoints (line 34899–34908 PUT; line 34647–34653 POST) — NOT `400 M_BAD_JSON`
- `M_BAD_JSON` (common errcode, line 3418–3420) is defined as "valid JSON but malformed (missing keys/invalid values)" — semantically a JSON-body error; upload request bodies are raw bytes, so this errcode's canonical spec meaning does not literally apply to a content-type rejection
- Spec MUST: every error response is the "standard error response" JSON object `{errcode, error}` (line 3389–3404); both `errcode` and `error` keys MUST always be present
- Spec does NOT mandate byte-sniffing vs header-trust — no spec language on how a server determines/validates the declared Content-Type
- Both endpoints are rate-limited (429/M_LIMIT_EXCEEDED) and require auth — unrelated to denylist but must not be short-circuited incorrectly
- PUT-specific additional codes (404 M_NOT_FOUND unknown/expired MXC, 409 M_CANNOT_OVERWRITE_MEDIA already-uploaded) — a denylist check MUST be ordered consistently with these (Nebu's own precedent: content-type check runs before body read/size check)
- **Compliance gap vs spec**: Nebu's existing `upload/1` precedent (`@blocked_upload_types` → 400 M_BAD_JSON) already deviates from the spec's 403/M_FORBIDDEN convention for this exact scenario; story 9c explicitly continues that same non-spec-standard error shape for consistency with existing Nebu behavior, not spec conformance. NOTE: this is a KNOWN, EXPLICIT, ALREADY-JUSTIFIED decision in the story text itself (AC2 + Technical Requirements "Error shape" section) — not a new finding to act on, just confirmed by the oracle. Do not "fix" this to 403/M_FORBIDDEN during dev — that would contradict the story's explicit intent to mirror the existing precedent.

## Q2 — MUST-test error codes / edge cases

- `errcode`/`error` keys present in every rejection response (standard error response shape)
- 400 M_BAD_JSON path (Nebu-internal convention) — verify status+errcode+body match precedent exactly
- Content-Type absent → defaults to `application/octet-stream`; verify denylist matches against the *defaulted* value, not a raw absent header
- Case-sensitivity of Content-Type prefix match (`String.starts_with?` is case-sensitive; spec doesn't mandate MIME case-folding — worth a test either way given HTTP header casing varies)
- Content-Type with parameters, e.g. `text/html; charset=utf-8` — prefix match against `text/html` boundary
- Empty `mime_denylist` ("") → zero rejections (AC4)
- Multiple comma-separated prefixes, one matching
- Interaction/ordering with existing PUT error precedence: 403 (forbidden-type/quota/wrong-user), 404 (bad MXC), 409 (already uploaded), 413 (too large) — denylist rejection must fire before size check (AC2) and not clobber these
- No body/bytes read before rejection (can't be black-box tested via spec but is an AC — test via no storage write / no scan job side effect)
- Live-reconfiguration: denylist changed between two PUTs, no restart (AC5) — Config TTL/pg-cache path
- Both endpoints if legacy POST also wired: same rejection behavior parity

Relevant spec locations: `client-server-api/index.html` lines 3388–3430 (standard error response, common error codes), 34559–34760 (POST /_matrix/media/v3/upload), 34784–35060 (PUT /_matrix/media/v3/upload/{serverName}/{mediaId}).
