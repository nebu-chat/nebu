## Security Review — e2ee-compliance-channel-guard

**Diff scope:** staged diff. The `m.room.encrypted` room-event refusal (router send route, state PUT, `EventDispatcher.Server.send_event/2` clause, createRoom `@initial_state_forbidden_types`), the to-device event-type allowlist (`HttpToDevice.refuse_unlisted_type/2`, `check_type/1`, the router order for `sendToDevice`), `RawBodyReader.key_material_shape?/1` (+ `keys/device_signing/upload`), and the ADR-011, 11-risks, 07-deployment, matrix-api-scope and CHANGELOG updates. The review targets ways around the guard (it closes epic SEC Gate 2 HIGH #1 and LOW #6).
**Date:** 2026-11-03
**Prescan candidates:** none (the candidates file has only its header line).

### Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| 1 | LOW | server/lib/nebu/matrix/event_dispatcher/server.ex `copy_state_events/3` (~9363 `excluded_types`) and `emit_state_event_at/6` | The room-upgrade copy is the one write path the guard does not cover. A legacy `m.room.encrypted` STATE event, stored through createRoom `initial_state` before this guard existed (that path accepted the type until now), is copied into the replacement room on upgrade. `emit_state_event_at/6` has no central type check, so the comment saying "the next write path cannot forget it" is not true. | Add `@encrypted_room_event_type` to `excluded_types` in `copy_state_events/3`, or better, refuse `encrypted_room_event?/1` (and `m.room.encryption`) inside `emit_state_event_at/6` so that every state writer inherits the check. Add an upgrade test with a seeded legacy row. |
| 2 | LOW | docs/architecture/adr/ADR-011 (Update 2026-11-03, item 3), 11-risks.md row, 07-deployment.md, CHANGELOG | Docs precision. The allowlist filters the TYPE only, never the content. The example from the epic review (two users chatting in plaintext outside the archive, `com.x.chat` with `{"body": ...}`) still works with the same 64 KiB per request under `m.dummy`, `m.key.verification.cancel`, `m.room_key_request` and the other allowlisted types. The capacity of the non-archived channel is unchanged. The ADR parenthetical ("Olm-wrapped content is opaque by design") suggests that only Olm ciphertext passes. | Add one sentence to ADR-011 (3) and to the 11-risks row: "The allowlist restricts event types, not content: any allowlisted type can carry up to 64 KiB of arbitrary client content (plaintext or ciphertext) per request. The residual capacity equals that of the channel before the allowlist; the allowlist removes naive custom types and the MatrixRTC key transport, it does not shrink the channel." |

### Detail

**Finding #1 — Room-upgrade copy forwards a legacy `m.room.encrypted` state event** [LOW]
Today a NEW `m.room.encrypted` state event cannot be created. The state PUT refuses it (it is outside the `@writable_state_types` allowlist, and the new router clause refuses it too), and `initial_state` now skips it. Rooms created before this story, however, may already hold one from `initial_state`, because the forbidden list did not contain the type until now. `copy_state_events/3` excludes `m.room.tombstone`, `m.room.aliases`, `m.room.encryption`, `m.space.child` and `m.space.parent`, but not `m.room.encrypted`. `emit_state_event_at/6` writes whatever type it receives. A user with the power level to upgrade the room therefore re-stores the legacy event in the new room. There is no new channel here: the content is the already-archived legacy blob, the upgrader cannot choose it, and it needs a pre-existing row plus upgrade rights. That is why the rating is LOW. It is still the one write path where the "every room write path" claim in CHANGELOG/ADR-011 does not hold. The cleanest fix is a single check in `emit_state_event_at/6`, the funnel shared by PUT state, initial_state, preset, name/topic/alias and the upgrade copies.

**Finding #2 — Allowlist is a type filter, not a content filter** [LOW]
The owner accepted the to-device residual, so this finding is about the docs saying exactly what was accepted. The story's goal ("the remaining non-archived channel is small, named and signed off") is met for "named" and "signed off". "Small" applies to the type set only, not to the content capacity: 64 KiB per request, 50 recipients, 60/min, 4 MiB/min per sender, unchanged. Content-shape validation (for example forcing `m.dummy` to `{}`) would not help, because `m.room.encrypted` stays open with arbitrary content. So the right remediation is precise wording, not code.

### Bypass attempts verified as closed (no finding)

- **Room send route variants:** only `/client/v3/...` routes exist in `Protected`. The `Nebu.Web.Router` has no r0, v1 or unstable rewrite for send, state or sendToDevice, so those paths reach the unrecognized fallback. Plug 1.20.3 `decode_path_info!` decodes path params ONCE (`URI.decode`): `m.room.%65ncrypted` is refused, and `%2565` decodes to the literal `m.room.%65ncrypted` type, which clients do not treat as encrypted. Trailing and duplicate slashes are dropped by the path_info split, so the same params and the same check apply. Case variants (`M.room.encrypted`) and NUL, overlong or invalid-UTF-8 types are not `m.room.encrypted`. Clients decrypt only the exact type, so these are ordinary archived custom events. The check is the first `cond` branch, before JSON, UTF-8, size, room lookup and txn-dedup, with a fixed text and the same answer for every room.
- **State PUT:** already refused by the `@writable_state_types` allowlist. The new router clause matches the value that is stored (the double-decoded `URI.decode_www_form` value).
- **Dispatcher:** `Room.Server.send_event/6` has exactly one caller (`EventDispatcher.Server.send_event`, line 247). `%Core.SendEventRequest{}` is built only in the router send route. The new head clause raises before any lookup.
- **Other inserts:** the `insert_event` call sites write membership, redaction, power-levels and state-change events with server-fixed types. `apply_initial_state` matches on the JSON-decoded string, so `\u` escapes cannot get around it. Redaction, relations and edits (`m.relates_to`, `m.new_content`) live inside `m.room.message` content, which is archived plaintext from the server's view.
- **To-device:** `plug :authenticate` runs before `:dispatch`, so an unauthenticated caller gets 401 and never sees the 400 type text. The type check runs before `RateLimit.call` (no bucket), before `ToDeviceSendGate.run` (no slot) and before `JsonBody.parse_to_device` (no body read, no byte budget, no DB). There is one fixed text, the type is not echoed, it is a `MapSet.member?` exact match (a huge or invalid-UTF-8 type just returns false, no crash), and no ETS key derives from the type. The answer does not depend on the recipient, because the body is never read. Typical near misses (`org.matrix.room_key.withheld`, `m.room_key`, case and prefix variants) are refused, and the tests pin them.
- **LOW #6 (epic):** `key_material_shape?/1` now covers `keys/device_signing/upload` for any version, normalized and percent-decoded. `RequestLogger.account_data_content?/1` uses it for request AND response capture.
- **Docs overclaim check:** ADR-011, 11-risks, 07-deployment and the CHANGELOG all say that to-device stays a non-archived, server-opaque channel accepted by the owner, with no per-send audit, and that Element Call E2EE is excluded. The release precondition 000056/57 before 000058-61 is stated. Remaining imprecisions: Findings #1 and #2.
- **Out-of-scope note (INFO):** a modified client can always put self-encrypted ciphertext into an `m.room.message` body or a custom type. The archive then stores ciphertext. The server cannot prevent this; it is not a client-native E2EE path and no standard client decrypts it.

### Summary

CRITICAL: 0 — block commit
HIGH: 0 — block commit
MEDIUM: 0 — advisory, address before epic end
LOW: 2 — advisory

Epic SEC Gate 2 HIGH #1 is closed for the closable part (`m.room.encrypted` room events); the to-device residual is documented as owner-accepted. Epic LOW #6 is closed.

**Verdict:** APPROVED
