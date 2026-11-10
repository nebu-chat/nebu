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

  Rendered through `Nebu.Web.PageShell` (logo, the one shared `<style>`, `lang`) with the texts of `Nebu.Web.PageText`
  (`consent.*`, English or German by `Nebu.Web.Locale`). Order (design 5.1): logo, ONE `<h1>` (static, like the
  `<title>`), the risk notices that apply, the app block (claimed name + "Name given by the app, not verified"), ONE
  permission sentence naming the user id, the device name line `data-role="device-name"` (or, when no name can be
  derived, the required `<input id="device-name" name="device_name">` inside the form with its own
  `id="device-name-error"` `role="alert"` message after a refusal), ONE `<form method="post" action="/oauth2/consent">`
  with the hidden `csrf_token` and two `<button type="submit" name="decision" value="deny|allow">` (Deny first, class
  `secondary`; Allow `id="allow"`, class `primary`, `aria-describedby="arm-hint arm-instructions[ <rendered notice ids>]"`),
  ONE visible hint line `id="arm-hint"` (`data-arm-hint`), the full mouse / keyboard / touch instructions in a visually
  hidden element `id="arm-instructions"` (never `hidden`, never inside `<details>`), the live region `data-arm-status`,
  a `<noscript>` line, the fine print and ONE closed `<details>` ("Show details") holding the app website, the
  destination (`<dt id="consent-destination-label">` / `<dd id="consent-destination">`), the session line, terms and
  privacy URLs (escaped plain text, never links). The notices `freshness-notice`, `destination-notice`, `replace-notice`
  are `<div class="notice ..." id data-role>` with an icon, a bold text label and no `role`; they are never inside the
  details. `<main data-page="oauth-consent" data-device="new|same_client|replace" data-fresh="true|false">`.

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
  alias Nebu.Web.{Locale, PageShell, PageText}

  # The ONE inline style block is the shared one of the Nebu page shell (story oauth-pages-redesign/02); its hash is the CSP style source.
  @css Nebu.Web.PageShell.css()

  @css_hash Base.encode64(:crypto.hash(:sha256, @css))

  # The ONE inline script (see the moduledoc): the shared arming script of the decision pages.
  @script Nebu.Web.ArmScript.script()

  @script_hash Base.encode64(:crypto.hash(:sha256, @script))

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
  holder}`, `holder` = the `Nebu.Matrix.oauth_device_holder/2` map), `:login_fresh`, `:csrf_token`; optional `:device_name` (story oauth-pages-redesign / 01-device-naming-chain: `{:derived, name}` | `{:existing, name}` shows the
  name the device will carry in ONE line `data-role="device-name"`, `:ask` renders the required text input `device_name`), `:name_error` (the page is shown
  again after an Allow without a usable name) and `:status` (default 200, 422 after that refusal).
  """
  @spec send_page(Plug.Conn.t(), map()) :: {:ok, Plug.Conn.t()} | :error
  def send_page(conn, assigns) do
    case target(assigns.redirect_uri) do
      {:ok, target} ->
        lang = Locale.from_conn(conn)
        conn = conn |> put_headers(target.source) |> send_resp(Map.get(assigns, :status, 200), render(assigns, target, lang))
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

  @warn_icon ~s(<svg viewBox="0 0 20 20" width="20" height="20" fill="currentColor" aria-hidden="true" focusable="false">) <>
               ~s(<path d="M10 2 1 18h18L10 2Zm-1 6h2v5H9V8Zm0 6h2v2H9v-2Z"/></svg>)

  @shield_icon ~s(<svg viewBox="0 0 20 20" width="20" height="20" fill="currentColor" aria-hidden="true" focusable="false">) <>
                 ~s(<path d="M10 1 3 4v5c0 4.4 3 8.3 7 10 4-1.7 7-5.6 7-10V4l-7-3Z"/></svg>)

  # Order (design 5.1): h1, the notices that apply, the app block, ONE permission sentence, the device name line, the form
  # (name field when asked, Deny, Allow, the one-line hint, the visually hidden instructions, the live region), the fine print,
  # the collapsed details. The shell adds the logo, the style block and (here only) the one arming script.
  defp render(a, target, lang) do
    meta = a.client_metadata || %{}
    device_state = device_state(a.device)
    fresh = freshness_notice(a.login_fresh, lang)
    dest = destination_notice(target, meta["client_uri"], lang)
    repl = replace_notice(a.device, a.device_id, lang)
    notice_ids = for {id, _html} <- [fresh, dest, repl], id != nil, do: id
    described_by = Enum.join(["arm-hint", "arm-instructions" | notice_ids], " ")
    device_name = Map.get(a, :device_name)

    content =
      Enum.join(
        [
          "<h1>#{t(lang, "consent.heading")}</h1>",
          html(fresh) <> html(dest) <> html(repl),
          app_block(meta["client_name"], lang),
          permission(a.user_id, lang),
          device_name_line(device_name, lang),
          ~s(<form method="post" action="/oauth2/consent">),
          ~s(<input type="hidden" name="csrf_token" value="#{PageShell.esc(a.csrf_token)}">),
          device_name_input(device_name, Map.get(a, :name_error, false), lang),
          ~s(<div class="actions">),
          ~s(<button type="submit" name="decision" value="deny" class="btn secondary" formnovalidate>#{t(lang, "consent.deny")}</button>),
          ~s(<button type="submit" name="decision" value="allow" id="allow" class="btn primary" form="oauth-consent-armed" aria-disabled="true" aria-describedby="#{described_by}" data-arm>#{t(lang, "consent.allow")}</button>),
          "</div>",
          ~s(<p class="muted hint" id="arm-hint" data-arm-hint>#{t(lang, "consent.arm_hint")}</p>),
          ~s(<p class="sr-only" id="arm-instructions">#{t(lang, "consent.arm_instructions")}</p>),
          ~s(<p class="muted" role="status" data-arm-status></p>),
          ~s(<noscript><p class="muted">#{t(lang, "consent.noscript")}</p></noscript>),
          "</form>",
          ~s(<p class="fine">#{t(lang, "consent.fine")}</p>),
          details(a, meta, target, lang)
        ]
        |> Enum.reject(&(&1 == "")),
        "\n"
      )

    PageShell.render(lang,
      title: PageText.fetch!("consent.title", lang),
      main_attrs: ~s(data-page="oauth-consent" data-device="#{device_state}" data-fresh="#{a.login_fresh == true}"),
      content: content,
      script: @script
    )
  end

  defp t(lang, key), do: PageShell.esc(PageText.fetch!(key, lang))

  # A catalog text with `{name}` placeholders: the text is escaped, then ONE pass fills the placeholders with already-safe HTML.
  defp fill(lang, key, vars),
    do: Regex.replace(~r/\{([a-z_]+)\}/, t(lang, key), fn _all, k -> Map.fetch!(vars, k) end)

  defp html({_id, html}), do: html

  # WHO asks: the app's claimed name (clean text) and the line that Nebu has not verified it.
  defp app_block(client_name, lang) do
    ~s(<div class="app"><div><span class="name">#{name(client_name, lang)}</span><span class="claim">#{t(lang, "consent.claim")}</span></div></div>)
  end

  # WHAT it gets, in ONE sentence.
  defp permission(user_id, lang) do
    ~s(<div class="perm">#{@shield_icon}<p class="lead">#{t(lang, "consent.perm.as")} <strong>#{PageShell.esc(user_id)}</strong> ) <>
      ~s(#{t(lang, "consent.perm.gets")} <strong>#{t(lang, "consent.perm.full")}</strong>#{t(lang, "consent.perm.rest")}</p></div>)
  end

  # The name the device will carry (plain text, escaped). Nothing is rendered when the user is asked instead (the input carries the question).
  defp device_name_line({kind, name}, lang) when kind in [:derived, :existing] and is_binary(name),
    do:
      ~s(<p class="devname"><span class="muted" id="consent-device-name-label">#{t(lang, "consent.devname")}</span><br>) <>
        ~s(<strong id="consent-device-name" data-role="device-name">#{cut_80(name)}</strong></p>)

  defp device_name_line(_plan, _lang), do: ""

  # A long (or hostile) device name is cut at 80 characters wherever it is shown.
  defp cut_80(name), do: if(String.length(name) > 80, do: PageShell.esc(String.slice(name, 0, 80)) <> "...", else: PageShell.esc(name))

  # Required, at most 64 characters, labelled. `formnovalidate` on Deny keeps Deny available without a name. Enter inside the field is the
  # form's default button (Deny, first in the DOM), so the help text names the Allow button.
  defp device_name_input(:ask, name_error, lang) do
    error =
      if name_error,
        do:
          ~s(<div class="notice error icon" id="device-name-error" data-role="device-name-error" role="alert">#{@warn_icon}<p><strong>#{t(lang, "consent.name_error.label")}</strong> #{t(lang, "consent.name_error.text")}</p></div>\n),
        else: ""

    described = if name_error, do: "device-name-error device-name-hint", else: "device-name-hint"

    error <>
      ~s(<div class="field"><label for="device-name">#{t(lang, "consent.name_label")}</label>\n) <>
      ~s(<input type="text" id="device-name" name="device_name" required maxlength="64" autocomplete="off" aria-describedby="#{described}">\n) <>
      ~s(<p class="muted" id="device-name-hint">#{t(lang, "consent.name_hint")}</p></div>)
  end

  defp device_name_input(_plan, _name_error, _lang), do: ""

  # The collapsed details: website, destination, session, terms, privacy. Everything the app supplies is escaped plain text, never a link.
  defp details(a, meta, target, lang) do
    rows =
      [
        ~s(<dt>#{t(lang, "consent.d.website")}</dt>\n<dd>#{website(meta["client_uri"], lang)}</dd>),
        ~s(<dt id="consent-destination-label">#{t(lang, "consent.d.destination")}</dt>\n<dd id="consent-destination">#{destination(target, meta["client_uri"], lang)}</dd>),
        ~s(<dt>#{t(lang, "consent.d.session")}</dt>\n<dd>#{session_line(a.device, a.device_id, lang)}</dd>),
        claim(t(lang, "consent.d.terms"), meta["tos_uri"]),
        claim(t(lang, "consent.d.privacy"), meta["policy_uri"])
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    "<details>\n<summary>#{t(lang, "consent.details")}</summary>\n<dl>\n#{rows}\n</dl>\n</details>"
  end

  # Shown unless the login is EXACTLY known to be fresh (a missing / nil value never hides it: fail closed).
  # The three warning blocks are `{id, html}` (or `{nil, ""}` when not rendered): the id list of Allow's
  # `aria-describedby` is built from exactly the rendered ones. They are static text, no live region (UX N4).
  defp freshness_notice(true, _lang), do: {nil, ""}

  defp freshness_notice(_not_fresh, lang),
    do: notice("freshness-notice", "error", t(lang, "consent.warning"), t(lang, "consent.fresh.text"))

  # L-5: an https destination that is NOT part of the website the app claims is the phishing case: say so.
  defp destination_notice(%{kind: :https, host: host}, client_uri, lang) do
    case host_of(client_uri) do
      nil ->
        {nil, ""}

      site ->
        if part_of_website?(host, site),
          do: {nil, ""},
          else:
            notice(
              "destination-notice",
              "error",
              t(lang, "consent.warning"),
              fill(lang, "consent.dest.text", %{"host" => PageShell.esc(host), "site" => PageShell.esc(site)})
            )
    end
  end

  defp destination_notice(_target, _client_uri, _lang), do: {nil, ""}

  # A1: the session that is going to be signed out, before the form, device name first.
  defp replace_notice({:replace, holder}, device_id, lang),
    do:
      notice(
        "replace-notice",
        "warn",
        t(lang, "consent.headsup"),
        fill(lang, "consent.replace.text", %{"name" => holder_name(holder, lang), "id" => PageShell.esc(device_id)})
      )

  defp replace_notice(_device, _device_id, _lang), do: {nil, ""}

  # icon + bold text label + text: the meaning is never colour alone
  defp notice(id, kind, label, body),
    do:
      {id,
       ~s(<div class="notice #{kind} icon" id="#{id}" data-role="#{id}">#{@warn_icon}<p><strong>#{label}</strong> #{body}</p></div>\n)}

  # Control / format / separator characters are dropped: a claimed name never reaches the page with an invisible or terminal-control character.
  defp name(n, lang) when is_binary(n) and n != "" do
    clean = if String.valid?(n), do: String.replace(n, ~r/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u, ""), else: ""
    if clean == "", do: t(lang, "consent.no_name"), else: PageShell.esc(clean)
  end

  defp name(_n, lang), do: t(lang, "consent.no_name")

  defp website(uri, lang) do
    case host_of(uri) do
      nil -> t(lang, "consent.none_given")
      host -> PageShell.esc(host)
    end
  end

  # The terms / privacy URLs the app claims are shown as escaped PLAIN TEXT, never as a link (a hostile
  # client must not get a clickable link on a Nebu page); omitted when absent. `label` is already safe HTML.
  defp claim(label, uri) when is_binary(uri) and uri != "", do: "<dt>#{label}</dt>\n<dd>#{PageShell.esc(uri)}</dd>"
  defp claim(_label, _uri), do: ""

  defp destination(%{kind: :https, host: host, port: port}, client_uri, lang) do
    shown = host <> if(port, do: ":#{port}", else: "")

    if part_of_website?(host, host_of(client_uri)),
      do: PageShell.esc(shown) <> " " <> t(lang, "consent.dest.part"),
      else: PageShell.esc(shown)
  end

  defp destination(%{kind: :loopback, host: host, port: port}, _client_uri, lang) do
    detail = if port, do: fill(lang, "consent.dest.port", %{"host" => PageShell.esc(host), "port" => PageShell.esc(port)}), else: PageShell.esc(host)
    fill(lang, "consent.dest.local", %{"detail" => detail})
  end

  defp destination(%{kind: :private, scheme: scheme}, _client_uri, lang),
    do: fill(lang, "consent.dest.local", %{"detail" => PageShell.esc(scheme) <> ":"})

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

  defp session_line(:new, device_id, lang), do: fill(lang, "consent.session.new", %{"id" => PageShell.esc(device_id)})

  defp session_line({:same_client, holder}, device_id, lang),
    do:
      fill(lang, "consent.session.same", %{
        "name" => holder_name(holder, lang),
        "id" => PageShell.esc(device_id),
        "when" => last_active(holder, lang)
      })

  defp session_line({:replace, holder}, device_id, lang),
    do:
      fill(lang, "consent.session.replace", %{
        "name" => holder_name(holder, lang),
        "id" => PageShell.esc(device_id),
        "when" => last_active(holder, lang)
      })

  # A10: a long (or hostile) device name is cut at 80 characters
  defp holder_name(%{display_name: name}, _lang) when is_binary(name) and name != "" do
    if String.length(name) > 80, do: PageShell.esc(String.slice(name, 0, 80)) <> "...", else: PageShell.esc(name)
  end

  defp holder_name(_holder, lang), do: t(lang, "consent.unnamed_device")

  defp last_active(%{last_seen_ts: ms}, lang) when is_integer(ms) do
    case DateTime.from_unix(ms, :millisecond) do
      {:ok, dt} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
      _ -> t(lang, "consent.unknown_time")
    end
  end

  defp last_active(_holder, lang), do: t(lang, "consent.unknown_time")
end
