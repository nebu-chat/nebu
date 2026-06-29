defmodule Nebu.Matrix.SsoScopeProfileEmailTest do
  @moduledoc """
  RED-phase ATDD test for bug `bugfix-oidc-bootstrap-only-e2e-regressions`, AC4.

  ## Background (root cause)

  ADR-022 reduced `Nebu.Matrix.SsoLogin`'s `@base_scopes` to `~w(openid)`. Without
  `profile`, Dex omits the `name` claim, so the configured `oidc_user_id_claim = "name"`
  cannot resolve and the MXID falls back to `sub` — the exact regression previously
  fixed by `df249f8c`.

  ## AC4 / AC5 — Matrix SSO must request `openid profile email`

  `scope_list/0` (a `defp`) base becomes `~w(openid profile email)`, keeping the
  `offline_access`-when-offline logic. The OBSERVABLE surface is the `scope` query
  param of the 302 redirect built by `GET /_matrix/client/v3/login/sso/redirect`,
  the only public caller of `scope_list/0`.

    * online mode  → scope contains `openid profile email`, NO `offline_access`.
    * offline mode → ADDITIONALLY contains `offline_access` (refresh-mode behavior
      unchanged — regression guard).

  RED NOW: `@base_scopes ~w(openid)`, so `"profile"`/`"email"` are absent. The
  `openid` and offline_access assertions are already GREEN — kept as regression
  guards that the fix does not drop them.

  ## ⚠ CONFLICT — sso_login_scope_test.exs asserts the OPPOSITE

  `server/test/nebu/matrix/sso_login_scope_test.exs` is a PRE-EXISTING test from the
  old `fix-element-login` bug. It asserts the Matrix base scope is EXACTLY
  `["openid"]` and that `"profile"`/`"email"` MUST NOT appear. This story (AC4/AC5)
  DELIBERATELY changes the default to `openid profile email`, directly contradicting
  that test. The dev step that implements AC4 MUST update/replace
  `sso_login_scope_test.exs` — its assertions are now stale. (Not deleted here.)

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

    on_exit(fn ->
      Nebu.Web.OidcTestSupport.clear()

      for k <- [
            :admin_secret_at_rest,
            :sso_bootstrap_reader,
            :oidc_metadata_override,
            :matrix_oidc_refresh_mode_reader
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

  describe "AC4 — Matrix SSO requests profile + email" do
    test "online mode: scope contains openid profile email and NO offline_access" do
      set_mode("online")
      scopes = scope_params()

      # Already-green guard.
      assert "openid" in scopes

      # RED NOW: @base_scopes is ~w(openid), so profile/email are absent.
      assert "profile" in scopes,
             "Matrix SSO must request `profile` so the `name` claim is present; got: #{inspect(scopes)}"

      assert "email" in scopes,
             "Matrix SSO must request `email`; got: #{inspect(scopes)}"

      # online mode never adds offline_access (already-green guard).
      refute "offline_access" in scopes
    end

    test "offline mode: scope contains openid profile email AND offline_access" do
      set_mode("offline")
      scopes = scope_params()

      assert "openid" in scopes

      # RED NOW: profile/email absent under the reduced base scope.
      assert "profile" in scopes,
             "offline mode must still request `profile`; got: #{inspect(scopes)}"

      assert "email" in scopes,
             "offline mode must still request `email`; got: #{inspect(scopes)}"

      # Regression guard — refresh-mode behavior unchanged (already-green).
      assert "offline_access" in scopes,
             "offline mode must still include offline_access; got: #{inspect(scopes)}"
    end
  end
end
