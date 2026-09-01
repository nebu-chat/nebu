# Security Review — media-security-admin-control / 3-clamav-genserver

**Reviewer:** Kassandra (adversarial security review)
**Date:** 2026-07-13
**Diff scope:** New/staged files — `server/lib/nebu/media/clamav.ex` (new GenServer, TCP INSTREAM client), `server/lib/nebu/media/supervisor.ex` (new child supervisor), `server/lib/nebu/application.ex` (`media_children/0`), `server/config/config.exs`, `server/config/runtime.exs`, `server/config/test.exs`, `docker-compose.yml` (new `clamav` service), `server/mix.exs`, `server/test/test_helper.exs`, `server/test/nebu/media/clamav_test.exs`, `server/test/nebu/media/clamav_fake_server.exs`.
**Story:** 3 — the low-level scanner boundary. `Nebu.Media.ClamAV.scan_binary/1` sends an in-memory, already-decrypted-and-decompressed binary to clamd over `:gen_tcp` (INSTREAM) and returns clean/infected/error. Consumed by the future Story 4b `MediaScanWorker`.
**Relevant ADRs:** ADR-024 (self-hosted ClamAV — no file content/hash leaves the deployment, DSGVO), ADR-021 (pure Elixir — no NIF, no shell-out).
**Independence note:** I performed my own adversarial trace of every path. The prior two code-review cycles (both non-security, fresh-context) passed CLEAN; I concur on the functional side but I re-weight one item the cycle-1 review explicitly dismissed as "clamd is trusted self-hosted infrastructure" (F-1 below) — that dismissal is exactly the framing error my memory pattern #81 warns against.

---

## Verdict: APPROVED — no CRITICAL/HIGH. Commit not blocked.

The wire protocol is implemented correctly and safely. The INSTREAM byte-length framing cannot be used to smuggle protocol commands (F-INFO-A). The file-size ceiling (AC4) fires before any TCP connection. Every `:gen_tcp` failure mode returns a tagged error, never a raise. The auto-reconnect/retry path is bounded at exactly two attempts and cannot hot-loop. AC9 (no scanned content in this module's own log calls) holds — the payload is never in a reply and is never interpolated into a `Logger` statement.

The findings are all defense-in-depth against a **compromised or buggy clamd** — which is not a hypothetical: clamd is, by design, the process fed attacker-controlled malware bytes, and its archive/PE parsers have a real CVE history (memory pattern #81). One **MEDIUM** (unbounded reply buffer → node-wide OOM), three **LOW**, three **INFO**. None block, but the MEDIUM should be fixed before the epic ends and several items are hand-offs to Story 4b.

---

## Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| F-1 | MEDIUM | `clamav.ex:248-271` (`recv_until_null/3`) | Unbounded reply-buffer accumulation. A compromised/buggy clamd that streams bytes without ever sending `<<0>>` (and without stalling a full `recv_timeout`) keeps `recv` returning `{:ok, data}` → buffer grows without bound → OOM of the single ClamAV GenServer → the whole BEAM node (Matrix API, admin, media) dies. clamd is the exact component fed attacker bytes. | Cap the accumulator (clamd replies are <64 bytes; cap at e.g. 4 KB–64 KB). On exceed: `close_socket` + return `{:error, :reply_too_large}` (or `:connection_closed`). |
| F-2 | LOW | `clamav.ex:108` (`handle_call`) + `connect/1` non-total | Scanned content can leak into OTP/SASL **crash reports**. `handle_call({:scan_binary, bytes}, …)` holds the full (attacker-controlled) binary as its current message + in flight; any raise inside dumps message+state to the crash log, defeating AC9 via a vector AC9's implementation never considers. Concrete (config-gated) trigger: `connect/1` matches only `{:tcp,…}`/`{:unix,…}` — any other `address` shape raises `FunctionClauseError`. | (a) Make `connect/1` total (catch-all → `{:error, :bad_address, state}`). (b) `Process.flag(:sensitive, true)` in `init/1` — redacts this process's mailbox+state from crash reports, tracing, and observer. Strong, cheap hardening for a process whose entire job is holding attacker bytes. |
| F-3 | LOW | `clamav.ex` (single named GenServer, no pool) + `docker-compose.yml` clamd | Node-wide scan serialization DoS. One process serializes every scan; each occupies it up to ~2×(connect+recv). A crafted archive that makes clamd slow (scan-time bombs are real) stalls **all** media scanning node-wide. Self-limiting (bounded by Oban concurrency + per-call timeout) and it is the epic's intended "S" sizing, so LOW/by-design — but compounds F-1: one wedged connection is the whole DoS surface. | Accepted design; hand to Story 4b: cap Oban scan concurrency, enforce an upload-time size gate, treat scan latency as expected. Revisit pooling if throughput matters. |
| F-4 | LOW | `docker-compose.yml:242-243` | clamd published on the host as `3310:3310`. clamd has **no authentication**; publishing its control socket on `0.0.0.0:3310` lets any local (or, if the host is exposed, remote) process issue clamd verbs — incl. `SHUTDOWN` (DoS the scanner) or use it as a scan oracle. The `server` reaches clamav over the compose network by service name, so the host publish is unnecessary. (Prior review called this "consistent with postgres 5432 / minio 9000" — but those are not unauthenticated control planes with a SHUTDOWN verb.) | Drop the host port mapping, or bind `127.0.0.1:3310:3310`. Dev-stack only (prod uses `NEBU_CLAMAV_HOST`) → LOW. |
| F-5 | INFO | `clamav.ex:108-109` (AC4 gate) | The size ceiling is the **last** line, not the first, against memory/decompression-bomb DoS: `scan_binary/1` receives an already-in-memory, already-decrypted-and-decompressed binary. A zip/decompression bomb has already expanded in Story 4b's memory before this ceiling is consulted. The check here only prevents oversized data reaching clamd. | Hand-off: Story 4b MUST enforce the ceiling **before** fetch+decrypt+decompress and bound decompression output. This module's ceiling does not protect node memory. |
| F-6 | INFO | `clamav.ex:349-351` | FOUND signature interpolated raw into the log (`… infected (#{signature})`) vs the error path's `inspect(reason)`. Signature is single-line (regex `.` excludes `\n`, so no fake-log-line injection) and clamd-DB-derived (not file content, so no AC9 content leak) — but a compromised clamd could embed ANSI/control chars. | Prefer `inspect(signature)` for symmetry with the error path. Cosmetic hardening. |
| F-7 | INFO | clamd config vs `max_file_size_bytes` | If the `clamav/clamav:stable` image's `StreamMaxLength` is below the 100 MB ceiling, files between the two limits pass Nebu's gate, stream to clamd, and clamd aborts mid-stream ("INSTREAM size limit exceeded") → `connection_closed` → wasted bandwidth + confusing errors. Operational, not security. | Verify and align clamd `StreamMaxLength` with `max_file_size_bytes` (document for Story 4b/9). |

---

## Detail

### F-1 — Unbounded reply-buffer accumulation → node-wide OOM [MEDIUM]

`recv_until_null/3` loops `:gen_tcp.recv(socket, 0, timeout)` and accumulates into `buffer` until a `<<0>>` byte appears. The timeout is per-iteration, not cumulative (correct for latency, but load-bearing here): as long as clamd delivers *some* bytes within each `recv_timeout` window, `recv` returns `{:ok, data}`, the loop continues, and `buffer` grows with no upper bound. A clamd that has been driven into a bad state by a crafted upload — the precise threat this whole architecture exists to contain — streaming continuous non-null bytes will grow the ClamAV GenServer's heap until the BEAM is OOM-killed. Because this is the single OTP node serving Matrix, admin, and media, that is a full-service outage, not a scoped failure.

The cycle-1 code review saw the same code path and recorded it as INFO with the note "theoretical only, clamd is trusted self-hosted infrastructure with a tiny fixed reply size." That is the wrong trust model for this component. Per ADR-024 clamd is self-hosted, but it is self-hosted *because it must chew on hostile input locally* — "self-hosted" means "we own the blast radius," not "we trust its output." The scanner is the one process in the deployment whose compromise the design explicitly anticipates (memory pattern #81), so its wire output must be treated as adversarial. The reply is a fixed tiny line in the happy path, which is exactly why a hard cap costs nothing: cap the accumulator at a small constant and fail closed on exceed.

**Why MEDIUM not HIGH:** it requires clamd to already be malicious/buggy (a second-order condition), and there is no data-disclosure or auth-bypass component — the impact is availability (node OOM). But the consequence is total and the fix is a two-line guard, so it should not ride to production as an INFO.

### F-2 — Scanned content can leak into OTP crash reports (AC9 is incomplete) [LOW]

AC9 is implemented at the granularity of *this module's own `Logger` calls* (`log_scan_outcome/2` logs size/outcome/signature only — verified, and the marker test proves it). But the process holds the full, possibly attacker-controlled malware binary as the current message of `handle_call({:scan_binary, bytes}, …)` and in `do_scan`'s stack. If any exception is raised inside that call, OTP's crash report dumps the message and state — the binary — to the logger and to the operational log store, defeating AC9 through a channel its implementation never addresses.

In the current code the only realistic raise site is that `connect/1` is non-total: it matches `{:tcp, host, port}` and `{:unix, _}` but nothing else, so a malformed `address` (operator misconfig or a future default drift) raises `FunctionClauseError` *inside* `handle_call`. Config today always supplies well-formed `{:tcp,…}` tuples, so likelihood is low — hence LOW, not MEDIUM. Two fixes: make `connect/1` total, and set `Process.flag(:sensitive, true)` in `init/1`. The `:sensitive` flag is the right structural control here — it redacts the process's message queue and state from crash reports, tracing, and observer, which is exactly the guarantee AC9 wants for a process whose entire purpose is holding attacker bytes.

### F-3 — Single serialized scanner: node-wide scan stall under a slow/hostile clamd [LOW]

One named GenServer, no pool (by design — the epic's "S" sizing). Every scan serializes; a wedged clamd holds the process for the full `recv_timeout`, and a dropped-then-reconnected scan re-sends the whole payload for a second cycle, so worst-case per-call occupancy is ~2×(connect+recv) ≈ 20 s at defaults. An attacker who can trigger scans (upload files) plus a scan-time-bomb archive (clamd can be made slow on crafted archives) stalls all media scanning on the node. It is bounded — `GenServer.call` self-limits via `call_timeout_ms()`, callers are async Oban jobs, and mailbox depth equals Oban worker concurrency — so it degrades throughput rather than crashing. Compounds F-1. Accepted as design; the mitigations belong in Story 4b (concurrency cap + upload-time size gate).

### F-4 — Unauthenticated clamd published on the host [LOW]

See table. Dev-stack only; prod points `NEBU_CLAMAV_HOST` at a network-scoped clamd. Bind to loopback or drop the mapping.

---

## What I checked and found clean

- **INSTREAM framing cannot smuggle commands.** `send_instream/2` sends `zINSTREAM\0`, then per chunk `<<byte_size(chunk)::32-big, chunk::binary>>`, then `<<0::32>>`. The length prefix is always exactly the real chunk size, so file bytes (including embedded `<<0,0,0,0>>`) are consumed by clamd strictly as stream data — there is no path for payload content to be reinterpreted as a length prefix or a new command. The only terminator is the client-sent zero-length chunk. Correct and safe.
- **AC4 size gate is first.** `byte_size(bytes) > max_file_size_bytes` is the first expression in `handle_call`, O(1), and returns before `ensure_connected`. No TCP connection on oversized input (test 3 asserts `accept_count == 0`). The 100 MB binary is a refc binary passed by reference across the `GenServer.call`, not copied — no memory doubling.
- **No raise on any `:gen_tcp` failure** (connect refused/timeout, mid-stream send failure, recv timeout, peer close, malformed reply) — every branch returns a tagged tuple. `call_timeout_ms/0` correctly budgets `2 × (connect+recv) + 2000` so the outer call cannot fire before the internal reconnect-retry completes (the cycle-1 M1 fix; re-verified at 5000/30000 ms).
- **Reconnect is bounded.** `had_socket?` gates the retry to reused (not freshly-connected) sockets, retries exactly once, and only on `:connection_closed` (not a bare `:timeout`) — no hot-loop, max two connect+scan cycles per call.
- **AC9 log content.** Payload never appears in a reply and is never interpolated into a `Logger` call; error reasons go through `inspect/1` (newlines escaped → no log-line injection from a clamd ERROR message). The one raw interpolation (F-6) is a single-line clamd-DB signature, not file content.
- **Config / secrets.** No credentials introduced (clamd is unauthenticated by protocol). `config.exs` default is the safe generic `127.0.0.1`; runtime host/port is prod/dev-only and mirrors the established `NEBU_MINIO_ENDPOINT` pattern; `String.to_integer` on a bad port fails fast at boot. `test.exs` correctly disables the Application-supervised instance (`start_clamav_client: false`). No `active: true` socket, so no unsolicited `{:tcp,…}` messages; no `handle_info`/`handle_cast` surface.
- **Test fake** (`clamav_fake_server.exs`) is a real loopback listener, cleans up its accept loop + handler tasks + agent on `stop/1`, and is registered in `mix.exs` `test_ignore_filters`. No secrets, no leakage.

---

## Summary

- CRITICAL: 0
- HIGH: 0
- MEDIUM: 1 (F-1 — fix before epic end)
- LOW: 3 (F-2, F-3, F-4)
- INFO: 3 (F-5 Story-4b hand-off, F-6, F-7)

**Verdict: APPROVED** — no commit-blocking findings. Fix F-1 before the epic closes; carry F-5 (ceiling-before-decompress) and F-3 (concurrency cap) into the Story 4b `MediaScanWorker` review as MUST-VERIFY items.

---

## RESOLUTION (same day)

F-1 and F-4 were fixed immediately rather than deferred, given both were cheap and closed a real node-wide exposure:

- **F-1 → FIXED.** `recv_until_null/3` now caps the accumulator at `@max_reply_bytes` (64 KB — generous headroom over clamd's real reply size of well under 1 KB, tiny relative to the module's own 100 MB `max_file_size_bytes` scan ceiling). Exceeding the cap returns `{:error, :reply_too_large}`, which `do_scan/2` routes through the existing `transport_error/3` path (closes and clears the socket, so the next call reconnects cleanly) — no new raise path, AC6 still holds.
- **F-4 → FIXED.** Removed the `ports: ["3310:3310"]` host publish from the `clamav` service in `docker-compose.yml`. `server` reaches `clamav` over the compose network by service name (`NEBU_CLAMAV_HOST=clamav`); no host-level access was ever required for the feature to work.

Re-verified: `clamav_test.exs` 10/10 still passing, full unit suite 1646 passed/4 skipped/0 failed (unchanged), `docker compose config clamav` parses cleanly with no `ports:` key, no new compiler warnings.

F-2, F-3, F-5, F-6, F-7 remain open as documented hand-offs (F-2/F-6 low-value hardening for a follow-up pass; F-3/F-5 explicit MUST-VERIFY items for the Story 4b `MediaScanWorker` review).
