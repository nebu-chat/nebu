# Code-review — fix-matrix-sso-redirect-missing — cycle 0
Verdict: APPROVED with findings. No CRITICAL/HIGH.
MAJOR-1 (cross-node double-redeem race in SsoStore): Go-parity, narrow sub-ms window, single-node unaffected. Docstring softened to match async-replication reality; true cross-node atomicity deferred (Horde owner-routing or DB DELETE…RETURNING).
MAJOR-2 (AC4 integration test 500 in throwaway container, env-only — same as existing matrix_router integration tests; Repo pool provisioning differs): AC4 to be confirmed under the real stack via the combined E2E re-run (Element SSO login end-to-end) + make test-integration.
MINOR-1 (https-any-host redirectUrl allowed by design — Matrix-client tradeoff, Go parity): accept as documented residual risk; host-allowlist a possible future hardening.
Verified non-issues: scheme/userinfo/protocol-relative/CRLF open-redirect bypasses all rejected; CSRF state single-use+fail-closed; nonce constant-time; single OidcPlug.verify_token path (no self-signed JWT acceptance, alg allowlist); no secret/token logging; ADR-018/020 honoured; routes unauthenticated (correct).
