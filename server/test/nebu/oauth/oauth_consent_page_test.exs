defmodule Nebu.OAuth.OAuthConsentPageTest do
  @moduledoc """
  Acceptance tests for story `oauth-authorize-freshness` (P3): AC3 (page content and
  accessibility hooks, FR9, FR11) and AC4 (headers and the CSP `form-action` source, FR10), amended by story
  `consent-arming-hardening` (epic SEC gate 3, G3-5): Allow is `aria-disabled` (never `disabled`) and armed by the
  shared `Nebu.Web.ArmScript` with the same markup contract as the SSO confirmation page (D1-D4, AC1-AC3).

  The page is rendered by `GET /oauth2/consent` from a LIVE `oauth_consent_requests` row (the test
  inserts rows DIRECTLY with `T.insert_consent!/2` for values the real flow cannot produce: hostile
  names, loopback / private-use / upper-case-scheme redirect URIs, a redirect URI that must fail the
  CSP source check).

  Pinned contract (also in `oauth_test_support.exs` and the report of the ATDD role):

    * `<main data-page="oauth-consent" data-device="new|same_client|replace" data-fresh="true|false">`
    * `<html lang="en">`, ONE static `<title>` (never contains request values), ONE `<h1>` "Allow this app
      to use your Matrix account?", a `<dl>`, ONE `<form method="post" action="/oauth2/consent">` with the
      hidden `csrf_token` and two `<button type="submit" name="decision" value="deny|allow">` ("Deny" FIRST,
      "Allow" rendered `aria-disabled="true"` + `data-arm` + `form="oauth-consent-armed"` (a form that does not
      exist: inert without JavaScript) and NEVER `disabled`, armed by ONE hash-pinned inline script, exactly
      `Nebu.Web.ArmScript.script()`, security review M-1 / FR21 / G3-5); no other `<script>`, no `<img>`, `<a>`,
      `autofocus`, inline handler or external URL.
    * the arming markup (same as `Nebu.Matrix.SsoConfirmPage`): a visible hint `<p class="hint" id="arm-hint"
      data-arm-hint>`, an empty polite live region `<p class="hint" role="status" data-arm-status>` (the ONLY
      `role="status"` of the page), both inside the form before `.actions`; Allow is `aria-describedby="arm-hint
      consent-destination-label consent-destination[ freshness-notice][ destination-notice][ replace-notice]"` (exactly the rendered warning
      blocks, each `<p class="notice" id="..." data-role="...">` WITHOUT `role="status"`); the destination `<dt
      id="consent-destination-label">` and `<dd class="key" id="consent-destination">` (review cycle 1, UX N4).
    * every request-derived value is HTML-escaped (`Plug.HTML.html_escape/1`).
    * headers: `no-store`, `Pragma: no-cache`, `X-Frame-Options: DENY`, `Cross-Origin-Opener-Policy:
      same-origin`, `Referrer-Policy: same-origin`, no CORS; CSP `default-src 'none'; style-src
      'sha256-<css>'; script-src 'sha256-<script>'; img-src 'none'; base-uri 'none'; frame-ancestors
      'none'; form-action 'self' <target>` where `<target>` is the https origin, the
      scheme source `http:` for a loopback redirect (never an IPv6 literal), `<scheme>:` (lower-cased) for
      a private-use scheme. A redirect URI that cannot give a valid source => `500` page `server_error`,
      nothing consumed.
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  alias Nebu.OAuth.TestSupport, as: T

  @https "https://app.example.com/cb"
  @website "https://app.example.com"

  setup do
    T.enable_oauth()
    T.reset_rate_limits()
    priv = T.setup_idp!()

    on_exit(fn ->
      T.clear_oauth_config()
      T.restore_rate_limits()
      Application.delete_env(:nebu_http, :oauth_repo)
    end)

    sub = T.unique_sub()

    {:ok,
     priv: priv,
     sub: sub,
     uid: T.provision_user!(sub),
     cid: T.oauth_client!([@https], client_name: "Consent Page App", client_uri: @website)}
  end

  defp get_page(row), do: T.consent_get(row.cookie)

  defp csp(conn), do: T.header(conn, "content-security-policy") || ""

  defp directive(csp, name) do
    csp
    |> String.split(";")
    |> Enum.map(&String.trim/1)
    |> Enum.find_value(fn d -> if d == name or String.starts_with?(d, name <> " "), do: String.trim_leading(d, name) |> String.trim() end)
  end

  # the ids Allow is described by (N3): everything after aria-describedby=
  defp allow_describedby(b) do
    assert [allow] = Regex.scan(~r/<button\b[^>]*value="allow"[^>]*>/, b) |> Enum.map(&hd/1)
    assert [_, ids] = Regex.run(~r/aria-describedby="([^"]+)"/, allow), "Allow has an aria-describedby: #{allow}"
    String.split(ids, " ", trim: true)
  end

  defp assert_ids_exist(b, ids) do
    for id <- ids, do: assert(length(Regex.scan(~r/\sid="#{id}"/, b)) == 1, "aria-describedby names #{id}, which is not exactly once in the page")
  end

  # plain text of the page with entities left as the server wrote them (for substring checks)
  defp plain(body), do: body |> String.replace(~r/<[^>]+>/, " ") |> String.replace(~r/\s+/, " ")

  # ════════════════════════════════════════════════════════════════════════════
  # AC3 — structure, hooks, accessibility
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC3.1 — page contract" do
    test "hooks, language, one h1, a dl, one form with two submit buttons, nothing active", %{cid: cid, uid: uid} do
      row = T.insert_consent!(cid, user_id: uid, device_id: "NEWDEV1234")
      conn = get_page(row)
      assert conn.status == 200
      assert (T.header(conn, "content-type") || "") =~ ~r{^text/html;\s*charset=utf-8}i
      b = conn.resp_body

      assert b =~ ~r/\A\s*<!doctype html>/i
      assert b =~ ~r/<html[^>]*lang="en"/
      assert b =~ ~r/<meta[^>]*charset/i
      assert b =~ ~r/<meta[^>]*name="viewport"/
      assert b =~ ~r/<main[^>]*data-page="oauth-consent"/
      assert b =~ ~s(data-device="new")
      assert b =~ ~s(data-fresh="true")
      assert length(Regex.scan(~r/<main[\s>]/, b)) == 1

      assert [_] = Regex.scan(~r/<h1[\s>]/, b), "exactly one level-1 heading"
      assert b =~ ~r/<h1[^>]*>\s*Allow this app to use your Matrix account\?\s*<\/h1>/
      assert b =~ ~r/<dl[\s>]/, "the facts are a description list"
      assert b =~ ~r/<dt[\s>]/ and b =~ ~r/<dd[\s>]/

      assert [form] = Regex.scan(~r/<form\b[^>]*>/, b) |> Enum.map(&hd/1)
      assert form =~ ~r/method="post"/i
      assert form =~ ~s(action="/oauth2/consent")

      buttons = Regex.scan(~r/<button\b[^>]*>.*?<\/button>/s, b) |> Enum.map(&hd/1)
      assert length(buttons) == 2, "exactly two buttons, got #{inspect(buttons)}"
      assert Enum.all?(buttons, &(&1 =~ ~s(type="submit") and &1 =~ ~s(name="decision")))
      assert [deny, allow] = buttons, "Deny comes FIRST in the DOM (and visual) order (M-1)"
      assert allow =~ ~s(value="allow") and allow =~ ~r/>\s*Allow\s*</
      assert deny =~ ~s(value="deny") and deny =~ ~r/>\s*Deny\s*</
      assert allow =~ ~s(aria-disabled="true"), "Allow is rendered aria-disabled until the shared script armed it (M-1, G3-5)"
      assert allow =~ ~r/\sdata-arm(\s|>|=)/, "the shared arming script finds the button through data-arm"
      assert allow =~ ~s(form="oauth-consent-armed"), "a form attribute that points at no form: Allow is inert without JavaScript"
      assert allow =~ ~s(id="allow")
      refute allow =~ ~r/\sdisabled(\s|>|=)/, "never the disabled attribute (a screen-reader touch user could not reach it)"

      for attr <- [~r/disabled/, ~r/aria-disabled/, ~r/\sform=/, ~r/\sdata-arm(\s|>|=|-)/] do
        refute deny =~ attr, "Deny is a plain button, #{inspect(attr)} must not appear on it"
      end

      assert b =~ ~r/<input[^>]*name="csrf_token"/
      assert T.csrf_from(conn) == T.consent_csrf(row.value), "CSRF = base64url(SHA-256(\"nebu-oauth-consent-csrf:\" <> cookie)) (FR8)"

      for forbidden <- [~r/<script[^>]*\ssrc/i, ~r/<img/i, ~r/<a[\s>]/i, ~r/autofocus/i, ~r/\son[a-z]+\s*=/i, ~r/<iframe/i, ~r/<link/i, ~r/(src|href)="(https?:)?\/\//i] do
        refute b =~ forbidden, "#{inspect(forbidden)} must not appear on the consent page"
      end
    end

    test "the <title> is static: it never carries request values and is the same for every request", %{cid: cid, uid: uid} do
      other = T.oauth_client!([@https], client_name: "A Different App Name", client_uri: @website)
      a = get_page(T.insert_consent!(cid, user_id: uid, device_id: "TTL0000001"))
      b = get_page(T.insert_consent!(other, user_id: uid, device_id: "TTL0000002"))
      [_, t1] = Regex.run(~r/<title>([^<]+)<\/title>/, a.resp_body)
      [_, t2] = Regex.run(~r/<title>([^<]+)<\/title>/, b.resp_body)
      assert t1 == t2
      assert String.length(t1) > 5
      refute t1 =~ "Consent Page App"
    end

    test "GET is read only: reloading renders the same page and consumes nothing (PRG, FR7)", %{cid: cid, uid: uid} do
      row = T.insert_consent!(cid, user_id: uid)
      a = get_page(row)
      b = get_page(row)
      assert a.status == 200 and b.status == 200
      assert a.resp_body == b.resp_body
      assert T.consent_row(row.value), "the row survives GETs"
      assert T.consent_set_cookies(a) == [], "a GET sets and clears no cookie"
      assert T.count_for("oauth_codes", cid) == 0
    end
  end

  describe "AC3.2 — FR9 / FR11 texts" do
    test "the signed-in user id, the claimed app name, the website host, the access sentence and the always-on warning", %{cid: cid, uid: uid} do
      row = T.insert_consent!(cid, user_id: uid, device_id: "TXT0000001")
      t = plain(get_page(row).resp_body)
      assert t =~ uid
      assert t =~ "App name (claimed by the app)"
      assert t =~ "Consent Page App"
      assert t =~ "App website (claimed by the app, not verified by Nebu)"
      refute t =~ "approved by your administrator", "L-5: the unverified client_uri must not borrow the administrator's credibility"
      assert t =~ "app.example.com"
      assert t =~ "Full access to your account: read and send messages, and manage your rooms, devices and encryption keys."
      assert t =~ "Only allow this if you just started signing in to this app yourself."
      assert t =~ "After you choose, you are sent to"
    end

    test "an app without name / client_uri: 'No name given' / 'None given'", %{uid: uid} do
      cid = T.oauth_client!([@https], client_name: nil, client_uri: nil)
      t = plain(get_page(T.insert_consent!(cid, user_id: uid)).resp_body)
      assert t =~ "No name given"
      assert t =~ "None given"
    end

    test "tos_uri / policy_uri are shown as escaped PLAIN TEXT, labelled as claimed, never as a link; omitted when absent", %{uid: uid} do
      cid = T.oauth_client!([@https], metadata: %{"tos_uri" => "https://app.example.com/terms?a=1&b=2", "policy_uri" => "https://app.example.com/privacy"})
      conn = get_page(T.insert_consent!(cid, user_id: uid))
      t = plain(conn.resp_body)
      assert t =~ "Terms of service"
      assert t =~ "Privacy policy"
      assert t =~ "claimed by the app"
      assert t =~ "https://app.example.com/terms?a=1&amp;b=2", "escaped plain text"
      assert t =~ "https://app.example.com/privacy"
      refute conn.resp_body =~ ~r/<a[\s>]/i, "no link (a hostile client must not get a clickable link on a Nebu page)"

      plain_cid = T.oauth_client!([@https])
      t2 = plain(get_page(T.insert_consent!(plain_cid, user_id: uid)).resp_body)
      refute t2 =~ "Terms of service"
      refute t2 =~ "Privacy policy"
    end

    test "hostile client_name, tos_uri, policy_uri and device id are HTML-escaped (no element injected)", %{uid: uid} do
      evil = ~S|<script>alert("x")</script>&|
      cid = T.oauth_client!([@https], client_name: evil, metadata: %{"tos_uri" => ~S|javascript:alert("t")<b>&|, "policy_uri" => ~S|"><img src=x onerror=alert(1)>|})
      row = T.insert_consent!(cid, user_id: uid, device_id: ~S|D"<i>&'x|)
      conn = get_page(row)
      assert conn.status == 200
      b = conn.resp_body
      assert length(Regex.scan(~r/<script[\s>]/i, b)) == 1, "only OUR one script element, client_name must not inject another"
      refute b =~ ~S|alert("x")|
      refute b =~ ~r/<img/i
      refute b =~ ~S|alert("t")<b>|
      refute b =~ ~S|D"<i>|
      assert b =~ "&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt;&amp;"
      assert b =~ "&lt;b&gt;"
      assert b =~ "&lt;img src=x onerror=alert(1)&gt;"
      assert b =~ "&lt;i&gt;"
    end

    test "hostile display name of the device holder is escaped", %{cid: cid, uid: uid} do
      dev = "HOST000001"
      evil = ~S|<img src=x onerror=alert(1)>"&|
      :ok = Nebu.Matrix.DeviceKeyStore.upsert_device(uid, dev, display_name: evil, last_seen_ts: System.system_time(:millisecond))
      _legacy = T.legacy_session!(uid, dev)
      b = get_page(T.insert_consent!(cid, user_id: uid, device_id: dev)).resp_body
      refute b =~ ~r/<img/i
      assert b =~ "&lt;img src=x onerror=alert(1)&gt;&quot;&amp;"
    end

    test "the redirect target: an https host that is the client_uri host or a subdomain is 'part of the app website'", %{uid: uid} do
      cid = T.oauth_client!(["https://app.example.com/cb", "https://login.app.example.com/cb", "https://elsewhere.example.org/cb"], client_uri: @website)

      for {uri, host, part?} <- [
            {"https://app.example.com/cb", "app.example.com", true},
            {"https://login.app.example.com/cb", "login.app.example.com", true},
            {"https://elsewhere.example.org/cb", "elsewhere.example.org", false},
            # look-alike hosts: no label boundary / the client host is only a PREFIX of an unrelated name
            {"https://notapp.example.com/cb", "notapp.example.com", false},
            {"https://app.example.com.evil.org/cb", "app.example.com.evil.org", false},
            {"https://evilapp.example.com/cb", "evilapp.example.com", false}
          ] do
        t = plain(get_page(T.insert_consent!(cid, user_id: uid, redirect_uri: uri)).resp_body)
        [_, after_label] = String.split(t, "After you choose, you are sent to", parts: 2)
        assert after_label =~ host, "#{uri}: the host is shown"
        if part?, do: assert(after_label =~ "(part of the app website)", uri), else: refute(after_label =~ "(part of the app website)", uri)
        refute t =~ "https://elsewhere.example.org/cb", "the full redirect URI (path, query) is never rendered"
      end
    end

    test "loopback and private-use targets are 'an app on this device', with the cannot-check warning", %{uid: uid} do
      cid = T.oauth_client!(["http://localhost/cb", "http://127.0.0.1/cb", "http://[::1]/cb", "com.example.app:/oauth2/callback"])

      localhost = plain(get_page(T.insert_consent!(cid, user_id: uid, redirect_uri: "http://localhost:53682/cb")).resp_body)
      assert localhost =~ "an app on this device (localhost, port 53682)"
      assert localhost =~ "Nebu cannot check which app on your device receives this."

      for uri <- ["http://127.0.0.1:53682/cb", "http://[::1]:53682/cb"] do
        t = plain(get_page(T.insert_consent!(cid, user_id: uid, redirect_uri: uri)).resp_body)
        assert t =~ ~r/an app on this device \([^)]*port 53682\)/, uri
        assert t =~ "Nebu cannot check which app on your device receives this."
      end

      private = plain(get_page(T.insert_consent!(cid, user_id: uid, redirect_uri: "com.example.app:/oauth2/callback")).resp_body)
      assert private =~ "an app on this device (com.example.app:)"
      assert private =~ "Nebu cannot check which app on your device receives this."
      refute private =~ "(part of the app website)"
    end
  end

  describe "AC3.2/FR11 — the session line (device holder)" do
    test ":none => 'A new session (device ID) will be created.'", %{cid: cid, uid: uid} do
      conn = get_page(T.insert_consent!(cid, user_id: uid, device_id: "SESSNEW001"))
      assert conn.resp_body =~ ~s(data-device="new")
      assert plain(conn.resp_body) =~ "A new session (device SESSNEW001) will be created."
    end

    test "a live session of the SAME client => data-device=same_client, 'Continues your existing session NAME (device ID), last active DATE.'", %{cid: cid, uid: uid, sub: sub, priv: priv} do
      dev = "SESSSAME01"
      :ok = Nebu.Matrix.DeviceKeyStore.upsert_device(uid, dev, display_name: "Pixel Seven", last_seen_ts: System.system_time(:millisecond))
      s = T.session!(cid, @https, priv, sub: sub, authorize: %{"scope" => T.matrix_scope(T.stable_prefix(), dev)})
      assert s.device_id == dev

      conn = get_page(T.insert_consent!(cid, user_id: s.user_id, device_id: dev))
      assert conn.resp_body =~ ~s(data-device="same_client")
      assert plain(conn.resp_body) =~ ~r/Continues your existing session .+ \(device SESSSAME01\), last active .+\./
      refute plain(conn.resp_body) =~ "will be signed out"
    end

    test "a DCR re-registration of the same app (other client_id, same client_uri + redirect set) still 'continues' (correction 2)", %{sub: sub, priv: priv} do
      first = T.oauth_client!([@https], client_uri: @website)
      second = T.oauth_client!([@https], client_uri: @website <> "/")
      dev = "SESSRE0001"
      s = T.session!(first, @https, priv, sub: sub, authorize: %{"scope" => T.matrix_scope(T.stable_prefix(), dev)})

      conn = get_page(T.insert_consent!(second, user_id: s.user_id, device_id: dev))
      assert conn.status == 200
      assert conn.resp_body =~ ~s(data-device="same_client")
    end

    test "a LEGACY session (or a device row without a live session) => data-device=replace with the sign-out warning", %{cid: cid, uid: uid} do
      dev = "SESSLEG001"
      :ok = Nebu.Matrix.DeviceKeyStore.upsert_device(uid, dev, display_name: "Old Element", last_seen_ts: System.system_time(:millisecond))
      _legacy = T.legacy_session!(uid, dev)

      conn = get_page(T.insert_consent!(cid, user_id: uid, device_id: dev))
      assert conn.resp_body =~ ~s(data-device="replace")

      assert plain(conn.resp_body) =~
               ~r/Replaces your existing session Old Element \(device SESSLEG001\), last active .+, signed in without this app\. That session will be signed out\./

      dev2 = "SESSNOLIVE"
      :ok = Nebu.Matrix.DeviceKeyStore.upsert_device(uid, dev2, display_name: "Dormant", last_seen_ts: System.system_time(:millisecond))
      conn2 = get_page(T.insert_consent!(cid, user_id: uid, device_id: dev2))
      assert conn2.resp_body =~ ~s(data-device="replace"), "no live session but an existing device: the device is replaced"
    end
  end

  describe "AC3.3 — the freshness notice appears exactly when login_fresh = false" do
    test "login_fresh true => no notice, data-fresh=true", %{cid: cid, uid: uid} do
      conn = get_page(T.insert_consent!(cid, user_id: uid, login_fresh: true))
      assert conn.resp_body =~ ~s(data-fresh="true")
      refute plain(conn.resp_body) =~ "You were not asked for your password just now."
    end

    test "login_fresh false => the notice text, data-fresh=false, still both buttons", %{cid: cid, uid: uid} do
      conn = get_page(T.insert_consent!(cid, user_id: uid, login_fresh: false))
      assert conn.resp_body =~ ~s(data-fresh="false")
      t = plain(conn.resp_body)

      assert t =~
               "You were not asked for your password just now. Your sign-in provider did not confirm a new sign-in for this request. If you did not just start signing in to this app yourself, choose Deny."

      assert t =~ "Only allow this if you just started signing in to this app yourself.", "the always-on sentence stays"
      assert length(Regex.scan(~r/<button\b/, conn.resp_body)) == 2
    end

    test "N4: rendered warning blocks keep the Warning: label, are no live region; [data-arm-status] is the only role=status", %{uid: uid} do
      cid = T.oauth_client!([@https, "https://evil.example.net/cb"], client_uri: @website)
      dev = "NOTE000001"
      :ok = Nebu.Matrix.DeviceKeyStore.upsert_device(uid, dev, display_name: "Old Element", last_seen_ts: System.system_time(:millisecond))
      _legacy = T.legacy_session!(uid, dev)
      b = get_page(T.insert_consent!(cid, user_id: uid, device_id: dev, login_fresh: false, redirect_uri: "https://evil.example.net/cb")).resp_body

      for role <- ~w(freshness-notice destination-notice replace-notice) do
        assert [block] = Regex.scan(~r/<p\b[^>]*data-role="#{role}"[^>]*>.*?<\/p>/s, b) |> Enum.map(&hd/1), "#{role} is rendered once"
        assert block =~ ~r/<strong>Warning:<\/strong>/, "#{role}: a text label (not colour only)"
        refute block =~ ~r/\srole=/, "#{role}: static text in a live region is not announced reliably (UX N4)"
      end

      assert [status] = Regex.scan(~r/<[^>]*role="status"[^>]*>/, b) |> Enum.map(&hd/1), "exactly one status region on the page"
      assert status =~ "data-arm-status"
    end

    test "N4: the page of a fresh login has exactly one role=status, the empty [data-arm-status]", %{cid: cid, uid: uid} do
      b = get_page(T.insert_consent!(cid, user_id: uid, login_fresh: true)).resp_body
      assert [_] = Regex.scan(~r/role="status"/, b)
      assert [region] = Regex.scan(~r/<p\b[^>]*data-arm-status[^>]*>.*?<\/p>/s, b) |> Enum.map(&hd/1)
      assert region =~ ~s(role="status")
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC4 — headers and the CSP form-action source (FR10)
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC4.1 — headers on GET" do
    test "no-store, Pragma, X-Frame-Options, Referrer-Policy same-origin, no CORS, nosniff", %{cid: cid, uid: uid} do
      conn = T.consent_get(T.insert_consent!(cid, user_id: uid).cookie, headers: [{"origin", "https://client.example.com"}])
      assert T.header(conn, "cache-control") =~ "no-store"
      assert T.header(conn, "pragma") == "no-cache"
      assert T.header(conn, "x-frame-options") == "DENY"
      assert T.header(conn, "referrer-policy") == "same-origin", "no-referrer would make the page's own form POST carry `Origin: null`"
      assert T.header(conn, "x-content-type-options") == "nosniff"
      refute Enum.any?(conn.resp_headers, fn {k, _} -> String.starts_with?(k, "access-control-") end)
    end

    test "CSP: default-src none, style hash equals the inline CSS, img/base/frame locked, form-action self + the https origin", %{cid: cid, uid: uid} do
      conn = get_page(T.insert_consent!(cid, user_id: uid))
      c = csp(conn)
      assert c =~ ~r/^default-src 'none'/
      assert directive(c, "img-src") == "'none'"
      assert directive(c, "base-uri") == "'none'"
      assert directive(c, "frame-ancestors") == "'none'"
      assert directive(c, "form-action") == "'self' https://app.example.com"
      refute c =~ "unsafe-inline", "no 'unsafe-inline' at all"
      refute c =~ "unsafe-eval"
      assert [_, script_hash] = Regex.run(~r/script-src 'sha256-([^']+)'/, c), "script-src is pinned by hash"
      assert [script] = Regex.scan(~r/<script>(.*?)<\/script>/s, conn.resp_body) |> Enum.map(&List.last/1)
      assert script == apply(Nebu.Web.ArmScript, :script, []), "AC1: the page embeds the shared script byte for byte"
      assert script_hash == Base.encode64(:crypto.hash(:sha256, apply(Nebu.Web.ArmScript, :script, []))), "the CSP hash is computed from ArmScript.script/0"
      assert script_hash == Base.encode64(:crypto.hash(:sha256, script)), "the CSP hash equals the ONE inline script"
      refute script =~ ~r/fetch|XMLHttpRequest|eval\(|innerHTML|document\.write|location/, "the script only arms the button"

      [_, hash] = Regex.run(~r/style-src 'sha256-([^']+)'/, c)
      assert [css] = Regex.scan(~r/<style>(.*?)<\/style>/s, conn.resp_body) |> Enum.map(&List.last/1)
      assert hash == Base.encode64(:crypto.hash(:sha256, css)), "the CSP hash equals the CSS actually inlined"
    end

    test "form-action carries the PORT of an https redirect", %{uid: uid} do
      cid = T.oauth_client!(["https://app.example.com:8443/cb"])
      c = csp(get_page(T.insert_consent!(cid, user_id: uid, redirect_uri: "https://app.example.com:8443/cb")))
      assert directive(c, "form-action") == "'self' https://app.example.com:8443"
    end

    test "loopback redirects get the SCHEME source http: and NO host source (an IPv6 literal is no valid CSP host-source)", %{uid: uid} do
      cid = T.oauth_client!(["http://localhost/cb", "http://127.0.0.1/cb", "http://[::1]/cb"])

      for uri <- ["http://localhost:53682/cb", "http://127.0.0.1:53682/cb", "http://[::1]:53682/cb"] do
        conn = get_page(T.insert_consent!(cid, user_id: uid, redirect_uri: uri))
        assert conn.status == 200, uri
        c = csp(conn)
        assert directive(c, "form-action") == "'self' http:", "#{uri} => #{c}"
        refute c =~ "[::1]"
        refute c =~ "::"
        refute c =~ "localhost"
        refute c =~ "127.0.0.1"
        refute c =~ "53682"
      end
    end

    test "a private-use scheme gets the scheme source <scheme>:, lower-cased", %{uid: uid} do
      cid = T.oauth_client!(["com.example.app:/oauth2/callback", "COM.Example.App:/cb"])

      plain_scheme = csp(get_page(T.insert_consent!(cid, user_id: uid, redirect_uri: "com.example.app:/oauth2/callback")))
      assert directive(plain_scheme, "form-action") == "'self' com.example.app:"

      upper = get_page(T.insert_consent!(cid, user_id: uid, redirect_uri: "COM.Example.App:/cb"))
      assert upper.status == 200
      assert directive(csp(upper), "form-action") == "'self' com.example.app:", "the scheme is lower-cased first (CSP scheme sources are matched case-sensitively by some engines)"
    end

    test "an upper-case https scheme / host is normalized too", %{uid: uid} do
      cid = T.oauth_client!(["https://app.example.com/cb"])
      conn = get_page(T.insert_consent!(cid, user_id: uid, redirect_uri: "HTTPS://App.Example.COM/cb"))
      assert conn.status == 200
      assert directive(csp(conn), "form-action") == "'self' https://app.example.com"
    end
  end

  describe "AC4.2 — a redirect URI that fails the source check => the server_error page, the row stays, no code" do
    for {label, uri} <- [
          {"a `;` in the host (CSP directive injection)", "https://app.example.com;script-src-elem *;/cb"},
          {"a space in the host", "https://app example.com/cb"},
          {"a quote", "https://app.example.com'/cb"},
          {"an empty private-use scheme body", "://x"}
        ] do
      test "#{label}", %{cid: cid, uid: uid} do
        row = T.insert_consent!(cid, user_id: uid, redirect_uri: unquote(uri))
        conn = get_page(row)
        T.assert_page(conn, 500, "server_error")
        refute csp(conn) =~ "script-src-elem", "the hostile value never reaches a header"
        assert T.consent_row(row.value), "nothing consumed: the row stays"
        assert T.count_for("oauth_codes", cid) == 0
      end
    end

    test "POST Allow on such a row issues nothing either (the redirect target is unusable)", %{cid: cid, uid: uid} do
      row = T.insert_consent!(cid, user_id: uid, redirect_uri: "https://app.example.com;x/cb")
      conn = T.consent!(row.cookie, :allow, get: false)
      T.assert_page(conn, 500, "server_error")
      assert T.location(conn) == nil, "never a redirect to the unusable target"
      assert T.consent_row(row.value) == nil, "the single-use row is consumed by the attempt (it can never become valid)"
      assert T.count_for("oauth_codes", cid) == 0
    end
  end
  # ════════════════════════════════════════════════════════════════════════════
  # review cycle 1 — M-1 (double clickjacking), L-5 (website wording), UX advisories
  # ════════════════════════════════════════════════════════════════════════════

  describe "M-1 / FR21 / G3-5 — the page is hardened against double clickjacking (shared ArmScript)" do
    test "COOP stays same-origin (D5); Allow is aria-disabled with data-arm; the other headers are unchanged (AC5)", %{cid: cid, uid: uid} do
      conn = get_page(T.insert_consent!(cid, user_id: uid))
      assert T.header(conn, "cross-origin-opener-policy") == "same-origin", "D5: the consent page keeps COOP (FR10); the SSO page is the one that drops it"
      assert T.header(conn, "x-frame-options") == "DENY"
      assert T.header(conn, "referrer-policy") == "same-origin"
      assert T.header(conn, "cache-control") =~ "no-store"
      b = conn.resp_body
      assert [allow] = Regex.scan(~r/<button\b[^>]*value="allow"[^>]*>/, b) |> Enum.map(&hd/1)
      assert allow =~ ~s(aria-disabled="true") and allow =~ ~r/\sdata-arm(\s|>|=)/ and allow =~ ~s(form="oauth-consent-armed")
      refute allow =~ ~r/\sdisabled(\s|>|=)/
    end

    test "hint and noscript line carry the exact D3 wording (how Allow becomes available)", %{cid: cid, uid: uid} do
      b = get_page(T.insert_consent!(cid, user_id: uid)).resp_body

      assert plain(b) =~
               "Mouse: move the pointer onto Allow, then click. Keyboard: move the focus onto Allow, then press Enter. Touch: tap Allow. Allow becomes available a moment after your first interaction with the page; this protects you from accidental clicks."

      refute plain(b) =~ "Allow becomes available a moment after you move the pointer or press a key.", "the old wording is gone"
      refute plain(b) =~ "Then move onto Allow to use it.", "review cycle 1 (UX N6): the hint names the action per input method"

      assert plain(b) =~
               "JavaScript is off, so Allow stays unavailable even after the steps above. Turn on JavaScript or use another browser. You can still choose Deny."

      assert b =~ ~r/<noscript>.*Allow stays unavailable.*Deny.*<\/noscript>/s, "no JavaScript => Allow stays inert, Deny works (fail closed)"
      assert [allow_btn] = Regex.scan(~r/<button\b[^>]*value="allow"[^>]*>.*?<\/button>/s, b) |> Enum.map(&hd/1)
      assert allow_btn =~ ~r/>\s*Allow\s*<\/button>/, "the visible label is exactly Allow (the script takes the live-region name from it)"
    end

    test "Kassandra INFO #2: an inherited #allow fragment cannot activate Allow (the page loads with Allow focused, still unarmed)", %{cid: cid, uid: uid} do
      b = get_page(T.insert_consent!(cid, user_id: uid)).resp_body
      script = apply(Nebu.Web.ArmScript, :script, [])

      # a fragment navigation to #allow scrolls to / focuses the element: the id exists exactly once ...
      assert length(Regex.scan(~r/\sid="allow"/, b)) == 1
      # ... a focusin ON Allow never arms (the document listener skips the armed element) ...
      assert script =~ ~r/focusin",function\(e\)\{if\(!\(e\.target&&b\.contains\(e\.target\)\)\)\{act\(\)\}\}/
      # ... the focus only counts after arming (focused=false is reset on arming), so Enter is cancelled
      assert script =~ ~S|b.addEventListener("focusin",function(){if(armed){|
      assert script =~ ~r/function arm\(\)\{if\(armed\)\{return\}armed=true;entered=false;focused=false;/
      assert script =~ ~r/if\(e\.detail===0\)\{if\(!focused\)\{e\.preventDefault\(\)/
    end

    test "AC2: one data-arm, one visible hint, one EMPTY live region, hint and region inside the form before .actions", %{cid: cid, uid: uid} do
      b = get_page(T.insert_consent!(cid, user_id: uid)).resp_body

      assert length(Regex.scan(~r/\sdata-arm(?![-\w])/, b)) == 1, "exactly one data-arm element"
      assert length(Regex.scan(~r/\sdata-arm-hint(?![-\w])/, b)) == 1, "one hint element"
      assert length(Regex.scan(~r/\sdata-arm-status(?![-\w])/, b)) == 1, "one live region"

      assert [hint] = Regex.scan(~r/<[^>]*data-arm-hint[^>]*>/, b) |> Enum.map(&hd/1)
      assert hint =~ ~s(id="arm-hint")
      assert hint =~ ~s(class="hint")
      refute hint =~ ~r/\shidden(\s|>|=)/, "the hint is hidden by the script when it arms, not by the markup"

      assert [region] = Regex.scan(~r/<p\b[^>]*data-arm-status[^>]*>.*?<\/p>/s, b) |> Enum.map(&hd/1)
      assert region =~ ~s(role="status")
      assert Regex.replace(~r/<[^>]+>/, region, "") |> String.trim() == "", "empty in the markup (the script announces)"

      refute b =~ ~s(id="oauth-consent-armed"), "form=oauth-consent-armed must point at NO form (fail closed without JavaScript)"
      refute b =~ ~r/<form[^>]*oauth-consent-armed/

      {form_at, _} = :binary.match(b, "<form")
      {hint_at, _} = :binary.match(b, "data-arm-hint")
      {status_at, _} = :binary.match(b, "data-arm-status")
      {actions_at, _} = :binary.match(b, ~s(class="actions"))
      {form_end, _} = :binary.match(b, "</form>")
      assert form_at < hint_at and hint_at < actions_at and actions_at < form_end, "the hint is inside the form before the buttons"
      assert form_at < status_at and status_at < actions_at, "the live region is inside the form before the buttons"
    end

    test "the page embeds exactly Nebu.Web.ArmScript.script() and nothing else active (AC1)", %{cid: cid, uid: uid} do
      b = get_page(T.insert_consent!(cid, user_id: uid)).resp_body
      script = apply(Nebu.Web.ArmScript, :script, [])
      assert [inline] = Regex.scan(~r/<script>(.*?)<\/script>/s, b) |> Enum.map(&List.last/1)
      assert inline == script
      assert length(Regex.scan(~r/<script[\s>]/i, b)) == 1
    end

    test "D1/AC1: ConsentPage.script/0 is gone; consent_page.ex has no addEventListener and names Nebu.Web.ArmScript" do
      assert {:module, Nebu.OAuth.ConsentPage} = Code.ensure_loaded(Nebu.OAuth.ConsentPage)
      assert function_exported?(Nebu.OAuth.ConsentPage, :script, 0) == false, "one source of truth: no delegate either"
      assert function_exported?(Nebu.OAuth.ConsentPage, :css, 0), "the CSS accessor is untouched"

      src =
        Path.expand("../../../lib/nebu/oauth/consent_page.ex", __DIR__)
        |> File.read!()
        |> String.replace(~r/"""[\s\S]*?"""/, "")
        |> String.replace(~r/#[^\n]*/, "")

      assert src =~ "Nebu.Web.ArmScript"
      assert src =~ "Nebu.Web.ArmScript.script()"
      refute src =~ "addEventListener", "no private script in consent_page.ex"
      refute src =~ ~r/~S[\[\']/, "no ~S[ / ~S' script literal"
      refute src =~ ~r/def script\b/
      refute src =~ "a.disabled"
    end

    test "CSS: button[aria-disabled=true] replaces button:disabled; the CSP style hash equals the inlined CSS", %{cid: cid, uid: uid} do
      conn = get_page(T.insert_consent!(cid, user_id: uid))
      assert [css] = Regex.scan(~r/<style>(.*?)<\/style>/s, conn.resp_body) |> Enum.map(&List.last/1)
      assert css =~ "button[aria-disabled=true]{opacity:.6;cursor:not-allowed}"
      refute css =~ "button:disabled"
      assert css == apply(Nebu.OAuth.ConsentPage, :css, [])
      assert [_, hash] = Regex.run(~r/style-src 'sha256-([^']+)'/, csp(conn))
      assert hash == Base.encode64(:crypto.hash(:sha256, css))
    end
  end

  describe "N3/N4 — Allow is described by the hint, the destination and every RENDERED warning block (and only those)" do
    test "fresh login, destination inside the app website: arm-hint consent-destination-label consent-destination, nothing else", %{cid: cid, uid: uid} do
      b = get_page(T.insert_consent!(cid, user_id: uid, device_id: "DESC000001", login_fresh: true)).resp_body
      ids = allow_describedby(b)
      assert ids == ["arm-hint", "consent-destination-label", "consent-destination"]
      assert_ids_exist(b, ids)
      refute b =~ "freshness-notice" or b =~ "destination-notice" or b =~ "replace-notice"
    end

    test "UX N4: the destination <dt id=consent-destination-label> names the value; Allow is described by the label first", %{cid: cid, uid: uid} do
      b = get_page(T.insert_consent!(cid, user_id: uid)).resp_body
      assert [dt] = Regex.scan(~r/<dt\b[^>]*id="consent-destination-label"[^>]*>.*?<\/dt>/s, b) |> Enum.map(&hd/1)
      assert plain(dt) =~ "After you choose, you are sent to"
      assert Enum.take(allow_describedby(b), 3) == ["arm-hint", "consent-destination-label", "consent-destination"]
    end

    test "the destination <dd class=key id=consent-destination> carries the redirect target", %{cid: cid, uid: uid} do
      b = get_page(T.insert_consent!(cid, user_id: uid)).resp_body
      assert [dd] = Regex.scan(~r/<dd\b[^>]*id="consent-destination"[^>]*>.*?<\/dd>/s, b) |> Enum.map(&hd/1)
      assert dd =~ ~s(class="key")
      assert plain(dd) =~ "app.example.com"
    end

    test "stale login + foreign destination + replaced session: all three notice ids, each id exists once", %{uid: uid} do
      cid = T.oauth_client!([@https, "https://evil.example.net/cb"], client_uri: @website)
      dev = "DESC000002"
      :ok = Nebu.Matrix.DeviceKeyStore.upsert_device(uid, dev, display_name: "Old Element", last_seen_ts: System.system_time(:millisecond))
      _legacy = T.legacy_session!(uid, dev)
      b = get_page(T.insert_consent!(cid, user_id: uid, device_id: dev, login_fresh: false, redirect_uri: "https://evil.example.net/cb")).resp_body

      ids = allow_describedby(b)
      assert Enum.take(ids, 3) == ["arm-hint", "consent-destination-label", "consent-destination"]
      assert Enum.sort(Enum.drop(ids, 3)) == ["destination-notice", "freshness-notice", "replace-notice"]
      assert_ids_exist(b, ids)

      for {role, id} <- [{"freshness-notice", "freshness-notice"}, {"destination-notice", "destination-notice"}, {"replace-notice", "replace-notice"}] do
        assert [tag] = Regex.scan(~r/<p\b[^>]*data-role="#{role}"[^>]*>/, b) |> Enum.map(&hd/1)
        assert tag =~ ~s(id="#{id}"), "the existing data-role keeps its hook and gains the id"
        assert tag =~ ~s(class="notice")
      end
    end

    test "each notice alone adds only its own id", %{uid: uid} do
      cid = T.oauth_client!([@https, "https://evil.example.net/cb"], client_uri: @website)

      stale = allow_describedby(get_page(T.insert_consent!(cid, user_id: uid, device_id: "DESC000003", login_fresh: false)).resp_body)
      assert stale == ["arm-hint", "consent-destination-label", "consent-destination", "freshness-notice"]

      foreign = get_page(T.insert_consent!(cid, user_id: uid, device_id: "DESC000004", login_fresh: true, redirect_uri: "https://evil.example.net/cb")).resp_body
      assert allow_describedby(foreign) == ["arm-hint", "consent-destination-label", "consent-destination", "destination-notice"]

      dev = "DESC000005"
      :ok = Nebu.Matrix.DeviceKeyStore.upsert_device(uid, dev, display_name: "Dormant", last_seen_ts: System.system_time(:millisecond))
      replaced = get_page(T.insert_consent!(cid, user_id: uid, device_id: dev, login_fresh: true)).resp_body
      assert allow_describedby(replaced) == ["arm-hint", "consent-destination-label", "consent-destination", "replace-notice"]
    end

    test "aria-describedby never names an id that is not in the page (nil freshness, loopback, private scheme)" do
      page = fn assigns ->
        {:ok, conn} =
          apply(Nebu.OAuth.ConsentPage, :send_page, [
            Plug.Test.conn(:get, "/oauth2/consent"),
            Map.merge(%{user_id: "@u:test.local", client_metadata: %{}, redirect_uri: @https, device_id: "D1", device: :new, login_fresh: true, csrf_token: "t"}, assigns)
          ])

        conn.resp_body
      end

      for assigns <- [%{login_fresh: nil}, %{redirect_uri: "http://localhost:53682/cb"}, %{redirect_uri: "com.example.app:/cb"}, %{client_metadata: %{"client_uri" => @website}}] do
        b = page.(assigns)
        assert_ids_exist(b, allow_describedby(b))
      end

      assert allow_describedby(page.(%{login_fresh: nil})) == ["arm-hint", "consent-destination-label", "consent-destination", "freshness-notice"]
      assert allow_describedby(page.(%{redirect_uri: "http://localhost:53682/cb"})) == ["arm-hint", "consent-destination-label", "consent-destination"]
    end
  end

  describe "L-5 — the website line and the destination warning" do
    test "an https destination that is NOT part of the claimed website gets an explicit warning; a matching one does not", %{uid: uid} do
      cid = T.oauth_client!(["https://app.example.com/cb", "https://evil.example.net/cb"], client_uri: @website)
      bad = get_page(T.insert_consent!(cid, user_id: uid, redirect_uri: "https://evil.example.net/cb"))
      assert bad.resp_body =~ ~s(data-role="destination-notice")
      t = plain(bad.resp_body)
      assert t =~ "You are sent to evil.example.net, which does not belong to the website this app names (app.example.com)."
      refute t =~ "(part of the app website)"

      good = get_page(T.insert_consent!(cid, user_id: uid, redirect_uri: @https))
      refute good.resp_body =~ "destination-notice"
    end

    test "a bare public suffix as the claimed website never makes a host 'part of the app website'", %{uid: uid} do
      for site <- ["https://github.io", "https://co.uk"] do
        cid = T.oauth_client!(["https://evil" <> String.replace(site, "https://", ".") <> "/cb"], client_uri: site)
        redirect = "https://evil" <> String.replace(site, "https://", ".") <> "/cb"
        conn = get_page(T.insert_consent!(cid, user_id: uid, redirect_uri: redirect))
        refute plain(conn.resp_body) =~ "(part of the app website)", site
        assert conn.resp_body =~ "destination-notice", site
      end
    end

    test "the replaced-session warning is its own labelled block before the form, device name first", %{cid: cid, uid: uid} do
      dev = "WARN000001"
      :ok = Nebu.Matrix.DeviceKeyStore.upsert_device(uid, dev, display_name: "Phil's Pixel", last_seen_ts: System.system_time(:millisecond))
      _legacy = T.legacy_session!(uid, dev)
      b = get_page(T.insert_consent!(cid, user_id: uid, device_id: dev)).resp_body
      assert b =~ ~s(data-role="replace-notice")
      assert plain(b) =~ "Warning: Another session will be signed out: Phil&#39;s Pixel (device WARN000001)."
      assert :binary.match(b, "replace-notice") < :binary.match(b, "<form")
      same = get_page(T.insert_consent!(cid, user_id: uid, device_id: "WARN000002")).resp_body
      refute same =~ "replace-notice"
    end

    test "a very long display name of the replaced device is cut at 80 characters", %{cid: cid, uid: uid} do
      dev = "LONG000001"
      long = String.duplicate("N", 200)
      :ok = Nebu.Matrix.DeviceKeyStore.upsert_device(uid, dev, display_name: long, last_seen_ts: System.system_time(:millisecond))
      _legacy = T.legacy_session!(uid, dev)
      b = get_page(T.insert_consent!(cid, user_id: uid, device_id: dev)).resp_body
      refute b =~ String.duplicate("N", 81)
      assert b =~ String.duplicate("N", 80) <> "..."
    end

    test "the freshness notice is shown for ANYTHING but an exactly-fresh login (a nil can never hide it)" do
      page = fn fresh ->
        {:ok, conn} =
          apply(Nebu.OAuth.ConsentPage, :send_page, [
            Plug.Test.conn(:get, "/oauth2/consent"),
            %{user_id: "@u:test.local", client_metadata: %{}, redirect_uri: @https, device_id: "D1", device: :new, login_fresh: fresh, csrf_token: "t"}
          ])

        conn.resp_body
      end

      assert page.(nil) =~ "freshness-notice"
      assert page.(false) =~ "freshness-notice"
      refute page.(true) =~ "freshness-notice"
      assert page.(nil) =~ ~s(data-fresh="false")
    end
  end
end
