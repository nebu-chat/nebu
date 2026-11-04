defmodule Nebu.Matrix.DeviceKeyDirectorySyncHttpTest do
  @moduledoc """
  Acceptance tests (REAL database, full `Nebu.Web.Router`) of the E2E fields of `GET /sync` for story `device-key-directory` (REQ-2026-013), Matrix CS v1.18 `#e2e-extensions-to-sync`:
  oracle edge cases 3, 4, 13, 14 and 15, decisions D11 and D12 of the story.

    * `device_one_time_keys_count` is per DEVICE and ALWAYS contains `signed_curve25519` (0 when none);
    * `device_unused_fallback_key_types` is ALWAYS a list and PER DEVICE (it was a user aggregate: a second device's used fallback key was masked by the first device's unused one);
    * `device_lists` `{changed, left}` (always both lists): peers whose device or cross-signing keys changed, users who newly share a joined room, the caller itself for its own devices,
      `left` for users who share nothing any more; an INITIAL sync lists no peer; a FALLBACK of a request that carried a `since` lists every shared user; the position is the last token group.
  """
  use ExUnit.Case, async: false

  alias Nebu.Matrix.DeviceKeyDirectoryTestSupport, as: DK
  alias Nebu.Matrix.ModerationTestSupport, as: S
  alias Nebu.Matrix.ToDeviceTestSupport, as: TD
  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration

  setup do
    T.reset_rate_limits()
    Nebu.Test.ServerName.pin!(T.server_name())
    TD.disable_rate_limit()
    on_exit(fn -> T.restore_rate_limits() end)
    alice = TD.user!("DKA")
    alice2 = TD.device!(alice, "DKB")
    peer = TD.user!("DKP")
    room = TD.share!(alice, peer)
    stranger = TD.user!("DKS")
    {:ok, a: alice, a2: alice2, p: peer, room: room, s: stranger}
  end

  describe "device_one_time_keys_count: per device, signed_curve25519 always present" do
    test "a device without any key reports {signed_curve25519: 0} in the initial AND in an incremental sync", %{a: a} do
      first = DK.sync(a)
      assert first["device_one_time_keys_count"] == %{"signed_curve25519" => 0}
      assert DK.sync(a, TD.next(first))["device_one_time_keys_count"] == %{"signed_curve25519" => 0}
    end

    test "the count is the number of UNCLAIMED keys of THIS device; another device of the user has its own count", %{a: a, a2: a2} do
      DK.publish!(a, otks: ["A1", "A2", "A3"])
      DK.publish!(a2, otks: ["B1"])
      assert {DK.sync(a)["device_one_time_keys_count"], DK.sync(a2)["device_one_time_keys_count"]} == {%{"signed_curve25519" => 3}, %{"signed_curve25519" => 1}}
    end

    test "a claim lowers the count of the claimed device only; at zero the entry stays (0)", %{a: a, p: p} do
      DK.publish!(a, otks: ["A1", "A2"])
      DK.claim_one!(p, a)
      assert DK.sync(a)["device_one_time_keys_count"] == %{"signed_curve25519" => 1}
      DK.claim_one!(p, a)
      assert DK.sync(a)["device_one_time_keys_count"] == %{"signed_curve25519" => 0}
    end

    test "other algorithms are listed next to signed_curve25519 (which is 0 when only they exist)", %{a: a} do
      DK.upload!(a, %{"one_time_keys" => %{"curve25519:Z1" => "k1", "curve25519:Z2" => "k2"}})
      assert DK.sync(a)["device_one_time_keys_count"] == %{"curve25519" => 2, "signed_curve25519" => 0}
    end

    test "the key upload answer keeps its own member name one_time_key_counts and the same numbers", %{a: a} do
      assert DK.upload!(a, %{"one_time_keys" => DK.otks(["A1", "A2"])})["one_time_key_counts"] == %{"signed_curve25519" => 2}
    end
  end

  describe "device_unused_fallback_key_types: always a list, per device (oracle D2)" do
    test "a device without a fallback key reports [] (initial, incremental and an empty long poll)", %{a: a} do
      first = DK.sync(a)
      assert first["device_unused_fallback_key_types"] == []
      assert DK.sync(a, TD.next(first))["device_unused_fallback_key_types"] == []
      assert DK.sync(a, TD.next(first), timeout: 200)["device_unused_fallback_key_types"] == []
    end

    test "an unused fallback key lists its algorithm, a claim that hands it out removes it, a new upload puts it back", %{a: a, p: p} do
      DK.publish!(a, fallback: "FFFF")
      assert DK.sync(a)["device_unused_fallback_key_types"] == ["signed_curve25519"]
      DK.claim_one!(p, a)
      assert DK.sync(a)["device_unused_fallback_key_types"] == []
      DK.publish!(a, keys: false, fallback: "NEW1")
      assert DK.sync(a)["device_unused_fallback_key_types"] == ["signed_curve25519"]
    end

    test "PER DEVICE: a used fallback key of device 2 is NOT masked by an unused one of device 1 (the aggregate did), and vice versa", %{a: a, a2: a2, p: p} do
      DK.publish!(a, fallback: "AAAA")
      DK.publish!(a2, fallback: "BBBB")
      DK.claim_one!(p, a2)
      assert {DK.sync(a)["device_unused_fallback_key_types"], DK.sync(a2)["device_unused_fallback_key_types"]} == {["signed_curve25519"], []}
      DK.claim_one!(p, a)
      DK.publish!(a2, keys: false, fallback: "CCCC")
      assert {DK.sync(a)["device_unused_fallback_key_types"], DK.sync(a2)["device_unused_fallback_key_types"]} == {[], ["signed_curve25519"]}
    end

    test "several algorithms: only the unused ones are listed, sorted", %{a: a, p: p} do
      DK.upload!(a, %{"fallback_keys" => %{"signed_curve25519:F1" => DK.fallback_obj("F1"), "zz_alg:F2" => DK.fallback_obj("F2"), "aa_alg:F3" => DK.fallback_obj("F3")}})
      assert DK.sync(a)["device_unused_fallback_key_types"] == ["aa_alg", "signed_curve25519", "zz_alg"]
      DK.claim_one!(p, a, "zz_alg")
      assert DK.sync(a)["device_unused_fallback_key_types"] == ["aa_alg", "signed_curve25519"]
    end

    test "a one-time key claim does not touch the fallback list while one-time keys last", %{a: a, p: p} do
      DK.publish!(a, otks: ["A1"], fallback: "FFFF")
      DK.claim_one!(p, a)
      assert DK.sync(a)["device_unused_fallback_key_types"] == ["signed_curve25519"]
    end

    test "two users with the SAME device id keep separate lists (the claim of one marks only its own fallback)", %{a: _a} do
      id = "SAME" <> String.upcase(T.rand(3))
      u1 = TD.user_with_device!(id)
      u2 = TD.user_with_device!(id)
      caller = TD.user!("DKC")
      TD.share!(caller, u1)
      DK.publish!(u1, fallback: "F1")
      DK.publish!(u2, fallback: "F2")
      DK.claim_one!(caller, u1)
      assert {DK.sync(u1)["device_unused_fallback_key_types"], DK.sync(u2)["device_unused_fallback_key_types"]} == {[], ["signed_curve25519"]}
    end
  end

  describe "device_lists on an INCREMENTAL sync (oracle edge 13)" do
    test "a peer's new device identity keys put the peer into `changed`, once; the next sync lists nobody", %{a: a, p: p} do
      t0 = DK.token(a)
      DK.publish!(p)
      body = DK.sync(a, t0)
      assert DK.dl_changed(body) == [p.uid] and DK.dl_left(body) == []
      assert DK.dl(DK.sync(a, TD.next(body))) == %{"changed" => [], "left" => []}
    end

    test "a peer's device delete and a peer's cross-signing change are in `changed` too", %{a: a, p: p} do
      second = TD.device!(p, "DKX")
      DK.publish!(second)
      t0 = DK.token(a)
      :ok = Nebu.Matrix.end_device_session(second.uid, second.dev)
      b1 = DK.sync(a, t0)
      assert DK.dl_changed(b1) == [p.uid]
      :ok = Nebu.Matrix.CrossSigningKeyStore.put_keys(p.uid, T.cross_signing_keys(p.uid, "1"))
      assert DK.dl_changed(DK.sync(a, TD.next(b1))) == [p.uid]
    end

    test "every device of the caller sees the change (the position lives in each device's own token)", %{a: a, a2: a2, p: p} do
      ta = DK.token(a)
      tb = DK.token(a2)
      DK.publish!(p)
      assert {DK.dl_changed(DK.sync(a, ta)), DK.dl_changed(DK.sync(a2, tb))} == {[p.uid], [p.uid]}
    end

    test "NEGATIVE: a stranger's changes, and an invited-only user's changes, are never listed", %{a: a, s: s} do
      TD.invite_only!(a, s)
      t0 = DK.token(a)
      DK.publish!(s)
      :ok = Nebu.Matrix.CrossSigningKeyStore.put_keys(s.uid, T.cross_signing_keys(s.uid, "x"))
      assert DK.dl(DK.sync(a, t0)) == %{"changed" => [], "left" => []}
    end

    test "a peer who newly shares a joined room is `changed`; a peer who leaves the last shared room is `left`", %{a: a, p: p, room: room, s: s} do
      t0 = DK.token(a)
      S.join!(s, S.public_room(a))
      S.leave!(p, room)
      body = DK.sync(a, t0)
      assert {DK.dl_changed(body), DK.dl_left(body)} == {[s.uid], [p.uid]}
    end

    test "oracle edge 14: leave, change a device while apart, rejoin: `changed` on the rejoin sync", %{a: a, p: p, room: room} do
      t0 = DK.token(a)
      S.leave!(p, room)
      DK.publish!(p)
      S.invite!(a, room, p)
      S.join!(p, room)
      body = DK.sync(a, t0)
      assert {DK.dl_changed(body), DK.dl_left(body)} == {[p.uid], []}
    end

    test "the OWN user is listed when the caller adds or deletes an own device with keys (for its other devices and the writer)", %{a: a, a2: a2} do
      ta = DK.token(a)
      DK.publish!(a2)
      assert DK.dl_changed(DK.sync(a, ta)) == [a.uid]
      tb = DK.token(a)
      :ok = Nebu.Matrix.end_device_session(a2.uid, a2.dev)
      assert DK.dl_changed(DK.sync(a, tb)) == [a.uid]
    end

    test "the own user is never in `left`, and a user in `left` is not also in `changed`", %{a: a, p: p, room: room} do
      t0 = DK.token(a)
      S.leave!(p, room)
      DK.publish!(a)
      body = DK.sync(a, t0)
      assert a.uid not in DK.dl_left(body) and p.uid in DK.dl_left(body) and p.uid not in DK.dl_changed(body)
    end

    test "a long poll with a change already pending answers at once (no wait for the timeout)", %{a: a, p: p} do
      t0 = DK.token(a)
      DK.publish!(p)
      started = System.monotonic_time(:millisecond)
      body = DK.sync(a, t0, timeout: 10_000)
      assert System.monotonic_time(:millisecond) - started < 4_000
      assert DK.dl_changed(body) == [p.uid]
    end

    test "device_lists is in EVERY response with both lists, also an empty long poll", %{a: a} do
      t0 = DK.token(a)
      assert DK.dl(DK.sync(a, t0, timeout: 150)) == %{"changed" => [], "left" => []}
    end

    test "a retry with the same since token lists the same change again (the position lives in the token, nothing is consumed)", %{a: a, p: p} do
      t0 = DK.token(a)
      DK.publish!(p)
      assert {DK.dl_changed(DK.sync(a, t0)), DK.dl_changed(DK.sync(a, t0))} == {[p.uid], [p.uid]}
    end
  end

  describe "device_lists on an INITIAL sync and on a FALLBACK" do
    test "an initial sync lists NO peer, whatever happened before it, and carries a position", %{a: a, p: p, s: s} do
      DK.publish!(p)
      DK.publish!(s)
      body = DK.sync(a)
      assert DK.dl(body) == %{"changed" => [], "left" => []}
      assert is_integer(DK.dl_pos(TD.next(body)))
    end

    test "an unknown core token (a fallback of a since request) lists EVERY shared user and the caller, never a stranger", %{a: a, p: p, s: s} do
      DK.publish!(s)
      body = DK.sync(a, "s2_" <> T.rand(8) <> ".0.d1")
      assert DK.dl_changed(body) == Enum.sort([p.uid, a.uid])
      assert DK.dl_left(body) == []
      assert is_integer(DK.dl_pos(TD.next(body)))
    end

    test "IDOR: presenting another user's token is a fallback for the presenter: only the PRESENTER's shared users are listed", %{a: a, p: p} do
      carol = TD.user!("DKC")
      q = TD.user!("DKQ")
      TD.share!(carol, q)
      foreign = DK.token(a)
      body = DK.sync(carol, foreign)
      assert DK.dl_changed(body) == Enum.sort([q.uid, carol.uid])
      refute p.uid in DK.dl_changed(body)
    end
  end

  describe "the token (D11): <core>.<account data>[.<to-device>].d<device-list position>" do
    test "every next_batch ends with the group .d<digits>; the other groups keep their order", %{a: a, p: p} do
      t = DK.token(a)
      assert t =~ ~r/\A[A-Za-z0-9_\-]+\.[0-9]+\.d[0-9]+\z/, "token: #{t}"
      TD.tell!(p, a, "m.dummy", %{"n" => 1})
      t2 = TD.next(DK.sync(a, t))
      assert t2 =~ ~r/\A[A-Za-z0-9_\-]+\.[0-9]+\.[0-9]+\.d[0-9]+\z/, "with a to-device position: #{t2}"
    end

    test "a token WITHOUT the group (old, or from an old node) works: 200, every shared user listed once, the next token has the group", %{a: a, p: p} do
      t0 = DK.token(a)
      body = DK.sync(a, DK.strip_dl(t0))
      assert DK.dl_changed(body) == Enum.sort([p.uid, a.uid]), "conservative: unknown position"
      t1 = TD.next(body)
      assert is_integer(DK.dl_pos(t1))
      assert DK.dl(DK.sync(a, t1)) == %{"changed" => [], "left" => []}
    end

    test "a stripped token is still the SAME core: the rooms part of the answer is incremental, not a fallback snapshot", %{a: a} do
      room = S.public_room(a)
      t0 = DK.token(a)
      S.say!(a, room, "later")
      body = DK.sync(a, DK.strip_dl(t0))
      assert [_] = S.join_timeline(body, room), "the room delta carries the new message only"
    end

    test "a garbled group makes the token unknown to the core (a fallback), never an error", %{a: a} do
      t0 = DK.token(a)
      assert is_map(DK.sync(a, DK.strip_dl(t0) <> ".dxyz"))
    end

    test "a FORGED huge position is no error and leaks nothing: the lists are empty, other users' data stays out", %{a: a, p: p, s: s} do
      DK.publish!(p)
      DK.publish!(s)
      t0 = DK.token(a)
      forged = DK.strip_dl(t0) <> ".d9223372036854775807"
      body = DK.sync(a, forged)
      assert DK.dl(body) == %{"changed" => [], "left" => []}
    end

    test "a QUIET device's position advances to the visible bound: changes of users it does not share a room with move it, so the next sync does not rescan them (D11)", %{a: a, p: p, s: s} do
      t0 = DK.token(a)
      DK.publish!(s)
      stranger_pos = DK.keys_pos(s.uid)
      body = DK.sync(a, t0)
      assert DK.dl(body) == %{"changed" => [], "left" => []}, "a stranger's change concerns nobody the caller shares a room with"
      t1 = TD.next(body)
      assert DK.dl_pos(t1) >= stranger_pos, "the token moved past the rows the reads covered (#{DK.dl_pos(t0)} -> #{DK.dl_pos(t1)}, stranger at #{stranger_pos})"
      assert DK.dl_pos(t1) > DK.dl_pos(t0)

      DK.publish!(p)
      body2 = DK.sync(a, t1)
      assert DK.dl_changed(body2) == [p.uid], "a later change of a peer is still reported after the advance"
      assert DK.dl_pos(TD.next(body2)) >= DK.keys_pos(p.uid)
    end

    test "the position never goes backwards when the presented one is above the bound (forged or after an erasure)", %{a: a} do
      t0 = DK.token(a)
      high = DK.dl_pos(t0) + 1_000_000
      forged = DK.strip_dl(t0) <> ".d" <> Integer.to_string(high)
      assert DK.dl_pos(TD.next(DK.sync(a, forged))) == high
    end

    test "the to-device acknowledgement still works with the new group: a message is delivered once and removed by the next token", %{a: a, p: p} do
      TD.tell!(p, a, "m.dummy", %{"n" => 1})
      first = DK.sync(a)
      assert length(TD.events(first)) == 1
      assert TD.events(DK.sync(a, TD.next(first))) == []
    end
  end

  describe "newly shared users through room events and the caller joining" do
    test "the CALLER joining a room lists the members of that room in `changed` of the next sync", %{a: a, s: s} do
      other = TD.user!("DKO")
      room = TD.share!(s, other)
      t0 = DK.token(a)
      S.invite!(s, room, a)
      S.join!(a, room)
      assert DK.dl_changed(DK.sync(a, t0)) == Enum.sort([s.uid, other.uid])
    end

    test "an INVITATION lists nobody", %{a: a, s: s} do
      t0 = DK.token(a)
      TD.invite_only!(s, a)
      assert DK.dl_changed(DK.sync(a, t0)) == []
    end
  end
end
