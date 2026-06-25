---
id: sync-nginx-timeout
epic: element-compat
status: in-progress
security_review: not-needed
---

# Story: Fix /sync 504 Gateway Timeout

## Story

As a Matrix client user logging in via SSO, I should not receive a 504 Gateway Timeout on `/sync`, so that Element Web completes its startup successfully.

After Keycloak SSO login, Element Web makes two kinds of sync requests that can 504:

1. **Initial sync** (`GET /sync` with no `?since=`): `get_initial_sync` runs directly in the HTTP request process with no timeout guard. For a user with pre-existing rooms, sequential room fetching (1 DB query + N GenServer/DB calls per room) can exceed the 90-second nginx `proxy_read_timeout`.

2. **Long-poll incremental sync** (`GET /sync?since=<token>&timeout=30000`): The server holds the connection for up to 30,000ms. The Stackit Application Load Balancer (L7 HTTPS ALB) sits in front of nginx and has a backend connection timeout (~60s). A 30s hold plus network overhead can exceed the ALB window when Bandit is under startup load (multiple concurrent Element requests), causing the ALB to return 504 before Bandit sends the response.

**Deployment chain**: Client → Stackit ALB (unknown backend timeout, est. 60s) → nginx (proxy_read_timeout=90s) → Bandit:4000

**Matrix spec note (from Oracle)**: The `timeout` parameter is advisory — servers are explicitly allowed to use a shorter hold time. Returning an error from the origin server for a slow initial sync is NOT spec-compliant; initial sync must return 200.

## Acceptance Criteria

**AC1 — Reduce max long-poll timeout**: The server-enforced maximum long-poll hold time is reduced from 30,000ms to 25,000ms. This gives at least 5 seconds of margin against any proxy timeout tuned near 30 seconds.

**AC2 — Initial sync parallelises room fetching**: The `get_initial_sync` room-fetch loop (`Enum.flat_map/2` over room_ids) is replaced with `Task.async_stream` (max_concurrency: 10) so all rooms are fetched concurrently. This prevents sequential DB/GenServer calls from stacking up and keeps the initial sync well within the proxy timeout window for users with many rooms.

**AC3 — Short-timeout long-poll returns promptly**: `GET /sync?since=<token>&timeout=500` returns an empty delta within 1.5 seconds (no events in queue), confirming the server respects the client-requested timeout and does not hold for the 30s maximum.

**AC4 — `parse_timeout/1` caps at 25,000ms**: The public-testable timeout parser returns 25,000 for inputs >= 25,000ms, and passes through values below that unchanged.

## Acceptance Tests

### Tests written FIRST (before implementation code):

1. **AC4 — `parse_timeout` cap is 25,000ms** — ExUnit unit test
   - Given: raw timeout strings "25000", "30000", "60000", "999999"
   - When: `parse_timeout/1` (now `def`, was `defp`) is called
   - Then: all return 25,000 (not 30,000)

2. **AC4 — `parse_timeout` passes through values below cap** — ExUnit unit test
   - Given: raw timeout strings "0", "100", "10000", "24999"
   - When: `parse_timeout/1` is called
   - Then: returns the parsed integer clamped to [0, 25_000]

3. **AC3 — Short-timeout sync returns promptly** — ExUnit :integration test
   - Given: an authenticated user with no pending events
   - When: `GET /sync?since=<valid_token>&timeout=500`
   - Then: response arrives in < 1,500ms with status 200 and a valid `next_batch`

4. **AC2 — Initial sync with multiple rooms returns correct shape** — ExUnit :integration test
   - Given: an authenticated user who has joined 3 rooms
   - When: `GET /sync` (no `?since=`)
   - Then: status 200, body has `next_batch` (binary), `rooms.join` contains all 3 room IDs, each with `state`, `timeline` keys

## Dev Notes

- `parse_timeout/1` was `defp` — promote to `def` with `@doc false` to make it unit-testable.
- The long-poll timeout cap lives in TWO places: `server.ex` line ~2365 (`timeout_ms |> max(0) |> min(30_000)`) and `protected.ex` line ~1102 (`v |> max(0) |> min(30_000)`). Both must change to `min(25_000)`.
- `get_initial_sync` in `server.ex`: replace `Enum.flat_map(room_ids, fn room_id -> ... end)` with `Task.async_stream(room_ids, fn room_id -> ... end, max_concurrency: 10, timeout: 10_000, on_timeout: :kill_task, ordered: false) |> Enum.flat_map(fn {:ok, rooms} -> rooms; {:exit, _} -> [] end)`.
- AC1 cap applies only to the server-internal clamp. The `task_timeout` in `get_sync_delta` becomes `timeout_ms + 10_000 = max 35,000ms` — no change needed there.
- Test 3 (AC3) requires a valid since_token. Set one up by calling `GET /sync` first (no since) and using the returned `next_batch` as `since`.
