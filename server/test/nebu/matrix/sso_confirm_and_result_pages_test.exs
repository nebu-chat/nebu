defmodule Nebu.OAuth.SsoConfirmAndResultPagesTest do
  @moduledoc """
  ATDD for story `04-sso-confirm-and-result-pages` (REQ-2026-019) — SSO confirmation and sign-in result pages in the Nebu look.

  One test per Gherkin scenario, tagged `@tag ac: "<scenario-slug>"`. Red until the story is implemented.

  Pure rendering, no database, no IdP: the pages are sent on `Plug.Test` conns, the language comes from the `Accept-Language` header
  (`Nebu.Web.Locale`, story 02), the frame from `Nebu.Web.PageShell` (one `<style>` = `PageShell.css/0`, hash-pinned).
  The pixel claims (390 x 844, nothing to scroll) are proven by the e2e feature; here the DOM order pins the same thing.

  Contract pinned here:

    * `Nebu.Matrix.SsoConfirmPage.send_page/3`, `send_cancelled/1`, `send_error/4` keep their signatures and now take the language from the conn.
    * confirm page: everything OUTSIDE the single closed `<details>` is h1, risk notice (`id="confirm-notice"`, bold label), the target origin
      (`data-role="target-origin"`, `id="target-origin"`), hint / live region / noscript, Cancel, Continue (armed as before: `id="continue"`,
      `aria-disabled="true"`, `data-arm`, `form="sso-confirm-armed"`, described by hint + origin + notice). The user id (`data-role="user-id"`) and
      the path (`data-role="target-path"`) sit INSIDE the `<details>`. No `<dl>` outside the details. Unchanged: ONE inline script =
      `Nebu.Web.ArmScript.script/0` pinned by SHA-256, CSP `form-action 'self' https://<origin>`, no COOP, `Referrer-Policy: same-origin`.
    * cancelled / error pages: shell, `data-page` `sso-confirm` + `data-result="cancelled"` / `sso-confirm-error` + `data-error`, status icon on errors,
      no `<h2>`, the primary suggestion as `<strong>`, the remaining ones under a `<details>` "More options"; CSP = `PageShell.csp/0`.
    * NEW seam: `Nebu.Matrix.SsoLogin.send_uia_result(conn, :complete | :mismatch)` sends the "Authentication complete" (200) / "Authentication did
      not match" (403) page and returns the conn; `complete_uia/3` calls it. It logs nothing itself.
    * `Nebu.Matrix.SsoLogin.render_html_error/1` returns the shell page (English default), the HTTP 400 path uses the browser language and `PageShell.csp/0`.

  Crash/restart — NOT APPLICABLE (no process state; the CSS/script hashes are computed at compile time).
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn
  import ExUnit.CaptureLog

  alias Nebu.Matrix.SsoConfirmPage
  alias Nebu.Matrix.SsoLogin
  alias Nebu.Web.ArmScript
  alias Nebu.Web.PageShell

  @de_header "de-AT,de;q=0.9,en;q=0.5"
  @user "@anna:nebu.example"
  @confirm_path "/_matrix/client/v3/login/sso/confirm"
  @hostile_query "?secret=q1&redirectUrl=https%3A%2F%2Fevil.example%2Fcb"

  # ── helpers ────────────────────────────────────────────────────────────────

  defp request(lang, path \\ @confirm_path <> @hostile_query) do
    c = conn(:get, path)
    if lang, do: put_req_header(c, "accept-language", lang), else: c
  end

  defp entry(extra), do: Map.merge(%{host: "app.unlisted.example", port: nil, path: "/cb/deep", user_id: @user}, extra)

  defp confirm(lang, extra \\ %{}) do
    assert {:ok, conn} = SsoConfirmPage.send_page(request(lang), entry(extra), "csrf-token-1")
    conn
  end

  defp lang(body) do
    case Regex.run(~r/<html lang="([^"]*)"/, body) do
      [_, l] -> l
      _ -> nil
    end
  end

  defp text(html), do: html |> String.replace(~r/<[^>]+>/, " ") |> String.replace(~r/\s+/, " ") |> String.trim()

  defp tag_text(body, tag) do
    case Regex.run(~r/<#{tag}\b[^>]*>(.*?)<\/#{tag}>/s, body) do
      [_, inner] -> text(inner)
      _ -> ""
    end
  end

  # the (single) <details> block: {outside, inside}
  defp split_details(body) do
    assert length(Regex.scan(~r/<details[\s>]/, body)) == 1, "exactly ONE <details> block"
    [[block, inner]] = Regex.scan(~r/<details\b[^>]*>(.*?)<\/details>/s, body)
    {String.replace(body, block, ""), inner}
  end

  defp without_details(body), do: Regex.replace(~r/<details\b[^>]*>.*?<\/details>/s, body, "")

  # the full element carrying id="<id>" (nested same-name tags are balanced), or nil
  defp element(body, id) do
    with [{s, l}, {ts, tl}] <- Regex.run(~r/<([a-z0-9]+)\b[^>]*\sid="#{id}"[^>]*>/, body, return: :index) do
      tag = binary_part(body, ts, tl)
      from = s + l
      rest = binary_part(body, from, byte_size(body) - from)

      close =
        Regex.scan(~r/<(\/?)#{tag}\b/, rest, return: :index)
        |> Enum.reduce_while(1, fn [{pos, _}, {_, glen}], depth ->
          depth = if glen == 1, do: depth - 1, else: depth + 1
          if depth == 0, do: {:halt, {:found, pos}}, else: {:cont, depth}
        end)

      case close do
        {:found, pos} -> binary_part(body, s, l + pos)
        _ -> binary_part(body, s, byte_size(body) - s)
      end
    else
      _ -> nil
    end
  end

  defp index_of(body, needle) do
    case :binary.match(body, needle) do
      {i, _} -> i
      :nomatch -> flunk("#{inspect(needle)} is not in the page")
    end
  end

  defp buttons(body), do: Regex.scan(~r/<button\b[^>]*>.*?<\/button>/s, body) |> Enum.map(&hd/1)

  defp header(conn, name), do: conn |> get_resp_header(name) |> List.first()

  defp directive(csp, name) do
    csp
    |> String.split(";")
    |> Enum.map(&String.trim/1)
    |> Enum.find_value(fn d -> if d == name or String.starts_with?(d, name <> " "), do: d |> String.trim_leading(name) |> String.trim() end)
  end

  defp sha256_b64(bytes), do: Base.encode64(:crypto.hash(:sha256, bytes))

  defp style_block(body) do
    assert [[_, css]] = Regex.scan(~r/<style>(.*?)<\/style>/s, body)
    css
  end

  defp scripts(body), do: Regex.scan(~r/<script\b[^>]*>(.*?)<\/script>/s, body)

  defp shell_page?(body) do
    assert body =~ PageShell.logo(), "the Nebu logo of the shell"
    assert body =~ ~s(class="shell")
    assert style_block(body) == PageShell.css(), "the ONE shared stylesheet"
    assert body =~ ~r/<meta[^>]*name="viewport"/
    assert length(Regex.scan(~r/<main[\s>]/, body)) == 1, "one <main>"
    assert length(Regex.scan(~r/<h1[\s>]/, body)) == 1, "one <h1>"
  end

  defp flow_headers?(conn, referrer) do
    assert header(conn, "cache-control") == "no-store"
    assert header(conn, "pragma") == "no-cache"
    assert header(conn, "x-frame-options") == "DENY"
    assert header(conn, "referrer-policy") == referrer
    assert header(conn, "cross-origin-opener-policy") == nil, "NO COOP: popup clients need window.opener"
    refute Enum.any?(conn.resp_headers, fn {k, _} -> String.starts_with?(k, "access-control-") end)
  end

  # ── scenarios ──────────────────────────────────────────────────────────────

  # Scenario: The SSO confirm page has the same decision-first structure as consent
  #   Given a pending legacy SSO redirect in German and in English at 390 x 844
  #   When the confirm page is shown
  #   Then heading, target origin, notice, Cancel and Continue are visible without scrolling, Cancel comes first, Continue is armed as before and user id and path are inside the collapsed details
  @tag ac: "the-sso-confirm-page-has-the-same-decision-first-structure-as-consent"
  test "Scenario: The SSO confirm page has the same decision-first structure as consent" do
    en_conn = confirm(nil)
    de_conn = confirm(@de_header)

    assert en_conn.status == 200 and de_conn.status == 200
    assert lang(en_conn.resp_body) == "en"
    assert lang(de_conn.resp_body) == "de"
    assert tag_text(en_conn.resp_body, "title") != tag_text(de_conn.resp_body, "title"), "the <title> is translated"
    refute tag_text(en_conn.resp_body, "title") =~ "unlisted", "the <title> stays static, never a request value"

    for {c, label} <- [{en_conn, :en}, {de_conn, :de}] do
      b = c.resp_body
      shell_page?(b)

      {outside, inside} = split_details(b)
      main_view = outside |> String.replace(~r/<script\b.*?<\/script>/s, "") |> text()

      assert Regex.run(~r/<details\b[^>]*>/, b) |> hd() |> String.contains?("open") == false, "the details are collapsed"
      assert b =~ ~r/<summary[^>]*>[^<]+<\/summary>/
      refute outside =~ ~r/<(dl|dt|dd|table)[\s>]/, "no label/value list in the first view"
      assert outside =~ ~s(data-page="sso-confirm")
      assert outside =~ ~s(data-result="pending")

      # heading, notice, target origin
      if label == :en do
        assert tag_text(outside, "h1") == "Continue signing in to this app?"
      else
        assert tag_text(outside, "h1") != "Continue signing in to this app?"
        refute main_view =~ ~r/\b(Cancel|Continue|Warning|signing)\b/, "German page has no English text"
      end

      assert [_, origin] = Regex.run(~r/data-role="target-origin"[^>]*>([^<]*)</, outside)
      assert origin == "https://app.unlisted.example"
      assert element(outside, "target-origin"), "the origin carries id=target-origin"

      notice = element(outside, "confirm-notice")
      assert notice, "the risk notice is in the first view"
      assert notice =~ ~r/<strong>[^<]+<\/strong>/, "the notice has a bold text label"
      assert text(notice) =~ if(label == :en, do: ~r/Warning/, else: ~r/Achtung/)

      # user id and path are details
      refute main_view =~ "@anna", "the user id is a detail"
      refute main_view =~ "/cb/deep", "the path is a detail"
      assert [_, user] = Regex.run(~r/data-role="user-id"[^>]*>([^<]*)</, inside)
      assert user == @user
      assert [_, path] = Regex.run(~r/data-role="target-path"[^>]*>([^<]*)</, inside)
      assert path == "/cb/deep"

      # Cancel first, Continue armed as before
      assert [cancel, continue] = buttons(outside)
      assert cancel =~ ~s(value="cancel") and cancel =~ ~s(name="decision")
      refute cancel =~ "aria-disabled", "Cancel is never disabled"
      assert continue =~ ~s(value="continue") and continue =~ ~s(id="continue")
      assert continue =~ ~s(aria-disabled="true")
      refute continue =~ ~r/\sdisabled(\s|>|=)/
      assert continue =~ ~r/\sdata-arm(\s|>|=)/
      assert continue =~ ~s(form="sso-confirm-armed")

      if label == :en do
        assert text(cancel) == "Cancel"
        assert text(continue) == "Continue"
      else
        assert text(cancel) =~ "Abbrechen"
        assert text(continue) =~ ~r/Fortfahren|Weiter/
      end

      assert [_, ids] = Regex.run(~r/aria-describedby="([^"]+)"/, continue)
      described = String.split(ids, " ", trim: true)
      for id <- ["target-origin", "confirm-notice"], do: assert(id in described, "Continue is described by #{id}")
      for id <- described, do: assert(element(b, id), "aria-describedby target #{id} exists")

      # hint, live region, noscript stay
      assert outside =~ ~r/\sdata-arm-hint(\s|>|=)/
      refute Regex.run(~r/<[^>]*data-arm-hint[^>]*>/, outside) |> hd() |> String.contains?("hidden")
      assert [_] = Regex.scan(~r/role="status"/, b)
      assert outside =~ ~r/\sdata-arm-status(\s|>|=)/
      assert outside =~ "<noscript"
      assert [_] = Regex.scan(~r/<form[\s>]/, b)
      assert b =~ ~s(<form method="post" action="#{@confirm_path}")
      assert b =~ ~s(name="csrf_token" value="csrf-token-1")

      # order of the first view: h1, notice, origin, Cancel, Continue, details
      positions = [
        index_of(b, "<h1"),
        index_of(b, ~s(id="confirm-notice")),
        index_of(b, ~s(data-role="target-origin")),
        index_of(b, ~s(value="cancel")),
        index_of(b, ~s(value="continue")),
        index_of(b, "<details")
      ]

      assert positions == Enum.sort(positions), "heading, notice, target origin, Cancel, Continue, details in this order"

      # one inline script = ArmScript, pinned by SHA-256; strict CSP unchanged in shape
      assert [[_, script]] = scripts(b)
      assert script == ArmScript.script()
      assert b =~ "<script>"
      csp = header(c, "content-security-policy")
      assert directive(csp, "default-src") == "'none'"
      assert directive(csp, "script-src") == "'sha256-#{sha256_b64(ArmScript.script())}'"
      assert directive(csp, "style-src") == "'sha256-#{sha256_b64(PageShell.css())}'"
      assert directive(csp, "form-action") == "'self' https://app.unlisted.example"
      assert directive(csp, "img-src") == "'none'"
      assert directive(csp, "base-uri") == "'none'"
      refute csp =~ "unsafe"

      flow_headers?(c, "same-origin")

      for forbidden <- [~r/<a[\s>]/i, ~r/autofocus/i, ~r/\son[a-z]+\s*=/i, ~r/<img/i, ~r/<link/i, ~r/<script[^>]*\ssrc/i] do
        refute b =~ forbidden
      end
    end

    # request-derived values stay escaped
    hostile = confirm(nil, %{user_id: "<img src=x onerror=alert(1)>", path: "/<b>x</b>"}).resp_body
    refute hostile =~ "<img src=x"
    assert hostile =~ "&lt;img src=x"
    refute hostile =~ "<b>x</b>"
  end

  # Scenario: Cancelled and error pages use the shell and keep their hooks
  #   Given the cancelled page and each of the five error pages of the SSO confirmation
  #   When they are rendered
  #   Then each uses the shell and the browser language, keeps data-page "sso-confirm" / "sso-confirm-error" with its data-result / data-error, renders no request value, and keeps its headers and status
  @tag ac: "cancelled-and-error-pages-use-the-shell-and-keep-their-hooks"
  test "Scenario: Cancelled and error pages use the shell and keep their hooks" do
    errors = [
      {400, "invalid_state", nil, :many},
      {403, "forbidden", nil, :many},
      {400, "invalid_request", nil, :many},
      {429, "rate_limited", 30, :one},
      {503, "unavailable", 60, :one}
    ]

    render_all = fn header ->
      cancelled = SsoConfirmPage.send_cancelled(request(header))

      errs =
        for {status, code, retry, shape} <- errors do
          opts = if retry, do: [retry_after: retry], else: []
          {status, code, retry, shape, SsoConfirmPage.send_error(request(header), status, code, opts)}
        end

      {cancelled, errs}
    end

    {en_cancelled, en_errs} = render_all.(nil)
    {de_cancelled, de_errs} = render_all.(@de_header)

    # cancelled
    for {c, l} <- [{en_cancelled, "en"}, {de_cancelled, "de"}] do
      assert c.status == 200
      assert lang(c.resp_body) == l
      shell_page?(c.resp_body)
      assert c.resp_body =~ ~s(data-page="sso-confirm")
      assert c.resp_body =~ ~s(data-result="cancelled")
      refute c.resp_body =~ "sso-confirm-error"
      refute c.resp_body =~ "<script"
      assert header(c, "content-security-policy") == PageShell.csp()
      flow_headers?(c, "no-referrer")
    end

    assert tag_text(en_cancelled.resp_body, "h1") == "Sign-in cancelled"
    assert tag_text(de_cancelled.resp_body, "h1") != "Sign-in cancelled"
    assert tag_text(de_cancelled.resp_body, "title") != tag_text(en_cancelled.resp_body, "title")

    # the five error pages
    for {{status, code, retry, shape, en}, {_, _, _, _, de}} <- Enum.zip(en_errs, de_errs) do
      for {c, l} <- [{en, "en"}, {de, "de"}] do
        b = c.resp_body
        assert c.status == status, "#{code}: status"
        assert lang(b) == l, "#{code}: language"
        shell_page?(b)
        assert b =~ ~s(data-page="sso-confirm-error")
        assert b =~ ~s(data-error="#{code}")
        refute b =~ "data-result"
        assert b =~ ~s(class="status"), "#{code}: status icon"
        refute b =~ ~r/<h2[\s>]/, "#{code}: no 'What you can do' heading"
        refute b =~ "What you can do"
        refute b =~ ~r/<(script|form)[\s>]/
        assert without_details(b) =~ ~r/<strong>[^<]+<\/strong>/, "#{code}: one primary suggestion in bold"

        if shape == :many do
          assert [[_, inner]] = Regex.scan(~r/<details\b[^>]*>(.*?)<\/details>/s, b)
          assert inner =~ ~r/<li[\s>]/, "#{code}: the other suggestions sit in the details"
          assert tag_text(inner, "summary") == if(l == "en", do: "More options", else: "Weitere Möglichkeiten")
        end

        # no request value is rendered
        for leaked <- ["secret", "q1", "evil.example", "redirectUrl", "csrf"], do: refute(b =~ leaked, "#{code}: leaked #{leaked}")

        # headers and status are kept
        assert header(c, "content-security-policy") == PageShell.csp()
        flow_headers?(c, "no-referrer")
        assert header(c, "retry-after") == if(retry, do: Integer.to_string(retry), else: nil)
      end

      assert tag_text(de.resp_body, "h1") != tag_text(en.resp_body, "h1"), "#{code}: the heading is translated"
      assert tag_text(de.resp_body, "title") != tag_text(en.resp_body, "title"), "#{code}: the title is translated"
    end

    # a hostile Accept-Language is never echoed
    hostile = SsoConfirmPage.send_error(request("de, <script>alert(1)</script>;q=0.1"), 400, "invalid_state")
    refute hostile.resp_body =~ "alert(1)"
  end

  # Scenario: A finished sign-in still tells the Matrix client that authentication is done
  #   Given a user who completed the UIA SSO fallback
  #   When the "Authentication complete" page loads in a browser
  #   Then window.onAuthDone is called and "authDone" is posted to window.opener exactly as before, the page is in the shell and the language of the browser, and its CSP allows only that one script by hash
  @tag ac: "a-finished-sign-in-still-tells-the-matrix-client-that-authentication"
  test "Scenario: A finished sign-in still tells the Matrix client that authentication is done" do
    callback = "/_matrix/client/v3/login/sso/redirect/oidc?code=SECRETCODE&state=abc123"
    en = SsoLogin.send_uia_result(request(nil, callback), :complete)
    de = SsoLogin.send_uia_result(request(@de_header, callback), :complete)

    for {c, l} <- [{en, "en"}, {de, "de"}] do
      b = c.resp_body
      assert c.status == 200
      assert (header(c, "content-type") || "") =~ ~r{^text/html}
      assert lang(b) == l
      shell_page?(b)
      refute b =~ "SECRETCODE", "no request value is rendered"

      # the one inline script is the UIA fallback contract
      assert [[open, script]] = scripts(b)
      assert open =~ "<script>", "no attribute on the script"
      # (bugfix matrix-uia-authdone-else-if: the spec script, `else if`; the exact text is pinned in uia_authdone_else_if_test.exs)
      assert script =~ "if (window.onAuthDone) { window.onAuthDone(); } else if (window.opener && window.opener.postMessage) {"
      assert script =~ ~s|window.opener.postMessage("authDone", "*"); }|

      # CSP allows exactly that script by its hash, the style by its hash, nothing else
      csp = header(c, "content-security-policy")
      assert directive(csp, "default-src") == "'none'"
      assert directive(csp, "script-src") == "'sha256-#{sha256_b64(script)}'"
      assert directive(csp, "style-src") == "'sha256-#{sha256_b64(PageShell.css())}'"
      assert directive(csp, "base-uri") == "'none'"
      assert directive(csp, "form-action") == "'none'"
      refute csp =~ "unsafe"
      refute csp =~ "nonce"

      assert header(c, "cache-control") == "no-store"
      assert header(c, "cross-origin-opener-policy") == nil, "popup clients need window.opener"
    end

    assert tag_text(en.resp_body, "title") == "Authentication complete"
    assert text(en.resp_body) =~ "You may return to your client"
    assert tag_text(de.resp_body, "title") != "Authentication complete"
    refute text(de.resp_body) =~ "You may return"
    assert tag_text(de.resp_body, "h1") != tag_text(en.resp_body, "h1")
  end

  # UX gate (WCAG 1.4.10 reflow): the shared shell CSS wraps the request-derived origin, the details values and code.
  test "UX gate: the shell CSS wraps the origin, the dd values and code at 320 px" do
    css = PageShell.css()

    for sel <- [".app .name{", "dd{", "code{"] do
      assert [_, rule] = Regex.run(~r/#{Regex.escape(sel)}([^}]*)\}/, css), "rule #{sel} exists"
      assert rule =~ "overflow-wrap:anywhere", "#{sel} wraps long unbroken values"
    end

    assert css =~ ".app>div{min-width:0}", "the flex child of .app may shrink below its content"
    assert css =~ ~r/code\{[^}]*monospace/, "the origin is shown in monospace"
  end

  test "UX gate: a 253-char xn-- host still renders the origin in <code id=target-origin>" do
    label = "xn--" <> String.duplicate("a", 59)
    host = Enum.join([label, label, label, "xn--" <> String.duplicate("b", 57)], ".")
    assert String.length(host) == 253

    body = confirm(nil, %{host: host}).resp_body
    assert body =~ ~s(<code id="target-origin" data-role="target-origin">https://#{host}</code>)
    assert style_block(body) == PageShell.css()
  end

  # Scenario: A mismatching authentication shows a clear refusal
  #   Given a UIA completion whose identity does not match the pending request
  #   When the 403 page is rendered
  #   Then it says in plain German or English that nothing was authorised, runs no script, keeps status 403 and no-store, and logs nothing new
  @tag ac: "a-mismatching-authentication-shows-a-clear-refusal"
  test "Scenario: A mismatching authentication shows a clear refusal" do
    callback = "/_matrix/client/v3/login/sso/redirect/oidc?code=SECRETCODE&state=abc123"

    {en, en_log} = with_log([level: :debug], fn -> SsoLogin.send_uia_result(request(nil, callback), :mismatch) end)
    {de, de_log} = with_log([level: :debug], fn -> SsoLogin.send_uia_result(request(@de_header, callback), :mismatch) end)

    assert en_log == "" and de_log == "", "rendering the refusal logs nothing"

    for {c, l, said} <- [{en, "en", ~r/not authori[sz]ed|nothing was authori[sz]ed/i}, {de, "de", ~r/nicht autorisiert|nichts autorisiert|nicht genehmigt/i}] do
      b = c.resp_body
      assert c.status == 403
      assert lang(b) == l
      shell_page?(b)
      assert text(b) =~ said
      refute b =~ "SECRETCODE"
      refute b =~ "<script", "the refusal runs no script"
      refute b =~ "onAuthDone"
      refute b =~ "authDone"
      assert header(c, "cache-control") == "no-store"
      csp = header(c, "content-security-policy")
      assert csp == PageShell.csp()
      assert directive(csp, "script-src") == nil
      assert header(c, "cross-origin-opener-policy") == nil
    end

    assert tag_text(en.resp_body, "title") == "Authentication did not match"
    assert tag_text(de.resp_body, "title") != "Authentication did not match"
    assert tag_text(de.resp_body, "h1") != tag_text(en.resp_body, "h1")
  end

  # Scenario: The unsupported-login page escapes the scheme and is readable
  #   Given an app whose redirect scheme "<script>alert(1)</script>" is not allowed
  #   When render_html_error/1 is rendered
  #   Then the scheme is HTML-escaped inside a code element, the page has lang, viewport, one main and one h1, and tells the user to contact the administrator
  @tag ac: "the-unsupported-login-page-escapes-the-scheme-and-is-readable"
  test "Scenario: The unsupported-login page escapes the scheme and is readable" do
    b = SsoLogin.render_html_error("<script>alert(1)</script>")

    assert b =~ ~r/\A\s*<!doctype html>/i
    assert lang(b) == "en"
    shell_page?(b)
    assert b =~ "<code>&lt;script&gt;alert(1)&lt;/script&gt;</code>", "the scheme is escaped inside a <code> element"
    refute b =~ "<script", "no script, escaped or not, can run"
    refute b =~ "alert(1)</script>"
    assert text(b) =~ ~r/contact your (server )?administrator/i
    assert tag_text(b, "title") != ""

    # a missing scheme renders an empty code element, not a crash
    assert SsoLogin.render_html_error(nil) =~ "<code></code>"

    # through the HTTP path: browser language, shell CSP, status 400
    conn =
      conn(:get, "/_matrix/client/v3/login/sso/redirect?redirectUrl=" <> URI.encode_www_form("unknown-scheme://host"))
      |> put_req_header("accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8")
      |> put_req_header("accept-language", @de_header)
      |> Nebu.Web.Router.call(Nebu.Web.Router.init([]))

    assert conn.status == 400
    assert lang(conn.resp_body) == "de"
    shell_page?(conn.resp_body)
    assert conn.resp_body =~ "<code>unknown-scheme</code>"
    assert text(conn.resp_body) =~ "Administrat"
    refute text(conn.resp_body) =~ ~r/administrator/i
    assert header(conn, "content-security-policy") == PageShell.csp()
  end
end
