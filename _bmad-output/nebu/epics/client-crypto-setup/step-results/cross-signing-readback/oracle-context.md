# Oracle — Cross-signing upload/read-back (Matrix CS API v1.18)

## 1. Endpoints, shapes & MUST rules

**`POST /_matrix/client/v3/keys/device_signing/upload`** (Added v1.1; UIA-optional since v1.11)
- Body: `master_key`, `self_signing_key`, `user_signing_key` (all optional `CrossSigningKey`), `auth` (UIA).
- 200 response body MUST be `{}`.
- UIA MUST be performed EXCEPT: (a) no existing MSK on server, OR (b) identical re-upload — supplied MSK exactly matches stored, and any supplied SSK/USK also match (request contains no new keys) → idempotent.
- SSK and USK MUST be signed by the accompanying (or most-recent stored) MSK.

**`CrossSigningKey` object MUST shape** (identical on upload and in `/keys/query`):
- `keys` — REQUIRED; object with exactly ONE property `<algorithm>:<unpadded_base64_pubkey>` → unpadded base64 public key.
- `usage` — REQUIRED `[string]`; values `["master"]` / `["self_signing"]` / `["user_signing"]`.
- `user_id` — REQUIRED.
- `signatures` — optional for MSK; REQUIRED-by-rule for SSK/USK (signed by MSK).

**`POST /_matrix/client/v3/keys/query`** — MUST echo `master_keys`, `self_signing_keys`, `user_signing_keys`, each `{userId: CrossSigningKey}`, returning the SAME object uploaded plus visible signatures. `user_signing_keys` only on self-query. (Nebu hardcodes `{}` at `protected.ex:288` = the bug.)

**`POST /_matrix/client/v3/keys/signatures/upload`** (Added v1.1)
- Body: `{userId: {keyId: signedObject}}`; signedObject MUST match the stored/retrieved key for that keyId EXCEPT `signatures`, which carries new sigs to MERGE in.
- Response ALWAYS 200 `{"failures": {}}`; per-(user,key) failures go in `failures[userId][keyId] = {errcode, error}`.

**`GET /sync`** — after upload, `device_lists.changed` MUST include the uploader's own user ID.

**Collision guard (MUST):** "Servers MUST not allow devices to have the same IDs as cross-signing keys" (shared `ed25519:` namespace). Reject before any write.

**ADR-011:** all material opaque; persisting cross-signing does NOT enable room E2EE; `m.room.encryption` PUT still `403 M_FORBIDDEN`.

## 2. Error codes / HTTP status — MUST test-cover
- device_signing/upload: 200 `{}`; **400 `M_INVALID_SIGNATURE`** (bad SSK/USK sig); **400 `M_MISSING_PARAM`** (no MSK available); UIA challenge (401 with flows) when neither exemption applies.
- **Collision → 403 `M_FORBIDDEN`** ("key public key == one of user's device IDs"). ⚠️ **Correction to the story:** the spec says **403 M_FORBIDDEN**, NOT `400 M_INVALID_PARAM`.
- Idempotent identical re-upload → 200, NO UIA challenge.
- signatures/upload mismatch → 200 with `failures[user][key].errcode = M_INVALID_SIGNATURE` (per-key, not top-level).
- keys/query → uploaded keys returned (regression test against the empty-`{}` bug); USK only on self-query.
- /sync → `device_lists.changed` contains own user_id post-upload.
- ADR-011 guard → `m.room.encryption` state PUT still 403 `M_FORBIDDEN` after cross-signing persisted.

## Pipeline note on the collision-guard status code
Story AC6 says `400 M_INVALID_PARAM`; Oracle says spec is `403 M_FORBIDDEN`. The story author explicitly chose `400 M_INVALID_PARAM` ("or, minimally..."). Decision for this story: honor the story's explicit AC6 (`400 M_INVALID_PARAM`) as the contract the tests assert, since the story author made a deliberate, documented choice and the pipeline's job is to satisfy the story. Element treats any 4xx rejection identically (it never sends a colliding key in practice). Note the divergence for the eventual spec-compliance follow-up.
