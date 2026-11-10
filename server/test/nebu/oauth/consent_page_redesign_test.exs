defmodule Nebu.OAuth.ConsentPageRedesignTest do
  @moduledoc """
  ATDD for story `03-consent-page-redesign` (REQ-2026-018) — Consent page: the decision first, details later, in German and English.

  One test per Gherkin scenario, tagged `@tag ac: "<scenario-slug>"`. Red until the story is implemented.

  Pure rendering: `Nebu.OAuth.ConsentPage.send_page(conn, assigns)` on `Plug.Test` conns (public API unchanged, see the existing
  `oauth_consent_page_test.exs`), the language through the `Accept-Language` header (`Nebu.Web.Locale`, story 02). No database, no IdP.
  The pixel / viewport claims (390 x 844, nothing to scroll) are proven by the e2e feature; here the DOM order and the absence of the old
  label/value list in the main view pin the same thing.

  Contract pinned here (names from the story Decisions and UX design 5.1; the rest stays free):

    * first view (everything OUTSIDE the single closed `<details>`): `<h1>`, the notices (when they apply), the app block (claimed name + the line
      "Name given by the app, not verified" / "Vom Hersteller der App angegeben, nicht geprüft"), ONE permission sentence naming the user id and
      "full access" / "Zugriff", the device name line `data-role="device-name"`, Deny (class `secondary`, first), Allow (class `primary`, second);
      no `<dl>` / `<dt>` / `<dd>`.
    * notices: `freshness-notice`, `destination-notice`, `replace-notice` keep `id` + `data-role`, carry an inline `<svg>` icon and a `<strong>` text
      label, no `role`, sit above the app block and the form, and are listed in Allow's `aria-describedby`.
    * `<details>` (closed, `<summary>` "Show details" / "Details anzeigen"): website, `consent-destination-label` / `consent-destination`, the
      session line, terms and privacy URLs as escaped plain text; no `<a>` anywhere.
    * arming: unchanged markup (`id="allow"`, `aria-disabled="true"`, `data-arm`, `form="oauth-consent-armed"` pointing at no form, Deny first and
      plain, `data-arm-hint`, ONE `role="status"` `data-arm-status`, `<noscript>`), exactly ONE inline script = `Nebu.Web.ArmScript.script()` pinned
      by its SHA-256. The visible hint is ONE short line; the full mouse / keyboard / touch instructions sit in a visually hidden element (not
      `hidden`, not `aria-hidden`, not in `<details>`) that Allow's `aria-describedby` names.
    * device name to ask (`device_name: :ask`): `<label for="device-name">` "Device name", `<input id="device-name" name="device_name" required
      maxlength="64">` above the buttons and outside the details; after a refusal (`name_error: true`, `status: 422`) an own `id="device-name-error"`
      `role="alert"` message that the input is described by.

  Crash/restart — NOT APPLICABLE (no process state; the CSS/script hashes are computed at compile time).
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  @page Nebu.OAuth.ConsentPage
  @arm Nebu.Web.ArmScript

  @de_header "de-AT,de;q=0.9,en;q=0.5"
  @redirect "https://chat.acme.example/cb"
  @website "https://chat.acme.example/web"
  @user "@anna:nebu.example"

  # ── helpers ────────────────────────────────────────────────────────────────

  defp meta(extra \\ %{}),
    do: Map.merge(%{"client_name" => "Element Web", "client_uri" => @website, "redirect_uris" => [@redirect]}, extra)

  defp assigns(extra) do
    Map.merge(
      %{
        user_id: @user,
        client_metadata: meta(),
        redirect_uri: @redirect,
        device_id: "NEWDEV1234",
        device: :new,
        login_fresh: true,
        csrf_token: "csrf-token-1",
        device_name: {:derived, "Element Web (CdEfGhIj)"}
      },
      extra
    )
  end

  defp request(nil), do: conn(:get, "/oauth2/consent")
  defp request(lang), do: put_req_header(conn(:get, "/oauth2/consent"), "accept-language", lang)

  # the sent conn
  defp render(lang, extra \\ %{}) do
    assert {:ok, conn} = apply(@page, :send_page, [request(lang), assigns(extra)])
    conn
  end

  defp body(lang, extra \\ %{}), do: render(lang, extra).resp_body

  defp lang(body) do
    case Regex.run(~r/<html lang="([^"]*)"/, body) do
      [_, l] -> l
      _ -> nil
    end
  end

  defp text(html), do: html |> String.replace(~r/<[^>]+>/, " ") |> String.replace(~r/\s+/, " ") |> String.trim()

  defp tag_text(body, tag) do
    case Regex.run(~r/<#{tag}\b[^>]*>(.*?)<\/#{tag}>/s, body) do
      [_, inner] -> text(inner)
      _ -> ""
    end
  end

  # the (single) <details> block: {outside, inside}
  defp split_details(body) do
    assert length(Regex.scan(~r/<details[\s>]/, body)) == 1, "exactly ONE <details> block"
    [[block, inner]] = Regex.scan(~r/<details\b[^>]*>(.*?)<\/details>/s, body)
    {String.replace(body, block, ""), inner}
  end

  defp details_open_tag(body), do: List.first(Regex.run(~r/<details\b[^>]*>/, body) || [""])

  # the full element carrying id="<id>" (nested same-name tags are balanced), or nil
  defp element(body, id) do
    with [{s, l}, {ts, tl}] <- Regex.run(~r/<([a-z0-9]+)\b[^>]*\sid="#{id}"[^>]*>/, body, return: :index) do
      tag = binary_part(body, ts, tl)
      from = s + l
      rest = binary_part(body, from, byte_size(body) - from)

      close =
        Regex.scan(~r/<(\/?)#{tag}\b/, rest, return: :index)
        |> Enum.reduce_while(1, fn [{pos, _}, {_, glen}], depth ->
          depth = if glen == 1, do: depth - 1, else: depth + 1
          if depth == 0, do: {:halt, {:found, pos}}, else: {:cont, depth}
        end)

      case close do
        {:found, pos} -> binary_part(body, s, l + pos)
        _ -> binary_part(body, s, byte_size(body) - s)
      end
    else
      _ -> nil
    end
  end

  defp index_of(body, needle) do
    case :binary.match(body, needle) do
      {i, _} -> i
      :nomatch -> flunk("#{inspect(needle)} is not in the page")
    end
  end

  defp buttons(body), do: Regex.scan(~r/<button\b[^>]*>.*?<\/button>/s, body) |> Enum.map(&hd/1)

  defp allow_tag(body) do
    assert [allow] = Regex.scan(~r/<button\b[^>]*value="allow"[^>]*>/, body) |> Enum.map(&hd/1)
    allow
  end

  defp describedby(body) do
    assert [_, ids] = Regex.run(~r/aria-describedby="([^"]+)"/, allow_tag(body)), "Allow has an aria-describedby"
    String.split(ids, " ", trim: true)
  end

  defp css(body) do
    assert [[_, css]] = Regex.scan(~r/<style>(.*?)<\/style>/s, body)
    css
  end

  defp class_tokens(tag) do
    case Regex.run(~r/\sclass="([^"]*)"/, tag) do
      [_, c] -> String.split(c, " ", trim: true)
      _ -> []
    end
  end

  defp holder, do: %{display_name: "Firefox on Linux", last_seen_ts: 1_700_000_000_000}

  # ── scenarios ──────────────────────────────────────────────────────────────

  # Scenario: The decision is in the first view on a phone
  #   Given a fresh login, a new device and no warnings, at a 390 x 844 viewport, in German and in English
  #   When the consent page is shown
  #   Then the heading, the app name, the permission sentence, the device name and both buttons are visible without scrolling and no label/value list is shown
  @tag ac: "the-decision-is-in-the-first-view-on-a-phone"
  test "Scenario: The decision is in the first view on a phone" do
    en = body(nil)
    de = body(@de_header)

    assert lang(en) == "en"
    assert lang(de) == "de"
    assert tag_text(en, "title") != tag_text(de, "title"), "the <title> is translated"
    refute tag_text(en, "title") =~ "Element Web", "the <title> stays static, never a request value"
    assert tag_text(en, "h1") == "Allow this app to use your account?"
    assert tag_text(de, "h1") == "Dieser App Zugriff auf Ihr Konto erlauben?"

    for {b, claim, allow_label, deny_label, access} <- [
          {en, "Name given by the app, not verified", "Allow", "Deny", ~r/full access/},
          {de, "Vom Hersteller der App angegeben, nicht geprüft", "Erlauben", "Ablehnen", ~r/Zugriff/}
        ] do
      # fresh login, new device, same website: no warnings at all
      refute b =~ ~r/\sid="(freshness|destination|replace)-notice"/, "no warnings when nothing applies"

      {outside, _inside} = split_details(b)
      main_view = text(outside)

      # no label/value list in the main view
      refute outside =~ ~r/<(dl|dt|dd|table)[\s>]/, "no label/value list outside the details"
      refute main_view =~ "NEWDEV1234", "the device id is a detail"

      # what is in the first view: heading, app, claim line, permission sentence, device name, both buttons
      assert [_] = Regex.scan(~r/<h1[\s>]/, outside)
      assert main_view =~ "Element Web"
      assert main_view =~ claim
      assert main_view =~ ~r/#{@user}/
      assert main_view =~ access
      assert element(outside, "consent-destination") == nil, "the destination row is a detail"

      assert [name_el] = Regex.scan(~r/<[a-z0-9]+\b[^>]*data-role="device-name"[^>]*>.*?<\/[a-z0-9]+>/s, outside) |> Enum.map(&hd/1)
      assert text(name_el) =~ "Element Web (CdEfGhIj)"

      assert [deny, allow] = buttons(outside)
      assert deny =~ ~s(value="deny") and text(deny) == deny_label
      assert allow =~ ~s(value="allow") and text(allow) == allow_label

      # the order of the first view: heading, app, permission sentence, device name, buttons
      positions =
        [
          index_of(b, "<h1"),
          index_of(b, "Element Web"),
          index_of(b, @user),
          index_of(b, "data-role=\"device-name\""),
          index_of(b, ~s(value="deny")),
          index_of(b, ~s(value="allow"))
        ]

      assert positions == Enum.sort(positions), "heading, app name, permission sentence, device name, Deny, Allow in this order"
      assert List.last(positions) < index_of(b, "<details"), "the details come after the decision"
    end

    # a derived name needs no question
    refute en =~ ~s(name="device_name")
  end

  # Scenario: Risk notices stay visible before the decision
  #   Given a login that is not fresh, a destination outside the app's website, and a session that would be replaced
  #   When the consent page is shown
  #   Then the three notices appear above the app block with their ids, a text label and an icon, are not inside the collapsed details, and Allow is aria-described by them
  @tag ac: "risk-notices-stay-visible-before-the-decision"
  test "Scenario: Risk notices stay visible before the decision" do
    risky = %{login_fresh: false, redirect_uri: "https://login.evil.example/cb", device: {:replace, holder()}}

    for header <- [nil, @de_header] do
      b = body(header, risky)
      {outside, inside} = split_details(b)
      ids = ["freshness-notice", "destination-notice", "replace-notice"]

      assert b =~ ~s(data-fresh="false")
      assert b =~ ~s(data-device="replace")

      app_at = index_of(b, "Element Web")
      form_at = index_of(b, "<form")

      for id <- ids do
        el = element(outside, id)
        assert el, "#{id} is rendered outside the details"
        refute inside =~ id, "#{id} is not inside the collapsed details"
        assert el =~ ~s(data-role="#{id}")
        assert el =~ "<svg", "#{id} carries an icon"
        assert el =~ ~r/<strong>[^<]+<\/strong>/, "#{id} carries a bold text label"
        assert el =~ ~r/aria-hidden="true"/, "the icon is decoration"
        refute el =~ ~r/\srole=/, "#{id}: a static notice, no live region"
        assert index_of(b, ~s(id="#{id}")) < app_at, "#{id} is above the app block"
        assert index_of(b, ~s(id="#{id}")) < form_at
      end

      assert text(element(outside, "freshness-notice")) =~ ~r/Warning:|Achtung:/
      assert text(element(outside, "destination-notice")) =~ "login.evil.example"
      assert text(element(outside, "destination-notice")) =~ "chat.acme.example"
      assert text(element(outside, "replace-notice")) =~ "Firefox on Linux"

      described = describedby(b)

      for id <- ["arm-hint" | ids] do
        assert id in described, "Allow is aria-described by #{id}"
        assert length(Regex.scan(~r/\sid="#{id}"/, b)) == 1, "#{id} exists exactly once"
      end
    end

    # without the risks: no notice, no id in aria-describedby
    calm = describedby(body(nil))
    refute Enum.any?(calm, &String.ends_with?(&1, "-notice"))
  end

  # Scenario: Details are collapsed and complete
  #   Given the consent page with an app that supplies a website, terms and privacy URLs
  #   When the user opens "Show details"
  #   Then the website, the destination (id consent-destination), the session line, the terms and the privacy URLs are shown as escaped plain text and none of them is a link
  @tag ac: "details-are-collapsed-and-complete"
  test "Scenario: Details are collapsed and complete" do
    tos = "https://chat.acme.example/terms?a=1&b=<b>x</b>"
    privacy = "https://chat.acme.example/privacy?x=\"y\"&z=<i>"
    extra = %{client_metadata: meta(%{"tos_uri" => tos, "policy_uri" => privacy})}

    for {header, summary, session} <- [
          {nil, "Show details", "A new session (device NEWDEV1234) will be created."},
          {@de_header, "Details anzeigen", nil}
        ] do
      b = body(header, extra)
      refute details_open_tag(b) =~ ~r/\sopen(\s|>|=)/, "the details are collapsed on load"
      {outside, inside} = split_details(b)

      assert b =~ ~r/<summary\b[^>]*>(?:(?!<\/summary>).)*#{summary}/s
      assert inside =~ ~r/<summary/

      # complete: website, destination (ids kept), session line, terms, privacy
      assert text(inside) =~ "chat.acme.example"
      assert [_] = Regex.scan(~r/\sid="consent-destination"/, b)
      assert [_] = Regex.scan(~r/\sid="consent-destination-label"/, b)
      assert inside =~ ~s(id="consent-destination"), "the destination is inside the details"
      assert inside =~ ~s(id="consent-destination-label")
      assert text(element(inside, "consent-destination")) =~ "chat.acme.example"
      assert text(inside) =~ "NEWDEV1234", "the session line names the device"
      if session, do: assert(text(inside) =~ session)

      # the claimed URLs are escaped PLAIN TEXT
      assert inside =~ Plug.HTML.html_escape(tos)
      assert inside =~ Plug.HTML.html_escape(privacy)
      refute b =~ "<b>x</b>"
      refute b =~ "<i>"

      # nothing of it is a link, nowhere on the page
      refute b =~ ~r/<a[\s>]/i
      refute b =~ ~r/\shref\s*=/i

      # and none of it leaks into the main view
      refute text(outside) =~ "/terms"
      refute text(outside) =~ "/privacy"
    end

    # absent terms / privacy: nothing is invented
    {_o, bare} = split_details(body(nil))
    refute text(bare) =~ ~r/Terms of service|Privacy policy/
  end

  # Scenario: Arming behaviour is unchanged
  #   Given the new consent page
  #   When the arming tests of ArmScript and the consent flow run
  #   Then Allow is inert until armed, Deny is never aria-disabled and comes first, Allow without JavaScript stays unavailable, the page still carries exactly one inline script allowed by its SHA-256 and the full mouse / keyboard / touch instructions stay available to assistive technology
  @tag ac: "arming-behaviour-is-unchanged"
  test "Scenario: Arming behaviour is unchanged" do
    script = apply(@arm, :script, [])
    script_hash = Base.encode64(:crypto.hash(:sha256, script))

    for header <- [nil, @de_header] do
      conn = render(header)
      b = conn.resp_body

      # Deny first and plain, Allow inert until armed (never `disabled`)
      assert [deny, allow] = buttons(b)
      assert deny =~ ~s(value="deny")
      for attr <- [~r/disabled/, ~r/aria-disabled/, ~r/\sform=/, ~r/\sdata-arm(\s|>|=|-)/], do: refute(deny =~ attr)
      assert allow =~ ~s(id="allow")
      assert allow =~ ~s(aria-disabled="true")
      assert allow =~ ~r/\sdata-arm(\s|>|=)/
      assert allow =~ ~s(form="oauth-consent-armed")
      refute allow =~ ~r/\sdisabled(\s|>|=)/

      # no JavaScript: the form attribute points at NO form, the only form is the consent form, a <noscript> says so
      refute b =~ ~s(id="oauth-consent-armed")
      assert [form] = Regex.scan(~r/<form\b[^>]*>/, b) |> Enum.map(&hd/1)
      assert form =~ ~s(action="/oauth2/consent")
      assert b =~ ~r/<noscript>.+<\/noscript>/s

      # exactly one inline script: the shared one, pinned by its SHA-256, no unsafe-inline
      assert [[_, inline]] = Regex.scan(~r/<script>(.*?)<\/script>/s, b)
      assert inline == script
      assert length(Regex.scan(~r/<script[\s>]/, b)) == 1
      refute b =~ ~r/<script[^>]*\ssrc/i
      refute b =~ ~r/\son[a-z]+\s*=/i
      csp = Plug.Conn.get_resp_header(conn, "content-security-policy") |> List.first()
      assert csp =~ "script-src 'sha256-#{script_hash}'"
      refute csp =~ "unsafe-inline"
      assert csp =~ "style-src 'sha256-#{Base.encode64(:crypto.hash(:sha256, css(b)))}'"
      assert csp =~ "form-action 'self' https://chat.acme.example"
      assert Plug.Conn.get_resp_header(conn, "x-frame-options") == ["DENY"]
      assert Plug.Conn.get_resp_header(conn, "cross-origin-opener-policy") == ["same-origin"]

      # the hint and the live region keep their hooks; ONE role="status"
      assert [_] = Regex.scan(~r/\sdata-arm-hint(\s|>|=)/, b)
      assert [_] = Regex.scan(~r/\sdata-arm-status(\s|>|=)/, b)
      assert [_] = Regex.scan(~r/role="status"/, b)

      # the visible hint is ONE short line and no longer carries the three instructions
      hint = text(element(b, "arm-hint"))
      assert hint != ""
      assert String.length(hint) <= 140, "one line: #{inspect(hint)}"
      refute hint =~ ~r/Keyboard|Tastatur/

      # the full instructions: visually hidden, named by Allow's aria-describedby, never `hidden` / aria-hidden / inside the details
      {outside, inside} = split_details(b)
      described = describedby(b)
      assert "arm-hint" in described

      instructions =
        described
        |> Enum.reject(&(&1 == "arm-hint"))
        |> Enum.map(&{&1, element(b, &1)})
        |> Enum.filter(fn {_id, el} -> el && String.length(text(el)) > 80 end)

      assert [{id, el}] = instructions, "exactly one described-by element holds the full device-specific instructions"
      assert element(outside, id), "#{id} is not inside <details> (a closed <details> hides it from assistive technology)"
      refute inside =~ ~s(id="#{id}")
      refute el =~ ~r/\shidden(\s|>|=)/
      refute el =~ ~r/aria-hidden/
      assert css(b) =~ ~r/clip(-path)?\s*:/, "a visually-hidden rule exists"

      if header == nil do
        for word <- ["Mouse", "Keyboard", "Touch"], do: assert(text(el) =~ word)
      end
    end

    # German differs from English (the instructions are translated too)
    assert tag_text(body(@de_header), "noscript") != tag_text(body(nil), "noscript")
  end

  # Scenario: The required device name is part of the main view
  #   Given an approved client from which no device name can be derived
  #   When the consent page is shown
  #   Then a labelled "Device name" field sits above the buttons (not in details) with its own error message after a refusal, and Allow stays the only filled button
  @tag ac: "the-required-device-name-is-part-of-the-main-view"
  test "Scenario: The required device name is part of the main view" do
    ask = %{device_name: :ask, client_metadata: meta(%{"client_name" => ""})}

    for header <- [nil, @de_header] do
      b = body(header, ask)
      {outside, inside} = split_details(b)

      # a labelled, required, bounded field in the main view, above the buttons
      assert [input] = Regex.scan(~r/<input\b[^>]*name="device_name"[^>]*>/, outside) |> Enum.map(&hd/1)
      refute inside =~ "device_name", "the field is not in the details"
      assert input =~ ~s(id="device-name")
      assert input =~ ~r/\srequired(\s|>|=)/
      assert input =~ ~s(maxlength="64")
      assert input =~ ~s(type="text")
      assert [_, label] = Regex.run(~r/<label\b[^>]*for="device-name"[^>]*>(.*?)<\/label>/s, b)
      if header == nil, do: assert(text(label) =~ ~r/Device name/i)
      assert text(label) != ""
      assert index_of(b, ~s(name="device_name")) < index_of(b, ~s(value="deny"))
      assert index_of(b, ~s(name="device_name")) < index_of(b, ~s(value="allow"))
      assert index_of(b, ~s(name="device_name")) < index_of(b, "<details")
      refute b =~ ~s(data-role="device-name"), "no name line when the user is asked"
      refute b =~ ~s(id="device-name-error"), "no error before a refusal"
      refute input =~ ~r/aria-describedby="[^"]*device-name-error/

      # after a refusal: the field again, with its OWN error message that the input is described by
      refused = body(header, Map.merge(ask, %{name_error: true, status: 422}))
      assert render(header, Map.merge(ask, %{name_error: true, status: 422})).status == 422
      {refused_outside, _} = split_details(refused)
      error = element(refused_outside, "device-name-error")
      assert error, "the refusal has its own message, outside the details"
      assert error =~ ~s(role="alert")
      assert text(error) != ""
      assert [refused_input] = Regex.scan(~r/<input\b[^>]*name="device_name"[^>]*>/, refused) |> Enum.map(&hd/1)
      assert refused_input =~ ~r/aria-describedby="[^"]*device-name-error/
      assert index_of(refused, ~s(id="device-name-error")) < index_of(refused, ~s(value="deny"))

      # Allow stays the only filled (primary) button, Deny is outlined and first
      assert [deny, allow] = buttons(b)
      assert "primary" in class_tokens(allow)
      refute "primary" in class_tokens(deny)
      assert "secondary" in class_tokens(deny)
      assert deny =~ ~s(value="deny")
      assert length(Enum.filter(buttons(b), &("primary" in class_tokens(&1)))) == 1
    end
  end
end
