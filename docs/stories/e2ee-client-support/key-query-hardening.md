---
story_id: key-query-hardening
title: "Key query hardening: restricted /keys/query, self-only user-signing keys and cross-user signatures"
epic: e2ee-client-support
status: done
security_review: required
matrix: true
ui: false
traceability_id: REQ-2026-014
created: 2026-11-02
refined: 2026-11-03
---

## Story

**As** a Matrix client user verifying another user, **I want** `POST /keys/query` to show me only the devices and cross-signing keys I am allowed to see and `POST /keys/signatures/upload` to accept the signature I make on another user's master key, **so that** cross-user verification works without leaking the key directory of strangers.

Origin: follow-up of story `device-key-directory` (REQ-2026-013), which was split by the orchestrator (see its `## Decisions` D1). Source: the oracle contexts of both stories (`_bmad-output/nebu/epics/e2ee-client-support/step-results/{device-key-directory,key-query-hardening}/oracle-context.md`; Matrix CS v1.18 `#post_matrixclientv3keysquery`, `#post_matrixclientv3keyssignaturesupload`, `#cross-signing`).

## Decisions (orchestrator, 2026-11-03, from the oracle context)

- **D1 Visibility.** Caller V sees the device keys, master key and self-signing key of X only when X is V, or V and X share a room in which BOTH are currently `join` (`room_members.left_at IS NULL` both sides; the same predicate as `key_claim_store.ex` / `device_list_store.ex`). Every other X (not shared, invite-only, left, unknown, keyless, remote, malformed id) is left out of the answer and the answer is byte-identical for all of them: one code path, one statement shape, no early return, no state-dependent status. `failures` stays `{}` (server names only). A pending invite does NOT count (Element's DM pre-check then finds no keys and creates the DM unencrypted, harmless while rooms stay unencrypted, ADR-011; owner option for later).
- **D2 `user_signing_keys`** only for the caller, only when the caller queries itself (already done by `device-key-directory` D1; this story keeps the pin test).
- **D3 Display name.** `unsigned.device_display_name` comes from the `devices` table, a rename shows in the next query (pin test).
- **D4 Signature visibility.** Viewer V sees on X's master key the signatures made by X's own keys (the self signatures, incl. X's devices) and the signatures made by V; never a signature by a third user. Cross-user signatures are stored apart from the key object, per (signer, target user, target key).
- **D5 Upload: who may sign what.** Allowed: (a) the caller's own device signed by the caller's self-signing key; (b) the caller's own master key signed by one of the caller's devices; (c) ANOTHER user's master key (the object sits under the OTHER user's id) signed by the caller's user-signing key, only when V and X are both joined in a shared room (D1). Everything else is refused per entry with `M_FORBIDDEN`: a foreign device, a foreign self-signing or user-signing key, the caller's own user-signing or self-signing key through this endpoint, and a foreign master key without a shared joined room. The sharing check happens BEFORE the key lookup, so an unknown user and a non-shared user get the identical failure (no oracle).
- **D6 Verification.** Every uploaded signature is verified with Ed25519: the message is the canonical JSON (UTF-8, keys sorted by code point, no whitespace, integers only in [-(2^53)+1, 2^53-1], no floats) of the signed object WITHOUT `signatures` AND WITHOUT `unsigned`; the signature is unpadded base64 of 64 bytes; the verifying key is 32 bytes unpadded base64 from the caller's stored key named by the signature (`signatures[caller]["ed25519:<id>"]`: the stored self-signing key, device key or user-signing key as D5 demands). The signed object must also equal the stored key object apart from `signatures` and `unsigned`. A bad signature, an unknown signing key id or a changed object is `M_INVALID_SIGNATURE` for that entry and nothing is stored for it. A non-object entry, a malformed `signatures` member or no signature by the caller is `M_INVALID_PARAM`. A body that is not a JSON object is `400 M_NOT_JSON` / `M_BAD_JSON` (whole request). Failures are always inside HTTP 200 `{"failures": {user: {key_id: {errcode, error}}}}`; valid entries of the same request still apply (partial success).
- **D7 Replacement.** When a user replaces its master key, the cross-user signatures stored for the old key are dropped (they no longer match).
- **D8 Limits (new endpoint behaviour needs them).** At most 200 signed objects per upload request (`400 M_INVALID_PARAM` before any verification), the existing body-size cap of the raw body reader applies; a per-user rate tier `keys_signatures` (60 / min, burst 20) in front of the handler; `/keys/query` keeps its existing tier and gets a cap on the number of queried users (1000, `400 M_INVALID_PARAM` beyond). Stored cross-user signatures are one row per (signer, target user, target key id): bounded by the number of users the signer shares a room with, replaced idempotently.
- **D9 GDPR.** The erasure of a user deletes the signatures it made and the signatures made on its keys (`UserDeletion`, with its fence/lock order unchanged); runbook and the erased-tables pin are updated.
- **D10 Device-list stream.** A stored signature stamps the signer's own key row in `device_list_changes` (the signer's other devices see the change in `device_lists.changed` and re-query), the target user is not stamped (V's signature is invisible to everybody else).
- **D11 Logging.** Request bodies of `keys/signatures/upload` and `keys/query` are never logged (already excluded for upload; check query); no key material or signature in error messages.

## Acceptance Criteria

```gherkin
Feature: Key query hardening

  Scenario: Query of a user I share no room with leaves the user out
    Given "@erin:nebu.test" has a device with identity keys and cross-signing keys and shares no joined room with me
    When I POST /keys/query for "@erin:nebu.test"
    Then the response contains no device keys, master key or self-signing key for "@erin:nebu.test" and is byte-identical to the answer for an unknown user

  Scenario: A pending invite or a left room does not make a user visible
    Given "@carol:nebu.test" was only invited to my room or left it
    When I POST /keys/query for "@carol:nebu.test"
    Then the answer is byte-identical to the answer for an unknown user

  Scenario: My own keys are visible without any shared room
    Given I have a device, a master key, a self-signing key and a user-signing key and share no room with anybody
    When I POST /keys/query for myself
    Then all four are returned

  Scenario: The user-signing key is only visible to its owner
    Given "@bob:nebu.test" shares a room with me and both of us have cross-signing keys
    When I POST /keys/query for myself and for "@bob:nebu.test"
    Then "user_signing_keys" contains my key and does not contain the key of "@bob:nebu.test"

  Scenario: A device rename shows in the next query
    Given "@bob:nebu.test" shares a room with me and has a device with a display name
    When "@bob:nebu.test" renames the device and I POST /keys/query again
    Then "unsigned.device_display_name" shows the new name

  Scenario: A signature on another user's master key is stored and visible to the signer only
    Given "@bob:nebu.test" shares a room with me and I have a user-signing key
    When I POST /keys/signatures/upload with my valid signature over the master key of "@bob:nebu.test"
    Then "failures" is empty, my query of "@bob:nebu.test" shows my signature and Bob's own signatures on his master key, and a third user's and Bob's own query do not show my signature

  Scenario: A signature on the master key of a user I share no room with is refused like an unknown user
    Given "@erin:nebu.test" shares no joined room with me
    When I POST /keys/signatures/upload with a signature over the master key of "@erin:nebu.test" and with one over an unknown user's key
    Then "failures" reports the identical M_FORBIDDEN for both and nothing is stored

  Scenario: A signature on a foreign device is refused per entry while valid entries still apply
    Given the request signs my own device and a device of "@bob:nebu.test"
    When I POST /keys/signatures/upload
    Then the own device signature is stored and "failures" names the foreign device with M_FORBIDDEN

  Scenario: An invalid signature is rejected
    Given I upload a signature that does not verify against the signing key, one with an unknown signing key id and one over an object whose key differs from the stored key
    When I POST /keys/signatures/upload
    Then "failures" reports M_INVALID_SIGNATURE for each of these entries and nothing is stored

  Scenario: The unsigned member and the key order do not break a valid signature
    Given a client signs an object with an "unsigned" member, more than 32 keys and a non-ASCII value in canonical JSON
    When I POST /keys/signatures/upload
    Then the signature verifies and is stored

  Scenario: A malformed entry is an M_INVALID_PARAM failure, a malformed body a 400
    Given an entry that is not an object, and separately a body that is not a JSON object
    When I POST /keys/signatures/upload
    Then the entry fails with M_INVALID_PARAM in "failures" and the body is answered 400 M_NOT_JSON or M_BAD_JSON

  Scenario: The request sizes are bounded and the endpoint is rate limited
    Given a request with 201 signed objects, and a client that sends 21 uploads at once
    When I POST /keys/signatures/upload
    Then the large request is answered 400 M_INVALID_PARAM before any verification and the 21st upload is answered 429 M_LIMIT_EXCEEDED

  Scenario: Replacing a master key drops the cross-user signatures made on the old one
    Given I stored a signature over the master key of "@bob:nebu.test"
    When "@bob:nebu.test" uploads a new master key
    Then my query of "@bob:nebu.test" no longer shows my signature

  Scenario: Erasing a user deletes the signatures it made and the ones made on its keys
    Given I signed the master key of "@bob:nebu.test" and Bob signed mine
    When the GDPR erasure of "@bob:nebu.test" runs
    Then no signature row of either direction remains for Bob
```

## Definition of Done

- [ ] All Gherkin scenarios have failing tests (ATDD)
- [ ] All tests pass (green)
- [ ] Code review clean (0 MAJOR)
- [ ] Security review (if required) clean
