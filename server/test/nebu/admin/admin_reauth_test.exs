defmodule Nebu.Admin.AdminReauthTest do
  @moduledoc """
  Acceptance tests for story `oauth-client-revocation` (P4), AC8.2 - AC8.4 (decisions SO4, SO5): the fresh admin
  re-authentication that gates approving and revoking an OAuth client. The gate itself (POST without / with an old /
  foreign marker => 303 to the re-auth start) is asserted in `test/nebu/oauth/oauth_admin_clients_test.exs`.

  Driven the way `admin_oidc_login_test.exs` / `admin_token_refresh_test.exs` drive the admin OIDC legs:
  `Nebu.Admin.Auth.login_start/2` and `callback/2` on a test-session conn, the token leg short-circuited by
  `:admin_oidc_token_override` (every surrounding check of the callback still runs).

  ## Pinned contract

    * `Auth.login_start(conn, %{"mode" => "reauth", "return_to" => path})` with an EXISTING ADMIN session
      (`current_user.admin == true`): the authorization request carries `prompt=login` AND `max_age=0`; the signed
      login state (`admin_oidc_login`) holds `"mode" => "reauth"`, `"return_to"` (allowlist
      `\\A/admin/oauth/(registrations|clients)(/[A-Za-z0-9_-]{1,128}/(approve|revoke))?\\z`, anything else becomes
      `/admin/oauth/registrations`) and `"started_at"` (unix seconds). Without an admin session the request is a NORMAL
      login (no `max_age`, mode not `reauth`, no `return_to` stored). A normal login (no mode) never sends `max_age`.
    * The callback in mode `reauth` runs the normal admin path (state, nonce, admin claim, `put_current_user`) and then:
      `auth_time` an integer with `started_at - 30 <= auth_time <= now + 30` => FRESH, marker
      `"admin_reauth" => %{"sub" => claims["sub"], "at" => now, "kind" => "auth_time", "path" => return_to}` in the session (outside
      `current_user`, put AFTER the session renewal), `303` to `return_to`; an `auth_time` outside that window (the IdP
      skipped the login) or of another type => NOT fresh; an ABSENT `auth_time` => NOT fresh unless the app env
      `:nebu_http, :admin_reauth_allow_missing_auth_time` is exactly `true` (then kind `"flow"` + a value-free
      WARNING; the opt-out never rescues a present but stale / invalid `auth_time`). NOT fresh => no marker, an error
      flash (or `error=` in the Location), a redirect inside `/admin/`. A non-admin token => 403 as today.
    * A normal login and the silent pre-expiry refresh never create a marker (and never touch an existing one).
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn
  import ExUnit.CaptureLog

  alias Nebu.Admin.Auth

  @issuer "https://dex.example.com/dex"
  @audience "nebu-admin"
  @client_id "nebu-admin"
  @authorization_endpoint "https://dex.example.com/dex/auth"
  @token_endpoint "https://dex.example.com/dex/token"
  @default_return "/admin/oauth/registrations"
  @return_to "/admin/oauth/clients/abc123/revoke"

  setup do
    jwk = JOSE.JWK.generate_key({:rsa, 2048})

    pub =
      jwk |> JOSE.JWK.to_public() |> JOSE.JWK.to_map() |> elem(1) |> Map.merge(%{"kid" => "admin-key-1", "alg" => "RS256", "use" => "sig"})

    Nebu.Web.OidcTestSupport.configure(@issuer, @audience)
    Application.put_env(:nebu_http, :oidc_jwks, [pub])
    Application.put_env(:nebu_http, :admin_secret_at_rest, "admin-reauth-test-key")

    Application.put_env(:nebu_http, :admin_oidc_config_reader, fn
      "oidc_client_id" -> @client_id
      "oidc_client_secret" -> Nebu.Admin.BootstrapLive.encrypt_secret("client-secret")
      _ -> nil
    end)

    Application.put_env(:nebu_http, :server_name, "localhost")
    Application.put_env(:nebu_http, :admin_session_secure, false)

    Application.put_env(:nebu_http, :oidc_metadata_override, %{
      "issuer" => @issuer,
      "authorization_endpoint" => @authorization_endpoint,
      "token_endpoint" => @token_endpoint
    })

    on_exit(fn ->
      Nebu.Web.OidcTestSupport.clear()

      for k <- [
            :oidc_jwks,
            :admin_secret_at_rest,
            :admin_oidc_config_reader,
            :server_name,
            :admin_session_secure,
            :oidc_metadata_override,
            :admin_oidc_token_override,
            :admin_oidc_refresh_override,
            :admin_reauth_allow_missing_auth_time
          ] do
        Application.delete_env(:nebu_http, k)
      end
    end)

    :ok
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp now, do: System.system_time(:second)

  defp admin_user(extra \\ %{}),
    do: Map.merge(%{"admin" => true, "sub" => "admin-1", "email" => "admin@example.com", "matrix_user_id" => "@admin-1:localhost", "session_exp" => now() + 3600}, extra)

  defp session_conn(path, session) do
    conn(:get, path) |> init_test_session(session) |> Phoenix.Controller.fetch_flash([])
  end

  defp start(params, session), do: session_conn("/admin/login/start", session) |> Auth.login_start(params)
  defp authorize_params(conn), do: conn |> get_resp_header("location") |> hd() |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

  defp login_state(extra \\ %{}) do
    Map.merge(
      %{"state" => "s", "verifier" => "v", "nonce" => "n", "mode" => "reauth", "return_to" => @return_to, "started_at" => now() - 5, "exp" => now() + 600},
      extra
    )
  end

  defp claims(extra \\ %{}),
    do: Map.merge(%{"sub" => "admin-1", "email" => "admin@example.com", "nonce" => "n", "exp" => now() + 3600, "groups" => ["instance_admin"]}, extra)

  # runs the callback with the token leg stubbed to `claims`; the existing session is an admin one
  defp callback(claims, state \\ login_state()) do
    Application.put_env(:nebu_http, :admin_oidc_token_override, fn -> {:ok, claims} end)

    session_conn("/admin/callback", %{"current_user" => admin_user(), "admin_oidc_login" => state})
    |> Auth.callback(%{"code" => "auth-code", "state" => "s"})
  end

  defp marker(conn), do: get_session(conn, "admin_reauth")
  defp location(conn), do: conn |> get_resp_header("location") |> List.first()

  defp error_signalled?(conn) do
    flash = conn.assigns[:flash] || %{}
    is_binary(flash["error"]) or (location(conn) || "") =~ "error="
  end

  defp refute_fresh(conn, label) do
    assert marker(conn) == nil, "#{label}: no marker"
    assert conn.status in [302, 303], "#{label}: a redirect, got #{conn.status}"
    assert String.starts_with?(location(conn) || "", "/admin/"), "#{label}: stays inside /admin/ (got #{inspect(location(conn))})"
    assert error_signalled?(conn), "#{label}: the admin is told why (error flash)"
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC8.2 — login start in mode reauth
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC8.2 — GET /admin/login/start?mode=reauth" do
    test "an existing admin session: prompt=login AND max_age=0; mode, return_to and started_at are bound into the signed login state" do
      before = now()
      conn = start(%{"mode" => "reauth", "return_to" => @return_to}, %{"current_user" => admin_user()})

      assert conn.status == 302
      assert String.starts_with?(location(conn), @authorization_endpoint <> "?")
      params = authorize_params(conn)
      assert params["prompt"] == "login"
      assert params["max_age"] == "0"
      assert params["response_type"] == "code" and params["code_challenge_method"] == "S256"
      assert "openid" in String.split(params["scope"], " ")

      state = get_session(conn, "admin_oidc_login")
      assert state["mode"] == "reauth"
      assert state["return_to"] == @return_to
      assert is_integer(state["started_at"]) and state["started_at"] >= before and state["started_at"] <= now()
      assert state["state"] == params["state"] and state["nonce"] == params["nonce"]
      assert is_binary(state["verifier"]) and is_integer(state["exp"])
    end

    allowed = [
      "/admin/oauth/registrations",
      "/admin/oauth/clients",
      "/admin/oauth/clients/revoked",
      "/admin/oauth/clients/abc-123_X/revoke",
      "/admin/oauth/registrations/abc-123_X/approve",
      "/admin/config",
      "/admin/config/claim-mapping",
      "/admin/config/role-mapping"
    ]

    for path <- allowed do
      test "return_to #{String.slice(path, 0, 60)} is kept" do
        conn = start(%{"mode" => "reauth", "return_to" => unquote(path)}, %{"current_user" => admin_user()})
        assert get_session(conn, "admin_oidc_login")["return_to"] == unquote(path)
      end
    end

    rejected = [
      "https://evil.example.com/admin/oauth/registrations",
      "//evil.example.com",
      "/admin/users",
      "/admin/config/",
      "/admin/config/sso-origins",
      "/admin/config?x=1",
      "/admin/config/../users",
      "/admin/oauth/registrations/../../users",
      "/admin/oauth/registrations/%2e%2e/x/approve",
      "/admin/oauth/clients/a%2Fb/revoke",
      "/admin/oauth/clients/x/revoke?next=//evil.example.com",
      "/admin/oauth/clients/x/revoke#frag",
      "/admin/oauth/registrations\n",
      "/admin/oauth/registrations/x/reject",
      "/admin/oauth/clients/x/delete",
      "/admin/oauth/clients/" <> String.duplicate("a", 129) <> "/revoke",
      "/ADMIN/oauth/registrations",
      "/admin/oauth/clients/x/revoke/",
      "javascript:alert(1)",
      "/admin/oauth/clients/x y/revoke",
      "",
      "/admin/oauth/registrations/x\r\nSet-Cookie: a=b/approve"
    ]

    for path <- rejected do
      test "return_to #{String.slice(inspect(path), 0, 60)} becomes the default" do
        conn = start(%{"mode" => "reauth", "return_to" => unquote(path)}, %{"current_user" => admin_user()})
        assert get_session(conn, "admin_oidc_login")["return_to"] == @default_return
      end
    end

    test "a missing return_to, a non-binary one and several values all fall back to the default" do
      for params <- [%{"mode" => "reauth"}, %{"mode" => "reauth", "return_to" => ["/admin/oauth/clients"]}, %{"mode" => "reauth", "return_to" => %{"a" => "b"}}] do
        conn = start(params, %{"current_user" => admin_user()})
        assert get_session(conn, "admin_oidc_login")["return_to"] == @default_return, inspect(params)
      end
    end

    test "WITHOUT an admin session (none / a non-admin one) it is a NORMAL login: no max_age, no return_to, mode is not reauth" do
      for session <- [%{}, %{"current_user" => admin_user(%{"admin" => false})}] do
        conn = start(%{"mode" => "reauth", "return_to" => @return_to}, session)
        assert conn.status == 302
        params = authorize_params(conn)
        assert params["prompt"] == "login"
        refute Map.has_key?(params, "max_age")
        state = get_session(conn, "admin_oidc_login")
        assert state["mode"] != "reauth"
        refute Map.has_key?(state, "return_to")
      end
    end

    test "a normal login never sends max_age and stores no return_to" do
      conn = start(%{}, %{"current_user" => admin_user()})
      refute Map.has_key?(authorize_params(conn), "max_age")
      assert authorize_params(conn)["prompt"] == "login"
      refute Map.has_key?(get_session(conn, "admin_oidc_login"), "return_to")
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC8.3 — the callback in mode reauth
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC8.3 — callback (mode reauth), fresh auth_time" do
    test "auth_time after started_at => marker kind auth_time, 303 to return_to, the admin session is the freshly verified one" do
      state = login_state()
      conn = callback(claims(%{"auth_time" => state["started_at"] + 2}), state)

      assert conn.status in [302, 303], "the redirect to return_to (Phoenix redirect/2 answers 302; 303 also accepted)"
      assert location(conn) == @return_to
      m = marker(conn)
      assert m["sub"] == "admin-1" and m["kind"] == "auth_time"
      assert is_integer(m["at"]) and abs(m["at"] - now()) <= 3
      assert Map.keys(m) |> Enum.sort() == ["at", "kind", "path", "sub"]
      assert m["path"] == @return_to, "the marker is bound to the confirm page the flow was started for (Kassandra M-1)"
      assert get_session(conn, "current_user")["admin"] == true
      refute Map.has_key?(get_session(conn, "current_user"), "admin_reauth"), "the marker lives OUTSIDE current_user (the silent refresh rebuilds that)"
      assert get_session(conn, "admin_oidc_login") == nil, "the login state is consumed"
    end

    for page <- ["/admin/config/claim-mapping", "/admin/config/role-mapping"] do
      test "return_to #{page} (story admin-config-privileged-forms-sweep): the marker is bound to that page, the admin is told that the change was not saved yet" do
        state = login_state(%{"return_to" => unquote(page)})
        conn = callback(claims(%{"auth_time" => state["started_at"] + 2}), state)

        assert conn.status in [302, 303]
        assert location(conn) == unquote(page)
        assert marker(conn)["path"] == unquote(page)
        info = (conn.assigns[:flash] || %{})["info"] || ""
        assert info =~ "Your change was not saved yet"
        assert info =~ "5 minutes"
      end
    end

    test "return_to /admin/config: the admin is told that the change was not saved yet (info flash); other return targets get no flash" do
      state = login_state(%{"return_to" => "/admin/config"})
      conn = callback(claims(%{"auth_time" => state["started_at"] + 2}), state)

      assert location(conn) == "/admin/config"
      assert marker(conn)["path"] == "/admin/config"
      info = (conn.assigns[:flash] || %{})["info"] || get_in(conn.private, [:phoenix_flash, "info"])
      assert is_binary(info)
      assert info =~ "Signed in again"
      assert info =~ ~r/not saved yet/i
      assert info =~ ~r/enter it again/i
      assert info =~ "5 minutes", "the text names the marker lifetime (300 s)"

      other = callback(claims(%{"auth_time" => login_state()["started_at"] + 2}))
      assert location(other) == @return_to
      refute is_binary((other.assigns[:flash] || %{})["info"] || get_in(other.private, [:phoenix_flash, "info"]))
    end

    test "the clock-skew window: started_at - 30 s is fresh, started_at - 31 s is not; now + 20 s is fresh, now + 60 s is not" do
      state = login_state()

      assert marker(callback(claims(%{"auth_time" => state["started_at"] - 30}), state))["kind"] == "auth_time"
      refute_fresh(callback(claims(%{"auth_time" => state["started_at"] - 31}), state), "31 s before the start")
      assert marker(callback(claims(%{"auth_time" => now() + 20}), state))["kind"] == "auth_time"
      refute_fresh(callback(claims(%{"auth_time" => now() + 60}), state), "from the future")
    end

    test "the marker sub is the sub of the NEW token (a different admin completing the flow gets their own marker)" do
      state = login_state()
      conn = callback(claims(%{"sub" => "admin-2", "auth_time" => state["started_at"] + 1}), state)
      assert marker(conn)["sub"] == "admin-2"
      assert get_session(conn, "current_user")["sub"] == "admin-2"
    end
  end

  describe "AC8.3 / SO5 — an IdP that skipped the login or reports no auth_time (fail closed)" do
    test "an older auth_time (the IdP reused its SSO session) => NOT fresh: no marker, an error flash" do
      state = login_state()
      refute_fresh(callback(claims(%{"auth_time" => state["started_at"] - 3600}), state), "stale auth_time")
    end

    test "no auth_time claim => NOT fresh by default" do
      refute_fresh(callback(claims()), "absent auth_time")
    end

    test "an invalid auth_time (string, negative, float, list, null) => NOT fresh" do
      for bad <- ["yesterday", "1700000000", -5, 1.7e9, [1], nil] do
        refute_fresh(callback(claims(%{"auth_time" => bad})), "auth_time #{inspect(bad)}")
      end
    end

    test "with :admin_reauth_allow_missing_auth_time == true a MISSING auth_time gives kind flow + a value-free WARNING" do
      Application.put_env(:nebu_http, :admin_reauth_allow_missing_auth_time, true)

      {conn, log} = with_log(fn -> callback(claims(%{"email" => "leaky-mail@example.com"})) end)
      assert conn.status in [302, 303] and location(conn) == @return_to
      assert marker(conn)["kind"] == "flow" and marker(conn)["sub"] == "admin-1"
      assert log =~ ~r/auth_time/i, "the accepted risk is logged"
      refute log =~ "leaky-mail@example.com"
      refute log =~ "auth-code"
    end

    test "the opt-out only counts for the exact value true and never rescues a present but stale auth_time" do
      for not_true <- ["true", 1, "1", :yes, nil, false] do
        Application.put_env(:nebu_http, :admin_reauth_allow_missing_auth_time, not_true)
        refute_fresh(callback(claims()), "opt-out #{inspect(not_true)}")
      end

      Application.put_env(:nebu_http, :admin_reauth_allow_missing_auth_time, true)
      state = login_state()
      refute_fresh(callback(claims(%{"auth_time" => state["started_at"] - 3600}), state), "stale auth_time with the opt-out")
      refute_fresh(callback(claims(%{"auth_time" => "yesterday"}), state), "invalid auth_time with the opt-out")
    end

    test "a real auth_time wins over the opt-out: kind stays auth_time" do
      Application.put_env(:nebu_http, :admin_reauth_allow_missing_auth_time, true)
      state = login_state()
      assert marker(callback(claims(%{"auth_time" => state["started_at"] + 1}), state))["kind"] == "auth_time"
    end
  end

  describe "AC8.3 — the normal callback checks still run" do
    test "a token without the admin group claim => 403 as today, no marker" do
      state = login_state()
      conn = callback(claims(%{"groups" => ["users"], "auth_time" => state["started_at"] + 1}), state)
      assert conn.status == 403
      assert marker(conn) == nil
    end

    test "a wrong nonce or state is refused (bounce / 400), no marker" do
      state = login_state()
      conn = callback(claims(%{"nonce" => "other", "auth_time" => state["started_at"] + 1}), state)
      assert marker(conn) == nil
      assert conn.status in [302, 303]
      assert location(conn) =~ "/admin/login"

      Application.put_env(:nebu_http, :admin_oidc_token_override, fn -> {:ok, claims(%{"auth_time" => now()})} end)
      bad = session_conn("/admin/callback", %{"current_user" => admin_user(), "admin_oidc_login" => state}) |> Auth.callback(%{"code" => "c", "state" => "forged"})
      assert bad.status == 400 and marker(bad) == nil
    end

    test "an expired login state is refused" do
      state = login_state(%{"exp" => now() - 1})
      assert callback(claims(%{"auth_time" => now()}), state) |> Map.fetch!(:status) == 400
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC8.4 — nothing else creates a marker
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC8.4 — a normal login and the silent refresh never create (or touch) a marker" do
    test "a normal login callback with a perfectly fresh auth_time creates no marker and lands on the dashboard" do
      state = login_state(%{"mode" => nil}) |> Map.drop(["return_to"])
      conn = callback(claims(%{"auth_time" => now()}), state)
      assert conn.status == 302 and location(conn) == "/admin/dashboard"
      assert marker(conn) == nil
    end

    test "the silent pre-expiry refresh keeps a session without a marker markerless and leaves an existing marker untouched" do
      Application.put_env(:nebu_http, :admin_oidc_refresh_override, fn _rt -> {:ok, claims(%{"auth_time" => now()}), nil} end)
      near_expiry = admin_user(%{"session_exp" => now() + 30})
      rt = Nebu.Web.SecretBox.encrypt("refresh-token")

      without = conn(:get, "/admin/dashboard") |> init_test_session(%{"current_user" => near_expiry, "admin_oidc_rt" => rt}) |> Auth.fetch_current_user([])
      assert get_session(without, "current_user")["session_exp"] > near_expiry["session_exp"], "the refresh really ran"
      assert marker(without) == nil

      m = %{"sub" => "admin-1", "at" => now() - 100, "kind" => "auth_time"}
      with = conn(:get, "/admin/dashboard") |> init_test_session(%{"current_user" => near_expiry, "admin_oidc_rt" => rt, "admin_reauth" => m}) |> Auth.fetch_current_user([])
      assert marker(with) == m, "the refresh neither renews nor re-stamps the marker"
    end

    test "logout drops the whole session, the marker with it" do
      conn = session_conn("/admin/logout", %{"current_user" => admin_user(), "admin_reauth" => %{"sub" => "admin-1", "at" => now(), "kind" => "auth_time"}}) |> Auth.logout(%{})
      assert conn.private.plug_session_info == :drop
    end
  end

  describe "SO5 — configuration" do
    test "config/runtime.exs reads NEBU_ADMIN_REAUTH_ALLOW_MISSING_AUTH_TIME (exact true only) into :nebu_http, :admin_reauth_allow_missing_auth_time" do
      runtime = File.read!(Path.expand("../../../config/runtime.exs", __DIR__))
      assert runtime =~ "NEBU_ADMIN_REAUTH_ALLOW_MISSING_AUTH_TIME"
      assert runtime =~ ":admin_reauth_allow_missing_auth_time"
      assert runtime =~ ~r/NEBU_ADMIN_REAUTH_ALLOW_MISSING_AUTH_TIME[^\n]*"true"/, "only the exact string true switches it on"
      refute runtime =~ ~r/NEBU_ADMIN_REAUTH_ALLOW_MISSING_AUTH_TIME[^\n]*(downcase|\bin\b|"1")/, "no lenient parsing"
    end

    test "the default is off: nothing sets the env in config/config.exs or test.exs" do
      for f <- ~w(config.exs test.exs dev.exs prod.exs) do
        path = Path.expand("../../../config/#{f}", __DIR__)
        if File.exists?(path), do: refute(File.read!(path) =~ "admin_reauth_allow_missing_auth_time", "#{f} must not enable the opt-out")
      end
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # story role-mapping-self-lockout-guard (follow-up dg), AC1 / D1 / D3 — the fingerprint of the fresh sign-in claims in the marker
  # ════════════════════════════════════════════════════════════════════════════

  describe "role-mapping-self-lockout-guard AC1 — marker fingerprint" do
    @role_page "/admin/config/role-mapping"

    defp role_state, do: login_state(%{"return_to" => @role_page})

    defp chunks6(<<>>), do: []
    defp chunks6(<<h::binary-size(6), rest::binary>>), do: [h | chunks6(rest)]

    test "return_to the role mapping page: claims_fp + claims_fp_complete, the other marker keys unchanged" do
      state = role_state()
      conn = callback(claims(%{"auth_time" => state["started_at"] + 2, "groups" => ["instance_admin", "ops-admins"]}), state)

      m = marker(conn)
      assert m["path"] == @role_page and m["kind"] == "auth_time" and m["sub"] == "admin-1"
      assert Map.keys(m) |> Enum.sort() == ["at", "claims_fp", "claims_fp_complete", "claims_fp_path", "kind", "path", "sub"]
      assert m["claims_fp_complete"] == true
      hashes = chunks6(m["claims_fp"])
      for v <- ["instance_admin", "ops-admins"], do: assert(Auth.role_claim_hash(v) in hashes, v)
      refute Auth.role_claim_hash("not-in-the-token") in hashes
      refute m |> :erlang.term_to_binary() |> String.contains?("ops-admins"), "no claim value in the signed (not encrypted) cookie"
    end

    test "with a configured claim path only the values at that path are in it" do
      Application.put_env(:nebu_http, :admin_oidc_config_reader, fn
        "admin_group_claim_path" -> "realm_access.roles"
        "oidc_client_id" -> @client_id
        "oidc_client_secret" -> Nebu.Admin.BootstrapLive.encrypt_secret("client-secret")
        _ -> nil
      end)

      state = role_state()
      claims = claims(%{"auth_time" => state["started_at"] + 2, "realm_access" => %{"roles" => ["instance_admin"]}, "name" => "Ada Lovelace", "groups" => ["decoy"]})
      m = marker(callback(claims, state))
      hashes = chunks6(m["claims_fp"])
      assert Auth.role_claim_hash("instance_admin") in hashes
      refute Auth.role_claim_hash("Ada Lovelace") in hashes
      refute Auth.role_claim_hash("decoy") in hashes
    end

    test "more than 32 values: the marker keeps 32 and says it is not complete" do
      Application.put_env(:nebu_http, :admin_oidc_config_reader, fn
        "admin_group_claim_path" -> "groups"
        "oidc_client_id" -> @client_id
        "oidc_client_secret" -> Nebu.Admin.BootstrapLive.encrypt_secret("client-secret")
        _ -> nil
      end)

      state = role_state()
      m = marker(callback(claims(%{"auth_time" => state["started_at"] + 2, "groups" => ["instance_admin" | Enum.map(1..40, &"g#{&1}")]}), state))
      assert byte_size(m["claims_fp"]) == 32 * 6
      assert m["claims_fp_complete"] == false
    end

    test "every other return page gets the plain marker (no fingerprint)" do
      for page <- ["/admin/config", "/admin/config/claim-mapping", @return_to] do
        state = login_state(%{"return_to" => page})
        m = marker(callback(claims(%{"auth_time" => state["started_at"] + 2}), state))
        assert Map.keys(m) |> Enum.sort() == ["at", "kind", "path", "sub"], page
      end
    end

    test "the fingerprint comes from the claims of the fresh token, not from the claims-free session that started the flow" do
      state = role_state()
      Application.put_env(:nebu_http, :admin_oidc_token_override, fn -> {:ok, claims(%{"auth_time" => state["started_at"] + 2, "groups" => ["instance_admin", "newly-joined"]})} end)

      conn =
        session_conn("/admin/callback", %{"current_user" => admin_user(), "admin_oidc_login" => state})
        |> Auth.callback(%{"code" => "auth-code", "state" => "s"})

      assert Auth.role_claim_hash("newly-joined") in chunks6(marker(conn)["claims_fp"])
    end

    test "kind flow (the dev IdP without auth_time, opt-out on): the marker carries the fingerprint too" do
      Application.put_env(:nebu_http, :admin_reauth_allow_missing_auth_time, true)
      m = marker(callback(claims(%{"groups" => ["instance_admin", "ops-admins"]}), role_state()))
      assert m["kind"] == "flow"
      assert Auth.role_claim_hash("ops-admins") in chunks6(m["claims_fp"])
      assert m["claims_fp_complete"] == true
    end

    test "a stale re-authentication (no marker) carries no fingerprint either" do
      state = role_state()
      conn = callback(claims(%{"auth_time" => state["started_at"] - 3600}), state)
      assert marker(conn) == nil
    end
  end

  describe "story admin-forms-gate-sweep D2 — the marker of the media settings page" do
    test "return_to /admin/media/settings: the marker is bound to that page, the notice tells the admin to enter the change again including the secret key" do
      state = login_state(%{"return_to" => "/admin/media/settings"})
      conn = callback(claims(%{"auth_time" => state["started_at"] + 2}), state)

      assert conn.status in [302, 303]
      assert location(conn) == "/admin/media/settings"
      m = marker(conn)
      assert m["path"] == "/admin/media/settings"
      assert Map.keys(m) |> Enum.sort() == ["at", "kind", "path", "sub"], "no role mapping fingerprint on this page"
      info = (conn.assigns[:flash] || %{})["info"] || get_in(conn.private, [:phoenix_flash, "info"]) || ""
      assert info =~ "Your change was not saved yet"
      assert info =~ ~r/secret key/i
      assert info =~ "5 minutes"
    end

    test "login start keeps the media settings page as return_to" do
      conn = start(%{"mode" => "reauth", "return_to" => "/admin/media/settings"}, %{"current_user" => admin_user()})
      assert get_session(conn, "admin_oidc_login")["return_to"] == "/admin/media/settings"
    end
  end
end
