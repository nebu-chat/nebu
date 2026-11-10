# Oracle context: token lookup DB error must not become 401 (Matrix v1.18)

## Endpoints in scope
- Every authenticated route behind OidcPlug: /_matrix/client/v3/*, /_matrix/client/v1/* (also v1/media/{config,download,thumbnail,preview_url}), /_matrix/media/v3/* (deprecated, frozen per v1.12)
- Token comes from `Authorization: Bearer` or the deprecated `?access_token=`. MUST support both ("Using access tokens"), so the 503 path MUST work for both transports
- No new endpoint, no event type, no sync/e2ee/room-version effect

## MUST / SHOULD rules (citations: client-server-api "Standard error response", "Using access tokens", "Soft logout", "Rate limiting")
- MUST: every error at Matrix API level is a standard error response; `errcode` and `error` MUST always be present -> 503 body `{"errcode":"M_UNKNOWN","error":"..."}`
- 401 + M_MISSING_TOKEN / M_UNKNOWN_TOKEN only when credentials are "missing or invalid". A DB failure means validity is unknown, so 401 is wrong
- M_UNKNOWN_TOKEN means: never valid / logged out / soft logged out / needs refresh. Clients then refresh, re-login, or treat as logged out
- soft_logout missing or false = "server has destroyed the session"; client persisted state (E2EE keys, device info) "must not be reused and must be discarded". A wrong 401 on a DB failure wipes client crypto state -> main reason for the fix
- soft_logout appears only on 401 M_UNKNOWN_TOKEN, so the 503 MUST NOT carry it
- Expired token: M_UNKNOWN_TOKEN, "preferably with soft_logout: true" (keep superseded/expired -> 401 + soft_logout true)
- M_UNKNOWN: "clients should prefer the HTTP status code" -> 503 M_UNKNOWN is the right retryable signal
- Retry-After: the spec only requires it (SHOULD) for 429. On 503 it is plain HTTP semantics (RFC 9110), not Matrix. `retry_after_ms` is deprecated and belongs to M_LIMIT_EXCEEDED, so do NOT add it to the 503
- Do NOT use 429/M_LIMIT_EXCEEDED for a DB failure (it means client rate limiting)
- M_UNAVAILABLE is NOT in v1.18 (0 hits in index.html/api.json). Do not use it. M_RESOURCE_LIMIT_EXCEEDED also does not fit (requires admin_contact, means a hosting quota)
- Media v1 download/thumbnail list 429/502 (M_TOO_LARGE)/504 (M_NOT_YET_UPLOADED). A 503 for an auth backend failure does not clash with these; never send 502/504 for it

## Status/errcode matrix that MUST be tested
- DB error (timeout, connection, pool exhausted, repo down) + valid token -> 503, M_UNKNOWN, Retry-After header, no soft_logout, no retry_after_ms, handler not run
- DB error + unknown/malformed opaque token -> the same 503 (no oracle); none authenticated
- No session row -> 401 M_UNKNOWN_TOKEN, no soft_logout (unchanged)
- Superseded/expired -> 401 M_UNKNOWN_TOKEN, soft_logout true (unchanged)
- Valid -> 200 (unchanged)
- Missing token -> 401 M_MISSING_TOKEN (unchanged, no DB call)

## Edge cases
- Test the 503 on a client route (e.g. GET /_matrix/client/v3/account/whoami) AND a media route (/_matrix/client/v1/media/config or download), since the AC says "any route that runs the OidcPlug"
- Test the token via query param `access_token` too: 503 response and log both redacted
- Response body and log MUST NOT contain the token, its hash, user_id, device_id, SQL, or the exception message. At most one log line, with a redacted error class only
- The 503 body MUST be valid JSON with Content-Type application/json (standard error response). Media routes must not fall back to an HTML/plain error
- Exception path (raise, e.g. DBConnection.ConnectionError / Postgrex timeout) and {:error, _} return path both map to 503, never fall through to 401
- If the plug can't reach the DB, it must not crash the request with a generic 500 that has no body. Expected is 503 M_UNKNOWN
