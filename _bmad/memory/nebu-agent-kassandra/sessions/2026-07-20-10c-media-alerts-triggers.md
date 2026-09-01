# Session 2026-07-20 — 10c-media-alerts-triggers security review

**Scope:** new `media_alerts` table (migration 000033) + `media_alert_severity` ENUM +
partial-unique index + `media_config_update_mutable` allowlist extension; per-minute
`Nebu.Workers.MediaAlertsCheckerWorker` Oban cron; `Nebu.Media.Alerts.list_open/0` read seam;
4 new `media_config` threshold keys; additive open-alerts rendering on existing
`/admin/media/health` LiveView.

**Verdict: CLEAN (APPROVED).** 0 CRITICAL / 0 HIGH / 0 MEDIUM / 0 LOW / 2 INFO (advisory only).

## Key checks (verified against real code, not dev summaries)
- **No RLS on `media_alerts` is CORRECT, not the recurring "missing RLS" pattern.** Verified
  the sibling operational table `media_scan_stats` (10a, 000032) also has no RLS/no trigger —
  same derived/mutable-operational class. RLS in this codebase is reserved for immutability
  enforcement (`media_config` per-key, `media_state_transitions` append-only ledger). Guardrails
  explicitly forbid modelling on audit_log. Do NOT flag operational tables' RLS absence here.
- **`media_config_update_mutable` extension = the SAFE key-scoped pattern** (opposite of the
  000045 `USING(true)` cautionary tale, MEMORY row). `ALTER POLICY ... USING (key IN (...))`
  adds 4 keys to an already-scoped allowlist; original policy has no WITH CHECK, ALTER USING
  preserves that. `.down.sql` reverts to 9a's 10-key list. 4 new keys validated as nonneg ints
  by `Config.upsert` (added to `@nonneg_int_keys`) → admin can't inject string/negative.
- **No injection:** all runtime values bound ($1..$5); only SQL interpolation is the
  compile-time constant `@sentinel_media_id "__pipeline_level__"` (logged INFO I-1). JSONB
  `condition_metadata` passed as bound map param, not concatenated.
- **No XSS:** HEEx `{alert.message}` auto-escaped; message is server-derived numerics only;
  severity is 2-value ENUM compared to literal → fixed class/role strings.
- **Auth:** no new route; `/media/health` is inside `live_session :admin, on_mount
  {Nebu.Admin.Auth, :require_admin}` (router.ex:224/257) — additive section inherits gate.
- **AC5 concurrency:** `WHERE NOT EXISTS` + `ON CONFLICT (...) WHERE resolved_at IS NULL DO
  NOTHING` on the partial unique index = correct race guard. Open rows bounded to ≤4 (all
  media_id NULL, one per type) → `list_open/0` missing LIMIT is not a DoS.
- **div-by-zero:** `failure_rate_pct/2` returns nil (no NaN/Inf) on 0 denominator.
- `media_id` TEXT-not-UUID migration fix = correctness (matches media_files PK type), no sec
  impact.

## INFO advisories (no fix)
1. I-1: keep `@sql_open_alert` sentinel interpolation constant-only (never runtime data).
2. I-2: `list_open/0` returns `condition_metadata`/`media_id` the dashboard doesn't render —
   admin-only, no leak; note for future callers.

## Pattern reinforcement
- "Missing RLS on new tables" must be triaged against the table's CLASS: compliance-ledger /
  immutable-config → RLS required; derived/operational (media_scan_stats, media_alerts) → no
  RLS is the codebase norm. Check the sibling table before flagging.

Report: docs/stories/media-security-admin-control/security-reports/10c-media-alerts-triggers-security-review-2026-07-20.md
