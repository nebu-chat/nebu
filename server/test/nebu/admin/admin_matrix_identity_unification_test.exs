defmodule Nebu.Admin.AdminMatrixIdentityUnificationTest do
  @moduledoc """
  Regression tests for bug `bugfix-unify-admin-matrix-oidc-identity`.

  ## The bug (confirmed live against the real dev Dex stack)

  An operator who is both an `instance_admin` (admin login) and a Matrix user
  (Matrix SSO login) could end up with TWO different Matrix `user_id`s for the
  SAME real-world identity (same `sub` at the same issuer):

    * `Nebu.Admin.Auth.admin_oidc_scope/0` and `Nebu.Matrix.SsoLogin.scope_list/0`
      each read their OWN independent `server_config` key
      (`admin_oidc_extra_scopes` vs `matrix_oidc_extra_scopes`, OIDC Scopes Law —
      both default to `""`/`openid`-only, but an operator may configure them
      DIFFERENTLY, e.g. Matrix gets `"profile"` so `preferred_username`/`name`
      resolve, admin gets only `"groups"`).
    * `Nebu.Matrix.UserId.from_claims/2` derives the localpart from the
      configured claim, falling back through `preferred_username` → `name` →
      `sub`. Two ID tokens for the SAME person with DIFFERENT claim sets (because
      the two flows requested different scopes) therefore land on DIFFERENT
      Matrix user_ids — one from a real username claim, one from the opaque
      `sub` fallback.

  Live evidence (this bug's investigation): with
  `admin_oidc_extra_scopes = "profile groups"` and `matrix_oidc_extra_scopes = ""`,
  `oidc_user_id_claim = "name"`, logging in as Dex user `kai` (same `sub`) via
  the admin flow resolved to `@kai:localhost` while the Matrix SSO flow resolved
  to the opaque sanitized-`sub` fallback `@ciqwmdaw...:localhost` — two
  identities for one person.

  ## The fix

  `Nebu.Admin.Auth.admin_oidc_scope/0` now UNIONS the admin's own configured
  extra scopes with `Nebu.Matrix.SsoLogin.matrix_extra_scopes/0` (exposed for
  this purpose) before building the authorize-request `scope` parameter. The
  admin ID token is therefore always a claim-SUPERSET of whatever the Matrix
  flow would receive, so `UserId.from_claims/2` — which is claim-priority-driven,
  not scope-driven — resolves IDENTICALLY for both flows for the same person.
  This does NOT retroactively merge identities that already split under the old
  drift (out of scope — see the bug report); it only stops NEW divergence.

  ## Public surface (no testing of privates)

  `admin_oidc_scope/0` and `scope_list/0` are both `defp`. We assert via the
  observable `scope` query-param of each flow's 302 redirect (mirrors
  `admin_scope_mode_test.exs` / `sso_login_scope_test.exs`), AND via the
  end-to-end claims → `user_id` derivation exercised through
  `Auth.put_current_user/2` (admin) and `Nebu.Matrix.UserId.from_claims/2`
  (Matrix / OidcPlug path) — the same derivation `POST /login` uses.
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
  # Scope unification: admin scope is always a superset of the Matrix scope
  # ══════════════════════════════════════════════════════════════════════════

  describe "admin_oidc_scope/0 always includes matrix_oidc_extra_scopes (root-cause fix)" do
    test "operator configures DIFFERENT admin vs matrix extra scopes → admin request is a superset" do
      set_admin_extra_scopes("groups")
      set_matrix_extra_scopes("profile")

      admin_scopes = admin_login_scope()
      matrix_scopes = matrix_login_scope()

      assert "openid" in admin_scopes
      assert "groups" in admin_scopes
      # THE FIX: admin also requests what Matrix requests, so the SAME claims land
      # in both ID tokens for the same person.
      assert "profile" in admin_scopes,
             "admin scope must include the Matrix flow's extra scopes so the ID tokens " <>
               "carry the same claims for the same person; got admin scopes: #{inspect(admin_scopes)}"

      assert "openid" in matrix_scopes
      assert "profile" in matrix_scopes
      # The union is one-directional: Matrix scope is NEVER polluted with
      # admin-only scopes (e.g. an admin-gate-only "groups" claim request must not
      # leak into the Matrix client's authorization request).
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

    test "admin has no extra scopes configured, matrix requests profile → admin still gets profile" do
      set_admin_extra_scopes(nil)
      set_matrix_extra_scopes("profile")

      admin_scopes = admin_login_scope()

      assert "openid" in admin_scopes
      assert "profile" in admin_scopes
    end

    test "both unconfigured → both flows request openid only (OIDC Scopes Law preserved)" do
      set_admin_extra_scopes(nil)
      set_matrix_extra_scopes(nil)

      assert Enum.sort(admin_login_scope()) == ["openid"]
      assert Enum.sort(matrix_login_scope()) == ["openid"]
    end

    test "duplicate scope tokens across admin+matrix config are de-duplicated" do
      set_admin_extra_scopes("profile groups")
      set_matrix_extra_scopes("profile")

      admin_scopes = admin_login_scope()
      assert Enum.count(admin_scopes, &(&1 == "profile")) == 1
      assert "groups" in admin_scopes
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # End-to-end identity unification: same sub/issuer → same Matrix user_id
  # ══════════════════════════════════════════════════════════════════════════

  describe "same OIDC identity resolves to the same Matrix user_id across both login flows" do
    test "admin login (put_current_user) and Matrix identity derivation (UserId.from_claims) agree" do
      # oidc_user_id_claim = "preferred_username" (a realistic operator config that
      # requires the "profile" scope to actually be present in the token).
      set_user_id_claim("preferred_username")

      # BEFORE the fix, an operator could configure these two independently and end
      # up with drifted claim sets. AFTER the fix, admin_oidc_scope/0 always folds in
      # whatever Matrix requests, so both flows' ID tokens carry "preferred_username"
      # once ANY of the two configs requests "profile".
      set_admin_extra_scopes("groups")
      set_matrix_extra_scopes("profile")

      # Simulates the claims the IdP would return under the ACTUAL admin scope
      # (openid + groups + profile, because of the fix) for one real person.
      admin_id_token_claims = %{
        "sub" => "00000000-0000-0000-0000-000000000001",
        "preferred_username" => "kai",
        "email" => "kai@example.com",
        "groups" => ["instance_admin"]
      }

      # Simulates the claims the IdP returns under the Matrix scope (openid + profile)
      # for the SAME real person (same sub/issuer).
      matrix_id_token_claims = %{
        "sub" => "00000000-0000-0000-0000-000000000001",
        "preferred_username" => "kai"
      }

      admin_conn =
        session_conn(:get, "/admin/callback") |> Auth.put_current_user(admin_id_token_claims)

      admin_user = get_session(admin_conn, "current_user")

      matrix_user_id = Nebu.Matrix.UserId.from_claims(matrix_id_token_claims, "localhost")

      assert admin_user["matrix_user_id"] == matrix_user_id
      assert admin_user["matrix_user_id"] == "@kai:localhost"
      assert matrix_user_id == "@kai:localhost"
    end

    test "REGRESSION: without the fix's scope union, drifted scopes would have produced two identities" do
      # This test documents the OLD broken behaviour by directly modelling what each
      # flow's ID token would contain WITHOUT the scope union (i.e. computing the
      # matrix and admin claim sets independently, as the old code did structurally).
      # It is a documentation/regression guard, not a call into private scope
      # functions — it shows why the fix is necessary. If someone reverts the fix,
      # `admin_login_scope/0` above already fails; this test asserts the DOWNSTREAM
      # consequence in terms of derived identities that motivated the fix.
      set_user_id_claim("preferred_username")

      # Old-world simulation: admin ID token WITHOUT profile (only "groups" was
      # configured for admin) → no preferred_username claim → falls back to sub.
      admin_id_token_claims_pre_fix = %{
        "sub" => "00000000-0000-0000-0000-000000000001",
        "groups" => ["instance_admin"]
      }

      # Matrix ID token WITH profile → preferred_username present.
      matrix_id_token_claims = %{
        "sub" => "00000000-0000-0000-0000-000000000001",
        "preferred_username" => "kai"
      }

      pre_fix_admin_user_id =
        Nebu.Matrix.UserId.from_claims(admin_id_token_claims_pre_fix, "localhost")

      matrix_user_id = Nebu.Matrix.UserId.from_claims(matrix_id_token_claims, "localhost")

      refute pre_fix_admin_user_id == matrix_user_id,
             "sanity check: this demonstrates the pre-fix divergence this bug fixes"

      # With the fix, admin_oidc_scope/0 ensures the admin ID token is NEVER missing
      # a claim the Matrix flow would have — this is asserted end-to-end in the test
      # above ("admin login (put_current_user) and Matrix identity derivation agree").
    end
  end
end
