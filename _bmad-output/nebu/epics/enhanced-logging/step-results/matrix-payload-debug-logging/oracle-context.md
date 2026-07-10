## 1. Applicable Matrix CS API surface + MUST requirements

**Nature:** Internal logging/redaction plug, not a CS API endpoint. No new endpoint/event type/server behavior. Matrix relevance = enumerating fields the redactor MUST catch across wire formats Nebu already serves.

**Credential-bearing fields (redact → `***REDACTED***`):**
- `POST /_matrix/client/v3/login`, `/register`, `/account/password`: request `password`, `auth.password`, `new_password`; response `access_token`, `refresh_token`
- `POST /_matrix/client/v3/refresh`: request+response `refresh_token`, response `access_token`
- UIAA (`auth` object, any endpoint): `password`, `token`, `session` secrets
- HTTP `Authorization: Bearer <token>` header (all authed endpoints)
- Query-param `access_token=` (deprecated auth style) — MUST also be redacted (URL/path logging)

**Message-content fields (redact → `***MESSAGE_CONTENT***`):**
- `PUT /rooms/{roomId}/send/{eventType}/{txnId}` + `/state/...`: `content.body`, `content.formatted_body`, `content.filename`
- All msgtypes (m.text/m.notice/m.emote/m.image/m.file/m.audio/m.video/m.location) carry `body`; captions/`formatted_body`
- Other content-bearing types: `m.room.topic` `content.topic`, `m.room.name` `content.name`, `m.reaction` `content["m.relates_to"].key`, `m.room.encrypted` `content.ciphertext`, `m.sticker` `body`
- `/sync` response: `rooms.*.timeline.events[].content.body` and all state/ephemeral content bodies
- `GET /rooms/{roomId}/messages`, `/context/{eventId}`, `/event/{eventId}`, `/search`: same `content.body` nesting

**Behavioral MUST:**
- Redaction MUST be recursive/depth-independent — `content.body` nests differently per endpoint; flat key scan is insufficient.
- MUST NOT rely on event `type` allowlist — redact `content.body` regardless of event type (unknown/custom types included).
- `m.room.encrypted` payloads are opaque but still MUST be redacted (contain user data).
- Access-token redaction MUST be format-agnostic (opaque bytes) — match by key/header name, not value pattern.

## 2. Error codes / HTTP status / edge cases to test-cover

Plug does not alter responses — no new/changed `M_*` errcode or HTTP status. Edge cases for `PayloadRedactor.redact_payload/1`:
- Empty/`nil`/non-JSON (binary, form-encoded, multipart media upload) body → returned unchanged, no crash
- Invalid/malformed JSON → not parsed, not leaked verbatim at DEBUG
- Nested arrays of events (sync `timeline.events`, `/messages` `chunk`) → every element redacted
- Both categories present in one payload (login body + token in response) → both redacted
- Key-name case/variant collisions: `access_token` vs. `token`, `Authorization` header case-insensitive
- Deeply nested `content.body` (context/search bundled results) reached
- Redaction MUST be idempotent (running twice yields identical output)
- Media upload/download bodies (binary) MUST NOT be JSON-parsed or logged as text
- This logic is in-process only → test via direct `redact_payload/1` unit tests (AC10), not HTTP acceptance tests. AC8 (Kassandra SEC gate) is a security-review assertion, not a CS-API behavioral test.
