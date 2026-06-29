defmodule Nebu.Web.MatrixRouterTest do
  @moduledoc """
  RED-phase ATDD tests for the `matrix-api-migration` story.

  Goal: every Matrix Client-Server API endpoint currently served by the Go
  gateway is served directly by the Elixir Plug.Router (`Nebu.Web.Router` →
  `Nebu.Web.Router.Protected` / `Nebu.Http.MatrixRouter`). The new handlers must
  call the SAME internal OTP functions used by `Nebu.Matrix.EventDispatcher.Server`
  (no gRPC hop) and reproduce the exact Go JSON response shapes.

  ## Why these tests MUST FAIL right now

  At the time these tests are written the protected sub-router only contains a
  `/client/v3/sync` stub plus a catch-all `match _` that returns
  `%{"authenticated_user" => user}`. None of the real Matrix endpoints below are
  implemented, so:

    * discovery routes (auth_issuer / auth_metadata) currently fall through the
      `/_matrix` forward into `OidcPlug` and are rejected with 401 (no Bearer) —
      they MUST become unauthenticated 200s.
    * authed endpoints currently return the catch-all `{"authenticated_user"}`
      shape, NOT the Matrix contract shape asserted below.

  ## Test layering

    * Pure-unit tests (no `:integration` tag): exercise routing + response shape
      that need NO auth and NO DB — the MSC2965 discovery endpoints (AC5) and the
      auth gate (no/garbage Bearer → 401 envelope). These run in the default
      `mix test` profile.

    * `@moduletag :integration` block: contract-shape tests for the authenticated
      endpoints. They drive the full `Nebu.Web.Router` via `Plug.Test` and rely on
      the event_dispatcher test-injection seams
      (`Application.put_env(:event_dispatcher, :rooms_db_module, …)` etc., exactly
      the override keys defined at the top of
      `core/apps/event_dispatcher/lib/nebu/event_dispatcher/server.ex`) so they do
      not need a live PostgreSQL. They are excluded from the default profile
      (`test_helper.exs` sets `exclude: [:integration]`) and run in CI's
      integration stage against the full OTP supervision tree.

  All assertions encode the Oracle contract from the story prompt.
  """

  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  @server_name "test.local"
  @issuer "https://keycloak.example.com/realms/nebu"
  @audience "nebu-gateway"
  @kid "matrix-router-key-1"

  # Per-run-unique sub → per-run-unique Matrix user id. config/test.exs uses a
  # RANDOM pii_encryption_key per boot, so the test process cannot decrypt PII rows
  # written under a DIFFERENT boot's key (e.g. a pre-existing @kai:test.local from
  # the running server) → login 500. A unique sub per run means each run provisions
  # and decrypts its OWN rows with this boot's key. lowercase hex needs no localpart
  # sanitisation, so the uid is exactly "@<sub>:<server>".
  @run_id Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
  @kai_sub "kai" <> @run_id

  @router_opts Nebu.Web.Router.init([])

  # ── shared helpers ────────────────────────────────────────────────────────

  defp future_exp, do: System.system_time(:second) + 3600

  # Generate an in-test RSA keypair, inject the public JWK so OidcPlug verifies
  # without a network call, and return the private JWK map for signing.
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
    Nebu.Web.OidcTestSupport.configure(@issuer, @audience)

    Application.put_env(:nebu_http, :oidc_jwks, [pub_jwk])

    ExUnit.Callbacks.on_exit(fn ->
      Application.delete_env(:nebu_http, :server_name)
      Nebu.Web.OidcTestSupport.clear()
      Application.delete_env(:nebu_http, :oidc_jwks)
    end)

    priv_jwk
  end

  # Sign an RS256 JWT whose `sub` becomes the Matrix user id "@<sub>:<server>".
  defp bearer_for(sub, priv_jwk) do
    claims = %{
      "iss" => @issuer,
      "aud" => @audience,
      "sub" => sub,
      "exp" => future_exp(),
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

    conn =
      Enum.reduce(headers, conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)

    Nebu.Web.Router.call(conn, @router_opts)
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)

  # ══════════════════════════════════════════════════════════════════════════
  # AC5 — MSC2965 OIDC discovery (no auth, no DB) — PURE UNIT
  # ══════════════════════════════════════════════════════════════════════════

  describe "OIDC discovery endpoints (AC5) — unauthenticated, no DB" do
    setup do
      # oidc-bootstrap-only-config (ADR-022): the discovery handlers resolve the
      # issuer via Nebu.Web.OidcConfig.get().issuer, not env. Install the OidcConfig
      # seam so auth_issuer / auth_metadata can resolve a known issuer without a DB.
      Nebu.Web.OidcTestSupport.configure(@issuer, @audience)

      # MINOR-4: auth_metadata proxies the live provider's discovery document and
      # now fails CLOSED (503) when the provider is unreachable — it no longer
      # synthesises a (Keycloak-shaped, Dex-wrong) fallback. The :oidc_metadata_override
      # test seam (Nebu.Matrix.OidcMetadata.fetch/1) lets us assert the 200 happy-path
      # shape without a live network call.
      Application.put_env(:nebu_http, :oidc_metadata_override, %{
        "issuer" => @issuer,
        "authorization_endpoint" => @issuer <> "/auth",
        "token_endpoint" => @issuer <> "/token",
        "jwks_uri" => @issuer <> "/jwks"
      })

      on_exit(fn ->
        Nebu.Web.OidcTestSupport.clear()
        Application.delete_env(:nebu_http, :oidc_metadata_override)
      end)

      :ok
    end

    test "GET /_matrix/client/v1/auth_issuer → 200 %{\"issuer\" => issuer} without a Bearer token" do
      conn = call(:get, "/_matrix/client/v1/auth_issuer")
      assert conn.status == 200
      body = json(conn)
      assert body["issuer"] == @issuer
    end

    test "GET /_matrix/client/unstable/org.matrix.msc2965/auth_issuer → 200 %{\"issuer\" => issuer}" do
      conn = call(:get, "/_matrix/client/unstable/org.matrix.msc2965/auth_issuer")
      assert conn.status == 200
      assert json(conn)["issuer"] == @issuer
    end

    test "GET /_matrix/client/v1/auth_metadata → 200 OIDC metadata object" do
      conn = call(:get, "/_matrix/client/v1/auth_metadata")
      assert conn.status == 200
      body = json(conn)
      assert is_map(body)
      assert Map.has_key?(body, "issuer")
      assert Map.has_key?(body, "authorization_endpoint")
      assert Map.has_key?(body, "token_endpoint")
    end

    test "GET /_matrix/client/unstable/org.matrix.msc2965/auth_metadata → 200 OIDC metadata object" do
      conn = call(:get, "/_matrix/client/unstable/org.matrix.msc2965/auth_metadata")
      assert conn.status == 200
      body = json(conn)
      assert Map.has_key?(body, "issuer")
      assert Map.has_key?(body, "authorization_endpoint")
    end

    test "GET auth_metadata fails CLOSED with 503 M_UNAVAILABLE when the provider is unreachable (MINOR-4)" do
      # Drop the override and point at an unreachable issuer so the live fetch
      # fails. The handler must NOT synthesise wrong endpoint URLs — it returns
      # 503 M_UNAVAILABLE, mirroring the Go authMetadataHandler.
      Application.delete_env(:nebu_http, :oidc_metadata_override)

      conn = call(:get, "/_matrix/client/v1/auth_metadata")
      assert conn.status == 503
      assert json(conn)["errcode"] == "M_UNAVAILABLE"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # MAJOR-1 — GET /_matrix/client/v3/login advertises login flows
  # Unauthenticated, static route (no token, no DB) — PURE UNIT. Mirrors the Go
  # gateway GetLogin handler (login.go): m.login.sso + m.login.token.
  # ══════════════════════════════════════════════════════════════════════════

  describe "GET /_matrix/client/v3/login (login flows, MAJOR-1) — unauthenticated, no DB" do
    setup do
      Application.put_env(:nebu_http, :oidc_display_name, "Test SSO")
      on_exit(fn -> Application.delete_env(:nebu_http, :oidc_display_name) end)
      :ok
    end

    test "GET /_matrix/client/v3/login → 200 with m.login.sso + m.login.token flows" do
      conn = call(:get, "/_matrix/client/v3/login")
      assert conn.status == 200

      ct = get_resp_header(conn, "content-type") |> List.first() |> to_string()
      assert String.contains?(ct, "application/json")

      body = json(conn)
      flows = body["flows"]
      assert is_list(flows)

      types = Enum.map(flows, & &1["type"])
      # Element Web 1.12+ needs BOTH advertised together (see login.go GetLogin).
      assert "m.login.sso" in types
      assert "m.login.token" in types

      sso = Enum.find(flows, &(&1["type"] == "m.login.sso"))
      [idp | _] = sso["identity_providers"]
      assert idp["id"] == "oidc"
      assert idp["name"] == "Test SSO"
      assert Map.has_key?(idp, "icon")
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Auth gate (carry-over security) — PURE UNIT
  # Confirms forwarded Matrix traffic is validated by OidcPlug first (no bypass).
  # ══════════════════════════════════════════════════════════════════════════

  describe "auth gate on protected Matrix routes" do
    test "GET /_matrix/client/v3/sync with NO Bearer → 401 M_MISSING_TOKEN envelope" do
      conn = call(:get, "/_matrix/client/v3/sync")
      assert conn.status == 401

      ct = get_resp_header(conn, "content-type") |> List.first() |> to_string()
      assert String.contains?(ct, "application/json")

      body = json(conn)
      assert body["errcode"] == "M_MISSING_TOKEN"
      assert is_binary(body["error"])
    end

    test "GET /_matrix/client/v3/sync with a garbage Bearer token → 401 M_UNKNOWN_TOKEN" do
      _priv = setup_oidc_keys()

      conn =
        call(:get, "/_matrix/client/v3/sync", nil, [
          {"authorization", "Bearer not-a-real-jwt"}
        ])

      assert conn.status == 401
      assert json(conn)["errcode"] == "M_UNKNOWN_TOKEN"
    end

    # Parity regression (elixir-stack-regression GATE → matrix-api-migration):
    # PUT .../send with a MALFORMED JSON body must return 400 M_BAD_JSON, mirroring
    # the Go gateway and the typing handler. The bad-body guard fires after OidcPlug
    # but BEFORE any room/core lookup, so this needs a valid Bearer but no DB — it
    # runs in the default (non-integration) profile. Before the fix the handler
    # mapped the malformed body to %{} and returned 200 {event_id}.
    test "PUT send with a MALFORMED JSON body → 400 M_BAD_JSON (no DB)" do
      priv = setup_oidc_keys()
      {_uid, token} = bearer_for("kai", priv)

      conn =
        try do
          conn(
            :put,
            "/_matrix/client/v3/rooms/#{URI.encode_www_form("!any:test.local")}/send/m.room.message/txn-bad",
            "{not valid json"
          )
          |> put_req_header("content-type", "application/json")
          |> put_req_header("authorization", "Bearer " <> token)
          |> Nebu.Web.Router.call(@router_opts)
        rescue
          e in Plug.Parsers.ParseError ->
            flunk(
              "send must return 400 M_BAD_JSON for malformed JSON, but Plug.Parsers raised: " <>
                Exception.message(e)
            )
        end

      assert conn.status == 400
      assert json(conn)["errcode"] == "M_BAD_JSON"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # F-5 — X-Content-Type-Options: nosniff on every response (PURE UNIT)
  # ══════════════════════════════════════════════════════════════════════════

  describe "security headers (F-5)" do
    test "every response carries X-Content-Type-Options: nosniff" do
      # /health (200), a 401 envelope, and a discovery 200 should all carry it.

      for conn <- [
            call(:get, "/health"),
            call(:get, "/_matrix/client/v3/sync"),
            call(:get, "/_matrix/client/v1/auth_issuer")
          ] do
        assert get_resp_header(conn, "x-content-type-options") == ["nosniff"],
               "response (status #{conn.status}) must carry X-Content-Type-Options: nosniff"
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # F-3 — per-IP rate limit on POST /login (PURE UNIT, no DB)
  # The login handler verifies the token before any DB work; an invalid token
  # gives 403, but once the per-IP bucket is empty the limiter must answer 429
  # M_LIMIT_EXCEEDED BEFORE the handler runs. We force a tiny burst via the
  # RateLimit ETS bucket by hammering the same peer IP.
  # ══════════════════════════════════════════════════════════════════════════

  describe "login rate limit (F-3)" do
    setup do
      _priv = setup_oidc_keys()

      # The integration harness sets NEBU_RATE_LIMIT_DISABLED=true (and other suites
      # set :rate_limit_disabled) so they are not throttled. This test EXPLICITLY
      # enables the limiter for its duration — otherwise the disabled escape hatch
      # makes the plug a no-op and no 429 is ever produced. Mirrors url_preview_test.
      prev_env = System.get_env("NEBU_RATE_LIMIT_DISABLED")
      System.delete_env("NEBU_RATE_LIMIT_DISABLED")
      prev_app = Application.get_env(:nebu_http, :rate_limit_disabled)
      # DELETE the override (not put false) so a leaked `true` from a sibling test —
      # e.g. login_refresh_test / the AC1 contract block — cannot disable the limiter
      # under us. With the key absent the plug's disabled? default (false) applies and
      # the limiter is ENABLED, which is what this block asserts. Consistent with the
      # RateLimitTest setup that also force-deletes the key.
      Application.delete_env(:nebu_http, :rate_limit_disabled)

      # Clean the shared bucket table so the count starts fresh.
      if :ets.whereis(:nebu_http_rate_limit_buckets) != :undefined do
        :ets.delete_all_objects(:nebu_http_rate_limit_buckets)
      end

      on_exit(fn ->
        if :ets.whereis(:nebu_http_rate_limit_buckets) != :undefined do
          :ets.delete_all_objects(:nebu_http_rate_limit_buckets)
        end

        case prev_app do
          nil -> Application.delete_env(:nebu_http, :rate_limit_disabled)
          v -> Application.put_env(:nebu_http, :rate_limit_disabled, v)
        end

        if prev_env, do: System.put_env("NEBU_RATE_LIMIT_DISABLED", prev_env)
      end)

      :ok
    end

    test "a single IP that exceeds the login burst is rejected with 429 M_LIMIT_EXCEEDED" do
      # The login limiter is 30/min burst 10. From one IP, the first ~10 calls
      # pass through to the handler (which 403s the bad token); a later call in
      # the same burst window is rejected by the limiter with 429 before the
      # handler runs. Drive 40 calls from a fixed peer to guarantee exhaustion.
      results =
        for _ <- 1..40 do
          conn =
            conn(:post, "/_matrix/client/v3/login", Jason.encode!(%{"type" => "m.login.token", "token" => "bad"}))
            |> put_req_header("content-type", "application/json")
            |> Map.put(:remote_ip, {203, 0, 113, 7})
            |> Nebu.Web.Router.call(@router_opts)

          conn.status
        end

      assert 429 in results, "the login limiter must reject a burst from one IP with 429"

      # Find one 429 and assert the Matrix envelope + Retry-After.
      conn =
        conn(:post, "/_matrix/client/v3/login", Jason.encode!(%{"type" => "m.login.token", "token" => "bad"}))
        |> put_req_header("content-type", "application/json")
        |> Map.put(:remote_ip, {203, 0, 113, 7})
        |> Nebu.Web.Router.call(@router_opts)

      assert conn.status == 429
      assert json(conn)["errcode"] == "M_LIMIT_EXCEEDED"
      assert get_resp_header(conn, "retry-after") |> List.first() != nil
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Authenticated endpoint contract-shape tests (AC1) — INTEGRATION
  # Drive the full router with a valid Bearer; rely on event_dispatcher injection
  # seams so no live DB is needed. These exercise the SAME OTP functions the gRPC
  # server delegates to (no gRPC hop).
  # ══════════════════════════════════════════════════════════════════════════

  describe "authenticated Matrix endpoints — contract parity (AC1)" do
    @describetag :integration

    setup do
      # These contract tests drive POST /login + protected endpoints repeatedly from
      # the default peer IP, which would trip the per-IP login limiter. Disable the
      # limiter LOCALLY for this describe block only (no global env — the F-3 block
      # below ASSERTS the limiter and must keep working). Restore the prior value
      # exactly in on_exit so nothing bleeds into the rate-limit assertion tests.
      prev_rl = Application.get_env(:nebu_http, :rate_limit_disabled)
      Application.put_env(:nebu_http, :rate_limit_disabled, true)

      on_exit(fn ->
        case prev_rl do
          nil -> Application.delete_env(:nebu_http, :rate_limit_disabled)
          v -> Application.put_env(:nebu_http, :rate_limit_disabled, v)
        end
      end)

      priv = setup_oidc_keys()
      {uid, token} = bearer_for(@kai_sub, priv)

      # Fixture: "kai is a logged-in user." In the migrated stack the Elixir side
      # is the single auth + provisioning point (OidcPlug provisions on any authed
      # request; login provisions explicitly). Provision kai up-front so this
      # describe block's contract tests are order-independent — e.g. the
      # unauthenticated GET /profile/{uid} test must find kai's profile row
      # regardless of which test ran first. Guarded by Repo presence so it is a
      # no-op in any non-DB run. Best-effort: ignore the result.
      if Process.whereis(Nebu.Repo) do
        _ = Nebu.Matrix.Session.TokenValidator.validate(uid, "user", "Kai", "kai@example.com")
        # validate/4 provisions the users row; the profiles row is upserted by the
        # login path (Server.validate_token). Mirror that here so GET /profile finds it.
        _ = Nebu.Matrix.Profile.DB.upsert_profile(uid, "Kai", nil)

        on_exit(fn ->
          if Process.whereis(Nebu.Repo) do
            # matrix_sessions before users (FK). Per-run-unique uid → no cross-run leak.
            for table <- ["matrix_sessions", "profiles", "users"] do
              _ = Ecto.Adapters.SQL.query(Nebu.Repo, "DELETE FROM #{table} WHERE user_id = $1", [uid])
            end
          end
        end)
      end

      {:ok, priv_jwk: priv, user_id: uid, token: token}
    end

    defp auth(token), do: [{"authorization", "Bearer " <> token}]

    test "POST /_matrix/client/v3/login → 200 {user_id, access_token, device_id, token_type:\"Bearer\"}",
         %{token: token, user_id: uid} do
      conn =
        call(:post, "/_matrix/client/v3/login", %{
          "type" => "m.login.token",
          "token" => token
        })

      assert conn.status == 200
      body = json(conn)
      assert body["user_id"] == uid
      assert is_binary(body["access_token"])
      assert is_binary(body["device_id"])
      assert body["token_type"] == "Bearer"
    end

    test "POST /_matrix/client/v3/login with malformed JSON → 400 M_NOT_JSON", %{} do
      # The login handler must surface a Matrix 400 M_NOT_JSON envelope for a body
      # that is not valid JSON — NOT let Plug.Parsers raise a 500-class ParseError.
      # Implementation must read the body itself or install an error handler that
      # converts Plug.Parsers.ParseError → 400 M_NOT_JSON.
      conn =
        try do
          conn(:post, "/_matrix/client/v3/login", "{not json")
          |> put_req_header("content-type", "application/json")
          |> Nebu.Web.Router.call(@router_opts)
        rescue
          e in Plug.Parsers.ParseError ->
            flunk(
              "login must return 400 M_NOT_JSON for malformed JSON, but Plug.Parsers raised: " <>
                Exception.message(e)
            )
        end

      assert conn.status == 400
      assert json(conn)["errcode"] == "M_NOT_JSON"
    end

    test "POST /_matrix/client/v3/login with unsupported login type → 400 M_UNKNOWN",
         %{token: token} do
      conn =
        call(:post, "/_matrix/client/v3/login", %{"type" => "m.login.password", "token" => token})

      assert conn.status == 400
      assert json(conn)["errcode"] == "M_UNKNOWN"
    end

    test "POST /_matrix/client/v3/logout → 200 {}", %{token: token} do
      conn = call(:post, "/_matrix/client/v3/logout", %{}, auth(token))
      assert conn.status == 200
      assert json(conn) == %{}
    end

    # F-1 regression: logout must REVOKE the access token. The Go gateway wrote
    # the token to a denylist on logout and checked it on every request; the
    # migrated Elixir path returns the OIDC token verbatim, so without a denylist
    # a logged-out token would keep re-validating until its exp. This proves the
    # full round-trip: use (200) → logout (200) → reuse same token (401).
    test "F-1: after logout the same Bearer token is rejected with 401 M_UNKNOWN_TOKEN", %{
      token: token
    } do
      # Clean the denylist so a prior test cannot mask the behaviour.
      if :ets.whereis(:nebu_http_token_denylist) != :undefined do
        :ets.delete_all_objects(:nebu_http_token_denylist)
      end

      # 1. The token works before logout.
      before = call(:get, "/_matrix/client/v3/sync", nil, auth(token))
      assert before.status == 200, "token must be accepted before logout"

      # 2. Logout (the same token authenticates the logout request).
      out = call(:post, "/_matrix/client/v3/logout", %{}, auth(token))
      assert out.status == 200
      assert json(out) == %{}

      # 3. Reusing the SAME token must now be rejected — logout actually revoked it.
      after_logout = call(:get, "/_matrix/client/v3/sync", nil, auth(token))
      assert after_logout.status == 401, "a logged-out token must not be reusable"
      assert json(after_logout)["errcode"] == "M_UNKNOWN_TOKEN"
    end

    test "GET /_matrix/client/v3/sync → 200 {next_batch, rooms{join,invite,leave}}",
         %{token: token} do
      conn = call(:get, "/_matrix/client/v3/sync", nil, auth(token))
      assert conn.status == 200
      body = json(conn)
      assert is_binary(body["next_batch"])
      assert is_map(body["rooms"])
      assert Map.has_key?(body["rooms"], "join")
      assert Map.has_key?(body["rooms"], "invite")
      assert Map.has_key?(body["rooms"], "leave")
    end

    test "POST /_matrix/client/v3/createRoom → 200 {room_id \"!...\"}", %{token: token} do
      conn = call(:post, "/_matrix/client/v3/createRoom", %{"name" => "shape-test"}, auth(token))
      assert conn.status == 200
      body = json(conn)
      assert is_binary(body["room_id"])
      assert String.starts_with?(body["room_id"], "!")
    end

    test "POST /_matrix/client/v3/join/{roomIdOrAlias} → 200 {room_id}", %{token: token} do
      room_id = create_room(token, "join-shape")

      conn = call(:post, "/_matrix/client/v3/join/#{URI.encode_www_form(room_id)}", %{}, auth(token))
      assert conn.status == 200
      assert json(conn)["room_id"] == room_id
    end

    test "PUT send → 200 {event_id \"$...\"}", %{token: token} do
      room_id = create_room(token, "send-shape")

      conn =
        call(
          :put,
          "/_matrix/client/v3/rooms/#{URI.encode_www_form(room_id)}/send/m.room.message/txn-001",
          %{"msgtype" => "m.text", "body" => "hi"},
          auth(token)
        )

      assert conn.status == 200
      body = json(conn)
      assert is_binary(body["event_id"])
      assert String.starts_with?(body["event_id"], "$")
    end

    test "PUT send is idempotent: same txnId+device → identical event_id, no duplicate (AC1)",
         %{token: token} do
      room_id = create_room(token, "idempotency-shape")

      send_once = fn ->
        call(
          :put,
          "/_matrix/client/v3/rooms/#{URI.encode_www_form(room_id)}/send/m.room.message/dup-txn",
          %{"msgtype" => "m.text", "body" => "dup"},
          auth(token)
        )
      end

      first = json(send_once.()) |> Map.fetch!("event_id")
      second = json(send_once.()) |> Map.fetch!("event_id")
      assert first == second, "same txnId must yield the same event_id"
    end

    test "PUT send to a room the caller is NOT a member of → 404 or 403 with Matrix errcode",
         %{token: token} do
      # Unknown room → 404 M_NOT_FOUND per Oracle contract.
      conn =
        call(
          :put,
          "/_matrix/client/v3/rooms/#{URI.encode_www_form("!nonexistent:test.local")}/send/m.room.message/txn-x",
          %{"msgtype" => "m.text", "body" => "x"},
          auth(token)
        )

      assert conn.status == 404
      assert json(conn)["errcode"] == "M_NOT_FOUND"
    end

    test "GET messages → 200 {chunk[], start, end, state:[]}", %{token: token} do
      room_id = create_room(token, "messages-shape")

      conn =
        call(
          :get,
          "/_matrix/client/v3/rooms/#{URI.encode_www_form(room_id)}/messages?dir=b&limit=10",
          nil,
          auth(token)
        )

      assert conn.status == 200
      body = json(conn)
      assert is_list(body["chunk"])
      assert Map.has_key?(body, "start")
      assert Map.has_key?(body, "end")
      assert is_list(body["state"])
    end

    test "GET messages without required dir param → 400 M_MISSING_PARAM", %{token: token} do
      room_id = create_room(token, "messages-nodir")

      conn =
        call(
          :get,
          "/_matrix/client/v3/rooms/#{URI.encode_www_form(room_id)}/messages",
          nil,
          auth(token)
        )

      assert conn.status == 400
      assert json(conn)["errcode"] in ["M_MISSING_PARAM", "M_INVALID_PARAM"]
    end

    test "PUT typing for SELF → 200 {}", %{token: token, user_id: uid} do
      room_id = create_room(token, "typing-shape")

      conn =
        call(
          :put,
          "/_matrix/client/v3/rooms/#{URI.encode_www_form(room_id)}/typing/#{URI.encode_www_form(uid)}",
          %{"typing" => true, "timeout" => 30_000},
          auth(token)
        )

      assert conn.status == 200
      assert json(conn) == %{}
    end

    test "PUT typing typing:true WITHOUT timeout → 400", %{token: token, user_id: uid} do
      room_id = create_room(token, "typing-notimeout")

      conn =
        call(
          :put,
          "/_matrix/client/v3/rooms/#{URI.encode_www_form(room_id)}/typing/#{URI.encode_www_form(uid)}",
          %{"typing" => true},
          auth(token)
        )

      assert conn.status == 400
    end

    test "PUT typing for a DIFFERENT user → 403 M_FORBIDDEN", %{token: token} do
      room_id = create_room(token, "typing-other")
      other = URI.encode_www_form("@someone-else:test.local")

      conn =
        call(
          :put,
          "/_matrix/client/v3/rooms/#{URI.encode_www_form(room_id)}/typing/#{other}",
          %{"typing" => true, "timeout" => 30_000},
          auth(token)
        )

      assert conn.status == 403
      assert json(conn)["errcode"] == "M_FORBIDDEN"
    end

    test "POST receipt → 200 {}", %{token: token} do
      room_id = create_room(token, "receipt-shape")
      event_id = send_message(token, room_id, "for-receipt")

      conn =
        call(
          :post,
          "/_matrix/client/v3/rooms/#{URI.encode_www_form(room_id)}/receipt/m.read/#{URI.encode_www_form(event_id)}",
          %{},
          auth(token)
        )

      assert conn.status == 200
      assert json(conn) == %{}
    end

    test "POST receipt with a bad receipt type → 400", %{token: token} do
      room_id = create_room(token, "receipt-bad")
      event_id = send_message(token, room_id, "for-bad-receipt")

      conn =
        call(
          :post,
          "/_matrix/client/v3/rooms/#{URI.encode_www_form(room_id)}/receipt/not.a.receipt/#{URI.encode_www_form(event_id)}",
          %{},
          auth(token)
        )

      assert conn.status == 400
    end

    test "GET /_matrix/client/v3/profile/{userId} → 200 with optional displayname/avatar_url",
         %{token: token, user_id: uid} do
      conn = call(:get, "/_matrix/client/v3/profile/#{URI.encode_www_form(uid)}", nil, auth(token))
      assert conn.status == 200
      body = json(conn)
      assert is_map(body)
      # displayname / avatar_url are optional — assert they are absent or strings.
      if Map.has_key?(body, "displayname"), do: assert(is_binary(body["displayname"]))
      if Map.has_key?(body, "avatar_url"), do: assert(is_binary(body["avatar_url"]))
    end

    test "GET profile for an unknown user → 404 M_NOT_FOUND", %{token: token} do
      conn =
        call(
          :get,
          "/_matrix/client/v3/profile/#{URI.encode_www_form("@ghost:test.local")}",
          nil,
          auth(token)
        )

      assert conn.status == 404
      assert json(conn)["errcode"] == "M_NOT_FOUND"
    end

    test "PUT profile for SELF → 200", %{token: token, user_id: uid} do
      conn =
        call(
          :put,
          "/_matrix/client/v3/profile/#{URI.encode_www_form(uid)}/displayname",
          %{"displayname" => "Kai"},
          auth(token)
        )

      assert conn.status == 200
    end

    test "PUT profile for a DIFFERENT user → 403 M_FORBIDDEN", %{token: token} do
      other = URI.encode_www_form("@not-me:test.local")

      conn =
        call(
          :put,
          "/_matrix/client/v3/profile/#{other}/displayname",
          %{"displayname" => "Hacker"},
          auth(token)
        )

      assert conn.status == 403
      assert json(conn)["errcode"] == "M_FORBIDDEN"
    end

    test "GET /_matrix/client/v3/presence/{userId}/status → 200 {presence, last_active_ago}",
         %{token: token, user_id: uid} do
      conn =
        call(:get, "/_matrix/client/v3/presence/#{URI.encode_www_form(uid)}/status", nil, auth(token))

      assert conn.status == 200
      body = json(conn)
      assert body["presence"] in ["online", "offline", "unavailable"]
      assert is_integer(body["last_active_ago"])
    end

    test "PUT /_matrix/client/v3/presence/{userId}/status for a DIFFERENT user → 403 M_FORBIDDEN",
         %{token: token} do
      other = URI.encode_www_form("@not-me:test.local")

      conn =
        call(
          :put,
          "/_matrix/client/v3/presence/#{other}/status",
          %{"presence" => "online"},
          auth(token)
        )

      assert conn.status == 403
      assert json(conn)["errcode"] == "M_FORBIDDEN"
    end

    # ── small flow helpers (drive the router itself, no gRPC) ──────────────

    defp create_room(token, name) do
      conn =
        call(:post, "/_matrix/client/v3/createRoom", %{"name" => name}, [
          {"authorization", "Bearer " <> token}
        ])

      assert conn.status == 200, "createRoom must succeed to set up the scenario"
      room_id = Jason.decode!(conn.resp_body)["room_id"]

      assert is_binary(room_id) and String.starts_with?(room_id, "!"),
             "createRoom must return a real Matrix room_id (got: #{inspect(room_id)})"

      room_id
    end

    defp send_message(token, room_id, body) do
      txn = "setup-" <> Integer.to_string(System.unique_integer([:positive]))

      conn =
        call(
          :put,
          "/_matrix/client/v3/rooms/#{URI.encode_www_form(room_id)}/send/m.room.message/#{txn}",
          %{"msgtype" => "m.text", "body" => body},
          [{"authorization", "Bearer " <> token}]
        )

      assert conn.status == 200, "send must succeed to set up the scenario"
      Jason.decode!(conn.resp_body)["event_id"]
    end
  end
end
