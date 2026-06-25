---
epic: element-compat
story: element-startup-stubs
security_review: not-needed
baseline_commit: 41b0576f451ba8a90f7504977ed9c114a1d07b39
---

# Story: Element Web Startup Stub Endpoints

Status: review

## Story

As an Element Web 1.12.15 client,
I want all startup-phase endpoints to respond with spec-valid stub responses,
so that the client can complete initialization and reach the key-generation dialog and /sync without hanging or retrying.

## Acceptance Criteria

1. `GET /_matrix/client/v3/thirdparty/protocols` returns `200 {}` (empty object, no protocols supported)
2. `GET /_matrix/client/v3/voip/turnServer` returns `404` with `{"errcode":"M_NOT_FOUND","error":"No TURN server configured"}` body
3. `GET /_matrix/client/v3/room_keys/version` returns `404` with `{"errcode":"M_NOT_FOUND","error":"No backup found"}` body
4. `GET /_matrix/client/unstable/org.matrix.msc3814.v1/dehydrated_device` returns `404` with `{"errcode":"M_NOT_FOUND","error":"No dehydrated device found"}` body
5. `GET /_matrix/client/unstable/org.matrix.msc4143/rtc/transports` returns `404` with `{"errcode":"M_NOT_FOUND","error":"No RTC transports"}` body
6. `POST /_matrix/client/v3/keys/device_signing/upload` returns `200 {}` (accept and acknowledge, no-op)
7. All endpoints are protected by OidcPlug — a request without a valid Bearer returns `401 M_MISSING_TOKEN`
8. All existing protected-router tests continue to pass (no regressions)

## Tasks / Subtasks

- [x] Add 6 route handlers to `server/lib/nebu/web/router/protected.ex` (AC: 1–7)
  - [x] `get "/client/v3/thirdparty/protocols"` → `send_json(conn, 200, %{})`
  - [x] `get "/client/v3/voip/turnServer"` → `send_json(conn, 404, %{"errcode" => "M_NOT_FOUND", "error" => "No TURN server configured"})`
  - [x] `get "/client/v3/room_keys/version"` → `send_json(conn, 404, %{"errcode" => "M_NOT_FOUND", "error" => "No backup found"})`
  - [x] `get "/client/unstable/org.matrix.msc3814.v1/dehydrated_device"` → `send_json(conn, 404, %{"errcode" => "M_NOT_FOUND", "error" => "No dehydrated device found"})`
  - [x] `get "/client/unstable/org.matrix.msc4143/rtc/transports"` → `send_json(conn, 404, %{"errcode" => "M_NOT_FOUND", "error" => "No RTC transports"})`
  - [x] `post "/client/v3/keys/device_signing/upload"` → `send_json(conn, 200, %{})`
- [x] Remove the now-incorrect comment in protected.ex that says these endpoints are left unimplemented (AC: 8)
- [x] Add unit tests to `server/test/nebu/matrix/matrix_client_compat_test.exs` (AC: 1–7)
  - [x] Auth-gate tests (no Bearer → 401) for all 6 new endpoints
  - [x] Contract-response tests (valid Bearer, no DB) for all 6 new endpoints

## Dev Notes

### Where to add the routes

File to modify: `server/lib/nebu/web/router/protected.ex`

The 6 new routes belong in the **"Client startup endpoints (Element compatibility)"** section at line ~161, alongside the existing `capabilities`, `pushrules/`, `keys/query`, `keys/upload`, `user/:id/filter`, and `account_data` stubs. Place them BEFORE the `match _` catch-all at line 963.

The existing comment at lines 165–166 says:
```
# Optional endpoints Element tolerates as 404 — room_keys/version, voip/turnServer,
# thirdparty/protocols, dehydrated_device, unset account_data — are left unimplemented.
```
This comment is now incorrect — update it to reflect that these are implemented.

### Pattern to follow exactly

Every existing stub in the file follows one of two patterns:

**Pattern A — static 200:**
```elixir
get "/client/v3/capabilities" do
  send_json(conn, 200, %{...})
end
```

**Pattern B — M_NOT_FOUND 404:**
```elixir
# No equivalent exists yet — this story adds the first ones.
```

Use `send_json/3` from `Nebu.Matrix.Http` (already imported via `import Nebu.Matrix.Http` at the top of the module). Do NOT use `error/4` for these stub 404s; use `send_json(conn, 404, %{"errcode" => "...", "error" => "..."})` directly. The `error/4` helper is reserved for validation errors.

### Route paths

Plug.Router matches on the path AFTER the `/_matrix` prefix strip done by the top-level router. Verify against the existing patterns:

| Matrix spec path | Plug.Router clause |
|---|---|
| `/_matrix/client/v3/sync` | `get "/client/v3/sync"` |
| `/_matrix/client/v3/capabilities` | `get "/client/v3/capabilities"` |
| `/_matrix/client/unstable/org.matrix.msc2965/auth_issuer` | handled in public router |

Following this, the 6 new clauses are:
```elixir
get "/client/v3/thirdparty/protocols" do ... end
get "/client/v3/voip/turnServer" do ... end
get "/client/v3/room_keys/version" do ... end
get "/client/unstable/org.matrix.msc3814.v1/dehydrated_device" do ... end
get "/client/unstable/org.matrix.msc4143/rtc/transports" do ... end
post "/client/v3/keys/device_signing/upload" do ... end
```

Note the `unstable` path segments — these sit under `/_matrix/client/unstable/...` and are matched in the same protected router because the top-level router forwards all `/_matrix` traffic to protected (except the explicit unauthenticated forwards).

### Auth surface

All 6 routes are INSIDE the Protected router. The `plug Nebu.Web.Plugs.OidcPlug` is at the top of the pipeline — it runs before any `match` clause, so authentication is automatic. No per-handler auth code is needed.

### No DB, no business logic

Pure stub handlers — `conn` is the only input, no `body_params`, no `current_user`, no `Core.*` request structs. These are equivalent to `get "/client/v3/capabilities"` which also ignores the user identity.

### send_json/3 behavior

`send_json(conn, status, map)` is defined in `Nebu.Matrix.Http` (imported at module top). It calls `Jason.encode!/1` on the map and sends it with `Content-Type: application/json`. It also applies the `X-Content-Type-Options: nosniff` header via the pipeline. Do not call `Plug.Conn.send_resp` directly.

### Where to add the tests

File to modify: `server/test/nebu/matrix/matrix_client_compat_test.exs`

This test module already covers all the existing compatibility stubs. The new tests must follow the same two-layer structure:

1. **Auth gate tests** — add to the `describe "auth gate on the client-compat endpoints — no DB"` block. Each is a single-liner asserting `401 M_MISSING_TOKEN` when no Bearer is sent.

2. **Static contract tests** — add to the `describe "static contract responses — valid Bearer, no DB"` block. Each asserts the exact status code and body shape. For 200 endpoints assert `%{}`. For 404 endpoints assert `conn.status == 404` and `json(conn)["errcode"] == "M_NOT_FOUND"`.

No `@moduletag :integration` needed — these are pure Plug.Test unit tests with no DB.

### Test helper pattern (already in file)

```elixir
defp call(method, path, body \\ nil, headers \\ []) do
  conn =
    case body do
      nil -> conn(method, path)
      b -> conn(method, path, Jason.encode!(b)) |> put_req_header("content-type", "application/json")
    end
  conn = Enum.reduce(headers, conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)
  Nebu.Web.Router.call(conn, @router_opts)
end

defp auth(token), do: [{"authorization", "Bearer " <> token}]
defp json(conn), do: Jason.decode!(conn.resp_body)
```

Use these existing helpers — do NOT add new helpers.

### Regression constraint

The `match _` catch-all at the bottom of `protected.ex` currently returns `error(conn, 404, "M_NOT_FOUND", "Unrecognized request")`. The 6 new routes must be placed BEFORE this catch-all or they will never be reached. All existing routes — sync, logout, whoami, capabilities, pushrules, keys/query, keys/upload, filter, account_data, createRoom, join, invite, send, messages, initialSync, typing, receipt, presence, leave, forget, relations, hierarchy, members, event, read_markers, upgrade, search, profile, state — must continue working unchanged.

### Spec references

- `thirdparty/protocols` — Matrix CS API v1.18 §GET /thirdparty/protocols; `{}` means no protocols
- `voip/turnServer` — Matrix CS API v1.18 §GET /voip/turnServer; spec allows 404 M_NOT_FOUND
- `room_keys/version` — Matrix CS API v1.18 §GET /room_keys/version; spec defines 404 when no backup
- `dehydrated_device` — MSC3814 §GET /dehydrated_device; 404 M_NOT_FOUND when no device
- `rtc/transports` — MSC4143 §GET /rtc/transports; 404 M_NOT_FOUND when no transports
- `keys/device_signing/upload` — Matrix CS API v1.18 §POST /keys/device_signing/upload; `{}` acknowledges upload (ADR-011 managed E2EE, no-op store)

### ADR-011 note for device_signing/upload

The `POST /keys/device_signing/upload` endpoint accepts cross-signing key material from the client. Under ADR-011 (Managed E2EE, server-side decryption model) Nebu does not store or use per-user cross-signing keys — we acknowledge the upload silently (`200 {}`). This is the same pattern as `POST /keys/upload` which returns `{"one_time_key_counts": {}}`. For `device_signing/upload`, the response body is simply `{}` — the spec does not require any fields in the success response.

### Project Structure Notes

- Single OTP application, no umbrella — do not create new files; modify `protected.ex` and `matrix_client_compat_test.exs` only
- Public-API rule (ADR-020) — these stubs never call cross-domain functions; they are pure HTTP handlers
- No domain model (ADR-018) — no Ecto schemas, no DB queries
- ADR-019 — one `mix.exs`, one `Nebu.Application`; the new routes join the existing Protected router, not a new module

### References

- `server/lib/nebu/web/router/protected.ex` — the file to modify, lines 161–240 for existing startup stubs
- `server/test/nebu/matrix/matrix_client_compat_test.exs` — the test file to extend
- `server/lib/nebu/matrix/http.ex` — defines `send_json/3`, `error/4`, `stream/1`, `call_core/1`
- `docs/architecture/adr/` — ADR-011 (managed E2EE), ADR-018 (no domain model), ADR-019 (single OTP app), ADR-020 (public API rule)

## Acceptance Tests

### Tests written FIRST (before implementation code):

All tests are pure ExUnit / Plug.Test — no DB, no integration tag needed.

**Auth gate tests** (add to existing `describe "auth gate on the client-compat endpoints — no DB"` block):

1. `GET /thirdparty/protocols with NO Bearer → 401 M_MISSING_TOKEN` — ExUnit, Plug.Test
   - Given: no Bearer header
   - When: `GET /_matrix/client/v3/thirdparty/protocols`
   - Then: `conn.status == 401` and `json(conn)["errcode"] == "M_MISSING_TOKEN"`

2. `GET /voip/turnServer with NO Bearer → 401 M_MISSING_TOKEN` — ExUnit, Plug.Test
   - Given: no Bearer header
   - When: `GET /_matrix/client/v3/voip/turnServer`
   - Then: `conn.status == 401` and `json(conn)["errcode"] == "M_MISSING_TOKEN"`

3. `GET /room_keys/version with NO Bearer → 401 M_MISSING_TOKEN` — ExUnit, Plug.Test
   - Given: no Bearer header
   - When: `GET /_matrix/client/v3/room_keys/version`
   - Then: `conn.status == 401` and `json(conn)["errcode"] == "M_MISSING_TOKEN"`

4. `GET /unstable/.../dehydrated_device with NO Bearer → 401 M_MISSING_TOKEN` — ExUnit, Plug.Test
   - Given: no Bearer header
   - When: `GET /_matrix/client/unstable/org.matrix.msc3814.v1/dehydrated_device`
   - Then: `conn.status == 401` and `json(conn)["errcode"] == "M_MISSING_TOKEN"`

5. `GET /unstable/.../rtc/transports with NO Bearer → 401 M_MISSING_TOKEN` — ExUnit, Plug.Test
   - Given: no Bearer header
   - When: `GET /_matrix/client/unstable/org.matrix.msc4143/rtc/transports`
   - Then: `conn.status == 401` and `json(conn)["errcode"] == "M_MISSING_TOKEN"`

6. `POST /keys/device_signing/upload with NO Bearer → 401 M_MISSING_TOKEN` — ExUnit, Plug.Test
   - Given: no Bearer header
   - When: `POST /_matrix/client/v3/keys/device_signing/upload`
   - Then: `conn.status == 401` and `json(conn)["errcode"] == "M_MISSING_TOKEN"`

**Contract response tests** (add to existing `describe "static contract responses — valid Bearer, no DB"` block):

7. `GET /thirdparty/protocols → 200 {}` — ExUnit, Plug.Test
   - Given: valid Bearer token from `setup_oidc_keys`
   - When: `GET /_matrix/client/v3/thirdparty/protocols`
   - Then: `conn.status == 200` and `json(conn) == %{}`

8. `GET /voip/turnServer → 404 M_NOT_FOUND` — ExUnit, Plug.Test
   - Given: valid Bearer token
   - When: `GET /_matrix/client/v3/voip/turnServer`
   - Then: `conn.status == 404` and `json(conn)["errcode"] == "M_NOT_FOUND"`

9. `GET /room_keys/version → 404 M_NOT_FOUND` — ExUnit, Plug.Test
   - Given: valid Bearer token
   - When: `GET /_matrix/client/v3/room_keys/version`
   - Then: `conn.status == 404` and `json(conn)["errcode"] == "M_NOT_FOUND"`

10. `GET /unstable/.../dehydrated_device → 404 M_NOT_FOUND` — ExUnit, Plug.Test
    - Given: valid Bearer token
    - When: `GET /_matrix/client/unstable/org.matrix.msc3814.v1/dehydrated_device`
    - Then: `conn.status == 404` and `json(conn)["errcode"] == "M_NOT_FOUND"`

11. `GET /unstable/.../rtc/transports → 404 M_NOT_FOUND` — ExUnit, Plug.Test
    - Given: valid Bearer token
    - When: `GET /_matrix/client/unstable/org.matrix.msc4143/rtc/transports`
    - Then: `conn.status == 404` and `json(conn)["errcode"] == "M_NOT_FOUND"`

12. `POST /keys/device_signing/upload → 200 {}` — ExUnit, Plug.Test
    - Given: valid Bearer token
    - When: `POST /_matrix/client/v3/keys/device_signing/upload` with any JSON body
    - Then: `conn.status == 200` and `json(conn) == %{}`

## Dev Agent Record

### Agent Model Used

claude-sonnet-4-6

### Debug Log References

_No blockers encountered._

### Completion Notes List

- Implemented all 6 route handlers in `server/lib/nebu/web/router/protected.ex` in the "Client startup endpoints" section, before the `match _` catch-all.
- Updated the comment at lines 161–166 to remove the now-incorrect list of "unimplemented" endpoints.
- Tests were pre-written (red phase) in `matrix_client_compat_test.exs`. All 12 new tests (6 auth-gate + 6 contract) passed after implementation.
- Full suite: 31/31 compat tests pass; 894 total tests pass (0 regressions).
- All error strings match the pinned values from the test review: "No TURN server configured", "No backup found", "No dehydrated device found", "No RTC transports".
- `send_json/3` used directly for all handlers (not `error/4`), following the pattern specified in Dev Notes.
- No new files created; only two existing files modified.

### File List

- `server/lib/nebu/web/router/protected.ex` (modified — added 6 route handlers, updated comment)
- `server/test/nebu/matrix/matrix_client_compat_test.exs` (pre-existing tests, no modification needed)
