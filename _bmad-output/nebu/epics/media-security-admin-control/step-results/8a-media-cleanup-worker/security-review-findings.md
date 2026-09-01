# Security Review (Kassandra) — 8a-media-cleanup-worker — 2026-07-19

Verdict: no CRITICAL / no HIGH. 1 MEDIUM (compliance/correctness), 2 INFO.

## F-1 — MEDIUM — the `:deleted` retention path never fires in production

The worker's `:deleted` candidate query is `WHERE state = 'deleted' AND deleted_at < NOW() - interval`,
but nothing in `server/lib/` ever populates `media_files.deleted_at`:
- Migration 000022 adds the column (nullable TIMESTAMPTZ, no default, no trigger).
- `Nebu.Media.admin_delete/2` (server/lib/nebu/media.ex:775, Story 6a) calls
  `StateMachine.transition(media_id, :deleted, {:admin, admin_id}, %{})` + an audit write — it never
  stamps `deleted_at`. Confirmed directly: `state_machine.ex`'s generic `@sql_update_state` only sets
  `state`; only the `:hard_deleted` branch has a special SQL variant that stamps a column
  (`hard_deleted_at`). There is no `:deleted` analogue.
- Repo-wide grep for a `deleted_at` writer against `media_files` found none.

Because `deleted_at` is always NULL, `NULL < x` is never true — the `:deleted` query matches zero rows
forever. Admin-soft-deleted media is never hard-deleted; bytes are retained indefinitely; the retention
policy is silently unenforced for half the worker's scope (AC1/AC3's `:deleted` half).

The sibling `:infected` path is unaffected — it derives age from the ledger
(`media_state_transitions.inserted_at WHERE to_state='infected'`), which `transition/4` genuinely
populates.

Why it passed ATDD/test-review/CI/code-review: the test FakeRepo seeds `deleted_at` directly on the
fake row and filters on it — every green test presupposes exactly the population the production
`admin_delete/2` (a DIFFERENT story, already landed) never performs. A per-story fake cannot see this
cross-story seam gap.

Failure direction is over-retain, not premature-delete (no attacker path, no data-loss) — hence MEDIUM
not HIGH — but it defeats half of this story's stated purpose.

**Fix options** (either fully resolves it):
(a) Stamp `deleted_at` at the transition-to-`:deleted` call site (mirrors how `:hard_deleted` stamps
    `hard_deleted_at`) — but this requires changing `Nebu.Media.StateMachine.transition/4`'s generic
    SQL path or adding a `:deleted`-specific branch, i.e. touching shared state-machine code other
    stories also rely on.
(b) Derive `:deleted` age from the ledger instead, exactly like the `:infected` query already does:
    `(SELECT MAX(inserted_at) FROM media_state_transitions WHERE media_id = mf.media_id AND
    to_state = 'deleted') < NOW() - interval` — no schema/other-module change, symmetric with the
    :infected query's own precedent, confined entirely to this worker's own file.

## F-2 — INFO — worker ignores AuditWriter.log/6's return value
A post-null-UPDATE audit-write failure loses the audit_log projection with no retry. Mitigated: the
authoritative immutable `media_state_transitions` ledger row is written atomically inside
`transition/4`'s own transaction and cannot be lost — only the denormalized audit_log projection can.
Consistent with the codebase-wide best-effort audit posture elsewhere. No action required.

## F-3 — INFO — reaper/completion query has no age/attribution filter
`state = 'hard_deleted' AND storage_key IS NOT NULL` with no time bound — a hypothetical future
non-worker code path that reaches this same intermediate state for a different reason would be
silently swept up. No such path exists today. Documentation-only, no action required.

## Defended angles (no findings)
- Admin-un-infect-race vs worker: defended by transition/4's row-level FOR UPDATE lock + re-read.
- Timestamp tampering: :infected age anchored to the immutable, trigger-protected ledger; bound SQL
  params; no injection surface.
- Config trust boundary: deleted_days/infected_days are static config.exs only, no admin-mutable or
  HTTP-exposed path found.
- Storage.delete/1 error handling: 404 -> :ok; every other error -> row left untouched for retry;
  never silently treated as done.
- ADR-018/ADR-020 compliance: worker only calls public StateMachine/Storage/AuditWriter APIs plus its
  own narrowly-scoped SELECTs/non-state UPDATEs.
- media_hard_deleted genuinely present in AuditWriter.@known_actions (line 107).
