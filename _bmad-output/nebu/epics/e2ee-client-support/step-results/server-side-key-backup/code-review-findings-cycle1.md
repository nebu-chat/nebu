# Code review (cycle 1 delta): server-side-key-backup

Reviewer: nebu-code-reviewer (read-only, static). 0 MAJOR, 4 MINOR, 6 INFO. Cycle-0 findings M1, m1, m2, m3, m4, m6 closed; m5 (count(*)) deliberately a follow-up.

## Peak memory of the bulk read (estimate, not measured)
Full read of one version holds the stored text about once (spliced iodata adds no copy) + ~0.3-0.5 KiB list/encode overhead per row (30-50 MB at 100k rows). Worst case ~300-350 MiB per request for a 256 MiB version (+ up to ~0.75x if Bandit compresses). Not bounded in aggregate: the bulk bucket (protected.ex:604, 30/min, burst 10, node-local ETS) limits rate, not concurrency; one account can start 10 reads (~3 GiB) and hold all 10 pool connections while a slow reader drains. Realistic backups are far smaller (100k sessions x 0.4 KiB ~ 40 MB).

## MINOR
- MINOR-1 Residual memory risk not recorded (http_room_keys.ex:121-125, room_key_backup_store.ex:274-283, 11-risks "Resolved by design"). Record the peak and accepted residual; optionally cap the response size (413/429 above a threshold). Stronger follow-up: chunked keyset reads via Plug.Conn.chunk.
- MINOR-2 Byte budget ignores id bytes and row overhead (room_key_backup_store.ex:539-546 sums only octet_length(session_data) + live auth_data). 100k sessions x 10 versions with 255-byte ids can exceed 1 GiB while the budget shows near zero. Add octet_length(room_id)+octet_length(session_id)+constant per row, or cap sessions across versions. MINOR with OIDC accounts, MAJOR with open registration.
- MINOR-3 Version-row cap is a permanent lockout (room_key_backup_store.ex:96): markers are never pruned; the 403 says "contact the administrator" (http_room_keys.ex:159) but no tool/runbook exists. Prune oldest markers at the cap (keep the highest-numbered marker, a pruned number's DELETE answers 404), or add a runbook SQL line.
- MINOR-4 Stale `000056_room_key_backup.up.sql` in the security report l.13 (docs/stories/e2ee-client-support/security-reports/...).

## INFO
1 every write runs 2-3 count(*) + sum(octet_length) scans under the sync_global advisory lock (shared with account_data/cross-signing writers without lock timeout); 2 route_normalizer.ex:91 labels room_keys/version/{n} as `:room_id`; 3 buckets node-local ETS (cluster = N x limit), sharpens MINOR-1; 4 lock waiters can hold up to 10 pool connections for 2 s; 5 after an operator lowers the budget a user above it cannot replace even with a smaller blob; 6 very large read can exceed the 15 s Ecto query timeout -> 500 (rescued).

## Verified clean
Splice validity/escaping/empty cases/grouping; budget (post-write total under the lock, boundary inclusive, deletes free, all writers lock first); lock_timeout transaction-local, 55P03 -> 429 never 500; request order authenticate -> rate limit -> parse; 413/400 paths; logging (error kind only, bodies skipped); ADR-018/019/020; erasure covers both tables in FK order; docs match code; no dead code.

---

# Code review, cycle 2 delta: server-side-key-backup

Reviewer: nebu-code-reviewer (read-only, static; mix/Postgres unavailable in its sandbox). 0 MAJOR, 4 MINOR, 6 INFO. Every cycle-1 and Kassandra cycle-1 finding closed in code (budget 64 MiB, try-lock in all 5 store writers / 9 routes, read gate + buckets, decoded-segment skip, runbook SQL, normalizer `:version`). RoomKeysReadGate verified correct (monitor on caller, `after` release, DOWN, double release no-op, timeout + `{:cancel, pid}`, not-running -> overflow -> 429).

## MINOR
1. Story cycle-1 bullets (docs/stories/e2ee-client-support/server-side-key-backup.md:70, 71) not marked SUPERSEDED (write burst 30, bulk burst 10, version GETs unlimited, 256 MiB). Prefix "SUPERSEDED (cycle 2)"; room_keys_docs_test.exs:187 pins the "256 MiB" text: adjust with the label.
2. Stale prose: http_room_keys.ex:19 ("could not get the per-user lock in time" -> "found it busy or a row lock timed out"); http_room_keys.ex:29-30 omit the slot and the version bucket; 000058_room_key_backup.up.sql:48 "markers are never pruned" -> "automatically; an operator prunes via the runbook".
3. No unit test for RoomKeysReadGate (MemberSliceGate has member_slice_gate_test.exs): add (cancel branch, acquire timeout, gate not running -> overflow, double release).
4. 11-risks.md:31 records only the read-side peak: add the write-side peak (5 MiB body ~25 MiB decoded, burst 5 per account ~125 MiB per account, no per-node write cap) and the accepted residual; record two accounts with slow readers holding both node bulk slots until Bandit's send timeout (Kassandra cycle-2 #1, #2).

## INFO
1 gate loses state on restart (cap can be exceeded transiently; no boot/invalid-seam warning unlike MemberSliceGate); 2 cap 2 + open registration = cross-user availability coupling, list in risks; 3 try-lock key shared with AccountDataStore.put / CrossSigningKeyStore.put_keys / erasure (blocking lock): concurrent Element setup can get 429 on PUT /room_keys/*, fixed retry_after_ms 1000; 4 pruned marker number's DELETE answers 404 (runbook should say so); 5 128 B per row does not model row overhead (0.3-0.5 KiB) nor gzip; "x2.5" is an order of magnitude; 6 08-concepts per-user tier table (~l.456-464) does not list the three room_keys tiers; 07-deployment.md:1029 ambiguous sentence; application.ex:177 no comment for the new gate child.
