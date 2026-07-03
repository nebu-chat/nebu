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
  import ExUnit.CaptureLog

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
    Nebu.Web.OidcTestSupport.configure(@issuer, @audience)

    Application.put_env(:nebu_http, :oidc_jwks, [pub_jwk])
    # oidc-session-refresh: the login path encrypts the captured OIDC refresh token
    # at rest via Nebu.Web.SecretBox, which derives its AES-256 key from the internal
    # secret. Inject a non-empty test secret through the same seam the admin helper
    # uses (:admin_secret_at_rest) so encryption succeeds without a real env file.
    Application.put_env(:nebu_http, :admin_secret_at_rest, "login-refresh-test-internal-secret")

    # The SSO single client comes from the Bootstrap DB via the :sso_bootstrap_reader
    # seam (ADR-022) — NOT from removed :matrix_oidc_client_* env keys. The redirect
    # leg needs it to build the authorize URL; the token exchange itself is stubbed by
    # :matrix_sso_token_override.
    encrypted_secret = Nebu.Admin.BootstrapLive.encrypt_secret("shhh")

    Application.put_env(:nebu_http, :sso_bootstrap_reader, fn
      "oidc_client_id" -> "nebu-client"
      "oidc_client_secret" -> encrypted_secret
      _ -> nil
    end)

    Application.put_env(:nebu_http, :oidc_metadata_override, %{
      "issuer" => @issuer,
      "authorization_endpoint" => @authorize,
      "token_endpoint" => @token_endpoint,
      "jwks_uri" => @issuer <> "/jwks"
    })

    on_exit(fn ->
      Nebu.Web.OidcTestSupport.clear()

      for k <- [
            :server_name,
            :oidc_jwks,
            :sso_bootstrap_reader,
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

  # fix-matrix-login-missing-refresh-token (AC4): no helper on MatrixSessionStore
  # queries "how many session rows for this user" — the store only exposes
  # lookups by access_token / refresh_token (by design, it's an opaque-token
  # store, not a per-user index). A raw COUNT against matrix_sessions mirrors
  # the existing raw-SQL convention already used in this file's on_exit/expiry
  # helpers (e.g. the expires_at UPDATE above) to prove the AC7/AC4 JWT-fallback
  # path creates NO opaque session row for the user.
  defp session_count_for_user(user_id) do
    {:ok, %{rows: [[count]]}} =
      Ecto.Adapters.SQL.query(
        Nebu.Repo,
        "SELECT COUNT(*) FROM matrix_sessions WHERE user_id = $1",
        [user_id]
      )

    count
  end

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

      # matrix-refresh-revalidates-with-idp: /refresh now contacts the IdP before
      # re-minting — stub the round-trip with a far-future fresh id_token.exp so
      # THIS test's assertion (the TTL seam, not the IdP exp, caps expires_in_ms)
      # is exercised in isolation.
      put_matrix_oidc_refresh_override(fn _decrypted_rt ->
        {:ok, %{"sub" => current_sub(), "exp" => future_exp()}, nil}
      end)

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
  # fix-matrix-login-missing-refresh-token — AC2 + AC4
  #
  # AC1 diagnosis (this story): Nebu.Web.OidcScopes.resolve_scope(:matrix)
  # (server/lib/nebu/web/oidc_scopes.ex:74-86) correctly appends "offline_access"
  # whenever the Matrix refresh mode is "offline" (the default — refresh_mode/1
  # collapses anything other than the literal "online" to "offline", see
  # oidc_scopes.ex:151-163). Nebu therefore DOES request offline_access
  # correctly — root cause (b) (a scope-construction code bug) is RULED OUT by
  # this code path. Root cause (c) (a parsing bug in extract_id_token) is also
  # ruled out: sso_login.ex extract_id_token/1 (~lines 504-521) correctly reads
  # body["refresh_token"] and threads it through as nil when absent — that is
  # spec-correct OAuth2 behavior, not a bug.
  #
  # This leaves root cause (a): when the IdP grants no offline_access (e.g. a
  # misconfigured Keycloak client), Nebu silently gets no refresh_token in the
  # token response, which is legal per OAuth2, and Nebu already degrades
  # correctly to the JWT-only response (AC7 fallback, http_public.ex
  # respond_login/7). What was NOT true, and is fixed by this story, is AC2:
  # the existing WARNING log (http_public.ex ~416-420) is not as operator-
  # actionable as the admin-side parity message
  # (admin/auth.ex store_refresh_token/2, ~326-330: "admin login: no OIDC
  # refresh token returned — session cannot be silently refreshed; ensure the
  # IdP grants offline_access to the admin client"). This story's fix is a
  # logging-parity fix only (AC1 outcome (a) — no Nebu code-behavior bug, no
  # AC3 fix needed); AC4 additionally closes an untested branch.
  # ══════════════════════════════════════════════════════════════════════════

  describe "POST /login: offline_access requested but IdP grants none (AC2, AC4)" do
    test "degrades to JWT-only response (no refresh_token/expires_in_ms) even though refresh_token:true was sent",
         %{priv_jwk: priv} do
      # oidc_refresh_token: nil simulates a Keycloak-style IdP that ignores the
      # requested offline_access scope and returns a token response with no
      # refresh_token at all (OAuth2-legal — RFC 6749 does not require the
      # server to grant every requested scope).
      login_token = mint_login_token(priv, nil)

      resp =
        call(:post, "/_matrix/client/v3/login", %{
          "type" => "m.login.token",
          "token" => login_token,
          "refresh_token" => true
        })

      assert resp.status == 200
      body = json(resp)

      assert is_binary(body["access_token"])

      assert String.contains?(body["access_token"], "."),
             "AC4: with no OIDC refresh token available, access_token must degrade to the raw JWT"

      refute Map.has_key?(body, "refresh_token"),
             "AC4: no refresh_token must be returned when the IdP granted none"

      refute Map.has_key?(body, "expires_in_ms"),
             "AC4: no expires_in_ms must be returned in the JWT-only fallback"
    end

    test "creates NO opaque matrix_sessions row for the user (idempotency of the JWT-only fallback)",
         %{priv_jwk: priv, user_id: uid} do
      login_token = mint_login_token(priv, nil)

      resp =
        call(:post, "/_matrix/client/v3/login", %{
          "type" => "m.login.token",
          "token" => login_token,
          "refresh_token" => true
        })

      assert resp.status == 200

      assert session_count_for_user(uid) == 0,
             "AC4: the JWT-only fallback must not create an opaque matrix_sessions row"
    end

    test "logs a WARNING with admin-parity, operator-actionable wording (AC2)", %{priv_jwk: priv} do
      login_token = mint_login_token(priv, nil)

      log =
        capture_log(fn ->
          resp =
            call(:post, "/_matrix/client/v3/login", %{
              "type" => "m.login.token",
              "token" => login_token,
              "refresh_token" => true
            })

          assert resp.status == 200
        end)

      # AC2: same information content as the admin-side parity message
      # (admin/auth.ex store_refresh_token/2 — "ensure the IdP grants
      # offline_access to the admin client"). The Matrix-side message must be
      # equally concrete: it must name WHICH client needs the offline_access
      # grant, not just gesture at "the IdP" in the abstract.
      assert log =~ "warning",
             "AC2: a missing OIDC refresh token must be logged at WARNING or above"

      assert log =~ "no OIDC refresh token" or log =~ "no refresh token",
             "AC2: the log must name the actual condition (no OIDC refresh token returned)"

      assert log =~ "ensure the IdP grants offline_access to the matrix client",
             "AC2: wording must match admin-side parity (name the SPECIFIC client, " <>
               "like admin/auth.ex store_refresh_token/2 does for the admin client) " <>
               "so an operator can act without reading code"

      # SEC Gate 1: no sensitive values (token contents) must ever appear in the log.
      refute log =~ login_token, "AC2/SEC: the log must never contain a token value"
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

      # matrix-refresh-revalidates-with-idp: /refresh now contacts the IdP
      # before re-minting — stub the round-trip with a far-future fresh
      # id_token.exp (this test is about the opaque-token rotation mechanics,
      # not the IdP-contact behavior, which has its own dedicated describe
      # blocks below).
      put_matrix_oidc_refresh_override(fn _decrypted_rt ->
        {:ok, %{"sub" => current_sub(), "exp" => future_exp()}, nil}
      end)

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

      # matrix-refresh-revalidates-with-idp: stub the mandatory IdP round-trip
      # (this test is about opaque RT rotation/grace mechanics, not the IdP
      # contact itself).
      put_matrix_oidc_refresh_override(fn _decrypted_rt ->
        {:ok, %{"sub" => current_sub(), "exp" => future_exp()}, nil}
      end)

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

  # ══════════════════════════════════════════════════════════════════════════
  # matrix-refresh-revalidates-with-idp — AC1-AC4, AC6
  #
  # GREEN-phase: `do_refresh_with/2` (http_public.ex) now decrypts
  # `sess.oidc_refresh_token` and redeems it at the IdP via
  # `revalidate_with_idp/1` → `exchange_oidc_refresh_token/1` BEFORE any local
  # opaque-token rotation. The `:matrix_oidc_refresh_override` Application-env
  # seam short-circuits that HTTP+JWT-verify leg for tests; every test below
  # that sets it and asserts the seam fun was invoked exercises the real,
  # shipped call path (not a stub for future code).
  #
  # Seam contract (mirrors `:admin_oidc_refresh_override`, admin/auth.ex
  # exchange_refresh_token/1): a 1-arity fun receiving the DECRYPTED OIDC
  # refresh token string, returning `{:ok, claims_map, new_rt_or_nil}` or
  # `{:error, reason}`.
  # ══════════════════════════════════════════════════════════════════════════

  defp put_matrix_oidc_refresh_override(fun) do
    Application.put_env(:nebu_http, :matrix_oidc_refresh_override, fun)
    on_exit(fn -> Application.delete_env(:nebu_http, :matrix_oidc_refresh_override) end)
  end

  # Reads the CURRENT (possibly rotated) encrypted oidc_refresh_token column for
  # a session row, keyed by the ORIGINAL access_token minted at login (rotation
  # changes access_token/refresh_token but the row's PII/session lineage is
  # tracked here via a fresh lookup by whatever AT is currently valid — tests
  # below pass whichever AT is live at the point of the read).
  defp oidc_rt_column_for_access_token(access_token) do
    {:ok, %{rows: rows}} =
      Ecto.Adapters.SQL.query(
        Nebu.Repo,
        "SELECT oidc_refresh_token FROM matrix_sessions WHERE access_token = $1",
        [access_token]
      )

    case rows do
      [[enc]] -> enc
      [] -> nil
    end
  end

  describe "POST /_matrix/client/v3/refresh contacts the IdP (AC1, matrix-refresh-revalidates-with-idp)" do
    test "invokes :matrix_oidc_refresh_override with the DECRYPTED stored OIDC refresh token, BEFORE rotating opaque tokens",
         %{priv_jwk: priv} do
      login_token = mint_login_token(priv, "oidc-rt-from-keycloak")

      login =
        call(:post, "/_matrix/client/v3/login", %{
          "type" => "m.login.token",
          "token" => login_token,
          "refresh_token" => true
        })

      assert login.status == 200
      rt = json(login)["refresh_token"]

      test_pid = self()

      put_matrix_oidc_refresh_override(fn decrypted_rt ->
        send(test_pid, {:matrix_refresh_called, decrypted_rt})
        {:ok, %{"sub" => current_sub(), "exp" => future_exp()}, nil}
      end)

      refresh = call(:post, "/_matrix/client/v3/refresh", %{"refresh_token" => rt})

      assert refresh.status == 200

      # AC1: the seam must be invoked with the PLAINTEXT OIDC refresh token
      # captured at login (never the encrypted-at-rest blob, never Nebu's own
      # opaque RT), proving the IdP is actually contacted before rotation.
      assert_received {:matrix_refresh_called, "oidc-rt-from-keycloak"},
                       "AC1: /refresh must decrypt the stored OIDC refresh token and hand it to " <>
                         "the IdP-exchange seam BEFORE minting/rotating Nebu's own opaque tokens"
    end
  end

  describe "POST /_matrix/client/v3/refresh: IdP rejects the refresh — fail-closed (AC2, AC6)" do
    test "IdP rejection → 401 M_UNKNOWN_TOKEN and the session becomes permanently unusable (no local fallback)",
         %{priv_jwk: priv} do
      login_token = mint_login_token(priv, "oidc-rt-from-keycloak")

      login =
        call(:post, "/_matrix/client/v3/login", %{
          "type" => "m.login.token",
          "token" => login_token,
          "refresh_token" => true
        })

      assert login.status == 200
      rt = json(login)["refresh_token"]
      at = json(login)["access_token"]

      put_matrix_oidc_refresh_override(fn _decrypted_rt ->
        {:error, {:token_endpoint_status, 400}}
      end)

      refresh = call(:post, "/_matrix/client/v3/refresh", %{"refresh_token" => rt})

      assert refresh.status == 401
      assert json(refresh)["errcode"] == "M_UNKNOWN_TOKEN"

      # AC2: fail-CLOSED — no silent fallback to a purely local token extension.
      # The old opaque access token must ALSO stop working (the session row is
      # invalidated, not just the /refresh response withheld while an
      # unchanged row lives on to be re-checked later).
      refute call(:get, "/_matrix/client/v3/sync", nil, auth(at)).status == 200,
             "AC2: fail-closed — a rejected IdP refresh must invalidate the underlying " <>
               "session, not merely refuse this one /refresh response"

      # Retrying /refresh with the same RT must still fail — the session was
      # invalidated, not left alive for a retry to slip through.
      retry = call(:post, "/_matrix/client/v3/refresh", %{"refresh_token" => rt})
      assert retry.status == 401
      assert json(retry)["errcode"] == "M_UNKNOWN_TOKEN"
    end

    test "IdP rejection sets soft_logout: true on the 401 (parity with the existing expired-token envelope)",
         %{priv_jwk: priv} do
      login_token = mint_login_token(priv, "oidc-rt-from-keycloak")

      login =
        call(:post, "/_matrix/client/v3/login", %{
          "type" => "m.login.token",
          "token" => login_token,
          "refresh_token" => true
        })

      assert login.status == 200
      rt = json(login)["refresh_token"]

      put_matrix_oidc_refresh_override(fn _decrypted_rt -> {:error, :network_error} end)

      refresh = call(:post, "/_matrix/client/v3/refresh", %{"refresh_token" => rt})
      assert refresh.status == 401
      body = json(refresh)
      assert body["errcode"] == "M_UNKNOWN_TOKEN"

      assert body["soft_logout"] == true,
             "spec-relevant parity: /refresh's 401 on IdP rejection should carry soft_logout:true, " <>
               "matching the existing expired-opaque-AT 401 envelope (AC5 describe block above)"
    end
  end

  describe "POST /_matrix/client/v3/refresh: fresh id_token indicates deprovisioning (AC2, AC6)" do
    test "a deactivated user's fresh id_token → 401 M_UNKNOWN_TOKEN and the session is invalidated",
         %{priv_jwk: priv, user_id: uid} do
      login_token = mint_login_token(priv, "oidc-rt-from-keycloak")

      login =
        call(:post, "/_matrix/client/v3/login", %{
          "type" => "m.login.token",
          "token" => login_token,
          "refresh_token" => true
        })

      assert login.status == 200
      rt = json(login)["refresh_token"]
      at = json(login)["access_token"]

      # IMPORTANT: this must NOT go through Nebu.Matrix.EventDispatcher.Server
      # .deactivate_user/2 — that entry point ALREADY hard-deletes the
      # matrix_sessions row itself (see "deactivate_user clears opaque
      # matrix_sessions (cycle-2 HIGH)" above), which would make /refresh
      # 401 for the unrelated reason "unknown refresh token" (the row is
      # simply gone) rather than because /refresh itself re-checked
      # deprovisioning on the freshly verified id_token claims. To isolate
      # the NEW behavior this AC is about, flip is_active directly (same
      # raw-SQL convention already used elsewhere in this file, e.g. the
      # expires_at UPDATE above) so the matrix_sessions row is STILL
      # PRESENT and otherwise valid when /refresh runs — the only way it
      # can end up invalidated is if /refresh's own IdP-refresh leg
      # re-evaluates is_active (the same TokenValidator gate the login path
      # uses) on the fresh claims and reacts to it.
      {:ok, _} =
        Ecto.Adapters.SQL.query(
          Nebu.Repo,
          "UPDATE users SET is_active = false WHERE user_id = $1",
          [uid]
        )

      # The IdP itself happily refreshes (no network/token rejection, valid
      # signature/iss/aud/exp) — the deprovisioning must be caught by
      # Nebu's OWN re-check of the user's current is_active status, not by
      # the IdP's response.
      put_matrix_oidc_refresh_override(fn _decrypted_rt ->
        {:ok, %{"sub" => current_sub(), "exp" => future_exp()}, nil}
      end)

      refresh = call(:post, "/_matrix/client/v3/refresh", %{"refresh_token" => rt})

      assert refresh.status == 401
      assert json(refresh)["errcode"] == "M_UNKNOWN_TOKEN"

      refute call(:get, "/_matrix/client/v3/sync", nil, auth(at)).status == 200,
             "AC2: deprovisioning detected on refresh must invalidate the session immediately, " <>
               "kill-switch parity with the existing deactivate_user pattern"
    end
  end

  describe "POST /_matrix/client/v3/refresh: lifetime derived from the fresh id_token (AC3, AC6)" do
    test "expires_in_ms reflects the FRESH id_token.exp from the seam, not the flat ceiling", %{
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

      # A SHORT fresh id_token.exp (30s out) — far below the 8h ceiling. If
      # AC3 is honored, expires_in_ms must reflect THIS short exp (same
      # min(exp, now+ceiling) function as login), not the flat ~8h ceiling.
      short_exp = System.system_time(:second) + 30

      put_matrix_oidc_refresh_override(fn _decrypted_rt ->
        {:ok, %{"sub" => current_sub(), "exp" => short_exp}, nil}
      end)

      refresh = call(:post, "/_matrix/client/v3/refresh", %{"refresh_token" => rt})
      assert refresh.status == 200
      ttl_ms = json(refresh)["expires_in_ms"]

      assert is_integer(ttl_ms) and ttl_ms > 0 and ttl_ms <= 31_000,
             "AC3: expires_in_ms must be derived from the FRESH id_token.exp returned by the " <>
               "IdP-refresh seam via the SAME min(exp, now+ceiling) function login uses — " <>
               "got #{ttl_ms}ms, expected <= 31000ms for a 30s-out fresh exp"
    end
  end

  describe "POST /_matrix/client/v3/refresh: OIDC refresh-token rotation is persisted (AC4, AC6)" do
    test "IdP returns a NEW oidc refresh token → the stored encrypted oidc_refresh_token column changes",
         %{priv_jwk: priv} do
      login_token = mint_login_token(priv, "oidc-rt-from-keycloak")

      login =
        call(:post, "/_matrix/client/v3/login", %{
          "type" => "m.login.token",
          "token" => login_token,
          "refresh_token" => true
        })

      assert login.status == 200
      rt = json(login)["refresh_token"]
      at_before = json(login)["access_token"]
      enc_before = oidc_rt_column_for_access_token(at_before)
      assert is_binary(enc_before)

      put_matrix_oidc_refresh_override(fn _decrypted_rt ->
        {:ok, %{"sub" => current_sub(), "exp" => future_exp()}, "rotated-oidc-rt-from-keycloak"}
      end)

      refresh = call(:post, "/_matrix/client/v3/refresh", %{"refresh_token" => rt})
      assert refresh.status == 200
      at_after = json(refresh)["access_token"]

      enc_after = oidc_rt_column_for_access_token(at_after)
      assert is_binary(enc_after)

      refute enc_after == enc_before,
             "AC4: the IdP returned a new OIDC refresh token — the stored encrypted value must change"

      assert {:ok, "rotated-oidc-rt-from-keycloak"} = Nebu.Web.SecretBox.decrypt(enc_after),
             "AC4: the NEW encrypted column must decrypt to the rotated OIDC RT the seam returned"
    end

    test "IdP returns NO new oidc refresh token → the previous (encrypted) one is kept", %{
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
      at_before = json(login)["access_token"]
      enc_before = oidc_rt_column_for_access_token(at_before)
      assert is_binary(enc_before)

      put_matrix_oidc_refresh_override(fn _decrypted_rt ->
        {:ok, %{"sub" => current_sub(), "exp" => future_exp()}, nil}
      end)

      refresh = call(:post, "/_matrix/client/v3/refresh", %{"refresh_token" => rt})
      assert refresh.status == 200
      at_after = json(refresh)["access_token"]

      enc_after = oidc_rt_column_for_access_token(at_after)

      assert enc_after == enc_before,
             "AC4: when the IdP returns no new refresh_token, the previous encrypted OIDC RT " <>
               "must be carried over UNCHANGED (not cleared, not re-encrypted)"
    end
  end

  describe "POST /_matrix/client/v3/refresh: full happy path end-to-end (AC6 regression)" do
    test "valid OIDC RT → seam returns fresh id_token → new Matrix tokens with lifetime derived from id_token.exp",
         %{priv_jwk: priv} do
      login_token = mint_login_token(priv, "oidc-rt-from-keycloak")

      login =
        call(:post, "/_matrix/client/v3/login", %{
          "type" => "m.login.token",
          "token" => login_token,
          "refresh_token" => true
        })

      assert login.status == 200
      rt = json(login)["refresh_token"]

      fresh_exp = System.system_time(:second) + 120
      test_pid = self()

      put_matrix_oidc_refresh_override(fn decrypted_rt ->
        send(test_pid, {:happy_path_refresh_called, decrypted_rt})
        {:ok, %{"sub" => current_sub(), "exp" => fresh_exp}, "next-oidc-rt"}
      end)

      refresh = call(:post, "/_matrix/client/v3/refresh", %{"refresh_token" => rt})
      assert refresh.status == 200
      rbody = json(refresh)

      assert_received {:happy_path_refresh_called, "oidc-rt-from-keycloak"}

      assert is_binary(rbody["access_token"])
      refute String.contains?(rbody["access_token"], ".")
      assert Regex.match?(@hex64, rbody["access_token"])
      assert is_binary(rbody["refresh_token"])

      assert is_integer(rbody["expires_in_ms"]) and rbody["expires_in_ms"] > 0 and
               rbody["expires_in_ms"] <= 121_000

      # The freshly minted opaque AT is immediately usable.
      sync = call(:get, "/_matrix/client/v3/sync", nil, auth(rbody["access_token"]))
      assert sync.status == 200
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # code-review cycle-1 MAJOR fix — a not-yet-backfilled user (signing_key_id
  # IS NULL: an existing user row that predates crypto-key provisioning) must
  # NOT have their real display_name/email silently wiped to blank by /refresh.
  #
  # check_still_active/2 (http_public.ex) re-validates the user's is_active
  # status via TokenValidator.validate/4 — which is NOT read-only: Postgres's
  # `signing_key_id: nil` branch calls UserProvisioner.provision_user/4, which
  # unconditionally re-encrypts display_name/email with whatever is passed in.
  # The fixed code must pass the FRESH id_token claims' display_name/email
  # (never hardcoded blanks) so this backfill branch, when it fires, persists
  # the user's REAL current profile — not "".
  # ══════════════════════════════════════════════════════════════════════════

  describe "POST /_matrix/client/v3/refresh: not-yet-backfilled user (signing_key_id IS NULL) (code-review cycle-1 MAJOR)" do
    # Rolls the fully-provisioned fixture user (setup already ran
    # TokenValidator.validate, which fully backfills signing_key_id +
    # encrypted PII) BACK to the "existing user, never backfilled" state this
    # bug only manifests on: signing_key_id/encryption_key_id NULL, but
    # is_active still true and the row still exists (unlike a brand-new user,
    # which takes a different TokenValidator branch entirely).
    defp reset_to_not_yet_backfilled(user_id) do
      {:ok, _} =
        Ecto.Adapters.SQL.query(
          Nebu.Repo,
          """
          UPDATE users
          SET signing_key_id = NULL,
              encryption_key_id = NULL,
              display_name_encrypted = NULL,
              display_name_nonce = NULL,
              email_encrypted = NULL,
              email_nonce = NULL,
              email_ephemeral_pub = NULL
          WHERE user_id = $1
          """,
          [user_id]
        )

      {:ok, _} =
        Ecto.Adapters.SQL.query(Nebu.Repo, "DELETE FROM user_keys WHERE user_id = $1", [user_id])

      :ok
    end

    defp decrypted_profile_for(user_id) do
      {:ok, %{rows: [[dn_enc, dn_nonce, email_enc, email_nonce, email_pub, signing_key_id, encryption_key_id]]}} =
        Ecto.Adapters.SQL.query(
          Nebu.Repo,
          """
          SELECT display_name_encrypted, display_name_nonce, email_encrypted, email_nonce,
                 email_ephemeral_pub, signing_key_id, encryption_key_id
          FROM users
          WHERE user_id = $1
          """,
          [user_id]
        )

      server_key = Application.get_env(:signature, :pii_encryption_key)

      display_name =
        case dn_enc && dn_nonce &&
               Nebu.Matrix.Signature.decrypt_operational_pii(dn_enc, dn_nonce, server_key) do
          {:ok, dn} -> dn
          _ -> nil
        end

      enc_priv_key = encryption_private_key_for(encryption_key_id)

      email =
        case email_enc && email_pub && email_nonce &&
               Nebu.Matrix.Signature.decrypt_sensitive_pii(email_enc, email_pub, email_nonce, enc_priv_key) do
          {:ok, e} -> e
          _ -> nil
        end

      %{display_name: display_name, email: email, signing_key_id: signing_key_id}
    end

    defp encryption_private_key_for(nil), do: nil

    defp encryption_private_key_for(encryption_key_id) do
      case Ecto.Adapters.SQL.query(
             Nebu.Repo,
             "SELECT private_key FROM user_keys WHERE key_id = $1",
             [encryption_key_id]
           ) do
        {:ok, %{rows: [[priv]]}} -> priv
        _ -> nil
      end
    end

    test "refresh does NOT wipe real display_name/email to blank and provisions with the fresh id_token's profile claims",
         %{priv_jwk: priv, user_id: uid} do
      login_token = mint_login_token(priv, "oidc-rt-from-keycloak")

      login =
        call(:post, "/_matrix/client/v3/login", %{
          "type" => "m.login.token",
          "token" => login_token,
          "refresh_token" => true
        })

      assert login.status == 200
      rt = json(login)["refresh_token"]

      # Roll the user back to "existing but never backfilled" AFTER login (so
      # the login/session-creation itself is unaffected) — this is the exact
      # branch (Postgres.validate/4 `{:ok, %{signing_key_id: nil}}`) the bug
      # lives in.
      :ok = reset_to_not_yet_backfilled(uid)

      before = decrypted_profile_for(uid)
      assert before.signing_key_id == nil, "sanity check: user must be in the not-yet-backfilled state"

      # The fresh id_token carries the user's REAL current profile — the fix
      # must thread these into the backfill provisioning call, not "".
      put_matrix_oidc_refresh_override(fn _decrypted_rt ->
        {:ok,
         %{
           "sub" => current_sub(),
           "exp" => future_exp(),
           "preferred_username" => "Alice Real Name",
           "email" => "alice-real@example.com"
         }, nil}
      end)

      refresh = call(:post, "/_matrix/client/v3/refresh", %{"refresh_token" => rt})
      assert refresh.status == 200

      after_refresh = decrypted_profile_for(uid)

      refute after_refresh.display_name in [nil, ""],
             "MAJOR fix: /refresh must never leave a not-yet-backfilled user's display_name blank"

      refute after_refresh.email in [nil, ""],
             "MAJOR fix: /refresh must never leave a not-yet-backfilled user's email blank"

      assert after_refresh.display_name == "Alice Real Name",
             "the backfill provisioning call must use the FRESH id_token's profile claims, not hardcoded blanks"

      assert after_refresh.email == "alice-real@example.com",
             "the backfill provisioning call must use the FRESH id_token's profile claims, not hardcoded blanks"

      # The backfill branch DOES legitimately provision fresh signing/encryption
      # keys for a not-yet-backfilled user (that's the whole point of the
      # branch) — assert it actually ran (signing_key_id is no longer nil),
      # rather than asserting "no key generation happened", since key
      # generation on FIRST backfill is correct, expected behavior.
      assert after_refresh.signing_key_id != nil,
             "the not-yet-backfilled user must be provisioned with real keys by this refresh"
    end

    test "a SECOND refresh (now already backfilled) does not re-trigger provisioning or change the profile again",
         %{priv_jwk: priv, user_id: uid} do
      login_token = mint_login_token(priv, "oidc-rt-from-keycloak")

      login =
        call(:post, "/_matrix/client/v3/login", %{
          "type" => "m.login.token",
          "token" => login_token,
          "refresh_token" => true
        })

      assert login.status == 200
      rt = json(login)["refresh_token"]

      :ok = reset_to_not_yet_backfilled(uid)

      put_matrix_oidc_refresh_override(fn _decrypted_rt ->
        {:ok,
         %{
           "sub" => current_sub(),
           "exp" => future_exp(),
           "preferred_username" => "Alice Real Name",
           "email" => "alice-real@example.com"
         }, nil}
      end)

      refresh1 = call(:post, "/_matrix/client/v3/refresh", %{"refresh_token" => rt})
      assert refresh1.status == 200
      rt2 = json(refresh1)["refresh_token"]

      after_first = decrypted_profile_for(uid)
      signing_key_id_after_first = after_first.signing_key_id
      assert signing_key_id_after_first != nil

      # A second refresh with a (hypothetically) different display_name in the
      # fresh claims must NOT overwrite the already-backfilled row — the
      # `WHERE signing_key_id IS NULL` guard on UserProvisioner.provision_user/4
      # makes the write a no-op once backfilled, needless key regeneration is
      # avoided, and the profile is untouched by this second call.
      put_matrix_oidc_refresh_override(fn _decrypted_rt ->
        {:ok,
         %{
           "sub" => current_sub(),
           "exp" => future_exp(),
           "preferred_username" => "Someone Else Entirely",
           "email" => "someone-else@example.com"
         }, nil}
      end)

      refresh2 = call(:post, "/_matrix/client/v3/refresh", %{"refresh_token" => rt2})
      assert refresh2.status == 200

      after_second = decrypted_profile_for(uid)

      assert after_second.signing_key_id == signing_key_id_after_first,
             "an already-backfilled user must not have their signing key regenerated on subsequent refreshes"

      assert after_second.display_name == "Alice Real Name",
             "an already-backfilled user's profile must not be overwritten by a later refresh's fresh claims"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # code-review cycle-1 MINOR (m2) — a session with NO stored
  # oidc_refresh_token is permanently unrefreshable via revalidate_with_idp/1's
  # `defp revalidate_with_idp(_sess), do: {:error, :no_oidc_refresh_token}`
  # fallthrough. This is intentional (Resource-Server posture requires a real
  # IdP round-trip — there is nothing to redeem), documented here explicitly
  # as a regression test rather than an untested side effect.
  # ══════════════════════════════════════════════════════════════════════════

  describe "POST /_matrix/client/v3/refresh: session with no stored OIDC refresh token (code-review cycle-1 m2)" do
    test "is permanently unrefreshable — 401 M_UNKNOWN_TOKEN and the session is invalidated (intentional, not a fallback)",
         %{user_id: uid} do
      # mint_login_token(priv, nil) simulates the IdP granting no
      # offline_access / no refresh_token at all — the AC7 JWT-only fallback
      # path (fix-matrix-login-missing-refresh-token) — which creates NO
      # opaque matrix_sessions row at all. To exercise revalidate_with_idp/1's
      # `no_oidc_refresh_token` fallthrough specifically (a session ROW that
      # exists but has no OIDC RT), mint an opaque session by hand exactly like
      # the login path would, only with the oidc_refresh_token column left
      # empty.
      alias Nebu.Matrix.Session.MatrixSessionStore, as: Store

      at = opaque()
      rt = opaque()

      :ok =
        Store.create(%{
          user_id: uid,
          device_id: "REFRESHTESTDEV",
          access_token: at,
          refresh_token: rt,
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        })

      # No :matrix_oidc_refresh_override needed — a session with no stored
      # OIDC RT must never reach the IdP-exchange seam at all.
      refresh = call(:post, "/_matrix/client/v3/refresh", %{"refresh_token" => rt})

      assert refresh.status == 401
      assert json(refresh)["errcode"] == "M_UNKNOWN_TOKEN"

      # The opaque AT for this session must also stop working — same
      # fail-closed hard-invalidation as any other revalidate_with_idp/1
      # error (AC2 kill-switch parity), not merely a refused /refresh response.
      refute call(:get, "/_matrix/client/v3/sync", nil, auth(at)).status == 200,
             "m2: a session with no stored OIDC refresh token must be hard-invalidated on the first " <>
               "/refresh attempt, not left alive for a retry"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # code-review cycle-1 MINOR (m1) — a TRANSIENT failure while re-checking
  # is_active (e.g. a DB hiccup — anything other than a confirmed
  # `{:error, :deactivated}` verdict or an IdP-round-trip rejection) must be
  # distinguished from CONFIRMED deprovisioning: check_still_active/2 wraps it
  # as `{:error, {:transient_check_failed, reason}}`, and do_refresh_with/2
  # must fail this ONE request closed (still 401) WITHOUT calling
  # Store.delete_for_user_device/2 — a later retry must still be able to
  # succeed once the transient issue clears, instead of the session being
  # permanently killed over an unrelated infra blip.
  #
  # Simulated via the SAME :session_manager, :validator_module seam used by
  # token_validator_test.exs and oidc_plug_test.exs to stub
  # TokenValidator.validate/4 — the IdP round-trip itself (the
  # :matrix_oidc_refresh_override seam) succeeds; the transient failure is
  # injected at the LOCAL is_active re-check, one step later.
  # ══════════════════════════════════════════════════════════════════════════

  describe "POST /_matrix/client/v3/refresh: transient is_active re-check failure (code-review cycle-1 m1)" do
    defmodule TransientlyFailingValidator do
      @behaviour Nebu.Matrix.Session.TokenValidator

      @impl Nebu.Matrix.Session.TokenValidator
      def validate(_user_id, _system_role, _display_name, _email) do
        {:error, :db_timeout}
      end
    end

    test "fails the request closed (401) WITHOUT hard-deleting the opaque session row",
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

      # Sanity check: the session row exists and its AT works before the
      # transient failure is injected.
      assert {:ok, _} = Nebu.Matrix.Session.MatrixSessionStore.get_by_refresh_token(rt)
      assert call(:get, "/_matrix/client/v3/sync", nil, auth(at)).status == 200

      # The IdP round-trip itself succeeds (fresh claims come back fine) — the
      # failure is injected one step later, at the LOCAL is_active re-check.
      put_matrix_oidc_refresh_override(fn _decrypted_rt ->
        {:ok, %{"sub" => current_sub(), "exp" => future_exp(), "preferred_username" => "Alice"}, nil}
      end)

      Application.put_env(:session_manager, :validator_module, TransientlyFailingValidator)
      on_exit(fn -> Application.delete_env(:session_manager, :validator_module) end)

      refresh = call(:post, "/_matrix/client/v3/refresh", %{"refresh_token" => rt})

      assert refresh.status == 401
      assert json(refresh)["errcode"] == "M_UNKNOWN_TOKEN"

      # m1: unlike a CONFIRMED rejection/deprovisioning, a transient check
      # failure must NOT hard-delete the opaque session row — Store.delete_for_user_device/2
      # must not have fired. Verified by reading the row back via the ORIGINAL
      # refresh token: if the delete path had (wrongly) fired, this lookup
      # would return :error just like it does in the m2/deprovisioning tests.
      assert {:ok, sess} = Nebu.Matrix.Session.MatrixSessionStore.get_by_refresh_token(rt)
      assert sess.user_id == uid

      # The original opaque AT is therefore still live too — the session was
      # merely refused THIS refresh, not killed.
      assert call(:get, "/_matrix/client/v3/sync", nil, auth(at)).status == 200,
             "m1: a transient is_active re-check failure must preserve the existing session " <>
               "so a later refresh can succeed once the transient issue clears"
    end
  end
end
