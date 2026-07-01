defmodule Nebu.Matrix.SsoLoginScopeTest do
  @moduledoc """
  Regression tests for the Matrix SSO base scope.

  ## SUPERSEDED decisions (read this first)

  This file originally guarded bug `fix-element-login`, which set
  `@base_scopes` in `Nebu.Matrix.SsoLogin` to the MINIMAL `~w(openid)` and asserted
  `profile`/`email` MUST NOT appear.

  Story **`oidc-bootstrap-only-e2e-regressions`** (ADR-022 end-to-end fix) REVERSED
  that decision: the base scope was set to the fixed default `~w(openid profile email)`.

  Bug **`bugfix-remove-default-scopes`** REVERSES AGAIN per the OIDC Scopes Law:
  "default scope is ONLY 'openid'; no hardcoded extra scopes". The `@default_matrix_extra_scopes`
  constant is now `""`. Operators who need `profile`/`email` must configure them explicitly
  via the bootstrap wizard or admin config page. This file is updated to match the new law.

  ## Acceptance Criteria covered (new contract)

    * AC1 — Base scope is `openid` only (OIDC Scopes Law): online mode → `openid` only
      (NO `profile`, `email`, `offline_access`); offline mode → `openid offline_access`.
    * AC3 — offline_access behavior unchanged: offline mode still gets
      `offline_access`; online mode still excludes it.
    * AC4 — Regression guard: explicit assertion that `profile`/`email` are NOT in the
      default scope and that ONLY `openid` (+ optional `offline_access`) is the base.

  ## Public surface

  `scope_list/0` is `defp`. We assert via the observable result: the `scope`
  query-param of the 302 redirect built by
  `GET /_matrix/client/v3/login/sso/redirect`, which is the only public caller of
  `scope_list/0`. This style mirrors `sso_scope_mode_test.exs`.
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Nebu.Matrix.SsoStore

  @issuer "https://idp.example.com/realms/nebu"
  @authorize "https://idp.example.com/realms/nebu/auth"
  @token_endpoint "https://idp.example.com/realms/nebu/token"

  @router_opts Nebu.Web.Router.init([])

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp setup_oidc do
    # oidc-bootstrap-only-config (ADR-022): issuer via OidcConfig, the single SSO
    # OIDC client via the :sso_bootstrap_reader seam. No env config path.
    Nebu.Web.OidcTestSupport.configure(@issuer, "nebu-client")
    Application.put_env(:nebu_http, :admin_secret_at_rest, "sso-login-scope-test-key")

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

  # Drive the only public caller of scope_list/0 and return the scope tokens.
  defp scope_params do
    conn =
      conn(
        :get,
        "/_matrix/client/v3/login/sso/redirect?redirectUrl=" <>
          URI.encode_www_form("https://app.example.com/#/home")
      )

    conn = Nebu.Web.Router.call(conn, @router_opts)
    assert conn.status == 302
    loc = conn |> get_resp_header("location") |> List.first()
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
  # AC1 — Base scope is `openid profile email` (NEW default, ADR-022 e2e fix)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC1 — base scope is openid only (OIDC Scopes Law)" do
    test "online mode: scope is openid only, no profile/email/offline_access" do
      # bugfix-remove-default-scopes: @default_matrix_extra_scopes is now "" (OIDC Scopes Law).
      # No profile/email unless operator configures them explicitly.
      set_mode("online")
      scopes = scope_params()

      assert "openid" in scopes,
             "openid must always be present; got: #{inspect(scopes)}"

      refute "profile" in scopes,
             "profile must NOT be in default scope (OIDC Scopes Law); got: #{inspect(scopes)}"

      refute "email" in scopes,
             "email must NOT be in default scope (OIDC Scopes Law); got: #{inspect(scopes)}"

      refute "offline_access" in scopes,
             "online mode must NOT add offline_access; got: #{inspect(scopes)}"
    end

    test "offline mode: scope is openid + offline_access only, no profile/email" do
      set_mode("offline")
      scopes = scope_params()

      assert "openid" in scopes,
             "openid must always be present; got: #{inspect(scopes)}"

      refute "profile" in scopes,
             "profile must NOT be in default scope (OIDC Scopes Law); got: #{inspect(scopes)}"

      refute "email" in scopes,
             "email must NOT be in default scope (OIDC Scopes Law); got: #{inspect(scopes)}"

      assert "offline_access" in scopes,
             "offline_access must be present in offline mode; got: #{inspect(scopes)}"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC3 — offline_access behavior is not regressed
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC3 — offline_access behavior unchanged after base-scope reduction" do
    test "offline mode still includes offline_access" do
      set_mode("offline")
      scopes = scope_params()
      assert "offline_access" in scopes
    end

    test "online mode still excludes offline_access" do
      set_mode("online")
      scopes = scope_params()
      refute "offline_access" in scopes
    end

    test "unset / nil mode defaults to offline (includes offline_access)" do
      # Model 'unset' deterministically via the seam returning nil so we avoid a
      # racy live DB read. matrix_refresh_mode/0 collapses nil → "offline".
      prev = Application.get_env(:nebu_http, :matrix_oidc_refresh_mode_reader)
      Application.put_env(:nebu_http, :matrix_oidc_refresh_mode_reader, fn -> nil end)

      on_exit(fn ->
        case prev do
          nil -> Application.delete_env(:nebu_http, :matrix_oidc_refresh_mode_reader)
          v -> Application.put_env(:nebu_http, :matrix_oidc_refresh_mode_reader, v)
        end
      end)

      scopes = scope_params()
      assert "openid" in scopes
      assert "offline_access" in scopes
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC4 — Regression guard: the broken `~w(openid)`-only scope is NOT in effect
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC4 — regression guard: default scope is openid only (OIDC Scopes Law)" do
    test "online mode → scope list is exactly ['openid'] (order-independent)" do
      # bugfix-remove-default-scopes: OIDC Scopes Law — default is ONLY openid.
      # profile/email must NOT be hardcoded defaults; operators configure them explicitly.
      set_mode("online")
      scopes = scope_params()

      assert Enum.sort(scopes) == ["openid"],
             "expected default scope to be exactly [\"openid\"] but got: " <>
               "#{inspect(scopes)}. OIDC Scopes Law violation: no hardcoded extra scopes."
    end

    test "offline mode → scope list is exactly openid+offline_access (order-independent)" do
      set_mode("offline")
      scopes = scope_params()

      assert Enum.sort(scopes) == Enum.sort(["openid", "offline_access"]),
             "expected default scope to be exactly [\"openid\", \"offline_access\"] but got: " <>
               "#{inspect(scopes)}."
    end
  end
end
