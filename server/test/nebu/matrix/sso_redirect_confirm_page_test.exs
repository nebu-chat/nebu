defmodule Nebu.Matrix.SsoRedirectConfirmPageTest do
  @moduledoc """
  ATDD acceptance tests for story `legacy-sso-redirect-confirmation` (G3-3), AC5 (the page, `GET
  /_matrix/client/v3/login/sso/confirm`) and AC6 (headers). Plug level, IdP stubbed, no DB.

  Pinned contract (D9, D15; ATDD role):

    * `<main data-page="sso-confirm" data-result="pending">`, `<html lang="en">`, ONE static `<title>Confirm
      sign-in</title>`, ONE `<h1>` "Continue signing in to this app?", `data-role="user-id"` (Matrix id derived
      from the claims), a `<dl>` with `data-role="target-origin"` (the normalized origin, ASCII / `xn--` host) and
      the path (raw, truncated to 60 characters + "...", omitted for empty or `/`), NEVER the query or fragment.
    * ONE form `method="post" action="/_matrix/client/v3/login/sso/confirm"` with the hidden `csrf_token` and two
      submit buttons, Cancel FIRST, Continue (`id="continue"`) rendered `aria-disabled="true"` (not `disabled`, UX B1), ONE inline script that is
      exactly `Nebu.Web.ArmScript.script/0` (pinned by its SHA-256 in the CSP) addressing the button only through
      `data-arm`, a `<noscript>`.
    * headers: `no-store`, `Pragma: no-cache`, `X-Frame-Options: DENY`, NO `Cross-Origin-Opener-Policy` (oracle
      M1: popup-based web clients keep `window.opener`), `Referrer-Policy: same-origin` on the page and
      `no-referrer` on every other response, no `access-control-*`; CSP `default-src 'none'; style-src
      'sha256-<css>'; script-src 'sha256-<script>'; img-src 'none'; base-uri 'none'; frame-ancestors 'none';
      form-action 'self' https://host[:port]` (page) or `form-action 'none'` without `script-src` (cancel and
      error pages).
  """
  use ExUnit.Case, async: false

  alias Nebu.OAuth.TestSupport, as: T

  @unlisted "https://unlisted.example/cb"

  setup do
    T.reset_rate_limits()
    priv = T.setup_idp!()
    T.drop_confirm_entries!()
    T.drop_token_entries!()
    T.sso_no_trusted_origins!()
    T.sso_origins!([])

    on_exit(fn ->
      T.restore_rate_limits()
      T.drop_confirm_entries!()
    end)

    {:ok, priv: priv}
  end

  defp callback(priv, url, opts \\ []), do: T.legacy_callback!(priv, Keyword.get(opts, :sub, T.unique_sub()), url, opts)

  # callback + GET: `%{cb, page, value, pair}`
  defp page(priv, url, opts \\ []) do
    cb = callback(priv, url, opts)
    T.assert_confirm_redirect(cb, Keyword.take(opts, [:https]))
    {name, value, _} = T.sso_confirm_cookie(cb)
    pair = {name, value}
    %{cb: cb, page: T.sso_confirm_get(pair, Keyword.take(opts, [:https])), value: value, pair: pair}
  end

  defp csp(conn), do: T.header(conn, "content-security-policy") || ""

  defp directive(csp, name) do
    csp
    |> String.split(";")
    |> Enum.map(&String.trim/1)
    |> Enum.find_value(fn d -> if d == name or String.starts_with?(d, name <> " "), do: String.trim_leading(d, name) |> String.trim() end)
  end

  defp plain(body), do: body |> String.replace(~r/<[^>]+>/, " ") |> String.replace(~r/\s+/, " ")

  defp sha256_b64(bytes), do: Base.encode64(:crypto.hash(:sha256, bytes))

  # ════════════════════════════════════════════════════════════════════════════
  # AC5.1 — structure, hooks, accessibility
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC5.1 — page contract" do
    test "hooks, language, one h1, a dl, one form with Cancel before an aria-disabled Continue, nothing external", %{priv: priv} do
      sub = T.unique_sub()
      %{page: conn, value: value} = page(priv, "https://unlisted.example/cb/deep?secret=q1#frag1", sub: sub)
      assert conn.status == 200
      assert (T.header(conn, "content-type") || "") =~ ~r{^text/html;\s*charset=utf-8}i
      b = conn.resp_body

      assert b =~ ~r/\A\s*<!doctype html>/i
      assert b =~ ~r/<html[^>]*lang="en"/
      assert b =~ ~r/<meta[^>]*charset/i
      assert b =~ ~r/<meta[^>]*name="viewport"/
      assert b =~ ~r/<main[^>]*data-page="sso-confirm"/
      assert b =~ ~s(data-result="pending")
      assert length(Regex.scan(~r/<main[\s>]/, b)) == 1

      assert [_] = Regex.scan(~r/<h1[\s>]/, b), "exactly one level-1 heading"
      assert b =~ ~r/<h1[^>]*>\s*Continue signing in to this app\?\s*<\/h1>/
      assert b =~ ~r/<dl[\s>]/ and b =~ ~r/<dt[\s>]/ and b =~ ~r/<dd[\s>]/

      assert [_, origin] = Regex.run(~r/data-role="target-origin"[^>]*>([^<]*)</, b)
      assert origin == "https://unlisted.example"
      assert [_, user] = Regex.run(~r/data-role="user-id"[^>]*>([^<]*)</, b)
      assert user == T.sso_user_id(%{"sub" => sub})
      assert plain(b) =~ "You are signed in as"
      assert plain(b) =~ "The app asks to be sent to"

      assert [form] = Regex.scan(~r/<form\b[^>]*>/, b) |> Enum.map(&hd/1)
      assert form =~ ~r/method="post"/i
      assert form =~ ~s(action="/_matrix/client/v3/login/sso/confirm")

      buttons = Regex.scan(~r/<button\b[^>]*>.*?<\/button>/s, b) |> Enum.map(&hd/1)
      assert length(buttons) == 2, "exactly two buttons, got #{inspect(buttons)}"
      assert Enum.all?(buttons, &(&1 =~ ~s(type="submit") and &1 =~ ~s(name="decision")))
      assert [cancel, continue] = buttons, "Cancel comes FIRST in the DOM (and visual) order"
      assert cancel =~ ~s(value="cancel") and cancel =~ ~r/>\s*Cancel\s*</
      assert continue =~ ~s(value="continue") and continue =~ ~r/>\s*Continue\s*</ and continue =~ ~s(id="continue")
      assert continue =~ ~s(aria-disabled="true"), "UX B1: Continue is rendered aria-disabled (focusable and announced) until the page armed it"
      refute continue =~ ~r/\sdisabled(\s|>|=)/, "UX B1: never the disabled attribute (a screen-reader touch user could not reach it)"
      refute cancel =~ ~r/disabled/, "Cancel is never disabled"
      assert continue =~ ~r/\sdata-arm(\s|>|=)/, "the arming script finds the button through data-arm"

      assert T.csrf_from(conn) == T.sso_confirm_csrf(value), "CSRF = base64url(SHA-256(\"nebu-sso-confirm-csrf:\" <> cookie)) (D8)"

      for forbidden <- [~r/<script[^>]*\ssrc/i, ~r/<img/i, ~r/<a[\s>]/i, ~r/autofocus/i, ~r/\son[a-z]+\s*=/i, ~r/<iframe/i, ~r/<link/i, ~r/(src|href)="(https?:)?\/\//i] do
        refute b =~ forbidden, "#{inspect(forbidden)} must not appear on the confirmation page"
      end
    end

    test "NO query or fragment of the redirect URL appears anywhere in the body (the marker test)", %{priv: priv} do
      %{page: conn} = page(priv, "https://unlisted.example/cb?secret=QMARKONE&other=QMARKTWO#FRAGMARK")
      for needle <- ["secret", "QMARKONE", "QMARKTWO", "FRAGMARK", "other="], do: refute(conn.resp_body =~ needle, "#{needle} must not be rendered")
    end

    test "the <title> is static: it never carries request values and is the same for every target", %{priv: priv} do
      a = page(priv, "https://one.example/cb").page
      b = page(priv, "https://two.example/other").page
      [_, t1] = Regex.run(~r/<title>([^<]+)<\/title>/, a.resp_body)
      [_, t2] = Regex.run(~r/<title>([^<]+)<\/title>/, b.resp_body)
      assert t1 == t2
      assert t1 == "Confirm sign-in"
    end

    test "the warning is a labelled text block (not colour only)", %{priv: priv} do
      t = plain(page(priv, @unlisted).page.resp_body)
      assert t =~ "Warning:"
      assert t =~ "Continuing gives the app at this address full access to your Matrix account"
      assert t =~ "it can read and send messages as you"
      assert t =~ "Only continue if you just started signing in to this app yourself and you recognise the address"
      assert t =~ "If you did not, choose Cancel."
    end

    test "touch targets, focus outline and a narrow viewport are in the CSS (WCAG 2.1 AA hooks)", %{priv: priv} do
      b = page(priv, @unlisted).page.resp_body
      assert [css] = Regex.scan(~r/<style>(.*?)<\/style>/s, b) |> Enum.map(&List.last/1)
      assert css =~ "44px", "44 px touch targets"
      assert css =~ ~r/:focus[^{]*\{[^}]*outline/, "a visible focus outline"
      assert b =~ ~r/<meta[^>]*name="viewport"[^>]*width=device-width/
    end

    test "a <noscript> explains that Continue needs JavaScript (fail closed: only Cancel works)", %{priv: priv} do
      b = page(priv, @unlisted).page.resp_body
      assert [_] = Regex.scan(~r/<noscript>.*?<\/noscript>/s, b)
      assert b =~ ~r/<noscript>.*JavaScript.*Cancel.*<\/noscript>/s
      assert plain(b) =~ "JavaScript is off, so Continue stays unavailable. Turn on JavaScript or use another browser. You can still choose Cancel."
    end
  end

  describe "AC5.1 — the displayed target" do
    test "port only when not 443; the host is lower-cased ASCII", %{priv: priv} do
      assert [_, o1] = Regex.run(~r/data-role="target-origin"[^>]*>([^<]*)</, page(priv, "HTTPS://Unlisted.Example:8443/cb").page.resp_body)
      assert o1 == "https://unlisted.example:8443"
      assert [_, o2] = Regex.run(~r/data-role="target-origin"[^>]*>([^<]*)</, page(priv, "https://unlisted.example:443/cb").page.resp_body)
      assert o2 == "https://unlisted.example"
    end

    test "the path line shows the raw path truncated at 60 characters + '...'; absent for / and for no path", %{priv: priv} do
      long = "/" <> String.duplicate("p", 100)
      b = page(priv, "https://unlisted.example" <> long).page.resp_body
      t = plain(b)
      assert t =~ "Path"
      assert t =~ String.slice(long, 0, 60) <> "..."
      refute t =~ String.slice(long, 0, 61)

      for url <- ["https://unlisted.example/", "https://unlisted.example", "https://unlisted.example?x=1", "https://unlisted.example/#/login"] do
        refute plain(page(priv, url).page.resp_body) =~ ~r/\bPath\b/, "no path line for #{url}"
      end
    end

    test "a percent-encoded path is shown as received (not decoded)", %{priv: priv} do
      t = plain(page(priv, "https://unlisted.example/p%20q%2F").page.resp_body)
      assert t =~ "/p%20q%2F"
    end

    test "an IDN host is shown in its xn-- form with the internationalized-name notice; a plain host has no notice", %{priv: priv} do
      idn = plain(page(priv, "https://xn--bcher-kva.example/cb").page.resp_body)
      assert idn =~ "xn--bcher-kva.example"
      assert idn =~ "This address uses special characters, which can be used to imitate another address. It is shown in a technical form starting with xn--. Check it carefully."
      refute plain(page(priv, @unlisted).page.resp_body) =~ "special characters"
    end
  end

  describe "UX gate B1/B2/N1-N5 — accessibility and wording of the page" do
    test "B1: Continue is aria-described by the hint, the target origin and the notice (ids that exist in the page)", %{priv: priv} do
      b = page(priv, @unlisted).page.resp_body
      assert [continue] = Regex.scan(~r/<button\b[^>]*id="continue"[^>]*>/, b) |> Enum.map(&hd/1)
      assert [_, ids] = Regex.run(~r/aria-describedby="([^"]+)"/, continue)
      ids = String.split(ids, " ", trim: true)
      assert length(ids) >= 3, "the hint, the target origin and the notice: #{inspect(ids)}"

      for id <- ids, do: assert(b =~ ~s(id="#{id}"), "aria-describedby names #{id}, which is not in the page")
      assert "arm-hint" in ids and "target-origin" in ids and "confirm-notice" in ids

      assert b =~ ~r/<[^>]*id="arm-hint"[^>]*data-arm-hint|<[^>]*data-arm-hint[^>]*id="arm-hint"/
      assert b =~ ~r/<[^>]*id="target-origin"[^>]*data-role="target-origin"|<[^>]*data-role="target-origin"[^>]*id="target-origin"/
      assert b =~ ~r/<[^>]*id="confirm-notice"/
    end

    test "B1: the hint is VISIBLE by default (no hidden attribute: it still explains Continue when the script fails) and sits before the buttons", %{priv: priv} do
      b = page(priv, @unlisted).page.resp_body
      assert [hint] = Regex.scan(~r/<[^>]*data-arm-hint[^>]*>/, b) |> Enum.map(&hd/1)
      refute hint =~ ~r/\shidden(\s|>|=)/, "the hint is hidden by the script when it arms, not by the markup"
      assert :binary.match(b, "data-arm-hint") < :binary.match(b, ~s(id="continue"))
    end

    test "B1/B2: a polite live region <p role=\"status\" data-arm-status> exists, empty until the script fills it", %{priv: priv} do
      b = page(priv, @unlisted).page.resp_body
      assert [region] = Regex.scan(~r/<p\b[^>]*data-arm-status[^>]*>.*?<\/p>/s, b) |> Enum.map(&hd/1)
      assert region =~ ~s(role="status")
      assert Regex.replace(~r/<[^>]+>/, region, "") |> String.trim() == "", "empty in the markup (the script announces)"
    end

    test "N4: the static warning notice is NOT a live region (role=status is only the arming announcement)", %{priv: priv} do
      b = page(priv, @unlisted).page.resp_body
      assert length(Regex.scan(~r/role="status"/, b)) == 1, "exactly one status region: [data-arm-status]"
      assert [notice] = Regex.scan(~r/<[^>]*id="confirm-notice"[^>]*>/, b) |> Enum.map(&hd/1)
      refute notice =~ "role="
    end

    test "N2: the target origin is shown in monospace (a <code> element or a monospace font rule), the data-role hook stays", %{priv: priv} do
      %{page: conn} = page(priv, @unlisted)
      b = conn.resp_body
      assert [_, origin] = Regex.run(~r/data-role="target-origin"[^>]*>([^<]*)</, b)
      assert origin == "https://unlisted.example"
      assert b =~ ~r/<code[^>]*data-role="target-origin"/ or Regex.run(~r/<style>(.*?)<\/style>/s, b) |> List.last() =~ "monospace"
    end

    test "N1: the notice says why the page appears, what Cancel does and when the request expires", %{priv: priv} do
      t = plain(page(priv, @unlisted).page.resp_body)
      assert t =~ "This address is not on the list of apps your administrator trusts."
      assert t =~ "Cancel stops the sign-in. Nothing is sent to the app."
      assert t =~ "This request expires in 5 minutes."
    end

    test "N5: every page has its own static <title>: confirm, cancelled and each error kind", %{priv: priv} do
      title = fn conn ->
        [_, t] = Regex.run(~r/<title>([^<]+)<\/title>/, conn.resp_body)
        t
      end

      cb = callback(priv, @unlisted)
      assert title.(T.sso_confirm_get(cb)) == "Confirm sign-in"
      assert title.(T.confirm!(cb, :cancel)) == "Sign-in cancelled"

      # invalid_state
      assert title.(T.sso_confirm_get(nil)) == "Sign-in link expired"

      # forbidden and invalid_request
      cb2 = callback(priv, @unlisted)
      {_, v2, _} = T.sso_confirm_cookie(cb2)
      pair2 = {T.sso_confirm_cookie_name(), v2}
      forbidden = T.sso_confirm_post([{"csrf_token", "wrong"}, {"decision", "continue"}], cookie: pair2)
      T.assert_confirm_error(forbidden, 403, "forbidden")
      assert title.(forbidden) == "Sign-in request refused"
      invalid = T.sso_confirm_post([{"csrf_token", T.sso_confirm_csrf(v2)}, {"decision", "maybe"}], cookie: pair2)
      T.assert_confirm_error(invalid, 400, "invalid_request")
      assert title.(invalid) == "Sign-in request refused"

      # rate_limited
      T.drain_binding!(v2)
      limited = T.sso_confirm_get(pair2)
      T.assert_confirm_error(limited, 429, "rate_limited")
      assert title.(limited) == "Too many requests"
    end

    # Filling the confirm store to its 10 000 cap is quadratic (45-60 s and more on the shared CI runner): more than the 60 s default.
    @tag timeout: 300_000
    test "N5: the unavailable page has the title \"Sign-in unavailable\" (confirm store full)", %{priv: priv} do
      fill = T.confirm_entry_fixture()

      try do
        for i <- 1..10_000, do: :ok = apply(Nebu.Matrix.SsoStore, :put_confirm, ["fill-#{i}", fill, 300])
        conn = callback(priv, @unlisted)
        T.assert_confirm_error(conn, 503, "unavailable")
        assert [_, "Sign-in unavailable"] = Regex.run(~r/<title>([^<]+)<\/title>/, conn.resp_body)
      after
        T.drop_confirm_entries!()
      end
    end

    test "N5: the confirmation page <title> never carries request values (still static)", %{priv: priv} do
      a = page(priv, "https://one.example/cb").page
      [_, t] = Regex.run(~r/<title>([^<]+)<\/title>/, a.resp_body)
      refute t =~ "one.example"
    end
  end

  describe "AC5.2 — every displayed value is HTML-escaped" do
    test "a hostile user id and a hostile path are escaped (no raw tag or quote breaks out)", %{priv: _priv} do
      value = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      hostile_user = "@<img src=x onerror=alert(1)>\"':test.local"
      hostile_path = "/a<b>\"c'd"

      T.put_confirm_both!(
        value,
        T.confirm_entry_fixture(%{user_id: hostile_user, path: hostile_path, redirect_url: "https://unlisted.example" <> hostile_path})
      )

      conn = T.sso_confirm_get({T.sso_confirm_cookie_name(), value})
      assert conn.status == 200
      b = conn.resp_body
      refute b =~ "<img src=x", "the user id is escaped"
      refute b =~ "onerror=alert(1)>", "no raw attribute injection"
      refute b =~ ~s(<b>"c), "the path is escaped"
      assert b =~ "&lt;img src=x"
      assert b =~ "&lt;b&gt;"
      assert b =~ "&quot;"
    end

    test "a real flow with markup in the path renders it escaped", %{priv: priv} do
      b = page(priv, ~s(https://unlisted.example/a<b>"c)).page.resp_body
      refute b =~ "a<b>"
      assert b =~ "a&lt;b&gt;"
    end
  end

  describe "AC5.3 — GET mutates nothing" do
    test "two GETs render the same page, the entry survives, no cookie is set or cleared, no token is minted", %{priv: priv} do
      %{pair: pair, value: value} = page(priv, @unlisted)
      before = T.sso_token_keys()
      a = T.sso_confirm_get(pair)
      b = T.sso_confirm_get(pair)
      assert a.status == 200 and b.status == 200
      assert a.resp_body == b.resp_body
      assert T.confirm_entry(value), "the entry survives GETs"
      assert T.sso_confirm_set_cookies(a) == [], "a GET sets and clears no cookie"
      assert T.sso_token_keys() == before
    end
  end

  describe "AC5.4 — missing, malformed, unknown, expired => 400 invalid_state, cookie cleared (not for a missing one)" do
    test "no cookie at all: invalid_state, nothing cleared (SEC L-1: a cross-site POST must not delete the cookie)" do
      conn = T.sso_confirm_get(nil)
      T.assert_confirm_error(conn, 400, "invalid_state")
      refute T.sso_confirm_cookie_cleared?(conn)
    end

    test "a malformed or unknown cookie value" do
      for bad <- ["x", String.duplicate("a", 43), String.duplicate("a", 200), "%00", ""] do
        conn = T.sso_confirm_get({T.sso_confirm_cookie_name(), bad})
        T.assert_confirm_error(conn, 400, "invalid_state")
        assert T.sso_confirm_cookie_cleared?(conn), "cookie cleared for #{inspect(bad)}"
      end
    end

    test "an expired entry" do
      value = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      T.put_confirm_both!(value, T.confirm_entry_fixture(), -1)
      T.assert_confirm_error(T.sso_confirm_get({T.sso_confirm_cookie_name(), value}), 400, "invalid_state")
    end

    test "on https only the __Host- cookie name counts: the plain-http name alone is missing", %{priv: priv} do
      %{value: value} = page(priv, @unlisted)
      conn = T.sso_confirm_get({T.sso_confirm_cookie_name(false), value}, https: true)
      T.assert_confirm_error(conn, 400, "invalid_state")
      assert T.confirm_entry(value), "the entry is untouched"
    end

    test "on http the __Host- name is not read either (cookie tossing)", %{priv: priv} do
      %{value: value} = page(priv, @unlisted)
      T.assert_confirm_error(T.sso_confirm_get({T.sso_confirm_cookie_name(true), value}), 400, "invalid_state")
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC5.6 — the arming script
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC5.6 — the script is Nebu.Web.ArmScript.script/0 byte for byte" do
    test "exactly one inline script, equal to ArmScript.script/0, pinned by its hash in the CSP; no page-specific id inside it", %{priv: priv} do
      conn = page(priv, @unlisted).page
      script = apply(Nebu.Web.ArmScript, :script, [])
      assert is_binary(script) and script != ""
      assert [inline] = Regex.scan(~r/<script>(.*?)<\/script>/s, conn.resp_body) |> Enum.map(&List.last/1)
      assert inline == script, "the page embeds the shared script byte for byte"

      assert [_, hash] = Regex.run(~r/script-src 'sha256-([^']+)'/, csp(conn)), "script-src is pinned by hash"
      assert hash == sha256_b64(script)

      refute script =~ ~r/["']continue["']|#continue|getElementById/, "the script addresses the button only through data-arm (no page-specific id)"
      assert script =~ "data-arm"
    end

    test "the page marks exactly the armed element with data-arm and carries the hint element data-arm-hint", %{priv: priv} do
      b = page(priv, @unlisted).page.resp_body
      assert length(Regex.scan(~r/\sdata-arm(?![-\w])/, b)) == 1, "exactly one data-arm element"
      assert length(Regex.scan(~r/\sdata-arm-hint(?![-\w])/, b)) == 1, "one hint element"
    end

    test "the cancel and error pages carry no script at all", %{priv: priv} do
      cb = callback(priv, @unlisted)
      cancel = T.confirm!(cb, :cancel)
      refute cancel.resp_body =~ ~r/<script/i
      refute csp(cancel) =~ "script-src"
      refute T.sso_confirm_get(nil).resp_body =~ ~r/<script/i
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC6 — headers
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC6.1 — the confirmation page headers" do
    test "no-store, no-cache, DENY, no COOP (oracle M1), same-origin referrer, nosniff, no CORS", %{priv: priv} do
      conn = page(priv, @unlisted).page
      assert T.header(conn, "cache-control") =~ "no-store"
      assert T.header(conn, "pragma") =~ "no-cache"
      assert T.header(conn, "x-frame-options") == "DENY"
      assert T.header(conn, "cross-origin-opener-policy") == nil, "COOP must be ABSENT: popup clients keep window.opener"
      assert T.header(conn, "referrer-policy") == "same-origin"
      assert T.header(conn, "x-content-type-options") == "nosniff"
      refute Enum.any?(conn.resp_headers, fn {k, _} -> String.starts_with?(k, "access-control-") end)
    end

    test "no access-control-* header even with an Origin request header", %{priv: priv} do
      %{pair: pair} = page(priv, @unlisted)
      conn = T.sso_confirm_get(pair, headers: [{"origin", "https://evil.example.com"}])
      assert conn.status == 200
      refute Enum.any?(conn.resp_headers, fn {k, _} -> String.starts_with?(k, "access-control-") end)
    end

    test "CSP: default-src none, style hash = the inline CSS, img/base/frame locked, form-action self + the https origin", %{priv: priv} do
      conn = page(priv, @unlisted).page
      c = csp(conn)
      assert c =~ ~r/^default-src 'none'/
      assert directive(c, "img-src") == "'none'"
      assert directive(c, "base-uri") == "'none'"
      assert directive(c, "frame-ancestors") == "'none'"
      assert directive(c, "form-action") == "'self' https://unlisted.example"
      refute c =~ "unsafe-inline"
      refute c =~ "unsafe-eval"
      [_, hash] = Regex.run(~r/style-src 'sha256-([^']+)'/, c)
      assert [css] = Regex.scan(~r/<style>(.*?)<\/style>/s, conn.resp_body) |> Enum.map(&List.last/1)
      assert hash == sha256_b64(css), "the CSP hash equals the CSS actually inlined"
    end

    test "form-action carries the PORT of the target iff it is not 443, built from the parsed host only", %{priv: priv} do
      assert directive(csp(page(priv, "https://unlisted.example:8443/cb").page), "form-action") == "'self' https://unlisted.example:8443"
      assert directive(csp(page(priv, "https://unlisted.example:443/cb").page), "form-action") == "'self' https://unlisted.example"
      assert directive(csp(page(priv, "HTTPS://UNLISTED.Example/cb").page), "form-action") == "'self' https://unlisted.example"
      assert directive(csp(page(priv, "https://10.0.0.5:8443/cb").page), "form-action") == "'self' https://10.0.0.5:8443"
    end

    test "a hostile path or query can never reach a header (the CSP is built from the parsed components only)", %{priv: priv} do
      conn = page(priv, "https://unlisted.example/a;script-src-elem;b'c/?x=y;form-action").page
      c = csp(conn)
      refute c =~ "script-src-elem"
      refute c =~ "b'c"
      refute c =~ "x=y"
      assert directive(c, "form-action") == "'self' https://unlisted.example"
    end
  end

  describe "AC6.2 — the cancel and error pages" do
    test "CSP default-src none, form-action none, no script-src, no-referrer, the other headers as the page", %{priv: priv} do
      cancel = T.confirm!(callback(priv, @unlisted), :cancel)
      invalid = T.sso_confirm_get(nil)

      for conn <- [cancel, invalid] do
        c = csp(conn)
        assert c =~ ~r/^default-src 'none'/
        assert directive(c, "form-action") == "'none'"
        assert directive(c, "base-uri") == "'none'"
        assert directive(c, "frame-ancestors") == "'none'"
        refute c =~ "script-src"
        refute c =~ "unsafe-inline"
        assert T.header(conn, "referrer-policy") == "no-referrer"
        assert T.header(conn, "cache-control") =~ "no-store"
        assert T.header(conn, "pragma") =~ "no-cache"
        assert T.header(conn, "x-frame-options") == "DENY"
        assert T.header(conn, "cross-origin-opener-policy") == nil
        refute Enum.any?(conn.resp_headers, fn {k, _} -> String.starts_with?(k, "access-control-") end)
        refute conn.resp_body =~ ~r/<script/i

        case Regex.run(~r/style-src 'sha256-([^']+)'/, c) do
          [_, hash] ->
            assert [css] = Regex.scan(~r/<style>(.*?)<\/style>/s, conn.resp_body) |> Enum.map(&List.last/1)
            assert hash == sha256_b64(css)

          nil ->
            refute conn.resp_body =~ "<style", "inline CSS without a style-src hash"
        end
      end
    end

    test "an error page renders no request value at all", %{priv: _priv} do
      marker = "marker-" <> T.rand(8)
      conn = T.sso_confirm_get({T.sso_confirm_cookie_name(), marker}, headers: [{"referer", "https://#{marker}.example/"}])
      T.assert_confirm_error(conn, 400, "invalid_state")
      refute conn.resp_body =~ marker
      assert conn.resp_body =~ "This sign-in link has expired or was already used. Start signing in again from your app."
      assert [_] = Regex.scan(~r/<h1[\s>]/, conn.resp_body)
      assert conn.resp_body =~ ~r/What you can do/i
    end
  end

  describe "AC6.3 — the 303s" do
    test "the callback 303 and the Continue 303: no-store, no-cache, no-referrer, no CORS", %{priv: priv} do
      cb = callback(priv, @unlisted)
      for conn <- [cb, T.confirm!(cb, :continue)] do
        assert conn.status == 303
        assert T.header(conn, "cache-control") =~ "no-store"
        assert T.header(conn, "pragma") =~ "no-cache"
        assert T.header(conn, "referrer-policy") == "no-referrer"
        refute Enum.any?(conn.resp_headers, fn {k, _} -> String.starts_with?(k, "access-control-") end)
      end
    end
  end

  describe "AC6.4 (oracle M1) — NO response of the flow carries Cross-Origin-Opener-Policy" do
    test "callback 302 (listed) and 303, the page, cancel, Continue, and every error page", %{priv: priv} do
      T.sso_origins!(["https://listed.example"])
      listed = callback(priv, "https://listed.example/cb")
      cb = callback(priv, @unlisted)
      {_, value, _} = T.sso_confirm_cookie(cb)
      pair = {T.sso_confirm_cookie_name(), value}
      page = T.sso_confirm_get(pair)

      forbidden = T.sso_confirm_post([{"csrf_token", "wrong"}, {"decision", "continue"}], cookie: pair)
      invalid_request = T.sso_confirm_post([{"csrf_token", T.sso_confirm_csrf(value)}, {"decision", "maybe"}], cookie: pair)
      invalid_state = T.sso_confirm_get(nil)

      # a separate binding for the rate-limited answer (the main one still decides below)
      {_, limited_value, _} = T.sso_confirm_cookie(callback(priv, @unlisted))
      T.drain_binding!(limited_value)
      limited = T.sso_confirm_get({T.sso_confirm_cookie_name(), limited_value})

      cancel = T.confirm!(callback(priv, @unlisted), :cancel)
      continue = T.confirm!(cb, :continue)

      conns = [listed, cb, page, forbidden, invalid_request, invalid_state, limited, cancel, continue]
      assert Enum.map(conns, & &1.status) == [302, 303, 200, 403, 400, 400, 429, 200, 303]

      for conn <- conns do
        assert T.header(conn, "cross-origin-opener-policy") == nil, "HTTP #{conn.status} #{String.slice(conn.resp_body || "", 0, 60)} carries COOP"
      end
    end
  end
end
