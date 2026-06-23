# Test Review — oidc-middleware-migration (FINAL, round 2)

Verdict: APPROVED — 0 MAJOR, 0 MINOR, 2 INFO
Round-1 MAJOR-1 (AC5 JWKS cache + GenServer crash/restart) RESOLVED.
Round-1 MINOR-1 (AC6 indirect) RESOLVED. MINOR-3 (tampered string-append) RESOLVED.

## AC coverage — all 6 have ≥1 test
- AC1 oidc_plug_test (current_user @kai:test.local, not halted) + Godog ValidToken
- AC2 oidc_plug_expired_test (exact body)
- AC3 oidc_plug_test (true signature-segment corruption) + Godog TamperedToken
- AC4 oidc_plug_missing_token_test (exact body + non-Bearer case)
- AC5 jwks_cache_test: ttl_ms default 300_000; NEBU_OIDC_JWKS_TTL="120"→120_000; fetch-on-start via injected stub; crash/restart (Process.exit kill + monitor/poll-with-timeout, keys/0 repopulated, fetcher re-invoked)
- AC6 Godog OidcMigration_ElixirAuthorsRejection (asserts errcode + non-empty error envelope = Elixir-authored) + HealthUnprotected

## JwksCache public-API contract (dev must implement exactly)
- start_link(opts): :fetcher (0-arity fun returning {:ok,[jwk]} OR module w/ fetch_jwks/0); fallback Application env :nebu_http,:jwks_fetcher; then real HTTP via :nebu_http,:oidc_jwks_uri. :name default NebuHttp.JwksCache.
- keys/0 → list of cached JWK maps from state.
- ttl_ms/0 → integer ms. default 300_000; NEBU_OIDC_JWKS_TTL (seconds) → *1000.
- Registered under module name so it survives crash/restart re-resolution.

## OidcPlug contract (from round 1)
- Module NebuHttp.Plugs.OidcPlug. Reads :nebu_http :oidc_issuer, :oidc_audience, :server_name. Selects JWK by token-header kid. On success: conn.assigns.current_user = "@<sub>:<server_name>", not halted. On failure: 401 JSON Matrix error, halted. Test JWKS override: Application env :nebu_http,:oidc_jwks (list).
- Error contract: missing/non-Bearer → M_MISSING_TOKEN "Missing access token"; expired → M_UNKNOWN_TOKEN "Access token has expired"; bad sig → M_UNKNOWN_TOKEN. All content-type application/json, 401, halted.

## INFO (non-blocking)
- INFO-1 duplicated RSA-keygen setup across two test files — extract helper if a 3rd added.
- INFO-2 MINOR-2: three Godog step defs undefined by design — dev implements in Gate 2.

## Notes for dev
- Router: insert OidcPlug after Plug.Parsers, scoped to PROTECTED routes only (NOT /health).
- assent v0.3.1 + jose 1.11 in mix.lock. Use Assent.JWTAdapter.verify(token, jwk, opts) → {:ok,%{"verified?"=>_,"claims"=>_,"header"=>_}}.
- AC6: patch Go auth middleware to pass-through (no validation).
