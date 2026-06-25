## Security Review — bug-fix-element-login

**Diff scope:** `@base_scopes` in `Nebu.Matrix.SsoLogin` reduced from `~w(openid profile email)` to `~w(openid)` only; `Logger.warning` calls added in `Nebu.Web.Plugs.OidcPlug.do_provision/2` when OIDC email/display_name claims are absent; documentation and test updates aligned to the new scope behavior.

**Date:** 2026-06-25

**Files reviewed:**
- `server/lib/nebu/matrix/sso_login.ex` (full file)
- `server/lib/nebu/web/plugs/oidc_plug.ex` (full file)
- `server/config/runtime.exs` (full file)
- `server/test/nebu/matrix/sso_scope_mode_test.exs` (full file)
- `docs/architecture/08-concepts.md` (affected section)

---

### Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| 1 | LOW | `oidc_plug.ex:213–222` | User ID logged in warning message — `user_id` is a Matrix user ID derived from the OIDC `sub` claim; present in logs on every first provisioning for any user with absent email/display_name claims | Downgrade to `Logger.debug` or redact to a hash/prefix; or gate behind a compile-time debug flag. |
| 2 | LOW | `sso_login.ex:396` | Client secret concatenated inline for Basic auth — `"#{cfg.client_id}:#{cfg.client_secret}"` is interpolated into a string before `Base.encode64`; if an exception occurs mid-flight the interpolated secret could appear in a crash report or Logger output | No direct leak path in normal operation; ensure OIDC client secrets are excluded from crash dumps / Logger metadata. Accept as low or add `redact: :client_secret` config. |

---

### Detail

**Finding #1 — User ID in warning log (LOW)**

`do_provision/2` (lines 212–222) logs the resolved Matrix user ID (`@<sub>:<server_name>`) when `email` or `display_name` claims are absent. The Matrix user ID is derived from the OIDC `sub` claim, which is PII in most deployments (it is typically a UUID or an email address depending on the IdP). The warning is suppressed on subsequent requests within the 60-second provisioning-cache TTL, so it fires at most once per cache window per unique user. In a production environment with structured logging forwarded to a SIEM or third-party log aggregator, this may constitute an unintended PII export path.

The log message itself contains actionable operator guidance (`NEBU_OIDC_EXTRA_SCOPES=profile email`), which is valuable; the risk is the inclusion of `user_id` rather than a redacted/pseudonymous identifier. The actual security impact is low: an attacker would need access to the log pipeline to exploit this.

**Remediation:** Replace `"#{user_id}"` with either `"<user>"` (anonymized) or a first-8-char prefix/hash so operators can correlate without exposing the full identifier. Alternatively, emit at `Logger.debug` level so production log levels (`:info` and above) suppress it.

**Finding #2 — OIDC client secret string interpolation (LOW)**

`exchange_code/5` (line 396) builds the Basic auth header via:
```elixir
basic = Base.encode64("#{cfg.client_id}:#{cfg.client_secret}")
```
String interpolation materializes the secret as a plain Elixir binary on the process heap. This is standard Elixir and does not differ from the previous codebase; the diff does not introduce this pattern — it was already present. Flagged for completeness because the bug-fix diff touches the scope that feeds into this exchange path, increasing scrutiny. No regression introduced by this diff.

---

### Scope Confirmed Clean

The following dimensions were reviewed and found to have no issues introduced by this diff:

- **Scope reduction (`@base_scopes ~w(openid)`):** Correct and intended. Reducing the scope never widens an auth bypass; the IdP accepts or rejects based on what is requested. Operators who previously relied on implicit `profile`/`email` scopes will now need `NEBU_OIDC_EXTRA_SCOPES`, which is documented. No auth bypass or token-confusion risk.
- **`NEBU_OIDC_EXTRA_SCOPES` injection path:** `scope_list/0` deduplicates via `Enum.uniq()` and the result is passed through `URI.encode_query/1`. No scope injection attack surface (scopes are a whitespace-separated string in an OAuth query parameter — they cannot escape the parameter context via injection).
- **JWT validation:** Unchanged. Algorithm allowlist (`@allowed_algs`), fail-closed issuer/audience, `exp`, `sub` checks all remain in place. `alg:none` and HS* remain blocked.
- **Open redirect in `redirectUrl`:** Unchanged. Scheme denylist (`javascript`, `data`, `file`, `vbscript`, `blob`) + allowlist logic in `redirect_url_allowed?/1` remain fully in place.
- **CSRF / state replay protection:** `SsoStore.pop_state/1` (single-use, TTL-bound) unchanged. Nonce check via `Plug.Crypto.secure_compare/2` unchanged.
- **PKCE:** `code_challenge_method: S256` with `pkce_challenge/1` using `:crypto.hash(:sha256, verifier)` — unchanged, correct.
- **SQL injection:** The two inline queries (`@sql_config`, `@sql_matrix_refresh_mode`) are parameterized (`[key]`, `[]`). No user-controlled input reaches the SQL string. Config changes in this diff only affect comments.
- **Timing attacks:** Nonce comparison uses `Plug.Crypto.secure_compare/2`. State lookup uses ETS key match (opaque 128-bit random token). No `==` on secrets introduced.
- **Plaintext secrets in logs:** No token, OIDC access/refresh token, or client secret is logged in the new code. The `Logger.warning` lines log only `user_id`.
- **Body-size limits / rate limits:** No new HTTP endpoints introduced. Existing middleware unchanged.
- **Weak crypto primitives:** PKCE uses SHA-256. `random_token/1` uses `:crypto.strong_rand_bytes`. No MD5/SHA1/DES introduced.
- **Security headers:** No new HTML endpoints. No regression.
- **New SQL migrations:** None in this diff.

---

### Summary

```
CRITICAL: 0
HIGH:      0
MEDIUM:    0
LOW:       2 — advisory, address before epic end
```

**Verdict: APPROVED**

The core change — reducing `@base_scopes` to `~w(openid)` — is correct and does not introduce any exploitable vulnerability. The two LOW findings are pre-existing patterns (client-secret interpolation) or minor PII hygiene concerns (user ID in warning logs). Neither blocks the commit. The PII in logs finding (Finding #1) is recommended for a follow-up hardening ticket before the epic closes.
