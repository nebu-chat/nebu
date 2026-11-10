defmodule Nebu.OAuth.PortalRedesignTest do
  @moduledoc """
  ATDD for story `05-portal-redesign` (REQ-2026-020) — Account portal: overview, device cards and apps in the Nebu look.

  One test per Gherkin scenario, tagged `@tag ac: "<scenario-slug>"`. Red until the story is implemented.

  Pure rendering: `Nebu.OAuth.AccountPages.send_page(conn, status, page, assigns)` and `send_error(conn, status, code, opts)` on `Plug.Test` conns (public
  API unchanged), the language through the `Accept-Language` header (`Nebu.Web.Locale`, story 02). No database, no IdP. The pixel claims (390 px, no
  horizontal scroll) are proven by the e2e feature; here the DOM and the stylesheet pin the same thing.

  Contract pinned here (names from the story Decisions and UX design 5.4; the rest stays free):

    * assigns: unchanged for every page, plus ONE new one: the overview (`:default`) also receives `grants:` (the list of `:apps`), so it can show the
      live count "2 allowed". The count "3 signed in" is `length(devices)`.
    * header: a `data-role="signed-in-as"` element ("Signed in as <user id>" / "Angemeldet als <user id>"), one `<nav>` with four links in this order:
      Overview, Devices, Apps, Security / Übersicht, Geräte, Apps, Sicherheit (hrefs of the last three unchanged), `aria-current="page"` on the active one.
    * overview: one `<h1>` "Your account" / "Ihr Konto", one sentence (`<p>` right after the `<h1>`), three `<a data-role="portal-tile" data-tile="devices|apps|security">`
      tiles (the first two carry the count text), ONE closed `<details data-role="profile-details">` with `<summary>` "Show profile details" /
      "Profildetails anzeigen" that holds Matrix ID and display name (nowhere else on the page, except the signed-in-as line), no table, no device list.
    * devices: `<ul data-role="device-list">` of `<li data-role="account-device" data-device-id=...>` cards; per card `data-role="device-name"` (the name, or
      "Unnamed device" / "Unbenanntes Gerät"), `data-role="device-meta"` ("<app> · active 5 minutes ago" / "zuletzt aktiv vor 5 Minuten": relative up to 7
      days in minutes / hours / days with singular and plural, then the ISO date; "never active" / "noch nie aktiv"), the sign-out link
      `data-role="device-row-sign-out"` (visible text "Sign out" / "Abmelden", `aria-label` names device and id, href unchanged) and ONE closed
      `<details>` with device id, IP and the absolute UTC timestamps. No `<table>`, no `table-wrap`. `data-role="devices-truncated"` stays below the list.
    * apps: `<ul data-role="grant-list">` of `<li data-role="consent-grant" data-client-id=...>` cards (name, website, allowed on, Withdraw form with
      `data-role="withdraw-grant"`), the one-sentence note `data-role="grants-note"` plus ONE closed `<details data-role="grants-details">` with the long
      explanation, `data-role="no-grants"` for the empty state.
    * notices: `data-role="notice"` `data-notice=<code>` with the old role (status / alert), classes `notice` + `icon`, an inline `<svg aria-hidden="true">`
      and a `<strong>` text label, above the page content.
    * every page: `<html lang>`, the shell logo, ONE `<main data-page data-action>`, ONE `<h1>`, ONE inline `<style>` pinned by the CSP hash, the old headers
      (`referrer-policy: same-origin`, `form-action 'self'`, `img-src 'none'`, `no-store`, `X-Frame-Options: DENY`).
    * reset page: the click-proof script `Nebu.Web.ClickProofScript.script/0` inline, ONLY while ONE request is pending and the session is fresh, pinned
      in the CSP by `script-src <csp_hash>`; Decline (own form, first) before Approve (own form, class `danger`).

  Crash/restart — NOT APPLICABLE (no process state; the CSS and script hashes are computed at compile time).
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Nebu.OAuth.AccountPages
  alias Nebu.Web.{ClickProofScript, PageText}

  @user "@tom:nebu.example"
  @display "Anna Beispiel"
  @csrf "csrf-token-portal-1"
  @langs [:en, :de]

  @created_ms DateTime.to_unix(~U[2026-10-02 09:14:00Z], :millisecond)
  @devices_href "/account?action=org.matrix.devices_list"
  @apps_href "/account/apps"
  @reset_href "/account?action=org.matrix.cross_signing_reset"

  @pages [:default, :profile, :devices, :device, :delete, :reset, :apps, :signed_out]

  @copy %{
    en: %{
      h1: "Your account",
      signed_in: "Signed in as",
      nav: ["Overview", "Devices", "Apps", "Security"],
      summary: "Show profile details",
      devices_count: "3 signed in",
      apps_count: "2 allowed",
      sign_out: "Sign out",
      unnamed: "Unnamed device",
      never: "never active"
    },
    de: %{
      h1: "Ihr Konto",
      signed_in: "Angemeldet als",
      nav: ["Übersicht", "Geräte", "Apps", "Sicherheit"],
      summary: "Profildetails anzeigen",
      devices_count: "3 angemeldet",
      apps_count: "2 erlaubt",
      sign_out: "Abmelden",
      unnamed: "Unbenanntes Gerät",
      never: "noch nie aktiv"
    }
  }

  # code => {status, role}: the notice codes of today, with the role they keep
  @notices %{
    "device_deleted" => "status",
    "reset_approved" => "status",
    "reset_declined" => "status",
    "signed_out" => "status",
    "grant_withdrawn" => "status",
    "activation_unproven" => "status",
    # story oauth-pages-redesign/06 (renaming a device) extends the contract by two codes
    "device_renamed" => "status",
    "device_name_invalid" => "alert",
    "device_not_found" => "alert",
    "invalid_request" => "alert",
    "reset_not_found" => "alert",
    "stale" => "alert",
    "grant_not_found" => "alert",
    "freshness_unavailable" => "alert"
  }

  # error code => {status, restart link back to /account}
  @errors %{
    "unavailable" => {503, false},
    "rate_limited" => {429, false},
    "method_not_allowed" => {405, true},
    "not_found" => {404, true},
    "invalid_request" => {400, true},
    "invalid_state" => {400, true},
    "forbidden" => {403, true},
    "no_account" => {403, false},
    "deactivated" => {403, false},
    "reauth_failed" => {403, true},
    "access_denied" => {403, true},
    "server_error" => {500, true}
  }

  # the old English UI texts that must not survive on a German page
  @english_ui [
    "Signed in as",
    "Your devices",
    "Your account",
    "Your profile",
    "Sign out",
    "Device ID",
    "Last active",
    "Withdraw",
    "Cancel",
    "Confirm it",
    "Approve",
    "Decline",
    "Back to",
    "Apps you have allowed",
    "Reset your identity",
    "Display name",
    "Unnamed",
    "What you can do",
    "Go back",
    "contact your administrator",
    "Try again"
  ]

  # ── fixtures ───────────────────────────────────────────────────────────────

  defp now_ms, do: System.system_time(:millisecond)

  # the 2 s margin keeps "5 minutes" from rounding down to 4 while the page renders
  defp ago_ms(ms), do: now_ms() - ms - 2_000

  defp minutes(n), do: n * 60_000
  defp hours(n), do: n * 3_600_000
  defp days(n), do: n * 86_400_000

  defp device(id, name, extra) do
    Map.merge(
      %{
        device_id: id,
        display_name: name,
        app_name: "Element Web",
        auth_api: "oauth",
        last_seen_ts: ago_ms(minutes(5)),
        last_seen_ip: "192.0.2.10",
        created_at: @created_ms
      },
      extra
    )
  end

  defp devices do
    [
      device("ABCDEFGHIJ", "Firefox on Linux", %{}),
      device("KLMNOPQRST", "Pixel 8", %{app_name: "FluffyChat", last_seen_ts: ago_ms(days(2)), last_seen_ip: "198.51.100.7", created_at: @created_ms + days(1)}),
      device("UVWXYZ0123", nil, %{app_name: "Element Desktop", last_seen_ts: nil, last_seen_ip: nil, created_at: @created_ms + days(2)})
    ]
  end

  defp grants do
    [
      %{client_id: "client-a", client_name: "Element Web", client_host: "chat.acme.example", granted_at: ~U[2026-10-01 08:00:00Z]},
      %{client_id: "client-b", client_name: "FluffyChat", client_host: nil, granted_at: ~U[2026-10-05 12:30:00Z]}
    ]
  end

  defp reset_request(session_id) do
    unix = System.system_time(:second)

    %{
      session_id: session_id,
      device_id: "ABCDEFGHIJ",
      device_display_name: "Firefox on Linux",
      app_name: "Element Web",
      device_last_seen_ts: ago_ms(minutes(3)),
      requested_at: unix - 60,
      expires_at: unix + 540,
      keys_fingerprint: "ab12cd34"
    }
  end

  defp action(:default), do: "default"
  defp action(:profile), do: "org.matrix.profile"
  defp action(:devices), do: "org.matrix.devices_list"
  defp action(:device), do: "org.matrix.device_view"
  defp action(:delete), do: "org.matrix.device_delete"
  defp action(:reset), do: "org.matrix.cross_signing_reset"
  defp action(:apps), do: "apps"
  defp action(:signed_out), do: "signed_out"

  defp page_assigns(:default), do: %{devices: devices(), hidden: 0, hidden_exact: true, grants: grants()}
  defp page_assigns(:profile), do: %{}
  defp page_assigns(:devices), do: %{devices: devices(), hidden: 0, hidden_exact: true}
  defp page_assigns(:device), do: %{device: hd(devices())}

  defp page_assigns(:delete),
    do: %{device: hd(devices()), fresh: true, no_auth_time: false, reauth_href: "/account/reauth?action=org.matrix.device_delete&device_id=ABCDEFGHIJ"}

  defp page_assigns(:reset),
    do: %{requests: [reset_request("sess-1")], fresh: true, no_auth_time: false, reauth_href: "/account/reauth?action=org.matrix.cross_signing_reset"}

  defp page_assigns(:apps), do: %{grants: grants()}

  defp assigns(:signed_out, extra), do: Map.merge(%{action: "signed_out", notice: "signed_out"}, extra)

  defp assigns(page, extra) do
    %{user_id: @user, display_name: @display, csrf_token: @csrf, notice: nil, action: action(page)}
    |> Map.merge(page_assigns(page))
    |> Map.merge(extra)
  end

  defp request(:en), do: conn(:get, "/account")
  defp request(:de), do: put_req_header(conn(:get, "/account"), "accept-language", "de")

  # the sent conn
  defp sent(lang, page, extra), do: AccountPages.send_page(request(lang), 200, page, assigns(page, extra))
  defp body(lang, page, extra), do: sent(lang, page, extra).resp_body

  defp error_opts("rate_limited"), do: [retry_after: 30]
  defp error_opts("unavailable"), do: [retry_after: 30]
  defp error_opts("method_not_allowed"), do: [allow: "GET"]
  defp error_opts(_code), do: []

  defp sent_error(lang, code) do
    {status, _restart} = Map.fetch!(@errors, code)
    AccountPages.send_error(request(lang), status, code, error_opts(code))
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp lang_attr(body) do
    case Regex.run(~r/<html lang="([^"]*)"/, body) do
      [_, l] -> l
      _ -> nil
    end
  end

  defp text(html), do: html |> String.replace(~r/<[^>]+>/, " ") |> String.replace(~r/\s+/, " ") |> String.trim()

  defp visible_text(body), do: body |> String.replace(~r/<style>.*?<\/style>/s, "") |> text()

  defp tag_text(body, tag) do
    case Regex.run(~r/<#{tag}\b[^>]*>(.*?)<\/#{tag}>/s, body) do
      [_, inner] -> text(inner)
      _ -> ""
    end
  end

  defp attr(tag, name) do
    case Regex.run(~r/\s#{name}="([^"]*)"/, tag) do
      [_, v] -> v
      _ -> nil
    end
  end

  defp class_tokens(tag), do: (attr(tag, "class") || "") |> String.split(" ", trim: true)

  defp css(body) do
    assert [[_, css]] = Regex.scan(~r/<style>(.*?)<\/style>/s, body)
    css
  end

  defp open?(tag), do: tag =~ ~r/\sopen(\s|>|=|\/)/

  defp details_tag(html), do: List.first(Regex.run(~r/<details\b[^>]*>/, html) || [""])

  # {outside, inside} of the single <details> of `html`
  defp split_details(html) do
    assert length(Regex.scan(~r/<details[\s>]/, html)) == 1, "exactly ONE <details> block"
    [[block, inner]] = Regex.scan(~r/<details\b[^>]*>(.*?)<\/details>/s, html)
    {String.replace(html, block, ""), inner}
  end

  defp strip_role(html, role), do: Regex.replace(~r/<([a-z0-9]+)\b[^>]*data-role="#{role}"[^>]*>.*?<\/\1>/s, html, "")

  # the element carrying data-role="<role>": %{tag: opening tag, inner: html}, or nil
  defp by_role(html, role) do
    case Regex.run(~r/(<([a-z0-9]+)\b[^>]*data-role="#{role}"[^>]*>)(.*?)<\/\2>/s, html) do
      [_, tag, _name, inner] -> %{tag: tag, inner: inner}
      _ -> nil
    end
  end

  defp index_of(html, needle) do
    case :binary.match(html, needle) do
      {i, _} -> i
      :nomatch -> flunk("#{inspect(needle)} is not in the page")
    end
  end

  defp nav_links(body) do
    assert [[_, nav_tag, nav]] = Regex.scan(~r/(<nav\b[^>]*>)(.*?)<\/nav>/s, body), "exactly one <nav>"
    assert (attr(nav_tag, "aria-label") || "") != "", "the <nav> has an accessible name"

    Regex.scan(~r/<a\b([^>]*)>(.*?)<\/a>/s, nav)
    |> Enum.map(fn [_, attrs, inner] -> %{label: text(inner), href: attr(attrs, "href"), current: attrs =~ ~s(aria-current="page")} end)
  end

  defp tiles(body) do
    Regex.scan(~r/<a\b([^>]*data-role="portal-tile"[^>]*)>(.*?)<\/a>/s, body)
    |> Enum.map(fn [_, attrs, inner] -> %{tile: attr(attrs, "data-tile"), href: attr(attrs, "href"), text: text(inner)} end)
  end

  # the device / grant cards of a list: [%{tag:, inner:}]
  defp cards(body, list_role, item_role) do
    assert [_, list] = Regex.run(~r/<ul\b[^>]*data-role="#{list_role}"[^>]*>(.*?)<\/ul>/s, body), "a <ul data-role=\"#{list_role}\"> exists"

    Regex.scan(~r/(<li\b[^>]*data-role="#{item_role}"[^>]*>)(.*?)<\/li>/s, list)
    |> Enum.map(fn [_, tag, inner] -> %{tag: tag, inner: inner} end)
  end

  defp form(body, action) do
    case Regex.run(~r/(<form\b[^>]*\saction="#{Regex.escape(action)}"[^>]*>)(.*?)<\/form>/s, body) do
      [_, tag, inner] -> %{tag: tag, inner: inner}
      _ -> flunk("no form with action #{action}")
    end
  end

  defp hidden(form, name) do
    Regex.scan(~r/<input\b[^>]*>/, form.inner)
    |> Enum.find_value(fn [input] -> if attr(input, "name") == name, do: attr(input, "value") end)
  end

  defp device_href(action, id), do: "/account?" |> Kernel.<>(URI.encode_query([{"action", action}, {"device_id", id}])) |> Plug.HTML.html_escape()

  defp csp_directives(conn) do
    (header(conn, "content-security-policy") || "")
    |> String.split(";", trim: true)
    |> Map.new(fn d ->
      case d |> String.trim() |> String.split(" ", parts: 2) do
        [k, v] -> {k, v}
        [k] -> {k, ""}
      end
    end)
  end

  defp header(conn, name), do: conn |> get_resp_header(name) |> List.first()

  defp sorted_headers(conn), do: conn.resp_headers |> Enum.reject(fn {k, _} -> k == "content-length" end) |> Enum.sort()

  # the headers of every account response, as before the redesign
  defp assert_headers(conn, where) do
    assert header(conn, "content-type") =~ ~r{^text/html;\s*charset=utf-8}i, "content-type on #{where}"
    assert header(conn, "x-frame-options") == "DENY", "x-frame-options on #{where}"
    assert header(conn, "cache-control") =~ "no-store", "cache-control on #{where}"
    assert header(conn, "pragma") == "no-cache", "pragma on #{where}"
    assert header(conn, "referrer-policy") == "same-origin", "referrer-policy on #{where}"
    refute Enum.any?(conn.resp_headers, fn {k, _} -> String.starts_with?(k, "access-control-") end), "no CORS on #{where}"

    directives = csp_directives(conn)
    style = css(conn.resp_body)
    assert directives["default-src"] == "'none'", "default-src on #{where}"
    assert directives["style-src"] == "'sha256-#{Base.encode64(:crypto.hash(:sha256, style))}'", "style-src is the hash of the one inline style on #{where}"
    assert directives["img-src"] == "'none'"
    assert directives["form-action"] == "'self'"
    assert directives["base-uri"] == "'none'"
    assert directives["frame-ancestors"] == "'none'"
    refute header(conn, "content-security-policy") =~ ~r/unsafe-|font-src|\*/, "no looser CSP on #{where}"
    assert [[_, ^style]] = Regex.scan(~r/<style>(.*?)<\/style>/s, conn.resp_body), "exactly one inline <style> on #{where}"
    refute conn.resp_body =~ ~r/\sstyle\s*=/i, "no style attribute on #{where}"
    refute conn.resp_body =~ ~r/<img\b/i
    refute conn.resp_body =~ ~r/(src|href|action)\s*=\s*["']?(https?:)?\/\//i, "no external resource on #{where}"
  end

  # ── scenarios ──────────────────────────────────────────────────────────────

  # Scenario: The overview shows what matters and hides the rest
  #   Given a user with 3 devices and 2 allowed apps, in German and in English
  #   When the user opens /account
  #   Then the overview shows the headline, the counts "3 signed in" / "2 allowed", the three tiles and the navigation, and the Matrix ID and display name only inside collapsed details
  @tag ac: "the-overview-shows-what-matters-and-hides-the-rest"
  test "Scenario: The overview shows what matters and hides the rest" do
    for lang <- @langs do
      c = Map.fetch!(@copy, lang)
      conn = sent(lang, :default, %{})
      b = conn.resp_body
      where = "(#{lang})"

      assert conn.status == 200
      assert lang_attr(b) == Atom.to_string(lang)
      assert [_] = Regex.scan(~r/<main[\s>]/, b)
      assert [_] = Regex.scan(~r/<h1[\s>]/, b)
      assert b =~ ~s(data-page="account")
      assert b =~ ~s(data-action="default")
      assert tag_text(b, "h1") == c.h1, "headline #{where}"

      # the headline is followed by one sentence
      assert [_, sentence] = Regex.run(~r/<\/h1>\s*<p\b[^>]*>(.*?)<\/p>/s, b), "one sentence right after the headline #{where}"
      assert text(sentence) != ""

      # header: who is signed in
      signed = by_role(b, "signed-in-as")
      assert signed, "the signed-in-as line #{where}"
      assert text(signed.inner) =~ c.signed_in
      assert text(signed.inner) =~ @user

      # navigation: four entries, the overview is current
      links = nav_links(b)
      assert Enum.map(links, & &1.label) == c.nav, "navigation labels #{where}"
      assert [overview | rest] = links
      assert overview.href in ["/account", "/account?action=org.matrix.profile"]
      assert Enum.map(rest, & &1.href) == [@devices_href, @apps_href, @reset_href]
      assert Enum.map(links, & &1.current) == [true, false, false, false], "aria-current on the overview #{where}"

      # three tiles with the live counts
      assert [devices_tile, apps_tile, security_tile] = tiles(b)
      assert Enum.map([devices_tile, apps_tile, security_tile], & &1.tile) == ["devices", "apps", "security"]
      assert devices_tile.href == @devices_href
      assert apps_tile.href == @apps_href
      assert security_tile.href == @reset_href
      assert devices_tile.text =~ c.devices_count, "#{c.devices_count} #{where}"
      assert apps_tile.text =~ c.apps_count, "#{c.apps_count} #{where}"
      assert devices_tile.text =~ Enum.at(c.nav, 1)
      assert apps_tile.text =~ Enum.at(c.nav, 2)
      assert security_tile.text =~ Enum.at(c.nav, 3)

      # profile: only inside the collapsed details
      {outside, inside} = split_details(b)
      assert details_tag(b) =~ ~s(data-role="profile-details")
      refute open?(details_tag(b)), "the profile details are collapsed on load #{where}"
      assert inside =~ ~r/<summary\b[^>]*>(?:(?!<\/summary>).)*#{c.summary}/s
      assert text(inside) =~ "Matrix ID"
      assert text(inside) =~ @user
      assert text(inside) =~ @display

      shown = outside |> strip_role("signed-in-as") |> text()
      refute shown =~ @user, "the Matrix ID is a detail #{where}"
      refute shown =~ @display, "the display name is a detail #{where}"
      refute shown =~ "Matrix ID"
      refute outside =~ ~r/<(dl|dt|dd|table)[\s>]/, "no label/value list and no table outside the details #{where}"
      refute b =~ ~s(data-role="account-device"), "the overview shows the count, not the device list"

      # order: headline, tiles, details
      assert index_of(b, "<h1") < index_of(b, ~s(data-role="portal-tile"))
      assert index_of(b, ~s(data-role="portal-tile")) < index_of(b, "<details")

      # the sign-out control of the page is kept
      logout = form(b, "/account/logout")
      assert hidden(logout, "csrf_token") == @csrf
      assert logout.inner =~ ~s(data-role="sign-out")

      assert_headers(conn, "overview #{where}")
    end

    # the counts are live: one device, no allowed app
    for {lang, devices_count, apps_count} <- [{:en, "1 signed in", "0 allowed"}, {:de, "1 angemeldet", "0 erlaubt"}] do
      [devices_tile, apps_tile | _] = lang |> body(:default, %{devices: [hd(devices())], grants: []}) |> tiles()
      assert devices_tile.text =~ devices_count
      assert apps_tile.text =~ apps_count
    end

    # a read that hit its limit only knows a lower bound: the tile says "at least"
    for {lang, text} <- [{:en, "At least 3 signed in"}, {:de, "Mindestens 3 angemeldet"}] do
      [devices_tile | _] = lang |> body(:default, %{devices: devices(), hidden: 0, hidden_exact: false, grants: []}) |> tiles()
      assert devices_tile.text =~ text
    end
  end

  # Scenario: Devices are cards, not a table
  #   Given a user with three devices
  #   When the user opens the devices page at 390 px
  #   Then each device is a list item with its name, app and last activity and a Sign out control whose accessible name includes the device, there is no table and no horizontal scroll, and device id, IP and creation time are inside each card's collapsed details
  @tag ac: "devices-are-cards-not-a-table"
  test "Scenario: Devices are cards, not a table" do
    for lang <- @langs do
      c = Map.fetch!(@copy, lang)
      conn = sent(lang, :devices, %{})
      b = conn.resp_body
      where = "(#{lang})"

      # no table at all
      refute b =~ ~r/<(table|caption|thead|tbody|tr|th|td)[\s>]/, "no table markup #{where}"
      refute b =~ "table-wrap"
      refute b =~ ~r/\sdata-label=/
      refute b =~ ~r/role="region"/

      # nothing that scrolls sideways, 44 px targets, long values wrap
      style = css(b)
      refute style =~ ~r/overflow-x\s*:\s*(auto|scroll)/, "no horizontal scroll container #{where}"
      assert style =~ "overflow-wrap:anywhere"
      assert style =~ "min-height:44px"
      refute style =~ ~r/min-width:\s*(3[2-9]\d|[4-9]\d\d|\d{4,})px/, "no fixed minimum width above 320px #{where}"

      assert [_] = Regex.scan(~r/<h1[\s>]/, b)
      assert b =~ ~s(data-action="org.matrix.devices_list")

      cards = cards(b, "device-list", "account-device")
      assert length(cards) == 3, "one list item per device #{where}"
      assert Enum.map(cards, &attr(&1.tag, "data-device-id")) == ["ABCDEFGHIJ", "KLMNOPQRST", "UVWXYZ0123"]

      for {card, dev} <- Enum.zip(cards, devices()) do
        {outside, inside} = split_details(card.inner)
        id = dev.device_id
        name = dev.display_name || c.unnamed
        w = "#{id} #{where}"

        # name, app and last activity in the main line
        assert text(by_role(outside, "device-name").inner) == name, "device name #{w}"
        meta = text(by_role(outside, "device-meta").inner)
        assert meta =~ dev.app_name, "app in the meta line #{w}"

        # a Sign out control whose accessible name includes the device
        assert [sign_out_tag, sign_out_text] =
                 (case Regex.run(~r/(<a\b[^>]*data-role="device-row-sign-out"[^>]*>)(.*?)<\/a>/s, outside) do
                    [_, t, i] -> [t, text(i)]
                    _ -> flunk("no sign-out link #{w}")
                  end)

        assert sign_out_text == c.sign_out
        assert attr(sign_out_tag, "href") == device_href("org.matrix.device_delete", id)
        assert attr(sign_out_tag, "aria-label") =~ name
        assert attr(sign_out_tag, "aria-label") =~ id

        # device id, IP and creation time are details
        refute open?(details_tag(card.inner)), "the card details are collapsed #{w}"
        main_view = text(outside)
        refute main_view =~ id, "the device id is a detail #{w}"
        refute main_view =~ ~r/\b\d{1,3}(\.\d{1,3}){3}\b/, "the IP is a detail #{w}"
        refute main_view =~ ~r/\d{4}-\d{2}-\d{2} \d{2}:\d{2} UTC/, "the absolute timestamps are details #{w}"
        assert text(inside) =~ id
        if dev.last_seen_ip, do: assert(text(inside) =~ dev.last_seen_ip)
        assert text(inside) =~ Calendar.strftime(DateTime.from_unix!(dev.created_at, :millisecond), "%Y-%m-%d %H:%M UTC")
        if dev.last_seen_ts, do: assert(text(inside) =~ Calendar.strftime(DateTime.from_unix!(dev.last_seen_ts, :millisecond), "%Y-%m-%d %H:%M UTC"))
      end

      # the first card, in words
      [first, second, third] = cards
      {first_out, _} = split_details(first.inner)
      {second_out, _} = split_details(second.inner)
      {third_out, _} = split_details(third.inner)

      case lang do
        :en ->
          assert text(by_role(first_out, "device-meta").inner) =~ "active 5 minutes ago"
          assert text(by_role(second_out, "device-meta").inner) =~ "active 2 days ago"

        :de ->
          assert text(by_role(first_out, "device-meta").inner) =~ "zuletzt aktiv vor 5 Minuten"
          assert text(by_role(second_out, "device-meta").inner) =~ "zuletzt aktiv vor 2 Tagen"
      end

      assert text(by_role(third_out, "device-meta").inner) =~ c.never

      assert_headers(conn, "devices #{where}")
    end

    # relative time: singular and plural in both languages, up to 7 days, then the ISO date
    for {offset, en, de} <- [
          {minutes(1), "active 1 minute ago", "zuletzt aktiv vor 1 Minute"},
          {minutes(5), "active 5 minutes ago", "zuletzt aktiv vor 5 Minuten"},
          {hours(1), "active 1 hour ago", "zuletzt aktiv vor 1 Stunde"},
          {hours(3), "active 3 hours ago", "zuletzt aktiv vor 3 Stunden"},
          {days(1), "active 1 day ago", "zuletzt aktiv vor 1 Tag"},
          {days(2), "active 2 days ago", "zuletzt aktiv vor 2 Tagen"}
        ] do
      for {lang, expected} <- [{:en, en}, {:de, de}] do
        b = body(lang, :devices, %{devices: [device("ABCDEFGHIJ", "Firefox on Linux", %{last_seen_ts: ago_ms(offset)})]})
        [card] = cards(b, "device-list", "account-device")
        {outside, _inside} = split_details(card.inner)
        assert text(by_role(outside, "device-meta").inner) =~ expected, "#{lang}: #{expected}"
      end
    end

    for offset <- [days(8), days(30)] do
      ts = ago_ms(offset)
      iso = Calendar.strftime(DateTime.from_unix!(ts, :millisecond), "%Y-%m-%d")

      for lang <- @langs do
        b = body(lang, :devices, %{devices: [device("ABCDEFGHIJ", "Firefox on Linux", %{last_seen_ts: ts})]})
        [card] = cards(b, "device-list", "account-device")
        {outside, _inside} = split_details(card.inner)
        meta = text(by_role(outside, "device-meta").inner)
        assert meta =~ iso, "#{lang}: after 7 days the main line shows the ISO date"
        refute meta =~ ~r/\bago\b|\bvor \d/, "#{lang}: no relative time after 7 days"
      end
    end

    # the truncation note stays below the list
    for {lang, hidden, exact, pattern} <- [
          {:en, 2, true, ~r/2 more devices not shown/},
          {:en, 1, true, ~r/1 more device not shown/},
          {:en, 2, false, ~r/At least 2 more devices not shown/},
          {:de, 2, true, ~r/2 weitere Ger/},
          {:de, 2, false, ~r/Mindestens 2 weitere Ger/}
        ] do
      b = body(lang, :devices, %{hidden: hidden, hidden_exact: exact})
      note = by_role(b, "devices-truncated")
      assert note, "the truncation note (#{lang}, #{hidden}, #{exact})"
      assert text(note.inner) =~ pattern
      assert index_of(b, ~s(data-role="devices-truncated")) > index_of(b, "</ul>"), "the note is below the list"
    end

    refute body(:en, :devices, %{}) =~ "devices-truncated"

    # request-derived values stay inert
    evil = "<img src=x onerror=1>"
    hostile = body(:en, :devices, %{devices: [device("ABCDEFGHIJ", evil, %{app_name: "<script>alert(1)</script>"})]})
    refute hostile =~ "<img"
    refute hostile =~ "<script"
    assert hostile =~ Plug.HTML.html_escape(evil)
  end

  # Scenario: Signing out a device and withdrawing an app work as before
  #   Given the devices page and the apps page
  #   When the user signs out a device and withdraws an app
  #   Then the same confirmation steps, freshness rules and notice codes apply as today, the notices are shown in the shared notice style with a text label, and the device or app is gone from the list
  @tag ac: "signing-out-a-device-and-withdrawing-an-app-work-as-before"
  test "Scenario: Signing out a device and withdrawing an app work as before" do
    dev = hd(devices())

    for lang <- @langs do
      where = "(#{lang})"

      # the confirmation step: the same form, fields and hooks
      confirm = sent(lang, :delete, %{})
      b = confirm.resp_body
      f = form(b, "/account/devices/delete")
      assert attr(f.tag, "method") == "post"
      assert hidden(f, "device_id") == dev.device_id
      assert hidden(f, "csrf_token") == @csrf
      assert [button] = Regex.scan(~r/<button\b[^>]*data-role="delete-device-confirm"[^>]*>(.*?)<\/button>/s, f.inner)
      assert text(List.last(button)) =~ dev.display_name, "the confirm button names the device #{where}"
      assert hd(button) =~ ~s(type="submit")
      assert tag_text(b, "h1") =~ dev.display_name
      assert tag_text(b, "title") =~ dev.display_name
      assert text(b) =~ dev.device_id
      assert b =~ ~s(data-action="org.matrix.device_delete")
      cancel = by_role(b, "cancel")
      assert cancel && attr(cancel.tag, "href") == @devices_href, "Cancel leads back to the devices #{where}"
      refute b =~ ~s(data-role="reauth")
      assert_headers(confirm, "delete confirm #{where}")

      # freshness: a stale session gets the re-authentication link and no form, a session without auth_time neither
      stale = body(lang, :delete, %{fresh: false})
      refute stale =~ ~s(data-role="delete-device-confirm")
      refute stale =~ "/account/devices/delete"
      reauth = by_role(stale, "reauth")
      assert reauth, "the re-authentication link #{where}"
      assert attr(reauth.tag, "href") == Plug.HTML.html_escape("/account/reauth?action=org.matrix.device_delete&device_id=ABCDEFGHIJ")

      unknown = body(lang, :delete, %{fresh: false, no_auth_time: true})
      refute unknown =~ ~s(data-role="reauth")
      refute unknown =~ ~s(data-role="delete-device-confirm")

      # the apps page: cards with the same hooks, the withdraw form per card
      apps = sent(lang, :apps, %{})
      ab = apps.resp_body
      assert ab =~ ~s(data-action="apps")
      refute ab =~ ~r/<(table|caption|thead|tbody|tr|th|td)[\s>]/, "no table markup on the apps page #{where}"
      assert [_] = Regex.scan(~r/<h1[\s>]/, ab)
      cards = cards(ab, "grant-list", "consent-grant")
      assert Enum.map(cards, &attr(&1.tag, "data-client-id")) == ["client-a", "client-b"]

      for {card, grant} <- Enum.zip(cards, grants()) do
        w = "#{grant.client_id} #{where}"
        t = text(card.inner)
        assert t =~ grant.client_name, "the name claimed by the app #{w}"
        if grant.client_host, do: assert(t =~ grant.client_host, "the website #{w}")
        assert t =~ Calendar.strftime(grant.granted_at, "%Y-%m-%d"), "allowed on #{w}"

        wf = form(card.inner, "/account/apps/withdraw")
        assert attr(wf.tag, "method") == "post"
        assert hidden(wf, "csrf_token") == @csrf
        assert hidden(wf, "client_id") == grant.client_id
        assert [wb] = Regex.scan(~r/<button\b[^>]*data-role="withdraw-grant"[^>]*>/, wf.inner) |> Enum.map(&hd/1)
        assert wb =~ ~s(type="submit")
        assert attr(wb, "aria-label") =~ grant.client_name
        if grant.client_host, do: assert(attr(wb, "aria-label") =~ grant.client_host)
      end

      # the long explanation became one sentence plus details
      note = by_role(ab, "grants-note")
      assert note, "the one-sentence note #{where}"
      assert String.length(text(note.inner)) in 20..200
      refute open?(details_tag(by_role(ab, "grants-details").tag)), "the explanation is collapsed #{where}"
      assert String.length(text(by_role(ab, "grants-details").inner)) > String.length(text(note.inner))
      assert_headers(apps, "apps #{where}")

      # the empty state
      empty = body(lang, :apps, %{grants: []})
      assert by_role(empty, "no-grants")
      refute empty =~ ~s(data-role="consent-grant")
    end

    assert Enum.sort(AccountPages.notice_codes()) == @notices |> Map.keys() |> Enum.sort(), "no notice code added or dropped"

    # the notices: same codes, same roles, the shared notice style with an icon and a text label, above the content
    for {code, role} <- @notices, lang <- @langs, page <- [:devices, :apps] do
      b = body(lang, page, %{notice: code})
      where = "#{code} on #{page} (#{lang})"

      assert [_] = Regex.scan(~r/data-role="notice"/, b), "exactly one notice #{where}"
      notice = by_role(b, "notice")
      assert attr(notice.tag, "data-notice") == code
      assert attr(notice.tag, "role") == role, "role #{role} #{where}"
      assert "notice" in class_tokens(notice.tag) and "icon" in class_tokens(notice.tag), "shared notice classes #{where}"
      assert notice.inner =~ ~r/<svg\b[^>]*aria-hidden="true"/, "decorative icon #{where}"
      assert [_, label] = Regex.run(~r/<strong>([^<]+)<\/strong>/, notice.inner), "bold text label #{where}"
      assert text(label) != ""
      assert text(notice.inner) != text(label), "the notice has a text besides its label #{where}"
      assert index_of(b, "<h1") < index_of(b, ~s(data-role="notice"))
      assert index_of(b, ~s(data-role="notice")) < index_of(b, ~s(data-role="#{if page == :devices, do: "device-list", else: "grant-list"}"))
    end

    # the German notices are translated, an unknown code renders no notice at all
    for code <- Map.keys(@notices) do
      en = by_role(body(:en, :devices, %{notice: code}), "notice")
      de = by_role(body(:de, :devices, %{notice: code}), "notice")
      assert text(en.inner) != text(de.inner), "notice #{code} is translated"
    end

    for code <- [nil, "bogus", "<script>"], lang <- @langs do
      refute body(lang, :devices, %{notice: code}) =~ ~s(data-role="notice")
    end
  end

  # Scenario: Every portal page and error follows the browser language
  #   Given the portal pages, the signed-out page and each of the 12 account error codes
  #   When they are rendered with "Accept-Language: de" and with none
  #   Then each is German respectively English with the same data hooks, status codes and headers as before, and the catalog test finds no missing key
  @tag ac: "every-portal-page-and-error-follows-the-browser-language"
  test "Scenario: Every portal page and error follows the browser language" do
    # the pages
    titles =
      for page <- @pages, into: %{} do
        en = sent(:en, page, %{})
        de = sent(:de, page, %{})
        where = "#{page}"

        assert en.status == 200 and de.status == 200
        assert lang_attr(en.resp_body) == "en"
        assert lang_attr(de.resp_body) == "de"

        for {conn, language} <- [{en, "en"}, {de, "de"}] do
          b = conn.resp_body
          w = "#{where}/#{language}"
          assert [_] = Regex.scan(~r/<main[\s>]/, b), "one <main> on #{w}"
          assert [_] = Regex.scan(~r/<h1[\s>]/, b), "one <h1> on #{w}"
          assert [[main_tag]] = Regex.scan(~r/<main\b[^>]*>/, b)
          assert attr(main_tag, "data-page") == "account"
          assert attr(main_tag, "data-action") == action(page)
          assert b =~ ~r/<svg\b[^>]*class="logo"/, "the shell logo on #{w}"
          assert String.length(tag_text(b, "title")) > 5, "title on #{w}"
          assert tag_text(b, "h1") != "", "heading on #{w}"
          refute b =~ ~r/translation missing|missing translation|\#\{|%\{|\{\{|\bnil\b|\bundefined\b/i, "unresolved key on #{w}"
          refute b =~ ~r/<(title|h1|h2|p|li|strong|summary|button)\b[^>]*>\s*<\/\1>/, "blank element on #{w}"
          assert_headers(conn, w)
        end

        # the same hooks, status and headers in both languages
        assert sorted_headers(en) == sorted_headers(de), "the headers do not depend on the language (#{where})"

        assert Regex.scan(~r/\sdata-(?:role|page|action|device-id|client-id|notice|tile)="[^"]*"/, en.resp_body) ==
                 Regex.scan(~r/\sdata-(?:role|page|action|device-id|client-id|notice|tile)="[^"]*"/, de.resp_body),
               "the same data hooks in both languages (#{where})"

        assert tag_text(de.resp_body, "title") != tag_text(en.resp_body, "title"), "title not translated on #{where}"
        assert tag_text(de.resp_body, "h1") != tag_text(en.resp_body, "h1"), "heading not translated on #{where}"

        # no English UI text on the German page, not in the labels either
        german = visible_text(de.resp_body)

        for phrase <- @english_ui do
          refute german =~ phrase, "English text #{inspect(phrase)} on the German #{where} page"
        end

        for [_, label] <- Regex.scan(~r/aria-label="([^"]*)"/, de.resp_body) do
          refute label =~ ~r/Sign out|Withdraw|Approve|Decline|Details of/, "English accessible name #{inspect(label)} on the German #{where} page"
        end

        {page, {tag_text(en.resp_body, "title"), tag_text(de.resp_body, "title")}}
      end

    # distinct titles per page (WCAG 2.4.2), in both languages
    for index <- [0, 1] do
      all = titles |> Map.values() |> Enum.map(&elem(&1, index))
      assert length(Enum.uniq(all)) == length(@pages), "every page has its own title (language #{index})"
    end

    # an unsupported language is the English page, byte for byte
    fr = AccountPages.send_page(put_req_header(conn(:get, "/account"), "accept-language", "fr"), 200, :signed_out, assigns(:signed_out, %{}))
    assert fr.resp_body == sent(:en, :signed_out, %{}).resp_body

    # the errors
    assert Enum.sort(AccountPages.error_codes()) == @errors |> Map.keys() |> Enum.sort(), "the 12 error codes, none added or dropped"

    for {code, {status, restart}} <- @errors do
      en = sent_error(:en, code)
      de = sent_error(:de, code)

      for {conn, language} <- [{en, "en"}, {de, "de"}] do
        b = conn.resp_body
        w = "#{code}/#{language}"
        assert conn.status == status, "status of #{w}"
        assert lang_attr(b) == language
        assert [[main_tag]] = Regex.scan(~r/<main\b[^>]*>/, b)
        assert attr(main_tag, "data-page") == "account-error"
        assert attr(main_tag, "data-error") == code
        assert [_] = Regex.scan(~r/<h1[\s>]/, b)
        assert String.length(tag_text(b, "title")) > 5, "title on #{w}"
        assert tag_text(b, "h1") != "", "heading on #{w}"
        assert tag_text(b, "p") != "", "explanation on #{w}"
        refute b =~ ~r/translation missing|missing translation|\#\{|%\{|\{\{|\bnil\b|\bundefined\b/i, "unresolved key on #{w}"
        refute b =~ ~r/<(title|h1|h2|p|li|strong|a)\b[^>]*>\s*<\/\1>/, "blank element on #{w}"
        refute b =~ ~r/<script\b/i
        assert (b =~ ~s(href="/account")) == restart, "the link back to /account is #{restart} on #{w}"
        assert_headers(conn, w)
      end

      assert sorted_headers(en) == sorted_headers(de), "the headers of #{code} do not depend on the language"

      case code do
        "rate_limited" -> assert header(de, "retry-after") == "30"
        "unavailable" -> assert header(de, "retry-after") == "30"
        "method_not_allowed" -> assert header(de, "allow") == "GET"
        _ -> :ok
      end

      for tag <- ["title", "h1", "p"] do
        assert tag_text(de.resp_body, tag) != tag_text(en.resp_body, tag), "<#{tag}> of #{code} is not translated"
      end

      german = visible_text(de.resp_body)

      for phrase <- @english_ui ++ ["Back to the account page", "Open the account page"] do
        refute german =~ phrase, "English text #{inspect(phrase)} on the German #{code} page"
      end
    end

    fr_error = AccountPages.send_error(put_req_header(conn(:get, "/account"), "accept-language", "fr"), 404, "not_found", [])
    assert fr_error.resp_body == sent_error(:en, "not_found").resp_body

    # the catalog: no key without both languages, a missing key raises, the portal texts live in it
    keys = PageText.keys()

    for key <- keys, lang <- @langs do
      assert String.trim(PageText.fetch!(key, lang)) != "", "catalog key #{key} (#{lang})"
    end

    assert_raise ArgumentError, fn -> PageText.fetch!("portal.no.such.key", :de) end

    for lang <- @langs do
      values = for key <- keys, do: PageText.fetch!(key, lang)
      c = Map.fetch!(@copy, lang)

      for text <- [c.h1, c.summary | c.nav] do
        assert text in values, "#{inspect(text)} is a catalog text (#{lang})"
      end
    end
  end

  # Scenario: The reset page keeps its click proof
  #   Given the encryption reset page with a pending request
  #   When it is rendered in the new layout
  #   Then the approve form still embeds the click-proof script allowed by its SHA-256, Approve and Decline are two clearly separated buttons with Decline first, and no other script is added
  @tag ac: "the-reset-page-keeps-its-click-proof"
  test "Scenario: The reset page keeps its click proof" do
    script = ClickProofScript.script()
    hash = ClickProofScript.csp_hash()

    csps =
      for lang <- @langs do
        conn = sent(lang, :reset, %{})
        b = conn.resp_body
        where = "(#{lang})"

        assert conn.status == 200
        assert b =~ ~s(data-action="org.matrix.cross_signing_reset")
        assert lang_attr(b) == Atom.to_string(lang)
        assert [_] = Regex.scan(~r/<h1[\s>]/, b)
        assert [_] = Regex.scan(~r/<main[\s>]/, b)
        assert b =~ ~s(data-role="reset-request")
        assert b =~ "Firefox on Linux"
        assert b =~ "ab12cd34"

        # exactly one script: the click proof, byte for byte, allowed by its SHA-256 and nothing else
        assert [_] = Regex.scan(~r/<script\b/i, b), "exactly one <script> #{where}"
        assert [[_, js]] = Regex.scan(~r/<script>(.*?)<\/script>/s, b)
        assert js == script, "the inline script is the pinned click-proof script #{where}"
        refute b =~ ~r/\son[a-z]+\s*=/i, "no inline event handler #{where}"

        directives = csp_directives(conn)
        assert directives["script-src"] == hash, "script-src is exactly the hash of the script #{where}"
        assert hash == "'sha256-#{Base.encode64(:crypto.hash(:sha256, js))}'"
        assert Map.keys(directives) |> Enum.sort() == ["base-uri", "default-src", "form-action", "frame-ancestors", "img-src", "script-src", "style-src"]
        assert directives["form-action"] == "'self'"
        refute header(conn, "content-security-policy") =~ ~r/unsafe-|\*/
        assert [[_, style]] = Regex.scan(~r/<style>(.*?)<\/style>/s, b)
        assert directives["style-src"] == "'sha256-#{Base.encode64(:crypto.hash(:sha256, style))}'"
        assert header(conn, "x-frame-options") == "DENY"
        assert header(conn, "cache-control") =~ "no-store"
        assert header(conn, "referrer-policy") == "same-origin"

        # the forms: Decline first, Approve second, each in its own form, Approve carries the click proof
        decline = form(b, "/account/cross_signing_reset/decline")
        approve = form(b, "/account/cross_signing_reset/approve")
        assert attr(decline.tag, "method") == "post" and attr(approve.tag, "method") == "post"
        assert hidden(decline, "session_id") == "sess-1" and hidden(approve, "session_id") == "sess-1"
        assert hidden(decline, "csrf_token") == @csrf and hidden(approve, "csrf_token") == @csrf
        assert approve.inner =~ ~r/<input\b[^>]*name="_click_proof"[^>]*data-click-proof|<input\b[^>]*data-click-proof[^>]*name="_click_proof"/
        refute decline.inner =~ "click-proof", "Decline needs no click proof #{where}"
        refute decline.inner =~ "approve-reset"
        refute approve.inner =~ "decline-reset"

        assert index_of(b, ~s(data-role="decline-reset")) < index_of(b, ~s(data-role="approve-reset")), "Decline comes first #{where}"
        assert index_of(b, "/account/cross_signing_reset/decline") < index_of(b, "/account/cross_signing_reset/approve")

        assert [decline_button] = Regex.scan(~r/<button\b[^>]*data-role="decline-reset"[^>]*>/, b) |> Enum.map(&hd/1)
        assert [approve_button] = Regex.scan(~r/<button\b[^>]*data-role="approve-reset"[^>]*>/, b) |> Enum.map(&hd/1)
        assert decline_button =~ ~s(type="submit") and approve_button =~ ~s(type="submit")
        assert "danger" in class_tokens(approve_button), "Approve is the dangerous one #{where}"
        refute "danger" in class_tokens(decline_button), "Decline is not styled like Approve #{where}"
        assert attr(decline_button, "aria-label") =~ "Firefox on Linux"
        assert attr(approve_button, "aria-label") =~ "Firefox on Linux"

        # clearly separated: big targets and a gap between them
        style_text = css(b)
        assert style_text =~ "min-height:44px"
        assert style_text =~ ~r/\.actions\s*\{[^}]*gap\s*:/, "a gap between the buttons #{where}"

        csp = header(conn, "content-security-policy")
        {lang, csp}
      end

    assert csps |> Keyword.values() |> Enum.uniq() |> length() == 1, "the CSP does not depend on the language"

    # no script (and no script-src) whenever the approve form is not rendered
    several = %{requests: [reset_request("sess-1"), reset_request("sess-2")]}

    for lang <- @langs, extra <- [%{requests: []}, %{fresh: false}, %{fresh: false, no_auth_time: true}, several] do
      conn = sent(lang, :reset, extra)
      refute conn.resp_body =~ ~r/<script\b/i, "no script without an approvable request (#{lang}, #{inspect(Map.keys(extra))})"
      refute header(conn, "content-security-policy") =~ "script-src"
      refute conn.resp_body =~ ~s(data-role="approve-reset")
    end

    # several requests: a problem notice, only Decline
    for lang <- @langs do
      b = body(lang, :reset, several)
      assert [_, _] = Regex.scan(~r/data-role="decline-reset"/, b)
      notice = by_role(b, "reset-several")
      assert notice && attr(notice.tag, "role") == "alert", "the several-requests notice stays an alert (#{lang})"
    end

    # stale session: the re-authentication link, no forms
    for lang <- @langs do
      b = body(lang, :reset, %{fresh: false})
      assert by_role(b, "reauth")
      refute b =~ "/account/cross_signing_reset/"
    end
  end
end
