---
epic: element-compat
story: account-data-get
security_review: not-needed
baseline_commit: 3d57da2710d04e09b0c20fb1e0c06f1ffc8a5a7f
---

# Story: GET account_data — ETS-backed account data store

Status: review

## Story

As an Element Web 1.12.15 client,
I want `GET /_matrix/client/v3/user/{userId}/account_data/{type}` to return data I previously stored via PUT,
so that secret storage key setup and cross-signing initialisation can complete without hanging on a 404.

## Acceptance Criteria

1. `PUT /_matrix/client/v3/user/{userId}/account_data/{type}` stores the request body in ETS keyed by `{user_id, type}` and returns `200 {}`
2. `GET /_matrix/client/v3/user/{userId}/account_data/{type}` reads from ETS and returns `200 <stored body>` when data exists
3. `GET /_matrix/client/v3/user/{userId}/account_data/{type}` returns `404 {"errcode":"M_NOT_FOUND","error":"Account data not found"}` when no data was previously stored for that key
4. Only the authenticated user can read/write their own account data — OidcPlug enforces auth; a request without a valid Bearer returns `401 M_MISSING_TOKEN`
5. Data survives multiple PUT-then-GET round trips within a single server session
6. All existing account_data tests and the full compat-test suite continue to pass (no regressions)

## Tasks / Subtasks

- [x] Create `server/lib/nebu/matrix/account_data_store.ex` — thin ETS wrapper (AC: 1–3, 5)
  - [x] Module attribute `@table :NebuAccountData`
  - [x] `init_table/0` — idempotent, same pattern as `Nebu.Web.TokenDenylist.init_table/0`
  - [x] `put/3` — `:ets.insert(@table, {{user_id, type}, json_body})` where `json_body` is the raw JSON string
  - [x] `get/2` — `:ets.lookup(@table, {user_id, type})`; returns `{:ok, json_body}` or `:error`
- [x] Wire `Nebu.Matrix.AccountDataStore.init_table/0` into `Nebu.Application.start/2` alongside the existing `TokenDenylist.init_table()` and `RateLimit.init_table()` calls (AC: 1–3)
- [x] Update `server/lib/nebu/web/router/protected.ex` — replace the no-op PUT and add a GET (AC: 1–4)
  - [x] Replace the no-op `put "/client/v3/user/:_user_id/account_data/:_type"` with a handler that reads `body_params(conn)`, re-encodes to JSON via `Jason.encode!/1`, calls `AccountDataStore.put/3`, returns `send_json(conn, 200, %{})`
  - [x] Add `get "/client/v3/user/:user_id/account_data/:type"` BEFORE the `match _` catch-all — reads from `AccountDataStore.get/2`, returns stored JSON on hit, `error(conn, 404, "M_NOT_FOUND", "Account data not found")` on miss
- [x] Add tests to `server/test/nebu/matrix/matrix_client_compat_test.exs` (AC: 1–6)
  - [x] Auth gate: `GET /account_data/{type}` with no Bearer → 401 M_MISSING_TOKEN
  - [x] Miss: `GET` of unknown key → 404 M_NOT_FOUND
  - [x] Round-trip: `PUT` then `GET` the same key → 200 stored body
  - [x] Isolation: two users cannot read each other's keys
  - [x] Multi round-trip: two sequential PUT+GET pairs overwrite correctly

## Dev Notes

### New file: `Nebu.Matrix.AccountDataStore`

Create `server/lib/nebu/matrix/account_data_store.ex`. This module is a pure ETS accessor — no GenServer needed. The table is owned by the application process (created in `Nebu.Application.start/2`), which means it survives any worker crash.

**Exact module shape to follow (mirrors `Nebu.Web.TokenDenylist` / `Nebu.Web.Plugs.RateLimit`):**

```elixir
defmodule Nebu.Matrix.AccountDataStore do
  @moduledoc """
  Volatile, node-local ETS store for per-user account data.
  ...
  """

  @table :NebuAccountData

  @spec init_table() :: :ok
  def init_table, do: ensure_table()

  @spec put(String.t(), String.t(), String.t()) :: :ok
  def put(user_id, type, json_body)
      when is_binary(user_id) and is_binary(type) and is_binary(json_body) do
    ensure_table()
    :ets.insert(@table, {{user_id, type}, json_body})
    :ok
  end

  @spec get(String.t(), String.t()) :: {:ok, String.t()} | :error
  def get(user_id, type) when is_binary(user_id) and is_binary(type) do
    ensure_table()
    case :ets.lookup(@table, {user_id, type}) do
      [{{^user_id, ^type}, body}] -> {:ok, body}
      [] -> :error
    end
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
          :ok
        rescue
          ArgumentError -> :ok
        end
      _ref -> :ok
    end
  end
end
```

Key design choices:
- `:public` so the Plug process can call `:ets.insert` directly without a GenServer serializer (same as `TokenDenylist`)
- `ensure_table()` called defensively in `put/3` and `get/2` (for unit tests that start without the Application)
- No cluster replication — account_data is node-local volatile stub per ADR-002/ADR-011
- No TTL or size limit — stub data for session lifetime only

### Changes to `Nebu.Application` — `server/lib/nebu/application.ex`

Add one line to the boot-time init block alongside the existing two `init_table()` calls (lines 31–32):

```elixir
    # existing:
    Nebu.Web.TokenDenylist.init_table()
    Nebu.Web.Plugs.RateLimit.init_table()
    # ADD:
    Nebu.Matrix.AccountDataStore.init_table()
```

This creates the ETS table before Bandit starts, eliminating any race between the first HTTP request and table creation (R-2 pattern established by the security re-review).

### Changes to `server/lib/nebu/web/router/protected.ex`

**Current state (lines 267–273):**
```elixir
  # GET/PUT /user/{userId}/account_data/{type} — per-user account data. Nebu has no
  # account-data store yet; GET of unset data is a spec-valid 404 (clients tolerate it),
  # and PUT is accepted as a no-op so client startup writes (breadcrumbs, recent emoji,
  # secret-storage bootstrap) don't error out and stall the app.
  put "/client/v3/user/:_user_id/account_data/:_type" do
    send_json(conn, 200, %{})
  end
```

**Replace with:**
```elixir
  # GET/PUT /user/{userId}/account_data/{type} — ETS-backed per-user account data stub.
  # PUT stores the JSON body; GET reads it back. Volatile (in-memory ETS, lost on restart).
  # ADR-011: managed E2EE stub; ADR-002: ETS for volatile data.
  put "/client/v3/user/:user_id/account_data/:type" do
    authenticated_user = conn.assigns[:current_user]
    decoded_user = URI.decode_www_form(user_id)
    decoded_type = URI.decode_www_form(type)

    if decoded_user != authenticated_user do
      error(conn, 403, "M_FORBIDDEN", "You can only write your own account data")
    else
      json_body = Jason.encode!(body_params(conn))
      Nebu.Matrix.AccountDataStore.put(decoded_user, decoded_type, json_body)
      send_json(conn, 200, %{})
    end
  end

  get "/client/v3/user/:user_id/account_data/:type" do
    authenticated_user = conn.assigns[:current_user]
    decoded_user = URI.decode_www_form(user_id)
    decoded_type = URI.decode_www_form(type)

    if decoded_user != authenticated_user do
      error(conn, 403, "M_FORBIDDEN", "You can only read your own account data")
    else
      case Nebu.Matrix.AccountDataStore.get(decoded_user, decoded_type) do
        {:ok, json_body} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, json_body)

        :error ->
          error(conn, 404, "M_NOT_FOUND", "Account data not found")
      end
    end
  end
```

**IMPORTANT — route placement:** The GET must be placed BEFORE the `match _` catch-all at the bottom of the file (currently line 998). The existing PUT was already before the catch-all; replace it in-place. The GET should be added immediately after the PUT (keep them together in the "Client startup endpoints" section).

**IMPORTANT — `send_resp` for GET:** The GET handler sends the pre-encoded JSON string directly via `send_resp/3` with `put_resp_content_type("application/json")` rather than `send_json/3`. This avoids double-encoding: the stored value is already a JSON string from `Jason.encode!/1`; calling `send_json/3` would call `Jason.encode!/1` again, escaping it as a string literal.

**IMPORTANT — path param names:** The current PUT uses `_user_id` and `_type` (prefixed with `_` to suppress unused-variable warnings since the body was previously ignored). The new handlers bind them as `user_id` and `type` so they can be used. Rename these in the route clauses.

**IMPORTANT — URL decoding:** Both `user_id` and `type` path params must be `URI.decode_www_form/1` before use, matching the pattern used throughout this file (e.g. `room_id`, `event_id`). Element sends `%40alice%3Aserver` for the user_id.

**403 guard:** The PUT (and GET) must verify `decoded_user == authenticated_user`. This prevents IDOR — user Alice cannot write (or read) Bob's account data. OidcPlug already ensures the token is valid; this guard ties the path param to the token identity.

### Tests in `server/test/nebu/matrix/matrix_client_compat_test.exs`

**Do NOT create a new test file.** Add to the existing `matrix_client_compat_test.exs` (441 lines as of baseline commit). Follow its exact structure:

1. **Auth gate test** — add to the `describe "auth gate on the client-compat endpoints — no DB"` block
2. **Behavioural tests** — add a NEW describe block `describe "account_data ETS store — no DB"` after the existing static-contract describe block

The test file already defines all needed helpers: `call/4`, `auth/1`, `json/1`, `setup_oidc_keys/0`, `bearer_for/2`, and the `@router_opts` module attribute. Use them as-is; do NOT add new helpers.

**CRITICAL — test isolation:** The ETS table `:NebuAccountData` persists across tests in the same test run (it is created at Application start time OR lazily by the first call). Tests must use unique keys to avoid cross-test contamination. Use the test name or a unique suffix in the type string (e.g., `"m.test.account_data_get_miss_#{:erlang.unique_integer()}"` or simply pick a type name unlikely to collide, like `"m.test.get_miss"` for a GET-only test).

**CRITICAL — no DB needed:** All account_data tests are pure unit tests (Plug.Test + ETS). No `@moduletag :integration` needed. The `Nebu.Matrix.AccountDataStore.init_table/0` call from Application boots the table before tests run IF the Application is started. If tests run without the Application (pure Plug.Test with just `@router_opts`), the `ensure_table()` guard in the store module creates it lazily on first access. Either way the tests work.

**Test for the 403 user mismatch:** One test should confirm that User A cannot read User B's data. Mint two separate tokens with `bearer_for("alice-acct", priv)` and `bearer_for("bob-acct", priv)` and verify the GET for the wrong user returns 403 M_FORBIDDEN.

### Pattern: using `send_resp` for pre-encoded JSON

The standard pattern throughout `protected.ex` is `send_json(conn, 200, map)`. However, when the value is already a JSON-encoded string (retrieved from ETS), use:

```elixir
conn
|> put_resp_content_type("application/json")
|> send_resp(200, json_body)
```

Both `send_json/3` (from `Nebu.Matrix.Http`) and `send_resp/3` (from `Plug.Conn`) are available — `Plug.Conn` is already implicitly available via `use Plug.Router`. `put_resp_content_type/2` is imported from `Plug.Conn` through `Plug.Router`.

### ADR Alignment

- **ADR-002** (No Redis, No NATS — ETS for volatile data): The account data store is an ETS table, not DB or Redis.
- **ADR-011** (Managed E2EE stub): The store is explicitly temporary — `m.secret_storage.default_key` and related types are part of cross-signing setup. Full server-side decryption is tracked separately.
- **ADR-018** (No domain model): No Ecto schema; the handler reads `body_params/1` and re-encodes inline.
- **ADR-019** (Single OTP app): New module goes under `lib/nebu/matrix/` — no new `mix.exs`, no new Application.
- **ADR-020** (Public-API rule): `AccountDataStore` is internal to the `Nebu.Matrix.*` namespace. The router (`Nebu.Web.*`) calls it directly, which is a cross-domain call. Given the `Nebu.Matrix` public API rule (ADR-020), the store module should either be placed under `Nebu.Web.*` or treated as a shared cross-cutting infrastructure module. Recommendation: place it at `server/lib/nebu/matrix/account_data_store.ex` and consider it a shared data-access helper (same disposition as `Nebu.Matrix.Http`). If code review objects to the cross-domain call, the module can be moved to `server/lib/nebu/web/account_data_store.ex` without any functional change.

### Regression constraint

These existing tests in `matrix_client_compat_test.exs` must still pass after this story:

```elixir
test "PUT /user/{userId}/account_data/{type} → 200 {}", %{user_id: uid, token: token} do
  conn = call(:put, "/_matrix/client/v3/user/#{URI.encode_www_form(uid)}/account_data/m.breadcrumbs",
    %{"recent_rooms" => []}, auth(token))
  assert conn.status == 200
  assert json(conn) == %{}
end
```

The new PUT handler must return `200 {}` (same as before) — **this test already exists and must keep passing.**

The entire 441-line test file must pass: 31 compat tests + initialSync integration test + whatever other tests exist.

### Spec reference

- Matrix CS API §PUT /user/{userId}/account_data/{type}: `200 {}` on success
- Matrix CS API §GET /user/{userId}/account_data/{type}: `200 <content>` on hit; `404 M_NOT_FOUND` on miss
- Both endpoints are authenticated (protected pipeline, OidcPlug)

### Project Structure Notes

- New file: `server/lib/nebu/matrix/account_data_store.ex` (module `Nebu.Matrix.AccountDataStore`)
- Modified: `server/lib/nebu/application.ex` — add `Nebu.Matrix.AccountDataStore.init_table()` call
- Modified: `server/lib/nebu/web/router/protected.ex` — replace PUT no-op, add GET handler
- Modified: `server/test/nebu/matrix/matrix_client_compat_test.exs` — add new tests

### References

- `server/lib/nebu/web/router/protected.ex` — lines 267–273 (current no-op PUT), line 998 (`match _` catch-all)
- `server/lib/nebu/web/token_denylist.ex` — `init_table/0`, `ensure_table/0`, ETS `:public` named table pattern
- `server/lib/nebu/web/plugs/rate_limit.ex` — `init_table/0` idiom for eager boot-time table creation
- `server/lib/nebu/application.ex` — lines 31–32 (existing `init_table` calls — add the new one after line 32)
- `server/test/nebu/matrix/matrix_client_compat_test.exs` — full test file structure, helpers, describe blocks
- `server/lib/nebu/matrix/http.ex` — `send_json/3`, `error/4` signatures

## Acceptance Tests

### Tests written FIRST (before implementation code):

All tests are pure ExUnit / Plug.Test — no DB, no `@moduletag :integration` needed.

**Auth gate test** (add to existing `describe "auth gate on the client-compat endpoints — no DB"` block):

1. `GET /account_data/{type} with NO Bearer → 401 M_MISSING_TOKEN` — ExUnit, Plug.Test
   - Given: no Bearer header
   - When: `GET /_matrix/client/v3/user/%40alice%3Atest.local/account_data/m.secret_storage.default_key`
   - Then: `conn.status == 401` and `json(conn)["errcode"] == "M_MISSING_TOKEN"`

**Behavioural tests** (new `describe "account_data ETS store — no DB"` block):

2. `GET unknown key → 404 M_NOT_FOUND` — ExUnit, Plug.Test
   - Given: valid Bearer for user `@alice:test.local`
   - When: `GET /_matrix/client/v3/user/<alice_encoded>/account_data/m.unknown.key.#{unique}`
   - Then: `conn.status == 404` and `json(conn)["errcode"] == "M_NOT_FOUND"` and `json(conn)["error"] == "Account data not found"`

3. `PUT then GET round-trip → stored body returned` — ExUnit, Plug.Test
   - Given: valid Bearer for `@alice:test.local`
   - When: `PUT /_matrix/client/v3/user/<alice>/account_data/m.secret_storage.default_key` with body `%{"key" => "abc123"}`
   - Then: `conn.status == 200` and `json(conn) == %{}`
   - When: `GET /_matrix/client/v3/user/<alice>/account_data/m.secret_storage.default_key`
   - Then: `conn.status == 200` and `json(conn) == %{"key" => "abc123"}`

4. `User isolation — Alice cannot read Bob's data` — ExUnit, Plug.Test
   - Given: Alice's Bearer; Bob has previously stored data under type `m.test.isolation`
   - When: `GET /_matrix/client/v3/user/<bob_encoded>/account_data/m.test.isolation` with Alice's Bearer
   - Then: `conn.status == 403` and `json(conn)["errcode"] == "M_FORBIDDEN"`

5. `PUT overwrites on second write, GET returns latest` — ExUnit, Plug.Test
   - Given: valid Bearer for `@alice:test.local`; a unique type `m.test.overwrite.#{unique}`
   - When: `PUT` with body `%{"v" => 1}`
   - Then: status 200
   - When: `PUT` same type with body `%{"v" => 2}`
   - Then: status 200
   - When: `GET` same type
   - Then: `conn.status == 200` and `json(conn)["v"] == 2`

6. `Existing PUT /account_data/{type} → 200 {} regression` — ExUnit, Plug.Test (already exists — must not break)
   - Given: valid Bearer
   - When: `PUT /_matrix/client/v3/user/<uid>/account_data/m.breadcrumbs` with `%{"recent_rooms" => []}`
   - Then: `conn.status == 200` and `json(conn) == %{}`

## Dev Agent Record

### Agent Model Used

claude-sonnet-4-6

### Debug Log References

No issues — all 4 previously RED tests turned GREEN with a single implementation pass. Full suite: 900 passed, 0 failed, 2 skipped, 140 excluded.

### Completion Notes List

- Created `Nebu.Matrix.AccountDataStore` — ETS-backed module following the `Nebu.Web.TokenDenylist` pattern: `:public` named table, idempotent `ensure_table/0`, `init_table/0` called from Application boot (pre-Bandit R-2 pattern).
- Wired `Nebu.Matrix.AccountDataStore.init_table()` into `Nebu.Application.start/2` after the existing `TokenDenylist` and `RateLimit` init calls.
- Replaced the no-op PUT in `protected.ex` with a handler that JSON-encodes `body_params/1` via `Jason.encode!/1`, stores in ETS, and returns `200 {}`. Added IDOR guard (403 M_FORBIDDEN if path user_id != authenticated_user).
- Added GET handler immediately after the PUT, using `send_resp(200, json_body)` + `put_resp_content_type("application/json")` to avoid double-encoding the pre-encoded ETS value. Returns 404 M_NOT_FOUND on miss.
- Tests (already existed in the test file from ATDD phase) all passed: auth gate (401), miss (404), PUT→GET round-trip (200), user isolation (403), overwrite (second PUT wins).

### File List

- server/lib/nebu/matrix/account_data_store.ex (new)
- server/lib/nebu/application.ex (modified — added AccountDataStore.init_table/0 call)
- server/lib/nebu/web/router/protected.ex (modified — replaced no-op PUT, added GET handler)
- server/test/nebu/matrix/matrix_client_compat_test.exs (tests were already present from ATDD phase — no changes needed)

## Change Log

- 2026-06-25: Implemented ETS-backed account data store (Nebu.Matrix.AccountDataStore), wired into Application boot, replaced no-op PUT and added GET handler in protected.ex. All 4 previously RED acceptance tests now GREEN; full suite 900 passed, 0 failed.
