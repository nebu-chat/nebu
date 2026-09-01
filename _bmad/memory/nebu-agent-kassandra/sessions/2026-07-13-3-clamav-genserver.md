# Session 2026-07-13 — media-security-admin-control / 3-clamav-genserver

Security review of the ClamAV INSTREAM TCP client (`Nebu.Media.ClamAV`), the low-level
scanner boundary for the media malware-scan pipeline. Story `security_review: required`.

## Verdict: APPROVED — no CRITICAL/HIGH.
Report: `docs/stories/media-security-admin-control/security-reports/3-clamav-genserver-security-review-2026-07-13.md`

## Findings
- **F-1 MEDIUM** — `recv_until_null/3` (clamav.ex:248-271) has NO cap on the accumulated
  reply buffer. Timeout is per-iteration not cumulative, so a compromised/buggy clamd
  streaming continuous non-null bytes (each arriving within recv_timeout) grows the
  GenServer heap unbounded → OOM the whole single BEAM node (Matrix+admin+media). Prior
  code-review cycle-1 saw it and dismissed as "clamd is trusted self-hosted infra" — the
  exact framing error pattern #81 warns against. Fix: cap accumulator (replies <64B), fail
  closed on exceed.
- **F-2 LOW** — scanned (attacker) binary is the current `handle_call` message; any raise
  inside handle_call dumps it into OTP/SASL crash reports → AC9 bypass via a vector AC9's
  per-Logger impl never considered. Concrete (config-gated) trigger: `connect/1` non-total
  (matches only {:tcp}/{:unix}). Fix: total connect + `Process.flag(:sensitive, true)` in
  init/1 (redacts mailbox+state from crash reports/tracing/observer).
- **F-3 LOW** — single named GenServer, no pool: slow/hostile clamd (scan-time-bomb archive)
  serializes/stalls ALL node media scanning ~2×(connect+recv) per call. By-design ("S");
  bounded by Oban concurrency + call timeout. Mitigations → Story 4b. Compounds F-1.
- **F-4 LOW** — docker-compose publishes unauthenticated clamd on host `3310:3310`. clamd
  has a SHUTDOWN verb — unlike postgres/minio it's an unauthed CONTROL plane, so the "same
  as 5432/9000" defense the prior review gave is wrong. Bind loopback / drop the mapping.
- **F-5 INFO** — AC4 ceiling is the LAST line not the first: scan_binary receives an
  already-fetched+decrypted+DECOMPRESSED binary → a decompression bomb has already expanded
  in Story 4b memory before this gate. Hand-off: 4b MUST gate size BEFORE fetch/decrypt/
  decompress and bound decompression output.
- **F-6 INFO** — FOUND signature interpolated raw (vs inspect on error path); single-line
  (regex `.` excludes \n → no log-line injection), clamd-DB-derived (no content leak).
  Cosmetic: prefer inspect(signature).
- **F-7 INFO** — verify/align clamd StreamMaxLength with the 100MB ceiling (operational;
  mismatch → mid-stream INSTREAM-size-limit abort on files between the two limits).

## Clean confirmations (independent adversarial trace)
- INSTREAM byte-length framing CANNOT smuggle protocol commands: length prefix is always
  exactly `byte_size(chunk)`, so embedded `<<0,0,0,0>>` in payload is consumed by clamd as
  stream data, never as a length/command. Only terminator is the client-sent `<<0::32>>`.
- AC4 gate is first + O(1); the 100MB binary is a refc-binary passed by reference across
  GenServer.call (no copy/doubling).
- No raise on any :gen_tcp failure (connect refused/timeout, mid-send, recv timeout, peer
  close, malformed reply) → all tagged tuples. call_timeout budgets 2×(connect+recv)+2000
  (cycle-1 M1 fix, re-verified 5000/30000ms).
- Reconnect bounded to exactly 2 cycles, gated on had_socket? + :connection_closed only
  (not bare :timeout) → no hot-loop.
- AC9 own-Logger path clean (marker test passes); error reasons via inspect (newlines
  escaped). No secrets introduced (clamd unauthed by protocol). active:false → no
  unsolicited tcp msgs, no handle_info/cast surface. Fake server cleans up all procs.

## Pattern harvested → MEMORY #85
"Self-hosted" ≠ "output trusted" for a component deliberately fed attacker bytes; and OTP
crash reports are an AC9/no-content-in-logs bypass channel per-Logger redaction never
closes (Process.flag(:sensitive,true) is the structural fix).
