defmodule Nebu.Matrix.SsoLoginTest do
  @moduledoc """
  RED-phase ATDD tests for story `oidc-scopes-configurable`, AC4 + AC11 (Matrix side).

  ## What is under test

  After this story `scope_list/0` in `Nebu.Matrix.SsoLogin` must:

    1. Read `matrix_oidc_extra_scopes` from `server_config` (via the
       `:matrix_oidc_extra_scopes_reader` seam — mirrors the existing
       `:matrix_oidc_refresh_mode_reader` pattern).
    2. Always include `"openid"` (OIDC-mandatory).
    3. Append the extra scopes (default `"profile email"` if NULL/empty).
    4. Add `"offline_access"` iff `matrix_refresh_mode() == "offline"`.
    5. Return space-separated, de-duplicated, filtered string.

  TODAY `scope_list/0` uses a compile-time `@base_scopes ~w(openid profile email)` and
  does not consult `server_config` for extra scopes. The `:matrix_oidc_extra_scopes_reader`
  seam does NOT exist yet. All tests below are RED until the seam + runtime read is added.

  ## Public surface (no testing of privates)

  `scope_list/0` is `defp`. We assert via the only public observable: the `scope`
  query-param of the 302 `GET /_matrix/client/v3/login/sso/redirect` redirect — the
  same pattern as `sso_scope_mode_test.exs` and `sso_login_scope_test.exs`.

  ## Test seam

  `:matrix_oidc_extra_scopes_reader` — a 0-arity fun injected via Application.put_env.
  Returns a string of space-separated extra scopes (beyond `openid`), or `nil`/`""` to
  trigger the default `"profile email"` fallback. Mirrors `:matrix_oidc_refresh_mode_reader`.

  ## Crash/restart — NOT APPLICABLE

  Pure config read on the request process (Persistenz Option C — stateless).
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Nebu.Matrix.SsoStore

  @issuer "https://idp.example.com/realms/nebu"
  @authorize "https://idp.example.com/realms/nebu/auth"
  @token_endpoint "https://idp.example.com/realms/nebu/token"

  @router_opts Nebu.Web.Router.init([])

  defp setup_oidc do
    Nebu.Web.OidcTestSupport.configure(@issuer, "nebu-client")
    Application.put_env(:nebu_http, :admin_secret_at_rest, "sso-login-extra-scopes-test-key")

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

    # Pin online mode so offline_access is absent by default — tests that need
    # offline mode set it explicitly via set_mode/1.
    Application.put_env(:nebu_http, :matrix_oidc_refresh_mode_reader, fn -> "online" end)

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

  defp set_extra_scopes(scopes),
    do: Application.put_env(:nebu_http, :matrix_oidc_extra_scopes_reader, fn -> scopes end)

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
  # AC11-1 — No extra scopes → returns "openid profile email" (online mode)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC11-1: no extra scopes configured → default openid profile email (online)" do
    test "nil extra scopes + online mode → openid profile email, no offline_access" do
      # The :matrix_oidc_extra_scopes_reader seam does NOT exist today → RED.
      # After implementation: nil/missing scopes fall back to "profile email" default.
      set_extra_scopes(nil)
      set_mode("online")

      scopes = scope_params()

      assert "openid" in scopes,
             "openid must always be present; got: #{inspect(scopes)}"

      assert "profile" in scopes,
             "profile must be in default extra scopes; got: #{inspect(scopes)}"

      assert "email" in scopes,
             "email must be in default extra scopes; got: #{inspect(scopes)}"

      refute "offline_access" in scopes,
             "online mode must not add offline_access; got: #{inspect(scopes)}"
    end

    test "empty string extra scopes + online mode → defaults to openid profile email" do
      set_extra_scopes("")
      set_mode("online")

      scopes = scope_params()

      assert "openid" in scopes
      assert "profile" in scopes
      assert "email" in scopes
      refute "offline_access" in scopes
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC11-2 — Custom scopes via seam → returns openid + custom scopes
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC11-2: custom extra scopes via seam" do
    test "extra scopes 'profile email groups' → scope includes groups" do
      # The seam must cause scope_list/0 to use custom scopes instead of @base_scopes.
      set_extra_scopes("profile email groups")
      set_mode("online")

      scopes = scope_params()

      assert "openid" in scopes
      assert "profile" in scopes
      assert "email" in scopes
      assert "groups" in scopes,
             "custom extra scope 'groups' must appear in scope list; got: #{inspect(scopes)}"

      refute "offline_access" in scopes
    end

    test "extra scopes 'profile email' → no groups" do
      set_extra_scopes("profile email")
      set_mode("online")

      scopes = scope_params()

      assert "openid" in scopes
      assert "profile" in scopes
      assert "email" in scopes
      refute "groups" in scopes
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC11-3 — Offline mode + extra scopes → includes offline_access
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC11-3: offline mode + extra scopes → offline_access appended" do
    test "offline mode with custom scopes includes offline_access" do
      set_extra_scopes("profile email groups")
      set_mode("offline")

      scopes = scope_params()

      assert "openid" in scopes
      assert "profile" in scopes
      assert "email" in scopes
      assert "groups" in scopes
      assert "offline_access" in scopes,
             "offline mode must include offline_access; got: #{inspect(scopes)}"
    end

    test "offline mode with nil extra scopes includes offline_access and defaults" do
      set_extra_scopes(nil)
      set_mode("offline")

      scopes = scope_params()

      assert "openid" in scopes
      assert "profile" in scopes
      assert "email" in scopes
      assert "offline_access" in scopes
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC11-4 — Duplicate scopes → de-duplicated
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC11-4: duplicate scopes in extra_scopes are de-duplicated" do
    test "extra scopes containing openid are not duplicated" do
      # The seam returns extra scopes that include openid (which is always added).
      # Result must contain exactly one "openid".
      set_extra_scopes("openid profile email")
      set_mode("online")

      scopes = scope_params()

      assert Enum.count(scopes, &(&1 == "openid")) == 1,
             "openid must appear exactly once even when duplicated in extra scopes; got: #{inspect(scopes)}"

      assert "profile" in scopes
      assert "email" in scopes
    end

    test "extra scopes with repeated tokens are de-duplicated" do
      set_extra_scopes("profile profile email email")
      set_mode("online")

      scopes = scope_params()

      assert Enum.count(scopes, &(&1 == "profile")) == 1,
             "profile must appear exactly once; got: #{inspect(scopes)}"

      assert Enum.count(scopes, &(&1 == "email")) == 1,
             "email must appear exactly once; got: #{inspect(scopes)}"
    end
  end
end
