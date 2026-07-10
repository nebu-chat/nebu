# Enhanced-Logging Epic Security Review — SEC Gate 2 (epic-end) — 2026-07-08

## Scope
- Epic: enhanced-logging
- Base: `25e74fcd` → HEAD (`146be6d1`), feature/enhanced-logging
- Stories (12): operational-log-store, matrix-payload-debug-logging, admin-logs-monitoring-view, admin-logs-retention-settings, admin-sidebar-nesting, war-room-mode, trace-map-filter-reset-bugfix, trace-map-hierarchy, trace-map-leitstand, trace-map-node-controls, war-room-dedicated-page (+ noise-endpoint-bucketing docs)
- Method: full epic diff; all prior per-story Gate-1 verdicts re-verified against code, not trusted. Emphasis on composition surfaces that only appear at epic level.

## Findings

| # | Severity | Story(s) | Location | Vulnerability | Status |
|---|----------|----------|----------|---------------|--------|
| F-1 | MEDIUM | matrix-payload-debug-logging + operational-log-store + monitoring-view | `payload_redactor.ex` `@always_content_keys` / `request_logger.ex` `write_path_content_body?/1` | Redactor field-name list still misses `search_term` (POST /user_directory/search), `status_msg` (PUT /presence/{u}/status), and `account_data` body (PUT /user/{u}/account_data/{type}); these carry user text/PII redacted only if a field happens to match the fixed list. Leaks verbatim into `operational_logs` at DEBUG payload capture. | Carried / OPEN (advisory) |
| F-2 | LOW | trace-map-node-controls | `trace_map.ex` `configure_logging` writes `log_min_level_<route>`/`log_retention_days_<route>`; RLS family allowed by mig 000020 | Per-route keys are validated + written but not yet consumed by any emitter or pruner (display-only). Latent landmine when consumption is wired. | Carried / OPEN |
| F-3 | LOW | war-room-dedicated-page | mig 000021 `exclusive_scope` JSONB; `WarRoom` check | `validate_exclusive_scope/1` caps neither list length nor element length → O(n) scan per log event on the hot path; admin-only, session-bounded. | Carried / OPEN |
| F-4 | LOW | trace-map-leitstand/node-controls | `trace_map.ex` `node_states`/`endpoint_order` seeded from `?endpoint[]=` URL param | Per-socket key registry grows unbounded via attacker-supplied URL params; admin-only self-DoS, bounded to own LiveView process. | Carried / OPEN |
| F-5 | LOW/INFO | trace-map-leitstand (test infra) | `e2e/fixtures/db.ts` | Raw-SQL seed helper via `execSync` psql. Test-only, no server/lib coupling; preferred over a rejected test-only HTTP backdoor. | Informational |

No CRITICAL. No HIGH.

## Cross-Story Composition Analysis (the epic-level questions)

**1. The full "what can an admin cause to be logged, for how long, who sees it" matrix — composition of DEBUG payload logging + temporary capture + war-room exclusive-scope.** CLEAN with one carried MEDIUM. The decisive fact: **nothing in this epic raises the effective global `Logger.level` to `:debug`.** War-room mode confirmed does *not* raise it (it only flips the persist decision in `Handler.log/2`: `should_persist?(…) or not is_nil(war_room_id)`); per-route `log_min_level_<route>` keys are written and displayed only, never consumed to emit or prune; temporary-capture (`CaptureCache`) only participates in the persistence gate `should_persist?/2`. Therefore the request/response-body capture closure in `RequestLogger` (`Logger.debug(fn -> … end)`) fires only when an operator has set global `:debug` via console `Logger.configure/1` — there is no admin-UI or unauthenticated path to trigger payload capture. When it does fire, redaction is applied at write-time upstream, and the residual is F-1's field-name coverage gap. Because there is no in-epic escalation path to `:debug`, F-1 stays MEDIUM (not HIGH), and the leaked data is user text/PII (search queries, presence status, account_data), not credentials — credentials are covered.

**2. New endpoints + auth composition.** All new real-time routes (`/logs`, `/logs/trace-map`, `/logs/war-room`, `/logs/war-room/:room_id`) are inside `live_session :admin, on_mount {Nebu.Admin.Auth, :require_admin}`. The two new HTTP controller routes (`GET /logs/config`, `POST /logs/config/retention`) are served by `LogsController`, which declares `plug Nebu.Admin.Auth, :require_admin` at module level. No route was introduced outside the admin gate. `started_by`/`current_admin_id` are server-derived from the signed session, never params.

**3. Migration chain / RLS.** 000017→000021 extend `config_update_mutable` consistently: each re-create carries the full prior key set verbatim, then adds. The two LIKE patterns (`log\_min\_level\_%`, `log\_retention\_days\_%`, with escaped `_`) do **not** overlap the enumerated keys — e.g. `log_retention_debug_days` does not match `log_retention_days_%`. FK `operational_logs.war_room_id → war_room_sessions(id)` deferred correctly across 000017/000019. New tables (`operational_logs`, `war_room_sessions`, `admin_temporary_captures`) inherit the single-role no-RLS posture (the recurring family pattern; app-layer scoping complete).

**4. Crypto/secrets drift.** None. No new tokens/credentials/keys. The only config change is `config :nebu, Nebu.Repo, log: false` — and it is a **net security improvement**: it closes Ecto's default query logger, which prints bound SQL parameter values (including opaque access/refresh tokens bound by `MatrixSessionStore`) verbatim at `:debug` — a leak strictly worse than any plug gap and independent of `PayloadRedactor`. It is replaced by `Nebu.Repo.QueryTelemetry`, which logs only source/duration/result and never `:query`/`:params`/the raw `Exception`. Correctly placed in runtime.exs (NEBU_DB_URL-gated) to preserve `repo_children/0`'s presence invariant.

**5. Redaction pipeline under composition.** The guarantee holds at every combination point because redaction happens once, at write-time, in `RequestLogger` before any `Logger.debug/info` call. `Handler` is generic and re-derives nothing (its moduledoc SECURITY LAW verified). War-room tagging reads only `route_template` + metadata `user_id`/`device_id`, never `message`. All persistence gates (war-room override, temporary capture, route policy) decide only *whether* to persist an already-redacted entry — none widen content.

**6. e2e/fixtures/db.ts blast radius.** Test-only: `execSync` psql against `NEBU_DB_CONTAINER` for INSERT/DELETE seeding, in `e2e/fixtures/`, no import path from `server/lib`. Consistent with the rejected-HTTP-backdoor precedent.

## Closed since prior gates (re-verified against code)
- war-room-mode F-1 (MEDIUM): bounds now enforced at the trust boundary `WarRoomManager.start_session/1` (`@max_entries_bounds {10,10_000}`, `@max_duration_s_bounds {10,3_600}`), not only in the UI.
- trace-map-node-controls (MEDIUM): `configure_logging` validates `min_level` against `@ui_levels` and `retention_days` 1..90 before upsert; invalid input rejects the whole update.
- Ecto bound-param leak: closed as above.

## Follow-up
- **Required:** none (0 CRITICAL/HIGH).
- **Recommended (non-blocking):** close F-1 by extending write-time redaction to `search_term`/`status_msg`/`account_data` (prefer a route-aware `in_content?`-style treatment over growing the fixed field-name list, since Matrix's content schema is open-ended). F-2/F-3/F-4 are hardening.

## Summary
CRITICAL: 0 | HIGH: 0 | MEDIUM: 1 (carried, open, non-blocking) | LOW: 4

**Epic security gate: PASS.** Safe to merge feature/enhanced-logging → main.
