# Security Review — admin-http-refactor / admin-forms-http-controller

**Reviewer:** Kassandra (nebu-agent-kassandra)
**Diff scope:** `git diff --staged` — conversion of 7 Admin LiveViews to Phoenix HTTP controllers
(Users, Rooms, Spaces, Config, ClaimMapping, RoleMapping, Compliance), new router wiring,
`Nebu.Admin.Auth.require_admin/2` plug, new HEEx templates, test config, and test suites.
**Date:** 2026-06-25
**Verdict:** **APPROVED — CLEAN** (no CRITICAL/HIGH; 2 LOW advisories)

---

## Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| 1 | LOW | `rooms_controller.ex:167,261,365`, `spaces_controller.ex:102,138,229,251,291` | Internal error term echoed to operator via `inspect(reason)` in flash. Defence-in-depth (verbose error disclosure). Not a secret leak — `reason` is a `Nebu.Matrix.Error`/changeset term, rendered HEEx-escaped, only visible to an authenticated admin. | Optional: map to generic messages; log the detail server-side instead. Carried over verbatim from the LiveViews — not a regression. |
| 2 | LOW | `admin/endpoint.ex:65` | `Plug.Parsers` declares no explicit `length:` — relies on Phoenix's 8 MB default body cap. Pre-existing, not introduced by this diff; admin endpoint is behind the auth gate. | Optional: set an explicit `length:` on the admin endpoint for clarity. |

No CRITICAL, HIGH, or MEDIUM findings.

---

## Detail — Scope-by-scope

**SQL injection — CLEAN.**
Every query is parameterized or built from server-controlled constants:
- `UsersController` (`@sql_list_users`), `ComplianceController` (`@sql`) are static, no interpolation.
- `RoomsController.@sql_update_auto_join` uses `$1/$2` placeholders. `load_rooms/1` interpolates only
  `filter_clause/1`, whose four branches are hard-coded string literals selected by the
  `@valid_filters` allowlist (`status` is validated against `~w(all active archived stale)` before use).
- User-decoded path params (`room_id`, `space_id`, `user_id`, `child_id`) flow only into parameterized
  `Nebu.Admin.DB.*` helpers (not in this diff) and `Nebu.Matrix.*` functions — never string-built SQL.

**XSS — CLEAN.**
No `raw/1`, `Phoenix.HTML.raw`, or `{:safe, ...}` anywhere in the new templates (grep-verified).
All interpolation goes through HEEx auto-escaping. Dynamic `href`/`action` attributes are built with
`URI.encode(..., &URI.char_unreserved?/1)`, which strips quotes/angle-brackets — no attribute-injection vector.

**CSRF — CLEAN.**
The `:browser` pipeline runs `plug :protect_from_forgery` and all `/admin` routes `pipe_through :browser`.
Every state-changing form carries `<input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />`
(grep-verified across all POST/DELETE forms). DELETE is wired via `Plug.MethodOverride` + `_method=DELETE`
hidden field, so DELETE actions sit under the same CSRF gate.
The `maybe_skip_csrf` test escape hatch reads `Application.get_env(:nebu_http, :admin_csrf_bypass, false)`
— defaults to **false** in prod/dev, and `admin_csrf_bypass: true` is set **only** in `config/test.exs`
(grep-verified: no occurrence in `config.exs`/`runtime.exs`/`prod.exs`). The bypass also explicitly excludes
`/admin/bootstrap/select-claim` so its real-token CSRF test still runs. Correctly fenced.

**Auth bypass / IDOR — CLEAN.**
Every one of the 7 converted controllers declares `plug Nebu.Admin.Auth, :require_admin` at module level
(verified individually in all 7 files), so the gate runs on **every** action including the POST/DELETE writers.
`require_admin/2` matches `%{"admin" => true}` and otherwise halts with a redirect to `/admin/login`.
The `"admin"` flag is derived server-side in `put_current_user/2` (`admin_claim?(claims)` from the verified
ID-token) and stored in the signed Plug session — it is read back via `get_session/2`, not from request
params, so it is not client-forgeable. No IDOR surface: the admin role is global (single privilege tier),
and `remove_member` additionally blocks self-removal.

**Open redirect — CLEAN.**
All `redirect(to: ...)` targets are either static literals (`/admin/rooms`, `/admin/config`, ...) or
`"/admin/rooms/" <> URI.encode(room_id, ...)` — same-origin relative paths with no user-controlled host
or scheme. No `redirect(external:)`, no `return_to`/`redirect_uri` param echoed.

**Timing attacks / weak crypto / plaintext secrets — N/A to this diff.**
No secret comparison, crypto primitive, or secret logging is introduced by these controllers. (Refresh-token
encryption via `SecretBox` in `auth.ex` is pre-existing and unchanged.)

**Security headers — CLEAN (unchanged).**
The `:browser` pipeline still applies `put_secure_browser_headers` + the `admin_csp` plug
(`default-src 'self'; script-src 'self'; ...`) to all converted HTTP routes. `ws:/wss:` remains in
`connect-src` only because Dashboard/AuditLog/Bootstrap LiveViews still need it (CSP tightening explicitly
deferred to AC19). Consistent with the same-origin self-hosted-asset topology — SRI not required here
(see MEMORY watch-flag, 2026-06-25).

**Path traversal / JWT / body limits / rate limits — N/A or unchanged.**
No filesystem path is built from user input. JWT verification is unchanged (`OidcPlug.verify_token` with
`audience:`). Body-size default cap present (Finding #2). Rate limiting on the admin surface is unchanged by
this refactor (admin endpoint is auth-gated).

---

## Summary

- CRITICAL: 0 — _none_
- HIGH: 0 — _none_
- MEDIUM: 0 — _none_
- LOW: 2 — advisory (verbose error disclosure; implicit body-size default), both carried over, not regressions

**Verdict: APPROVED.** The LiveView→HTTP-controller conversion preserves the auth gate on every action,
parameterizes all SQL, keeps HEEx escaping intact, and wires CSRF tokens + MethodOverride correctly on all
state-changing forms. The test-only CSRF bypass is correctly fenced to `config/test.exs`. No commit-blocking findings.
