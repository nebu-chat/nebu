defmodule Nebu.Web.MatrixMutualRoomsTest do
  @moduledoc """
  Acceptance/regression test suite for `GET /_matrix/client/v1/mutual_rooms`
  (MSC2666, new in Matrix CS API v1.19) and its unstable
  `uk.half-shot.msc2666.query_mutual_rooms` alias route, both implemented in
  `Nebu.Web.Router.Protected`. Every test in this file is green.

  ## What this suite covers (ACs 1-11; AC12 is covered separately, see
  ## "Structure" below)

    * AC1 — `200` with `{"count": N, "joined": [...]}` for a caller/`user_id`
      pair sharing N currently-joined rooms; a room where only the caller is
      joined, and a room where `user_id` was invited but never joined, are
      both excluded.
    * AC2/AC3/AC4 — pagination: a single-page result omits `next_batch`
      entirely; an overflowing result carries a non-empty opaque
      `next_batch` plus the TOTAL shared-room `count`; walking pages via
      `from` yields the full shared-room set with no duplicates.
    * AC5 — an unknown-but-syntactically-valid `user_id` → `200` with an
      empty `joined` list, never `404` (anti-user-enumeration).
    * AC6/AC7/AC8/AC11 — `400 M_INVALID_PARAM` for a missing `user_id`, a
      malformed `user_id`, `user_id` equal to the caller's own id, and a
      forged/malformed `from` token.
    * AC9 — auth gate: missing/expired/invalid Bearer → `401`, before any DB
      access.
    * AC10 — exceeding the rate limit → `429` with a `Retry-After` header.

  ## Oracle Gate (MSC2666 / client-server-api v1.19, `#mutual-rooms`)

    * Rate-limited: yes. Requires authentication: yes (both explicit on the
      endpoint itself).
    * `user_id` query param required; `from` optional (an opaque `next_batch`
      cursor from a previous call).
    * 200 `count` — REQUIRED, the TOTAL shared-room count, even when the result
      is batched (Nebu reads directly from Postgres, so this is always exact).
    * 200 `joined` — REQUIRED array of room ids where BOTH users currently hold
      `membership: join` (backed by `Nebu.Matrix.Room.DB.get_rooms_for_user/1`,
      which already scopes `room_members.left_at IS NULL` — invited-but-never-
      joined rows don't exist in `room_members` at all, per
      `priv/migrations/000001_init.up.sql`, so they're excluded for free).
    * 200 `next_batch` — optional, ABSENT (never `null`/`""`) when there is no
      more data.
    * `user_id` that does not resolve to a real user → 200 with an EMPTY list,
      never 404.
    * 400 (spec's own worked example uses `M_INVALID_PARAM`) covers: missing
      `user_id`, non-compliant `user_id`, `user_id` == caller's own id, and an
      invalid/expired `from` token — ALL FOUR use `M_INVALID_PARAM` uniformly
      (NOT `M_MISSING_PARAM`, even though that's this project's usual
      missing-param convention elsewhere).
    * `retry_after_ms` was deprecated spec-wide in v1.10; the `Retry-After` HTTP
      header is what matters for a 429 here — no bespoke 429 body is needed,
      `Nebu.Web.Plugs.RateLimit` already produces header + envelope.

  ## Test-determinism seam for AC3/AC4 (pagination)

  The spec places NO requirement on page size for this endpoint (implementer's
  choice) — so this suite cannot know in advance how many shared rooms it takes
  to overflow a page, and creating e.g. 100+ real rooms through the HTTP router
  per test would be far too slow. To make the multi-page walk deterministic
  regardless of whatever default the eventual implementation picks, these tests
  require one new, test-only configuration seam:

      Application.put_env(:event_dispatcher, :mutual_rooms_page_size, n)

  mirroring the existing `:rate_limit_clock_fn` / `:rate_limit_disabled` seams
  this codebase already uses (`matrix_router_test.exs`, `url_preview_test.exs`)
  to force otherwise-nondeterministic server behaviour under test control. The
  mutual_rooms handler is expected to read this override (falling back to its
  own real default when unset) exactly the way `RateLimit` reads its clock
  override.

  ## Structure

    * "no DB" describes (auth gate AC9, 400s AC6/AC7/AC8/AC11, rate limit AC10)
      — pure unit, mirrors `matrix_room_view_routes_test.exs`'s auth-gate block.
    * `@describetag :integration` describe (AC1-AC5 contract shape, AC3/AC4
      pagination) — drives the full `Nebu.Web.Router` against the real OTP tree
      (Postgres etc.), mirrors `matrix_room_routes_test.exs`'s contract-parity
      block.

  AC12 (regression: existing v1 routes / `/sync` stay green) is not a unit test
  in this file — it is validated by running the FULL existing suite alongside
  this new file at the CI gate step, per the pipeline's TDD-first order.
  """

  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  @server_name "test.local"
  @issuer "https://keycloak.example.com/realms/nebu"
  @audience "nebu-gateway"
  @kid "matrix-mutual-rooms-key-1"

  @router_opts Nebu.Web.Router.init([])

  # ── shared helpers (mirrors matrix_room_routes_test.exs / matrix_room_view_routes_test.exs) ──

  defp future_exp, do: System.system_time(:second) + 3600
  defp past_exp, do: System.system_time(:second) - 3600

  defp setup_oidc_keys do
    jwk = JOSE.JWK.generate_key({:rsa, 2048})
    {_, priv_map} = JOSE.JWK.to_map(jwk)

    pub_jwk =
      jwk
      |> JOSE.JWK.to_public()
      |> JOSE.JWK.to_map()
      |> elem(1)
      |> Map.put("kid", @kid)
      |> Map.put("alg", "RS256")
      |> Map.put("use", "sig")

    priv_jwk = Map.put(priv_map, "kid", @kid)

    Application.put_env(:nebu_http, :server_name, @server_name)
    # story create-room-invites-direct (DATA adaptation): POST /invite refuses foreign-domain invitees, the domain is :event_dispatcher's server_name
    Nebu.Test.ServerName.pin!(@server_name)
    Nebu.Web.OidcTestSupport.configure(@issuer, @audience)

    Application.put_env(:nebu_http, :oidc_jwks, [pub_jwk])

    ExUnit.Callbacks.on_exit(fn ->
      Application.delete_env(:nebu_http, :server_name)
      Nebu.Web.OidcTestSupport.clear()
      Application.delete_env(:nebu_http, :oidc_jwks)
    end)

    priv_jwk
  end

  defp bearer_for(sub, priv_jwk, exp \\ nil) do
    claims = %{
      "iss" => @issuer,
      "aud" => @audience,
      "sub" => sub,
      "exp" => exp || future_exp(),
      "iat" => System.system_time(:second)
    }

    jws = %{"alg" => "RS256", "kid" => @kid}
    signed = JOSE.JWT.sign(JOSE.JWK.from_map(priv_jwk), jws, claims)
    {_, compact} = JOSE.JWS.compact(signed)
    "@" <> sub <> ":" <> @server_name |> then(fn uid -> {uid, compact} end)
  end

  defp call(method, path, body \\ nil, headers \\ []) do
    conn =
      case body do
        nil -> conn(method, path)
        b -> conn(method, path, Jason.encode!(b)) |> put_req_header("content-type", "application/json")
      end

    conn = Enum.reduce(headers, conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)
    Nebu.Web.Router.call(conn, @router_opts)
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)

  defp auth(token), do: [{"authorization", "Bearer " <> token}]

  # ── mutual_rooms-specific helpers ───────────────────────────────────────────

  defp mutual_rooms_path(params) when is_map(params) do
    case URI.encode_query(params) do
      "" -> "/_matrix/client/v1/mutual_rooms"
      q -> "/_matrix/client/v1/mutual_rooms?" <> q
    end
  end

  defp mutual_rooms(token, user_id) when is_binary(user_id) do
    mutual_rooms(token, %{"user_id" => user_id})
  end

  defp mutual_rooms(token, params) when is_map(params) do
    call(:get, mutual_rooms_path(params), nil, auth(token))
  end

  defp mutual_rooms_from_ip(token, params, ip) do
    %{conn(:get, mutual_rooms_path(params)) | remote_ip: ip}
    |> put_req_header("authorization", "Bearer " <> token)
    |> Nebu.Web.Router.call(@router_opts)
  end

  # ── unstable MSC2666 alias helpers ──────────────────────────────────────────
  # router.ex's unstable_features["uk.half-shot.msc2666.query_mutual_rooms"]
  # flag is the historical signal for THIS path, not the stable v1 one above.

  @unstable_mutual_rooms_path "/_matrix/client/unstable/uk.half-shot.msc2666/user/mutual_rooms"

  defp mutual_rooms_unstable_path(params) when is_map(params) do
    case URI.encode_query(params) do
      "" -> @unstable_mutual_rooms_path
      q -> @unstable_mutual_rooms_path <> "?" <> q
    end
  end

  defp mutual_rooms_unstable(token, user_id) when is_binary(user_id) do
    mutual_rooms_unstable(token, %{"user_id" => user_id})
  end

  defp mutual_rooms_unstable(token, params) when is_map(params) do
    call(:get, mutual_rooms_unstable_path(params), nil, auth(token))
  end

  # Walks the full paginated result set by repeatedly following `next_batch` as
  # `from`, stopping when the key is ABSENT (never on a null/empty value, which
  # would mask a server that wrongly omits the key only sometimes). Guards
  # against a non-terminating walk (e.g. an implementation that always resends
  # the same token) with a hard hop cap — AC4 requires the walk to terminate.
  defp walk_all_pages(token, user_id, from, acc, hops \\ 0) do
    if hops > 50 do
      flunk("pagination walk did not terminate within 50 pages — next_batch likely never clears")
    end

    params = if from, do: %{"user_id" => user_id, "from" => from}, else: %{"user_id" => user_id}
    conn = mutual_rooms(token, params)
    assert conn.status == 200, "each page of the walk must return 200, got #{conn.status}"

    body = json(conn)
    acc = acc ++ body["joined"]

    if Map.has_key?(body, "next_batch") do
      walk_all_pages(token, user_id, body["next_batch"], acc, hops + 1)
    else
      {acc, body["count"]}
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC9 — auth gate — PURE UNIT, no DB
  # No Bearer → 401 M_MISSING_TOKEN; expired/invalid Bearer → 401 M_UNKNOWN_TOKEN
  # — both must happen BEFORE any handler/DB access runs.
  # ══════════════════════════════════════════════════════════════════════════

  describe "auth gate on GET /mutual_rooms (AC9) — no DB" do
    test "no Authorization header → 401 M_MISSING_TOKEN" do
      conn = call(:get, "/_matrix/client/v1/mutual_rooms?user_id=" <> URI.encode_www_form("@someone:test.local"))

      assert conn.status == 401
      assert json(conn)["errcode"] == "M_MISSING_TOKEN"
    end

    test "expired Bearer token → 401 M_UNKNOWN_TOKEN" do
      priv = setup_oidc_keys()
      {_uid, token} = bearer_for("mutual-probe-expired", priv, past_exp())

      conn = mutual_rooms(token, "@someone:test.local")

      assert conn.status == 401
      assert json(conn)["errcode"] == "M_UNKNOWN_TOKEN"
    end

    test "garbage/unparseable Bearer token → 401 M_UNKNOWN_TOKEN" do
      _priv = setup_oidc_keys()

      conn = mutual_rooms("not-a-jwt-at-all", "@someone:test.local")

      assert conn.status == 401
      assert json(conn)["errcode"] == "M_UNKNOWN_TOKEN"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC6, AC7, AC8, AC11 — 400 M_INVALID_PARAM — PURE UNIT, valid Bearer, no DB
  # Spec's own worked 400 example uses M_INVALID_PARAM for ALL of: missing
  # user_id, malformed user_id, self-id, and a bad `from` token — never
  # M_MISSING_PARAM, even though that's this project's usual convention for a
  # missing param elsewhere.
  # ══════════════════════════════════════════════════════════════════════════

  describe "400 M_INVALID_PARAM cases (AC6, AC7, AC8, AC11) — valid Bearer, no DB" do
    setup do
      priv = setup_oidc_keys()
      {uid, token} = bearer_for("mutual-caller", priv)
      {:ok, token: token, user_id: uid}
    end

    # ── AC6 ──

    test "missing user_id query param → 400 M_INVALID_PARAM", %{token: token} do
      conn = call(:get, "/_matrix/client/v1/mutual_rooms", nil, auth(token))

      assert conn.status == 400
      assert json(conn)["errcode"] == "M_INVALID_PARAM"
    end

    # Reachability check for the unstable MSC2666 alias route: same cheap,
    # no-DB 400 case as above, but against @unstable_mutual_rooms_path. This
    # catches a route-path typo/mismatch in the fast unit gate without
    # needing the full stack.
    test "unstable alias — missing user_id query param → 400 M_INVALID_PARAM", %{token: token} do
      conn = call(:get, @unstable_mutual_rooms_path, nil, auth(token))

      assert conn.status == 400
      assert json(conn)["errcode"] == "M_INVALID_PARAM"
    end

    # ── AC7 (Nebu.Matrix.UserId.valid?/1 grammar: ^@[a-z0-9._=\-\/+]+:[^\s:]+$) ──

    test "malformed user_id — no leading '@' → 400 M_INVALID_PARAM", %{token: token} do
      conn = mutual_rooms(token, "someone:test.local")

      assert conn.status == 400
      assert json(conn)["errcode"] == "M_INVALID_PARAM"
    end

    test "malformed user_id — no domain part → 400 M_INVALID_PARAM", %{token: token} do
      conn = mutual_rooms(token, "@someone")

      assert conn.status == 400
      assert json(conn)["errcode"] == "M_INVALID_PARAM"
    end

    test "malformed user_id — uppercase localpart → 400 M_INVALID_PARAM", %{token: token} do
      conn = mutual_rooms(token, "@Someone:test.local")

      assert conn.status == 400
      assert json(conn)["errcode"] == "M_INVALID_PARAM"
    end

    test "malformed user_id — embedded whitespace → 400 M_INVALID_PARAM", %{token: token} do
      conn = mutual_rooms(token, "@some one:test.local")

      assert conn.status == 400
      assert json(conn)["errcode"] == "M_INVALID_PARAM"
    end

    # ── AC8 ──

    test "user_id equal to the caller's own mxid → 400 M_INVALID_PARAM", %{token: token, user_id: uid} do
      conn = mutual_rooms(token, uid)

      assert conn.status == 400
      assert json(conn)["errcode"] == "M_INVALID_PARAM"
    end

    # Kassandra security review (F-1): the caller's own mxid plus a trailing
    # newline used to pass Nebu.Matrix.UserId.valid?/1 (Elixir's ~r// compiles
    # without PCRE_DOLLAR_ENDONLY, so `$` matched before the `\n`), while no
    # longer being byte-equal to `uid` — so the AC8 self-id equality check
    # failed to trip and the request fell through to a 200 {count:0,joined:[]}
    # instead of 400. The tightened regex (`\A`/`\z` anchors) now rejects the
    # trailing-newline id outright at the shape-check step, restoring 400.
    test "user_id equal to the caller's own mxid plus a trailing newline → 400 M_INVALID_PARAM (not 200)",
         %{token: token, user_id: uid} do
      conn = mutual_rooms(token, uid <> "\n")

      assert conn.status == 400
      assert json(conn)["errcode"] == "M_INVALID_PARAM"
    end

    # ── AC11 (mirrors SpaceHierarchy.decode_token/1's fail-closed {:error, :invalid_token} → 400) ──

    test "malformed/forged `from` token → 400 M_INVALID_PARAM, fails closed (never resets to page 0, never 500s)",
         %{token: token} do
      conn = mutual_rooms(token, %{"user_id" => "@someone:test.local", "from" => "not-a-real-opaque-token!!"})

      assert conn.status == 400
      assert json(conn)["errcode"] == "M_INVALID_PARAM"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC10 — rate limit — PURE UNIT, no DB
  # Exceeding the applied per-IP rate limit → 429 M_LIMIT_EXCEEDED body PLUS a
  # Retry-After HTTP header (RFC 9110, whole seconds). retry_after_ms is NOT
  # asserted (deprecated spec-wide since v1.10). Mirrors the deterministic
  # frozen-clock burst technique from matrix_router_test.exs (F-3) and
  # url_preview_test.exs (F-1): this endpoint's rate-limit tier/burst size is
  # not yet decided (no implementation exists) — and this project already
  # configures a generous `burst: 100` tier for another high-frequency
  # authenticated read endpoint (`GET /sync`, see
  # `Nebu.Web.Router.Protected`), so a fixed-count burst could pass or fail
  # purely based on which tier an implementer reuses. Instead, with the
  # refill clock frozen, this probes up to a high ceiling and stops the
  # instant a 429 is observed, so the test is correct regardless of whatever
  # tier gets configured.
  # ══════════════════════════════════════════════════════════════════════════

  describe "rate limit (AC10) — no DB, forced burst" do
    @rl_table :nebu_http_rate_limit_buckets

    setup do
      priv = setup_oidc_keys()
      {_uid, token} = bearer_for("mutual-rl-probe", priv)

      prev_env = System.get_env("NEBU_RATE_LIMIT_DISABLED")
      System.delete_env("NEBU_RATE_LIMIT_DISABLED")
      prev_app = Application.get_env(:nebu_http, :rate_limit_disabled)
      Application.put_env(:nebu_http, :rate_limit_disabled, false)

      # Freeze the refill clock so now - last == 0 on every request → zero
      # refill across the burst → deterministic 429 regardless of CI speed.
      prev_clock = Application.get_env(:nebu_http, :rate_limit_clock_fn)
      Application.put_env(:nebu_http, :rate_limit_clock_fn, fn -> 1_000_000 end)

      if :ets.whereis(@rl_table) != :undefined, do: :ets.delete_all_objects(@rl_table)

      on_exit(fn ->
        if :ets.whereis(@rl_table) != :undefined, do: :ets.delete_all_objects(@rl_table)

        case prev_clock do
          nil -> Application.delete_env(:nebu_http, :rate_limit_clock_fn)
          v -> Application.put_env(:nebu_http, :rate_limit_clock_fn, v)
        end

        case prev_app do
          nil -> Application.delete_env(:nebu_http, :rate_limit_disabled)
          v -> Application.put_env(:nebu_http, :rate_limit_disabled, v)
        end

        if prev_env, do: System.put_env("NEBU_RATE_LIMIT_DISABLED", prev_env)
      end)

      {:ok, token: token}
    end

    test "a burst of requests from one IP is eventually rejected with 429 M_LIMIT_EXCEEDED + Retry-After",
         %{token: token} do
      ip = {203, 0, 113, 9}
      params = %{"user_id" => "@mutual-rl-target:test.local"}
      max_attempts = 500

      # Dynamic probe: fire requests up to a high ceiling and stop the
      # instant a 429 is observed, rather than firing a fixed count and
      # checking only at the end. This endpoint's rate-limit tier is not
      # yet decided — a fixed-count burst would pass or fail purely based
      # on which tier an implementer picks (e.g. this project already uses
      # a generous `burst: 100` for GET /sync), so the ceiling here only
      # needs to exceed whatever tier gets configured, not match it exactly.
      blocked =
        Enum.reduce_while(1..max_attempts, nil, fn _attempt, _acc ->
          conn = mutual_rooms_from_ip(token, params, ip)
          if conn.status == 429, do: {:halt, conn}, else: {:cont, nil}
        end)

      assert blocked != nil,
             "a sustained burst from one IP must eventually be rate-limited with 429; " <>
               "no 429 observed within #{max_attempts} attempts"

      assert blocked.status == 429
      assert json(blocked)["errcode"] == "M_LIMIT_EXCEEDED"

      retry_after = get_resp_header(blocked, "retry-after") |> List.first()
      assert retry_after != nil, "a 429 must carry a Retry-After header"
      assert String.to_integer(retry_after) >= 1
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC1-AC5 contract shape + AC3/AC4 pagination — INTEGRATION
  # Drives the full router with a valid Bearer against the real OTP tree
  # (Postgres etc.). Every identity is freshly generated per test
  # (tag-#{unique_integer}) so exact `count`/`joined` assertions can never be
  # polluted by rooms created in another test in this file, another test file
  # in the same suite run, or a prior suite run against a long-lived DB.
  # ══════════════════════════════════════════════════════════════════════════

  describe "mutual_rooms — contract parity" do
    @describetag :integration

    setup do
      priv = setup_oidc_keys()
      {:ok, priv_jwk: priv}
    end

    defp fresh_user(priv, tag) do
      sub = tag <> "-" <> Integer.to_string(System.unique_integer([:positive]))
      {uid, token} = bearer_for(sub, priv)

      if Process.whereis(Nebu.Repo) do
        _ = Nebu.Matrix.Session.TokenValidator.validate(uid, "user", tag, sub <> "@example.com")
        _ = Nebu.Matrix.Profile.DB.upsert_profile(uid, tag, nil)
      end

      {uid, token}
    end

    # ── flow helpers (drive the router itself, mirror matrix_room_routes_test.exs) ──

    defp create_room(token, name) do
      conn = call(:post, "/_matrix/client/v3/createRoom", %{"name" => name}, auth(token))
      assert conn.status == 200, "createRoom must succeed to set up the scenario"
      json(conn)["room_id"]
    end

    defp invite_user(token, room_id, user_id) do
      conn =
        call(
          :post,
          "/_matrix/client/v3/rooms/#{URI.encode_www_form(room_id)}/invite",
          %{"user_id" => user_id},
          auth(token)
        )

      assert conn.status == 200, "invite must succeed to set up the scenario"
      conn
    end

    defp join_room(token, room_id) do
      conn = call(:post, "/_matrix/client/v3/join/#{URI.encode_www_form(room_id)}", %{}, auth(token))
      assert conn.status == 200, "join must succeed to set up the scenario"
      conn
    end

    # ── AC1 + AC2 ────────────────────────────────────────────────────────────
    # A shared (both joined) room appears; a caller-only room and a room where
    # the other user was only INVITED (never joined) do NOT appear. All of it
    # fits in one page → next_batch key is entirely ABSENT (not null/"").

    test "only the truly-shared room appears; caller-only and invited-not-joined rooms are excluded; no next_batch (AC1, AC2)",
         %{priv_jwk: priv} do
      {_kai_uid, kai_token} = fresh_user(priv, "mutual-caller")
      {marie_uid, marie_token} = fresh_user(priv, "mutual-other")

      shared_room = create_room(kai_token, "mutual-shared-room")
      invite_user(kai_token, shared_room, marie_uid)
      join_room(marie_token, shared_room)

      _caller_only_room = create_room(kai_token, "mutual-caller-only-room")

      invited_not_joined_room = create_room(kai_token, "mutual-invited-not-joined-room")
      invite_user(kai_token, invited_not_joined_room, marie_uid)
      # marie is deliberately never joined to invited_not_joined_room.

      conn = mutual_rooms(kai_token, marie_uid)
      assert conn.status == 200

      body = json(conn)
      assert body["count"] == 1
      assert body["joined"] == [shared_room]
      refute Map.has_key?(body, "next_batch"),
             "next_batch must be entirely absent when everything fits on one page"
    end

    # ── AC5 ──────────────────────────────────────────────────────────────────

    test "user_id for a syntactically-valid but unknown user → 200 count 0 joined [] (never 404) (AC5)",
         %{priv_jwk: priv} do
      {_kai_uid, kai_token} = fresh_user(priv, "mutual-caller")
      unknown_user_id = "@mutual-ghost-" <> Integer.to_string(System.unique_integer([:positive])) <> ":test.local"

      conn = mutual_rooms(kai_token, unknown_user_id)
      assert conn.status == 200

      body = json(conn)
      assert body["count"] == 0
      assert body["joined"] == []
      refute Map.has_key?(body, "next_batch")
    end

    # ── AC3 + AC4 — pagination ───────────────────────────────────────────────

    test "shared rooms exceeding one page → next_batch + TOTAL count (AC3); walking `from` yields the rest with no duplicates (AC4)",
         %{priv_jwk: priv} do
      {_kai_uid, kai_token} = fresh_user(priv, "mutual-caller")
      {marie_uid, marie_token} = fresh_user(priv, "mutual-other")

      Application.put_env(:event_dispatcher, :mutual_rooms_page_size, 2)
      on_exit(fn -> Application.delete_env(:event_dispatcher, :mutual_rooms_page_size) end)

      room_ids =
        for i <- 1..5 do
          room_id = create_room(kai_token, "mutual-page-#{i}")
          invite_user(kai_token, room_id, marie_uid)
          join_room(marie_token, room_id)
          room_id
        end

      # ── AC3: first page ──
      first = mutual_rooms(kai_token, marie_uid)
      assert first.status == 200
      first_body = json(first)

      assert first_body["count"] == 5, "count must be the TOTAL shared-room count, not the page length"
      assert length(first_body["joined"]) > 0
      assert length(first_body["joined"]) < 5, "the first page must be strictly smaller than the total"
      assert Enum.all?(first_body["joined"], &(&1 in room_ids))
      assert is_binary(first_body["next_batch"]) and first_body["next_batch"] != "",
             "next_batch must be a non-empty opaque token when more pages remain"

      # ── AC4: walk the remaining pages via `from` ──
      {rest, last_count} = walk_all_pages(kai_token, marie_uid, first_body["next_batch"], [])

      assert last_count == 5, "count must stay the TOTAL on every page of the walk"

      all_joined = first_body["joined"] ++ rest
      assert Enum.sort(all_joined) == Enum.sort(room_ids),
             "the union of every page's joined ids must equal the full shared-room set"

      assert length(Enum.uniq(all_joined)) == length(all_joined),
             "no room id may appear twice across the full paginated walk"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Regression guard — unstable MSC2666 alias
  # GET /_matrix/client/unstable/uk.half-shot.msc2666/user/mutual_rooms must
  # return the SAME `joined` contents as the stable v1 route for a shared-
  # rooms scenario, AND — the actual regression this guards against — it must
  # NEVER truncate `joined` or emit `next_batch`, even when the shared-room
  # count exceeds whatever page size the stable v1 route is configured with
  # (the historical/unstable endpoint never paginated).
  # ══════════════════════════════════════════════════════════════════════════

  describe "mutual_rooms — unstable MSC2666 alias" do
    @describetag :integration

    setup do
      priv = setup_oidc_keys()
      {:ok, priv_jwk: priv}
    end

    test "200 with correct joined contents for a shared-rooms scenario", %{priv_jwk: priv} do
      {_kai_uid, kai_token} = fresh_user(priv, "mutual-unstable-caller")
      {marie_uid, marie_token} = fresh_user(priv, "mutual-unstable-other")

      shared_room = create_room(kai_token, "mutual-unstable-shared-room")
      invite_user(kai_token, shared_room, marie_uid)
      join_room(marie_token, shared_room)

      _caller_only_room = create_room(kai_token, "mutual-unstable-caller-only-room")

      conn = mutual_rooms_unstable(kai_token, marie_uid)
      assert conn.status == 200

      body = json(conn)
      assert body["count"] == 1
      assert body["joined"] == [shared_room]
      refute Map.has_key?(body, "next_batch")
    end

    test "with MORE shared rooms than the configured page size, the unstable alias returns ALL of them in one response with no next_batch",
         %{priv_jwk: priv} do
      {_kai_uid, kai_token} = fresh_user(priv, "mutual-unstable-caller")
      {marie_uid, marie_token} = fresh_user(priv, "mutual-unstable-other")

      # Force the stable v1 route's page size well below the number of shared
      # rooms created below, so a request that DID forward to the paginated
      # path unchanged would observably truncate `joined` and emit
      # `next_batch` — exactly the gap this alias must not reproduce.
      Application.put_env(:event_dispatcher, :mutual_rooms_page_size, 2)
      on_exit(fn -> Application.delete_env(:event_dispatcher, :mutual_rooms_page_size) end)

      room_ids =
        for i <- 1..5 do
          room_id = create_room(kai_token, "mutual-unstable-page-#{i}")
          invite_user(kai_token, room_id, marie_uid)
          join_room(marie_token, room_id)
          room_id
        end

      # Sanity check: the STABLE v1 route is indeed paginated under this
      # configuration (proves the page-size override is actually in effect).
      stable_conn = mutual_rooms(kai_token, marie_uid)
      assert stable_conn.status == 200
      stable_body = json(stable_conn)
      assert stable_body["count"] == 5
      assert length(stable_body["joined"]) < 5
      assert Map.has_key?(stable_body, "next_batch")

      # The UNSTABLE alias must return everything in one shot regardless.
      conn = mutual_rooms_unstable(kai_token, marie_uid)
      assert conn.status == 200

      body = json(conn)
      assert body["count"] == 5
      assert Enum.sort(body["joined"]) == Enum.sort(room_ids),
             "unstable alias must return the COMPLETE joined list, never truncated"

      refute Map.has_key?(body, "next_batch"),
             "unstable alias must never emit next_batch — the historical endpoint has no pagination concept"
    end

    test "a `from` query param on the unstable alias is ignored rather than erroring", %{priv_jwk: priv} do
      {_kai_uid, kai_token} = fresh_user(priv, "mutual-unstable-caller")
      {marie_uid, marie_token} = fresh_user(priv, "mutual-unstable-other")

      shared_room = create_room(kai_token, "mutual-unstable-from-ignored-room")
      invite_user(kai_token, shared_room, marie_uid)
      join_room(marie_token, shared_room)

      conn =
        mutual_rooms_unstable(kai_token, %{"user_id" => marie_uid, "from" => "whatever-a-legacy-client-might-send"})

      assert conn.status == 200
      body = json(conn)
      assert body["count"] == 1
      assert body["joined"] == [shared_room]
      refute Map.has_key?(body, "next_batch")
    end
  end
end
