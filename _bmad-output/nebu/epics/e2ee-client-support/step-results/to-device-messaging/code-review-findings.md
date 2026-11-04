# Code review (cycle 0): to-device-messaging (REQ-2026-012)

Reviewer: nebu-code-reviewer (read-only, static; could not run mix/Postgres). 0 MAJOR, 6 MINOR, 8 INFO. Oracle MUSTs met (event shape, `{}` answer, persisted txn idempotency keyed (user, device, type, txn id), `*` at send time, explicit wins, sending device excluded, order by stream_pos, `to_device` always emitted, 100 msg / 1 MiB cap with immediate continuation, initial sync delivery, error codes).

## MINOR
1. Ack position can cover another in-flight response's messages (to_device_store.ex:385-406): `position = max(since, nextval, stamped)` takes a fresh `nextval` even when the stamping UPDATE touched 0 rows (lost the row-lock race to a concurrent response of the same device). Trace: syncs A and B of one device present the same `since`; B read `[m]` before `n` committed; A read `[m,n]` and stamps both with seq 10; B gets seq 11, its UPDATE matches 0 rows, its token carries position 11; if A's response is lost and the client continues from B's token, the next sync's ack (`delivery_seq <= 11`) deletes `n`, which the client never received. Narrow window (two overlapping syncs, differing batches, lost response). 08-concepts admits "two syncs in flight can acknowledge what the other carried" but the next sentence ("covers exactly the batch a response carried") contradicts it: fix the sentence or the design.
2. Volatile, side-effecting lock function inside a WHERE (to_device_store.ex:185-187): `pg_try_advisory_xact_lock_shared(...)` is one qual of the `users` scan in `active_users`; qual order is not guaranteed, a seq scan on a small `users` table may lock every user (max_locks_per_transaction exhaustion, blocks other users' erasure). Lock only matched ids (MATERIALIZED CTE / OFFSET 0 fence, or unnest the matched ids and lock in an outer query).
3. ADR-020 reach-through: to_device_purge_worker.ex:15 calls `Nebu.Matrix.ToDeviceStore.purge_expired/0` directly: add a facade function (precedent `Nebu.Matrix.purge_expired_uia_sessions`, matrix.ex:976). The router calling `ToDeviceStore` directly (protected.ex:127,193) follows `RoomAccountDataStore` precedent (lower priority).
4. Test seam in a production hot path (event_dispatcher/server.ex:6099-6104: `Application.get_env(:nebu, :atdd_to_device_before_join)` on every incremental sync). (Orchestrator: accepted, cheap get_env.)
5. Stale moduledoc to_device_store.ex:21-25 ("Budgets") omits the per-sender-user cap (200 / 4 MiB) and the fair user-level eviction.
6. Docs arithmetic 08-concepts.md:1426: 64 KiB content reaches "at most 16 devices"; with `fit_fanout_bytes` (1 MiB, content + 128 per row) near-64 KiB reaches 15: say "about 16" or "15".

## INFO
Fair-eviction SQL correct and the HAVING prefilter does not change results; caps are soft under concurrent senders (overshoot of one request's rows, bounded by the gate and rate limit); late commits neither deleted nor lost (unstamped), delivery order follows stream_pos; sequence reset after down+up of 000059 or a DB restore (operator note); token compatibility good (old two-part tokens unchanged; rolling deploy: old node reads a three-part token as unknown core -> initial sync, redelivery only); sync hot-path cost +6-7 statements even with an empty queue; `take_within_bytes` (:375) duplicates the SQL byte cut and is dead in practice; `limits/0` rebuilds a 14-key map with `String.to_atom` several times per send; wake-up residual window across nodes (same as room-event wake-ups); purge worker cluster-safe (leader-only cron, SKIP LOCKED) but shares the limit-1 `oauth_cleanup` queue and keys txn purge/trim on `ctid`; non-transactional `DeviceKeyStore.delete_device/2` swallows errors (only caller: caller's own device after UIA, protected.ex:2892; TTL cleans up); content re-encoded through Jason (semantically equal, not byte-identical); unused alias in to_device_identical_device_test.exs:11 (`alias Nebu.Matrix.ModerationTestSupport, as: S`) causes a compile warning; statement-count ranges in history_visibility/member_prev_content tests accepted.

## Verified clean
Recipient rule (`room_members.left_at IS NULL` on both sides = both join; identical statement shape for unknown/unshared/deactivated); send path order authenticate -> rate limit -> gate (429 before the body) -> 64 KiB parse; gate monitor-based; shared try-lock on sync_global|<sender>, erased status read after the lock, txn record in the same transaction; logging (kind only; RequestLogger/RouteNormalizer cover the route; `rescue` in pending_query/undelivered? keeps Repo-less dispatcher tests green); GDPR (both tables in erased_tables + sent-by step under the same exclusive lock); device removal paths; migration 000059 up/down symmetric, grants and RLS like 000058; docs match apart from 1, 5, 6.

---

# Code review (cycle 1, delta, sonnet): to-device-messaging (REQ-2026-012)

Reviewer: nebu-code-reviewer (read-only, static). 0 MAJOR, 3 MINOR, 6 INFO. Scope: the cycle-1 delta (reference-impl-cycle1.diff plus removal of `take_within_bytes/2` and the 11-risks item 11).

All cycle-0 MINORs (1, 2, 3, 5, 6; 4 stays accepted) and all Kassandra cycle-0 findings (HIGH 1, MEDIUM 2-5, LOW 6) are resolved in code. No new defect found in eviction SQL, lock ordering, error mapping or logging.

## MINOR
1. user_deletion.ex:11-12 (moduledoc step 4a) and :250-253 still describe only the `sync_global|` fence; the exclusive `to_device_erasure|` lock at :279 is missing.
2. Position wording inexact: 08-concepts "never exceeds its own stamps (else `since`)", 11-risks (8), story D21 vs to_device_store.ex:455-457 (code also counts stamps of already-stamped carried rows). Reword to "never covers a row it did not carry".
3. Risk wording: 11-risks (11) says "a `*` send" but explicit device entries take the same `KEY SHARE` and 100 ms wait (to_device_store.ex:275); 11-risks (4b) "a slot is never held for long" (the timeout is per statement, ~12 statements per transaction, slot held for the whole run); CHANGELOG "429 before the body is read" is false for the byte bucket (fires after the parse).

## INFO
- Position over-cover edge with more than 100 pending rows and a late-committed low stream_pos (pre-existing design, now in the capped formula).
- `delete_device/2` is all-or-nothing and silent (one failing DELETE keeps everything, caller still sees :ok); before it was per-table best effort, also silent.
- `charge_bytes` tokens are not refunded when the transaction later fails; retries are charged again (node-local, state independent).
- Persistent delivery error with a pending row: pre-check at protected.ex:124-128 gives timeout 0, so /sync answers 200 immediately and a client may loop without backoff (formerly 503); bounded by the sync rate tier and the 2 s statement timeout.
- `limits/0` rebuilds 20 keys with `String.to_atom` about 6 times per send; every sync pays one extra `set_config`.
- 07-deployment operator list omits the 1 MiB per sender-and-device and the 200 msgs / 4 MiB per sender-and-recipient-user shares (08-concepts has both).

---

# Code review (cycle 4, delta, sonnet): two-phase send

Reviewer: nebu-code-reviewer (read-only, static). 0 MAJOR, 2 MINOR, 4 INFO. Verified clean: KEY SHARE window holds only the two device lookups, the INSERT and the commit (no FK/trigger on to_device_messages; phase 2 touches only to_device_messages); `set_config(.., true)` per transaction incl. phase 2; `settle/3` also catches `:exit`; slot released by try/after and :DOWN; replayed txn id runs no wake and no phase 2; erasure fence holds; phase 2 always 7 statements (no oracle); logging kind-only; ADR-018/019/020, cluster safety.

## MINOR
1. docs/architecture/08-concepts.md:1426 "Concurrency bounds": says every statement of a send runs under the 2 s timeout with 429 and txn id not burnt: false for phase-2 eviction statements (timeout there = 200, row stored). Add "(phase 1; a phase-2 timeout is only logged and the send answers 200)".
2. CHANGELOG.md:14: the parenthetical "(a failed eviction never fails the send; node-local, `429` before the body is read)" now reads as if the eviction were node-local; move "node-local, 429 before the body is read" back after the slots and give the eviction its own clause.

## INFO
- http_to_device.ex:16 moduledoc: "a statement over the 2 s timeout" as 429 cause holds only for phase 1 ("of the first transaction").
- Phase 2 is one all-or-nothing transaction: one failing statement rolls back the other six; docs "until the next send" assumes the next eviction succeeds: say "until an eviction succeeds or the purge" (matches Kassandra LOW 2). Possible later hardening: per-statement catch-up in the purge worker.
- Test gaps without a mutant: (a) a phase-1 refusal (byte-bucket 429, lock_busy) runs zero eviction statements; (b) the `catch :exit` branch in `settle`. The docs-test source pin `String.slice(after_send, 0, 4_000)` is fragile if `send/5` grows. Orchestrator: (b) accepted; (a) optional.
- `server/test/nebu/matrix/regression_sync_load_test.exs` is unstaged-deleted: that is `ci_run.sh` parking it during the gate (restored afterwards); keep it out of the commit.
