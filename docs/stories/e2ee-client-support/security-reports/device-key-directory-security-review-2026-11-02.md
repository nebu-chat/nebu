## Security Review — device-key-directory (epic e2ee-client-support)

**Diff scope:** staged diff, 11 files under `server/lib` and `server/priv`. New `POST /_matrix/client/v3/keys/claim` (`HttpKeyDirectory`, `KeyClaimStore`), new `GET /_matrix/client/v3/keys/changes` (`DeviceListStore`), `/sync` `device_lists` and per-device OTK/fallback fields, the `.d<pos>` sync-token group, migration 000060 (`device_list_changes` plus a commit-time stamp trigger and a `room_members` trigger, `device_fallback_keys.key_id`), RequestLogger body/query redaction for the key routes, `user_signing_keys` limited to the caller in `/keys/query`, and the GDPR erasure entry.
**Date:** 2026-11-02

### Prescan candidates

| Candidate | Decision |
|---|---|
| `device_key_store.ex:501` `DELETE FROM #{table}` | Dismissed. `table` iterates the compile-time module attribute `@device_tables`; user_id/device_id are bound parameters. |

### Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| 1 | HIGH | server/lib/nebu/matrix/http_key_directory.ex:129-132 (`charge/2`) | Authenticated memory exhaustion: one ETS rate bucket is created per attacker-chosen `(uid, did)` (up to 1000 per request). The bucket keys are Jason sub-binaries that pin the whole request body (up to 1 MB) for at least an hour | Bound bucket creation per caller (charge the caller bucket `cost = length(valid)`, or key the per-target bucket on a fixed-size hash), and `:binary.copy` any request-derived term before it goes into ETS |
| 2 | LOW | server/lib/nebu/matrix/device_list_store.ex:54-66 (`@left_sql`) | Membership-timing leak: the first `left` branch checks only that the caller has *some* `room_members` row in the room (no `left_at IS NULL`). A caller who already left room R still learns when another user left R later | Restrict branch 1 to rooms the caller was still joined in when the leave happened, or accept and document it as part of the "over-report" rule |
| 3 | LOW | server/lib/nebu/matrix/http_key_directory.ex (`changes/1`), router `get "/client/v3/keys/changes"` | `/keys/changes` has no rate limit, and `from=…d0` forces a full-range scan of the stream (the table is bounded by users + memberships) | Add a per-user read tier (e.g. 60/min) like the other read endpoints added in this epic |
| 4 | LOW | migration 000060 `device_list_changes_stamp()`, device_list_store.ex:145 `position/0` | One cluster-wide advisory lock (4760, 60) is held from the stamp trigger to COMMIT for every membership and key write. Every `/sync` with a token without `.d` (any client can send one) and every initial sync also takes it | Hardening: monitor contention; consider `pg_try_advisory_xact_lock` and a retry in `position/0` |

### Detail

**Finding #1 — Per-target claim buckets keyed on unverified ids pin request bodies in ETS** [HIGH]

`charge/2` builds one `RateLimit.take_all` bucket `{"keys_claim_target", user, uid, did}` for every syntactically valid target. "Valid" only requires 1..255 bytes, no NUL, a uid that starts with `@` and contains `:`. Existence is deliberately not checked (no-oracle rule), so the attacker picks every key freely. Per request: 1000 targets, so up to 1000 new ETS rows. The caller bucket counts *requests* (burst 10, 30/min), not targets. Over one hour that is about 1,810 requests × 1,000 = ~1.8M rows per account per node. Idle rows are only evicted after `@idle_ms` = 1 h, plus up to the 10-minute sweep interval.

The keys pin the request bodies:
- Plug.Parsers decodes with Jason's default `strings: :reference`. Verified: the decoded uid key of a ~900 KB body has `:binary.referenced_byte_size/1` = 900,144.
- ERTS copies a sub-binary longer than 64 bytes into ETS as a reference to the parent binary. Verified: 50 inserted keys kept 45 MB of `:erlang.memory(:binary)` alive until the table was deleted.
- So a request with one 65..255-byte uid or device id keeps its whole ~1 MB body alive as long as the bucket row lives.

Impact: about 1.8 GB of binary memory per account per node per hour (≥ 200 MB of ETS even with short ids), growing linearly with the number of accounts. The default 2 GB container limit is reached by one ordinary user in about an hour, or by two or three users much sooner. A node OOM takes down Matrix, Admin and media for everyone. This is the same class as the HIGH in server-side-key-backup (authenticated OOM). Exploitable with standard credentials and trivial effort.

Remediation, apply all three:
1. Charge the caller bucket per target: add `{{"keys_claim_targets", user}, length(valid), N, N}`, e.g. N = 1000/min. Bucket creation is then bounded per account, and the cost does not depend on target state, so no oracle.
2. Key the per-target bucket on a fixed-size digest, `:crypto.hash(:sha256, uid <> <<0>> <> did)` (32 bytes, stored as a heap binary), or `:binary.copy/1` the ids.
3. Add a regression test that asserts ETS row growth per request is bounded and that `referenced_byte_size` of stored keys is not the body size.

**Finding #2 — `left` reports leaves in rooms the caller already left** [LOW]

In `@left_sql` branch 1, `EXISTS (SELECT 1 FROM room_members m WHERE m.room_id = c.room_id AND m.user_id = $1)` has no `left_at` condition. If caller C left R at t0 and X leaves R at t1 > t0, and X shares no joined room with C, then `/keys/changes?from=<pos before t1>` returns X in `left`. The caller controls `from`, so it can bisect positions. The only thing learned is roughly when X left a room that C no longer belongs to. Whether X shares a room with C is already visible today. Low impact; covered in spirit by the documented over-report. Fix: `AND (m.left_at IS NULL OR m.left_at >= <leave time of X>)`, or drop branch 1 for rooms the caller already left.

**Finding #3 — `/keys/changes` unthrottled, client-chosen scan floor** [LOW]

`from`/`to` are parsed strictly (`\z` anchored, int8 bounded, 512 bytes; good). But any `.d0` floor makes both CTE queries scan the whole `pos` range, and the endpoint has no rate tier. The table is one row per (user, room), so the cost is bounded but O(memberships) per request. Add a per-user read bucket.

**Finding #4 — Global commit lock** [LOW]

The design (commit-ordered positions) is sound and correct, but it serialises every key/membership commit across the cluster, and any authenticated client can make `/sync` take the lock on every request by stripping `.d`. Sync is rate limited (600/min, per IP), so the impact is contention, not a denial of service. Hardening note only.

### Verified (no finding)

- **Claim authorization:** inside the single statement, the target is the caller itself or a user with a shared room where both sides are joined (`room_members` holds joined rows only; `left_at IS NULL` on both sides). Caller and target must be active and not deleted. No IDOR. Unknown, unshared and remote targets all produce the same response shape (omitted, `failures` `{}`) and run the same statement. The per-target bucket is charged regardless of target state, so a 429 does not reveal existence.
- **Exactly-once claim:** `FOR UPDATE SKIP LOCKED` picks the row and `UPDATE … ctid = ANY(...)` consumes it in the same statement. The fallback key is marked `used` and never deleted.
- **Input handling:** a too-large or malformed body becomes `%{}`, which answers 400 (fail closed). The 1000-target cap is checked before any charge. `take_all` is all-or-nothing.
- **No key material in logs:** RequestLogger excludes request and response bodies for `keys/claim` and `keys/upload` (exact path shape, decoded segments, empty segments dropped). `keys/changes` logs query parameter names only. Error logs contain only the module or atom name.
- **Token parsing:** `strip_position` bounds the digits (≤19, ≤ int8 max) before `String.to_integer`; `parse_token` anchors with `\z`.
- **`/keys/changes` reachability:** every branch of `changed` requires that the caller currently shares a joined room with the reported user (or is that user).
- **`/keys/query`:** `user_signing_keys` is now limited to the caller (a correct hardening).
- **Migration 000060:** `GRANT` to `nebu_app` is present; RLS is ENABLE + FORCE with one policy per command; triggers are SECURITY INVOKER; no key material in the new table; `device_list_changes` is in `UserDeletion.@erased_tables`.
- **Cross-signing:** the pending marker `-1` is never `> since`, so a pending row is invisible until the deferred stamp assigns its commit-time position.

### Summary

CRITICAL: 0 — block commit
HIGH: 1 — block commit
MEDIUM: 0
LOW: 3 — advisory

**Verdict:** BLOCKED (Finding #1)
