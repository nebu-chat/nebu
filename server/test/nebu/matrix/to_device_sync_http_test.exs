defmodule Nebu.Matrix.ToDeviceSyncHttpTest do
  @moduledoc """
  Acceptance tests for story `to-device-messaging` (epic e2ee-client-support, REQ-2026-012), the SYNC half: `to_device.events` of `GET /_matrix/client/v3/sync` over the real stack.

  Gherkin scenario 3 ("a queued message is removed when the client's next sync presents the covering since token") and the oracle behaviours 1, 7, 8, 9, 10, 11, 12.

  Decisions pinned here (see the story file, `## Decisions`):

    * `to_device` is ALWAYS emitted, as `{"events": []}` when nothing is pending (initial, incremental, timed-out long poll, `filter`, `set_presence`, `full_state`, no rooms, a
      device-less credential): older clients choke on `null`.
    * ACK ON THE NEXT TOKEN, never on delivery: a response only delivers; the messages it carried are deleted when a LATER sync presents the `since` token of that response (its
      to-device position travels in the token, the state is in the database, nothing is node-local). A retry with an older token delivers the batch again; an initial sync (no
      `since`) and a fallback (unknown, foreign or garbage token) deliver everything pending and acknowledge nothing; a token of ANOTHER device never acknowledges anything of
      this device. An acknowledgement covers exactly the batch a response carried: a message that committed late (a lower queue position than a delivered one) is neither
      deleted by it nor missed.
    * A response carries at most 100 messages and 1 MiB (the first message is always carried); the rest comes with the next sync WITHOUT waiting for `timeout`.
    * A new message wakes the long poll of exactly the TARGET device (other devices of the user keep waiting); a message that is already queued (not covered by the presented
      token) makes the next sync return at once; a message the presented token already covers does not (no busy loop).
    * The token of a device that never received a to-device message keeps the two-part shape `<core>.<position>` (the room account data contract of the sync suites).
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

  defp pair! do
    alice = TD.user!("TDA")
    bob1 = TD.user!("TDB")
    bob2 = TD.device!(bob1, "TDC")
    TD.share!(alice, bob1)
    %{alice: alice, bob1: bob1, bob2: bob2}
  end

  defp say(f, n, device \\ nil), do: TD.tell!(f.alice, device || f.bob1, "m.dummy", %{"n" => n})
  defp ns(body), do: Enum.map(TD.events(body), & &1["content"]["n"])

  defp timed(fun) do
    started = System.monotonic_time(:millisecond)
    result = fun.()
    {result, System.monotonic_time(:millisecond) - started}
  end

  # ═══ Scenario 3: acknowledgement on the next token ════════════════════════════════════════════════════════════════════════════

  describe "Scenario 3 - a queued message is removed when the client's next sync presents the covering since token" do
    test "Gherkin: the sync that presents the delivering next_batch no longer returns it, its queue row is deleted" do
      f = pair!()
      say(f, 1)
      first = TD.sync(f.bob1)
      assert ns(first) == [1]
      assert TD.queue_count(f.bob1.uid, f.bob1.dev) == 1, "a response only DELIVERS: the row stays until the client presents the token"

      second = TD.sync(f.bob1, TD.next(first))
      assert TD.events(second) == []
      assert TD.queue_count(f.bob1.uid, f.bob1.dev) == 0, "its queue row is deleted"
    end

    test "oracle 8 and 9: a retry with the EARLIER since redelivers the batch, the covering token acknowledges it" do
      f = pair!()
      t0 = TD.next(TD.sync(f.bob1))
      say(f, 1)
      say(f, 2)

      a = TD.sync(f.bob1, t0)
      assert ns(a) == [1, 2]
      # the response was lost: the client repeats the request with the SAME since (the previous generation of the token stays valid for it)
      retry = TD.sync(f.bob1, t0)
      assert ns(retry) == [1, 2], "the retry with the older token delivers the batch again"
      assert TD.queue_count(f.bob1.uid, f.bob1.dev) == 2, "nothing was deleted by the delivery of either response"

      acked = TD.sync(f.bob1, TD.next(retry))
      assert TD.events(acked) == []
      assert TD.queue_count(f.bob1.uid, f.bob1.dev) == 0

      # a token one generation old after the acknowledgement: nothing to redeliver, no error
      again = TD.sync_conn(f.bob1, since: TD.next(retry), timeout: 0)
      assert again.status == 200
      assert TD.events(TD.json(again)) == []
    end

    test "messages that arrive AFTER the delivering response are not covered by its token" do
      f = pair!()
      say(f, 1)
      first = TD.sync(f.bob1)
      say(f, 2)

      second = TD.sync(f.bob1, TD.next(first))
      assert ns(second) == [2], "m1 is acknowledged and gone, m2 is new"
      assert TD.queue_count(f.bob1.uid, f.bob1.dev) == 1, "m2 stays until its own token comes back"
      assert TD.events(TD.sync(f.bob1, TD.next(second))) == []
      assert TD.queue_count(f.bob1.uid, f.bob1.dev) == 0
    end

    test "a chain of ten rounds (message, sync with the newest token): every message exactly once" do
      f = pair!()
      {seen, token} =
        Enum.reduce(1..10, {[], TD.next(TD.sync(f.bob1))}, fn n, {acc, token} ->
          say(f, n)
          body = TD.sync(f.bob1, token)
          {acc ++ ns(body), TD.next(body)}
        end)

      assert seen == Enum.to_list(1..10)
      assert TD.events(TD.sync(f.bob1, token)) == []
      assert TD.queue_count(f.bob1.uid, f.bob1.dev) == 0
    end

    test "oracle 11: an INITIAL sync (no since) delivers the pending messages and acknowledges nothing" do
      f = pair!()
      say(f, 1)
      assert ns(TD.sync(f.bob1)) == [1]
      assert ns(TD.sync(f.bob1)) == [1]
      assert TD.queue_count(f.bob1.uid, f.bob1.dev) == 1
    end

    test "an unknown, garbage or malformed since is a fallback: everything pending is delivered, nothing is deleted" do
      f = pair!()
      say(f, 1)
      for since <- ["garbage-since", "!!.7", "s2_unknown.1.1", "x.y.z", "", "..", "s2_" <> T.rand(8)] do
        body = TD.sync(f.bob1, since)
        assert ns(body) == [1], "since #{inspect(since)}"
      end

      assert TD.queue_count(f.bob1.uid, f.bob1.dev) == 1
    end

    test "a token of ANOTHER device of the same user never acknowledges anything of this device" do
      f = pair!()
      say(f, 2, f.bob2)
      # device 2 is delivered FIRST (its delivery stamp is lower than the one device 1 gets next): an acknowledgement by position alone would delete it
      b2 = TD.sync(f.bob2)
      say(f, 1, f.bob1)
      b1 = TD.sync(f.bob1)
      assert {ns(b1), ns(b2)} == {[1], [2]}

      # device 2 presents the token of device 1: initial-shaped answer, its own pending message is delivered, nothing is deleted
      cross = TD.sync(f.bob2, TD.next(b1))
      assert ns(cross) == [2]
      assert TD.queue_count(f.bob2.uid, f.bob2.dev) == 1
      assert TD.queue_count(f.bob1.uid, f.bob1.dev) == 1
    end

    test "a token of ANOTHER USER never acknowledges anything either" do
      f = pair!()
      carol = TD.user!("TDK")
      TD.share!(f.alice, carol)
      say(f, 1)
      TD.tell!(f.alice, carol, "m.dummy", %{"n" => 9})
      c = TD.sync(carol)
      b = TD.sync(f.bob1, TD.next(c))
      assert ns(b) == [1]
      assert TD.queue_count(f.bob1.uid, f.bob1.dev) == 1
    end

    test "a FORGED position beyond everything can only acknowledge what was delivered, never an undelivered message" do
      f = pair!()
      say(f, 1)
      first = TD.sync(f.bob1)
      say(f, 2)

      [digits] = Regex.run(~r/[0-9]+\z/, TD.next(first))
      forged = String.replace_suffix(TD.next(first), digits, digits <> "999999")
      body = TD.sync(f.bob1, forged)
      assert ns(body) == [2], "m1 was delivered and is covered (gone), m2 was never delivered: it must come, whatever the forged token says"
      assert TD.queue_count(f.bob1.uid, f.bob1.dev) == 1
    end

    test "each device acknowledges its own queue: bob1 acknowledging does not touch bob2's messages" do
      f = pair!()
      TD.send!(f.alice, "m.dummy", TD.txn(), TD.star(f.bob1, %{"n" => 1}))
      # bob2 is delivered first (lower delivery stamp), bob1 afterwards: bob1's token covers a position above bob2's stamp
      b2 = TD.sync(f.bob2)
      b1 = TD.sync(f.bob1)
      assert TD.events(TD.sync(f.bob1, TD.next(b1))) == []
      assert TD.queue_count(f.bob1.uid, f.bob1.dev) == 0
      assert TD.queue_count(f.bob2.uid, f.bob2.dev) == 1
      assert ns(b2) == [1]
    end

    test "`filter`, `set_presence` and `full_state` neither lose nor acknowledge pending messages" do
      f = pair!()
      t0 = TD.next(TD.sync(f.bob1))
      say(f, 1)
      filter = Jason.encode!(%{"room" => %{"timeline" => %{"limit" => 1}}, "presence" => %{"types" => []}})

      for params <- [[filter: filter], [set_presence: "offline"], [full_state: "true"], [filter: "0"], [filter: filter, set_presence: "online", full_state: "false"]] do
        assert ns(TD.sync(f.bob1, nil, params)) == [1], "initial sync with #{inspect(Keyword.keys(params))}"
      end

      assert TD.queue_count(f.bob1.uid, f.bob1.dev) == 1
      assert ns(TD.sync(f.bob1, t0, filter: filter, set_presence: "offline")) == [1], "also on an incremental sync with a token from before the message"
    end

    test "the acknowledgement is database state: a request process of another task sees and applies it" do
      f = pair!()
      say(f, 1)
      first = TD.sync(f.bob1)
      t = Task.async(fn -> TD.sync(f.bob1, TD.next(first)) end)
      assert TD.events(Task.await(t, 15_000)) == []
      assert TD.queue_count(f.bob1.uid, f.bob1.dev) == 0
    end

    test "a message that COMMITS LATE (lower queue position than a delivered one) is neither deleted nor missed" do
      f = pair!()
      TD.slow_commit_trigger!("LATE-COMMIT", 4)

      t0 = TD.next(TD.sync(f.bob1))
      slow = Task.async(fn -> TD.tell!(f.alice, f.bob1, "m.dummy", %{"n" => 1, "mark" => "LATE-COMMIT"}) end)
      TD.wait_sleeping(1)
      say(f, 2)

      first = TD.sync(f.bob1, t0)
      assert ns(first) == [2], "the late message has not committed yet"
      Task.await(slow, 15_000)

      second = TD.sync(f.bob1, TD.next(first))
      assert ns(second) == [1], "the late message (lower queue position than the delivered one) is delivered, the acknowledgement of the first batch did not delete it"
      assert TD.events(TD.sync(f.bob1, TD.next(second))) == []
      assert TD.queue_count(f.bob1.uid, f.bob1.dev) == 0
    end

    # story device-key-directory (D11) appends the device-list position as the LAST group `.d<digits>` to EVERY next_batch; the pin below is about the
    # to-device part (`<core>.<pos>[.<to-device pos>]`) and so it looks at the token without that group.
    test "no to-device traffic keeps the two-part token `<core>.<position>` (before the .d<n> group); with traffic it is still s2_" do
      f = pair!()
      quiet = TD.next(TD.sync(f.bob1))
      assert quiet =~ ~r/\.d[0-9]+\z/, "the device-list group is the last one"
      assert [core, pos] = quiet |> strip_dl() |> String.split(".")
      assert String.starts_with?(core, "s2_") and pos =~ ~r/\A[0-9]+\z/

      say(f, 1)
      busy = TD.next(TD.sync(f.bob1, quiet))
      assert String.starts_with?(busy, "s2_")
      assert strip_dl(busy) =~ ~r/\A[^.]+(\.[0-9]+)+\z/
    end
  end

  defp strip_dl(token), do: Regex.replace(~r/\.d[0-9]+\z/, token, "")

  # ═══ always emitted ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

  describe "`to_device: {\"events\": []}` is always emitted" do
    test "initial sync, incremental sync, an expired long poll: exactly {\"events\": []}" do
      f = pair!()
      initial = TD.sync(f.bob1)
      assert initial["to_device"] == %{"events" => []}
      incremental = TD.sync(f.bob1, TD.next(initial))
      assert incremental["to_device"] == %{"events" => []}
      {polled, ms} = timed(fn -> TD.sync(f.bob1, TD.next(incremental), timeout: 400) end)
      assert polled["to_device"] == %{"events" => []}
      assert ms >= 300, "it really waited (#{ms} ms)"
    end

    test "with filter, set_presence and full_state, and for a user with no rooms at all" do
      lonely = TD.user!("TDN")
      body = TD.sync(lonely)
      assert body["to_device"] == %{"events" => []}
      assert S.section(body, "join") == %{} and S.section(body, "invite") == %{}

      for params <- [[filter: Jason.encode!(%{"room" => %{"rooms" => []}})], [set_presence: "unavailable"], [full_state: "true"]] do
        assert TD.sync(lonely, TD.next(body), params)["to_device"] == %{"events" => []}
      end
    end

    test "the member is a JSON object with a list, never null" do
      f = pair!()
      conn = TD.sync_conn(f.bob1, timeout: 0)
      assert conn.resp_body =~ ~s("to_device":{"events":[]})
    end

    test "a DEVICE-LESS credential (a raw IdP JWT without a device binding) gets {\"events\": []} and its devices' messages stay untouched; it can send to its own devices" do
      priv = T.setup_idp!()
      sub = T.unique_sub()
      uid = T.provision_user!(sub)
      dev = TD.device!(%{uid: uid}, "TDW")
      jwt = %{uid: uid, dev: "", at: T.unbound_jwt!(priv, sub)}
      alice = TD.user!("TDA")
      TD.share!(alice, jwt)

      TD.tell!(alice, dev, "m.dummy", %{"n" => 1})
      body = TD.sync(jwt)
      assert body["to_device"] == %{"events" => []}
      assert TD.queue_count(uid, dev.dev) == 1

      TD.send!(jwt, "m.dummy", TD.txn(), TD.msg(dev, %{"from" => "jwt"}))
      assert Enum.map(TD.events(TD.sync(dev)), & &1["content"]) == [%{"n" => 1}, %{"from" => "jwt"}]
    end
  end

  # ═══ continuation ═════════════════════════════════════════════════════════════════════════════════════════════════════════════

  describe "oracle behaviour 10: more than 100 pending messages - bounded per sync, the rest on the next sync, no loss, no duplicate" do
    test "150 pending (two senders): 100 in the first sync in arrival order, 50 in the next, no waiting" do
      f = pair!()
      carol = TD.user!("TDK")
      TD.share!(carol, f.bob1)

      for n <- 1..150 do
        sender = if rem(n, 2) == 0, do: carol, else: f.alice
        TD.tell!(sender, f.bob1, "m.dummy", %{"n" => n})
      end

      {first, ms1} = timed(fn -> TD.sync(f.bob1) end)
      assert ns(first) == Enum.to_list(1..100)
      {second, ms2} = timed(fn -> TD.sync(f.bob1, TD.next(first), timeout: 20_000) end)
      assert ns(second) == Enum.to_list(101..150), "the continuation does not wait for the timeout (#{ms2} ms)"
      assert ms2 < 3_000 and ms1 < 3_000
      third = TD.sync(f.bob1, TD.next(second))
      assert TD.events(third) == []
      assert TD.queue_count(f.bob1.uid, f.bob1.dev) == 0
    end

    test "a small batch size (seam): 8 messages come as 3, 3, 2; a retry repeats that batch; no loss, no dup" do
      f = pair!()
      TD.seam(:sync_batch_size, 3)
      t0 = TD.next(TD.sync(f.bob1))
      for n <- 1..8, do: say(f, n)

      b1 = TD.sync(f.bob1, t0)
      assert ns(b1) == [1, 2, 3]
      r1 = TD.sync(f.bob1, t0)
      assert ns(r1) == [1, 2, 3], "a retry with the older token repeats the batch (nothing of the later messages jumps in)"
      b2 = TD.sync(f.bob1, TD.next(r1))
      assert ns(b2) == [4, 5, 6]
      r2 = TD.sync(f.bob1, TD.next(r1))
      assert ns(r2) == [4, 5, 6]
      b3 = TD.sync(f.bob1, TD.next(r2))
      assert ns(b3) == [7, 8]
      assert TD.events(TD.sync(f.bob1, TD.next(b3))) == []
      assert TD.queue_count(f.bob1.uid, f.bob1.dev) == 0
    end

    test "the byte cap of a response (seam): by size, at least ONE message is always carried" do
      f = pair!()
      content = fn n -> %{"pad" => String.duplicate("x", 1000), "n" => n} end
      TD.seam(:sync_batch_bytes, 3 * TD.cost(content.(1)))
      t0 = TD.next(TD.sync(f.bob1))
      for n <- 1..7, do: TD.tell!(f.alice, f.bob1, "m.dummy", content.(n))

      first = TD.sync(f.bob1, t0)
      assert ns(first) == [1, 2, 3], "exactly three messages fit the cap, the fourth does not"
      {rest, _} = TD.drain(f.bob1, TD.next(first))
      assert Enum.map(rest, & &1["content"]["n"]) == [4, 5, 6, 7]
    end

    test "the response byte cap boundary, one byte less: two messages of three fit" do
      f = pair!()
      content = fn n -> %{"pad" => String.duplicate("x", 1000), "n" => n} end
      TD.seam(:sync_batch_bytes, 3 * TD.cost(content.(1)) - 1)
      t0 = TD.next(TD.sync(f.bob1))
      for n <- 1..4, do: TD.tell!(f.alice, f.bob1, "m.dummy", content.(n))
      assert ns(TD.sync(f.bob1, t0)) == [1, 2]
    end

    test "a response cap below the size of one message still carries one message per response (no stall)" do
      f = pair!()
      TD.seam(:sync_batch_bytes, 10)
      t0 = TD.next(TD.sync(f.bob1))
      for n <- 1..3, do: say(f, n)
      b1 = TD.sync(f.bob1, t0)
      assert ns(b1) == [1]
      b2 = TD.sync(f.bob1, TD.next(b1))
      assert ns(b2) == [2]
      b3 = TD.sync(f.bob1, TD.next(b2))
      assert ns(b3) == [3]
    end

    test "default response budget: 20 messages of 60 KiB do not fit one response (1 MiB), nothing is lost" do
      f = pair!()
      carols = for _ <- 1..2, do: TD.user!("TDK")
      for c <- carols, do: TD.share!(c, f.bob1)
      t0 = TD.next(TD.sync(f.bob1))
      pad = String.duplicate("p", 60_000)
      for n <- 1..20, do: TD.tell!(Enum.at(carols, rem(n, 2)), f.bob1, "m.dummy", %{"n" => n, "pad" => pad})

      first = TD.sync(f.bob1, t0)
      costs = for n <- 1..20, do: TD.cost(%{"n" => n, "pad" => pad})
      expected = costs |> Enum.scan(&+/2) |> Enum.take_while(&(&1 <= TD.defaults().sync_batch_bytes)) |> length()
      assert length(TD.events(first)) == expected, "exactly as many as fit 1 MiB (#{expected})"
      {rest, _} = TD.drain(f.bob1, TD.next(first))
      assert Enum.map(TD.events(first) ++ rest, & &1["content"]["n"]) == Enum.to_list(1..20)
    end
  end

  # ═══ wake-up ═════════════════════════════════════════════════════════════════════════════════════════════════════════════════

  describe "oracle behaviour 12: a to-device message wakes the long poll of its target device" do
    test "a waiting /sync?timeout=30000 returns promptly with the event when the message arrives" do
      f = pair!()
      since = TD.next(TD.sync(f.bob1))
      poll = Task.async(fn -> timed(fn -> TD.sync(f.bob1, since, timeout: 30_000) end) end)
      TD.wait_polling(f.bob1.uid)
      say(f, 1)
      {body, ms} = Task.await(poll, 35_000)
      assert ms < 3_000, "returned for the message within 3 s of a 30 s timeout (#{ms} ms)"
      assert ns(body) == [1]
    end

    test "a message that is already queued (not covered by the presented token) makes the next sync return at once, however long the timeout" do
      f = pair!()
      since = TD.next(TD.sync(f.bob1))
      say(f, 1)
      {body, ms} = timed(fn -> TD.sync(f.bob1, since, timeout: 30_000) end)
      assert ns(body) == [1]
      assert ms < 3_000, "no waiting (#{ms} ms)"
    end

    test "a message the presented token already COVERS does not end the wait (no busy loop): the poll waits for its timeout" do
      f = pair!()
      say(f, 1)
      first = TD.sync(f.bob1)
      {body, ms} = timed(fn -> TD.sync(f.bob1, TD.next(first), timeout: 800) end)
      assert TD.events(body) == []
      assert ms >= 600, "it waited (#{ms} ms): an acknowledged message is not pending"
    end

    test "a retry with the OLDER token returns at once (the delivered batch is pending for that token)" do
      f = pair!()
      t0 = TD.next(TD.sync(f.bob1))
      say(f, 1)
      assert ns(TD.sync(f.bob1, t0)) == [1]
      {body, ms} = timed(fn -> TD.sync(f.bob1, t0, timeout: 30_000) end)
      assert ns(body) == [1]
      assert ms < 3_000
    end

    test "the missed wake-up window: a message that arrives AFTER the pre-check and BEFORE the poll joins its group still ends the poll at once" do
      f = pair!()
      since = TD.next(TD.sync(f.bob1))
      fired = :atomics.new(1, [])

      # the seam runs inside the sync, between the pre-check (nothing pending yet) and the subscription: the sender is not woken-up-able yet (nobody is in the group)
      Application.put_env(:nebu, :atdd_to_device_before_join, fn ->
        if :atomics.add_get(fired, 1, 1) == 1, do: say(f, 1)
      end)

      on_exit(fn -> Application.delete_env(:nebu, :atdd_to_device_before_join) end)

      {body, ms} = timed(fn -> TD.sync(f.bob1, since, timeout: 30_000) end)
      assert :atomics.get(fired, 1) >= 1, "the seam was reached"
      assert ns(body) == [1]
      assert ms < 3_000, "the poll found the message queued before it subscribed instead of waiting for its timeout (#{ms} ms)"
    end

    test "only the TARGET device wakes: the other device of the user keeps waiting while the target returns" do
      f = pair!()
      s1 = TD.next(TD.sync(f.bob1))
      s2 = TD.next(TD.sync(f.bob2))
      p1 = Task.async(fn -> timed(fn -> TD.sync(f.bob1, s1, timeout: 6_000) end) end)
      p2 = Task.async(fn -> timed(fn -> TD.sync(f.bob2, s2, timeout: 6_000) end) end)
      TD.wait_polling(f.bob1.uid, 2)

      say(f, 1)
      assert {body1, ms1} = Task.await(p1, 15_000)
      assert ns(body1) == [1]
      assert ms1 < 3_000
      assert Task.yield(p2, 1_000) == nil, "the other device of bob was not woken by a message for B1"
      assert {body2, ms2} = Task.await(p2, 15_000)
      assert TD.events(body2) == []
      assert ms2 >= 4_500, "B2 waited its timeout (#{ms2} ms)"
    end

    test "a message for a user's `*` wakes every device of that user" do
      f = pair!()
      s1 = TD.next(TD.sync(f.bob1))
      s2 = TD.next(TD.sync(f.bob2))
      p1 = Task.async(fn -> timed(fn -> TD.sync(f.bob1, s1, timeout: 30_000) end) end)
      p2 = Task.async(fn -> timed(fn -> TD.sync(f.bob2, s2, timeout: 30_000) end) end)
      TD.wait_polling(f.bob1.uid, 2)
      TD.send!(f.alice, "m.dummy", TD.txn(), TD.star(f.bob1, %{"n" => 1}))

      for p <- [p1, p2] do
        {body, ms} = Task.await(p, 35_000)
        assert ns(body) == [1]
        assert ms < 3_000
      end
    end

    test "a message to ANOTHER user does not wake bob's poll" do
      f = pair!()
      carol = TD.user!("TDK")
      TD.share!(f.alice, carol)
      since = TD.next(TD.sync(f.bob1))
      poll = Task.async(fn -> timed(fn -> TD.sync(f.bob1, since, timeout: 2_000) end) end)
      TD.wait_polling(f.bob1.uid)
      TD.tell!(f.alice, carol, "m.dummy", %{"n" => 1})
      assert {body, ms} = Task.await(poll, 15_000)
      assert TD.events(body) == []
      assert ms >= 1_700
    end
  end

  # ═══ ordering and shape ═════════════════════════════════════════════════════════════════════════════════════════════════════

  describe "delivery shape" do
    test "sync keeps delivering the rooms: a room message and a to-device message arrive in the SAME response" do
      f = pair!()
      room = S.make_room(f.alice, %{"preset" => "private_chat", "invite" => [f.bob1.uid]})
      S.join!(f.bob1, room)
      since = TD.next(TD.sync(f.bob1))
      marker = S.marker("room-msg")
      S.say!(f.alice, room, marker)
      say(f, 1)

      body = TD.sync(f.bob1, since)
      assert ns(body) == [1]
      assert marker in (S.join_timeline(body, room) |> Enum.map(& &1["content"]["body"]))
    end

    test "the to-device events of a response are in queue order and the response is valid JSON of the three-member events" do
      f = pair!()
      for n <- 1..5, do: say(f, n)
      body = TD.sync(f.bob1)
      assert ns(body) == [1, 2, 3, 4, 5]
      for e <- TD.events(body), do: assert(Enum.sort(Map.keys(e)) == ["content", "sender", "type"])
    end
  end
end
