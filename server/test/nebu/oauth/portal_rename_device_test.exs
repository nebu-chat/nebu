defmodule Nebu.OAuth.PortalRenameDeviceTest do
  @moduledoc """
  ATDD for story `06-portal-rename-device` (REQ-2026-021) — Rename a device in the account portal.

  One test per Gherkin scenario, tagged `@tag ac: "<scenario-slug>"`, plus oracle tests tagged `@tag ac: "oracle-<slug>"`. Red until the story is implemented.

  HTTP level through the real router (`Nebu.OAuth.TestSupport` helpers: `account_session!/2`, `account_get/2`, `account_post/3`, real OAuth device sessions
  for the Matrix side, `Nebu.OAuth.DeviceNameTestSupport` for the device rows and the Matrix device API). The portal sessions are inserted directly, so the
  CSRF token is the one `account_session!/2` returns (never the one rendered on a page).

  ## The contract this story pins (names are the ATDD agent's; the dev may deviate only with a story Decisions note)

    * `GET /account/devices/rename?device_id=<id>` — the rename page of ONE device of the signed-in user: `<main data-page="account" data-action="device_rename">`,
      one `<h1>`, ONE `<form data-role="rename-device-form" method="post" action="/account/devices/rename">` with the hidden fields `csrf_token` and
      `device_id`, a visible `<label for=ID>` tied to the text input `<input type="text" name="device_name" id=ID>`, and one `class="actions"` container
      that holds Save (`<button data-role="rename-save">`) and Cancel (`<a data-role="rename-cancel" href="/account?action=org.matrix.devices_list">`). The
      shared page shell supplies the 44 px controls and the focus ring. A stale session gets the `data-role="reauth"` link instead of the form (like the
      sign-out confirmation); a session without `auth_time` gets `data-notice="freshness_unavailable"`, no reauth link, no form. A device that is not the
      user's or does not exist: `303` to the devices list with the notice `device_not_found`.
    * `POST /account/devices/rename` with `device_id`, `device_name`, `csrf_token` — the same CSRF / Origin / Sec-Fetch rules and the same order of checks
      as `POST /account/devices/delete`. Every outcome is a `303` to `/account?action=org.matrix.devices_list&notice=<code>`:
      `device_renamed` (stored), `device_name_invalid` (nothing left after sanitising: the old name stays), `device_not_found` (foreign or unknown device:
      zero rows of any user change), `stale` (session `auth_time` older than 5 minutes: nothing changes), `freshness_unavailable` (no `auth_time`: nothing
      changes, no reauth link).
    * Sanitising of `device_name` (Matrix domain, never trusted from the page): markup tags removed, control / format / invisible characters removed,
      surrounding whitespace trimmed, cut to 64 CODE POINTS (not bytes). Stored in the one `devices.display_name` column, so Matrix `GET /devices`,
      `GET /devices/{id}`, `POST /keys/query` (`unsigned.device_display_name`) and the admin user page (`Nebu.Matrix.list_user_devices/1`) show the same
      name. The write goes through `Nebu.Matrix.DeviceKeyStore.rename_device/3` (or keeps its stamp): a keyed device advances the device-list stream.
      A client `PUT /devices/{id}` afterwards still replaces the name (last write wins).
    * The user id comes from the verified portal session only (a new public function of `Nebu.Matrix`, the dev picks the name, e.g. `account_rename_device/3`).
    * Device list cards carry a rename link `data-role="device-row-rename"` to the rename page of that device.
    * Catalog (`Nebu.Web.PageText`): `acct.notice.device_renamed` and `acct.notice.device_name_invalid` in en and de; every text of the rename page comes from it.

  Crash/restart — NOT APPLICABLE (no process state: one SQL update through the existing store).
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  alias Nebu.Matrix.{DeviceKeyStore, DeviceListStore}
  alias Nebu.OAuth.DeviceNameTestSupport, as: DN
  alias Nebu.OAuth.TestSupport, as: T
  alias Nebu.Web.PageText

  @https "https://app.example.com/cb"
  @old_name "OAuth client (CdEfGhIj)"
  @devices_href "/account?action=org.matrix.devices_list"

  setup do
    T.enable_oauth()
    T.reset_rate_limits()
    priv = T.setup_idp!()

    on_exit(fn ->
      T.clear_oauth_config()
      T.restore_rate_limits()
      for k <- [:oauth_repo, :oauth_session_repo, :account_matrix_repo], do: Application.delete_env(:nebu_http, k)
    end)

    cid = T.oauth_client!([@https])
    sub = T.unique_sub()
    uid = T.provision_user!(sub)
    s = T.oauth_device!(cid, @https, priv, sub, dev())
    other = T.oauth_device!(cid, @https, priv, sub, dev())
    :ok = DeviceKeyStore.rename_device(uid, s.device_id, @old_name)

    {:ok, priv: priv, cid: cid, sub: sub, uid: uid, s: s, other: other}
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp dev, do: "RN" <> String.upcase(T.rand(4))
  defp now, do: System.system_time(:second)
  defp rename_path(device_id), do: "/account/devices/rename?device_id=" <> URI.encode_www_form(device_id)

  defp rename(acct, device_id, name, opts \\ []) do
    T.account_post("/account/devices/rename", [{"device_id", device_id}, {"device_name", name}, {"csrf_token", acct.csrf}], [cookie: acct.cookie] ++ opts)
  end

  # the page the 303 points at, with the same session
  defp follow(conn, acct, opts \\ []) do
    assert conn.status == 303, "expected a 303, got #{conn.status}: #{String.slice(conn.resp_body || "", 0, 300)}"
    T.account_get(T.location(conn), [cookie: acct.cookie] ++ opts)
  end

  defp stored(ctx, device_id), do: DN.name_of(ctx.uid, device_id)

  defp card_name(body, device_id) do
    case Regex.run(~r/data-device-id="#{Regex.escape(device_id)}".*?data-role="device-name"[^>]*>([^<]*)</s, body) do
      [_, name] -> String.trim(name)
      _ -> flunk("no device card for #{device_id} in the devices page")
    end
  end

  defp matrix_name(at, device_id) do
    at |> DN.list_devices!() |> Enum.find(&(&1["device_id"] == device_id)) |> Kernel.||(flunk("device #{device_id} not in GET /devices")) |> Map.get("display_name")
  end

  defp admin_name(user_id, device_id) do
    user_id |> Nebu.Matrix.list_user_devices() |> Enum.find(&(&1["device_id"] == device_id)) |> Kernel.||(flunk("device #{device_id} not in the admin list")) |> Map.get("display_name")
  end

  defp visible_text(body), do: body |> String.replace(~r/<style>.*?<\/style>/s, "") |> String.replace(~r/<[^>]+>/, " ") |> String.replace(~r/\s+/, " ")

  defp foreign_device(ctx) do
    sub = T.unique_sub()
    uid = T.provision_user!(sub)
    d = T.oauth_device!(ctx.cid, @https, ctx.priv, sub, dev())
    :ok = DeviceKeyStore.rename_device(uid, d.device_id, "Foreign " <> T.rand(3))
    %{uid: uid, s: d, name: DN.name_of(uid, d.device_id), at: d.at}
  end

  # ── scenarios ──────────────────────────────────────────────────────────────

  # Scenario: A fresh user renames a device
  #   Given a user signed in to the portal within the last 5 minutes with a device named "OAuth client (CdEfGhIj)"
  #   When the user opens Rename on that device, enters "Annas Handy" and saves
  #   Then the device list shows "Annas Handy" with the notice "device_renamed", and Matrix GET /devices and the admin user page show the same name
  @tag ac: "a-fresh-user-renames-a-device"
  test "Scenario: A fresh user renames a device", ctx do
    acct = T.account_session!(ctx.uid, auth_time: now() - 30)
    other_before = stored(ctx, ctx.other.device_id)

    # the devices list offers Rename on that device's card
    list = T.account_get(@devices_href, cookie: acct.cookie)
    T.assert_account_page(list, "org.matrix.devices_list")
    assert list.resp_body =~ ~r/data-role="device-row-rename"/, "every device card carries a Rename link"
    assert list.resp_body =~ ctx.s.device_id

    # the rename page shows the form for THIS device
    page = T.account_get(rename_path(ctx.s.device_id), cookie: acct.cookie)
    T.assert_account_page(page, "device_rename")
    assert page.resp_body =~ ~s(data-role="rename-device-form")
    assert page.resp_body =~ ~s(name="device_name")
    assert page.resp_body =~ ctx.s.device_id
    assert page.resp_body =~ @old_name, "the form starts from the current name"

    conn = rename(acct, ctx.s.device_id, "Annas Handy")
    assert conn.status == 303 and T.notice_of(conn) == "device_renamed", "got #{conn.status} #{inspect(T.location(conn))}"
    assert URI.parse(T.location(conn)).path == "/account"
    assert T.location(conn) =~ "org.matrix.devices_list"

    after_page = follow(conn, acct)
    T.assert_account_page(after_page, "org.matrix.devices_list")
    assert after_page.resp_body =~ ~s(data-notice="device_renamed")
    assert card_name(after_page.resp_body, ctx.s.device_id) == "Annas Handy"

    assert stored(ctx, ctx.s.device_id) == "Annas Handy"
    assert matrix_name(ctx.s.at, ctx.s.device_id) == "Annas Handy"
    assert DN.get_device!(ctx.s.at, ctx.s.device_id)["display_name"] == "Annas Handy"
    assert admin_name(ctx.uid, ctx.s.device_id) == "Annas Handy"
    assert stored(ctx, ctx.other.device_id) == other_before, "the user's other device is untouched"
  end

  # Scenario: A stale session must confirm first and nothing changes
  #   Given a user whose portal sign-in is older than 5 minutes
  #   When the user submits a rename
  #   Then the response is a 303 with notice "stale" and the "Confirm it is you" link, and the device name is unchanged
  @tag ac: "a-stale-session-must-confirm-first-and-nothing-changes"
  test "Scenario: A stale session must confirm first and nothing changes", ctx do
    acct = T.account_session!(ctx.uid, auth_time: now() - 400)
    before = {T.device_fingerprint(ctx.uid, ctx.s.device_id), T.world_snapshot([ctx.uid])}

    # the page offers the re-authentication link instead of the form
    page = T.account_get(rename_path(ctx.s.device_id), cookie: acct.cookie)
    T.assert_account_page(page, "device_rename")
    assert page.resp_body =~ ~s(data-role="reauth")
    refute page.resp_body =~ ~s(data-role="rename-device-form")

    # a POST anyway: stale, nothing changes, and the page it lands on carries the link
    conn = rename(acct, ctx.s.device_id, "Sneaky name")
    assert conn.status == 303 and T.notice_of(conn) == "stale", "got #{conn.status} #{inspect(T.location(conn))}"
    landed = follow(conn, acct)
    assert landed.resp_body =~ ~s(data-notice="stale")
    assert landed.resp_body =~ ~r/data-role="reauth"/, "the stale notice comes with the 'Confirm it is you' link"

    assert stored(ctx, ctx.s.device_id) == @old_name
    assert {T.device_fingerprint(ctx.uid, ctx.s.device_id), T.world_snapshot([ctx.uid])} == before
  end

  # Scenario: Another user's device cannot be renamed
  #   Given a device id that belongs to another user, or does not exist
  #   When the portal user submits a rename for it
  #   Then the notice "device_not_found" is shown and no device of any user is changed
  @tag ac: "another-user-s-device-cannot-be-renamed"
  test "Scenario: Another user's device cannot be renamed", ctx do
    f = foreign_device(ctx)
    acct = T.account_session!(ctx.uid)

    before = %{
      own: T.device_fingerprint(ctx.uid, ctx.s.device_id),
      own_other: T.device_fingerprint(ctx.uid, ctx.other.device_id),
      foreign: T.device_fingerprint(f.uid, f.s.device_id),
      names: {DN.names_of(ctx.uid), DN.names_of(f.uid)}
    }

    for id <- [f.s.device_id, "UNKNOWN" <> String.upcase(T.rand(3))] do
      conn = rename(acct, id, "Taken over")
      assert conn.status == 303 and T.notice_of(conn) == "device_not_found", "#{id}: got #{conn.status} #{inspect(T.location(conn))}"
      assert follow(conn, acct).resp_body =~ ~s(data-notice="device_not_found")
    end

    assert %{
             own: T.device_fingerprint(ctx.uid, ctx.s.device_id),
             own_other: T.device_fingerprint(ctx.uid, ctx.other.device_id),
             foreign: T.device_fingerprint(f.uid, f.s.device_id),
             names: {DN.names_of(ctx.uid), DN.names_of(f.uid)}
           } == before

    assert matrix_name(f.at, f.s.device_id) == f.name, "the other user's GET /devices is unchanged"
  end

  # Scenario: A hostile or empty name is sanitised or refused
  #   Given the rename form of a device
  #   When the user submits "<b>Work\u0007 laptop</b>", then a name of only invisible characters, then a 500 character name
  #   Then the names are stored as "Work laptop" and cut to 64 code points respectively, the invisible-only name is refused with "device_name_invalid" and the old name stays
  @tag ac: "a-hostile-or-empty-name-is-sanitised-or-refused"
  test "Scenario: A hostile or empty name is sanitised or refused", ctx do
    acct = T.account_session!(ctx.uid)
    id = ctx.s.device_id

    # markup and a control character: sanitised, stored
    conn = rename(acct, id, "<b>Work\u0007 laptop</b>")
    assert conn.status == 303 and T.notice_of(conn) == "device_renamed", "got #{conn.status} #{inspect(T.location(conn))}"
    assert stored(ctx, id) == "Work laptop"
    refute follow(conn, acct).resp_body =~ "<b>Work"

    # nothing visible left: refused, the old name stays (also after a refused form of every invisible kind)
    for invisible <- ["\u200B\u200D\u2060", "   ", "\u0007\u0008", "\u00AD\uFEFF", "<i></i>", "\u2028\u2029", ""] do
      conn = rename(acct, id, invisible)
      assert conn.status == 303 and T.notice_of(conn) == "device_name_invalid", "#{inspect(invisible)}: got #{conn.status} #{inspect(T.location(conn))}"
      assert follow(conn, acct).resp_body =~ ~s(data-notice="device_name_invalid")
      assert stored(ctx, id) == "Work laptop", "#{inspect(invisible)} must not change the name"
    end

    # 500 characters: cut to 64 CODE POINTS (multi-byte on purpose), never to 64 bytes
    for {long, expected} <- [{String.duplicate("ä", 500), String.duplicate("ä", 64)}, {String.duplicate("日本", 250), String.duplicate("日本", 32)}] do
      conn = rename(acct, id, long)
      assert conn.status == 303 and T.notice_of(conn) == "device_renamed"
      assert stored(ctx, id) == expected
      assert DN.codepoints(stored(ctx, id)) == 64
    end

    # a script tag: no markup survives anywhere
    conn = rename(acct, id, "<script>alert(1)</script>Pixel 8")
    assert T.notice_of(conn) == "device_renamed"
    name = stored(ctx, id)
    refute DN.hostile?(name), "stored name must be clean, got #{inspect(name)}"
    assert name =~ "Pixel 8"
    assert matrix_name(ctx.s.at, id) == name
  end

  # Scenario: The rename page is accessible and works in both languages
  #   Given the rename page in German and in English at 390 px and without JavaScript
  #   When it is rendered
  #   Then it has one main and one h1, a label tied to the field, a visible focus ring, 44 px controls, Cancel next to Save, and every text comes from the catalog
  @tag ac: "the-rename-page-is-accessible-and-works-in-both-languages"
  test "Scenario: The rename page is accessible and works in both languages", ctx do
    acct = T.account_session!(ctx.uid)

    for {lang, accept, save, cancel, foreign_words} <- [
          {:en, "en", "Save", "Cancel", []},
          {:de, "de", "Speichern", "Abbrechen", ["Cancel", "Save", "Rename", "Device name", "Back to"]}
        ] do
      page = T.account_get(rename_path(ctx.s.device_id), cookie: acct.cookie, headers: [{"accept-language", accept}])
      T.assert_account_page(page, "device_rename")
      body = page.resp_body
      where = "[#{lang}]"

      assert body =~ ~s(<html lang="#{accept}"), "#{where} html lang"
      assert length(Regex.scan(~r/<main[\s>]/, body)) == 1, "#{where} exactly one main"
      assert length(Regex.scan(~r/<h1[\s>]/, body)) == 1, "#{where} exactly one h1"
      assert length(Regex.scan(~r/<form[\s>]/, body)) >= 1
      assert length(Regex.scan(~r/data-role="rename-device-form"/, body)) == 1

      # a label tied to the field
      [_, input] = Regex.run(~r/(<input[^>]*name="device_name"[^>]*>)/, body) || flunk("#{where} no device_name input")
      [_, field_id] = Regex.run(~r/\sid="([^"]+)"/, input) || flunk("#{where} the field has no id: #{input}")
      assert body =~ ~r/<label[^>]*\sfor="#{Regex.escape(field_id)}"[^>]*>\s*[^<\s]/, "#{where} a label with text is tied to the field"
      assert input =~ ~r/type="text"/

      # Save and Cancel side by side in ONE actions container, Cancel back to the list
      [_, actions] = Regex.run(~r/class="actions"[^>]*>(.*?)<\/div>/s, body) || flunk("#{where} no .actions container")
      assert actions =~ ~r/<button[^>]*data-role="rename-save"[^>]*>\s*#{save}\s*</, "#{where} Save"
      assert actions =~ ~r/<a[^>]*data-role="rename-cancel"[^>]*>\s*#{cancel}\s*</, "#{where} Cancel"
      assert actions =~ ~s(href="#{@devices_href}"), "#{where} Cancel goes back to the devices list"

      # focus ring and 44 px controls from the shared shell, a strict page without script
      assert body =~ ":focus-visible"
      assert body =~ "min-height:44px"
      refute body =~ "<script", "#{where} works without JavaScript"
      assert body =~ "width=device-width", "#{where} responsive viewport (390 px)"

      # every text comes from the catalog: no English UI text on the German page
      for w <- foreign_words, do: refute(visible_text(body) =~ w, "#{where} English text #{inspect(w)} on the German page")

      # the notices of the story are in the catalog and shown in the page language
      for key <- ["acct.notice.device_renamed", "acct.notice.device_name_invalid"] do
        assert key in PageText.keys(), "catalog key #{key}"
        text = PageText.fetch!(key, lang)
        assert String.trim(text) != "", "catalog key #{key} (#{lang})"
        refute text == PageText.fetch!(key, if(lang == :en, do: :de, else: :en)), "#{key} is translated"
      end

      conn = rename(acct, ctx.s.device_id, "Handy " <> accept, headers: [{"accept-language", accept}])
      landed = follow(conn, acct, headers: [{"accept-language", accept}])
      assert landed.resp_body =~ Plug.HTML.html_escape(PageText.fetch!("acct.notice.device_renamed", lang)), "#{where} notice text from the catalog"
    end
  end

  # ── oracle (Matrix spec v1.18 + the portal rules) ──────────────────────────

  # GET /devices: "display_name ... absent if no name has been set"; the portal never stores an empty name; whitespace is trimmed
  @tag ac: "oracle-name-trimmed-and-never-empty"
  test "oracle: surrounding whitespace is trimmed and an empty name is never stored", ctx do
    acct = T.account_session!(ctx.uid)
    conn = rename(acct, ctx.s.device_id, "   Annas Handy \t")
    assert T.notice_of(conn) == "device_renamed"
    assert matrix_name(ctx.s.at, ctx.s.device_id) == "Annas Handy"

    missing = T.account_post("/account/devices/rename", [{"device_id", ctx.s.device_id}, {"csrf_token", acct.csrf}], cookie: acct.cookie)
    assert missing.status == 303 and T.notice_of(missing) == "device_name_invalid", "a form without device_name is refused, got #{missing.status}"
    assert matrix_name(ctx.s.at, ctx.s.device_id) == "Annas Handy"
  end

  # PUT /devices/{id}: 200 overwrites ("last write wins"); client rename afterwards replaces the portal name
  @tag ac: "oracle-client-put-after-portal-rename"
  test "oracle: portal rename, then a client PUT replaces the name, then a portal rename replaces it again", ctx do
    acct = T.account_session!(ctx.uid)
    assert T.notice_of(rename(acct, ctx.s.device_id, "Portal name")) == "device_renamed"
    assert matrix_name(ctx.s.at, ctx.s.device_id) == "Portal name"

    :ok = DN.put_name!(ctx.s.at, ctx.s.device_id, "Client name")
    assert matrix_name(ctx.s.at, ctx.s.device_id) == "Client name"

    assert T.notice_of(rename(acct, ctx.s.device_id, "Portal again")) == "device_renamed"
    assert stored(ctx, ctx.s.device_id) == "Portal again"
  end

  # PUT for a device the user does not own -> 404 (regression: the portal path must not loosen it)
  @tag ac: "oracle-put-foreign-device-404"
  test "oracle: after a portal rename a client PUT for another user's device is still 404 and changes nothing", ctx do
    f = foreign_device(ctx)
    acct = T.account_session!(ctx.uid)
    assert T.notice_of(rename(acct, ctx.s.device_id, "Mine")) == "device_renamed"

    conn = T.matrix_request(:put, "/_matrix/client/v3/devices/" <> URI.encode_www_form(f.s.device_id), ctx.s.at, body: %{"display_name" => "Hijack"})
    assert conn.status == 404, "got #{conn.status}: #{conn.resp_body}"
    assert DN.name_of(f.uid, f.s.device_id) == f.name
  end

  # POST /keys/query unsigned.device_display_name + the device-list change for a keyed device
  @tag ac: "oracle-keyed-device-list-change-and-keys-query"
  test "oracle: renaming a keyed device advances the device-list stream and /keys/query shows the new name", ctx do
    T.seed_device_keys!(ctx.uid, ctx.s.device_id)
    acct = T.account_session!(ctx.uid)
    {:ok, pos_before} = DeviceListStore.position()

    assert T.notice_of(rename(acct, ctx.s.device_id, "Keyed laptop")) == "device_renamed"

    {:ok, pos_after} = DeviceListStore.position()
    assert pos_after > pos_before, "a rename of a device with identity keys is a device-list change (peers must refresh the name)"

    q = T.matrix_request(:post, "/_matrix/client/v3/keys/query", ctx.s.at, body: %{"device_keys" => %{ctx.uid => []}})
    assert q.status == 200
    assert get_in(T.json(q), ["device_keys", ctx.uid, ctx.s.device_id, "unsigned", "device_display_name"]) == "Keyed laptop"
  end

  # FR14: no auth_time is told apart from a stale one: no reauth link (a loop), no change
  @tag ac: "oracle-freshness-unavailable"
  test "oracle: a session without auth_time gets freshness_unavailable, no reauth link, no change", ctx do
    acct = T.account_session!(ctx.uid, auth_time: nil)

    page = T.account_get(rename_path(ctx.s.device_id), cookie: acct.cookie)
    T.assert_account_page(page, "device_rename")
    assert page.resp_body =~ ~s(data-notice="freshness_unavailable")
    refute page.resp_body =~ ~s(data-role="reauth")
    refute page.resp_body =~ ~s(data-role="rename-device-form")

    conn = rename(acct, ctx.s.device_id, "No way")
    assert conn.status == 303 and T.notice_of(conn) == "freshness_unavailable", "got #{conn.status} #{inspect(T.location(conn))}"
    refute follow(conn, acct).resp_body =~ ~s(data-role="reauth")
    assert stored(ctx, ctx.s.device_id) == @old_name
  end

  # 300 s boundary of the freshness rule (same as sign-out): 290 s ago renames, 300 s ago is stale
  @tag ac: "oracle-freshness-boundary"
  test "oracle: auth_time 290 s ago renames, 300 s ago is stale", ctx do
    fresh = T.account_session!(ctx.uid, auth_time: now() - 290)
    assert T.notice_of(rename(fresh, ctx.s.device_id, "Just in time")) == "device_renamed"

    stale = T.account_session!(ctx.uid, auth_time: now() - 300)
    assert T.notice_of(rename(stale, ctx.s.device_id, "Too late")) == "stale"
    assert stored(ctx, ctx.s.device_id) == "Just in time"
  end

  # the page of a foreign or unknown device is never rendered
  @tag ac: "oracle-rename-page-foreign-device"
  test "oracle: the rename page of another user's or an unknown device is a device_not_found redirect", ctx do
    f = foreign_device(ctx)
    acct = T.account_session!(ctx.uid)

    for id <- [f.s.device_id, "UNKNOWN" <> String.upcase(T.rand(3))] do
      conn = T.account_get(rename_path(id), cookie: acct.cookie)
      assert conn.status == 303 and T.notice_of(conn) == "device_not_found", "#{id}: got #{conn.status}"
      refute conn.resp_body =~ f.name
    end
  end

  # M3: CSRF on every POST endpoint, no session => sign-in, never a write
  @tag ac: "oracle-csrf-and-session"
  test "oracle: a wrong CSRF token is refused (403 forbidden), no session starts the sign-in, nothing changes", ctx do
    acct = T.account_session!(ctx.uid)
    before = T.device_fingerprint(ctx.uid, ctx.s.device_id)

    wrong = T.account_post("/account/devices/rename", [{"device_id", ctx.s.device_id}, {"device_name", "Evil"}, {"csrf_token", "wrong"}], cookie: acct.cookie)
    T.assert_account_error(wrong, 403, "forbidden")

    foreign_origin = rename(acct, ctx.s.device_id, "Evil", headers: [{"origin", "https://evil.example.com"}])
    T.assert_account_error(foreign_origin, 403, "forbidden")

    anonymous = T.account_post("/account/devices/rename", [{"device_id", ctx.s.device_id}, {"device_name", "Evil"}, {"csrf_token", acct.csrf}])
    assert anonymous.status == 302, "no account session: redirect to the IdP, got #{anonymous.status}"

    assert T.device_fingerprint(ctx.uid, ctx.s.device_id) == before
    assert stored(ctx, ctx.s.device_id) == @old_name
  end
end
