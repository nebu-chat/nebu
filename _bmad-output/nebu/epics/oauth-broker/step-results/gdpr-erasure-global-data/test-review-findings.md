# Pre-dev test review: gdpr-erasure-global-data (follow-up `ck`, REQ-2026-005), 2026-10-27

Scope: staged tests (`git diff --cached -- server/test`): 7 new files `server/test/nebu/compliance/user_deletion_*` (+ support file), amended
`user_deletion_test.exs`, `sync_token_per_device_docs_test.exs`, `test_helper.exs`. Static review only (no docker, no mix). `python3 .oauth-ci/namelen.py`
is silent (names < 200). Story type bugfix, `ui: false`, `matrix: false`: no Playwright tests required, no GenServer state (no crash/restart test required;
the transaction rollback tests of Scenario 5 are the failure-recovery coverage).

Verdict: 3 MAJOR, 11 MINOR, 8 INFO. The suite is strong (real DB, structural lock-wait proofs instead of sleeps, 14 generated rollback tests, probe tables for the
guard, mutation run of 68 mutants). The MAJORs are coverage holes for decisions D11 and D13.

## Decision / scenario coverage matrix

| Item | Test(s) that fail without the implementation | Verdict |
|---|---|---|
| S1 global data, cross-signing, device keys (D1, D2) | global_data S1 (3 tests, incl. ghost device without `devices` row, B byte-identical) | OK |
| S2 other tables + profile (D2, D9) | global_data S2 (5 tests), `oauth_codes` describe (3) | OK |
| S3 nothing served, sessions dead | global_data S3 (3): keys/query shape equal to never-uploaded user, A token 401 | OK, see MINOR-8/9 |
| S4 second erasure no-op, D14 race loser | global_data S4 (2); race test deterministic via `FOR UPDATE` holder | OK (no unit pin of the unwrap, INFO-2) |
| S5 rollback (D4) | 14 generated fault tests + dispatcher variant + FakeRepo failing-statement tests | OK, see MINOR-3, MINOR-4 |
| S6 deactivation keeps data | global_data S6 | OK |
| S7 / D5 in-flight initial sync | concurrency (7 tests): rejected persist, in-progress, WAIT on `users` row, share lock, 2-statement count | OK |
| S8 / D3 guard | schema_guard (10) + probe tables | OK, see MINOR-6, MINOR-7 |
| S9 / D7 log law | log_test (4) | partial, see MINOR-5 |
| D1 advisory lock | concurrency D1 (+ FakeRepo order pin) | OK |
| D6 docs | docs_test (16) | OK, see MINOR-10, INFO-5, INFO-6 |
| D8 sweep | sweep_test (7, 3 DB) runs the SQL extracted from the docs | OK except D13 (MAJOR-2) |
| D10 late writes | late_writes (4) | OK, see INFO-4 |
| D11 `oauth_codes` policy (migration 000055) | row gone / not redeemable / rollback fault / "not widened" | MAJOR-1, MAJOR-3 |
| D12 legacy devices ended | global_data S3 "devices rows of LEGACY devices" | OK, positive path only (MINOR-2) |
| D13 sweep deletes `devices` of erased users | none | MAJOR-2 (known gap) |
| D14 | global_data S4 race test | OK |
| D15 (`:ok` for rejected persist, D10 done, allow-list in support, id `cn`) | concurrency + late_writes + schema_guard | `cn` not pinned (MINOR-10) |

## MAJOR

### MAJOR-1: no test for migration 000055 (D11: up adds the branch, down restores 000041, files exist as next free number)
D11 makes a migration IN scope and names its contract ("up adds a second DELETE policy branch ...; down restores the 000041 policy"). The repo convention is one
`server/test/nebu/migration/0000NN_*_test.exs` per migration (000041, 000044, 000045, 000046, 000054 ...: static file analysis + `:integration` introspection + a
down/up round trip on the privileged role inside a rolled-back transaction). None is staged; `grep 000055 server/test` is empty. Behaviour tests cover only the up
state. A missing or broken down (for example one that restores `USING (true)`), or a wrong file number, passes every staged test. The Definition of Done also demands
"the migration applies and reverts on a throwaway PostgreSQL".
Fix (ATDD fix pass): add `server/test/nebu/migration/000055_oauth_codes_erasure_delete_test.exs` (mirror of the 000041 test): both files exist and 000055 is unique;
`pg_policies` after up: `oauth_codes_delete` qual has the 24 h expiry branch and a `users` / `deletion_status IS NOT NULL` branch; after down: exactly the 000041 qual
(`expires_at < now() - interval '24 hours'`); down/up round trip in a rolled-back privileged transaction; no other policy / grant / trigger of `oauth_codes` changed (policy
only, as the release note claims). Assert catalog facts, not the exact SQL text.

### MAJOR-2: D13 (sweep also deletes `devices` of erased users) is not pinned (known gap, reported as requested)
`user_deletion_sweep_test.exs` asserts only `E.expected_erased()` for the erased user. `devices` is a teardown table: the active-user snapshot would catch an over-eager
`DELETE FROM devices` for ACTIVE or deactivated users (`E.snapshot/1` includes `devices`, `seed_user!` creates a `devices` row), but nothing fails if the sweep does not delete the
leftover legacy `devices` rows (display name, last seen IP) of erased users. `as_erased_before_the_fix!/1` does not simulate the state the old teardown left (a legacy `devices`
row with `display_name` / `last_seen_ip`).
Fix: seed the erased user a `devices` row with `display_name` and `last_seen_ip` (`DeviceKeyStore.upsert_device`, as in the S3 G2 test), assert precondition >= 1 and
`E.count("devices", erased.uid) == 0` after the sweep, for the deployment-note block and the runbook block; assert the active and the deactivated user's `devices` rows are
byte-identical (`E.fp("devices", ...)`, explicit). Keep `devices` OUT of `erased_tables/0` (it is a separate sweep statement). Do not pin the other teardown tables as swept
(D13), and do not assert them untouched either (FK cascades from `devices` legitimately remove `matrix_sessions`, `jwt_device_bindings`, `oauth_idp_refresh_leases` rows). The existing
"second run is a no-op" snapshot already includes `devices`.

### MAJOR-3: the "policy not widened" pin is order / data dependent and misses the realistic widening mutant (D11)
`the runtime role still cannot delete an ACTIVE user's unexpired code` seeds one active user B and attempts `DELETE FROM oauth_codes WHERE user_id = B`. It kills `USING (true)`.
It does NOT deterministically kill the most plausible wrong implementation of the new branch: an UNCORRELATED subquery
(`OR EXISTS (SELECT 1 FROM users WHERE deletion_status IS NOT NULL)`, i.e. forgetting `u.user_id = oauth_codes.user_id`). That policy deletes B's code as soon as ANY user in the
database is erased; the test passes on a fresh database and fails only if earlier tests left an erased user (reused DB, test order). Security relevance: authorization codes
(`idp_rt_enc`), reuse detection rows.
Fix: make the test self-contained: first erase a user A (guaranteeing an erased user exists), THEN assert the runtime role cannot delete B's unexpired code (`num_rows == 0`, row
still there) and B's USED-but-fresh code (the point of the 24 h rule). Add the positive mirror in the same test: a user with `deletion_status = 'deletion_in_progress'` (set via SQL, as the
erasure does before it deletes) CAN have its codes deleted, an active user's cannot.

## MINOR

### MINOR-1: stale hedges after D11 and D15
`user_deletion_global_data_test.exs`: the race test (`for t <- E.expected_erased() -- ["oauth_codes"]`) and the S5 retry loop (same exclusion, "after the retry A has rows in") still
exclude `oauth_codes` ("needs the policy of gap G1"). With D11 decided the exclusion hides a regression where the retry / race winner leaves a code. Remove it. Also stale: describe name
"gap G1" / test name "gap G2", the moduledoc of `user_deletion_late_writes_test.exs` ("THIS FILE IS CONDITIONAL ... delete this file"; D15: D10 is DONE), the comment "oauth_codes needs the
policy of gap G1" above the S5 fault list.

### MINOR-2: D12 pinned on the positive path only
The legacy `devices` test proves the row is gone. It does not prove the new step is "best effort, guarded like the rest" (D12): no test forces `end_all_user_devices/1` to fail
(`E.block!("devices", "DELETE", uid)` exists) and asserts that the dispatcher still answers `keys_deleted`, the other sessions are still ended and the warning carries no personal data.
A mutant that removes the `guarded` wrapper (a raise after the COMMIT turns a committed erasure into a 500) survives. The OAuth-device path of the teardown is covered only by the old
`oauth_logout_test.exs` (fine, state it in the dev report).

### MINOR-3: the failing-statement FakeRepo tests over-claim ("runs nothing after it")
`ck: a failing statement (...)` asserts `{:error, :simulated_db_error}`, one attempted audit, and that no `UPDATE users ... keys_deleted` ran. The title promises "runs nothing after it",
but statements after the failing one (further DELETEs, the profile UPDATE) are not asserted absent. Assert the failing statement is the LAST recorded statement, or drop the claim.

### MINOR-4: unit sequence pins tighter than the contract (check 3)
The FakeRepo pins require each inventory DELETE to start with `DELETE FROM <t>` (`\A` anchor) and `args == [user]` exactly, the lock as a separate `SELECT pg_advisory_xact_lock`
statement (failing-statement regex `\ASELECT pg_advisory_xact_lock`), the flip as an `UPDATE users` containing `keys_deleted`, the anonymisation as `UPDATE profiles ... avatar_url ... Deleted User`.
Legitimate alternatives blocked: one `WITH d AS (DELETE ...)` statement, `DELETE ... WHERE user_id = ANY($1)`, `DELETE ... USING`, a CTE lock. The real-DB suite already proves behaviour; either
relax to "every table of `erased_tables/0` appears in a DELETE FROM statement before the flip, parameterised by the target user" or keep it as the deliberate re-pin the story test list asks for.

### MINOR-5: log law coverage (check 4) has three blind spots
(a) The post-commit teardown FAILURE path (`guarded/2` warnings, the OAuth `inspect(reason)` warning) is never run with canaries: the forced failures of `log_test` are pre-commit. Force a teardown
failure (BEFORE DELETE trigger on `devices` / `matrix_sessions`) with display name / IP / token canaries (also covers D12's new step). (b) The seeded world has no `devices.display_name` /
`last_seen_ip`, so D12's step cannot leak them into a test-visible log. (c) The D10 refusal and the D5 rejected persist are log-checked only for the room id (D5) and not at all (D10).

### MINOR-6: guard heuristics miss column shapes the story names (check 6)
Discovery: `user_id`, `*_user_id`, `sender inviter_id invitee_id granted_by started_by actor_id owner`, FKs to `users`. D2's scan method also lists `actor_*` and `requester_*`; `created_by`, `author(_id)`,
`owner_id`, `recipient`, `requested_by`, `approved_by`, `target_id` are not caught. Most tables in this schema do NOT use an FK to `users`, so a new table with `created_by text` passes silently, the
recurrence the guard exists to prevent. The probes cover 4 shapes only (`user_id`, `reporter_user_id`, `sender`, FK). Fix: broaden to `%_by`, `actor%`, `requester%`, `approver%`, `author%`, `owner%`,
`recipient%`, with an explicit per-table ignore list if a false positive appears; add probes for `granted_by` and `created_by`. The guard otherwise does fail for a new personal table: probe test
asserts `found == Enum.sort([p1..p4])` and the real-schema test runs the same `unclassified/2` over the same discovery.

### MINOR-7: "ended by the teardown" classification is not proven for 3 of 7 tables
`teardown_tables/0` lets an author silence the guard by listing a new table there. The dispatcher test asserts `count == 0` for every teardown table but only asserts the PRECONDITION (`>= 1`) for
`devices sessions sync_tokens matrix_sessions`. `jwt_device_bindings`, `oauth_idp_refresh_leases`, `sync_room_cursors` are vacuous zero checks, and a newly listed table would be too. Add a precondition for
each teardown table (seed it, or document the cascade source) so an unseeded entry fails like `expected_erased` does via `seed_user!`.

### MINOR-8: S3 "no global account data of A reaches any client" is near-vacuous; Matrix status set too loose
`for {name, secret} <- a.secrets, do: refute(sync.resp_body =~ secret)` is on B's `/sync`; B never had A's data, so it holds before the erasure too and no implementation mutation fails it
(the dead tokens and the `/keys/query` shape are the real assertions). `other.status in [401, 403, 404]` for B reading A's `m.direct`: the spec answer is 403 `M_FORBIDDEN`; the set cannot fail for a
regression between the three.

### MINOR-9: Matrix error codes (`errcode`) and `/profile` not asserted
Dead tokens: `T.whoami(a_session.at).status == 401` without `errcode == "M_UNKNOWN_TOKEN"`. No `GET /_matrix/client/v3/profile/{userId}` for the erased user: the story says "/profile of an erased user
shows Deleted User", only the DB row is checked, so a handler / cache that bypasses `profiles` is untested. Add one such request from B (200, `displayname == "Deleted User"`, no `avatar_url`).

### MINOR-10: docs pins weaker or looser than the decisions (check 7)
(a) D11: the release-note test accepts `no migration|migration 0000\d\d`; pin `migration 000055` and "policy". (b) D15 fixes the follow-up id `cn`; the docs test accepts any unique id named in the id line, so a
reserved id (bv, bw, bm, bn, bo) passes. Pin the `| cn | ` row and `cn` in the id line. (c) `new_row()` selects by `DELETE /api/v1/admin/users/{userId}` + story and excludes only `| ck |`: a `cj` note
naming the path breaks it confusingly; exclude `cj` too or match the id. (d) `refute id_line =~ ~r/unused:[^.]*`#{id}`[^.]*`gm` onward/` is vacuous (no id sits before `gm` in the unused segment and
`[^.]*` cannot cross the period); the invariant that matters, `unused:[^.]*`gm` onward` intact plus the reserved list and "`cj`, `ck`, `cl` and `cm`", is separately and correctly asserted, so the eight
existing suites stay compatible. (e) the sweep-mentioned regex (`sweep|already erased|erased before`) is satisfied by almost any text.

### MINOR-11: sweep test names a case it does not test
`a user in the middle of an erasure or a deactivated user is not swept: only deletion_status = keys_deleted` seeds only a DEACTIVATED user. Add a `deletion_status = 'deletion_in_progress'` user (set via SQL)
or rename the test.

## INFO

- INFO-1 (positive): no hard wait as an assertion; the single `Process.sleep(20)` is the poll step of `await_blocked!/4` with a 10 s deadline and the structural `pg_blocking_pids` check. Pool size 10 (runtime.exs)
  covers the worst test (holder, two erasure tasks, probe connection). `async: false` on every module that touches the real `AuditWriter`, `Logger.configure/1`, trigger / probe DDL or committed rows;
  `user_deletion_docs_test.exs` is `async: true` and only reads pure lists. The support moduledoc contains the text `async: false` that `AuditWriterSeamRaceRegressionTest` scans for.
- INFO-2: D14 (race loser) is pinned only by the real-DB race test (integration job); a unit pin is impossible with the existing fakes (they roll back on `{:error, _}` and hide `{:ok, {:error, _}}`).
  The test is deterministic (two erasures queued behind a `FOR UPDATE` of the `users` row) and also works for an implementation that moves the guard into the transaction.
- INFO-3: the fault trigger raises a FIXED message, so log / audit tests cannot detect an implementation that stores `inspect(error_reason)` of a Postgres error whose DETAIL carries row data
  (existing `error: inspect(error_reason)` in `user_deletion.ex`, allowed by D7 "beyond what the existing code emits"). Ecto query logging is `log: false` in `runtime.exs`; if that changes, the debug-level log
  test would catch parameters for the seeded canaries.
- INFO-4: D10 pins `{:error, _}` without a reason; the HTTP mapping of that error in `protected.ex` for an in-flight request of an erased user is untested (tokens are dead for new requests). Note for the dev:
  the handler must not log content.
- INFO-5: neither the inventory section nor the release note is pinned to state D12 (legacy `devices` rows removed by the teardown). Optional pin: the `devices` line contains "legacy".
- INFO-6: `sync_token_per_device_docs_test.exs` amendment is a deliberate minimal old -> new change; `status(id) =~ "closed"` is a substring match and the test title still says "its status is open". Cosmetic.
- INFO-7: guard residuals: probe tests create real committed tables (privileged) and drop them in `on_exit`: a crash in between leaves a table that fails the real-schema test until dropped. Partition children
  (relkind `r`) would appear as separate unclassified tables if a per-user table is ever partitioned (none today). The static `DELETE FROM` literal scan of `user_deletion.ex` is vacuous for the interpolated form
  `DELETE FROM #{table}` (regex needs `[a-z_]+` after FROM); it only catches extra hard-coded literals, the FakeRepo "nothing outside the inventory" test covers 9 named retained tables only.
- INFO-8: the exact `[2, 2, 2]` statement count follows D5 (guard in the same statement, measured on HEAD); a design with a separate `SELECT ... FOR SHARE` fails it by design. The sweep contract (fenced
  ```sql block, plain `;` statements, no DO block) is a documented test-driven constraint; the sweep runs as the privileged role, so whether the 000055 branch is exercised depends on that role being subject to
  FORCE RLS (not asserted).

## Checked and fine

- Names < 200 chars; no tautologies found: every absence check has a precondition (`>= 1`, `== 6`, `== 2`); `fp/3` md5 over whole rows proves B byte-identical.
- S5: every table the transaction deletes plus the profile UPDATE is a generated fault test proving rollback of EARLIER steps, the attempted audit row and a successful retry.
- D1 lock waits (structural), D5 share lock and wait on the `users` row, D8 sweep SQL extracted from the docs and executed (doc / code drift impossible), active and deactivated users byte-identical.
- UI / Matrix / GenServer rules: `ui: false` (no Playwright), no GenServer state (no crash/restart test), Matrix codes: see MINOR-8 / MINOR-9.
