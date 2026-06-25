# Oracle Context — sync-nginx-timeout

## Matrix Spec: GET /sync timeout parameter

- `timeout` is advisory — the server is explicitly allowed to use a shorter hold time (spec says "SHOULD wait up to"). Server caps are spec-compliant.
- When timeout expires with no events: return HTTP 200 with empty/minimal delta + `next_batch`. NOT 504 or any error.
- Initial sync (no `?since=`) has no `timeout` parameter in the spec. Must run to completion and return 200. Origin server must NOT return 504/M_TIMEOUT for slow initial sync.
- `M_TIMEOUT` is NOT a defined Matrix error code. Only canonical codes apply (M_FORBIDDEN, M_NOT_FOUND, etc.).

## Current Nebu caps (both must change to 25_000):
- `server.ex` line ~2365: `timeout_ms |> max(0) |> min(30_000)`
- `protected.ex` line ~1102: `v |> max(0) |> min(30_000)`

## Spec-compliant behavior after fix:
- Long-poll max: 25,000ms (reduced from 30,000ms) — spec-compliant reduction
- Initial sync: concurrent room fetch via Task.async_stream — returns 200 regardless
- Empty timeout: returns 200 with empty rooms immediately
