# Security Review — bugfix-oidc-bootstrap-only-e2e-regressions (epic oidc-bootstrap-only)

**Reviewer:** Kassandra (nebu-agent-kassandra, adversarial security review)
**Diff scope:** STAGED diff — production files:
`server/lib/nebu/web/plugs/oidc_plug.ex`, `server/lib/nebu/web/jwks_cache.ex`,
`server/lib/nebu/admin/auth.ex`, `server/lib/nebu/matrix/sso_login.ex`.
Test files reviewed as supporting context only.
**Date:** 2026-06-28
**Story context:** CRITICAL bug fix for 3 ADR-022 (bootstrap-only OIDC, 53a3cb4f) regressions:
(1) `:no_keys` during bootstrap (draft-local JWKS fetch + verify-token overrides),
(2) admin/bootstrap scope `+groups`, (3) Matrix SSO base scope `+profile email`.

---

## Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| — | — | — | No exploitable findings | — |

**No security issues found.**

---

## Mandatory Scope — verification results (each story-required item)

### THE #1 INVARIANT (AC2) — fail-closed preserved: PASS

The bootstrap verify path **never** writes the draft config/keys into the global
`JwksCache`/`OidcConfig`.

- `Nebu.Admin.Auth.verify_id_token(id_token, "bootstrap", cfg)`
  (`server/lib/nebu/admin/auth.ex:432-451`) calls only
  `Nebu.Web.JwksCache.fetch_keys_for/2` (which by design touches neither the
  GenServer cache nor `OidcConfig`) and then `OidcPlug.verify_token/2` with the
  draft `issuer`/`audience`/`jwks` passed as **per-call opts**. No
  `JwksCache.refresh()`, no `OidcConfig.refresh()`, no `Application.put_env(:oidc_jwks, …)`
  in this branch.
- The only `OidcConfig.refresh()` + `JwksCache.refresh()` calls live in
  `do_complete_bootstrap/2` (`auth.ex:1271-1285`), which runs **after** the wizard
  has persisted the OIDC config to `server_config` — the legitimate completion
  path, not the verify path. Correct.
- `JwksCache.fetch_keys_for/2` (`jwks_cache.ex:82-98`) returns a key list to the
  caller and reads nothing from `OidcConfig`; the OidcConfig read is isolated to
  `discover_jwks_uri_and_fetch/0` (global path only, `jwks_cache.ex:230-241`).
- Confirmed by `server/test/nebu/web/oidc_bootstrap_verify_test.exs` AC2: with
  the global caches deliberately empty, a well-formed Matrix Bearer JWT is still
  rejected `401`, **including after** invoking the draft-verify path — proving the
  draft path does not pollute the global caches and let the Matrix API accept
  tokens early.

### Draft-sourced JWKS fetch uses the SAME TLS verification — PASS

`fetch_keys_for/2` routes through the shared `fetch_jwks_over_http/1` →
`fetch_jwks_over_http_real/1`, which calls `http_opts_for/1`
(`jwks_cache.ex:316-330`): `verify: :verify_peer`, `cacerts: :public_key.cacerts_get()`,
and hostname match via `:public_key.pkix_verify_hostname_match_fun(:https)`. This
is the identical TLS posture as the global JwksCache fetch — no downgrade. (`http://`
is unverified, but that is the pre-existing, documented dev-internal-Dex carve-out
per ADR-012, unchanged by this diff.)

### SSRF posture on operator/discovery-supplied jwks_uri — PASS (improved)

- Explicit draft `jwks_uri` is scheme-gated to `http(s)://` via `http_scheme?/1`
  **before** any `:httpc` call (`jwks_cache.ex:84-90`). A non-http(s) scheme
  (`file://`, `gopher://`, etc.) is rejected with `:error` and does not silently
  fall through to issuer discovery — closing a confused-deputy variant.
- The discovery branch's `extract_valid_jwks_uri/1` already enforces the same
  scheme allowlist on the URI pulled from the well-known document
  (`jwks_cache.ex:263-272`). Parity confirmed.
- Residual SSRF surface (fetch to an operator-controlled host/IP — incl. RFC1918 /
  link-local) is **pre-existing** to the global JwksCache path and is not introduced
  or widened by this diff. The actor able to set the draft `jwks_uri`/`issuer` is the
  bootstrapping operator (the highest-trust principal, pre-any-admin). No new
  privilege boundary is crossed. Not a new finding.

### `:issuer`/`:jwks` overrides cannot be triggered on the normal request path — PASS

Swept all callers of `verify_token` (grep over `server/lib`):
- `oidc_plug.ex:120` — normal Matrix request path, **no opts**.
- `http_public.ex:286` — `verify_token(id_token)`, **no opts**.
- `sso_login.ex:216` — `verify_token(id_token)`, **no opts**.
- `auth.ex:208` — admin refresh-token (normal mode), `audience:` only.
- `auth.ex:454` — admin login normal mode, `audience:` only.
- `auth.ex:442` — **the only** caller passing `issuer:`/`jwks:`, gated behind the
  `verify_id_token(_, "bootstrap", _)` clause.

The overrides are reachable exclusively from the bootstrap-mode admin callback.

### Overrides remain FAIL-CLOSED — PASS

In `OidcPlug` (`oidc_plug.ex:413-470`):
- `select_key/2`: `keys = if is_list(jwks_override), do: jwks_override, else: available_keys()`.
  An empty `[]` override still hits `keys == [] -> {:error, :no_keys}`. nil override →
  global resolution unchanged.
- `check_issuer/2`: `issuer_or_nil(override) || oidc_issuer()`. nil/`""` override with no
  global issuer → `:issuer_not_configured`; `iss` mismatch → `:bad_issuer`. The added
  explicit `"" -> :issuer_not_configured` clause is a correct fail-closed tightening.
- alg allowlist (`@allowed_algs`, no `none`/HS*), `check_exp`, `check_subject`,
  `check_audience`, signature verification — all unchanged and still in the single
  `with` pipeline. Nonce (`check_nonce`) and PKCE (`code_verifier`) live in the admin
  callback flow and are untouched.
- `fetch_keys_for/2` returns `:error` on fetch/discovery failure → bootstrap branch
  maps to `{:error, :bootstrap_jwks_unavailable}` → callback logs + redirects to
  `/admin/login?error=auth_failed`. No fail-open.

### Scope additions (`groups`, `profile email`) — PASS

- `admin_oidc_scope/0` (`auth.ex:887-903`) and `sso_login` `@base_scopes`
  (`sso_login.ex:431`) are **static literals**; no attacker- or user-controlled input
  flows into the scope string. `matrix_refresh_mode/0` collapses any non-"online"
  value to "offline", so a stray `server_config` value cannot inject an arbitrary
  scope (`sso_login.ex:447-454`).
- `groups`/`profile`/`email` are standard OIDC scopes releasing standard claims
  (`name`, `email`, `groups`) — no over-request beyond what the wizard / admin-group
  gate / MXID derivation legitimately consume. No new PII beyond `email`/`name`,
  which the system already provisions.
- The `name`-claim → MXID change is safe: `UserId.localpart/1` routes every claim
  value through `sanitize/1` (downcase + replace any non-grammar char with `_`,
  `user_id.ex:58-62`), so a crafted `name` claim cannot break the `@localpart:server`
  shape or spoof another localpart's grammar.

### No plaintext secrets in logs — PASS

`client_secret` is used only for HTTP Basic encoding (`auth.ex:742`) and carried as an
encrypted blob elsewhere; never passed to `Logger`. The bootstrap-failure log lines
(`auth.ex:399`, `jwks_cache.ex:88,255,…`) log reasons/URIs/issuer, not tokens or
secrets. `Logger.warning("…discover jwks_uri from issuer #{issuer}")` logs the issuer
URL only (not a secret).

### ADR-022 holds — PASS

No `NEBU_OIDC_*` / `NEBU_ADMIN_OIDC_SCOPE` env reintroduced in any staged production
file (grep of the staged diff over `server/lib` finds only doc-comment references that
explicitly state these env paths do NOT exist). `System.get_env` is not added on any
config path by this diff.

---

## General Scope Sweep

- **SQL injection:** No new SQL in the diff; existing `server_config` reads are static,
  param-free constant queries. None reachable with attacker input. PASS.
- **Auth bypass / IDOR:** The bootstrap-group gate is intentionally skipped pre-bootstrap
  (no admin exists yet — Go parity); `bootstrap_callback` re-guards with
  `bootstrap_completed?()` and rejects a missing/empty `sub`. Normal mode still enforces
  `check_admin`. No bypass introduced. PASS.
- **JWT validation flaws (alg confusion / missing exp/aud/iss/nonce):** alg allowlist,
  exp, iss, aud, sub all enforced; overrides are additive and fail-closed. PASS.
- **Timing attacks:** No new secret comparison introduced. PASS.
- **Open redirects:** Callback redirects are to fixed internal paths
  (`/admin/login`, `/admin/dashboard`). PASS.
- **Weak crypto:** None introduced; TLS verify_peer retained. PASS.
- **Path traversal:** N/A — no filesystem paths from input. PASS.

---

## Summary

- CRITICAL: 0
- HIGH: 0
- MEDIUM: 0
- LOW: 0

**Classification: CLEAN**

**Verdict: APPROVED** — no commit-blocking findings. The fix correctly preserves the
ADR-022 fail-closed invariant: draft-sourced JWKS/issuer are used only as per-call
`verify_token/2` overrides reachable solely from the bootstrap callback, the global
caches are never warmed by the verify path (only by `do_complete_bootstrap` after
config persistence), TLS peer verification is unchanged, SSRF scheme-gating is at
parity (and slightly improved), and the new scopes introduce no attacker-controllable
input or over-request.
