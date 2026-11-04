# Security Review: server-side-key-backup (Kassandra, delta cycle 1)

Date: 2026-10-30. Scope: staged diff in worktree `open-chat-e2ee`, branch `feature/e2ee-client-support` (cycle 1). **Verdict: BLOCKED (1 HIGH).** CRITICAL 0 | HIGH 1 | MEDIUM 2 | LOW 2 | INFO 1.

| # | Severity | Location | Finding | Remediation |
|---|----------|----------|---------|-------------|
| 1 | HIGH | protected.ex:606, 666-672; room_key_backup_store.ex:64, 274-360 | CWE-400/770: one authenticated user can still OOM the node. 256 MiB budget + bulk-read burst 10 + write burst 30 exceeds the default 2g container limit. | Single-flight bulk reads per user plus a node-wide semaphore (monitor-based), or stream the response; budget around 64 MiB; write burst around 5 |
| 2 | MEDIUM | room_key_backup_store.ex:520-523 | Cycle-0 #2 only partly fixed: lock_timeout limits how long a waiter waits, not how many. A burst of 30 writes still holds all 10 pool connections for up to 2 s. | `pg_try_advisory_xact_lock`: a busy lock is an immediate 429, no waiters |
| 3 | MEDIUM | room_key_backup_store.ex:539-546 | Budget counts only octet_length(session_data/auth_data); ids (2 x 255 B) and per-row overhead uncounted; SUM scans all of the user's rows on every write. | Count ids + fixed per-row cost; running byte counter by deltas under the lock |
| 4 | LOW | protected.ex (GET version routes); store.ex:133 | `GET /room_keys/version[/{v}]` has no rate limit; each call runs count(*) over up to 100k rows. | Own light bucket |
| 5 | INFO | json_body.ex:113 | Encoded segment (`room%5Fkeys`) skips the JsonBody skip clause but still matches the routes; gets the normal 1 MB parse before auth like every other route; the 5 MiB parse is unreachable that way. | Optional: match decoded segments |
| 6 | LOW | migration 000058 | RLS USING(true) still accepted. | none |

## #1 detail
In `get_sessions` Postgrex loads every row of the version into the request process (`decode_binary: :copy`): ~256 MiB of copies. Iodata splicing avoids re-encoding, but Bandit compresses the whole `send_resp` body with `Accept-Encoding: gzip` (+~0.75x output + CPU): one bulk read ~450-700 MiB peak. A rate limit is not a concurrency limit: burst 10 lets one user run ~4 such reads at once, exhausting a 2g container (upcloud/stackit default; k8s example 1Gi). Filling the budget takes under a minute (burst 30 x 5 MiB, then 1 write/s). Writes: all 30 burst writes parse bodies before the lock, ~25 MiB each (body, decoded terms, Jason.encode! twice in size_ok and store_entries, Postgrex params) ~750 MiB. A second account doubles it; buckets are per node.
Remediation: one bulk read per user at a time (Registry/monitor-based slot, not try/after: under HTTP/2 the release can be skipped); node-wide cap on concurrent bulk reads (e.g. 2); better: Repo.transaction + stream + send_chunked; budget ~64 MiB (real megolm session_data ~0.5-1 KiB, 100k sessions ~100 MiB at most); room_keys write burst ~5.

## Verified correct
No pre-auth parse (match -> authenticate -> dispatch; unknown sub-paths, trailing/double slashes, HEAD, OPTIONS never read a body; 5 MiB parse only after auth + write limit). No IDOR (every statement filters on authenticated user_id; other user's version looks like a non-existent one). Logging (error kind only; RequestLogger excludes room_keys bodies on decoded segments; Ecto query logger off). lock_timeout transaction-local, only inside `transact`; 55P03 -> rollback -> 429. All SQL parameterised; spliced session_data only written via Jason.encode!(map) (not re-validated on read; manual DB edit could break the response: INFO). GDPR: both tables in @erased_tables, sessions first. Version-row cap incl. markers and normalizer anchor fixed. Partial index matches the queries.
