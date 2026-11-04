## Security Review — key-query-hardening (epic e2ee-client-support)

**Diff scope:** staged diff. New `Nebu.Matrix.HttpKeyQuery`, `KeyQueryStore` (visibility-filtered `/keys/query`, one statement), `KeySignatureStore` (Ed25519-verified `/keys/signatures/upload`, cases a/b/c), `CanonicalJson.encode_strict/1`, `CrossSigningKeyStore` (D7 delete on master replacement, D10 stamp, removal of the unfiltered `query_cross_signing/1`), migration 000061 `cross_signing_user_signatures` (GRANT + FORCE RLS), router (`keys_signatures` tier 60/min burst 20 charged before work), `RawBodyReader.key_material_shape?/1` (query + signatures/upload excluded from body capture), `UserDeletion` (both directions erased).
**Date:** 2026-11-03

### Prescan candidates

| Candidate | Decision |
|---|---|
| 000061 up.sql:23 `signature` column "secret-like" | Dismissed: a public Ed25519 signature, no secret. Erasure covers both directions (signer via `@erased_tables`, target via `run_delete_signed_on/1`), inside the 4a/4b transaction that holds the erased user's `sync_global|` lock; `deletion_status` is committed in step 2 before, so the upsert guard `NOT EXISTS ... deletion_status IS NOT NULL` refuses late writers. |

### Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| 1 | LOW | server/lib/nebu/matrix/cross_signing_key_store.ex (put_keys D7 DELETE), server/lib/nebu/matrix/key_query_store.ex `master_for/4` | Cross-user signature row is bound to the master key ID only, not to the key material: a master key replacement that keeps the key id (`ed25519:<id>` with a different public key; the upload does not enforce id == pub) keeps and serves the stale signature | Store the target public key (or sha256 of the stripped canonical master object) in the row and compare it in the D7 DELETE and in the reader |
| 2 | LOW | server/lib/nebu/matrix/key_signature_store.ex:@max_signatures_per_object, verify/4 | CPU budget: 200 objects x 20 caller signatures = up to 4000 Ed25519 verifies per request (all reachable with 20 own devices / 20 keys in own SSK/USK), 60 req/min per account | Add a per-request verification budget (e.g. 200 total) or cap caller signatures per object at 1-2 |
| 3 | LOW | server/lib/nebu/matrix/key_signature_store.ex write_cross_user/5 | New cross-user acquisition of the TARGET's `sync_global|` advisory lock by any co-member (auto-join = everyone); the victim's own writers (key backup has a 2000 ms lock_timeout -> 429) queue behind it | Holds are short (no verify under lock, one tx per entry), so advisory only; keep the lock window minimal, consider a dedicated `xsig|<target>` key taken also by put_keys/erasure if contention is observed |

### Detail

**Finding #1 — signature bound to key id, not key** [LOW]
`cross_signing_user_signatures` stores `target_key_id`; `put_keys/2` deletes only rows whose `target_key_id` is NOT among the new master key ids, and `KeyQueryStore.master_for/4` shows a row while `key_id in master_key_ids(obj)`. Matrix key ids are conventionally the base64 public key, but nothing in device_signing/upload enforces `keys["ed25519:X"] == X`. The target (or whoever holds the target's UIA for a reset) can replace the master public key under the same id; the viewer then receives its own old USK signature attached to the NEW master object. The upload path itself is correct (signature verified against the STORED object, re-checked under the lock), and conforming clients re-verify the USK signature cryptographically (the stale signature fails and the identity shows as changed), so no direct trust escalation — but the D7/D4 claim "a replaced master key drops its rows" is not true for this case and a lax client would show a stale "verified" state. Fix: bind the row to the public key value (or a hash of the stripped canonical object) and compare that in both places; alternatively reject a master upload whose key id differs from its public key.

**Finding #2 — Ed25519 verification amplification inside the caps** [LOW]
Caps hold (rate tier charged before work, 200-object cap before any verification, object must `===` the stored key so canonical JSON work is bounded by the 1 MB body). `Enum.all?` short-circuits on the first bad signature, but an attacker controls its own keys and can make 19 of 20 valid: 4000 verifies (~0.25 s CPU) per request, burst 20 -> ~5 s CPU instantly per account, ~0.25 core sustained per account; multiplied by accounts. Spec usage needs one signature per caller per object. Fix: total-verify budget per request or `@max_signatures_per_object` 1-2.

**Finding #3 — cross-user sync_global| lock** [LOW]
Previously only the user's own writers and the erasure took `sync_global|<user>`; now every co-member's upload (case c) takes it per entry (sorted pair, so no deadlock cycle between mutual signers; lock order vs erasure (row -> advisory) and put_keys (advisory first) verified: write_cross_user takes no row lock on cross_signing_keys and stamps only the signer's stream row, no cycle). Holds are milliseconds; starvation of the victim's 2000 ms-bounded key-backup writer would need sustained parallel load across many accounts. Advisory.

### Checked and clean (from the launch focus list)

1. Memory/ETS: no request-derived ETS/cache key; rate key `:user` is the authenticated id; denied (429) requests allocate no rows/locks; failed entries store nothing.
2. Existence oracle: `/keys/query` is one statement with the visibility CTE, no per-user early return, `failures` always `{}`; NUL ids dropped request-only. `/keys/signatures/upload` (c): shape check first (state-independent), then ONE statement (share EXISTS + master lookup); unknown / non-shared / keyless / non-master key id all `:forbidden` with fixed text. Visible (shared) users may get `:invalid_signature` — no new information.
3. CPU: see #2; `encode_strict` rejects floats/out-of-range ints without raising; base64/length checks before `:crypto.verify`, rescue -> false (fail closed).
4. Locking: see #3; write_device row lock -> stream row matches `put_device_keys`; merge (b) reuses lock_keys protocol; erasure fence verified.
5. Authorization: (a) own device by own SSK, (b) own master by own device key, (c) foreign master by own USK with joined-room share; foreign device/SSK/USK and own SSK/USK refused; verification keys selected from the caller's STORED keys by prop; object compared to the STORED key (unlocked and again under lock); only `%{caller => sigs}` is ever stored (forged `signatures[other]` entries ignored).
6. Exposure: master key served with owner's signatures + the viewer's own rows only (`s.user_id = $1`), USK only to owner, unfiltered `query_cross_signing/1` deleted; table has GRANT + ENABLE/FORCE RLS; both erasure directions.
7. Logging: both routes in `key_material_shape?/1`; all error logs use `error_kind` (module/atom only); failure texts fixed, no key id/object/signature echoed except the request's own map keys.

### Summary

CRITICAL: 0 — block commit
HIGH: 0 — block commit
MEDIUM: 0 — advisory, address before epic end
LOW: 3 — advisory

**Verdict:** APPROVED
