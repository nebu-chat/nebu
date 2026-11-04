# Oracle context: e2ee-compliance-channel-guard (spec v1.18)
## Endpoints (from draft, unchanged)
- PUT /rooms/{roomId}/send/{eventType}/{txnId}: auth yes; 200 | 400 [M_DUPLICATE_ANNOTATION, M_UNKNOWN]; MUST allow m.room.redaction (all room versions)
- PUT /sendToDevice/{eventType}/{txnId}: auth yes; body `messages` required; 200 only (no 400 listed; standard error rules apply)
- POST /keys/device_signing/upload: 200 | 400 [M_INVALID_SIGNATURE, M_MISSING_PARAM] | 403 M_FORBIDDEN; UIA MUST rules (unchanged, D4 is logging only)
## Spec rules for the outer to-device type (the `{eventType}` path param)
- To-device module: "one message per device per txn, all the same event type"; "not intended for conversational data"; receivers "ignore any they do not understand" (no MUST about which types a server accepts; an allowlist is server policy, not spec-violating)
- m.room_key: "encrypted as m.room.encrypted using Olm, then sent as to-device" -> never an outer type
- m.forwarded_room_key: same (Olm-wrapped) -> never an outer type
- m.secret.send: "must be encrypted as m.room.encrypted using Olm" -> never an outer type
- m.dummy: "typically encrypted as m.room.encrypted" -> normally inner; plaintext outer possible
- m.room_key_request: "sent as an unencrypted to-device event" -> outer, MUST allow
- m.secret.request: "sent as an unencrypted to-device event" -> outer, MUST allow (cross-signing + backup key gossip)
- m.room_key.withheld: "sent as a to-device event" (clients send it plaintext) -> outer, MUST allow
- Verification (to-device flow): m.key.verification.request, .ready, .start, .accept, .key, .mac, .done, .cancel -> outer, plaintext, MUST allow
- QR verification: NO own event type; uses m.key.verification.start with method m.reciprocate.v1, then .done (methods m.qr_code.show.v1/scan.v1 are values in .request/.ready) -> covered
- In-room verification: m.room.message msgtype m.key.verification.request + room events m.key.verification.ready/start/accept/key/mac/done/cancel go via the ROOM send path -> D1 must block only m.room.encrypted there, not m.key.verification.* (DM user verification in Element/FluffyChat uses this)
## D2 comparison
- Missing (spec-required): none. All 8 verification types, m.room.encrypted, m.room_key_request, m.secret.request, m.room_key.withheld, m.dummy present
- Superfluous (spec says Olm-wrapped only): m.room_key, m.forwarded_room_key, m.secret.send -> no compliant client sends them as outer type; removing is safe and narrower (plaintext secrets/keys would at least not be opaque, so keeping is low risk; decide and document)
- org.matrix.room_key.withheld: legacy unstable alias, not in spec; harmless (receivers ignore); keep for old clients or drop, low impact
- MSC4268 room_key_bundle (m.room_key_bundle / io.element.msc4268.*): sent Olm-wrapped inside m.room.encrypted -> no extra outer type needed; same for dehydrated devices (MSC3814)
- NOT covered, deliberately: Element Call/MatrixRTC to-device key transport (io.element.call.encryption_keys and m.call.*/org.matrix.call.* to-device signalling) -> breaks Element Call E2EE calls only; document as known exclusion
## (a) m.room.encrypted in a room without m.room.encryption
- Spec: no rule links them; room auth rules (v6/v11) do not check it; Synapse stores it without validation
- Refusal is server policy; idiomatic errcode 403 M_FORBIDDEN ("Forbidden access"), consistent with Nebu's existing m.room.encryption 403 M_FORBIDDEN; same answer for unknown room (no membership oracle)
## (b) errcode for a non-allowlisted to-device type
- 400 M_INVALID_PARAM: "a parameter that was specified has the wrong value" -> eventType is a path parameter; correct
- Not M_UNRECOGNIZED: spec reserves it for 404 (endpoint not implemented) / 405 (wrong method); clients would misread it as "sendToDevice unsupported"
- Not M_BAD_JSON: about malformed body; type check runs before body parsing
## (c) Client impact of a 400 (client-source knowledge, NOT spec; verify by smoke test)
- Normal key sharing, key requests, withheld, secret gossip, SAS + QR verification use only allowlisted outer types -> no break expected
- rust-crypto (Element Web): outgoing to-device request not marked sent stays in the OlmMachine queue and may be re-sent each sync loop (log noise, no UI banner) for a refused type
- dart-sdk (FluffyChat): sendToDevice throws MatrixException; key/verification code logs or cancels the flow
## Tests that MUST exist
- room send m.room.encrypted: 403 M_FORBIDDEN, no row; identical body for member room and unknown room; m.room.message + m.room.redaction + in-room m.key.verification.* still 200
- createRoom initial_state + state PUT of m.room.encrypted: refused/skipped, nothing stored
- sendToDevice: every allowlisted type 200 + delivered in /sync to_device; com.example.chat -> 400 M_INVALID_PARAM, no row, no rate/byte budget, byte-identical for peer/stranger/unknown user
- QR flow types (.start with m.reciprocate.v1, .done) and m.secret.request accepted
- device_signing/upload body never in a log line
