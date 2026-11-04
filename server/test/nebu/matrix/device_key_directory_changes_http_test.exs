defmodule Nebu.Matrix.DeviceKeyDirectoryChangesHttpTest do
  @moduledoc """
  Acceptance tests (REAL database, full `Nebu.Web.Router`) of `GET /_matrix/client/v3/keys/changes` for story `device-key-directory` (REQ-2026-013), Matrix CS v1.18
  `#get_matrixclientv3keyschanges`: Gherkin scenario 4, oracle edge cases 11, 12 and 14, decisions D9 / D10 / D17 of the story.

  `from` and `to` are sync `next_batch` tokens (the device-list position is their last group `.d<n>`). `changed` and `left` are ALWAYS lists. A user appears in `changed` only when the
  caller shares a joined room with it (both sides `join`) or it is the caller itself; a user who shares nothing with the caller NEVER appears, whatever it does.
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
    peer = TD.user!("DKP")
    room = TD.share!(alice, peer)
    stranger = TD.user!("DKS")
    {:ok, a: alice, p: peer, room: room, s: stranger}
  end

  # the changes between two fresh initial-sync tokens around `fun`
  defp between(a, fun) do
    from = DK.token(a)
    fun.()
    to = DK.token(a)
    DK.changes!(a, from, to)
  end

  describe "Scenario 4 - changed device lists are reported between two sync tokens" do
    test "a peer who ADDS a device (identity keys uploaded) after the from token is in `changed`, nobody is in `left`", %{a: a, p: p} do
      assert between(a, fn -> DK.publish!(p) end) == %{"changed" => [p.uid], "left" => []}
    end

    test "a peer who DELETES a device that had identity keys is in `changed`", %{a: a, p: p} do
      second = TD.device!(p, "DKX")
      DK.publish!(second)
      assert between(a, fn -> :ok = Nebu.Matrix.end_device_session(second.uid, second.dev) end) == %{"changed" => [p.uid], "left" => []}
    end

    test "no change between the tokens: changed and left are empty lists (present, not omitted)", %{a: a, p: p} do
      DK.publish!(p)
      assert between(a, fn -> :ok end) == %{"changed" => [], "left" => []}
    end

    test "a change BEFORE the from token is not reported", %{a: a, p: p} do
      DK.publish!(p)
      from = DK.token(a)
      assert DK.changes!(a, from, DK.token(a)) == %{"changed" => [], "left" => []}
    end

    test "a change AFTER the to token is not reported (to is an upper bound), and is reported by a later range", %{a: a, p: p} do
      from = DK.token(a)
      to = DK.token(a)
      DK.publish!(p)
      assert DK.changes!(a, from, to)["changed"] == []
      assert DK.changes!(a, from, DK.token(a))["changed"] == [p.uid]
    end

    test "NEGATIVE: a user the caller shares no room with never appears, however often it changes its devices", %{a: a, s: s} do
      assert between(a, fn ->
               DK.publish!(s)
               DK.publish!(s, keys: "2")
               :ok = Nebu.Matrix.CrossSigningKeyStore.put_keys(s.uid, T.cross_signing_keys(s.uid, "x"))
             end) == %{"changed" => [], "left" => []}
    end

    test "NEGATIVE: a user who is only INVITED into a room of the caller does not appear", %{a: a, s: s} do
      TD.invite_only!(a, s)
      assert between(a, fn -> DK.publish!(s) end)["changed"] == []
    end

    test "the changes are read through the CALLER's shared rooms: two callers with different peers see different users", %{a: a, p: p} do
      carol = TD.user!("DKC")
      q = TD.user!("DKQ")
      TD.share!(carol, q)
      from_a = DK.token(a)
      from_c = DK.token(carol)
      DK.publish!(p)
      DK.publish!(q)
      assert DK.changes!(a, from_a, DK.token(a))["changed"] == [p.uid]
      assert DK.changes!(carol, from_c, DK.token(carol))["changed"] == [q.uid]
    end

    test "a user who changed several times and shares several rooms is listed ONCE", %{a: a, p: p} do
      TD.share!(a, p)
      res = between(a, fn -> for t <- ~w(1 2 3), do: DK.publish!(p, keys: t) end)
      assert res["changed"] == [p.uid]
    end
  end

  describe "what counts as a device-list change (D10, D17)" do
    test "a keyless device appearing is NO change; the moment it uploads identity keys it is", %{a: a, p: p} do
      assert between(a, fn -> TD.device!(p, "DKK") end) == %{"changed" => [], "left" => []}
      second = TD.device!(p, "DKL")
      assert between(a, fn -> DK.publish!(second) end)["changed"] == [p.uid]
    end

    test "deleting a KEYLESS device is no change", %{a: a, p: p} do
      second = TD.device!(p, "DKK")
      assert between(a, fn -> :ok = Nebu.Matrix.end_device_session(second.uid, second.dev) end)["changed"] == []
    end

    test "re-uploading the IDENTICAL identity keys is no change, uploading DIFFERENT keys for the device is", %{a: a, p: p} do
      DK.publish!(p)
      assert between(a, fn -> DK.publish!(p) end)["changed"] == []
      assert between(a, fn -> DK.publish!(p, keys: "2") end)["changed"] == [p.uid]
    end

    test "uploading one-time keys or a fallback key is no change", %{a: a, p: p} do
      DK.publish!(p)
      assert between(a, fn -> DK.publish!(p, keys: false, otks: ["A1", "A2"], fallback: "FFFF") end)["changed"] == []
    end

    test "claiming a key is no change (the claimed device's list is the same)", %{a: a, p: p} do
      DK.publish!(p, otks: ["A1"])
      assert between(a, fn -> DK.claim_one!(a, p) end)["changed"] == []
    end

    test "a cross-signing key upload of the peer is a change", %{a: a, p: p} do
      assert between(a, fn -> :ok = Nebu.Matrix.CrossSigningKeyStore.put_keys(p.uid, T.cross_signing_keys(p.uid, "1")) end)["changed"] == [p.uid]
    end

    test "renaming a device WITH keys is a change (the name is in unsigned.device_display_name), renaming a keyless device is not", %{a: a, p: p} do
      keyed = TD.device!(p, "DKK")
      keyless = TD.device!(p, "DKL")
      DK.publish!(keyed)
      rename = fn d -> T.matrix_request(:put, "/_matrix/client/v3/devices/" <> d.dev, d.at, body: %{"display_name" => "New " <> T.rand(3)}) end
      assert between(a, fn -> assert rename.(keyed).status == 200 end)["changed"] == [p.uid]
      assert between(a, fn -> assert rename.(keyless).status == 200 end)["changed"] == []
    end

    test "the CALLER's own device add / delete / cross-signing upload lists the caller itself (its other devices must learn it)", %{a: a} do
      second = TD.device!(a, "DKY")
      assert between(a, fn -> DK.publish!(second) end)["changed"] == [a.uid]
      assert between(a, fn -> :ok = Nebu.Matrix.end_device_session(second.uid, second.dev) end)["changed"] == [a.uid]
      assert between(a, fn -> :ok = Nebu.Matrix.CrossSigningKeyStore.put_keys(a.uid, T.cross_signing_keys(a.uid, "own")) end)["changed"] == [a.uid]
    end

    test "a user who is in the changes because of its keys AND newly shares a room is still listed once", %{a: a, s: s} do
      res =
        between(a, fn ->
          DK.publish!(s)
          S.join!(s, S.public_room(a))
        end)

      assert res["changed"] == [s.uid]
    end
  end

  describe "membership: newly shared users are `changed`, users who share nothing any more are `left`" do
    test "a peer who JOINS another room of the caller (a new room, no key change) is in `changed`", %{a: a, s: s} do
      room = S.public_room(a)
      assert between(a, fn -> S.join!(s, room) end) == %{"changed" => [s.uid], "left" => []}
    end

    test "the CALLER joining a room that others are in lists those others (they newly share a room)", %{a: a, s: s} do
      other = TD.user!("DKO")
      room = TD.share!(s, other)
      assert between(a, fn -> S.invite!(s, room, a) && S.join!(a, room) end) == %{"changed" => Enum.sort([s.uid, other.uid]), "left" => []}
    end

    test "an invitation does not count: only the join puts the invitee into `changed`", %{a: a, s: s} do
      room = S.make_room(a, %{"preset" => "private_chat"})
      assert between(a, fn -> S.invite!(a, room, s) end)["changed"] == []
      assert between(a, fn -> S.join!(s, room) end)["changed"] == [s.uid]
    end

    test "a peer who leaves the ONLY shared room is in `left` (and not in `changed`)", %{a: a, p: p, room: room} do
      assert between(a, fn -> S.leave!(p, room) end) == %{"changed" => [], "left" => [p.uid]}
    end

    test "a peer who leaves one of TWO shared rooms is not `left`", %{a: a, p: p, room: room} do
      TD.share!(a, p)
      assert between(a, fn -> S.leave!(p, room) end) == %{"changed" => [], "left" => []}
    end

    test "the CALLER leaving the only shared room lists the peer in `left`; the caller itself is never in `left`", %{a: a, p: p, room: room} do
      res = between(a, fn -> S.leave!(a, room) end)
      assert res["left"] == [p.uid] and a.uid not in res["left"]
    end

    test "NEGATIVE: a user who never shared a room with the caller is not in `left` when it leaves a room of its own", %{a: a, s: s} do
      other = TD.user!("DKO")
      room = TD.share!(s, other)
      assert between(a, fn -> S.leave!(other, room) end) == %{"changed" => [], "left" => []}
    end

    test "a peer who left BEFORE the from token and changes devices while apart is neither `changed` nor `left`", %{a: a, p: p, room: room} do
      S.leave!(p, room)
      assert between(a, fn -> DK.publish!(p) end) == %{"changed" => [], "left" => []}
    end

    test "oracle edge 14: a user who leaves, changes a device and REJOINS is in `changed` on the rejoin", %{a: a, p: p, room: room} do
      from = DK.token(a)
      S.leave!(p, room)
      DK.publish!(p)
      S.invite!(a, room, p)
      S.join!(p, room)
      res = DK.changes!(a, from, DK.token(a))
      assert res == %{"changed" => [p.uid], "left" => []}
    end

    test "a peer who leaves a room AFTER the caller left it is not `left` (the caller must still be joined to learn of a leave)", %{a: a, p: p, room: room} do
      S.leave!(a, room)
      from = DK.token(a)
      S.leave!(p, room)
      assert DK.changes!(a, from, DK.token(a)) == %{"changed" => [], "left" => []}
    end

    test "the caller still joined: the peer who leaves the only shared room is listed (the guard does not hide a real loss)", %{a: a, p: p, room: room} do
      from = DK.token(a)
      S.leave!(p, room)
      assert DK.changes!(a, from, DK.token(a))["left"] == [p.uid]
    end

    test "the user whose leave was reported once is not reported again by a later range", %{a: a, p: p, room: room} do
      from = DK.token(a)
      S.leave!(p, room)
      to = DK.token(a)
      assert DK.changes!(a, from, to)["left"] == [p.uid]
      assert DK.changes!(a, to, DK.token(a)) == %{"changed" => [], "left" => []}
    end
  end

  describe "the rate limit: per user tier keys_changes, 60 per minute, burst 20, charged before any database work" do
    test "twenty immediate requests pass, the 21st is a 429 M_LIMIT_EXCEEDED with retry_after_ms", %{a: a} do
      t = DK.token(a)
      TD.enable_rate_limit()
      for i <- 1..20, do: assert(DK.changes(a, t, t).status == 200, "request #{i}")
      c = DK.changes(a, t, t)
      body = c |> TD.assert_429("the 21st request") |> TD.json()
      assert body["errcode"] == "M_LIMIT_EXCEEDED" and body["retry_after_ms"] == 1000
    end

    test "the bucket is per user: an exhausted caller does not limit another user, and it refills one token per second", %{a: a, p: p} do
      t = DK.token(a)
      tp = DK.token(p)
      TD.enable_rate_limit()
      for _ <- 1..20, do: DK.changes(a, t, t)
      assert DK.changes(a, t, t).status == 429
      assert DK.changes(p, tp, tp).status == 200
      DK.set_clock(DK.clock() + 1_100)
      assert DK.changes(a, t, t).status == 200
      assert DK.changes(a, t, t).status == 429
    end

    test "a request refused by the limiter does no database work: even a malformed token answers 429, not 400", %{a: a} do
      t = DK.token(a)
      TD.enable_rate_limit()
      for _ <- 1..20, do: DK.changes(a, t, t)
      assert DK.changes_raw(a, "?from=!!!&to=!!!").status == 429
    end
  end

  describe "oracle edge 12 - the tokens" do
    test "`from` missing: 400 M_MISSING_PARAM; `to` missing: 400 M_MISSING_PARAM; both missing; an empty value counts as missing", %{a: a} do
      t = DK.token(a)

      for query <- ["", "?to=" <> t, "?from=" <> t, "?from=&to=" <> t, "?from=" <> t <> "&to="] do
        TD.assert_error(DK.changes_raw(a, query), 400, "M_MISSING_PARAM")
      end
    end

    test "a MALFORMED `from` or `to` is 400 M_INVALID_PARAM: odd characters, broken or misplaced groups, overflow, over 512 bytes", %{a: a} do
      good = DK.token(a)

      bad = [
        "!!!",
        "has space",
        "s2_x.d",
        "s2_x.dx",
        "s2_x..5",
        "s2_x.5.6.7.d1",
        "s2_x.d5.6",
        "s2_x.5.d99999999999999999999",
        "s2_x.5.d9223372036854775808",
        String.duplicate("a", 600),
        "s2_ä",
        "s2_x/../y",
        "s2_x?y",
        "%00"
      ]

      for t <- bad do
        enc = URI.encode_www_form(t)
        TD.assert_error(DK.changes_raw(a, "?from=#{enc}&to=#{good}"), 400, "M_INVALID_PARAM")
        TD.assert_error(DK.changes_raw(a, "?from=#{good}&to=#{enc}"), 400, "M_INVALID_PARAM")
      end
    end

    test "a list or map valued parameter (`from[]=x`) is a 400 M_INVALID_PARAM, not a crash", %{a: a} do
      t = DK.token(a)
      assert DK.changes_raw(a, "?from[]=" <> t <> "&to=" <> t).status == 400
      assert DK.changes_raw(a, "?from[x]=" <> t <> "&to=" <> t).status == 400
    end

    test "a malformed token never reaches the database: the answer is the same 400 with and without a shared room", %{a: a, s: s} do
      t = DK.token(a)
      assert TD.shape(DK.changes_raw(a, "?from=!!!&to=" <> t)) |> elem(0) == 400
      assert TD.shape(DK.changes_raw(s, "?from=!!!&to=" <> t)) |> elem(0) == 400
    end

    test "a well-formed token WITHOUT a position ('expired') is no error: 200, every shared user is `changed`, `left` is empty, no stranger", %{a: a, p: p, s: s} do
      DK.publish!(s)
      stale = DK.strip_dl(DK.token(a))
      refute stale =~ ".d"
      body = DK.changes!(a, stale, DK.token(a))
      assert p.uid in body["changed"] and s.uid not in body["changed"]
      assert body["left"] == []
    end

    test "a token of any shape the alphabet allows (an unknown core, a bare core, positions only) is well formed", %{a: a, p: p} do
      to = DK.token(a)

      for from <- ["s2_unknowncore.5", "s2_unknowncore", "s2_unknowncore.5.6", "s2_nobody.0.0"] do
        body = DK.changes!(a, from, to)
        assert p.uid in body["changed"], "#{from}: #{inspect(body)}"
      end
    end

    test "an expired `from` ignores the `to` bound (everything shared is listed)", %{a: a, p: p} do
      to = DK.token(a)
      assert p.uid in DK.changes!(a, "s2_old.1.2", to)["changed"]
    end

    test "`to` without a position ('now') is no bound: a change after `from` is reported", %{a: a, p: p} do
      from = DK.token(a)
      DK.publish!(p)
      assert DK.changes!(a, from, DK.strip_dl(DK.token(a)))["changed"] == [p.uid]
    end

    test "a `from` that is not before `to` (equal, swapped) gives empty lists", %{a: a, p: p} do
      from = DK.token(a)
      DK.publish!(p)
      to = DK.token(a)
      assert DK.changes!(a, from, from) == %{"changed" => [], "left" => []}
      assert DK.changes!(a, to, from) == %{"changed" => [], "left" => []}
    end

    test "a FORGED huge position is well formed up to int8 and simply hides everything: no error, no foreign data", %{a: a, p: p} do
      DK.publish!(p)
      assert DK.changes!(a, "s2_x.0.d9223372036854775807", "s2_y.0.d9223372036854775807") == %{"changed" => [], "left" => []}
    end

    test "IDOR: a token of ANOTHER user is only a position: the answer is about the caller's own shared users", %{a: a, p: p} do
      carol = TD.user!("DKC")
      q = TD.user!("DKQ")
      TD.share!(carol, q)
      foreign = DK.token(a)
      DK.publish!(p)
      DK.publish!(q)
      body = DK.changes!(carol, foreign, DK.token(carol))
      assert body["changed"] == [q.uid], "carol never learns about alice's peer: #{inspect(body)}"
    end
  end

  describe "authentication and routes" do
    test "no Authorization header: 401 M_MISSING_TOKEN; a junk token: 401 M_UNKNOWN_TOKEN", %{a: a} do
      t = DK.token(a)
      TD.assert_error(TD.req(:get, DK.changes_path() <> "?from=#{t}&to=#{t}", nil), 401, "M_MISSING_TOKEN")
      TD.assert_error(TD.req(:get, DK.changes_path() <> "?from=#{t}&to=#{t}", "junk" <> T.rand(6)), 401, "M_UNKNOWN_TOKEN")
    end

    test "authentication comes first: an anonymous request with a malformed token is a 401, not a 400", %{a: _a} do
      TD.assert_error(TD.req(:get, DK.changes_path() <> "?from=!!!&to=!!!", nil), 401, "M_MISSING_TOKEN")
    end

    test "the answer is JSON with exactly the members changed and left", %{a: a} do
      t = DK.token(a)
      c = DK.changes(a, t, t)
      assert c.status == 200 and (T.header(c, "content-type") || "") =~ ~r{^application/json}
      assert Map.keys(TD.json(c)) |> Enum.sort() == ["changed", "left"]
    end
  end

  describe "positions: the tokens order the changes" do
    test "the position of an initial token is above every change made before it and below every change made after it", %{a: a, p: p} do
      DK.publish!(p)
      before_pos = DK.keys_pos(p.uid)
      t0 = DK.token(a)
      DK.publish!(p, keys: "2")
      assert before_pos < DK.dl_pos(t0) and DK.dl_pos(t0) < DK.keys_pos(p.uid)
    end

    test "every sync response carries a position and it never goes backwards", %{a: a, p: p} do
      t0 = DK.token(a)
      DK.publish!(p)
      body = DK.sync(a, t0)
      assert DK.dl_pos(TD.next(body)) >= DK.dl_pos(t0)
      assert DK.dl_pos(TD.next(DK.sync(a, TD.next(body)))) >= DK.dl_pos(TD.next(body))
    end
  end
end
