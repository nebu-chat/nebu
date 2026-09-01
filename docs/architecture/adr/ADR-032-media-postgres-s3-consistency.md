# ADR-032: Persistence Consistency Between PostgreSQL and S3 for Media Deletes

## Status

Accepted - 2026-07-06

Builds on: ADR-013 (MinIO Object Storage), NFR-C3/NFR-C4 (PRD — runtime data in
PostgreSQL, media binaries in S3-compatible object storage). Closes a gap flagged in
the `media-security-admin-control` UX decision log (D8: "an ADR will record this") that
had not been fulfilled as of Review 7. Raised in the Review 8 party-mode round (Winston).

## Context

Nebu's persistence architecture (NFR-C4) splits media across two systems: PostgreSQL
holds the `media_files` row (state, metadata, `storage_key`), while the actual encrypted
bytes live in S3/MinIO. Every delete-family operation this epic introduces — hard-delete
(Story 8a), archive-tier copy (Story 8c), the consolidated lifecycle engine (Story 13c),
and two-eyes physical deletion (Story 13d) — must therefore perform **two writes across
two systems** to fully execute a delete: remove the S3 object, and null out
`storage_key`/`uploader_id` in the DB row.

Without an explicit, shared strategy, each of these four stories (built independently,
likely by different pipeline runs) would be free to invent its own ordering and failure
handling. A crash between the two writes can produce one of two failure modes:

1. **DB says deleted, S3 blob still exists** — an orphaned blob. Storage waste, but not a
   compliance violation on its own: nothing references it, nothing serves it (the
   download handler already denies on state, ADR-026), and it can be swept later.
2. **S3 blob is gone, DB row still shows a `storage_key`** — a dangling reference. Worse:
   any code path that trusts `storage_key IS NOT NULL` (the storage-usage counter in
   Story 6b, the "N files affected" warning in Story 11b, a future download attempt) now
   observes a lie about what actually exists in the object store.

## Decision

Every delete-family operation follows this ordering:

1. **Mark intent in Postgres first:** set the terminal timestamp field (e.g.
   `hard_deleted_at = NOW()`, `state = :hard_deleted`) while `storage_key` is **still
   populated**. This is the durable, transactional record that "this object is being
   deleted."
2. **Delete the S3 object.**
3. **Null out `storage_key` (and `uploader_id`) in Postgres**, completing the DB-side
   compliance record (ADR-030's invariant: the `media_files` row is never deleted, only
   the storage-referencing fields are nulled).

A crash between steps 2 and 3 leaves the row in a **recognizable, idempotently-repairable
intermediate state**: `hard_deleted_at` is set but `storage_key` is still non-null. A
reaper job (run as part of the existing lifecycle cron infrastructure, Story 13c) detects
rows in this intermediate state older than a short grace window and completes step 3
**without re-attempting step 2** (the object is presumed already deleted — re-issuing a
delete against a non-existent S3 key is a safe no-op regardless, but the reaper does not
depend on that for correctness).

This ordering deliberately accepts failure mode 1 (an orphaned blob, swept by the
reaper) over failure mode 2 (a dangling DB reference) — an orphaned blob that nothing
can reach is a storage-hygiene issue; a DB row that lies about what exists in the object
store is a data-integrity issue that can propagate into compliance-facing surfaces
(storage counters, "test connection" warnings, audit records).

The same ordering applies uniformly to Stories 8a, 8c (archive copy: copy-then-verify
before any primary-object deletion, `archive_delete_from_primary`), 13c, and 13d — none
of these stories may invent a different sequence.

## Consequences

### Positive
- One documented, testable ordering that every delete-touching story implements
  identically — no divergent behavior between work packages built independently.
- The reaper job is simple: it only ever completes an already-started deletion, never
  decides whether to start one.

### Negative / risks
- Requires every delete-family story to implement (or call into a shared helper for) the
  two-step DB write plus the intermediate-state check — a shared `Nebu.Media.Storage`
  function is the intended implementation seam, not ad hoc SQL per worker.
- The reaper introduces a small window (the grace period) during which a fully-deleted
  object's DB row is in the intermediate state. This is intentional and bounded, not an
  open-ended inconsistency.
- Does not by itself address a **backup/restore** producing an inconsistent
  cross-system state (a DB snapshot and an S3 snapshot taken at different times can
  disagree after a restore) — that is a distinct concern, addressed by the
  restore-reconciliation procedure added to ADR-030 in Review 8 (Offene Entscheidung #11).

## Related

- Epic `media-security-admin-control`, Stories 8a, 8c, 13c, 13d.
- ADR-013 — MinIO Object Storage.
- ADR-030 — Media Lifecycle Rules & Two-Eyes Delete (Restore-Verfahren section, Review 8).
- ADR-031 — DB-Level Immutability for `media_state_transitions`.
