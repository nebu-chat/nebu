defmodule Nebu.Matrix.ToDeviceConcurrencyTest do
  @moduledoc """
  Acceptance tests for story `to-device-messaging` (epic e2ee-client-support, REQ-2026-012): CONCURRENCY and CLUSTER SAFETY (lessons of the sibling story's three security reviews).

    * Exactly-once under races: the same txn id from many requests at once queues ONE message; distinct senders and distinct txn ids to one device lose nothing and duplicate
      nothing (a request that is told to retry, `429`, is retried with the same txn id); concurrent syncs with one token neither lose, duplicate nor fail; a consumer that always presents the
      newest token sees every message of a concurrent producer exactly once, in order.
    * NO WAITING LOCKS: a request never waits for a lock while holding a pooled database connection. A transaction record that another, uncommitted transaction holds does not block the
      request (429 within a second, the pool stays usable even when more requests than pool connections pile up); the source scan that forbids blocking lock calls is in `to_device_docs_test.exs`.
    * BOUNDED WORK: a send issues a constant number of statements on the to-device tables however many recipients it names (set based, no per-recipient round trip); a delivery of a full batch is
      a handful of statements.
    * CLUSTER SAFETY (ADR-020) is pinned by the static scans of `to_device_docs_test.exs` (no process state in the code that touches the tables, the wake-up is the cluster-wide `:pg` broadcast).
  """
  use ExUnit.Case, async: false

  alias Nebu.Compliance.UserDeletionTestSupport, as: E
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

  defp ns(body), do: Enum.map(TD.events(body), & &1["content"]["n"])

  # ═══ exactly once under races ═══════════════════════════════════════════════════════════════════════════════════════════════

  describe "exactly once under races" do
    test "the SAME txn id from 16 requests at once: exactly one message is queued, every answer is 200 or 429" do
      f = pair!()
      t = TD.txn()

      answers = for _ <- 1..16, do: Task.async(fn -> TD.put_send(f.alice, "m.dummy", t, TD.msg(f.bob1, %{"n" => 1})) end)
      answers = Enum.map(answers, &Task.await(&1, 30_000))

      for c <- answers do
        assert c.status in [200, 429], "got #{c.status} #{c.resp_body}"
        if c.status == 429, do: assert(TD.json(c)["errcode"] == "M_LIMIT_EXCEEDED")
      end

      assert Enum.any?(answers, &(&1.status == 200)), "at least one request won"
      assert TD.queue_count(f.bob1.uid, f.bob1.dev) == 1
      assert TD.txn_count(f.alice.uid, f.alice.dev) == 1

      TD.send!(f.alice, "m.dummy", t, TD.msg(f.bob1, %{"n" => 1}))
      assert TD.queue_count(f.bob1.uid, f.bob1.dev) == 1
    end

    test "30 distinct senders write to one device at once: all 30 messages arrive, none twice (a 429 is retried with the same txn id)" do
      f = pair!()
      senders = for _ <- 1..30, do: (s = TD.user!("TDS"); TD.share!(s, f.bob1); s)

      tasks =
        for {s, i} <- Enum.with_index(senders, 1) do
          t = TD.txn()
          Task.async(fn -> TD.retrying(fn -> TD.put_send(s, "m.dummy", t, TD.msg(f.bob1, %{"n" => i})) end).status end)
        end

      assert Enum.map(tasks, &Task.await(&1, 60_000)) == List.duplicate(200, 30)
      {events, _} = TD.drain(f.bob1, nil)
      assert Enum.sort(Enum.map(events, & &1["content"]["n"])) == Enum.to_list(1..30)
      assert Enum.sort(Enum.map(events, & &1["sender"])) == Enum.sort(Enum.map(senders, & &1.uid))
    end

    test "one sender, 24 distinct txn ids at once to one device: all arrive exactly once (retried 429s keep their txn id)" do
      f = pair!()
      txns = for i <- 1..24, do: {i, TD.txn()}

      tasks = for {i, t} <- txns, do: Task.async(fn -> TD.retrying(fn -> TD.put_send(f.alice, "m.dummy", t, TD.msg(f.bob1, %{"n" => i})) end).status end)
      assert Enum.map(tasks, &Task.await(&1, 60_000)) == List.duplicate(200, 24)
      {events, _} = TD.drain(f.bob1, nil)
      assert Enum.sort(Enum.map(events, & &1["content"]["n"])) == Enum.to_list(1..24)
      assert TD.txn_count(f.alice.uid, f.alice.dev) == 24
    end

    test "a batch of `*` requests and explicit requests at once to the same two devices: every device has every message once" do
      f = pair!()

      tasks =
        for i <- 1..12 do
          t = TD.txn()
          messages = if rem(i, 2) == 0, do: TD.star(f.bob1, %{"n" => i}), else: TD.merge([TD.msg(f.bob1, %{"n" => i}), TD.msg(f.bob2, %{"n" => i})])
          Task.async(fn -> TD.retrying(fn -> TD.put_send(f.alice, "m.dummy", t, messages) end).status end)
        end

      assert Enum.map(tasks, &Task.await(&1, 60_000)) == List.duplicate(200, 12)

      for d <- [f.bob1, f.bob2] do
        {events, _} = TD.drain(d, nil)
        assert Enum.sort(Enum.map(events, & &1["content"]["n"])) == Enum.to_list(1..12), "device #{d.dev}"
      end
    end

    test "four concurrent syncs with the SAME token: every answer is 200, none loses or invents a message" do
      f = pair!()
      t0 = TD.next(TD.sync(f.bob1))
      for n <- 1..3, do: TD.tell!(f.alice, f.bob1, "m.dummy", %{"n" => n})

      answers = for(_ <- 1..4, do: Task.async(fn -> TD.sync_conn(f.bob1, since: t0, timeout: 0) end)) |> Enum.map(&Task.await(&1, 60_000))

      for c <- answers do
        assert c.status == 200, "got #{c.status} #{String.slice(c.resp_body, 0, 200)}"
        # a response carries what it stamped itself (or what an earlier response stamped): the one that wins the stamp carries all three, a response that lost the
        # race carries nothing (its position stays at the presented one): never a part, never a message that was not queued
        assert ns(TD.json(c)) in [[], [1, 2, 3]]
      end

      assert Enum.any?(answers, &(ns(TD.json(&1)) == [1, 2, 3])), "at least one response delivered the batch"

      assert TD.queue_count(f.bob1.uid, f.bob1.dev) == 3
      assert ns(TD.sync(f.bob1)) == [1, 2, 3]
    end

    test "a consumer with its newest token sees every message of a concurrent producer exactly once, in order" do
      f = pair!()
      total = 40
      producer = Task.async(fn -> for n <- 1..total, do: TD.tell!(f.alice, f.bob1, "m.dummy", %{"n" => n}) end)

      consume = fn consume, token, seen, deadline ->
        if length(seen) >= total or System.monotonic_time(:millisecond) > deadline do
          {seen, token}
        else
          body = TD.sync(f.bob1, token, timeout: 2_000)
          consume.(consume, TD.next(body), seen ++ ns(body), deadline)
        end
      end

      first = TD.sync(f.bob1)
      {seen, token} = consume.(consume, TD.next(first), ns(first), System.monotonic_time(:millisecond) + 40_000)
      Task.await(producer, 40_000)
      assert seen == Enum.to_list(1..total), "every message exactly once, in order: #{inspect(seen)}"
      assert TD.events(TD.sync(f.bob1, token)) == []
      assert TD.queue_count(f.bob1.uid, f.bob1.dev) == 0
    end
  end

  # ═══ no waiting locks ═══════════════════════════════════════════════════════════════════════════════════════════════════════

  describe "no waiting locks: a request never waits for a lock while holding a pooled connection" do
    defp hold_txn!(sender, type, txn_id) do
      E.hold(fn ->
        T.sql!("INSERT INTO to_device_txns (user_id, device_id, event_type, txn_id) VALUES ($1, $2, $3, $4)", [sender.uid, sender.dev, type, txn_id])
      end)
    end

    test "a txn record held by another uncommitted transaction does not block: 429 within a second, the retry is delivered" do
      f = pair!()
      t = TD.txn()
      holder = hold_txn!(f.alice, "m.dummy", t)

      {c, ms} =
        (fn ->
           started = System.monotonic_time(:millisecond)
           c = TD.put_send(f.alice, "m.dummy", t, TD.msg(f.bob1, %{"n" => 1}))
           {c, System.monotonic_time(:millisecond) - started}
         end).()

      assert ms < 1_500, "the request waited #{ms} ms for a lock (lock_timeout is 100 ms; the 2 s statement timeout is only the second line of defence)"
      TD.assert_429(c, "a request that conflicts with an in-flight transaction")
      assert TD.queue_count(f.bob1.uid, f.bob1.dev) == 0

      E.finish(holder, :rollback)
      TD.send!(f.alice, "m.dummy", t, TD.msg(f.bob1, %{"n" => 1}))
      assert ns(TD.sync(f.bob1)) == [1]
    end

    test "14 requests (more than pool connections) behind such a record all answer 429, the pool stays usable" do
      f = pair!()
      t = TD.txn()
      holder = hold_txn!(f.alice, "m.dummy", t)
      carol = TD.user!("TDK")
      TD.share!(carol, f.bob1)

      assert Nebu.Repo.config()[:pool_size] < 14, "the claim 'more requests than pool connections' holds (pool size #{Nebu.Repo.config()[:pool_size]})"
      started = System.monotonic_time(:millisecond)
      tasks = for _ <- 1..14, do: Task.async(fn -> TD.put_send(f.alice, "m.dummy", t, TD.msg(f.bob1, %{"n" => 1})).status end)

      TD.tell!(carol, f.bob1, "m.dummy", %{"n" => 2})
      assert ns(TD.sync(f.bob1)) == [2]

      assert Enum.map(tasks, &Task.await(&1, 15_000)) == List.duplicate(429, 14)
      assert System.monotonic_time(:millisecond) - started < 8_000
      assert %{rows: [[1]]} = T.sql!("SELECT 1")
      E.finish(holder, :rollback)
    end
  end

  # ═══ slots ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════

  describe "slots: a rate limit is not a concurrency limit (4 per user, 6 per node, 429 before the body)" do
    @slow "SLOW-COMMIT-MARK"

    # a send that stays in flight for `seconds` (its row is inserted, the COMMIT sleeps): a Task that returns the conn
    defp slow_send(sender, to) do
      Task.async(fn -> TD.put_send(sender, "m.dummy", TD.txn(), TD.msg(to, %{"mark" => @slow, "from" => sender.uid})) end)
    end

    test "per user (seam 2): the third send is 429 at once, body UNREAD, no txn; others unaffected; later it works" do
      f = pair!()
      carol = TD.user!("TDK")
      TD.share!(carol, f.bob1)
      TD.seam(:max_concurrent_sends_per_user, 2)
      TD.slow_commit_trigger!(@slow, 4)

      slow = for _ <- 1..2, do: slow_send(f.alice, f.bob1)
      TD.wait_sleeping(2)

      t = TD.txn()
      started = System.monotonic_time(:millisecond)
      refused = TD.put_send(f.alice, "m.dummy", t, TD.msg(f.bob1, %{"n" => 1}))
      assert System.monotonic_time(:millisecond) - started < 3_000, "the refusal waited"
      TD.assert_429(refused, "the third send of one user")
      assert match?(%Plug.Conn.Unfetched{}, refused.body_params), "the body was read although no slot was free"

      TD.tell!(carol, f.bob1, "m.dummy", %{"n" => 2})
      assert TD.sync_conn(f.alice, timeout: 0).status == 200, "sync is not gated"

      assert Enum.map(slow, &Task.await(&1, 15_000).status) == [200, 200]
      assert TD.txn_count(f.alice.uid, f.alice.dev) == 2, "the refused send recorded no transaction"
      TD.send!(f.alice, "m.dummy", t, TD.msg(f.bob1, %{"n" => 1}))
      assert length(TD.events(TD.sync(f.bob1))) == 4
    end

    test "per node (seam 2): two users in flight, a third user is 429" do
      f = pair!()
      carol = TD.user!("TDK")
      dave = TD.user!("TDD")
      TD.share!(carol, f.bob1)
      TD.share!(dave, f.bob1)
      TD.seam(:max_concurrent_sends_per_node, 2)
      TD.slow_commit_trigger!(@slow, 4)

      slow = [slow_send(f.alice, f.bob1), slow_send(carol, f.bob1)]
      TD.wait_sleeping(2)
      TD.assert_429(TD.put_send(dave, "m.dummy", TD.txn(), TD.msg(f.bob1, %{"n" => 1})), "the node is full")
      assert Enum.map(slow, &Task.await(&1, 15_000).status) == [200, 200]
      TD.send!(dave, "m.dummy", TD.txn(), TD.msg(f.bob1, %{"n" => 1}))
    end

    test "a request process killed in flight frees its user and node slot at once (monitor based)" do
      f = pair!()
      TD.seam(:max_concurrent_sends_per_user, 1)
      TD.seam(:max_concurrent_sends_per_node, 1)
      TD.slow_commit_trigger!(@slow, 4)

      task = slow_send(f.alice, f.bob1)
      TD.wait_sleeping(1)
      TD.assert_429(TD.put_send(f.alice, "m.dummy", TD.txn(), TD.msg(f.bob1, %{"n" => 1})), "the slot is taken")

      Task.shutdown(task, :brutal_kill)
      TD.send!(f.alice, "m.dummy", TD.txn(), TD.msg(f.bob1, %{"n" => 2}))
    end

    test "every ending frees the slot: a sequence of 200, 400, 413 and skipped requests never leaves it taken" do
      f = pair!()
      TD.seam(:max_concurrent_sends_per_user, 1)
      TD.seam(:max_concurrent_sends_per_node, 1)

      big = ~s({"messages":{"#{f.bob1.uid}":{"#{f.bob1.dev}":{"p":"#{String.duplicate("a", 70_000)}"}}}})

      for i <- 1..6 do
        assert TD.put_send(f.alice, "m.dummy", TD.txn(), TD.msg(f.bob1, %{"n" => i})).status == 200
        assert TD.put_send(f.alice, "m.dummy", TD.txn(), {:raw, "{nope"}).status == 400
        assert TD.put_send(f.alice, "m.dummy", TD.txn(), {:raw, big}).status == 413
        assert TD.put_send(f.alice, "bad type", TD.txn(), %{}).status == 400
        assert TD.put_send(f.alice, "m.dummy", TD.txn(), TD.msg({"@nobody:test.local", "D"}, %{})).status == 200
      end

      assert length(TD.events(TD.sync(f.bob1))) == 6
    end

    test "a request that fails inside (the database refuses, a 500) frees its slot as well" do
      f = pair!()
      TD.seam(:max_concurrent_sends_per_user, 1)
      TD.seam(:max_concurrent_sends_per_node, 1)

      name = "atdd_td_fail_" <> T.rand(4)
      T.privileged_sql!("CREATE FUNCTION #{name}() RETURNS trigger AS $$ BEGIN RAISE EXCEPTION 'atdd: forced'; END $$ LANGUAGE plpgsql")
      T.privileged_sql!("CREATE TRIGGER #{name} BEFORE INSERT ON to_device_messages FOR EACH ROW EXECUTE FUNCTION #{name}()")

      remove = fn ->
        T.privileged_sql!("DROP TRIGGER IF EXISTS #{name} ON to_device_messages")
        T.privileged_sql!("DROP FUNCTION IF EXISTS #{name}()")
      end

      on_exit(remove)
      assert TD.put_send(f.alice, "m.dummy", TD.txn(), TD.msg(f.bob1, %{"n" => 1})).status == 500
      remove.()
      TD.send!(f.alice, "m.dummy", TD.txn(), TD.msg(f.bob1, %{"n" => 2}))
    end
  end

  # ═══ bounded work ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

  describe "bounded work: no per-recipient round trips" do
    test "a send to 50 explicit recipients issues about as many to-device statements as a send to one (set based)" do
      f = pair!()
      devices = for i <- 1..49, do: (d = "BULK#{String.pad_leading(Integer.to_string(i), 3, "0")}"; :ok = Nebu.Matrix.DeviceKeyStore.upsert_device(f.bob1.uid, d); d)
      TD.disable_rate_limit()

      {_, one} = TD.statements(fn -> TD.send!(f.alice, "m.dummy", TD.txn(), TD.msg(f.bob1, %{"n" => 1})) end, "device")

      many_entries = TD.merge(for d <- [f.bob1.dev | devices], do: TD.msg({f.bob1.uid, d}, %{"n" => 2}))
      assert Enum.count(many_entries[f.bob1.uid]) == 50
      {_, many} = TD.statements(fn -> TD.send!(f.alice, "m.dummy", TD.txn(), many_entries) end, "device")

      assert TD.queue_count(f.bob1.uid) == 51
      assert length(many) <= length(one) + 2, "#{length(one)} statements for one recipient, #{length(many)} for fifty:\n#{Enum.join(many, "\n")}"
      assert length(many) <= 17, "a send is a handful of statements on the to-device tables (got #{length(many)})"
    end

    test "a `*` to 100 devices and 50 unknown users: still a constant number of statements on the to-device tables" do
      f = pair!()
      many = TD.user!("TDM")
      TD.share!(f.alice, many)
      for i <- 1..99, do: :ok = Nebu.Matrix.DeviceKeyStore.upsert_device(many.uid, "MANY#{String.pad_leading(Integer.to_string(i), 3, "0")}")
      messages = Map.merge(for(i <- 1..49, into: %{}, do: {"@nobody#{i}-#{TD.txn()}:test.local", %{"D" => %{}}}), TD.star(many, %{"n" => 1}))
      assert map_size(messages) == 50

      {_, statements} = TD.statements(fn -> TD.send!(f.alice, "m.dummy", TD.txn(), messages) end, "device")
      assert TD.queue_count(many.uid) == 100
      assert length(statements) <= 17, "got #{length(statements)}:\n#{Enum.join(statements, "\n")}"
    end

    test "a sync that delivers a full batch of 100 issues a handful of to-device statements, an idle sync fewer" do
      f = pair!()
      carol = TD.user!("TDK")
      TD.share!(carol, f.bob1)
      for n <- 1..100, do: TD.tell!(if(rem(n, 2) == 0, do: carol, else: f.alice), f.bob1, "m.dummy", %{"n" => n})

      {first, full} = TD.statements(fn -> TD.sync(f.bob1) end)
      assert length(TD.events(first)) == 100
      assert length(full) <= 8, "got #{length(full)}:\n#{Enum.join(full, "\n")}"

      {second, quiet} = TD.statements(fn -> TD.sync(f.bob1, TD.next(first)) end)
      assert TD.events(second) == []
      assert length(quiet) <= 6, "got #{length(quiet)}:\n#{Enum.join(quiet, "\n")}"
    end
  end
end
