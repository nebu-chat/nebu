# Security Review: admin-oauth-switch (SEC Gate 1), 2026-10-14

Reviewer: Kassandra (nebu-kassandra), read-only; report stored by the orchestrator (condensed from the agent's hand-back; findings verbatim in substance).
Scope: `git diff --staged` (31 files): `ConfigController.save_oauth_switch/2`, `POST /admin/config/oauth-switch`, `Nebu.Admin.OAuthSwitch`, `Nebu.OAuth.SwitchStore`,
`Nebu.OAuth.save_switch/2`, `normalize_issuer/1`, `config_cache_ms/0`, `Config.invalidate_cache/0`, audit action `oauth_switch_changed`, template, router unframed list, docs, tests.

**Classification: CLEAN (0 CRITICAL, 0 HIGH, 1 MEDIUM, 2 LOW, 6 INFO). Approved; MEDIUM and LOWs fixed in dev cycle 2 (below).**

| # | Sev | Finding | Resolution |
|---|---|---|---|
| M-1 | MEDIUM | A change of the issuer while OAuth stays OFF silently widens legacy-SSO trust (the issuer origin is a trusted `redirectUrl` source 2 even while off, `SsoRedirect` / `trusted_redirect_url?`): it needed no acknowledgement and was applied even when the audit row failed (`unaudited_ok: not enabled`). | FIXED: the acknowledgement is required whenever the result is ON and differs, OR whenever a non-empty issuer is set / changed (also while off); `unaudited_ok` only for a result OFF whose issuer stays the same or is cleared; help text, 07-deployment and ADR AS5 / AS7 name the legacy-SSO side effect; tests (refused without ack, refused without audit). |
| L-1 | LOW | Validation read `conn.params` (query + body merged); the click proof reads `body_params` only. | FIXED: `conn.body_params` for validation and for the re-render; test with a query string. |
| L-2 | LOW | Doc statements: kill switch "always works while the database is up" (the UI path needs a fresh IdP sign-in; SQL otherwise), "never unaudited" without the `unaudited_ok` exception, `trusted_redirect_url?` doc "Nebu's own host". | FIXED in story AC7, `oauth.ex`, `switch_store.ex`. |
| I-1..I-6 | INFO | any https host may be the issuer (accepted, AS3, the page warns when it differs from `NEBU_SERVER_NAME`); marker bound to the page, not the form (same as Y-2); cookie session replay inside 300 s (Y-3); cache race <= TTL (AS8); last write wins (`dc`); the existing seam `:admin_server_config_reader` has no `Mix.env()` guard (follow-up `dd`). | accepted / recorded |

Checked and fine: privileges (`require_admin`, CSRF, gate order, the only writer of the keys is `SwitchStore`), lock-out (runtime fail-closed unchanged, admin login and legacy SSO do not depend on the issuer, only OAuth
clients can be locked out and the UI reverses it), re-auth (gate before parsing, marker bound / single use / consumed after success only, pollution shapes refused, `_method` and path variants), audit (one row, same
transaction, allowed metadata only, no secrets in logs), cache (ETS public, drop on the saving node), headers on 200 / 302 / 403 / notice, SQL parameterized, RLS allowlist (no migration).
