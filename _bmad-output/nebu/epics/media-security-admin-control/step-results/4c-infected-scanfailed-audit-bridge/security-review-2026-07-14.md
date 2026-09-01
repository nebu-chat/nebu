## Security Review — media-security-admin-control/4c-infected-scanfailed-audit-bridge

**Diff scope:** `server/lib/nebu/workers/media_scan_worker.ex` (new `write_audit/4` +
`audit_enrichment/1` + `audit_writer/0` seam + `@audit_actor`, called from `infect/2` and
`scan_error/4`'s `attempt >= max_attempts` branch), `server/lib/nebu/compliance/audit_writer.ex`
(`@known_actions` += `media_infected_detected`, `media_scan_failed`), `server/lib/nebu/media/db.ex`
(`lookup_for_scan/1`'s SELECT extended with `filename`, `file_hash`, `uploader_user_id`), plus
3 new test files (`audit_writer_media_actions_test.exs`, `media_scan_worker_audit_bridge_test.exs`,
`media_db_lookup_for_scan_test.exs`). No new migration, no new table, no new endpoint.

**Date:** 2026-07-14

### Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| 1 | LOW | `media_scan_worker.ex` `scan_error/4`, `write_audit(..., %{reason: inspect(reason)})` | `inspect(reason)` on a raw `ExAws`/`Nebu.Media.Storage.get/1` error term is written verbatim into `audit_log.metadata` — a broader-visibility compliance surface than `media_state_transitions`, which already carries the identical string (Story 4b's own pre-existing `%{reason: inspect(reason)}` write). If a storage/S3 client error term ever embeds connection details (this codebase's own `Nebu.Admin.MediaSettingsController` "test connection" feature demonstrably constructs error terms containing `user:pass@host`-shaped URLs for a *different* code path), it would now also land in the wider-audience audit trail, not just the per-file ledger. | Not a new exposure class (accepted already for `media_state_transitions`), but widens its reach. If/when a compliance-export or audit-log-detail view starts surfacing `metadata` content (today's `AuditLogLive` does not — verified, its SQL only selects `event_time/actor_user_id/action/target_type/target_id/outcome`, no `metadata`), redact/allowlist `reason` before rendering rather than raw `inspect/1`. |
| 2 | LOW (advisory, no current sink) | Forward-looking — `metadata.filename`/`clamav_signature`/`reason` | `filename` is attacker-influenced (unsanitized `?filename=` query param, per 2b). No current code serializes `audit_log.metadata` to CSV/spreadsheet, so no CSV/formula-injection sink exists today. | Flagging forward only (same pattern as 4a's own review flagging `MediaScanWorker.discard/2` forward to this story): when a `compliance_export_downloaded` feature is implemented, neutralize leading `=`/`+`/`-`/`@` in any metadata value written to a CSV/XLSX export. |

### Detail

**Finding #1 — `inspect(reason)` widens (does not create) an existing potential secret-adjacent leak surface** [LOW]
`scan_error/4` already wrote `%{reason: inspect(reason)}` into `media_state_transitions.metadata`
before this story (Story 4b, unchanged). This story adds the identical value to `audit_log.metadata`
via the new `media_scan_failed` action. `audit_log` is explicitly described (this story's own
Summary) as "the surface compliance officers and auditors actually use," a broader/different trust
boundary than the per-file ledger. Today's only consumer, `Nebu.Admin.AuditLogLive`, does not select
or render `metadata` at all (confirmed by reading its `@sql` and `~H` template — no `metadata` in
either), so there is no active render-time exploit path right now. Recorded as a LOW watch-item, not
blocking: the underlying value is already accepted at the `media_state_transitions` sink, and no new
sink reads `audit_log.metadata` yet.

**Finding #2 — CSV/export-injection is a future concern, not a present one** [LOW / advisory]
`filename` reaching `audit_log.metadata` is new (this story). It originates from an unsanitized
upload-time query parameter (Story 2b). No compliance-export code path exists yet in this codebase
(grepped for `compliance_export`/`ExportController` — only the `compliance_export_downloaded` action
name exists in the allowlist, no implementing module). Flagged forward for whichever future story
implements that export, per the same "flag forward, don't block on unimplemented code" precedent
Story 4a's own review set for `MediaScanWorker.discard/2`.

### Checks performed (clean)

- **SQL injection**: all writes go through `Ecto.Changeset` + `Repo.insert!`/parameterized
  `Ecto.Adapters.SQL.query` — `metadata` is bound as a typed `:map`/JSONB parameter, never
  string-interpolated. Clean.
- **Public-API bypass (ADR-020)**: `Nebu.Workers.MediaScanWorker` calls only
  `Nebu.Compliance.AuditWriter.log/6` — no direct `Repo.insert`/`AuditLogEntry` construction from
  `Nebu.Media`/`Nebu.Workers`. Clean.
- **Allowlist regression (this epic's recurring footgun)**: `media_infected_detected` and
  `media_scan_failed` are present in `@known_actions`; verified live — temporarily reverted both
  entries, confirmed `AuditWriterMediaActionsTest` goes RED with `{:error, :audit_unknown_action}`,
  restored, re-verified GREEN (1856 passed / 0 failed). Clean.
- **Actor spoofing**: `@audit_actor "system:media_scan_worker"` is a compile-time literal, not
  influenced by any request/job input. Clean.
- **Audit-write-failure abuse as evidence suppression**: `write_audit/4` cannot be selectively
  triggered to fail by an external actor — the only failure mode is `Nebu.Repo` being unstartable
  (caught, logged, degrades to `{:error, :audit_write_failed}`), which would equally break the
  `media_state_transitions` write in the same code path (not a new selective-suppression primitive;
  pre-existing architectural trade-off, already documented in `AuditWriter`'s own moduledoc/error
  policy for its other system-driven callers). Clean.
- **`room_id` omission (ADR-028, AC7)**: confirmed by direct test assertion on both `:infected` and
  `:scan_failed` metadata. Clean.
- **New DB exposure via `lookup_for_scan/1`'s 3 added columns**: function is `defp`-adjacent in
  usage (private DB module function, no new HTTP/API caller), only consumed by the worker itself.
  No new externally-reachable read path. Clean.
- **XSS**: `AuditLogLive`'s `~H` template only interpolates `event_time`/`actor`/`action`/`target`/
  `outcome` via HEEx's auto-escaping `{...}`, no `raw/1` calls, and does not currently select
  `metadata` at all. Clean (moot for this diff, since metadata isn't rendered anywhere yet).
- **Secrets in source**: no hardcoded credentials in any new/changed file. Clean.

### Summary

CRITICAL: 0 — block commit
HIGH: 0 — block commit
MEDIUM: 0
LOW: 2 — advisory, both forward-looking/non-blocking (see Detail)

**Verdict:** APPROVED
