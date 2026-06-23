# Pre-Dev Test-Review — admin-oidc-session-refresh, 2026-06-22
## Verdict: CLEAN (0 MAJOR)
All AC1–AC6 covered, deterministic (exp set directly, refresh via override seam, no live net/sleeps),
real fetch_current_user/2 + real SecretBox, legitimate signed-session helpers, e2e Auth-Code+PKCE.
## Dev notes
- Wire new seam `:admin_oidc_refresh_override` (1-arity, decrypted RT → {:ok, claims, new_rt|nil} | {:error,_}).
- Extend `:admin_oidc_token_override` to also accept `{:ok, claims, refresh_token}` (auth.ex:260-262).
- Make `offline_access` part of the default admin scope (test doesn't set :admin_oidc_scope).
- Reuse put_current_user/2 → session_expiry/1 on refreshed claims (advances session_exp).
- @refresh_window in [31s,3599s] (story: 120s). Session key "admin_oidc_rt".
- Un-pend e2e @pending-feature + fill step stubs; configure short AT lifetime on test IdP client.
- INFO cookie size: encrypted Keycloak RT may approach ~4KB; if server-side fallback needed, flag (untested path).
test-review subagent id: adbd4496f20bcbfbf
