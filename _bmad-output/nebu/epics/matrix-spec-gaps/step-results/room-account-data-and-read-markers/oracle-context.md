# Oracle context — room-account-data-and-read-markers (verified 2026-10-08 against bundled spec v1.18)
Finding "per-room account_data missing = v1.12 MUST violation": PARTIALLY TRUE. Nebu does not advertise v1.12 (router.ex:123 lists up to v1.11) and Client Config / Read and Unread Markers / Room Tagging are "Optional" in all feature profiles -> a feature gap, not a v1.12 MUST breach. But the Client Config module spans BOTH scopes and Nebu implements only global.

## Spec rules (v1.18)
- Account data is "either global or scoped to a particular room"; a missing type in a room has NO fallback to the global value.
- PUT /user/{userId}/rooms/{roomId}/account_data/{type}: delivered "in the per-room entries via /sync". Errors: 400 M_BAD_JSON/M_NOT_JSON (body not an object), 400 M_INVALID_PARAM (invalid roomId), 403 M_FORBIDDEN (other user's id), 405 M_BAD_JSON (server-managed type).
- GET same path: 200 content; 400 M_INVALID_PARAM; 403 M_FORBIDDEN; 404 M_NOT_FOUND.
- MUST: "Servers MUST reject setting account data for m.fully_read and m.push_rules [405] ... applies to both global and room-specific"; "Servers must allow clients to read the above event types as normal."
- /sync: rooms.join.<id>.account_data and rooms.leave.<id>.account_data = private data attached to the room.
- m.fully_read: kept as an event in the room's account data, pushed down the event stream when updated. POST read_markers: server treats m.read/m.read.private like /receipt; "Upon updating the m.fully_read ... the server MUST send the updated account data event via /sync"; "MUST prevent clients from setting m.fully_read directly".
- m.marked_unread (v1.12, MSC2867): content {"unread": bool}; the only server duty is normal room account data store+sync.
- m.tag lives in room account data (separate module): GET .../rooms/{roomId}/tags, PUT/DELETE .../tags/{tag}, tag name <= 255 bytes (follow-up story).

## Nebu today (code)
- Global account data: durable, PUT/GET protected.ex:546-588; /sync global part protected.ex:102,114-126 with consume-once per-USER `changed` flag (multi-device weakness).
- Room account data endpoints: MISSING (catch-all protected.ex:1309 -> 404 M_NOT_FOUND). rooms.join.*.account_data hard-coded {"events": []} (http.ex ~131/174); initialSync per room "account_data" => [] (protected.ex:792).
- read_markers (protected.ex:1172-1181): no-op 200 {}; m.read/m.read.private ignored; m.fully_read never produced.
- Receipts: read_receipts table only (matrix/receipt/db.ex).
- REAL MUST violations found beyond the original finding: (1) global PUT accepts m.fully_read/m.push_rules (no type check, protected.ex:552-563); (2) read_markers offered but does nothing. Minor: global PUT with malformed JSON stores {} and answers 200.

## Minimal scope proposed
Migration + table room_account_data (user_id, room_id, type, content TEXT, monotonic change position, timestamps; PK(user_id, room_id, type)); PUT/GET endpoints with the error matrix; 405 for m.fully_read/m.push_rules in both scopes; read_markers storing m.fully_read and forwarding m.read(.private) to receipts; /sync rooms.join.<id>.account_data (initial all; incremental only changed since token; room with only an account-data change must appear in join); per-DEVICE correctness via monotonic position vs since token; cluster-safe (ADR-020); verbatim content (ADR-011).
Not first step: rooms.leave account_data, sync filters, advertising v1.12, deletion, /events, tags (own story).

## Unverified (needs a network trace): matrix-js-sdk may send m.read only via /read_markers -> receipts lost (assumption).
