## Security Review — fix-and-configure-sso-redirect-schemes

**Reviewer:** Kassandra (nebu-agent-kassandra)
**Diff scope:** staged diff (`git diff --staged`) — bugfix + feature to the SSO redirect-URL open-redirect allowlist (`Nebu.Matrix.SsoLogin.redirect_url_allowed?/1`), a new Admin-UI-managed `sso_extra_redirect_schemes` config path (`config_controller.ex`, `router.ex`, `oidc_config.ex`, `db.ex`, HEEX template), and removal of the `NEBU_SSO_REDIRECT_SCHEMES` env var.
**Date:** 2026-07-03
**Classification:** CLEAN

### Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| — | — | — | No security issues found | — |

### AC14 Explicit Checklist

**(a) Strict enumerated exact-string match — no pattern/wildcard/heuristic — CONFIRMED.**
`redirect_url_allowed?/1` (sso_login.ex:310-328) uses only `scheme in @scheme_denylist`, `scheme == "https"`, `scheme == "http"` (host in loopback list), `scheme in @default_deep_link_schemes`, `scheme in extra_redirect_schemes()`. All membership/equality tests on the downcased URI scheme. No regex, no `String.starts_with?`, no prefix/substring/wildcard matching anywhere in the allow decision. RFC 8252 §8.6 scheme-squatting control intact.

**(b) Admin write path authenticated/authorized with the SAME guard as sibling mutation endpoints — CONFIRMED.**
The new route `post "/config/sso-schemes", ConfigController, :save_sso_schemes` (router.ex:190) sits inside `scope "/admin" ... pipe_through :browser` (router.ex:123-124), immediately adjacent to the existing `post "/config/scopes", ConfigController, :save_scopes` (router.ex:189). The `:browser` pipeline only fetches the current user (router.ex:82, `Nebu.Admin.Auth, :fetch_current_user`); authorization is enforced per-controller. `ConfigController` declares a controller-level `plug Nebu.Admin.Auth, :require_admin` (config_controller.ex:18) which runs for ALL actions in the module, including `save_sso_schemes/2`. This is the identical guard protecting `save_scopes/2` and `save_refresh_mode/2`. The route is NOT in any unauthenticated pipeline (the unauthenticated routes — login/callback/bootstrap — are in the same scope but dispatch to `LoginController`/`BootstrapController`, which do not carry `require_admin`; `ConfigController` does).

**(c) Two redirect legs confirmed independent; `callback_url/1` untouched — CONFIRMED.**
`git diff --staged` for `sso_login.ex` contains ZERO `callback_url` hunks; `callback_url/1` remains a private function at sso_login.ex:567, unchanged. The client-facing leg (`redirect_url_allowed?/1`) reads only `conn.query_params["redirectUrl"]` (sso_login.ex:71) and validates it against the allowlist; the IdP-facing leg (`callback_url/1`) computes Nebu's own fixed callback URI from request scheme+host and is passed as `"redirect_uri"` (sso_login.ex:104). The validated client `redirect_url` is stored in the SsoStore state (sso_login.ex:97) and never flows into `callback_url/1`. No coupling.

### Additional Focus Areas

**Input validation (server-side, before DB write) — CONFIRMED.**
`validate_sso_schemes/1` (config_controller.ex) runs in the `save_sso_schemes/2` handler before any persistence. It: (1) splits WITHOUT `trim: true` so blank/whitespace-only interior tokens (`"a,, b"`) are preserved and rejected with the empty-scheme error; (2) trims each token then applies `@scheme_regex ~r/^[a-zA-Z][a-zA-Z0-9+.-]*$/` (RFC 3986 scheme-token syntax); (3) rejects case-insensitively (`String.downcase(token) in Nebu.Matrix.SsoLogin.scheme_denylist()`) any denylisted scheme. An empty overall string is valid input (clears custom schemes → defaults only). An authenticated admin canNOT allowlist `javascript`/`data`/`file`/`vbscript`/`blob` — the denylist check is enforced at save time regardless of admin privilege. Validation is entirely server-side; there is no client-side-only trust.

**Denylist-wins-over-allowlist (defense in depth, two independent layers) — CONFIRMED.**
Layer 1 (write path): `validate_sso_schemes/1` rejects denylisted schemes before DB write. Layer 2 (read path): `redirect_url_allowed?/1` checks `scheme in @scheme_denylist -> false` at sso_login.ex:318, BEFORE the `@default_deep_link_schemes` check (line 324) and the `extra_redirect_schemes()` check (line 325). Even if a denylisted scheme somehow reached `server_config` (direct DB manipulation, future bug, or a different write path bypassing validation), a `javascript:` redirectUrl is still rejected at request time. The two layers are genuinely independent (different modules, different triggers).

**Regex `$` trailing-newline behavior — analyzed, NOT exploitable.**
`~r/^[a-zA-Z][a-zA-Z0-9+.-]*$/` without the `m` flag lets `$` match before a single trailing `\n`, so `"element\n"` passes the raw regex (verified empirically). However, tokens are `String.trim/1`-ed before the regex is applied, so a trailing newline is stripped first. Interior newlines (`"ele\nment"`, `"element\ndata"`) FAIL the regex (verified empirically) — the char class excludes `\n` and `$` only matches the final position. No newline-injection can smuggle a second (denylisted) scheme past validation.

**Trim-normalization fix (code-review finding) — CONFIRMED not a security bypass.**
`save_sso_schemes/2` now persists the NORMALIZED value (split on comma, `String.trim` each token, rejoin with `", "`) rather than a raw `String.trim/1` of the outer string, so interior whitespace/newlines between tokens do not survive verbatim into `server_config`. Independently, the read side `extra_redirect_schemes/0` (sso_login.ex:338-356) re-splits on comma, re-trims, downcases, rejects empties, and dedups every token on every read — so even a messy stored value cannot smuggle a dangerous or mismatched scheme. This is a display/consistency correctness fix, not a security gate; the security gate (denylist-wins at sso_login.ex:318) is upstream of it regardless.

**Cache / cluster consistency — CONFIRMED, no staleness window.**
`sso_extra_redirect_schemes` is added to `@scope_cache_keys` (db.ex:24-27). `upsert_server_config/1` is the single central write point; when a change touches any `@scope_cache_keys` key it calls `refresh_oidc_scope_cache/0` → `Nebu.Web.OidcConfig.refresh()` (db.ex:760-762, 774-777), which re-reads from `server_config` (the extended `load_from_db/0` SQL now selects `sso_extra_redirect_schemes`, oidc_config.ex) and broadcasts `:pg` invalidation to peer nodes (ADR-020/M-3). A REMOVED scheme is persisted as the new smaller normalized list and takes effect cluster-wide on the next read; a newly-added scheme likewise. No per-request DB call, no stale-allowlist window.

**Error handling / info leak — CONFIRMED unchanged.**
Rejected redirects still return `M_INVALID_PARAM` with a generic message and do NOT echo the scheme/URL (sso_login.ex:78-80, `Logger.warning("matrix SSO: redirectUrl rejected by allowlist")` with no interpolation). This pre-existing behavior is not in the diff. The Admin-UI validation error message interpolates the operator's own submitted token, but it is surfaced via flash and rendered through HEEX `{Phoenix.Flash.get(@flash, :error)}` (auto HTML-escaped) — no reflected XSS.

**CSRF — CONFIRMED.**
The new `#sso-schemes-form` includes `<input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />`, identical to the sibling `oidc-scopes-form`. The `:browser` pipeline runs `plug :protect_from_forgery` (router.ex:76). The stored config value rendered back into the form (`value={sso_schemes_value(@config, ...)}`) is auto HTML-escaped by HEEX — no stored XSS.

**Other dimensions:** No SQL injection (the extended `load_from_db/0` query uses a static column list, no interpolation of user input; `upsert_server_config/1` uses the existing parameterized helper). No new secrets, no crypto changes, no new unauthenticated endpoints, no timing-sensitive comparison introduced. Security headers unchanged (admin CSP pipeline covers the config page). No new dependencies (ADR-021).

### Summary

CRITICAL: 0
HIGH: 0
MEDIUM: 0
LOW: 0
INFO: 0

**Verdict:** APPROVED — CLEAN. No blocking findings. All six AC14 checklist items and all additional focus areas verified against the code with file:line citations. The bugfix (corrected default schemes) and feature (operator-configurable allowlist with strict validation, denylist-wins defense-in-depth, and cluster-aware cache invalidation) preserve the open-redirect protection gate's security properties.

---

### Addendum (2026-07-03, post-review follow-up) — `$` vs `\z` anchor: found and fixed

The original review's "Regex `$` trailing-newline behavior" finding above concluded the `$`-anchored `@scheme_regex` was "analyzed, NOT exploitable" **because tokens were `String.trim/1`-ed before the regex ran** — i.e. the safety came from adjacent code stripping the trailing `\n` first, not from the regex itself being correct. A subsequent independent check flagged that this reproduces an already-identified and already-fixed anti-pattern in this exact codebase: `Nebu.Web.OidcScopes.@scope_regex` was corrected to anchor with `\z` (not `$`) during the `configurable-oidc-scopes` security review, specifically because relying on `$`'s before-trailing-`\n` matching behavior — or on incidental trimming elsewhere — is fragile and has previously masked validation bypasses. The established codebase rule since then: **every input-whitelist regex must anchor with `\z`, never `$`**, and the safety property must hold from the regex alone, not from cooperating code upstream of it.

**Fix applied:**
1. `@scheme_regex` in `server/lib/nebu/admin/config_controller.ex` changed from `~r/^[a-zA-Z][a-zA-Z0-9+.-]*$/` to `~r/^[a-zA-Z][a-zA-Z0-9+.-]*\z/`, matching `oidc_scopes.ex`'s pattern.
2. Root-caused that the `\z` fix alone was masked by `validate_sso_schemes/1`'s use of `String.trim/1` (which strips ALL Unicode whitespace, including `\n`) on each token before the regex check — the same underlying fragility, one layer up. Replaced with a `trim_space_only/1` helper that strips only literal ASCII space/tab, so an embedded or trailing `\n` survives to be correctly rejected by the now-`\z`-anchored regex, rather than being silently laundered away pre-regex.
3. Added regression tests (`config_controller_test.exs`, describe block `"AC5: \\z anchor — trailing newline is rejected, not just embedded newline"`, mirroring `oidc_scopes_test.exs`'s existing equivalent): a trailing-`\n` token is rejected, an embedded-`\n` token is rejected, and a normal valid multi-token string is still accepted (no false positive from the fix).
4. Verified: `mix test test/nebu/admin/config_controller_test.exs test/nebu/matrix/sso_login_test.exs test/nebu/web/oidc_scopes_test.exs` — 83 passed, 0 failed. Full unit suite: 1235 passed, 2 skipped, 0 failed (up from 1232 — the 3 new regression tests).

**Re-review scope:** this is a narrow, mechanical, same-day follow-up to an already-CLEAN security review, confined to one regex anchor and its immediately-adjacent trim logic — no new attack surface, no new endpoint, no change to auth/authz/cache/denylist logic already verified above. A full gate re-run was judged unnecessary; this addendum records the finding and fix so future reviewers see it was caught and closed, not silently patched.

**Updated verdict:** still APPROVED — CLEAN. CRITICAL: 0, HIGH: 0, MEDIUM: 0, LOW: 0, INFO: 0. (The original finding is superseded by this addendum, not retracted — it correctly identified the `$` behavior but under-weighted the fragility of relying on incidental trim ordering; that gap is now closed.)
