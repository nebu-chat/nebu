defmodule Nebu.Compliance.UserDeletionToDeviceTest do
  @moduledoc """
  Acceptance tests (REAL database) of the GDPR erasure part of story `to-device-messaging` (epic e2ee-client-support, REQ-2026-012): "Queue rows are purged on ... GDPR erasure", in the
  framework of story `gdpr-erasure-global-data`.

    * `Nebu.Compliance.UserDeletion.erased_tables/0` names `to_device_messages` and `to_device_txns` (the deleting code, the schema recurrence guard, the sweep and the docs inventory are
      driven by that list; `UserDeletionTestSupport.expected_erased/0` carries them and `seed_user!/2` seeds the state through the REAL route, so every generic erasure test of
      `user_deletion_*_test.exs` - one erasure, rollback of a failing step per table, the sweep, the late retry - covers the to-device state too). There is no foreign key between the two
      tables, so the order does not matter.
    * One erasure deletes the queue of the user (every message queued FOR it, from anybody), its idempotency records, AND the messages the user SENT that wait in other users' queues
      (authored content and the user id; decision of this step: the erasure deletes by `sender` as well); every row of another user (other senders' messages, other users' records) stays
      byte-identical and deliverable.
    * A send of an erased user's bearer that the provisioning cache still confirms (the in-flight request) is refused `403 M_USER_DEACTIVATED` (a permanent condition, like the account
      data, cross-signing and key backup writers) and stores nothing; a send TO an erased user is skipped silently.
    * The senders serialise with the erasure through the advisory lock `to_device_erasure|<user>` (its OWN key since the Kassandra review, cycle 1: the account data, cross-signing and key backup writers
      hold `sync_global|<user>` and must not make a message skip; the erasure takes both exclusively): while a transaction holds it, a send by that user is answered `429 M_LIMIT_EXCEEDED` AT ONCE (a shared TRY-lock: no waiter holds a pooled connection) and a send to that user is skipped silently (no oracle for
      the erasure state); a race between an erasure and a burst of sends never leaves a row of the erased user, as recipient or as sender.

  `async: false` (real `AuditWriter` seam via `E.setup_env!/0`, committed rows, own connections).
  """
  use ExUnit.Case, async: false

  alias Nebu.Compliance.UserDeletion
  alias Nebu.Compliance.UserDeletionTestSupport, as: E
  alias Nebu.Matrix.ToDeviceTestSupport, as: TD
  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration

  @tables ~w(to_device_messages to_device_txns)

  setup do
    # (order independent: an older suite that deletes `:event_dispatcher, :server_name` would make the `@x:test.local` invitees foreign for createRoom)
    Nebu.Test.ServerName.pin!(T.server_name())
    env = E.setup_env!()
    # AFTER `setup_env!` (it resets the limiter to enabled with a frozen clock): these tests send more than the burst of 30
    TD.disable_rate_limit()
    {:ok, env}
  end

  defp erase!(uid), do: UserDeletion.delete_user_keys(E.admin(), uid, "atdd erasure")

  # an in-flight request: the bearer was confirmed (and cached) while the user was active, then the status is set
  defp in_flight_device!(uid) do
    device = TD.device!(%{uid: uid}, "TDF")
    assert T.whoami(device.at).status == 200, "precondition: the session is accepted and the user is in the provisioning cache"
    T.sql!("UPDATE users SET deletion_status = 'keys_deleted' WHERE user_id = $1", [uid])
    device
  end

  defp sync_global_sql, do: "SELECT pg_advisory_xact_lock(hashtextextended('sync_global|' || $1::text, 0))"
  defp lock_sql, do: "SELECT pg_advisory_xact_lock(hashtextextended('to_device_erasure|' || $1::text, 0))"

  # a world: alice and bob share a room; bob has two devices, alice one; carol shares with bob and alice
  defp world! do
    alice = TD.user!("TDA")
    bob1 = TD.user!("TDB")
    bob2 = TD.device!(bob1, "TDC")
    carol = TD.user!("TDK")
    TD.share!(alice, bob1)
    TD.share!(carol, bob1)
    TD.share!(alice, carol)
    %{alice: alice, bob1: bob1, bob2: bob2, carol: carol}
  end

  defp timed(fun) do
    started = System.monotonic_time(:millisecond)
    result = fun.()
    {result, System.monotonic_time(:millisecond) - started}
  end

  describe "the inventory" do
    test "erased_tables/0 names both to-device tables and agrees with the inventory of the suites" do
      erased = UserDeletion.erased_tables()
      for t <- @tables, do: assert(t in erased, "#{t} is not erased by the GDPR erasure")
      assert Enum.sort(erased) == Enum.sort(E.expected_erased())
    end

    test "the seeded world has rows in both tables (so every generic erasure test proves something)", %{cid: cid} do
      a = E.seed_user!(cid, "a")
      assert E.count("to_device_messages", a.uid) == 2
      assert E.count("to_device_messages", a.uid, "sender") == 2
      assert E.count("to_device_txns", a.uid) == 2
      assert a.to_device.queued_for == 2
    end
  end

  describe "the erasure deletes queue, records and SENT messages, nothing of another user" do
    test "A's queue, records and sent messages are gone; B's and C's rows are untouched and still delivered" do
      w = world!()
      TD.tell!(w.carol, w.alice, "m.dummy", %{"canary" => "from-carol-to-alice"})
      TD.tell!(w.bob1, w.alice, "m.dummy", %{"canary" => "from-bob-to-alice"})
      TD.tell!(w.alice, w.bob1, "m.dummy", %{"canary" => "from-alice-to-bob-1"})
      TD.send!(w.alice, "m.dummy", TD.txn(), TD.star(w.bob1, %{"canary" => "from-alice-to-bob-star"}))
      TD.tell!(w.carol, w.bob1, "m.dummy", %{"canary" => "from-carol-to-bob"})
      TD.tell!(w.bob1, w.carol, "m.dummy", %{"canary" => "from-bob-to-carol"})

      assert {TD.queue_count(w.alice.uid), TD.sent_count(w.alice.uid), TD.txn_count(w.alice.uid)} == {2, 3, 2}
      carol_queue = E.fp("to_device_messages", w.carol.uid)
      bob_txns = E.fp("to_device_txns", w.bob1.uid)

      assert {:ok, %{keys_deleted_at: at}} = erase!(w.alice.uid)
      assert is_integer(at)

      assert TD.queue_count(w.alice.uid) == 0, "the queue of A is gone"
      assert TD.txn_count(w.alice.uid) == 0, "A's idempotency records are gone"
      assert TD.sent_count(w.alice.uid) == 0, "the messages A SENT, queued for B, are gone"

      contents = Enum.map(TD.events(TD.sync(w.bob1)), & &1["content"]["canary"])
      assert contents == ["from-carol-to-bob"], "B's queue holds exactly the message of C (A's are gone)"
      assert E.fp("to_device_messages", w.carol.uid) == carol_queue, "C's queue (the message of B) is untouched"
      assert E.fp("to_device_txns", w.bob1.uid) == bob_txns, "B's records are untouched"
    end

    test "the erasure logs and audits no content (the canaries of the seeded world never reach the log)", %{cid: cid} do
      a = E.seed_user!(cid, "a")
      log = ExUnit.CaptureLog.capture_log([level: :debug], fn -> assert {:ok, _} = erase!(a.uid) end)
      T.refute_secrets_in_log(log, Map.take(a.secrets, [:to_device]))
      assert E.count("to_device_messages", a.uid) == 0
      assert E.count("to_device_messages", a.uid, "sender") == 0
      assert E.count("to_device_txns", a.uid) == 0
    end

    test "a blocked delete of the queue rolls the whole erasure back (the user is not half erased)", %{cid: cid} do
      a = E.seed_user!(cid, "a")
      before = E.snapshot(a.uid, @tables)
      E.block!("to_device_messages", "DELETE", a.uid)

      assert {:error, _} = erase!(a.uid)
      assert E.snapshot(a.uid, @tables) == before
    end

    test "a blocked delete of the idempotency records rolls the erasure back as well", %{cid: cid} do
      a = E.seed_user!(cid, "a")
      before = E.snapshot(a.uid, @tables)
      E.block!("to_device_txns", "DELETE", a.uid)

      assert {:error, _} = erase!(a.uid)
      assert E.snapshot(a.uid, @tables) == before
    end
  end

  describe "an erased user's late writes" do
    test "a send of the in-flight bearer is refused 403 M_USER_DEACTIVATED, stores nothing (no queue row, no record), logs no content and no error level" do
      w = world!()
      device = in_flight_device!(w.alice.uid)
      canary = "late-td-" <> T.rand(6)

      log = ExUnit.CaptureLog.capture_log([level: :debug], fn -> send(self(), {:resp, TD.put_send(device, "m.dummy", TD.txn(), TD.msg(w.bob1, %{"c" => canary}))}) end)

      assert_received {:resp, resp}
      assert resp.status == 403 and TD.json(resp)["errcode"] == "M_USER_DEACTIVATED", "got #{resp.status} #{resp.resp_body}"
      assert TD.queue_count(w.bob1.uid) == 0
      assert TD.txn_count(w.alice.uid, device.dev) == 0
      refute log =~ "[error]", "a permanent refusal is not an error-level event"
      refute log =~ canary
    end

    test "a send TO an erased user is skipped silently (the identical 200 {}), nothing is queued for it" do
      w = world!()
      assert {:ok, _} = erase!(w.bob1.uid)
      c = TD.put_send(w.alice, "m.dummy", TD.txn(), TD.star(w.bob1, %{"n" => 1}))
      assert TD.shape(c) == TD.shape(TD.put_send(w.alice, "m.dummy", TD.txn(), TD.msg(w.carol, %{"n" => 1}))), "the answer equals that of a delivered request"
      assert TD.queue_count(w.bob1.uid) == 0
    end
  end

  describe "the senders serialise with the erasure through its OWN fence `to_device_erasure|<user>` (shared try-lock, no waiter)" do
    test "while the user's lock is held: a send BY the user is 429 at once, a send TO the user is skipped" do
      w = world!()
      holder = E.hold(fn -> T.sql!(lock_sql(), [w.alice.uid]) end)

      {by, ms1} = timed(fn -> TD.put_send(w.alice, "m.dummy", TD.txn(), TD.msg(w.bob1, %{"n" => 1})) end)
      assert ms1 < 3_000, "the sender waited for the lock (#{ms1} ms): it must be a try-lock"
      TD.assert_429(by, "a send by the user whose erasure holds the lock")
      assert TD.queue_count(w.bob1.uid) == 0

      {to, ms2} = timed(fn -> TD.put_send(w.carol, "m.dummy", TD.txn(), TD.msg(w.alice, %{"n" => 2})) end)
      assert ms2 < 3_000, "the sender waited for the recipient's lock (#{ms2} ms)"
      baseline = TD.shape(TD.put_send(w.carol, "m.dummy", TD.txn(), TD.msg(w.bob1, %{"n" => 5})))
      assert TD.shape(to) == baseline, "no oracle for an erasure in progress: status, body and headers equal a delivered request"
      assert TD.queue_count(w.alice.uid) == 0

      E.finish(holder, :rollback)
      TD.send!(w.alice, "m.dummy", TD.txn(), TD.msg(w.bob1, %{"n" => 3}))
      TD.send!(w.carol, "m.dummy", TD.txn(), TD.msg(w.alice, %{"n" => 4}))
      assert {TD.queue_count(w.bob1.uid), TD.queue_count(w.alice.uid)} == {2, 1}, "bob: the baseline message of carol and the released send of alice; alice: the released send of carol"
    end

    test "a recipient's writer holding sync_global|<user> does NOT make a message skip: it is queued" do
      w = world!()
      holder = E.hold(fn -> T.sql!(sync_global_sql(), [w.alice.uid]) end)

      {c, ms} = timed(fn -> TD.put_send(w.carol, "m.dummy", TD.txn(), TD.msg(w.alice, %{"n" => 1})) end)
      assert {c.status, c.resp_body} == {200, "{}"}
      assert ms < 3_000, "the sender waited for sync_global (#{ms} ms)"
      assert TD.queue_count(w.alice.uid) == 1, "the message was queued although the recipient's writer holds sync_global"

      # the same for the SENDER side: a send by the user whose own writer holds sync_global is served (and its txn id is used up by a real send)
      {c2, _} = timed(fn -> TD.put_send(w.alice, "m.dummy", TD.txn(), TD.msg(w.bob1, %{"n" => 2})) end)
      assert {c2.status, c2.resp_body} == {200, "{}"}
      assert TD.queue_count(w.bob1.uid) == 1
      E.finish(holder, :rollback)
    end

    test "the erasure takes the fence EXCLUSIVELY: it waits for a send in flight (a shared holder)" do
      w = world!()
      holder = E.hold(fn -> T.sql!("SELECT pg_advisory_xact_lock_shared(hashtextextended('to_device_erasure|' || $1::text, 0))", [w.alice.uid]) end)
      erase = Task.async(fn -> erase!(w.alice.uid) end)
      assert Task.yield(erase, 1_000) == nil, "the erasure did not wait for the in-flight send (it does not take the fence)"
      E.finish(holder, :rollback)
      assert {:ok, _} = Task.await(erase, 30_000)
    end

    test "a race between the erasure and a burst of sends leaves no row of the erased user (4 rounds)" do
      for _round <- 1..4 do
        w = world!()
        stop = :atomics.new(1, [])

        senders =
          for {from, to} <- [{w.alice, w.bob1}, {w.alice, w.bob2}, {w.carol, w.alice}, {w.bob1, w.alice}] do
            Task.async(fn ->
              Enum.reduce_while(1..40, :ok, fn i, _ ->
                if :atomics.get(stop, 1) == 1 do
                  {:halt, :ok}
                else
                  TD.put_send(from, "m.dummy", "r#{i}-#{TD.txn()}", TD.msg(to, %{"i" => i}))
                  {:cont, :ok}
                end
              end)
            end)
          end

        # erase once the burst really is in flight (rows of the user exist), not after a guessed pause
        assert :ok = Nebu.Matrix.ModerationTestSupport.wait_until(fn -> TD.queue_count(w.alice.uid) + TD.sent_count(w.alice.uid) > 0 end, 5_000)
        assert {:ok, _} = erase!(w.alice.uid)
        :atomics.put(stop, 1, 1)
        Enum.each(senders, &Task.await(&1, 60_000))

        assert TD.queue_count(w.alice.uid) == 0, "a message was queued for the erased user after the erasure"
        assert TD.sent_count(w.alice.uid) == 0, "a message of the erased user was queued after the erasure"
        assert TD.txn_count(w.alice.uid) == 0, "a record of the erased user was written after the erasure"
      end
    end
  end
end
