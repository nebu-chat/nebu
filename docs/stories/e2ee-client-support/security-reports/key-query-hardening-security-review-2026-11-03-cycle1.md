## Security Review — key-query-hardening (cycle 1, delta re-review of L1-L3)

**Diff scope:** the fixes for the 3 LOW findings of `key-query-hardening-security-review-2026-11-03.md`: `server/lib/nebu/matrix/key_signature_store.ex`, `key_query_store.ex`, `cross_signing_key_store.ex` (`put_keys/2` D7 delete), migration `000061_cross_signing_user_signatures` (up/down, edited in place), `docs/architecture/11-risks.md`, `08-concepts.md`, tests in `server/test/nebu/matrix/key_query_hardening_test.exs`.
**Date:** 2026-11-03

### Verification of the previous findings

**L1 (cross-user signature bound to key id only): CLOSED.**
- Migration 000061 adds `target_key TEXT NOT NULL`. The file is tracked only as staged (`A`), `git log --all` has no commit touching it: edit in place is legitimate (never shipped).
- Writer (`write_cross_user/5`): `target_key` comes from `key_value_of(master, key_id)` on the master key RE-READ under both `sync_global|` advisory locks (lines 311-316), never from the request. A non-binary value or missing id ends in `:invalid_signature` (no row). Upsert also updates `target_key` on conflict.
- Drop (`put_keys/2`): `DELETE ... WHERE target_user_id = $1 AND NOT EXISTS (SELECT 1 FROM unnest($2::text[], $3::text[]) AS k(id, key) WHERE k.id = s.target_key_id AND k.key = s.target_key)`. Parallel arrays built from the same list of `{key_id_of(prop), key}` pairs (equal length, so no NULL padding from `unnest`); non-binary values are skipped on both sides consistently. Edge cases: master absent/NULL -> `[[],[]]` -> every row of the target deleted (correct: no master, no signature; replacement paths merge the stored keys first so a partial upload never reaches this); `keys` not a map or empty -> same, all rows dropped; NULL cannot match `=`, but `target_key` is NOT NULL so no row survives through NULL semantics.
- Reader (`master_for/4`): shows a row only when `{key_id, target_key}` is in the pairs of the CURRENT master key: a row left by a concurrent replacement is also hidden. Reader still filters `s.user_id = $1` (viewer is signer) and the `vis` CTE: no new visibility oracle.
- Test `security L1` covers same id + other key (row deleted, signature gone) and the unchanged re-upload (row kept).

**L2 (up to 4000 Ed25519 verifications): CLOSED.**
- `check_shape/4`: only `signatures[caller]` is taken; it must be a map of 1..4 entries, else `:invalid_param` before any lookup or verification. Foreign signers are only checked for `is_map` (cheap, body-cap bounded), never verified, never stored ((a)/(b) merge `%{caller => sigs}`, (c) stores one of `sigs`).
- 200-object cap in `HttpKeyQuery.check_cap/1` before `process/2`; rate tier `keys_signatures` (60/min, burst 20, per user) applied in `Router.Protected` before the handler. Worst case 200 x 4 = 800 verifications, documented in 11-risks and the module doc.
- Test `security L2`: 5 caller signatures -> `M_INVALID_PARAM`; foreign garbage next to a valid caller signature stores the valid one and not the foreign one.

**L3 (peers take the target's `sync_global|` lock): DOCUMENTED.** 11-risks row residual (6) (what, impact, sorted order, monitoring) and 08-concepts "Locks" paragraph. Lock order unchanged (sorted `[first, second]`).

### New problems introduced by the fix

None at MEDIUM or above. Checked: migration constraints (PK unchanged, `target_key` NOT NULL on a new table, rolling-deploy safe, down drops the table); no undeletable row (erasure deletes by `user_id` and by `target_user_id`, `user_deletion.ex:53/325`, so the new column is covered; master replacement drops by pair); GRANT and the four RLS policies unchanged; no key value, id or signature in any log line.

### Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| I1 | INFO | cross_signing_key_store.ex:122-127, key_signature_store.ex:316-319 | A master key VALUE containing `\u0000` (JSON allows it, the cross-signing upload does not reject it) is now passed as a `text` parameter: PostgreSQL refuses it, so the owner's own `put_keys/2` (and a signer's insert on that target) fails with a 500. Pre-existing for ids (same path with NUL in the prop); self-inflicted only: the owner breaks its own upload, or makes itself unsignable by others, which it could already do by not sharing a room. | Optional: reject NUL in cross-signing key props/values at upload (400), same rule as `valid_id?`. |

### Summary

CRITICAL: 0 — block commit
HIGH: 0 — block commit
MEDIUM: 0
LOW: 0 (L1, L2 closed; L3 documented)
INFO: 1

**Verdict:** APPROVED
