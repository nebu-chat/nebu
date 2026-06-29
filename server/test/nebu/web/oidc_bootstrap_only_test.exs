defmodule Nebu.Web.OidcBootstrapOnlyTest do
  @moduledoc """
  ATDD acceptance tests for story `oidc-bootstrap-only-config` (ADR-022):
  OIDC is configured EXCLUSIVELY through the Bootstrap Wizard (server_config),
  read via the DB-backed `Nebu.Web.OidcConfig` cache. The environment-variable
  OIDC config path is REMOVED — `OidcPlug`, `JwksCache`, `SsoLogin`, and
  `Admin.Auth` resolve issuer/audience/client solely from `server_config`
  (or the bootstrap draft during the wizard flow). A single OIDC client serves
  both Matrix Bearer validation and admin operator login.

  These tests are written FIRST (red phase). The critical security-regression
  tests (#3, #4) assert that a STALE/BOGUS Application env value is IGNORED in
  favour of the DB (`:oidc_config_source` / `:sso_bootstrap_reader` /
  `:admin_oidc_config_reader` seams). They FAIL while the env-first branch still
  exists and pass only after it is removed.

  ## Seams (ADR-018)

  - `:nebu_http, :oidc_jwks` — inject public JWK for OidcPlug (no network).
  - `:nebu_http, :oidc_config_source` — 0-arity fun returning
    `%{issuer: _, audience: _}` — the DB-backed OidcConfig seam.
  - `:nebu_http, :sso_bootstrap_reader` — 1-arity fun `fn(key) -> value | nil`
    for the SsoLogin server_config lookups.
  - `:nebu_http, :admin_oidc_config_reader` — 1-arity fun for Admin.Auth.
  """

  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  @server_name "test.local"
  @db_issuer "https://idp.example.com"
  @db_audience "nebu"
  @kid "bootstrap-only-key-1"

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp build_rsa_keypair do
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

    {Map.put(priv_map, "kid", @kid), pub_jwk}
  end

  defp sign_jwt(claims, priv_jwk) do
    jws = %{"alg" => "RS256", "kid" => @kid}
    signed = JOSE.JWT.sign(JOSE.JWK.from_map(priv_jwk), jws, claims)
    {_, compact} = JOSE.JWS.compact(signed)
    compact
  end

  defp future_exp, do: System.system_time(:second) + 3_600

  defp valid_claims do
    %{"iss" => @db_issuer, "aud" => @db_audience, "sub" => "alice", "exp" => future_exp()}
  end

  defp conn_with_bearer(token) do
    :get
    |> conn("/sync")
    |> put_req_header("authorization", "Bearer #{token}")
  end

  # Make sure NO OIDC config comes from Application env — only from the seam.
  defp clean_oidc_env do
    for k <- [
          :oidc_issuer,
          :oidc_audience,
          :oidc_jwks_uri,
          :oidc_jwks,
          :oidc_config_source,
          :sso_bootstrap_reader,
          :admin_oidc_config_reader,
          :matrix_oidc_client_id,
          :matrix_oidc_client_secret,
          :admin_oidc_client_id,
          :admin_oidc_client_secret,
          :admin_oidc_redirect_uri,
          :admin_oidc_scope,
          :oidc_extra_scopes,
          :server_name
        ] do
      Application.delete_env(:nebu_http, k)
    end
  end

  setup do
    clean_oidc_env()
    on_exit(&clean_oidc_env/0)
    :ok
  end

  # ════════════════════════════════════════════════════════════════════════════
  # Test 1 — OidcPlug fail-closed with empty server_config (no env)
  # ════════════════════════════════════════════════════════════════════════════

  describe "Test 1 — OidcPlug fail-closed when server_config is empty" do
    test "rejects every Bearer token with 401 when issuer/audience are nil" do
      {priv_jwk, pub_jwk} = build_rsa_keypair()
      Application.put_env(:nebu_http, :oidc_jwks, [pub_jwk])
      Application.put_env(:nebu_http, :server_name, @server_name)

      # DB seam returns nothing configured.
      Application.put_env(:nebu_http, :oidc_config_source, fn ->
        %{issuer: nil, audience: nil}
      end)

      token = sign_jwt(valid_claims(), priv_jwk)
      conn = conn_with_bearer(token) |> Nebu.Web.Plugs.OidcPlug.call([])

      assert conn.halted
      assert conn.status == 401
      assert Jason.decode!(conn.resp_body)["errcode"] == "M_UNKNOWN_TOKEN"
    end

    test "rejects with 401 when NO oidc_config_source seam is configured at all (Kassandra LOW-1)" do
      {priv_jwk, pub_jwk} = build_rsa_keypair()
      Application.put_env(:nebu_http, :oidc_jwks, [pub_jwk])
      Application.put_env(:nebu_http, :server_name, @server_name)

      # No seam at all → OidcConfig.get/0 falls through to ETS (empty in unit tests)
      # → nil issuer/audience → fail closed. Guards against a fail-open on the no-seam path.
      Application.delete_env(:nebu_http, :oidc_config_source)

      token = sign_jwt(valid_claims(), priv_jwk)
      conn = conn_with_bearer(token) |> Nebu.Web.Plugs.OidcPlug.call([])

      assert conn.halted
      assert conn.status == 401
      assert Jason.decode!(conn.resp_body)["errcode"] == "M_UNKNOWN_TOKEN"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # Test 2 — OidcPlug accepts when server_config provides issuer/audience
  # ════════════════════════════════════════════════════════════════════════════

  describe "Test 2 — OidcPlug accepts a token resolved from server_config only" do
    test "assigns current_user when iss/aud come from the DB seam (no env)" do
      {priv_jwk, pub_jwk} = build_rsa_keypair()
      Application.put_env(:nebu_http, :oidc_jwks, [pub_jwk])
      Application.put_env(:nebu_http, :server_name, @server_name)

      Application.put_env(:nebu_http, :oidc_config_source, fn ->
        %{issuer: @db_issuer, audience: @db_audience}
      end)

      token = sign_jwt(valid_claims(), priv_jwk)
      conn = conn_with_bearer(token) |> Nebu.Web.Plugs.OidcPlug.call([])

      refute conn.halted
      assert conn.assigns[:current_user] != nil
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # Test 3 — OidcPlug IGNORES Application env (regression for env removal)
  # ════════════════════════════════════════════════════════════════════════════

  describe "Test 3 — OidcPlug ignores Application env (env removed)" do
    test "a bogus :oidc_issuer env is ignored; the DB issuer is authoritative" do
      {priv_jwk, pub_jwk} = build_rsa_keypair()
      Application.put_env(:nebu_http, :oidc_jwks, [pub_jwk])
      Application.put_env(:nebu_http, :server_name, @server_name)

      # Bogus env values — MUST be ignored after the env branch is removed.
      Application.put_env(:nebu_http, :oidc_issuer, "https://attacker.evil/bogus")
      Application.put_env(:nebu_http, :oidc_audience, "wrong-audience")

      # The real config comes from the DB seam.
      Application.put_env(:nebu_http, :oidc_config_source, fn ->
        %{issuer: @db_issuer, audience: @db_audience}
      end)

      # Token matches the DB issuer/audience (NOT the bogus env values).
      token = sign_jwt(valid_claims(), priv_jwk)
      conn = conn_with_bearer(token) |> Nebu.Web.Plugs.OidcPlug.call([])

      # RED before removal: the env-first branch would use the bogus issuer and
      # reject the DB-issued token with :bad_issuer. GREEN after removal.
      refute conn.halted,
             "OidcPlug must ignore the stale env issuer and accept the DB-issued token"

      assert conn.assigns[:current_user] != nil
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # Test 5 — Admin.Auth.oidc_config resolves from server_config only
  # ════════════════════════════════════════════════════════════════════════════

  describe "Test 5 — Admin.Auth resolves OIDC config from server_config only" do
    setup do
      Application.put_env(:nebu_http, :admin_secret_at_rest, "bootstrap-only-admin-key")
      on_exit(fn -> Application.delete_env(:nebu_http, :admin_secret_at_rest) end)
      :ok
    end

    test "normal mode returns the single client from the DB reader (no admin env)" do
      Application.put_env(:nebu_http, :server_name, @server_name)

      # DB issuer via OidcConfig seam.
      Application.put_env(:nebu_http, :oidc_config_source, fn ->
        %{issuer: @db_issuer, audience: @db_audience}
      end)

      encrypted = Nebu.Admin.BootstrapLive.encrypt_secret("the-secret")

      Application.put_env(:nebu_http, :admin_oidc_config_reader, fn
        "oidc_client_id" -> "single-client"
        "oidc_client_secret" -> encrypted
        _ -> nil
      end)

      # No admin-client env set at all — the single DB client must be used.
      assert {:ok, cfg} = Nebu.Admin.Auth.oidc_config_for_test("normal")
      assert cfg.issuer == @db_issuer
      assert cfg.client_id == "single-client"
      assert cfg.client_secret == "the-secret"
    end

    test "ignores a stale admin-client env value (env removed regression)" do
      Application.put_env(:nebu_http, :server_name, @server_name)

      Application.put_env(:nebu_http, :oidc_config_source, fn ->
        %{issuer: @db_issuer, audience: @db_audience}
      end)

      encrypted = Nebu.Admin.BootstrapLive.encrypt_secret("db-secret")

      Application.put_env(:nebu_http, :admin_oidc_config_reader, fn
        "oidc_client_id" -> "db-client"
        "oidc_client_secret" -> encrypted
        _ -> nil
      end)

      # Stale env client must be ignored.
      Application.put_env(:nebu_http, :admin_oidc_client_id, "stale-env-client")
      Application.put_env(:nebu_http, :admin_oidc_client_secret, "stale-env-secret")

      assert {:ok, cfg} = Nebu.Admin.Auth.oidc_config_for_test("normal")
      assert cfg.client_id == "db-client", "admin env client_id must be ignored"
      assert cfg.client_secret == "db-secret", "admin env client_secret must be ignored"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # Test 4 — SsoLogin resolves client + issuer from server_config only
  # ════════════════════════════════════════════════════════════════════════════

  describe "Test 4 — SsoLogin uses the single server_config client; env is ignored" do
    @sso_issuer "https://keycloak.example.com/realms/INNOQ"
    @sso_authorize "https://keycloak.example.com/realms/INNOQ/protocol/openid-connect/auth"
    @sso_client_id "single-db-client"

    defp sso_setup(pub_jwk) do
      Application.put_env(:nebu_http, :oidc_jwks, [pub_jwk])
      Application.put_env(:nebu_http, :admin_secret_at_rest, "bootstrap-only-sso-key")

      encrypted = Nebu.Admin.BootstrapLive.encrypt_secret("db-client-secret")

      Application.put_env(:nebu_http, :oidc_config_source, fn ->
        %{issuer: @sso_issuer, audience: @db_audience}
      end)

      Application.put_env(:nebu_http, :sso_bootstrap_reader, fn
        "oidc_client_id" -> @sso_client_id
        "oidc_client_secret" -> encrypted
        _ -> nil
      end)

      Application.put_env(:nebu_http, :oidc_metadata_override, %{
        "issuer" => @sso_issuer,
        "authorization_endpoint" => @sso_authorize,
        "token_endpoint" => @sso_issuer <> "/token",
        "jwks_uri" => @sso_issuer <> "/jwks"
      })

      on_exit(fn ->
        for k <- [
              :oidc_jwks,
              :admin_secret_at_rest,
              :oidc_config_source,
              :sso_bootstrap_reader,
              :oidc_metadata_override,
              :matrix_oidc_client_id,
              :matrix_oidc_client_secret,
              :admin_oidc_client_id,
              :admin_oidc_client_secret
            ] do
          Application.delete_env(:nebu_http, k)
        end
      end)
    end

    defp call_redirect do
      Nebu.Web.Router.call(
        conn(
          :get,
          "/_matrix/client/v3/login/sso/redirect?redirectUrl=" <>
            URI.encode_www_form("http://localhost:7070")
        ),
        Nebu.Web.Router.init([])
      )
    end

    setup do
      alias Nebu.Matrix.SsoStore
      if Process.whereis(SsoStore) == nil, do: start_supervised!(SsoStore)
      :ok
    end

    test "SSO redirect carries the server_config client_id (no env client set)" do
      {_priv, pub_jwk} = build_rsa_keypair()
      sso_setup(pub_jwk)

      conn = call_redirect()
      assert conn.status == 302

      loc = conn |> get_resp_header("location") |> List.first()
      assert String.starts_with?(loc, @sso_authorize)
      params = loc |> URI.parse() |> Map.get(:query) |> URI.decode_query()
      assert params["client_id"] == @sso_client_id
    end

    test "a stale matrix_oidc_client_id env is IGNORED — DB client wins" do
      {_priv, pub_jwk} = build_rsa_keypair()
      sso_setup(pub_jwk)

      # Stale env client/secret — must be ignored after env removal (RED before).
      Application.put_env(:nebu_http, :matrix_oidc_client_id, "stale-env-client")
      Application.put_env(:nebu_http, :matrix_oidc_client_secret, "stale-env-secret")

      conn = call_redirect()
      assert conn.status == 302

      params =
        conn
        |> get_resp_header("location")
        |> List.first()
        |> URI.parse()
        |> Map.get(:query)
        |> URI.decode_query()

      assert params["client_id"] == @sso_client_id,
             "SsoLogin must use the server_config client, not the stale env client"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # Test 6 — Bootstrap wizard renders all OIDC fields editable + required
  # ════════════════════════════════════════════════════════════════════════════

  describe "Test 6 — wizard OIDC fields always editable + required" do
    import Phoenix.LiveViewTest

    @endpoint Nebu.Admin.Endpoint

    setup do
      store = start_supervised!({Agent, fn -> %{draft: %{}, config: %{}} end})

      dispatcher = fn
        :load_draft, [] -> {:ok, Agent.get(store, & &1.draft)}
        :put_draft, [key, value] ->
          Agent.update(store, fn s -> put_in(s, [:draft, key], value) end)
          :ok
        :clear_draft, [] ->
          Agent.update(store, fn s -> %{s | draft: %{}} end)
          :ok
        :put_config, [key, value] ->
          Agent.update(store, fn s -> put_in(s, [:config, key], value) end)
          :ok
        :bootstrap_completed?, [] ->
          {:ok, Agent.get(store, &(&1.config["bootstrap_completed"] == "true"))}
      end

      Application.put_env(:nebu_http, :admin_bootstrap_store, dispatcher)
      Application.put_env(:nebu_http, :admin_secret_at_rest, "bootstrap-render-test-key")

      on_exit(fn ->
        Application.delete_env(:nebu_http, :admin_bootstrap_store)
        Application.delete_env(:nebu_http, :admin_secret_at_rest)
      end)

      {:ok, store: store}
    end

    test "step-2 OIDC fields have no disabled attribute and are required" do
      {:ok, view, _html} =
        live_isolated(Plug.Test.conn(:get, "/admin/bootstrap"), Nebu.Admin.BootstrapLive,
          session: %{"current_user" => %{"admin" => true, "sub" => "admin-1"}}
        )

      view |> form("form", %{"instance_name" => "test-nebu"}) |> render_submit()
      html = render(view)

      # No "(set via env)" indicator may appear — the env-lock mode is gone.
      refute html =~ "(set via env)"

      # All five OIDC fields present and NOT disabled.
      for field <- ~w(oidc_issuer oidc_client_id oidc_client_secret oidc_audience oidc_jwks_uri) do
        assert html =~ ~s(name="#{field}"), "missing field #{field}"
      end

      refute html =~ "disabled", "no OIDC field may be disabled (env-lock removed)"
    end

    test "submitting an empty audience is rejected as required" do
      {:ok, view, _html} =
        live_isolated(Plug.Test.conn(:get, "/admin/bootstrap"), Nebu.Admin.BootstrapLive,
          session: %{"current_user" => %{"admin" => true, "sub" => "admin-1"}}
        )

      view |> form("form", %{"instance_name" => "test-nebu"}) |> render_submit()

      # Submit step-2 with a blank audience — must NOT advance to step 3.
      view
      |> form("form", %{
        "oidc_issuer" => "https://idp.example.com",
        "oidc_client_id" => "c",
        "oidc_client_secret" => "s",
        "oidc_audience" => "",
        "oidc_jwks_uri" => "https://idp.example.com/jwks"
      })
      |> render_submit()

      html = render(view)
      refute html =~ ~s(data-step="3"), "blank audience must not advance the wizard"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # Test 7 — Server boots with zero OIDC env + empty server_config
  # ════════════════════════════════════════════════════════════════════════════

  describe "Test 7 — OidcConfig/JwksCache start with no env and empty DB" do
    test "OidcConfig starts, caches hold nil, no crash" do
      clean_oidc_env()

      {:ok, pid} =
        Nebu.Web.OidcConfig.start_link(name: :"OidcConfigBootTest#{System.unique_integer()}")

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "JwksCache starts with an empty key set when nothing is configured" do
      clean_oidc_env()

      {:ok, pid} =
        Nebu.Web.JwksCache.start_link(
          name: :"JwksCacheBootTest#{System.unique_integer()}",
          fetcher: fn -> {:ok, []} end
        )

      assert GenServer.call(pid, :keys) == []
      GenServer.stop(pid)
    end
  end
end
