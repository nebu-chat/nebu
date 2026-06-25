defmodule Nebu.Matrix.SsoLoginOidcConfigDbFallbackTest do
  @moduledoc """
  Regression tests for bug: SSO login fails when Nebu starts without NEBU_OIDC_* env vars.

  ## Root Cause

  `oidc_config/0` in `Nebu.Matrix.SsoLogin` read the OIDC issuer only from
  `Application.get_env(:nebu_http, :oidc_issuer)`. When `NEBU_OIDC_ISSUER` is not
  set (Bootstrap-Wizard deployments), that value is `nil` → `{:error, :issuer_not_configured}`
  → 503 on every SSO redirect and callback.

  `Nebu.Web.Plugs.OidcPlug` already solves this correctly: its `oidc_issuer/0`
  private function falls back to `Nebu.Web.OidcConfig.get().issuer` (ETS cache
  backed by `server_config`) when the env var is absent. The SSO login module must
  use the same fallback.

  ## Fix

  Apply the same env → OidcConfig fallback pattern used in OidcPlug:

  ```elixir
  issuer =
    case Application.get_env(:nebu_http, :oidc_issuer) do
      v when is_binary(v) and v != "" -> v
      _ -> Nebu.Web.OidcConfig.get().issuer
    end
  ```

  ## Test Design

  Uses the `:oidc_config_source` seam (`Nebu.Web.OidcConfig.get/0`) to inject DB
  values without a live Postgres or GenServer. This mirrors the seam already used in
  admin OIDC tests.

  ## Acceptance Criteria

  - AC1: When `NEBU_OIDC_ISSUER` env is absent AND OidcConfig returns an issuer from
    the DB, the SSO redirect succeeds (302 to the IdP authorize endpoint).
  - AC2: When `NEBU_OIDC_ISSUER` env IS set, it takes priority over the DB value.
  - AC3: When neither env nor DB provides an issuer, the redirect fails closed (503).
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Nebu.Matrix.SsoStore

  @issuer_from_db "https://keycloak.example.com/realms/INNOQ"
  @issuer_from_env "https://env-override.example.com/dex"
  @audience "innoq-nebu"
  @kid "kc-fallback-key"
  @authorize "https://keycloak.example.com/realms/INNOQ/protocol/openid-connect/auth"
  @client_id "innoq-nebu-matrix"
  @at_rest_key "sso-oidc-db-fallback-test-key"

  @router_opts Nebu.Web.Router.init([])

  # ── helpers ──────────────────────────────────────────────────────────────────

  defp gen_pub_jwk do
    jwk = JOSE.JWK.generate_key({:rsa, 2048})

    jwk
    |> JOSE.JWK.to_public()
    |> JOSE.JWK.to_map()
    |> elem(1)
    |> Map.put("kid", @kid)
    |> Map.put("alg", "RS256")
    |> Map.put("use", "sig")
  end

  # Injects the OidcConfig DB value via the :oidc_config_source seam.
  defp inject_db_issuer(issuer) do
    Application.put_env(:nebu_http, :oidc_config_source, fn ->
      %{issuer: issuer, audience: @audience}
    end)
  end

  defp setup_base(pub_jwk) do
    Application.put_env(:nebu_http, :oidc_audience, @audience)
    Application.put_env(:nebu_http, :oidc_jwks, [pub_jwk])
    Application.put_env(:nebu_http, :admin_secret_at_rest, @at_rest_key)

    # sso_bootstrap_reader: returns client credentials from Bootstrap DB.
    encrypted_secret =
      Nebu.Admin.BootstrapLive.encrypt_secret("client-secret-for-keycloak")

    Application.put_env(:nebu_http, :sso_bootstrap_reader, fn
      "oidc_client_id" -> @client_id
      "oidc_client_secret" -> encrypted_secret
      _ -> nil
    end)

    Application.put_env(:nebu_http, :oidc_metadata_override, %{
      "issuer" => @issuer_from_db,
      "authorization_endpoint" => @authorize,
      "token_endpoint" => @issuer_from_db <> "/protocol/openid-connect/token",
      "jwks_uri" => @issuer_from_db <> "/jwks"
    })

    on_exit(fn ->
      for k <- [
            :oidc_issuer,
            :oidc_audience,
            :oidc_jwks,
            :oidc_config_source,
            :sso_bootstrap_reader,
            :oidc_metadata_override,
            :matrix_oidc_client_id,
            :admin_secret_at_rest
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
      @router_opts
    )
  end

  defp location(conn), do: conn |> get_resp_header("location") |> List.first()

  setup do
    if Process.whereis(SsoStore) == nil, do: start_supervised!(SsoStore)
    :ok
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC1 — No NEBU_OIDC_ISSUER env; issuer comes from Bootstrap DB via OidcConfig
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC1 — SSO redirect uses OidcConfig DB issuer when env var is absent" do
    test "redirect 302s to IdP authorize endpoint using DB issuer" do
      pub_jwk = gen_pub_jwk()
      setup_base(pub_jwk)

      # NEBU_OIDC_ISSUER NOT set → nil in Application env.
      Application.delete_env(:nebu_http, :oidc_issuer)
      Application.delete_env(:nebu_http, :matrix_oidc_client_id)

      # OidcConfig DB seam: returns issuer from Bootstrap DB.
      inject_db_issuer(@issuer_from_db)

      conn = call_redirect()

      # Before the fix: oidc_config/0 reads nil issuer → {:error, :issuer_not_configured}
      # → 503. After the fix: falls back to OidcConfig.get().issuer → 302.
      assert conn.status == 302,
             "expected 302 (issuer from Bootstrap DB), got #{conn.status}. " <>
               "Root cause: oidc_config/0 reads only Application.get_env(:nebu_http, :oidc_issuer) " <>
               "without falling back to Nebu.Web.OidcConfig.get().issuer — fix mirrors OidcPlug.oidc_issuer/0."

      loc = location(conn)
      assert is_binary(loc) and String.starts_with?(loc, @authorize),
             "expected redirect to Keycloak authorize endpoint, got: #{inspect(loc)}"
    end

    test "redirect carries the DB issuer's client_id in the authorize URL" do
      pub_jwk = gen_pub_jwk()
      setup_base(pub_jwk)

      Application.delete_env(:nebu_http, :oidc_issuer)
      Application.delete_env(:nebu_http, :matrix_oidc_client_id)
      inject_db_issuer(@issuer_from_db)

      conn = call_redirect()
      assert conn.status == 302

      params = conn |> location() |> URI.parse() |> Map.get(:query) |> URI.decode_query()
      assert params["client_id"] == @client_id,
             "expected client_id from Bootstrap DB, got: #{inspect(params["client_id"])}"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC2 — NEBU_OIDC_ISSUER env takes priority over DB value
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC2 — env issuer takes priority over Bootstrap DB issuer" do
    test "when NEBU_OIDC_ISSUER is set, DB issuer is not used" do
      pub_jwk = gen_pub_jwk()
      setup_base(pub_jwk)

      # Set env issuer (different from DB value).
      Application.put_env(:nebu_http, :oidc_issuer, @issuer_from_env)
      Application.put_env(:nebu_http, :matrix_oidc_client_id, "env-client")
      Application.put_env(:nebu_http, :matrix_oidc_client_secret, "env-secret")

      # Also inject DB issuer — must be ignored when env is set.
      inject_db_issuer(@issuer_from_db)

      # Discovery seam must match the env issuer.
      Application.put_env(:nebu_http, :oidc_metadata_override, %{
        "issuer" => @issuer_from_env,
        "authorization_endpoint" => @issuer_from_env <> "/auth",
        "token_endpoint" => @issuer_from_env <> "/token",
        "jwks_uri" => @issuer_from_env <> "/jwks"
      })

      conn = call_redirect()

      assert conn.status == 302
      loc = location(conn)
      assert String.starts_with?(loc, @issuer_from_env <> "/auth"),
             "redirect should use env issuer's authorize URL, got: #{inspect(loc)}"

      refute String.starts_with?(to_string(loc), @issuer_from_db),
             "DB issuer must not be used when env is set"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC3 — Fail-closed: no issuer from either source → 503
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC3 — fail-closed: no issuer from env or DB → 503" do
    test "503 when both NEBU_OIDC_ISSUER and OidcConfig.get() return nil" do
      pub_jwk = gen_pub_jwk()
      setup_base(pub_jwk)

      Application.delete_env(:nebu_http, :oidc_issuer)
      Application.delete_env(:nebu_http, :matrix_oidc_client_id)

      # OidcConfig seam returns nil issuer (no Bootstrap config done).
      inject_db_issuer(nil)

      conn = call_redirect()

      assert conn.status == 503,
             "expected 503 M_UNAVAILABLE when no issuer is available; got #{conn.status}"
    end
  end
end
