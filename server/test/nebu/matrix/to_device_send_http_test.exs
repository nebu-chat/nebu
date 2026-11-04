defmodule Nebu.Matrix.ToDeviceSendHttpTest do
  @moduledoc """
  Acceptance tests for story `to-device-messaging` (epic e2ee-client-support, REQ-2026-012), the SEND half: `PUT /_matrix/client/v3/sendToDevice/{eventType}/{txnId}` over the real
  stack (`Nebu.Web.Router` + `Plug.Test`, real `Nebu.Repo`, real rooms through the real routes; users and devices through `Nebu.Matrix.ToDeviceTestSupport`). Delivery is observed
  through `GET /sync` (the sibling file `to_device_sync_http_test.exs` pins the sync side: acknowledgement, continuation, wake-up).

  Gherkin scenarios of the story: 1 (specific device), 2 (`*`), 4 (unknown / unreachable recipient). Scenario 3 (acknowledgement) is in the sync file, scenario 5 (device deletion) in
  `to_device_purge_test.exs`. The 20 Gherkin-testable behaviours of the oracle context are spread over the files; here: 1, 2, 3, 4, 5, 6, 7, 14, 19, 20.

  Decisions pinned here (beyond the story text; see the story file, `## Decisions`):

    * The recipient restriction (shared room with either side `join` or `invite`, or the sender's own device) is evaluated at SEND time; every other recipient is skipped silently,
      with an answer that is byte-identical to a delivered one (no existence / membership oracle), also for a malformed user id or device id.
    * `*` expands at send time to the devices that exist then; for the sender's own user the sending device is excluded; an explicit device entry of the same user wins over `*`
      (one copy per device, whatever the order of the keys).
    * A transaction is scoped to (user, device, event type, txn id): the token is irrelevant (a new access token of the same device is the same transaction), another device,
      another user, another event type and the room `send` endpoint are independent transactions. A request that is refused (400) does not burn its txn id.
    * Everything is validated before anything is stored (a request is stored whole or not at all).
  """
  use ExUnit.Case, async: false

  alias Nebu.Matrix.ModerationTestSupport, as: S
  alias Nebu.Matrix.ToDeviceTestSupport, as: TD
  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration

  setup do
    T.reset_rate_limits()
    Nebu.Test.ServerName.pin!(T.server_name())
    TD.disable_rate_limit()
    on_exit(fn -> T.restore_rate_limits() end)
    :ok
  end

  # alice (one device) and bob (devices B1, B2) who share a room
  defp pair! do
    alice = TD.user!("TDA")
    bob1 = TD.user!("TDB")
    bob2 = TD.device!(bob1, "TDC")
    _room = TD.share!(alice, bob1)
    %{alice: alice, bob1: bob1, bob2: bob2}
  end

  defp td(device, since \\ nil), do: TD.events(TD.sync(device, since))

  @content %{"transaction_id" => "verif-1", "timestamp" => 1_700_000_000_000, "methods" => ["m.sas.v1", "m.qr_code.show.v1"], "from_device" => "ALICEDEV"}

  # ═══ Scenario 1: a message to a specific device ═══════════════════════════════════════════════════════════════════════════════

  describe "Scenario 1 - a message to a specific device is delivered via sync" do
    test "alice sends m.key.verification.request to B1: 200 {}, B1's next sync has exactly sender, type and content; B2 has nothing" do
      f = pair!()
      c = TD.put_send(f.alice, "m.key.verification.request", TD.txn(), TD.msg(f.bob1, @content))
      assert c.status == 200
      assert TD.json(c) == %{}
      assert c.resp_body == "{}"
      assert (T.header(c, "content-type") || "") =~ ~r{^application/json}

      assert td(f.bob1) == [TD.ev(f.alice, "m.key.verification.request", @content)]
      assert td(f.bob2) == []
    end

    test "the event has exactly the members sender, type and content (no event_id, no origin_server_ts, no unsigned, no room_id)" do
      f = pair!()
      TD.tell!(f.alice, f.bob1, "m.key.verification.request", @content)
      assert [event] = td(f.bob1)
      assert Enum.sort(Map.keys(event)) == ["content", "sender", "type"]
    end

    test "an INCREMENTAL sync (since = a token taken before the send) delivers it as well" do
      f = pair!()
      since = TD.next(TD.sync(f.bob1))
      TD.tell!(f.alice, f.bob1, "m.room_key_request", %{"action" => "request", "request_id" => "r1"})
      assert td(f.bob1, since) == [TD.ev(f.alice, "m.room_key_request", %{"action" => "request", "request_id" => "r1"})]
    end

    test "the sender is the AUTHENTICATED user: a `sender` inside the content stays content, the top-level sender is alice" do
      f = pair!()
      content = %{"sender" => "@mallory:test.local", "type" => "m.room.message", "event_id" => "$x", "origin_server_ts" => 1}
      TD.tell!(f.alice, f.bob1, "m.dummy", content)
      assert td(f.bob1) == [TD.ev(f.alice, "m.dummy", content)]
    end

    test "the type of the event is the type of the PATH, every message of one request has it" do
      f = pair!()
      TD.send!(f.alice, "m.room_key_request", TD.txn(), TD.merge([TD.msg(f.bob1, %{"a" => 1}), TD.msg(f.bob2, %{"a" => 2})]))
      assert [%{"type" => "m.room_key_request"}] = td(f.bob1)
      assert [%{"type" => "m.room_key_request"}] = td(f.bob2)
    end

    test "content is opaque and transported verbatim: unicode, NUL, big integers, floats, null, nesting, an empty object" do
      f = pair!()

      content = %{
        "algorithm" => "m.olm.v1.curve25519-aes-sha2",
        "ciphertext" => %{"BASE64KEY" => %{"type" => 0, "body" => "AwogE+/=="}},
        "unicode" => "ünï 😀 \u0000 end",
        "big" => 9_007_199_254_740_993,
        "float" => 1.5e-7,
        "null" => nil,
        "empty" => %{},
        "list" => [1, [2, [3, %{"x" => nil}]], "s"],
        "bool" => false
      }

      TD.tell!(f.alice, f.bob1, "m.room.encrypted", content)
      assert td(f.bob1) == [TD.ev(f.alice, "m.room.encrypted", content)]
    end

    test "an EMPTY content object is a message (the content member is present and {})" do
      f = pair!()
      TD.tell!(f.alice, f.bob1, "m.dummy", %{})
      assert td(f.bob1) == [TD.ev(f.alice, "m.dummy", %{})]
    end

    test "the allowlisted types all pass through unchanged (verification, key requests, withheld, secret requests, olm, dummy)" do
      f = pair!()

      types =
        ~w(m.key.verification.request m.key.verification.ready m.key.verification.start m.key.verification.accept m.key.verification.key
           m.key.verification.mac m.key.verification.done m.key.verification.cancel m.room_key_request
           m.room_key.withheld m.secret.request m.room.encrypted m.dummy)

      for {type, i} <- Enum.with_index(types), do: TD.tell!(f.alice, f.bob1, type, %{"i" => i})
      delivered = td(f.bob1)
      assert Enum.map(delivered, & &1["type"]) == types
      assert Enum.map(delivered, & &1["content"]) == for(i <- 0..(length(types) - 1), do: %{"i" => i})
    end

    test "ordering: messages arrive in the order they were sent (several senders interleaved, several requests)" do
      f = pair!()
      carol = TD.user!("TDK")
      TD.share!(carol, f.bob1)

      order =
        for i <- 1..12 do
          sender = if rem(i, 3) == 0, do: carol, else: f.alice
          TD.tell!(sender, f.bob1, "m.dummy", %{"n" => i})
          {sender.uid, i}
        end

      assert Enum.map(td(f.bob1), &{&1["sender"], &1["content"]["n"]}) == order
    end

    test "20 oracle behaviour 20: m.room_key_request `request` then `request_cancellation` are both delivered, in order (no dedup by content)" do
      f = pair!()
      req = %{"action" => "request", "request_id" => "rq-1", "requesting_device_id" => "ALICEDEV", "body" => %{"room_id" => "!r:test.local", "session_id" => "s"}}
      cancel = %{"action" => "request_cancellation", "request_id" => "rq-1", "requesting_device_id" => "ALICEDEV"}
      TD.tell!(f.alice, f.bob1, "m.room_key_request", req)
      since = TD.next(TD.sync(f.bob1))
      TD.tell!(f.alice, f.bob1, "m.room_key_request", cancel)
      TD.tell!(f.alice, f.bob1, "m.room_key_request", cancel)

      assert td(f.bob1, since) == [TD.ev(f.alice, "m.room_key_request", cancel), TD.ev(f.alice, "m.room_key_request", cancel)]
    end

    test "a content with the same bytes sent twice (distinct transactions) is two messages" do
      f = pair!()
      TD.tell!(f.alice, f.bob1, "m.dummy", %{"same" => true})
      TD.tell!(f.alice, f.bob1, "m.dummy", %{"same" => true})
      assert length(td(f.bob1)) == 2
    end
  end

  # ═══ Scenario 2: the wildcard ═════════════════════════════════════════════════════════════════════════════════════════════════

  describe "Scenario 2 - `*` fans out to every device of the user" do
    test "bob has three devices: each device receives exactly one copy, the sender's devices and other users receive nothing" do
      f = pair!()
      bob3 = TD.device!(f.bob1, "TDD")
      carol = TD.user!("TDK")
      TD.share!(f.alice, carol)

      TD.send!(f.alice, "m.room_key_request", TD.txn(), TD.star(f.bob1, @content))
      for dev <- [f.bob1, f.bob2, bob3], do: assert(td(dev) == [TD.ev(f.alice, "m.room_key_request", @content)], "device #{dev.dev}")
      assert td(f.alice) == []
      assert td(carol) == []
      assert TD.queue_count(f.bob1.uid) == 3
    end

    test "`*` to ONESELF: the other devices of the sender receive it, the sending device does not (orchestrator decision; Synapse includes it)" do
      alice1 = TD.user!("TDA")
      alice2 = TD.device!(alice1, "TDE")
      alice3 = TD.device!(alice1, "TDF")

      TD.send!(alice1, "m.secret.request", TD.txn(), TD.star(alice1, %{"action" => "request"}))
      assert td(alice2) == [TD.ev(alice1, "m.secret.request", %{"action" => "request"})]
      assert td(alice3) == [TD.ev(alice1, "m.secret.request", %{"action" => "request"})]
      assert td(alice1) == [], "the sending device is excluded"
      assert TD.queue_count(alice1.uid, alice1.dev) == 0
    end

    test "own devices need no shared room: alice shares no room with anybody and still reaches her other device (self-verification, m.secret.*)" do
      alice1 = TD.user!("TDA")
      alice2 = TD.device!(alice1, "TDE")
      TD.tell!(alice1, alice2, "m.key.verification.request", @content)
      assert td(alice2) == [TD.ev(alice1, "m.key.verification.request", @content)]
    end

    test "an EXPLICIT device entry of the same user wins over `*` (whatever the order of the keys in the body): one copy per device" do
      f = pair!()
      uid = f.bob1.uid
      star = %{"which" => "star"}
      one = %{"which" => "explicit"}

      for {label, raw} <- [
            {"* first", ~s({"messages":{"#{uid}":{"*":#{Jason.encode!(star)},"#{f.bob1.dev}":#{Jason.encode!(one)}}}})},
            {"explicit first", ~s({"messages":{"#{uid}":{"#{f.bob1.dev}":#{Jason.encode!(one)},"*":#{Jason.encode!(star)}}}})}
          ] do
        before1 = TD.queue_count(uid, f.bob1.dev)
        before2 = TD.queue_count(uid, f.bob2.dev)
        c = TD.put_send(f.alice, "m.dummy", TD.txn(), {:raw, raw})
        assert c.status == 200, label
        assert TD.queue_count(uid, f.bob1.dev) == before1 + 1, "#{label}: exactly one copy on B1"
        assert TD.queue_count(uid, f.bob2.dev) == before2 + 1, "#{label}: exactly one copy on B2"
      end

      assert Enum.map(td(f.bob1), & &1["content"]) == [one, one]
      assert Enum.map(td(f.bob2), & &1["content"]) == [star, star]
    end

    test "`*` expands at SEND time: a device created afterwards does not receive the message (oracle behaviour 19)" do
      f = pair!()
      TD.send!(f.alice, "m.dummy", TD.txn(), TD.star(f.bob1, %{"n" => 1}))
      late = TD.device!(f.bob1, "TDL")
      assert td(late) == []
      assert td(f.bob1) == [TD.ev(f.alice, "m.dummy", %{"n" => 1})]
    end

    test "`*` to a user with no device (or none that exists any more): 200, nothing queued" do
      f = pair!()
      lonely = TD.user!("TDN")
      TD.share!(f.alice, lonely)
      T.sql!("DELETE FROM devices WHERE user_id = $1", [lonely.uid])
      TD.send!(f.alice, "m.dummy", TD.txn(), TD.star(lonely, %{"n" => 1}))
      assert TD.queue_count(lonely.uid) == 0
    end

    test "one request may address several users and several devices: every (user, device) gets its own content" do
      f = pair!()
      carol = TD.user!("TDK")
      TD.share!(f.alice, carol)

      TD.send!(f.alice, "m.dummy", TD.txn(), TD.merge([TD.msg(f.bob1, %{"to" => "b1"}), TD.msg(f.bob2, %{"to" => "b2"}), TD.msg(carol, %{"to" => "carol"})]))
      assert td(f.bob1) == [TD.ev(f.alice, "m.dummy", %{"to" => "b1"})]
      assert td(f.bob2) == [TD.ev(f.alice, "m.dummy", %{"to" => "b2"})]
      assert td(carol) == [TD.ev(f.alice, "m.dummy", %{"to" => "carol"})]
    end
  end

  # ═══ Scenario 4: unknown / unreachable recipients ═════════════════════════════════════════════════════════════════════════════

  describe "Scenario 4 - an unknown or unreachable recipient is skipped silently (no existence or membership oracle)" do
    # the answer of a request: everything that could tell recipients apart (status, body, every header except the per-request ones)
    defp shape(conn), do: TD.shape(conn)

    test "Gherkin: carol shares no room with alice (or does not exist): 200 {} and no message is queued for her" do
      f = pair!()
      carol = TD.user!("TDK")
      c = TD.put_send(f.alice, "m.key.verification.request", TD.txn(), TD.msg(carol, @content))
      assert {c.status, TD.json(c)} == {200, %{}}
      assert TD.queue_count(carol.uid) == 0
      assert td(carol) == []

      ghost = "@nobody-#{T.rand(5)}:test.local"
      c = TD.put_send(f.alice, "m.key.verification.request", TD.txn(), TD.msg({ghost, "ANY"}, @content))
      assert {c.status, TD.json(c)} == {200, %{}}
      assert T.sql!("SELECT count(*) FROM to_device_messages WHERE user_id = $1", [ghost]).rows == [[0]]
    end

    test "oracle behaviour 4: every skipped recipient gets the byte-identical answer of a delivered one, nothing is queued" do
      f = pair!()
      carol = TD.user!("TDK")
      content = %{"probe" => true}

      baseline = TD.put_send(f.alice, "m.dummy", TD.txn(), TD.msg(f.bob1, content)) |> shape()
      assert elem(baseline, 0) == 200

      skipped = [
        {"a real user without a shared room", TD.msg(carol, content)},
        {"a real user without a shared room, `*`", TD.star(carol, content)},
        {"an unknown local user", TD.msg({"@nobody-#{T.rand(5)}:test.local", "DEV"}, content)},
        {"a remote user", TD.msg({"@someone:remote.example.org", "DEV"}, content)},
        {"a remote user, `*`", %{"@someone:remote.example.org" => %{"*" => content}}},
        {"an unknown device of a user the sender shares a room with", TD.msg({f.bob1.uid, "NO-SUCH-DEVICE"}, content)},
        {"a malformed user id (no sigil)", %{"bob" => %{"DEV" => content}}},
        {"a malformed user id (no domain)", %{"@bob" => %{"DEV" => content}}},
        {"an empty user id", %{"" => %{"DEV" => content}}},
        {"a user id of 300 bytes", %{("@" <> String.duplicate("a", 300) <> ":test.local") => %{"DEV" => content}}},
        {"a user id with a NUL", %{"@a\u0000b:test.local" => %{"DEV" => content}}},
        {"a device id of 300 bytes", TD.msg({f.bob1.uid, String.duplicate("D", 300)}, content)},
        {"a device id with a NUL", TD.msg({f.bob1.uid, "DE\u0000V"}, content)},
        {"an empty device id", TD.msg({f.bob1.uid, ""}, content)}
      ]

      for {label, messages} <- skipped do
        assert shape(TD.put_send(f.alice, "m.dummy", TD.txn(), messages)) == baseline, "#{label}: the answer differs from a delivered request"
      end

      assert TD.queue_count(carol.uid) == 0
      assert TD.queue_count(f.bob1.uid, "NO-SUCH-DEVICE") == 0
      assert T.sql!("SELECT count(*) FROM to_device_messages WHERE user_id LIKE '@someone:%' OR user_id LIKE '@nobody-%'").rows == [[0]]
      assert TD.queue_count(f.bob1.uid) == 1, "only the baseline message was queued for bob"
    end

    test "work proxy for timing: a delivered recipient and every skipped one issue the SAME number of statements" do
      f = pair!()
      carol = TD.user!("TDK")
      count = fn messages -> TD.statements(fn -> TD.send!(f.alice, "m.dummy", TD.txn(), messages) end, "") |> elem(1) |> length() end

      delivered = count.(TD.msg(f.bob1, %{"n" => 1}))

      for {label, messages} <- [
            {"unshared real user", TD.msg(carol, %{"n" => 1})},
            {"unknown user", TD.msg({"@nobody-#{T.rand(5)}:test.local", "D"}, %{"n" => 1})},
            {"remote user", TD.msg({"@x:remote.example.org", "D"}, %{"n" => 1})},
            {"unknown device", TD.msg({f.bob1.uid, "NOPE"}, %{"n" => 1})},
            {"malformed id", %{"bob" => %{"D" => %{"n" => 1}}}}
          ] do
        assert count.(messages) == delivered, "#{label}: the statement count tells a skipped recipient from a delivered one"
      end
    end

    test "a skipped recipient in a request does not stop the others of the same request" do
      f = pair!()
      carol = TD.user!("TDK")
      TD.send!(f.alice, "m.dummy", TD.txn(), TD.merge([TD.msg(carol, %{"n" => 1}), TD.msg(f.bob1, %{"n" => 2}), TD.msg({"@x:remote.example.org", "D"}, %{"n" => 3})]))
      assert td(f.bob1) == [TD.ev(f.alice, "m.dummy", %{"n" => 2})]
      assert td(carol) == []
    end

    test "no shared room: alice and bob each share a room with carol, but not with each other" do
      alice = TD.user!("TDA")
      bob = TD.user!("TDB")
      carol = TD.user!("TDK")
      TD.share!(carol, alice)
      TD.share!(carol, bob)
      TD.tell!(alice, bob, "m.dummy", %{"n" => 1})
      assert td(bob) == []
      assert TD.queue_count(bob.uid) == 0
    end
  end

  # ═══ the recipient restriction (orchestrator decision) ════════════════════════════════════════════════════════════════════════

  describe "recipient restriction: a shared room where BOTH sides are join, evaluated at send time" do
    defp delivered?(sender, recipient) do
      before = TD.queue_count(recipient.uid, recipient.dev)
      TD.send!(sender, "m.dummy", TD.txn(), TD.msg(recipient, %{"probe" => TD.txn()}))
      TD.queue_count(recipient.uid, recipient.dev) == before + 1
    end

    test "both joined: delivered" do
      alice = TD.user!("TDA")
      bob = TD.user!("TDB")
      TD.share!(alice, bob)
      assert delivered?(alice, bob)
      assert delivered?(bob, alice)
    end

    test "oracle 5 SUPERSEDED: a recipient that is only INVITED gets nothing (200 {}), no send path without consent" do
      alice = TD.user!("TDA")
      bob = TD.user!("TDB")
      TD.invite_only!(alice, bob)
      refute delivered?(alice, bob)
      assert td(bob) == []
    end

    test "the SENDER is only invited, the recipient joined: skipped (both sides must be join)" do
      alice = TD.user!("TDA")
      bob = TD.user!("TDB")
      TD.invite_only!(bob, alice)
      refute delivered?(alice, bob)
    end

    test "an invitation without consent opens no send path (any user could invite anyone); joining opens it" do
      alice = TD.user!("TDA")
      bob = TD.user!("TDB")
      room = TD.invite_only!(alice, bob)
      for _ <- 1..3, do: refute(delivered?(alice, bob))
      assert TD.queue_count(bob.uid) == 0
      S.join!(bob, room)
      assert delivered?(alice, bob)
    end

    test "the recipient left the room: skipped" do
      alice = TD.user!("TDA")
      bob = TD.user!("TDB")
      room = TD.share!(alice, bob)
      S.leave!(bob, room)
      refute delivered?(alice, bob)
    end

    test "the recipient was kicked: skipped" do
      alice = TD.user!("TDA")
      bob = TD.user!("TDB")
      room = TD.share!(alice, bob)
      S.tick()
      assert S.kick(alice, room, bob).status == 200
      refute delivered?(alice, bob)
    end

    test "the recipient was banned: skipped" do
      alice = TD.user!("TDA")
      bob = TD.user!("TDB")
      room = TD.share!(alice, bob)
      S.tick()
      assert S.ban(alice, room, bob).status == 200
      refute delivered?(alice, bob)
    end

    test "the sender left the room: skipped" do
      alice = TD.user!("TDA")
      bob = TD.user!("TDB")
      room = TD.share!(alice, bob)
      S.leave!(alice, room)
      refute delivered?(alice, bob)
    end

    test "the recipient declined the invitation: skipped before and after" do
      alice = TD.user!("TDA")
      bob = TD.user!("TDB")
      room = TD.invite_only!(alice, bob)
      refute delivered?(alice, bob)
      S.leave!(bob, room)
      refute delivered?(alice, bob)
    end

    test "any ONE shared room is enough: a second, left room does not matter; leaving the last shared room ends it" do
      alice = TD.user!("TDA")
      bob = TD.user!("TDB")
      room1 = TD.share!(alice, bob)
      room2 = TD.share!(alice, bob)
      S.leave!(bob, room1)
      assert delivered?(alice, bob)
      S.leave!(bob, room2)
      refute delivered?(alice, bob)
    end

    test "evaluated at SEND time (a): a message queued while the room was shared is still delivered after the recipient left" do
      alice = TD.user!("TDA")
      bob = TD.user!("TDB")
      room = TD.share!(alice, bob)
      TD.tell!(alice, bob, "m.key.verification.request", %{"n" => 1})
      S.leave!(bob, room)
      assert td(bob) == [TD.ev(alice, "m.key.verification.request", %{"n" => 1})]
    end

    test "evaluated at SEND time (b): a room shared only LATER does not deliver the message sent before" do
      alice = TD.user!("TDA")
      bob = TD.user!("TDB")
      TD.tell!(alice, bob, "m.dummy", %{"n" => 1})
      TD.share!(alice, bob)
      assert td(bob) == []
      assert delivered?(alice, bob)
    end

    test "the restriction is per RECIPIENT USER inside one request: bob (shared) gets it, carol (not shared) does not" do
      alice = TD.user!("TDA")
      bob = TD.user!("TDB")
      carol = TD.user!("TDK")
      TD.share!(alice, bob)
      TD.send!(alice, "m.dummy", TD.txn(), TD.merge([TD.star(bob, %{"n" => 1}), TD.star(carol, %{"n" => 1}), TD.star(alice, %{"n" => 1})]))
      assert td(bob) != []
      assert td(carol) == []
    end
  end

  # ═══ transaction ids ═════════════════════════════════════════════════════════════════════════════════════════════════════════

  describe "transaction ids are idempotent per device and path (oracle behaviour 6)" do
    test "the same txn id on the same path twice: both 200 {}, delivered ONCE; the first content wins" do
      f = pair!()
      t = TD.txn()
      c1 = TD.put_send(f.alice, "m.dummy", t, TD.msg(f.bob1, %{"v" => 1}))
      c2 = TD.put_send(f.alice, "m.dummy", t, TD.msg(f.bob1, %{"v" => 2}))
      c3 = TD.put_send(f.alice, "m.dummy", t, TD.msg(f.bob1, %{"v" => 1}))
      assert Enum.map([c1, c2, c3], &{&1.status, &1.resp_body}) == [{200, "{}"}, {200, "{}"}, {200, "{}"}]
      assert td(f.bob1) == [TD.ev(f.alice, "m.dummy", %{"v" => 1})]
    end

    test "a retry that addresses OTHER recipients is still the same transaction: nothing new is queued" do
      f = pair!()
      t = TD.txn()
      TD.send!(f.alice, "m.dummy", t, TD.msg(f.bob1, %{"v" => 1}))
      TD.send!(f.alice, "m.dummy", t, TD.msg(f.bob2, %{"v" => 1}))
      assert td(f.bob2) == []
    end

    test "the same txn id with ANOTHER event type is a different transaction (different path)" do
      f = pair!()
      t = TD.txn()
      TD.send!(f.alice, "m.dummy", t, TD.msg(f.bob1, %{"v" => 1}))
      TD.send!(f.alice, "m.room_key_request", t, TD.msg(f.bob1, %{"v" => 2}))
      assert Enum.map(td(f.bob1), & &1["type"]) == ["m.dummy", "m.room_key_request"]
    end

    test "the same txn id as a ROOM send (`/rooms/{id}/send/{type}/{txn}`) is independent, in both orders" do
      alice = TD.user!("TDA")
      bob = TD.user!("TDB")
      room = TD.share!(alice, bob)
      t1 = TD.txn()
      t2 = TD.txn()
      room_send = fn t -> T.matrix_request(:put, S.path(room, "send/m.dummy/#{t}"), alice.at, body: %{"msgtype" => "m.text", "body" => "hi"}) end

      assert room_send.(t1).status == 200
      TD.send!(alice, "m.dummy", t1, TD.msg(bob, %{"n" => 1}))
      TD.send!(alice, "m.dummy", t2, TD.msg(bob, %{"n" => 2}))
      assert room_send.(t2).status == 200

      assert Enum.map(td(bob), & &1["content"]) == [%{"n" => 1}, %{"n" => 2}]
    end

    test "scope is the DEVICE: another device of the same user with the same txn id is an independent transaction" do
      alice1 = TD.user!("TDA")
      alice2 = TD.device!(alice1, "TDE")
      bob = TD.user!("TDB")
      TD.share!(alice1, bob)
      t = TD.txn()
      TD.send!(alice1, "m.dummy", t, TD.msg(bob, %{"from" => 1}))
      TD.send!(alice2, "m.dummy", t, TD.msg(bob, %{"from" => 2}))
      assert Enum.sort(Enum.map(td(bob), & &1["content"]["from"])) == [1, 2]
    end

    test "scope is the DEVICE, not the token: a new access token of the same device keeps the transaction (the rust-sdk retries after a refresh)" do
      f = pair!()
      t = TD.txn()
      TD.send!(f.alice, "m.dummy", t, TD.msg(f.bob1, %{"v" => 1}))
      refreshed = TD.new_token!(f.alice)
      assert refreshed.at != f.alice.at
      TD.send!(refreshed, "m.dummy", t, TD.msg(f.bob1, %{"v" => 1}))
      assert length(td(f.bob1)) == 1
    end

    test "another USER with the same txn id is an independent transaction" do
      f = pair!()
      carol = TD.user!("TDK")
      TD.share!(carol, f.bob1)
      t = TD.txn()
      TD.send!(f.alice, "m.dummy", t, TD.msg(f.bob1, %{"from" => "alice"}))
      TD.send!(carol, "m.dummy", t, TD.msg(f.bob1, %{"from" => "carol"}))
      assert length(td(f.bob1)) == 2
    end

    test "persisted: the record is a database row (it outlives the queue): after bob acknowledged, a retry of the txn still queues nothing" do
      f = pair!()
      t = TD.txn()
      TD.send!(f.alice, "m.dummy", t, TD.msg(f.bob1, %{"v" => 1}))
      assert TD.txn_count(f.alice.uid, f.alice.dev) == 1

      first = TD.sync(f.bob1)
      assert length(TD.events(first)) == 1
      acked = TD.sync(f.bob1, TD.next(first))
      assert TD.events(acked) == []
      assert TD.queue_count(f.bob1.uid, f.bob1.dev) == 0, "the acknowledgement deleted the queue row"

      TD.send!(f.alice, "m.dummy", t, TD.msg(f.bob1, %{"v" => 1}))
      assert TD.queue_count(f.bob1.uid, f.bob1.dev) == 0, "the retry after the acknowledgement is not queued again"
      assert TD.events(TD.sync(f.bob1, TD.next(acked))) == []
      assert TD.txn_count(f.alice.uid, f.alice.dev) == 1
    end

    test "one record per transaction, scoped to the sending device (a request with no new transaction adds none)" do
      f = pair!()
      t = TD.txn()
      for _ <- 1..3, do: TD.send!(f.alice, "m.dummy", t, TD.msg(f.bob1, %{"v" => 1}))
      assert TD.txn_count(f.alice.uid, f.alice.dev) == 1
      TD.send!(f.alice, "m.dummy", TD.txn(), TD.msg(f.bob1, %{"v" => 1}))
      assert TD.txn_count(f.alice.uid, f.alice.dev) == 2
      assert TD.txn_count(f.bob1.uid) == 0, "the record belongs to the sender, not the recipient"
    end

    test "a refused request (400) does not burn its txn id: the corrected request with the same id is delivered" do
      f = pair!()
      t = TD.txn()
      assert TD.put_send(f.alice, "m.dummy", t, {:body, %{"messages" => "oops"}}).status == 400
      assert TD.put_send(f.alice, "m.dummy", t, {:raw, "{not json"}).status == 400
      assert TD.txn_count(f.alice.uid, f.alice.dev) == 0
      TD.send!(f.alice, "m.dummy", t, TD.msg(f.bob1, %{"v" => 1}))
      assert td(f.bob1) == [TD.ev(f.alice, "m.dummy", %{"v" => 1})]
    end

    test "txn ids with special characters are compared exactly: `a/b` (encoded) and unicode retry once, `a` and `a/b` differ" do
      f = pair!()
      for t <- ["a/b", "tränsäktion-😀", "with space", "a"] do
        TD.send!(f.alice, "m.dummy", t, TD.msg(f.bob1, %{"t" => t}))
        TD.send!(f.alice, "m.dummy", t, TD.msg(f.bob1, %{"t" => t}))
      end

      assert Enum.sort(Enum.map(td(f.bob1), & &1["content"]["t"])) == Enum.sort(["a/b", "tränsäktion-😀", "with space", "a"])
    end
  end

  # ═══ validation ══════════════════════════════════════════════════════════════════════════════════════════════════════════════

  describe "validation (oracle behaviour 14)" do
    test "event types: only the allowlist passes (story e2ee-compliance-channel-guard, D2), everything else is 400 M_INVALID_PARAM and nothing is queued" do
      f = pair!()

      for type <- ["m.key.verification.request"] do
        assert TD.put_send(f.alice, type, TD.txn(), TD.msg(f.bob1, %{"t" => 1})).status == 200, "valid type #{String.slice(type, 0, 20)}"
      end

      # well-formed types that are not on the allowlist (the old regex accepted them)
      for type <- ["A-b_c.d", "x", String.duplicate("a", 255), "org.example.custom_type-1", "1.2.3"] do
        assert TD.assert_error(TD.put_send(f.alice, type, TD.txn(), TD.msg(f.bob1, %{"t" => 1})), 400, "M_INVALID_PARAM"), "not allowlisted type #{String.slice(type, 0, 20)}"
      end

      for type <- ["bad type", "tüpe", "a:b", "x\n", "m.room@x", String.duplicate("a", 256), String.duplicate("é", 130), "a\u0000b", "a+b", "a*b"] do
        assert TD.assert_error(TD.put_send(f.alice, type, TD.txn(), TD.msg(f.bob1, %{"t" => 1})), 400, "M_INVALID_PARAM"), "invalid type #{inspect(String.slice(type, 0, 20))}"
      end

      assert TD.queue_count(f.bob1.uid) == 1
    end

    test "txn ids: 1..255 bytes of text without NUL; 256 bytes and NUL are 400 M_INVALID_PARAM" do
      f = pair!()
      assert TD.put_send(f.alice, "m.dummy", String.duplicate("t", 255), TD.msg(f.bob1, %{"t" => 1})).status == 200
      TD.assert_error(TD.put_send(f.alice, "m.dummy", String.duplicate("t", 256), TD.msg(f.bob1, %{"t" => 1})), 400, "M_INVALID_PARAM")
      TD.assert_error(TD.put_send(f.alice, "m.dummy", "t\u0000x", TD.msg(f.bob1, %{"t" => 1})), 400, "M_INVALID_PARAM")
      assert TD.queue_count(f.bob1.uid) == 1
    end

    test "`messages` missing or of the wrong type, and entries that are not objects: 400 M_BAD_JSON, NOTHING is queued (not even the valid entries of the request)" do
      f = pair!()
      uid = f.bob1.uid
      dev = f.bob1.dev
      ok_entry = %{uid => %{dev => %{"ok" => true}}}

      bodies = [
        {"no messages", %{}},
        {"messages is a list", %{"messages" => []}},
        {"messages is a string", %{"messages" => "x"}},
        {"messages is null", %{"messages" => nil}},
        {"messages is a number", %{"messages" => 5}},
        {"a user entry is a list", %{"messages" => Map.put(ok_entry, "@x:test.local", [])}},
        {"a user entry is a string", %{"messages" => Map.put(ok_entry, "@x:test.local", "s")}},
        {"a user entry is null", %{"messages" => Map.put(ok_entry, "@x:test.local", nil)}},
        {"a device entry is a string", %{"messages" => %{uid => %{dev => %{"ok" => true}, "OTHER" => "s"}}}},
        {"a device entry is a list", %{"messages" => %{uid => %{dev => %{"ok" => true}, "OTHER" => []}}}},
        {"a device entry is null", %{"messages" => %{uid => %{dev => %{"ok" => true}, "OTHER" => nil}}}},
        {"a device entry is a number", %{"messages" => %{uid => %{dev => %{"ok" => true}, "OTHER" => 1}}}},
        {"a device entry is a bool", %{"messages" => %{uid => %{dev => %{"ok" => true}, "OTHER" => true}}}}
      ]

      for {label, body} <- bodies do
        TD.assert_error(TD.put_send(f.alice, "m.dummy", TD.txn(), {:body, body}), 400, "M_BAD_JSON")
        assert TD.queue_count(uid) == 0, "#{label}: nothing is queued"
      end

      for {label, raw} <- [{"a top-level list", "[]"}, {"a top-level string", ~s("x")}, {"a top-level number", "5"}, {"a top-level null", "null"}] do
        TD.assert_error(TD.put_send(f.alice, "m.dummy", TD.txn(), {:raw, raw}), 400, "M_BAD_JSON")
        assert TD.queue_count(uid) == 0, label
      end
    end

    test "not JSON: 400 M_NOT_JSON; an empty body is 400 M_BAD_JSON (no `messages`), nothing queued" do
      f = pair!()

      for raw <- ["{not json", ~s({"messages": {}} trailing), "\u0000\u0001", ~s({"messages": {"@a:b": {"D": {"x": 1}}})] do
        TD.assert_error(TD.put_send(f.alice, "m.dummy", TD.txn(), {:raw, raw}), 400, "M_NOT_JSON")
      end

      TD.assert_error(TD.put_send(f.alice, "m.dummy", TD.txn(), {:raw, ""}), 400, "M_BAD_JSON")
      assert TD.queue_count(f.bob1.uid) == 0
    end

    test "an empty `messages` object and an empty device object are valid: 200 {}, nothing queued, the txn is recorded" do
      f = pair!()
      c = TD.put_send(f.alice, "m.dummy", TD.txn(), %{})
      assert {c.status, TD.json(c)} == {200, %{}}
      c = TD.put_send(f.alice, "m.dummy", TD.txn(), %{f.bob1.uid => %{}})
      assert {c.status, TD.json(c)} == {200, %{}}
      assert TD.queue_count(f.bob1.uid) == 0
      assert TD.txn_count(f.alice.uid, f.alice.dev) == 2, "both requests recorded their transaction"
    end

    test "extra top-level members of the body are ignored" do
      f = pair!()
      c = TD.put_send(f.alice, "m.dummy", TD.txn(), {:body, %{"messages" => TD.msg(f.bob1, %{"n" => 1}), "unrelated" => [1, 2, 3]}})
      assert c.status == 200
      assert length(td(f.bob1)) == 1
    end

    test "a deeply nested content (10 000 levels, about 20 KB) is opaque: 200 and delivered intact" do
      f = pair!()
      deep = String.duplicate("[", 10_000) <> String.duplicate("]", 10_000)
      raw = ~s({"messages":{"#{f.bob1.uid}":{"#{f.bob1.dev}":{"deep":#{deep}}}}})
      c = TD.put_send(f.alice, "m.dummy", TD.txn(), {:raw, raw})
      assert {c.status, c.resp_body} == {200, "{}"}
      assert [%{"content" => %{"deep" => nested}}] = td(f.bob1)
      assert Jason.encode!(nested) == deep
    end

    test "the answers of a refused request name no content: the 400 text does not echo the body" do
      f = pair!()
      c = TD.put_send(f.alice, "m.dummy", TD.txn(), {:body, %{"messages" => %{"@x:test.local" => %{"D" => "SECRET-CONTENT-ECHO"}}}})
      assert c.status == 400
      refute c.resp_body =~ "SECRET-CONTENT-ECHO"
    end
  end

  # ═══ the sender's own view ═══════════════════════════════════════════════════════════════════════════════════════════════════

  describe "the answer never depends on the recipient's state" do
    test "an EMPTY queue, a queue with a BACKLOG and a FULL queue answer with the identical shape (status, body, headers)" do
      f = pair!()
      send1 = fn n -> TD.put_send(f.alice, "m.dummy", TD.txn(), TD.msg(f.bob1, %{"n" => n})) end

      empty = send1.(1)
      assert TD.queue_count(f.bob1.uid, f.bob1.dev) == 1
      backlog = send1.(2)
      assert TD.queue_count(f.bob1.uid, f.bob1.dev) == 2

      TD.seam(:max_per_device, 2)
      full = send1.(3)
      assert TD.queue_count(f.bob1.uid, f.bob1.dev) == 2, "the queue is at its cap: the oldest was evicted"
      full_again = send1.(4)
      assert Enum.map([backlog, full, full_again], &TD.shape/1) == List.duplicate(TD.shape(empty), 3)
      assert elem(TD.shape(empty), 0) == 200
    end

    test "the sender's own /sync is unaffected by sending: `to_device.events` of the sender stays empty" do
      f = pair!()
      TD.tell!(f.alice, f.bob1, "m.dummy", %{"n" => 1})
      assert td(f.alice) == []
    end
  end
end
