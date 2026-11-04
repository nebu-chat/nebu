# ATDD report: to-device-messaging (epic e2ee-client-support, REQ-2026-012)

Step `atdd`. Branch `feature/e2ee-client-support`, worktree `open-chat-e2ee`. Nothing committed. Only tests, test support, the story `## Decisions` addendum and step results remain; the throwaway reference
implementation (lib, migration 000059, config cron entry, docs 04/05/07/08/11-risks, ADR-011, CHANGELOG, GDPR runbook) is `reference-impl.diff` (applies with `git apply`, was reverted completely).

## Result

| | count |
|---|---|
| new tests (12 new files + 1 support file; see the fix pass below for the final numbers) | 296 |
| red without implementation (fresh DB without migration 000059) | 287 (the other 9 are regression guards) |
| green with the reference | 296 / 296 |
| changed existing files | `unrecognized_routes_test.exs` (clause inventory + 405 table, 3 red), `member_prev_content_http_test.exs` and `history_visibility_http_test.exs` (DELIBERATE statement-count re-pins, 1 red each), `user_deletion_oauth_test_support.exs` (inventory + seed, makes ~85 shared erasure tests red), `test_helper.exs` |
| no-DB job `.e2ee-ci/unit_nodb.sh` (warnings as errors) with the reference | 6854 / 6855, only `release_test` contiguity (56/57 live on another branch: expected). Red without the reference: routes 17, docs 30, gate 10, migration static 16 |
| wide integration run with the reference (matrix, web, migration, compliance, oauth, admin) | all green except the known environmental families (TemporaryCapture, LogStore Retention, RoomsFallbackName, WarRoom, TraceMapNodeControls, AdminStaleRooms, RegressionSyncLoad: fail identically on the clean tree) and `release_test`; `RoomKeysBudget` default cap and `AdminOidcLogin` failed only inside the long run (token expiry / shared state), pass alone on the clean tree |
| mutation | 195 mutants, 190 killed, 5 survived, all equivalent (`mutation-results.txt`) |

## Files

`server/test/nebu/matrix/`: `to_device_send_http_test.exs` (55), `to_device_sync_http_test.exs` (32), `to_device_limits_http_test.exs` (45), `to_device_routes_test.exs` (20, no DB), `to_device_purge_test.exs` (22),
`to_device_concurrency_test.exs` (16), `to_device_logging_test.exs` (7), `to_device_send_gate_test.exs` (10, no DB), `to_device_docs_test.exs` (34, no DB), `to_device_oauth_test_support.exs` (suffix required by
`test_ignore_filters`, registered in `test_helper.exs`); `server/test/nebu/migration/000059_to_device_messages_test.exs` (17); `server/test/nebu/compliance/user_deletion_to_device_test.exs` (10).
No Playwright / Element e2e (the verification flow needs Dex, Element Web and two devices); the API level runs through the full `Nebu.Web.Router` with real sessions and rooms.

## Scenario -> test

| Gherkin scenario | tests |
|---|---|
| 1 specific device | send "Scenario 1" (10) + sync incremental |
| 2 `*` fan-out | send "Scenario 2" (7), limits (entries, fan-out) |
| 3 ack on the covering token | sync "Scenario 3" (14: retry, chain, initial, foreign / forged / garbage tokens, late commit via deferred trigger) |
| 4 unknown / unreachable recipient | send "Scenario 4" (4: byte-identical answers for 14 skipped shapes) + recipient restriction (11) |
| 5 device deletion | purge "Scenario 5" (12: DELETE /devices, delete_devices, logout, logout-all, admin revoke, OAuth logout, deactivation, re-created id, IDOR) |

Oracle behaviours 1-20: 1-3, 5-7, 19, 20 send; 4 oracle test; 8-12 sync; 13 limits; 14 + 18 routes / send / logging; 15 limits (rate limit); 16 purge; 17 purge (TTL).

## Lessons of the sibling story, where pinned

* Aggregate for every per-item cap: device / user / sender-share / fan-out targets / fan-out bytes / txn records / sync response (limits, sync); exact byte boundaries with the 128-byte row cost.
* Auth before body, rate limit before parse, 429 before parse, junk bearer = 401 with `body_params` unfetched, encoded segment spellings (routes, limits).
* Rate limit is not a concurrency limit: send slots 4 / user, 32 / node (`ToDeviceSendGate`, monitor based, killed request frees slots, 429 before the body), set-based statement counts, 100 targets and 1 MiB of rows per request, wake-up of the target device only (gate test, concurrency, sync).
* No waiting locks: held txn record answers 429 < 1 s with 14 requests behind it and a usable pool; erasure lock is a shared try-lock; static scan (concurrency, erasure, docs).
* Content opaque, never logged: canaries in content / txn id / path type at `:debug`, refused paths, DB faults whose message quotes the row (send, delivery, ack: nothing half done), purge worker; static scan of Logger / telemetry / inspect (logging, docs).
* No oracle: byte-identical answers (status, body, headers) for no shared room, unknown user / device, remote user, malformed / oversize ids, erasure in progress, deactivated recipient, full queue.
* IDOR-free: foreign `since` tokens (other device, other user), forged positions, DELETE of a foreign device, per-device queue isolation.
* GDPR: both tables in `erased_tables/0`, `sender` delete, in-flight sender 403, lock serialisation, race rounds, runbook / 07 sweep (existing erasure suites now cover the tables through `seed_user!`).
* Cluster safe TTL sweep (Oban cron, concurrent runs, 12 000-row backlog in one run), persisted txn ids (replay after the ack), DB-only state (static scan).

## Findings of the reference run the dev must know

1. The existing dispatcher unit tests (`sync_test`, `sync_membership_partition_test`) run WITHOUT `Nebu.Repo`: any DB read added to `do_incremental_sync` must never raise (22 tests went red until `pending_query` rescued).
2. Two existing exact statement pins move: initial `/sync` 59 -> 61 (`member_prev_content_http_test`) and the history-visibility baseline `initial_sync {50,2} -> {52,2}`, `incremental_sync {30,0} -> {33,0}`; re-pinned to the reference's numbers (a leaner implementation re-pins down).
3. The `RequestLogger` logs sync RESPONSE bodies at `:debug`: `to_device.events[].content` is already redacted by the generic redactor (`***MESSAGE_CONTENT***`), but `type` and `sender` are visible (decided: a type is not content). The request body of the route needs the `to_device_shape?` opt-out.
4. Only the current and the previous token generation are valid for a retry (D8): a retry with the oldest token invalidates the token of the response before it; the tests therefore always continue from the newest token.
5. A pure "delete up to the position" acknowledgement loses a message that commits late (lower queue position than a delivered one); the reference stamps a delivery sequence per response. Pinned with a deferred trigger.
6. `T.reset_rate_limits/0` re-freezes the clock: helper `enable_rate_limit` resets first.

## Decisions pinned (beyond the story text; details in the story `## Decisions`)

Evict oldest, never 429 the sender; recipient restriction (join / invite either side, at send time, silent); `*` excludes the sending device, explicit wins; ack on next token with delivery stamps, to-device position as optional third token group
(two-part token for devices without traffic); limits and defaults via `ToDeviceStore.limits/0` (500 / 8 MiB per device, 2000 / 32 MiB per user, 100 per sender and device, 100 targets and 1 MiB per request, 1000 txn records, 100 messages / 1 MiB per
response, 7 days / 24 h TTL); rate limit 60 / min burst 30 per user; send slots 4 / user, 32 / node; idempotency in `to_device_txns` (unique key), 24 h; try-lock + `lock_timeout` (429); deactivated recipients skipped, queue kept; session-only revoke keeps the queue,
device removal purges queue and records, sent messages stay; erasure also deletes the messages the user SENT; migration 000059; worker `Nebu.Workers.ToDevicePurgeWorker`.

## Open questions

See the story file: rate limit burst for key-request bursts, eviction by colluding co-members, wake-up amplification (up to 100 polls per request), node-wide slots held by colluding accounts, timing oracle, crash reports not forced, manual Element / FluffyChat check.

## Commands

```
.e2ee-ci/quick.sh --migrate                                                      # after the migration exists
.e2ee-ci/quick.sh "mix test <files> --include integration 2>&1 | tail -40"
.e2ee-ci/unit_nodb.sh                                                            # the no-DB job, warnings as errors
python3 mutation/check.py mutation/mutants.py                                    # dry run of the replacements
python3 mutation/mutate.py mutation/mutants.py <log> [ids]                       # (from the repo root, with reference-impl.diff applied)
```

The throwaway database currently has no migration 000059 (dropped for the red run): run `--migrate` after applying the reference.

## Fix pass after the test review (`test-review-findings.md`; owner decisions M1, M2, m2, m1, m3-m8, accepted m9-m12 / i3 / i4)

Result: 296 new tests (12 new files incl. `to_device_identical_device_test.exs`), 287 red without the implementation (9 regression guards: routes 3, docs 5, migration 1), 296 / 296 green with the reference,
no-DB job 6855 / 6856 (only `release_test`), sync / event-dispatcher / OAuth device suites 1069 green, mutation 195 mutants: 190 killed, 5 survived (all equivalent: R09, R10 alone, R21, R22, V17), `mutation-results.txt` replaced.
The re-pinned statement counts are ranges now, green without and with the reference. The throwaway DB is back at schema version 58 without the 000059 tables (red state): run `--migrate` after applying the reference.

* **M1 fair eviction (reference + tests + mutants B07/B08/B13/F01-F06, S01-S08):** per sender and recipient USER 200 messages / 4 MiB (own oldest first, per device share 100 stays); at the user cap (2000 / 32 MiB) the row of the highest rank
  (position counted from the newest message of its sender, i.e. the sender with the LARGEST share) goes first, older first on a tie, set based (one statement for the count, one for the bytes). Tests: victim below its share survives a flood
  (count and bytes), two flooders, largest-share victim, tie inside the cut, single sender regression. Residual (many colluding senders) accepted in the Decisions and 11-risks.
* **M2 identical device ids (`to_device_identical_device_test.exs`, 12; mutants D01-D05):** two users with the same device id: delivery, pre-check, acknowledgement, foreign token, logout / admin revoke / teardown purge, txn scope, `*` self exclusion. `DELETE /devices/{id}` is 404 while another user owns that id (existing guard): pinned as no-op.
* **m2 both-join:** other users count only when both sides are `join`; the invite tests are negatives (200, nothing queued, joining opens the path); reference, docs, Decisions, oracle-context note updated; mutants R02-R05.
* **m1:** story Constraints rewritten with SUPERSEDED marks and read by the docs test. **m3:** statement counts are ranges (old baseline floor, reference ceiling; SET LOCAL exact). **m4:** tautologies and `in [...]` assertions replaced by exact values; the three queue states compared by shape.
* **m5 / m6:** `slow_commit_trigger!` + `wait_sleeping` scoped to the test's own backends (advisory lock `(key, pid)`), sleeps removed, wake-up bounds <= 3 s with a 30 s timeout; the missed wake-up window is pinned by the seam `:nebu, :atdd_to_device_before_join` (mutant W06 = old A19, killed).
* **m7:** "-1" boundaries (sync byte cap, fan-out, user bytes, sender-user bytes) + W07. **m8:** the statement sequence is constant per request (delivered = unknown = unshared = malformed, pinned by counting; the reference lost its short-circuits), shape comparison for deactivated / erased / lock-busy recipients and the three queue states.

## Cycle 1 (after the code review 0 MAJOR / 6 MINOR and Kassandra BLOCKED 1 HIGH / 4 MEDIUM / 2 LOW; the DEV implementation is staged, orchestrator decisions 1-8)

Nothing committed. The throwaway reference of this cycle is `reference-impl-cycle1.diff` (lib: `to_device_store.ex`, `http_to_device.ex`, `to_device_send_gate.ex`, `device_key_store.ex`, `user_deletion.ex`, `matrix.ex`, `protected.ex`, the purge worker; docs 07 / 08 / 11-risks and CHANGELOG; it applies with `git apply` ON TOP OF THE STAGED TREE and was reverted completely: `git diff -- server/lib server/priv docs/architecture CHANGELOG.md` is empty). A previous ATDD agent of this cycle was stopped mid-run; its tests, support helpers, story addendum and the applied reference were reviewed, kept where correct, and completed (gaps below).

| | count |
|---|---|
| tests of the story suite | 296 -> 360 (+44 in two new files, +20 in existing files: docs +17, erasure +2, routes +1) |
| red against the STAGED dev tree (14 files: the new and the changed ones) | 64 of 357: 35 of the 44 new-file tests (budget 18/22, faults 17/22) + 29 in changed files (docs 19, erasure 3, routes 3, logging 2, limits 1, gate 1); the 9 new tests that are green on the staged tree are regression guards of behaviour the dev already has (silent eviction, plain single-sender eviction, largest-share newcomer, duplicate txn not charged twice, slow-but-below-timeout statement, no device after delete, lock count in the planner's favourable case, two store-level redelivery rules) |
| green with the reference | all: wide run matrix + web + compliance + migration 6806 / 6814, the 8 failures + the 67 tests of one module invalidated are NOT in this story's files (see below) |
| no-DB job `.e2ee-ci/unit_nodb.sh` (warnings as errors, Elixir 1.20) with the reference | 6873 / 6874, only `release_test` contiguity (56 / 57 live on another branch, as in cycle 0); the unused alias in `to_device_identical_device_test.exs:11` is fixed |
| mutation (`mutation-results.txt`) | cycle 1: 110 mutants (`mutation/mutants_c1.py`), 109 killed, 1 survivor (K92, equivalent); cycle 0 mutants re-run on the new reference: 150 applied, 144 killed, 6 survivors all equivalent (B35 new, because the dev cuts the response bytes in SQL as well; R09, R10, R21, R22, V17 as in cycle 0); 45 cycle 0 mutants moved with the code and are re-targeted in `mutants_c1.py` (suffix `c`) |

Environmental / pre-existing failures in the wide green run (none in this story's files): `MatrixSsoTest` "POST /login 500" fails identically on `HEAD` with this database (verified with a `git archive` copy of HEAD, 12 / 13), `RegressionSyncLoadTest` (latency), `LogStore.RetentionTest` (2, `MatchError`), and a run-order dependent `ModerationTestSupport.tick/0` `:timeout` in `MembershipStateHttpTest` (setup_all, 67 tests invalidated), `Room.ModerationAtomicDbTest` (4) and `SyncTokenPerDeviceDispatcherTest` (1): all of them pass when run alone (121 / 122 with MatrixSso). In the FIRST wide run `SyncRejoinRangeScanBound` also failed 3 row-count tests that pass alone.

### Files

New: `server/test/nebu/matrix/to_device_sender_budget_test.exs` (22: sender total 4000 / 16 MiB over all recipients incl. one sender to 6 users and a second sender unaffected, 1 MiB sender-device byte share, FAIR device eviction incl. two colluding co-members, the byte-cost bucket 4 MiB / min burst 8 MiB with `retry_after_ms`, refill boundary, no oracle, `*` cost, rolled back), `to_device_delivery_faults_test.exs` (22: a delivery fault never fails `/sync`, held row locks + `SKIP LOCKED` in ack / stamp / eviction, 2 s statement timeout in send and delivery, the lost stamp race at HTTP and store level, send racing a device delete with `FOR KEY SHARE`, advisory lock count, facade).
Changed: `to_device_docs_test.exs` (+17: 07 / 08 / 11-risks / CHANGELOG / story / moduledoc / worker facade / source pins), `user_deletion_to_device_test.exs` (own fence key, held `sync_global` does not skip, exclusive erasure fence; now pins the server name itself: it failed order-dependently in a wide run before), `to_device_routes_test.exs` (defaults, cycle 1 numbers literally), `to_device_send_gate_test.exs` (6 per node), `to_device_concurrency_test.exs` (statement ceilings 14 -> 17, same-token concurrent syncs, lock-wait bound 3 s -> 1.5 s), `to_device_limits_http_test.exs` (default device budget with nine senders, flood expectation), `to_device_logging_test.exs` (200 + empty `to_device`), `to_device_purge_test.exs` (seams), `to_device_identical_device_test.exs` (unused alias), `to_device_oauth_test_support.exs` (defaults, `slow_statement_trigger!`, `lock_rows!`, `sleeping_pids`), `sync_rejoin_range_scan_bound_http_test.exs` (the "no statement timeout" pin now exempts the one statement that sets the transaction-local timeout of the to-device delivery).

### Orchestrator decision -> test

1 HIGH #1: budget test (one sender to 6 users stops at 25 / exact byte fit, second sender unaffected, newest of the send order survives, silent), bucket tests, docs 07 / 11-risks footprint pins. 2 MEDIUM #2: budget "DEVICE cap is fair" (cap 10 / 11 / bytes / tie / largest share), sender-device byte share seam and default, 11-risks wording. 3 MEDIUM #3: erasure test with a held `sync_global` (queued) and with a held `to_device_erasure` (skip / 429), exclusive erasure, static pins. 4 MEDIUM #4: faults (locked rows, ack skip, only-oldest-locked, send into a full queue with locked rows < 1.5 s, statement timeout both ways, position kept with a PRESENTED position), logging tests (200 + empty). 5 MEDIUM #5: gate 6 / 4, routes defaults, statement timeout tests, 11-risks follow-up note. 6 LOW #6: faults "send racing a device delete" (slow insert, `delete_device`, `delete_device!`, `*`, admin delete). 7 LOW #7: 11-risks follow-up pin only. 8 code review: MINOR 1 trace at HTTP and store level (below), 08-concepts sentence pin, MINOR 2 `pg_locks` count + static materialised-candidate pin, MINOR 3 facade static pin + purge through the facade, MINOR 5 / 6 moduledoc and "about 16 / 15" pins, INFO notes (sequence reset, `ctid`, `oauth_cleanup`, token CAS) docs pins.

### Findings of this cycle the dev must know

1. **Byte bucket: deviation from the orchestrator wording ("fan-out bytes actually accepted").** The bucket is charged with the bytes the request ASKS to fan out (explicit device: content + 128; `*`: `min(row x max_targets, fan-out budget)`; a cost above the burst is charged as the burst). An accepted-bytes cost makes the 429 depend on whether the target was delivered, which is the existence oracle the project forbids (pinned: delivered / unknown user / unshared / unknown device all hit 429 at the same request). Recorded as a Decision with the reason; the orchestrator can overrule (the oracle test and `*` cost tests then change).
2. **The lost-race position trace (MINOR 1) cannot be driven to a visible loss over HTTP with the nesting the test seam can build:** a second sync that presents the same `since` is a retry of the previous token generation and invalidates the token of the first, so the loser's token falls back to an initial sync. The rule "a response's position never exceeds the highest stamp THIS response made (else `since`)" is therefore pinned at the store level (`ToDeviceStore.deliver/3` driven through the seam `:nebu, :atdd_to_device_before_stamp`, a 0-arity function run inside the delivery transaction between the read and the stamp) and the HTTP-level trace stays as a guard. The dev must keep this seam (an `Application.get_env` per delivery, same accepted cost as `:atdd_to_device_before_join`).
3. **A delivery fault keeps the position the client presented** (not 0): the failed answer's third token group equals the presented one and the acknowledgement rolls back with the failed transaction (nothing deleted).
4. Tests that existed before and are DELIBERATELY changed (all listed in the story Decisions 22): node slots 32 -> 6, statement ceilings 14 -> 17, the 8 MiB device default test (nine senders, 1 MiB share each), the device flood expectation `[2, 4, 5, 11, 12]`, delivery error answers 503 -> 200 with an empty `to_device`, fence key `sync_global|` -> `to_device_erasure|`, concurrent same-token syncs (a losing response carries nothing), the sync-rejoin "no statement timeout" pin (exemption), lock-wait bound 1.5 s.
5. The dev's `take_within_bytes/2` is dead code now that the SQL cuts the response (mutant B35 survives alone, K98 removing both cuts is killed): remove it or keep it knowingly.
6. A `*` fan-out to a device that is being deleted waits for the delete (key share on the lateral lookup), at most `lock_timeout` 100 ms, then a 429.

### Commands

```
git apply _bmad-output/nebu/epics/e2ee-client-support/step-results/to-device-messaging/reference-impl-cycle1.diff   # on the staged tree; git checkout -- server/lib server/priv server/config docs/architecture docs/compliance CHANGELOG.md to remove
.e2ee-ci/quick.sh --migrate
.e2ee-ci/quick.sh "mix test test/nebu/matrix/to_device_sender_budget_test.exs test/nebu/matrix/to_device_delivery_faults_test.exs --include integration 2>&1 | tail -40"
.e2ee-ci/quick.sh "mix test test/nebu/matrix test/nebu/web test/nebu/compliance test/nebu/migration --include integration --exclude slow 2>&1 | tail -60"
.e2ee-ci/unit_nodb.sh
python3 .../mutation/check.py .../mutation/mutants_c1.py ; python3 .../mutation/mutate.py .../mutation/mutants_c1.py <log> [ids]     # from the repo root, reference applied
```

## Cycle 4 (the owner FIXES Kassandra's cycle 1 MEDIUM: a send held `FOR KEY SHARE` on the recipient's `devices` rows through the soft eviction; 11-risks (12))

Nothing committed. A previous ATDD agent of this cycle was stopped mid mutation run (it left mutant N06 applied in `to_device_store.ex`; the tree was restored from the diff and verified byte-identical). The throwaway reference is `reference-impl-cycle4.diff` (lib `to_device_store.ex`, CHANGELOG, docs 07 / 08 / 11-risks; applies with `git apply` on `HEAD` d41ec675). The lib / docs / CHANGELOG changes are REVERTED in the tree.

| | count |
|---|---|
| new file `to_device_two_phase_send_test.exs` | 13 tests (7 headline: no row lock on `devices` while a send evicts, 1 / 4 overlapping senders, explicit and `*` target, rows committed and wake-up before the eviction, the key share around the INSERT stays; 3 phase-2 failure: statement timeout, error quoting the row, a retry runs no phase 2; 3 quiescent caps) |
| changed: `to_device_docs_test.exs` | +6 (11-risks (12), 08, 07, CHANGELOG, story Decisions D23-26, source shape: two `transact`, the eviction touches no `devices` and no KEY SHARE) |
| changed: `to_device_oauth_test_support.exs` | `slow_statement_trigger!/3` also takes `:delete` (BEFORE DELETE on the messages: makes an eviction slow) |
| run set | 527 tests (all `to_device_*`, `user_deletion_to_device`, 000059 migration, `unrecognized_routes`, `member_prev_content_http`, `history_visibility_http`, `sync_rejoin_range_scan_bound_http`) |
| red against HEAD (reference reverted) | 12 of 527: 7 in the new file, 5 docs pins (the story Decisions pin is green: the story file is in the tree). The other new tests are regression guards (sequential and burst caps, key share around the INSERT, the retry test) |
| green with the reference | 527 / 527 (+1 new retry test: two_phase file 12 / 12 then 13 / 13) |
| `.e2ee-ci/unit_nodb.sh 1.19-alpine` with the reference | 6888 tests, 2 failures: `release_test` contiguity (known) and `MemberSliceGateTest` throughput sanity (timing flake under load, 13 / 13 alone) |
| mutation | `mutants_c4.py`: 19 mutants, 19 killed (N12 survived first, killed by the added retry test) |

Mutants cover: eviction lock on `devices` (FOR KEY SHARE N01, FOR UPDATE N02), eviction back inside phase 1 (N03), phase-2 error propagated (N04), phase 2 skipped (N05), no own timeouts (N06), error text instead of kind (N07), wake-up after phase 2 (N08), empty eviction arrays (N09), asynchronous phase 2 (N10), txn record outside the first transaction (N11), phase 2 for a duplicate (N12), the target lookups losing their KEY SHARE (N13, N14), four docs mutants (N15-N19).

### Existing pins checked against the single-transaction shape (none deleted)

No existing assertion needed a change: all stayed green with the reference. Re-verified and still valid: the statement ceiling 17 and the "50 recipients ~ one recipient" set-based pins (`to_device_concurrency_test`; phase 2 adds only BEGIN/COMMIT + the same seven statements, filtered by "device"), the "same number of statements for a delivered and a skipped recipient" no-oracle pin (`to_device_send_http_test`), the key-share-through-the-INSERT and `delete_device` ordering tests (`to_device_delivery_faults_test`: the slow trigger is on INSERT, inside the window), the 08-concepts "FOR KEY SHARE" pin, the 3 statement-shape files (`member_prev_content`, `history_visibility`, `sync_rejoin_range_scan_bound`). Changed support only: `slow_statement_trigger!` `:delete`. Superseded in meaning (text, not assertion): the old accepted-residual wording of 11-risks (12) ("holds FOR KEY SHARE until its transaction commits", "follow-up idea") is now refuted by `refute` in the new docs pin; the moduledoc of `to_device_delivery_faults_test` line 12 still says a send holds the key share, which stays true for the INSERT window.

### Commands

```
git apply _bmad-output/nebu/epics/e2ee-client-support/step-results/to-device-messaging/reference-impl-cycle4.diff   # on HEAD d41ec675; git checkout -- server/lib server/priv server/config docs/architecture docs/compliance CHANGELOG.md to remove
.e2ee-ci/quick.sh "mix test test/nebu/matrix/to_device_two_phase_send_test.exs test/nebu/matrix/to_device_docs_test.exs --include integration"
python3 .../mutation/check.py .../mutation/mutants_c4.py ; python3 .../mutation/mutate.py .../mutation/mutants_c4.py <log> [ids]     # reference applied
```
