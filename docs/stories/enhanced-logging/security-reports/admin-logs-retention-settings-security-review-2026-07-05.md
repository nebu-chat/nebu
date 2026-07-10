## Security Review — admin-logs-retention-settings (epic: enhanced-logging)

**Reviewer:** Kassandra (nebu-agent-kassandra)
**Diff scope:** staged diff (`git diff --staged`) — new Admin UI page `GET /admin/logs/config` + `POST /admin/logs/config/retention` (plain Phoenix Controller, not LiveView), RLS-allowlist migration 000018, WARN/ERROR backend safety-net TTL, and supporting policy-cache/read-path wiring.
**Date:** 2026-07-05
**Standing LAW checked:** No secrets/credentials AND no chat-message/user-generated content leak. This story's surface is admin-config UI (retention days/max-counts, on/off toggles), not payload redaction; no new payload-logging path is introduced.

### Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| — | — | — | No exploitable findings | — |

### Detail — Focus-Area Verification (all PASS)

**1. RLS/allowlist correctness (migration 000018) — PASS**
`server/priv/migrations/000018_config_log_info_max_count_mutable.up.sql` re-creates `config_update_mutable` with the FULL 25-key list from `000017_operational_logs.up.sql` verbatim PLUS the one new key `log_retention_info_max_count` (26 keys). Byte-for-byte comparison against 000017 confirms NO existing key was silently dropped or typo-mangled by copy-paste. The `.down.sql` restores exactly the 000017 list (25 keys, without the new key) — correct reversal. The `DROP POLICY IF EXISTS` + `CREATE POLICY` pattern is idempotent. This closes the exact silent-no-op UPDATE bug class (RLS `USING` fails → 0 rows affected, no error) that design-decisions.md #4b warned about.

**2. CSRF — PASS**
`POST /admin/logs/config/retention` is declared inside `scope "/admin"` with `pipe_through :browser`, whose pipeline includes `plug :protect_from_forgery` (Plug.CSRFProtection). The form template emits `<input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />` (matches ConfigController). The route is NOT in `@csrf_bypass_excluded_paths` handling in a way that weakens it, and `maybe_skip_csrf` only fires when the test-only `:admin_csrf_bypass` app-env is set (never set in production; no-op there). No `plug_skip_csrf_protection` opt-out anywhere in the controller.

**3. Auth gate — PASS**
`plug Nebu.Admin.Auth, :require_admin` is declared at the controller module level (no `when action in [...]` scoping), so it runs before BOTH `index/2` (GET) and `save_retention/2` (POST). `require_admin/2` (auth.ex:119) pattern-matches `%{"admin" => true}` and otherwise `redirect + halt()` to `/admin/login`. Non-admins and unauthenticated users are gated on both actions.

**4. Injection surface — PASS**
Persistence flows through `Nebu.Admin.DB.upsert_server_config/1`, which uses a fully parameterized `Ecto.Adapters.SQL.query!` (`$1/$2/$3`). The config KEYS are hardcoded literals in the controller (`log_collect_info`, `log_retention_info_days`, `log_retention_info_max_count`, `log_collect_debug`, `log_retention_debug_days`, `log_retention_debug_max_count`) — no user-controlled key reaches SQL, so no mass-assignment of arbitrary `server_config` keys. VALUES are either `"true"/"false"` (from `== "true"` boolean coercion) or validated integers/`""`. The retention prune queries in `retention.ex` are likewise parameterized (`$1` level literal, `$2` bounded integer). No string concatenation of user input into SQL.

**5. WARN/ERROR safety-net TTL is NOT admin-configurable — PASS**
`server/lib/nebu/web/log_store/retention.ex` uses a module attribute `@warn_error_safety_net_days 90` applied via `prune_ttl("warning"/"error", 90)`. There is no matching `server_config` key, no PolicyCache default, no allowlist entry, and no form field / HTTP param path — confirming AC6's "always-on, non-interactive, no operator input" requirement. No attacker- or operator-controlled input can alter the WARN/ERROR retention window.

**6. XSS / raw echo on error re-render — PASS**
The AC15 error re-render path (`state_from_params/1`) echoes submitted values back through the template exclusively via HEEx auto-escaping interpolation (`value={@state.info_days}`, `aria-pressed={to_string(@state.info_enabled)}`, etc.). No `Phoenix.HTML.raw/1`, no `{:safe, ...}`, no `raw(...)` anywhere in `index.html.heex`. Flash messages are controller-hardcoded constant strings (validation errors + "Logging settings saved"), never user input. Reflected params are HTML-attribute-escaped; no injection.

**7. Injectable writer/reader seams are test-only — PASS**
`persist/1` reads the writer via `Application.get_env(:nebu_http, :admin_logs_retention_writer)`, an application-env value not derivable from any HTTP param, header, or body. In production the env is unset and the code falls through to the real `Nebu.Admin.DB.upsert_server_config/1`. Not reachable or influenceable by an unauthenticated (or authenticated) request. Matches ConfigController's established seam pattern.

### Additional Observations (not findings)

- Boolean coercion `params["#{level}_enabled"] == "true"` and integer bounds validation (`validate_bound/4`: 1..90 days, 1..10000 entries; blank/`"0"` → stored `""`) reject negatives, floats, and non-numerics before persistence. `to_int("")` → `nil` on read-back = "no limit", consistent with the stored sentinel; a stored literal `"0"` (which would prune everything) is correctly avoided by `finalize(:blank) -> ""`.
- The `maybe_skip_csrf` test-bypass mechanism (pre-existing, not introduced by this story) would disable CSRF on all admin POSTs except bootstrap IF `:admin_csrf_bypass` were ever set in production. This is inherited infrastructure with a documented "never set in prod" contract — noted for continued awareness, not a finding against this diff.
- Pre-existing infra items self-documented in the Dev Agent Record (server_config has no DELETE RLS policy; async batched-writer test race) are test-fixture/housekeeping concerns, not vulnerabilities in shipped code.

### Summary

CRITICAL: 0
HIGH: 0
MEDIUM: 0
LOW: 0

No security issues found across the reviewed staged diff.

**Verdict:** APPROVED (CLEAN)
