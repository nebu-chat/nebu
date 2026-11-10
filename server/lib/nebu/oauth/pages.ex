defmodule Nebu.OAuth.Pages do
  @moduledoc """
  The ONE renderer for every non-redirect outcome of `GET /oauth2/authorize` and of the OAuth
  branch of the shared IdP callback (epic oauth-broker, story oauth-authorize-idp-delegation-code,
  AC12/AC13). An error page is shown whenever the client or its redirect URI is not (or no longer)
  trusted — such outcomes are NEVER redirects (RFC 6749 4.1.2.1).

  Look and language (story oauth-pages-redesign/02): the page frame, tokens, logo and the ONE inline
  `<style>` come from `Nebu.Web.PageShell`, the texts from the catalog `Nebu.Web.PageText` (every
  text in English and German), the language from `Nebu.Web.Locale.from_conn/1` (`Accept-Language`,
  never echoed). Copy shape: heading, one sentence of reason, one bold primary suggestion, further
  suggestions under a native `<details>`.

  Accessibility: `<html lang>` follows the language, charset + viewport meta, a specific `<title>`,
  exactly one `<main>` and one `<h1>`, a plain-language explanation; no color-only meaning, no
  `<img>`, no scripts, no forms, no links to client-controlled URLs. E2E hook:
  `<main data-page="oauth-error" data-error="<code>">`.

  The ONLY request-derived value ever rendered is the `client_uri` host on the
  `client_pending` / `client_rejected` pages, HTML-escaped (`Plug.HTML.html_escape/1`) and
  labelled unverified.

  Headers (AC12/AC13): `text/html; charset=utf-8`, a strict CSP (`default-src 'none'`, the one
  inline style block allowed by its SHA-256, computed at compile time in the shell),
  `X-Frame-Options: DENY`, `Cache-Control: no-store`, `Pragma: no-cache`,
  `Referrer-Policy: no-referrer`, and NO CORS headers (`put_flow_headers/1`, also used for the
  redirects of both flows).
  """

  import Plug.Conn

  alias Nebu.Web.{Locale, PageShell, PageText}

  # code => catalog keys of the further suggestions (under "More options"). The title, heading,
  # explanation and the bold primary suggestion of a code are `err.<code>.title|heading|explanation|primary`.
  @pages %{
    "unknown_client" => ["act.contact"],
    "invalid_redirect_uri" => ["act.contact"],
    "invalid_request" => ["act.contact"],
    "client_pending" => ["err.client_pending.more"],
    "client_rejected" => ["err.client_rejected.more"],
    "invalid_state" => [],
    # story oauth-authorize-freshness (FR11): the app asked for a device id another app uses (Nebu policy,
    # stricter than the spec). A user page, NEVER a redirect: the client learns nothing about the holder.
    "device_in_use" => ["err.device_in_use.more", "act.contact"],
    # story oauth-authorize-freshness (FR8): a consent POST that did not come from the consent page
    "forbidden" => [],
    "not_found" => [],
    "unavailable" => ["act.contact"],
    "rate_limited" => [],
    "method_not_allowed" => [],
    "server_error" => ["act.contact"]
  }

  # A key missing in either language fails the build, never renders a blank.
  for {code, more} <- @pages,
      key <- ["err.#{code}.title", "err.#{code}.heading", "err.#{code}.explanation", "err.#{code}.primary"] ++ more,
      lang <- [:en, :de] do
    PageText.fetch!(key, lang)
  end

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
    more = Map.fetch!(@pages, error_code)
    host = if error_code in ["client_pending", "client_rejected"], do: opts[:client_host]
    lang = Locale.from_conn(conn)

    conn
    |> put_flow_headers()
    |> maybe_header("retry-after", error_code == "rate_limited" && opts[:retry_after])
    |> maybe_header("allow", error_code == "method_not_allowed" && opts[:allow])
    |> put_resp_header("content-security-policy", PageShell.csp())
    |> put_resp_header("x-frame-options", "DENY")
    |> put_resp_content_type("text/html")
    |> send_resp(status, render(lang, error_code, more, host))
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

  defp render(lang, code, more, host) do
    text = &PageShell.esc(PageText.fetch!(&1, lang))
    key = &"err.#{code}.#{&1}"

    host_html =
      case host do
        h when is_binary(h) and h != "" ->
          "\n<p>#{text.("err.host.prefix")} <span class=\"host\">#{PageShell.esc(h)}</span> #{text.("err.host.suffix")}</p>"

        _ ->
          ""
      end

    more_html =
      case more do
        [] ->
          ""

        keys ->
          items = Enum.map_join(keys, "\n", &"<li>#{text.(&1)}</li>")
          "\n<details>\n<summary>#{text.("ui.more_options")}</summary>\n<ul>\n#{items}\n</ul>\n</details>"
      end

    content =
      "#{PageShell.status_icon()}\n" <>
        "<h1>#{text.(key.("heading"))}</h1>\n" <>
        "<p>#{text.(key.("explanation"))}</p>#{host_html}\n" <>
        "<p class=\"primary\"><strong>#{text.(key.("primary"))}</strong></p>#{more_html}"

    PageShell.render(lang,
      title: PageText.fetch!(key.("title"), lang),
      main_attrs: ~s(data-page="oauth-error" data-error="#{code}"),
      content: content
    )
  end
end
