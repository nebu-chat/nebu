# Oracle context: server-side-key-backup (Matrix CS v1.18, "Server-side key backups")
Source: skills/nebu-agent-oracle/matrix-spec/v1.18/client-server-api/index.html (concept L39536; endpoints L39754-42700). All endpoints: auth required, rate-limited (429 M_LIMIT_EXCEEDED + retry_after_ms).

- POST /room_keys/version: body {algorithm (req, m.megolm_backup.v1.curve25519-aes-sha2), auth_data (req, object)} -> 200 {"version": "<string>"}.
- GET /room_keys/version: latest backup -> 200 {algorithm, auth_data, count:int, etag:string, version:string}; 404 M_NOT_FOUND when none.
- GET /room_keys/version/{version}: same shape; 404 M_NOT_FOUND when unknown.
- PUT /room_keys/version/{version}: only auth_data modifiable; body {algorithm (must equal existing), auth_data, version (optional, must equal path)} -> 200 {}; 400 M_INVALID_PARAM on algorithm or version mismatch; 404 unknown.
- DELETE /room_keys/version/{version}: deletes info + all keys -> 200 {}; IDEMPOTENT (a previously deleted version returns 200; 404 only for a version that never existed => keep a soft-delete marker).
- GET /room_keys/keys?version= -> 200 {"rooms":{roomId:{"sessions":{sid:KeyBackupData}}}} ({"rooms":{}} when empty); GET /keys/{roomId} -> {"sessions":{...}} ({"sessions":{}} when empty, not 404); GET /keys/{roomId}/{sessionId} -> bare KeyBackupData, 404 when key or backup missing; 404 when the backup is not found.
- PUT /keys, /keys/{roomId}, /keys/{roomId}/{sessionId}: body {"rooms":..} / {"sessions":..} / KeyBackupData; version "must be the current backup" -> 200 {count:int, etag:string}; 403 M_WRONG_ROOM_KEYS_VERSION with top-level "current_version":"<string>"; 404 M_NOT_FOUND.
- DELETE /keys, /keys/{roomId}, /keys/{roomId}/{sessionId} ?version= -> 200 {count, etag}; 404 when the backup is not found (not restricted to the current version).
- KeyBackupData: first_message_index int, forwarded_count int, is_verified bool, session_data object (all required).
- count = TOTAL keys in the backup; etag opaque, changes when the stored set changes. `version` query param required on every keys route (missing => 400 M_MISSING_PARAM, Synapse behaviour). Version numbers are never reused; "current" = most recently created non-deleted version (after deleting the latest, the newest remaining, or 404 if none). 
- MERGE RULE for a re-uploaded session (spec order): 1. if is_verified differs keep the verified one; 2. else keep the lower first_message_index; 3. if equal keep the lower forwarded_count; full tie keeps the existing key. Count unchanged when replacing. (The story paraphrase "lower fmi OR lower fwd OR becomes verified" is WRONG, use this order.)
- Key PUT for an unknown version: follow Synapse: 403 M_WRONG_ROOM_KEYS_VERSION when the user has any current version; 404 M_NOT_FOUND when the user has no backup.
- Other users' versions look non-existent (404 M_NOT_FOUND).
- Client flows: Element: GET version (404 = none) -> POST version -> account data m.megolm_backup.v1 -> loop GET version / PUT keys?version=X; reset: loop GET + DELETE until GET 404; on 403 re-GET and read current_version; recovery: GET version -> GET /room_keys/keys?version=X, on-demand GET /keys/{room}/{session}.
- Quota error: M_LIMIT_EXCEEDED is the rate-limit code (clients auto-retry); do NOT use it for the 11th version: use 403 M_FORBIDDEN.
- Stub conflicts / tests to update in the same story: server/lib/nebu/web/router/protected.ex ~599-612 (stateless stub, "M_UNRECOGNIZED" comment, ADR-011 comment obsolete); server/test/nebu/matrix/matrix_client_compat_test.exs L397-419; server/test/nebu/web/unrecognized_routes_test.exs L229-230 (405 Allow ["GET","POST"] still right) and L388-389 (route clause inventory); server/test/nebu/web/unrecognized_routes_integration_test.exs L140 ("No backup found" message).
