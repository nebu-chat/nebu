defmodule Nebu.Matrix.LoginRefreshTest do
  @moduledoc """
  RED-phase ATDD tests for `oidc-session-refresh` — login + /refresh HTTP surface.

  Drives the full `Nebu.Web.Router` via `Plug.Test`, mirroring
  `matrix_router_test.exs` and `matrix_sso_test.exs`.

  ## Why these MUST FAIL right now

  * AC1: login with `refresh_token: true` currently returns the raw OIDC JWT as
    `access_token` (the "AC7 fallback", http_public.ex:~274) — no opaque token,
    no `refresh_token`, no `expires_in_ms`.
  * AC2/AC3: `POST /_matrix/client/v3/refresh` is not routed yet → falls through
    to the catch-all / 404.
  * AC5: `OidcPlug` has no opaque-token path, so an expired opaque AT is treated
    as a malformed JWT (`M_UNKNOWN_TOKEN` *without* `soft_logout`), not the
    `soft_logout: true` envelope the spec requires.

  ## Seams (use, don't reinvent)

  * `:matrix_sso_token_override` — the existing SSO code-exchange seam
    (sso_login.ex:317). To make an OIDC *refresh* token available on the login
    path, this story extends the override to return a 3-tuple
    `{:ok, id_token, oidc_refresh_token}` (the dev threads the RT through
    SsoStore + provision_and_respond). The legacy `{:ok, id_token}` 2-tuple keeps
    working (AC7 / no-RT fallback). The AC1 test below drives the real SSO
    callback → loginToken → `POST /login` flow so an OIDC RT is genuinely present.
  * `:oidc_jwks` / `:oidc_issuer` / `:oidc_audience` — inject the verifying JWK so
    no network call is needed (same as the sibling tests).

  Tagged `:integration` — excluded from `mix test`; runs via `make test-integration`.
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  @moduletag :integration

  alias Nebu.Matrix.SsoStore

  @server_name "test.local"
  @issuer "https://idp.example.com/realms/nebu"
  @audience "nebu-client"
  @kid "login-refresh-key-1"
  @authorize "https://idp.example.com/realms/nebu/auth"
  @token_endpoint "https://idp.example.com/realms/nebu/token"

  # Per-run-unique sub → per-run-unique Matrix user id. config/test.exs uses a
  # RANDOM pii_encryption_key per boot, so the test process cannot decrypt PII rows
  # written by another boot's key (e.g. a pre-existing @alice:test.local from the
  # running server). Each run provisions + decrypts its OWN rows with this boot's
  # key, so a unique sub avoids colliding with pre-existing users → no login 500.
  # A FRESH sub PER TEST (generated in setup), not a shared module attribute:
  # config/test.exs uses a RANDOM pii_encryption_key per boot, so the test process
  # cannot decrypt PII rows written under another boot's key (a pre-existing
  # @alice:test.local from the running server) → login 500. A unique id per test
  # means each test provisions + decrypts its OWN row with this boot's key. It MUST
  # be per-test (not per-module): the deactivate_user / invalidate_user_sessions
  # tests permanently set is_active=false on their user, and TokenValidator never
  # reactivates — a shared id would 403 every test that ran after them. lowercase
  # hex needs no localpart sanitisation, so the uid is exactly "@<sub>:<server>".
  defp fresh_sub, do: "alice" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

  # The per-test sub is stashed in the process dictionary by setup so the signing
  # helpers (sign_id_token / mint_login_token) read the SAME id the test provisions.
  defp current_sub, do: Process.get(:login_refresh_sub) || raise("sub not set by setup")

  @router_opts Nebu.Web.Router.init([])
  @hex64 ~r/^[0-9a-f]{64}$/

  # ── shared helpers ──────────────────────────────────────────────────────────

  defp future_exp, do: System.system_time(:second) + 3600

  defp setup_oidc do
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
    Application.put_env(:nebu_http, :oidc_issuer, @issuer)
    Application.put_env(:nebu_http, :oidc_audience, @audience)
    Application.put_env(:nebu_http, :oidc_jwks, [pub_jwk])
    Application.put_env(:nebu_http, :matrix_oidc_client_id, "nebu-client")
    Application.put_env(:nebu_http, :matrix_oidc_client_secret, "shhh")
    # oidc-session-refresh: the login path encrypts the captured OIDC refresh token
    # at rest via Nebu.Web.SecretBox, which derives its AES-256 key from the internal
    # secret. Inject a non-empty test secret through the same seam the admin helper
    # uses (:admin_secret_at_rest) so encryption succeeds without a real env file.
    Application.put_env(:nebu_http, :admin_secret_at_rest, "login-refresh-test-internal-secret")

    Application.put_env(:nebu_http, :oidc_metadata_override, %{
      "issuer" => @issuer,
      "authorization_endpoint" => @authorize,
      "token_endpoint" => @token_endpoint,
      "jwks_uri" => @issuer <> "/jwks"
    })

    on_exit(fn ->
      for k <- [
            :server_name,
            :oidc_issuer,
            :oidc_audience,
            :oidc_jwks,
            :matrix_oidc_client_id,
            :matrix_oidc_client_secret,
            :oidc_metadata_override,
            :matrix_sso_token_override,
            :admin_secret_at_rest
          ] do
        Application.delete_env(:nebu_http, k)
      end
    end)

    priv_jwk
  end

  defp sign_id_token(priv_jwk, overrides) do
    claims =
      Map.merge(
        %{
          "iss" => @issuer,
          "aud" => @audience,
          "sub" => current_sub(),
          "exp" => future_exp(),
          "iat" => System.system_time(:second)
        },
        overrides
      )

    jws = %{"alg" => "RS256", "kid" => @kid}
    signed = JOSE.JWT.sign(JOSE.JWK.from_map(priv_jwk), jws, claims)
    {_, compact} = JOSE.JWS.compact(signed)
    compact
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
  defp location(conn), do: conn |> get_resp_header("location") |> List.first()

  defp opaque, do: :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)

  # Run the real SSO redirect→callback flow with an injected token exchange that
  # ALSO yields an OIDC refresh token, returning the single-use opaque loginToken
  # the client then redeems at POST /login.
  defp mint_login_token(priv, oidc_refresh_token) do
    redirect_url = "http://localhost:7070/#/home"

    init =
      call(
        :get,
        "/_matrix/client/v3/login/sso/redirect?redirectUrl=" <> URI.encode_www_form(redirect_url)
      )

    assert init.status == 302, "SSO redirect must 302 to set up the login-token flow"
    params = init |> location() |> URI.parse() |> Map.get(:query) |> URI.decode_query()
    state = params["state"]
    nonce = params["nonce"]

    id_token = sign_id_token(priv, %{"sub" => current_sub(), "nonce" => nonce})

    # 3-tuple override: dev extends the exchange seam to surface the OIDC RT.
    Application.put_env(:nebu_http, :matrix_sso_token_override, fn ->
      {:ok, id_token, oidc_refresh_token}
    end)

    cb =
      call(
        :get,
        "/_matrix/client/v3/login/sso/redirect/oidc?code=authcode&state=" <> URI.encode_www_form(state)
      )

    assert cb.status == 302
    cb_query = cb |> location() |> URI.parse() |> Map.get(:query) |> URI.decode_query()
    login_token = cb_query["loginToken"]
    assert is_binary(login_token) and login_token != ""
    login_token
  end

  setup do
    # These tests hammer POST /login + /refresh + /sync from a single (default) peer
    # IP, which would trip the per-IP login limiter. Disable the limiter LOCALLY for
    # this file only (no global env — that bug throttled nothing AND broke the
    # RateLimitTest assertions). Restore the prior value exactly in on_exit so it
    # cannot bleed into the rate-limit assertion tests.
    prev_rl = Application.get_env(:nebu_http, :rate_limit_disabled)
    Application.put_env(:nebu_http, :rate_limit_disabled, true)

    on_exit(fn ->
      case prev_rl do
        nil -> Application.delete_env(:nebu_http, :rate_limit_disabled)
        v -> Application.put_env(:nebu_http, :rate_limit_disabled, v)
      end
    end)

    if Process.whereis(SsoStore) == nil, do: start_supervised!(SsoStore)
    priv = setup_oidc()

    sub = fresh_sub()
    Process.put(:login_refresh_sub, sub)
    uid = "@" <> sub <> ":" <> @server_name

    if Process.whereis(Nebu.Repo) do
      _ = Nebu.Matrix.Session.TokenValidator.validate(uid, "user", "Alice", "alice@example.com")
      _ = Nebu.Matrix.Profile.DB.upsert_profile(uid, "Alice", nil)

      on_exit(fn ->
        if Process.whereis(Nebu.Repo) do
          # matrix_sessions holds BOTH opaque access + refresh tokens (columns, not a
          # separate table). Delete it before users (FK).
          for table <- ["matrix_sessions", "profiles", "users"] do
            _ =
              Ecto.Adapters.SQL.query(
                Nebu.Repo,
                "DELETE FROM #{table} WHERE user_id = $1",
                [uid]
              )
          end
        end
      end)
    end

    {:ok, priv_jwk: priv, user_id: uid}
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC1 — login with refresh_token:true → opaque AT + opaque RT + expires_in_ms
  # ══════════════════════════════════════════════════════════════════════════

  describe "POST /login with refresh_token:true (AC1)" do
    test "returns opaque access_token, opaque refresh_token, positive expires_in_ms", %{
      priv_jwk: priv,
      user_id: uid
    } do
      login_token = mint_login_token(priv, "oidc-rt-from-keycloak")

      resp =
        call(:post, "/_matrix/client/v3/login", %{
          "type" => "m.login.token",
          "token" => login_token,
          "refresh_token" => true
        })

      assert resp.status == 200
      body = json(resp)

      assert body["user_id"] == uid
      assert is_binary(body["device_id"])

      # access_token is opaque: 64 lowercase hex, NO dots (not a JWT).
      assert is_binary(body["access_token"])
      refute String.contains?(body["access_token"], "."), "access_token must not be a JWT"
      assert Regex.match?(@hex64, body["access_token"])

      # refresh_token is opaque, same shape.
      assert is_binary(body["refresh_token"])
      refute String.contains?(body["refresh_token"], ".")
      assert Regex.match?(@hex64, body["refresh_token"])

      # expires_in_ms is a positive integer (ms until the AT expires).
      assert is_integer(body["expires_in_ms"])
      assert body["expires_in_ms"] > 0
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Configurable session-TTL seam (story e2e-session-refresh-suites, AC1)
  # Proves BOTH the login path AND the /v3/refresh re-mint path honor a short
  # NEBU_MATRIX_SESSION_TTL_SECONDS (the re-mint path was the test-review MAJOR).
  # ══════════════════════════════════════════════════════════════════════════

  describe "configurable session TTL (Nebu.Web.SessionConfig seam)" do
    test "a short TTL shrinks expires_in_ms on BOTH login and /refresh re-mint", %{priv_jwk: priv} do
      # future_exp is now+3600s; without the seam the login ceiling is min(exp, now+8h)=~3600s
      # (≈3_600_000 ms). A 60s TTL must cap it far below that, on login AND on refresh re-mint.
      Application.put_env(:nebu_http, :matrix_session_ttl_seconds, 60)
      on_exit(fn -> Application.delete_env(:nebu_http, :matrix_session_ttl_seconds) end)

      login =
        call(:post, "/_matrix/client/v3/login", %{
          "type" => "m.login.token",
          "token" => mint_login_token(priv, "oidc-rt-from-keycloak"),
          "refresh_token" => true
        })

      assert login.status == 200
      login_ttl_ms = json(login)["expires_in_ms"]
      assert login_ttl_ms > 0 and login_ttl_ms <= 61_000, "login honors the 60s TTL (got #{login_ttl_ms})"

      # The /v3/refresh re-mint independently re-derives the lifetime — it must use the seam too.
      refresh = call(:post, "/_matrix/client/v3/refresh", %{"refresh_token" => json(login)["refresh_token"]})
      assert refresh.status == 200
      remint_ttl_ms = json(refresh)["expires_in_ms"]
      assert remint_ttl_ms > 0 and remint_ttl_ms <= 61_000, "refresh re-mint honors the 60s TTL (got #{remint_ttl_ms})"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC7 — login WITHOUT refresh_token:true → JWT as before (backward compat)
  # ══════════════════════════════════════════════════════════════════════════

  describe "POST /login without refresh_token (AC7 backward compat)" do
    test "access_token IS a JWT (has dots); no refresh_token / expires_in_ms", %{priv_jwk: priv} do
      login_token = mint_login_token(priv, "oidc-rt-from-keycloak")

      resp =
        call(:post, "/_matrix/client/v3/login", %{
          "type" => "m.login.token",
          "token" => login_token
        })

      assert resp.status == 200
      body = json(resp)

      # Unchanged legacy shape: the verified OIDC JWT is returned verbatim.
      assert is_binary(body["access_token"])
      assert String.contains?(body["access_token"], "."), "legacy access_token must be a JWT"
      refute Map.has_key?(body, "refresh_token")
      refute Map.has_key?(body, "expires_in_ms")
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC2 + AC3 — POST /refresh returns new opaque tokens; new AT works for /sync
  # ══════════════════════════════════════════════════════════════════════════

  describe "POST /_matrix/client/v3/refresh (AC2, AC3)" do
    test "valid RT → 200 new opaque tokens; the new AT then works for GET /sync", %{
      priv_jwk: priv
    } do
      login_token = mint_login_token(priv, "oidc-rt-from-keycloak")

      login =
        call(:post, "/_matrix/client/v3/login", %{
          "type" => "m.login.token",
          "token" => login_token,
          "refresh_token" => true
        })

      assert login.status == 200
      rt = json(login)["refresh_token"]
      assert is_binary(rt)

      # /refresh requires NO Authorization header (Matrix MUST).
      refresh = call(:post, "/_matrix/client/v3/refresh", %{"refresh_token" => rt})
      assert refresh.status == 200
      rbody = json(refresh)

      assert is_binary(rbody["access_token"])
      refute String.contains?(rbody["access_token"], ".")
      assert Regex.match?(@hex64, rbody["access_token"])
      assert is_binary(rbody["refresh_token"])
      assert is_integer(rbody["expires_in_ms"]) and rbody["expires_in_ms"] > 0

      # AC3: the new opaque AT is immediately usable.
      sync = call(:get, "/_matrix/client/v3/sync", nil, auth(rbody["access_token"]))
      assert sync.status == 200
    end

    # MINOR-1 (tightened): an empty {} body is a well-formed JSON object that is
    # MISSING the required refresh_token field → M_MISSING_PARAM specifically (the
    # handler distinguishes empty-{} from malformed JSON, Dev Notes §5).
    test "empty body → 400 M_MISSING_PARAM" do
      resp = call(:post, "/_matrix/client/v3/refresh", %{})
      assert resp.status == 400
      assert json(resp)["errcode"] == "M_MISSING_PARAM"
    end

    test "unknown / used refresh token → 401 M_UNKNOWN_TOKEN (AC6)" do
      resp = call(:post, "/_matrix/client/v3/refresh", %{"refresh_token" => opaque()})
      assert resp.status == 401
      assert json(resp)["errcode"] == "M_UNKNOWN_TOKEN"
    end

    # MINOR-2 (added): AC6 "already-used-and-replaced RT → 401" at the HTTP level.
    # Rotate RT_A → (AT_B, RT_B), use AT_B once (closes the old RT's grace window),
    # then re-presenting RT_A must be rejected.
    test "rotated-then-used old RT → 401 M_UNKNOWN_TOKEN (AC6 HTTP level)", %{priv_jwk: priv} do
      login_token = mint_login_token(priv, "oidc-rt-from-keycloak")

      login =
        call(:post, "/_matrix/client/v3/login", %{
          "type" => "m.login.token",
          "token" => login_token,
          "refresh_token" => true
        })

      assert login.status == 200
      rt_a = json(login)["refresh_token"]

      refresh = call(:post, "/_matrix/client/v3/refresh", %{"refresh_token" => rt_a})
      assert refresh.status == 200
      at_b = json(refresh)["access_token"]

      # Use the new AT once — this closes the grace window on the old (RT_A) row.
      sync = call(:get, "/_matrix/client/v3/sync", nil, auth(at_b))
      assert sync.status == 200

      # The old RT is now fully invalid.
      reuse = call(:post, "/_matrix/client/v3/refresh", %{"refresh_token" => rt_a})
      assert reuse.status == 401
      assert json(reuse)["errcode"] == "M_UNKNOWN_TOKEN"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC5 — expired opaque AT → 401 M_UNKNOWN_TOKEN with soft_logout: true
  # ══════════════════════════════════════════════════════════════════════════

  describe "expired opaque access token (AC5)" do
    test "GET /sync with an expired opaque AT → 401 soft_logout:true", %{priv_jwk: priv} do
      login_token = mint_login_token(priv, "oidc-rt-from-keycloak")

      login =
        call(:post, "/_matrix/client/v3/login", %{
          "type" => "m.login.token",
          "token" => login_token,
          "refresh_token" => true
        })

      assert login.status == 200
      at = json(login)["access_token"]

      # Force the row's expires_at into the past (deterministic, no sleep).
      {:ok, _} =
        Ecto.Adapters.SQL.query(
          Nebu.Repo,
          "UPDATE matrix_sessions SET expires_at = NOW() - INTERVAL '1 second' WHERE access_token = $1",
          [at]
        )

      resp = call(:get, "/_matrix/client/v3/sync", nil, auth(at))
      assert resp.status == 401
      body = json(resp)
      assert body["errcode"] == "M_UNKNOWN_TOKEN"
      assert body["soft_logout"] == true
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # MINOR-2 — admin deactivation / full logout invalidates opaque matrix_sessions.
  # invalidate_user_sessions(device_id="") must DELETE the matrix_sessions row so a
  # deactivated user's opaque AT stops working immediately (not up to 8h later).
  # ══════════════════════════════════════════════════════════════════════════

  describe "invalidate_user_sessions clears opaque matrix_sessions (MINOR-2)" do
    test "after invalidation (device_id=\"\") the opaque session row is gone and the AT → 401",
         %{priv_jwk: priv, user_id: uid} do
      login_token = mint_login_token(priv, "oidc-rt-from-keycloak")

      login =
        call(:post, "/_matrix/client/v3/login", %{
          "type" => "m.login.token",
          "token" => login_token,
          "refresh_token" => true
        })

      assert login.status == 200
      at = json(login)["access_token"]

      # The opaque AT works before invalidation.
      assert {:ok, _} = Nebu.Matrix.Session.MatrixSessionStore.get_by_access_token(at)
      assert call(:get, "/_matrix/client/v3/sync", nil, auth(at)).status == 200

      # Admin deactivation path: device_id="" → all devices.
      req = %Core.InvalidateUserSessionsRequest{user_id: uid, device_id: ""}
      assert %Core.InvalidateUserSessionsResponse{ok: true} =
               Nebu.Matrix.EventDispatcher.Server.invalidate_user_sessions(req, nil)

      # The matrix_sessions row is gone and the opaque AT no longer authenticates.
      assert :error = Nebu.Matrix.Session.MatrixSessionStore.get_by_access_token(at)
      assert call(:get, "/_matrix/client/v3/sync", nil, auth(at)).status == 401
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # cycle-2 (Kassandra HIGH) — admin deactivation (the deactivate_user entry
  # point, NOT invalidate_user_sessions) must DELETE the opaque matrix_sessions
  # rows so a deactivated user's opaque AT stops working immediately and
  # POST /refresh can no longer mint fresh tokens for them.
  # ══════════════════════════════════════════════════════════════════════════

  describe "deactivate_user clears opaque matrix_sessions (cycle-2 HIGH)" do
    test "after deactivate_user: row gone, opaque AT → 401, and the RT → 401",
         %{priv_jwk: priv, user_id: uid} do
      login_token = mint_login_token(priv, "oidc-rt-from-keycloak")

      login =
        call(:post, "/_matrix/client/v3/login", %{
          "type" => "m.login.token",
          "token" => login_token,
          "refresh_token" => true
        })

      assert login.status == 200
      at = json(login)["access_token"]
      rt = json(login)["refresh_token"]

      # The opaque AT works before deactivation.
      assert {:ok, _} = Nebu.Matrix.Session.MatrixSessionStore.get_by_access_token(at)
      assert call(:get, "/_matrix/client/v3/sync", nil, auth(at)).status == 200

      # Drive the REAL admin deactivation path (deactivate_user/2 — the entry
      # point admin offboarding actually calls), with a trusted-admin stream so
      # the audit log records a real actor.
      stream = %{http_request_headers: %{"x-user-id" => "@admin:" <> @server_name, "x-system-role" => "admin"}}
      req = %Core.DeactivateUserRequest{user_id: uid}

      assert %Core.DeactivateUserResponse{ok: true} =
               Nebu.Matrix.EventDispatcher.Server.deactivate_user(req, stream)

      # (a) the opaque matrix_sessions row is gone.
      assert :error = Nebu.Matrix.Session.MatrixSessionStore.get_by_access_token(at)

      # (b) the opaque AT no longer authenticates GET /sync.
      assert call(:get, "/_matrix/client/v3/sync", nil, auth(at)).status == 401

      # (c) POST /refresh with the deactivated user's RT no longer mints tokens.
      refresh = call(:post, "/_matrix/client/v3/refresh", %{"refresh_token" => rt})
      assert refresh.status == 401
      assert json(refresh)["errcode"] == "M_UNKNOWN_TOKEN"
    end
  end
end
