defmodule Nebu.OAuth.PageShellI18nTest do
  @moduledoc """
  ATDD for story `02-page-shell-and-i18n` (REQ-2026-017) — Shared Nebu page shell and German/English texts.

  One test per Gherkin scenario, tagged `@tag ac: "<scenario-slug>"`. Red until the story is implemented.

  Contract pinned here (names from the story Decisions; the rest stays free):

      Nebu.OAuth.Pages.send_page(conn, status, code, opts)   # public API unchanged
      Nebu.Web.Locale.from_conn(conn) :: :en | :de            # first match of Accept-Language in {de, en}, else :en
      Nebu.Web.PageText                                       # the catalog module (existence only)
      Nebu.Web.PageShell                                      # the shared shell (existence only)

  Everything else is asserted on the rendered page (HTML + headers), so the dev's internal naming stays free.
  Pure rendering on `Plug.Test` conns; the one router-level check needs no database (405 happens before any query).
  Crash/restart — NOT APPLICABLE (no process state; the CSS/CSP hash is computed at compile time).
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Nebu.OAuth.TestSupport, as: T

  @pages Nebu.OAuth.Pages
  @locale Nebu.Web.Locale
  @catalog Nebu.Web.PageText
  @shell Nebu.Web.PageShell

  # data-error code => the status the endpoints send it with
  @codes [
    {400, "unknown_client"},
    {400, "invalid_redirect_uri"},
    {400, "invalid_request"},
    {403, "client_pending"},
    {403, "client_rejected"},
    {400, "invalid_state"},
    {403, "device_in_use"},
    {403, "forbidden"},
    {404, "not_found"},
    {404, "unavailable"},
    {429, "rate_limited"},
    {405, "method_not_allowed"},
    {500, "server_error"}
  ]

  @de_header "de-AT,de;q=0.9,en;q=0.5"

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

  # ── helpers ────────────────────────────────────────────────────────────────

  defp request(accept_language) do
    conn = conn(:get, "/oauth2/authorize")
    if accept_language == nil, do: conn, else: put_req_header(conn, "accept-language", accept_language)
  end

  defp render(accept_language, status, code, opts \\ []),
    do: apply(@pages, :send_page, [request(accept_language), status, code, opts])

  defp lang(body) do
    case Regex.run(~r/<html lang="([^"]*)"/, body) do
      [_, l] -> l
      _ -> nil
    end
  end

  defp tag_text(body, tag) do
    case Regex.run(~r/<#{tag}\b[^>]*>(.*?)<\/#{tag}>/s, body) do
      [_, inner] -> inner |> String.replace(~r/<[^>]+>/, " ") |> String.replace(~r/\s+/, " ") |> String.trim()
      _ -> ""
    end
  end

  defp css(body) do
    [[_, css]] = Regex.scan(~r/<style>(.*?)<\/style>/s, body)
    css
  end

  defp csp_directives(conn) do
    (T.header(conn, "content-security-policy") || "")
    |> String.split(";", trim: true)
    |> Map.new(fn d ->
      case d |> String.trim() |> String.split(" ", parts: 2) do
        [k, v] -> {k, v}
        [k] -> {k, ""}
      end
    end)
  end

  defp luminance("#" <> hex) do
    hex = if byte_size(hex) == 3, do: hex |> String.graphemes() |> Enum.map_join(&(&1 <> &1)), else: hex
    <<r, g, b>> = Base.decode16!(String.upcase(hex))

    [r, g, b]
    |> Enum.map(fn c ->
      c = c / 255
      if c <= 0.03928, do: c / 12.92, else: :math.pow((c + 0.055) / 1.055, 2.4)
    end)
    |> then(fn [r, g, b] -> 0.2126 * r + 0.7152 * g + 0.0722 * b end)
  end

  defp contrast(a, b) do
    {l1, l2} = {luminance(a), luminance(b)}
    (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
  end

  # ── scenarios ──────────────────────────────────────────────────────────────

  # Scenario: An error page follows the browser language
  #   Given a request to /oauth2/authorize with an unknown client and the header "Accept-Language: de-AT,de;q=0.9,en;q=0.5"
  #   When the error page is rendered
  #   Then it is German (html lang "de", German title, heading and explanation) and keeps data-page "oauth-error" and data-error "unknown_client"
  @tag ac: "an-error-page-follows-the-browser-language"
  test "Scenario: An error page follows the browser language" do
    # the locale helper itself
    assert apply(@locale, :from_conn, [request(@de_header)]) == :de
    assert apply(@locale, :from_conn, [request("de")]) == :de
    assert apply(@locale, :from_conn, [request("DE-ch")]) == :de
    assert apply(@locale, :from_conn, [request("en-GB,de;q=0.5")]) == :en
    assert apply(@locale, :from_conn, [request(nil)]) == :en

    # the rendered unknown_client page
    en = render(nil, 400, "unknown_client")
    de = render(@de_header, 400, "unknown_client")

    assert de.status == 400
    body = de.resp_body
    assert lang(body) == "de"
    assert body =~ ~s(<main data-page="oauth-error" data-error="unknown_client">)

    for tag <- ["title", "h1", "p"] do
      assert tag_text(body, tag) != "", "German <#{tag}> must not be blank"
      assert tag_text(body, tag) != tag_text(en.resp_body, tag), "German <#{tag}> must differ from the English one"
    end

    german_words = ~r/\b(nicht|ist|sind|Sie|Ihr\w*|Anmeldung|App|die|der|das|und|diesem|Server)\b/
    assert tag_text(body, "h1") =~ german_words
    assert tag_text(body, "p") =~ german_words
    refute body =~ tag_text(en.resp_body, "h1"), "no English heading on the German page"

    # through the real router (POST => 405 page, no database involved): the locale reaches the authorize endpoint
    Application.put_env(:nebu_http, :oauth_repo, T.NoSuchRepo)
    routed = T.authorize(T.authorize_params("some-client", "https://app.example.com/cb"), method: :post, headers: [{"accept-language", @de_header}])
    T.assert_page(routed, 405, "method_not_allowed")
    assert lang(routed.resp_body) == "de"
    assert T.header(routed, "allow") == "GET"
  end

  # Scenario: Unknown, missing or malformed language falls back to English
  #   Given requests with "Accept-Language: fr", no Accept-Language header, and the garbage value "xx;;q=,,*"
  #   When the error page is rendered
  #   Then each page is English with html lang "en", the value is never echoed into the body or any header, and the response is still 200 / the original status
  @tag ac: "unknown-missing-or-malformed-language-falls-back-to-english"
  test "Scenario: Unknown, missing or malformed language falls back to English" do
    english = render(nil, 400, "unknown_client")
    refute lang(english.resp_body) == "de"

    inputs = [
      "fr",
      nil,
      "xx;;q=,,*",
      "*",
      "de;q=",
      ",,,",
      "<script>alert(1)</script>;q=x",
      String.duplicate("zz,", 4000)
    ]

    for input <- inputs do
      assert apply(@locale, :from_conn, [request(input)]) == :en, "Accept-Language #{inspect(String.slice(input || "", 0, 20))} must fall back to :en"

      for {status, code} <- [{400, "unknown_client"}, {403, "client_pending"}, {500, "server_error"}] do
        conn = render(input, status, code, client_host: "client.example.com")
        assert conn.status == status, "the original status stays (#{status})"
        assert T.header(conn, "location") == nil
        assert lang(conn.resp_body) == "en"
        assert conn.resp_body =~ ~s(data-error="#{code}")

        assert tag_text(conn.resp_body, "h1") == tag_text(render(nil, status, code, client_host: "client.example.com").resp_body, "h1")

        if input not in [nil, "fr", "*", ",,,"] do
          needle = String.slice(input, 0, 12)
          refute conn.resp_body =~ needle, "the Accept-Language value is never echoed into the body"

          for {name, value} <- conn.resp_headers do
            refute value =~ needle, "the Accept-Language value is never echoed into header #{name}"
          end
        end
      end
    end

    # an unsupported locale renders byte-for-byte the English page
    fr = render("fr", 400, "unknown_client")
    assert lang(fr.resp_body) == "en"
    assert fr.resp_body == english.resp_body, "an unsupported language renders exactly the English page"
  end

  # Scenario: Every page wears the Nebu look without loosening the CSP
  #   Given any page rendered by the shell
  #   When its HTML and headers are inspected
  #   Then it shows the inline hexagon-N logo, uses the dark Obsidian tokens and a prefers-color-scheme light variant, has exactly one inline style allowed by its SHA-256 in the CSP, loads no external resource or font, and the CSP is not looser than before
  @tag ac: "every-page-wears-the-nebu-look-without-loosening-the-csp"
  test "Scenario: Every page wears the Nebu look without loosening the CSP" do
    assert Code.ensure_loaded?(@shell), "the shared shell module #{inspect(@shell)} must exist"

    for accept <- [nil, @de_header], {status, code} <- @codes do
      conn = render(accept, status, code, client_host: "client.example.com", retry_after: 30, allow: "GET")
      body = conn.resp_body
      where = "#{code} (#{accept || "no Accept-Language"})"

      # logo: inline SVG only, never an <img>, every svg hidden from or labelled for assistive tech
      svgs = Regex.scan(~r/<svg\b[^>]*>/, body)
      assert svgs != [], "inline hexagon-N logo missing on #{where}"

      for [svg] <- svgs do
        assert svg =~ ~r/aria-hidden="true"|aria-label=|role="img"/, "svg must be decorative or labelled on #{where}"
      end

      refute body =~ ~r/<img\b/i

      # Obsidian tokens (DESIGN.md section 4): dark default + light variant behind prefers-color-scheme
      style = css(body)
      for hex <- ["#111827", "#1f2937", "#f9fafb", "#f97316"], do: assert(style =~ ~r/#{hex}/i, "dark token #{hex} missing on #{where}")
      assert style =~ ~r/@media\s*\(\s*prefers-color-scheme:\s*light\s*\)/, "light variant missing on #{where}"
      for hex <- ["#f3f4f6", "#4b5563", "#c2410c"], do: assert(style =~ ~r/#{hex}/i, "light token #{hex} missing on #{where}")
      assert style =~ ~r/#fff(fff)?\b/i
      assert style =~ ~r/:focus-visible/, "visible focus style missing on #{where}"
      assert style =~ ~r/forced-colors/, "forced-colors rule missing on #{where}"
      refute body =~ ~r/<meta name="color-scheme" content="light">/, "the page is dark by default, not light-only"

      # exactly one inline <style>, no style attributes (the CSP has no unsafe-hashes), no external anything
      assert [[_, ^style]] = Regex.scan(~r/<style>(.*?)<\/style>/s, body)
      refute body =~ ~r/\sstyle\s*=/i
      refute body =~ ~r/(src|href|action)\s*=\s*["']?(https?:)?\/\//i
      refute style =~ ~r/url\(|@import|@font-face/i
      refute body =~ ~r/<link\b|<script\b|<iframe\b|<form\b/i

      # CSP: the one style hash, nothing looser than before (default-src none, no new sources, no unsafe-*)
      directives = csp_directives(conn)
      hash = :crypto.hash(:sha256, style) |> Base.encode64()
      assert directives["default-src"] == "'none'"
      assert directives["style-src"] == "'sha256-#{hash}'", "style-src must be exactly the hash of the one inline style on #{where}"
      assert directives["base-uri"] == "'none'"
      assert directives["form-action"] == "'none'"
      assert directives["frame-ancestors"] == "'none'"
      assert Map.keys(directives) -- ["default-src", "style-src", "base-uri", "form-action", "frame-ancestors", "img-src"] == []
      if Map.has_key?(directives, "img-src"), do: assert(directives["img-src"] == "'none'")
      refute T.header(conn, "content-security-policy") =~ ~r/unsafe-|font-src|script-src|\*/

      # headers unchanged
      assert T.header(conn, "x-frame-options") == "DENY"
      assert T.header(conn, "cache-control") =~ "no-store"
      assert T.header(conn, "pragma") == "no-cache"
      assert T.header(conn, "referrer-policy") == "no-referrer"
      assert T.header(conn, "access-control-allow-origin") == nil
    end
  end

  # Scenario: The catalog is complete in both languages
  #   Given the string catalog and the code lists of the error pages
  #   When the completeness test runs
  #   Then every key has a non-empty English and German text, every error code has title, heading, explanation and actions in both, and a missing key fails the build instead of rendering a blank
  @tag ac: "the-catalog-is-complete-in-both-languages"
  test "Scenario: The catalog is complete in both languages" do
    assert Code.ensure_loaded?(@catalog), "the string catalog module #{inspect(@catalog)} must exist"

    # the code list of the error pages is the one this test knows (no code silently added or dropped)
    assert Enum.sort(apply(@pages, :codes, [])) == @codes |> Enum.map(&elem(&1, 1)) |> Enum.sort()

    for {status, code} <- @codes do
      en = render(nil, status, code)
      de = render(@de_header, status, code)

      for {conn, language} <- [{en, "en"}, {de, "de"}] do
        body = conn.resp_body
        where = "#{code}/#{language}"

        assert lang(body) == language
        assert body =~ ~s(<main data-page="oauth-error" data-error="#{code}">)
        assert String.length(tag_text(body, "title")) > 5, "title missing on #{where}"
        assert tag_text(body, "h1") != "", "heading missing on #{where}"
        assert tag_text(body, "p") != "", "explanation missing on #{where}"
        assert tag_text(body, "strong") != "", "primary suggestion (bold line) missing on #{where}"

        # the old "What you can do" h2 is gone; no blank element and no placeholder leaks
        refute body =~ ~r/What you can do/i
        refute body =~ ~r/<h2\b/
        refute body =~ ~r/<(title|h1|p|li|strong|summary)\b[^>]*>\s*<\/\1>/, "blank element on #{where}"
        refute body =~ ~r/translation missing|missing translation|\#\{|%\{|\{\{|\bnil\b|\bundefined\b/i, "unresolved key on #{where}"
      end

      assert tag_text(de.resp_body, "title") != tag_text(en.resp_body, "title"), "title not translated for #{code}"
      assert tag_text(de.resp_body, "h1") != tag_text(en.resp_body, "h1"), "heading not translated for #{code}"
      assert tag_text(de.resp_body, "p") != tag_text(en.resp_body, "p"), "explanation not translated for #{code}"
      assert tag_text(de.resp_body, "strong") != tag_text(en.resp_body, "strong"), "primary suggestion not translated for #{code}"
    end
  end

  # Scenario: Request-derived values stay inert and the page stays accessible
  #   Given an error page that shows the unverified app website host "<img src=x onerror=1>.example"
  #   When it is rendered in German and in English
  #   Then the host is HTML-escaped plain text, there is one main and one h1, the text contrast is at least 4.5:1 in both themes, the focus outline is visible and the layout works at 320 px
  @tag ac: "request-derived-values-stay-inert-and-the-page-stays-accessible"
  test "Scenario: Request-derived values stay inert and the page stays accessible" do
    host = "<img src=x onerror=1>.example"
    escaped = Plug.HTML.html_escape(host)

    for accept <- [nil, @de_header], code <- ["client_pending", "client_rejected"] do
      conn = render(accept, 403, code, client_host: host)
      body = conn.resp_body
      where = "#{code} (#{accept || "en"})"

      assert lang(body) == if(accept, do: "de", else: "en")
      assert body =~ escaped, "the host must appear HTML-escaped on #{where}"
      refute body =~ "<img", "the host must stay inert on #{where}"
      refute body =~ ~r/<[^>]*\son\w+\s*=/i, "no live event handler on #{where}"
      refute body =~ ~r/<a[\s>]/i, "the host is never a link on #{where}"

      assert [_] = Regex.scan(~r/<main\b/, body), "exactly one <main> on #{where}"
      assert [_] = Regex.scan(~r/<h1\b/, body), "exactly one <h1> on #{where}"
      assert body =~ ~r/<meta name="viewport"[^>]*width=device-width/i

      # visible focus, 320 px layout (long hosts wrap, no wide fixed minimum, fluid max-width)
      style = css(body)
      assert style =~ ~r/:focus-visible[^{]*\{[^}]*outline/, "visible focus outline on #{where}"
      assert style =~ "overflow-wrap:anywhere"
      assert style =~ ~r/max-width/
      refute style =~ ~r/min-width:\s*(3[2-9]\d|[4-9]\d\d|\d{4,})px/, "a fixed minimum width above 320px on #{where}"
    end

    # WCAG 2.1 text contrast >= 4.5:1 in both themes (the token pairs the shell must use; DESIGN.md section 4)
    style = css(render(nil, 403, "client_pending", client_host: host).resp_body)

    dark_bg = "#1f2937"
    light_bg = "#ffffff"

    for {fg, bg} <- [
          {"#f9fafb", dark_bg},
          {"#9ca3af", dark_bg},
          {"#fb923c", dark_bg},
          {"#f9fafb", "#111827"},
          {"#111827", light_bg},
          {"#4b5563", light_bg},
          {"#c2410c", light_bg},
          {"#111827", "#f3f4f6"},
          {"#1c1917", "#f97316"}
        ] do
      assert style =~ ~r/#{fg}/i, "token #{fg} (text) missing from the shared stylesheet"
      assert contrast(fg, bg) >= 4.5, "#{fg} on #{bg} is below 4.5:1"
    end

    # the error text colours of the warning/error notices must also be in the sheet (both themes)
    for hex <- ["#fca5a5", "#7f1d1d"], do: assert(style =~ ~r/#{hex}/i, "notice text token #{hex} missing")
  end
end
