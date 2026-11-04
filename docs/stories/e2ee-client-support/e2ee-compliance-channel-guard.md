---
story_id: e2ee-compliance-channel-guard
title: "E2EE compliance channel guard: no encrypted room events, to-device allowlist, documented residual"
epic: e2ee-client-support
status: done
security_review: required
matrix: true
ui: false
traceability_id: REQ-2026-015
created: 2026-11-03
---

## Story

**As** the operator of a compliance-native server (archive and audit are the product), **I want** the E2EE client infrastructure of this epic not to give clients an unrestricted opaque channel next to the archived rooms, **so that** the ADR-011 posture (client key infrastructure yes, encrypted rooms no, everything in rooms archived) still holds and the remaining non-archived channel is small, named and signed off.

Origin: HIGH finding #1 of the epic security review (SEC Gate 2, `docs/stories/e2ee-client-support/security-reports/epic-e2ee-client-support-security-review-2026-11-03.md`). `m.room.encryption` is rejected on every write path, but `PUT /rooms/{id}/send/m.room.encrypted/{txn}` is accepted (no type check on the room send route) and `PUT /sendToDevice/{type}/{txn}` accepts any event type with up to 64 KiB of opaque content that is never audited and is deleted on ack. Decision of the owner (epic gate, 2026-11-03): fix what is closable now with a small story and document the remainder as an accepted residual; no metadata audit of to-device sends.

## Decisions (orchestrator, 2026-11-03, from the epic review)

- **D1 Room events.** An event of type `m.room.encrypted` is refused on EVERY room write path with `403 M_FORBIDDEN` and the fixed text of the `m.room.encryption` rejection (no id echoed; read how `protected.ex` ~l.3339 and `event_dispatcher/server.ex` ~l.9045 do it and reuse the wording): the `PUT /rooms/{roomId}/send/{eventType}/{txnId}` route (protected.ex ~l.1821) AND, as defence in depth, the dispatcher's send path, so no caller of the dispatcher can store one. The check happens before any DB work and before the txn-dedup entry; nothing is stored, no event id is consumed, no broadcast. The 403 does not depend on the room (an unknown room and a member room give the same answer) and does not echo the content. `m.room.encrypted` must not slip in through another type of write path either: check state events (`PUT /state/m.room.encrypted/...`), `initial_state` of createRoom, the room upgrade copy and any relation/redaction path that takes an event type from the request; refuse or document why not applicable (the state paths already refuse `m.room.encryption` only).
- **D2 To-device allowlist.** `PUT /sendToDevice/{eventType}/{txnId}` accepts only these event types (exact match, one named constant list in `http_to_device.ex`, documented; list confirmed by the oracle against the spec): `m.room.encrypted` (the Olm wrapper of room keys, forwarded keys and secrets), `m.room_key_request`, `m.room_key.withheld`, `m.secret.request`, `m.dummy`, and the verification family `m.key.verification.request`, `.ready`, `.start`, `.accept`, `.key`, `.mac`, `.done`, `.cancel` (QR verification uses `.start` with method `m.reciprocate.v1` and `.done`, no own type). NOT in the list on purpose: `m.room_key`, `m.forwarded_room_key` and `m.secret.send` (the spec makes them inner, Olm-wrapped payloads, never the outer type) and the unstable alias `org.matrix.room_key.withheld`. Known exclusion to document: the to-device key transport of Element Call / MatrixRTC (`io.element.call.encryption_keys`, `m.call.*`, `org.matrix.call.*`) is refused, so Element Call end-to-end encrypted calls do not work against Nebu (no Element Call support is claimed). Any other type (also a type that only matches the old regex) is `400 M_INVALID_PARAM` with a fixed text; the type check happens FIRST, before the JSON/recipient/budget work, so it consumes no rate/byte budget, creates no row and no ETS bucket, and the answer does not depend on any recipient (no oracle). A new client flow that needs another type is a one-line list change plus a doc line, reviewed (not configuration).
- **D3 What stays open and is accepted.** To-device remains a non-archived, server-opaque, user-to-user channel for the allowlisted types: Olm-wrapped `m.room.encrypted` content is opaque by design and is needed for key sharing and verification. It stays bounded by the budgets of story to-device-messaging (64 KiB per request, 50 recipients, per-device/pair/sender queues, TTL 7 days, rate limit). ADR-011 (update 2026-11-03) and `11-risks.md` state this as an accepted residual signed off by the owner at the epic gate, together with: the key-backup blobs and the cross-signing signatures are opaque client data as well; there is no per-send audit of to-device traffic; an operator who needs one must open a new story.
- **D4 Logging.** `keys/device_signing/upload` is added to the key-material request-body exclusion (`RawBodyReader.key_material_shape?/1` and everything that pins the list, LOW #6 of the epic review).
- **D5 Documentation of the other epic findings (docs only, no code).** `11-risks.md` / `07-deployment.md`: (MEDIUM #2) the migrations 000058-000061 must reach a database only AFTER 000056/000057 of the OAuth branch (the runner applies versions above the single recorded one; the `ReleaseTest` contiguity guard is red until then): add it as a release/merge precondition; (MEDIUM #3) the epic-level aggregate memory of one account (about 400 MiB plus 10-20 MB per concurrent `/sync` that carries to-device content; two or three colluding accounts reach a 2 GiB node) as an accepted epic residual with the monitoring signals; (LOW #4) two concurrent erasures of users who messaged or signed each other can deadlock (SQLSTATE 40P01) on `to_device_messages` and `cross_signing_user_signatures`, the erasure fails closed and a retry succeeds; (LOW #5) `/sync` reaches the device-list scan and the global (4760, 60) lock through the per-IP sync tier, not the per-user `keys_changes` tier.
- **D6 Existing tests.** Existing to-device tests that send arbitrary or made-up event types are adapted to an allowlisted type (the assertion stays), `unrecognized_routes_test` and the docs pins keep passing; adapt only what the D1/D2 behaviour change forces, nothing weakened.

## Acceptance Criteria

```gherkin
Feature: E2EE compliance channel guard

  Scenario: An encrypted room event is refused
    Given I am a member of a room
    When I PUT /rooms/{roomId}/send/m.room.encrypted/{txnId} with an opaque ciphertext content
    Then the answer is 403 M_FORBIDDEN, no event is stored and the same answer comes for an unknown room

  Scenario: Other room events still work, including in-room verification and redaction
    Given I am a member of a room
    When I send an m.room.message event, an m.room.redaction and the in-room verification events m.key.verification.ready, .start, .accept, .key, .mac, .done and .cancel
    Then each is stored and delivered as before (only m.room.encrypted is refused)

  Scenario: No other write path takes an encrypted room event
    Given a room creation with initial_state of type m.room.encrypted and a state PUT of that type
    When the requests are sent
    Then they are refused or the event is skipped and nothing of that type is stored

  Scenario: Allowlisted to-device types are delivered
    Given I share a joined room with another user
    When I send every allowlisted type (the eight m.key.verification.* types incl. the QR flow m.key.verification.start with method m.reciprocate.v1 and m.key.verification.done, m.room.encrypted, m.room_key_request, m.room_key.withheld, m.secret.request, m.dummy) to its device
    Then each is accepted with 200 and delivered in the recipient's next sync

  Scenario: A to-device type outside the allowlist is refused before anything is consumed
    Given I share a joined room with another user
    When I send a to-device message with the made-up type com.example.chat, and with the inner-only types m.room_key, m.forwarded_room_key, m.secret.send and the unstable alias org.matrix.room_key.withheld
    Then each answer is 400 M_INVALID_PARAM, no row is stored, no rate or byte budget is consumed

  Scenario: The refusal does not reveal anything about the recipient
    Given a non-allowlisted type
    When I send it to an existing peer, to a stranger and to an unknown user
    Then the three answers are byte-identical

  Scenario: The cross-signing upload body is not logged
    Given the debug capture is on
    When I POST /keys/device_signing/upload with key material
    Then no key material reaches a log line

  Scenario: The architecture documents state the accepted residual and the release precondition
    Given the ADR-011 update and the risk register
    When they are read
    Then they name the to-device channel as an accepted non-archived opaque channel, the migration order precondition and the other epic residuals
```

## Definition of Done

- [ ] All Gherkin scenarios have failing tests (ATDD)
- [ ] All tests pass (green)
- [ ] Code review clean (0 MAJOR)
- [ ] Security review (if required) clean
- [ ] Epic security gate 2 re-run (delta) clean
