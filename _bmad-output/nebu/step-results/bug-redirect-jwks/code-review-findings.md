# Code Review Findings — bug-redirect-jwks — Cycle 0

## Summary: 0 MAJOR, 3 MINOR, 5 INFO

## MINOR-1: Discovery failures return `{:ok, []}` instead of `:error`
In `discover_jwks_uri_and_fetch/0`, the `else` branch returns `{:ok, []}` on any discovery failure. This bypasses the last-known-good key retention in `do_fetch/1` (which only keeps prior keys on `:error`). A transient network blip during boot-time fetch silently empties the key cache, causing all JWT validation to fail with 401 until the next TTL refresh. Fix: return `:error` in the `else` branch.

## MINOR-2: `:jwks_http_fetcher` seam has no production guard
The seam is checked unconditionally on every `fetch_jwks_over_http/1` call. An operator who accidentally ships the seam in production silently redirects all key fetches. Same risk exists for the existing `:jwks_fetcher` seam — no production guard there either. **Accepted as INFO**: consistent with existing seam patterns in the codebase; low marginal risk.

## MINOR-3: `server_name` is a Matrix identifier, not necessarily the admin HTTP hostname  
For split-hostname deployments (Matrix domain ≠ admin UI hostname), the derived redirect URI would be wrong. **Accepted as INFO**: Nebu is a single-domain deployment (ADR-019); `server_name` IS the public hostname by design. No split-hostname support is planned.

## INFO findings (5)
- OidcMetadata 5-min cache may delay jwks_uri changes (pre-existing, not introduced here)
- localhost:8008 heuristic doesn't match 127.0.0.1/0.0.0.0 (minor dev ergonomics)
- `derive_admin_redirect_uri/0` not covered by isolated unit test
- `on_exit` in login test missing `:server_name`/`:admin_session_secure` cleanup (latent)
- Stale comment in test references `:jwks_uri_fetcher` but impl uses `:jwks_http_fetcher`

## Action required
- MINOR-1: Fix `discover_jwks_uri_and_fetch/0` `else` to return `:error` instead of `{:ok, []}`
- MINOR-2: Accepted (consistent with existing pattern)
- MINOR-3: Accepted (single-domain design)
