# ADR-028: Compliance Visibility of Scan Events (Audit-Log Bridge)

## Status

Accepted - 2026-07-06

Part of: Epic `media-security-admin-control`. Formalizes a decision already made and
referenced throughout that epic's stories (4c, 6, 6d).

## Context

`media_state_transitions` (ADR-031) is the authoritative, append-only, per-file
history of every state change. It is not, however, the surface compliance officers or
auditors use — that is the global `audit_log` (`AuditLogLive`). Some media events are
compliance-relevant beyond their own file's history: a malware detection, a scan
failure that required admin attention, and every admin action on media (block, delete,
override, bulk actions) needs to be discoverable from the same place as every other
audited action in the system.

## Decision

**System-driven** scan events with compliance relevance (`:infected`, `scan_failed`)
and **all admin actions** on media (Story 6, including override and bulk actions) write,
**in addition to** their `media_state_transitions` entry, a corresponding entry into the
global `audit_log`. Routine, non-compliance-relevant transitions remain exclusively in
`media_state_transitions`.

**Deliberately unresolved interface point:** `media_files` has no `room_id` column. A
future "compliance report per room" feature will need a query-time join:
`audit_log.target_id (= media_id)` → `events.content @> '{"url": "mxc://..."}'`. This ADR
fixes that join as the contract for such a future story, and reserves the audit action
`compliance_export_downloaded` for it. This ADR does not build the report — only the
data contract it will rely on.

**Batch-cohort contract (Story 6d, Review 7):** bulk actions capture their justification
**once** but write **per-file** `audit_log` entries (never one collective entry), each
stamped with a shared `batch_id`. The decision is recorded once; the effect remains
discoverable per file — and therefore per room, via the join above. A file must never
disappear from a per-room compliance report merely because it was part of a batch.

## Consequences

### Positive
- A single, predictable rule ("compliance-relevant + admin actions bridge to
  `audit_log`") that every story implementing a media action can follow without
  reinventing the bridging logic.
- The `batch_id` contract keeps bulk actions from becoming an audit blind spot.

### Negative / risks
- Two parallel logs (`media_state_transitions` and `audit_log`) for the same event in the
  compliance-relevant cases is some duplication, accepted because the two logs serve
  different consumers (file-level history vs. cross-domain compliance search).
- The room-join is query-time and not indexed by this epic — a large `events.content`
  scan without care could be slow; left as a follow-on concern for whichever epic builds
  the actual report UI.

## Implementation Note (Story 4c, landed 2026-07-14)

Story 4c implemented the `:infected`/`scan_failed` half of this ADR's decision against
`Nebu.Workers.MediaScanWorker`'s real, already-landed code (Story 4b), not the story's own
pre-4b draft prose. Two corrections worth recording for future stories following this same
pattern (6a–6d, admin actions on media):

- **No separate Oban `discard/2` callback exists.** The exhausted-retries path lives inside
  the worker's own private `scan_error/4`, in its `attempt >= max_attempts` branch, which
  itself returns `{:discard, reason}` to Oban. The audit-bridge call sites are `infect/2`
  (the `{:ok, {:infected, sig}}` branch) and that `scan_error/4` branch — not a distinct
  callback function.
- **`Nebu.Media.DB.lookup_for_scan/1` did not originally return `filename`/`file_hash`/
  `uploader_user_id`** (only the crypto/compression fields Story 4b needed). Story 4c
  extended that one query (already keyed by `media_id`) with those three columns rather than
  adding a second lookup function, since the audit metadata (AC4/AC5 of 4c) needs exactly
  the same key. Both new audit actions (`media_infected_detected`, `media_scan_failed`) were
  added to `AuditWriter.@known_actions` in the same commit, with a direct regression test
  (`AuditWriterMediaActionsTest`) proving the allowlist addition — the addition was verified
  live by temporarily reverting it and confirming the regression test fails loudly.

## Related

- Epic `media-security-admin-control`, Stories 4c, 6a–6d.
- ADR-031 — DB-Level Immutability for `media_state_transitions`.
