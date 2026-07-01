defmodule Nebu.Matrix.SsoScopeProfileEmailTest do
  @moduledoc """
  ATDD test originally for bug `bugfix-oidc-bootstrap-only-e2e-regressions`, AC4.

  ## SUPERSEDED — bugfix-remove-default-scopes

  Bug `bugfix-remove-default-scopes` applies the OIDC Scopes Law: "default scope is
  ONLY 'openid'; no hardcoded extra scopes." The `@default_matrix_extra_scopes` constant
  is now `""`, so `profile`/`email` are NOT in the default scope unless the operator
  configures them explicitly.

  This file is updated to verify the OIDC Scopes Law: without configured extra scopes,
  `profile` and `email` must NOT appear. The `openid` and `offline_access` behavior
  (refresh-mode) is unchanged. Operators who need `profile`/`email` must configure them
  explicitly via the bootstrap wizard or /admin/config.

  ## Crash/restart — NOT APPLICABLE

  Pure config read on the request process (Persistenz Option C — stateless).
  """
  use ExUnit.Case, async: false
  import Plug.Test

  alias Nebu.Matrix.SsoStore

  @issuer "https://idp.example.com/realms/nebu"
  @authorize "https://idp.example.com/realms/nebu/auth"
  @token_endpoint "https://idp.example.com/realms/nebu/token"

  @router_opts Nebu.Web.Router.init([])

  defp setup_oidc do
    Nebu.Web.OidcTestSupport.configure(@issuer, "nebu-client")
    Application.put_env(:nebu_http, :admin_secret_at_rest, "sso-scope-profile-email-test-key")

    Application.put_env(:nebu_http, :sso_bootstrap_reader, fn
      "oidc_client_id" -> "nebu-client"
      "oidc_client_secret" -> Nebu.Admin.BootstrapLive.encrypt_secret("shhh")
      _ -> nil
    end)

    Application.put_env(:nebu_http, :oidc_metadata_override, %{
      "issuer" => @issuer,
      "authorization_endpoint" => @authorize,
      "token_endpoint" => @token_endpoint,
      "jwks_uri" => @issuer <> "/jwks"
    })

    # Isolate from server_config DB — OIDC Scopes Law: default is empty (openid only).
    Application.put_env(:nebu_http, :matrix_oidc_extra_scopes_reader, fn -> nil end)

    on_exit(fn ->
      Nebu.Web.OidcTestSupport.clear()

      for k <- [
            :admin_secret_at_rest,
            :sso_bootstrap_reader,
            :oidc_metadata_override,
            :matrix_oidc_refresh_mode_reader,
            :matrix_oidc_extra_scopes_reader
          ] do
        Application.delete_env(:nebu_http, k)
      end
    end)

    :ok
  end

  defp set_mode(mode),
    do: Application.put_env(:nebu_http, :matrix_oidc_refresh_mode_reader, fn -> mode end)

  defp scope_params do
    conn =
      conn(
        :get,
        "/_matrix/client/v3/login/sso/redirect?redirectUrl=" <>
          URI.encode_www_form("https://app.example.com/#/home")
      )

    conn = Nebu.Web.Router.call(conn, @router_opts)
    assert conn.status == 302
    loc = conn |> Plug.Conn.get_resp_header("location") |> List.first()
    assert is_binary(loc) and String.starts_with?(loc, @authorize)

    %URI{query: q} = URI.parse(loc)
    URI.decode_query(q)["scope"] |> String.split(" ", trim: true)
  end

  setup do
    if Process.whereis(SsoStore) == nil, do: start_supervised!(SsoStore)
    setup_oidc()
    :ok
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC4 — Matrix SSO base scope is `openid profile email`
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC4 — Matrix SSO default scope is openid only (OIDC Scopes Law)" do
    test "online mode: scope is openid only, no profile/email/offline_access" do
      # bugfix-remove-default-scopes: OIDC Scopes Law. profile/email are NOT defaults.
      set_mode("online")
      scopes = scope_params()

      assert "openid" in scopes

      refute "profile" in scopes,
             "profile must NOT be in default scope (OIDC Scopes Law); got: #{inspect(scopes)}"

      refute "email" in scopes,
             "email must NOT be in default scope (OIDC Scopes Law); got: #{inspect(scopes)}"

      refute "offline_access" in scopes
    end

    test "offline mode: scope is openid + offline_access only, no profile/email" do
      set_mode("offline")
      scopes = scope_params()

      assert "openid" in scopes

      refute "profile" in scopes,
             "profile must NOT be in default scope (OIDC Scopes Law); got: #{inspect(scopes)}"

      refute "email" in scopes,
             "email must NOT be in default scope (OIDC Scopes Law); got: #{inspect(scopes)}"

      assert "offline_access" in scopes,
             "offline mode must still include offline_access; got: #{inspect(scopes)}"
    end
  end
end
