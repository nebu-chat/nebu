# Oracle context — room-tags (verified 2026-10-08, bundled spec v1.18, #room-tagging ~l.51306-51700 + Client Config server behaviour)
S = stated by the spec, D = Nebu design decision.
- Module Room Tagging is OPTIONAL in all feature profiles (S). Tags are visible only to the user, shared across devices (S).
- Event: single `m.tag` in the room's account_data: `{"tags": {string: Tag}}`, Tag = `{order?: number}`; order "a number between 0 and 1 ... 0 is displayed first"; tags without order sort after (client rule); the spec does NOT require the server to reject orders outside [0,1] (S).
- Tag name MUST NOT exceed 255 bytes (S). Namespaces: m.* reserved (m.favourite, m.lowpriority, m.server_notice), u.* user tags, tld.name.*; no server rules (S).
- GET /user/{userId}/rooms/{roomId}/tags → 200 {"tags": {...}}; PUT .../tags/{tag} body = tag object → 200 {}; DELETE .../tags/{tag} → 200 {} ; "token must be authorized for this user ID" (S). The spec names NO error codes for these endpoints; 403/400/404/413 are D derived from account data.
- Not rate-limited per spec ("Rate-limited: No"); using the account_data tier is a documented D.
- Direct PUT account_data/m.tag must stay allowed: servers MUST reject only m.fully_read and m.push_rules with 405 (S).
- Delivery: per-room account_data in /sync (S).
- Undefined by spec (D): DELETE unknown tag (200 idempotent), deleting the last tag (keep `m.tag` as {"tags":{}} so /sync delivers it; the store has no tombstone).

## Nebu today
- No tag routes (catch-all 404 M_NOT_FOUND protected.ex ~1648); docs/matrix-api-scope.md ~121-123 wrongly marks them ✅.
- m.tag via PUT account_data/m.tag works already (do_put_room_account_data stores verbatim; delivered through list_for_sync; counts 1 row/room against the 1000-row and 4 MiB caps; rate-limit tier account_data).
- room_account_data_store.ex: `put/4` takes pg_advisory_xact_lock(hashtextextended(user_id,0)) INSIDE its own transaction; `get/3` has no lock → a handler doing get→merge→put loses concurrent updates: a new store function must do the read-modify-write in ONE transaction under the lock. Each upsert draws a new stream_pos (per-device sync correct). No delete/tombstone function.
- GDPR: user_deletion.ex deletes user_room_account_data; FKs ON DELETE CASCADE (migration 000035_user_room_account_data).

## Minimal scope (D)
New store function (e.g. update(user, room, type, fun)): transaction + advisory lock + SELECT content + merge/remove + upsert with the same cap logic + notify_sync; 3 routes with the same check order as the room account-data PUT; GET returns {"tags":{}} if nothing stored; tolerant of malformed stored m.tag. Out of scope: /events, initialSync account_data, m.server_notice, M_UNRECOGNIZED, client-side sort.
