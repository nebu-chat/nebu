# Code-Review (cycle 0) — bugfix-oidc-bootstrap-only-e2e-regressions

Verdict: APPROVED. 0 CRITICAL, 0 MAJOR, 1 MINOR, 2 INFO.
AC1-AC5 all PASS. AC2 #1 invariant verified: fetch_keys_for/2 is a pure local fetch — reads nothing from OidcConfig, never calls JwksCache.refresh()/put_env/GenServer; override jwks consumed only locally in select_key/2. Override fail-closed verified (nil/"" issuer→:issuer_not_configured, []→:no_keys, mismatch→:bad_issuer). Overrides cannot leak onto normal path (only auth.ex bootstrap branch passes them; full caller sweep done). Single verify path preserved. TLS/SSRF parity preserved (reuses http_opts_for verify_peer). ADR-018/020/022 hold.

MINOR-1 (AUTO-CYCLE TO DEV): fetch_keys_for/2 direct jwks_uri branch (is_binary && != "") calls fetch_jwks_over_http(jwks_uri) WITHOUT the http(s)://-only scheme guard that the discovery branch enforces via extract_valid_jwks_uri/1. bootstrap_live.ex validates only non-emptiness, not scheme. Low risk (operator-only first-boot input; non-http(s) fails at :httpc anyway) but fix for defense-in-depth + parity: gate the direct branch on the same http(s):// prefix check, returning :error otherwise.

INFO-1: test reconciliation (sso_login_scope_test.exs / sso_scope_mode_test.exs flipped to openid+profile+email) is correct supersession — not a finding.
INFO-2: scopes within standard OIDC claims; no over-request; no plaintext secrets in logs.
