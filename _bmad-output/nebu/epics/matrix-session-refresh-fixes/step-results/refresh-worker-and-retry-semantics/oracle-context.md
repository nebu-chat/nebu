# Oracle context — refresh-worker-and-retry-semantics (spec bundled: v1.18)

Sections: #refreshing-access-tokens, #soft-logout, #post_matrixclientv3refresh.

## Legacy API (applies to Nebu)
- /login: client opts in with `refresh_token: true`; response MAY carry `refresh_token`, `expires_in_ms`.
- POST /refresh: no access token; rate-limited; body `refresh_token` required. 200: `access_token` (req), `expires_in_ms`
  (opt; missing = never expires), `refresh_token` (opt; missing = reuse old).
- "The old refresh token remains valid until the new access token or refresh token is used, at which point the old
  refresh token is revoked." -> supports AC3, contradicts fixed 60s window.
- Old access token: server MAY revoke immediately or keep until expiry.
- New tokens bound to the original device; `device_id` must not change.
- Expired access token: `M_UNKNOWN_TOKEN` preferably with `soft_logout: true`.
- `soft_logout` defaults false. Missing/false => client MUST discard persisted state (E2EE keys, device). Therefore the
  server must NOT send `soft_logout: true` when the session was really destroyed.
- Spec says nothing about server-side background renewal; compliant only if the client's tokens stay valid.

## OAuth refresh grant only (not legacy /refresh)
- SHOULD rotate; MUST allow retry on lost response; SHOULD treat reuse of an invalidated token as compromise and revoke.
- Client: network/5xx => retry later with old token; 4xx => treat as logged out. => transient errors on /refresh MUST be 5xx.

## Test coverage required
- 200 with new access_token; expires_in_ms integer; refresh_token present when rotated.
- Replay old RT while new tokens unused: 200 (also after >60s, up to session expires_at).
- After first use of new AT -> old RT: 401 M_UNKNOWN_TOKEN. After first use of new RT -> old RT: 401 M_UNKNOWN_TOKEN.
- Garbage RT: 401 M_UNKNOWN_TOKEN. Missing refresh_token: 400. Rate limit: 429 M_LIMIT_EXCEEDED + retry_after_ms.
- Expired AT with valid RT: 401 M_UNKNOWN_TOKEN + soft_logout:true.
- After worker cycle: client's AT -> 200, client's RT -> 200.
- Concurrent /refresh same token: exactly one rotation wins; loser consistent 200 or 401, never 5xx/broken device.
- Reuse invalidation scoped to one device. device_id unchanged after refresh.
- Transient IdP/DB failure in /refresh: 5xx, not 4xx. Client without refresh_token:true: behavior unchanged.

## Open point decided in the story
- Reuse of a consumed RT destroys the session => `soft_logout` must be false/omitted (not true).
