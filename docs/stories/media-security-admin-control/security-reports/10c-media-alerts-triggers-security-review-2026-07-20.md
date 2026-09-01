# Security Review — 10c-media-alerts-triggers

**Epic:** media-security-admin-control
**Reviewer:** Kassandra (adversarial security review)
**Diff scope:** `git diff --staged` — new `media_alerts` table + ENUM + partial-unique index + `media_config_update_mutable` RLS-allowlist extension (migration 000033), per-minute `Nebu.Workers.MediaAlertsCheckerWorker` Oban cron worker, `Nebu.Media.Alerts.list_open/0` read seam, four new `media_config` threshold keys, cron registration, and additive open-alerts rendering on the existing `/admin/media/health` LiveView.
**Date:** 2026-07-20
**Baseline commit:** 73f36337536a76f94d911964ee619e1cab1ae9b7

## Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| — | — | — | No CRITICAL / HIGH / MEDIUM findings | — |
| I-1 | INFO | `media_alerts_checker_worker.ex:79` | SQL string interpolation of `@sentinel_media_id` module attribute into `@sql_open_alert` | Keep the interpolated value a compile-time constant only — never route runtime/user data through this seam. No action required. |
| I-2 | INFO | `alerts.ex:35` | `list_open/0` selects `condition_metadata` + `media_id` that the dashboard does not render | No action; admin-only surface, no sensitive data. Noted for future callers. |

No blocking findings. Two INFO-level hardening notes recorded for the audit trail only.

## Detail

### Attack surface reviewed

This diff is an **entirely internal monitoring feature** with no new externally-reachable input path:

- The only writer to `media_alerts` is the Oban cron worker; there is no admin-facing or Matrix-API write path to the table (AC3/Guardrails: auto-resolve-only, no dismiss/acknowledge action).
- The worker's inputs are all server-derived: admin-validated `media_config` integers, the internal `Nebu.Media.ClamAV` status/signature readers, and the internal `media_scan_stats` rollup table. No request-scoped or user-controlled data enters the worker.

### Injection — CLEAN

- **SQL injection:** every runtime value in `@sql_open_alert`, `@sql_resolve_alert`, `@sql_latest_scan_stats` (worker) and `@sql_list_open` (`Alerts`) is passed as a bound parameter (`$1..$5`) via `Ecto.Adapters.SQL.query!/3`. The single string interpolation (`ON CONFLICT (... COALESCE(media_id, '#{@sentinel_media_id}'))`) resolves a **compile-time module-attribute constant** (`"__pipeline_level__"`), not runtime data → not injectable (recorded as I-1: keep it constant-only). The migration's sentinel is likewise a literal.
- **JSONB parameter:** `condition_metadata` is passed as a bound `$5` map (Postgrex/Jason-encoded), not string-concatenated. Contents are server-built (ISO-8601 timestamps + numeric thresholds), no interpolation.
- **Path/command injection:** none present — no filesystem or shell interaction in the diff.

### Web application (XSS/CSRF) — CLEAN

- The new alerts `<section>` renders `{alert.message}` and derives `class`/`role` from `alert.severity`. HEEx `{...}` interpolation is **auto-escaped**, and `message` is composed exclusively from server-derived numerics (`trunc(minutes_down)`, `backlog_depth`, `Float.round(rate_pct, 1)`), never user- or attacker-controlled strings. `severity` is a two-value DB `ENUM` compared against a literal (`== "critical"`), so the ternary can only emit fixed class/role strings. No stored-XSS vector (contrast Epic-12 "inline Content-Type echoed back" — not applicable here).
- No new state-changing HTTP endpoint is introduced, so no new CSRF surface.

### Authentication & authorization — CLEAN

- No new route. The alerts list renders inside the **pre-existing** `live "/media/health", MediaHealthLive` route, which sits within `live_session :admin, on_mount: {Nebu.Admin.Auth, :require_admin}` (`admin/router.ex:224,257`). The `on_mount` hook gates both the static render and the websocket connect, so the additive section inherits the admin auth boundary. No soft-auth / pre-auth data path.
- No IDOR: `list_open/0` is an unparameterized, non-tenant-scoped read of a global operational table; there is no per-user resource to confuse.

### Migration / RLS — CLEAN (deliberate design, verified against precedent)

- **No RLS on `media_alerts` is correct here, not an oversight.** The MEMORY "Missing RLS on new tables" recurring pattern was checked against the actual codebase convention: the direct sibling operational table `media_scan_stats` (Story 10a, `000032`) also carries **no RLS and no append-only trigger**, precisely because it is derived/mutable operational data. `media_config` (`000023`) has RLS only because it enforces per-key immutability; `media_state_transitions` (ADR-031) has RLS + a `BEFORE UPDATE` trigger only because it is a compliance ledger. `media_alerts` is opened-then-updated-in-place operational state, matching the `media_scan_stats` precedent. The Dev Agent Guardrails explicitly forbid modelling it on `audit_log`/`media_state_transitions`. **This is an intentional, precedented choice — not flagged.**
- **GRANT is correctly narrowed:** `SELECT, INSERT, UPDATE` only (no `DELETE`) — more restrictive than `media_scan_stats`'s 4-verb grant. Companion `GRANT USAGE, SELECT ON SEQUENCE` present (satisfies the `MigrationsGrantTest` regression guard that Story 9a's F-1 established).
- **`media_config_update_mutable` allowlist extension is the safe pattern**, the opposite of the migration-000045 cautionary tale (MEMORY "Permissive RLS UPDATE without key-scope"). The `ALTER POLICY ... USING (key IN (...))` **adds** four keys to an already key-scoped allowlist; it does not widen to `USING (true)`. The original policy (`000023:28-41`) has no `WITH CHECK` clause, and `ALTER POLICY ... USING` preserves that shape, so no regression. The four new keys (`clamav_down_alert_minutes`, `signature_stale_alert_hours`, `backlog_depth_alert_threshold`, `scan_failed_rate_alert_pct`) are all benign operational thresholds appropriate for admin mutability. The `.down.sql` correctly reverts to Story 9a's original ten-key list.
- **`media_id TEXT` FK fix verified:** the dev's correction of the story's illustrative `UUID` type to `TEXT REFERENCES media_files(media_id)` matches the real `media_files` primary-key type; a `UUID`→`TEXT` FK would fail migration (PG 42804). No security impact — a legitimate correctness fix.

### Input validation / config trust — CLEAN

- The four new threshold keys are added to `@nonneg_int_keys`, so `Nebu.Media.Config.upsert/3`'s `validate_value/2` (`config.ex:324`) rejects any non-integer or negative value **before** any DB write. An admin cannot inject a string or negative threshold. Story 9a's original ten keys and their validation are untouched (Guardrails honored).
- Division safety: `failure_rate_pct/2` returns `nil` (not `0.0`, and never `NaN`/`Infinity`) on a zero denominator, mirroring `MediaHealthLive.error_rate_pct/2`. A zero/absent-data window cannot produce a spurious alert or a crash.

### Concurrency / idempotency (AC5) — CLEAN

- `open_alert/5` combines `INSERT ... SELECT ... WHERE NOT EXISTS` (sequential fast path) with `ON CONFLICT (alert_type, COALESCE(media_id, sentinel)) WHERE resolved_at IS NULL DO NOTHING` (the partial-unique-index inference) for the genuine-concurrency race. This is the correct belt-and-suspenders shape: under READ COMMITTED two racing runs can both pass `NOT EXISTS`, but the unique index forces the loser to a no-op rather than a duplicate or an error. `resolve_alert/2`'s `media_id IS NOT DISTINCT FROM $2` is NULL-safe and correctly scopes to the single open pipeline-level row per type.
- **Bounded result set:** because all four alert types use `media_id = NULL` and the partial unique index permits at most one open row per `(alert_type, sentinel)`, `media_alerts` can hold at most four open rows at any time. `list_open/0`'s missing `LIMIT` is therefore not an unbounded-result DoS vector.

### DoS / resource — CLEAN

- The per-minute cadence on the shared `:media_cleanup` queue (`max_attempts: 5`) is justified by the 5-minute default ClamAV threshold. Each run performs four bounded queries. A transient DB error raises and is retried by Oban with no security consequence. `list_open/0`'s `if Process.whereis(Nebu.Repo)` guard is a unit-test accommodation (returns `[]` without a live Repo); in production the Repo is always up, so this is graceful degradation, not a fail-open of a security control.

### Secrets / crypto — N/A

No secret handling, token comparison, or cryptographic primitive is introduced or touched by this diff.

## Epic-end note

Per the Epic-12 "per-story CLEAN reviews can stack into combined HIGH" lesson (MEMORY), this feature was also assessed for cross-story/topology interactions: `media_alerts` is a self-contained, admin-gated, internally-fed monitoring surface with no deployment-topology coupling (no new port, no external URL, no auth layer). No combinatorial risk with sibling 10a/10b/9a stories identified. Re-confirm at epic SEC Gate 2 alongside the rest of the epic.

## Summary

- CRITICAL: 0 — none
- HIGH: 0 — none
- MEDIUM: 0 — none
- LOW: 0 — none
- INFO: 2 — advisory only (I-1 keep SQL sentinel constant-only; I-2 read seam returns unrendered fields)

**Verdict: APPROVED (CLEAN)** — no blocking findings. The one migration deviation from the story text (`media_id` TEXT vs UUID) is a verified correctness fix with no security impact. The absence of RLS/append-only enforcement on `media_alerts` is a deliberate, precedented design decision (matching `media_scan_stats`), explicitly sanctioned by the Dev Agent Guardrails, and is not a finding.
