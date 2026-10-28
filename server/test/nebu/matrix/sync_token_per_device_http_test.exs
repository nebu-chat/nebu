defmodule Nebu.Matrix.SyncTokenPerDeviceHttpTest do
  @moduledoc """
  Acceptance tests for story `sync-token-per-device` (epic oauth-broker, follow-up `fd`), HTTP half: `GET /_matrix/client/v3/sync`
  over the real stack (`Nebu.Web.Router` + `Plug.Test`, real `Nebu.Repo`, real Room.Server / Horde / :pg; users and sessions through
  `Nebu.OAuth.TestSupport` and `Nebu.Matrix.ModerationTestSupport` (`S`), random localparts, `:server_name` pinned). Scenarios 1-13 of the
  story plus the SECURITY tests of its D8 and the Oracle's extra cases (every one of them has a test here or in the sibling files):

    * the siblings: `sync_token_per_device_store_test.exs` (positions, advisory lock, wake-up, `PgStore` columns, interleaving),
      `sync_token_per_device_dispatcher_test.exs` (the key per request, the real anchor, proto parity), the migration test
      `migration/000052_sync_device_positions_test.exs`, the docs test `sync_token_per_device_docs_test.exs`.

  Conventions (as `sync_membership_partition_http_test.exs`):

    * A device is a legacy opaque session of the user with its own `device_id` (`device!/2`); a DEVICE-LESS client is a raw IdP JWT without a
      server-side binding (`T.unbound_jwt!/2`, D2); a BOUND JWT is `T.bound_jwt!/3`.
    * "Incremental" is told from "initial-shaped" by the room's timeline (a snapshot repeats the room from `m.room.create` on and the markers of
      earlier messages, a delta only carries what is newer than the anchor): the detector has a POSITIVE control (the single-device baseline passes today).
    * Scenario 5 (interleaving) is pinned deterministically in the STORE test (its `request/4` helper replays the read / advance order of the route against the
      store primitives; a route that wires them wrongly is caught by the position-VALUE assertions here, e.g. `{first_ad, 0}` and `{max_ad_pos, cs_pos}`). The
      concurrent-writers test of this file is a stochastic supplement (store API writers, no jitter-free guarantee): it can only fail, never prove.
    * `tick/0` separates writes whose order a sync token depends on. Long-poll tests start the sync in a `Task` and wait (bounded poll) until
      its process joined the user's `:pg` group; no fixed sleeps. Every test stays well below the 100-request `/sync` burst of the frozen clock.
  """
  use ExUnit.Case, async: false

  alias Nebu.Matrix.AccountDataStore
  alias Nebu.Matrix.CrossSigningKeyStore
  alias Nebu.Matrix.ModerationTestSupport, as: S
  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration

  setup do
    T.reset_rate_limits()
    Nebu.Test.ServerName.pin!(T.server_name())
    on_exit(fn -> T.restore_rate_limits() end)
    :ok
  end

  # ─── fixtures ────────────────────────────────────────────────────────────────

  defp device!(uid, prefix) do
    dev = prefix <> String.upcase(T.rand(3))
    %{uid: uid, dev: dev, at: T.legacy_session!(uid, dev, expires_at: S.session_expiry()).at}
  end

  # a user with devices A and B, joined (through A) to `room` owned by O, an own anchor room, and a first incremental token per device
  defp shared! do
    uid = T.provision_user!()
    a = device!(uid, "FDA")
    b = device!(uid, "FDB")
    o = S.user!("FDO")
    room = S.invite_room(o, [a])
    anchor = S.anchor_room!(a)
    ta = S.snapshot!(a, anchor)
    tb = S.snapshot!(b, anchor)
    %{uid: uid, a: a, b: b, o: o, room: room, anchor: anchor, ta: ta, tb: tb}
  end

  defp jwt_user!(priv) do
    sub = T.unique_sub()
    uid = T.provision_user!(sub)
    %{sub: sub, uid: uid, priv: priv}
  end

  defp unbound(%{priv: priv, sub: sub, uid: uid}), do: %{uid: uid, dev: "", at: T.unbound_jwt!(priv, sub)}

  # ─── database probes ─────────────────────────────────────────────────────────

  defp rows(uid), do: T.sql!("SELECT * FROM sync_tokens WHERE user_id = $1 ORDER BY device_id", [uid]).rows
  defp row(uid, dev), do: T.sql!("SELECT * FROM sync_tokens WHERE user_id = $1 AND device_id = $2", [uid, dev]).rows
  defp device_ids(uid), do: T.sql!("SELECT device_id FROM sync_tokens WHERE user_id = $1 ORDER BY device_id", [uid]).rows |> List.flatten()

  defp token_and_anchor(uid, dev) do
    case T.sql!("SELECT since_token, last_event_id FROM sync_tokens WHERE user_id = $1 AND device_id = $2", [uid, dev]).rows do
      [[token, anchor]] -> %{since_token: token, last_event_id: anchor}
      [] -> nil
    end
  end

  defp positions(uid, dev), do: T.sql!("SELECT account_data_pos, cross_signing_pos FROM sync_tokens WHERE user_id = $1 AND device_id = $2", [uid, dev]).rows |> hd() |> List.to_tuple()
  defp ad_flags(uid), do: T.sql!("SELECT type, changed FROM account_data WHERE user_id = $1 ORDER BY type", [uid]).rows
  defp max_ad_pos(uid), do: T.sql!("SELECT coalesce(max(stream_pos), 0) FROM account_data WHERE user_id = $1", [uid]).rows |> hd() |> hd()
  defp cs_flag(uid), do: T.sql!("SELECT cross_signing_changed FROM cross_signing_keys WHERE user_id = $1", [uid]).rows |> hd() |> hd()
  defp cs_pos(uid), do: T.sql!("SELECT changed_pos FROM cross_signing_keys WHERE user_id = $1", [uid]).rows |> hd() |> hd()

  # ─── the sync client ─────────────────────────────────────────────────────────

  defp next(body), do: body["next_batch"]
  defp core(token), do: token |> String.split(".") |> hd()
  defp bodies(body, room), do: for(ev <- S.join_timeline(body, room), ev["type"] == "m.room.message", do: ev["content"]["body"])
  # an initial-shaped answer repeats the room from its creation (the timeline starts at m.room.create); a delta only carries the events after the
  # anchor (its `state` section is NOT a discriminator: the delta carries the current room state too)
  defp snapshot?(body, room), do: Enum.any?(S.join_timeline(body, room), &(&1["type"] == "m.room.create"))
  defp changed(body), do: get_in(body, ["device_lists", "changed"]) || []
  defp left_users(body), do: get_in(body, ["device_lists", "left"]) || []
  defp ad_events(body), do: get_in(body, ["account_data", "events"]) || []
  defp ad_map(body), do: Map.new(ad_events(body), &{&1["type"], &1["content"]})

  defp timed(user, since, params) do
    started = System.monotonic_time(:millisecond)
    body = S.sync(user, since, params)
    {body, System.monotonic_time(:millisecond) - started}
  end

  defp wait_polling(uid), do: assert(:ok = S.wait_until(fn -> :pg.get_local_members("user:#{uid}") != [] end, 10_000), "the sync never started polling")

  defp put_ad(user, type, content), do: T.matrix_request(:put, "/_matrix/client/v3/user/#{S.enc(user.uid)}/account_data/#{type}", user.at, body: content)

  defp put_ad!(user, type, content) do
    conn = put_ad(user, type, content)
    assert conn.status == 200, "PUT account data: #{conn.status} #{conn.resp_body}"
  end

  defp message!(o, room, label) do
    S.tick()
    m = S.marker(label)
    S.say!(o, room, m)
    m
  end

  defp assert_incremental(body, room, new_marker, old_markers \\ []) do
    assert new_marker in bodies(body, room), "the new event is in the delta: #{inspect(bodies(body, room))}"
    refute snapshot?(body, room), "a delta does not repeat the room from its creation (this was an initial-shaped answer)"
    for old <- old_markers, do: refute(old in bodies(body, room), "an earlier message is not repeated: #{old}")
    body
  end

  defp assert_snapshot(body, room, markers) do
    assert snapshot?(body, room), "an initial-shaped answer repeats the room from its creation"
    for m <- markers, do: assert(m in bodies(body, room), "the snapshot repeats #{m}")
    body
  end

  # ═══ Scenario 1: two clients alternate ════════════════════════════════════════════════════════════════════════════════════════

  describe "Scenario 1 - two devices alternate" do
    test "positive control: ONE device syncs incrementally (the detector helpers, true today)" do
      uid = T.provision_user!()
      a = device!(uid, "FDA")
      o = S.user!("FDO")
      room = S.invite_room(o, [a])
      anchor = S.anchor_room!(a)
      ta = S.snapshot!(a, anchor)

      m1 = message!(o, room, "m1")
      body = S.sync(a, ta)
      assert_incremental(body, room, m1)
      assert is_binary(next(body))
      assert_snapshot(S.sync(a, "stale"), room, [m1])
    end

    test "A and B alternate (timeout=0 and >0): every answer is incremental and long-polls, one row per device, no '' row" do
      f = shared!()
      m1 = message!(f.o, f.room, "m1")

      a1 = S.sync(f.a, f.ta, timeout: 0) |> assert_incremental(f.room, m1)
      b1 = S.sync(f.b, f.tb, timeout: 0) |> assert_incremental(f.room, m1)
      assert device_ids(f.uid) == Enum.sort([f.a.dev, f.b.dev]), "one row per device and no '' row"

      {a2, ms_a} = timed(f.a, next(a1), timeout: 300)
      {b2, ms_b} = timed(f.b, next(b1), timeout: 300)
      assert ms_a >= 250 and ms_b >= 250, "nothing happened: both long-poll (took #{ms_a} / #{ms_b} ms), no fallback that returns at once"
      assert bodies(a2, f.room) == [] and bodies(b2, f.room) == []
      assert is_binary(next(a2)) and is_binary(next(b2))

      # an event while B waits: B returns with it, then A (which did not wait) is incremental as well
      poll = Task.async(fn -> timed(f.b, next(b2), timeout: 15_000) end)
      wait_polling(f.uid)
      m2 = message!(f.o, f.room, "m2")
      assert {b3, ms} = Task.await(poll, 20_000)
      assert ms < 8_000, "the long-poll of B returned for the event (#{ms} ms)"
      assert_incremental(b3, f.room, m2, [m1])

      a3 = S.sync(f.a, next(a2), timeout: 0) |> assert_incremental(f.room, m2, [m1])
      assert is_binary(next(a3))

      assert device_ids(f.uid) == Enum.sort([f.a.dev, f.b.dev])
      for dev <- [f.a, f.b], do: assert(token_and_anchor(f.uid, dev.dev).since_token == core(next(if dev == f.a, do: a3, else: b3)), "the row holds the token of that device's LAST response")
    end

    test "each device's own token stays valid while the other syncs: six alternating rounds, always incremental, always its own row" do
      f = shared!()
      tokens = %{a: f.ta, b: f.tb}

      final =
        Enum.reduce(1..6, tokens, fn round, acc ->
          m = message!(f.o, f.room, "round#{round}")
          who = if rem(round, 2) == 1, do: :a, else: :b
          other = if who == :a, do: :b, else: :a
          dev = Map.fetch!(f, who)
          body = S.sync(dev, Map.fetch!(acc, who)) |> assert_incremental(f.room, m)
          other_body = S.sync(Map.fetch!(f, other), Map.fetch!(acc, other)) |> assert_incremental(f.room, m)
          %{who => next(body), other => next(other_body)}
        end)

      assert map_size(final) == 2
      assert device_ids(f.uid) == Enum.sort([f.a.dev, f.b.dev])
      assert length(rows(f.uid)) == 2, "no row per request, no growth"
    end

    test "next_batch is always present and keeps the <core>.<pos> shape: initial, delta, fallback, malformed since, full_state" do
      f = shared!()
      shape = ~r/\A[^.]+\.\d+\z/
      c = device!(f.uid, "FDC")

      bodies_ = [
        S.sync(c),
        S.sync(f.a, f.ta),
        S.sync(f.b, "garbage-since"),
        S.sync(f.a, "!!.7"),
        S.sync(f.a, nil, full_state: true)
      ]

      for b <- bodies_, do: assert(is_binary(next(b)) and next(b) =~ shape, "next_batch #{inspect(next(b))}")
    end

    test "a user with many syncs on one device keeps exactly one row; three devices keep exactly three (rows are bounded by the devices, no '' row)" do
      uid = T.provision_user!()
      devs = for p <- ["FD1", "FD2", "FD3"], do: device!(uid, p)
      tokens = for d <- devs, do: {d, next(S.sync(d))}

      final =
        Enum.reduce(1..4, Map.new(tokens), fn _, acc ->
          Map.new(acc, fn {d, t} -> {d, next(S.sync(d, t))} end)
        end)

      assert map_size(final) == 3
      assert device_ids(uid) == devs |> Enum.map(& &1.dev) |> Enum.sort()
      assert length(rows(uid)) == 3
    end
  end

  defp end_membership!(:leave, f), do: S.leave!(f.a, f.room)
  defp end_membership!(:kick, f), do: assert(S.kick(f.o, f.room, f.uid).status == 200)
  defp end_membership!(:ban, f), do: assert(S.ban(f.o, f.room, f.uid).status == 200)

  # ═══ Scenario 2: leave / kick / ban reach the other device ═══════════════════════════════════════════════════════════════════

  describe "Scenario 2 - a membership end reaches the other device in rooms.leave" do
    for {cause, membership} <- [leave: "leave", kick: "leave", ban: "ban"] do
      test "#{cause}: both devices get the room in rooms.leave, bounded at the #{cause} event, once each" do
        f = shared!()
        membership = unquote(membership)
        S.tick()
        end_membership!(unquote(cause), f)
        # a message AFTER the cause: it must not be in the window (the window ends at the cause event)
        after_cause = message!(f.o, f.room, "after-#{unquote(cause)}")

        a1 = S.sync(f.a, f.ta)
        b1 = S.sync(f.b, f.tb)

        for {who, body} <- [a: a1, b: b1] do
          timeline = S.leave_timeline(body, f.room)
          assert S.in_section?(body, "leave", f.room), "device #{who}: the room is in rooms.leave"
          refute S.in_section?(body, "join", f.room)
          assert S.member_ev(timeline, f.uid, membership), "device #{who}: the #{membership} event is in the window"
          last = List.last(timeline)
          assert last["type"] == "m.room.member" and last["state_key"] == f.uid, "device #{who}: the window ENDS at the #{membership} event"
          refute Enum.any?(timeline, &(&1["type"] == "m.room.message" and &1["content"]["body"] == after_cause)), "device #{who}: the later message is not delivered"
        end

        # exactly once: the following syncs of both devices do not list it again
        assert S.in_section?(S.sync(f.a, next(a1)), "leave", f.room) == false
        assert S.in_section?(S.sync(f.b, next(b1)), "leave", f.room) == false
      end
    end
  end

  # ═══ Scenario 3: global account data per device ══════════════════════════════════════════════════════════════════════════════

  describe "Scenario 3 - global account data is delivered per device" do
    test "a PUT through device A is echoed to A's own next sync AND delivered to B; a further sync of either does not repeat it" do
      f = shared!()
      put_ad!(f.a, "m.secret_storage.default_key", %{"key" => "k1"})

      a1 = S.sync(f.a, f.ta)
      assert ad_map(a1) == %{"m.secret_storage.default_key" => %{"key" => "k1"}}, "the echo to the writer"
      b1 = S.sync(f.b, f.tb)
      assert ad_map(b1) == %{"m.secret_storage.default_key" => %{"key" => "k1"}}, "device B is not robbed by A's read"

      assert ad_events(S.sync(f.a, next(a1))) == []
      assert ad_events(S.sync(f.b, next(b1))) == []
    end

    test "an overwrite and an identical-content PUT are delivered again, once per device, with the newest content" do
      f = shared!()
      put_ad!(f.a, "m.secret_storage.default_key", %{"key" => "v1"})
      a1 = S.sync(f.a, f.ta)
      b1 = S.sync(f.b, f.tb)

      put_ad!(f.b, "m.secret_storage.default_key", %{"key" => "v2"})
      a2 = S.sync(f.a, next(a1))
      b2 = S.sync(f.b, next(b1))
      for body <- [a2, b2], do: assert(ad_events(body) == [%{"type" => "m.secret_storage.default_key", "content" => %{"key" => "v2"}}])

      put_ad!(f.a, "m.secret_storage.default_key", %{"key" => "v2"})
      a3 = S.sync(f.a, next(a2))
      b3 = S.sync(f.b, next(b2))
      for body <- [a3, b3], do: assert(ad_map(body) == %{"m.secret_storage.default_key" => %{"key" => "v2"}}, "identical content is re-delivered")

      assert ad_events(S.sync(f.a, next(a3))) == [] and ad_events(S.sync(f.b, next(b3))) == []
    end

    test "a device that missed two versions gets the newest content once, together with other types it missed" do
      f = shared!()
      put_ad!(f.a, "org.fd.one", %{"v" => 1})
      put_ad!(f.a, "org.fd.one", %{"v" => 2})
      put_ad!(f.a, "org.fd.two", %{"w" => 1})
      assert ad_map(S.sync(f.b, f.tb)) == %{"org.fd.one" => %{"v" => 2}, "org.fd.two" => %{"w" => 1}}
    end

    test "a bound device never clears the consume-once flags (only device-less requests do): they stay set after both read" do
      f = shared!()
      put_ad!(f.a, "org.fd.flag", %{"x" => 1})
      assert ad_flags(f.uid) == [["org.fd.flag", true]]

      a1 = S.sync(f.a, f.ta)
      b1 = S.sync(f.b, f.tb)
      assert ad_map(a1) == %{"org.fd.flag" => %{"x" => 1}} and ad_map(b1) == ad_map(a1)
      assert ad_flags(f.uid) == [["org.fd.flag", true]], "the flag is still set: the delivery of bound devices is by position"
    end

    test "an initial sync delivers ALL global account data (no since), the next incremental only what changed afterwards" do
      f = shared!()
      put_ad!(f.a, "org.fd.one", %{"v" => 1})
      put_ad!(f.a, "org.fd.two", %{"v" => 2})
      c = device!(f.uid, "FDC")

      initial = S.sync(c)
      assert ad_map(initial) == %{"org.fd.one" => %{"v" => 1}, "org.fd.two" => %{"v" => 2}}
      put_ad!(f.a, "org.fd.three", %{"v" => 3})
      assert ad_map(S.sync(c, next(initial))) == %{"org.fd.three" => %{"v" => 3}}
    end

    test "full_state=true widens only the room state: global account data stays incremental by position" do
      f = shared!()
      put_ad!(f.a, "org.fd.one", %{"v" => 1})
      a1 = S.sync(f.a, f.ta)
      assert Map.has_key?(ad_map(a1), "org.fd.one")

      put_ad!(f.a, "org.fd.two", %{"v" => 2})
      refute S.in_section?(S.sync(f.b, f.tb), "join", f.room), "control: without full_state a room without news is not in rooms.join"
      full = S.sync(f.a, next(a1), full_state: true)
      assert S.in_section?(full, "join", f.room) and S.join_state(full, f.room) != [], "full_state: every joined room with its full state"
      assert ad_map(full) == %{"org.fd.two" => %{"v" => 2}}, "only the entry written since this device's last response"

      again = S.sync(f.a, next(full), full_state: true)
      assert ad_events(again) == []
    end

    test "the writer's row stores the highest delivered account data position (the next sync sends nothing again)" do
      f = shared!()
      put_ad!(f.a, "org.fd.one", %{"v" => 1})
      a1 = S.sync(f.a, f.ta)
      assert {ad, _cs} = positions(f.uid, f.a.dev)
      assert ad == max_ad_pos(f.uid), "account_data_pos = the highest stream_pos delivered"
      assert {0, _} = positions(f.uid, f.b.dev), "device B has not been sent it yet"
      assert ad_events(S.sync(f.a, next(a1))) == []
    end

    test "the two columns advance independently: account data moves only account_data_pos, a key change only cross_signing_pos" do
      f = shared!()
      put_ad!(f.a, "org.fd.one", %{"v" => 1})
      a1 = S.sync(f.a, f.ta)
      first_ad = max_ad_pos(f.uid)
      assert positions(f.uid, f.a.dev) == {first_ad, 0}, "no key change yet: cross_signing_pos stays 0"

      assert :ok = CrossSigningKeyStore.put_keys(f.uid, T.cross_signing_keys(f.uid, "A"))
      a2 = S.sync(f.a, next(a1))
      assert positions(f.uid, f.a.dev) == {first_ad, cs_pos(f.uid)}, "a key change does not lift the account data position"

      put_ad!(f.a, "org.fd.two", %{"v" => 2})
      _ = S.sync(f.a, next(a2))
      assert positions(f.uid, f.a.dev) == {max_ad_pos(f.uid), cs_pos(f.uid)}
      assert max_ad_pos(f.uid) > cs_pos(f.uid) and cs_pos(f.uid) > first_ad
    end

    test "an oversize PUT (413) writes no row, draws no position and wakes nobody" do
      f = shared!()
      :pg.join("user:#{f.uid}", self())
      before_pos = T.sql!("SELECT last_value FROM sync_global_pos_seq").rows

      conn = put_ad(f.a, "org.fd.big", %{"x" => String.duplicate("a", 1_000_100)})
      assert conn.status == 413
      assert T.json(conn)["errcode"] == "M_TOO_LARGE"

      assert T.sql!("SELECT count(*) FROM account_data WHERE user_id = $1", [f.uid]).rows == [[0]]
      assert T.sql!("SELECT last_value FROM sync_global_pos_seq").rows == before_pos, "no position was drawn"
      refute_receive {:account_data_changed, _}, 200
      assert ad_events(S.sync(f.a, f.ta)) == []
      :pg.leave("user:#{f.uid}", self())
    end

    test "an account data row of another user never reaches the caller (its marker appears nowhere in the response)" do
      f = shared!()
      stranger = S.user!("FDS")
      marker = "stranger-secret-#{T.rand(6)}"
      put_ad!(stranger, "m.secret_storage.default_key", %{"key" => marker})
      put_ad!(f.a, "m.secret_storage.default_key", %{"key" => "mine"})

      for body <- [S.sync(f.a, f.ta), S.sync(f.b, f.tb), S.sync(device!(f.uid, "FDC"))] do
        refute Jason.encode!(body) =~ marker
        assert ad_map(body) == %{"m.secret_storage.default_key" => %{"key" => "mine"}}
      end
    end
  end

  # ═══ Scenario 4: the own cross-signing change reaches every device ════════════════════════════════════════════════════════════

  describe "Scenario 4 - own cross-signing change in device_lists.changed" do
    test "an upload through A lists the user on A itself and on B, each exactly once, never in device_lists.left" do
      f = shared!()
      assert T.device_signing_upload(f.a.at, T.cross_signing_keys(f.uid, "X#{T.rand(2)}")).status == 200

      a1 = S.sync(f.a, f.ta)
      b1 = S.sync(f.b, f.tb)

      for {who, body} <- [uploader_a: a1, other_b: b1] do
        assert Enum.count(changed(body), &(&1 == f.uid)) == 1, "#{who}: the user is listed once, got #{inspect(changed(body))}"
        refute f.uid in left_users(body)
      end

      for {body, tok} <- [{S.sync(f.a, next(a1)), :a}, {S.sync(f.b, next(b1)), :b}] do
        refute f.uid in changed(body), "device #{tok}: not listed again"
        refute f.uid in left_users(body)
      end
    end

    test "every further key change (the same keys again too) is listed once more, per device" do
      f = shared!()
      assert :ok = CrossSigningKeyStore.put_keys(f.uid, T.cross_signing_keys(f.uid, "A"))
      a1 = S.sync(f.a, f.ta)
      b1 = S.sync(f.b, f.tb)
      assert f.uid in changed(a1) and f.uid in changed(b1)

      assert :ok = CrossSigningKeyStore.put_keys(f.uid, T.cross_signing_keys(f.uid, "A"))
      a2 = S.sync(f.a, next(a1))
      b2 = S.sync(f.b, next(b1))
      assert Enum.count(changed(a2), &(&1 == f.uid)) == 1 and Enum.count(changed(b2), &(&1 == f.uid)) == 1
      refute f.uid in changed(S.sync(f.a, next(a2)))
    end

    test "a bound device NEVER clears the cross-signing flag (the device-less client reads it); the position moves instead" do
      f = shared!()
      assert :ok = CrossSigningKeyStore.put_keys(f.uid, T.cross_signing_keys(f.uid, "A"))
      assert cs_flag(f.uid) == true

      S.sync(f.a, f.ta)
      S.sync(f.b, f.tb)
      assert cs_flag(f.uid) == true
      assert {_, cs_a} = positions(f.uid, f.a.dev)
      assert cs_a == cs_pos(f.uid), "cross_signing_pos = the changed_pos that was sent"
    end

    test "device_lists is in every response and lists nobody without a change (an initial sync: no entry for the own user)" do
      f = shared!()
      c = device!(f.uid, "FDC")
      initial = S.sync(c)
      assert changed(initial) == [] and left_users(initial) == []
      assert changed(S.sync(f.a, f.ta)) == []
    end
  end

  # ═══ Scenario 5: concurrent writers and a polling device (stochastic; the deterministic interleaving is in the store test) ═════════════════════════════════════════════════════════

  describe "Scenario 5 - concurrent writes against a polling device (stochastic)" do
    test "twelve PUTs and two cross-signing writes while device B polls: every entry reaches B, none is skipped" do
      f = shared!()
      expected = for i <- 1..12, do: "org.fd.race#{i}"

      writers =
        for w <- 0..2 do
          Task.async(fn ->
            for i <- 1..12, rem(i, 3) == w do
              assert :ok = AccountDataStore.put(f.uid, "org.fd.race#{i}", Jason.encode!(%{"i" => i}))
              if i in [4, 9], do: assert(:ok = CrossSigningKeyStore.put_keys(f.uid, T.cross_signing_keys(f.uid, "R#{i}")))
              Process.sleep(rem(i * 7, 5))
            end
          end)
        end

      poll = fn poll, token, seen, rounds ->
        body = S.sync(f.b, token)
        seen = Enum.reduce(ad_events(body), seen, &MapSet.put(&2, &1["type"]))
        if rounds <= 0, do: {seen, next(body)}, else: poll.(poll, next(body), seen, rounds - 1)
      end

      {seen, token} = poll.(poll, f.tb, MapSet.new(), 25)
      Task.await_many(writers, 30_000)
      {seen, _} = poll.(poll, token, seen, 1)

      assert MapSet.new(expected) |> MapSet.subset?(seen), "never delivered: #{inspect(expected -- MapSet.to_list(seen))}"
    end
  end

  # ═══ Scenario 6: wake-up and pending check ═══════════════════════════════════════════════════════════════════════════════════

  describe "Scenario 6 - a global account data PUT ends a waiting or following long-poll" do
    test "device B waits with timeout=15000; a PUT through A wakes it at once and it carries the entry" do
      f = shared!()
      poll = Task.async(fn -> timed(f.b, f.tb, timeout: 15_000) end)
      wait_polling(f.uid)
      put_ad!(f.a, "m.secret_storage.default_key", %{"key" => "woken"})

      assert {body, ms} = Task.await(poll, 25_000)
      assert ms < 6_000, "the long-poll of B ended for the PUT (took #{ms} ms of 15000)"
      assert ad_map(body) == %{"m.secret_storage.default_key" => %{"key" => "woken"}}
    end

    test "the writer's OWN waiting sync is woken by its own PUT too (the echo Element waits for)" do
      f = shared!()
      poll = Task.async(fn -> timed(f.a, f.ta, timeout: 15_000) end)
      wait_polling(f.uid)
      put_ad!(f.a, "m.secret_storage.default_key", %{"key" => "echo"})

      assert {body, ms} = Task.await(poll, 25_000)
      assert ms < 6_000
      assert ad_map(body) == %{"m.secret_storage.default_key" => %{"key" => "echo"}}
    end

    test "a since that predates a committed PUT gets an IMMEDIATE answer with the entry instead of waiting (pending check)" do
      f = shared!()
      put_ad!(f.a, "m.secret_storage.default_key", %{"key" => "before"})

      {body, ms} = timed(f.b, f.tb, timeout: 10_000)
      assert ms < 3_000, "pending account data zeroes the timeout (took #{ms} ms of 10000)"
      assert ad_map(body) == %{"m.secret_storage.default_key" => %{"key" => "before"}}

      # nothing pending any more: now it really waits
      {_, waited} = timed(f.b, next(body), timeout: 300)
      assert waited >= 250
    end

    test "a pending change does not spin: delivered once, the device long-polls again; the other device still has it pending" do
      f = shared!()
      put_ad!(f.a, "org.fd.once", %{"v" => 1})
      {a1, _} = timed(f.a, f.ta, timeout: 5_000)
      assert Map.has_key?(ad_map(a1), "org.fd.once")
      {_, ms} = timed(f.a, next(a1), timeout: 300)
      assert ms >= 250
      {b1, ms_b} = timed(f.b, f.tb, timeout: 5_000)
      assert ms_b < 3_000 and Map.has_key?(ad_map(b1), "org.fd.once")
    end
  end

  # ═══ Scenario 7: initial sync and fallback store the real anchor and the positions under the device key ══════════════════════════

  describe "Scenario 7 - initial sync and fallback persist per device" do
    test "a first sync: all account data, the row holds the newest delivered event as anchor (never empty) and the highest positions" do
      f = shared!()
      put_ad!(f.a, "org.fd.one", %{"v" => 1})
      put_ad!(f.a, "org.fd.two", %{"v" => 2})
      assert :ok = CrossSigningKeyStore.put_keys(f.uid, T.cross_signing_keys(f.uid, "A"))
      c = device!(f.uid, "FDC")

      body = S.sync(c)
      assert map_size(ad_map(body)) == 2
      assert changed(body) == [], "a real initial sync lists no device_lists entry"

      stored = token_and_anchor(f.uid, c.dev)
      assert stored.since_token == core(next(body))
      assert is_binary(stored.last_event_id) and stored.last_event_id != "", "the anchor is the real newest event, never nil / empty (the nil-anchor bug)"

      delivered = for {_rid, r} <- S.section(body, "join"), ev <- get_in(r, ["timeline", "events"]) || [], do: ev
      newest = delivered |> Enum.map(& &1["origin_server_ts"]) |> Enum.max()
      assert stored.last_event_id in (for ev <- delivered, ev["origin_server_ts"] == newest, do: ev["event_id"])

      assert positions(f.uid, c.dev) == {max_ad_pos(f.uid), cs_pos(f.uid)}
      assert [] == row(f.uid, ""), "no '' row is written for a device-bound request"
    end

    test "a stale token: 200 initial-shaped, all account data, real anchor, own user in device_lists.changed, never in left" do
      f = shared!()
      put_ad!(f.a, "org.fd.one", %{"v" => 1})
      m1 = message!(f.o, f.room, "m1")

      body = S.sync(f.a, "not-the-token-we-issued")
      assert_snapshot(body, f.room, [m1])
      assert ad_map(body) == %{"org.fd.one" => %{"v" => 1}}
      assert f.uid in changed(body), "D10: a fallback to a request that carried a since lists the own user"
      refute f.uid in left_users(body)

      stored = token_and_anchor(f.uid, f.a.dev)
      assert stored.since_token == core(next(body))
      assert is_binary(stored.last_event_id) and stored.last_event_id != "", "the fallback no longer writes a nil anchor"
      assert elem(positions(f.uid, f.a.dev), 0) == max_ad_pos(f.uid), "the fallback sets the account data position: it delivered everything"

      m2 = message!(f.o, f.room, "m2")
      assert_incremental(S.sync(f.a, next(body)), f.room, m2, [m1])
    end

    test "the nil-anchor bug over HTTP: after a fallback the next delta does not replay the room's earlier events" do
      f = shared!()
      m1 = message!(f.o, f.room, "old")
      _ = S.sync(f.a, f.ta)
      fallback = S.sync(f.a, "stale")
      assert_snapshot(fallback, f.room, [m1])
      assert token_and_anchor(f.uid, f.a.dev).last_event_id != nil

      delta = S.sync(f.a, next(fallback))
      refute m1 in bodies(delta, f.room), "no replay from timestamp 0"
      assert S.join_timeline(delta, f.room) == []
    end

    test "a request without a since (an empty one counts as absent) lists no device_lists entry; with a since it does" do
      f = shared!()
      assert changed(S.sync(f.a, nil)) == []
      assert changed(S.sync(f.a, "")) == []
      assert f.uid in changed(S.sync(f.a, "something-else"))
    end

    test "a fallback also advances cross_signing_pos to the current changed_pos (the own user is listed once, not again)" do
      f = shared!()
      assert :ok = CrossSigningKeyStore.put_keys(f.uid, T.cross_signing_keys(f.uid, "A"))
      fallback = S.sync(f.a, "stale")
      assert f.uid in changed(fallback)
      assert {_, cs} = positions(f.uid, f.a.dev)
      assert cs == cs_pos(f.uid)
      assert Enum.count(changed(S.sync(f.a, next(fallback))), &(&1 == f.uid)) == 0
    end
  end

  # ═══ Scenario 8: requests without a device id ═══════════════════════════════════════════════════════════════════════════════

  describe "Scenario 8 - a request without a device id keeps the per-user behaviour" do
    setup do
      {:ok, priv: T.setup_idp!()}
    end

    test "an unbound JWT uses the '' row, bound JWT and legacy session use their device rows; bound requests never touch the '' row", %{priv: priv} do
      j = jwt_user!(priv)
      jwt = unbound(j)
      dev = device!(j.uid, "FDD")
      bound_dev = "FDJ" <> String.upcase(T.rand(3))
      bound = %{uid: j.uid, dev: bound_dev, at: T.bound_jwt!(priv, j.sub, bound_dev)}

      t_jwt = next(S.sync(jwt))
      assert device_ids(j.uid) == [""], "the device-less client writes the per-user row"
      before = row(j.uid, "")

      t_dev = next(S.sync(dev))
      t_bound = next(S.sync(bound))
      assert device_ids(j.uid) == Enum.sort(["", dev.dev, bound_dev])
      assert row(j.uid, "") == before, "device-bound requests do not touch the '' row, byte for byte"

      j2 = S.sync(jwt, t_jwt)
      assert is_binary(next(j2))
      assert token_and_anchor(j.uid, "").since_token == core(next(j2))
      assert is_binary(next(S.sync(dev, t_dev))) and is_binary(next(S.sync(bound, t_bound)))
      assert token_and_anchor(j.uid, "").since_token == core(next(j2)), "still the device-less client's token"
    end

    test "device-less client gets account data and cross-signing by the flags, bound devices by position; neither disturbs the other", %{priv: priv} do
      j = jwt_user!(priv)
      jwt = unbound(j)
      dev = device!(j.uid, "FDD")

      tj = next(S.sync(jwt))
      td = next(S.sync(dev))
      put_ad!(dev, "org.fd.flag", %{"v" => 1})
      assert :ok = CrossSigningKeyStore.put_keys(j.uid, T.cross_signing_keys(j.uid, "A"))

      d1 = S.sync(dev, td)
      assert ad_map(d1) == %{"org.fd.flag" => %{"v" => 1}} and j.uid in changed(d1)
      assert ad_flags(j.uid) == [["org.fd.flag", true]] and cs_flag(j.uid) == true, "the bound device cleared no flag"

      j1 = S.sync(jwt, tj)
      assert ad_map(j1) == %{"org.fd.flag" => %{"v" => 1}} and j.uid in changed(j1), "the device-less client still gets both by the flags"
      assert ad_flags(j.uid) == [["org.fd.flag", false]] and cs_flag(j.uid) == false, "and clears them, as today"
      assert ad_events(S.sync(jwt, next(j1))) == [] and ad_events(S.sync(dev, next(d1))) == []

      # the device-less client's read did not hide anything from a later bound device
      c = device!(j.uid, "FDC")
      assert ad_map(S.sync(c)) == %{"org.fd.flag" => %{"v" => 1}}
    end

    test "D10 device-less fallback: the own user is listed (request with a since) and the flag is still consumed", %{priv: priv} do
      j = jwt_user!(priv)
      jwt = unbound(j)
      _ = S.sync(jwt)
      assert :ok = CrossSigningKeyStore.put_keys(j.uid, T.cross_signing_keys(j.uid, "A"))

      body = S.sync(jwt, "stale-token")
      assert j.uid in changed(body) and Enum.count(changed(body), &(&1 == j.uid)) == 1
      refute j.uid in left_users(body)
      assert cs_flag(j.uid) == false, "a device-less fallback consumes the flag as today"
      assert changed(S.sync(jwt)) == [], "no since: no entry"
    end

    test "D11 for a device-less client: a waiting request is woken by a PUT and returns the entry through the flags", %{priv: priv} do
      j = jwt_user!(priv)
      jwt = unbound(j)
      dev = device!(j.uid, "FDD")
      tj = next(S.sync(jwt))

      poll = Task.async(fn -> timed(jwt, tj, timeout: 15_000) end)
      wait_polling(j.uid)
      put_ad!(dev, "org.fd.wake", %{"v" => 1})

      assert {body, ms} = Task.await(poll, 25_000)
      assert ms < 6_000, "took #{ms} ms"
      assert ad_map(body) == %{"org.fd.wake" => %{"v" => 1}}
    end
  end

  # ═══ Scenario 9: a token issued before the change ═══════════════════════════════════════════════════════════════════════════

  describe "Scenario 9 - a token stored under the per-user key falls back once" do
    test "a next_batch stored under '' before the update: one initial-shaped answer, then incremental, '' row untouched" do
      f = shared!()
      m1 = message!(f.o, f.room, "m1")
      # the pre-change world: the device's token lives under the per-user key
      T.sql!("DELETE FROM sync_tokens WHERE user_id = $1 AND device_id = $2", [f.uid, f.a.dev])
      # DELIBERATE amendment by story sync-stream-position (D3), old -> new: the cursor rows reference the token row of their device (FK), so moving the row to
      # the '' key needs the pre-change world's shape: no cursor rows (the table did not exist then). The scenario itself (one fallback, '' row untouched) is unchanged.
      T.sql!("DELETE FROM sync_room_cursors WHERE user_id = $1 AND device_id = $2", [f.uid, f.b.dev])
      T.sql!("UPDATE sync_tokens SET device_id = '' WHERE user_id = $1 AND device_id = $2", [f.uid, f.b.dev])
      legacy_row = row(f.uid, "")
      assert [_] = legacy_row

      first = S.sync(f.b, f.tb)
      assert_snapshot(first, f.room, [m1])
      assert f.uid in changed(first), "D10: the client cannot know it was a fallback"
      assert device_ids(f.uid) == Enum.sort(["", f.b.dev]), "the device now has its own row"
      assert row(f.uid, "") == legacy_row, "no '' compat read or write"

      m2 = message!(f.o, f.room, "m2")
      assert_incremental(S.sync(f.b, next(first)), f.room, m2, [m1])
    end
  end

  # ═══ Scenario 10 + SECURITY: foreign, malformed, empty, oversize since ═══════════════════════════════════════════════════════

  describe "Scenario 10 - a foreign or malformed since token is never accepted" do
    test "SECURITY: B presents A's valid next_batch: 200 initial-shaped for B, A's row byte-identical, A's token still works" do
      f = shared!()
      m1 = message!(f.o, f.room, "m1")
      a1 = S.sync(f.a, f.ta) |> assert_incremental(f.room, m1)
      a_row = row(f.uid, f.a.dev)

      body = S.sync(f.b, next(a1))
      assert_snapshot(body, f.room, [m1])
      assert f.uid in changed(body)
      assert row(f.uid, f.a.dev) == a_row, "device A's row is byte-identical after B used A's token"

      m2 = message!(f.o, f.room, "m2")
      assert_incremental(S.sync(f.a, next(a1)), f.room, m2, [m1])
    end

    test "SECURITY: a new device (no row) presenting A's next_batch gets the initial-shaped answer and its own row, A's row untouched" do
      f = shared!()
      m1 = message!(f.o, f.room, "m1")
      a1 = S.sync(f.a, f.ta)
      a_row = row(f.uid, f.a.dev)
      c = device!(f.uid, "FDC")

      body = S.sync(c, next(a1))
      assert_snapshot(body, f.room, [m1])
      assert [_] = row(f.uid, c.dev)
      assert row(f.uid, f.a.dev) == a_row
    end

    test "SECURITY: user Y presents X's valid next_batch: Y gets its OWN snapshot and account data, nothing of X, X's rows byte-identical" do
      f = shared!()
      secret = message!(f.o, f.room, "x-room-secret")
      marker = "x-ad-secret-#{T.rand(6)}"
      put_ad!(f.a, "m.secret_storage.default_key", %{"key" => marker})
      x1 = S.sync(f.a, f.ta)
      assert get_in(ad_map(x1), ["m.secret_storage.default_key", "key"]) == marker
      x_rows = rows(f.uid)

      y = S.user!("FDY")
      y_room = S.make_room(y, %{"preset" => "private_chat"})
      y_marker = message!(y, y_room, "y-room")
      put_ad!(y, "m.secret_storage.default_key", %{"key" => "y-key"})

      body = S.sync(y, next(x1))
      raw = Jason.encode!(body)
      assert snapshot?(body, y_room) and y_marker in bodies(body, y_room), "Y's own snapshot"
      assert ad_map(body) == %{"m.secret_storage.default_key" => %{"key" => "y-key"}}
      for leaked <- [secret, marker, f.room, f.anchor], do: refute(raw =~ leaked, "nothing of X: #{leaked}")
      refute Map.has_key?(S.section(body, "join"), f.room)

      assert rows(f.uid) == x_rows, "X's sync_tokens rows (every device) are byte-identical"
      assert T.sql!("SELECT count(*) FROM sync_tokens WHERE user_id = $1", [y.uid]).rows == [[1]], "Y has exactly its own row"
    end

    test "SECURITY: a malformed, empty or oversize since is a 200 initial-shaped answer; other devices' and users' rows byte-identical" do
      f = shared!()
      m1 = message!(f.o, f.room, "m1")
      other = S.user!("FDO2")
      S.make_room(other, %{})
      _ = S.sync(other)
      before_b = row(f.uid, f.b.dev)
      before_o = rows(other.uid)

      cases = ["!!!", "....", "a.b.c", "x.99999999999999999999999", "..", "%00", "=", String.duplicate("A", 100_000), String.duplicate("1.", 5_000)]

      for since <- cases do
        conn = S.sync_conn(f.a, since: since, timeout: 0)
        assert conn.status == 200, "since #{inspect(String.slice(since, 0, 20))}: #{conn.status}"
        body = T.json(conn)
        assert is_binary(next(body))
        assert_snapshot(body, f.room, [m1])
        assert f.uid in changed(body), "a request that carried a since lists the own user on a fallback"
        refute f.uid in left_users(body)
      end

      empty = S.sync_conn(f.a, since: "", timeout: 0)
      assert empty.status == 200
      assert changed(T.json(empty)) == [], "an empty since counts as absent"
      assert snapshot?(T.json(empty), f.room)

      assert row(f.uid, f.b.dev) == before_b
      assert rows(other.uid) == before_o
      assert device_ids(f.uid) == Enum.sort([f.a.dev, f.b.dev]), "no row appeared"
      assert [_] = row(f.uid, f.a.dev)
    end

    test "SECURITY: the device key is the authenticated device only: device_id / deviceId parameters are ignored" do
      f = shared!()
      for param <- ["device_id", "deviceId", "device"] do
        conn = T.matrix_request(:get, "/_matrix/client/v3/sync?timeout=0&#{param}=FOREIGN", f.a.at)
        assert conn.status == 200
      end

      assert device_ids(f.uid) == Enum.sort([f.a.dev, f.b.dev]), "no FOREIGN row, no row of any other key"
      assert S.in_section?(S.sync(f.a, nil, device_id: "FOREIGN"), "join", f.room)
      assert "FOREIGN" not in device_ids(f.uid)
    end

    test "SECURITY: a forged position suffix in the token cannot suppress global account data (positions live in the row)" do
      f = shared!()
      put_ad!(f.b, "m.secret_storage.default_key", %{"key" => "must-arrive"})
      forged = core(f.ta) <> ".9223372036854775807"

      body = S.sync(f.a, forged)
      assert ad_map(body) == %{"m.secret_storage.default_key" => %{"key" => "must-arrive"}}

      # the old-format token (no suffix at all) is no shortcut either
      put_ad!(f.b, "org.fd.second", %{"v" => 1})
      assert Map.has_key?(ad_map(S.sync(f.b, core(f.tb))), "org.fd.second")
    end

    # DELIBERATE amendment by story sync-stream-position (D8, the `cj` (b) mitigation), old -> new: a retry with the SAME since after a lost response used to FALL BACK
    # (snapshot + own user in device_lists.changed + every account data row); the previous generation now stays valid for one generation, so the retry is INCREMENTAL.
    # "loses nothing" stays: the lost response's room events and global account data (the previous generation's account data position) come again; the own user is
    # listed only by a fallback (D10), which this is not.
    test "SECURITY: a retry with the SAME since after a lost response is incremental and loses nothing: the events and all account data of the lost response again" do
      f = shared!()
      m1 = message!(f.o, f.room, "m1")
      put_ad!(f.a, "org.fd.one", %{"v" => 1})
      first = S.sync(f.a, f.ta)
      assert m1 in bodies(first, f.room) and ad_map(first) == %{"org.fd.one" => %{"v" => 1}}

      retry = S.sync(f.a, f.ta)
      assert_incremental(retry, f.room, m1)
      assert ad_map(retry) == %{"org.fd.one" => %{"v" => 1}}, "the entry is delivered again by the retry (never missed)"
    end
  end

  # ═══ Scenarios 11-13: teardown ═══════════════════════════════════════════════════════════════════════════════════════════════

  describe "Scenario 11 - a deleted device's old token is rejected" do
    test "POST /logout of device A: its token and last next_batch give 401 M_UNKNOWN_TOKEN, no (user, A) row comes back, B untouched" do
      f = shared!()
      a1 = S.sync(f.a, f.ta)
      assert [_] = row(f.uid, f.a.dev)
      assert T.matrix_request(:post, "/_matrix/client/v3/logout", f.a.at, body: %{}).status == 200
      assert row(f.uid, f.a.dev) == [], "the device teardown removed the row"
      b_row = row(f.uid, f.b.dev)

      T.assert_unknown_token(S.sync_conn(f.a, since: next(a1), timeout: 0), false)
      assert row(f.uid, f.a.dev) == [], "no row was re-created by the rejected request"
      assert row(f.uid, f.b.dev) == b_row
    end

    test "DELETE /devices/{A} through B: 401 M_UNKNOWN_TOKEN, the row with its positions is gone and not re-created" do
      T.put_env_scoped(:uia_fresh_auth_seconds, 86_400)
      f = shared!()
      put_ad!(f.a, "org.fd.one", %{"v" => 1})
      a1 = S.sync(f.a, f.ta)
      assert {ad, _} = positions(f.uid, f.a.dev)
      assert ad > 0

      assert T.matrix_request(:delete, "/_matrix/client/v3/devices/" <> f.a.dev, f.b.at, body: %{}).status == 200
      T.assert_unknown_token(S.sync_conn(f.a, since: next(a1), timeout: 0), false)
      assert row(f.uid, f.a.dev) == [], "the row (and with it the positions) of the deleted device is gone and not re-created"
    end
  end

  describe "Scenario 12 - a re-created device id does not resume the deleted device's sync" do
    test "a new session with the same device id and the old next_batch gets an initial-shaped fallback, never a delta" do
      T.put_env_scoped(:uia_fresh_auth_seconds, 86_400)
      f = shared!()
      m1 = message!(f.o, f.room, "m1")
      a1 = S.sync(f.a, f.ta) |> assert_incremental(f.room, m1)

      assert T.matrix_request(:delete, "/_matrix/client/v3/devices/" <> f.a.dev, f.b.at, body: %{}).status == 200
      reborn = %{f.a | at: T.legacy_session!(f.uid, f.a.dev, expires_at: S.session_expiry()).at}

      body = S.sync(reborn, next(a1))
      assert_snapshot(body, f.room, [m1])
      assert f.uid in changed(body)
    end
  end

  describe "Scenario 13 - device deletion, logout and erasure remove the since tokens and the positions" do
    test "DELETE /devices/{A} removes (user, A), (user, B) stays; POST /delete_devices likewise" do
      T.put_env_scoped(:uia_fresh_auth_seconds, 86_400)
      f = shared!()
      put_ad!(f.a, "org.fd.one", %{"v" => 1})
      S.sync(f.a, f.ta)
      S.sync(f.b, f.tb)
      c = device!(f.uid, "FDC")
      S.sync(c)
      assert device_ids(f.uid) == Enum.sort([f.a.dev, f.b.dev, c.dev])
      b_row = row(f.uid, f.b.dev)

      assert T.matrix_request(:delete, "/_matrix/client/v3/devices/" <> f.a.dev, f.b.at, body: %{}).status == 200
      assert device_ids(f.uid) == Enum.sort([f.b.dev, c.dev])
      assert row(f.uid, f.b.dev) == b_row

      assert T.matrix_request(:post, "/_matrix/client/v3/delete_devices", f.b.at, body: %{"devices" => [c.dev]}).status == 200
      assert device_ids(f.uid) == [f.b.dev]
    end

    test "the erasure removes every sync_tokens row of the user ('' row too) and leaves other users' rows" do
      {f, stranger, stranger_rows} = three_rows_and_a_stranger!()

      admin = %{http_request_headers: %{"x-user-id" => "@admin:test.local", "x-system-role" => "admin"}}
      req = %Core.DeleteUserKeysRequest{admin_user_id: "@admin:test.local", target_user_id: f.uid, reason: "atdd erasure"}
      assert %Core.DeleteUserKeysResponse{status: "keys_deleted"} = Nebu.Matrix.EventDispatcher.Server.delete_user_keys(req, admin)

      assert rows(f.uid) == [], "no row of the erased user remains"
      assert rows(stranger.uid) == stranger_rows
    end

    test "POST /logout/all removes every sync_tokens row of the user ('' row too) and leaves other users' rows" do
      {f, stranger, stranger_rows} = three_rows_and_a_stranger!()

      assert T.matrix_request(:post, "/_matrix/client/v3/logout/all", f.b.at, body: %{}).status == 200

      assert rows(f.uid) == []
      assert rows(stranger.uid) == stranger_rows
    end

    test "an admin deactivation removes every sync_tokens row of the user and leaves other users' rows" do
      {f, stranger, stranger_rows} = three_rows_and_a_stranger!()

      admin = %{http_request_headers: %{"x-user-id" => "@admin:test.local", "x-system-role" => "admin"}}
      assert %Core.DeactivateUserResponse{ok: true} = Nebu.Matrix.EventDispatcher.Server.deactivate_user(%Core.DeactivateUserRequest{user_id: f.uid}, admin)

      assert rows(f.uid) == []
      assert rows(stranger.uid) == stranger_rows
    end
  end

  # the user with devices A and B and a '' row (three rows), and a stranger with one row
  defp three_rows_and_a_stranger! do
    f = shared!()
    stranger = S.user!("FDS")
    _ = S.sync(stranger)
    S.sync(f.a, f.ta)
    S.sync(f.b, f.tb)

    T.sql!(
      "INSERT INTO sync_tokens (user_id, device_id, since_token, last_event_id, updated_at) VALUES ($1, '', 'legacy', NULL, 1) ON CONFLICT (user_id, device_id) DO UPDATE SET since_token = 'legacy'",
      [f.uid]
    )

    assert length(rows(f.uid)) == 3, "precondition: one row per device and the per-user row"
    {f, stranger, rows(stranger.uid)}
  end

  # ═══ failure direction: deliver again, never miss ═════════════════════════════════════════════════════════════════════════════

  # Hides a column from the runtime role by renaming it (privileged, restored in `after` AND in on_exit). A restore that fails is NOT swallowed: it raises,
  # so a half-restored shared database fails loudly instead of breaking later tests with confusing `column does not exist` errors.
  defp with_hidden_columns!(columns, fun) do
    restore = fn ->
      for {table, col} <- columns do
        hidden = "fd_hidden_" <> col

        %{rows: [[n]]} =
          T.privileged_sql!(
            "SELECT count(*) FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = $1 AND column_name = $2",
            [table, hidden]
          )

        if n == 1, do: T.privileged_sql!("ALTER TABLE #{table} RENAME COLUMN #{hidden} TO #{col}")
      end

      :ok
    end

    on_exit(restore)
    for {table, col} <- columns, do: T.privileged_sql!("ALTER TABLE #{table} RENAME COLUMN #{col} TO fd_hidden_#{col}")

    try do
      fun.()
    after
      restore.()
    end
  end

  describe "failure direction (deliver again, never miss)" do
    # DELIBERATE amendment by story sync-stream-position (D7 / D8), old -> new: the token write is now ONE guarded transaction that also re-bases the two position
    # columns (`prev_account_data_pos` / `prev_cross_signing_pos` := the base positions), so a `sync_tokens` whose position columns are unreadable can no longer be
    # written at all. It used to answer 200 with the entry delivered (the token upsert never touched those columns). The failure direction stays "deliver again, never
    # miss": the request fails closed (a handled 500 / 503, or a crash the test sees as a WrapperError; NEVER a 200 that advanced a token), NOTHING is written, the
    # client's old next_batch stays valid, and once the columns are back the SAME token delivers the entry and the own user.
    test "unreadable and unwritable sync_tokens position columns: the sync fails closed (no 200, no token advanced); the SAME next_batch then delivers the entry and the own user" do
      f = shared!()
      put_ad!(f.a, "org.fd.one", %{"v" => 1})
      assert :ok = CrossSigningKeyStore.put_keys(f.uid, T.cross_signing_keys(f.uid, "A"))
      before = row(f.uid, f.a.dev)

      outcome = with_hidden_columns!([{"sync_tokens", "account_data_pos"}, {"sync_tokens", "cross_signing_pos"}], fn -> S.sync_conn(f.a, since: f.ta, timeout: 0) end)

      # story D21 (1): a failed persist is a handled 503 M_UNAVAILABLE, no token persisted
      assert outcome.status == 503, "a failed persist is the handled 503, got #{outcome.status}"
      assert T.json(outcome)["errcode"] == "M_UNAVAILABLE"
      assert row(f.uid, f.a.dev) == before, "nothing was written: the token row is byte-identical"

      retry = S.sync(f.a, f.ta)
      assert ad_map(retry) == %{"org.fd.one" => %{"v" => 1}}, "the entry is delivered (again): the old next_batch is still valid"
      assert f.uid in changed(retry), "and the own user after the cross-signing change"
    end

    test "an unreadable account_data.stream_pos: the sync answers 200 (never raises), and the entry arrives with the next sync after the column is back" do
      f = shared!()
      put_ad!(f.a, "org.fd.one", %{"v" => 1})

      first = with_hidden_columns!([{"account_data", "stream_pos"}], fn -> S.sync(f.a, f.ta) end)
      assert is_binary(next(first))
      assert ad_events(first) == [], "nothing could be read"

      assert ad_map(S.sync(f.a, next(first))) == %{"org.fd.one" => %{"v" => 1}}, "the position did not advance past the unread row: it is delivered now"
    end

    test "an unreadable cross_signing_keys.changed_pos: the sync answers 200, and the own user is listed by the next sync after the column is back" do
      f = shared!()
      assert :ok = CrossSigningKeyStore.put_keys(f.uid, T.cross_signing_keys(f.uid, "A"))

      first = with_hidden_columns!([{"cross_signing_keys", "changed_pos"}], fn -> S.sync(f.a, f.ta) end)
      assert is_binary(next(first))

      assert f.uid in changed(S.sync(f.a, next(first))), "the change was never reported as delivered, so it is reported now"
    end

    # review cycle 0, m1: an initial-shaped answer whose account data read fails delivered nothing; a client that reset its state
    # (Element "Clear cache and reload", or any no-since sync) must get every row with its next delta, so the position goes back to 0
    for {label, since} <- [{"an initial sync (no since)", nil}, {"a fallback (stale since)", "stale-token"}] do
      test "#{label} with an unreadable account_data.stream_pos sets account_data_pos back to 0; the next delta delivers every row" do
        f = shared!()
        put_ad!(f.a, "org.fd.one", %{"v" => 1})
        put_ad!(f.a, "org.fd.two", %{"v" => 2})
        a1 = S.sync(f.a, f.ta)
        assert map_size(ad_map(a1)) == 2
        assert {ad_before, _} = positions(f.uid, f.a.dev)
        assert ad_before == max_ad_pos(f.uid) and ad_before > 0, "precondition: the device was sent both rows"

        reset = with_hidden_columns!([{"account_data", "stream_pos"}], fn -> S.sync(f.a, unquote(since)) end)
        assert is_binary(next(reset))
        assert ad_events(reset) == [], "nothing could be read"
        assert {0, _} = positions(f.uid, f.a.dev), "the initial-shaped answer delivered no account data: the position goes back to 0"
        assert token_and_anchor(f.uid, f.a.dev).since_token == core(next(reset)), "the row holds the token of that answer"

        delta = S.sync(f.a, next(reset))
        assert ad_map(delta) == %{"org.fd.one" => %{"v" => 1}, "org.fd.two" => %{"v" => 2}}, "every row is delivered with the next delta"
        assert elem(positions(f.uid, f.a.dev), 0) == max_ad_pos(f.uid)
        assert ad_events(S.sync(f.a, next(delta))) == [], "and then not again"
      end
    end

    test "a failed account data read in a TRUE delta keeps account_data_pos (the rows above it come with the next sync)" do
      f = shared!()
      put_ad!(f.a, "org.fd.one", %{"v" => 1})
      a1 = S.sync(f.a, f.ta)
      {ad_before, _} = positions(f.uid, f.a.dev)
      assert ad_before > 0

      put_ad!(f.a, "org.fd.two", %{"v" => 2})
      a2 = with_hidden_columns!([{"account_data", "stream_pos"}], fn -> S.sync(f.a, next(a1)) end)
      assert ad_events(a2) == []
      assert {^ad_before, _} = positions(f.uid, f.a.dev), "a delta keeps the position (its client still holds the older rows)"
      assert ad_map(S.sync(f.a, next(a2))) == %{"org.fd.two" => %{"v" => 2}}
    end
  end

  # ═══ failed writes (review cycle 0, m3 / m4) ═════════════════════════════════════════════════════════════════════════════════

  # every INSERT/UPDATE of `table` for `uid` raises (privileged trigger), removed in on_exit
  defp block_writes!(table, uid) do
    name = "fd_block_" <> T.rand(5)

    T.privileged_sql!(
      "CREATE FUNCTION #{name}() RETURNS trigger AS $$ BEGIN RAISE EXCEPTION 'fd: write blocked'; END $$ LANGUAGE plpgsql"
    )

    T.privileged_sql!("CREATE TRIGGER #{name} BEFORE INSERT OR UPDATE ON #{table} FOR EACH ROW WHEN (NEW.user_id = '#{uid}') EXECUTE FUNCTION #{name}()")

    remove = fn ->
      T.privileged_sql!("DROP TRIGGER IF EXISTS #{name} ON #{table}")
      T.privileged_sql!("DROP FUNCTION IF EXISTS #{name}()")
    end

    on_exit(remove)
    remove
  end

  describe "failed writes answer 500 M_UNKNOWN and log only the error kind" do
    test "a failed global account data PUT: 500 M_UNKNOWN, no row, no wake-up; the log has the kind, never the content" do
      f = shared!()
      remove = block_writes!("account_data", f.uid)
      :ok = :pg.join("user:#{f.uid}", self())
      secret = "fd-secret-content-#{T.rand(8)}"

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          send(self(), {:resp, put_ad(f.a, "m.secret_storage.default_key", %{"key" => secret})})
        end)

      assert_received {:resp, conn}
      assert conn.status == 500, "got #{conn.status}: #{conn.resp_body}"
      assert T.json(conn)["errcode"] == "M_UNKNOWN"
      refute conn.resp_body =~ secret
      assert log =~ "global account data write failed: Postgrex.Error", "the error kind is logged: #{inspect(log)}"
      refute log =~ secret, "the content is never logged"
      refute log =~ "write blocked", "the error message is never logged"

      assert T.sql!("SELECT count(*) FROM account_data WHERE user_id = $1", [f.uid]).rows == [[0]]
      refute_receive {:account_data_changed, _}, 300
      :pg.leave("user:#{f.uid}", self())

      # (a rolled-back upsert may still have drawn a sequence value, nextval is not transactional; no row carries it)
      remove.()
      put_ad!(f.a, "m.secret_storage.default_key", %{"key" => "ok"})
      assert ad_map(S.sync(f.a, f.ta)) == %{"m.secret_storage.default_key" => %{"key" => "ok"}}
    end

    test "a failed FIRST cross-signing upload: 500 M_UNKNOWN, nothing stored, nothing listed; the log has the kind, never key material" do
      f = shared!()
      keys = T.cross_signing_keys(f.uid, "FIRST")
      material = keys["master_key"]["keys"] |> Map.values() |> hd()
      remove = block_writes!("cross_signing_keys", f.uid)

      log = ExUnit.CaptureLog.capture_log(fn -> send(self(), {:resp, T.device_signing_upload(f.a.at, keys)}) end)
      assert_received {:resp, conn}
      assert conn.status == 500, "got #{conn.status}: #{conn.resp_body}"
      assert T.json(conn)["errcode"] == "M_UNKNOWN"
      assert log =~ "cross-signing key write failed: Postgrex.Error", "the error kind is logged: #{inspect(log)}"
      refute log =~ material, "no key material in the log"
      refute log =~ "write blocked", "the error message is never logged"
      assert T.stored_master(f.uid) == nil
      refute f.uid in changed(S.sync(f.a, f.ta)), "nothing was stamped"

      remove.()
      assert T.device_signing_upload(f.a.at, keys).status == 200, "works once the fault is gone"
    end
  end

  describe "the key is user + device" do
    test "two users with the SAME device id string keep separate rows and tokens, each incremental with its own token" do
      u1 = T.provision_user!()
      u2 = T.provision_user!()
      dev = "FDSAME" <> String.upcase(T.rand(2))
      a = %{uid: u1, dev: dev, at: T.legacy_session!(u1, dev, expires_at: S.session_expiry()).at}
      b = %{uid: u2, dev: dev, at: T.legacy_session!(u2, dev, expires_at: S.session_expiry()).at}

      ta = next(S.sync(a))
      tb = next(S.sync(b))
      assert device_ids(u1) == [dev] and device_ids(u2) == [dev]
      assert token_and_anchor(u1, dev).since_token != token_and_anchor(u2, dev).since_token

      a2 = S.sync(a, ta)
      b2 = S.sync(b, tb)
      assert is_binary(next(a2)) and is_binary(next(b2))
      assert token_and_anchor(u1, dev).since_token == core(next(a2))
      assert token_and_anchor(u2, dev).since_token == core(next(b2)), "u2's row was not touched by u1's sync"
    end
  end

  # ═══ rate behaviour ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

  describe "rate behaviour" do
    test "the per-IP /sync limit still applies to a multi-device user and a rejected request writes nothing" do
      f = shared!()
      c = device!(f.uid, "FDC")
      ip = {10, 77, :rand.uniform(200), :rand.uniform(200)}
      request = fn user, query -> T.matrix_request(:get, "/_matrix/client/v3/sync?timeout=0" <> query, user.at, ip: ip) end

      limited =
        Enum.find_value(1..140, fn _ ->
          conn = request.(c, "")
          if conn.status == 429, do: conn
        end)

      assert limited, "the 600/min (burst 100) limit of the sync tier is unchanged"
      assert T.json(limited)["errcode"] == "M_LIMIT_EXCEEDED"

      before = rows(f.uid)
      assert request.(f.a, "&since=" <> f.ta).status == 429
      assert rows(f.uid) == before, "a request rejected by the limiter reads and writes no sync state"
    end
  end
end
