defmodule Nebu.OAuth.OAuthConsentCsrfTest do
  @moduledoc """
  Acceptance tests for story `oauth-authorize-freshness` (P3), AC7 (FR8): browser binding,
  CSRF token and fetch metadata of `POST /oauth2/consent`.

  Pinned (FR8) order, all BEFORE the consumption of the row: `FormPost.parse/1` (form body, no query
  string, one `csrf_token`, one `decision` in `allow|deny`, <= 16 KiB) => `400 invalid_request`; the
  `Origin` header (absent, the issuer origin, or `null` ONLY with `Sec-Fetch-Site: same-origin`) and the
  fetch metadata (`Sec-Fetch-Site` absent / `same-origin`; `Sec-Fetch-Mode` / `-Dest` / `-User` absent /
  `navigate` / `document` / `?1`) => `403 forbidden`; the consent cookie (missing / malformed / unknown
  => `400 invalid_state`); the CSRF token (constant-time compare against
  `base64url(SHA-256("nebu-oauth-consent-csrf:" <> cookie))`, nothing stored) => `403 forbidden`.
  A failure never consumes the row and logs ONE value-free WARNING.

  The Origin / navigation checks move out of `Nebu.OAuth.Account` into `Nebu.OAuth.BrowserPost`
  (one copy, FR8); `oauth_account_*` tests keep proving the story-6 behaviour through HTTP.
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  import ExUnit.CaptureLog
  alias Nebu.OAuth.TestSupport, as: T

  @https "https://app.example.com/cb"
  @lib Path.expand("../../../lib/nebu", __DIR__)

  setup do
    T.enable_oauth()
    T.reset_rate_limits()
    priv = T.setup_idp!()
    on_exit(fn ->
      T.clear_oauth_config()
      T.restore_rate_limits()
    end)

    cid = T.oauth_client!([@https], client_name: "CSRF App", client_uri: "https://app.example.com")
    flow = T.start_flow(cid, @https)
    cb = T.finish_flow(flow, priv, claims: %{"sub" => T.unique_sub()})
    T.assert_consent_redirect(cb)
    {_name, value, _raw} = T.consent_cookie(cb)

    {:ok, priv: priv, cid: cid, flow: flow, cb: cb, value: value, pair: {"nebu_oauth_consent", value}, token: T.consent_csrf(value)}
  end

  defp post(ctx, extra \\ [], params \\ nil) do
    T.consent_post(params || [{"csrf_token", ctx.token}, {"decision", "allow"}], [cookie: ctx.pair] ++ extra)
  end

  defp intact!(ctx) do
    assert T.consent_row(ctx.value), "the consent row must survive a refused POST"
    assert T.count_for("oauth_codes", ctx.cid) == 0, "no code issued"
  end

  describe "the happy path of the same helper (so every refusal below differs in exactly one thing)" do
    test "cookie + token + same-origin navigation headers => Allow", ctx do
      conn = post(ctx)
      T.assert_allow_redirect(conn, @https, "fragment", T.param(ctx.flow.pairs, "state"))
    end

    test "Origin absent => accepted (privacy-stripped browsers)", ctx do
      conn = post(ctx, headers: [{"origin", nil}])
      assert conn.status == 303
    end

    test "Origin: null WITH Sec-Fetch-Site: same-origin => accepted (Referrer-Policy / sandbox fallback)", ctx do
      conn = post(ctx, origin: "null")
      assert conn.status == 303
    end

    test "all Sec-Fetch-* absent => accepted (older browsers)", ctx do
      conn = post(ctx, headers: [{"sec-fetch-site", nil}, {"sec-fetch-mode", nil}, {"sec-fetch-dest", nil}, {"sec-fetch-user", nil}])
      assert conn.status == 303
    end
  end

  describe "story safari-fetch-metadata-compat — the consent POST is at the lenient level" do
    test "the Safari set (Site / Mode / Dest, a WebKit User-Agent, NO Sec-Fetch-User) => Allow works: nothing to fix here", ctx do
      conn = post(ctx, headers: [{"sec-fetch-user", nil}, {"user-agent", T.safari_user_agent()}])
      T.assert_allow_redirect(conn, @https, "fragment", T.param(ctx.flow.pairs, "state"))
    end

    test "the page has no click-proof field and no strict requirement: a Safari Deny works too", ctx do
      conn = post(ctx, [headers: [{"sec-fetch-user", nil}, {"user-agent", T.safari_user_agent()}]], [{"csrf_token", ctx.token}, {"decision", "deny"}])
      T.assert_deny_redirect(conn, @https, "fragment", T.param(ctx.flow.pairs, "state"))
    end
  end

  describe "AC7 — CSRF token" do
    test "missing token => 403 forbidden page, row intact", ctx do
      T.assert_page(post(ctx, [], [{"decision", "allow"}]), 403, "forbidden")
      intact!(ctx)
    end

    test "wrong token (also the token of ANOTHER flow's cookie) => 403 forbidden, row intact", ctx do
      T.assert_page(post(ctx, [], [{"csrf_token", "wrong"}, {"decision", "allow"}]), 403, "forbidden")
      T.assert_page(post(ctx, [], [{"csrf_token", T.consent_csrf("another-cookie-value")}, {"decision", "allow"}]), 403, "forbidden")
      T.assert_page(post(ctx, [], [{"csrf_token", ""}, {"decision", "allow"}]), 403, "forbidden")
      intact!(ctx)
    end

    test "a token for a DENY decision cannot be reused to forge anything else: decision is a separate field", ctx do
      conn = post(ctx, [], [{"csrf_token", ctx.token}, {"decision", "deny"}])
      T.assert_deny_redirect(conn, @https, "fragment", T.param(ctx.flow.pairs, "state"))
    end
  end

  describe "AC7 — browser binding (cookie)" do
    test "no cookie => 400 invalid_state, row intact", ctx do
      conn = T.consent_post([{"csrf_token", ctx.token}, {"decision", "allow"}], [])
      T.assert_page(conn, 400, "invalid_state")
      intact!(ctx)
    end

    test "a cookie of ANOTHER flow with this flow's token => refused, BOTH rows intact", ctx do
      other = T.insert_consent!(ctx.cid, user_id: T.provision_user!())
      conn = T.consent_post([{"csrf_token", ctx.token}, {"decision", "allow"}], cookie: other.cookie)
      # the cookie is well-formed, so the CSRF token (derived from THIS cookie) is what fails: 403, not 400
      T.assert_page(conn, 403, "forbidden")
      assert T.consent_row(other.value), "the foreign row is not consumed by a refused POST"
      intact!(ctx)
    end

    test "an unknown / malformed cookie value => 400 invalid_state, nothing consumed", ctx do
      for bad <- ["x", String.duplicate("a", 43), String.duplicate("a", 200), "%00"] do
        conn = T.consent_post([{"csrf_token", T.consent_csrf(bad)}, {"decision", "allow"}], cookie: {"nebu_oauth_consent", bad})
        T.assert_page(conn, 400, "invalid_state")
      end

      intact!(ctx)
    end

    test "on https only the __Host- cookie name counts: the plain-http name is ignored", ctx do
      conn = T.consent_post([{"csrf_token", ctx.token}, {"decision", "allow"}], cookie: ctx.pair, https: true)
      T.assert_page(conn, 400, "invalid_state")
      intact!(ctx)
    end
  end

  describe "AC7 — Origin" do
    test "a foreign Origin => 403 forbidden, row intact", ctx do
      T.assert_page(post(ctx, origin: "https://evil.example"), 403, "forbidden")
      T.assert_page(post(ctx, origin: "http://nebu.example.com"), 403, "forbidden")
      T.assert_page(post(ctx, origin: "https://nebu.example.com.evil.example"), 403, "forbidden")
      intact!(ctx)
    end

    test "Origin: null WITHOUT Sec-Fetch-Site: same-origin => 403 forbidden", ctx do
      T.assert_page(post(ctx, origin: "null", headers: [{"sec-fetch-site", nil}]), 403, "forbidden")
      T.assert_page(post(ctx, origin: "null", headers: [{"sec-fetch-site", "cross-site"}]), 403, "forbidden")
      intact!(ctx)
    end
  end

  describe "AC7 — fetch metadata" do
    for site <- ["cross-site", "same-site"] do
      test "Sec-Fetch-Site: #{site} => 403 forbidden, row intact", ctx do
        T.assert_page(post(ctx, headers: [{"sec-fetch-site", unquote(site)}]), 403, "forbidden")
        intact!(ctx)
      end
    end

    test "Sec-Fetch-Mode: cors / no-cors / same-origin (fetch, XHR) => 403 forbidden", ctx do
      for mode <- ["cors", "no-cors", "same-origin", "websocket"] do
        T.assert_page(post(ctx, headers: [{"sec-fetch-mode", mode}]), 403, "forbidden")
      end

      intact!(ctx)
    end

    test "Sec-Fetch-Dest: empty / iframe / frame (not a top-level document) => 403 forbidden", ctx do
      for dest <- ["empty", "iframe", "frame", "object", "embed"] do
        T.assert_page(post(ctx, headers: [{"sec-fetch-dest", dest}]), 403, "forbidden")
      end

      intact!(ctx)
    end

    test "Sec-Fetch-User: ?0 => 403 forbidden (not user-activated)", ctx do
      T.assert_page(post(ctx, headers: [{"sec-fetch-user", "?0"}]), 403, "forbidden")
      intact!(ctx)
    end

    test "a refused POST is followed by a valid one: the row was never consumed", ctx do
      T.assert_page(post(ctx, headers: [{"sec-fetch-site", "cross-site"}]), 403, "forbidden")
      conn = post(ctx)
      T.assert_allow_redirect(conn, @https, "fragment", T.param(ctx.flow.pairs, "state"))
    end
  end

  describe "AC7 — body shape => 400 invalid_request, nothing consumed" do
    test "a duplicated field (csrf_token or decision)", ctx do
      for body <- ["csrf_token=#{ctx.token}&decision=allow&decision=deny", "csrf_token=#{ctx.token}&csrf_token=#{ctx.token}&decision=allow"] do
        T.assert_page(post(ctx, [], body), 400, "invalid_request")
      end

      intact!(ctx)
    end

    test "malformed percent-encoding", ctx do
      T.assert_page(post(ctx, [], "csrf_token=%zz&decision=allow"), 400, "invalid_request")
      intact!(ctx)
    end

    test "a non-form content type (JSON, multipart, none)", ctx do
      for ct <- ["application/json", "multipart/form-data; boundary=x", "text/plain", nil] do
        T.assert_page(post(ctx, [content_type: ct], "csrf_token=#{ctx.token}&decision=allow"), 400, "invalid_request")
      end

      intact!(ctx)
    end

    test "an unknown or missing decision", ctx do
      for body <- ["csrf_token=#{ctx.token}&decision=maybe", "csrf_token=#{ctx.token}&decision=", "csrf_token=#{ctx.token}", "csrf_token=#{ctx.token}&decision=ALLOW"] do
        T.assert_page(post(ctx, [], body), 400, "invalid_request")
      end

      intact!(ctx)
    end

    test "a query string on the POST (even a harmless one)", ctx do
      T.assert_page(post(ctx, [query: "x=1"]), 400, "invalid_request")
      T.assert_page(post(ctx, [query: "decision=allow"]), 400, "invalid_request")
      intact!(ctx)
    end

    test "a body over 16 KiB", ctx do
      T.assert_page(post(ctx, [], "csrf_token=#{ctx.token}&decision=allow&pad=" <> String.duplicate("a", 16_400)), 400, "invalid_request")
      intact!(ctx)
    end
  end

  describe "AC7 — a refusal logs ONE value-free WARNING" do
    test "no cookie, token, Origin or header value reaches the log", ctx do
      log =
        capture_log(fn ->
          send(self(), {:conn, post(ctx, origin: "https://evil.example.org", headers: [{"sec-fetch-site", "cross-site"}])})
        end)

      assert_received {:conn, conn}
      T.assert_page(conn, 403, "forbidden")
      assert log =~ "[warning]"
      assert length(Regex.scan(~r/\[warning\]/, log)) == 1, "exactly one WARNING, got: #{log}"
      refute log =~ ctx.value, "the cookie value"
      refute log =~ ctx.token, "the CSRF token"
      refute log =~ "evil.example.org", "the Origin value"
      refute log =~ "cross-site"
    end
  end

  describe "FR8 — one copy of the Origin / navigation checks (Nebu.OAuth.BrowserPost)" do
    test "Nebu.OAuth.BrowserPost exists; account.ex no longer carries its own copy; consent.ex uses it" do
      assert File.exists?(Path.join(@lib, "oauth/browser_post.ex")), "lib/nebu/oauth/browser_post.ex missing"
      account = File.read!(Path.join(@lib, "oauth/account.ex")) |> String.replace(~r/#[^\n]*/, "")
      consent = File.read!(Path.join(@lib, "oauth/consent.ex")) |> String.replace(~r/#[^\n]*/, "")

      assert account =~ "BrowserPost", "account.ex must delegate the Origin / fetch-metadata checks to BrowserPost"
      assert consent =~ "BrowserPost", "consent.ex must use BrowserPost"
      refute account =~ ~r/sec-fetch-(mode|dest|user)/i, "the fetch-metadata header names live in BrowserPost only"
      refute consent =~ ~r/sec-fetch-(mode|dest|user)/i
    end

    test "the account page still refuses a cross-site / fetch POST through the shared module (story-6 behaviour)", %{} do
      uid = T.provision_user!()
      acct = T.account_session!(uid)

      for headers <- [[{"origin", "https://evil.example"}], [{"sec-fetch-site", "cross-site"}], [{"origin", "null"}, {"sec-fetch-site", "cross-site"}]] do
        conn = T.account_post("/account/logout", [{"csrf_token", acct.csrf}], cookie: acct.cookie, headers: headers)
        T.assert_account_error(conn, 403, "forbidden")
      end
    end
  end
end
