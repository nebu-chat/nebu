## Security Review — enhanced-logging / trace-map-node-controls (SEC Gate 1)

**Reviewer:** Kassandra (nebu-agent-kassandra)
**Diff scope:** staged (`git diff --staged`) — DB-backed temporary-capture manager, hot-path capture cache, migration 000020 (`admin_temporary_captures` + `config_update_mutable` RLS LIKE-family extension), Trace Map inspector logging/capture handlers, route-aware `should_persist?/2`, audit-writer action allowlist, e2e fixtures.
**Date:** 2026-07-08
**Frameworks:** OWASP Top 10, ASVS L2, CWE Top 25, STRIDE.

### Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| 1 | MEDIUM | trace_map.ex `configure_logging` (~L310-345) | Unvalidated client input (`node_key`, `min_level`, `retention_days`) persisted to dynamic `server_config` keys; bypasses the existing `logs_controller` validate_level/validate_bound (1-90 day) convention (CWE-20) | Validate `min_level` ∈ `@ui_levels` (downcased), `retention_days` ∈ retention_options keys (or 1-90 bound), and constrain `node_key` to observed endpoints before upsert |
| 2 | LOW | trace_map.ex `configure_logging` | Per-endpoint logging-policy change (min level + retention) writes NO audit entry, while capture enable/disable do (AC12 Option B) | Emit an audit entry (actor + target endpoint + changed keys); note this matches the existing unaudited global retention path |
| 3 | LOW | log_store `should_persist?/2` + capture on `/_matrix/client/v3/sync` | Feature converts transient (never-persisted) sync-endpoint logs into persisted+retained records when an admin toggles capture; sensitive-content safety is inherited entirely from upstream `RequestLogger` redaction | Confirm `RequestLogger` redaction covers sync request/response bodies (message content) before per-route capture ships broadly |
| 4 | INFO | temporary_capture_manager `cleanup_expired/0` (auto-expiry) | No audit entry on auto-expiry | Accepted: documented design; the off-window is reconstructible from the `enable_temporary_capture` entry's `expires_at` + errors-always-persist |
| 5 | INFO | e2e/fixtures/db.ts | Raw-SQL test seeding helpers | Test-only blast radius confirmed; `sqlLiteral` escapes quotes, numeric interpolation is `Math.floor`'d; not reachable from production Elixir |

### Detail

**Finding #1 — configure_logging: unvalidated input, no allowlist [MEDIUM]**
The `configure_logging` phx-change handler reads `node_key`, `min_level`, `retention_days` straight from client (admin) params and writes them into dynamic `server_config` keys (`"log_min_level_" <> target`, `"log_retention_days_" <> target`) with zero validation. `cascade_targets/2`'s satellite branch returns `[node_key]` verbatim — no check that `node_key` is an observed endpoint — so an admin can create arbitrary `log_min_level_*` / `log_retention_days_*` keys, and `min_level`/`retention_days` accept any string (e.g. `retention_days = "99999"` or `"-1"`, `min_level = "bogus"`).

Assessment against code-review concern #1: this is NOT a privilege escalation. The constructed key always carries the `log_min_level_`/`log_retention_days_` prefix; `server_config` is exact-match keyed (no path interpretation), so a crafted `node_key` like `../gdpr_retention_days` yields the distinct key `log_min_level_../gdpr_retention_days`, never `gdpr_retention_days`. The RLS `config_update_mutable` LIKE patterns use backslash-escaped underscores (`log\_min\_level\_%`) so they cannot over-match, and cannot be gamed to authorize UPDATE of any enumerated config surface. RLS correctness holds.

Current runtime impact is bounded: the per-route keys are consumed ONLY by `read_config_value/2` to populate the inspector SELECT defaults (display-only). The retention pruner uses the enumerated global keys (`log_retention_debug_days`, etc.), NOT `log_retention_days_<route>`, and `should_persist?/2` enforces off-list/capture gating independently of `log_min_level_<route>`. So there is no exploitable retention bypass today. The finding is (a) a defense-in-depth / input-validation gap that ignores the codebase's own `logs_controller.validate_level`/`validate_bound` (1-90 day) convention and the `toggle_level` handler's own `when level in @ui_levels` guard, and (b) a latent GDPR-retention landmine: the moment a future story wires per-route retention into the pruner, an unvalidated `log_retention_days_<route> = 99999` silently defeats retention limits for that route. Fix by allowlisting `min_level`/`retention_days` and constraining `node_key` at the handler.

**Finding #2 — configure_logging not audited [LOW]**
`enable/disable` capture correctly write `enable_temporary_capture`/`disable_temporary_capture` audit entries (AC12 Option B, implemented well, best-effort via AuditWriter's never-raise contract). But `configure_logging` — which changes per-endpoint min level and retention window, arguably the more substantive logging-policy change — writes no audit entry. This is consistent with the existing global `logs_controller.save_retention` path (which also does not audit), so it is a pre-existing convention gap rather than a regression, and AC12 named only capture actions. For a compliance-native product, per-endpoint retention/level changes leaving no compliance trail is worth closing; low priority given parity with existing behavior.

**Finding #3 — capture re-persists highest-sensitivity endpoint logs [LOW]**
Enabling capture on `/_matrix/client/v3/sync` newly persists that endpoint's DEBUG/INFO/WARN entries for 5 minutes. The invariant "capture cannot capture MORE sensitive data than policy allows / cannot bypass redaction" HOLDS: redaction happens upstream in `Nebu.Web.Plugs.RequestLogger` BEFORE `Logger.*` is called (the handler explicitly does no redaction and re-derives nothing), so capture only re-enables persistence of already-redacted entries — it changes WHETHER, never HOW, an entry is built. Residual concern: sync is the endpoint that streams message content, and this feature converts its transient logs into persisted+retained records on an admin toggle. Its safety is fully coupled to RequestLogger's field coverage (a pipeline with historically noted field-coverage gaps). Out of this diff's scope, but recommend confirming RequestLogger redacts sync request/response bodies before per-route capture is exercised in anger.

**Finding #4 — auto-expiry not audited [INFO / accepted]**
Documented design decision (expiry is the timer doing its job, not an admin action). The off-window is reconstructible: the `enable_temporary_capture` entry records `expires_at`, and errors-always-persist keeps failures visible even after expiry. No compliance-trail loss in practice. Accepted.

**Finding #5 — e2e/fixtures/db.ts [INFO]**
Test-only SQL seeding (`docker exec psql` / `NEBU_DB_URL`), not imported by any production Elixir path. `sqlLiteral` escapes single quotes; `seconds` is `Math.floor`'d before interpolation. Blast radius confirmed test-only (code-review concern #3 resolved).

### Verified (no finding)
- **Authz (concern #2):** `LogsLive.TraceMap` is inside `live_session :admin, on_mount: {Nebu.Admin.Auth, :require_admin}` (admin/router.ex:216-229). `handle_event` callbacks only fire on a successfully-mounted connected socket, so the mount gate protects `configure_logging`/`enable_capture`/`disable_capture`. No unauthenticated or low-priv path.
- **SQL injection:** All manager queries (`enable/2`, `disable/2`, `active?/1`, `cleanup_expired/0`) and `upsert_server_config/1` are fully parameterized (`$1..$n`). No concatenation of user input into SQL.
- **Errors-always-persist:** `should_persist?/2` and `should_ingest?/3` place `level == "error" -> true` as the unconditional first branch — off-list silencing can never suppress a failure.
- **Cluster-safety (spot-check):** "state is a row, expiry is `expires_at > now()`" — no process timer owns correctness; `active?`/`active_captures` treat unswept expired rows as inactive. CaptureCache correctly avoids self-deadlock by not calling `cleanup_expired/0` from its own refresh.
- **Audit immutability:** untouched; only the `@known_actions` allowlist is extended.

### Summary

CRITICAL: 0
HIGH: 0
MEDIUM: 1 — advisory, address before epic end
LOW: 2 — advisory
INFO: 2 — accepted / verified

**Verdict:** APPROVED (no CRITICAL/HIGH; commit not blocked). Finding #1 (input validation) should be closed before per-endpoint retention is wired into the pruner.
