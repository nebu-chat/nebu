defmodule Nebu.OAuth.OAuthTokenHttpTest do
  @moduledoc """
  RED-phase acceptance tests for story `oauth-token-endpoint` (story 3), AC1-AC4 (+ T20-T24, T32,
  the oracle "extra tests", Must #1, #2, #3, #24, #33) through the FULL `Nebu.Web.Router`:
  `POST /oauth2/token` and `GET /oauth2/jwks` — kill switch, methods, CORS, request parsing, client
  authentication `none`, grant-type checks, rate limits ("refresh is never 429"), 5xx bodies `{}`.

  Unit describes need no database (the paths are answered before any DB access, proven with the
  `:oauth_repo` / `:oauth_session_repo` NoSuchRepo seams); `:integration` describes use fixture
  clients in `oauth_clients`.

  Red today: neither `/oauth2/token` nor `/oauth2/jwks` is routed (router `404 "not found"`).
  """
  use ExUnit.Case, async: false

  alias Nebu.OAuth.TestSupport, as: T

  @router_opts Nebu.Web.Router.init([])
  @https "https://app.example.com/cb"
  @hex64 String.duplicate("ab", 32)

  setup do
    T.enable_oauth()
    T.reset_rate_limits()

    on_exit(fn ->
      T.clear_oauth_config()
      T.restore_rate_limits()
      Application.delete_env(:nebu_http, :oauth_repo)
      Application.delete_env(:nebu_http, :oauth_session_repo)
    end)

    :ok
  end

  defp no_db! do
    Application.put_env(:nebu_http, :oauth_repo, T.NoSuchRepo)
    Application.put_env(:nebu_http, :oauth_session_repo, T.NoSuchRepo)
  end

  defp call(method, path, body \\ "", headers \\ []) do
    Plug.Test.conn(method, path, body)
    |> T.put_headers(headers)
    |> Map.put(:remote_ip, T.unique_ip())
    |> Nebu.Web.Router.call(@router_opts)
  end

  defp verifier, do: String.duplicate("v", 43)

  defp code_params(client_id, overrides \\ %{}),
    do: T.code_grant(client_id, "bogus-code-" <> T.rand(), @https, verifier(), overrides)

  defp refresh_params(client_id, overrides \\ %{}), do: T.refresh_grant(client_id, @hex64, overrides)

  defp junk(opts \\ []), do: T.token_request([{"grant_type", "authorization_code"}], Keyword.put_new(opts, :query, "x=1"))

  # ════════════════════════════════════════════════════════════════════════════
  # AC1 / T22 / Must #1 — kill switch
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC1/T22/Must #1 — disabled / invalid issuer => 404 M_UNRECOGNIZED (no DB, no rate-limit token)" do
    test "OAuth disabled: POST /oauth2/token and GET /oauth2/jwks => 404 M_UNRECOGNIZED" do
      T.disable_oauth()
      no_db!()
      T.token_request(code_params("some-client")) |> T.assert_unrecognized_404_no_error()
      T.jwks() |> T.assert_unrecognized_404_no_error()
    end

    for bad <- ["http://nebu.example.com", "https://nebu.example.com/nebu", "https://nebu.example.com/a/b/",
                "https://nebu.example.com?x=1", "https://user@nebu.example.com", "nebu.example.com", ""] do
      test "issuer #{inspect(bad)} (invalid, incl. an issuer with a path, T31) => 404 on token and jwks" do
        T.enable_oauth(unquote(bad))
        no_db!()
        conn = T.token_request(code_params("some-client")) |> T.assert_unrecognized_404_no_error()
        refute conn.resp_body =~ "nebu.example.com"
        T.jwks() |> T.assert_unrecognized_404_no_error()
      end
    end

    test "the 404 carries ACAO * (browser clients can read it)" do
      T.disable_oauth()
      conn = T.token_request(code_params("some-client"), origin: "https://client.example.com")
      assert conn.status == 404
      assert T.header(conn, "access-control-allow-origin") == "*"
    end

    test "the disabled path does NOT charge the token bucket" do
      ip = T.unique_ip()
      T.drain!("oauth_token", ip, 10, 600, 1)
      T.disable_oauth()
      for _ <- 1..5, do: T.token_request(code_params("some-client"), ip: ip) |> T.assert_unrecognized_404_no_error()

      T.enable_oauth()
      no_db!()
      junk(ip: ip) |> T.assert_token_error(400, "invalid_request")
      junk(ip: ip) |> T.assert_token_error(429, "too_many_requests")
    end

    test "an issuer with a single trailing slash is valid (live: a junk request is 400, not 404)" do
      T.enable_oauth("https://nebu.example.com/")
      no_db!()
      junk() |> T.assert_token_error(400, "invalid_request")
    end
  end

  describe "AC1/T22/T20 — unreadable config (:unknown) => 503 {} + Retry-After: 5 (never 404, never 4xx)" do
    test "POST /oauth2/token (both grants)" do
      T.unreadable_oauth_config()
      no_db!()

      for params <- [code_params("some-client"), refresh_params("some-client")] do
        conn = T.token_request(params) |> T.assert_token_5xx(503)
        assert T.header(conn, "retry-after") == "5"
      end
    end

    test "GET /oauth2/jwks" do
      T.unreadable_oauth_config()
      no_db!()
      conn = T.jwks() |> T.assert_5xx_empty(503)
      assert T.header(conn, "retry-after") == "5"
      assert T.header(conn, "access-control-allow-origin") == "*"
    end
  end

  describe "AC1 — sub-paths, methods (no DB)" do
    test "sub-paths => 404 M_UNRECOGNIZED" do
      no_db!()
      call(:post, "/oauth2/token/x", "grant_type=refresh_token", [{"content-type", "application/x-www-form-urlencoded"}]) |> T.assert_unrecognized_404_no_error()
      call(:get, "/oauth2/jwks/x") |> T.assert_unrecognized_404_no_error()
      call(:get, "/oauth2/jwks/x/y") |> T.assert_unrecognized_404_no_error()
    end

    for method <- [:get, :put, :delete, :patch] do
      test "#{method} /oauth2/token while live => 405 invalid_request, Allow: POST, OPTIONS" do
        no_db!()
        conn = T.token_request(code_params("some-client"), method: unquote(method))
        T.assert_token_error(conn, 405, "invalid_request")
        assert T.header(conn, "allow") == "POST, OPTIONS"
      end
    end

    for method <- [:post, :put, :delete] do
      test "#{method} /oauth2/jwks while live => 405 invalid_request, Allow: GET, OPTIONS" do
        no_db!()
        conn = call(unquote(method), "/oauth2/jwks")
        assert conn.status == 405
        assert T.json(conn)["error"] == "invalid_request"
        refute Map.has_key?(T.json(conn), "errcode")
        assert T.header(conn, "allow") == "GET, OPTIONS"
      end
    end

    test "GET /oauth2/token while DISABLED => 404 (kill switch first), not 405" do
      T.disable_oauth()
      T.token_request([], method: :get) |> T.assert_unrecognized_404_no_error()
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # T32 / C15 — CORS
  # ════════════════════════════════════════════════════════════════════════════

  describe "T32/C15 — CORS preflight and simple requests" do
    for {path, method} <- [{"/oauth2/token", "POST"}, {"/oauth2/jwks", "GET"}] do
      test "OPTIONS #{path}: CORS headers, Allow-Headers incl. Content-Type + Authorization, no endpoint logic, no DB" do
        pid = self()

        Application.put_env(:nebu_http, :oauth_config_source, fn ->
          send(pid, :oauth_config_read)
          %{enabled: true, issuer_url: T.issuer()}
        end)

        no_db!()
        conn = T.options(unquote(path), request_method: unquote(method), request_headers: "content-type, authorization, x-requested-with")
        assert conn.status in [200, 204], "preflight status #{conn.status}"
        assert T.header(conn, "access-control-allow-origin") == "*"
        headers = (T.header(conn, "access-control-allow-headers") || "") |> String.downcase()
        for h <- ~w(content-type authorization x-requested-with), do: assert(headers =~ h, "Allow-Headers lacks #{h}: #{headers}")
        methods = (T.header(conn, "access-control-allow-methods") || "") |> String.upcase()
        assert methods =~ unquote(method)

        refute T.header(conn, "access-control-allow-credentials") == "true",
               "never Allow-Credentials together with ACAO * (C15)"

        refute_received :oauth_config_read, "a preflight must not run endpoint logic (not even the config read)"
      end
    end

    test "OPTIONS does not take rate-limit tokens (token bucket)" do
      ip = T.unique_ip()
      T.drain!("oauth_token", ip, 10, 600, 1)
      for _ <- 1..3, do: T.options("/oauth2/token", ip: ip)
      no_db!()
      refute junk(ip: ip).status == 429, "the last token must still be there after 3 preflights"
    end

    test "OPTIONS does not take rate-limit tokens (jwks bucket)" do
      ip = T.unique_ip()
      T.drain!("oauth_jwks", ip, 10, 600, 0)
      for _ <- 1..3, do: assert(T.options("/oauth2/jwks", ip: ip, request_method: "GET").status in [200, 204])
    end

    test "a simple cross-origin POST gets ACAO * and never Access-Control-Allow-Credentials" do
      no_db!()
      conn = junk(origin: "https://client.example.com")
      T.assert_token_error(conn, 400, "invalid_request")
      assert T.header(conn, "access-control-allow-origin") == "*"
      assert T.header(conn, "access-control-allow-credentials") == nil
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC2 / T23 / Must #3, #33 — request parsing (all answered before any DB access)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC2 — request format (no DB)" do
    setup do
      no_db!()
      :ok
    end

    test "step 1: a non-empty query string => 400 invalid_request (credentials never in URLs)" do
      T.token_request(code_params("cid"), query: "code=leak") |> T.assert_token_error(400, "invalid_request")
    end

    for {label, ct, body} <- [
          {"application/json", "application/json", ~s({"grant_type":"authorization_code"})},
          {"multipart/form-data", "multipart/form-data; boundary=xyz",
           "--xyz\r\nContent-Disposition: form-data; name=\"grant_type\"\r\n\r\nauthorization_code\r\n--xyz--\r\n"},
          {"text/plain", "text/plain", "grant_type=authorization_code"},
          {"no content type", nil, "grant_type=authorization_code"}
        ] do
      test "step 2: #{label} => 400 invalid_request" do
        T.token_request(unquote(body), content_type: unquote(ct)) |> T.assert_token_error(400, "invalid_request")
      end
    end

    test "step 2: '; charset=UTF-8' and a mixed-case media type are accepted (proceeds to client auth: 401)" do
      for ct <- ["application/x-www-form-urlencoded; charset=UTF-8", "Application/X-WWW-Form-URLEncoded"] do
        T.token_request([{"grant_type", "authorization_code"}], content_type: ct)
        |> T.assert_token_error(401, "invalid_client")
      end
    end

    test "step 3: a body larger than 16 384 bytes => 413 invalid_request" do
      body = "grant_type=authorization_code&pad=" <> String.duplicate("a", 16_400)
      T.token_request(body) |> T.assert_token_error(413, "invalid_request")
    end

    test "step 3: a body of exactly 16 384 bytes is read (not 413)" do
      prefix = "grant_type=authorization_code&pad="
      body = prefix <> String.duplicate("a", 16_384 - byte_size(prefix))
      assert byte_size(body) == 16_384
      T.token_request(body) |> T.assert_token_error(401, "invalid_client")
    end

    test "step 4: a malformed body (%zz) => 400 invalid_request" do
      T.token_request("grant_type=authorization_code&code=%zz&client_id=c") |> T.assert_token_error(400, "invalid_request")
    end

    test "step 5: a duplicated parameter => 400 (also identical values, also one empty)" do
      for body <- ["grant_type=authorization_code&client_id=a&client_id=b",
                   "grant_type=authorization_code&client_id=a&client_id=a",
                   "grant_type=refresh_token&scope=&scope=openid&client_id=a",
                   "grant_type=authorization_code&grant_type=refresh_token&client_id=a"] do
        T.token_request(body) |> T.assert_token_error(400, "invalid_request")
      end
    end

    test "step 6: a control character (percent-encoded NUL / LF) or invalid UTF-8 => 400 invalid_request" do
      for body <- ["grant_type=authorization_code&client_id=a%00b", "grant_type=authorization_code&code=a%0Ab&client_id=c",
                   "grant_type=authorization_code&code=%FF%FE&client_id=c"] do
        T.token_request(body) |> T.assert_token_error(400, "invalid_request")
      end
    end

    test "missing Accept header and Accept: text/html still answer JSON" do
      for headers <- [[], [{"accept", "text/html"}]] do
        conn = T.token_request(code_params("cid"), query: "x=1", headers: headers)
        T.assert_token_error(conn, 400, "invalid_request")
      end
    end

    test "error_description is fixed text: nothing from the request is reflected" do
      conn = T.token_request("grant_type=authorization_code&client_id=REFLECTED-VALUE&client_id=x")
      T.assert_token_error(conn, 400, "invalid_request")
      refute conn.resp_body =~ "REFLECTED-VALUE"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC3 / T24 / AC2 step 8 — client authentication `none`, grant type (integration: clients)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC3/T24/Must #3 — client authentication method none" do
    @describetag :integration

    setup do
      {:ok, cid: T.oauth_client!([@https])}
    end

    test "client_id missing => 401 invalid_client" do
      T.token_request(List.keydelete(code_params("x"), "client_id", 0)) |> T.assert_token_error(401, "invalid_client")
    end

    test "client_id empty => missing => 401 invalid_client" do
      T.token_request(code_params("", %{})) |> T.assert_token_error(401, "invalid_client")
    end

    test "client_id longer than 256 bytes => 401 invalid_client" do
      T.token_request(code_params(String.duplicate("c", 257))) |> T.assert_token_error(401, "invalid_client")
    end

    test "unknown client_id => 401 invalid_client (not reflected)" do
      conn = T.token_request(code_params("no-such-client-" <> T.rand()))
      T.assert_token_error(conn, 401, "invalid_client")
      refute conn.resp_body =~ "no-such-client"
    end

    for status <- ["pending", "rejected"] do
      test "a #{status} client => 401 invalid_client (both grants)" do
        cid = T.oauth_client!([@https], status: unquote(status))
        T.token_request(code_params(cid)) |> T.assert_token_error(401, "invalid_client")
        T.token_request(refresh_params(cid)) |> T.assert_token_error(401, "invalid_client")
      end
    end

    test "a NON-EMPTY client_secret => 401 invalid_client", %{cid: cid} do
      T.token_request(code_params(cid, %{"client_secret" => "s3cr3t"})) |> T.assert_token_error(401, "invalid_client")
    end

    test "an EMPTY client_secret= is omitted and accepted (oracle C3): proceeds to the code check", %{cid: cid} do
      T.token_request(code_params(cid, %{"client_secret" => ""})) |> T.assert_token_error(400, "invalid_grant")
    end

    test "Authorization: Basic => 401 invalid_client + WWW-Authenticate: Basic realm=\"nebu\"", %{cid: cid} do
      basic = "Basic " <> Base.encode64(cid <> ":")
      conn = T.token_request(code_params(cid), headers: [{"authorization", basic}])
      T.assert_token_error(conn, 401, "invalid_client")
      assert T.header(conn, "www-authenticate") == ~s(Basic realm="nebu")
    end

    test "a stray Authorization: Bearer header is ignored (refresh: plain invalid_grant for an unknown RT)", %{cid: cid} do
      T.token_request(refresh_params(cid), headers: [{"authorization", "Bearer " <> @hex64}])
      |> T.assert_token_error(400, "invalid_grant")
    end

    test "DB error on the client lookup => 503 {} + Retry-After (never invalid_client)", %{cid: cid} do
      Application.put_env(:nebu_http, :oauth_repo, T.NoSuchRepo)
      T.token_request(code_params(cid)) |> T.assert_token_5xx(503)
      T.token_request(refresh_params(cid)) |> T.assert_token_5xx(503)
    end
  end

  describe "AC2 step 8/AC5/AC9/Must #3, #33 — grant type and required parameters" do
    @describetag :integration

    setup do
      {:ok, cid: T.oauth_client!([@https])}
    end

    test "grant_type missing => 400 invalid_request", %{cid: cid} do
      T.token_request([{"client_id", cid}, {"code", "x"}]) |> T.assert_token_error(400, "invalid_request")
    end

    test "grant_type empty => missing => 400 invalid_request", %{cid: cid} do
      T.token_request(code_params(cid, %{"grant_type" => ""})) |> T.assert_token_error(400, "invalid_request")
    end

    for gt <- ["password", "client_credentials", "implicit", "urn:ietf:params:oauth:grant-type:device_code",
               "Refresh_Token", "AUTHORIZATION_CODE", "token"] do
      test "grant_type=#{gt} => 400 unsupported_grant_type", %{cid: cid} do
        T.token_request(code_params(cid, %{"grant_type" => unquote(gt)})) |> T.assert_token_error(400, "unsupported_grant_type")
      end
    end

    for p <- ~w(code redirect_uri code_verifier) do
      test "authorization_code without #{p} => 400 invalid_request", %{cid: cid} do
        T.token_request(code_params(cid, %{unquote(p) => nil})) |> T.assert_token_error(400, "invalid_request")
      end

      test "authorization_code with an EMPTY #{p}= => 400 invalid_request", %{cid: cid} do
        T.token_request(code_params(cid, %{unquote(p) => ""})) |> T.assert_token_error(400, "invalid_request")
      end
    end

    test "refresh_token missing / empty => 400 invalid_request", %{cid: cid} do
      T.token_request(refresh_params(cid, %{"refresh_token" => nil})) |> T.assert_token_error(400, "invalid_request")
      T.token_request(refresh_params(cid, %{"refresh_token" => ""})) |> T.assert_token_error(400, "invalid_request")
    end

    test "a refresh_token that is not 64 lowercase hex => invalid_grant without DB access", %{cid: cid} do
      for bad <- ["short", String.upcase(@hex64), @hex64 <> "0", "a.b.c"] do
        T.token_request(refresh_params(cid, %{"refresh_token" => bad})) |> T.assert_token_error(400, "invalid_grant")
      end
    end

    test "unknown parameters are ignored (state, nonce, resource, foo)", %{cid: cid} do
      T.token_request(refresh_params(cid, %{"state" => "s", "nonce" => "n", "resource" => "https://x", "foo" => "bar"}))
      |> T.assert_token_error(400, "invalid_grant")
    end

    test "registered grant_types lack refresh_token => 400 unauthorized_client" do
      cid = T.oauth_client!([@https], grant_types: ["authorization_code"])
      T.token_request(refresh_params(cid)) |> T.assert_token_error(400, "unauthorized_client")
      # the registered grant still passes the grant check
      T.token_request(code_params(cid)) |> T.assert_token_error(400, "invalid_grant")
    end

    test "registered grant_types lack authorization_code => 400 unauthorized_client" do
      cid = T.oauth_client!([@https], grant_types: ["refresh_token"])
      T.token_request(code_params(cid)) |> T.assert_token_error(400, "unauthorized_client")
    end

    test "metadata WITHOUT grant_types => both grants allowed (story-1 default)" do
      id = "atdd-oa-nogt-" <> T.rand(6)
      on_exit(fn -> T.cleanup_clients([id]) end)

      meta = %{"client_name" => "ATDD no grant_types " <> id, "client_uri" => "https://client.example.com",
               "redirect_uris" => [@https], "application_type" => "web", "token_endpoint_auth_method" => "none"}

      :ok = T.insert_row!(id, Jason.encode!(meta), "atdd-hash-" <> id, "approved")
      T.token_request(refresh_params(id)) |> T.assert_token_error(400, "invalid_grant")
      T.token_request(code_params(id)) |> T.assert_token_error(400, "invalid_grant")
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC4 / T21 / Must #24 — rate limits
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC4/T21/Must #24 — {\"oauth_token\", ip}: code grant + junk => 429 too_many_requests (before the DB)" do
    test "an exhausted bucket answers a code-grant request 429 + Retry-After, no DB access" do
      ip = T.unique_ip()
      T.drain!("oauth_token", ip, 10, 600)
      no_db!()
      conn = T.token_request(code_params("some-client"), ip: ip)
      T.assert_token_error(conn, 429, "too_many_requests")
      assert {secs, ""} = Integer.parse(T.header(conn, "retry-after") || "")
      assert secs > 0
    end

    test "junk requests (query string, wrong content type, unknown/missing grant type) pay the same bucket" do
      ip = T.unique_ip()
      T.drain!("oauth_token", ip, 10, 600)
      no_db!()
      junk(ip: ip) |> T.assert_token_error(429, "too_many_requests")
      T.token_request("grant_type=authorization_code", content_type: "application/json", ip: ip) |> T.assert_token_error(429, "too_many_requests")
      T.token_request([{"grant_type", "password"}], ip: ip) |> T.assert_token_error(429, "too_many_requests")
      T.token_request([{"client_id", "x"}], ip: ip) |> T.assert_token_error(429, "too_many_requests")
    end

    test "every request pays exactly one token (the 600th passes, the 601st is limited); other IPs are unaffected" do
      ip = T.unique_ip()
      T.drain!("oauth_token", ip, 10, 600, 1)
      no_db!()
      junk(ip: ip) |> T.assert_token_error(400, "invalid_request")
      junk(ip: ip) |> T.assert_token_error(429, "too_many_requests")
      junk() |> T.assert_token_error(400, "invalid_request")
    end

    test "the tuple keys never collide with the authorize / register / callback families" do
      ip = T.unique_ip()
      for fam <- ~w(oauth_authorize oauth_callback oauth_register oauth_register_invalid oauth_register_loose), do: T.drain!(fam, ip, 10, 600)
      T.drain!("oauth_token_refresh", ip, 100, 1200)
      no_db!()
      junk(ip: ip) |> T.assert_token_error(400, "invalid_request")
    end
  end

  describe "AC4/T21/Must #24 — {\"oauth_token_refresh\", ip}: refresh => 503 {} + Retry-After, NEVER 429" do
    test "a drained refresh bucket answers 503 {} + Retry-After (no DB access)" do
      ip = T.unique_ip()
      T.drain!("oauth_token_refresh", ip, 100, 1200)
      no_db!()
      conn = T.token_request(refresh_params("some-client"), ip: ip)
      T.assert_token_5xx(conn, 503)
      refute conn.status == 429
    end

    test "a refresh is never 429, even with BOTH buckets drained" do
      ip = T.unique_ip()
      T.drain!("oauth_token_refresh", ip, 100, 1200)
      T.drain!("oauth_token", ip, 10, 600)
      no_db!()

      for _ <- 1..3 do
        conn = T.token_request(refresh_params("some-client"), ip: ip)
        refute conn.status == 429, "spec 6: 429 logs Matrix clients out"
        T.assert_token_5xx(conn, 503)
      end
    end
  end

  describe "AC4 — the two families are separate (integration: real client)" do
    @describetag :integration

    setup do
      {:ok, cid: T.oauth_client!([@https])}
    end

    test "a drained CODE bucket does not limit refreshes", %{cid: cid} do
      ip = T.unique_ip()
      T.drain!("oauth_token", ip, 10, 600)
      T.token_request(refresh_params(cid), ip: ip) |> T.assert_token_error(400, "invalid_grant")
    end

    test "a drained REFRESH bucket does not limit code grants", %{cid: cid} do
      ip = T.unique_ip()
      T.drain!("oauth_token_refresh", ip, 100, 1200)
      T.token_request(code_params(cid), ip: ip) |> T.assert_token_error(400, "invalid_grant")
    end

    test "a refresh pays the refresh bucket (1 left: one passes, the next is 503 {})", %{cid: cid} do
      ip = T.unique_ip()
      T.drain!("oauth_token_refresh", ip, 100, 1200, 1)
      T.token_request(refresh_params(cid), ip: ip) |> T.assert_token_error(400, "invalid_grant")
      T.token_request(refresh_params(cid), ip: ip) |> T.assert_token_5xx(503)
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC10 / T20 / Must #2 — rescued exception; no errcode anywhere
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC10/T20/Must #2 — unexpected exception => 500 {} + Retry-After" do
    @describetag :integration

    test "a raise inside the handler is rescued: 500, body exactly {}, Retry-After, token headers; type logged only" do
      cid = T.oauth_client!([@https])
      T.inject_token_handler_fault!()

      for params <- [code_params(cid), refresh_params(cid)] do
        log = ExUnit.CaptureLog.capture_log(fn -> send(self(), {:conn, T.token_request(params)}) end)
        assert_received {:conn, conn}
        T.assert_token_5xx(conn, 500)
        refute log =~ "atdd injected token-handler fault", "only the exception TYPE is logged, never its message"
      end
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC1 / D21 — /oauth2/revoke (story 4)
  # ════════════════════════════════════════════════════════════════════════════

  # story 4 (oauth-token-revocation-logout, AC11 / R13 / Trap 7): changed deliberately. Story 3
  # asserted "/oauth2/revoke is still the router's plain 404"; story 4 routes it and keeps it LIVE
  # while OAuth is disabled (no kill switch, oracle O5), unlike /oauth2/token (whose T22 kill switch
  # is unchanged, Must #36). Full revoke behaviour: oauth_revoke_http_test.exs.
  describe "AC1/Must #30 — /oauth2/revoke is routed and live (story 4); the token kill switch is unchanged" do
    for enabled <- [true, false] do
      test "/oauth2/revoke (oauth enabled=#{enabled}) => routed: POST malformed token 200 {}, GET 405" do
        if unquote(enabled), do: T.enable_oauth(), else: T.disable_oauth()
        no_db!()

        post = call(:post, "/oauth2/revoke", "token=x", [{"content-type", "application/x-www-form-urlencoded"}])
        refute post.resp_body == "not found"
        T.assert_revoke_ok(post)

        get = T.get("/oauth2/revoke")
        assert get.status == 405
        assert T.header(get, "allow") == "POST, OPTIONS"
      end
    end

    test "while disabled /oauth2/token keeps its 404 kill switch (only revoke is exempt, R13)" do
      T.disable_oauth()
      no_db!()
      T.token_request(code_params("some-client")) |> T.assert_unrecognized_404_no_error()
      call(:post, "/oauth2/revoke", "token=x", [{"content-type", "application/x-www-form-urlencoded"}]) |> T.assert_revoke_ok()
    end
  end
end
