# SEC Gate 2 — Epic-End Security Review: element-compat

**Reviewer:** Kassandra  
**Date:** 2026-06-25  
**Branch:** bugfix/oidc-login-keycloak  
**Stories reviewed:** element-startup-stubs, account-data-get, sync-nginx-timeout

## Verdict: PASS (0 CRITICAL, 0 HIGH)

### MEDIUM-1 — No rate limit on PUT/GET account_data
PUT /client/v3/user/:userId/account_data/:type has no rate limit. Authenticated DoS possible at wire speed. ETS write is cheap but body encoding adds CPU cost. Recommendation: add 60 PUT/min rate limit. Follow-up story required.

### LOW-1 — ETS key type parameter unbounded length
`:type` path segment used directly as ETS key with no length check. Very long type strings inflate ETS memory per entry. No key-confusion or path-traversal (pin operators used). Recommendation: 255-byte cap, return 400 M_INVALID_PARAM. Follow-up story.

### LOW-2 — Logger.warning logs user_id
User_id (MXID) in log for room fetch timeout. Not a secret — MXID is a public Matrix identifier. Exit reason is :killed only. No action required.

### LOW-3 — Task.async_stream authenticated DoS (bot accounts)
User with O(1000) rooms causes long initial sync. Bounded by max_concurrency:5, 10s kill timeout, 600 req/min rate limit. Operational concern, not security vulnerability. Recommendation: consider max_rooms_for_initial_sync cap in a future story.

### All checks cleared
SQL injection, XSS, CSRF, auth bypass/IDOR, body-size limits (1MB cap), weak crypto, open redirects, security headers, path traversal, JWT validation, plaintext secrets — all PASS.
