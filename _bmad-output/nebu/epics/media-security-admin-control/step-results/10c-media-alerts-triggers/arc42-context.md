## Summary

Story 10a gives the admin dashboard a `media_scan_stats` hourly rollup (throughput, average
scan duration, backlog depth, `scan_failed` error rate); Story 10b adds a live ClamAV
connection status ("up"/"down since") and freshclam signature-age reading. Both are
**passive** metrics — an admin has to be looking at `/admin/media/health` at the right moment
to notice ClamAV has been down for twenty minutes, or that the error rate has been climbing
for an hour.

This story turns those passive signals into an **active** operational alert: a new
`media_alerts` table, a periodic checker that evaluates a fixed set of conditions against
`media_config`-backed thresholds (ADR-027's existing config table, extended with this story's
own migration), opens an alert the moment a condition first crosses its threshold, and —
without any admin interaction — **auto-resolves** that same alert the moment the condition
clears. Unresolved alerts surface prominently at the top of the 10a/10b dashboard section,
additive to the existing nav attention-badges from Story 5b/7 (which flag individual
`:infected`/`scan_failed` *files*, not pipeline-level operational health).

`media_alerts` is deliberately **not** modeled like `media_state_transitions` (Story 1a,
ADR-031): it is operational/monitoring data, not a compliance ledger. Rows are opened and then
*updated in place* (`resolved_at` set) by the same periodic checker — there is no append-only
invariant, no DB-enforced immutability trigger, and no RLS-mandated insert/update-only-mutable
split modeled on `audit_log`. See Dev Agent Guardrails for the explicit contrast.

**Note on story sequencing:** at the time this story file was authored, 10a
(`10a-scan-stats-rollup.md`) and 10b (`10b-clamav-status-freshclam-age.md`) had not yet been
written as story files — only their acceptance-criteria scope exists in the epic document
(`_bmad-output/planning-artifacts/media-security-admin-control-epic.md`, "Story 10a" /
"Story 10b" sections). This story's Technical Requirements name the expected module/table
shapes those two stories are expected to produce (`media_scan_stats`, a ClamAV
status/`down_since` reader, a freshclam signature-age reader, and a dashboard LiveView at
`/admin/media/health`) based on that epic scope. The dev agent implementing 10c MUST reconcile
the exact function/module names against 10a's and 10b's actual story files (or their landed
code) once those exist — do not block on a mismatch, adapt the call sites.

## User Story

As an admin, I want the scan pipeline's own operational health (ClamAV connectivity, signature
freshness, scan backlog, and scan failure rate) to raise a visible, self-clearing alert the
moment something goes wrong — without me having to notice a degrading number on a dashboard —
so that I find out about an incident promptly and don't have to remember to manually dismiss
the alert once it's fixed.

## Dev Agent Guardrails

### `media_alerts` is operational data, not a compliance ledger — do not copy 1a/ADR-031's pattern

`media_state_transitions` (Story 1a) is a **DB-enforced append-only** table: a `BEFORE UPDATE
OR DELETE` trigger raises `SQLSTATE 23001` for every role including the owner, because it is a
compliance ledger where retroactive edits would be a tamper risk. **`media_alerts` is the
opposite kind of table on purpose.** It is operational/monitoring state: the same periodic
checker that opens a row is expected to come back a minute later and `UPDATE` that exact row's
`resolved_at`. Do **not**:
- add a `BEFORE UPDATE` trigger blocking updates to `media_alerts`,
- model its RLS policies on `audit_log`'s insert-only/update-mutable-allowlist split,
- treat "an alert row got updated" as a finding in a future security review of this story —
  updating `resolved_at` in place is the entire mechanism, not a bug.

### Do Not Change

- `media_state_transitions` / its `BEFORE UPDATE OR DELETE` trigger (1a, ADR-031) — do not
  touch, do not reuse its trigger function for `media_alerts`.
- `media_config`'s existing key catalog/defaults (9a) — this story only **adds** four new keys
  to the `media_config_update_mutable` allowlist via its own migration; it does not change any
  of 9a's original ten keys or `Nebu.Media.Config`'s validation logic for them.
- `Nebu.Compliance.AuditWriter` / `@known_actions` — opening or resolving a `media_alerts` row
  is **not** an audit-log event (it is system-internal operational monitoring, not an
  admin-attributable action or a compliance-relevant file-state change per ADR-028's scope).
  Do not add a `media_alert_opened`/`media_alert_resolved` audit action.
- The Story 5b/7 nav attention-badge logic — those badges count individual `:infected`/
  `scan_failed` **files**; this story's alerts are pipeline-level and additive, not a
  replacement or a merge of the two mechanisms.
- Do not add a manual "dismiss"/"acknowledge" admin action in this story — AC3 is explicit that
  auto-resolve-only is the full scope here; a manual override (if ever wanted) is a separate,
  unscoped future story, since it would need its own audit trail and role-gating decision this
  story's ACs do not cover.
- Do not implement the ClamAV status reader, the freshclam signature-age reader, or the
  `media_scan_stats` rollup query themselves — those are Story 10b's and Story 10a's scope
  respectively. This story only *consumes* whatever read function each of those stories
  exposes.
