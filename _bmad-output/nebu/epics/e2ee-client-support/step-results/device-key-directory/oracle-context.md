# Oracle context: device-key-directory (REQ-2026-013), Matrix CS API v1.18

Source: skills/nebu-agent-oracle/matrix-spec/v1.18/client-server-api/index.html. Anchors: `#post_matrixclientv3keysclaim` (l.43923), `#get_matrixclientv3keyschanges` (l.43807), `#post_matrixclientv3keysquery` (l.44084), `#post_matrixclientv3keysupload` (l.44413), `#e2e-extensions-to-sync` (l.44646), `#post_matrixclientv3keyssignaturesupload` (l.39123), `#one-time-and-fallback-keys` (l.36400), `#tracking-the-device-list-for-a-user` (l.36452), `#cross-signing` (l.38710), `#key-algorithms` (l.36334). Read-only oracle run. Code paths relative to `server/`.

## 1. POST /_matrix/client/v3/keys/claim
- Auth required. Spec "Rate-limited: No"; a Nebu rate limit is policy; 429 uses the standard shape (`M_LIMIT_EXCEEDED`, `retry_after_ms`, `Retry-After`).
- Request: `one_time_keys` **required**, `{UserID: {DeviceID: algorithm}}` (one algorithm per device). `timeout` optional (10 s, remote servers only): accept and ignore, do not reject.
- Response 200: `one_time_keys` **required**, `{UserID: {DeviceID: {"<alg>:<key_id>": KeyObject}}}`; KeyObject has `key` and `signatures` (both required); a fallback key also carries `"fallback": true`. Return the stored JSON verbatim.
- **MUST**: each one-time key is returned at most once; discard after handing out. OTKs go out in upload order (earlier uploads first; within one call any order: use `created_at`).
- No OTK left for the algorithm: return the device's fallback key. The fallback key is **not consumed**, but is marked `used` (its algorithm leaves `device_unused_fallback_key_types`). Neither OTK nor fallback: leave the device out.
- Server is algorithm-agnostic (`signed_curve25519` for Olm v1): match the requested string against the stored algorithm prefix.
- `failures` `{string: object}` is keyed by **server name**, only for unreachable remote servers. "If the homeserver could be reached, but the user or device was unknown, no failure is recorded. Instead, the user or device is missing from the result."

## 2. GET /_matrix/client/v3/keys/changes
- Auth required. `from` and `to` required, both sync `next_batch` tokens; `to` may be a hint.
- 200: `changed` [UserID], `left` [UserID] (always emit both as lists).
- Who counts: users currently sharing a room with the caller (both sides `join`) who added/removed a device with identity keys between the tokens; also cross-signing key changes (via `device_lists.changed` semantics). `left`: users who may have left all shared rooms (Nebu has no encrypted rooms: "shared joined room" stands in).
- Errors: spec defines none; malformed token 400 `M_INVALID_PARAM` and missing parameter 400 `M_MISSING_PARAM` are Nebu policy.

## 3. /sync E2E fields (`#e2e-extensions-to-sync`)
- `device_one_time_keys_count` {alg: int}: required if any unclaimed OTKs exist, counted for THIS device; zero entries may be omitted.
- `device_unused_fallback_key_types` [string]: **Required** since v1.2. Always emit (`[]` when none). Lists the algorithms where THIS device has a fallback key no `/keys/claim` response has returned yet.
- `device_lists` {changed, left}: optional, only on incremental sync. `changed`: users who updated device identity keys or cross-signing keys, or who now share a room with the caller. `left`: users who no longer share any room. A user who leaves, adds a device and rejoins must appear in `changed` on the rejoin. The server may add a user to `changed` on every newly shared room.

## 4. POST /keys/upload (exists)
- `device_keys` device_id/user_id must match the login; `one_time_keys`, `fallback_keys` `{"<alg>:<id>": key}`; a signed fallback key should carry `fallback: true`. Response `one_time_key_counts` required (spelling differs from the sync field). A new fallback key replaces the previous and resets `used=false`.

## 5. POST /keys/query
- Request `device_keys` {UserID: [DeviceID]} (empty list = all devices); `timeout` ignored. Response `device_keys` = uploaded object + `unsigned.device_display_name`; `failures` follows the server-name rule (unknown users/devices simply left out).
- `master_keys`/`self_signing_keys` for queried users; master keys include only the signatures the requester may see. **`user_signing_keys`: only the requester's own, only if they queried themselves** (`#cross-signing`: "only visible to the user that it belongs to").

## 6. POST /keys/signatures/upload
- Body `{UserID: {KeyID: signedObject}}` (KeyID = device id or cross-signing public key); the object must match the stored key except `signatures`. 200: `failures` {UserID: {KeyID: {errcode, error}}}; invalid signature -> `M_INVALID_SIGNATURE`.
- Valid cases: the caller's own device signed by the caller's SSK; the caller's own master key signed by one of the caller's devices; **another user's master key signed by the caller's USK** (user verification; object sits under the OTHER user's id). Another user's devices may not be signed by the caller. A server should verify the signature cryptographically (Nebu currently only compares objects). Signatures a user made on someone else's master key should be visible only to the signer.

## 7. Nebu today vs. this story
- Exists: `/keys/upload` (protected.ex:857-919; device-binding guard, 100-key cap, `one_time_key_counts`); stores device_key_store.ex:102-160 (OTKs insert-once, fallback upserted `used=FALSE`); schema 000009 (`claimed_at` on OTKs with partial index, `used` on fallback keys: the claim schema is in place); `/keys/query` (protected.ex:812-834, query_device_keys :3401-3420; already returns `unsigned.device_display_name` from `devices`, device_key_store.ex:226-257/:493; `failures` always `{}`: open item (b) only needs a test); `/keys/signatures/upload` (protected.ex:842, 3247-3378; a foreign `user_id` gets `M_FORBIDDEN` for every key :3262-3268); sync `put_device_e2e_counts` (protected.ex:372-385); `device_lists.changed` holds only the OWN user after a cross-signing change (protected.ex:293-365).
- **Missing**: `POST /keys/claim`, `GET /keys/changes`; `device_lists` for other users (device add/delete, key change, newly shared/no longer shared room) and for the own user's device add/delete; a device-list change stream position (sync token is `<core>.<ad pos>[.<to-device pos>]`, protected.ex:259-282).
- **`/keys/query` does NOT restrict foreign users**: returns device keys plus master, self-signing AND user-signing keys for any queried user (protected.ex:816-831, cross_signing_key_store.ex:199-222).
- Reusable: the both-sides-`join` shared-room rule from to-device (to_device_store.ex:82, 201-221).

## 8. Spec deviations in existing code
- D1 (MUST-level): `user_signing_keys` returned for foreign users (protected.ex:824): return only for `user_id == caller`.
- D2: `device_unused_fallback_key_types` aggregated per USER (device_key_store.ex:199-209, used protected.ex:384); spec says per device: device B's used fallback key is masked by device A's unused one, so B never rotates its fallback key (replay exposure). Make it per device when a device is bound.
- D3: `otk_counts_for_user` for device-less sessions (protected.ex:379) inflates counts for multi-device users; legacy fallback only, document.
- D4: master-key signature visibility is not filtered; relevant once cross-user USK signatures are stored.

## 9. Story conflicts with the spec
- Scenario 3 ("`failures` reports the requested target") contradicts the spec: unknown/unauthorized targets record no failure and are left out; a per-target `failures` keyed by user id would be read as server names (rust-sdk records failed servers and backs off).
- The claim restriction (self + shared room) is stricter than the spec: acceptable, the spec lets unknown targets be left out.
- Open item (c): "refuses signatures for foreign devices" is spec-correct, but refusing a foreign **master key** signed by the caller's USK breaks cross-user verification (Element and FluffyChat upload it after in-room SAS/QR); the user sees "verified" but the signature is lost.
- Scenario 4 is correct; "added" means identity keys were uploaded: a keyless device row is not a change.

## 10. Interop pitfalls
- rust-sdk (Element, Element X): tops up OTKs to max/2 (~50) when the sync count is below; a missing `device_one_time_keys_count` is read as 0 and re-uploads; Synapse always sends `{"signed_curve25519": N}` even for 0: always emit `signed_curve25519`. It uploads a new fallback key only when the algorithm is missing from `device_unused_fallback_key_types`; an absent field = server without fallback support; a per-user aggregate (D2) suppresses rotation.
- matrix-dart-sdk (FluffyChat): reads `device_one_time_keys_count[signed_curve25519]`, uploads below the limit; a null/missing `device_unused_fallback_key_types` or one lacking the algorithm makes it upload a fallback key on every sync. Always emit the field.
- Both track device lists only through `device_lists.changed/left` plus `/keys/changes` after a restart: if `device_lists` never names other users, a peer's new device stays invisible until restart ("unknown session / unable to decrypt"). The own user must appear in `changed` when they add/delete an own device.
- Claim: both SDKs omit devices missing from `one_time_keys` and retry later; rust-sdk wedged-session recovery re-claims at most ~once per hour per device; a key without valid `signatures` is rejected by the client: return verbatim.
- Concurrency: `UPDATE ... SET claimed_at=now WHERE ctid = (SELECT ... WHERE claimed_at IS NULL ORDER BY created_at LIMIT 1 FOR UPDATE SKIP LOCKED) RETURNING`; plain SELECT then UPDATE double-hands keys.
- `/keys/changes` with an old stored `next_batch` (client long offline): do NOT 400 a well-formed but expired token; return conservatively all currently shared users in `changed`; 400 only for malformed tokens.

## 11. Gherkin-testable behaviours and edge cases
1. N parallel claimers on one OTK: exactly one gets it, the others the fallback key or are left out; count 0.
2. OTKs claimed in upload order across two upload calls.
3. OTKs exhausted: the fallback key is returned twice with the identical key id; the device's next sync has `device_unused_fallback_key_types` without that algorithm.
4. Uploading a new fallback key puts the algorithm back in the list.
5. No OTK and no fallback key: device left out, `failures` `{}`.
6. Unknown user, unknown device, no shared room, invite-only shared room, remote user: **byte-identical** responses (no oracle).
7. Own device works without a shared room.
8. Claim for an algorithm with no keys: that device left out.
9. Claim with missing/non-object `one_time_keys`: 400 `M_BAD_JSON`; non-integer `timeout` ignored.
10. Rate limit exceeded: 429 `M_LIMIT_EXCEEDED` with `retry_after_ms`, OTK count unchanged.
11. `/keys/changes`: peer's device add (keys uploaded) or delete between tokens -> `changed`; cross-signing change -> `changed`; peer leaving the last shared room -> `left`; a non-shared user never appears.
12. `/keys/changes` malformed `from`/`to`: 400 `M_INVALID_PARAM`; missing: 400 `M_MISSING_PARAM`; expired but well-formed: 200 (conservative).
13. Incremental sync carries peer changes in `device_lists.changed`; initial sync has no `device_lists` for peers; the own new device puts the own user in `changed`.
14. Rejoin after a device change while apart -> `changed`.
15. Sync always carries `device_unused_fallback_key_types` (`[]` when empty), per device; a second device's used fallback key is not masked.
16. `/keys/query` foreign user: no `user_signing_keys`; self: yes.
17. `/keys/query` returns `unsigned.device_display_name`; a rename shows up in the next query.
18. `/keys/query` for a non-shared foreign user: left out, byte-identical to an unknown user.
19. `/keys/signatures/upload`: foreign device -> `failures[user][dev]`, valid entries in the same request still apply (partial success); tampered object -> `M_INVALID_SIGNATURE`.
20. Deleting a device deletes its OTKs and fallback keys and puts the user in peers' `changed`.

## 12. Oracle recommendations on the open items
- `failures`: follow the spec (server-name keyed, remote servers only; Nebu: always `{}`). Unknown, unauthorized and keyless targets are left out of `one_time_keys`. Rewrite scenario 3: "the response contains no key for that device and `failures` is empty".
- Rate limits (token bucket, `Nebu.Web.Plugs.RateLimit`, pattern protected.ex:634/710): (i) per caller user request bucket `/keys/claim` 30/min burst 10 (count requests, not targets); (ii) per (caller, target user, target device) 10/hour burst 5 (OTK and fallback claims alike; above rust-sdk's once-per-hour unwedging; a shared-room attacker drains at most ~5 + 10/h of 50 OTKs); (iii) per-request cap of 1000 targets, 400 `M_INVALID_PARAM` beyond. All buckets checked BEFORE the consuming transaction; any target over its limit -> 429 for the whole request. `/keys/changes` and `/keys/query` on the generic tier, optionally 120/min burst 30.
- Restriction: self + both sides `join` for BOTH claim and query (query also drops `user_signing_keys` for anyone but the caller, D1). Risk: Element's DM pre-check queries invitees without a shared room, gets nothing, creates the DM unencrypted (harmless, aligned with ADR-011). Evaluated at request time; reuse to_device_store.ex:201-221.
- No-oracle rule: claim, query, changes: unknown user/device, keyless device, non-shared, invite-only, remote: identical output and status; same code path (one SQL with the membership join, no early return).
- signatures/upload: per-entry `failures` with partial success; foreign master key signed by the caller's USK allowed only with a both-`join` shared room, else `M_FORBIDDEN`; foreign devices stay refused. Deferring cross-user master-key signatures is acceptable only as a documented interop gap.
- Device rename: also mark `changed` (Synapse does; display name sits in `unsigned`).
- Change stream: stamp device-list changes from `sync_global_pos_seq` (as `CrossSigningKeyStore.put_keys` does) on key upload, device delete and membership join/leave; add a device-list position to the per-device `sync_tokens` row or the token suffix, advance-only-under-own-token discipline like D9.

## Orchestrator decisions (to be recorded in the story Decisions by the ATDD agent)
- Recommendations of section 12 accepted, with this SCOPE SPLIT because the story is too big for one pipeline run: **this story (device-key-directory)** = `keys/claim` (+ rate limits, restriction, no oracle), `keys/changes`, the sync fields (`device_one_time_keys_count` always incl. `signed_curve25519`, per-device `device_unused_fallback_key_types` (D2/D3), `device_lists` for peers and own devices with the device-list stream position), key-change stamps on upload/delete/rename/membership, scenario 3 rewritten per section 12. **New follow-up story `key-query-hardening`** (REQ-2026-014, written after this story): `keys/query` restriction to self + shared-room (both `join`), D1 (`user_signing_keys` self only), D4 visibility of cross-user signatures, `signatures/upload` cross-user master key signed by the caller's USK, cryptographic signature verification, display-name pin test. D1 is a MUST-level spec bug but a small change: if it is trivially independent it may be done in this story at the dev's discretion, with a pin test.
