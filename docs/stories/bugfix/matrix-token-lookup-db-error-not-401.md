---
story: matrix-token-lookup-db-error-not-401
epic: bugfix
status: ready
security_review: required
matrix: true
ui: false
---

# Bugfix — a database error during the access-token lookup must not answer `401 M_UNKNOWN_TOKEN`

Found by the flake triage of the `oauth-pages-redesign` epic (story H, rows 14 and 15: `RoomKeysLimitsHttpTest` chunk 4 of 4 and
`MembershipWriteLimitsHttpTest` AC3 d got `401 M_UNKNOWN_TOKEN` for a valid, one hour old token under full-suite load).

## Problem

`Nebu.Matrix.Session.MatrixSessionStore.get_by_access_token_hash/1` maps EVERY non-row result of its query to `:error`, including a DB error, a pool
checkout timeout, a connection error and "repo not started" (`safe_query/2` rescues the exception into `{:error, e}`). `Nebu.Web.Plugs.OidcPlug.call_opaque/2`
answers `:error` with a hard `401 M_UNKNOWN_TOKEN` "Invalid or unknown token" (no `soft_logout`). A transient server-side failure therefore looks like
"token revoked": a real Matrix client treats `401 M_UNKNOWN_TOKEN` as "session invalid", drops/logs out the session and loses its E2EE keys.

Matrix spec v1.18 (client-server API, "Using access tokens" / error codes): `401 M_UNKNOWN_TOKEN` is reserved for an unknown, expired or invalid token.
A transient failure on the server must be a 5xx so that the client retries and keeps its session. The code base already does this for the refresh path
(`HttpPublic.refresh_unavailable/2`: 503 + `Retry-After`, `M_UNKNOWN`) and for the core dispatcher (`Nebu.Matrix.Http`: 503 `M_UNAVAILABLE`).

`OidcPlug.call/2` is the single authentication step of every client API route (`Router.Protected`), the media routes (`Router.Media`) and the
`/_matrix/client/v1/media` routes (`Router.ClientV1Media`); all three share the lookup.

## Acceptance criteria

```gherkin
Scenario: A failed token lookup is a retryable server error, not a session drop
  Given a valid opaque access token
  And the session lookup fails with a database error (timeout, connection error, pool exhaustion, repo not started)
  When the client sends an authenticated request on any route that runs the OidcPlug
  Then the response is 503 with errcode "M_UNKNOWN" and a Retry-After header
  And the response is not 401, does not carry errcode "M_UNKNOWN_TOKEN" and has no "soft_logout" member
  And the request is not authenticated and no handler runs (fail closed)

Scenario: A genuinely unknown token is still rejected with 401 M_UNKNOWN_TOKEN
  Given an opaque access token that has no session row
  When the client sends an authenticated request
  Then the response is 401 M_UNKNOWN_TOKEN without soft_logout, exactly as before
  And the response does not differ between "no row" and any other rejection reason in a way that reveals more than before

Scenario: A valid token is still accepted
  Given a valid opaque access token
  When the client sends an authenticated request
  Then the request is authenticated (200) as before

Scenario: Superseded and expired tokens keep their answers
  Given a soft-revoked (superseded) or an expired session
  When the client sends an authenticated request
  Then the response is 401 M_UNKNOWN_TOKEN with soft_logout true as before

Scenario: The failure is logged without sensitive data
  Given the session lookup fails with a database error
  When the client sends an authenticated request
  Then at most one log line is written for the failure and it names only a redacted error class
  And neither the access token, its hash, the user id, the device id, the SQL, nor the exception message appears in the log or in the response

Scenario: A lookup failure is not a token oracle
  Given a database outage
  When any token (valid, unknown, malformed) is presented
  Then every opaque token gets the same 503 answer and none is authenticated
```

## Notes

- Fix: `MatrixSessionStore.get_by_access_token/1` and `get_by_access_token_hash/1` return `{:ok, session} | :error | {:error, :unavailable}`
  (`:error` stays "no such row"). `safe_query/2` also catches `:exit` (pool checkout exits). `OidcPlug.call_opaque/2` answers `{:error, :unavailable}`
  with `503 M_UNKNOWN` + `Retry-After` (the same shape as `HttpPublic.refresh_unavailable/2`, no token material). The other caller of the hash lookup
  (`RefreshWorker.refresh_row/1`) skips the row on `{:error, :unavailable}` (it is retried by the next sweep; never deletes).
- The status/errcode of the failure case is the only change of the HTTP contract. No migration.
- Test seam: a compile-time guarded (`Mix.env() == :test`) fault injection in `get_by_access_token_hash/1`, like the other seams of the code base.
- Out of scope, reported only: JWT path (`DeviceBinding.lookup`, `provision/2`, `TokenDenylist`), `get_auth_context/1` (UIA freshness gate).
