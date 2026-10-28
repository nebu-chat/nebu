defmodule Nebu.OAuth.Pages do
  @moduledoc """
  The ONE renderer for every non-redirect outcome of `GET /oauth2/authorize` and of the OAuth
  branch of the shared IdP callback (epic oauth-broker, story oauth-authorize-idp-delegation-code,
  AC12/AC13). An error page is shown whenever the client or its redirect URI is not (or no longer)
  trusted — such outcomes are NEVER redirects (RFC 6749 4.1.2.1).

  Accessibility: `lang="en"`, charset + viewport meta, a specific `<title>`, exactly one `<main>`
  and one `<h1>`, a plain-language explanation and a "What you can do" section; no color-only
  meaning, no images, no scripts, no forms, no links to client-controlled URLs. E2E hook:
  `<main data-page="oauth-error" data-error="<code>">`.

  The ONLY request-derived value ever rendered is the `client_uri` host on the
  `client_pending` / `client_rejected` pages, HTML-escaped (`Plug.HTML.html_escape/1`) and
  labelled unverified.

  Headers (AC12/AC13): `text/html; charset=utf-8`, a strict CSP (`default-src 'none'`, the one
  inline style block allowed by its SHA-256, computed at compile time), `X-Frame-Options: DENY`,
  `Cache-Control: no-store`, `Pragma: no-cache`, `Referrer-Policy: no-referrer`, and NO CORS
  headers (`put_flow_headers/1`, also used for the redirects of both flows).
  """

  import Plug.Conn

  @css "body{font-family:system-ui,sans-serif;line-height:1.5;margin:0;padding:2rem 1rem;color:#1a1a1a;background:#fff}" <>
         "main{max-width:36rem;margin:0 auto}h1{font-size:1.5rem;margin:0 0 1rem}h2{font-size:1.1rem;margin:1.5rem 0 .5rem}" <>
         "strong{overflow-wrap:anywhere}"

  @csp "default-src 'none'; style-src 'sha256-#{Base.encode64(:crypto.hash(:sha256, @css))}'; " <>
         "base-uri 'none'; form-action 'none'; frame-ancestors 'none'"

  @restart "Start signing in again from your app."
  @close_restart "Close this window. Start signing in again from your app."
  @contact "If this keeps happening, contact your administrator."

  # code => {title, heading, explanation, what you can do}
  @pages %{
    "unknown_client" =>
      {"Unknown app - sign-in not possible", "This app is not known to this server",
       "The app that sent you here is not registered on this server, so you cannot sign in with it.",
       ["Check that you opened the right app.", @contact]},
    "invalid_redirect_uri" =>
      {"Invalid sign-in request - wrong return address", "This sign-in request is not valid",
       "The app asked to send you back to an address that is not registered for it. For your safety you are not sent there.",
       ["Close this page and start signing in again from your app.", @contact]},
    "invalid_request" =>
      {"Invalid sign-in request", "This sign-in request is not valid",
       "The sign-in request from your app is incomplete or malformed.", [@close_restart, @contact]},
    "client_pending" =>
      {"App waiting for approval - sign-in not yet possible", "This app is waiting for approval",
       "Your administrator has not yet approved this app for this server. You can sign in once it has been approved.",
       ["Ask your administrator to review and approve the app.", "Try again later."]},
    "client_rejected" =>
      {"App not approved - sign-in not possible", "This app is not approved",
       "Your administrator has not approved this app for this server, so you cannot sign in with it.",
       ["Use another app that is approved for this server.", "Contact your administrator if you think this is a mistake."]},
    "invalid_state" =>
      {"Sign-in link expired or already used", "This sign-in link cannot be used",
       "This sign-in link has expired or was already used.", [@close_restart]},
    # story oauth-authorize-freshness (FR11): the app asked for a device id another app uses (Nebu policy,
    # stricter than the spec). A user page, NEVER a redirect: the client learns nothing about the holder.
    "device_in_use" =>
      {"Sign-in refused - session already in use", "This sign-in was refused",
       "This app asked to take over a session that another app is using. This is not allowed.",
       [@close_restart, "To use this app on this device, first sign out of the other app that uses it, then start again.", @contact]},
    # story oauth-authorize-freshness (FR8): a consent POST that did not come from the consent page
    "forbidden" =>
      {"Request refused", "This request was refused",
       "The request did not come from the sign-in page, or the page was open too long. Nothing was changed.",
       [@close_restart]},
    "not_found" =>
      {"Page not found", "This page does not exist", "There is nothing at this address.",
       ["Close this window. Start signing in again from your app."]},
    "unavailable" =>
      {"Sign-in temporarily unavailable", "Sign-in is not available right now",
       "This server cannot complete the sign-in at the moment.", ["Try again in a few minutes.", @contact]},
    "rate_limited" =>
      {"Too many sign-in attempts", "Too many sign-in attempts",
       "There were too many sign-in attempts from your network in a short time.",
       ["Wait a little while, then start signing in again from your app."]},
    "method_not_allowed" =>
      {"This page cannot be opened this way", "This page cannot be opened this way",
       "This page cannot be opened this way. Start signing in from your app.", [@restart]},
    "server_error" =>
      {"Sign-in failed - server error", "Something went wrong",
       "The server ran into an unexpected problem while signing you in.", [@close_restart, @contact]}
  }

  @doc "Every page code this renderer knows."
  @spec codes() :: [String.t()]
  def codes, do: Map.keys(@pages)

  @doc """
  Renders and SENDS the page `error_code` with `status`. Options: `client_host:` (only shown on
  `client_pending` / `client_rejected`, escaped), `retry_after:` (seconds, `Retry-After` on
  `rate_limited`), `allow:` (`Allow` on `method_not_allowed`).
  """
  @spec send_page(Plug.Conn.t(), pos_integer(), String.t(), keyword()) :: Plug.Conn.t()
  def send_page(conn, status, error_code, opts \\ []) do
    # An unknown code is normalized (never rendered into data-error unescaped).
    error_code = if Map.has_key?(@pages, error_code), do: error_code, else: "server_error"
    {title, heading, explanation, actions} = Map.fetch!(@pages, error_code)
    host = if error_code in ["client_pending", "client_rejected"], do: opts[:client_host]

    conn
    |> put_flow_headers()
    |> maybe_header("retry-after", error_code == "rate_limited" && opts[:retry_after])
    |> maybe_header("allow", error_code == "method_not_allowed" && opts[:allow])
    |> put_resp_header("content-security-policy", @csp)
    |> put_resp_header("x-frame-options", "DENY")
    |> put_resp_content_type("text/html")
    |> send_resp(status, render(error_code, title, heading, explanation, actions, host))
  end

  @doc """
  AC13 headers of every response of the authorize / OAuth-callback flows (pages and redirects):
  `Cache-Control: no-store`, `Pragma: no-cache`, `Referrer-Policy: no-referrer`, and every
  `access-control-*` header the global `CORSPlug` already put on the conn deleted (browser
  navigation, no CORS).
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
  end

  defp maybe_header(conn, _name, value) when value in [nil, false], do: conn
  defp maybe_header(conn, name, value), do: put_resp_header(conn, name, to_string(value))

  defp render(code, title, heading, explanation, actions, host) do
    host_html =
      case host do
        h when is_binary(h) and h != "" ->
          "\n    <p>The app says it belongs to <strong>#{Plug.HTML.html_escape(h)}</strong> (unverified: this " <>
            "server has not checked this claim).</p>"

        _ ->
          ""
      end

    items = Enum.map_join(actions, "\n", &"      <li>#{&1}</li>")

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
    <main data-page="oauth-error" data-error="#{code}">
      <h1>#{heading}</h1>
      <p>#{explanation}</p>#{host_html}
      <h2>What you can do</h2>
      <ul>
    #{items}
      </ul>
    </main>
    </body>
    </html>
    """
  end
end
