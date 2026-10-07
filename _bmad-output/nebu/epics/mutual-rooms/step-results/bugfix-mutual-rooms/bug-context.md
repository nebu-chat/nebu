---
ui: false
security_review: required — new authenticated endpoint exposing a two-party room-membership intersection (IDOR/data-exposure class risk, same family Kassandra reviewed for the `fix-missing-matrix-room-routes` precedent); the "nonexistent user_id → 200 empty, not 404" rule is itself a user-enumeration defense that must be verified under adversarial review, not just ATDD.
---

# Bug: Implement GET /_matrix/client/v1/mutual_rooms (MSC2666)

## Story

As a Matrix client (e.g. Element Web rendering "Shared Rooms" on a user's profile card), I need
`GET /_matrix/client/v1/mutual_rooms?user_id=@other:server` to tell me which rooms I currently
share with another user, so the client can render that relationship without the user manually
cross-referencing every room's member list. Nebu implements the rest of the v1.18 Client-Server
surface (relations, hierarchy, media v1) but not this v1.19-new MSC2666 endpoint; every protected
route in this project already has a well-worn wiring pattern (auth, error envelopes, pagination)
this endpoint should reuse exactly, not reinvent.

## Verified architecture context

### 1. Router / endpoint wiring

- All authenticated Matrix CS routes live in `server/lib/nebu/web/router/protected.ex`
  (`Nebu.Web.Router.Protected`, `use Plug.Router` — a **plain Plug router, not Phoenix**).
  Pipeline (lines 29-32): `plug Nebu.Web.Plugs.OidcPlug` → `plug :fetch_query_params` →
  `plug :match` → `plug :dispatch`. Every route in this module is therefore already
  authenticated by construction.
- Top-level `server/lib/nebu/web/router.ex` forwards `"/_matrix"` to `Protected` as the
  catch-all (line 159: `forward "/_matrix", to: Nebu.Web.Router.Protected`), AFTER a short list
  of explicit unauthenticated forwards (login, refresh, uia fallback, auth_issuer/auth_metadata,
  public profile GET, media). `/_matrix/client/v1/mutual_rooms` is NOT one of those special
  cases, so it needs **zero changes to `router.ex`** — just a new route clause inside
  `protected.ex`.
- Exact style precedent for a `v1` GET endpoint, same file, two close analogues:
  - `GET /client/v1/rooms/:room_id/relations/:event_id[...]` (protected.ex:970-1010) — query
    params read via `conn.query_params`, delegates to a `defp do_relations/4` helper, calls
    `Nebu.Matrix.EventDispatcher.Server.get_relations/2` via `call_core/1`, maps `{:ok, resp}` /
    `{:error, err}` to `send_json/send_error`.
  - `GET /client/v1/rooms/:room_id/hierarchy` (protected.ex:1024-1063) — query-param parsing
    helpers return `{:ok, value} | {:error, :invalid_param}` and are composed with a `with`;
    on `{:error, :invalid_param}` falls through to `error(conn, 400, "M_INVALID_PARAM", ...)`
    (lines 1059-1062). This `with`-based param-validation shape is the best template for
    `mutual_rooms`' `user_id`/`from` validation.
  - Both live directly in `protected.ex`, are reached via the generic `/_matrix` forward (no
    special-cased router.ex entry), and call `Nebu.Matrix.EventDispatcher.Server` functions
    directly — see §8 on why this is the correct layering to copy (NOT `Nebu.Matrix` facade).
- Git history requested in the ticket: `bugfix/fix-matrix-client-v1-media-download-thumbnail-routes`
  (merge commit `e31ea69e`) added `server/lib/nebu/web/router/client_v1_media.ex` — but that's a
  **separate dedicated router** forwarded from `router.ex:111`, used only because its backend
  (`Nebu.Media.download/thumbnail`) lives in a different domain (`Nebu.Media`) and needed its own
  OidcPlug pipeline + narrow route surface (see that module's moduledoc for why it isn't just
  forwarded to the existing `Nebu.Web.Router.Media`). `mutual_rooms` has no such cross-domain
  concern — its data (room_members) is pure `Nebu.Matrix` domain — so it belongs directly in
  `protected.ex`, like relations/hierarchy, not in a new dedicated router. `fix-missing-matrix-room-routes`
  (commit `cae18ae3`) added leave/forget/relations/upgrade/search directly to `protected.ex` —
  confirms the same precedent.

### 2. Auth

- `server/lib/nebu/web/plugs/oidc_plug.ex` (`Nebu.Web.Plugs.OidcPlug`). Runs first in
  `Protected`'s pipeline (protected.ex:29). On failure it halts with a 401 Matrix envelope
  BEFORE any handler runs:
  - No/non-Bearer header → `401 M_MISSING_TOKEN "Missing access token"` (oidc_plug.ex:63, 150).
  - Expired/revoked/unknown/malformed token → `401 M_UNKNOWN_TOKEN` with a message (lines 78,
    83, 88, 100, 131, 158, 163, 166); expiry/deactivation cases also set `soft_logout: true`.
  - On success it assigns onto `conn`: `:access_token` (oidc_plug.ex:110/143),
    `:current_user` (lines 111/144 — the trusted `@localpart:server` MXID), `:device_id`
    (lines 112/146), `:oidc_claims` (lines 113/145).
- Handlers read the caller identity as `conn.assigns[:current_user]` (used everywhere in
  `protected.ex`, e.g. line 57, 170, 377, 449, etc.) — this is the trusted caller MXID for
  `mutual_rooms`' "caller" side of the intersection; never re-derive it from a param.

### 3. Rate limiting

- `server/lib/nebu/web/plugs/rate_limit.ex` (`Nebu.Web.Plugs.RateLimit`), a per-IP token-bucket
  `@behaviour Plug`. Usage pattern (only precedent in `protected.ex`, lines 44-54, for `/sync`):
  ```elixir
  @sync_rate_limit Nebu.Web.Plugs.RateLimit.init(rate_per_min: 600, burst: 100, tier: "sync")

  get "/client/v3/sync" do
    conn = Nebu.Web.Plugs.RateLimit.call(conn, @sync_rate_limit)
    if conn.halted, do: conn, else: do_sync(conn)
  end
  ```
- **On exhaustion this plug replies `429` with body `{"errcode":"M_LIMIT_EXCEEDED","error":"Rate
  limit exceeded"}` PLUS a `Retry-After` HTTP **header** in whole seconds
  (rate_limit.ex:144-151) — it does **NOT** put `retry_after_ms` in the JSON body.** This is a
  real discrepancy against the ticket's stated contract ("429 with the standard M_LIMIT_EXCEEDED
  / retry_after_ms shape") — flag for Oracle Gate. The OTHER 429 pattern in this codebase,
  `Nebu.Media`'s `error_with_retry/4` (`server/lib/nebu/media.ex:314-320`), DOES put an integer
  `retry_after_ms` field directly in the body:
  ```elixir
  defp error_with_retry(conn, status, errcode, message) do
    send_json(conn, status, %{"errcode" => errcode, "error" => message, "retry_after_ms" => retry_after_ms()})
  end
  ```
  (used at media.ex:279 for the pending-upload-cap 429; `retry_after_ms/0` reads a configurable
  default, media.ex:1328-1333). Existing tests assert on whichever shape their endpoint uses:
  `test/nebu/matrix/matrix_router_test.exs:396-397` asserts `errcode` + the `retry-after`
  **header**; `test/nebu/media/media_create_test.exs:195` asserts `is_integer(body["retry_after_ms"])`.
  **Decision needed (Dev Notes): do not change the shared `RateLimit` plug's body shape** (it's
  used by `/sync`, `/login`, SSO flows — changing it is a wider contract change than this story)
  — instead give `mutual_rooms` its own 429 body assembly mirroring `Nebu.Media.error_with_retry/4`
  if the Oracle Gate confirms `retry_after_ms` is truly required, OR use the existing `RateLimit`
  plug as-is (header-only) if Oracle Gate finds the body field is not actually spec-mandated.
- No existing `v1` GET endpoint in `protected.ex` (relations, hierarchy) carries ANY rate limit
  today — only `/sync` (uses `RateLimit`) and media's `preview_url`/upload (uses `RateLimit`,
  per `client_v1_media.ex`'s moduledoc) do. So there's no direct "v1 GET + rate limit" precedent
  to copy verbatim; `/sync`'s usage is the nearest template for wiring the plug into a route.

### 4. MXID validation

- `server/lib/nebu/matrix/user_id.ex`, `Nebu.Matrix.UserId.valid?/1` (lines 36-38):
  ```elixir
  @user_id_regex ~r/^@[a-z0-9._=\-\/+]+:[^\s:]+$/
  def valid?(user_id) when is_binary(user_id), do: Regex.match?(@user_id_regex, user_id)
  def valid?(_), do: false
  ```
  Shape-check only (does not verify existence) — exactly what's needed to gate `user_id` before
  any DB touch. Note the regex is **lowercase-localpart only** (matches the real Matrix grammar)
  and the domain part `[^\s:]+` is deliberately loose ("not a full RFC server-name parser" per
  its own doc, user_id.ex:24-26) — this is accepted existing behavior, not a gap to fix here.
  Already used as the admin-path precedent for default-deny validation before a membership write
  (`Nebu.Matrix.admin_add_room_member/3`, `lib/nebu/matrix.ex:253`).
- Self-user_id check: compare the decoded query param directly against
  `conn.assigns[:current_user]` (exact string equality) — same pattern as the existing
  `target != user` checks in `put "/client/v3/rooms/:room_id/typing/:path_user_id"`
  (protected.ex:844) and `put "/client/v3/presence/:path_user_id/status"` (protected.ex:915).

### 5. Error response helpers

- `server/lib/nebu/matrix/http.ex` (`Nebu.Matrix.Http`, imported into `protected.ex:24`):
  - `error(conn, status, errcode, message)` (http.ex:92-94) → `send_json(conn, status,
    %{"errcode" => errcode, "error" => message})`. Use directly for 400 M_INVALID_PARAM (3
    variants) and for a bespoke 429 if not reusing `RateLimit`.
  - `send_json(conn, status, body)` (http.ex:84-89) for the 200 success body.
  - `send_error(conn, {status, errcode, message})` (http.ex:97-99) only applies to tuples
    produced by `call_core/1`'s `map_error/1` — NOT needed here since this endpoint's only
    "backend" failure modes (invalid token already handled by OidcPlug) don't need to raise
    through `Nebu.Matrix.Error`; a plain direct DB read with no room-state GenServer call has no
    `Nebu.Matrix.Error`-raising surface to catch. (`call_core/1` wrapping is optional/unneeded
    unless the new EventDispatcher function is written to raise on e.g. a DB-unavailable error —
    see `get_initial_sync`'s pattern of raising `Nebu.Matrix.Status.unavailable()` on DB failure,
    protected.ex via event_dispatcher/server.ex:2316-2320, as the template if a 503 path is
    wanted for DB-down.)

### 6. Room membership data (the core query)

- **Public-API module** (ADR-020): `server/lib/nebu/matrix.ex` (`Nebu.Matrix`). **BUT** —
  important precedent correction to the ticket's framing: `Nebu.Web.Router.Protected` itself
  does **NOT** route through the `Nebu.Matrix` facade for its Matrix CS HTTP handlers; its own
  moduledoc (protected.ex:14-20) states every handler calls
  `Nebu.Matrix.EventDispatcher.Server` directly ("No gRPC hop"), and a repo-wide grep confirms
  `protected.ex` never references `Nebu.Matrix.Room.DB`/`Room.Server` directly either — only
  `EventDispatcher.Server`. `Nebu.Matrix` (the ADR-020 facade) is for OTHER domains
  (`Nebu.Admin`, `Nebu.Media`) calling INTO Matrix; within-domain HTTP handlers use
  `EventDispatcher.Server` as their one blessed entry point. **Follow that precedent**: add a
  new function to `Nebu.Matrix.EventDispatcher.Server` (e.g. `get_mutual_rooms/3` or similar),
  called directly from the new `protected.ex` route — do not add this to `Nebu.Matrix` (nothing
  outside the Matrix domain needs it) and do not call `Room.DB` directly from `protected.ex`.
- **The query that already does exactly half of what's needed**:
  `Nebu.Matrix.Room.DB.get_rooms_for_user/1` (`server/lib/nebu/matrix/room/db.ex:289-306`):
  ```sql
  SELECT room_id FROM room_members WHERE user_id = $1 AND left_at IS NULL
  ```
  "Returns all room IDs where `user_id` is currently an active member" — this is precisely
  Matrix `membership: join` semantics for this schema. Already called from
  `EventDispatcher.Server.get_initial_sync/2` (event_dispatcher/server.ex:2312) and referenced
  in `get_sync_delta/2`'s doc (line 2433) as THE room-list source for `/sync`.
- **Table** `room_members` (`server/priv/migrations/000001_init.up.sql:199-207`):
  `room_id TEXT, user_id TEXT, joined_at BIGINT, left_at BIGINT (nullable), PRIMARY KEY
  (room_id, user_id)`, indexed on `user_id` (`room_members_user_id_idx`). **A row only exists
  once a user has actually JOINED** — invites are tracked in a completely separate mechanism
  (`db_module_invite().insert_invitation/3`, e.g. event_dispatcher/server.ex:1062, 1315) and
  never create a `room_members` row. So `left_at IS NULL` cleanly means "currently joined",
  excluding invited-only, left, AND banned/kicked members:
  - Leave (`leave_room`) and kick both go through `delete_member/2` (room/db.ex, soft-delete —
    sets `left_at`), confirmed at event_dispatcher/server.ex:1189/1227.
  - Ban (`ban_user/2`, event_dispatcher/server.ex:3468-3533) calls
    `Nebu.Matrix.Room.Server.remove_member/2` (room/server.ex:115) when the target is currently
    a member, which itself calls `db_module().delete_member/2` (room/server.ex:382-397,
    `handle_call({:remove_member, ...})`) — same soft-delete, same `left_at` semantics. So a
    banned user's `room_members` row also gets `left_at` set — correctly excluded by
    `get_rooms_for_user/1`.
- **Implementation approach for the intersection**: call `get_rooms_for_user/1` ONCE for the
  caller (`conn.assigns[:current_user]`) and ONCE for the validated `user_id` param, then
  intersect the two id lists (`MapSet.intersection/2`) in Elixir. **Do NOT add a new
  `@callback` to `Nebu.Matrix.Room.DBBehaviour`** (`server/lib/nebu/matrix/room/db_behaviour.ex`)
  for a dedicated SQL-level `INTERSECT` query unless scale genuinely demands it — per this
  project's known gotcha (user memory: "a new `@callback` on a behaviour breaks all FakeDBs" /
  warnings-as-errors CI gate), adding a new required callback forces every injected FakeDB
  test-double across the suite to implement it. `get_rooms_for_user/1` is ALREADY an existing
  `@callback` (db_behaviour.ex:114) with FakeDBs already implementing it — reusing it twice adds
  zero new behaviour surface. Given realistic per-user room counts (compliance-native self-hosted
  deployment, not a public homeserver), an Elixir-side `MapSet` intersection of two already-cheap
  indexed queries is proportionate; do not prematurely add a bespoke SQL join.

### 7. Pagination pattern

- **No shared pagination module exists** — every endpoint that paginates rolls its own opaque
  token locally. The cleanest, most directly-applicable precedent (same "just a cursor over a
  deterministic in-memory sequence" shape mutual_rooms needs) is
  `server/lib/nebu/matrix/space_hierarchy.ex:167-203` (`Nebu.Matrix.SpaceHierarchy`):
  ```elixir
  @token_prefix "h1:"
  def encode_token(offset) when is_integer(offset) and offset >= 0,
    do: Base.url_encode64(@token_prefix <> Integer.to_string(offset), padding: false)
  def decode_token(token) when is_binary(token) do
    with {:ok, decoded} <- Base.url_decode64(token, padding: false),
         @token_prefix <> rest <- decoded,
         {offset, ""} <- Integer.parse(rest),
         true <- offset >= 0 do
      {:ok, offset}
    else
      _ -> {:error, :invalid_token}
    end
  end
  defp parse_offset(""), do: {:ok, 0}   # no token = first page
  defp parse_offset(token), do: decode_token(token)
  ```
  Page window = `all |> Enum.drop(offset) |> Enum.take(limit)`; `next_batch` is `encode_token/1`
  of the next offset, or `""`/omitted when the window reaches the end (space_hierarchy.ex:87-98).
  **A forged/malformed token fails closed** (`{:error, :invalid_token}`), never silently resets
  to page 0 — mirror this exactly for `from`/`next_batch`.
- **This confirms the ticket's hypothesis directly**: a simple offset-based opaque token is
  already this project's established convention for an endpoint with no backing Core-proto
  pagination cursor, and fits mutual_rooms (a deterministic sorted room-id-intersection list)
  perfectly. Give `mutual_rooms` its OWN prefix (e.g. `"mr1:"`) — don't reuse/import
  `SpaceHierarchy`'s private token functions, since they're module-private
  (`defp parse_offset`) and prefix-scoped; replicate the same tiny pattern next to the new
  handler/EventDispatcher function instead.
- Contrast: `/sync`'s `since_token` (http.ex / event_dispatcher/server.ex:2412-2418) and
  `/messages`'/relations'/search's `next_batch` are backed by actual DB cursors / monotonic
  markers inside Core proto responses — NOT a fit here since mutual_rooms has no Core proto
  message and no event-stream position to encode; the `SpaceHierarchy` BFS-offset style is the
  correct analogue, not those.

### 8. GenServer / cluster-safety concerns

- `get_rooms_for_user/1` is a **direct parameterised Ecto SQL read** (`Ecto.Adapters.SQL.query(
  Nebu.Repo, ...)`, room/db.ex:302) — **no Room GenServer involved**. `get_initial_sync/2` calls
  it directly from `EventDispatcher.Server` BEFORE touching any per-room GenServer (room state
  GenServers are only started afterward, per-room, to fetch each room's timeline/state — which
  mutual_rooms does not need at all, since it only needs the ID-level join/not-joined fact, not
  room content).
- Direct precedent for a read-only, no-GenServer, pure-DB Matrix endpoint: this is exactly what
  `get_rooms_for_user/1`'s existing callers already do, and matches CLAUDE.md ADR-018 ("No
  Domain Model — SQL inline in the handler/dispatcher, no Repository/Service layer") and the
  project's cluster-safety convention of not routing read-only, horizontally-scalable queries
  through a singleton per-entity process when a plain indexed SQL read suffices. **mutual_rooms
  should be a pure direct-DB-read EventDispatcher function — no GenServer, no `:pg`, no Horde
  lookup** — unlike e.g. `get_space_hierarchy` which legitimately needs per-room GenServer state
  for `m.space.child` edges and visibility, mutual_rooms needs none of that.

### 9. Existing tests structure

- Closest HTTP-level test precedent: `server/test/nebu/matrix/matrix_room_view_routes_test.exs`
  (from the `fix-room-view-endpoints` bugfix; 399 lines) and its sibling
  `matrix_room_routes_test.exs` (504 lines, from `fix-missing-matrix-room-routes`). Pattern:
  - `use ExUnit.Case, async: false`; `import Plug.Test`; `import Plug.Conn`.
  - `@router_opts Nebu.Web.Router.init([])`; drives the FULL top-level router (not just
    `Protected` directly), so forwarding/pipeline ordering is exercised too.
  - `setup_oidc_keys/0` — generates an RSA JWK, configures `Nebu.Web.OidcTestSupport` +
    `:nebu_http, :oidc_jwks`/`:server_name` app env, registers cleanup via `on_exit`.
  - `bearer_for(sub, priv_jwk)` — mints a signed RS256 JWT via `JOSE.JWT.sign`, returns
    `{user_id, compact_token}`.
  - `call(method, path, body \\ nil, headers \\ [])` / `json(conn)` / `auth(token)` helpers.
  - **Two-tier structure**:
    1. Pure-unit, no DB: `describe "auth gate ... — no DB"` — asserts 401 M_MISSING_TOKEN with
       no Bearer (lines 111-127 of the view-routes file); `describe "routes are wired ... — no
       DB"` with a `refute_catch_all/1` helper (lines 149-154) that asserts the response body is
       NOT exactly `%{"errcode" => "M_NOT_FOUND", "error" => "Unrecognized request"}` — i.e.
       proves the route exists and reached its handler (even if it then 403/404s for a
       legitimately-missing room), vs. silently falling through to the router's generic
       catch-all.
    2. `@describetag :integration` block driving the REAL OTP tree (Postgres, Horde, `:pg`) via
       `create_room/2`, `send_message/3`, invite/join flow helpers — full contract-shape
       assertions (status + body shape) for each AC.
  - Directly reusable for mutual_rooms: create two rooms with room A (both users joined) and
    room B (only caller joined), assert `joined` contains room A's id, excludes B; invite+leave
    scenarios for the "not actually joined" exclusions; self-user_id / malformed user_id /
    missing user_id as pure-unit 400 cases (no DB needed); 401 as a pure-unit auth-gate case
    (copy the `auth gate ... — no DB` describe block verbatim, new path).
  - Rate-limit ATDD precedent (if testing the 429 path): `test/nebu/web/rate_limit_test.exs` and
    `matrix_router_test.exs:331-368` (force-enable the limiter, reset the shared ETS bucket
    `:nebu_http_rate_limit_buckets`, restore env in `on_exit`) — reuse this setup block verbatim
    if wiring `RateLimit` into the new route.
- New test file should be named analogously, e.g.
  `server/test/nebu/matrix/matrix_mutual_rooms_test.exs` (matches `matrix_room_routes_test.exs` /
  `matrix_room_view_routes_test.exs` naming convention — `matrix_<feature>_test.exs` for a
  router-level ATDD file covering one bugfix/feature's new route(s)).

### 10. Classification

- `matrix: true` — obviously (`_matrix/` path, Matrix CS endpoint).
- `ui: false` — pure server API endpoint; no Admin UI (Go Templates/LiveView) surface touched.
- `security_review`: see frontmatter. `skills/nebu-pipeline/scripts/classify_story.py`'s
  `SECURITY_PATHS` (lines 29-36) are **stale Go-gateway paths**
  (`gateway/internal/auth/`, `gateway/internal/middleware/`, `gateway/internal/db/`, etc.) that
  no longer exist in this pure-Elixir, single-OTP-app codebase (ADR-019/021) — a staged diff
  touching only `server/lib/nebu/...` will NEVER auto-match any `SECURITY_PATHS` entry and the
  script will silently default to `"not-needed"` unless the frontmatter explicitly overrides it
  (classify_story.py:71-86). **This frontmatter's explicit `security_review:` value is therefore
  authoritative and load-bearing** — the auto-classifier cannot be relied on for this change.
  Direct precedent: `fix-missing-matrix-room-routes` (5 new/wired authenticated room routes
  including membership-scoped `relations`/`search`) got a full Kassandra review
  (`_bmad-output/implementation-artifacts/security-reports/bugfix-fix-missing-matrix-room-routes-security-review-2026-06-20.md`)
  that explicitly checked "Cross-room exfiltration" and IDOR concerns for those routes. Reviewing a
  BRAND NEW endpoint whose entire purpose is to compare two different users' membership sets
  (a more direct cross-user relationship surface than that precedent, which was same-room-scoped)
  is at least as sensitive — recommend `required`, not `optional`/`not-needed`.

## Scope boundary

**In scope:**
- `GET /_matrix/client/v1/mutual_rooms` — one new route in `protected.ex`, one new
  `EventDispatcher.Server` function, reusing `get_rooms_for_user/1` twice + a new offset-token
  pagination helper.
- Pagination (`from`/`next_batch`) — **yes, implement it**, even though Nebu is self-hosted at
  modest scale: the ticket's 200-response contract explicitly requires `count` to be the TOTAL
  shared-room count even when paginated (i.e. `count != len(joined)` is a real, testable case),
  so the feature can't be "minimally" implemented by just returning everything unpaginated and
  omitting `next_batch` support — that would make the `count`-vs-`len(joined)` AC untestable and
  silently wrong the first time a deployment's two users share more rooms than the page size.
  Implement the real offset-window pagination (space_hierarchy.ex pattern), not a stub.
- Rate limiting — apply SOME limit (ticket requires 429 M_LIMIT_EXCEEDED behavior to be
  testable); which exact plug/shape (shared `RateLimit` vs. a bespoke retry_after_ms body) is an
  Oracle-Gate-confirmed decision, see §3.
- 400 M_INVALID_PARAM for: missing `user_id`, malformed `user_id` (fails
  `Nebu.Matrix.UserId.valid?/1`), `user_id == conn.assigns[:current_user]`.
  **Discrepancy to flag for Oracle Gate**: this project's OTHER endpoints use `M_MISSING_PARAM`
  (not `M_INVALID_PARAM`) for a genuinely absent required param (e.g. `/messages`' missing `dir`,
  protected.ex:721; `/delete_devices`' missing `devices` key, protected.ex:498) — the ticket
  explicitly specifies `M_INVALID_PARAM` for ALL THREE 400 cases including missing `user_id`,
  which diverges from that house convention. Follow the ticket's explicit spec as given (Oracle
  Gate will independently re-verify the exact MSC2666/spec wording) rather than "fixing" it to
  match the `M_MISSING_PARAM` precedent.
- 200 with empty `joined`/`count: 0` (no `next_batch`) for a syntactically-valid but
  nonexistent/unknown `user_id` — never 404. `get_rooms_for_user/1` naturally returns `{:ok,
  []}` for any user_id with no `room_members` rows (nonexistent OR simply roomless users are
  indistinguishable at this query — which is fine, since the overall AND-intersection with the
  caller's own room list is `[]` either way).

**Out of scope:**
- No federation concerns (Nebu has no federation, ADR — ever).
- Invited-but-not-yet-joined, left, and banned/kicked rooms on EITHER side of the pair are
  excluded from `joined` — already naturally true of `get_rooms_for_user/1`'s `left_at IS NULL`
  semantics (§6); no extra filtering logic needed beyond the intersection itself.
- No new `Nebu.Matrix.Room.DBBehaviour` callback (see §6) unless a future performance need
  forces a SQL-level `INTERSECT`.
- No changes to `Nebu.Web.Plugs.RateLimit`'s shared body shape for other endpoints (`/sync`,
  login, SSO) — any `retry_after_ms` addition must be scoped to this endpoint's own 429 path.
- No Admin UI surface.

## Acceptance Criteria

1. `GET /_matrix/client/v1/mutual_rooms?user_id=<mxid>` with a valid Bearer token and a
   `user_id` sharing N≥1 currently-joined rooms with the caller → `200` with
   `{"count": N, "joined": [<room_id>, ...]}`; every `room_id` in `joined` is a room where BOTH
   the caller (`conn.assigns[:current_user]`) and `user_id` currently hold `room_members.left_at
   IS NULL` (i.e. actively joined) — verified via setup that also creates a room where only the
   caller is joined (must NOT appear) and a room where `user_id` was invited but never joined
   (must NOT appear).
2. When all shared rooms fit in one page, the response has NO `next_batch` key at all (omitted,
   not `null`/`""`).
3. When shared rooms exceed one page, `joined` contains only that page's room ids, `next_batch`
   is a non-empty opaque token, and `count` equals the TOTAL shared-room count (strictly greater
   than `length(joined)` for that page) — not just the current page's length.
4. Passing the `next_batch` value from AC3 back as `from` returns the next page's remaining
   room ids and (on the last page) omits `next_batch` again; the union of all pages' `joined`
   across the full walk equals the full shared-room set with no duplicates.
5. `user_id` referring to a syntactically-valid but nonexistent/unknown user → `200` with
   `{"count": 0, "joined": []}` (no `next_batch`) — NEVER `404`.
6. Missing `user_id` query param → `400 M_INVALID_PARAM`.
7. Malformed `user_id` (fails `Nebu.Matrix.UserId.valid?/1`, e.g. no leading `@`, no domain,
   uppercase localpart, embedded whitespace) → `400 M_INVALID_PARAM`.
8. `user_id` equal to the caller's own MXID (`conn.assigns[:current_user]`) → `400
   M_INVALID_PARAM`.
9. No `Authorization` header → `401 M_MISSING_TOKEN`; expired/invalid/revoked Bearer →
   `401 M_UNKNOWN_TOKEN` — both BEFORE any DB access (pure-unit, no-DB test, mirroring
   `matrix_room_view_routes_test.exs`'s "auth gate ... — no DB" describe block).
10. Exceeding the applied rate limit → `429` with `errcode: "M_LIMIT_EXCEEDED"` in the body
    PLUS a `Retry-After` HTTP header (RFC 9110, whole seconds) — **Oracle-Gate CONFIRMED**:
    `retry_after_ms` was deprecated spec-wide in v1.10 in favor of the `Retry-After` header;
    it MAY still be present but is NOT required. Use the existing shared
    `Nebu.Web.Plugs.RateLimit` plug as-is (header-only, no bespoke 429 body needed) — do NOT
    add a `retry_after_ms` body field for this endpoint; the pre-Oracle Dev Notes discussion
    recommending a `Nebu.Media`-style `retry_after_ms` body is SUPERSEDED, see Dev Notes.
11. A malformed/forged `from` token → fails closed with a `400`-class Matrix error (mirroring
    `SpaceHierarchy.decode_token/1`'s `{:error, :invalid_token}` → `400 M_INVALID_PARAM`
    pattern, protected.ex:1059-1062) — never silently resets to page 0 and never 500s.
12. Regression: existing `v1` routes (relations, hierarchy) and `/sync` remain unaffected —
    full existing suite green.

## Dev Notes

- **Handler location**: new `get "/client/v1/mutual_rooms" do ... end` clause in
  `server/lib/nebu/web/router/protected.ex`, alongside the other `v1` clauses (962-1063).
  Query params via `conn.query_params` (already fetched by the router's
  `plug :fetch_query_params`, protected.ex:30) — no `URI.decode_www_form` needed (that's only
  applied to PATH segments elsewhere in this file, e.g. `room_id`/`event_id`; query-string
  values are already decoded by Plug).
- **New backend function**: add to `Nebu.Matrix.EventDispatcher.Server`
  (`server/lib/nebu/matrix/event_dispatcher/server.ex`), NOT to the `Nebu.Matrix` facade
  (`lib/nebu/matrix.ex`) — see §6/§8 rationale (protected.ex only ever calls
  `EventDispatcher.Server` directly; the facade is for cross-domain callers). Call
  `rooms_db_module().get_rooms_for_user/1` (the existing injectable DI seam, already overridable
  via `Application.put_env(:event_dispatcher, :rooms_db_module, FakeDB)` per
  event_dispatcher/server.ex:23-25) for BOTH the caller and the target `user_id`, intersect with
  `MapSet.intersection/2`, sort deterministically (e.g. by room_id) before paginating so the
  offset-window pagination is stable across calls.
- **Validation order** (mirrors the hierarchy endpoint's `with`-chain, protected.ex:1033-1062):
  check `user_id` present → check `Nebu.Matrix.UserId.valid?/1` → check `user_id !=
  current_user` → THEN decode `from` (fail-closed) → THEN hit the DB. Keep the self-user_id and
  shape checks BEFORE any DB touch (cheap, default-deny, consistent with
  `admin_add_room_member/3`'s existing "validate before any write" pattern, even though this is
  a read).
- **Pagination token**: implement a small local twin of
  `Nebu.Matrix.SpaceHierarchy.encode_token/1`/`decode_token/1` (space_hierarchy.ex:167-203) with
  its own prefix (e.g. `"mr1:"`) — do not import/reuse SpaceHierarchy's (module-private,
  domain-specific prefix). `from=""`/absent = offset 0, matching `parse_offset/1`'s convention.
- **Rate limiting — RESOLVED by Oracle Gate** (supersedes the pre-Oracle discussion below the
  line): `retry_after_ms` is deprecated spec-wide since v1.10 in favor of the `Retry-After`
  HTTP header (MAY still appear, not Required — Oracle Gate, §(c)). Use the existing shared
  `Nebu.Web.Plugs.RateLimit.init/1`+`.call/2` for `mutual_rooms` AS-IS, header-only, exactly
  like `/sync`'s usage (protected.ex:44-54) — **no bespoke 429 body/helper needed**, no plug
  refactor needed. This removes the two-incompatible-shapes concern entirely for this endpoint.
  ~~Superseded pre-Oracle text: give `mutual_rooms` its own small 429 helper mirroring
  `Nebu.Media.error_with_retry/4` (media.ex:314-320) so the body includes `retry_after_ms`...~~
- **Tier**: give the new route its OWN `RateLimit.init(tier: "mutual_rooms", ...)` instance
  (own ETS bucket key is per-IP regardless of tier — tier is just a label, rate_limit.ex:86) —
  do not share `@sync_rate_limit`. Pick a generous-but-real limit (this is a low-cost read, not
  a brute-force target) — no house convention dictates the exact number; a reasonable default
  mirroring `/sync`'s generosity (e.g. 60-120/min, burst 20-30) is a reasonable starting point,
  confirm with Oracle Gate/PM if a specific number matters.
- **Test file**: create `server/test/nebu/matrix/matrix_mutual_rooms_test.exs` following
  `matrix_room_view_routes_test.exs`'s exact structure (§9): no-DB auth-gate tests, no-DB 400
  tests (missing/malformed/self user_id — all pure validation, no DB needed), then an
  `@describetag :integration` block with real `createRoom`/`invite`/`join`/`leave` flows for the
  join/count/pagination/empty-for-unknown-user ACs. Reuse `setup_oidc_keys/0`, `bearer_for/2`,
  `call/4`, `json/1`, `auth/1` verbatim (candidate for extraction into a shared test support
  module if a THIRD file ends up duplicating them, but out of scope to refactor here).
- Oracle Gate must independently confirm: (a) exact MSC2666 response field names/nullability
  (`count`/`joined`/`next_batch` casing and omission-vs-null), (b) whether `M_INVALID_PARAM` vs
  `M_MISSING_PARAM` for a missing `user_id` is truly what the spec (not just this ticket's
  prose) mandates, (c) whether `retry_after_ms` in the 429 body is actually spec-required for
  this endpoint or just general Matrix CS error-shape convention, (d) exact rate-limit numeric
  tier if the spec or Matrix ecosystem convention suggests one.
