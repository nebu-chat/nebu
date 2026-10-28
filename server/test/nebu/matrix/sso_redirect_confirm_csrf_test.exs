defmodule Nebu.Matrix.SsoRedirectConfirmCsrfTest do
  @moduledoc """
  ATDD acceptance tests for story `legacy-sso-redirect-confirmation` (G3-3), AC9 (browser binding, CSRF,
  fetch metadata, form parsing of `POST /_matrix/client/v3/login/sso/confirm`) and AC11 (rate limit).

  Pinned order (D9, since story sso-confirm-bucket-order the cookie classification comes FIRST), ALL before the pending entry is consumed:

      binding cookie present and well-formed (400 invalid_state, nothing charged)
      -> live entry? HIT: per-binding bucket (429) / MISS: per-IP miss bucket (429 or 400 invalid_state)
      -> form parse (400 invalid_request) -> decision in continue|cancel (400 invalid_request)
      -> Origin + fetch metadata (403 forbidden) -> CSRF token (403 forbidden) -> SsoStore.pop_confirm (single use, BEFORE minting)

  A refusal never consumes the entry, mints no token, keeps the cookie (except the definite `invalid_state`),
  and the 403s log ONE value-free WARNING. Plug level, IdP stubbed, no DB.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Nebu.OAuth.TestSupport, as: T

  @url "https://unlisted.example/cb"

  setup do
    T.reset_rate_limits()
    priv = T.setup_idp!()
    T.drop_confirm_entries!()
    T.drop_token_entries!()
    T.sso_no_trusted_origins!()
    T.sso_origins!([])
    original = Logger.level()
    Logger.configure(level: :debug)

    on_exit(fn ->
      Logger.configure(level: original)
      T.restore_rate_limits()
      T.drop_confirm_entries!()
    end)

    cb = T.legacy_callback!(priv, T.unique_sub(), @url)
    T.assert_confirm_redirect(cb)
    {_name, value, _raw} = T.sso_confirm_cookie(cb)
    pair = {T.sso_confirm_cookie_name(), value}

    {:ok, priv: priv, cb: cb, value: value, pair: pair, token: T.sso_confirm_csrf(value), tokens_before: T.sso_token_keys()}
  end

  defp post(ctx, extra \\ [], params \\ nil) do
    T.sso_confirm_post(params || [{"csrf_token", ctx.token}, {"decision", "continue"}], [cookie: ctx.pair] ++ extra)
  end

  defp intact!(ctx) do
    assert T.confirm_entry(ctx.value), "the pending entry must survive a refused POST"
    assert T.sso_token_keys() == ctx.tokens_before, "no token minted by a refused POST"
  end

  describe "the happy path of the same helper (so every refusal below differs in exactly one thing)" do
    test "cookie + token + same-origin navigation headers => Continue", ctx do
      T.assert_continue_redirect(post(ctx))
    end

    test "Origin absent => accepted (privacy-stripped browsers)", ctx do
      assert post(ctx, headers: [{"origin", nil}]).status == 303
    end

    test "Origin: null WITH Sec-Fetch-Site: same-origin => accepted (Referrer-Policy / sandbox fallback)", ctx do
      assert post(ctx, origin: "null").status == 303
    end

    test "all Sec-Fetch-* absent => accepted (older browsers)", ctx do
      conn = post(ctx, headers: [{"sec-fetch-site", nil}, {"sec-fetch-mode", nil}, {"sec-fetch-dest", nil}, {"sec-fetch-user", nil}])
      assert conn.status == 303
    end

    test "safari-fetch-metadata-compat: the Safari set (no Sec-Fetch-User, WebKit User-Agent) is accepted (lenient level)", ctx do
      conn = post(ctx, headers: [{"sec-fetch-user", nil}, {"user-agent", T.safari_user_agent()}])
      assert conn.status == 303
    end

    test "a Host with a port: the own origin is scheme + Host header (port kept unless default)", ctx do
      conn = post(ctx, host: "nebu.test:8008", origin: "http://nebu.test:8008")
      assert conn.status == 303
    end
  end

  describe "AC9 — CSRF token" do
    test "missing token => 403 forbidden page, entry intact, cookie kept", ctx do
      conn = post(ctx, [], [{"decision", "continue"}])
      T.assert_confirm_error(conn, 403, "forbidden")
      refute T.sso_confirm_cookie_cleared?(conn)
      intact!(ctx)
    end

    test "wrong token (also the token of ANOTHER flow's cookie) and an empty token => 403 forbidden, entry intact", ctx do
      T.assert_confirm_error(post(ctx, [], [{"csrf_token", "wrong"}, {"decision", "continue"}]), 403, "forbidden")
      T.assert_confirm_error(post(ctx, [], [{"csrf_token", T.sso_confirm_csrf("another-cookie-value")}, {"decision", "continue"}]), 403, "forbidden")
      T.assert_confirm_error(post(ctx, [], [{"csrf_token", ""}, {"decision", "continue"}]), 403, "forbidden")
      intact!(ctx)
    end

    test "the consent page's CSRF derivation does not work here (domain separation of the two flows)", ctx do
      consent_token = T.consent_csrf(ctx.value)
      T.assert_confirm_error(post(ctx, [], [{"csrf_token", consent_token}, {"decision", "continue"}]), 403, "forbidden")
      intact!(ctx)
    end

    test "the CSRF token is derived from the cookie, so the same token works for cancel too", ctx do
      conn = post(ctx, [], [{"csrf_token", ctx.token}, {"decision", "cancel"}])
      assert conn.status == 200
      assert conn.resp_body =~ ~s(data-result="cancelled")
    end
  end

  describe "AC9 — browser binding (cookie)" do
    test "no cookie => 400 invalid_state, entry intact", ctx do
      conn = T.sso_confirm_post([{"csrf_token", ctx.token}, {"decision", "continue"}], [])
      T.assert_confirm_error(conn, 400, "invalid_state")
      intact!(ctx)
    end

    test "a cookie of ANOTHER pending flow with this flow's token => 403 forbidden, BOTH entries intact", ctx do
      other_cb = T.legacy_callback!(ctx.priv, T.unique_sub(), "https://other.example/cb")
      {_, other_value, _} = T.sso_confirm_cookie(other_cb)
      conn = T.sso_confirm_post([{"csrf_token", ctx.token}, {"decision", "continue"}], cookie: other_cb)
      # the cookie is well-formed, so the CSRF token (derived from THIS cookie) is what fails: 403, not 400
      T.assert_confirm_error(conn, 403, "forbidden")
      assert T.confirm_entry(other_value), "the foreign entry is not consumed by a refused POST"
      intact!(ctx)
    end

    test "an unknown / malformed cookie value => 400 invalid_state, nothing consumed", ctx do
      for bad <- ["x", String.duplicate("a", 43), String.duplicate("a", 200), "%00"] do
        conn = T.sso_confirm_post([{"csrf_token", T.sso_confirm_csrf(bad)}, {"decision", "continue"}], cookie: {T.sso_confirm_cookie_name(), bad})
        T.assert_confirm_error(conn, 400, "invalid_state")
      end

      intact!(ctx)
    end

    test "on https only the __Host- cookie name counts: the plain-http name is ignored", ctx do
      conn = T.sso_confirm_post([{"csrf_token", ctx.token}, {"decision", "continue"}], cookie: ctx.pair, https: true)
      T.assert_confirm_error(conn, 400, "invalid_state")
      intact!(ctx)
    end

    test "on https the __Host- cookie works", ctx do
      cb = T.legacy_callback!(ctx.priv, T.unique_sub(), @url, https: true)
      T.assert_confirm_redirect(cb, https: true)
      T.assert_continue_redirect(T.confirm!(cb, :continue, https: true))
    end
  end

  describe "AC9 — Origin" do
    test "a foreign Origin WITHOUT same-origin fetch metadata => 403 forbidden, entry intact", ctx do
      for origin <- ["https://evil.example", "https://nebu.test", "http://nebu.test.evil.example", "http://evil.example/nebu.test", "http://nebu.test:8080", "http://test.local"] do
        T.assert_confirm_error(post(ctx, origin: origin, headers: [{"sec-fetch-site", nil}]), 403, "forbidden")
      end

      intact!(ctx)
    end

    test "MIN-2: a single Origin is accepted when Sec-Fetch-Site: same-origin is present (a proxy that strips the port from Host)", ctx do
      assert post(ctx, origin: "http://nebu.test:8008").status == 303
    end

    test "MIN-2: a single Origin equal to https://<server_name> is accepted even when Host differs and no fetch metadata is sent", ctx do
      # setup_idp! sets server_name "test.local"
      conn = post(ctx, origin: "https://test.local", headers: [{"sec-fetch-site", nil}, {"sec-fetch-mode", nil}, {"sec-fetch-dest", nil}, {"sec-fetch-user", nil}])
      assert conn.status == 303
    end

    test "MIN-2: the server_name origin keeps its port; the http scheme of the server name is not accepted", ctx do
      T.put_env_scoped(:server_name, "test.local:8448")
      cb = T.legacy_callback!(ctx.priv, T.unique_sub(), @url)
      {_, value, _} = T.sso_confirm_cookie(cb)
      pair = {T.sso_confirm_cookie_name(), value}
      body = [{"csrf_token", T.sso_confirm_csrf(value)}, {"decision", "continue"}]
      no_fetch = [{"sec-fetch-site", nil}]

      T.assert_confirm_error(T.sso_confirm_post(body, cookie: pair, origin: "https://test.local", headers: no_fetch), 403, "forbidden")
      T.assert_confirm_error(T.sso_confirm_post(body, cookie: pair, origin: "http://test.local:8448", headers: no_fetch), 403, "forbidden")
      assert T.confirm_entry(value)
      assert T.sso_confirm_post(body, cookie: pair, origin: "https://test.local:8448", headers: no_fetch).status == 303
    end

    test "MIN-2: a cross-origin Origin with cross-site fetch metadata is still refused, whatever the server name", ctx do
      T.assert_confirm_error(post(ctx, origin: "https://test.local", headers: [{"sec-fetch-site", "cross-site"}]), 403, "forbidden")
      intact!(ctx)
    end

    test "on https the own origin is https://<Host>: an http Origin is foreign", ctx do
      cb = T.legacy_callback!(ctx.priv, T.unique_sub(), @url, https: true)
      {_, value, _} = T.sso_confirm_cookie(cb)
      pair = {T.sso_confirm_cookie_name(true), value}
      body = [{"csrf_token", T.sso_confirm_csrf(value)}, {"decision", "continue"}]
      T.assert_confirm_error(T.sso_confirm_post(body, cookie: pair, https: true, origin: "http://nebu.test", headers: [{"sec-fetch-site", nil}]), 403, "forbidden")
      assert T.confirm_entry(value)
      assert T.sso_confirm_post(body, cookie: pair, https: true, origin: "https://nebu.test").status == 303
    end

    test "Origin: null WITHOUT Sec-Fetch-Site: same-origin => 403 forbidden", ctx do
      T.assert_confirm_error(post(ctx, origin: "null", headers: [{"sec-fetch-site", nil}]), 403, "forbidden")
      T.assert_confirm_error(post(ctx, origin: "null", headers: [{"sec-fetch-site", "cross-site"}]), 403, "forbidden")
      intact!(ctx)
    end

    test "two Origin headers => 403 forbidden", ctx do
      conn = post(ctx, headers: [{"origin", nil}], extra_headers: [{"origin", "http://nebu.test"}, {"origin", "http://nebu.test"}])
      T.assert_confirm_error(conn, 403, "forbidden")
      intact!(ctx)
    end
  end

  describe "AC9 — fetch metadata" do
    for site <- ["cross-site", "same-site", "none"] do
      test "Sec-Fetch-Site: #{site} => 403 forbidden, entry intact", ctx do
        T.assert_confirm_error(post(ctx, headers: [{"sec-fetch-site", unquote(site)}]), 403, "forbidden")
        intact!(ctx)
      end
    end

    test "Sec-Fetch-Mode: cors / no-cors / same-origin (fetch, XHR) => 403 forbidden", ctx do
      for mode <- ["cors", "no-cors", "same-origin", "websocket"] do
        T.assert_confirm_error(post(ctx, headers: [{"sec-fetch-mode", mode}]), 403, "forbidden")
      end

      intact!(ctx)
    end

    test "Sec-Fetch-Dest: empty / iframe / frame (not a top-level document) => 403 forbidden", ctx do
      for dest <- ["empty", "iframe", "frame", "object", "embed"] do
        T.assert_confirm_error(post(ctx, headers: [{"sec-fetch-dest", dest}]), 403, "forbidden")
      end

      intact!(ctx)
    end

    test "Sec-Fetch-User: ?0 => 403 forbidden (not user-activated)", ctx do
      T.assert_confirm_error(post(ctx, headers: [{"sec-fetch-user", "?0"}]), 403, "forbidden")
      intact!(ctx)
    end

    test "a repeated Sec-Fetch header (each at most once) => 403 forbidden", ctx do
      conn = post(ctx, extra_headers: [{"sec-fetch-site", "same-origin"}])
      T.assert_confirm_error(conn, 403, "forbidden")
      intact!(ctx)
    end

    test "a refused POST is followed by a valid one: the entry was never consumed", ctx do
      T.assert_confirm_error(post(ctx, headers: [{"sec-fetch-site", "cross-site"}]), 403, "forbidden")
      T.assert_continue_redirect(post(ctx))
    end
  end

  describe "AC9 — body shape => 400 invalid_request, nothing consumed, cookie kept" do
    test "a duplicated field (csrf_token or decision)", ctx do
      for body <- ["csrf_token=#{ctx.token}&decision=continue&decision=cancel", "csrf_token=#{ctx.token}&csrf_token=#{ctx.token}&decision=continue"] do
        conn = post(ctx, [], body)
        T.assert_confirm_error(conn, 400, "invalid_request")
        refute T.sso_confirm_cookie_cleared?(conn)
      end

      intact!(ctx)
    end

    test "malformed percent-encoding", ctx do
      T.assert_confirm_error(post(ctx, [], "csrf_token=%zz&decision=continue"), 400, "invalid_request")
      intact!(ctx)
    end

    test "a non-form content type (JSON, multipart, text, none)", ctx do
      for ct <- ["application/json", "multipart/form-data; boundary=x", "text/plain", nil] do
        T.assert_confirm_error(post(ctx, [content_type: ct], "csrf_token=#{ctx.token}&decision=continue"), 400, "invalid_request")
      end

      intact!(ctx)
    end

    test "a JSON body is not parsed by the router: 400 invalid_request, body_params stay unfetched (AC12)", ctx do
      body = Jason.encode!(%{"csrf_token" => ctx.token, "decision" => "continue"})
      T.assert_confirm_error(post(ctx, [content_type: "application/json"], body), 400, "invalid_request")
      intact!(ctx)
    end

    test "an unknown or missing decision", ctx do
      for body <- ["csrf_token=#{ctx.token}&decision=maybe", "csrf_token=#{ctx.token}&decision=", "csrf_token=#{ctx.token}", "csrf_token=#{ctx.token}&decision=CONTINUE", "csrf_token=#{ctx.token}&decision=allow"] do
        T.assert_confirm_error(post(ctx, [], body), 400, "invalid_request")
      end

      intact!(ctx)
    end

    test "a query string on the POST (even a harmless one)", ctx do
      T.assert_confirm_error(post(ctx, query: "x=1"), 400, "invalid_request")
      T.assert_confirm_error(post(ctx, query: "decision=continue"), 400, "invalid_request")
      intact!(ctx)
    end

    test "a body over 16 KiB", ctx do
      T.assert_confirm_error(post(ctx, [], "csrf_token=#{ctx.token}&decision=continue&pad=" <> String.duplicate("a", 16_400)), 400, "invalid_request")
      intact!(ctx)
    end

    test "a control character in a value", ctx do
      T.assert_confirm_error(post(ctx, [], "csrf_token=#{ctx.token}&decision=continue%00"), 400, "invalid_request")
      intact!(ctx)
    end
  end

  describe "AC9 — the checks run in the D9 order" do
    test "a bad Origin AND a bad body => 400 invalid_request (the form parse runs first)", ctx do
      conn = post(ctx, [origin: "https://evil.example"], "csrf_token=#{ctx.token}&decision=maybe")
      T.assert_confirm_error(conn, 400, "invalid_request")
      intact!(ctx)
    end

    test "a bad Origin AND a missing cookie => 400 invalid_state (story sso-confirm-bucket-order D3: the cookie classification runs first)", ctx do
      conn = T.sso_confirm_post([{"csrf_token", ctx.token}, {"decision", "continue"}], origin: "https://evil.example", headers: [{"sec-fetch-site", nil}])
      T.assert_confirm_error(conn, 400, "invalid_state")
      intact!(ctx)
    end

    test "a bad Origin WITH a live cookie => 403 (Origin and fetch metadata run before the CSRF check and the pop)", ctx do
      conn = post(ctx, origin: "https://evil.example", headers: [{"sec-fetch-site", nil}])
      T.assert_confirm_error(conn, 403, "forbidden")
      intact!(ctx)
    end

    test "a missing cookie AND a bad CSRF token => 400 invalid_state (the cookie runs before the CSRF check)", ctx do
      conn = T.sso_confirm_post([{"csrf_token", "wrong"}, {"decision", "continue"}], [])
      T.assert_confirm_error(conn, 400, "invalid_state")
      intact!(ctx)
    end

    test "a cookie-less POST with a bad body is invalid_state (the cookie classification runs first, story sso-confirm-bucket-order D3)", ctx do
      T.assert_confirm_error(T.sso_confirm_post("garbage", []), 400, "invalid_state")
      intact!(ctx)
    end

    test "an exhausted per-binding bucket AND a bad body => 429 (the binding's rate limit runs before the body checks)", ctx do
      T.drain_binding!(ctx.value)
      T.assert_confirm_error(post(ctx, [], "garbage"), 429, "rate_limited")
      intact!(ctx)
    end
  end

  describe "AC9 — a 403 logs ONE value-free WARNING" do
    test "no cookie, token, Origin or header value reaches the log; the text is the documented one", ctx do
      log =
        capture_log(fn ->
          send(self(), {:conn, post(ctx, origin: "https://evil.example.org", headers: [{"sec-fetch-site", "cross-site"}])})
        end)

      assert_received {:conn, conn}
      T.assert_confirm_error(conn, 403, "forbidden")
      assert log =~ "[warning] matrix SSO: confirmation request refused (the origin, fetch-metadata or CSRF check failed)"
      assert length(Regex.scan(~r/\[warning\]/, log)) == 1, "exactly one WARNING, got: #{log}"
      refute log =~ ctx.value, "the cookie value"
      refute log =~ ctx.token, "the CSRF token"
      refute log =~ "evil.example.org", "the Origin value"
      refute log =~ "cross-site"
    end

    test "a wrong CSRF token logs the same single WARNING without any value", ctx do
      log = capture_log(fn -> send(self(), {:conn, post(ctx, [], [{"csrf_token", "wrong-csrf-marker"}, {"decision", "continue"}])}) end)
      assert_received {:conn, conn}
      T.assert_confirm_error(conn, 403, "forbidden")
      assert length(Regex.scan(~r/\[warning\] matrix SSO: confirmation request refused/, log)) == 1
      refute log =~ "wrong-csrf-marker"
      refute log =~ ctx.value
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC11 — rate limit
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC11 (story sso-confirm-bucket-order, cv) — the cookie decides how a request is counted" do
    test "an exhausted per-binding bucket => 429 + Retry-After on GET and POST, cookie kept, nothing consumed", ctx do
      T.drain_binding!(ctx.value)

      get = T.sso_confirm_get(ctx.pair)
      T.assert_confirm_error(get, 429, "rate_limited")
      assert T.header(get, "retry-after") =~ ~r/\A\d+\z/

      post = post(ctx)
      T.assert_confirm_error(post, 429, "rate_limited")
      assert T.header(post, "retry-after") =~ ~r/\A\d+\z/
      refute T.sso_confirm_cookie_cleared?(post), "the cookie stays so the same browser can retry"
      intact!(ctx)
    end

    test "another binding is unaffected by an exhausted one", ctx do
      T.drain_binding!(ctx.value)
      cb2 = T.legacy_callback!(ctx.priv, T.unique_sub(), @url)
      {_, value2, _} = T.sso_confirm_cookie(cb2)
      assert T.sso_confirm_get({T.sso_confirm_cookie_name(), value2}).status == 200
    end

    test "GET and POST take from the SAME per-binding bucket", ctx do
      T.drain_binding!(ctx.value, 1)
      assert T.sso_confirm_get(ctx.pair).status == 200, "the last token"
      T.assert_confirm_error(post(ctx), 429, "rate_limited")
      intact!(ctx)
    end

    test "a real user needs few requests: the page, a reload and the decision pass inside the per-binding budget", ctx do
      assert T.sso_confirm_get(ctx.pair).status == 200
      assert T.sso_confirm_get(ctx.pair).status == 200
      T.assert_continue_redirect(post(ctx))
    end

    test "the callback and POST /login buckets are unchanged by the confirm buckets", ctx do
      ip = T.unique_ip()
      T.drain!("sso_confirm_miss", ip, 10, 600)
      T.drain_binding!(ctx.value)
      cb = T.legacy_callback!(ctx.priv, T.unique_sub(), @url, ip: ip)
      T.assert_confirm_redirect(cb)
      login = T.sso_token_login("not-a-token", ip: ip)
      assert login.status != 429
    end
  end

  describe "cv — a flood without a live binding cannot lock the page (G3-2 collapse)" do
    test "with the old per-address bucket drained a live user gets the page, Continue and Cancel", ctx do
      ip = T.unique_ip()
      T.drain!("sso_confirm", ip, 10, 600)
      T.drain!("sso_confirm_miss", ip, 10, 600)

      assert T.sso_confirm_get(ctx.pair, ip: ip).status == 200
      T.assert_continue_redirect(post(ctx, ip: ip))

      cb2 = T.legacy_callback!(ctx.priv, T.unique_sub(), @url, ip: ip)
      {_, value2, _} = T.sso_confirm_cookie(cb2)
      pair2 = {T.sso_confirm_cookie_name(), value2}
      cancel = T.sso_confirm_post([{"csrf_token", T.sso_confirm_csrf(value2)}, {"decision", "cancel"}], cookie: pair2, ip: ip)
      assert cancel.status == 200
    end

    test "no cookie / a malformed one: invalid_state and NO bucket is charged", ctx do
      ip = T.unique_ip()
      T.drain!("sso_confirm_miss", ip, 10, 600, 1)

      for _ <- 1..30 do
        T.assert_confirm_error(T.sso_confirm_get(nil, ip: ip), 400, "invalid_state")
        T.assert_confirm_error(T.sso_confirm_post([{"csrf_token", "x"}, {"decision", "continue"}], ip: ip), 400, "invalid_state")
        T.assert_confirm_error(T.sso_confirm_get({T.sso_confirm_cookie_name(), "short"}, ip: ip), 400, "invalid_state")
      end

      # exactly ONE token was left: the first unknown well-formed cookie spends it (invalid_state), the next one is limited
      unknown = {T.sso_confirm_cookie_name(), String.duplicate("A", 43)}
      T.assert_confirm_error(T.sso_confirm_get(unknown, ip: ip), 400, "invalid_state")
      T.assert_confirm_error(T.sso_confirm_get(unknown, ip: ip), 429, "rate_limited")
      intact!(ctx)
    end

    test "unknown cookies are charged to the per-address MISS bucket (429, cookie kept); a live binding is still served", ctx do
      ip = T.unique_ip()
      T.drain!("sso_confirm_miss", ip, 10, 600)
      unknown = {T.sso_confirm_cookie_name(), String.duplicate("B", 43)}

      limited = T.sso_confirm_get(unknown, ip: ip)
      T.assert_confirm_error(limited, 429, "rate_limited")
      assert T.header(limited, "retry-after") =~ ~r/\A\d+\z/
      refute T.sso_confirm_cookie_cleared?(limited)
      T.assert_confirm_error(T.sso_confirm_post([{"csrf_token", "x"}, {"decision", "continue"}], cookie: unknown, ip: ip), 429, "rate_limited")

      assert T.sso_confirm_get(ctx.pair, ip: ip).status == 200, "a live binding is never denied by the miss bucket"
      T.assert_continue_redirect(post(ctx, ip: ip))
    end

    test "per-binding budget is exactly 60: the 61st request answers 429 (about 30 s), cookie kept, others unaffected", ctx do
      for n <- 1..60, do: assert(T.sso_confirm_get(ctx.pair).status == 200, "request #{n}")

      limited = T.sso_confirm_get(ctx.pair)
      T.assert_confirm_error(limited, 429, "rate_limited")
      assert String.to_integer(T.header(limited, "retry-after")) in 25..35
      refute T.sso_confirm_cookie_cleared?(limited), "a 429 keeps the cookie (GET too)"
      intact!(ctx)

      {_, value2, _} = T.sso_confirm_cookie(T.legacy_callback!(ctx.priv, T.unique_sub(), @url))
      assert T.sso_confirm_get({T.sso_confirm_cookie_name(), value2}).status == 200
    end

    test "miss budget is exactly 600 per address: the 601st unknown cookie answers 429, a live binding is served", ctx do
      ip = T.unique_ip()
      unknown = {T.sso_confirm_cookie_name(), String.duplicate("D", 43)}
      for n <- 1..600, do: assert(T.sso_confirm_get(unknown, ip: ip).status == 400, "miss #{n}")

      limited = T.sso_confirm_get(unknown, ip: ip)
      T.assert_confirm_error(limited, 429, "rate_limited")
      assert String.to_integer(T.header(limited, "retry-after")) in 1..10
      assert T.sso_confirm_get(ctx.pair, ip: ip).status == 200
    end

    test "a cookie-less or malformed request leaves every rate-limit bucket untouched", ctx do
      table = :nebu_http_rate_limit_buckets
      # only the buckets of this page (other processes of the node may touch unrelated buckets while the test runs)
      snapshot = fn -> if(:ets.whereis(table) == :undefined, do: [], else: :ets.tab2list(table)) |> Enum.filter(fn entry -> match?({{family, _}, _, _} when family in ["sso_confirm", "sso_confirm_miss"], entry) or match?({{family, _}, _} when family in ["sso_confirm", "sso_confirm_miss"], entry) end) |> Enum.sort() end
      before = snapshot.()
      name = T.sso_confirm_cookie_name()

      for cookie <- [nil, {name, "short"}, {name, String.duplicate("A", 42)}, {name, String.duplicate("A", 44)}, {name, String.duplicate("A", 42) <> "+"}, {name, String.duplicate("A", 42) <> "="}, {name, ""}] do
        T.assert_confirm_error(T.sso_confirm_get(cookie), 400, "invalid_state")
        T.assert_confirm_error(T.sso_confirm_post([{"csrf_token", "x"}, {"decision", "continue"}], cookie: cookie), 400, "invalid_state")
      end

      assert snapshot.() == before, "no bucket was created or charged"
      intact!(ctx)
    end

    test "a MISSING cookie does not clear the user's cookie (a cross-site POST carries no Lax cookie), a MALFORMED one is cleared", _ctx do
      missing = T.sso_confirm_post([{"csrf_token", "x"}, {"decision", "continue"}], [])
      T.assert_confirm_error(missing, 400, "invalid_state")
      refute T.sso_confirm_cookie_cleared?(missing)

      malformed = T.sso_confirm_get({T.sso_confirm_cookie_name(), "short"})
      T.assert_confirm_error(malformed, 400, "invalid_state")
      assert T.sso_confirm_cookie_cleared?(malformed)
    end

    test "a POST with an unknown well-formed cookie is invalid_state (cleared) whatever its body or Origin (D3)", _ctx do
      unknown = {T.sso_confirm_cookie_name(), String.duplicate("E", 43)}

      for params <- ["garbage", [{"csrf_token", "x"}, {"decision", "maybe"}], [{"csrf_token", "x"}, {"decision", "continue"}]],
          extra <- [[], [origin: "https://evil.example", headers: [{"sec-fetch-site", nil}]]] do
        conn = T.sso_confirm_post(params, [cookie: unknown] ++ extra)
        T.assert_confirm_error(conn, 400, "invalid_state")
        assert T.sso_confirm_cookie_cleared?(conn)
      end
    end

    test "a consumed binding is a miss: invalid_state with the cookie cleared, charged to the miss bucket (not to a binding bucket)", ctx do
      T.assert_continue_redirect(post(ctx))
      ip = T.unique_ip()
      T.drain!("sso_confirm_miss", ip, 10, 600, 1)

      again = T.sso_confirm_get(ctx.pair, ip: ip)
      T.assert_confirm_error(again, 400, "invalid_state")
      assert T.sso_confirm_cookie_cleared?(again)
      T.assert_confirm_error(T.sso_confirm_get(ctx.pair, ip: ip), 429, "rate_limited")
    end

    test "an expired binding is a miss as well (invalid_state, cleared)", ctx do
      T.drop_confirm_entries!()
      expired = T.sso_confirm_get(ctx.pair)
      T.assert_confirm_error(expired, 400, "invalid_state")
      assert T.sso_confirm_cookie_cleared?(expired)
    end

    test "a flood of unknown cookies does not charge a live binding's bucket (100 misses, then 55 live requests all pass)", ctx do
      ip = T.unique_ip()
      for i <- 1..100, do: T.sso_confirm_get({T.sso_confirm_cookie_name(), String.pad_leading(Integer.to_string(i), 43, "C")}, ip: ip)
      for n <- 1..55, do: assert(T.sso_confirm_get(ctx.pair, ip: ip).status == 200, "live request #{n}")
    end
  end

  describe "cv — static: the per-address bucket is never charged before the cookie is classified" do
    test "SsoConfirm has no bucket call that precedes the cookie check, and the miss bucket has its own family" do
      src = File.read!(Path.expand("../../../lib/nebu/matrix/sso_confirm.ex", __DIR__))
      [_, rest] = String.split(src, "  def handle(conn) do", parts: 2)
      handle = rest |> String.split("\n  defp ", parts: 2) |> hd()
      refute handle =~ "RateLimit.take", "handle/1 must classify the cookie before charging anything"
      assert handle =~ "binding_cookie(conn)"
    end
  end
end
