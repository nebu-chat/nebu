---
story_id: revoke-lock-bounds
title: "Bound the lock waits that a long client revocation imposes on refresh and /sync (epic SEC gate 3, G3-1)"
type: bugfix
severity: medium
epic: oauth-broker
status: done
security_review: required
matrix: false
ui: false
created: 2026-10-13
branch: feature/migrate-to-oauth2
---

## Summary

Epic SEC gate 3 (docs/stories/oauth-broker/security-reports/epic-oauth-broker-security-review-gate3-2026-10-13.md, finding G3-1, MEDIUM): `Nebu.OAuth.revoke_client/3` (story oauth-client-revocation) holds the client row and every torn-down `devices` row (`FOR UPDATE`, then `DELETE`) until commit, for up to 120 s. The story bounded the waiters it knew (`lock_client!` in issuance and rotation: `SET LOCAL lock_timeout = '2s'` -> 503 + Retry-After) but two other request paths wait on the same `devices` rows WITHOUT a bound, each holding a pool connection (pool size 10):

1. **IdP refresh lease claim (`per_refresh`, the DEFAULT).** A refresh first runs the lease claim (`Nebu.Matrix.OAuthSession` ~216 before `lock_client!`; `OAuthSessionStore` `@sql_claim_lease` ~778-800): an INSERT into `oauth_idp_refresh_leases` whose FK check takes KEY SHARE on the `devices` row and therefore waits for the revoke, before the 2 s bound of `lock_client!` is ever reached. (Leases are DELETEd after every refresh, so every refresh INSERTs.)
2. **`/sync` -> `DeviceKeyStore.touch_last_seen`** (~286-301) UPDATEs the same `devices` rows (once per minute per device); it waits up to Ecto's 15 s query timeout.

Revoking a client that holds many devices (Element Web can be ONE client holding most devices, because identical metadata dedups to one client_id) can therefore take every pool connection and brown out the whole node. The 07-deployment / ADR runbook sentence "token and refresh requests of that client answer 503 + Retry-After after 2 s" is untrue for `per_refresh`.

## Decisions

- D1 **Bound the lease claim**: the claim runs in a short transaction with `SET LOCAL lock_timeout = '300ms'` (review cycle 1, Kassandra L-1: an uncontended claim takes milliseconds, a short bound keeps the pool connection hold of each waiter small; the same 300 ms now bounds `lock_client!`); a lock timeout maps to `{:unavailable, 5}` (503 `{}` + `Retry-After: 5`, no `error` member, never 429/`invalid_grant`; a short retry would keep the pool busy). No transaction or pool connection may be held across the IdP HTTP call (unchanged). The lease release has the same bound (it can add at most 300 ms to a refresh response).
- D2 **Make `touch_last_seen` non-blocking**: the UPDATE skips rows that are locked (`FOR NO KEY UPDATE SKIP LOCKED`, the strength of the UPDATE itself, so a lease claim's KEY SHARE does not make it skip, L-3); a skipped update is harmless (best effort, once a minute) and must not raise.
- D3 **Audit the other request-path statements that touch `devices` rows** without a lock bound (device upsert at login, key upload / `device_keys` writes, to-device or OTK paths, account page device list, `matrix_sessions` writers that FK-reference devices): list them in the Dev Agent Record; bound those on frequent per-request paths with the same `lock_timeout` idiom or SKIP LOCKED where the write is best effort; record the rest as accepted with the reason. Do NOT add a role-level `ALTER ROLE ... SET lock_timeout` (it would also bound legitimate long waits such as advisory locks and teardown).
- D4 **Runbook correction**: 07-deployment ("Revoking a client") and ADR-033 CR11 state precisely what is bounded (issuance, rotation, lease claim and release, request-path teardowns: bounded per request -> 503; `/sync` last-seen update skipped; overall load stays proportional to the client's active devices) and that a very large revoke still holds the rows for its duration; keep the follow-up bb (two-phase revoke) as the full fix.
- D5 No migration, no new config key.
- D6 **Bound the request-path teardowns (review cycle 1, Kassandra M-1)**: `OAuthSessionStore.end_session_for_token/1` (`/oauth2/revoke`, unauthenticated, the same token may be sent repeatedly) and `end_device/4` (`/logout`, `/logout/all`, account page, rpc revoke-all) take the devices-row lock with `lock_device_bounded!` (`SET LOCAL lock_timeout = '300ms'`); a timeout rolls back as `{:error, :lock_timeout}` and the facades answer unavailable (`/oauth2/revoke`: 503 `{}` + `Retry-After: 5`, `/logout`: the existing 500). `end_device/4` takes `bounded?` (default `true`); the client revoke's OWN teardown (`end_each/2` -> `end_client_devices/2`) passes `bounded?: false`: it must lock, it holds the rows by design. The legacy `/logout` keeps its 2 s (story legacy-logout-per-device LL3).
- D7 **Best effort on hot paths (L-2)**: `MatrixSessionStore.mark_access_token_used/1` (per request when a rotation is pending) uses `FOR UPDATE SKIP LOCKED` on the sibling rows and tolerates a failing statement (no `{:ok, _} =` match); a skipped sibling stays pending until the next request.

## Acceptance Criteria

1. With a revoke in flight (a test seam/hook holding the devices rows, e.g. `:oauth_client_revoke_hook`), a `refresh_token` grant under `oauth_idp_revalidation = per_refresh` answers `503 {}` + `Retry-After: 5` within the 300 ms lock bound (deterministic: poll `pg_stat_activity` for the waiter instead of sleeping), consumes nothing (the refresh token stays valid), and the lease row is not left behind; after the revoke commits the same refresh answers the normal `invalid_grant`/401 for a revoked client.
2. With the same revoke in flight, `touch_last_seen` returns immediately without raising and without updating the locked rows; `/sync` of such a device completes within its normal time (no 15 s wait).
3. Pool health: with the revoke in flight, N (> pool size) parallel per_refresh refreshes and /sync requests of that client's devices do not exhaust the pool: an unrelated request (e.g. `/versions` or `/whoami` of another user) still answers within its normal time, and all connections are returned after the revoke commits.
4. `off` revalidation mode and a client without devices behave as before (regression).
5. The existing revocation, lease, refresh and logout test suites stay green; the lease behaviours of story oauth-authorize-freshness (holder, TTL 60 s, follower 503, release on every path) are unchanged.
6. D3 audit is documented in the Dev Agent Record (table: statement, file, path, bounded or accepted + reason) and every bounded statement has a test or a static guard.
7. Docs: 07-deployment "Revoking a client" and ADR-033 CR11 are corrected per D4; follow-ups: new row (next free id; check the file) recording the audit result; the epic gate-3 report row G3-1 is marked closed in follow-ups/07-deployment status text (do not edit the security report file).

8. (M-1) With the revoke in flight, N (> pool size) parallel `/oauth2/revoke`, `/logout` and `/logout/all` calls of that client's devices end bounded (`/oauth2/revoke`: 503 `{}` + `Retry-After: 5`, the others 500/503), an unrelated request still answers, and the revoke's own teardown completes unbounded. (L-2) `mark_access_token_used/1` skips locked siblings. (L-3) `touch_last_seen/3` does not skip a row that only holds a KEY SHARE.

## Manual verification

Load rehearsal with a client holding thousands of devices on the reference stack: revoke while refreshes and /sync run; observe 503s on refresh, no pool exhaustion, node stays responsive.

## Dev Notes

- Files: `server/lib/nebu/matrix/oauth_session.ex` (lease claim before `lock_client!`), `server/lib/nebu/matrix/session/oauth_session_store.ex` (`@sql_claim_lease`, lock helpers, `lock_client!` idiom with `SET LOCAL lock_timeout`), `server/lib/nebu/matrix/device_key_store.ex` or wherever `touch_last_seen` lives, `server/lib/nebu/oauth/client_store.ex` (revoke, hooks), tests: `server/test/nebu/oauth/oauth_client_revocation_race_test.exs` (hook-based deterministic pattern with `pg_stat_activity` polling and `pg_stat_clear_snapshot()`), `oauth_refresh_lease_test.exs`.
- Keep test names < 200 chars (CI runs elixir 1.19).

## Tasks

- [x] D1: bound the lease claim (`claim_lease/4` short transaction, `SET LOCAL lock_timeout = '300ms'`, `{:error, :lock_timeout}`; `acquire_lease` maps it to `{:unavailable, 5}`)
- [x] D1/D3: bound the lease release the same way (a revoke cascade-deletes the lease row)
- [x] D2: `touch_last_seen/3` skips locked rows (`FOR UPDATE SKIP LOCKED`)
- [x] D3: audit of the other `devices` writers, table in the Dev Agent Record
- [x] D4/AC7: 07-deployment, ADR-033 CR11, follow-ups (bx, G3-1 closed)
- [x] Review cycle 1: M-1 (D6), L-1 (300 ms, Retry-After 5), L-2 (D7), L-3, code review MINOR 1-3 and INFO 4/6-9

## Dev Agent Record

### Implementation plan

- `OAuthSessionStore.claim_lease/4` and `release_lease/3` run in a short `repo.transaction` whose first statement is `SET LOCAL lock_timeout = '300ms'` (module attribute `@lease_lock_timeout`; the setting dies with the transaction, no reset is needed on rollback). `lock_not_available` -> `repo.rollback(:lock_timeout)` -> `{:error, :lock_timeout}`; a failed FK check (`:no_device`) rolls the aborted transaction back and is returned as before. No IdP call and no connection is held across the IdP leg: the claim transaction is over before `run_as_holder` starts.
- `OAuthSession.acquire_lease/7`: new clause `{:error, :lock_timeout}` -> one WARNING (static text, user and device id as metadata, no secret) and `{:error, {:unavailable, 5}}` (503 `{}` + `Retry-After: 5`), like the other storage failures.
- `DeviceKeyStore.touch_last_seen/3`: the UPDATE selects its target in `WHERE (user_id, device_id) IN (SELECT ... FROM devices WHERE <key and throttle> FOR NO KEY UPDATE SKIP LOCKED)`; a locked row is skipped, the function still returns `:ok` and never raises. The throttle predicate sits inside the subquery, so an unlocked, recently-seen row is not locked at all.
- No migration (D5), no config key, no role-level `lock_timeout` (static test scans every migration).

### D3 audit: statements that lock or wait on `devices` rows (and rows cascading from them) on request paths

Only the revoke (and the other teardowns) hold `devices` rows `FOR UPDATE`/DELETE for long; waiters are statements that need a CONFLICTING lock: row-modifying statements on `devices`, `FOR UPDATE` selects, and INSERTs into child tables with an FK to `devices` (today only `oauth_idp_refresh_leases`; `matrix_sessions`, `device_keys`, `device_one_time_keys`, `device_fallback_keys` have NO FK to `devices`). Plain `SELECT`s never wait (MVCC). Rows the teardown deletes in the child tables are locked only from the moment the revoke reaches them.

| Statement | File | Path (frequency) | Decision |
|---|---|---|---|
| `INSERT INTO oauth_idp_refresh_leases ... ON CONFLICT` (`claim_lease`; FK check = KEY SHARE on `devices`) | `matrix/session/oauth_session_store.ex` | every `per_refresh` refresh (frequent) | BOUNDED: `SET LOCAL lock_timeout = '300ms'`, `{:error, :lock_timeout}` -> 503 + `Retry-After: 5`; tests AC1 + static D1 |
| `DELETE FROM oauth_idp_refresh_leases WHERE holder` (`release_lease`; the revoke cascade-deletes the lease row) | same | end of every `per_refresh` refresh, only blocks for a refresh that was in flight when the revoke started | BOUNDED (same idiom; the lease row goes with the device or expires by TTL); test "release_lease" + static D3 |
| `UPDATE devices SET last_seen_ts ...` (`touch_last_seen`) | `matrix/device_key_store.ex` | `/sync` etc., once a minute per device (frequent) | BOUNDED: `FOR NO KEY UPDATE SKIP LOCKED`, skipped; tests AC2 + static D2/L-3 |
| `INSERT INTO devices ... ON CONFLICT DO UPDATE` (`upsert_device` via `insert_replacing_device`) | `matrix/device_key_store.ex`, `oauth_session_store.ex` | OAuth token issuance (once per login) | ACCEPTED: runs after `lock_client!`, whose `FOR SHARE` on the client row already waits at most 300 ms behind the revoke (503); the revoke holds the client row from its first statement, so issuance never reaches the device lock of a client being revoked. A same-user same-device long transaction is a rare, short logout. |
| `SELECT 1 FROM devices ... FOR UPDATE` in `lock_client_and_device_of` (OAuth rotation) | `oauth_session_store.ex` | every OAuth refresh rotation | ACCEPTED: `lock_client!` (300 ms bound) comes first in the same transaction, same argument as issuance |
| `INSERT INTO devices ... ON CONFLICT` (`register_device`, legacy `POST /login`) | `matrix/http_public.ex` -> `device_key_store.ex` | legacy login (IdP flow, rate limited) | ACCEPTED: a legacy login creates a new device id or re-logs one of the user's legacy devices; the revoke set is `matrix_sessions.client_id = <client>` (OAuth rows), a collision needs the user to pick an OAuth device id on the legacy API |
| `SELECT 1 FROM devices ... FOR UPDATE` in legacy `rotate_tokens/1` | `matrix/session/matrix_session_store.ex` | legacy `/refresh` | ACCEPTED: legacy sessions carry no `client_id`, their devices are never in a revoke's set |
| `put_device_keys` -> `upsert_device` + `INSERT INTO device_keys ... ON CONFLICT` | `device_key_store.ex`, `web/router/protected.ex` (`/keys/upload` with `device_keys`, cross-signing) | once per device at key setup (rare) | ACCEPTED: rare per device; the session of that device is being torn down anyway; a wait ends with the revoke's commit (error, the client retries). Revisit with the load rehearsal (follow-up bx). |
| `INSERT INTO device_one_time_keys` / `device_fallback_keys ... ON CONFLICT` | `device_key_store.ex` | `/keys/upload` OTK top-up | ACCEPTED: new key ids do not conflict with rows the revoke deleted or locks; no OTK claim statement exists (`/keys/claim` unrouted), so no UPDATE/DELETE of those rows by a request |
| `UPDATE devices SET display_name` (`rename_device`) | `device_key_store.ex` | `PUT /devices/{id}` (user), admin rename | ACCEPTED: user/admin initiated, rare, one row |
| `DELETE FROM devices/device_keys/...` (`delete_device`, `delete_device!`) | `device_key_store.ex` | `DELETE /devices/{id}`, account page, admin | ACCEPTED: rare, user/admin initiated, own teardown semantics (the locks they take are bounded since review cycle 1, see the `lock_device_bounded!` row) |
| `lock_device` / `lock_device_bounded!` (`SELECT 1 FROM devices ... FOR UPDATE`) in `end_session_for_token` and `end_device` | `oauth_session_store.ex` | `/oauth2/revoke` (unauthenticated, repeatable), OAuth `/logout`, `/logout/all`, account sign-out, rpc revoke-all | BOUNDED in review cycle 1 (D6, Kassandra M-1): 300 ms `lock_timeout`, `{:error, :lock_timeout}` -> 503 / 500; the revoke's own teardown (`bounded?: false`) stays unbounded; test "M-1" |
| `UPDATE matrix_sessions SET grace_until ... WHERE ... IN (SELECT ... FOR UPDATE)` (`mark_access_token_used`) | `matrix_session_store.ex` | per request while a rotation is pending (hot) | BOUNDED in review cycle 1 (D7, L-2): `FOR UPDATE SKIP LOCKED` + failure tolerated; a row a revoke deleted stays locked until its commit |
| other `matrix_sessions` writers (insert, soft-revoke in rotation, delete) | `matrix_session_store.ex`, `oauth_session_store.ex` | login, refresh, logout | ACCEPTED: no FK to `devices`; they take the client lock (300 ms) and the devices lock first (`lock_client!` -> `lock_client_and_device_of`, bounded by the client lock behind a revoke); rows a revoke deleted stay locked until its commit, which only a request that already passed both locks can reach (same user and device, rare) |
| `INSERT INTO devices ... ON CONFLICT` (`upsert_device`) of ANOTHER client of the same user for the SAME device id | `oauth_session_store.ex` | OAuth issuance | ACCEPTED (code review INFO 4): the issuing client's own `lock_client!` passes (it is not the revoked client), then the upsert waits on the device row the revoke holds; needs the same user to pick the same device id with two clients; note in follow-up bx |
| `SELECT ... FROM devices` (`list_devices`, `get_device`, `query_devices` join, `account_management`, `device_binding` NOT EXISTS, `/sync` reads, account page device list) | `device_key_store.ex`, `account_management.ex`, `session/device_binding.ex`, `oauth_session_store.ex` | many | NOT APPLICABLE: plain reads do not block on row locks |

### Test adjustments (staged tests)

- `oauth_revoke_lock_bounds_test.exs`, AC1 first test: `T.rows_snapshot` and `T.lease_rows` were read AFTER `with_revoke_hold/2` returned, i.e. after the revoke had committed and torn the sessions down (the snapshot was therefore always empty: "nothing is consumed" could not hold). They are now read inside the hold, right after the 503, while the rows are still locked.
- Added (the audit found one more bounded statement): test "release_lease/3 behind a held lease row ..." (AC1/AC6) and static test "D3: release_lease/3 also runs under a transaction-local lock_timeout".

### Review cycle 1 (Kassandra M-1, L-1..L-3; code review MINOR 1-3, INFO)

- **M-1 / D6**: `end_session_for_token/1` and `end_device/4` lock with `lock_device_bounded!(..., @request_device_lock_timeout)` (300 ms). `end_device/4` has `opts[:bounded?]` (default `true`); `end_each/2` (the client revoke's own teardown) passes `bounded?: false`. The `@request_device_lock_timeout` attribute must be defined before its first use in the module (a first version defined it below the callers: nil -> `SET LOCAL lock_timeout = ''` -> ConnectionError, caught by the new test). Tests: "M-1" (12 parallel revoke / logout / logout-all calls behind a held revoke, `/oauth2/revoke` 503 `{}` + `Retry-After: 5`, the others 500/503, unrelated `/whoami` 200, pool whole afterwards, the revoke completes; `/logout/all` also wipes the user's session rows before failing on the device lock, so the revoke counts 9..12 devices) and `end_device/4` returning `{:error, :lock_timeout}`; static D6.
- **Existing tests adjusted (D6 side effect)**: eight tests of `oauth_session_store_test.exs`, `oauth_device_teardown_test.exs`, `oauth_revoke_semantics_test.exs`, `oauth_logout_test.exs` and `oauth_account_test.exs` held the devices row for 500 ms (`Task.yield(task, 500) == nil`) to prove "the teardown waits for the lock"; with the 300 ms bound the teardown now (correctly) gives up in that window. They now wait deterministically for the waiter (`T.await_lock_wait!/1`, polls `pg_stat_activity`, new in `oauth_test_support.exs`) and assert it has not finished, then proceed within the bound. The teardown bound is 300 ms (not the 2 s Kassandra named for M-1) because 12 waiters of 2 s would saturate the pool of 10 for seconds, the very effect the story removes; the legacy `/logout` keeps its 2 s (LL3, pinned by its own test).
- **L-1**: `@client_lock_timeout`, `@lease_lock_timeout` 300 ms; `{:error, :lock_timeout}` of the claim -> `{:unavailable, 5}`. Staged expectations adapted (Retry-After 5, names/comments). The docs now say "bounded per request; the overall load is proportional to the client's active devices; the full fix is bb" instead of "cannot exhaust the pool". `release_lease` can add at most the 300 ms bound to a refresh response (INFO 6).
- **L-2 / D7**: `mark_access_token_used/1` `FOR UPDATE SKIP LOCKED`, result no longer matched. Test: locked pending sibling => `:ok` at once, the sibling stays pending, expired by the next call once free.
- **L-3**: `touch_last_seen/3` `FOR NO KEY UPDATE SKIP LOCKED`; test with a held `FOR KEY SHARE` (the lease claim's FK lock): the row is still updated.
- **Code review**: MINOR 1 audit rows corrected (see the table); MINOR 2 the D5 static guard no longer hard-codes a migration number (it checks that no migration names this story; D3 still scans for role-level `lock_timeout`); MINOR 3 the D1 slice ends at release_lease's `@doc`; INFO 4 noted in the audit and follow-up bx; INFO 6 documented above; INFO 7-9 stale names and comments fixed (moduledoc contract, the "hold on nothing" name, "before/after the fix" comments).

### Completion notes

All acceptance criteria are covered by the staged integration tests (AC1-AC4), the existing suites (AC5) and the static tests (AC6, AC7). Follow-up id used: `bx` (`by` onward are unused). Manual verification (load rehearsal with thousands of devices) is listed in the story and in 07-deployment.

### File List

- `server/lib/nebu/matrix/session/oauth_session_store.ex` (claim_lease, release_lease)
- `server/lib/nebu/matrix/oauth_session.ex` (acquire_lease clause, moduledoc)
- `server/lib/nebu/matrix/device_key_store.ex` (touch_last_seen)
- `server/lib/nebu/matrix/session/matrix_session_store.ex` (mark_access_token_used)
- `server/test/nebu/oauth/oauth_revoke_lock_bounds_test.exs`, `server/test/nebu/oauth/oauth_revoke_lock_bounds_static_test.exs`
- `docs/architecture/07-deployment.md`, `docs/architecture/adr/ADR-033-authorization-server-broker-model.md`, `docs/stories/oauth-broker/follow-ups.md`
- `docs/stories/oauth-broker/revoke-lock-bounds.md`

### Change Log

- 2026-10-13: bounded lease claim and release, non-blocking last-seen update, D3 audit, docs (follow-up bx).
- 2026-10-13 (review cycle 1): lease/client lock bound 300 ms and `Retry-After: 5` (L-1); request-path teardowns bounded, the revoke's own teardown stays unbounded via `bounded?` (M-1, D6); `mark_access_token_used` skips locked rows (L-2, D7); `touch_last_seen` `FOR NO KEY UPDATE` (L-3); D3 audit corrected; docs reworded; tests and static guards adapted.
