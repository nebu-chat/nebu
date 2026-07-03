# Oracle Findings — Matrix CS API Compliance

## 1. Endpoints in scope
- `POST /_matrix/client/v3/login` (spec `post_matrixclientv3login`, added v1.3 refresh fields)
- `POST /_matrix/client/v3/refresh` (spec `post_matrixclientv3refresh`, added v1.3) — out-of-scope for IdP round-trip per story, but its response contract is adjacent
- Concept: `#refreshing-access-tokens`, `#soft-logout` (v1.3)

## 2. Login MUST requirements (spec)
- 200 response `access_token` (Required), `device_id` (Required), `user_id` (Required)
- Server MUST auto-generate `device_id` if client omits it
- Returned access token MUST be associated with the request/generated `device_id`
- `refresh_token` request field is a `boolean`; client opts in with `refresh_token: true`
- `refresh_token` + `expires_in_ms` in 200 are OPTIONAL (not MUST) — server MAY issue non-expiring tokens; if `expires_in_ms` absent, client assumes no expiry
- If a `refresh_token` is returned, `expires_in_ms` SHOULD accompany it (only a refreshable token needs expiry semantics)
- Handling of clients that do not support refresh tokens is explicitly homeserver's choice (JWT-only degrade is spec-legal)
- `token_type: "Bearer"` is not a spec login field (Nebu-specific extra; harmless, non-load-bearing)

## 3. Refresh MUST (contract, for regression only)
- Request `refresh_token` (Required string); 200 returns `access_token` (Required), optional `refresh_token`/`expires_in_ms`
- Unknown/used RT MUST → 401 `M_UNKNOWN_TOKEN` (with `soft_logout: true` preferred)

## 4. Error codes / status codes that MUST be test-covered
- Login: 200 happy; 400 (invalid/unrecognised login type); 403 `M_FORBIDDEN`; 429 rate-limited
- Refresh: 200; 400 `M_MISSING_PARAM` (empty/missing RT), 400 `M_NOT_JSON` (malformed body); 401 `M_UNKNOWN_TOKEN` (unknown/used/grace-expired)

## 5. Edge cases MUST be covered (story-critical)
- AC4 GAP (confirmed untested): `refresh_token: true` requested BUT IdP token-response omits `refresh_token` despite requested `offline_access` → MUST degrade to JWT-only 200 (no `refresh_token`/`expires_in_ms`), AND emit AC2 WARNING. `sso_login.ex:504-521` `extract_id_token` returns `nil` RT; `http_public.ex:409-421` respond_login/7 fallback logs and returns JWT — this branch has no test.
- AC2: WARNING log MUST match admin parity (`admin/auth.ex store_refresh_token/2` mentions "ensure the IdP grants offline_access"). Current Matrix log at `http_public.ex:416-420` says "verify the IdP grants offline_access" — verify wording is equally operator-actionable.
- AC1 diagnosis point: scope is built by `Nebu.Web.OidcScopes.resolve_scope(:matrix)` (`sso_login.ex:422`); `offline_access` only appended when `matrix_oidc_refresh_mode == "offline"`. Root cause (b) lives there; (c) lives in `extract_id_token`.
- Idempotency/no-op: JWT-only fallback MUST create no opaque session row (`respond_login/7` clause at `http_public.ex:409` correctly skips `MatrixSessionStore.create`).
- Log MUST NOT contain token values / PII (existing warnings pass `user_id` only — acceptable; do not add token).
- AC5: existing successful-RT and "refresh not requested" tests MUST stay green (behavior of the 2 existing `respond_login` clauses unchanged).

## Relevant files
- `/Users/philippbeyerlein/dev/01_gitlab/1200_philippb/open-chat/server/lib/nebu/matrix/sso_login.ex` (scope construction via OidcScopes; `extract_id_token/1` parsing — root-cause (b)/(c))
- `/Users/philippbeyerlein/dev/01_gitlab/1200_philippb/open-chat/server/lib/nebu/matrix/http_public.ex` (`respond_login/7` AC7 fallback lines 376-439; `do_refresh` 513+)
- `/Users/philippbeyerlein/dev/01_gitlab/1200_philippb/open-chat/server/test/nebu/matrix/login_refresh_test.exs` (add AC4 case; describe blocks at lines 332, 357)
- `/Users/philippbeyerlein/dev/01_gitlab/1200_philippb/open-chat/server/lib/nebu/admin/auth.ex` (`store_refresh_token/2` — AC2 log-parity reference)
