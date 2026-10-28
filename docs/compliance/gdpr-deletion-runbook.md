# GDPR Right to Erasure - Operations Runbook

Story 14.4 | GDPR Article 17 | Route: `DELETE /api/v1/admin/users/{userId}`

## Overview

This runbook describes the procedure for processing a GDPR Right to Erasure (Article 17) request in Nebu.
The endpoint orchestrates full PII removal and key destruction for a single user account.

## Prerequisites

- The operator must hold the `instance_admin` system role
- A second admin must perform the deletion (self-deletion is blocked by a four-eyes guard)
- The operator must be authenticated (valid JWT, not expired or denylist-invalidated)

## Deletion Pipeline

The `DELETE /api/v1/admin/users/{userId}` endpoint executes the following steps atomically from the
requester's perspective. Each step is described with its failure behavior.

| Step | Action | Failure Behavior |
|------|--------|-----------------|
| 1 | Role gate: require `instance_admin` | 403 M_FORBIDDEN - request rejected |
| 2 | Path param validation (`userId` ≤ 255 chars) | 400 M_BAD_JSON - request rejected |
| 3 | Self-delete guard (callerSub ≠ userId) | 403 M_FORBIDDEN - four-eyes approval required |
| 4 | gRPC `DeactivateUser` - `is_active=false`, all sessions destroyed | 404 on unknown user, 500 on internal error |
| 5 | gRPC `DeleteUserKeys` - private signing + encryption key material set to NULL, and (story gdpr-erasure-global-data) the user's global account data, cross-signing keys, device keys and the other per-user rows deleted, the `users` PII columns set to NULL and `is_active=false` (the erasure is terminal), in one transaction. The scan of `read_receipts` by `user_id` has no index: erase off-peak on a large instance | Best-effort: warns on failure, continues |
| 6 | DB anonymization - `profiles.displayname='Deleted User'`, `profiles.avatar_url=NULL`, `users.anonymized_at=<unix_ms>` | 500 - PII erasure MUST NOT be silently skipped |
| 7 | Audit log - emits `gdpr_deletion` event with actor + target | Never-raise: audit failure does not block 200 response |
| 8 | 200 `{"user_id": "...", "status": "gdpr_deleted"}` | - |

## Example Request

```bash
curl -X DELETE \
  -H "Authorization: Bearer $ADMIN_JWT" \
  https://your-nebu-instance/api/v1/admin/users/@alice:example.com
```

## Example Response

```json
{
  "user_id": "@alice:example.com",
  "status": "gdpr_deleted"
}
```

## Error Codes

| HTTP | errcode | Cause |
|------|---------|-------|
| 400 | M_BAD_JSON | Missing or oversized `userId` path parameter |
| 403 | M_FORBIDDEN | Caller is not `instance_admin`, or caller is attempting self-deletion |
| 404 | M_NOT_FOUND | User does not exist in the system |
| 500 | M_UNKNOWN | DB anonymization or gRPC DeactivateUser failed |

**Note on idempotency:** If the user was already deactivated (e.g., from a prior partial deletion), the endpoint
treats this as an acceptable state and continues with the remaining steps (key deletion, anonymization, audit).
The final response is still 200 `{"status": "gdpr_deleted"}`. This behavior is intentional to support
re-running a partial deletion without errors.

## Verification Queries

After a successful deletion, confirm erasure with the following SQL queries:

```sql
-- Confirm PII anonymization
SELECT displayname, avatar_url
FROM profiles
WHERE user_id = '@alice:example.com';
-- Expected: displayname = 'Deleted User', avatar_url = NULL

-- Confirm key material erased
SELECT key_type, private_key IS NULL AS key_erased
FROM user_keys
WHERE user_id = '@alice:example.com';
-- Expected: private_key = NULL for all rows

-- Confirm anonymization timestamp
SELECT anonymized_at
FROM users
WHERE user_id = '@alice:example.com';
-- Expected: non-NULL unix millisecond timestamp

-- Confirm no active sessions
SELECT COUNT(*)
FROM sessions
WHERE user_id = '@alice:example.com' AND revoked_at IS NULL AND expires_at > NOW();
-- Expected: 0

-- Confirm the per-user rows are gone (story gdpr-erasure-global-data); every count must be 0
SELECT COUNT(*) FROM user_room_account_data WHERE user_id = '@alice:example.com';
SELECT COUNT(*) FROM account_data WHERE user_id = '@alice:example.com';
SELECT COUNT(*) FROM cross_signing_keys WHERE user_id = '@alice:example.com';
SELECT COUNT(*) FROM device_keys WHERE user_id = '@alice:example.com';
SELECT COUNT(*) FROM device_one_time_keys WHERE user_id = '@alice:example.com';
SELECT COUNT(*) FROM device_fallback_keys WHERE user_id = '@alice:example.com';
SELECT COUNT(*) FROM forgotten_rooms WHERE user_id = '@alice:example.com';
SELECT COUNT(*) FROM auto_join_opt_outs WHERE user_id = '@alice:example.com';
SELECT COUNT(*) FROM read_receipts WHERE user_id = '@alice:example.com';
SELECT COUNT(*) FROM uia_sessions WHERE user_id = '@alice:example.com';
SELECT COUNT(*) FROM oauth_account_sessions WHERE user_id = '@alice:example.com';
SELECT COUNT(*) FROM oauth_consent_requests WHERE user_id = '@alice:example.com';
SELECT COUNT(*) FROM oauth_codes WHERE user_id = '@alice:example.com';
-- Expected: 0 for each table above

-- Confirm the session teardown tables are empty (it is best effort after the commit; if a count is not 0 run the sweep below for this user)
SELECT COUNT(*) FROM devices WHERE user_id = '@alice:example.com';
SELECT COUNT(*) FROM matrix_sessions WHERE user_id = '@alice:example.com';
SELECT COUNT(*) FROM sessions WHERE user_id = '@alice:example.com';
SELECT COUNT(*) FROM jwt_device_bindings WHERE user_id = '@alice:example.com';
SELECT COUNT(*) FROM sync_tokens WHERE user_id = '@alice:example.com';
-- Expected: 0 for each table above

-- Confirm the users row holds no PII and is terminal for authentication
SELECT is_active, deletion_status,
       display_name_encrypted IS NULL AND avatar_url_encrypted IS NULL AND email_encrypted IS NULL
       AND last_seen_at IS NULL AND deactivation_reason IS NULL AS pii_gone
FROM users
WHERE user_id = '@alice:example.com';
-- Expected: is_active = false, deletion_status = 'keys_deleted', pii_gone = true

-- Confirm audit record
SELECT actor_user_id, action, target_id, outcome, inserted_at
FROM audit_log
WHERE action = 'gdpr_deletion' AND target_id = '@alice:example.com'
ORDER BY inserted_at DESC
LIMIT 1;
-- Expected: one row with outcome = 'success'
```

## Room History Preservation

Per GDPR recital 65, messages sent by the deleted user remain in room history.
The Matrix event timeline is an immutable append-only log - event content is preserved as sent.
The user's PII is removed from their profile, but message content in rooms is not scrubbed.
This is consistent with Matrix CS API v1.18 behavior.

## Rate Limits

The endpoint is governed by the `complianceRL` rate limiter: 10 requests/minute per IP (burst 10).
For bulk erasure operations, contact the system operator to temporarily raise the limit.

## Idempotency

The endpoint is idempotent with respect to deactivation (step 4 accepts `codes.AlreadyExists`
and continues). Re-running against an already-deleted user will re-apply anonymization and emit
a second audit record. Duplicate audit records are acceptable for traceability.

## After the erasure: remaining windows and the administrator group

* **Up to 60 s.** A raw IdP JWT (and any bearer a node already confirmed) is accepted on that node for up to 60 s after the erasure commit: the node-local provisioning cache is not evicted, the same bound as for a deactivation. In that window a still-running client can write the tables the erasure does not guard (device keys, receipts, room account data, the device row with its IP); profile, account data, cross-signing and the sync token are refused. Re-run the sweep below after that minute (follow-up `gn`: a cache eviction broadcast).
* **Remove an erased administrator from the IdP admin group.** The admin UI is governed by the group claim of the IdP, not by the erasure: an erased administrator who is still in the group can sign in to the admin UI (no personal data is re-created, the provisioning refuses). Remove the person from the group when you erase the account.
* An erased user cannot be reactivated: the admin reactivation is refused for a user with a `deletion_status`.

## Backups and retention

Erasure deletes rows in the live database. The deleted rows, the private keys that were set to NULL and the PII ciphertexts persist in the places PostgreSQL keeps old row versions until their retention expires: the table heap until `VACUUM`, the WAL / point-in-time-recovery archive, replicas and every database backup within its retention period. The erasure is therefore complete for the live system immediately and for the stored copies when the oldest backup that predates it has expired. State the retention period (N days) in the privacy notice. A restore of a backup taken before an erasure brings back the key and the ciphertext together with every row the erasure deleted: after any restore, re-run the erasure (or, for users already at `deletion_status = 'keys_deleted'`, the sweep below) before the restored system serves users. Long term, per-user private keys should be wrapped with a key encryption key held outside the database.

## Users erased before the gdpr-erasure-global-data release

Users erased by an older release keep rows the old erasure did not delete (global account data, cross-signing keys, device keys, ...), keep their `users` PII ciphertexts and stay active. The same one-off, idempotent sweep is the retry path of an erasure whose best-effort session teardown failed (a warning "ending ... failed" in the log; the response was `keys_deleted`), and the step after a database restore. Run it once as the operator role, after migration 000055 (it touches only `deletion_status = 'keys_deleted'`):

```sql
-- gdpr-erasure-global-data: one-off sweep for users erased BEFORE this release (deletion_status = 'keys_deleted'). Run once after the deploy (after migration 000055)
-- as the operator (owner) role; idempotent (a second run changes nothing); it is also the RETRY path of a failed post-commit session teardown of an erasure.
-- Built from the same table list as the erasure (UserDeletion.erased_tables/0), plus the teardown tables, the profile and the users row.
-- In psql run it with `\set ON_ERROR_STOP on` first, so that a failing statement stops the run instead of leaving an aborted transaction.
BEGIN;
DELETE FROM uia_sessions WHERE user_id IN (SELECT user_id FROM users WHERE deletion_status = 'keys_deleted');
DELETE FROM user_room_account_data WHERE user_id IN (SELECT user_id FROM users WHERE deletion_status = 'keys_deleted');
DELETE FROM account_data WHERE user_id IN (SELECT user_id FROM users WHERE deletion_status = 'keys_deleted');
DELETE FROM cross_signing_keys WHERE user_id IN (SELECT user_id FROM users WHERE deletion_status = 'keys_deleted');
DELETE FROM device_keys WHERE user_id IN (SELECT user_id FROM users WHERE deletion_status = 'keys_deleted');
DELETE FROM device_one_time_keys WHERE user_id IN (SELECT user_id FROM users WHERE deletion_status = 'keys_deleted');
DELETE FROM device_fallback_keys WHERE user_id IN (SELECT user_id FROM users WHERE deletion_status = 'keys_deleted');
DELETE FROM forgotten_rooms WHERE user_id IN (SELECT user_id FROM users WHERE deletion_status = 'keys_deleted');
DELETE FROM auto_join_opt_outs WHERE user_id IN (SELECT user_id FROM users WHERE deletion_status = 'keys_deleted');
DELETE FROM read_receipts WHERE user_id IN (SELECT user_id FROM users WHERE deletion_status = 'keys_deleted');
DELETE FROM oauth_account_sessions WHERE user_id IN (SELECT user_id FROM users WHERE deletion_status = 'keys_deleted');
DELETE FROM oauth_consent_requests WHERE user_id IN (SELECT user_id FROM users WHERE deletion_status = 'keys_deleted');
DELETE FROM oauth_codes WHERE user_id IN (SELECT user_id FROM users WHERE deletion_status = 'keys_deleted');
-- the post-commit session teardown tables (a teardown that failed after the commit left them; the tokens are dead, the rows are not)
DELETE FROM sync_room_cursors WHERE user_id IN (SELECT user_id FROM users WHERE deletion_status = 'keys_deleted');
DELETE FROM oauth_idp_refresh_leases WHERE user_id IN (SELECT user_id FROM users WHERE deletion_status = 'keys_deleted');
DELETE FROM jwt_device_bindings WHERE user_id IN (SELECT user_id FROM users WHERE deletion_status = 'keys_deleted');
DELETE FROM matrix_sessions WHERE user_id IN (SELECT user_id FROM users WHERE deletion_status = 'keys_deleted');
DELETE FROM sessions WHERE user_id IN (SELECT user_id FROM users WHERE deletion_status = 'keys_deleted');
DELETE FROM sync_tokens WHERE user_id IN (SELECT user_id FROM users WHERE deletion_status = 'keys_deleted');
DELETE FROM devices WHERE user_id IN (SELECT user_id FROM users WHERE deletion_status = 'keys_deleted');
UPDATE profiles SET displayname = 'Deleted User', avatar_url = NULL WHERE user_id IN (SELECT user_id FROM users WHERE deletion_status = 'keys_deleted');
UPDATE users SET anonymized_at = COALESCE(anonymized_at, keys_deleted_at), is_active = false, deactivated_at = COALESCE(deactivated_at, keys_deleted_at),
  display_name_encrypted = NULL, display_name_nonce = NULL, avatar_url_encrypted = NULL, avatar_url_nonce = NULL,
  email_encrypted = NULL, email_nonce = NULL, email_ephemeral_pub = NULL,
  last_seen_at = NULL, deactivation_reason = NULL
  WHERE deletion_status = 'keys_deleted';
COMMIT;
```
