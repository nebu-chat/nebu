defmodule Nebu.Matrix.ToDeviceDeliveryFaultsTest do
  @moduledoc """
  Acceptance tests for story `to-device-messaging` (epic e2ee-client-support, REQ-2026-012), cycle 1 after the Kassandra review (MEDIUM #4, #5, LOW #6) and the code review (MINOR 1, 2, 3):

    * A to-device DELIVERY FAULT (a row lock held by another request, a statement over its timeout) must NOT fail `/sync`: it answers 200 with `to_device: {"events": []}`, keeps the
      position (nothing acked, nothing lost), the room data is unaffected. The acknowledgement DELETE, the stamp UPDATE and the eviction subselects use `FOR UPDATE SKIP LOCKED`: a
      held row lock makes them skip the row, never wait for it (a send is not refused because an old row of its queue is locked).
    * `SET LOCAL statement_timeout` of 2 s in a send (over it: 429 `M_LIMIT_EXCEEDED`, nothing stored, the txn id not burnt) and in a delivery (over it: empty `to_device`).
    * LOST RACE (code review MINOR 1): two overlapping syncs with the same `since`; when the stamp UPDATE of one of them stamps nothing (the other was faster) the answer must not claim
      a position beyond the rows it stamped itself (else `since`), so the lost response of the other one loses no message. Test seam `:atdd_to_device_before_stamp` (a 0-arity
      function in the application env of `:nebu`, called inside the delivery transaction between the read and the stamp).
    * A send holds `FOR KEY SHARE` on the target `devices` rows and `delete_device` locks the device row first: a send racing a device delete never leaves rows behind for the
      (recreated) device of the same id (LOW #6).
    * `active_users` locks only the ids that passed the shared-room join (MINOR 2): a request with 40 ids of which 3 share a room holds at most 3 + 2 advisory locks.
    * The purge worker goes through the facade `Nebu.Matrix.purge_expired_to_device/0` (MINOR 3).
  """
  use ExUnit.Case, async: false

  alias Nebu.Compliance.UserDeletionTestSupport, as: E
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
    bob = TD.user!("TDB")
    room = TD.share!(alice, bob)
    %{alice: alice, bob: bob, room: room}
  end

  defp ns(body), do: Enum.map(TD.events(body), & &1["content"]["n"])

  # the first sync of the device (nothing queued yet): the token everything continues from
  defp token!(device), do: device |> TD.sync() |> TD.next()

  # ═══ a delivery fault never fails /sync ═══════════════════════════════════════════════════════════════════════════════════════

  describe "a delivery fault never fails /sync" do
    test "locked rows: 200 with an empty to_device, the room message arrives, the retry delivers" do
      w = pair!()
      t0 = token!(w.bob)
      for n <- 1..3, do: TD.tell!(w.alice, w.bob, "m.dummy", %{"n" => n})
      S.say!(w.alice, w.room, "hello-room")

      h = TD.lock_rows!(w.bob.uid, w.bob.dev)
      body = TD.sync(w.bob, t0)
      assert TD.events(body) == [], "a locked row is skipped, never waited for"
      assert body["to_device"] == %{"events" => []}
      assert Enum.any?(S.join_timeline(body, w.room), &(&1["content"]["body"] == "hello-room")), "the room data is unaffected"
      assert TD.queue_count(w.bob.uid, w.bob.dev) == 3

      E.finish(h, :rollback)
      assert ns(TD.sync(w.bob, t0)) == [1, 2, 3], "nothing was lost: the same position delivers once the lock is gone"
    end

    test "ONLY the oldest row is locked: the stamp skips it, the others are delivered (skip, not wait), the skipped one follows with the next sync" do
      w = pair!()
      t0 = token!(w.bob)
      for n <- 1..3, do: TD.tell!(w.alice, w.bob, "m.dummy", %{"n" => n})
      h = TD.lock_rows!(w.bob.uid, w.bob.dev, 1)
      body = TD.sync(w.bob, t0)
      assert ns(body) == [2, 3], "the locked row 1 was skipped, the free rows were delivered"
      E.finish(h, :rollback)
      assert {[%{"content" => %{"n" => 1}}], _} = TD.drain(w.bob, TD.next(body))
    end

    test "the ack skips ONLY the locked row: the other acknowledged row is deleted and the new message is delivered in the same sync" do
      w = pair!()
      t0 = token!(w.bob)
      for n <- 1..2, do: TD.tell!(w.alice, w.bob, "m.dummy", %{"n" => n})
      b1 = TD.sync(w.bob, t0)
      assert ns(b1) == [1, 2]
      TD.tell!(w.alice, w.bob, "m.dummy", %{"n" => 3})

      h = TD.lock_rows!(w.bob.uid, w.bob.dev, 1)
      b2 = TD.sync(w.bob, TD.next(b1))
      assert ns(b2) == [3], "the ack did not wait for the locked row 1, the new message came"
      assert T.sql!("SELECT count(*) FROM #{TD.messages_table()} WHERE user_id = $1", [w.bob.uid]).rows == [[2]], "row 2 was deleted, rows 1 (locked) and 3 remain"
      E.finish(h, :rollback)
    end

    test "a fault in the delivery of an EMPTY-handed token keeps the position: the next_batch can be used again at once" do
      w = pair!()
      t0 = token!(w.bob)
      TD.tell!(w.alice, w.bob, "m.dummy", %{"n" => 1})
      h = TD.lock_rows!(w.bob.uid, w.bob.dev)
      t1 = TD.next(TD.sync(w.bob, t0))
      assert is_binary(t1)
      E.finish(h, :rollback)
      assert ns(TD.sync(w.bob, t1)) == [1]
    end

    test "the ack meets a row lock: 200, the rows stay until the lock is gone, then they are deleted" do
      w = pair!()
      t0 = token!(w.bob)
      for n <- 1..3, do: TD.tell!(w.alice, w.bob, "m.dummy", %{"n" => n})
      b1 = TD.sync(w.bob, t0)
      assert ns(b1) == [1, 2, 3]
      t1 = TD.next(b1)

      h = TD.lock_rows!(w.bob.uid, w.bob.dev)
      b2 = TD.sync(w.bob, t1)
      assert TD.events(b2) == []
      assert TD.queue_count(w.bob.uid, w.bob.dev) == 3, "the locked rows are not deleted (and the ack did not wait for the lock)"
      td_group = fn token -> token |> String.split(".") |> Enum.at(2) end
      assert td_group.(TD.next(b2)) == td_group.(t1) and td_group.(t1) != nil, "the position of the failed answer is the presented one"

      E.finish(h, :rollback)
      b3 = TD.sync(w.bob, t1)
      assert TD.events(b3) == []
      assert TD.queue_count(w.bob.uid, w.bob.dev) == 0, "the retry of the acknowledgement deletes them"
    end

    test "a send into a full queue with locked oldest rows answers 200 at once, the next send catches up" do
      w = pair!()
      TD.seam(:max_per_device, 3)
      for n <- 1..3, do: TD.tell!(w.alice, w.bob, "m.dummy", %{"n" => n})

      h = TD.lock_rows!(w.bob.uid, w.bob.dev)
      {micros, c} = :timer.tc(fn -> TD.put_send(w.alice, "m.dummy", TD.txn(), TD.msg(w.bob, %{"n" => 4})) end)
      assert {c.status, c.resp_body} == {200, "{}"}
      assert div(micros, 1000) < 1_500, "the eviction skipped the locked rows instead of waiting for them (#{div(micros, 1000)} ms)"
      assert TD.queue_count(w.bob.uid, w.bob.dev) == 4

      E.finish(h, :rollback)
      TD.tell!(w.alice, w.bob, "m.dummy", %{"n" => 5})
      assert ns(TD.sync(w.bob)) == [3, 4, 5], "the next send caught the queue up to its cap, oldest first"
    end

    test "a delivery over the statement timeout answers 200 with an empty to_device, the retry delivers" do
      w = pair!()
      t0 = token!(w.bob)
      TD.tell!(w.alice, w.bob, "m.dummy", %{"n" => 1, "m" => "SLOWSTAMP"})
      S.say!(w.alice, w.room, "hello-room")
      TD.seam(:statement_timeout_ms, 300)
      remove = TD.slow_statement_trigger!("SLOWSTAMP", 2, :update)

      {micros, body} = :timer.tc(fn -> TD.sync(w.bob, t0) end)
      assert body["to_device"] == %{"events" => []}
      assert Enum.any?(S.join_timeline(body, w.room), &(&1["content"]["body"] == "hello-room"))
      assert div(micros, 1000) < 1_800, "cancelled by the statement timeout, not after the 2 s of the statement"
      assert T.sql!("SELECT count(*) FROM #{TD.messages_table()} WHERE user_id = $1 AND delivery_seq IS NOT NULL", [w.bob.uid]).rows == [[0]]

      remove.()
      assert [1] = ns(TD.sync(w.bob, t0))
    end

    test "a failing delivery keeps the PRESENTED to-device position (third token group), the acknowledgement rolls back with it, the retry delivers" do
      w = pair!()
      t0 = token!(w.bob)
      TD.tell!(w.alice, w.bob, "m.dummy", %{"n" => 1})
      b1 = TD.sync(w.bob, t0)
      assert ns(b1) == [1]
      t1 = TD.next(b1)
      group = fn token -> token |> String.split(".") |> Enum.at(2) end
      assert group.(t1) != nil, "the first answer carries a to-device position"

      TD.tell!(w.alice, w.bob, "m.dummy", %{"n" => 2, "m" => "SLOWSTAMP2"})
      TD.seam(:statement_timeout_ms, 300)
      remove = TD.slow_statement_trigger!("SLOWSTAMP2", 2, :update)

      b2 = TD.sync(w.bob, t1)
      assert b2["to_device"] == %{"events" => []}
      assert group.(TD.next(b2)) == group.(t1), "the failed answer keeps the presented position (it must not drop to 0 or advance)"
      assert TD.queue_count(w.bob.uid, w.bob.dev) == 2, "the acknowledgement rolled back with the failed transaction: nothing was deleted"

      remove.()
      assert ns(TD.sync(w.bob, TD.next(b2))) == [2], "the retry acknowledges the first message and delivers the second"
      assert TD.queue_count(w.bob.uid, w.bob.dev) == 1
    end

    test "a send over the statement timeout: 429, nothing stored, the txn id is not burnt" do
      w = pair!()
      TD.seam(:statement_timeout_ms, 300)
      remove = TD.slow_statement_trigger!("SLOWSEND", 2, :insert)
      t = TD.txn()

      {micros, c} = :timer.tc(fn -> TD.put_send(w.alice, "m.dummy", t, TD.msg(w.bob, %{"n" => 1, "m" => "SLOWSEND"})) end)
      TD.assert_429(c, "a send over the statement timeout")
      assert div(micros, 1000) < 1_800
      assert {TD.queue_count(w.bob.uid), TD.txn_count(w.alice.uid)} == {0, 0}

      remove.()
      TD.send!(w.alice, "m.dummy", t, TD.msg(w.bob, %{"n" => 1, "m" => "SLOWSEND"}))
      assert TD.queue_count(w.bob.uid) == 1, "the same txn id works afterwards"
    end

    test "a SLOW statement below the timeout is not cut: the default statement timeout (2 s) lets a 300 ms insert finish" do
      w = pair!()
      _ = TD.slow_statement_trigger!("SLOWOK", 0.3, :insert)
      TD.send!(w.alice, "m.dummy", TD.txn(), TD.msg(w.bob, %{"n" => 1, "m" => "SLOWOK"}))
      assert TD.queue_count(w.bob.uid) == 1
    end
  end

  # ═══ the lost race of two overlapping syncs ═══════════════════════════════════════════════════════════════════════════════════

  describe "two overlapping syncs with the same since (code review MINOR 1)" do
    test "A/B trace: A delivers [1,2] and is lost, B stamps nothing: the client still gets 1 and 2 from B's token" do
      w = pair!()
      t0 = token!(w.bob)
      TD.tell!(w.alice, w.bob, "m.dummy", %{"n" => 1})

      flag = :atomics.new(1, [])
      parent = self()

      hook = fn ->
        :atomics.add(flag, 1, 1)

        # only the FIRST delivery (B) acts: A is a delivery as well and must not recurse
        if :atomics.get(flag, 1) == 1 do
          task =
            Task.async(fn ->
              TD.tell!(w.alice, w.bob, "m.dummy", %{"n" => 2})
              TD.sync(w.bob, t0)
            end)

          send(parent, {:a_body, Task.await(task, 15_000)})
        end
      end

      TD.put_env_restoring(:nebu, :atdd_to_device_before_stamp, hook)
      b = TD.sync(w.bob, t0)
      assert_receive {:a_body, a}, 5_000
      assert :atomics.get(flag, 1) >= 2, "the seam ran in B and in A (the test needs the overlap)"
      assert [1, 2] = ns(a), "A (the faster one) delivered both messages: its response is the one that gets lost"

      Application.delete_env(:nebu, :atdd_to_device_before_stamp)
      {later, _} = TD.drain(w.bob, TD.next(b))
      delivered = Enum.sort(ns(b) ++ Enum.map(later, & &1["content"]["n"]))
      assert delivered == [1, 2], "B carried #{inspect(ns(b))} and the continuation #{inspect(later)}: nothing may be lost"
    end

    test "the sync that lost the race carries no position beyond its own stamps (nothing acknowledged)" do
      w = pair!()
      t0 = token!(w.bob)
      TD.tell!(w.alice, w.bob, "m.dummy", %{"n" => 1})
      flag = :atomics.new(1, [])

      hook = fn ->
        if :atomics.add_get(flag, 1, 1) == 1, do: Task.await(Task.async(fn -> TD.sync(w.bob, t0) end), 15_000)
      end

      TD.put_env_restoring(:nebu, :atdd_to_device_before_stamp, hook)
      b = TD.sync(w.bob, t0)
      Application.delete_env(:nebu, :atdd_to_device_before_stamp)

      assert TD.events(b) == [], "B stamped nothing: it carries nothing (the message it read belongs to A's response)"
      assert TD.queue_count(w.bob.uid, w.bob.dev) == 1
      assert ns(TD.sync(w.bob, TD.next(b))) == [1], "its token redelivers: still unacknowledged"
    end
  end

  describe "the lost stamp race at the store level (code review MINOR 1: the position a response claims)" do
    alias Nebu.Matrix.ToDeviceStore, as: Store

    # B (outer) reads [m], stalls between its read and its stamp; inside that gap a message `n` is committed and A (a delivery of its own connection) reads [m, n] and
    # stamps both. B's stamp then matches 0 rows. B must not claim a position beyond what it stamped itself (here: nothing, so its `since`), else the next acknowledgement
    # (`delivery_seq <= position`) deletes `n` although the response of A may be lost.
    test "B stamps nothing: it carries nothing and its position stays at `since`; continuing from it loses neither message" do
      w = pair!()
      TD.tell!(w.alice, w.bob, "m.dummy", %{"n" => 1})
      flag = :atomics.new(1, [])
      parent = self()

      hook = fn ->
        if :atomics.add_get(flag, 1, 1) == 1 do
          # (in a Task: its own connection, the hook itself runs inside B's open transaction)
          a =
            Task.await(
              Task.async(fn ->
                TD.tell!(w.alice, w.bob, "m.dummy", %{"n" => 2})
                Store.deliver(w.bob.uid, w.bob.dev, nil)
              end),
              15_000
            )

          send(parent, {:a, a})
        end
      end

      TD.put_env_restoring(:nebu, :atdd_to_device_before_stamp, hook)
      {:ok, b} = Store.deliver(w.bob.uid, w.bob.dev, nil)
      Application.delete_env(:nebu, :atdd_to_device_before_stamp)
      assert_receive {:a, {:ok, a}}, 5_000

      assert Enum.map(a.events, & &1["content"]["n"]) == [1, 2], "A stamped both rows"
      assert a.position > 0
      assert b.events == [], "B stamped nothing: it carries nothing"
      assert b.position == 0, "B's position is its `since` (0), not a fresh stamp number above A's stamp (got #{b.position}, A claims #{a.position})"

      {:ok, again} = Store.deliver(w.bob.uid, w.bob.dev, b.position)
      assert Enum.map(again.events, & &1["content"]["n"]) == [1, 2], "continuing from B's position still delivers both messages (nothing was acknowledged)"
    end

    test "the same with a presented position: B's position stays at the presented one" do
      w = pair!()
      TD.tell!(w.alice, w.bob, "m.dummy", %{"n" => 1})
      {:ok, first} = Store.deliver(w.bob.uid, w.bob.dev, nil)
      assert first.position > 0
      TD.tell!(w.alice, w.bob, "m.dummy", %{"n" => 2})
      flag = :atomics.new(1, [])

      hook = fn ->
        if :atomics.add_get(flag, 1, 1) == 1 do
          Task.await(
            Task.async(fn ->
              TD.tell!(w.alice, w.bob, "m.dummy", %{"n" => 3})
              Store.deliver(w.bob.uid, w.bob.dev, first.position)
            end),
            15_000
          )
        end
      end

      TD.put_env_restoring(:nebu, :atdd_to_device_before_stamp, hook)
      {:ok, b} = Store.deliver(w.bob.uid, w.bob.dev, first.position)
      Application.delete_env(:nebu, :atdd_to_device_before_stamp)

      assert b.events == [] and b.position == first.position, "B: #{inspect(b)}"
    end

    test "a response that stamped part of its batch carries the rows it stamped and the earlier-stamped ones" do
      w = pair!()
      TD.tell!(w.alice, w.bob, "m.dummy", %{"n" => 1})
      {:ok, first} = Store.deliver(w.bob.uid, w.bob.dev, nil)
      TD.tell!(w.alice, w.bob, "m.dummy", %{"n" => 2})
      {:ok, retry} = Store.deliver(w.bob.uid, w.bob.dev, nil)
      assert Enum.map(retry.events, & &1["content"]["n"]) == [1, 2], "an earlier-stamped row is carried again with a new one"
      assert retry.position > first.position, "the new stamp is above the earlier one"
      {:ok, idle} = Store.deliver(w.bob.uid, w.bob.dev, retry.position)
      assert idle.events == [] and idle.position == retry.position
    end

    test "a pure redelivery (nothing newly stamped) keeps the position of the rows it carries, so the next acknowledgement deletes them" do
      w = pair!()
      TD.tell!(w.alice, w.bob, "m.dummy", %{"n" => 1})
      {:ok, first} = Store.deliver(w.bob.uid, w.bob.dev, nil)
      {:ok, retry} = Store.deliver(w.bob.uid, w.bob.dev, nil)
      assert Enum.map(retry.events, & &1["content"]["n"]) == [1]
      assert retry.position == first.position, "the retry carries the stamped row and claims its stamp (not `since`)"
      {:ok, idle} = Store.deliver(w.bob.uid, w.bob.dev, retry.position)
      assert idle.events == []
      assert TD.queue_count(w.bob.uid, w.bob.dev) == 0, "acknowledged by the retry's position"
    end
  end

  # ═══ a send racing a device delete ════════════════════════════════════════════════════════════════════════════════════════════

  describe "a send racing a device delete (LOW #6)" do
    test "delete_device waits for the send in flight, a recreated device of the same id starts empty" do
      w = pair!()
      _ = TD.slow_statement_trigger!("SLOWDEV", 1.5, :insert)

      send_task = Task.async(fn -> TD.put_send(w.alice, "m.dummy", TD.txn(), TD.msg(w.bob, %{"n" => 1, "m" => "SLOWDEV"})) end)
      TD.wait_sleeping(1)
      delete_task = Task.async(fn -> Nebu.Matrix.DeviceKeyStore.delete_device(w.bob.uid, w.bob.dev) end)

      assert Task.yield(delete_task, 300) == nil, "the delete waits for the send in flight (the key share of the devices row)"
      assert %{status: 200} = Task.await(send_task, 15_000)
      assert :ok = Task.await(delete_task, 15_000)

      assert TD.queue_count(w.bob.uid, w.bob.dev) == 0, "the row the send inserted was deleted by the device delete that came after it"
      T.sql!("DELETE FROM devices WHERE user_id = $1 AND device_id = $2", [w.bob.uid, w.bob.dev])
      reborn = TD.new_token!(w.bob)
      :ok = Nebu.Matrix.DeviceKeyStore.upsert_device(reborn.uid, reborn.dev)
      assert TD.queue_count(reborn.uid, reborn.dev) == 0
      assert TD.events(TD.sync(reborn)) == []
    end

    test "the same with a `*` target (the lateral device lookup takes the key share as well) and with the raising delete_device! inside a transaction" do
      w = pair!()
      _ = TD.slow_statement_trigger!("SLOWSTAR", 1.5, :insert)
      send_task = Task.async(fn -> TD.put_send(w.alice, "m.dummy", TD.txn(), TD.star(w.bob, %{"n" => 1, "m" => "SLOWSTAR"})) end)
      TD.wait_sleeping(1)

      delete_task = Task.async(fn -> Nebu.Repo.transaction(fn -> Nebu.Matrix.DeviceKeyStore.delete_device!(w.bob.uid, w.bob.dev) end) end)
      assert Task.yield(delete_task, 300) == nil, "delete_device! waits for the send in flight"
      assert %{status: 200} = Task.await(send_task, 15_000)
      assert {:ok, :ok} = Task.await(delete_task, 15_000)
      assert TD.queue_count(w.bob.uid, w.bob.dev) == 0
    end

    test "a send after the delete finds no device: nothing is queued for the gone device" do
      w = pair!()
      T.sql!("DELETE FROM devices WHERE user_id = $1 AND device_id = $2", [w.bob.uid, w.bob.dev])
      TD.tell!(w.alice, w.bob, "m.dummy", %{"n" => 1})
      assert TD.queue_count(w.bob.uid, w.bob.dev) == 0
      :ok = Nebu.Matrix.DeviceKeyStore.upsert_device(w.bob.uid, w.bob.dev)
      assert TD.queue_count(w.bob.uid, w.bob.dev) == 0
    end

    test "delete_user_device/2 racing a send never leaves rows behind a deleted device" do
      w = pair!()
      _ = TD.slow_statement_trigger!("SLOWADM", 1.5, :insert)
      send_task = Task.async(fn -> TD.put_send(w.alice, "m.dummy", TD.txn(), TD.msg(w.bob, %{"n" => 1, "m" => "SLOWADM"})) end)
      TD.wait_sleeping(1)
      result = Nebu.Matrix.delete_user_device(w.bob.uid, w.bob.dev)
      assert result in [:ok, {:error, :unavailable}]
      assert %{status: 200} = Task.await(send_task, 15_000)

      device_left? = T.sql!("SELECT count(*) FROM devices WHERE user_id = $1 AND device_id = $2", [w.bob.uid, w.bob.dev]).rows == [[1]]
      rows = TD.queue_count(w.bob.uid, w.bob.dev)
      assert device_left? or rows == 0, "the device is gone but #{rows} row(s) remain: they would be delivered to a recreated device of the same id"
    end
  end

  # ═══ advisory locks of a send (MINOR 2) ═════════════════════════════════════════════════════════════════════════════════════════

  describe "advisory locks of a send (code review MINOR 2)" do
    test "40 ids of which 3 share a room: the send holds at most 3 + 2 advisory locks (not 40)" do
      alice = TD.user!("TDA")
      friends = for _ <- 1..3, do: (u = TD.user!("TDF"); TD.share!(alice, u); u)
      strangers = for i <- 1..37, do: "@nobody-#{i}-#{T.rand(4)}:test.local"
      _ = TD.slow_statement_trigger!("SLOWLOCK", 0.5, :insert)

      messages =
        friends
        |> Enum.map(&TD.msg(&1, %{"n" => 1, "m" => "SLOWLOCK"}))
        |> Kernel.++(Enum.map(strangers, &TD.msg({&1, "D"}, %{"n" => 1, "m" => "SLOWLOCK"})))
        |> TD.merge()

      task = Task.async(fn -> TD.put_send(alice, "m.dummy", TD.txn(), messages) end)
      TD.wait_sleeping(1)
      [pid] = TD.sleeping_pids()
      locks = T.sql!("SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND objsubid = 1 AND pid = $1 AND granted", [pid]).rows |> hd() |> hd()
      assert locks in 3..5, "the send holds #{locks} single-key advisory locks (3 matched recipients + the sender's fence; never one per requested id)"
      c = Task.await(task, 15_000)
      assert {c.status, c.resp_body} == {200, "{}"}
    end
  end

  # ═══ the facade of the purge worker (MINOR 3) ═══════════════════════════════════════════════════════════════════════════════════

  describe "the purge goes through the facade Nebu.Matrix.purge_expired_to_device/0 (code review MINOR 3)" do
    test "the facade exists and removes the rows past their TTL and the expired transaction records, keeps the fresh ones" do
      w = pair!()
      TD.tell!(w.alice, w.bob, "m.dummy", %{"n" => 1})
      TD.age_queue!(w.bob.uid, w.bob.dev, TD.defaults().ttl_seconds + 60)
      TD.age_txns!(w.alice.uid, w.alice.dev, TD.defaults().txn_ttl_seconds + 60)
      TD.tell!(w.alice, w.bob, "m.dummy", %{"n" => 2})

      assert Code.ensure_loaded?(Nebu.Matrix) and function_exported?(Nebu.Matrix, :purge_expired_to_device, 0)
      assert Nebu.Matrix.purge_expired_to_device() != :undefined
      assert TD.queue_count(w.bob.uid, w.bob.dev) == 1
      assert TD.txn_count(w.alice.uid, w.alice.dev) == 1
    end
  end
end
