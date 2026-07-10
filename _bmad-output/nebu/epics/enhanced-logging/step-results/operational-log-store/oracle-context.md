Compliance findings for `operational-log-store` (infra story; no new CS API endpoint):

## 1. Applicable Matrix Rules (ID Grammar — appendices §Common Identifier Format)
- Sigils (MUST): `@`=user, `!`=room, `$`=event, `#`=room alias.
- User ID: `@localpart:domain`; compliant localpart chars MUST be `[a-z0-9._=/+-]`; historical/federation localparts MAY contain any non-surrogate Unicode except `:` and NUL (incl. control chars, incl. empty) — normalizer MUST NOT assume charset.
- User ID total length MUST NOT exceed 255 bytes.
- Room ID: `!opaque` (v6+ URL-safe-base64, no domain) OR `!opaque:domain` (older); localpart may contain any Unicode except `:`/NUL; total MUST NOT exceed 255 bytes.
- Event ID: `$opaque` — v6/v11 URL-safe base64 (`-`,`_`, no padding), no domain, e.g. `$Rqnc-F-dvnEYJTyHq_iKxU2bZ1CI92-kuZq3a5lr5Zg`; v1/v2 room versions: `$hash:domain` with standard base64 (contains `+` and `/`); ≤255 bytes.
- Room alias: `#localpart:domain`; localpart MAY be arbitrary Unicode except `:`/NUL; ≤255 bytes.
- `state_key` MUST NOT exceed 255 bytes; MAY be arbitrary content (only `m.room.member` etc. constrain it to a user ID) — sensitive-data risk.

## 2. Route Shapes RequestLogger Will See (normalize these segments)
- `/_matrix/client/v3/rooms/{roomId}/send/{eventType}/{txnId}`
- `/_matrix/client/v3/rooms/{roomId}/state/{eventType}/{stateKey}`
- `/_matrix/client/v3/rooms/{roomId}/{event,messages,members,join,invite,leave,kick,ban,typing/{userId},receipt/{type}/{eventId},read_markers,redact/{eventId}/{txnId}}`
- `/_matrix/client/v3/{sync,login,logout,createRoom,join/{roomIdOrAlias},publicRooms,capabilities,versions}`
- `/_matrix/client/v3/{profile,presence}/{userId}/...`, `/user/{userId}/{account_data,rooms/{roomId}/account_data,filter}/{type}`
- `/_matrix/client/v3/directory/room/{roomAlias}`, `/devices/{deviceId}`, `/keys/...`
- IDs in paths arrive percent-encoded (`%21`,`%40`,`%24`,`%23`,`%3A`) — decode-or-match both forms.

## 3. Test Coverage MUST (sensitive-data / edge cases)
- `route_template` MUST replace `{roomId}`,`{userId}`,`{eventId}`,`{roomAlias}`,`{txnId}`,`{stateKey}`,`{eventType}`,`{type}`,`{deviceId}` — assert no raw ID leaks into template.
- `{stateKey}` MUST be normalized to placeholder (arbitrary/sensitive content) — do NOT echo verbatim; test with non-user-ID state_key.
- `{roomAlias}` and historical user localparts with Unicode/`+`/`/` chars — test normalizer does not fail-open (leaving raw ID) on non-standard charset.
- Event IDs containing `/` (v1/v2 standard-base64) and `-`/`_` (v6) — test path splitting not broken.
- Percent-encoded ID segments (`%21...%3A`) — test they still normalize.
- Redaction (project LAW): tokens/credentials AND chat message content in request/response payload bodies MUST be redacted; assert `access_token`, `password`, message `body`/`content` never persisted or broadcast.
- No CS API errcodes/HTTP-status assertions required — story adds no endpoint; RequestLogger MUST pass status through unchanged for all codes (200/4xx/5xx) and log `status`+`duration_ms`.

Spec files: `skills/nebu-agent-oracle/matrix-spec/v1.18/appendices/index.html` (lines 719-905); `skills/nebu-agent-oracle/matrix-spec/v1.18/rooms/v6/index.html` (lines 796-805).

## Pipeline-specific note (operational-log-store story)
The story's own `route_normalizer.ex` design sketch in Dev Notes only handles room IDs and user IDs — it does NOT mention `state_key` normalization. Per the spec finding above, `state_key` is a route path segment (`/rooms/{roomId}/state/{eventType}/{stateKey}`) that MAY contain arbitrary/sensitive content and MUST also be replaced by a placeholder, not left as a fallback "opaque ID-shaped segment → :id" pattern that might fail to match non-ID-shaped state_key values (e.g., a state_key that is plain text, empty string, or contains spaces/punctuation not matching the `[a-f0-9\-]{32,}` regex in the Dev Notes example). This is a gap ATDD/dev-story must close: add explicit `/state/{eventType}/{stateKey}` pattern handling in the normalizer, with a test using a non-UUID-shaped state_key.
