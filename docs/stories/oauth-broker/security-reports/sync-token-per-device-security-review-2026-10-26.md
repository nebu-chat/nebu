## Security Review — sync-token-per-device (follow-up `fd`, epic oauth-broker)

**Diff scope:** staged diff in worktree `open-chat-oauth` (branch `feature/migrate-to-oauth2`): migration `000052_sync_device_positions` (up/down), `AccountDataStore` (put/3 in tx + `sync_global|` advisory lock + wake-up, `list_since/2`, `pending_since?/2`), `CrossSigningKeyStore` (put_keys/2 in tx + lock + `changed_pos`, `changed_since?/2`), `Session.PgStore` facade + `Postgres` (`get_positions/2`, `advance_positions/5`), `EventDispatcher.Server` (device key through initial sync / fallback, nil-anchor upsert removed), `Router.Protected` (`do_sync` device key, D9/D10/D11 delivery, 500 on account-data write failure, cross-signing write errors -> rollback), proto field `GetInitialSyncRequest.device_id`, docs, tests.
**Date:** 2026-10-26

### Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| - | - | - | No security issues found (CRITICAL/HIGH/MEDIUM/LOW: none) | - |

Informational observations (no severity, not blocking) are listed below.

### Verification of the focus areas

1. **Token as capability (cross-device / cross-user reuse).** The since token is never decoded; `sync_delta/2` looks up the row keyed by `(authenticated user, authenticated device)` and only compares the client token for equality (`client_since_token != stored_token` -> `fallback_to_initial_sync/2` under the CALLER's key). B with A's token, Y with X's token, a forged/malformed/empty/oversize `since`: all end in an initial-shaped answer built from the caller's partition and the caller's own `account_data` rows; the only writes (`persist_token`, `advance_positions`) are keyed on the caller's `(user, device)`, so A's / X's rows stay untouched. The `.<pos>` suffix only selects the caller's own ROOM account data (pre-existing). The new D9 positions live server-side in the already validated row and are never emitted to the client (no new client-controlled input, no sequence-value leak). Tests: Scenario 10 (four SECURITY tests incl. byte-identical foreign rows and ignored `device_id`/`deviceId` parameters).
2. **Source of the device key.** `authenticated_device_id/1` reads only `conn.assigns[:device_id]`, which is assigned only by `OidcPlug` (opaque session l.126, server-side DeviceBinding l.168); non-binary/nil -> `""` (per-user row, D2). No request parameter is consulted. A deleted device's token is rejected by OidcPlug (401) before any `sync_tokens` access.
3. **Information disclosure.** `list_since/2`, `pending_since?/2`, `changed_since?/2` are all `WHERE user_id = $1` with `$1 = conn.assigns[:current_user]`; `device_lists.changed` only ever gets the caller's own id (D10 / D9), never `left`. No cross-user path.
4. **SQL.** All new statements are parameterised (`$1..$5`); the lock key is built in SQL as `'sync_global|' || $1::text` from a bound parameter (no string interpolation in Elixir); `nextval('sync_global_pos_seq')` is a literal. No injection surface.
5. **Advisory-lock DoS.** Key = hash of `'sync_global|' || <authenticated user>`; only the user's own writes contend (cross-user blocking only via a 64-bit `hashtextextended` collision, and user ids start with `@`, so the namespace does not overlap the room-account-data key `hashtextextended(user_id)` or the UIA key `user|device`). The lock is `xact`-scoped; in the cross-signing paths it lives inside the existing UIA/first-upload transaction which does only DB work (consume + `FOR UPDATE` + upsert, no network/IdP call). Lock order is consistent (cross_signing row `FOR UPDATE` -> advisory; account_data: advisory -> account_data row; nobody holds an account_data row and then waits on the advisory lock): no deadlock cycle.
6. **Unbounded work.** `list_since` is bounded by the user's own `account_data` rows (same bound as the pre-existing initial sync / `list_all_and_clear`), indexed by `(user_id, stream_pos)`. The wake-up fans out only to the user's own `user:<id>` members (each wake answers one request the user itself issued; no amplification beyond the 600/min `/sync` limit). Hot-loop check: `pending_since?` zeroes the timeout only while a row is above `account_data_pos`; the same response advances the position under the token guard, so the next request long-polls (test "a pending change does not spin"). A failed `get_positions` reads as `{0,0}` -> immediate answers only while the DB read fails. Rate limits unchanged (`/sync` 600/min per IP; account-data PUT 60/min burst 30 per user).
7. **Error handling / LAW (no tokens, credentials, chat or account-data content in logs).** The only new log line is `Logger.error("global account data write failed: #{error_kind(reason)}")` and `error_kind/1` yields the exception MODULE name or an atom, never the message (Postgrex messages could quote values); the client gets a static `500 M_UNKNOWN`. Cross-signing write errors become `rollback(:write_failed)` -> static 500; the existing rescues log `inspect(e.__struct__)` only. `Nebu.Repo` runs with `log: false`, so the 1 MB `content_json` parameter is not query-logged. `{:error, e}` structs are returned, never `inspect`ed into a log or response. The UIA consume and the key write remain in ONE transaction (a failed nested `put_keys` marks the outer transaction rolled back; the approval is not burned).
8. **Migration.** DDL only; `GRANT USAGE, SELECT ON SEQUENCE sync_global_pos_seq TO nebu_app` (no UPDATE, no ownership change; column additions inherit table grants). Confirmed: `account_data`, `cross_signing_keys`, `sync_tokens` have no RLS (only `room_account_data` / `user_room_account_data` do), so no RLS bypass is introduced. Down drops only the four position columns, the index and the sequence.
9. **GDPR / retention.** The new `sync_tokens` columns are part of the device row and are removed by the existing device teardown (`destroy_session/2`) and user-wide deletes (`destroy_session/1`: logout/all, deactivation, erasure). `account_data.stream_pos` and `cross_signing_keys.changed_pos` are integers drawn from a global sequence and add no personal content; the known pre-existing erasure gap `ck` is NOT made worse (no new content column, no new table).

### Informational (no severity)

**INFO-1 — Lock waiters hold pool connections (pre-existing pattern).** `pg_advisory_xact_lock` waits without `lock_timeout` while holding one of the 10 pool connections. A user bursting 30 concurrent global account-data PUTs (1 MB each) serialises them and briefly occupies the pool. Bounded by the per-user limit (60/min, burst 30) and equivalent to the pre-existing row-lock serialisation of concurrent upserts of the same `(user, type)` and to `RoomAccountDataStore`. Possible hardening for a later story: `SET LOCAL lock_timeout` in the writer transactions.

**INFO-2 — Lazy JWT binding can share a device row (same user only).** An unbound raw IdP JWT is bound at `/keys/upload` to the body-supplied `device_keys.device_id` (pre-existing, `maybe_bind_jwt_device/3`). It can therefore share the `sync_tokens` row of another (legacy) device of the SAME user, causing fallbacks for that device (no miss: `advance_positions` is token-guarded), and the story's bound "rows <= synced devices + 1" is really "rows <= bound device ids + 1". No cross-user effect; all rows go with `destroy_session/1`.

**INFO-3 — Pre-existing first-upload race (not introduced, cheap fix available).** In `do_persist_cross_signing/3` the `FOR UPDATE` read of a NON-existent row locks nothing, and the new advisory lock is taken only inside `put_keys/2` AFTER the decision; two concurrent "first uploads" both take the UIA-free branch, the second overwriting the first. Adds nothing over the by-design UIA-free first upload, but taking the `sync_global|` lock before `get_keys_for_update/1` would close it.

**INFO-4 — Rolling deploy.** A node still running the old `put/3` writes without the lock and its `ON CONFLICT` branch leaves `stream_pos` unchanged, so such an overwrite is not delivered to device-bound clients until their next fallback. Correctness only; deploy all nodes before relying on D9.

### Summary

CRITICAL: 0 — block commit
HIGH: 0 — block commit
MEDIUM: 0 — advisory, address before epic end
LOW: 0 — advisory

**Verdict:** APPROVED (CLEAN)
