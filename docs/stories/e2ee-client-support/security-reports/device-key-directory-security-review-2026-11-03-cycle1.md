## Security Review — device-key-directory (epic e2ee-client-support), delta re-review cycle 1

**Diff scope:** the fixes for the 4 findings of `device-key-directory-security-review-2026-11-02.md`: `server/lib/nebu/matrix/http_key_directory.ex` (`charge/2`, `target_key/3`, `limits/0`), `server/lib/nebu/matrix/device_list_store.ex` (`@left_sql`), `server/lib/nebu/web/router/protected.ex` (`keys_changes` tier), `server/lib/nebu/web/plugs/rate_limit.ex` (unchanged, `charge_buckets/2` re-read), `docs/architecture/11-risks.md` and the limit docs (05, 07, 08, story D8/D9).
**Date:** 2026-11-03

### Status of the previous findings

| # | Prev. severity | Status | Evidence |
|---|---|---|---|
| 1 | HIGH | CLOSED | see below |
| 2 | LOW | CLOSED | `@left_sql` branch 1 now `AND m.left_at IS NULL` (device_list_store.ex:58) |
| 3 | LOW | CLOSED | `@keys_changes_rate_limit` (60/min, burst 20, `key: :user`) applied in the route before `HttpKeyDirectory.changes/1` (protected.ex:913-917) |
| 4 | LOW | ACCEPTED / documented | 11-risks.md row "cluster-wide advisory lock (4760, 60)", plus 07-deployment (2) |

**Finding #1 verification**

(a) Fixed-size keys, no body reference.
- Per-target key `{"keys_claim_target", user, :crypto.hash(:sha256, [uid, 0, did])}`: the digest is a fresh 32-byte heap binary. Neither uid nor did is stored. The ids exclude NUL (`valid_target?`), so `uid <> 0 <> did` is injective.
- Stage-1 keys `{"keys_claim", user}` and `{"keys_claim_targets", user}`: `user` is `conn.assigns.current_user`, never request body.
  - Opaque path: `sess.user_id` comes from Postgrex, and the default `decode_binary: :copy` copies it (deps/postgrex type_module.ex:53).
  - JWT path: `UserId.from_claims` builds a new binary.

(b) ETS growth is bounded.
- Stage 1 `take_all([request bucket, targets bucket])` touches only the 2 per-caller rows.
- Stage 2, which creates up to 1000 per-target rows, runs only after stage 1 returns `:ok`.
  - A request denied in stage 1 (including an attacker whose caller buckets are empty) creates no per-target row.
  - A stage-2 denial keeps the rows `charge_buckets/2` inserted (no short circuit; the refund keeps the row). That growth is already paid by the stage-1 targets tokens.
- Per account, per node: at most about 1000 + 600/min x (1 h idle + up to 10 min sweep), roughly 43k small rows (a few MB, no pinned bodies). It grows linearly with the number of colluding accounts, as recorded in 11-risks (1).
- `check_cap` (1000) runs before any charge. A cost above the burst is charged as the burst.

(c) No existence oracle.
- The stage-1 cost is `length(valid)`, i.e. syntactic validity only.
- Stage-2 buckets are charged for every valid target, whatever its state. A 429 depends only on the caller's own past claims.

(d) No cross-user starvation.
- All three bucket keys contain the authenticated caller, so one account cannot drain another account's buckets.

Regression tests exist: `test/nebu/matrix/device_key_directory_claim_budget_test.exs` (`referenced_byte_size`, row growth) and `device_key_directory_changes_http_test.exs` (the keys_changes tier). The tests were not run by this reviewer.

**Finding #2 verification**

The check is whether the fix hides a leave the caller needs. `room_members` soft-deletes: leave sets `left_at`, so rows stay.
- If the caller C later leaves the shared room too, branch 2 (C's own leave) joins every member row of the room, including those with `left_at` set. X is then still reported, as long as C's leave lies in the window.
- In `/sync`, `to` is the current position, so a leave is never lost.

Informational only, no severity: for a `/keys/changes` window with a historical `to` that lies between X's leave and C's later leave, X is no longer listed in `left` for that window. It is reported in the following window (via C's leave). Under-reporting `left` only means a client keeps tracking X's device list a bit longer. This is not disclosure, and Megolm sharing follows room membership, not the tracked list. The doc wording "never under-reports a real loss" (11-risks (3)) is slightly too strong for historical `to` values; tightening it is optional.

**Finding #3 verification:** the tier runs after authentication (Protected router) and before any `DeviceListStore` query. The bucket is per user. The 429 goes through the shared plug envelope.

**New problems introduced by the fix:** none found.
- `rate_limit.ex` is unchanged.
- No new log lines that carry ids or key material: the `error_kind` logging is unchanged.
- No new route.
- No state-dependent branch.

### Findings

No security issues found (delta scope above).

### Summary

CRITICAL: 0 — block commit
HIGH: 0 — block commit
MEDIUM: 0
LOW: 0 (previous LOW #4 accepted and documented)

**Verdict:** APPROVED
