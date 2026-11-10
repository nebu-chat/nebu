defmodule Nebu.OAuth.DeviceNameFlowTest do
  @moduledoc """
  Story `oauth-device-default-display-name` (REQ-2026-004), scenarios 1 - 5 through the REAL flow (authorize -> IdP stub -> consent -> code -> token endpoint)
  and the real Matrix device API (`GET` / `PUT /devices`), real database, `--include integration`. The pure rules (sanitising table, bound, suffix) are in
  `device_name_test.exs`.

  Decisions pinned here (story `## Decisions`):

    * The default is written in the issuance transaction of the token endpoint, for a device whose stored display name is UNSET (`NULL`) only. A name that
      exists (a client's `PUT /devices`, a legacy login's `initial_device_display_name`) is never overwritten, not by a re-login of the same device id and
      not by a refresh. An EMPTY string is a name the client chose (Matrix lets a client clear it) and is kept; a `NULL` name on an existing device
      (a legacy login without a name, a `PUT` without `display_name`) is filled at the next OAuth login of that device id.
    * The client's own `PUT /devices/{id}` after the login always replaces the default (the default is only a starting value).
    * No other channel names an OAuth device: parameters of the token request (`initial_device_display_name` and the like) are ignored.
    * The base comes from the approved client record only (`for_client/2`): a revoked / pending / rejected / unknown client, a record without a usable name,
      an unreadable database give the plain `"OAuth client"`; the login itself never fails because of the name.
    * Logs: the name is not logged (no new log line; the existing lines carry ids only).
    * Legacy and SSO logins (`POST /login`) are unchanged: the device carries `initial_device_display_name` or none; the OAuth default is never applied there.
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  import ExUnit.CaptureLog

  alias Nebu.OAuth.DeviceNameTestSupport, as: D
  alias Nebu.OAuth.TestSupport, as: T

  setup do
    {:ok, D.setup_env!()}
  end

  # ── scenario 1 ──────────────────────────────────────────────────────────────

  describe "scenario 1 - a new OAuth device without a client-supplied name gets the client name with a device suffix" do
    test "the story's example: client FluffyChat, device ABCD1234 => 'FluffyChat (ABCD1234)'", %{cid: cid, priv: priv} do
      s = D.session!(cid, priv, "ABCD1234")
      assert s.device_id == "ABCD1234"
      assert D.name_of(s.user_id, "ABCD1234") == "FluffyChat (ABCD1234)"
    end

    test "the name is in place when the token response arrives, and the client sees it in GET /devices and GET /devices/{id} (no PUT needed)", %{cid: cid, priv: priv} do
      s = D.session!(cid, priv, "ABCD1234")

      assert [%{"device_id" => "ABCD1234", "display_name" => "FluffyChat (ABCD1234)"}] = D.list_devices!(s.at)
      assert %{"device_id" => "ABCD1234", "display_name" => "FluffyChat (ABCD1234)"} = D.get_device!(s.at, "ABCD1234")
    end

    test "an Element style 10 character device id contributes its last 8 characters", %{cid: cid, priv: priv} do
      s = D.session!(cid, priv, "AbCdEfGhIj")
      assert D.name_of(s.user_id, "AbCdEfGhIj") == "FluffyChat (CdEfGhIj)"
    end

    test "the name is exactly what the pure function says for the client's name and the device id (flow and function agree)", %{cid: cid, priv: priv} do
      dev = D.device_id()
      s = D.session!(cid, priv, dev)
      assert D.name_of(s.user_id, dev) == D.default_name("FluffyChat", dev)
    end

    test "the name carries nothing of the user: not the subject, the Matrix user id or the client id", %{cid: cid, priv: priv} do
      s = D.session!(cid, priv, "ABCD1234")
      name = D.name_of(s.user_id, "ABCD1234")
      localpart = s.user_id |> String.trim_leading("@") |> String.split(":") |> hd()

      refute name =~ s.sub
      refute name =~ localpart
      refute name =~ s.user_id
      refute name =~ cid
    end

    test "the same client logging in twice (two devices of one user) yields two names that can be told apart by the id suffix", %{cid: cid, priv: priv} do
      sub = T.unique_sub()
      a = D.session!(cid, priv, "FIRSTDEV01", sub: sub)
      b = D.session!(cid, priv, "SECONDDEV2", sub: sub)

      names = D.names_of(a.user_id)
      assert names["FIRSTDEV01"] == "FluffyChat (RSTDEV01)"
      assert names["SECONDDEV2"] == "FluffyChat (CONDDEV2)"
      assert names["FIRSTDEV01"] != names["SECONDDEV2"]
      assert Enum.sort(Enum.map(D.list_devices!(b.at), & &1["display_name"])) == Enum.sort(Map.values(names))
    end

    test "two devices whose ids only differ in the front part are still told apart", %{cid: cid, priv: priv} do
      sub = T.unique_sub()
      a = D.session!(cid, priv, "aaaaaaaa-0001", sub: sub)
      _b = D.session!(cid, priv, "bbbbbbbb-0002", sub: sub)
      names = a.user_id |> D.names_of() |> Map.values() |> Enum.sort()
      assert names == ["FluffyChat (aaa-0001)", "FluffyChat (bbb-0002)"]
    end

    test "another approved client names its own devices with its own name", %{cid: cid, priv: priv} do
      other = D.client!("Element Web")
      sub = T.unique_sub()
      a = D.session!(cid, priv, "DEVICE0001", sub: sub)
      _b = D.session!(other, priv, "DEVICE0002", sub: sub)
      names = D.names_of(a.user_id)
      assert names["DEVICE0001"] == "FluffyChat (VICE0001)"
      assert names["DEVICE0002"] == "Element Web (VICE0002)"
    end

    test "two users, same client, same device id: each has their own row and name; each list shows only the own device", %{cid: cid, priv: priv} do
      a = D.session!(cid, priv, "SAMEDEV001")
      b = D.session!(cid, priv, "SAMEDEV001")
      refute a.user_id == b.user_id

      assert D.name_of(a.user_id, "SAMEDEV001") == "FluffyChat (MEDEV001)"
      assert D.name_of(b.user_id, "SAMEDEV001") == "FluffyChat (MEDEV001)"

      for s <- [a, b] do
        assert [%{"device_id" => "SAMEDEV001"}] = D.list_devices!(s.at)
      end

      assert T.sql!("SELECT count(*) FROM devices WHERE device_id = 'SAMEDEV001' AND user_id = ANY($1)", [[a.user_id, b.user_id]]).rows == [[2]]
    end

    test "no channel of the token request can name the device: initial_device_display_name and similar parameters are ignored", %{cid: cid, priv: priv} do
      grant = T.flow_code!(cid, D.redirect(), priv, authorize: %{"scope" => T.js_sdk_scope("PARAMDEV01"), "nonce" => "n-" <> T.rand()})

      body =
        T.redeem!(grant, %{
          "initial_device_display_name" => "Injected Name",
          "device_display_name" => "Injected Name",
          "display_name" => "Injected Name"
        })

      assert is_binary(body["access_token"])
      assert D.name_of(grant.user_id, "PARAMDEV01") == "FluffyChat (RAMDEV01)"
    end

    test "a refresh never touches the name (default stays, no second suffix, no rewrite)", %{cid: cid, priv: priv} do
      s = D.session!(cid, priv, "REFRESHDEV")
      before = D.device_row(s.user_id, "REFRESHDEV")
      T.idp_refresh_ok(s.sub)

      body = T.refresh!(cid, s.rt)
      body2 = T.refresh!(cid, body["refresh_token"])
      assert is_binary(body2["access_token"])

      after_row = D.device_row(s.user_id, "REFRESHDEV")
      assert before["display_name"] == "FluffyChat (FRESHDEV)"
      assert after_row["display_name"] == "FluffyChat (FRESHDEV)"
    end
  end

  # ── scenario 2 ──────────────────────────────────────────────────────────────

  describe "scenario 2 - an existing device name is kept on re-login with the same device id" do
    test "the client named the device 'My phone' (PUT /devices); a new OAuth login with the same device id keeps it", %{cid: cid, priv: priv} do
      sub = T.unique_sub()
      first = D.session!(cid, priv, "ABCD1234", sub: sub)
      assert D.name_of(first.user_id, "ABCD1234") == "FluffyChat (ABCD1234)"
      D.put_name!(first.at, "ABCD1234", "My phone")

      second = D.session!(cid, priv, "ABCD1234", sub: sub)
      assert second.user_id == first.user_id
      assert D.name_of(first.user_id, "ABCD1234") == "My phone"
      assert [%{"device_id" => "ABCD1234", "display_name" => "My phone"}] = D.list_devices!(second.at)

      third = D.session!(cid, priv, "ABCD1234", sub: sub)
      assert D.name_of(third.user_id, "ABCD1234") == "My phone", "every further login keeps it"
    end

    test "the client's PUT after the login replaces the default and survives a refresh", %{cid: cid, priv: priv} do
      s = D.session!(cid, priv, "RENAMEDEV1")
      assert D.name_of(s.user_id, "RENAMEDEV1") =~ "FluffyChat ("
      D.put_name!(s.at, "RENAMEDEV1", "Work laptop")
      assert D.name_of(s.user_id, "RENAMEDEV1") == "Work laptop"

      T.idp_refresh_ok(s.sub)
      refreshed = T.refresh!(cid, s.rt)
      assert D.name_of(s.user_id, "RENAMEDEV1") == "Work laptop"
      assert [%{"display_name" => "Work laptop"}] = D.list_devices!(refreshed["access_token"])
    end

    test "a device created by a legacy login with a name keeps that name when the same device id logs in through OAuth", %{cid: cid, priv: priv} do
      sub = T.unique_sub()
      uid = T.provision_user!(sub)
      D.legacy_device!(uid, "LEGACYDEV1", "Legacy laptop")
      _legacy = T.legacy_session!(uid, "LEGACYDEV1")

      s = D.session!(cid, priv, "LEGACYDEV1", sub: sub)
      assert s.user_id == uid
      assert D.name_of(uid, "LEGACYDEV1") == "Legacy laptop"
    end

    test "a name the client set to the empty string is a choice and is kept", %{cid: cid, priv: priv} do
      sub = T.unique_sub()
      first = D.session!(cid, priv, "BLANKDEV01", sub: sub)
      D.put_name!(first.at, "BLANKDEV01", "")

      _second = D.session!(cid, priv, "BLANKDEV01", sub: sub)
      assert D.name_of(first.user_id, "BLANKDEV01") == ""
    end

    test "an existing device WITHOUT a name (NULL: a legacy login that sent none) is named at its next OAuth login", %{cid: cid, priv: priv} do
      sub = T.unique_sub()
      uid = T.provision_user!(sub)
      D.legacy_device!(uid, "UNNAMEDDEV", nil)
      assert D.name_of(uid, "UNNAMEDDEV") == nil

      _s = D.session!(cid, priv, "UNNAMEDDEV", sub: sub)
      assert D.name_of(uid, "UNNAMEDDEV") == "FluffyChat (NAMEDDEV)"
    end

    test "a name cleared through the API (PUT with display_name null = NULL) gets the default again at the next login", %{cid: cid, priv: priv} do
      sub = T.unique_sub()
      first = D.session!(cid, priv, "CLEAREDDEV", sub: sub)
      assert D.name_of(first.user_id, "CLEAREDDEV") == "FluffyChat (EAREDDEV)"
      D.put_name!(first.at, "CLEAREDDEV", "My phone")
      D.clear_name!(first.at, "CLEAREDDEV")
      assert D.name_of(first.user_id, "CLEAREDDEV") == nil, "precondition: the API call stored no name"

      second = D.session!(cid, priv, "CLEAREDDEV", sub: sub)
      assert D.name_of(first.user_id, "CLEAREDDEV") == "FluffyChat (EAREDDEV)"
      assert [%{"display_name" => "FluffyChat (EAREDDEV)"}] = D.list_devices!(second.at)
    end

    test "another user's device with the same id is never touched (the write is scoped to the user)", %{cid: cid, priv: priv} do
      bob = T.provision_user!()
      D.legacy_device!(bob, "SHAREDID01", "Bob's phone")
      bob_unnamed = T.provision_user!()
      D.legacy_device!(bob_unnamed, "SHAREDID01", nil)
      bob_before = D.device_row(bob, "SHAREDID01")
      bob_unnamed_before = D.device_row(bob_unnamed, "SHAREDID01")

      alice = D.session!(cid, priv, "SHAREDID01")
      assert D.name_of(alice.user_id, "SHAREDID01") == D.default_name("FluffyChat", "SHAREDID01")
      assert D.device_row(bob, "SHAREDID01") == bob_before
      assert D.device_row(bob_unnamed, "SHAREDID01") == bob_unnamed_before, "an unnamed device of ANOTHER user stays unnamed"
    end

    test "the other devices of the same user keep their names when a new OAuth device appears", %{cid: cid, priv: priv} do
      sub = T.unique_sub()
      uid = T.provision_user!(sub)
      D.legacy_device!(uid, "OLDNAMED01", "Old laptop")
      D.legacy_device!(uid, "OLDUNNAMED", nil)

      _s = D.session!(cid, priv, "NEWDEVICE01", sub: sub)
      names = D.names_of(uid)
      assert names["OLDNAMED01"] == "Old laptop"
      assert names["OLDUNNAMED"] == nil, "only the device of the login is named"
      assert names["NEWDEVICE01"] == D.default_name("FluffyChat", "NEWDEVICE01")
    end
  end

  # ── scenario 3 and 4 ────────────────────────────────────────────────────────

  describe "scenario 3 - a client name with markup and control characters is sanitised" do
    test "the story's example '<b>Evil\\u0007Client</b>' => 'EvilClient (ABCD1234)'", %{priv: priv} do
      cid = D.client!("<b>Evil\u0007Client</b>")
      s = D.session!(cid, priv, "ABCD1234")
      assert D.name_of(s.user_id, "ABCD1234") == "EvilClient (ABCD1234)"
    end

    test "a spread of hostile client names never reaches the device row as markup or control text", %{priv: priv} do
      names = [
        "<script>alert(1)</script>",
        "\u{202E}evil",
        "Zero\u{200B}width",
        "line\nbreak\r\nand\ttab",
        "<img src=x onerror=alert(1)>Chat",
        "a\u{2028}b"
      ]

      for client_name <- names do
        cid = D.client!(client_name)
        dev = D.device_id()
        s = D.session!(cid, priv, dev)
        stored = D.name_of(s.user_id, dev)
        refute D.hostile?(stored), "stored #{inspect(stored)} for the client name #{inspect(client_name)}"
        assert stored == D.default_name(client_name, dev)
        assert String.ends_with?(stored, " (" <> String.slice(dev, -8, 8) <> ")")
      end
    end

    test "a device id with markup characters (the scope charset admits them) gives a safe suffix", %{cid: cid, priv: priv} do
      dev = "<b>ID</b>x"
      s = D.session!(cid, priv, dev)
      stored = D.name_of(s.user_id, dev)
      assert stored == "FluffyChat (bIDbx)"
      refute stored =~ ~r/[<>\/]/
    end
  end

  describe "scenario 4 - an overlong client name is truncated to the safe length, the suffix is kept" do
    test "500 characters => the base is exactly the maximum, the suffix ' (ABCD1234)' stays", %{priv: priv} do
      cid = D.client!(String.duplicate("A", 500))
      s = D.session!(cid, priv, "ABCD1234")
      stored = D.name_of(s.user_id, "ABCD1234")
      assert stored == String.duplicate("A", D.max_base()) <> " (ABCD1234)"
      assert D.base_of(stored) |> D.codepoints() <= D.call(:max_base_length, [])
    end

    test "multi-byte names are bounded in code points, not bytes", %{priv: priv} do
      cid = D.client!(String.duplicate("日", 500))
      s = D.session!(cid, priv, "ABCD1234")
      stored = D.name_of(s.user_id, "ABCD1234")
      assert stored == String.duplicate("日", 64) <> " (ABCD1234)"
    end

    test "the longest name the registration accepts (255 characters) is cut as well", %{priv: priv} do
      cid = D.client!(String.duplicate("x", 255))
      s = D.session!(cid, priv, "ABCD1234")
      assert D.name_of(s.user_id, "ABCD1234") == String.duplicate("x", 64) <> " (ABCD1234)"
    end
  end

  describe "cycle 1 - invisible but not empty client names" do
    # story oauth-pages-redesign / 01-device-naming-chain: an unusable client name falls through to the host of the registered client_uri (the test client
    # has https://client.example.com); the plain "OAuth client" is only the last resort
    test "a client name made only of invisible characters / marks without a base falls through to the website host; letters mixed with them are kept", %{priv: priv} do
      for {client_name, expected} <- [
            {"\u{3164}" <> "\u{2800}" <> "\u{FFA0}", "client.example.com (ABCD1234)"},
            {"\u{0301}" <> "\u{FE0F}", "client.example.com (ABCD1234)"},
            {"Fluffy" <> "\u{3164}" <> "Chat" <> "\u{2800}", "FluffyChat (ABCD1234)"},
            {"\u{0301}" <> "FluffyChat", "FluffyChat (ABCD1234)"}
          ] do
        cid = D.client!(client_name)
        s = D.session!(cid, priv, "ABCD1234")
        assert D.name_of(s.user_id, "ABCD1234") == expected, "for " <> inspect(client_name)
      end
    end
  end

  describe "a client without a usable name is named after its website host" do
    test "no client_name, an empty, a blank, a markup-only name => 'client.example.com (ABCD1234)' (story 01-device-naming-chain)", %{priv: priv} do
      for client_name <- [nil, "", "   ", "<b></b>", "\u0007\u0008"] do
        cid = D.client!(client_name)
        s = D.session!(cid, priv, "ABCD1234")
        assert D.name_of(s.user_id, "ABCD1234") == "client.example.com (ABCD1234)", "for #{inspect(client_name)}"
      end
    end
  end

  # ── for_client/2: the client record decides ─────────────────────────────────

  describe "for_client/2 - only an approved client lends its name" do
    test "approved: its name; a hostile name is sanitised the same way", %{cid: cid} do
      assert D.for_client(cid, "ABCD1234") == "FluffyChat (ABCD1234)"
      assert D.for_client(D.client!("<b>Evil\u0007Client</b>"), "ABCD1234") == "EvilClient (ABCD1234)"
    end

    test "revoked, pending and rejected clients and an unknown client id give the plain 'OAuth client'", %{cid: cid} do
      revoked = D.client!("Revoked App")
      pending = T.oauth_client!([D.redirect()], status: "pending", client_name: "Pending App")
      rejected = T.oauth_client!([D.redirect()], status: "rejected", client_name: "Rejected App")
      T.mark_revoked!(revoked)

      assert D.for_client(cid, "ABCD1234") == "FluffyChat (ABCD1234)", "control: the approved client still lends its name"
      assert D.for_client(revoked, "ABCD1234") == "OAuth client (ABCD1234)"
      assert D.for_client(pending, "ABCD1234") == "OAuth client (ABCD1234)"
      assert D.for_client(rejected, "ABCD1234") == "OAuth client (ABCD1234)"
      assert D.for_client("no-such-client-" <> T.rand(), "ABCD1234") == "OAuth client (ABCD1234)"
    end

    test "an unreadable database never raises: the plain base", %{cid: cid} do
      T.put_env_scoped(:oauth_repo, T.NoSuchRepo)
      assert D.for_client(cid, "ABCD1234") == "OAuth client (ABCD1234)"
    end

    test "garbage ids never raise", %{} do
      for id <- [nil, 42, "", :atom, %{}], do: assert(is_binary(D.for_client(id, "ABCD1234")))
    end
  end

  # ── scenario 5: legacy / SSO ────────────────────────────────────────────────

  describe "scenario 5 - legacy password / SSO login device names are unaffected" do
    test "initial_device_display_name 'Legacy laptop' is the device name, exactly, no OAuth default", %{priv: priv} do
      sub = T.unique_sub()
      conn = D.legacy_login(priv, sub, device_id: "LEGACYLOG1", initial_device_display_name: "Legacy laptop")
      assert conn.status == 200, "legacy login must succeed, got #{conn.status}: #{conn.resp_body}"
      body = T.json(conn)
      assert body["device_id"] == "LEGACYLOG1"

      assert D.name_of(body["user_id"], "LEGACYLOG1") == "Legacy laptop"
    end

    test "a legacy login without a name leaves the name unset: the OAuth default is never applied to it", %{priv: priv} do
      sub = T.unique_sub()
      named = D.legacy_login(priv, sub, device_id: "LEGACYLOG2")
      assert named.status == 200
      generated = D.legacy_login(priv, sub)
      assert generated.status == 200
      uid = T.json(named)["user_id"]

      assert D.name_of(uid, "LEGACYLOG2") == nil
      assert D.name_of(uid, T.json(generated)["device_id"]) == nil
    end

    test "a user with a legacy device and an OAuth device: the legacy name stays, the OAuth device is named", %{cid: cid, priv: priv} do
      sub = T.unique_sub()
      legacy = D.legacy_login(priv, sub, device_id: "LEGACYLOG3", initial_device_display_name: "Legacy laptop")
      assert legacy.status == 200

      s = D.session!(cid, priv, "OAUTHDEV001", sub: sub)
      assert s.user_id == T.json(legacy)["user_id"]
      names = D.names_of(s.user_id)
      assert names["LEGACYLOG3"] == "Legacy laptop"
      assert names["OAUTHDEV001"] == D.default_name("FluffyChat", "OAUTHDEV001")
    end

    test "a legacy login that takes over an OAuth device keeps the device's name (initial_device_display_name names a device on its first creation only)", %{cid: cid, priv: priv} do
      s = D.session!(cid, priv, "TAKEOVER001")
      named = D.name_of(s.user_id, "TAKEOVER001")
      assert named == D.default_name("FluffyChat", "TAKEOVER001")

      conn = D.legacy_login(priv, s.sub, device_id: "TAKEOVER001", initial_device_display_name: "Legacy laptop")
      assert conn.status == 200, "got #{conn.status}: #{conn.resp_body}"
      assert D.name_of(s.user_id, "TAKEOVER001") == named
    end
  end

  # ── logs ────────────────────────────────────────────────────────────────────

  describe "no sensitive data in logs" do
    test "neither the client's name nor the made-up device name appears in any log line of the login, the issuance, the refresh and the re-login", %{priv: priv} do
      probe = "LeakProbeApp" <> String.upcase(T.rand(4))
      cid = D.client!(probe)
      sub = T.unique_sub()
      original = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: original) end)

      log =
        capture_log([level: :debug], fn ->
          s = D.session!(cid, priv, "LOGDEVICE01", sub: sub)
          T.idp_refresh_ok(s.sub)
          T.refresh!(cid, s.rt)
          D.session!(cid, priv, "LOGDEVICE01", sub: sub)
          D.session!(cid, priv, "LOGDEVICE02", sub: sub)
        end)

      assert log =~ "oauth session created", "control: the capture saw the issuance lines"
      leaked = log |> String.split("\n") |> Enum.filter(&String.contains?(&1, probe))
      assert leaked == [], "the client's name must not be logged, found: #{inspect(leaked)}"
      refute log =~ "(DEVICE01)", "the made-up device name must not be logged"
      refute log =~ "(DEVICE02)", "the made-up device name must not be logged"
    end
  end
end
