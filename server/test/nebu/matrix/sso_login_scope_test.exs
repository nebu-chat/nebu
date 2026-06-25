defmodule Nebu.Matrix.SsoLoginScopeTest do
  @moduledoc """
  Regression tests for bug `fix-element-login`.

  ## Root cause

  `@base_scopes` in `Nebu.Matrix.SsoLogin` was `~w(openid profile email)`.
  The innoq Keycloak OIDC client does not permit `profile` and `email` scopes
  by default, causing:

    * Offline mode → "Invalid or expired SSO state" (`M_UNKNOWN` 400) — the IdP
      rejects the authorization request.
    * Online mode  → "SSO login failed" (`M_FORBIDDEN` 403) — token verification
      fails.

  ## Fix applied (commit: fix-element-login)

  `@base_scopes` was changed from `~w(openid profile email)` to `~w(openid)`.
  `profile` and `email` are now opt-in via `NEBU_OIDC_EXTRA_SCOPES`.

  ## Acceptance Criteria covered

    * AC1 — Minimal base scope: no extra scopes → scope is `"openid"` (online) or
      `"openid offline_access"` (offline). `profile` and `email` MUST NOT appear.
    * AC2 — Extra scopes additive: `NEBU_OIDC_EXTRA_SCOPES=profile email` →
      `profile` and `email` appear IN ADDITION to the base scope.
    * AC3 — offline_access behavior unchanged: offline mode still gets
      `offline_access`; online mode still excludes it. The `:matrix_oidc_refresh_mode_reader`
      seam already present in `sso_login.ex` is used to control this without a DB.
    * AC4 — Regression guard: explicit assertion that `"profile"` and `"email"` are
      NOT in the base scope list.

  ## Public surface

  `scope_list/0` is `defp`. We assert via the observable result: the `scope`
  query-param of the 302 redirect built by
  `GET /_matrix/client/v3/login/sso/redirect`, which is the only public caller of
  `scope_list/0`. This style mirrors `sso_scope_mode_test.exs`.

  ## All tests are GREEN after the fix

  AC1 and AC4 pass because `@base_scopes` is now `~w(openid)`, so `"profile"` and
  `"email"` no longer appear in the scope param when no extra scopes are configured.
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
    Application.put_env(:nebu_http, :oidc_issuer, @issuer)
    Application.put_env(:nebu_http, :oidc_audience, "nebu-client")
    Application.put_env(:nebu_http, :matrix_oidc_client_id, "nebu-client")
    Application.put_env(:nebu_http, :matrix_oidc_client_secret, "shhh")

    Application.put_env(:nebu_http, :oidc_metadata_override, %{
      "issuer" => @issuer,
      "authorization_endpoint" => @authorize,
      "token_endpoint" => @token_endpoint,
      "jwks_uri" => @issuer <> "/jwks"
    })

    on_exit(fn ->
      for k <- [
            :oidc_issuer,
            :oidc_audience,
            :matrix_oidc_client_id,
            :matrix_oidc_client_secret,
            :oidc_metadata_override,
            :oidc_extra_scopes,
            :matrix_oidc_refresh_mode_reader
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
  # AC1 — Minimal base scope (no extra scopes configured)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC1 — minimal base scope without extra scopes" do
    test "online mode: scope is exactly 'openid' — profile and email MUST NOT appear" do
      # Previously failing — @base_scopes was ~w(openid profile email), which caused
      # profile and email to appear even without extra scopes; fixed to ~w(openid).
      set_mode("online")
      scopes = scope_params()

      assert "openid" in scopes,
             "openid must always be present; got: #{inspect(scopes)}"

      refute "profile" in scopes,
             "profile MUST NOT be in base scope; it is an opt-in extra. Got: #{inspect(scopes)}"

      refute "email" in scopes,
             "email MUST NOT be in base scope; it is an opt-in extra. Got: #{inspect(scopes)}"
    end

    test "offline mode: scope is exactly 'openid offline_access' — profile and email MUST NOT appear" do
      # Previously failing — @base_scopes was ~w(openid profile email), which caused
      # profile and email to appear alongside offline_access; fixed to ~w(openid).
      set_mode("offline")
      scopes = scope_params()

      assert "openid" in scopes,
             "openid must always be present; got: #{inspect(scopes)}"

      assert "offline_access" in scopes,
             "offline_access must be present in offline mode; got: #{inspect(scopes)}"

      refute "profile" in scopes,
             "profile MUST NOT be in base scope; it is an opt-in extra. Got: #{inspect(scopes)}"

      refute "email" in scopes,
             "email MUST NOT be in base scope; it is an opt-in extra. Got: #{inspect(scopes)}"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC2 — Extra scopes are additive via NEBU_OIDC_EXTRA_SCOPES
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC2 — extra scopes additive via oidc_extra_scopes" do
    test "oidc_extra_scopes='profile email' → profile and email appear in scope (online mode)" do
      # GREEN on current code (profile/email happen to be in @base_scopes), but will
      # remain GREEN after the fix because they are moved to extra scopes.
      set_mode("online")
      Application.put_env(:nebu_http, :oidc_extra_scopes, "profile email")
      scopes = scope_params()

      assert "openid" in scopes
      assert "profile" in scopes
      assert "email" in scopes
      refute "offline_access" in scopes
    end

    test "oidc_extra_scopes as list ['profile', 'email'] → profile and email appear (offline mode)" do
      set_mode("offline")
      Application.put_env(:nebu_http, :oidc_extra_scopes, ["profile", "email"])
      scopes = scope_params()

      assert "openid" in scopes
      assert "profile" in scopes
      assert "email" in scopes
      assert "offline_access" in scopes
    end

    test "oidc_extra_scopes='profile email' → no duplicates in scope string" do
      set_mode("offline")
      Application.put_env(:nebu_http, :oidc_extra_scopes, "profile email")
      scopes = scope_params()

      assert length(scopes) == length(Enum.uniq(scopes)),
             "scope list must not contain duplicates; got: #{inspect(scopes)}"
    end

    test "arbitrary extra scopes are appended after the base scope" do
      set_mode("online")
      Application.put_env(:nebu_http, :oidc_extra_scopes, "groups custom_claim")
      scopes = scope_params()

      assert "openid" in scopes
      assert "groups" in scopes
      assert "custom_claim" in scopes
      refute "profile" in scopes
      refute "email" in scopes
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
  # AC4 — Regression guard: document that the OLD bad value is wrong
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC4 — regression guard: base scope list is exactly ['openid']" do
    test "no extra scopes + online mode → scope list is exactly ['openid']" do
      # Previously failing — @base_scopes was ~w(openid profile email), making the
      # scope 'openid profile email' instead of 'openid'. This is the explicit
      # regression guard that the old value ~w(openid profile email) was wrong.
      set_mode("online")
      scopes = scope_params()

      assert scopes == ["openid"],
             "expected base scope to be exactly [\"openid\"] but got: #{inspect(scopes)}. " <>
               "This is the regression guard: the OLD @base_scopes ~w(openid profile email) " <>
               "must be replaced with ~w(openid)."
    end

    test "no extra scopes + offline mode → scope list is exactly ['offline_access', 'openid'] (order-independent)" do
      # Previously failing — see AC4 above; fixed by reducing @base_scopes to ~w(openid).
      set_mode("offline")
      scopes = scope_params()

      assert Enum.sort(scopes) == Enum.sort(["openid", "offline_access"]),
             "expected base scope to be exactly [\"openid\", \"offline_access\"] but got: #{inspect(scopes)}. " <>
               "The OLD @base_scopes ~w(openid profile email) must be replaced with ~w(openid)."
    end
  end
end
