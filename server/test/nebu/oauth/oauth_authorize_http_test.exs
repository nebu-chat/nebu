defmodule Nebu.OAuth.OAuthAuthorizeHttpTest do
  @moduledoc """
  RED-phase acceptance tests for story `oauth-authorize-idp-delegation-code`, AC1-AC5, AC12-AC14
  through the FULL `Nebu.Web.Router` (`GET /oauth2/authorize`).

  * AC1 enablement / methods / sub-paths / token routed + revoke live (story 4) — no DB (the disabled path must not
    touch the database: proven with the `:oauth_repo` NoSuchRepo seam).
  * AC2/AC3 pre-trust HTML pages, AC4/AC5 error redirects, AC13 headers, AC14 rate limit —
    `:integration` (fixture clients in `oauth_clients`).

  Red today: there is no `/oauth2/authorize` route (router `404 not found`).
  Crash/restart: no node-local state is involved before the IdP redirect except the abuse-only
  rate-limit bucket (D19); persistence/cluster safety is covered in `oauth_idp_delegation_test.exs`.
  """
  use ExUnit.Case, async: false

  alias Nebu.OAuth.TestSupport, as: T

  @https "https://app.example.com/cb"
  @loop_registered "http://localhost/cb"
  @loop "http://localhost:53682/cb"

  setup do
    T.enable_oauth()
    T.reset_rate_limits()

    on_exit(fn ->
      T.clear_oauth_config()
      T.restore_rate_limits()
      Application.delete_env(:nebu_http, :oauth_repo)
    end)

    :ok
  end

  defp no_db!, do: Application.put_env(:nebu_http, :oauth_repo, T.NoSuchRepo)
  defp valid(client_id \\ "some-client", uri \\ @https, o \\ %{}), do: T.authorize_params(client_id, uri, o)

  defp ip_string({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"

  # ════════════════════════════════════════════════════════════════════════════
  # AC1 — endpoint, enablement, methods (no DB)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC1 — fail closed: disabled / unknown config / invalid issuer => 404 M_UNRECOGNIZED" do
    test "OAuth disabled => 404 M_UNRECOGNIZED (JSON), without touching the DB" do
      T.disable_oauth()
      no_db!()
      T.authorize(valid()) |> T.assert_unrecognized_404()
    end

    test "unreadable config (:unknown) => 404 M_UNRECOGNIZED" do
      T.unreadable_oauth_config()
      no_db!()
      T.authorize(valid()) |> T.assert_unrecognized_404()
    end

    for bad <- ["http://nebu.example.com", "https://nebu.example.com?x=1", "https://user@nebu.example.com", "nebu.example.com", ""] do
      test "issuer #{inspect(bad)} that normalize_issuer/1 rejects => 404 M_UNRECOGNIZED" do
        T.enable_oauth(unquote(bad))
        no_db!()
        conn = T.authorize(valid()) |> T.assert_unrecognized_404()
        refute conn.resp_body =~ "nebu.example.com"
      end
    end

    test "sub-paths of /oauth2/authorize => 404 M_UNRECOGNIZED (enabled)" do
      no_db!()
      T.get("/oauth2/authorize/x") |> T.assert_unrecognized_404()
      T.get("/oauth2/authorize/x/y?client_id=a") |> T.assert_unrecognized_404()
    end
  end

  describe "AC1 — methods" do
    for method <- [:post, :put, :delete, :patch] do
      test "#{method} while enabled => 405, Allow: GET, HTML method_not_allowed page" do
        no_db!()
        conn = T.authorize(valid(), method: unquote(method))
        T.assert_page(conn, 405, "method_not_allowed")
        assert T.header(conn, "allow") == "GET"
      end
    end

    test "POST while disabled => 404 M_UNRECOGNIZED (not 405)" do
      T.disable_oauth()
      T.authorize(valid(), method: :post) |> T.assert_unrecognized_404()
    end
  end

  # story 3 (oauth-token-endpoint, Trap 13): changed deliberately. Story 2 asserted that BOTH
  # /oauth2/token and /oauth2/revoke are the router's plain 404; story 3 routes /oauth2/token
  # (AC1), so only /oauth2/revoke keeps the plain 404 (story 4) and /oauth2/token is asserted to be
  # routed (token behaviour itself: oauth_token_http_test.exs).
  #
  # story 4 (oauth-token-revocation-logout, AC11 / R23 / Trap 7): changed deliberately again. The
  # story-2/3 assertion "/oauth2/revoke is the router's plain 404" became wrong by design: revoke is
  # routed and LIVE also while OAuth is disabled (R13, oracle O5; no kill switch), only an
  # unreadable config answers 503 {}. Revoke behaviour itself: oauth_revoke_http_test.exs.
  describe "AC1/D21 — /oauth2/revoke is routed and live (story 4); /oauth2/token is routed (story 3)" do
    for enabled <- [true, false] do
      test "/oauth2/revoke (oauth enabled=#{enabled}) is routed: GET => 405, POST malformed token => 200 {} (never the plain 404)" do
        if unquote(enabled), do: T.enable_oauth(), else: T.disable_oauth()

        get = T.get("/oauth2/revoke")
        refute get.resp_body == "not found"
        assert get.status == 405

        post =
          Plug.Test.conn(:post, "/oauth2/revoke", "token=x")
          |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
          |> Map.put(:remote_ip, T.unique_ip())
          |> Nebu.Web.Router.call(Nebu.Web.Router.init([]))

        T.assert_revoke_ok(post)
      end
    end

    test "/oauth2/revoke with an unreadable config => 503 {} (the only non-live state, R13)" do
      T.unreadable_oauth_config()
      T.revoke(T.revoke_params("x")) |> T.assert_revoke_5xx(503)
    end

    test "/oauth2/token while enabled is ROUTED: a body-less POST is not the router's plain \"not found\"" do
      no_db!()
      conn = Plug.Test.conn(:post, "/oauth2/token", "") |> Nebu.Web.Router.call(Nebu.Web.Router.init([]))
      refute conn.resp_body == "not found", "story 3 routes /oauth2/token (AC1)"
      refute conn.status == 404
    end

    test "/oauth2/token while disabled => 404 M_UNRECOGNIZED (the OAuth kill switch, not the plain 404)" do
      T.disable_oauth()
      Plug.Test.conn(:post, "/oauth2/token", "grant_type=authorization_code") |> Nebu.Web.Router.call(Nebu.Web.Router.init([])) |> T.assert_unrecognized_404_no_error()
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC14 — rate limiting (before any DB lookup)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC14/D19 — authorize bucket {\"oauth_authorize\", ip}: 600 per IP, charged before the DB" do
    test "an exhausted bucket => 429 HTML page + Retry-After, no DB access, no redirect" do
      ip = T.unique_ip()
      for _ <- 1..600, do: Nebu.Web.Plugs.RateLimit.take({"oauth_authorize", ip_string(ip)}, 10, 600)
      no_db!()

      conn = T.authorize(valid(), ip: ip)
      T.assert_page(conn, 429, "rate_limited")
      assert {secs, ""} = Integer.parse(T.header(conn, "retry-after") || "")
      assert secs > 0
    end

    test "every request pays exactly one token (the 600th passes, the 601st is limited); other IPs are unaffected" do
      ip = T.unique_ip()
      for _ <- 1..599, do: Nebu.Web.Plugs.RateLimit.take({"oauth_authorize", ip_string(ip)}, 10, 600)
      no_db!()

      # missing client_id: answered without a DB lookup, but it still pays the bucket
      first = T.authorize([{"response_type", "code"}], ip: ip)
      refute first.status == 429
      T.assert_page(T.authorize([{"response_type", "code"}], ip: ip), 429, "rate_limited")
      refute T.authorize([{"response_type", "code"}], ip: T.unique_ip()).status == 429
    end

    test "the disabled 404 path does NOT charge the authorize bucket (AC1 decision)" do
      ip = T.unique_ip()
      for _ <- 1..599, do: Nebu.Web.Plugs.RateLimit.take({"oauth_authorize", ip_string(ip)}, 10, 600)
      no_db!()
      T.disable_oauth()
      for _ <- 1..5, do: T.authorize(valid(), ip: ip) |> T.assert_unrecognized_404()

      T.enable_oauth()
      # the one remaining token is still there ...
      refute T.authorize([{"response_type", "code"}], ip: ip).status == 429
      # ... and now it is used up
      T.assert_page(T.authorize([{"response_type", "code"}], ip: ip), 429, "rate_limited")
    end

    test "the tuple key never collides with story 1's register buckets" do
      ip = T.unique_ip()
      for _ <- 1..600, do: Nebu.Web.Plugs.RateLimit.take({"oauth_authorize", ip_string(ip)}, 10, 600)
      T.disable_oauth()
      # DCR on the same IP is not limited by the authorize bucket (disabled => its own 404 path)
      refute T.register(T.web_body(), ip: ip).status == 429
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC2/AC3 — pre-trust validation: HTML page, never a redirect
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC2 — client_id" do
    @describetag :integration

    test "missing client_id => 400 unknown_client page" do
      conn = T.authorize(valid() |> List.keydelete("client_id", 0))
      T.assert_page(conn, 400, "unknown_client")
    end

    test "client_id longer than 256 bytes => 400 unknown_client page" do
      T.authorize(valid(String.duplicate("c", 257))) |> T.assert_page(400, "unknown_client")
    end

    test "unknown client_id => 400 unknown_client page, the request is not reflected (must-test 1)" do
      conn = T.authorize(valid("does-not-exist-" <> T.rand(), "https://evil.example.com/cb"))
      T.assert_page(conn, 400, "unknown_client")
      refute conn.resp_body =~ "evil.example.com"
      refute conn.resp_body =~ "does-not-exist"
    end

    test "client_id with a NUL / control character => 400 unknown_client page, no error log (review cycle 1, MINOR 1)" do
      for bad <- ["abc%00def", "abc%0Adef", "%7F"] do
        log =
          ExUnit.CaptureLog.capture_log(fn ->
            qs = "response_type=code&client_id=#{bad}&redirect_uri=#{URI.encode_www_form(@https)}"
            T.authorize(qs) |> T.assert_page(400, "unknown_client")
          end)

        refute log =~ "[error]", "a control character in client_id is a client error, not an outage: #{log}"
      end
    end

    test "DB unavailable while looking up the client => 503 page (never a redirect, never unknown_client)" do
      no_db!()
      conn = T.authorize(valid("some-client"))
      T.assert_page(conn, 503, "unavailable")
    end
  end

  describe "AC2/D13 — raw query parsing" do
    @describetag :integration

    setup do
      {:ok, cid: T.oauth_client!([@https])}
    end

    test "duplicated client_id => 400 invalid_request page", %{cid: cid} do
      T.authorize(valid(cid) ++ [{"client_id", cid}]) |> T.assert_page(400, "invalid_request")
    end

    test "array-shaped client_id[] => 400 invalid_request page", %{cid: cid} do
      pairs = valid(cid) |> List.keydelete("client_id", 0)
      T.authorize(pairs ++ [{"client_id[]", cid}]) |> T.assert_page(400, "invalid_request")
      T.authorize(valid(cid) ++ [{"client_id[]", cid}]) |> T.assert_page(400, "invalid_request")
    end

    test "duplicated or array-shaped redirect_uri => 400 invalid_request page", %{cid: cid} do
      T.authorize(valid(cid) ++ [{"redirect_uri", @https}]) |> T.assert_page(400, "invalid_request")
      T.authorize(valid(cid) ++ [{"redirect_uri[]", @https}]) |> T.assert_page(400, "invalid_request")
    end

    test "malformed percent-encoding => 400 invalid_request page (no raise, no 500)", %{cid: cid} do
      qs = "response_type=code&client_id=#{cid}&redirect_uri=#{URI.encode_www_form(@https)}&state=%zz"
      T.authorize(qs) |> T.assert_page(400, "invalid_request")
    end
  end

  describe "AC2/AC3 — redirect_uri (must-test 2 + 4)" do
    @describetag :integration

    setup do
      {:ok, cid: T.oauth_client!([@https, @loop_registered]), evil: "https://evil.example.com/cb"}
    end

    test "missing redirect_uri => 400 invalid_redirect_uri page", %{cid: cid} do
      T.authorize(valid(cid) |> List.keydelete("redirect_uri", 0)) |> T.assert_page(400, "invalid_redirect_uri")
    end

    test "mismatching redirect_uri => page; the requested URI is never rendered", %{cid: cid, evil: evil} do
      conn = T.authorize(valid(cid, evil))
      T.assert_page(conn, 400, "invalid_redirect_uri")
      refute conn.resp_body =~ "evil.example.com"
    end

    test "not EXACTLY matching variants => page", %{cid: cid} do
      for bad <- [@https <> "/", "https://APP.example.com/cb", "https://app.example.com:443/cb", @https <> "?x=1", "https://app.example.com:8443/cb"] do
        T.authorize(valid(cid, bad)) |> T.assert_page(400, "invalid_redirect_uri")
      end
    end

    test "redirect_uri longer than 2048 bytes => page", %{cid: cid} do
      T.authorize(valid(cid, @https <> "?" <> String.duplicate("x", 2048))) |> T.assert_page(400, "invalid_redirect_uri")
    end

    test "loopback: any port accepted; 127.0.0.1 is not localhost; port 0 rejected", %{cid: cid} do
      conn = T.authorize(valid(cid, @loop, %{"code_challenge" => nil}))
      assert conn.status == 302, "loopback port must be accepted (error redirect expected), got #{conn.status}"
      assert String.starts_with?(T.location(conn), @loop <> "?")

      T.authorize(valid(cid, "http://127.0.0.1:53682/cb")) |> T.assert_page(400, "invalid_redirect_uri")
      T.authorize(valid(cid, "http://localhost:0/cb")) |> T.assert_page(400, "invalid_redirect_uri")
    end

    test "check order: an unknown client wins over a bad redirect URI", %{evil: evil} do
      T.authorize(valid("unknown-" <> T.rand(), evil)) |> T.assert_page(400, "unknown_client")
    end
  end

  describe "AC2 — pending / rejected clients (must-test 3)" do
    @describetag :integration

    test "pending => 403 client_pending page with only the escaped client_uri host, labelled unverified" do
      cid =
        T.oauth_client!([@https],
          status: "pending",
          client_name: "Sneaky Name " <> T.rand(),
          client_uri: "https://pending-client.example.org/about"
        )

      conn = T.authorize(valid(cid))
      T.assert_page(conn, 403, "client_pending")
      assert conn.resp_body =~ "This app is waiting for approval"
      assert conn.resp_body =~ "pending-client.example.org"
      assert conn.resp_body =~ ~r/unverified/i
      refute conn.resp_body =~ "Sneaky Name"
      refute conn.resp_body =~ "app.example.com/cb", "no redirect URI on the page"
      refute conn.resp_body =~ "/about", "only the host of client_uri"
    end

    test "rejected => 403 client_rejected page, never a redirect" do
      cid = T.oauth_client!([@https], status: "rejected")
      T.authorize(valid(cid)) |> T.assert_page(403, "client_rejected")
    end

    test "a pending client with a mismatching redirect URI gets invalid_redirect_uri (redirect check comes first)" do
      cid = T.oauth_client!([@https], status: "pending")
      T.authorize(valid(cid, "https://evil.example.com/cb")) |> T.assert_page(400, "invalid_redirect_uri")
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC4/AC5 — error redirects (state + iss, never errcode), both response modes
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC4/AC5 — every authorize-time error code in BOTH query and fragment form (must-test 10 + 26)" do
    @describetag :integration

    setup do
      _priv = T.setup_idp!()
      {:ok, cid: T.oauth_client!([@https])}
    end

    for mode <- ["query", "fragment"] do
      test "invalid_request (missing code_challenge) as #{mode}", %{cid: cid} do
        pairs = valid(cid, @https, %{"response_mode" => unquote(mode), "code_challenge" => nil})
        T.assert_error_redirect(T.authorize(pairs), @https, "invalid_request", unquote(mode), T.param(pairs, "state"))
      end

      test "unsupported_response_type as #{mode}", %{cid: cid} do
        pairs = valid(cid, @https, %{"response_mode" => unquote(mode), "response_type" => "token"})
        T.assert_error_redirect(T.authorize(pairs), @https, "unsupported_response_type", unquote(mode), T.param(pairs, "state"))
      end

      test "invalid_scope as #{mode}", %{cid: cid} do
        pairs = valid(cid, @https, %{"response_mode" => unquote(mode), "scope" => "openid"})
        T.assert_error_redirect(T.authorize(pairs), @https, "invalid_scope", unquote(mode), T.param(pairs, "state"))
      end

      test "login_required (prompt=none) as #{mode}: no IdP redirect, nothing persisted (must-test 31)", %{cid: cid} do
        pairs = valid(cid, @https, %{"response_mode" => unquote(mode), "prompt" => "none"})
        conn = T.authorize(pairs)
        T.assert_error_redirect(conn, @https, "login_required", unquote(mode), T.param(pairs, "state"))
        refute T.location(conn) =~ T.idp_authorize_endpoint()
        assert T.count_for("oauth_authz_requests", cid) == 0
        assert T.set_cookies(conn) |> Enum.filter(&(String.starts_with?(&1, "nebu_oa_") or String.starts_with?(&1, "__Host-nebu_oa_"))) == []
      end

      test "unauthorized_client (registered response_types lacks code) as #{mode}" do
        cid = T.oauth_client!([@https], response_types: ["token"])
        pairs = valid(cid, @https, %{"response_mode" => unquote(mode)})
        T.assert_error_redirect(T.authorize(pairs), @https, "unauthorized_client", unquote(mode), T.param(pairs, "state"))
      end

      test "unauthorized_client (grant_types lacks authorization_code) as #{mode}" do
        cid = T.oauth_client!([@https], grant_types: ["refresh_token"])
        pairs = valid(cid, @https, %{"response_mode" => unquote(mode)})
        T.assert_error_redirect(T.authorize(pairs), @https, "unauthorized_client", unquote(mode), T.param(pairs, "state"))
      end

      test "temporarily_unavailable (IdP discovery unusable) as #{mode}, nothing persisted", %{cid: cid} do
        Application.put_env(:nebu_http, :oidc_metadata_override, %{"issuer" => T.idp_issuer()})
        pairs = valid(cid, @https, %{"response_mode" => unquote(mode)})
        T.assert_error_redirect(T.authorize(pairs), @https, "temporarily_unavailable", unquote(mode), T.param(pairs, "state"))
        assert T.count_for("oauth_authz_requests", cid) == 0
      end
    end

    test "invalid response_mode => invalid_request in the DEFAULT mode (fragment for https)", %{cid: cid} do
      pairs = valid(cid, @https, %{"response_mode" => "form_post"})
      T.assert_error_redirect(T.authorize(pairs), @https, "invalid_request", "fragment", T.param(pairs, "state"))
    end

    test "absent response_mode => fragment for an https redirect URI", %{cid: cid} do
      pairs = valid(cid, @https, %{"scope" => "x"})
      T.assert_error_redirect(T.authorize(pairs), @https, "invalid_scope", "fragment", T.param(pairs, "state"))
    end

    test "invalid state => invalid_request WITHOUT state", %{cid: cid} do
      pairs = valid(cid, @https, %{"state" => String.duplicate("s", 2049)})
      T.assert_error_redirect(T.authorize(pairs), @https, "invalid_request", "fragment", nil)
    end

    test "absent state => error redirect without state", %{cid: cid} do
      pairs = valid(cid, @https, %{"state" => nil, "code_challenge" => nil})
      T.assert_error_redirect(T.authorize(pairs), @https, "invalid_request", "fragment", nil)
    end

    test "invalid client nonce => invalid_request (D23, must-test 27)", %{cid: cid} do
      pairs = valid(cid, @https, %{"nonce" => "bad\x00nonce", "scope" => T.js_sdk_scope()})
      T.assert_error_redirect(T.authorize(pairs), @https, "invalid_request", "fragment", T.param(pairs, "state"))
    end

    test "prompt list combining none => invalid_request", %{cid: cid} do
      pairs = valid(cid, @https, %{"prompt" => "none consent"})
      T.assert_error_redirect(T.authorize(pairs), @https, "invalid_request", "fragment", T.param(pairs, "state"))
    end

    test "duplicated scope => invalid_request redirect (D13)", %{cid: cid} do
      pairs = valid(cid) |> then(&(&1 ++ [{"scope", T.param(&1, "scope")}]))
      pairs = List.keyreplace(pairs, "client_id", 0, {"client_id", cid})
      T.assert_error_redirect(T.authorize(pairs), @https, "invalid_request", "fragment", T.param(pairs, "state"))
    end

    test "code_challenge of 64 (js-sdk plain fallback labelled S256), 42 and 44 characters => invalid_request (must-test 29)", %{cid: cid} do
      for n <- [64, 42, 44, 128] do
        pairs = valid(cid, @https, %{"code_challenge" => String.duplicate("A", n)})
        T.assert_error_redirect(T.authorize(pairs), @https, "invalid_request", "fragment", T.param(pairs, "state"))
      end
    end

    test "PKCE plain / missing method => invalid_request (must-test 6)", %{cid: cid} do
      for o <- [%{"code_challenge_method" => "plain"}, %{"code_challenge_method" => nil}] do
        pairs = valid(cid, @https, o)
        T.assert_error_redirect(T.authorize(pairs), @https, "invalid_request", "fragment", T.param(pairs, "state"))
      end
    end

    test "response_type missing => invalid_request (must-test 5)", %{cid: cid} do
      pairs = valid(cid, @https, %{"response_type" => nil})
      T.assert_error_redirect(T.authorize(pairs), @https, "invalid_request", "fragment", T.param(pairs, "state"))
    end

    test "error_description is fixed text, never client-supplied", %{cid: cid} do
      pairs = valid(cid, @https, %{"scope" => "evil<script>xyz", "state" => "st<b>x"})
      params = T.assert_error_redirect(T.authorize(pairs), @https, "invalid_scope", "fragment", "st<b>x")
      refute params["error_description"] =~ "evil"
      refute params["error_description"] =~ "xyz"
    end
  end

  describe "AC5 — response mode defaults and URI shapes" do
    @describetag :integration

    setup do
      _priv = T.setup_idp!()
      :ok
    end

    test "loopback (port at flow time) => query by default; the stored port is used" do
      cid = T.oauth_client!([@loop_registered])
      pairs = valid(cid, @loop, %{"code_challenge" => nil})
      T.assert_error_redirect(T.authorize(pairs), @loop, "invalid_request", "query", T.param(pairs, "state"))
    end

    test "private-use scheme => query by default" do
      uri = "com.example.app:/oauth2/callback"
      cid = T.oauth_client!([uri])
      pairs = valid(cid, uri, %{"code_challenge" => nil})
      conn = T.authorize(pairs)
      assert conn.status == 302
      assert String.starts_with?(T.location(conn), uri <> "?error=invalid_request&")
    end

    test "a registered URI with a query gets the params appended with &" do
      uri = "https://app.example.com/cb?tenant=t1"
      cid = T.oauth_client!([uri])
      pairs = valid(cid, uri, %{"code_challenge" => nil, "response_mode" => "query"})
      conn = T.authorize(pairs)
      assert conn.status == 302
      assert String.starts_with?(T.location(conn), uri <> "&error=invalid_request&")
    end

    test "explicit fragment honoured for a loopback URI" do
      cid = T.oauth_client!([@loop_registered])
      pairs = valid(cid, @loop, %{"code_challenge" => nil, "response_mode" => "fragment"})
      T.assert_error_redirect(T.authorize(pairs), @loop, "invalid_request", "fragment", T.param(pairs, "state"))
    end
  end

  describe "AC5/D15 — iss is byte-equal to the issuer of auth_metadata (must-test 28)" do
    @describetag :integration

    test "trailing-slash issuer config: iss == normalized metadata issuer" do
      _priv = T.setup_idp!()
      T.enable_oauth("https://nebu.example.com/")
      issuer = T.get_metadata() |> T.json() |> Map.fetch!("issuer")
      assert issuer == "https://nebu.example.com"

      cid = T.oauth_client!([@https])
      pairs = valid(cid, @https, %{"code_challenge" => nil})
      T.assert_error_redirect(T.authorize(pairs), @https, "invalid_request", "fragment", T.param(pairs, "state"), issuer)
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC13 — headers, no CORS
  # ════════════════════════════════════════════════════════════════════════════

  defp assert_ac13(conn) do
    assert T.header(conn, "cache-control") =~ "no-store"
    assert T.header(conn, "pragma") == "no-cache"
    assert T.header(conn, "referrer-policy") == "no-referrer"
    assert T.header(conn, "x-content-type-options") == "nosniff"

    for {k, _} <- conn.resp_headers, do: refute(String.starts_with?(k, "access-control-"), "CORS header #{k} must be deleted")
  end

  describe "AC13 — security headers and NO CORS on pages and redirects (must-test 22)" do
    @describetag :integration

    test "an error page requested with an Origin header" do
      conn = T.authorize(valid("unknown-" <> T.rand()), origin: "https://client.example.com")
      T.assert_page(conn, 400, "unknown_client")
      assert_ac13(conn)
    end

    test "an error redirect requested with an Origin header" do
      _priv = T.setup_idp!()
      cid = T.oauth_client!([@https])
      conn = T.authorize(valid(cid, @https, %{"code_challenge" => nil}), origin: "https://client.example.com")
      assert conn.status == 302
      assert_ac13(conn)
    end

    test "the 405 page and the 429 page" do
      conn = T.authorize(valid(), method: :post, origin: "https://client.example.com")
      assert conn.status == 405
      assert_ac13(conn)

      ip = T.unique_ip()
      for _ <- 1..600, do: Nebu.Web.Plugs.RateLimit.take({"oauth_authorize", ip_string(ip)}, 10, 600)
      conn = T.authorize(valid(), ip: ip, origin: "https://client.example.com")
      assert conn.status == 429
      assert_ac13(conn)
    end
  end
end
