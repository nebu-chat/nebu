# ATDD report: server-side-key-backup (epic e2ee-client-support, REQ-2026-011)

Step: `atdd`. Branch `feature/e2ee-client-support`, worktree `open-chat-e2ee`. Nothing committed. Only tests, test support and step results remain; the throwaway reference
implementation (lib, migration 000056, docs, CHANGELOG) is saved as `reference-impl.diff` and was reverted.

## Result

| | count |
|---|---|
| new tests (9 new files, one new support file) | 199 (after the fix pass; 178 before) |
| red without implementation | 187 (the other 12 are regression guards, see below) |
| green with the reference implementation | 199 / 199 |
| changed existing files | `matrix_client_compat_test.exs`, `unrecognized_routes_test.exs`, `unrecognized_routes_integration_test.exs`, `test_helper.exs`, `user_deletion_oauth_test_support.exs` |
| old-stub tests red without implementation | compat 3 (new describe), unrecognized_routes 3 (clause inventory x2, 405 table), integration 1 |
| shared erasure suites red without implementation | every suite that calls `UserDeletionTestSupport.seed_user!/2` (global_data 32, failure_steps 16, sweep 5, schema_guard 2, docs 1 ...), because the shared inventory now contains the two tables |
| no-DB job (`.e2ee-ci/unit_nodb.sh`, warnings as errors) | compiles; red: 31 (routes 8, docs 10, migration static 8, unrecognized 3, erasure docs / schema guard 2); with the reference (measured before the fix pass): 6726 passed, 0 failed |
| mutation | 98 mutants + 60 fix-pass mutants, all killed except 1 equivalent (D01) (`mutation-results.txt`) |

Red for the right reason: 404 `M_UNRECOGNIZED` / constant stub answer / missing tables (`undefined_table`), never a compile error (modules are not referenced before they exist).
The 12 passing tests are regression guards that must stay green: GET /version with no backup is `404 "No backup found"` (old answer kept), JWT-shaped junk token 401, `/version` 405
Allow GET, POST, unknown shapes and other API prefixes stay 404 M_UNRECOGNIZED (2), the 1 MB cap of every other route stays (2), the 1 MB cap of ANONYMOUS room_keys requests (3: no token, `access_token` query, non-bearer header),
no Logger call names a blob, migration 000055 untouched.

## Fix pass (test review `test-review-findings.md`: 12 MINOR, INFO 7 / 9 / 11)

1. Coinciding versions are deterministic (per-user counters, the first version is "1"): B creates "1" like A and reads / writes / deletes EVERY granularity (all / room / session, all three PUT shapes, PUT and DELETE of the version), A's sessions, count and etag untouched; 14 new mutants drop `user_id` from each room / session level SQL. Cap counts under coinciding ids tested (limits).
2. NUL in BODY ids (room / session key), NUL in auth_data / session_data, SQL metacharacter ids (quotes, `--`, `$1`, `%s`, `;`) through every shape; mutants: NUL check removed, SQL by string interpolation.
3. Valid empty batches (`{"rooms":{}}`, `{"sessions":{}}`, a room with no sessions): 200, count and etag unchanged; mutants: refused / etag bumped.
4. The 100 000-session test is tagged `:slow` (runs by default, `--exclude slow` for a quick local run); measured 7.4 s.
5. DB faults: replace with UPDATE and DELETE blocked, a batch of a new plus a replacing session (the new one is not stored), a failing INSERT whose database message QUOTES session_data / auth_data (no canary, no database message in answer or log); mutant: the DB message becomes the logged kind.
6. Behavioural cluster-safety: rows deleted with SQL behind the server's back are gone from `count` / `GET /keys` at once (mutant: count cached in `:persistent_term`); source scan extended (Cachex, ConCache, Nebulex, :mnesia, :global, :pg).
7. Body cap is credentialed-only (orchestrator decision): anonymous requests keep 1 MB (no token + 1 000 001 bytes = 413, exactly 1 000 000 = 401, malformed JSON without a token = 401, never M_NOT_JSON), a bearer request gets 5 MiB, `access_token` in the QUERY and a non-bearer `Authorization` header are no credentials (the OIDC plug reads only `Authorization: Bearer`). Mutants: cap for everybody, any header, query token, empty bearer, no bigger cap.
8. Erasure: `versions == 3` (older, current, marker); FK versions<-sessions is a Decision with a static and a catalog test (no cascade); mutants: cascade, no FK, marker row removed.
9. `seed_backup!` failures name `seed_backup!` / `seed_user!` in the assertion message.
10. Concurrency tests run at most 8 requests in flight (pool of 10); the lock mutants are still killed.
11. Docs pins loosened to proximity regexes of key facts (plus pins for the per-user counter, the credentialed cap, the FK).
12. Reads unlimited confirmed; the test is renamed "a 429 is answered before the body is VALIDATED" (an oversize body on an exhausted bucket is still 413, pinned).
INFO 7: float index `5.0`, non-JSON content types / empty body, `version[]=` array and duplicated `version` query tested. INFO 9: the shuffle of the 24-upload race is seeded and the seed is in the failure message. INFO 11: the junk-token test now asserts nothing was stored.

Environment note: in the full integration suite of the throwaway database 28 tests of admin / log-store / sync-load modules fail; they fail identically on an untouched checkout
(measured: 23 failing in the same 9 files at HEAD), they are not related to this story.

## Scenario -> test

| Gherkin scenario | tests |
|---|---|
| 1 create a version and read it back | `room_keys_versions_http_test.exs` "Scenario 1" (7), compat `room_keys - the Element startup contract` (5) |
| 2 store session keys, read back with count and etag | `room_keys_keys_http_test.exs` "Scenario 2" (8), "etag and count" (3) |
| 3 a better session replaces the stored one | "Scenario 3" (13 table cases of the spec merge order + 4), concurrency "same session uploaded concurrently" (3) |
| 4 write to a non-current version is refused | "Scenario 4" (4) + "the `version` query parameter" (3) |
| 5 another user cannot read my backup | versions "Scenario 5" (3), keys "Scenario 5" (3) (reads, writes, deletes; coinciding version numbers) |

## Story constraint / decision -> test

* Endpoints, shapes, status codes: versions + keys files; route table, 401 (no token / junk), 405 + Allow, 404 for off-shape paths: `room_keys_routes_test.exs` (no DB), AC12 inventory + 405 table in `unrecognized_routes_test.exs`.
* Idempotent DELETE, soft-delete marker keeps no `auth_data`, versions never reused, GET /version falls back to the newest remaining one or 404, PUT /version rules, version param required, malformed versions are 404/403 never 500: versions "DELETE", "version numbers", "PUT"; keys "the `version` query parameter".
* Merge order (verified > lower first_message_index > lower forwarded_count > keep stored), count unchanged on replace, etag changes on insert / replace / delete and equals the one GET /version reports: keys "Scenario 3", "etag and count".
* 403 `M_WRONG_ROOM_KEYS_VERSION` + `current_version` (older, deleted, unknown, malformed, other user's); 404 when the user has no backup: keys "Scenario 4".
* Quotas: 10 versions (11th 403 M_FORBIDDEN, nothing created / deleted, deleted do not count, numbers not reused): versions "quota"; 100 000 sessions (real default test + seam with batch atomicity, replace at the cap): limits; 8 KiB / 16 KiB / 5 MiB (exact boundaries, bytes not characters, 413 M_TOO_LARGE, whole request refused): limits, versions; non-object `auth_data`, wrong algorithm: versions "POST /version validation".
* Rate limit like the sibling write endpoints (per user, 60/min, burst 30, own bucket, 429 envelope, reads free): limits "rate limit".
* Logging law (canaries in auth_data / session_data at `:debug`, refused requests, generic 500 on a failing write with a DB trigger fault, no DB message in log or answer): `room_keys_logging_test.exs`; static: no Logger call names a blob (docs test). Phoenix `filter_parameters` is only for the Phoenix admin endpoint; the Matrix routes are plain Plug routes, so the `RequestLogger` is the one capture path.
* Cluster-safe: concurrency suite (same session x20, 24 distinct-rank uploads x5 rounds, quota races, cap races, delete vs upload without orphan rows) and a source scan that forbids ETS / persistent_term / Agent / GenServer / counters / process dictionary in the code that names the tables.
* Storage / RLS / grants: `000056_room_key_backup_test.exs` (static files, catalog as runtime role, down/up round trip in a rolled-back transaction).
* GDPR erasure: `user_deletion_room_keys_test.exs` (all versions incl. markers and all sessions deleted, other user byte-identical, in-flight writes `403 M_USER_DEACTIVATED`, writers wait for the `sync_global` advisory lock, erasure vs upload race), plus the shared inventory (`expected_erased`, `seed_user!`) which drives the existing erasure, sweep, docs and schema-guard suites.
* Docs: `room_keys_docs_test.exs` (ADR-011 clarification, 05 and 08 sections, CHANGELOG entry, stub comments gone) and the existing `user_deletion_docs_test` / `user_deletion_sweep_test` (runbook verification queries, both sweeps, 08 inventory) which now name the new tables.
* Not tested: the `m.oauth` UIA stage (out of scope). No Gherkin / Playwright feature: the Element flow needs the whole stack (Dex, Element Web), which this step may not start; the HTTP-level behaviour is covered through the full `Nebu.Web.Router` with real sessions, including the Element startup sequence in the compat file.

## Decisions pinned by the tests (beyond the story text; please confirm)

1. Tables `room_key_backup_versions` and `room_key_backup_sessions`, both `user_id TEXT NOT NULL` (named by the erasure inventory); the two tables are in `UserDeletion.erased_tables/0`, sessions before versions.
2. A version is a decimal string without leading zero, strictly increasing per user; anything else is an unknown version (never 500, "01" does not alias "1").
3. Errors: missing body member / query param `400 M_MISSING_PARAM`, wrong type / value `400 M_INVALID_PARAM`, not JSON `400 M_NOT_JSON`, JSON not an object `400 M_BAD_JSON`, oversize blob or body `413 M_TOO_LARGE`, quotas (11th version AND the session cap) `403 M_FORBIDDEN`, erased user `403 M_USER_DEACTIVATED`, failing DB write `500 M_UNKNOWN` (generic text).
4. Sizes are canonical (compact) JSON bytes; ids 1..255 bytes, valid UTF-8, no NUL; megolm indexes 0..4 294 967 295; every request is stored whole or not at all.
5. Seam `:nebu, :room_keys_max_sessions_per_version` (default 100 000), read at request time.
6. `JsonBody` gets a 5 MiB cap for `/_matrix/client/v3/room_keys/**` for requests carrying an `Authorization: Bearer` credential only (413 envelope of the existing rescue); anonymous requests and every other route keep 1 MB (pinned).
7. Rate limit: writes only, own per-user bucket (not shared with `account_data`), 429 is answered before the body is read; GETs are not limited (divergence, documented in 08).
8. The creating writers (POST /version, PUT /keys) take the per-user `sync_global` advisory lock (same key as `AccountDataStore.put/3`); pinned by lock-wait tests.
9. The route clauses must be the 14 literal `get|put|post|delete "/client/v3/room_keys/..."` lines (AC12 inventory), `/version` keeps 405 Allow GET, POST; the new shapes 405 Allow GET, PUT, DELETE.
10. `GET /version` without a backup keeps the answer `404 M_NOT_FOUND "No backup found"`.
11. Old-stub tests (constant `{"version":"1"}`, nothing stored, `@tag :no_repo`) are replaced by DB-backed ones (compat describe, `:integration`); the DB-free auth-gate tests stay.
12. The etag changes whenever the stored set changes; a no-op merge (stored session kept) is NOT pinned either way.

## Open questions

* Pre-auth cost (resolved in the fix pass): the 5 MiB cap is credentialed-only. A request with ANY bearer string (even a junk one) still gets 5 MiB parsed before the token is checked; a cheaper design would verify the token first.
* Error code of the session cap: `M_FORBIDDEN` (consistent with the story's version quota) vs `M_RESOURCE_LIMIT_EXCEEDED` (what the room account data cap uses). Pinned as M_FORBIDDEN.
* RLS predicate: policies of the sibling OAuth tables are `USING (true)` (FORCE RLS + grants); a per-user predicate (`app.user_id`) would break the erasure and the shared test counters, so only "enabled, forced, a policy per command, grants" is pinned.
* Invalid UTF-8 in a QUERY string never reaches a route (Plug answers a bodiless 400); path segments with invalid UTF-8 / NUL are handled (400) and tested.

## Commands

```
.e2ee-ci/quick.sh "mix test <files> --include integration 2>&1 | tail -40"      # needs the migration: .e2ee-ci/quick.sh --migrate
.e2ee-ci/unit_nodb.sh                                                            # the no-DB job, warnings as errors
.e2ee-ci/nodb_one.sh "<files>"
```

New files: `server/test/nebu/matrix/room_keys_{versions_http,keys_http,limits_http,concurrency,logging,routes,docs}_test.exs`, `room_keys_oauth_test_support.exs` (suffix required by
`test_ignore_filters`), `server/test/nebu/migration/000056_room_key_backup_test.exs`, `server/test/nebu/compliance/user_deletion_room_keys_test.exs`.
The throwaway database must be re-created (or migrated) after the migration exists; `limits_http_test` contains one slow test (fills 100 000 sessions, tag timeout 600 s).

## Cycle 1 (Kassandra HIGH 1 / MEDIUM 2, 3 / LOW 4, 5 / code review M1, m1, m2, m3, m6; orchestrator decisions 1-8)

The staged cycle-0 implementation was NOT touched; only tests, test support and the story Decisions changed. Reference: `reference-impl-cycle1.diff` (on top of the staged tree, reverted; apply with `git apply`).

New files: `room_keys_budget_http_test.exs` (byte budget 18, version rows cap), `room_keys_lock_timeout_test.exs` (5). Renamed: `000056_room_key_backup_test.exs` -> `000058_room_key_backup_test.exs` (`git mv`).
Red against the staged lib (per file, red / total): budget 18/18, lock_timeout 4/5, limits 4/29, routes 5/14, docs 7/19, migration 000058 4/19, route normalizer 8/68, logging 1/9; the rest of the room_keys suites stay green (regression guards of unchanged behaviour). Total red 51. No-DB job: compiles with warnings as errors, 23 red (docs 7, routes 5, migration static 3, normalizer 8). With the reference everything is green (all files above, compliance dir 206, web dir 768).

Pinned: (1) byte budget over all live versions (session_data + auth_data canonical bytes, default 256 MiB, seam `:room_keys_max_bytes_per_user`, net of replacements, freed by session / version deletes, decided under the lock, 403 M_FORBIDDEN, nothing stored; exact boundary, gross-vs-net, atomic batch, auth_data deltas on POST / PUT version, bytes not characters, per user, concurrent race, the DEFAULT proven by a slow test that fills 256 MiB); (2) bulk reads own bucket 30/min burst 10 (429 + retry_after_ms + Retry-After), single GET and GET /version* unlimited, independent of the write bucket, structural equality of a ~4 MB bulk response (the splice itself is unobservable, mutant S01 is equivalent); (3) lock timeout (seam `:room_keys_lock_timeout_ms`, default 2000 proven): each of the nine writers answers 429 M_LIMIT_EXCEEDED + retry_after_ms after about the timeout (a wait, not a try-lock), stores nothing, waiters beyond the pool size all answer, reads never wait; (4) no pre-auth parse: junk / no / malformed credentials + 1 000 001 bytes or 6 MiB => 401 with `body_params` still unfetched, valid token exactly 5 MiB => 200, +1 => 413, 429 before the body is read; (5) version rows incl. markers cap (seam `:room_keys_max_version_rows_per_user`, default 1000 proven); (6) route normalizer replaces non-sigil room ids and session ids (unit + log canary); (7) migration number 58, file names and headers, partial index (static + catalog); (8) docs tests (07 historical note, 08 erasure paragraph names RoomKeyBackupStore.create_version/put_sessions, 11-risks row, "opaque" not "verbatim", 000058 in every doc, CHANGELOG, story Decisions incl. "superseded").

### Superseded / changed tests (deliberate, each with the reason)
1. `room_keys_routes_test.exs` describe "credentials decide the body cap" -> "authentication comes before the body": was "no token + 1 000 001 bytes = 413", "junk bearer + 5 MiB + 1 = 413", "access_token / non-bearer header = 413 (1 MB applies)"; now every one of them is 401 without the body being read (decision 4, the cycle-0 "anonymous keeps 1 MB" Decision is superseded). Kept: exactly 1 000 000 anonymous bytes = 401, malformed JSON without a token = 401, createRoom keeps its 1 MB pre-router cap.
2. `room_keys_limits_http_test.exs` "a 429 is answered before the body is validated ... (an oversize one is still 413)" -> "before the body is read": an oversize body on an exhausted bucket is now 429 and `body_params` stays unfetched (decision 4: the limiter now precedes the read).
3. `room_keys_limits_http_test.exs` "reads are not limited: 40 reads of every kind" -> "single-session reads and version reads are not limited"; the two bulk reads moved into the new bulk-bucket tests (decision 2).
4. `room_keys_limits_http_test.exs` "exactly 5 242 880 bytes accepted, +1 = 413": `assert too_big.halted` dropped (the 413 is produced inside the authenticated route, not by the halting pre-router plug; status, envelope, nothing stored stay pinned).
5. `000056_room_key_backup_test.exs` -> `000058_...`: number `>= 56` -> `== 58` and the module / moduledoc renamed (decision 7).
6. `room_keys_docs_test.exs`: the pins "reads are not limited", "5 MiB cap for requests that carry credentials" and "anonymous requests keep the 1 MB cap" are removed and replaced by the cycle-1 wording pins (and a refute of the old rule); a "stored verbatim" refute and the 000058 pins added.
7. `room_keys_concurrency_test.exs`, versions, keys, erasure suites: unchanged.

Story Decisions (edited): the cycle-0 bullets on the credentialed 5 MiB cap and on reads were replaced by the SUPERSEDED / cycle-1 bullets (no pre-auth parse; bulk bucket; byte budget and row cap; lock timeout; migration 000058 and the partial index; normalizer).
Run: `.e2ee-ci/quick.sh --migrate` (after the migration exists), `.e2ee-ci/quick.sh "mix test <files> --include integration 2>&1 | tail -40"`, `.e2ee-ci/unit_nodb.sh`. The two `@tag :slow` tests of the budget file (fill 256 MiB / 1000 create-delete rounds) take about a minute each; the 100 000-session test 7 s.

## Cycle 2 (delta review: security `...-cycle1.md` and `code-review-findings-cycle1.md`; orchestrator decisions 1-8)

The staged cycle-1 implementation (lib, migrations, docs) was NOT touched; only tests, test support, the story Decisions and step-results changed. Reference: `reference-impl-cycle2.diff` (store try-lock + 64 MiB / row-cost accounting, `Nebu.Matrix.RoomKeysReadGate` (new, monitor based GenServer, child of `Nebu.Application`), `protected.ex` buckets and slots, `JsonBody` decoded skip clause, `RouteNormalizer` version placeholder `:version`, docs 08 / 11 / runbook prune SQL / CHANGELOG / security report 000058); it was applied on top of the staged tree, everything green, and reverted (`git checkout --` of exactly those paths; the story file keeps its Decisions addendum).

New files: `room_keys_bulk_flight_test.exs` (8: one bulk read per user, two per node, seam read at request time, killed request frees user and node slot, every finished request frees its slot, single-session / version GETs take no slot), `room_keys_prune_runbook_test.exs` (3: the SQL is TAKEN FROM THE DOCS (a fenced `sql` block with `DELETE FROM room_key_backup_versions ... deleted_at IS NOT NULL ... '<user_id>'`, the placeholder bound to `$1`) and EXECUTED: old markers of the user go, the highest-numbered marker stays, live versions / sessions / other users untouched, a locked-out user can create again with a number above every old one, 403 text points at the operator). Rewritten: `room_keys_lock_timeout_test.exs` (9).
Red against the staged lib (per file, red / total): budget 15/25, limits 13/36, lock_timeout 4/9, bulk_flight 5/8, prune_runbook 3/3, erasure (`user_deletion_room_keys`) 3/13, docs 13/30, routes 2/16, route normalizer 2/71. Total red 60; all other room_keys / erasure / migration / compat / unrecognized-route suites stay green (regression guards). No-DB job `.e2ee-ci/unit_nodb.sh`: compiles with warnings as errors, 18 red = docs 13, routes 2, normalizer 2 + the known `release_test.exs` migration contiguity (56/57 live on another branch, not touched). With the reference everything green (no-DB suite 6768/6769, only `release_test`; DB files: all green incl. the 64 MiB and 100 000-row slow tests).

Pinned: (1) budget 64 MiB default; accounting `octet_length(room_id) + octet_length(session_id) + 128 + session_data` per row + live `auth_data` (exact fit and +1 per part: multi-byte ids in BYTES, room id, session id, fixed 128, per row not per request, replacement costs no second row, version delete frees ids and row cost, 5 tiny sessions fit and the 6th not); (2) try-lock for all 9 writers: busy lock = 429 + `retry_after_ms` in < 1 s although the `lock_timeout` seam says 5 s and with no seam, 25 concurrent writers behind a held lock all 429 in < 2 s and the pool stays usable (other users write, this user reads), reads never take the lock; erasure suites: a writer while the erasure holds the lock is 429 at once and 403 `M_USER_DEACTIVATED` after its commit; `lock_timeout` stays as the safety net for ROW locks (holder keeps `SELECT .. FOR UPDATE` of the version row: 429 after about the seam, default 2 s); (3) single-flight: 1 bulk read in flight per user, 2 per node (seam `:room_keys_max_concurrent_bulk_reads_per_node`), 429 before any DB work (the database is blocked by an ACCESS EXCLUSIVE table lock held by the test, the 429 still comes), slot freed by a KILLED request process (user slot and node slot) and by every normal ending (200 / empty / 404 / 400); (4) buckets: write burst 5, bulk burst 3, light version bucket 120/min burst 30 shared by `GET /version` and `GET /version/{v}` (charged for 404 too, independent of write / bulk / other users), single-session GET unlimited; the three refill rates are pinned with a hand-advanced clock (1 token per 1 s / 2 s / 500 ms; 999 / 1 999 / 499 ms still 429); (5) prune SQL executed from the docs (above); (6) docs: 08-concepts (64 MiB, 128 + ids, try-lock, bulk slots, version bucket, node-local N x limit, bursts), 11-risks (peak numbers `300-350 MiB` before / `64 MiB x 2.5` after, streaming follow-up, single-flight + node cap, node-local buckets, accepted RLS USING (true), O(scan) per write with the O(1) counter column as follow-up), CHANGELOG 64 MiB, no `000056_room_key_backup` in the cycle-0 security report, story Decisions cycle-2 pins, the slot module is a separate monitor based module that does not name the key backup tables (the cluster-safe source scan stays valid for the data modules); (7) RouteNormalizer: `room_keys/version/{n}` is `/version/:version` (also encoded anchor, empty segments, trailing slash), keys routes unchanged (also ids literally named `version`); (8) JsonBody: encoded `room%5Fkeys`, `%72oom_keys`, `room_key%73`, `v%33`, `%63lient`, `%5Fmatrix`, `//` spellings are unparsed before the authentication (no token + 1 000 001 bytes / 6 MiB = 401, body unread, never 413) and with a valid token a 1.6 MB batch is accepted on them.

### Superseded / changed tests (deliberate, each with the reason)
1. `room_keys_limits_http_test.exs` rate-limit describe: burst 30 -> 5 ("the 31st write" -> "the 6th write", all 29-write loops -> 4 puts after the POST), bulk burst 10 -> 3 ("the 11th" -> "the 4th", independence loops 10 -> 3), "single-session reads and version reads are not limited" -> only the single-session GET (the version GETs now have the light bucket), "a 429 comes before the body is read" loop 29 -> 4.
2. `room_keys_budget_http_test.exs`: every budget now includes `cost(sid, bytes) = octet_length(room) + octet_length(sid) + 128 + bytes` per stored session (exact-fit budgets recomputed; the concurrent-uploads test uses equal-width ids `c01..c12` and `RK.retrying`); the slow default test "256 MiB: 32 767 sessions of 8 192 bytes" -> "64 MiB: as many 8 192-byte sessions as fit (about 8 043), then exactly the remaining bytes (id width kept equal) fit and one byte more does not".
3. `room_keys_lock_timeout_test.exs`: REPLACED "each of the nine writers: 429 after about the timeout (not at once ...): `elapsed >= 250` - it must WAIT, a try-lock is not the contract", "the DEFAULT timeout is 2 seconds (elapsed 1800-4500)", "more waiters than free pool connections (11 writers): all 429 after the timeout" and their mutant L05 (cycle 1: "lock wait is a try-lock") by the try-lock tests above; the row-lock describe keeps the timeout contract (wait up to the seam, default 2 s) for ROW locks.
4. `user_deletion_room_keys_test.exs`: "POST /version / PUT /keys (every shape) waits for a transaction that holds the user lock, then completes" and "a write that waited for the lock of an erasure in progress is refused after the commit" -> 429 at once while the lock is held, completes after it / 403 `M_USER_DEACTIVATED` after the erasure commit (same serialisation, no waiting); the race test also accepts 429; `setup` disables the limiter AFTER `E.setup_env!` (it re-enables it with a frozen clock; the writes of these tests exceed the burst of 5).
5. `room_keys_concurrency_test.exs`: `parallel/3` retries a 429 (a try-lock refuses concurrent writers of one user at once) so all state assertions are unchanged.
6. `room_keys_oauth_test_support.exs`: `seed_backup!` (6 writes per user) switches the limiter off while seeding and restores it (every erasure suite seeds through the routes with the real limiter on; burst 5); new helpers `session_cost/3`, `default_max_bytes/0`, `row_overhead/0`, `default_bulk_reads_per_node/0`, `set_clock/1`, `retrying/2`.
7. `room_keys_docs_test.exs`: pins of "burst 30", "bulk burst 10", "256 MiB" (08-concepts, 11-risks, CHANGELOG) and "lock timeout 2 s answers 429" replaced by the cycle-2 numbers (a refute of the old numbers where the doc must not keep them; 11-risks may still NAME the former 256 MiB for the honest peak); `route_normalizer_test.exs`: the cycle-1 `=~ "/room_keys/version"` (which also passed for the mislabelled `:room_id`) -> exact `/version/:version`.

Story Decisions (edited): five SUPERSEDED / cycle-2 bullets inserted before the migration bullet (memory and concurrency; try-lock; budget accounting; version bucket + node-local; marker prune SQL; normalizer `:version` and decoded JsonBody segments). Cycle-1 bullets stay as history (they still carry 256 MiB, burst 10 / 30, the waiting lock).
Run: `.e2ee-ci/quick.sh "mix test <files> --include integration 2>&1 | tail -40"`, `.e2ee-ci/unit_nodb.sh`, mutants `mutation/mutate.py mutation/mutants_c2.py <log> [ids]` (the `:slow` tests only run for the mutants marked `slow=True`). The 64 MiB default test fills about 8 000 sessions in 14 requests of up to 4.9 MB (a few seconds).
