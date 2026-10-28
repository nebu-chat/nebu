defmodule Nebu.OAuth.AccountPages do
  @moduledoc """
  The standalone HTML renderer of the account-management page `/account` (epic oauth-broker, story
  oauth-account-management, A20) — like `Nebu.OAuth.Pages` NOT the admin layout / DaisyUI: the page
  lives outside the Admin endpoint (no admin session, no `/admin/static` assets, a stricter CSP, no
  LiveView, no JavaScript except the one pinned click-proof script of the reset page, see Headers).

  Templates are EEx files under `account_templates/`, compiled at COMPILE time with
  `Phoenix.HTML.Engine` (every `<%= %>` value is HTML-escaped; the only raw values are the compile-time
  CSS, the compile-time click-proof script and the already rendered partials). Every attacker-controlled string (device display names,
  device ids, client names, the profile display name) therefore renders as inert text.

  ## Headers (every page, `put_headers/1,2`)

  `text/html; charset=utf-8`; `Content-Security-Policy: default-src 'none'; style-src 'sha256-<css>';
  img-src 'none'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'` (the hash is the SHA-256
  of the ONE inline `<style>` block, computed at compile time); `X-Frame-Options: DENY` (clickjacking
  of the destructive buttons); `Cache-Control: no-store`, `Pragma: no-cache`, `Referrer-Policy:
  same-origin` and no CORS header (`Nebu.OAuth.Pages.put_flow_headers/1`). No script, no inline event
  handler, no external resource, no image: the ONE exception is the reset page while it renders the approve form (story
  safari-fetch-metadata-compat): it embeds `Nebu.Web.ClickProofScript.script/0` and its CSP adds `script-src 'sha256-<script>'`
  (no `'unsafe-inline'`), because Safari sends no `Sec-Fetch-User` and the approval needs the click proof.

  ## Accessibility (WCAG 2.1 AA)

  `lang="en"`, charset + viewport meta, a page-specific `<title>`, ONE `<main>`, ONE `<h1>`, a
  `<nav aria-label="Account">` with `aria-current="page"`, the device list as a `<table>` with
  `<caption>` and `<th scope="col">` / `<th scope="row">`, controls whose accessible names include the
  device, notices in a `role="status"` (success) / `role="alert"` (problem) region with a text label
  (no colour-only meaning), a visible focus outline, text contrast >= 4.5:1, touch targets >= 24 px,
  a layout that works at 320 px width, real `<button type="submit">` buttons.

  ## End-to-end hooks

  `<main data-page="account" data-action="<action>">`, device rows `data-role="account-device"
  data-device-id=...`, `delete-device-confirm`, `reset-request`, `approve-reset`, `decline-reset`,
  `reauth`, `notice` (`data-notice=...`), `sign-out`, `device-sign-out`. Error pages:
  `<main data-page="account-error" data-error="<code>">`.
  """

  import Plug.Conn

  require EEx

  alias Nebu.OAuth.Pages

  @templates Path.expand("account_templates", __DIR__)

  @css "*{box-sizing:border-box}body{font-family:system-ui,sans-serif;line-height:1.5;margin:0;padding:1rem;color:#1a1a1a;background:#fff;overflow-wrap:anywhere}" <>
         "main,header{max-width:48rem;margin:0 auto}header{padding-bottom:.5rem;border-bottom:1px solid #767676;margin-bottom:1rem}" <>
         "h1{font-size:1.5rem;margin:0 0 1rem}h2{font-size:1.15rem;margin:1.5rem 0 .5rem}.who{margin:0 0 .5rem;overflow-wrap:anywhere}" <>
         "nav ul{list-style:none;margin:0;padding:0;display:flex;flex-wrap:wrap;gap:.5rem}" <>
         "a{color:#0b57d0;text-decoration:underline;display:inline-block;min-height:24px;padding:.15rem .25rem}" <>
         "nav a{padding:.4rem .75rem;border:1px solid #767676;border-radius:.25rem;text-decoration:none}" <>
         "nav a[aria-current=page]{background:#1a1a1a;color:#fff;border-color:#1a1a1a;font-weight:bold}" <>
         "a:focus,button:focus,[tabindex]:focus{outline:3px solid #1a1a1a;outline-offset:2px}" <>
         "a.button,button{display:inline-block;min-height:44px;padding:.6rem 1rem;border:2px solid #0b57d0;border-radius:.25rem;background:#0b57d0;color:#fff;font:inherit;font-weight:bold;text-decoration:none;cursor:pointer;white-space:normal}" <>
         "a.button.danger,button.danger{background:#b3261e;border-color:#b3261e}" <>
         "button:not(.danger){background:#fff;color:#0b57d0}.logout{margin-top:2rem}" <>
         ".notice{padding:.75rem 1rem;border:2px solid #1a1a1a;border-radius:.25rem;margin:0 0 1rem}" <>
         ".notice.success{background:#e6f4ea;border-color:#137333}.notice.problem{background:#fce8e6;border-color:#b3261e}.notice.info{background:#e8f0fe;border-color:#0b57d0}" <>
         ".table-wrap{overflow-x:auto}table{border-collapse:collapse;width:100%}caption{text-align:left;font-weight:bold;padding:.25rem 0}" <>
         "th,td{text-align:left;padding:.5rem;border-bottom:1px solid #767676;vertical-align:top;overflow-wrap:anywhere}" <>
         "dt{font-weight:bold;margin-top:.75rem}dd{margin:0}.request{border:1px solid #767676;border-radius:.25rem;padding:0 1rem 1rem;margin:1rem 0}" <>
         ".actions{display:flex;flex-wrap:wrap;gap:1rem}.actions form{margin:0}" <>
         "@media (max-width:40rem){table,thead,tbody,tr,th,td{display:block}" <>
         "thead{position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0 0 0 0)}" <>
         "tr{border-bottom:2px solid #1a1a1a;padding:.5rem 0}th,td{border-bottom:0;padding:.25rem .5rem}" <>
         "th[data-label]::before,td[data-label]::before{content:attr(data-label) \": \";font-weight:bold}}" <>
         "@media (forced-colors:active){a.button,button{border:2px solid ButtonText}nav a[aria-current=page]{border:3px solid Highlight}}"

  @csp "default-src 'none'; style-src 'sha256-#{Base.encode64(:crypto.hash(:sha256, @css))}'; img-src 'none'; " <>
         "form-action 'self'; base-uri 'none'; frame-ancestors 'none'"

  @script_csp @csp <> "; script-src " <> Nebu.Web.ClickProofScript.csp_hash()

  @contact "If this keeps happening, contact your administrator."
  @again "Go back to your app and start again."

  # code => {title, heading, explanation, what you can do, offer a link back to /account}
  @errors %{
    "unavailable" =>
      {"Account page temporarily unavailable", "The account page is not available right now",
       "This server cannot show the account page at the moment.", ["Try again in a few minutes.", @contact], false},
    "rate_limited" =>
      {"Too many requests", "Too many requests", "There were too many requests from your network in a short time.",
       ["Wait a few minutes, then try again.", "If you are on a shared company network, other people's requests count too."], false},
    "method_not_allowed" =>
      {"This page cannot be opened this way", "This page cannot be opened this way",
       "This page cannot be opened this way. Open the account page from your app, or use the link below.", ["Open the account page from your app or from the link below."], true},
    "not_found" =>
      {"Page not found", "This page does not exist", "There is nothing at this address.",
       ["Open the account page from your app or from the link below."], true},
    "invalid_request" =>
      {"Invalid request", "This request is not valid", "The request is incomplete or malformed. Nothing was changed.",
       ["Go back to the account page and try again.", @contact], true},
    "invalid_state" =>
      {"Sign-in link expired or already used", "This sign-in link cannot be used", "This sign-in link has expired or was already used.",
       ["Open the account page again from your app to start a new sign-in."], true},
    "forbidden" =>
      {"Request refused", "This request was refused",
       "The request did not come from the account page, or the page was open too long. Nothing was changed.",
       ["Open the account page again from your app and repeat the action there.",
        "Approving an encryption reset needs a current Chrome, Firefox or Safari: an old browser, or a proxy that removes the Sec-Fetch headers, is refused."], true},
    "no_account" =>
      {"No account found", "You have no account on this server yet",
       "Your company account is not known on this server. Sign in with a Matrix app first.",
       ["Sign in once with a Matrix app on this server.", "Then open the account page again."], false},
    "deactivated" =>
      {"Account deactivated", "This account has been deactivated", "You cannot use the account page with a deactivated account.",
       ["Contact your administrator if you think this is a mistake."], false},
    "reauth_failed" =>
      {"Sign-in could not be confirmed", "Your sign-in could not be confirmed",
       "Your company sign-in did not ask you to sign in again, so this sign-in cannot be trusted for account changes.",
       ["Open the account page again and enter your password when asked.", @contact], true},
    "access_denied" =>
      {"Sign-in not completed", "Sign-in was not completed", "The sign-in with your company account did not succeed.",
       ["Open the account page again to try again.", @contact], true},
    "server_error" =>
      {"Something went wrong", "Something went wrong", "The server ran into an unexpected problem. Nothing was changed.",
       [@again, @contact], true}
  }

  # code => {label shown in bold, role, kind css class, text}
  @notices %{
    "device_deleted" => {"Done:", "status", "success", "The device was signed out."},
    "reset_approved" => {"Done:", "status", "success", "Reset approved. Return to your app and continue."},
    "reset_declined" => {"Done:", "status", "success", "Reset declined."},
    "signed_out" => {"Done:", "status", "success", "You have been signed out of the account page."},
    "device_not_found" => {"Problem:", "alert", "problem", "This device was not found. Here are all your devices."},
    "invalid_request" => {"Problem:", "alert", "problem", "Part of the link was not understood, so here is the overview."},
    "reset_not_found" => {"Problem:", "alert", "problem", "This reset request was not found or has expired. Nothing was changed."},
    "stale" => {"Problem:", "alert", "problem", "Please confirm that it is you first. Nothing was changed."},
    # story safari-fetch-metadata-compat: a WebKit browser sent no proof that the button was pressed by the user (script blocked,
    # stale page): a note, not an error, nothing was changed
    "activation_unproven" =>
      {"Note:", "status", "info",
       "Nothing was changed. We could not confirm that you pressed the button yourself. " <>
         "Reload this page and press Approve reset again. " <>
         "If it keeps happening, turn off content blockers for this site or try another browser."},
    # story oauth-authorize-freshness (FR14, gate y): the IdP reports no sign-in time, so freshness can never be
    # proven. No reauth link on purpose (it would loop).
    "freshness_unavailable" =>
      {"Problem:", "alert", "problem",
       "Your sign-in provider does not report when you last signed in, so Nebu cannot confirm it is you. " <>
         "Signing out devices and approving key resets are not available here. Ask your administrator."}
  }

  # The page-specific `<title>` of every account page (distinct per page, WCAG 2.4.2).
  @titles %{
    default: "Your account",
    profile: "Your profile",
    devices: "Your devices",
    device: "Device details",
    delete: "Sign out a device",
    reset: "Reset your identity",
    signed_out: "Signed out"
  }

  EEx.function_from_file(:defp, :render_layout, Path.join(@templates, "layout.html.eex"), [:assigns], engine: Phoenix.HTML.Engine)
  EEx.function_from_file(:defp, :render_error, Path.join(@templates, "error.html.eex"), [:assigns], engine: Phoenix.HTML.Engine)

  EEx.function_from_file(:defp, :render_device_table, Path.join(@templates, "device_table.html.eex"), [:assigns],
    engine: Phoenix.HTML.Engine
  )

  EEx.function_from_file(:defp, :render_overview, Path.join(@templates, "overview.html.eex"), [:assigns], engine: Phoenix.HTML.Engine)
  EEx.function_from_file(:defp, :render_profile, Path.join(@templates, "profile.html.eex"), [:assigns], engine: Phoenix.HTML.Engine)
  EEx.function_from_file(:defp, :render_devices, Path.join(@templates, "devices.html.eex"), [:assigns], engine: Phoenix.HTML.Engine)
  EEx.function_from_file(:defp, :render_device, Path.join(@templates, "device.html.eex"), [:assigns], engine: Phoenix.HTML.Engine)

  EEx.function_from_file(:defp, :render_delete_confirm, Path.join(@templates, "delete_confirm.html.eex"), [:assigns],
    engine: Phoenix.HTML.Engine
  )

  EEx.function_from_file(:defp, :render_reset, Path.join(@templates, "reset.html.eex"), [:assigns], engine: Phoenix.HTML.Engine)

  # Static content (no assigns): a template would only compile with an unused-variable warning.
  defp render_signed_out(_assigns),
    do: Phoenix.HTML.raw(~s(<p>You can close this page, or sign in again. Your company sign-in session may still be active: close the browser or sign out at your company sign-in if you share this computer.</p>\n<p><a href="/account">Sign in again</a></p>\n))

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
  Renders and SENDS the error page `code` with `status`. Options: `retry_after:` (seconds, on
  `rate_limited` and `unavailable`), `allow:` (`Allow` on `method_not_allowed`). An unknown code is
  normalized to `server_error` (never rendered into `data-error` unescaped).
  """
  @spec send_error(Plug.Conn.t(), pos_integer(), String.t(), keyword()) :: Plug.Conn.t()
  def send_error(conn, status, code, opts \\ []) do
    code = if Map.has_key?(@errors, code), do: code, else: "server_error"
    {title, heading, explanation, actions, restart} = Map.fetch!(@errors, code)

    html =
      render_error(%{
        title: title,
        css: css(),
        code: code,
        heading: heading,
        explanation: explanation,
        actions: actions,
        restart: restart
      })

    conn
    |> put_headers()
    |> maybe_header("retry-after", opts[:retry_after])
    |> maybe_header("allow", code == "method_not_allowed" && opts[:allow])
    |> send_resp(status, to_html(html))
  end

  @doc """
  Renders and SENDS an account page. `page` is `:default | :profile | :devices | :device | :delete |
  :reset | :signed_out`; `assigns` carries what the page needs (see the templates): `:user_id`,
  `:display_name`, `:csrf_token`, `:notice` (a code of `notice_codes/0` or nil), `:action` (the
  `data-action` value), `:devices` / `:hidden`, `:device`, `:fresh`, `:no_auth_time` (a session without any `auth_time`: no reauth link, FR14), `:reauth_href`, `:requests`.
  """
  @spec send_page(Plug.Conn.t(), pos_integer(), atom(), map()) :: Plug.Conn.t()
  def send_page(conn, status, page, assigns) do
    conn |> put_headers(reset_script?(page, assigns)) |> send_resp(status, page_html(page, assigns))
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

  defp page_html(page, a) do
    a = Map.put_new(a, :notice, nil)
    table = fn ->
      render_device_table(%{devices: Map.get(a, :devices, []), hidden: Map.get(a, :hidden, 0), hidden_exact: Map.get(a, :hidden_exact, true)})
    end

    {title, heading, nav, logout, inner} =
      case page do
        :default ->
          {@titles.default, "Your account", nil, true, render_overview(%{user_id: a.user_id, display_name: a[:display_name], table: table.()})}

        :profile ->
          # no form at all on the read-only profile page (A5): the sign-out control lives on the others
          {@titles.profile, "Your profile", :profile, false, render_profile(%{user_id: a.user_id, display_name: a[:display_name]})}

        :devices ->
          {@titles.devices, "Your devices", :devices, true, render_devices(%{table: table.()})}

        :device ->
          {@titles.device, "Device details", :devices, true, render_device(%{device: a.device})}

        :delete ->
          # the device name in the title and the heading (a screen-reader user hears WHAT is signed out)
          {"Sign out #{device_name(a.device)}?", "Sign out #{device_name(a.device)}?", :devices, true,
           render_delete_confirm(%{
             device: a.device,
             fresh: a.fresh,
             no_auth_time: Map.get(a, :no_auth_time, false),
             csrf_token: a.csrf_token,
             reauth_href: a[:reauth_href]
           })}

        :reset ->
          {@titles.reset, "Reset your identity", :reset, true,
           render_reset(%{
             requests: a.requests,
             several: length(a.requests) > 1,
             fresh: a.fresh,
             no_auth_time: Map.get(a, :no_auth_time, false),
             csrf_token: a.csrf_token,
             reauth_href: a[:reauth_href],
             script: Phoenix.HTML.raw(Nebu.Web.ClickProofScript.script()),
             script?: reset_script?(:reset, a)
           })}

        :signed_out ->
          {@titles.signed_out, "You are signed out", nil, false, render_signed_out(%{})}
      end

    signed_in = page != :signed_out

    render_layout(%{
      title: title,
      css: css(),
      signed_in: signed_in,
      user_id: a[:user_id],
      nav: nav,
      action: a.action,
      heading: heading,
      notice: notice(a.notice),
      inner: inner,
      logout: logout,
      csrf_token: a[:csrf_token]
    })
    |> to_html()
  end

  defp notice(code) do
    case Map.get(@notices, code) do
      {label, role, kind, text} -> %{code: code, label: label, role: role, kind: kind, text: text}
      nil -> nil
    end
  end

  defp css, do: Phoenix.HTML.raw(@css)
  defp to_html(safe), do: safe |> Phoenix.HTML.safe_to_string()

  defp maybe_header(conn, _name, value) when value in [nil, false], do: conn
  defp maybe_header(conn, name, value), do: put_resp_header(conn, name, to_string(value))

  # ── template helpers ────────────────────────────────────────────────────────

  defp device_name(%{display_name: name}) when is_binary(name) and name != "", do: name
  defp device_name(_device), do: "Unnamed device"

  # `Nebu.OAuth.Account` resolves the client name (the app's OWN claim) and puts it into `:app_name`.
  defp app_label(%{app_name: name}) when is_binary(name) and name != "", do: name
  defp app_label(%{auth_api: "oauth"}), do: "Unnamed app"
  defp app_label(%{auth_api: "legacy"}), do: "Matrix app (company sign-in)"
  defp app_label(_device), do: "Not signed in"

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

  # "just now" / "3 minutes ago" / "in 8 minutes" (unix seconds): a hint next to the absolute UTC time.
  defp relative_time(unix) when is_integer(unix) do
    delta = unix - System.system_time(:second)
    minutes = div(abs(delta), 60)

    cond do
      minutes == 0 -> "just now"
      delta < 0 -> plural(minutes, "minute", "minutes") <> " ago"
      true -> "in " <> plural(minutes, "minute", "minutes")
    end
  end

  defp relative_time(_unix), do: ""

  defp plural(1, one, _many), do: "1 " <> one
  defp plural(n, _one, many), do: "#{n} " <> many

  defp request_app(%{app_name: name}) when is_binary(name) and name != "", do: name
  defp request_app(_request), do: "Unknown app"

  defp request_device(%{device_display_name: name, device_id: id}) when is_binary(name) and is_binary(id), do: name <> " (" <> id <> ")"
  defp request_device(%{device_id: id}) when is_binary(id), do: id
  defp request_device(_request), do: "an unknown device"

  defp device_href(action, device_id), do: "/account?" <> URI.encode_query([{"action", action}, {"device_id", device_id}])
end
