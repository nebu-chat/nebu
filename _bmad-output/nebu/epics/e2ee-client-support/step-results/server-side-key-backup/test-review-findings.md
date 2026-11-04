# Test review (pre-dev): server-side-key-backup

Reviewer: bmad-testarch-test-review (read-only). Verdict: approve to dev; 0 MAJOR, 12 MINOR, 11 INFO. All 5 scenarios, scope bullets and Decisions pinned (merge order, idempotent DELETE + marker, current_version, versions never reused, empty-read shapes, version param, 405 Allow, route inventory, status codes). 97/98 mutants killed (D01 equivalent). Changed existing tests extended, not weakened. No sleeps; async false; env restored.

## MINOR
1. Cross-user isolation with a COINCIDING version number is conditional/incomplete (`keys_http:599-617` `if vb != va`, `versions_http:444-469` `if va == vb`); GET /keys/{room}, GET /keys/{room}/{session}, DELETE room/session, the three PUT shapes against a coinciding number are not checked; no mutant drops `user_id` from the session-row SQL. => State per-user version counters (first is "1"); make deterministic: B creates a version equal to A's number and reads/PUTs/DELETEs every granularity; A's sessions/count/etag untouched; add mutants for room/session-level SQL.
2. NUL / SQL metacharacters in BODY ids and auth_data untested (NUL only in path segments): body ids `"a\u0000b"` (room/session key), auth_data with `\u0000`, ids with `'`, `--`, `"`.
3. Valid empty batches untested: `{"rooms":{}}`, `{"sessions":{}}`, `{"rooms":{"!r":{"sessions":{}}}}` => 200 {count,etag}, no change.
4. The 100 000-session test is untagged: add `@tag :slow` (or documented policy), record runtime.
5. Atomicity under DB fault only single-row and mechanism-coupled (blocks UPDATE only): add a batch variant (one new + one replacement, blocked UPDATE, new one absent), an INSERT-failure case (Postgres error may quote session_data: no leak in log/response), block UPDATE and DELETE for the replace test.
6. Cluster-safety pins narrow (source scan covers any lib file containing `room_key_backup`, incl. user_deletion.ex; forbidden list misses Cachex/ConCache/Nebulex/:mnesia): add a behavioural test: delete the user's rows directly with SQL, then GET /version count 0 and GET /keys {"rooms":{}} (no caches).
7. Unauthenticated: no-token + malformed JSON must be 401 not M_NOT_JSON; pre-auth body size: JsonBody parses before auth. ORCHESTRATOR DECISION: the 5 MiB cap applies only to requests that carry an Authorization bearer credential (header) or access_token query param; requests without credentials keep the 1 MB cap; test: no token + 1_000_001-byte body => 413 or 401, never 5xx, nothing stored.
8. Erasure tests: `versions >= 2` => `== 3`; the "sessions before versions" inventory order presumes an FK: state it as a Decision (FK versions<-sessions with ON DELETE restriction) or soften.
9. Shared `seed_user!` couples every user_deletion suite to the room_keys stack: assertion messages must name `seed_backup!`.
10. Pool contention: concurrency tests use up to 20 tasks with pool_size 10: use max_concurrency <= 8 for status-asserting tests.
11. Docs/wording pins over-pinned (exact phrases): loosen to key facts / proximity regexes.
12. Reads unlimited is a documented divergence: confirm in the story (decision: CONFIRMED). The test named "answered before the body is looked at" actually pins "before body validation" (JsonBody parses first; oversize body on an exhausted bucket is 413): rename the test and the Decision.

## INFO
No crash/restart test (no process state); no-op merge etag unpinned (fine); validation-vs-404/403 precedence unpinned; decimal-string versions stricter than spec (defensible, story literals "1","2"); 403 body exact keys; `halted` incidental pin; empty-body PUT /version, non-JSON content-type, float indexes `5.0`, duplicate/array `version` query values untested; DELETE /version, DELETE /keys, PUT /version lock pinned only indirectly; unseeded shuffle in concurrency test (log the seed); Phoenix filter_parameters N/A for Matrix routes; versions_http:483 named "nothing is stored" but asserts only 401s.

## e2e note (story)
No Gherkin/Playwright written (ui:false; Element startup sequence covered through the full router in compat tests). Add a story note/DoD: re-run the Element e2e job as a gate before merge; every Element e2e login now creates a REAL backup; e2e/features/element/crypto/recovery-setup.feature (known failure K7) is the place for an API read-back of GET /room_keys/version; update e2e/KNOWN-FAILURES.md:36 ("stub").
