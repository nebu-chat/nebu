defmodule Nebu.OAuth.OAuthDiscoveryRateLimitTest do
  @moduledoc """
  Acceptance tests for story `oauth-hardening-hygiene`, AC3 (HY3): per-source limits ONLY
  where the Matrix spec allows a 429.

    * `GET /_matrix/client/v3/login` ("Rate-limited: Yes"): own bucket `{"login_flows", ClientIP.bucket(conn)}`,
      300 per minute, burst 300, Matrix `429 M_LIMIT_EXCEEDED` + `retry_after_ms` + `Retry-After`.
    * live `GET /.well-known/openid-configuration`: own bucket `{"oauth_openid_configuration", bucket}`,
      600 per minute, burst 600, the JWKS 429 shape (`too_many_requests`, CORS, `Retry-After`).
      The disabled branch (404) takes no token.
    * `auth_metadata`, `auth_issuer`, the unstable aliases and `/versions` ("Rate-limited: No" / the load
      balancer health check) NEVER answer 429.
    * `NEBU_RATE_LIMIT_DISABLED` semantics (`:rate_limit_disabled`) switch all of it off.

  The limiter clock is frozen (`T.reset_rate_limits/0`), so a bucket never refills during a test.
  The buckets are own `RateLimit.take/3` keys, never the plug's bare-IP key shared by `POST /login`
  and `/refresh` (30 per minute, burst 10).
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  import Plug.Test
  alias Nebu.OAuth.TestSupport, as: T

  @router_opts Nebu.Web.Router.init([])

  setup do
    T.enable_oauth()
    T.reset_rate_limits()
    T.setup_idp!()

    on_exit(fn ->
      T.clear_oauth_config()
      T.restore_rate_limits()
    end)

    :ok
  end

  defp post_login(ip) do
    conn(:post, "/_matrix/client/v3/login", Jason.encode!(%{"type" => "m.login.token", "token" => "junk"}))
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Map.put(:remote_ip, ip)
    |> Nebu.Web.Router.call(@router_opts)
  end

  describe "AC3.1 — GET /_matrix/client/v3/login" do
    test "an exhausted {\"login_flows\", source} bucket => 429 M_LIMIT_EXCEEDED + retry_after_ms + Retry-After" do
      ip = T.unique_ip()
      T.drain!("login_flows", ip, 300, 300)

      conn = T.login_flows(ip: ip)
      assert conn.status == 429
      body = T.json(conn)
      assert body["errcode"] == "M_LIMIT_EXCEEDED"
      assert is_binary(body["error"])
      assert is_integer(body["retry_after_ms"]) and body["retry_after_ms"] > 0
      assert {secs, ""} = Integer.parse(T.header(conn, "retry-after") || "")
      assert secs > 0
    end

    test "burst 300: the 300th request answers, the 301st is limited" do
      ip = T.unique_ip()
      T.drain!("login_flows", ip, 300, 300, 1)
      assert T.login_flows(ip: ip).status == 200
      assert T.login_flows(ip: ip).status == 429
    end

    test "another source is unaffected" do
      ip = T.unique_ip()
      T.drain!("login_flows", ip, 300, 300)
      assert T.login_flows(ip: ip).status == 429
      assert T.login_flows(ip: T.unique_ip()).status == 200
    end

    test "the bucket is keyed by the resolved client (ClientIP.bucket/1), not by a header the client controls" do
      ip = T.unique_ip()
      T.drain!("login_flows", ip, 300, 300)
      # without a trusted-proxy configuration X-Forwarded-For is ignored: the peer's bucket is still empty
      assert T.login_flows(ip: ip, xff: "203.0.113.77").status == 429
    end

    test "the bucket is NOT shared with POST /login: draining GET leaves POST answered, and vice versa" do
      ip = T.unique_ip()
      T.drain!("login_flows", ip, 300, 300)
      assert T.login_flows(ip: ip).status == 429
      refute post_login(ip).status == 429, "POST /login has its own (bare client key) bucket"

      other = T.unique_ip()
      # drain the plug's bare-IP bucket of POST /login (30 per minute, burst 10)
      for _ <- 1..10, do: Nebu.Web.Plugs.RateLimit.take(T.ip_string(other), 30, 10)
      assert post_login(other).status == 429
      assert T.login_flows(ip: other).status == 200, "GET /login must not be limited by the POST /login bucket"
    end

    test "the legacy-compatible flow list still answers 200 for a fresh source" do
      conn = T.login_flows()
      assert conn.status == 200
      assert is_list(T.json(conn)["flows"])
    end
  end

  describe "AC3.2 — live GET /.well-known/openid-configuration" do
    test "an exhausted {\"oauth_openid_configuration\", source} bucket => 429 too_many_requests + CORS + Retry-After" do
      ip = T.unique_ip()
      T.drain!("oauth_openid_configuration", ip, 600, 600)

      conn = T.get("/.well-known/openid-configuration", ip: ip, origin: "https://client.example.com")
      assert conn.status == 429
      assert T.json(conn)["error"] == "too_many_requests"
      refute Map.has_key?(T.json(conn), "errcode"), "the OAuth error shape (RFC 6749), no Matrix errcode"
      assert T.header(conn, "access-control-allow-origin") == "*"
      assert {secs, ""} = Integer.parse(T.header(conn, "retry-after") || "")
      assert secs > 0

      assert T.get("/.well-known/openid-configuration", ip: T.unique_ip()).status == 200, "other sources are unaffected"
    end

    test "burst 600: the 600th request answers, the 601st is limited" do
      ip = T.unique_ip()
      T.drain!("oauth_openid_configuration", ip, 600, 600, 1)
      assert T.get("/.well-known/openid-configuration", ip: ip).status == 200
      assert T.get("/.well-known/openid-configuration", ip: ip).status == 429
    end

    test "the disabled branch answers the unchanged 404 and takes NO token" do
      ip = T.unique_ip()
      T.disable_oauth()

      for _ <- 1..650 do
        T.get("/.well-known/openid-configuration", ip: ip) |> T.assert_unrecognized_404_no_error()
      end

      T.enable_oauth()
      assert T.get("/.well-known/openid-configuration", ip: ip).status == 200, "650 disabled answers did not consume the bucket"
    end

    test "the JWKS bucket stays separate (a drained discovery bucket does not limit /oauth2/jwks)" do
      ip = T.unique_ip()
      T.drain!("oauth_openid_configuration", ip, 600, 600)
      refute T.jwks(ip: ip).status == 429
    end
  end

  describe "AC3.3 — spec-unlimited discovery paths never answer 429 (1 000 requests from one source)" do
    for {name, path} <- [
          {"auth_metadata", "/_matrix/client/v1/auth_metadata"},
          {"auth_issuer", "/_matrix/client/v1/auth_issuer"},
          {"unstable auth_metadata alias", "/_matrix/client/unstable/org.matrix.msc2965/auth_metadata"},
          {"unstable auth_issuer alias", "/_matrix/client/unstable/org.matrix.msc2965/auth_issuer"},
          {"/versions", "/_matrix/client/versions"}
        ] do
      test "#{name}: 1 000 requests from one source, none is 429" do
        ip = T.unique_ip()

        statuses = for _ <- 1..1000, do: T.get(unquote(path), ip: ip).status
        refute 429 in statuses, "#{unquote(name)} must never be rate limited (spec: Rate-limited: No / health check)"
        assert Enum.all?(statuses, &(&1 == 200)), "expected only 200, got #{inspect(Enum.uniq(statuses))}"
      end
    end

    test "they take no token of the new buckets (the GET /login and openid buckets stay full)" do
      ip = T.unique_ip()
      for path <- ["/_matrix/client/v1/auth_metadata", "/_matrix/client/v1/auth_issuer", "/_matrix/client/versions"], _ <- 1..50, do: T.get(path, ip: ip)

      T.drain!("login_flows", ip, 300, 300, 1)
      assert T.login_flows(ip: ip).status == 200, "the login_flows bucket was still full before"
    end
  end

  describe "AC3.4 — NEBU_RATE_LIMIT_DISABLED semantics" do
    test "with the limiter disabled neither GET /login nor openid-configuration limits" do
      ip = T.unique_ip()
      T.drain!("login_flows", ip, 300, 300)
      T.drain!("oauth_openid_configuration", ip, 600, 600)
      Application.put_env(:nebu_http, :rate_limit_disabled, true)

      assert T.login_flows(ip: ip).status == 200
      assert T.get("/.well-known/openid-configuration", ip: ip).status == 200

      for _ <- 1..400, do: assert(T.login_flows(ip: ip).status == 200)
    end
  end

  # test review M7: the bucket follows the RESOLVED client (trusted proxy, IPv6 /64) and a preflight is free
  describe "AC3.5 — bucket keys follow the resolved client; a CORS preflight consumes no token" do
    setup do
      # the unique test peers are 10.x.x.x: trust them as a proxy for the XFF cases
      Nebu.Web.ClientIP.configure("10.0.0.0/8")
      on_exit(fn -> Nebu.Web.ClientIP.configure(nil) end)
      :ok
    end

    test "behind a trusted proxy GET /login is bucketed by the forwarded client, not by the proxy peer" do
      proxy = T.unique_ip()
      # the client behind the proxy has used its whole budget; the proxy peer's own bucket is untouched
      for _ <- 1..300, do: Nebu.Web.Plugs.RateLimit.take({"login_flows", "203.0.113.5"}, 300, 300)

      assert T.login_flows(ip: proxy, xff: "203.0.113.5").status == 429, "the forwarded client's bucket is empty"
      assert T.login_flows(ip: proxy, xff: "203.0.113.6").status == 200, "another client behind the same proxy is unaffected"
      assert T.login_flows(ip: proxy).status == 200, "a request without XFF is the proxy peer's own bucket"
    end

    test "behind a trusted proxy the live openid-configuration bucket follows the forwarded client too" do
      proxy = T.unique_ip()
      for _ <- 1..600, do: Nebu.Web.Plugs.RateLimit.take({"oauth_openid_configuration", "203.0.113.9"}, 600, 600)

      assert T.get("/.well-known/openid-configuration", ip: proxy, xff: "203.0.113.9").status == 429
      assert T.get("/.well-known/openid-configuration", ip: proxy, xff: "203.0.113.10").status == 200
    end

    test "IPv6: two addresses in one /64 share the GET /login bucket, another /64 does not" do
      a = {0x2001, 0xDB8, 1, 2, 0, 0, 0, 1}
      b = {0x2001, 0xDB8, 1, 2, 0xA, 0xB, 0xC, 0xD}
      other_net = {0x2001, 0xDB8, 1, 3, 0, 0, 0, 1}

      bucket = Nebu.Web.ClientIP.bucket_for(a)
      assert bucket == "2001:db8:1:2::/64"
      for _ <- 1..300, do: Nebu.Web.Plugs.RateLimit.take({"login_flows", bucket}, 300, 300)

      assert T.login_flows(ip: a).status == 429
      assert T.login_flows(ip: b).status == 429, "one routed /64 is one bucket"
      assert T.login_flows(ip: other_net).status == 200
    end

    test "an OPTIONS preflight on openid-configuration consumes no token and is never limited" do
      ip = T.unique_ip()
      T.drain!("oauth_openid_configuration", ip, 600, 600, 1)

      for _ <- 1..20 do
        conn = T.options("/.well-known/openid-configuration", ip: ip, request_method: "GET")
        refute conn.status == 429
      end

      assert T.get("/.well-known/openid-configuration", ip: ip).status == 200, "the last token was still there"
      assert T.get("/.well-known/openid-configuration", ip: ip).status == 429
    end
  end
end
