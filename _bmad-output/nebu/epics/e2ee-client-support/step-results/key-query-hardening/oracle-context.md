# Oracle context: key-query-hardening (REQ-2026-014), Matrix CS v1.18
Sources: client-server-api `#post_matrixclientv3keysquery` (l.44084), `#post_matrixclientv3keyssignaturesupload` (l.39123), `#cross-signing` (l.38710); appendices `#signing-json` (l.404), `#canonical-json` (l.414), `#checking-for-a-signature` (l.606). Reuses device-key-directory oracle s.5/6/8/12. Paths under `server/`.
## Endpoint facts (script draft, kept)
- POST /keys/query: auth required, rate-limited no; body required `device_keys` {UserID:[DeviceID]} (empty list = all); optional `timeout` (ignore); 200 only.
- POST /keys/signatures/upload: auth required, rate-limited no; body {UserID:{KeyID:signedObject}}; 200 `{"failures":{UserID:{KeyID:Error}}}`; invalid signature -> errcode `M_INVALID_SIGNATURE`. MUST: the signed object must match the stored key for that key ID except `signatures`.
## MUST/SHOULD rules and Nebu status (MET / PARTLY / MISSING)
- R1 query `failures` keyed by server name only; unknown user/device left out, no failure -> MET (always `{}`, protected.ex:901); pin test.
- R2 `device_keys` = uploaded object + `unsigned.device_display_name` -> MET (device_key_store query_devices joins `devices`); pin test incl. rename visible in next query.
- R3 `user_signing_keys`: only the requester's own, only if they queried themselves (`#cross-signing`: USK "only visible to the user that it belongs to") -> MET (D1 fixed, protected.ex:894 `Map.take([caller])`, store read limited to requested ids); keep pin test (self yes, peer no, self not queried -> `{}`).
- R4 `master_keys`: "signatures ... that the requesting user is allowed to see"; diagram: cross-user signatures dotted = visible only to their creator -> MISSING (D4). Rule: viewer V sees on X's MSK the signatures by X (own MSK/device sigs) and by V; never by a third user. Today all merged into one stored object (cross_signing_key_store.ex:251-280).
- R5 restriction self + both-sides-joined shared room (Nebu policy, stricter than spec; spec permits leaving users out) -> MISSING for query (protected.ex:880-903 returns any user). Must cover device_keys, master_keys, self_signing_keys alike. Reuse SQL of key_claim_store.ex:25 / device_list_store.ex:209 (`room_members.left_at IS NULL` = joined).
- R6 no oracle: non-shared, unknown, keyless, remote, malformed user id -> byte-identical 200, same code path (one SQL with membership join, no early return) -> MISSING.
- R7 sigs upload, allowed objects: (a) own device signed by own SSK; (b) own MSK signed by own device key; (c) foreign MSK signed by caller's USK (object under the OTHER user's id). Forbidden: foreign device, foreign SSK/USK, own USK/SSK via this endpoint -> PARTLY: (a)(b) match-only; (c) refused today (protected.ex:3347-3352 M_FORBIDDEN for any foreign user).
- R8 per-entry failures with partial success -> MET for own entries (reduce per key); keep for (c).
- R9 Ed25519 verification (SHOULD-level, story makes it MUST): strip `signatures` AND `unsigned`, canonical JSON (UTF-8, keys sorted by codepoint, no whitespace, integers only in [-(2^53)+1, 2^53-1], no floats/exponent), signature = unpadded base64 of 64 bytes, key = 32-byte unpadded base64 from `ed25519:<id>` -> MISSING (only object equality; no canonical encoder in lib; `:crypto.verify(:eddsa, :none, msg, sig, [pub, :ed25519])` available, Nebu.Matrix.Signature already uses :crypto).
- R10 verify against the right key: (a) caller's stored SSK, (b) the caller's stored device ed25519 key, (c) caller's stored USK; signer entry must be `signatures[caller]`; unknown signing key id -> M_INVALID_SIGNATURE -> MISSING.
- R11 servers MUST not allow device IDs equal to cross-signing public keys (`#cross-signing`) -> out of scope, note only (key_id lookup tries device first, protected.ex:3378).
## Error codes per entry (all inside HTTP 200)
- M_INVALID_SIGNATURE (spec): bad Ed25519 sig, object differs from stored key, unknown signing key; nothing stored for that entry.
- M_FORBIDDEN (Nebu policy): foreign device/SSK/USK; foreign MSK without both-joined shared room. Check sharing BEFORE key lookup so unknown and non-shared users get the identical failure (no oracle).
- M_INVALID_PARAM (Nebu policy, Synapse-like): non-object entry, malformed `signatures`, no signature by the caller. Today these give M_INVALID_SIGNATURE (protected.ex:3389/3393): acceptable, decide and pin.
- Non-object body: 400 M_NOT_JSON/M_BAD_JSON (whole request).
## Story vs spec
- No contradiction found. Scenario 1 restriction stricter than spec but allowed. Scenario 4 errcode for foreign device not spec-named: use M_FORBIDDEN. Scenario 5 matches spec errcode.
- Scenario 3 must also assert self sees own-device/own-MSK sigs of Bob (R4: Bob's own sigs visible to all).
- Story says "Ed25519 over the canonical JSON": also strip `unsigned` (appendix: unsigned not covered), else valid client sigs fail.
## Interop
- Element/FluffyChat verify users via in-room request (DM); both join before SAS/QR completes -> both-joined rule suffices; then rust-sdk/dart-sdk upload USK sig over peer MSK and log `failures` (today lost: user sees "verified" only locally).
- Residual risk: Element's DM-creation pre-check queries invitees (not joined) -> no keys -> DM created unencrypted (accepted earlier, ADR-011); option: also allow pending invite either direction (owner decision).
- On peer MSK replacement, drop stored cross-user sigs for the old key (they no longer match).
## Tests to add (Gherkin)
1. Non-shared, invite-only shared, unknown, remote user: identical query bodies; no master/self_signing keys either.
2. Self query without any room: own device + master + SSK + USK.
3. Peer USK absent; self not queried -> `user_signing_keys` `{}`.
4. Display-name rename visible in next query.
5. Valid USK sig on shared peer MSK -> `failures` `{}`; signer sees it, peer and third user do not; peer's own sigs stay visible.
6. Same for non-shared peer -> M_FORBIDDEN, identical to unknown user; nothing stored.
7. Own device + foreign device in one request: own stored, foreign M_FORBIDDEN (partial success).
8. Tampered sig, wrong signing key, object with changed key, `unsigned` added (must still verify): M_INVALID_SIGNATURE except the `unsigned` case; nothing stored.
9. Canonical JSON: object with >32 keys / non-ASCII value verifies (map ordering).
