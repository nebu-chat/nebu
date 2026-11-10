defmodule Nebu.OAuth.AccountPages do
  @moduledoc """
  The standalone HTML renderer of the account-management page `/account` (epic oauth-broker, story
  oauth-account-management, A20) — like `Nebu.OAuth.Pages` NOT the admin layout / DaisyUI: the page
  lives outside the Admin endpoint (no admin session, no `/admin/static` assets, a stricter CSP, no
  LiveView, no JavaScript except the one pinned click-proof script of the reset page, see Headers).

  Look and language (story oauth-pages-redesign/05): the page frame, tokens, logo and the ONE inline `<style>` come from
  `Nebu.Web.PageShell` (wide variant), the texts from the catalog `Nebu.Web.PageText` (`acct.*`, every text in English and
  German), the language from `Nebu.Web.Locale.from_conn/1` (`Accept-Language`, never echoed). The device list and the apps are
  cards in a `<ul>` (no table); the technical details of a card live in a native `<details>`.

  Content templates are EEx files under `account_templates/`, compiled at COMPILE time with
  `Phoenix.HTML.Engine` (every `<%= %>` value is HTML-escaped; the only raw values are the compile-time
  icons and the already rendered time tags). Every attacker-controlled string (device display names,
  device ids, client names, the profile display name) therefore renders as inert text.

  ## Headers (every page, `put_headers/1,2`)

  `text/html; charset=utf-8`; `Content-Security-Policy: default-src 'none'; style-src 'sha256-<css>';
  img-src 'none'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'` (the hash is the SHA-256
  of the ONE inline `<style>` block of the shell, computed at compile time); `X-Frame-Options: DENY` (clickjacking
  of the destructive buttons); `Cache-Control: no-store`, `Pragma: no-cache`, `Referrer-Policy:
  same-origin` and no CORS header (`Nebu.OAuth.Pages.put_flow_headers/1`). No script, no inline event
  handler, no external resource, no image: the ONE exception is the reset page while it renders the approve form (story
  safari-fetch-metadata-compat): it embeds `Nebu.Web.ClickProofScript.script/0` and its CSP adds `script-src 'sha256-<script>'`
  (no `'unsafe-inline'`), because Safari sends no `Sec-Fetch-User` and the approval needs the click proof.

  ## Accessibility (WCAG 2.1 AA)

  `<html lang>` follows the language, charset + viewport meta, a page-specific `<title>`, ONE `<main>`, ONE `<h1>`, a
  `<nav aria-label>` (Overview, Devices, Apps, Security) with `aria-current="page"`, the device list as a `<ul>` of cards with
  controls whose accessible names include the device, notices with an icon and a text label (no colour-only meaning;
  `role="status"` for success, `role="alert"` for a problem), a visible focus outline, text contrast >= 4.5:1, 44 px touch
  targets, a layout that works at 320 px width, real `<button type="submit">` buttons.

  ## End-to-end hooks

  `<main data-page="account" data-action="<action>">`, `signed-in-as`, `portal-tile` (`data-tile`), device cards
  `data-role="account-device" data-device-id=...` (`device-name`, `device-meta`, `device-row-sign-out`, `device-row-rename`), `device-list`,
  `devices-truncated`, `grant-list`, `consent-grant`, `grants-note`, `grants-details`, `no-grants`, `profile-details`,
  `delete-device-confirm`, `rename-device-form`, `rename-save`, `rename-cancel`, `device-rename`, `cancel`, `reset-request`, `reset-several`, `approve-reset`, `decline-reset`, `reauth`, `notice`
  (`data-notice=...`), `sign-out`, `device-sign-out`. Error pages: `<main data-page="account-error" data-error="<code>">`.
  """

  import Plug.Conn

  require EEx

  alias Nebu.OAuth.Pages
  alias Nebu.Web.{ClickProofScript, Locale, PageShell, PageText}

  @templates Path.expand("account_templates", __DIR__)

  # The ONE inline style block is the shared one of the Nebu page shell; its hash is the CSP style source.
  @css PageShell.css()

  @csp "default-src 'none'; style-src 'sha256-#{Base.encode64(:crypto.hash(:sha256, @css))}'; img-src 'none'; " <>
         "form-action 'self'; base-uri 'none'; frame-ancestors 'none'"

  @script_csp @csp <> "; script-src " <> ClickProofScript.csp_hash()

  # The main line of a device shows a relative time up to this age, then the ISO date (the details always show the UTC time).
  @relative_max_s 7 * 86_400

  # code => {further suggestions under "More options", offer a link back to /account}. Texts: `acct.err.<code>.title|heading|explanation|primary`.
  @errors %{
    "unavailable" => {["act.contact"], false},
    "rate_limited" => {["acct.err.rate_limited.more"], false},
    "method_not_allowed" => {[], true},
    "not_found" => {[], true},
    "invalid_request" => {["act.contact"], true},
    "invalid_state" => {[], true},
    "forbidden" => {["acct.err.forbidden.more"], true},
    "no_account" => {["acct.err.no_account.more"], false},
    "deactivated" => {[], false},
    "reauth_failed" => {["act.contact"], true},
    "access_denied" => {["act.contact"], true},
    "server_error" => {["act.contact"], true}
  }

  # code => {label key, role, kind css class}. Text: `acct.notice.<code>`.
  @notices %{
    "device_deleted" => {"acct.label.done", "status", "success"},
    "reset_approved" => {"acct.label.done", "status", "success"},
    "reset_declined" => {"acct.label.done", "status", "success"},
    "signed_out" => {"acct.label.done", "status", "success"},
    "device_not_found" => {"acct.label.problem", "alert", "error"},
    # story oauth-pages-redesign/06: renaming a device
    "device_renamed" => {"acct.label.done", "status", "success"},
    "device_name_invalid" => {"acct.label.problem", "alert", "error"},
    "invalid_request" => {"acct.label.problem", "alert", "error"},
    "reset_not_found" => {"acct.label.problem", "alert", "error"},
    "stale" => {"acct.label.problem", "alert", "error"},
    # story persistent-consent-grants: withdrawing a remembered consent
    "grant_withdrawn" => {"acct.label.done", "status", "success"},
    "grant_not_found" => {"acct.label.problem", "alert", "error"},
    # story safari-fetch-metadata-compat: a WebKit browser sent no proof that the button was pressed by the user (script blocked,
    # stale page): a note, not an error, nothing was changed
    "activation_unproven" => {"acct.label.note", "status", "info"},
    # story oauth-authorize-freshness (FR14, gate y): the IdP reports no sign-in time, so freshness can never be
    # proven. No reauth link on purpose (it would loop).
    "freshness_unavailable" => {"acct.label.problem", "alert", "error"}
  }

  # A key missing in either language fails the build, never renders a blank.
  for {code, {more, _restart}} <- @errors,
      key <- ["acct.err.#{code}.title", "acct.err.#{code}.heading", "acct.err.#{code}.explanation", "acct.err.#{code}.primary"] ++ more,
      lang <- [:en, :de] do
    PageText.fetch!(key, lang)
  end

  for {code, {label, _role, _kind}} <- @notices, key <- [label, "acct.notice.#{code}"], lang <- [:en, :de] do
    PageText.fetch!(key, lang)
  end

  @ok_icon ~s(<svg viewBox="0 0 20 20" width="20" height="20" fill="currentColor" aria-hidden="true" focusable="false">) <>
             ~s(<path d="M10 1a9 9 0 1 0 0 18 9 9 0 0 0 0-18Zm4.2 6.6-5 5.6a.8.8 0 0 1-1.2.03L5.8 10.9l1.1-1.1 1.6 1.6 4.4-4.9 1.3 1.1Z"/></svg>)

  @info_icon ~s(<svg viewBox="0 0 20 20" width="20" height="20" fill="currentColor" aria-hidden="true" focusable="false">) <>
               ~s(<path d="M10 1a9 9 0 1 0 0 18 9 9 0 0 0 0-18Zm-1 4h2v2H9V5Zm0 4h2v6H9V9Z"/></svg>)

  @problem_icon ~s(<svg viewBox="0 0 20 20" width="20" height="20" fill="currentColor" aria-hidden="true" focusable="false">) <>
                  ~s(<path d="M10 2 1 18h18L10 2Zm-1 6h2v5H9V8Zm0 6h2v2H9v-2Z"/></svg>)

  EEx.function_from_file(:defp, :render_error, Path.join(@templates, "error.html.eex"), [:assigns], engine: Phoenix.HTML.Engine)
  EEx.function_from_file(:defp, :render_overview, Path.join(@templates, "overview.html.eex"), [:assigns], engine: Phoenix.HTML.Engine)
  EEx.function_from_file(:defp, :render_profile, Path.join(@templates, "profile.html.eex"), [:assigns], engine: Phoenix.HTML.Engine)
  EEx.function_from_file(:defp, :render_devices, Path.join(@templates, "devices.html.eex"), [:assigns], engine: Phoenix.HTML.Engine)
  EEx.function_from_file(:defp, :render_device, Path.join(@templates, "device.html.eex"), [:assigns], engine: Phoenix.HTML.Engine)
  EEx.function_from_file(:defp, :render_rename, Path.join(@templates, "rename.html.eex"), [:assigns], engine: Phoenix.HTML.Engine)

  EEx.function_from_file(:defp, :render_delete_confirm, Path.join(@templates, "delete_confirm.html.eex"), [:assigns],
    engine: Phoenix.HTML.Engine
  )

  EEx.function_from_file(:defp, :render_reset, Path.join(@templates, "reset.html.eex"), [:assigns], engine: Phoenix.HTML.Engine)
  EEx.function_from_file(:defp, :render_apps, Path.join(@templates, "apps.html.eex"), [:assigns], engine: Phoenix.HTML.Engine)
  EEx.function_from_file(:defp, :render_signed_out, Path.join(@templates, "signed_out.html.eex"), [:assigns], engine: Phoenix.HTML.Engine)

  # ── public API ──────────────────────────────────────────────────────────────

  @doc "Every error code this renderer knows (the A20 list)."
  @spec error_codes() :: [String.t()]
  def error_codes, do: @errors |> Map.keys() |> Enum.sort()

  @doc "The fixed notice codes of the `notice` parameter (A5)."
  @spec notice_codes() :: [String.t()]
  def notice_codes, do: @notices |> Map.keys() |> Enum.sort()

  @doc "The `Content-Security-Policy` header value of every account page (the CSS hash included)."
  @spec csp() :: String.t()
  def csp, do: @csp

  @doc """
  Renders and SENDS the error page `code` with `status`, in the browser language. Options: `retry_after:` (seconds, on
  `rate_limited` and `unavailable`), `allow:` (`Allow` on `method_not_allowed`). An unknown code is
  normalized to `server_error` (never rendered into `data-error` unescaped).
  """
  @spec send_error(Plug.Conn.t(), pos_integer(), String.t(), keyword()) :: Plug.Conn.t()
  def send_error(conn, status, code, opts \\ []) do
    code = if Map.has_key?(@errors, code), do: code, else: "server_error"
    {more, restart} = Map.fetch!(@errors, code)
    lang = Locale.from_conn(conn)

    content =
      render_error(%{
        icon: Phoenix.HTML.raw(PageShell.status_icon()),
        heading: t(lang, "acct.err.#{code}.heading"),
        explanation: t(lang, "acct.err.#{code}.explanation"),
        primary: t(lang, "acct.err.#{code}.primary"),
        more: Enum.map(more, &t(lang, &1)),
        more_label: t(lang, "ui.more_options"),
        restart: restart,
        restart_label: t(lang, "acct.err.restart")
      })

    html =
      PageShell.render(lang,
        title: t(lang, "acct.err.#{code}.title"),
        main_attrs: ~s(data-page="account-error" data-error="#{code}"),
        content: to_html(content)
      )

    conn
    |> put_headers()
    |> maybe_header("retry-after", opts[:retry_after])
    |> maybe_header("allow", code == "method_not_allowed" && opts[:allow])
    |> send_resp(status, html)
  end

  @doc """
  Renders and SENDS an account page. `page` is `:default | :profile | :devices | :device | :rename | :delete |
  :reset | :apps | :signed_out`; `assigns` carries what the page needs (see the templates): `:user_id`,
  `:display_name`, `:csrf_token`, `:notice` (a code of `notice_codes/0` or nil), `:action` (the
  `data-action` value), `:devices` / `:hidden`, `:grants` (the allowed apps: the overview shows their count), `:device`, `:fresh`,
  `:no_auth_time` (a session without any `auth_time`: no reauth link, FR14), `:reauth_href`, `:requests`.
  """
  @spec send_page(Plug.Conn.t(), pos_integer(), atom(), map()) :: Plug.Conn.t()
  def send_page(conn, status, page, assigns) do
    lang = Locale.from_conn(conn)
    conn |> put_headers(reset_script?(page, assigns)) |> send_resp(status, page_html(page, assigns, lang))
  end

  # the click-proof script is embedded (and pinned in the CSP) only on the reset page while it renders the approve form
  defp reset_script?(:reset, %{requests: [_one], fresh: true}), do: true
  defp reset_script?(_page, _assigns), do: false

  @doc """
  The headers every account response (pages, redirects) carries: the flow headers of
  `Nebu.OAuth.Pages` (no-store, no CORS), `X-Frame-Options: DENY`, the CSP and `text/html`.
  """
  @spec put_headers(Plug.Conn.t(), boolean()) :: Plug.Conn.t()
  def put_headers(conn, script? \\ false) do
    conn
    |> Pages.put_flow_headers()
    # `same-origin`, not `no-referrer` (review cycle 1 M1): under `no-referrer` browsers send
    # `Origin: null` for the page's own form POSTs, which the CSRF check refuses; nothing leaves the origin.
    |> put_resp_header("referrer-policy", "same-origin")
    |> put_resp_header("content-security-policy", if(script?, do: @script_csp, else: @csp))
    |> put_resp_header("x-frame-options", "DENY")
    |> put_resp_content_type("text/html")
  end

  # ── page assembly ───────────────────────────────────────────────────────────

  # Order inside <main>: h1, the notice, the page content, the sign-out control of the account page.
  defp page_html(page, a, lang) do
    a = Map.put_new(a, :notice, nil)
    csrf = a[:csrf_token]
    devices = Map.get(a, :devices, [])

    {title, heading, nav, logout, inner} =
      case page do
        :default ->
          {t(lang, "acct.default.title"), t(lang, "acct.default.heading"), :overview, true,
           render_overview(%{
             lang: lang,
             user_id: a.user_id,
             display_name: a[:display_name],
             devices_count: length(devices) + Map.get(a, :hidden, 0),
             devices_count_exact: Map.get(a, :hidden_exact, true),
             apps_text: apps_text(Map.get(a, :grants), lang)
           })}

        :profile ->
          # no form at all on the read-only profile page (A5): the sign-out control lives on the others
          {t(lang, "acct.profile.title"), t(lang, "acct.profile.heading"), :overview, false,
           render_profile(%{lang: lang, user_id: a.user_id, display_name: a[:display_name]})}

        :devices ->
          {t(lang, "acct.devices.title"), t(lang, "acct.devices.heading"), :devices, true,
           render_devices(%{lang: lang, devices: devices, hidden: Map.get(a, :hidden, 0), hidden_exact: Map.get(a, :hidden_exact, true)})}

        :device ->
          {t(lang, "acct.device.title"), t(lang, "acct.device.heading"), :devices, true, render_device(%{lang: lang, device: a.device})}

        :rename ->
          {t(lang, "acct.rename.title"), t(lang, "acct.rename.heading"), :devices, true,
           render_rename(%{
             lang: lang,
             device: a.device,
             fresh: a.fresh,
             no_auth_time: Map.get(a, :no_auth_time, false),
             csrf_token: csrf,
             reauth_href: a[:reauth_href]
           })}

        :delete ->
          # the device name in the title and the heading (a screen-reader user hears WHAT is signed out)
          heading = tf(lang, "acct.delete.title", %{"name" => device_name(a.device, lang)})

          {heading, heading, :devices, true,
           render_delete_confirm(%{
             lang: lang,
             device: a.device,
             fresh: a.fresh,
             no_auth_time: Map.get(a, :no_auth_time, false),
             csrf_token: csrf,
             reauth_href: a[:reauth_href]
           })}

        :reset ->
          {t(lang, "acct.reset.title"), t(lang, "acct.reset.heading"), :reset, true,
           render_reset(%{
             lang: lang,
             requests: a.requests,
             several: length(a.requests) > 1,
             fresh: a.fresh,
             no_auth_time: Map.get(a, :no_auth_time, false),
             csrf_token: csrf,
             reauth_href: a[:reauth_href],
             problem_icon: Phoenix.HTML.raw(@problem_icon)
           })}

        :apps ->
          {t(lang, "acct.apps.title"), t(lang, "acct.apps.heading"), :apps, true, render_apps(%{lang: lang, grants: a.grants, csrf_token: csrf})}

        :signed_out ->
          {t(lang, "acct.signed_out.title"), t(lang, "acct.signed_out.heading"), nil, false, render_signed_out(%{lang: lang})}
      end

    content =
      [
        "<h1>#{PageShell.esc(heading)}</h1>",
        notice_html(a.notice, lang),
        to_html(inner),
        if(logout, do: logout_html(csrf, lang), else: "")
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    PageShell.render(lang,
      title: title,
      main_attrs: ~s(data-page="account" data-action="#{PageShell.esc(a.action)}"),
      content: content,
      wide: true,
      before_main: if(page == :signed_out, do: nil, else: header_html(a.user_id, nav, lang)),
      script: if(reset_script?(page, a), do: ClickProofScript.script())
    )
  end

  # "Signed in as <user>" and the navigation; `nav` is the entry that carries `aria-current="page"`.
  defp header_html(user_id, nav, lang) do
    link = fn key, href, entry ->
      current = if nav == entry, do: ~s( aria-current="page"), else: ""
      ~s(<li><a href="#{href}"#{current}>#{PageShell.esc(t(lang, key))}</a></li>)
    end

    [
      ~s(<p class="who" data-role="signed-in-as">#{PageShell.esc(t(lang, "acct.signed_in_as"))} <strong>#{PageShell.esc(user_id)}</strong></p>),
      ~s(<nav class="portal" aria-label="#{PageShell.esc(t(lang, "acct.nav.label"))}"><ul>),
      link.("acct.nav.overview", "/account", :overview),
      link.("acct.nav.devices", "/account?action=org.matrix.devices_list", :devices),
      link.("acct.nav.apps", "/account/apps", :apps),
      link.("acct.nav.security", "/account?action=org.matrix.cross_signing_reset", :reset),
      "</ul></nav>"
    ]
    |> Enum.join("\n")
  end

  defp logout_html(csrf_token, lang) do
    ~s(<form method="post" action="/account/logout" class="foot">\n) <>
      ~s(<input type="hidden" name="csrf_token" value="#{PageShell.esc(csrf_token)}">\n) <>
      ~s(<button type="submit" class="btn" data-role="sign-out">#{PageShell.esc(t(lang, "acct.logout"))}</button>\n</form>)
  end

  # icon + bold text label + text: the meaning is never colour alone; an unknown code renders nothing
  defp notice_html(code, lang) do
    case Map.get(@notices, code) do
      {label, role, kind} ->
        icon =
          case kind do
            "success" -> @ok_icon
            "info" -> @info_icon
            _problem -> @problem_icon
          end

        ~s(<div class="notice #{kind} icon" role="#{role}" data-role="notice" data-notice="#{code}">#{icon}) <>
          ~s(<p><strong>#{PageShell.esc(t(lang, label))}</strong> #{PageShell.esc(t(lang, "acct.notice.#{code}"))}</p></div>)

      nil ->
        ""
    end
  end

  defp to_html(safe), do: safe |> Phoenix.HTML.safe_to_string()

  defp maybe_header(conn, _name, value) when value in [nil, false], do: conn
  defp maybe_header(conn, name, value), do: put_resp_header(conn, name, to_string(value))

  # ── template helpers ────────────────────────────────────────────────────────

  defp t(lang, key), do: PageText.fetch!(key, lang)

  # A catalog text with `{name}` placeholders (plain text in, plain text out; the template escapes). ONE pass: a value is never rescanned.
  defp tf(lang, key, vars),
    do: Regex.replace(~r/\{([a-z_]+)\}/, t(lang, key), fn all, k -> if v = Map.get(vars, k), do: to_string(v), else: all end)

  defp apps_text(grants, lang) when is_list(grants), do: tf(lang, "acct.tile.apps_count", %{"n" => length(grants)})
  defp apps_text(_unknown, lang), do: t(lang, "acct.tile.apps_open")

  defp device_name(%{display_name: name}, _lang) when is_binary(name) and name != "", do: name
  defp device_name(_device, lang), do: t(lang, "consent.unnamed_device")

  # `Nebu.OAuth.Account` resolves the client name (the app's OWN claim) and puts it into `:app_name`.
  defp app_label(%{app_name: name}, _lang) when is_binary(name) and name != "", do: name
  defp app_label(%{auth_api: "oauth"}, lang), do: t(lang, "acct.app.unnamed")
  defp app_label(%{auth_api: "legacy"}, lang), do: t(lang, "acct.app.legacy")
  defp app_label(_device, lang), do: t(lang, "acct.app.none")

  # "active 5 minutes ago" up to 7 days, then "active on 2026-10-02"; "never active" without a timestamp.
  defp active(%{last_seen_ts: ms}, lang) when is_integer(ms) do
    case DateTime.from_unix(ms, :millisecond) do
      {:ok, dt} ->
        # a timestamp slightly in the future (clock skew between nodes) reads "just now", not "in 1 minute"
        delta_s = min(div(ms - System.system_time(:millisecond), 1000), 0)

        if delta_s < -@relative_max_s,
          do: tf(lang, "acct.active.date", %{"date" => Calendar.strftime(dt, "%Y-%m-%d")}),
          else: tf(lang, "acct.active.rel", %{"ago" => PageText.relative(delta_s, lang)})

      _ ->
        t(lang, "acct.active.never")
    end
  end

  defp active(_device, lang), do: t(lang, "acct.active.never")

  defp hidden_note(hidden, exact?, lang) do
    key = "acct.devices.more.#{if exact?, do: "exact", else: "least"}.#{if hidden == 1, do: "one", else: "other"}"
    tf(lang, key, %{"n" => hidden})
  end

  # `<time datetime="...">YYYY-MM-DD HH:MM UTC</time>` (machine readable, no client-side script needed).
  defp time_tag(ms, fallback) when is_integer(ms) do
    case DateTime.from_unix(ms, :millisecond) do
      {:ok, dt} ->
        Phoenix.HTML.raw(~s(<time datetime="#{DateTime.to_iso8601(dt)}">#{Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")}</time>))

      _ ->
        fallback
    end
  end

  defp time_tag(_ms, fallback), do: fallback

  # unix seconds: "3 minutes ago" / "in 8 minutes", next to the absolute UTC time
  defp relative_time(unix, lang) when is_integer(unix), do: PageText.relative(unix - System.system_time(:second), lang)
  defp relative_time(_unix, _lang), do: ""

  defp request_app(%{app_name: name}, _lang) when is_binary(name) and name != "", do: name
  defp request_app(_request, lang), do: t(lang, "acct.reset.unknown_app")

  defp request_device(%{device_display_name: name, device_id: id}, _lang) when is_binary(name) and is_binary(id), do: name <> " (" <> id <> ")"
  defp request_device(%{device_id: id}, _lang) when is_binary(id), do: id
  defp request_device(_request, lang), do: t(lang, "acct.reset.unknown_device")

  # the app's OWN claimed name (HTML-escaped by the engine), never a trusted label
  defp grant_name(%{client_name: name}, _lang) when is_binary(name) and name != "", do: name
  defp grant_name(_grant, lang), do: t(lang, "acct.app.unnamed")

  # the STORED, verified host of the registration (never the app-claimed website)
  defp grant_host(%{client_host: host}, _lang) when is_binary(host) and host != "", do: host
  defp grant_host(_grant, lang), do: t(lang, "acct.apps.host_unknown")

  defp grant_time(%DateTime{} = dt, lang), do: time_tag(DateTime.to_unix(dt, :millisecond), t(lang, "acct.unknown"))
  defp grant_time(_other, lang), do: t(lang, "acct.unknown")

  defp rename_href(device_id), do: "/account/devices/rename?" <> URI.encode_query([{"device_id", device_id}])

  defp device_href(action, device_id), do: "/account?" <> URI.encode_query([{"action", action}, {"device_id", device_id}])
end
