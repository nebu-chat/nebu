defmodule Nebu.Matrix.SsoConfirmPage do
  @moduledoc """
  The pages of the legacy SSO redirect confirmation (story `legacy-sso-redirect-confirmation`, epic SEC gate 3
  finding G3-3, decisions D9 and D15): the confirmation page, the "cancelled" page, the error pages and the
  headers of every response of the flow, including the `303`s.

  Standalone HTML like the OAuth consent page (no admin layout, no external resource, no image, no link, no
  `autofocus`, no inline event handler). Every request-derived value (the Matrix user id, the displayed path) is
  HTML-escaped with `Plug.HTML.html_escape/1`; the page never shows the query or the fragment of the redirect
  URL; the error pages render no request value at all.

  ## Contract (E2E / test hooks, D15)

  `<main data-page="sso-confirm" data-result="pending">`, ONE `<h1>` "Continue signing in to this app?",
  `data-role="user-id"`, a `<dl>` with `data-role="target-origin"` (the ASCII / `xn--` host, port only when not
  443) and the optional path (raw, truncated to 60 characters), a "Warning:" notice, ONE `<form method="post"
  action="/_matrix/client/v3/login/sso/confirm">` with the hidden `csrf_token` and two equal-weight submit buttons,
  Cancel FIRST, Continue (`id="continue"`, `data-arm`) rendered `aria-disabled="true"` (never `disabled`, UX B1) and aria-described by the
  hint (`data-arm-hint`, visible by default), the target origin and the notice, the polite live region
  (`data-arm-status`, empty until the script announces), a
  `<noscript>` (Continue needs JavaScript: fail closed, only Cancel works) and ONE inline script, exactly
  `Nebu.Web.ArmScript.script/0`, pinned by its SHA-256 in the CSP. `data-page="sso-confirm" data-result="cancelled"`
  after Cancel, `data-page="sso-confirm-error" data-error="invalid_state|forbidden|invalid_request|rate_limited|unavailable"`
  for the error pages. `lang="en"`, a STATIC `<title>`, a visible focus outline, 44 px touch targets, works at 320 px.

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

  @confirm_path "/_matrix/client/v3/login/sso/confirm"

  @css "*{box-sizing:border-box}body{font-family:system-ui,sans-serif;line-height:1.5;margin:0;padding:1.5rem 1rem;color:#1a1a1a;background:#fff;overflow-wrap:anywhere}" <>
         "main{max-width:40rem;margin:0 auto}h1{font-size:1.5rem;margin:0 0 1rem}h2{font-size:1.1rem;margin:1.5rem 0 .5rem}p{margin:0 0 1rem}ul{margin:0 0 1rem;padding-left:1.25rem}" <>
         "dl{margin:0 0 1.25rem}dt{font-weight:bold;margin-top:.85rem}dd{margin:0}" <>
         ".notice{padding:.75rem 1rem;border:2px solid #b3261e;border-radius:.25rem;background:#fce8e6;margin:0 0 1rem}" <>
         "dd.key{font-size:1.15rem;font-weight:bold}code{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;background:#f1f3f4;border:1px solid #747775;border-radius:.25rem;padding:.1rem .35rem;overflow-wrap:anywhere}.hint{margin:1rem 0 0;font-size:.95rem}[hidden]{display:none}" <>
         ".actions{display:flex;flex-wrap:wrap;gap:1rem;margin-top:1rem}" <>
         "button{flex:1 1 8rem;min-height:44px;padding:.6rem 1rem;border:2px solid #0b57d0;border-radius:.25rem;background:#fff;color:#0b57d0;font:inherit;font-weight:bold;cursor:pointer}" <>
         "button:focus{outline:3px solid #1a1a1a;outline-offset:2px}button[aria-disabled=true]{opacity:.6;cursor:not-allowed}" <>
         "@media (forced-colors:active){button{border:2px solid ButtonText}.notice{border:2px solid CanvasText}}"

  @css_hash Base.encode64(:crypto.hash(:sha256, @css))
  @script Nebu.Web.ArmScript.script()
  @script_hash Base.encode64(:crypto.hash(:sha256, @script))

  @title "Confirm sign-in"
  @max_path_chars 60

  # kind => {status hint, title, heading, explanation, actions}
  @errors %{
    "invalid_state" =>
      {"Sign-in link expired", "This sign-in link has expired or was already used. Start signing in again from your app.",
       ["Go back to the app you were signing in to.", "Start signing in again.", "You can close this window."]},
    "forbidden" =>
      {"Sign-in request refused", "Nebu could not verify that this request came from the confirmation page you were shown.",
       ["Go back to the confirmation page and use its buttons.", "If that does not work, start signing in again from your app."]},
    "invalid_request" =>
      {"Sign-in request refused", "The request could not be read. Nothing was changed.",
       ["Go back to the confirmation page and use its buttons.", "If that does not work, start signing in again from your app."]},
    "rate_limited" =>
      {"Too many requests", "Too many requests were made from your address. Nothing was changed.",
       ["Wait a moment, then try again from the same page."]},
    "unavailable" =>
      {"Sign-in unavailable", "Nebu cannot complete this step right now. No sign-in token was issued.",
       ["Wait a moment, then start signing in again from your app."]}
  }

  @doc "The inline CSS of the pages (its SHA-256 is in every CSP)."
  @spec css() :: String.t()
  def css, do: @css

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

  defp static_csp,
    do: "default-src 'none'; style-src 'sha256-#{@css_hash}'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"

  defp page_csp(form_action) do
    "default-src 'none'; style-src 'sha256-#{@css_hash}'; script-src 'sha256-#{@script_hash}'; img-src 'none'; base-uri 'none'; " <>
      "frame-ancestors 'none'; form-action 'self' #{form_action}"
  end

  # ── the confirmation page ────────────────────────────────────────────────────

  @doc """
  Renders and SENDS the confirmation page (status 200) from the stored `entry` (`:host`, `:port`, `:path`,
  `:user_id`) and the CSRF token: `{:ok, conn}`, or `:error` (nothing sent) when the stored host / port is not a
  valid CSP host-source (fail closed: the caller answers the `invalid_state` page).
  """
  @spec send_page(Plug.Conn.t(), map(), String.t()) :: {:ok, Plug.Conn.t()} | :error
  def send_page(conn, entry, csrf_token) when is_binary(csrf_token) do
    with {:ok, host, port} <- valid_target(entry) do
      source = "https://" <> host <> port_suffix(port)

      conn =
        conn
        |> html_headers(page_csp(source))
        |> put_resp_header("referrer-policy", "same-origin")
        |> send_resp(200, render_page(entry, host, port, csrf_token))

      {:ok, conn}
    end
  end

  defp valid_target(%{host: host, port: port}) when is_binary(host) do
    if Nebu.Matrix.SsoRedirect.valid_https_host?(host) and valid_port?(port), do: {:ok, host, port}, else: :error
  end

  defp valid_target(_entry), do: :error

  defp valid_port?(nil), do: true
  defp valid_port?(port), do: is_integer(port) and port in 1..65_535 and port != 443

  defp port_suffix(nil), do: ""
  defp port_suffix(port), do: ":" <> Integer.to_string(port)

  defp render_page(entry, host, port, csrf_token) do
    """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="color-scheme" content="light">
    <title>#{@title}</title>
    <style>#{@css}</style>
    </head>
    <body>
    <main data-page="sso-confirm" data-result="pending">
    <h1>Continue signing in to this app?</h1>
    <p>You are signed in as <strong data-role="user-id">#{esc(entry[:user_id])}</strong>.</p>
    <dl>
    <dt>The app asks to be sent to</dt>
    <dd class="key"><code id="target-origin" data-role="target-origin">#{esc("https://" <> host <> port_suffix(port))}</code></dd>
    #{idn_notice(host)}#{path_line(entry[:path])}</dl>
    <p class="notice" id="confirm-notice"><strong>Warning:</strong> This address is not on the list of apps your administrator trusts. Continuing gives the app at this address full access to your Matrix account: it can read and send messages as you. Only continue if you just started signing in to this app yourself and you recognise the address. If you did not, choose Cancel. Cancel stops the sign-in. Nothing is sent to the app. This request expires in 5 minutes.</p>
    <form method="post" action="#{@confirm_path}">
    <input type="hidden" name="csrf_token" value="#{esc(csrf_token)}">
    <p class="hint" id="arm-hint" data-arm-hint>Continue becomes available a moment after you move the pointer, press a key, scroll, tap or move the focus. Then move onto Continue to use it.</p>
    <p class="hint" role="status" data-arm-status></p>
    <noscript><p class="hint">JavaScript is off, so Continue stays unavailable. Turn on JavaScript or use another browser. You can still choose Cancel.</p></noscript>
    <div class="actions">
    <button type="submit" name="decision" value="cancel">Cancel</button>
    <button type="submit" name="decision" value="continue" id="continue" form="sso-confirm-armed" aria-disabled="true" aria-describedby="arm-hint target-origin confirm-notice" data-arm>Continue</button>
    </div>
    </form>
    <script>#{@script}</script>
    </main>
    </body>
    </html>
    """
  end

  defp idn_notice(host) do
    if host |> String.split(".") |> Enum.any?(&String.starts_with?(&1, "xn--")),
      do: ~s(<dt>Note</dt>\n<dd data-role="idn-notice">This address uses special characters, which can be used to imitate another address. It is shown in a technical form starting with xn--. Check it carefully.</dd>\n),
      else: ""
  end

  # The raw path as received (percent-encoded form), cut at 60 characters; omitted for an empty path or `/`.
  defp path_line(path) when is_binary(path) and path not in ["", "/"] do
    shown =
      if String.length(path) > @max_path_chars,
        do: String.slice(path, 0, @max_path_chars) <> "...",
        else: path

    ~s(<dt>Path</dt>\n<dd data-role="target-path">#{esc(shown)}</dd>\n)
  end

  defp path_line(_path), do: ""

  # ── cancelled and error pages ────────────────────────────────────────────────

  @doc "The `200` page after Cancel: no token was minted, the entry is gone."
  @spec send_cancelled(Plug.Conn.t()) :: Plug.Conn.t()
  def send_cancelled(conn) do
    conn
    |> html_headers(static_csp())
    |> send_resp(
      200,
      shell("sso-confirm", ~s(data-result="cancelled"), "Sign-in cancelled", "Sign-in cancelled", "<p>No access was given. You can close this window.</p>\n")
    )
  end

  @doc """
  An error page (`data-page="sso-confirm-error"`, `data-error=<code>`) with the given status. Renders NO request
  value. Options: `:retry_after` (seconds, a `Retry-After` header for `rate_limited` / `unavailable`).
  """
  @spec send_error(Plug.Conn.t(), pos_integer(), String.t(), keyword()) :: Plug.Conn.t()
  def send_error(conn, status, code, opts \\ []) do
    code = if Map.has_key?(@errors, code), do: code, else: "unavailable"
    {heading, explanation, actions} = Map.fetch!(@errors, code)

    items = Enum.map_join(actions, "", &"<li>#{&1}</li>\n")

    body =
      "<p>#{explanation}</p>\n<h2>What you can do</h2>\n<ul>\n#{items}</ul>\n"

    conn
    |> html_headers(static_csp())
    |> maybe_retry_after(opts[:retry_after])
    |> send_resp(status, shell("sso-confirm-error", ~s(data-error="#{code}"), heading, heading, body))
  end

  defp maybe_retry_after(conn, seconds) when is_integer(seconds) and seconds >= 0,
    do: put_resp_header(conn, "retry-after", Integer.to_string(seconds))

  defp maybe_retry_after(conn, _none), do: conn

  # Every page has its OWN static `<title>` (never a request value).
  defp shell(page, extra_attr, title, heading, body) do
    """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="color-scheme" content="light">
    <title>#{title}</title>
    <style>#{@css}</style>
    </head>
    <body>
    <main data-page="#{page}" #{extra_attr}>
    <h1>#{heading}</h1>
    #{body}</main>
    </body>
    </html>
    """
  end

  defp esc(value), do: value |> to_string() |> Plug.HTML.html_escape()
end
