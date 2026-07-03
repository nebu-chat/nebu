# ATDD Output — admin-liveview-session-refresh

**Files created/modified:**
- `server/test/nebu/admin/admin_token_refresh_test.exs` — extended with 2 new tests (AC1, AC2), using
  `Phoenix.LiveViewTest.live_isolated/3` against the real `Nebu.Admin.DashboardLive` + real
  `Nebu.Admin.Auth.on_mount/4` gate. Pre-existing AC3/AC5/AC6 tests (10 tests) left untouched —
  verified still passing, confirming AC5 (HTTP-path regression) holds.
- `server/test/nebu/admin/admin_keepalive_test.exs` — new file, 4 tests for AC4, following the
  established `build_admin_conn`/`Nebu.Admin.Endpoint.call` pattern from
  `admin_http_controllers_test.exs` (real router, real `:browser` pipeline).

**Result: 16 tests total, 10 pass (pre-existing, untouched), 6 new tests fail — all RED for the
expected reason (missing route/mechanism, not typos/compile errors):**

1. `[AC1] ... an open Dashboard LiveView is force-logged-out at session_exp despite a live RT` —
   fails because `on_mount` unconditionally halts+redirects to `/admin/login` once `session_exp`
   passes; no refresh is ever attempted from the LiveView-reachable path, even with a valid stored RT.
2. `[AC2] ... a LiveView-reachable keepalive trigger refreshes the session before session_exp` —
   fails because no request path exists yet that re-triggers `fetch_current_user/2`'s silent-refresh
   leg from an idle LiveView socket.
3. `[AC4] GET /admin/keepalive as an authenticated admin returns a minimal success response` —
   fails: 404 (no route).
4. `[AC4] GET /admin/keepalive without an admin session is rejected exactly like any other admin
   route` — fails: 404 (route itself missing, not an auth rejection).
5. `[AC4] keepalive triggers the EXISTING silent-refresh leg (no new business logic) when inside the
   pre-expiry window` — fails: refresh never invoked (no route to trigger it).
6. `[AC4] keepalive with admin_oidc_refresh_mode = online (no refresh token) does not error or
   attempt a refresh` — fails: 404.

No typos/compile errors — all 6 failures are clean assertion failures pointing directly at the
missing `/admin/keepalive` route/controller and the missing LiveView-reachable refresh mechanism,
matching the story's root cause exactly. Ready for dev-story.
