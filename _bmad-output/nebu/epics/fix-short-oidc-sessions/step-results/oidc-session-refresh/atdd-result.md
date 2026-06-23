# ATDD Result — oidc-session-refresh (Elixir re-target), 2026-06-22

Red-phase tests written; NO production code touched. `make test-unit-elixir` clean
(753 passed, 2 skipped, 106 excluded, 0 failures) → new files compile-parse; new
`:integration` tests correctly excluded from the unit profile (run via `make test-integration`).

## Test files created
1. `server/test/nebu/matrix/session/matrix_session_store_test.exs` (`@moduletag :integration`)
   — store CRUD + AC4 grace + AC6 unknown/used RT. Port of Go `matrix_session_store_test.go`.
2. `server/test/nebu/matrix/login_refresh_test.exs` (`@moduletag :integration`)
   — AC1 (opaque tokens), AC7 (JWT backward compat), AC2+AC3 (`/refresh` + new AT works for `/sync`,
   empty body → 400, unknown RT → 401), AC5 (expired opaque AT → 401 `M_UNKNOWN_TOKEN` soft_logout:true).
3. `e2e/features/element/auth/matrix-session-refresh.feature` + steps stub (AC8) — 3 Element-web
   scenarios, Authorization-Code+PKCE via Dex (no ROPC). Steps are pending/throwing stubs (red).

## RED confirmation
`Nebu.Matrix.Session.MatrixSessionStore` does not exist; no `/_matrix/client/v3/refresh` route;
`OidcPlug` has no opaque-token/soft_logout path → integration tests fail until dev implements.
Did NOT run `make test-integration` (needs full DB stack) — integration tests are compile-clean
and red-by-construction.

## Contracts the dev MUST satisfy (asserted by tests)
- Opaque token format: `:crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)` (64 lc hex, no dots).
- `MatrixSessionStore`: `create/1` & `revoke/1` & `mark_access_token_used/1` → `:ok`;
  `get_by_access_token/1` & `get_by_refresh_token/1` → `{:ok, sess} | :error`;
  `rotate_tokens/1` → `:ok | :error`. `sess` exposes `user_id`, `device_id`, `expires_at`.
  `create/1`/`rotate_tokens/1` take maps; `:oidc_refresh_token` optional/nilable.
- Grace/expiry timing manipulated via direct SQL UPDATEs in tests — keep deterministic (no sleeps).

## NEW SEAM the dev must wire
Tests drive the real SSO redirect→callback→loginToken→`POST /login` flow and extend the
`:matrix_sso_token_override` seam (sso_login.ex:317) to a **3-tuple** `{:ok, id_token, oidc_refresh_token}`.
Dev must: accept the 3-tuple in the exchange seam (keep legacy `{:ok, id_token}` 2-tuple working for
AC7/no-RT), and thread the OIDC RT through `SsoStore` (login token carries it) into
`provision_and_respond`.

ATDD subagent id (resumable): ac5d425e79857fd5d
