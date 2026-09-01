---
story_id: 2a-post-media-create
title: "Async Upload Endpoints: POST /_matrix/media/v1/create"
epic: media-security-admin-control
status: review
security_review: required
ui: false
created: 2026-07-12
branch: feature/advanced-media-management
target_release: 0.3.0
---

## Summary

Implements `POST /_matrix/media/v1/create`, the reservation half of Matrix's async
upload flow (core-stable since spec `v1.7`; the historical "MSC2246" label is stale —
`v1.18` carries no MSC reference or `unstable` capability flag for it, so there is no
capability-discovery gate: clients simply try `/create` and fall back to the synchronous
`PUT /_matrix/media/v3/upload` on failure).

The endpoint takes **no request body and no query parameters** — a client-supplied
`expires_at` (as in an earlier internal draft) is not spec-conformant and is explicitly
out of scope. On success it reserves a `media_id`, writes a `media_files` row in
`:reserved` state via `Nebu.Media.StateMachine` (Story 1b), and returns an `mxc://`
content URI plus a server-chosen `unused_expires_at`. It does **not** accept, stream, or
persist any file bytes — that begins in Story 2b's
`PUT /_matrix/media/v3/upload/{serverName}/{mediaId}`, which is also the only place the
`:reserved → :quarantined` transition happens.

This story assumes Story 1a (`media_files` + `media_state_transitions` migration) and
Story 1b (`Nebu.Media.StateMachine` module) are already merged.

## User Story

As a Matrix client, I want to reserve an `mxc://` content URI before I have the file
bytes ready, so that I can prepare/compress/encrypt the upload client-side and later
`PUT` the bytes to a known, pre-agreed media ID — without blocking on a slow multipart
upload for the URI itself.

## Acceptance Criteria

1. **Reservation via the state machine.** A successful call creates exactly one
   `media_files` row through `Nebu.Media.StateMachine` (never a raw `INSERT` — same
   invariant as every other write to `media_files.state`, enforced by the Story 1b grep
   check and the DB-side append-only trigger on `media_state_transitions`, ADR-031). The
   row is created in `state: :reserved`, and `uploader_id` is set to the calling user's
   Matrix user ID (`conn.assigns.current_user`) — **required**, because Story 2b's
   ownership check on `PUT /upload` depends on it.
2. **Response shape (spec-conformant).** On success: `200 OK` with body
   `{"content_uri": "mxc://<server_name>/<media_id>", "unused_expires_at": <ms-epoch>}`.
   Both fields are **required** in the response. `unused_expires_at` is chosen
   **unilaterally by the server** (never by the client — no `expires_at` request
   parameter exists); the spec-recommended default is **24h** from creation. `content_uri`
   uses the same `mxc://` construction as the existing synchronous
   `PUT /_matrix/media/v3/upload` handler (`Nebu.Media.upload/1`).
   - **Status code note:** the epic and the Oracle spec review (session
     `2026-07-01`) agree the Matrix spec response is `200`, not `201` — this endpoint
     is documented here as `200 OK` on success. There is no ambiguity to resolve at
     dev time; do not introduce `201`.
3. **Pending-upload rate limit → 429.** A per-user limit `max_pending_per_user`
   (config-driven, default `20` — see "Open assumption: config source" below) caps how
   many `:reserved` rows (i.e., rows never followed by a successful `PUT`) a single
   `uploader_id` may hold at once. Exceeding it returns `429` with
   `{"errcode": "M_LIMIT_EXCEEDED", "error": "..."}` and a `retry_after_ms` field in the
   body (Matrix spec convention for `M_LIMIT_EXCEEDED` — see also the sibling pattern
   used for `M_LIMIT_EXCEEDED` in `Nebu.Matrix.SsoLogin`, which currently omits
   `retry_after_ms`; this endpoint's body **must** include it since the client has no
   other signal for when its pending-upload count will free up). This is a **counting
   check against `media_files`**, not the per-IP token-bucket `Nebu.Web.Plugs.RateLimit`
   used elsewhere in the media router — see Technical Requirements.
4. **Permission check → 403.** A caller without upload permission gets `403` with
   `{"errcode": "M_FORBIDDEN", "error": "..."}`. See "Open assumption: what 'no upload
   permission' means" below — this story defines it concretely as a **deactivated
   account** check, reusing the existing `{:error, :deactivated}` concept from
   `Nebu.Matrix.provision_identity/2`.
5. **`media_id`/`server_name` format matches Matrix conventions.** `server_name` is the
   single configured Nebu homeserver name (`Application.get_env(:nebu_http, :server_name,
   "localhost")` — Nebu does not federate, ADR-021/no-federation-by-design, so this is
   always the local server, never a caller-supplied value). `media_id` is an
   opaque, URL-safe, collision-resistant token — same generation scheme as the existing
   synchronous upload handler (`:crypto.strong_rand_bytes(16) |> Base.url_encode64(padding:
   false)`, ~128 bits of entropy) plus a DB-level uniqueness guarantee (see Technical
   Requirements) so entropy is a defense-in-depth measure, not the sole correctness
   argument.
6. **No request body / query parameters accepted.** The handler does not read or require
   a request body, and any query parameters (e.g. a client mistakenly sending
   `?expires_at=...`) are silently ignored, not rejected — this keeps the endpoint
   forward-compatible with clients written against the stale MSC2246 draft that may still
   send the parameter.
7. **Authentication.** Like every other route in `Nebu.Web.Router.Media`, this endpoint
   sits behind `Nebu.Web.Plugs.OidcPlug` — an unauthenticated call gets the standard
   `401 M_MISSING_TOKEN` / `401 M_UNKNOWN_TOKEN` response, not a new error shape.

### Open assumptions (flagged per task instructions — confirm with Oracle/Winston if wrong)

- **`actor_type` for a user-initiated reservation.** Story 1a's
  `media_state_transitions.actor_type` ENUM only has two values: `system` and `admin`.
  Neither is a perfect semantic fit for "an ordinary authenticated end user called a
  public API endpoint." This story's working assumption — consistent with Story 1b's
  note that `actor_id` is `NULL` only for *scanner* transitions — is: **`actor_type:
  :system`, `actor_id: <uploader's Matrix user ID>`**. Read: `:system` distinguishes
  "normal API/automated flow" from `:admin` (reserved for manual interventions via the
  Admin UI, Story 6), while `actor_id` still records *which* user/system-process
  triggered it. If Winston/Oracle intended a third actor bucket for end-user actions,
  the ENUM needs a migration follow-up — flagged here rather than guessed silently.
- **What "no upload permission" (AC4) means.** The epic text (`Story 2a` bullet 4) says
  only "`403 M_FORBIDDEN`, wenn der User keine Upload-Berechtigung hat" with no further
  elaboration anywhere else in the epic. There is currently no per-user "can upload"
  flag or room-scoped upload permission concept anywhere in `server/lib/nebu/`. This
  story's concrete interpretation: reuse the existing account-deactivation concept
  (`Nebu.Matrix.provision_identity/2`'s `{:error, :deactivated}`) as the only currently-
  known reason an authenticated Matrix user could lack upload permission. The check is
  implemented behind an injectable boundary (`:media_permission_module`, see Technical
  Requirements) specifically so a future, more granular permission model (e.g. a
  room-power-level check, or a Story 13-style compliance hold) can be swapped in without
  touching this handler again.
- **Config source for `max_pending_per_user`.** ADR-027 introduces `media_config` /
  `Nebu.Media.Config` for exactly this kind of admin-tunable value, but that module is
  built in Story 9a, which is **not** a dependency of 2a per the epic's dependency graph
  (`Story 2a — 1a, 1b`, no `9a`). This story therefore reads `max_pending_per_user` from
  `config.exs` (`Application.get_env(:nebu_http, :media_max_pending_per_user, 20)`) exactly
  like `Nebu.Media`'s existing `max_upload_bytes/0` reads `media_max_upload_bytes` — a
  later story (9a, or a 2a follow-up once 9a lands) can point this same key at
  `Nebu.Media.Config.get/0` without changing the call site here.

## Acceptance Tests

New test file: `server/test/nebu/media/media_create_test.exs`, following the existing
`media_upload_test.exs` conventions (`Nebu.Web.MediaTestSupport`, `Nebu.Web.MediaFakes`,
`Nebu.Web.Router.call/2` driving the full Plug pipeline, no live Postgres/S3).

### Tests written FIRST (RED phase):

1. **`"authenticated POST /create → 200 with content_uri + unused_expires_at, media_files row created via StateMachine in :reserved with correct uploader_id"`**
   - Given: a valid bearer token for `@uploader:test.local`, an injected
     `Nebu.Media.StateMachine` (or its DB seam) that records the call it received.
   - When: `POST /_matrix/media/v1/create` with no body.
   - Then: `conn.status == 200`; body has `content_uri` starting with
     `"mxc://test.local/"` and a numeric `unused_expires_at` in the future (ms-epoch,
     `> System.system_time(:millisecond)`); the injected state-machine seam was called
     with `to_state: :reserved`, `uploader_id/actor_id: "@uploader:test.local"` — never a
     direct SQL insert into `media_files`.

2. **`"POST /create twice returns two distinct media_ids"`**
   - Given: same authenticated user, two consecutive calls.
   - Then: both succeed, and the two `content_uri` values differ (collision-resistant
     generation, AC5).

3. **`"POST /create when max_pending_per_user is exceeded → 429 M_LIMIT_EXCEEDED with retry_after_ms"`**
   - Given: the injected pending-count seam reports the user already at (or above) the
     configured `max_pending_per_user` (e.g. set the config to `1` and pre-seed one
     `:reserved` row via the fake).
   - When: `POST /_matrix/media/v1/create`.
   - Then: `conn.status == 429`; body `errcode == "M_LIMIT_EXCEEDED"`; body has a numeric
     `retry_after_ms`; no new `media_files` row / state-machine call was made
     (`refute_received {:state_machine_called, _}` or equivalent).

4. **`"POST /create for a user without upload permission → 403 M_FORBIDDEN"`**
   - Given: the injected `:media_permission_module` fake reports `can_upload?/1 ==
     false` (or an equivalent deactivated-account signal) for the calling user.
   - Then: `conn.status == 403`; body `errcode == "M_FORBIDDEN"`; no `media_files` row
     created.

5. **`"POST /create without a Bearer token → 401 M_MISSING_TOKEN"`** and
   **`"POST /create with a garbage Bearer token → 401 M_UNKNOWN_TOKEN"`**
   - Mirrors the existing `media_upload_test.exs` auth tests — confirms `OidcPlug` gates
     this route too.

6. **`"POST /create ignores an expires_at query parameter instead of rejecting it"`**
   - Given: `POST /_matrix/media/v1/create?expires_at=1234567890`.
   - Then: `conn.status == 200`; the server-computed `unused_expires_at` in the response
     is **not** `1234567890` (i.e., the client-supplied value is provably ignored, not
     echoed back).

7. **DB-level / StateMachine unit test (belongs alongside 1b's own suite, referenced
   here for completeness):** `Nebu.Media.StateMachineTest` gains (or already has, if 1b
   ships first) a case asserting that a fresh reservation transition writes
   `from_state: nil` (or the sentinel Story 1b uses for "row does not yet exist"),
   `to_state: :reserved` into `media_state_transitions` with the `actor_type`/`actor_id`
   shape from the "Open assumptions" section above. This story's handler test (test 1
   above) only asserts the *seam was invoked correctly*; the transition-row shape itself
   is 1b's contract.

## Technical Requirements

### 1. Router — `server/lib/nebu/web/router/media.ex`

Add a new route inside the existing `Nebu.Web.Router.Media` Plug router (which already
runs `OidcPlug` for every route in its pipeline — no new auth wiring needed):

```elixir
post "/v1/create" do
  Media.create(conn)
end
```

No new rate-limit plug tier is needed here (unlike `preview_url`/`upload`'s per-IP
`Nebu.Web.Plugs.RateLimit`) — AC3's 429 is a **per-user pending-count** check, not a
per-IP token bucket, and belongs inside `Nebu.Media.create/1`, not the router pipeline.

### 2. Handler — `server/lib/nebu/media.ex`

New public function `Nebu.Media.create/1`, following the existing handler shape
(`upload/1`, `download/4`, boundary-module pattern documented in the moduledoc):

```elixir
@spec create(Plug.Conn.t()) :: Plug.Conn.t()
def create(conn) do
  user = conn.assigns[:current_user]

  cond do
    not permission_module().can_upload?(user) ->
      error(conn, 403, "M_FORBIDDEN", "You do not have permission to upload media")

    pending_count_exceeded?(user) ->
      error_with_retry(conn, 429, "M_LIMIT_EXCEEDED", "Too many pending uploads", retry_after_ms())

    true ->
      do_create(conn, user)
  end
end

defp do_create(conn, user) do
  server = server_name()
  media_id = generate_media_id()
  now_ms = System.system_time(:millisecond)
  expires_at = now_ms + unused_expires_ms()

  case Nebu.Media.StateMachine.reserve(%{
         media_id: media_id,
         server_name: server,
         uploader_id: user,
         unused_expires_at: expires_at
       }) do
    :ok ->
      send_json(conn, 200, %{
        "content_uri" => "mxc://#{server}/#{media_id}",
        "unused_expires_at" => expires_at
      })

    {:error, :media_id_taken} ->
      # Extremely unlikely (128-bit random collision) — regenerate once rather
      # than surface a 500 for a transient PK collision. See "collision-resistant
      # media_id" below.
      do_create(conn, user)

    {:error, _reason} ->
      error(conn, 500, "M_UNKNOWN", "Failed to reserve media")
  end
end
```

The exact function names on `Nebu.Media.StateMachine` are Story 1b's contract; this
story assumes a `reserve/1`-shaped entry point that performs the `INSERT ... state =
'reserved'` plus the corresponding `media_state_transitions` append in one call (Story
1b's module is the only code path allowed to touch `media_files.state`). If 1b's actual
public function has a different name/shape (e.g. `transition/3` from a `nil`
pseudo-state), adapt the call site accordingly — the acceptance tests assert on
observable behavior (HTTP response + injected seam invocation), not the literal function
name.

### 3. Pending-count check (AC3)

A `COUNT(*) FROM media_files WHERE uploader_id = $1 AND state = 'reserved'` (inline SQL,
ADR-018, likely living in `Nebu.Media.DB` alongside the existing `lookup/2`/`insert/1`)
compared against `max_pending_per_user`. This is intentionally **not** routed through
`Nebu.Web.Plugs.RateLimit` (that plug is a per-IP token bucket for abuse/DoS controls,
e.g. login and `preview_url`/`upload`; AC3 is a **business limit** on outstanding
reservations per identity, unrelated to request rate). Inject this as a swappable
boundary for the test suite the same way `media_db_module` already is, so tests don't
need a live Postgres.

### 4. Permission check (AC4)

New injectable boundary `:media_permission_module` (default:
`Nebu.Media.Permission`, mirroring the existing `:media_storage_module` /
`:media_db_module` / `:media_membership_module` seams documented in `Nebu.Media`'s
moduledoc), exposing `can_upload?(user_id) :: boolean`. The production default checks
account-deactivation status via `Nebu.Matrix`'s public API (ADR-020 — cross-domain calls
only through `Nebu.Matrix`/`Nebu.Media`/`Nebu.Admin`'s public module), reusing the
`{:error, :deactivated}` concept already present in `Nebu.Matrix.provision_identity/2`.
A fake in `media_fakes.exs` (`Nebu.Web.MediaFakes.Permission`) follows the existing
function-backed-fake pattern (`Application.get_env(:nebu_http, :media_permission_fun)`).

### 5. `media_id` generation (AC5, collision-resistance)

Reuse the existing scheme verbatim: `:crypto.strong_rand_bytes(16) |>
Base.url_encode64(padding: false)` — 128 bits of entropy is the primary
collision-resistance argument (matches the already-shipped synchronous
`PUT /_matrix/media/v3/upload` handler, `Nebu.Media.generate_media_id/0` — this story
should call the same private helper or extract it to a shared one rather than
duplicating it). As defense-in-depth (not because entropy is expected to fail in
practice), a `UNIQUE (server_name, media_id)` constraint already exists from Story 1a's
migration on `media_files`; a constraint-violation from `StateMachine.reserve/1` should
be treated as `{:error, :media_id_taken}` and trigger exactly one silent regeneration
retry (see `do_create/2` above), not an error response to the client.

### 6. Auth/permission check placement

Order matters for correctness, not just style: the **permission check (403) runs before
the pending-count check (429)** — a user who is not allowed to upload at all should not
learn anything about their pending-upload count via a different error code. `OidcPlug`
(401, unauthenticated) always runs first as router-pipeline middleware, before either.

## File List

| File | Change Type | Change |
|---|---|---|
| `server/lib/nebu/web/router/media.ex` | UPDATE | Add `post "/v1/create"` route |
| `server/lib/nebu/media.ex` | UPDATE | Add `create/1` handler + boundary resolution helpers (`permission_module/0`, `max_pending_per_user/0`, `unused_expires_ms/0`) |
| `server/lib/nebu/media/permission.ex` | NEW | Production `:media_permission_module` default — `can_upload?/1` via `Nebu.Matrix` public API |
| `server/lib/nebu/media/db.ex` | UPDATE | Add pending-reservation-count query (or equivalent seam) alongside existing `lookup/2`/`insert/1` |
| `server/test/nebu/media/media_create_test.exs` | NEW | Acceptance tests, see above |
| `server/test/nebu/media/media_fakes.exs` | UPDATE | Add `Nebu.Web.MediaFakes.Permission` fake |
| `server/test/nebu/media/media_test_support.exs` | UPDATE | Add helper(s) as needed for reserved-row fixtures |

Depends on (but does not modify) files delivered by Story 1a/1b:
`server/lib/nebu/media/state_machine.ex`, the `media_files`/`media_state_transitions`
migration under `server/priv/migrations/`.

## Dev Agent Guardrails

### Do Not Change

- The existing synchronous `PUT /_matrix/media/v3/upload` handler (`Nebu.Media.upload/1`)
  and its tests (`media_upload_test.exs`) — Story 2c is the story that unifies the sync
  and async paths onto one shared storage pipeline; 2a must not touch that flow.
- `Nebu.Media.download/4`, `thumbnail/3`, `preview_url/1` and their download-gate
  behavior — untouched by this story (Story 1c/2d own the download-gate/stall logic).
- The `media_files`/`media_state_transitions` migration (Story 1a) and the
  `Nebu.Media.StateMachine` module's public contract (Story 1b) — this story is a
  **consumer** of both, not their owner. If the migration or module genuinely need a
  change to support this story, that is a sign the dependency story was underspecified —
  flag it rather than quietly extending 1a/1b's scope inside a 2a PR.
- `Nebu.Web.Plugs.RateLimit` — do not add a new tier for `/v1/create`; AC3's 429 is a
  business/pending-count limit, not a per-IP abuse control (see Technical Requirements
  §3).

### Critical: this story does NOT touch upload bytes

`POST /v1/create` never reads a request body, never calls `Nebu.Media.Storage`, never
calls `Nebu.Media.Crypto`, and never transitions a row out of `:reserved`. All of that —
receiving the `PUT`, ownership check, `409 M_CANNOT_OVERWRITE_MEDIA`, SHA-256 on received
bytes, compression + encryption + S3 write, and the `:reserved → :quarantined` transition
— is Story 2b's scope. A correct 2a implementation stores **zero bytes**; if a review
finds this handler touching `Nebu.Media.Storage`/`Crypto`, that is scope creep into 2b.

### Critical: no client-supplied expiry

Do not read, trust, or persist any client-supplied `expires_at` value from query
parameters or body — `unused_expires_at` is always server-computed (AC2, AC6). This was
an explicit correction from the Oracle spec review; reintroducing a client-controlled
expiry would both violate the spec and reopen a since-closed review finding.

## Dependencies

- **Depends on:** `1a-media-files-migration` (schema: `media_files`,
  `media_state_transitions`, the `UNIQUE (server_name, media_id)` constraint this story
  relies on for collision defense-in-depth), `1b-state-machine-module`
  (`Nebu.Media.StateMachine`'s reservation entry point — the only permitted writer of
  `media_files.state`).
- **Enables:** `2b-put-media-upload` (`PUT /_matrix/media/v3/upload/{serverName}/{mediaId}`
  — consumes the `:reserved` row and `uploader_id` this story creates, performs the
  ownership check against it, and drives the `:reserved → :quarantined` transition).
- **Not a dependency:** `9a-media-config-table` — `max_pending_per_user` reads from
  `config.exs` in this story (see "Open assumptions" above) precisely because 9a is not
  yet available at this point in the build order; do not add a 9a dependency to make this
  story "more correct" — that is out of scope and would violate the epic's stated
  dependency graph (`Story 2a — 1a, 1b`).

## Dev Agent Record

### Implementation Notes (dev-story, cycle 0)

The coordinator's corrected technical design (see this story's own header note
in `media_create_test.exs`'s moduledoc) supersedes the "Technical
Requirements" section's original `StateMachine.reserve/1` sketch. What was
actually built:

- **`Nebu.Media.StateMachine.create/1`** (`server/lib/nebu/media/state_machine.ex`)
  — a NEW genesis function alongside the existing (untouched) `transition/4`.
  In one `Repo.transaction/1`: INSERTs a `media_files` row
  (`state: 'reserved'`, `uploader_user_id` set, placeholder `""`/`0` for
  `content_type`/`file_size`/`aes_key_hex`/`nonce_hex` — all pre-existing
  `NOT NULL` columns from `000001_init.up.sql` with no real value yet) plus
  the genesis `media_state_transitions` row (`from_state: NULL, to_state:
  'reserved', actor_type: 'system', actor_id: NULL` — already legal under
  `transition/4`'s existing guard, no ENUM/guard change). Returns
  `{:ok, media_id}` or `{:error, :media_id_taken}` on a `media_files` PK
  `unique_violation`. No migration added — every column already existed.
- **`Nebu.Media.create/1`** (`server/lib/nebu/media.ex`) — permission check
  (403) before the pending-count check (429); collision-retry exactly once
  via a `retried?` flag on the private `do_create/3`; reuses the existing
  `generate_media_id/0`/`server_name/0` helpers verbatim. New boundary
  resolvers `permission_module/0`, `state_machine_module/0`,
  `max_pending_per_user/0` (default 20), `unused_expires_ms/0` (default
  86_400_000 = 24h), `retry_after_ms/0` (default 60_000) — all
  `Application.get_env(:nebu_http, ...)`-backed, same pattern as the existing
  `max_upload_bytes/0`.
- **`Nebu.Media.Permission`** (NEW `server/lib/nebu/media/permission.ex`) —
  `can_upload?/1` delegates to a NEW minimal public API addition,
  **`Nebu.Matrix.active?/1`** (`server/lib/nebu/matrix.ex`): a read-only
  (no side effects, unlike `provision_identity/2`) `is_active` lookup,
  fail-closed (`false`) on a DB error or unknown user. ADR-020 compliant —
  `Nebu.Media` never reaches into `Nebu.Matrix.Session.*`/
  `Nebu.Matrix.EventDispatcher.*` directly.
- **`Nebu.Media.DB.count_pending_reservations/1`** (AC3 seam) — inline SQL
  `COUNT(*) ... WHERE uploader_user_id = $1 AND state = 'reserved'`,
  degrades to `0` on a DB error (soft business limit, not a security
  control).
- **Router**: `post "/v1/create"` added to `Nebu.Web.Router.Media`, no new
  `RateLimit` tier (per Technical Requirements §3 — AC3's 429 is a business
  check, not per-IP abuse control).

### Verification

- `mix test test/nebu/media/media_create_test.exs` — 10/10 passed.
- `mix test --include integration test/nebu/media/state_machine_test.exs` —
  18/18 passed (against a live dockerized Postgres, migrations
  `000001`-`000024` applied via `Nebu.Release.migrate/0`), including the 3
  new `create/1` genesis tests.
- `mix test test/nebu/media/` (unit-only) — 160 passed, 2 skipped, 29
  excluded, 0 failed — no regressions in the media suite.
- `mix test --warnings-as-errors` (full suite, unit-only) — 1769 passed, 4
  skipped, 452 excluded, 0 failed.
- `mix compile --warnings-as-errors` — clean.
- Guardrails held: `media_upload_test.exs`/`Nebu.Media.upload/1`,
  `download/4`/`thumbnail/3`/`preview_url/1`, and `Nebu.Web.Plugs.RateLimit`
  were not touched; zero bytes read/stored; no client-supplied `expires_at`
  read or trusted anywhere.

### File List

| File | Change Type |
|---|---|
| `server/lib/nebu/web/router/media.ex` | UPDATE — `post "/v1/create"` route |
| `server/lib/nebu/media.ex` | UPDATE — `create/1` handler, `do_create/3`, `error_with_retry/4`, boundary resolvers |
| `server/lib/nebu/media/state_machine.ex` | UPDATE — new `create/1` genesis function (existing `transition/4` untouched) |
| `server/lib/nebu/media/permission.ex` | NEW — `Nebu.Media.Permission.can_upload?/1` |
| `server/lib/nebu/media/db.ex` | UPDATE — `count_pending_reservations/1` |
| `server/lib/nebu/matrix.ex` | UPDATE — new `active?/1` public API function |

No changes to `server/test/nebu/media/media_create_test.exs`,
`media_fakes.exs`, or `state_machine_test.exs` (already staged/ATDD'd) and no
new migration.
