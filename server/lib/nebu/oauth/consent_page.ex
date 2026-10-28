defmodule Nebu.OAuth.ConsentPage do
  @moduledoc """
  The server-rendered consent screen of `GET /oauth2/consent` (epic oauth-broker, story
  oauth-authorize-freshness, ADR-033 FR9 / FR10): where the user decides, BEFORE any authorization code
  exists, whether THIS app gets the account and which device session is created or replaced.

  Standalone HTML like `Nebu.OAuth.Pages` / `Nebu.OAuth.AccountPages` (no admin layout, no external resource,
  no image, no link, no `autofocus`, no inline event handler). Every request-derived value (the user id, the
  app's claimed name / website / terms / privacy URLs, the device id, the display name of the device being
  replaced) is HTML-escaped with `Plug.HTML.html_escape/1` and labelled as a CLAIM of the app where it is one.
  Nothing the app supplies is ever a link.

  ## Arming Allow (security review cycle 1, M-1, G3-5, ADR-033 FR21)

  Against "double clickjacking" (an attacker page opens a window that lands on this page behind the victim's
  second click of a double click) the page carries exactly ONE inline script: `Nebu.Web.ArmScript.script()`, the
  same byte-identical script as the SSO confirmation page, pinned by its SHA-256 in the CSP
  (`script-src 'sha256-...'`, no `'unsafe-inline'`). The Allow button is rendered `aria-disabled="true"` (never
  `disabled`: it stays focusable and announced), carries `data-arm` and a `form="oauth-consent-armed"` attribute
  that points at NO form (so without JavaScript Allow is inert and the implicit submission of the form is Deny).
  The script arms it only after REAL interaction elsewhere on this page AND at least 600 ms after load, and then
  accepts a mouse click only after a pointer movement onto Allow that follows the arming (a pointer parked on the
  Allow position cannot activate it) and a keyboard activation only after the focus moved onto Allow after the
  arming. A visible hint (`data-arm-hint`) explains it and the polite live region (`data-arm-status`) announces
  the arming and a blocked click. Deny is never `aria-disabled` and comes first in the DOM and visual order.
  Without JavaScript Allow stays unavailable (fail closed: the user can only Deny; a `<noscript>` line says so).
  The server never trusts the button state: the decision is checked as before (cookie, CSRF token, fetch
  metadata); the arming is a usability barrier against an unintended click, not an authorization. The
  double-click risk is REDUCED, not eliminated (G3-5): a double-click and a multi-gesture lure with the pointer
  parked on Allow are closed. Residuals (touch, a keyboard lure with pauses, a moving-target "click game" whose
  click opens this page so that Allow sits under the next target, where only the 600 ms dwell remains) are
  recorded in ADR-033 FR21. `Cross-Origin-Opener-Policy: same-origin`
  severs the opener relationship of a popup that lands here (unlike the SSO page, D5 of story
  `consent-arming-hardening`).

  ## Contract (E2E / test hooks)

  `<main data-page="oauth-consent" data-device="new|same_client|replace" data-fresh="true|false">`, ONE `<h1>`
  "Allow this app to use your Matrix account?", the facts in ONE `<dl>`, ONE `<form method="post"
  action="/oauth2/consent">` with the hidden `csrf_token` and two `<button type="submit" name="decision"
  value="allow|deny">` (Allow: `id="allow"`, `aria-describedby="arm-hint consent-destination-label consent-destination[ <rendered
  notice ids>]"`; the warning blocks `freshness-notice`, `destination-notice`, `replace-notice` carry their id and no
  `role`; the destination `<dt>` / `<dd>` are `id="consent-destination-label"` / `id="consent-destination"`). `lang="en"`, a STATIC `<title>` (never a request value), a visible
  focus outline, 44 px touch targets, a layout that works at 320 px, a text label on the notice (no
  colour-only meaning).

  ## Headers (`put_headers/2`)

  `no-store`, `Pragma: no-cache`, `X-Frame-Options: DENY`, `Cross-Origin-Opener-Policy: same-origin`,
  `Referrer-Policy: same-origin` (`no-referrer` would make the page's OWN form POST carry `Origin: null`), no
  CORS, and the CSP `default-src 'none'; style-src 'sha256-<css>'; script-src 'sha256-<script>'; img-src
  'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self' <target>`. Chromium applies `form-action` to the redirect that FOLLOWS a form POST, so `<target>` is the
  redirect target of the consent row, built ONLY from parsed components (`form_action_source/1`): the https
  origin `https://host[:port]`; for a LOOPBACK redirect (`localhost`, `127.0.0.1`, `[::1]`) NO host source
  but the scheme source `http:` (an IPv6 literal is not a valid CSP host-source); for a private-use scheme
  the scheme source `<scheme>:`. The scheme is lower-cased first. When no valid source can be built the
  caller answers the `server_error` page and consumes nothing.
  """

  import Plug.Conn

  alias Nebu.OAuth.{Pages, PublicSuffix}

  @css "*{box-sizing:border-box}body{font-family:system-ui,sans-serif;line-height:1.5;margin:0;padding:1.5rem 1rem;color:#1a1a1a;background:#fff;overflow-wrap:anywhere}" <>
         "main{max-width:40rem;margin:0 auto}h1{font-size:1.5rem;margin:0 0 1rem}p{margin:0 0 1rem}" <>
         "dl{margin:0 0 1.25rem}dt{font-weight:bold;margin-top:.85rem}dd{margin:0}" <>
         ".notice{padding:.75rem 1rem;border:2px solid #b3261e;border-radius:.25rem;background:#fce8e6;margin:0 0 1rem}" <>
         "dd.key{font-size:1.15rem;font-weight:bold}.hint{margin:1rem 0 0;font-size:.95rem}[hidden]{display:none}" <>
         ".actions{display:flex;flex-wrap:wrap;gap:1rem;margin-top:1rem}" <>
         "button{flex:1 1 8rem;min-height:44px;padding:.6rem 1rem;border:2px solid #0b57d0;border-radius:.25rem;background:#fff;color:#0b57d0;font:inherit;font-weight:bold;cursor:pointer}" <>
         "button:focus{outline:3px solid #1a1a1a;outline-offset:2px}button[aria-disabled=true]{opacity:.6;cursor:not-allowed}" <>
         "@media (forced-colors:active){button{border:2px solid ButtonText}.notice{border:2px solid CanvasText}}"

  @css_hash Base.encode64(:crypto.hash(:sha256, @css))

  # The ONE inline script (see the moduledoc): the shared arming script of the decision pages.
  @script Nebu.Web.ArmScript.script()

  @script_hash Base.encode64(:crypto.hash(:sha256, @script))

  @title "Allow this app to use your Matrix account"

  @not_sure "Nebu cannot check which app on your device receives this."

  # A private-use scheme (RFC 8252 7.1) is the reverse-DNS of the app's domain; these can never be one.
  @unusable_schemes ~w(javascript data blob file about vbscript ws wss ftp filesystem)

  @loopback ~r/\A(localhost|127\.0\.0\.1|\[::1\])(?::([0-9]{1,5}))?\z/
  @https_authority ~r/\A([a-z0-9][a-z0-9.\-]*)(?::([0-9]{1,5}))?\z/

  @doc "The inline CSS of the page (its SHA-256 is in the CSP)."
  @spec css() :: String.t()
  def css, do: @css

  @doc """
  The redirect target of `redirect_uri` for the page: `{:ok, %{kind: :https | :loopback | :private, scheme:,
  host:, port:, source:}}` (`source` = the CSP `form-action` source, see the moduledoc) or `:error` when no
  valid source can be built. Built from parsed components only (scheme `[a-z][a-z0-9+.-]*`, host
  `[a-z0-9.-]+`, numeric port); a hostile value never reaches a header.
  """
  @spec target(String.t()) :: {:ok, map()} | :error
  def target(redirect_uri) when is_binary(redirect_uri) do
    case Regex.run(~r/\A([A-Za-z][A-Za-z0-9+.\-]*):(.*)\z/s, redirect_uri) do
      [_, scheme, rest] -> target(String.downcase(scheme), rest)
      _ -> :error
    end
  end

  def target(_redirect_uri), do: :error

  defp target("https", "//" <> rest) do
    [authority | _] = String.split(rest, ["/", "?", "#"], parts: 2)

    case Regex.run(@https_authority, String.downcase(authority)) do
      [_, host | port] ->
        port = port_of(port, 443)
        {:ok, %{kind: :https, scheme: "https", host: host, port: port, source: "https://" <> host <> if(port, do: ":#{port}", else: "")}}

      _ ->
        :error
    end
  end

  defp target("http", "//" <> rest) do
    [authority | _] = String.split(rest, ["/", "?", "#"], parts: 2)

    case Regex.run(@loopback, String.downcase(authority)) do
      # a scheme source only: an IPv6 literal is no valid host-source, and the port is not pinned
      [_, host | port] -> {:ok, %{kind: :loopback, scheme: "http", host: host, port: port_of(port, nil), source: "http:"}}
      _ -> :error
    end
  end

  defp target(scheme, _rest) when scheme in ["http", "https"], do: :error
  defp target(scheme, _rest) when scheme in @unusable_schemes, do: :error
  defp target(scheme, _rest), do: {:ok, %{kind: :private, scheme: scheme, host: nil, port: nil, source: scheme <> ":"}}

  defp port_of([port], default) do
    case Integer.parse(port) do
      {n, ""} when n in 1..65_535 and n != default -> n
      _ -> nil
    end
  end

  defp port_of(_none, _default), do: nil

  @doc "The CSP `form-action` source of `redirect_uri` (see `target/1`): `{:ok, source}` or `:error`."
  @spec form_action_source(String.t()) :: {:ok, String.t()} | :error
  def form_action_source(redirect_uri) do
    case target(redirect_uri) do
      {:ok, %{source: source}} -> {:ok, source}
      :error -> :error
    end
  end

  @doc """
  Renders and SENDS the consent page with status 200: `{:ok, conn}`, or `:error` (nothing sent) when the
  redirect target yields no valid CSP source. `assigns`: `:user_id`, `:client_metadata` (the registered
  metadata map), `:redirect_uri`, `:device_id`, `:device` (`:new | {:same_client, holder} | {:replace,
  holder}`, `holder` = the `Nebu.Matrix.oauth_device_holder/2` map), `:login_fresh`, `:csrf_token`.
  """
  @spec send_page(Plug.Conn.t(), map()) :: {:ok, Plug.Conn.t()} | :error
  def send_page(conn, assigns) do
    case target(assigns.redirect_uri) do
      {:ok, target} ->
        conn = conn |> put_headers(target.source) |> send_resp(200, render(assigns, target))
        {:ok, conn}

      :error ->
        :error
    end
  end

  @doc "The headers of the page: flow headers (no-store, no CORS), framing / referrer / CSP, `text/html`."
  @spec put_headers(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def put_headers(conn, form_action_source) do
    conn
    |> Pages.put_flow_headers()
    |> put_resp_header("referrer-policy", "same-origin")
    |> put_resp_header("content-security-policy", csp(form_action_source))
    |> put_resp_header("x-frame-options", "DENY")
    |> put_resp_header("cross-origin-opener-policy", "same-origin")
    |> put_resp_content_type("text/html")
  end

  defp csp(source) do
    "default-src 'none'; style-src 'sha256-#{@css_hash}'; script-src 'sha256-#{@script_hash}'; img-src 'none'; base-uri 'none'; " <>
      "frame-ancestors 'none'; form-action 'self' #{source}"
  end

  # ── rendering ───────────────────────────────────────────────────────────────

  defp render(a, target) do
    meta = a.client_metadata || %{}
    device_state = device_state(a.device)
    fresh = freshness_notice(a.login_fresh)
    dest = destination_notice(target, meta["client_uri"])
    repl = replace_notice(a.device, a.device_id)
    described_by = Enum.join(["arm-hint", "consent-destination-label", "consent-destination" | for({id, _html} <- [fresh, dest, repl], id != nil, do: id)], " ")

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
    <main data-page="oauth-consent" data-device="#{device_state}" data-fresh="#{a.login_fresh == true}">
    <h1>Allow this app to use your Matrix account?</h1>
    #{html(fresh)}#{html(dest)}<p>Signed in as <strong>#{esc(a.user_id)}</strong>.</p>
    <dl>
    <dt>App name (claimed by the app)</dt>
    <dd class="key">#{name(meta["client_name"])}</dd>
    <dt>App website (claimed by the app, not verified by Nebu)</dt>
    <dd>#{website(meta["client_uri"])}</dd>
    <dt id="consent-destination-label">After you choose, you are sent to</dt>
    <dd class="key" id="consent-destination">#{destination(target, meta["client_uri"])}</dd>
    <dt>Your session</dt>
    <dd>#{session_line(a.device, a.device_id)}</dd>
    <dt>What this app can do</dt>
    <dd>Full access to your account: read and send messages, and manage your rooms, devices and encryption keys.</dd>
    #{claim("Terms of service (claimed by the app)", meta["tos_uri"])}#{claim("Privacy policy (claimed by the app)", meta["policy_uri"])}</dl>
    #{html(repl)}<p>Only allow this if you just started signing in to this app yourself.</p>
    <form method="post" action="/oauth2/consent">
    <input type="hidden" name="csrf_token" value="#{esc(a.csrf_token)}">
    <p class="hint" id="arm-hint" data-arm-hint>Mouse: move the pointer onto Allow, then click. Keyboard: move the focus onto Allow, then press Enter. Touch: tap Allow. Allow becomes available a moment after your first interaction with the page; this protects you from accidental clicks.</p>
    <p class="hint" role="status" data-arm-status></p>
    <noscript><p class="hint">JavaScript is off, so Allow stays unavailable even after the steps above. Turn on JavaScript or use another browser. You can still choose Deny.</p></noscript>
    <div class="actions">
    <button type="submit" name="decision" value="deny">Deny</button>
    <button type="submit" name="decision" value="allow" id="allow" form="oauth-consent-armed" aria-disabled="true" aria-describedby="#{described_by}" data-arm>Allow</button>
    </div>
    </form>
    <script>#{@script}</script>
    </main>
    </body>
    </html>
    """
  end

  # Shown unless the login is EXACTLY known to be fresh (a missing / nil value never hides it: fail closed).
  # The three warning blocks are `{id, html}` (or `{nil, ""}` when not rendered): the id list of Allow's
  # `aria-describedby` is built from exactly the rendered ones. They are static text, no live region (UX N4).
  defp freshness_notice(true), do: {nil, ""}

  defp freshness_notice(_not_fresh),
    do:
      {"freshness-notice",
       ~s(<p class="notice" id="freshness-notice" data-role="freshness-notice"><strong>Warning:</strong> You were not asked for your password just now. ) <>
         ~s(Your sign-in provider did not confirm a new sign-in for this request. ) <>
         ~s(If you did not just start signing in to this app yourself, choose Deny.</p>\n)}

  defp html({_id, html}), do: html

  # L-5: an https destination that is NOT part of the website the app claims is the phishing case: say so.
  defp destination_notice(%{kind: :https, host: host}, client_uri) do
    case host_of(client_uri) do
      nil ->
        {nil, ""}

      site ->
        if part_of_website?(host, site),
          do: {nil, ""},
          else:
            {"destination-notice",
             "<p class=\"notice\" id=\"destination-notice\" data-role=\"destination-notice\"><strong>Warning:</strong> You are sent to #{esc(host)}, " <>
               "which does not belong to the website this app names (#{esc(site)}). Only continue if you trust it.</p>\n"}
    end
  end

  defp destination_notice(_target, _client_uri), do: {nil, ""}

  # A1: the session that is going to be signed out, as its own labelled block before the form, device name first.
  defp replace_notice({:replace, holder}, device_id),
    do:
      {"replace-notice",
       ~s(<p class="notice" id="replace-notice" data-role="replace-notice"><strong>Warning:</strong> Another session will be signed out: ) <>
         "#{holder_name(holder)} (device #{esc(device_id)}).</p>\n"}

  defp replace_notice(_device, _device_id), do: {nil, ""}

  defp name(n) when is_binary(n) and n != "", do: esc(n)
  defp name(_n), do: "No name given"

  defp website(uri) do
    case host_of(uri) do
      nil -> "None given"
      host -> esc(host)
    end
  end

  # The terms / privacy URLs the app claims are shown as escaped PLAIN TEXT, never as a link (a hostile
  # client must not get a clickable link on a Nebu page); omitted when absent.
  defp claim(label, uri) when is_binary(uri) and uri != "", do: "<dt>#{label}</dt>\n<dd>#{esc(uri)}</dd>\n"
  defp claim(_label, _uri), do: ""

  defp destination(%{kind: :https, host: host, port: port}, client_uri) do
    shown = host <> if(port, do: ":#{port}", else: "")
    if part_of_website?(host, host_of(client_uri)), do: esc(shown) <> " (part of the app website)", else: esc(shown)
  end

  defp destination(%{kind: :loopback, host: host, port: port}, _client_uri) do
    detail = if port, do: "#{host}, port #{port}", else: host
    "an app on this device (#{esc(detail)}). #{@not_sure}"
  end

  defp destination(%{kind: :private, scheme: scheme}, _client_uri),
    do: "an app on this device (#{esc(scheme)}:). #{@not_sure}"

  # The redirect host is the app's own website when it IS the registered `client_uri` host or a subdomain of
  # it (a label boundary: `notapp.example.com` and `app.example.com.evil.org` are not).
  # `site` must be a real registrable name: a bare public suffix (`github.io`, `co.uk`) or a single label as the
  # client website would make every host below it "part of the app website" (L-5).
  defp part_of_website?(_host, nil), do: false

  defp part_of_website?(host, site) do
    case PublicSuffix.classify(site) do
      {:ok, %{public_suffix?: false}} -> host == site or String.ends_with?(host, "." <> site)
      _ -> false
    end
  end

  defp host_of(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{host: host} when is_binary(host) and host != "" -> String.downcase(host)
      _ -> nil
    end
  end

  defp host_of(_uri), do: nil

  defp device_state(:new), do: "new"
  defp device_state({:same_client, _holder}), do: "same_client"
  defp device_state({:replace, _holder}), do: "replace"

  defp session_line(:new, device_id), do: "A new session (device #{esc(device_id)}) will be created."

  defp session_line({:same_client, holder}, device_id),
    do: "Continues your existing session #{holder_name(holder)} (device #{esc(device_id)}), last active #{last_active(holder)}."

  defp session_line({:replace, holder}, device_id),
    do:
      "Replaces your existing session #{holder_name(holder)} (device #{esc(device_id)}), last active #{last_active(holder)}, " <>
        "signed in without this app. That session will be signed out."

  # A10: a long (or hostile) device name is cut at 80 characters
  defp holder_name(%{display_name: name}) when is_binary(name) and name != "" do
    if String.length(name) > 80, do: esc(String.slice(name, 0, 80)) <> "...", else: esc(name)
  end

  defp holder_name(_holder), do: "Unnamed device"

  defp last_active(%{last_seen_ts: ms}) when is_integer(ms) do
    case DateTime.from_unix(ms, :millisecond) do
      {:ok, dt} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
      _ -> "at an unknown time"
    end
  end

  defp last_active(_holder), do: "at an unknown time"

  defp esc(value), do: value |> to_string() |> Plug.HTML.html_escape()
end
