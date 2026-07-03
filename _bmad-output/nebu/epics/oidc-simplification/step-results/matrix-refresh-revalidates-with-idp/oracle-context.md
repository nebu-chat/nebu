## Matrix CS API Spec Requirements — `POST /_matrix/client/v3/refresh`

### Endpoint / Behavioral Rules (spec-cited, v1.18 §refreshing-access-tokens, §post_matrixclientv3refresh, §using-access-tokens, §soft-logout)
- Endpoint: `POST /_matrix/client/v3/refresh` (Added v1.3). Legacy-API refresh path — the only endpoint in scope.
- No event types apply (auth/token endpoint, not a room-event endpoint).
- Auth: endpoint MUST NOT require an access token — authentication is via the `refresh_token` in the body. AS identity assertion is disabled.
- Rate-limited: Yes (MUST support 429).
- Request body: `refresh_token` (string, **Required**).
- 200 body: `access_token` (**Required**), `expires_in_ms` (optional; omission = non-expiring — must match AC3 lifetime), `refresh_token` (optional; if given, old RT MUST be invalidated once new token used).
- MUST: when a new refresh token is returned, the old refresh token is invalidated / revoked once the new access or refresh token is used (token rotation). Old RT remains valid until new token used (retry safety).
- MUST: new access+refresh tokens are bound to the same device as the incoming refresh token.
- MUST: on invalid/unknown/already-used token → 401 `M_UNKNOWN_TOKEN`; SHOULD include `soft_logout: true` for expired-but-refreshable sessions.
- Note: `M_UNKNOWN_TOKEN` on other endpoints (using expired access token) SHOULD carry `soft_logout: true` — the trigger for the client to call `/refresh`.

### Error codes / HTTP status / edge cases that MUST be test-covered
- `200` — happy path: fresh IdP exchange succeeds, returns `access_token` (+ `expires_in_ms` from fresh id_token exp per AC3, + rotated `refresh_token` per AC4).
- `401 M_UNKNOWN_TOKEN` — unknown opaque refresh token.
- `401 M_UNKNOWN_TOKEN` — already-used / rotated (replayed) refresh token.
- `401 M_UNKNOWN_TOKEN` — IdP rejects refresh (expired/revoked/network error) → session invalidated, fail-closed (AC2).
- `401 M_UNKNOWN_TOKEN` — fresh id_token verify fails (`OidcPlug.verify_token/2`: sig/alg/iss/aud/exp) → session invalidated (AC2).
- `401 M_UNKNOWN_TOKEN` — deprovisioning / role-change detected in fresh claims → session invalidated (AC2).
- `400 M_MISSING_PARAM` / `M_BAD_JSON` — missing `refresh_token` in body (malformed request).
- `429 M_LIMIT_EXCEEDED` with `retry_after_ms` — rate-limited (endpoint is rate-limited per spec).
- Edge: IdP returns **no** new refresh_token → old encrypted OIDC-RT retained (AC4); `refresh_token` may be omitted from 200 response (client re-uses old opaque RT).
- Edge: `soft_logout: true` presence on the 401 (spec SHOULD) — assert it accompanies the fail-closed 401 so clients can re-login.
- Edge: token/device binding — new opaque tokens bound to same session/device row; verify no cross-device leakage.
- Regression: existing local-rotation tests remain green; happy path still mints valid opaque pair (AC6).

### Nebu-specific note (not spec, from story)
- No spec rule forces contacting the IdP on `/refresh` — that is a Nebu resource-server policy (AC1/AC2). The spec-observable contract is unchanged: 200 with new tokens or 401 `M_UNKNOWN_TOKEN`. All IdP-exchange/deprovisioning behavior is only observable via the 401-vs-200 outcome at the CS API level.

### Relevant file paths (from story context)
- `server/lib/nebu/web/http_public.ex:531-573` — current `/refresh` handler
- `server/lib/nebu/matrix/matrix_session_store.ex:179` — `rotate_tokens/1` (`new_oidc_rt` never supplied)
- `server/lib/nebu/admin/auth.ex:162-229` — `exchange_refresh_token/1` (correct reference pattern; AC5 shared-module source)
- Spec: matrix-spec/v1.18/client-server-api/index.html (lines 4309-4360, 6417-6601)
