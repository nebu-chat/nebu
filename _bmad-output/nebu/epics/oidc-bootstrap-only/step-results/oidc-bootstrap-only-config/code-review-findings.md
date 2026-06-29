# Code Review — oidc-bootstrap-only-config (ADR-022)

VERDICT: APPROVE. 0 CRITICAL, 0 MAJOR. Fail-closed invariant fully preserved; all 11 ACs met by code; regression guards genuine.

MINOR (auto-cycle to dev — doc/comment staleness):
- MINOR-1 sso_login_oidc_config_db_fallback_test.exs:1-27 — stale Root Cause/Fix moduledoc describing removed env-fallback; drop no-op delete_env lines.
- MINOR-2 oidc_plug.ex:337-339 — verify_token/1 docstring "dedicated admin OAuth client (different aud)" → single client.
- MINOR-3 sso_login.ex:28-34 — moduledoc still cites NEBU_OIDC_* fallback + NEBU_OIDC_EXTRA_SCOPES.
- MINOR-4 stale comments: oidc_config.ex:76, jwks_cache.ex:173-174, auth.ex:842 (admin_oidc_scope honoured), jwks_cache.ex:173 discovery comment.

INFO (no action required):
- INFO-1 deployment doc: with single client, operator sets server_config.oidc_audience to the IdP-stamped aud (code correct).
- INFO-2 sso_login callback_url/0 derives host from Host header (pre-existing, out of scope).
- INFO-3 bootstrap_live comment "no OIDC discovery implemented" vs jwks_cache discovery (harmless).
