defmodule Nebu.OAuth.OAuthOpenidConfigurationTest do
  @moduledoc """
  RED-phase acceptance tests for story `oauth-token-endpoint`, AC21 / T31 (oracle C7 BLOCKER) and
  the issuer-path rule of AC18 (Must #34): `GET /.well-known/openid-configuration` under the
  issuer serves Nebu's OWN metadata document (exactly `Metadata.build/1`, the same JSON as
  `GET /_matrix/client/v1/auth_metadata`, incl. `jwks_uri`), because matrix-js-sdk's
  `OidcTokenRefresher` fetches `new URL(".well-known/openid-configuration", issuer)` before every
  refresh. Relative URL resolution drops the issuer's last path segment, so an issuer WITH a path
  is rejected by `Metadata.normalize_issuer/1` (fail closed: 404 on every OAuth endpoint).

  No DB (config seam); the IdP discovery override carries distinctive URLs that must never appear.

  Red today: no `/.well-known/openid-configuration` route (router plain 404), `normalize_issuer/1`
  accepts a path, the metadata has no `jwks_uri`.
  """
  use ExUnit.Case, async: false

  alias Nebu.OAuth.TestSupport, as: T

  @path "/.well-known/openid-configuration"
  @idp_marker "idp-only-marker.example.org"

  setup do
    T.enable_oauth()
    T.reset_rate_limits()

    # A distinctive IdP discovery document: nothing of it may ever reach Nebu's document.
    Nebu.Web.OidcTestSupport.configure("https://#{@idp_marker}/realms/corp", "nebu-client")

    Application.put_env(:nebu_http, :oidc_metadata_override, %{
      "issuer" => "https://#{@idp_marker}/realms/corp",
      "authorization_endpoint" => "https://#{@idp_marker}/auth",
      "token_endpoint" => "https://#{@idp_marker}/token",
      "jwks_uri" => "https://#{@idp_marker}/jwks",
      "userinfo_endpoint" => "https://#{@idp_marker}/userinfo"
    })

    on_exit(fn ->
      T.clear_oauth_config()
      T.restore_rate_limits()
      Nebu.Web.OidcTestSupport.clear()
      Application.delete_env(:nebu_http, :oidc_metadata_override)
      Application.delete_env(:nebu_http, :oauth_repo)
    end)

    :ok
  end

  describe "AC21 — OAuth live: Nebu's own document" do
    test "200, byte-identical to GET /_matrix/client/v1/auth_metadata, incl. jwks_uri and ES256" do
      conn = T.get(@path)
      assert conn.status == 200, "got #{conn.status}: #{String.slice(conn.resp_body || "", 0, 200)}"
      meta = T.get_metadata()
      assert meta.status == 200

      assert T.json(conn) == T.json(meta)
      assert conn.resp_body == meta.resp_body, "byte-identical JSON (same Metadata.build/1 encoding)"

      body = T.json(conn)
      assert body["issuer"] == T.issuer()
      assert body["jwks_uri"] == T.issuer() <> "/oauth2/jwks"
      assert body["id_token_signing_alg_values_supported"] == ["ES256"]
      assert body["token_endpoint"] == T.issuer() <> "/oauth2/token"
    end

    test "headers: JSON, the metadata Cache-Control, ACAO *, no Allow-Credentials" do
      conn = T.get(@path, origin: "https://client.example.com")
      assert conn.status == 200
      assert (T.header(conn, "content-type") || "") =~ ~r{^application/json}
      assert T.header(conn, "cache-control") == "public, max-age=259200"
      assert T.header(conn, "access-control-allow-origin") == "*"
      assert T.header(conn, "access-control-allow-credentials") == nil
    end

    test "never the IdP document (no Nebu.Matrix.OidcMetadata passthrough, no IdP field)" do
      conn = T.get(@path)
      assert conn.status == 200
      refute conn.resp_body =~ @idp_marker
      refute Map.has_key?(T.json(conn), "userinfo_endpoint")
    end

    test "issuer resolution as matrix-js-sdk does it (new URL(\".well-known/openid-configuration\", issuer)) hits this route" do
      issuer = T.json(T.get_metadata())["issuer"]
      resolved = URI.merge(URI.parse(issuer), ".well-known/openid-configuration")
      assert resolved.path == @path
      assert resolved.host == URI.parse(issuer).host

      conn = T.get(resolved.path)
      assert conn.status == 200
      assert T.json(conn)["issuer"] == issuer, "issuer byte-equal to auth_metadata (and to the id_token iss)"
    end

    test "why a path is forbidden: resolution DROPS the issuer's last path segment" do
      assert URI.merge(URI.parse("https://nebu.example.com/nebu"), ".well-known/openid-configuration") |> to_string() ==
               "https://nebu.example.com/.well-known/openid-configuration"
    end

    test "POST => 405 (GET only); sub-path => 404 M_UNRECOGNIZED" do
      conn =
        Plug.Test.conn(:post, @path, "")
        |> Map.put(:remote_ip, T.unique_ip())
        |> Nebu.Web.Router.call(Nebu.Web.Router.init([]))

      assert conn.status == 405, "got #{conn.status}"
      # test review (5): exact AC21 405 shape (same as /oauth2/jwks)
      assert T.header(conn, "allow") == "GET, OPTIONS"
      assert T.json(conn) == %{"error" => "invalid_request", "error_description" => "Method not allowed."}

      T.get(@path <> "/x") |> T.assert_unrecognized_404_no_error()
    end

    test "OPTIONS preflight is answered by CORSPlug (no endpoint logic, no DB)" do
      Application.put_env(:nebu_http, :oauth_repo, T.NoSuchRepo)
      conn = T.options(@path, request_method: "GET")
      assert conn.status in [200, 204]
      assert T.header(conn, "access-control-allow-origin") == "*"
    end
  end

  describe "AC21 — kill switch" do
    test "disabled => 404 M_UNRECOGNIZED (never the IdP document)" do
      T.disable_oauth()
      conn = T.get(@path) |> T.assert_unrecognized_404_no_error()
      refute conn.resp_body =~ @idp_marker
    end

    test "invalid issuer (http) => 404 M_UNRECOGNIZED" do
      T.enable_oauth("http://nebu.example.com")
      T.get(@path) |> T.assert_unrecognized_404_no_error()
    end

    test ":unknown (server_config unreadable) => 503 {} + Retry-After" do
      T.unreadable_oauth_config()
      conn = T.get(@path) |> T.assert_5xx_empty(503)
      refute conn.resp_body =~ @idp_marker
    end
  end

  describe "AC18/T31 — the issuer must have an empty path" do
    test "normalize_issuer/1: host and host/ are accepted (slash stripped); any path is rejected" do
      assert Nebu.OAuth.Metadata.normalize_issuer("https://nebu.example.com") == {:ok, "https://nebu.example.com"}
      assert Nebu.OAuth.Metadata.normalize_issuer("https://nebu.example.com/") == {:ok, "https://nebu.example.com"}
      assert Nebu.OAuth.Metadata.normalize_issuer("https://nebu.example.com/nebu") == :error
      assert Nebu.OAuth.Metadata.normalize_issuer("https://nebu.example.com/a/b") == :error
      assert Nebu.OAuth.Metadata.normalize_issuer("https://nebu.example.com/nebu/") == :error
    end

    test "issuer with a trailing slash: documents served, issuer stripped" do
      T.enable_oauth("https://nebu.example.com/")
      assert T.json(T.get_metadata())["issuer"] == "https://nebu.example.com"
      conn = T.get(@path)
      assert conn.status == 200
      assert T.json(conn)["issuer"] == "https://nebu.example.com"
      assert T.json(conn)["jwks_uri"] == "https://nebu.example.com/oauth2/jwks"
    end

    test "issuer https://nebu.example.com/nebu => 404 M_UNRECOGNIZED on metadata, authorize, token, jwks and openid-configuration" do
      T.enable_oauth("https://nebu.example.com/nebu")
      Application.put_env(:nebu_http, :oauth_repo, T.NoSuchRepo)

      responses = [
        auth_metadata: T.get_metadata(),
        authorize: T.authorize(T.authorize_params("some-client", "https://app.example.com/cb")),
        token: T.token_request([{"grant_type", "refresh_token"}, {"refresh_token", String.duplicate("a", 64)}, {"client_id", "c"}]),
        jwks: T.jwks(),
        openid_configuration: T.get(@path)
      ]

      for {name, conn} <- responses do
        assert conn.status == 404, "#{name}: expected 404, got #{conn.status}"
        assert T.json(conn)["errcode"] == "M_UNRECOGNIZED", "#{name}: Matrix 404 shape expected"

        # review cycle 1 (MINOR 1): the three story-3 endpoints carry NO `error` member (a refreshing
        # oidc-client-ts would treat it as a logout); the older endpoints keep theirs.
        if name in [:token, :jwks, :openid_configuration],
          do: refute(Map.has_key?(T.json(conn), "error"), "#{name}: no `error` member in the kill-switch 404"),
          else: assert(is_binary(T.json(conn)["error"]), "#{name}: unchanged Matrix 404 body")

        refute conn.resp_body =~ "nebu.example.com/nebu", "#{name}: the invalid issuer is never echoed"
      end
    end
  end
end
