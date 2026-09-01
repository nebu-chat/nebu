# ADR-025: Oban for the Async Malware-Scan Queue

## Status

Accepted - 2026-07-06

Part of: Epic `media-security-admin-control`. Formalizes a decision already made and
referenced throughout that epic's stories (4b, 7, 8a/8c, 10a, 13c).

## Context

Malware scanning is I/O-bound (TCP round-trip to clamd) and must not block the upload
request/response cycle. Every upload transitions to `:quarantined` and needs a scan job
that survives node restarts, retries with backoff on transient failure, and is observable.

Additionally, async-upload reservations (Story 2a) create `:reserved` rows with a TTL; stale
reservations must be periodically reaped so they don't accumulate against the per-user pending quota.

Two options were evaluated:

- **Oban:** Postgres-backed job queue. Jobs persist across node restarts, support
  exponential backoff, dead-letter (`discard/2`) semantics after `max_attempts`, and
  Oban Web gives operational visibility into the queue.
- **A bespoke GenServer-based queue:** no new dependency, but jobs live only in process
  memory — a node restart during an active scan silently loses the job, there is no
  built-in retry/backoff, and there is no monitoring surface without building one.

## Decision

Nebu uses **Oban** for the async scan queue (`Nebu.Workers.MediaScanWorker`) and for every
other cron/background job introduced by this epic (`Nebu.Workers.MediaReservedUploadCleanupWorker`,
`MediaArchiveWorker`, `MediaLifecycleWorker`, the scan-stats rollup, the webhook
notification job).

Configuration: `max_attempts: 5`, `backoff: :exponential`, `Oban.Plugins.Lifeline` with
`rescue_after` set comfortably above the maximum expected scan duration (30–60 minutes),
so a crashed node's orphaned jobs are rescued rather than stuck. After `max_attempts` is
exhausted, `discard/2` transitions the job to a terminal state (e.g. `scan_failed` for
scan jobs, or logged non-op for idempotent cleanup crons). Cron jobs (e.g. the cleanup
worker) use `Oban.Plugins.Cron` with `crontab:` config entries.

## Consequences

### Positive
- Scan jobs survive node restarts and Oban retries transient clamd/network failures
  automatically — no bespoke retry logic to write or maintain.
- Oban's dead-letter path (`scan_failed`) gives a clean, observable terminal state instead
  of a silently stuck or lost job.
- Cron jobs (cleanup workers, garbage collection tasks) survive node restarts and run
  on a predictable schedule without needing a separate time-based event loop.
- The same infrastructure serves every other async job this epic introduces, avoiding a
  second queueing mechanism.

### Negative / risks
- Adds a Postgres-backed dependency (Oban tables) to the schema; acceptable since Nebu is
  already Postgres-centric (ADR-018, ADR-019) and Oban does not require an external
  service (no Redis, consistent with ADR-002).
- Job throughput is bounded by Postgres row-locking semantics under very high burst load;
  out of scope for this ADR, tracked as a load-testing concern in the epic's test design.
- Raw SQL migrations required: this project's Nebu.Release raw-SQL-only migration runner
  (ADR-018) cannot directly call `Oban.Migration.up/1`, so all Oban-related schema must be
  hand-translated from Oban's ecto-generated SQL into numbered .sql files (Story 2e
  establishes this pattern; subsequent stories follow it).

## Lifecycle Note

**Story 2e (Media Reserved Upload Cleanup Cron) was the first ADR-025 implementation to land
(2026-07-14),** ahead of Story 4b's scan worker. The cleanup cron proves the Oban
infrastructure and migration pattern, validating core design assumptions before the heavier
scan-queue integration.

**Story 4b (MediaScanWorker) landed 2026-07-14,** adding only the `media_scan` queue entry to
the already-bootstrapped `config :nebu, Oban` block (no second migration, no second dependency
bump, no second supervisor child) — confirming this ADR's own framing that 2e's bootstrap is a
one-time cost every subsequent Oban-based story amortizes. `Nebu.Media.ScanEnqueue` was also
wired from its pre-4b no-op stub to a real `Oban.insert/1` call, the first genuinely
HTTP-adjacent trigger of a background job in this codebase (Kassandra security review:
APPROVED, 0 CRITICAL/HIGH/MEDIUM).

## Related

- Epic `media-security-admin-control`, Stories 2e (cleanup cron), 4a–4c, 7, 8a, 8c, 10a, 13c.
- ADR-002 — No Redis / No NATS (Oban avoids introducing either).
- ADR-018 — No Domain Model / Inline SQL (migrations).
