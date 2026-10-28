# Code review: sync-token-per-device (follow-up `fd`), cycle 0, 2026-10-26

**Verdict: APPROVE WITH MINOR FIXES. 0 MAJOR, 6 MINOR, 15 INFO.** Every Oracle MUST is met. The D9 lock, nextval, GREATEST and token-guard scheme is race-safe, and the lock order cannot deadlock. No hot loop occurs in normal operation. Cycle 0, so nothing has persisted across cycles.

Scope: `git diff --staged` in the worktree `open-chat-oauth` (24 files). Inputs: the story (Gherkin 1-14, D1-D11, Sizing), the oracle context, `dev-report-cycle0.md`, `atdd-report.md` and `test-review-findings.md`. No docker, no tests run (read-only).

## Oracle MUST / requirement check

| Requirement | Status |
|---|---|
| `AccountDataStore.put/3`: `stream_pos = nextval` in BOTH the INSERT and the ON CONFLICT branch | met (`account_data_store.ex` ~l.82-88) |
| F3: two columns, each advanced only to the max of its own source | met (`protected.ex` l.291-301, `postgres.ex` advance SQL) |
| F5: `pending_since?` pre-check sets `timeout_ms` to 0, plus a post-commit `notify_sync` that is cluster-wide | met (`protected.ex` l.113-121, l.143; `account_data_store.ex` l.98-101, l.226) |
| F4/D10: a fallback to a request WITH a `since` always lists the own user (device-bound and device-less); without `since` nobody is listed; never in `left` | met (`protected.ex` l.304, l.315-319) |
| 200 for an unknown, stale, foreign, malformed, empty or oversize `since`; 401 M_UNKNOWN_TOKEN for a deleted device before any lookup | met (no change to auth; HTTP scenarios 10/11) |
| D1: device key only from `conn.assigns[:device_id]` | met (`authenticated_device_id/1`, l.136-141; request params ignored, test l.818) |
| D4: exactly one token write, real anchor | met (`server.ex` `persist_token/4`; the nil-anchor upsert is removed) |
| Statement-count contract (+3 per `/sync`) | met, no re-pin needed |
| Test-review M1/M2 (`sync_membership_partition_http_test.exs` l.1203 vacuous, AC10 margin) | both fixed in the staged amendments |

## Adversarial analysis (focus areas)

**(1) Race safety of D9.** For one user, position order equals commit order, for these reasons:
- Both writers take `pg_advisory_xact_lock(hashtextextended('sync_global|'||user,0))` BEFORE `nextval`.
- PostgreSQL makes a commit visible (ProcArrayEndTransaction) before it releases transaction locks, so a writer's `nextval` is always drawn after the previous writer's commit is visible.
- `list_since` is one READ COMMITTED statement, so it cannot see N+1 without N.
- The cross-signing position is drawn under the same lock. In the nested case it stays held until the OUTER commit, so the order still holds.

The advance has three guards:
- `GREATEST` per column.
- `WHERE since_token = <this response's core token>`, so only the one response that carries this token can advance.
- It never inserts a row.

A read between the two sources cannot lift the other column, because there are two columns.

*Lock order:*

| Path | Lock order |
|---|---|
| Replacement | `Uia.consume` (uia row) -> `get_keys_for_update` (cs row FOR UPDATE) -> advisory |
| First upload | FOR UPDATE (cs row, if any) -> advisory |
| Global AD PUT | advisory -> `account_data` row |
| Signature merge (`put_keys_no_flag`) | cs row only, no advisory |

The advisory lock is always the LAST lock acquired by any path that already holds a row lock. The only path that takes the advisory lock first (AD PUT) never asks for a cs or uia row afterwards. So no cycle and no deadlock.

Inner `Repo.rollback` or a raise inside the nested transaction marks the outer one failed (DBConnection), and both callers roll back. That is correct.

**(2) Concern 1 (miss direction).** Confirmed as MINOR m1 below. The dev's reason for not fixing it is weak: the token guard already makes "reset" safe.

**(3) Fallback / nil anchor / D4 / key selection.** Correct:
- `fallback_to_initial_sync/2` forwards `device_id` into `GetInitialSyncRequest`, and `initial_sync/2` persists under that key.
- `get_initial_sync` has no other caller.
- Device-less is `""` -> `persist_since_token/3`.
- A lazy JWT binding switches to the device row and pays one fallback (D2).
- A binding lookup that returns nil flips the request to device-less for that request (INFO i10).

**(4) D10/D11 and spin.**
- The wake is sent after `{:ok, :ok}`, i.e. after the commit, via `:pg.get_members/1`.
- Device-less requests get no pre-check, so they cannot spin.
- A device-bound pre-check can only stay true across requests when `advance_positions` keeps failing or `get_positions` keeps returning `{0, 0}`. The first is correlated with the token upsert failing too (the request then 500s). The second is INFO i3.
- The `since_token` guard can only miss when a concurrent request of the SAME device replaced the token. That response then advances its own positions, so this is no loop.
- No hot loop in normal operation; HTTP test l.535 pins "no spin".

**(5) Error handling.** Every caller of `put/3` (1) and `put_keys/2` (2) handles `{:error, _}`. No `:ok =` match or ignored result remains in `lib/`. Callers list: `grep` over `server/lib` gives `protected.ex` l.1003, l.2888, l.3014.

---

## MAJOR

None.

## MINOR

### m1. An initial-shaped answer whose `list_since(user, 0)` read fails never lowers `account_data_pos`, so a reset client misses older rows (dev concern 1). D9 and the docs claim "never miss".
- **Where:** `server/lib/nebu/web/router/protected.ex` l.291-301 (`max(ad_latest, ad_pos)` with `ad_latest = 0` from `{pos, []}`), `server/lib/nebu/matrix/account_data_store.ex` l.186-198, `postgres.ex` `@advance_positions_sql` (`GREATEST`).
- **What goes wrong:** a device with `account_data_pos = P > 0` does an initial sync (no `since`, e.g. after clearing its cache) or a fallback, and the account data read fails transiently. The response carries no `account_data`, and the column stays at P. Every later delta delivers only rows above P. Element's `m.secret_storage.*` / `m.cross_signing.*` / push rules stay missing on that client until the type is written again or another initial sync happens. This is the "miss" direction that D9 ("Failure direction is always 'deliver again', never 'miss'"), the code comment at l.285 and `08-concepts.md` say cannot happen.
- **Pre-existing equivalent:** `list_all_and_clear` returning `[]`. So it is not a regression, but the new docs claim the opposite.
- **Why the dev's reason for not fixing it does not hold:** "it reopens the race GREATEST guards" does not apply. The advance is already guarded by `since_token = <this response's token>`, and only ONE response can carry that token, so there is no concurrent writer of the same (row, token) to race with.
- **Fix:** either make `list_since` distinguish a failed read (e.g. `{:error, pos}` or a third tuple element) and, on an initial-shaped response with a failed read, set `account_data_pos = 0` (plain SET, same token guard); or, on initial-shaped responses, write the read value without `GREATEST`. Add one HTTP test: initial sync with `stream_pos` unreadable, then column back, then the next delta delivers the rows. The existing tests l.1019 / store l.561 cover only the delta case.

### m2. Rolling deploy and lock cost of migration 000052 are wrong in the comment and missing from the release note.
- **Where:** `server/priv/migrations/000052_sync_device_positions.up.sql` l.15-16 ("Every new column has a default, so a node that does not know the columns yet keeps working (rolling deploy)"), l.20 (volatile `DEFAULT nextval`); `docs/architecture/07-deployment.md` l.272 ("migration 000052 adds ... DDL only").
- **(a) Old nodes break delivery to new clients during a mixed-version window.** An old node's `AccountDataStore.put/3` UPDATE branch does not touch `stream_pos` and takes no lock. An overwrite (for example a rotated `m.secret_storage.default_key` or a push-rules change) written by an old node keeps its OLD position. Device-bound clients on new nodes never receive that version, until the type changes again or the client does an initial sync. Old-node `put_keys` likewise leaves `changed_pos` unchanged, and old-node inserts draw `nextval` from the default without the lock, so they can commit out of order. So the old node "keeps working" only in the sense of not crashing. Delivery is permanently lost for writes made in the window.
- **(b) Lock and time cost.** `ADD COLUMN ... DEFAULT nextval(...)` has a VOLATILE default. That forces a full rewrite of `account_data` (rows up to 1 MB of content, TOAST copied) under ACCESS EXCLUSIVE, plus a non-concurrent index build in the same transaction. It is not catalog-only like the other three columns. The 000051 release note set the precedent: it documents locks, a maintenance window and a manual pre-create path. 000052 says "DDL only".
- **Fix:** correct the migration comment. Add a release-note sentence covering the table rewrite, the lock and the duration, and "deploy without a mixed-version window (or accept that overwrites written by old nodes during the window reach device-bound clients only at their next change / initial sync)". Optionally pre-stamp via a trigger. A doc fix is sufficient.

### m3. A failed cross-signing write is now a silent 500: no log line.
- **Where:** `server/lib/nebu/web/router/protected.ex` l.2888-2891 (first upload) and l.3014-3017 (`m.oauth` replacement); `server/lib/nebu/matrix/cross_signing_key_store.ex` `put_keys/2` `rescue e -> {:error, e}`.
- **What changed:** before, a write failure raised a MatchError out of the transaction fun. The callers' `rescue` then logged a value-free line (`"cross-signing key read failed: <struct>"` / `"m.oauth cross-signing replacement failed: <struct>"`). Now `put_keys/2` swallows every error and the caller does `Repo.rollback(:write_failed)` without logging. An operator sees a 500 `M_UNKNOWN` with nothing in the log. The global account data PUT got exactly this log line (`error_kind/1`, l.1009); the two cross-signing callers did not.
- **Fix:** `Logger.error("cross-signing key write failed: #{error_kind(reason)}")` in both `{:error, _reason}` branches (reuse `error_kind/1`).

### m4. The new error branches are untested.
- **What is not tested:**
  - The global account data PUT -> `500 M_UNKNOWN` mapping (`protected.ex` l.1003-1011) is not exercised over HTTP.
  - `error_kind/1` (content never logged) is not exercised.
  - The two `put_keys` `{:error, _} -> Repo.rollback(:write_failed)` branches have no test. In particular "a failed key write in the replacement path does NOT burn the `m.oauth` approval" (the UIA consume is rolled back) is now reached through a different mechanism than the old raise.
  - The store test "a failed write sends NO wake-up" (store test l.476-506) accepts both a raise and `{:error, _}` (`refute outcome == :ok`), so it does not pin the new `{:error, reason}` contract that the route now depends on. A regression back to raising would 500 the same way, but would put a Postgrex error (which can quote values) into a crash report.
- **Fix:** an HTTP test with the existing blocking-trigger technique (store test l.480-487) on `account_data` -> 500 `M_UNKNOWN`, no row, no wake, and a `capture_log` that contains the kind and not the content. The same on `cross_signing_keys` for both callers, plus the approval still being usable after the 500. Tighten the store test to `assert {:error, _} = outcome`.

### m5. Docs drift (the old per-user / consume-once wording survives next to the new sections).
- `docs/architecture/08-concepts.md` l.1343-1344: "The core token is the opaque value the sync core stores per user (unchanged semantics ...)". It is now per device (this story).
- `docs/architecture/06-runtime.md` l.1772 (cross-signing replacement sequence): "sets cross_signing_changed so peers see device_lists.changed". The write now also takes the `sync_global|` lock and stamps `changed_pos`. Device-bound clients read the position, not the flag, and "peers" was already inaccurate (only the own user is listed, `cm`).
- `docs/architecture/05-building-blocks.md` l.2000: still names `put_global_account_data/3`, which no longer exists (it is `put_global_deliveries/6`). The appended note at l.2009-2018 says the flags "described above stay for device-less requests", but the paragraph above still says "an INCREMENTAL sync returns only entries whose changed flag is set" without qualification.
- **Fix:** three one-line edits.

### m6. Stale RED-phase prose in the new test files (they are GREEN in the same changeset).
- `server/test/nebu/matrix/sync_token_per_device_store_test.exs` l.3 ("RED-phase acceptance tests ...") and l.38-39: "The functions of this story are called through apply/3: the red suite must COMPILE without them ... a missing function then shows as the UndefinedFunctionError of the test, which is the right red reason".
- `sync_token_per_device_dispatcher_test.exs` l.3, `sync_token_per_device_http_test.exs` l.3, `server/test/nebu/migration/000052_sync_device_positions_test.exs` l.3: the same "RED-phase acceptance tests" headers.
- `sync_token_per_device_store_test.exs` l.21: "After adding migration 000052 reset the throwaway database". This one is fine as an ops hint.
- **Fix:** reword the headers to "acceptance tests". The `apply/3` indirection can stay, but its comment should say why it is kept (or replace it with direct calls now that the functions exist).

## INFO

- **i1. Lock order (dev concern 3): no cycle, see the analysis above.** The cost: a global AD PUT of the same user waits for an in-flight cross-signing transaction from `put_keys` to the outer commit (milliseconds; the UIA consume runs before the lock). Acceptable.
- **i2. The shared lock key is not needed for correctness.** Each column is read and advanced only from its own table, and per table the commit order is guaranteed by any per-user key. Sharing it only couples AD PUTs to cross-signing transactions (i1). The key SQL is duplicated as a literal in two modules (`account_data_store.ex` l.221-222, `cross_signing_key_store.ex` l.57). Drift would be harmless for correctness but would break the "same key" test (store l.368). Optional: one shared private helper or a module attribute.
- **i3. Spin under a persistent `get_positions` failure.** The facade and `Postgres.get_positions/2` return `{0, 0}` for "no row" AND "read failed" (`pg_store.ex`, `postgres.ex`). While that read fails, every device-bound `/sync` with a `since` of a user who has any account data has `pending_since?(user, 0) = true`, so `timeout_ms = 0`. Each answer carries all global account data and returns at once, and the client loops up to the 600/min limit. The advance still works, but the next read fails again. This is the accepted "deliver again" direction, but the long-poll is lost too. Optional: return a distinct value on a read failure and skip the D11 pre-check in that case (deliver all, but still long-poll).
- **i4. Lost-wake window.** A PUT that commits between the route's pre-check (l.118-121) and the core Task's `:pg.join("user:<id>")` (`server.ex` ~l.5996) wakes nobody. That request then waits its full timeout (<= 25 s). The design property is the same as for room account data (test-review m1 notes the same). Not new.
- **i5. "Never raises" claim of `list_since/2`.** `Jason.decode!` at `account_data_store.ex` l.193 raises on a corrupt `content_json`. With positions, a corrupt row now gives a PERSISTENT 500 for every device-bound `/sync` of that user. Before, the flag was cleared by the `UPDATE ... RETURNING` before the raise, so it was one-off. `content_json` is only ever written via `Jason.encode!`, so this is theoretical. The `@doc` could say "never raises on a database error".
- **i6. `put/3` wakes after `Repo.transaction` returns.** That is post-commit only because `put/3` is never called inside an outer transaction (single caller, `protected.ex` l.1003). A future nested caller would wake before the outer commit (and could then hold the lock for long). Worth one `@doc` sentence ("must not be called inside a transaction").
- **i7. Dev concern 2.** `notify_sync/1` uses plain `send/2` to remote pids from the request process: the same exposure as the existing follow-up `bz`. Not new, not re-flagged.
- **i8. Story frontmatter** `docs/stories/oauth-broker/sync-token-per-device.md` l.7 still says `status: ready`. The Definition of Done checkboxes are unticked (the pipeline may update them at commit).
- **i9. Guard consistency.** `CrossSigningKeyStore.changed_since?/2` (l.315) lacks the `pos >= 0` guard that `list_since/2` / `pending_since?/2` have. Harmless.
- **i10. Binding flapping.** A bound raw JWT whose `DeviceBinding.lookup/1` returns nil on a DB hiccup is device-less for that one request. It reads the `''` row (fallback), consumes the device-less flags, and the next bound request falls back again. Covered by D2 / `cj` (c); only noting the flip cost.
- **i11. Advance before send.** `advance_positions` runs before `send_json`. A lost response leaves the positions advanced, but the client's retry carries the previous token, so it falls back and gets all rows again. "Deliver again" holds thanks to the one-token-per-device rule (`cj` (b)). Correct.
- **i12. Migration otherwise sound.** `IF NOT EXISTS` everywhere. The grant matches 000039 (`USAGE, SELECT` on the sequence to `nebu_app`). The sequence is not `OWNED BY` (shared by two tables, intentional). Down drops the index, then the columns, then the sequence, in dependency order. The migration test covers up/down on a fresh and a populated schema.
- **i13. Cluster-safety and ADR-018.** No `:pg.get_local_members` in `lib/` (only in the test helper `wait_polling`). The advisory lock is cluster-wide. SQL is inline in the stores. The router's reach into `Nebu.Matrix.Session.PgStore` is a pre-existing pattern (6 references at HEAD). Logging: one new line, the error kind only; no token, account data or chat content.
- **i14. GDPR.** The new columns live on rows that are already deleted with devices / sessions / erasure (`sync_tokens`), or on rows covered by the pre-existing gap `ck` (`account_data`, `cross_signing_keys`). Not re-flagged.
- **i15. Compile cleanliness.** No dead code: the old helpers `put_global_account_data/3` and `put_cross_signing_device_lists/3` are removed, and `list_all_and_clear` / `list_changed_and_clear` / `consume_changed_flag` are still used by the device-less clause. The optional callbacks plus the `function_exported?` facade keep the `@behaviour` fakes warning-free. The dev reports 1.19-alpine unit and 1.20 targeted runs green with `--warnings-as-errors` (not re-run here). The 21 full-suite failures are the known flaky families plus the AC20 fixture flake (`legacy_session!` without `S.session_expiry()`), which is unrelated to this diff; the suggested test fix is reasonable as a follow-up.

## Dev open concerns: assessment

1. Initial-shaped answer with a failed read: **MINOR m1.** The fix is safe because of the token guard.
2. `send/2` to remote pids: **INFO i7** (`bz`).
3. The lock held until the outer commit: **INFO i1.** No deadlock; the order is intended.
4. The extra pre-check statement: fine (it uses `account_data_user_pos_idx`, and the +3 is pinned).
5-7. Statement counts, security, closure date: agreed. The date needs adjusting only if the commit slips.
