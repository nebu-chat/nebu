defmodule Nebu.Admin.AdminMatrixIdentityUnificationTest do
  @moduledoc """
  Regression tests for bug `bugfix-unify-admin-matrix-oidc-identity`, UPDATED by
  story `centralize-scope-resolution` (epic `oidc-simplification`).

  ## History

  `bugfix-unify-admin-matrix-oidc-identity` originally fixed a "two identities for
  one person" bug by making `Nebu.Admin.Auth.admin_oidc_scope/0` UNION the admin's
  own configured extra scopes with the Matrix flow's extra scopes (via the
  `Nebu.Matrix.matrix_oidc_extra_scopes/0` facade), so both ID tokens carried the
  same claim superset.

  That fold was itself the root cause of a new, worse problem (AC3 of
  `centralize-scope-resolution`, Kassandra LOW): it let `offline_access` configured
  under `matrix_oidc_extra_scopes` leak into the Admin OIDC request even when the
  admin client's own refresh mode was `"online"` — i.e. one client's OIDC scope
  configuration silently altered another client's authorization request.

  `centralize-scope-resolution` removes the fold entirely (`union_scopes/2` is
  deleted from `Nebu.Admin.Auth`; `Nebu.Web.OidcScopes.resolve_scope/1` resolves
  each client's scope from ONLY that client's own `server_config` keys). Each
  client is independently responsible for requesting whatever scopes it needs to
  drive its own claim-derived identity — there is no cross-client union. The
  identity-unification claim-mapping problem this bug originally reported is
  tracked separately (see story Non-Goals: "Kein Claim-Mapping" — a future
  `centralize-claim-resolution`-style story, not scope resolution).

  This file keeps the parts of the original suite that remain valid (OIDC Scopes
  Law defaults, dedup, `UserId.from_claims/2` end-to-end derivation) and replaces
  the "admin scope is a superset of Matrix scope" assertions with "no cross-client
  leakage" assertions — the mirror image, on the admin side, of the AC3 tests in
  `test/nebu/web/oidc_scopes_test.exs`.
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Nebu.Admin.Auth
  alias Nebu.Matrix.SsoStore

  @issuer "https://idp.example.com/realms/nebu"
  @authorization_endpoint "https://idp.example.com/realms/nebu/auth"
  @token_endpoint "https://idp.example.com/realms/nebu/token"
  @client_id "nebu-gateway"

  setup do
    # oidc-bootstrap-only-config (ADR-022): SINGLE OIDC client serves both flows.
    Nebu.Web.OidcTestSupport.configure(@issuer, @client_id)
    Application.put_env(:nebu_http, :admin_secret_at_rest, "admin-matrix-identity-test-key")

    Application.put_env(:nebu_http, :admin_oidc_config_reader, fn
      "oidc_client_id" -> @client_id
      "oidc_client_secret" -> Nebu.Admin.BootstrapLive.encrypt_secret("client-secret")
      _ -> nil
    end)

    Application.put_env(:nebu_http, :sso_bootstrap_reader, fn
      "oidc_client_id" -> @client_id
      "oidc_client_secret" -> Nebu.Admin.BootstrapLive.encrypt_secret("client-secret")
      _ -> nil
    end)

    Application.put_env(:nebu_http, :server_name, "localhost")
    Application.put_env(:nebu_http, :admin_session_secure, false)

    Application.put_env(:nebu_http, :oidc_metadata_override, %{
      "issuer" => @issuer,
      "authorization_endpoint" => @authorization_endpoint,
      "token_endpoint" => @token_endpoint,
      "jwks_uri" => @issuer <> "/jwks"
    })

    # Pin refresh modes so offline_access never pollutes the scope assertions.
    Application.put_env(:nebu_http, :admin_oidc_refresh_mode_reader, fn -> "online" end)
    Application.put_env(:nebu_http, :matrix_oidc_refresh_mode_reader, fn -> "online" end)

    if Process.whereis(SsoStore) == nil, do: start_supervised!(SsoStore)

    on_exit(fn ->
      Nebu.Web.OidcTestSupport.clear()

      for k <- [
            :admin_secret_at_rest,
            :admin_oidc_config_reader,
            :sso_bootstrap_reader,
            :server_name,
            :admin_session_secure,
            :oidc_metadata_override,
            :admin_oidc_refresh_mode_reader,
            :matrix_oidc_refresh_mode_reader,
            :admin_oidc_extra_scopes_reader,
            :matrix_oidc_extra_scopes_reader
          ] do
        Application.delete_env(:nebu_http, k)
      end

      Application.delete_env(:matrix, :oidc_claim_reader)
      Nebu.Matrix.OidcClaimCache.reset_for_test()
    end)

    :ok
  end

  defp session_conn(method, path), do: conn(method, path) |> init_test_session(%{})

  defp set_admin_extra_scopes(scopes),
    do: Application.put_env(:nebu_http, :admin_oidc_extra_scopes_reader, fn -> scopes end)

  defp set_matrix_extra_scopes(scopes),
    do: Application.put_env(:nebu_http, :matrix_oidc_extra_scopes_reader, fn -> scopes end)

  # Injects the operator-configured oidc_user_id_claim via the SAME seam
  # `Nebu.Matrix.UserId` reads through (Nebu.Matrix.OidcClaimCache), mirroring
  # user_id_name_claim_test.exs. Resets the persistent_term cache so the next
  # UserId.from_claims/2 re-reads through the seam.
  defp set_user_id_claim(claim) do
    Application.put_env(:matrix, :oidc_claim_reader, fn -> claim end)
    Nebu.Matrix.OidcClaimCache.reset_for_test()
  end

  defp admin_login_scope do
    conn = session_conn(:get, "/admin/login/start") |> Auth.login_start(%{})
    assert conn.status == 302
    [location] = get_resp_header(conn, "location")
    %URI{query: query} = URI.parse(location)
    URI.decode_query(query)["scope"] |> String.split(" ", trim: true)
  end

  defp matrix_login_scope do
    router_opts = Nebu.Web.Router.init([])

    conn =
      conn(
        :get,
        "/_matrix/client/v3/login/sso/redirect?redirectUrl=" <>
          URI.encode_www_form("https://app.example.com/#/home")
      )
      |> Nebu.Web.Router.call(router_opts)

    assert conn.status == 302
    loc = conn |> get_resp_header("location") |> List.first()
    %URI{query: q} = URI.parse(loc)
    URI.decode_query(q)["scope"] |> String.split(" ", trim: true)
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Post-centralize-scope-resolution: admin and Matrix scopes are INDEPENDENT
  # (no cross-client union/fold — AC3/AC4 of centralize-scope-resolution)
  # ══════════════════════════════════════════════════════════════════════════

  describe "admin_oidc_scope/0 resolves ONLY its own configured extra scopes (no Matrix fold)" do
    test "operator configures DIFFERENT admin vs matrix extra scopes → neither leaks into the other" do
      set_admin_extra_scopes("groups")
      set_matrix_extra_scopes("profile")

      admin_scopes = admin_login_scope()
      matrix_scopes = matrix_login_scope()

      assert "openid" in admin_scopes
      assert "groups" in admin_scopes
      # Post-fix (centralize-scope-resolution, AC3/AC4): the admin scope no longer
      # folds in the Matrix flow's extra scopes — each client is independent.
      refute "profile" in admin_scopes,
             "admin scope must NOT include the Matrix flow's extra scopes (the fold that " <>
               "caused the AC3 offline_access leak was removed); got: #{inspect(admin_scopes)}"

      assert "openid" in matrix_scopes
      assert "profile" in matrix_scopes
      refute "groups" in matrix_scopes
    end

    test "matrix has no extra scopes configured → admin scope is unaffected beyond openid" do
      set_admin_extra_scopes("groups")
      set_matrix_extra_scopes(nil)

      admin_scopes = admin_login_scope()

      assert "openid" in admin_scopes
      assert "groups" in admin_scopes
      refute "profile" in admin_scopes
      refute "email" in admin_scopes
    end

    test "admin has no extra scopes configured, matrix requests profile → admin does NOT inherit it" do
      set_admin_extra_scopes(nil)
      set_matrix_extra_scopes("profile")

      admin_scopes = admin_login_scope()

      assert admin_scopes == ["openid"]
      refute "profile" in admin_scopes
    end

    test "both unconfigured → both flows request openid only (OIDC Scopes Law preserved)" do
      set_admin_extra_scopes(nil)
      set_matrix_extra_scopes(nil)

      assert Enum.sort(admin_login_scope()) == ["openid"]
      assert Enum.sort(matrix_login_scope()) == ["openid"]
    end

    test "duplicate scope tokens within a single client's own config are de-duplicated" do
      set_admin_extra_scopes("profile groups profile")
      set_matrix_extra_scopes("profile")

      admin_scopes = admin_login_scope()
      assert Enum.count(admin_scopes, &(&1 == "profile")) == 1
      assert "groups" in admin_scopes
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # End-to-end identity derivation: UserId.from_claims/2 behaves identically for
  # the same claim set regardless of which flow produced it (unaffected by the
  # scope-resolution refactor — claim mapping itself is out of scope here).
  # ══════════════════════════════════════════════════════════════════════════

  describe "UserId.from_claims/2 resolves consistently for a given claim set" do
    test "admin login (put_current_user) and Matrix identity derivation (UserId.from_claims) agree when claims match" do
      set_user_id_claim("preferred_username")

      # Same claims presented to both flows (e.g. because the operator configured
      # BOTH admin_oidc_extra_scopes and matrix_oidc_extra_scopes to include
      # "profile" independently) resolve to the same Matrix user_id.
      shared_claims = %{
        "sub" => "00000000-0000-0000-0000-000000000001",
        "preferred_username" => "kai",
        "email" => "kai@example.com"
      }

      admin_conn = session_conn(:get, "/admin/callback") |> Auth.put_current_user(shared_claims)
      admin_user = get_session(admin_conn, "current_user")

      matrix_user_id = Nebu.Matrix.UserId.from_claims(shared_claims, "localhost")

      assert admin_user["matrix_user_id"] == matrix_user_id
      assert admin_user["matrix_user_id"] == "@kai:localhost"
    end

    test "DOCUMENTED trade-off: independently-configured scopes CAN yield divergent claim sets post-refactor" do
      # Post-centralize-scope-resolution, admin_oidc_extra_scopes and
      # matrix_oidc_extra_scopes are fully independent (AC3/AC4) — an operator who
      # configures them differently can once again see two different Matrix
      # user_ids for the same real person, because each flow's ID token now only
      # ever carries the claims ITS OWN configured scope requested. This is an
      # accepted, documented trade-off of removing the cross-client fold (the fold
      # was removed because it caused the AC3 offline_access leak); unifying
      # identity across independently-scoped flows is tracked as a separate,
      # claim-mapping-centric story (see this story's Non-Goals).
      set_user_id_claim("preferred_username")

      admin_id_token_claims = %{
        "sub" => "00000000-0000-0000-0000-000000000001",
        "groups" => ["instance_admin"]
      }

      matrix_id_token_claims = %{
        "sub" => "00000000-0000-0000-0000-000000000001",
        "preferred_username" => "kai"
      }

      admin_user_id = Nebu.Matrix.UserId.from_claims(admin_id_token_claims, "localhost")
      matrix_user_id = Nebu.Matrix.UserId.from_claims(matrix_id_token_claims, "localhost")

      refute admin_user_id == matrix_user_id,
             "documents the accepted post-refactor trade-off: independently-configured " <>
               "scopes can yield divergent claim sets and thus divergent derived identities"
    end
  end
end
