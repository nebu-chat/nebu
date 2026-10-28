defmodule Nebu.OAuth.SafariAccountResetTest do
  @moduledoc """
  Acceptance tests (integration, real PostgreSQL) for story `safari-fetch-metadata-compat`, AC5 / AC6: the `/account`
  cross-signing reset approval (`POST /account/cross_signing_reset/approve`, the STRICT level of `BrowserPost.check/3`) under the
  five request shapes (a Chrome set, b Safari set + `_click_proof=1`, c Safari set without proof = redirect with the notice
  `activation_unproven`, d fetch / iframe / cross-origin / missing headers, e `Sec-Fetch-User` present and not `?1` or the proof on
  a non-WebKit engine), the reset page (hidden field, the one hash-pinned inline script, no script on any other account page) and
  the lenient `/account` POSTs, which keep accepting a request without `Sec-Fetch-User` (decline, device delete, sign-out).
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  import ExUnit.CaptureLog
  alias Nebu.OAuth.TestSupport, as: T

  @https "https://app.example.com/cb"
  @reset "org.matrix.cross_signing_reset"

  setup do
    T.enable_oauth()
    T.reset_rate_limits()
    priv = T.setup_idp!()

    on_exit(fn ->
      T.clear_oauth_config()
      T.restore_rate_limits()
      for k <- [:oauth_repo, :oauth_session_repo, :account_matrix_repo], do: Application.delete_env(:nebu_http, k)
    end)

    cid = T.oauth_client!([@https], client_name: "Element " <> T.rand(3))
    sub = T.unique_sub()
    _ = T.provision_user!(sub)
    s = T.oauth_device!(cid, @https, priv, sub, dev())
    assert T.device_signing_upload(s.at, T.cross_signing_keys(s.user_id, "A")).status == 200
    {:ok, s: s, uid: s.user_id, acct: T.account_session!(s.user_id), priv: priv, cid: cid, sub: sub}
  end

  defp dev, do: "SF" <> String.upcase(T.rand(4))
  defp q(pairs), do: "/account?" <> URI.encode_query(pairs)

  defp challenge!(ctx, tag) do
    conn = T.device_signing_upload(ctx.s.at, T.cross_signing_keys(ctx.uid, tag))
    assert conn.status == 401
    T.json(conn)["session"]
  end

  defp approve(ctx, sid, headers, proof?) do
    params = [{"session_id", sid}, {"csrf_token", ctx.acct.csrf}]
    params = if proof?, do: T.with_click_proof(params), else: params
    T.account_post("/account/cross_signing_reset/approve", params, cookie: ctx.acct.cookie, headers: headers)
  end

  defp safari, do: T.safari_fetch_headers()
  defp chrome, do: T.strict_fetch_headers() ++ [{"user-agent", T.chrome_user_agent()}]
  defp approved?(sid), do: T.uia_row(sid)["stage_complete"] == true
  defp reset_page(ctx, extra \\ []), do: T.account_get(q([{"action", @reset}] ++ extra), cookie: ctx.acct.cookie)

  describe "the five request shapes of the reset approval" do
    test "(a) Chrome / Firefox set with Sec-Fetch-User: ?1 and no proof field => approved (reset_approved)", ctx do
      sid = challenge!(ctx, "B")
      conn = approve(ctx, sid, chrome(), false)
      assert conn.status == 303 and T.notice_of(conn) == "reset_approved"
      assert approved?(sid)
    end

    test "(b) Safari set (no Sec-Fetch-User) + _click_proof=1 => approved (reset_approved)", ctx do
      sid = challenge!(ctx, "C")
      conn = approve(ctx, sid, safari(), true)
      assert conn.status == 303 and T.notice_of(conn) == "reset_approved"
      assert approved?(sid)
    end

    test "(c) Safari set without proof => 303 back to the reset page with the notice activation_unproven, NOT approved, no error page", ctx do
      sid = challenge!(ctx, "D")
      {conn, log} = with_log(fn -> approve(ctx, sid, safari(), false) end)
      assert conn.status == 303
      assert T.notice_of(conn) == "activation_unproven"
      assert URI.decode_query(URI.parse(T.location(conn)).query)["action"] == @reset
      refute approved?(sid)
      assert log =~ ~r/click proof|activation/i
      refute log =~ sid, "the UIA session id is never logged"
      refute log =~ T.safari_user_agent()
    end

    test "(c) the notice page: friendly status note, the request is still listed, the approve button is still there, and pressing it again with the proof works", ctx do
      sid = challenge!(ctx, "E")
      conn = approve(ctx, sid, safari(), false)
      page = T.account_get(T.location(conn), cookie: ctx.acct.cookie)
      T.assert_account_page(page, @reset)
      assert page.resp_body =~ ~s(data-notice="activation_unproven")
      assert [note] = Floki.parse_document!(page.resp_body) |> Floki.find(~s([data-notice="activation_unproven"]))
      role = Floki.attribute(note, "role") |> List.first()
      assert role == "status", "a notice (status), not an alert"
      refute page.resp_body =~ "This request was refused"
      assert page.resp_body =~ ~s(data-role="approve-reset") and page.resp_body =~ sid

      again = approve(ctx, sid, safari(), true)
      assert T.notice_of(again) == "reset_approved"
      assert approved?(sid)
    end

    for {label, header, value} <- [
          {"fetch() (mode cors)", "sec-fetch-mode", "cors"},
          {"fetch() (dest empty)", "sec-fetch-dest", "empty"},
          {"a hidden iframe", "sec-fetch-dest", "iframe"},
          {"cross-site", "sec-fetch-site", "cross-site"},
          {"same-site", "sec-fetch-site", "same-site"}
        ] do
      test "(d) Safari + proof + #{label} => 403 forbidden page, NOT approved", ctx do
        sid = challenge!(ctx, "F")
        headers = List.keystore(safari(), unquote(header), 0, {unquote(header), unquote(value)})
        T.assert_account_error(approve(ctx, sid, headers, true), 403, "forbidden")
        refute approved?(sid)
      end
    end

    for header <- ~w(sec-fetch-site sec-fetch-mode sec-fetch-dest) do
      test "(d) Safari + proof + #{header} missing => 403 (never the notice)", ctx do
        sid = challenge!(ctx, "G")
        headers = List.keydelete(safari(), unquote(header), 0)
        T.assert_account_error(approve(ctx, sid, headers, true), 403, "forbidden")
        T.assert_account_error(approve(ctx, sid, headers, false), 403, "forbidden")
        refute approved?(sid)
      end
    end

    test "(e) Sec-Fetch-User present and not ?1, or the proof on Chrome / Firefox / no User-Agent without Sec-Fetch-User => 403, NOT approved", ctx do
      sid = challenge!(ctx, "H")

      for value <- ["?0", "1", "true"] do
        T.assert_account_error(approve(ctx, sid, safari() ++ [{"sec-fetch-user", value}], true), 403, "forbidden")
      end

      for ua <- [T.chrome_user_agent(), T.firefox_user_agent(), nil] do
        headers = List.keydelete(safari(), "user-agent", 0) ++ if(ua, do: [{"user-agent", ua}], else: [])
        T.assert_account_error(approve(ctx, sid, headers, true), 403, "forbidden")
      end

      refute approved?(sid)
    end

    test "CSRF is judged together with the headers: a wrong token with the Safari set and proof is the 403 forbidden page", ctx do
      sid = challenge!(ctx, "I")
      conn = T.account_post("/account/cross_signing_reset/approve", T.with_click_proof([{"session_id", sid}, {"csrf_token", "wrong"}]), cookie: ctx.acct.cookie, headers: safari())
      T.assert_account_error(conn, 403, "forbidden")
      refute approved?(sid)
    end

    test "without proof the order is the same: a wrong CSRF token or a foreign Origin with the Safari set is the 403 forbidden page, never the notice", ctx do
      sid = challenge!(ctx, "I2")
      bad_csrf = T.account_post("/account/cross_signing_reset/approve", [{"session_id", sid}, {"csrf_token", "wrong"}], cookie: ctx.acct.cookie, headers: safari())
      T.assert_account_error(bad_csrf, 403, "forbidden")
      T.assert_account_error(approve(ctx, sid, safari() ++ [{"origin", "https://evil.example.com"}], false), 403, "forbidden")
      assert approve(ctx, sid, safari() ++ [{"origin", "https://nebu.example.com"}], true) |> T.notice_of() == "reset_approved"
    end

    test "a foreign Origin with the Safari set and proof is refused (the Origin rules still apply)", ctx do
      sid = challenge!(ctx, "J")
      T.assert_account_error(approve(ctx, sid, safari() ++ [{"origin", "https://evil.example.com"}], true), 403, "forbidden")
      refute approved?(sid)
    end

    test "the 403 text no longer promises that Safari 16.4+ reports how the button was pressed", ctx do
      sid = challenge!(ctx, "K")
      conn = approve(ctx, sid, List.keydelete(safari(), "sec-fetch-mode", 0), true)
      refute conn.resp_body =~ "Safari 16.4"
      assert conn.resp_body =~ ~r/Chrome|Firefox|Safari/
    end
  end

  describe "AC6 — the lenient /account POSTs keep accepting a request without Sec-Fetch-User (Safari)" do
    test "decline works with the Safari set and no proof", ctx do
      sid = challenge!(ctx, "L")
      params = [{"session_id", sid}, {"csrf_token", ctx.acct.csrf}]
      conn = T.account_post("/account/cross_signing_reset/decline", params, cookie: ctx.acct.cookie, headers: safari())
      assert conn.status == 303 and T.notice_of(conn) == "reset_declined"
    end

    test "device delete and sign-out work with the Safari set and no proof", ctx do
      d2 = dev()
      _ = Nebu.Matrix.DeviceKeyStore.upsert_device(ctx.uid, d2, display_name: "Other")
      conn = T.account_post("/account/devices/delete", [{"device_id", d2}, {"csrf_token", ctx.acct.csrf}], cookie: ctx.acct.cookie, headers: safari())
      assert conn.status == 303 and T.notice_of(conn) == "device_deleted"

      out = T.account_post("/account/logout", [{"csrf_token", ctx.acct.csrf}], cookie: ctx.acct.cookie, headers: safari())
      assert out.status == 200
    end
  end

  describe "AC5 — the reset page: hidden field, the one pinned inline script, no script anywhere else" do
    test "the approve form carries the hidden _click_proof field (empty, data-click-proof); the decline form does not need one", ctx do
      challenge!(ctx, "M")
      page = reset_page(ctx)
      T.assert_account_page(page, @reset)
      doc = Floki.parse_document!(page.resp_body)
      assert [approve] = Floki.find(doc, ~s(form[action="/account/cross_signing_reset/approve"]))
      assert [field] = Floki.find(approve, ~s(input[type="hidden"][name="_click_proof"]))
      assert Floki.attribute(field, "data-click-proof") != []
      assert Floki.attribute(field, "value") in [[""], []]
      assert [decline] = Floki.find(doc, ~s(form[action="/account/cross_signing_reset/decline"]))
      assert Floki.find(decline, ~s(input[name="_click_proof"])) == []
    end

    test "the page embeds exactly the shared script once and its CSP pins that script by SHA-256 (no unsafe-inline, no other script source)", ctx do
      challenge!(ctx, "N")
      page = reset_page(ctx)
      script = apply(Nebu.Web.ClickProofScript, :script, [])
      assert length(Regex.scan(~r/<script[\s>]/, page.resp_body)) == 1
      assert page.resp_body =~ "<script>" <> script <> "</script>"
      hash = Base.encode64(:crypto.hash(:sha256, script))
      csp = T.header(page, "content-security-policy")
      assert csp =~ "script-src 'sha256-#{hash}'"
      refute csp =~ "unsafe-inline"
      refute csp =~ "unsafe-eval"
      assert csp =~ ~r/^default-src 'none'/ and csp =~ "frame-ancestors 'none'" and csp =~ "form-action 'self'"
      assert length(Regex.scan(~r/script-src/, csp)) == 1
      refute page.resp_body =~ ~r/\son[a-z]+\s*=/i, "no inline event handler"
    end

    test "no pending request (no approve form) => no script, and no script-src", ctx do
      page = reset_page(ctx)
      refute page.resp_body =~ ~r/<script/i
      refute T.header(page, "content-security-policy") =~ "script-src"
    end

    test "two pending requests (no approve form is rendered) => no script and no script-src", ctx do
      challenge!(ctx, "Q")
      s2 = T.oauth_device!(ctx.cid, @https, ctx.priv, ctx.sub, dev())
      assert T.device_signing_upload(s2.at, T.cross_signing_keys(ctx.uid, "R")).status == 401
      page = reset_page(ctx)
      T.assert_account_page(page, @reset)
      assert page.resp_body =~ ~s(data-role="reset-several")
      refute page.resp_body =~ ~r/<script/i
      refute T.header(page, "content-security-policy") =~ "script-src"
      refute page.resp_body =~ ~s(data-role="approve-reset")
    end

    test "a stale session (reauth link instead of forms) => no script", ctx do
      challenge!(ctx, "O")
      stale = T.account_session!(ctx.uid, auth_time: System.system_time(:second) - 400)
      page = T.account_get(q([{"action", @reset}]), cookie: stale.cookie)
      refute page.resp_body =~ ~r/<script/i
      refute T.header(page, "content-security-policy") =~ "script-src"
    end

    test "every other account page and every error page keeps the no-JavaScript policy", ctx do
      challenge!(ctx, "P")

      for path <- ["/account", q([{"action", "org.matrix.profile"}]), q([{"action", "org.matrix.devices_list"}]), q([{"action", "org.matrix.device_view"}, {"device_id", ctx.s.device_id}]), q([{"action", "org.matrix.device_delete"}, {"device_id", ctx.s.device_id}])] do
        page = T.account_get(path, cookie: ctx.acct.cookie)
        refute page.resp_body =~ ~r/<script/i, path
        refute T.header(page, "content-security-policy") =~ "script-src", path
      end

      err = T.account_get("/account/nope", cookie: ctx.acct.cookie)
      refute err.resp_body =~ ~r/<script/i
      refute T.header(err, "content-security-policy") =~ "script-src"
    end

    test "the notice code is part of the fixed list (and nothing else new)" do
      assert "activation_unproven" in apply(Nebu.OAuth.AccountPages, :notice_codes, [])
    end

    test "an unknown notice value is still not rendered into data-notice", ctx do
      page = T.account_get(q([{"action", @reset}, {"notice", "activation_unproven\"><script>"}]), cookie: ctx.acct.cookie)
      refute page.resp_body =~ "activation_unproven\"><script>"
    end
  end
end
