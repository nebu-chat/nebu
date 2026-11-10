defmodule Nebu.Matrix.SsoConfirmPage do
  @moduledoc """
  The pages of the legacy SSO redirect confirmation (story `legacy-sso-redirect-confirmation`, epic SEC gate 3
  finding G3-3, decisions D9 and D15): the confirmation page, the "cancelled" page, the error pages and the
  headers of every response of the flow, including the `303`s.

  Standalone HTML in the Nebu look (story oauth-pages-redesign/04): the frame, the ONE shared `<style>` and the logo come from
  `Nebu.Web.PageShell`, the texts (English / German by the browser's `Accept-Language`, `Nebu.Web.Locale`) from
  `Nebu.Web.PageText` (`sso.*`, `err.*`). Same decision-first structure as the consent page: h1, risk notice, the target
  origin as the app block, Cancel first, Continue (armed), ONE visible hint line, the user id and the path inside ONE
  closed `<details>`. No admin layout, no external resource, no image, no link, no `autofocus`, no inline event handler. Every request-derived value (the Matrix user id, the displayed path) is
  HTML-escaped with `Plug.HTML.html_escape/1`; the page never shows the query or the fragment of the redirect
  URL; the error pages render no request value at all.

  ## Contract (E2E / test hooks, D15)

  `<main data-page="sso-confirm" data-result="pending">`, ONE `<h1>` "Continue signing in to this app?",
  `data-role="target-origin"` (the ASCII / `xn--` host, port only when not 443), a "Warning:" notice,
  `data-role="user-id"` and the optional `data-role="target-path"` (raw, truncated to 60 characters) inside the `<details>`, ONE `<form method="post"
  action="/_matrix/client/v3/login/sso/confirm">` with the hidden `csrf_token` and two equal-weight submit buttons,
  Cancel FIRST, Continue (`id="continue"`, `data-arm`) rendered `aria-disabled="true"` (never `disabled`, UX B1) and aria-described by the
  hint (`data-arm-hint`, visible by default), the target origin and the notice, the polite live region
  (`data-arm-status`, empty until the script announces), a
  `<noscript>` (Continue needs JavaScript: fail closed, only Cancel works) and ONE inline script, exactly
  `Nebu.Web.ArmScript.script/0`, pinned by its SHA-256 in the CSP. `data-page="sso-confirm" data-result="cancelled"`
  after Cancel, `data-page="sso-confirm-error" data-error="invalid_state|forbidden|invalid_request|rate_limited|unavailable"`
  for the error pages. `lang` follows the browser, a STATIC `<title>`, a visible focus outline, 44 px touch targets, works at 320 px.

  ## Headers

  Every response of the flow: `Cache-Control: no-store`, `Pragma: no-cache`, `X-Frame-Options: DENY`, no
  `access-control-*` header, and NO `Cross-Origin-Opener-Policy` (oracle M1: popup-based web clients such as
  FluffyChat web open the SSO flow with `window.open` and receive the result through `window.opener`; COOP on any
  response of the chain would sever the opener). `Referrer-Policy: same-origin` on the confirmation page (with
  `no-referrer` the page's OWN form POST would carry `Origin: null`), `no-referrer` on everything else. CSP of the
  confirmation page: `default-src 'none'; style-src 'sha256-<css>'; script-src 'sha256-<script>'; img-src 'none';
  base-uri 'none'; frame-ancestors 'none'; form-action 'self' https://host[:port]` - Chromium applies
  `form-action` to the redirect after the form POST, and the only redirect target of the form is the https origin,
  built ONLY from the validated host and port of the stored entry (a hostile value can never reach the header).
  The cancel and error pages: `default-src 'none'; style-src 'sha256-<css>'; base-uri 'none'; form-action 'none';
  frame-ancestors 'none'`, no script.
  """

  import Plug.Conn

  alias Nebu.Web.{Locale, PageShell, PageText}

  @confirm_path "/_matrix/client/v3/login/sso/confirm"

  # The ONE inline style block is the shared one of the Nebu page shell; its hash is the CSP style source.
  @css_hash Base.encode64(:crypto.hash(:sha256, PageShell.css()))
  @script Nebu.Web.ArmScript.script()
  @script_hash Base.encode64(:crypto.hash(:sha256, @script))

  @max_path_chars 60

  @warn_icon ~s(<svg viewBox="0 0 20 20" width="20" height="20" fill="currentColor" aria-hidden="true" focusable="false">) <>
               ~s(<path d="M10 2 1 18h18L10 2Zm-1 6h2v5H9V8Zm0 6h2v2H9v-2Z"/></svg>)

  # error code => catalog keys of the further suggestions (under "More options"). Title, heading, explanation and the bold
  # primary suggestion of a code are the shared `err.<code>.title|heading|explanation|primary` texts.
  @errors %{
    "invalid_state" => ["sso.more.back_to_app"],
    "forbidden" => ["sso.more.use_buttons"],
    "invalid_request" => ["sso.more.use_buttons", "act.contact"],
    "rate_limited" => [],
    "unavailable" => []
  }

  # A key missing in either language fails the build, never renders a blank.
  for {code, more} <- @errors,
      key <-
        [
          "err.#{code}.title",
          "err.#{code}.heading",
          "err.#{code}.explanation",
          "err.#{code}.primary"
        ] ++ more,
      lang <- [:en, :de] do
    PageText.fetch!(key, lang)
  end

  @doc "The inline CSS of the pages (the shared shell stylesheet; its SHA-256 is in every CSP)."
  @spec css() :: String.t()
  def css, do: PageShell.css()

  # ── headers ──────────────────────────────────────────────────────────────────

  @doc """
  Headers of the `303`s of the flow (callback -> page, Continue -> client target) and the base of every page:
  `Cache-Control: no-store`, `Pragma: no-cache`, `Referrer-Policy: no-referrer`, `X-Frame-Options: DENY`, and every
  `access-control-*` header the global CORS plug may already have put on the conn deleted (browser navigation).
  Never `Cross-Origin-Opener-Policy`.
  """
  @spec put_flow_headers(Plug.Conn.t()) :: Plug.Conn.t()
  def put_flow_headers(conn) do
    conn =
      conn.resp_headers
      |> Enum.map(&elem(&1, 0))
      |> Enum.filter(&String.starts_with?(&1, "access-control-"))
      |> Enum.reduce(conn, &delete_resp_header(&2, &1))

    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("pragma", "no-cache")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("x-frame-options", "DENY")
  end

  @doc "A `303 See Other` to `location` with the flow headers and an empty body."
  @spec see_other(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def see_other(conn, location) do
    conn
    |> put_flow_headers()
    |> put_resp_header("location", location)
    |> send_resp(303, "")
  end

  defp html_headers(conn, csp) do
    conn
    |> put_flow_headers()
    |> put_resp_header("content-security-policy", csp)
    |> put_resp_content_type("text/html")
  end

  defp page_csp(form_action) do
    "default-src 'none'; style-src 'sha256-#{@css_hash}'; script-src 'sha256-#{@script_hash}'; img-src 'none'; base-uri 'none'; " <>
      "frame-ancestors 'none'; form-action 'self' #{form_action}"
  end

  # ── the confirmation page ────────────────────────────────────────────────────

  @doc """
  Renders and SENDS the confirmation page (status 200) from the stored `entry` (`:host`, `:port`, `:path`,
  `:user_id`) and the CSRF token: `{:ok, conn}`, or `:error` (nothing sent) when the stored host / port is not a
  valid CSP host-source (fail closed: the caller answers the `invalid_state` page). The language comes from the conn.
  """
  @spec send_page(Plug.Conn.t(), map(), String.t()) :: {:ok, Plug.Conn.t()} | :error
  def send_page(conn, entry, csrf_token) when is_binary(csrf_token) do
    with {:ok, host, port} <- valid_target(entry) do
      source = "https://" <> host <> port_suffix(port)
      lang = Locale.from_conn(conn)

      conn =
        conn
        |> html_headers(page_csp(source))
        |> put_resp_header("referrer-policy", "same-origin")
        |> send_resp(200, render_page(lang, entry, host, port, csrf_token))

      {:ok, conn}
    end
  end

  defp valid_target(%{host: host, port: port}) when is_binary(host) do
    if Nebu.Matrix.SsoRedirect.valid_https_host?(host) and valid_port?(port),
      do: {:ok, host, port},
      else: :error
  end

  defp valid_target(_entry), do: :error

  defp valid_port?(nil), do: true
  defp valid_port?(port), do: is_integer(port) and port in 1..65_535 and port != 443

  defp port_suffix(nil), do: ""
  defp port_suffix(port), do: ":" <> Integer.to_string(port)

  defp t(lang, key), do: PageShell.esc(PageText.fetch!(key, lang))

  # Order (design 5.2): h1, the risk notice, the target origin as the app block, (the IDN note), the form (Cancel first, Continue
  # armed, ONE hint line, live region, noscript), the collapsed details (user id, path). The shell adds the logo, the style block
  # and the one arming script.
  defp render_page(lang, entry, host, port, csrf_token) do
    content =
      Enum.join(
        [
          "<h1>#{t(lang, "sso.confirm.heading")}</h1>",
          ~s(<div class="notice error icon" id="confirm-notice">#{@warn_icon}<p><strong>#{t(lang, "consent.warning")}</strong> #{t(lang, "sso.confirm.notice")}</p></div>),
          ~s(<div class="app"><div><span class="claim">#{t(lang, "sso.confirm.origin_label")}</span>) <>
            ~s(<span class="name"><code id="target-origin" data-role="target-origin">#{PageShell.esc("https://" <> host <> port_suffix(port))}</code></span></div></div>),
          idn_notice(host, lang),
          ~s(<form method="post" action="#{@confirm_path}">),
          ~s(<input type="hidden" name="csrf_token" value="#{PageShell.esc(csrf_token)}">),
          ~s(<div class="actions">),
          ~s(<button type="submit" name="decision" value="cancel" class="btn secondary">#{t(lang, "sso.confirm.cancel")}</button>),
          ~s(<button type="submit" name="decision" value="continue" id="continue" class="btn primary" form="sso-confirm-armed" aria-disabled="true" aria-describedby="arm-hint target-origin confirm-notice" data-arm>#{t(lang, "sso.confirm.continue")}</button>),
          "</div>",
          ~s(<p class="muted hint" id="arm-hint" data-arm-hint>#{t(lang, "sso.confirm.arm_hint")}</p>),
          ~s(<p class="muted" role="status" data-arm-status></p>),
          ~s(<noscript><p class="muted">#{t(lang, "sso.confirm.noscript")}</p></noscript>),
          "</form>",
          details(entry, lang)
        ]
        |> Enum.reject(&(&1 == "")),
        "\n"
      )

    PageShell.render(lang,
      title: PageText.fetch!("sso.confirm.title", lang),
      main_attrs: ~s(data-page="sso-confirm" data-result="pending"),
      content: content,
      script: @script
    )
  end

  defp idn_notice(host, lang) do
    if host |> String.split(".") |> Enum.any?(&String.starts_with?(&1, "xn--")),
      do: ~s(<p class="muted" data-role="idn-notice">#{t(lang, "sso.confirm.idn")}</p>),
      else: ""
  end

  # The user id and the raw path as received (percent-encoded form, cut at 60 characters; omitted for an empty path or `/`).
  defp details(entry, lang) do
    rows =
      [
        ~s(<dt>#{t(lang, "sso.confirm.d.user")}</dt>\n<dd data-role="user-id">#{PageShell.esc(entry[:user_id])}</dd>),
        path_row(entry[:path], lang)
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    "<details>\n<summary>#{t(lang, "consent.details")}</summary>\n<dl>\n#{rows}\n</dl>\n</details>"
  end

  defp path_row(path, lang) when is_binary(path) and path not in ["", "/"] do
    shown =
      if String.length(path) > @max_path_chars,
        do: String.slice(path, 0, @max_path_chars) <> "...",
        else: path

    ~s(<dt>#{t(lang, "sso.confirm.d.path")}</dt>\n<dd data-role="target-path">#{PageShell.esc(shown)}</dd>)
  end

  defp path_row(_path, _lang), do: ""

  # ── cancelled and error pages ────────────────────────────────────────────────

  @doc "The `200` page after Cancel: no token was minted, the entry is gone."
  @spec send_cancelled(Plug.Conn.t()) :: Plug.Conn.t()
  def send_cancelled(conn) do
    lang = Locale.from_conn(conn)

    body =
      PageShell.render(lang,
        title: PageText.fetch!("sso.cancelled.title", lang),
        main_attrs: ~s(data-page="sso-confirm" data-result="cancelled"),
        content:
          "<h1>#{t(lang, "sso.cancelled.title")}</h1>\n<p>#{t(lang, "sso.cancelled.text")}</p>"
      )

    conn
    |> html_headers(PageShell.csp())
    |> send_resp(200, body)
  end

  @doc """
  An error page (`data-page="sso-confirm-error"`, `data-error=<code>`) with the given status. Renders NO request
  value. Options: `:retry_after` (seconds, a `Retry-After` header for `rate_limited` / `unavailable`).
  """
  @spec send_error(Plug.Conn.t(), pos_integer(), String.t(), keyword()) :: Plug.Conn.t()
  def send_error(conn, status, code, opts \\ []) do
    code = if Map.has_key?(@errors, code), do: code, else: "unavailable"
    lang = Locale.from_conn(conn)

    conn
    |> html_headers(PageShell.csp())
    |> maybe_retry_after(opts[:retry_after])
    |> send_resp(status, render_error(lang, code))
  end

  defp render_error(lang, code) do
    key = &"err.#{code}.#{&1}"

    more_html =
      case Map.fetch!(@errors, code) do
        [] ->
          ""

        keys ->
          items = Enum.map_join(keys, "\n", &"<li>#{t(lang, &1)}</li>")

          "\n<details>\n<summary>#{t(lang, "ui.more_options")}</summary>\n<ul>\n#{items}\n</ul>\n</details>"
      end

    content =
      "#{PageShell.status_icon()}\n" <>
        "<h1>#{t(lang, key.("heading"))}</h1>\n" <>
        "<p>#{t(lang, key.("explanation"))}</p>\n" <>
        "<p class=\"primary\"><strong>#{t(lang, key.("primary"))}</strong></p>#{more_html}"

    PageShell.render(lang,
      title: PageText.fetch!(key.("title"), lang),
      main_attrs: ~s(data-page="sso-confirm-error" data-error="#{code}"),
      content: content
    )
  end

  defp maybe_retry_after(conn, seconds) when is_integer(seconds) and seconds >= 0,
    do: put_resp_header(conn, "retry-after", Integer.to_string(seconds))

  defp maybe_retry_after(conn, _none), do: conn
end
