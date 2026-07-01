# Session 2026-06-28 — Cross-signing upload/read-back compliance answer

Story: opaque cross-signing persist+echo (device_signing/upload, signatures/upload, keys/query echo, device_lists in /sync).

Spec MUSTs confirmed against v1.18 client-server-api/index.html:
- §cross-signing (L38710+): 3 ed25519 keypairs MSK/USK/SSK; usage values "master"/"self_signing"/"user_signing".
- CrossSigningKey object (L38990+): REQUIRED keys (exactly one prop `<algo>:<unpadded_b64>`), usage [string], user_id. signatures optional for MSK; SSK/USK MUST be signed by MSK.
- device_signing/upload (L38866+): UIA required EXCEPT (a) no existing MSK, OR (b) identical re-upload (all supplied keys match stored) -> idempotent. Responses: 200 {}; 400 M_INVALID_SIGNATURE (bad SSK/USK sig) / M_MISSING_PARAM (no MSK available); **403 (M_FORBIDDEN) when a key public key == one of user's device IDs**.
- CORRECTION to story brief: collision is 403 M_FORBIDDEN ("Key ID in use"), NOT 400 M_INVALID_PARAM. Spec L39100-39104 + L38803/38824 "Servers MUST ensure device IDs will not collide with cross-signing public keys".
- signatures/upload (L39123+): body {userId:{keyId: signedObject}}; signedObject MUST match stored key except `signatures` (merge new sigs). Response ALWAYS 200 {"failures": {userId:{keyId:{errcode:M_INVALID_SIGNATURE,error}}}}. Per-(user,key) failure granularity; NOT a top-level error.
- keys/query (L44185+): master_keys/self_signing_keys/user_signing_keys each {userId: CrossSigningKey}, "same as uploaded ... along with signatures the requesting user is allowed to see". user_signing_keys only for self-query. Nebu currently hardcodes empty (protected.ex:288) = the bug.
- /sync device_lists.changed MUST include uploader's own user_id after cross-signing upload (§cross-signing L38734-38736; device_lists §e2e-extensions).

ADR-011: persisting opaque cross-signing material does NOT enable room E2EE; m.room.encryption PUT still 403 M_FORBIDDEN.
