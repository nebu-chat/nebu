# Oracle context: to-device-messaging (REQ-2026-012), Matrix CS API v1.18

Source: skills/nebu-agent-oracle/matrix-spec/v1.18/client-server-api/index.html. Anchors: `#send-to-device-messaging`, `#put_matrixclientv3sendtodeviceeventtypetxnid`, `#extensions-to-sync` (to-device), `#transaction-identifiers`, `#size-limits`, `#standard-error-response`, `#mkeyverificationrequest`, `#mroom_key_request`, `#delete_matrixclientv3devicesdeviceid`. Read-only oracle run.

## 1. Endpoint: PUT /_matrix/client/v3/sendToDevice/{eventType}/{txnId}
- Auth required. Spec: "Rate-limited: No"; rate limiting is still allowed as server policy, 429 must use the standard shape (`M_LIMIT_EXCEEDED` + `retry_after_ms` + `Retry-After`).
- Body `{"messages": {UserID: {DeviceID | "*": EventContent}}}`; `messages` required. Response 200 `{}`; the spec defines no other codes, so errors are Nebu policy + standard error codes.
- One message per device per transaction; every message in a request has the event type from the path. `*` = all known devices of that user.
- Remote users: spec says send via federation; Nebu has no federation, so remote recipients are dropped silently and the request still returns 200.
- Unknown users/devices: spec defines no error; common practice (Synapse) ignores silently and returns 200 (matches the story: skip silently, no existence oracle).

## 2. Transaction IDs
- Scope: one device + one HTTP endpoint. `send/{eventType}/{txnId}` and `sendToDevice/{eventType}/{txnId}` with the same txnId are separate.
- Retransmission = same txnId on the same request path: return the same status/body (`{}`) and do not enqueue again.
- Scope is the device, not the access token (token refresh keeps the device; a new login is a new device). Key on (user, device_id, endpoint, path/txnId), not the token string.
- Same txnId with a different eventType = different path = new transaction.

## 3. Sync delivery
- `to_device` optional, shape `{"events": [{"sender","type","content"}]}`; exactly those three fields (no event_id, origin_server_ts, unsigned).
- Server (should): store pending messages until delivered, in order of arrival.
- Ack (should): when the client calls /sync with the `next_batch` of the response that delivered messages, those messages are delivered and deleted. Repeating the older `since` must return the undeleted batch again; deletion only once a later token is presented. A token a generation old after the ack: nothing to redeliver, must not error.
- Initial sync (no `since`) also delivers pending messages; nothing is acked until the next sync with a `since`.
- Spec recommends ~100 messages per response; continuation via `next_batch` encoding the per-device to-device stream position; the client gets the rest on its next sync without waiting for `timeout`.
- A new to-device message must wake a long-polling /sync of the target device (verification needs sub-second round trips).
- Sibling E2EE sync fields: `device_one_time_keys_count` (required if unclaimed keys exist, may be omitted when all zero), `device_unused_fallback_key_types` (Required since v1.2), `device_lists` (optional, incremental only). Check which story covers them (see orchestrator note).
- Recommendation: always emit `"to_device": {"events": []}` (Synapse does); clients accept absent and empty, but empty avoids null bugs in older clients.

## 4. Size and validation
- Event `type` <= 255 bytes (`#size-limits`); the story's regex `^[a-zA-Z0-9._-]{1,255}$` is a stricter, compatible Nebu policy.
- 64 KiB limit in the spec applies to PDUs; the 64 KiB request-body cap is Nebu policy -> 413 `M_TOO_LARGE`. Typical payloads: verification < 2 KiB, Olm-wrapped m.forwarded_room_key ~2-4 KiB, m.secret.send < 4 KiB. `*` fan-out sends the body once.
- 50 recipient entries per request: count (user, device) pairs with `*` as one; exceeded -> 413 `M_TOO_LARGE`, never truncate silently.
- Malformed body (`messages` missing / not an object / device value not an object): 400 `M_BAD_JSON`; non-JSON: 400 `M_NOT_JSON`; bad eventType: 400 `M_INVALID_PARAM` (Nebu choice). Malformed user id key: skip it or 400 `M_INVALID_PARAM`; pick one and test it.

## 5. MUST NOT / transport rules
- Content is opaque: do not inspect, rewrite, strip or log content (law: no chat/credential content in logs). `sender` = authenticated user id; `type` = path eventType.
- Transported verbatim: `m.key.verification.request|ready|start|accept|key|mac|done|cancel`; `m.room_key_request` (`request` | `request_cancellation`), `m.forwarded_room_key`, `m.room_key`, `m.room_key.withheld`; `m.secret.request`, `m.secret.send`, `m.room.encrypted` (Olm to-device), `m.dummy`; unknown custom types.
- `m.key.verification.request` has `timestamp` + `transaction_id`; receivers ignore requests > 5 min in the future or > 10 min in the past, so delivery must never be delayed by minutes (no batching/holding).
- `request_cancellation` must be delivered even after the original request was acked; no dedup by content.
- Exactly once per device. No duplicates across `*` + an explicit device id in the same request: the explicit entry wins (Nebu choice, test it).
- `*` expands at send time; a device created later does not receive the message.

## 6. Device removal and logout
- Delete device / delete_devices / logout / logout/all / admin session revoke: tokens invalid; the device's queue is undeliverable and should be purged. Dehydrated devices are not in v1.18 (out of scope). The 7-day TTL is acceptable (verification windows are short).

## 7. Recipient restriction (shared room or own device): assessment
- The spec puts no restriction on recipients.
- Own devices (self-verification, m.secret.*, key forwarding): allowed. Other users: Element and FluffyChat (matrix-dart-sdk) run user verification IN-ROOM (the request is a room message in the DM, later steps are room events with m.relates_to), not to-device. Cross-user to-device traffic is mostly Olm/Megolm key sharing and m.room_key_request, which only make sense for room co-members; rooms are unencrypted here (ADR-011).
- Compatibility risk LOW. Recommendation: accept the restriction with: (a) a room counts as shared if either side's membership is `join` or `invite` (DM-invite verification can start before the invitee joins); (b) evaluate at send time, not at delivery; (c) keep the silent 200 skip, no 403 (membership oracle); (d) document in a client-compat note.
- Queue full (500 per device): a 429 to the SENDER reveals recipient state (oracle) and lets one sender's flood block others. Recommend dropping silently for that device (or evicting the oldest) and logging a count without content; reserve 429 `M_LIMIT_EXCEEDED` for the sender's own rate limit. Needs a security-review decision.

## 8. Known client interop pitfalls
- matrix-dart-sdk: `to_device` absent or empty fine, `events` must be a list; each event needs `sender`, `type`, `content` (missing `content` throws).
- rust-sdk (Element) retries sends with the SAME txnId after timeout/5xx: idempotency must survive a server restart, persist txnIds (in-memory is not enough).
- Clients repeat the same `since` after a network failure: redeliver, never lose. Acking on delivery instead of on the next token loses verification messages (classic bug).
- Sync must not drop pending to-device messages when `filter` or `set_presence` are used or when the rooms section is empty.

## 9. Gherkin-testable behaviours and edge cases
1. Specific device: 200 `{}`; the recipient's next sync has the event with exactly sender/type/content, content byte-equal.
2. `*` fans out to all N devices of the recipient, one copy each. For a sender targeting themselves with `*`, the sending device itself is excluded (Nebu choice; Synapse includes it; test the chosen one).
3. Own other device: delivered, no shared room needed.
4. No shared room, unknown user, unknown device, remote server: 200, nothing queued, identical response (no oracle).
5. Invited-only shared room: delivered.
6. Same txnId + same path twice: both 200 `{}`, delivered once. Same txnId to /send: independent. Same txnId from another device: independent.
7. Ordering: messages 1..3 in send order.
8. Ack: sync with since = the delivering next_batch no longer returns it.
9. Retry with the earlier since: same batch redelivered.
10. > 100 pending: first sync bounded, next sync the remainder, no loss, no duplicates.
11. Initial sync delivers pending messages.
12. Long-poll /sync?timeout=30000 returns promptly when a to-device message arrives.
13. Body > 64 KiB or > 50 recipient entries: 413 `M_TOO_LARGE`, nothing queued.
14. eventType > 255 bytes / invalid characters: 400 `M_INVALID_PARAM`; `messages` missing/wrong type: 400 `M_BAD_JSON`; no token: 401 `M_MISSING_TOKEN`.
15. Sender rate limit: 429 `M_LIMIT_EXCEEDED` with `retry_after_ms`.
16. Device deleted / logout / logout/all / revoke: that device's queue purged, other devices keep theirs.
17. TTL job: messages older than 7 days purged, fresh ones untouched.
18. Content never logged (log-capture assertion with a sentinel).
19. A device added after a `*` send does not receive it.
20. `m.room_key_request` request then request_cancellation: both delivered in order.

## Orchestrator decisions on the open items
- Queue full (500/device): silently evict the OLDEST for that device (newest messages are the relevant ones), count logged without content, no 429 to the sender (Kassandra to confirm).
- Recipient restriction accepted with refinements (a)-(d).
- `*` to self excludes the sending device; explicit device entry wins over `*`.
- `device_one_time_keys_count` / `device_unused_fallback_key_types` / `device_lists` belong to story device-key-directory (REQ-2026-013); this story only guarantees `to_device: {"events": []}` is always emitted.

## Owner decision after the test review (supersedes refinement (a) of section 7)
The recipient rule is tightened: other users count only if BOTH sides are `join` in a shared room (own devices always allowed). An invitation opens no send path (no consent; in-room verification needs no to-device). Behaviour 5 ("invited-only shared room: delivered") is replaced by "invited-only: 200, nothing queued". Fair eviction and per-sender-user caps (200 messages / 4 MiB) are in the story Decisions.
