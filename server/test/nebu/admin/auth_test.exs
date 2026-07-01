defmodule Nebu.Admin.AuthTest do
  @moduledoc """
  RED-phase ATDD tests for story `oidc-scopes-configurable`, AC5 + AC11 (admin side).

  ## What is under test

  After this story `admin_oidc_scope/0` in `Nebu.Admin.Auth` must:

    1. Read `admin_oidc_extra_scopes` from `server_config` (via the
       `:admin_oidc_extra_scopes_reader` seam — mirrors `:admin_oidc_refresh_mode_reader`).
    2. Always include `"openid"` (OIDC-mandatory).
    3. Append the extra scopes from server_config (default `""` if NULL/empty —
       OIDC Scopes Law: only "openid").
    4. Add `"offline_access"` only if `admin_refresh_mode() == "offline"`.
    5. Return space-separated, de-duplicated, filtered string.

  TODAY `admin_oidc_scope/0` hardcodes `"openid profile email groups"` and does NOT
  consult `server_config` for extra scopes. The `:admin_oidc_extra_scopes_reader` seam
  does NOT exist yet. All tests below are RED until the seam + runtime read is added.

  ## Public surface (no testing of privates)

  `admin_oidc_scope/0` is `defp`. We assert via the observable result: the `scope`
  query-param of the 302 redirect that `Auth.login_start/2` builds toward the IdP —
  same pattern as `admin_scope_mode_test.exs` and `admin_bootstrap_groups_scope_test.exs`.

  ## Test seam

  `:admin_oidc_extra_scopes_reader` — a 0-arity fun injected via Application.put_env.
  Returns a string of space-separated extra scopes (beyond `openid`), or `nil`/`""` to
  trigger the default `"profile email groups"` fallback.

  ## Crash/restart — NOT APPLICABLE

  Pure config read on the request process (Persistenz Option C — stateless).
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Nebu.Admin.Auth

  @issuer "https://dex.example.com/dex"
  @authorization_endpoint "https://dex.example.com/dex/auth"
  @token_endpoint "https://dex.example.com/dex/token"
  @client_id "nebu-admin"

  setup do
    Nebu.Web.OidcTestSupport.configure(@issuer, @client_id)
    Application.put_env(:nebu_http, :admin_secret_at_rest, "admin-auth-extra-scopes-test-key")

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

    # Pin online mode by default so offline_access is absent.
    Application.put_env(:nebu_http, :admin_oidc_refresh_mode_reader, fn -> "online" end)

    on_exit(fn ->
      Nebu.Web.OidcTestSupport.clear()

      for k <- [
            :admin_secret_at_rest,
            :admin_oidc_config_reader,
            :server_name,
            :admin_session_secure,
            :oidc_metadata_override,
            :admin_oidc_refresh_mode_reader,
            :admin_oidc_extra_scopes_reader
          ] do
        Application.delete_env(:nebu_http, k)
      end
    end)

    :ok
  end

  defp set_mode(mode),
    do: Application.put_env(:nebu_http, :admin_oidc_refresh_mode_reader, fn -> mode end)

  defp set_extra_scopes(scopes),
    do: Application.put_env(:nebu_http, :admin_oidc_extra_scopes_reader, fn -> scopes end)

  defp scope_params do
    conn =
      conn(:get, "/admin/login/start")
      |> init_test_session(%{})
      |> Auth.login_start(%{})

    assert conn.status == 302
    [loc] = get_resp_header(conn, "location")
    assert String.starts_with?(loc, @authorization_endpoint <> "?")

    %URI{query: q} = URI.parse(loc)
    URI.decode_query(q)["scope"] |> String.split(" ", trim: true)
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC11-5 — No extra scopes → returns "openid" only (OIDC Scopes Law: default is ONLY openid)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC11-5: no extra scopes configured → openid only (OIDC Scopes Law)" do
    test "nil extra scopes + online mode → openid only, no profile/email/groups/offline_access" do
      # OIDC Scopes Law: default scope is ONLY "openid". No fallback to "profile email groups".
      # bugfix-remove-default-scopes: @default_admin_extra_scopes must be "" not "profile email groups".
      set_extra_scopes(nil)
      set_mode("online")

      scopes = scope_params()

      assert "openid" in scopes,
             "openid must always be present; got: #{inspect(scopes)}"

      refute "profile" in scopes,
             "profile must NOT be in default scopes (OIDC Scopes Law violation); got: #{inspect(scopes)}"

      refute "email" in scopes,
             "email must NOT be in default scopes (OIDC Scopes Law violation); got: #{inspect(scopes)}"

      refute "groups" in scopes,
             "groups must NOT be in default scopes (OIDC Scopes Law violation); got: #{inspect(scopes)}"

      refute "offline_access" in scopes,
             "online mode must not add offline_access; got: #{inspect(scopes)}"
    end

    test "empty string extra scopes + online mode → openid only, no fallback to profile email groups" do
      # OIDC Scopes Law: empty string means no extra scopes — do not fall back to defaults.
      set_extra_scopes("")
      set_mode("online")

      scopes = scope_params()

      assert "openid" in scopes
      refute "profile" in scopes
      refute "email" in scopes
      refute "groups" in scopes
      refute "offline_access" in scopes
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC11-6 — Custom scopes via seam (groups removed) → openid profile email
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC11-6: custom extra scopes override the admin default" do
    test "extra scopes 'profile email' (no groups) → scope omits groups" do
      # When the operator explicitly configures scopes without 'groups', it must
      # not be injected automatically.
      set_extra_scopes("profile email")
      set_mode("online")

      scopes = scope_params()

      assert "openid" in scopes
      assert "profile" in scopes
      assert "email" in scopes

      refute "groups" in scopes,
             "groups must NOT appear when not in custom extra scopes; got: #{inspect(scopes)}"

      refute "offline_access" in scopes
    end

    test "extra scopes 'profile email groups' with online mode → openid profile email groups" do
      set_extra_scopes("profile email groups")
      set_mode("online")

      scopes = scope_params()

      assert "openid" in scopes
      assert "profile" in scopes
      assert "email" in scopes
      assert "groups" in scopes
      refute "offline_access" in scopes
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC11-7 — Offline mode + extra scopes → includes offline_access
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC11-7: offline mode + extra scopes → offline_access appended" do
    test "offline mode with custom extra scopes includes offline_access" do
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

    test "offline mode with nil extra scopes → openid + offline_access only (no defaults)" do
      # OIDC Scopes Law: nil extra scopes must NOT fall back to "profile email groups".
      # Only "openid" + "offline_access" for offline mode when no custom scopes set.
      set_extra_scopes(nil)
      set_mode("offline")

      scopes = scope_params()

      assert "openid" in scopes
      refute "profile" in scopes
      refute "email" in scopes
      refute "groups" in scopes
      assert "offline_access" in scopes
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC11-8 — Duplicate openid in extra scopes → de-duplicated
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC11-8: duplicate openid in extra scopes is de-duplicated" do
    test "extra scopes containing openid → exactly one openid in result" do
      set_extra_scopes("openid profile email groups")
      set_mode("online")

      scopes = scope_params()

      assert Enum.count(scopes, &(&1 == "openid")) == 1,
             "openid must appear exactly once; got: #{inspect(scopes)}"

      assert "profile" in scopes
      assert "email" in scopes
      assert "groups" in scopes
    end

    test "extra scopes with repeated groups → groups appears exactly once" do
      set_extra_scopes("profile email groups groups")
      set_mode("online")

      scopes = scope_params()

      assert Enum.count(scopes, &(&1 == "groups")) == 1,
             "groups must appear exactly once; got: #{inspect(scopes)}"
    end
  end
end
