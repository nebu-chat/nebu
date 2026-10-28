defmodule Nebu.OAuth.OAuthRevokeHttpTest do
  @moduledoc """
  RED-phase acceptance tests for story `oauth-token-revocation-logout` (story 4 of epic
  oauth-broker), AC1-AC3 and AC6 (R6-R10, R13, R14, oracle O3/O5) through the FULL
  `Nebu.Web.Router`: `POST /oauth2/revoke` (RFC 7009) — NO kill switch (live while disabled and
  with an invalid issuer, only `:unknown` => `503 {}`), methods, sub-paths, CORS on every status,
  request parsing (same `FormPost` code as the token endpoint), the `{"oauth_revoke", ip}` rate
  limit, response shapes (`200 {}` + `application/json`; RFC 6749 5.2 errors; every 5xx `{}` +
  `Retry-After`), ignored `client_id` / `client_secret` / `Authorization` / `token_type_hint`.

  Unit describes need no database: the paths are answered before any DB access, proven with the
  `:oauth_session_repo` NoSuchRepo seam (a DB access would turn the 200 into a 503). Integration
  describes revoke REAL story-2/3 sessions.

  Red today: `/oauth2/revoke` is not routed (router plain `404 "not found"`), `Nebu.OAuth.Revoke`
  and the `Nebu.Matrix.oauth_revoke_token/1` facade do not exist.
  """
  use ExUnit.Case, async: false

  alias Nebu.OAuth.TestSupport, as: T

  @https "https://app.example.com/cb"
  @hex64 String.duplicate("ab", 32)

  setup do
    T.enable_oauth()
    T.reset_rate_limits()

    on_exit(fn ->
      T.clear_oauth_config()
      T.restore_rate_limits()
      for k <- [:oauth_repo, :oauth_session_repo, :oauth_revoke_test_hook], do: Application.delete_env(:nebu_http, k)
    end)

    :ok
  end

  defp no_db! do
    Application.put_env(:nebu_http, :oauth_repo, T.NoSuchRepo)
    Application.put_env(:nebu_http, :oauth_session_repo, T.NoSuchRepo)
  end

  # a well-formed but unknown token, malformed junk (no DB) and a 400 request
  defp unknown(opts \\ []), do: T.revoke(T.revoke_params(T.rand(32)), opts)
  defp malformed(opts \\ []), do: T.revoke(T.revoke_params("not-a-nebu-token"), opts)
  defp junk(opts \\ []), do: T.revoke(T.revoke_params(@hex64), Keyword.put_new(opts, :query, "x=1"))

  defp disabled_states do
    [
      {"disabled", fn -> T.disable_oauth() end},
      {"invalid issuer (http)", fn -> T.enable_oauth("http://nebu.example.com") end},
      {"invalid issuer (path)", fn -> T.enable_oauth("https://nebu.example.com/nebu") end},
      {"empty issuer", fn -> T.enable_oauth("") end}
    ]
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC1 / R13 / Must #1 — NO kill switch (oracle O5), only :unknown => 503 {}
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC1/R13/Must #1 — revoke stays LIVE while disabled / with an invalid issuer (no DB needed for these)" do
    test "malformed token => 200 {} in every non-:unknown state (never the 404 kill switch)" do
      no_db!()

      for {label, set} <- disabled_states() ++ [{"enabled", fn -> T.enable_oauth() end}] do
        set.()
        conn = malformed()
        refute conn.status == 404, "#{label}: revoke has NO kill switch (R13), got 404 #{conn.resp_body}"
        T.assert_revoke_ok(conn)
      end
    end

    test "parse errors are answered (400 invalid_request) also while disabled" do
      T.disable_oauth()
      no_db!()
      junk() |> T.assert_revoke_error(400, "invalid_request")
    end

    test "the rate limit applies while disabled (drained bucket => 429)" do
      T.disable_oauth()
      no_db!()
      ip = T.unique_ip()
      T.drain!("oauth_revoke", ip, 60, 600)
      malformed(ip: ip) |> T.assert_revoke_error(429, "too_many_requests")
    end
  end

  describe "AC1/R13/Must #1, #4 — unreadable config (:unknown) => 503 {} + Retry-After: 5" do
    test "503 {}, Retry-After 5, AC1 headers; no lookup (NoSuchRepo not needed), for valid and junk requests" do
      T.unreadable_oauth_config()
      no_db!()

      for conn <- [unknown(), malformed(), junk(), T.revoke("", content_type: "application/json")] do
        T.assert_revoke_5xx(conn, 503)
        assert T.header(conn, "retry-after") == "5"
      end
    end

    test ":unknown takes NO rate-limit token" do
      ip = T.unique_ip()
      T.drain!("oauth_revoke", ip, 60, 600, 1)
      T.unreadable_oauth_config()
      for _ <- 1..5, do: T.revoke(T.revoke_params(@hex64), ip: ip) |> T.assert_revoke_5xx(503)

      T.enable_oauth()
      no_db!()
      junk(ip: ip) |> T.assert_revoke_error(400, "invalid_request")
      junk(ip: ip) |> T.assert_revoke_error(429, "too_many_requests")
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC1 — routing, methods, sub-paths, trailing slash
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC1/Must #18 — methods, sub-paths, trailing slash (no DB)" do
    setup do
      no_db!()
      :ok
    end

    for method <- [:get, :put, :delete, :patch, :head] do
      test "#{method} /oauth2/revoke => 405 invalid_request + Allow: POST, OPTIONS (also while disabled)" do
        for set <- [fn -> T.enable_oauth() end, fn -> T.disable_oauth() end] do
          set.()
          conn = T.revoke(T.revoke_params(@hex64), method: unquote(method))
          assert conn.status == 405, "expected 405, got #{conn.status}: #{conn.resp_body}"
          assert T.header(conn, "allow") == "POST, OPTIONS"
          T.assert_revoke_headers(conn)

          # HEAD has no body on the wire; Plug.Test still carries the resp_body
          if unquote(method) != :head, do: T.assert_revoke_error(conn, 405, "invalid_request")
        end
      end
    end

    test "sub-paths => 404 {\"errcode\":\"M_UNRECOGNIZED\"} (no error member) with the revoke headers" do
      for path <- ["/oauth2/revoke/x", "/oauth2/revoke/x/y"] do
        conn = T.revoke(T.revoke_params(@hex64), path: path)
        T.assert_unrecognized_404_no_error(conn)
        assert T.header(conn, "access-control-allow-origin") == "*"
        assert (T.header(conn, "cache-control") || "") =~ "no-store"
        assert T.header(conn, "pragma") == "no-cache", "AC1: EVERY revoke response (incl. the 404) carries Pragma: no-cache"
        assert T.header(conn, "access-control-allow-credentials") == nil
      end
    end

    test "a trailing slash (/oauth2/revoke/) is the endpoint itself" do
      T.revoke(T.revoke_params("junk-token"), path: "/oauth2/revoke/") |> T.assert_revoke_ok()
    end

    test "the endpoint itself never answers the router's plain \"not found\"" do
      conn = malformed()
      refute conn.resp_body == "not found"
      T.assert_revoke_ok(conn)
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC1 / R14 / Must #2, #3 — CORS
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC1/R14/Must #2 — OPTIONS preflight answered by CORSPlug (credentials-free branch)" do
    for {label, set} <- [{"enabled", :enable}, {"disabled", :disable}] do
      test "OPTIONS /oauth2/revoke (#{label}): 204, ACAO *, Allow-Headers incl. Content-Type + Authorization, no ACAC, no config read, no DB" do
        pid = self()
        enabled = unquote(set) == :enable

        Application.put_env(:nebu_http, :oauth_config_source, fn ->
          send(pid, :oauth_config_read)
          %{enabled: enabled, issuer_url: T.issuer()}
        end)

        no_db!()
        conn = T.options("/oauth2/revoke", request_method: "POST", request_headers: "content-type, authorization")
        assert conn.status == 204, "preflight status #{conn.status}"
        assert T.header(conn, "access-control-allow-origin") == "*"
        headers = (T.header(conn, "access-control-allow-headers") || "") |> String.downcase()
        for h <- ~w(content-type authorization), do: assert(headers =~ h, "Allow-Headers lacks #{h}: #{headers}")
        assert (T.header(conn, "access-control-allow-methods") || "") |> String.upcase() =~ "POST"
        assert T.header(conn, "access-control-allow-credentials") == nil, "never ACAC together with ACAO * (R14, Trap 9)"
        refute_received :oauth_config_read, "a preflight runs no endpoint logic (not even the config read)"
      end
    end

    test "OPTIONS takes no rate-limit token" do
      ip = T.unique_ip()
      T.drain!("oauth_revoke", ip, 60, 600, 1)
      for _ <- 1..3, do: assert(T.options("/oauth2/revoke", ip: ip).status == 204)
      no_db!()
      junk(ip: ip) |> T.assert_revoke_error(400, "invalid_request")
      junk(ip: ip) |> T.assert_revoke_error(429, "too_many_requests")
    end
  end

  describe "AC1/R14/Must #3 — a simple cross-origin POST (Origin, no preflight) gets ACAO * on EVERY status" do
    test "200, 400, 405, 404 (sub-path), 413, 429, 503 all carry ACAO * and never ACAC / Set-Cookie / WWW-Authenticate" do
      no_db!()
      o = [origin: "https://client.example.com"]
      ip = T.unique_ip()
      T.drain!("oauth_revoke", ip, 60, 600)

      conns = [
        malformed(o),
        junk(o),
        T.revoke(T.revoke_params(@hex64), [method: :get] ++ o),
        T.revoke(T.revoke_params(@hex64), [path: "/oauth2/revoke/x"] ++ o),
        T.revoke("token=" <> String.duplicate("a", 16_400), o),
        malformed([ip: ip] ++ o),
        unknown(o)
      ]

      for conn <- conns do
        assert T.header(conn, "access-control-allow-origin") == "*", "HTTP #{conn.status} lacks ACAO *"
        assert T.header(conn, "access-control-allow-credentials") == nil, "HTTP #{conn.status} carries ACAC"
        assert T.header(conn, "www-authenticate") == nil
        assert Plug.Conn.get_resp_header(conn, "set-cookie") == []
        assert (T.header(conn, "content-type") || "") =~ ~r{^application/json}i
      end

      assert Enum.map(conns, & &1.status) == [200, 400, 405, 404, 413, 429, 503]
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC2 / R8 / Must #18 — request format (all answered before any DB access)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC2/R8/Must #18 — request format (no DB)" do
    setup do
      no_db!()
      :ok
    end

    test "step 1: a non-empty query string => 400 invalid_request (the token is NOT revoked)" do
      T.revoke(T.revoke_params(@hex64), query: "token=" <> @hex64) |> T.assert_revoke_error(400, "invalid_request")
    end

    for {label, ct, body} <- [
          {"application/json", "application/json", ~s({"token":"abc"})},
          {"multipart/form-data", "multipart/form-data; boundary=xyz",
           "--xyz\r\nContent-Disposition: form-data; name=\"token\"\r\n\r\nabc\r\n--xyz--\r\n"},
          {"text/plain", "text/plain", "token=abc"},
          {"no content type", nil, "token=abc"}
        ] do
      test "step 2: #{label} => 400 invalid_request" do
        T.revoke(unquote(body), content_type: unquote(ct)) |> T.assert_revoke_error(400, "invalid_request")
      end
    end

    test "step 2: '; charset=UTF-8' and an upper-case media type are accepted (=> 200 for a malformed token)" do
      for ct <- ["application/x-www-form-urlencoded; charset=UTF-8", "Application/X-WWW-Form-Urlencoded", "APPLICATION/X-WWW-FORM-URLENCODED"] do
        T.revoke(T.revoke_params("junk"), content_type: ct) |> T.assert_revoke_ok()
      end
    end

    test "step 3: a body of 16 385 bytes => 413 invalid_request \"The request body is too large.\"" do
      body = "token=junk&pad=" <> String.duplicate("a", 16_385 - byte_size("token=junk&pad="))
      assert byte_size(body) == 16_385
      conn = T.revoke(body)
      T.assert_revoke_error(conn, 413, "invalid_request")
      assert T.json(conn)["error_description"] == "The request body is too large."
    end

    test "step 3: a body of exactly 16 384 bytes is read (200 for the malformed token)" do
      prefix = "token=junk&pad="
      body = prefix <> String.duplicate("a", 16_384 - byte_size(prefix))
      T.revoke(body) |> T.assert_revoke_ok()
    end

    test "step 4: malformed percent-encoding (%zz) => 400 invalid_request" do
      T.revoke("token=%zz") |> T.assert_revoke_error(400, "invalid_request")
    end

    test "step 5: a duplicated parameter => 400 (also identical values, also one empty occurrence)" do
      for body <- ["token=a&token=b", "token=#{@hex64}&token=#{@hex64}", "token=#{@hex64}&token=",
                   "token=x&client_id=a&client_id=b", "token=x&token_type_hint=access_token&token_type_hint="] do
        T.revoke(body) |> T.assert_revoke_error(400, "invalid_request")
      end
    end

    test "step 5: a control character (NUL / LF / C1) or invalid UTF-8 => 400 invalid_request" do
      for body <- ["token=a%00b", "token=a%0Ab", "token=x&client_id=%C2%85", "token=%FF%FE"] do
        T.revoke(body) |> T.assert_revoke_error(400, "invalid_request")
      end
    end

    test "step 7: token missing / empty => 400 invalid_request \"The token parameter is required.\"" do
      for body <- ["", "token=", "token_type_hint=access_token", "client_id=abc&token="] do
        conn = T.revoke(body)
        T.assert_revoke_error(conn, 400, "invalid_request")
        assert T.json(conn)["error_description"] == "The token parameter is required."
      end
    end

    test "step 8 / R5 / Must #7: tokens that are not 64 lowercase hex => 200 {} WITHOUT DB access" do
      for bad <- ["short", String.upcase(@hex64), String.slice(@hex64, 0, 63), @hex64 <> "0", "a.b.c",
                  "eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJ4In0.c2ln", " " <> @hex64, @hex64 <> " ", String.replace(@hex64, "a", "g", global: false)] do
        T.revoke(T.revoke_params(bad)) |> T.assert_revoke_ok()
      end
    end

    test "R8: a token with surrounding spaces is NOT trimmed (200 no-op, would otherwise hit the NoSuchRepo => 503)" do
      T.revoke("token=%20" <> @hex64 <> "%20") |> T.assert_revoke_ok()
    end

    test "R8: a percent-encoded well-formed token is DECODED before the format check (it reaches the lookup => 503 with NoSuchRepo)" do
      encoded = @hex64 |> String.graphemes() |> Enum.map_join(fn c -> "%" <> Base.encode16(c, case: :upper) end)
      T.revoke("token=" <> encoded) |> T.assert_revoke_5xx(503)
    end

    test "unknown parameters are ignored" do
      T.revoke(T.revoke_params("junk") ++ [{"foo", "bar"}, {"state", "s"}]) |> T.assert_revoke_ok()
    end

    test "error_description is fixed text: nothing from the request is reflected" do
      conn = T.revoke("token=x&client_id=REFLECTED-VALUE&client_id=y")
      T.assert_revoke_error(conn, 400, "invalid_request")
      refute conn.resp_body =~ "REFLECTED-VALUE"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC3 / R9 / Must #19 — rate limit {"oauth_revoke", ip}
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC3/R9/Must #19 — {\"oauth_revoke\", ip}: 60/min, burst 600, charged before any DB access" do
    test "an exhausted bucket => 429 too_many_requests + Retry-After; NoSuchRepo is never reached (not 503)" do
      ip = T.unique_ip()
      T.drain!("oauth_revoke", ip, 60, 600)
      no_db!()
      conn = T.revoke(T.revoke_params(@hex64), ip: ip)
      T.assert_revoke_error(conn, 429, "too_many_requests")
      assert T.json(conn) == %{"error" => "too_many_requests"}
      assert {secs, ""} = Integer.parse(T.header(conn, "retry-after") || "")
      assert secs > 0
    end

    test "junk requests (query string, wrong content type, duplicates, missing token) are charged and become 429" do
      ip = T.unique_ip()
      T.drain!("oauth_revoke", ip, 60, 600)
      no_db!()
      junk(ip: ip) |> T.assert_revoke_error(429, "too_many_requests")
      T.revoke("token=x", content_type: "application/json", ip: ip) |> T.assert_revoke_error(429, "too_many_requests")
      T.revoke("token=a&token=b", ip: ip) |> T.assert_revoke_error(429, "too_many_requests")
      T.revoke("", ip: ip) |> T.assert_revoke_error(429, "too_many_requests")
    end

    test "every request pays exactly one token (the 600th passes, the 601st is limited); other IPs unaffected" do
      ip = T.unique_ip()
      T.drain!("oauth_revoke", ip, 60, 600, 1)
      no_db!()
      malformed(ip: ip) |> T.assert_revoke_ok()
      malformed(ip: ip) |> T.assert_revoke_error(429, "too_many_requests")
      malformed() |> T.assert_revoke_ok()
    end

    test "the key never collides with the other OAuth families" do
      ip = T.unique_ip()
      for fam <- ~w(oauth_authorize oauth_callback oauth_register oauth_register_invalid oauth_register_loose oauth_token oauth_jwks),
          do: T.drain!(fam, ip, 10, 600)

      T.drain!("oauth_token_refresh", ip, 100, 1200)
      no_db!()
      malformed(ip: ip) |> T.assert_revoke_ok()
    end

    test "a drained revoke bucket does not limit the token endpoint" do
      ip = T.unique_ip()
      T.drain!("oauth_revoke", ip, 60, 600)
      no_db!()
      T.token_request([{"grant_type", "authorization_code"}], query: "x=1", ip: ip) |> T.assert_token_error(400, "invalid_request")
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC2 / AC6 / R6 / Must #4 — 5xx: DB unavailable, rescued exception
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC6/Must #4 — DB unavailable on the lookup => 503 {} + Retry-After: 5" do
    test "a well-formed token with an unavailable session repo => 503 {} (never a silent 200)" do
      Application.put_env(:nebu_http, :oauth_session_repo, T.NoSuchRepo)
      conn = unknown()
      T.assert_revoke_5xx(conn, 503)
      assert T.header(conn, "retry-after") == "5"
    end
  end

  describe "AC2/AC6/Must #4 — rescued exception => 500 {} + Retry-After (:oauth_revoke_test_hook)" do
    test "a raise inside the handler is rescued: 500, body exactly {}, Retry-After, revoke headers; type logged only" do
      T.inject_revoke_handler_fault!()

      log = ExUnit.CaptureLog.capture_log(fn -> send(self(), {:conn, unknown()}) end)
      assert_received {:conn, conn}
      T.assert_revoke_5xx(conn, 500)
      refute log =~ "atdd injected revoke-handler fault", "only the exception TYPE is logged, never its message"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC6 / R4 / R7 / R10 / Must #5, #15, #16, #17 — real sessions (integration)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC6/R4/R7/R10 — ignored credentials, unreachable errors, identical responses (integration)" do
    @describetag :integration

    setup do
      priv = T.setup_idp!()
      {:ok, priv: priv, cid: T.oauth_client!([@https])}
    end

    defp session(cid, priv) do
      d = "RV" <> String.upcase(T.rand(4))
      T.session!(cid, @https, priv, authorize: %{"scope" => T.matrix_scope(T.stable_prefix(), d)})
    end

    test "Must #17: client_secret, Authorization: Basic and Authorization: Bearer are ignored (200, revoked, never 401)",
         %{cid: cid, priv: priv} do
      variants = [
        {T.revoke_params(nil) ++ [{"client_secret", "s3cr3t"}], []},
        {[], [{"authorization", "Basic " <> Base.encode64(cid <> ":secret")}]},
        {[], [{"authorization", "Bearer " <> T.rand(32)}]}
      ]

      for {extra, headers} <- variants do
        s = session(cid, priv)
        params = [{"token", s.at}, {"client_id", cid}] ++ Enum.reject(extra, fn {k, _} -> k == "token" end)
        conn = T.revoke(params, headers: headers)
        refute conn.status == 401, "revoke authenticates no client (R4): never 401 invalid_client"
        T.assert_revoke_ok(conn)
        assert T.session_rows(s.user_id, s.device_id) == [], "revoked despite the ignored credential"
      end
    end

    test "Must #5 / R10: the 200 for a revoked token is byte-identical (body + headers) to the 200 for an unknown token",
         %{cid: cid, priv: priv} do
      s = session(cid, priv)
      ip = T.unique_ip()
      legacy = T.legacy_session!(T.provision_user!(), "RVL" <> String.upcase(T.rand(3)))
      hit = T.revoke(T.revoke_params(s.at), ip: ip) |> T.assert_revoke_ok()
      again = T.revoke(T.revoke_params(s.rt), ip: ip) |> T.assert_revoke_ok()
      miss = T.revoke(T.revoke_params(T.rand(32)), ip: ip) |> T.assert_revoke_ok()
      junk = T.revoke(T.revoke_params("junk"), ip: ip) |> T.assert_revoke_ok()
      leg = T.revoke(T.revoke_params(legacy.at), ip: ip) |> T.assert_revoke_ok()

      strip = fn conn -> conn.resp_headers |> Enum.reject(fn {k, _} -> k in ["date", "x-request-id"] end) |> Enum.sort() end
      # revoked, already revoked, unknown, malformed and legacy: one indistinguishable answer (R10)
      for other <- [again, miss, junk, leg] do
        assert other.resp_body == hit.resp_body
        assert strip.(other) == strip.(hit)
      end

      assert T.whoami(legacy.at).status == 200
    end

    test "R7: 401 invalid_client and 400 unsupported_token_type are never produced (hint matrix incl. id_token / junk)",
         %{cid: cid, priv: priv} do
      for hint <- [nil, "access_token", "refresh_token", "id_token", "urn:junk", "ACCESS_TOKEN"],
          client <- [nil, cid, "unknown-client-" <> T.rand()] do
        conn = T.revoke(T.revoke_params(T.rand(32), hint, client))
        refute conn.status == 401
        refute (conn.resp_body || "") =~ "unsupported_token_type"
        T.assert_revoke_ok(conn)
      end

      s = session(cid, priv)
      T.revoke(T.revoke_params(s.rt, "id_token", "no-such-client")) |> T.assert_revoke_ok()
      assert T.session_rows(s.user_id, s.device_id) == []
    end

    test "DB unavailable on the DELETE (blocked trigger) => 503 {} and the session stays fully intact (AT works, RT refreshes)",
         %{cid: cid, priv: priv} do
      s = session(cid, priv)
      T.seed_device_keys!(s.user_id, s.device_id)
      before = T.world_snapshot([s.user_id])
      _remove = T.block_session_deletes!(s.user_id)

      T.revoke(T.revoke_params(s.at)) |> T.assert_revoke_5xx(503)
      assert T.world_snapshot([s.user_id]) == before, "rolled back: no row of any table changed (device + keys too)"
      assert T.whoami(s.at).status == 200

      T.idp_refresh_ok(s.sub)
      T.refresh(cid, s.rt) |> T.assert_token_success()
    end

    test "rescued exception => 500 {} and the session is unchanged", %{cid: cid, priv: priv} do
      s = session(cid, priv)
      before = T.world_snapshot([s.user_id])
      T.inject_revoke_handler_fault!()
      T.revoke(T.revoke_params(s.at)) |> T.assert_revoke_5xx(500)
      assert T.world_snapshot([s.user_id]) == before
      assert T.whoami(s.at).status == 200
    end

    test "revoke of a REAL token while OAuth is disabled / with an invalid issuer ends the session (O5)", %{cid: cid, priv: priv} do
      for set <- [fn -> T.disable_oauth() end, fn -> T.enable_oauth("http://nebu.example.com") end] do
        T.enable_oauth()
        s = session(cid, priv)
        set.()
        T.revoke(T.revoke_params(s.rt)) |> T.assert_revoke_ok()
        assert T.session_rows(s.user_id, s.device_id) == []
        assert T.device_gone?(s.user_id, s.device_id)
      end
    end
  end

  describe "AC6 — never errcode / error_uri except the sub-path 404" do
    test "bodies of 200/400/405/413/429/503 carry neither errcode nor error_uri" do
      no_db!()
      ip = T.unique_ip()
      T.drain!("oauth_revoke", ip, 60, 600)

      for conn <- [malformed(), junk(), T.revoke([], method: :get), T.revoke("token=" <> String.duplicate("a", 16_400)),
                   malformed(ip: ip), unknown()] do
        body = T.json(conn)
        refute Map.has_key?(body, "errcode"), "HTTP #{conn.status} carries errcode"
        refute Map.has_key?(body, "error_uri")
      end
    end
  end
end
