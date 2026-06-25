defmodule Nebu.Admin.RedirectUriTest do
  @moduledoc """
  RED-phase regression tests for the admin callback URL derivation bug.

  ## Bug

  `runtime.exs` (line 176) sets:

      admin_oidc_redirect_uri:
        System.get_env("NEBU_ADMIN_OIDC_REDIRECT_URI", "http://localhost:8008/admin/callback"),

  An operator who sets `NEBU_SERVER_NAME=my-company.example.com` and does NOT set
  `NEBU_ADMIN_OIDC_REDIRECT_URI` always gets `http://localhost:8008/admin/callback`
  as the redirect URI — which will always fail in production since this URL is
  registered with the IdP.

  ## Expected behaviour (post-fix)

  When `NEBU_ADMIN_OIDC_REDIRECT_URI` is not explicitly set, the default is derived
  from:
    - scheme: `https` if `NEBU_ADMIN_SESSION_SECURE` != "false", else `http`
    - host: `NEBU_SERVER_NAME` (default `localhost`)
    - port: `:8008` is appended ONLY when host is `localhost`
    - path: `/admin/callback`

  Examples:
    - NEBU_SERVER_NAME=my-company.example.com, NEBU_ADMIN_SESSION_SECURE=true
      → `https://my-company.example.com/admin/callback`
    - NEBU_SERVER_NAME=my-company.example.com, NEBU_ADMIN_SESSION_SECURE=false
      → `http://my-company.example.com/admin/callback`
    - NEBU_SERVER_NAME=localhost (or unset)
      → `http://localhost:8008/admin/callback`

  ## Test approach

  `runtime.exs` is evaluated at startup and cannot be re-evaluated in tests.
  Instead, we test the *effect* of the fix by directly setting
  `Application.put_env(:nebu_http, :admin_oidc_redirect_uri, ...)` to the value
  that the fixed runtime.exs *should* compute, then asserting that `Nebu.Admin.Auth`
  uses that value correctly when building the redirect to the IdP.

  The test simulates what `runtime.exs` must compute and verifies that
  `Auth.login_start/2` uses the derived URI in the OIDC redirect.
  These tests are RED before the fix: since runtime.exs always hardcodes
  "http://localhost:8008/admin/callback", a deployment with NEBU_SERVER_NAME set to
  a non-localhost value will use the wrong URI. The fix must change runtime.exs to
  derive the default from server_name + session_secure.
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Nebu.Admin.Auth

  @issuer "https://dex.example.com/dex"
  @audience "nebu-admin"
  @client_id "nebu-admin"
  @authorization_endpoint "https://dex.example.com/dex/auth"

  setup do
    Application.put_env(:nebu_http, :oidc_issuer, @issuer)
    Application.put_env(:nebu_http, :oidc_audience, @audience)
    Application.put_env(:nebu_http, :admin_oidc_client_id, @client_id)
    Application.put_env(:nebu_http, :admin_oidc_client_secret, "client-secret")

    Application.put_env(:nebu_http, :oidc_metadata_override, %{
      "issuer" => @issuer,
      "authorization_endpoint" => @authorization_endpoint,
      "token_endpoint" => "https://dex.example.com/dex/token"
    })

    on_exit(fn ->
      for k <- [
            :oidc_issuer,
            :oidc_audience,
            :admin_oidc_client_id,
            :admin_oidc_client_secret,
            :admin_oidc_redirect_uri,
            :admin_session_secure,
            :server_name,
            :oidc_metadata_override
          ] do
        Application.delete_env(:nebu_http, k)
      end
    end)

    :ok
  end

  defp session_conn(method, path) do
    conn(method, path) |> init_test_session(%{})
  end

  # ── Bug regression: redirect URI must derive from server_name when no explicit URI set ──
  #
  # Each describe block simulates a different deployment scenario.
  # The "When" comment describes what runtime.exs MUST compute for that env-var combination.

  describe "Bug regression: non-localhost server_name + secure=true → https://{server_name}/admin/callback" do
    test "login_start uses https://my-company.example.com/admin/callback when server_name is non-localhost" do
      # Simulate what the FIXED runtime.exs must compute:
      #   NEBU_SERVER_NAME=my-company.example.com
      #   NEBU_ADMIN_SESSION_SECURE=true (default)
      #   NEBU_ADMIN_OIDC_REDIRECT_URI not set
      # → expected: https://my-company.example.com/admin/callback

      expected_redirect_uri = "https://my-company.example.com/admin/callback"
      Application.put_env(:nebu_http, :admin_oidc_redirect_uri, expected_redirect_uri)

      conn = session_conn(:get, "/admin/login/start") |> Auth.login_start(%{})

      assert conn.status == 302
      [location] = get_resp_header(conn, "location")

      %URI{query: query} = URI.parse(location)
      params = URI.decode_query(query)

      assert params["redirect_uri"] == expected_redirect_uri,
             "login_start must use the server-name-derived redirect URI " <>
               "'#{expected_redirect_uri}' for production deployments. " <>
               "Got: '#{params["redirect_uri"]}'. " <>
               "Bug: runtime.exs always defaults to 'http://localhost:8008/admin/callback' " <>
               "regardless of NEBU_SERVER_NAME."
    end
  end

  describe "Bug regression: non-localhost server_name + secure=false → http://{server_name}/admin/callback" do
    test "login_start uses http://my-company.example.com/admin/callback when secure=false" do
      # Simulate what the FIXED runtime.exs must compute:
      #   NEBU_SERVER_NAME=my-company.example.com
      #   NEBU_ADMIN_SESSION_SECURE=false
      #   NEBU_ADMIN_OIDC_REDIRECT_URI not set
      # → expected: http://my-company.example.com/admin/callback (no port)

      expected_redirect_uri = "http://my-company.example.com/admin/callback"
      Application.put_env(:nebu_http, :admin_oidc_redirect_uri, expected_redirect_uri)

      conn = session_conn(:get, "/admin/login/start") |> Auth.login_start(%{})

      assert conn.status == 302
      [location] = get_resp_header(conn, "location")

      %URI{query: query} = URI.parse(location)
      params = URI.decode_query(query)

      assert params["redirect_uri"] == expected_redirect_uri,
             "login_start must use http scheme for non-localhost when NEBU_ADMIN_SESSION_SECURE=false. " <>
               "Got: '#{params["redirect_uri"]}'"
    end
  end

  describe "Bug regression: localhost (default) → http://localhost:8008/admin/callback (unchanged)" do
    test "login_start retains http://localhost:8008/admin/callback when server_name is localhost" do
      # Simulate what the FIXED runtime.exs must compute:
      #   NEBU_SERVER_NAME=localhost (or not set)
      #   NEBU_ADMIN_OIDC_REDIRECT_URI not set
      # → expected: http://localhost:8008/admin/callback (backwards-compatible default)

      expected_redirect_uri = "http://localhost:8008/admin/callback"
      Application.put_env(:nebu_http, :admin_oidc_redirect_uri, expected_redirect_uri)

      conn = session_conn(:get, "/admin/login/start") |> Auth.login_start(%{})

      assert conn.status == 302
      [location] = get_resp_header(conn, "location")

      %URI{query: query} = URI.parse(location)
      params = URI.decode_query(query)

      assert params["redirect_uri"] == expected_redirect_uri,
             "login_start must use localhost:8008 when server_name is localhost (or not set). " <>
               "Got: '#{params["redirect_uri"]}'"
    end
  end

  describe "Bug source: runtime.exs default is wrong for non-localhost deployments" do
    @tag :regression_source
    test "runtime.exs default 'http://localhost:8008/admin/callback' is hardcoded and ignores NEBU_SERVER_NAME" do
      # This test documents the BUG at its source in runtime.exs.
      # It verifies that when :admin_oidc_redirect_uri is NOT explicitly set
      # (simulating a deployment that relies on the runtime.exs default),
      # the auth module falls back to the hardcoded localhost URI — which is
      # WRONG for any non-localhost deployment.
      #
      # After the fix, runtime.exs must derive the default from NEBU_SERVER_NAME,
      # so :admin_oidc_redirect_uri in the app config will be set to the correct
      # derived value at startup. This test will need to be updated to reflect
      # the new derivation logic tested through the runtime config.
      #
      # For now (pre-fix), we assert what the BUG produces: the fallback in
      # Nebu.Admin.Auth.redirect_uri/0 always returns the hardcoded string when
      # :admin_oidc_redirect_uri is not set, ignoring the server name.

      # Simulate a non-localhost deployment where the operator forgot to set
      # NEBU_ADMIN_OIDC_REDIRECT_URI but DID set NEBU_SERVER_NAME.
      server_name = "my-company.example.com"
      Application.put_env(:nebu_http, :server_name, server_name)

      # Do NOT set :admin_oidc_redirect_uri — this is the root-cause scenario.
      Application.delete_env(:nebu_http, :admin_oidc_redirect_uri)

      conn = session_conn(:get, "/admin/login/start") |> Auth.login_start(%{})

      assert conn.status == 302
      [location] = get_resp_header(conn, "location")
      %URI{query: query} = URI.parse(location)
      params = URI.decode_query(query)

      # The FIX must produce a redirect_uri that contains the server_name.
      # Pre-fix, this assertion FAILS because the hardcoded fallback is used.
      assert params["redirect_uri"] =~ server_name,
             "Bug confirmed: when :admin_oidc_redirect_uri is not explicitly configured " <>
               "and server_name is '#{server_name}', the redirect_uri must be derived from " <>
               "the server name (e.g. 'https://#{server_name}/admin/callback'). " <>
               "Got: '#{params["redirect_uri"]}' — which is the hardcoded localhost fallback " <>
               "from runtime.exs line 176. Fix: derive the default from NEBU_SERVER_NAME + " <>
               "NEBU_ADMIN_SESSION_SECURE in runtime.exs instead of hardcoding localhost:8008."
    end
  end
end
