defmodule Nebu.Matrix.ToDeviceTwoPhaseSendTest do
  @moduledoc """
  Acceptance tests for story `to-device-messaging` (epic e2ee-client-support, REQ-2026-012), cycle 4: the owner FIXES Kassandra's cycle 1 MEDIUM (reverse direction of the device-delete race).

  Before: a send held `FOR KEY SHARE` on the recipient's `devices` rows from the target lookup until its COMMIT, i.e. through the seven soft-eviction statements (up to 2 s each).
  PostgreSQL grants new key-share lockers without queueing them behind a waiting `FOR UPDATE`, so overlapping sends of co-members could starve the victim's bounded `FOR UPDATE`
  (OAuth token rotation, `/oauth2/revoke`, `DELETE /devices`, the admin revoke: 300 ms `lock_timeout`).

  Now a send is TWO transactions (Decisions D23 - D26 of the story):

    * PHASE 1 (short): timeouts, the shared try-locks, the transaction record, the byte bucket, the target lookup with `FOR KEY SHARE` IMMEDIATELY before the INSERT, the INSERT, the COMMIT.
      No eviction, count or sum scan runs inside the key-share window.
    * PHASE 2 (a second transaction after the commit, best effort): the soft eviction, WITHOUT any lock on `devices`. It runs in the request process BEFORE the response (so a quiescent
      state follows the answer). A failure or a timeout there never fails the send (`200 {}`, the rows are queued, the transaction id is recorded), logs the error KIND only, and the next
      send evicts anyway (the caps stay soft, as documented).

  The eviction is made slow with a privileged `BEFORE DELETE` trigger on a marked old row (`TD.slow_statement_trigger!/3` with `:delete`): while it sleeps another connection tries
  `SELECT .. FROM devices .. FOR UPDATE`. The cap seams are `:to_device_*` application keys (`TD.seam/2`). Rate limits are disabled.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Nebu.Matrix.ToDeviceTestSupport, as: TD
  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration

  @slow "SLOWEVICT"

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
    TD.share!(alice, bob)
    %{alice: alice, bob: bob}
  end

  defp sender_for!(bob) do
    s = TD.user!("TDS")
    TD.share!(s, bob)
    s
  end

  defp ns(body), do: Enum.map(TD.events(body), & &1["content"]["n"])

  # What the victim's bounded writers do (token rotation, revoke, device delete): `FOR UPDATE` on the device row under a 300 ms `lock_timeout` in a transaction of its own.
  # `{elapsed_ms, {:ok, result} | {:error, error}}`
  defp lock_device(uid, dev, nowait \\ "") do
    outcome =
      Nebu.Repo.transaction(fn ->
        {:ok, _} = Ecto.Adapters.SQL.query(Nebu.Repo, "SELECT set_config('lock_timeout', '300ms', true)", [])

        {micros, result} =
          :timer.tc(fn -> Ecto.Adapters.SQL.query(Nebu.Repo, "SELECT 1 FROM devices WHERE user_id = $1 AND device_id = $2 FOR UPDATE#{nowait}", [uid, dev]) end)

        v = {div(micros, 1000), result}
        if match?({:ok, _}, result), do: v, else: Nebu.Repo.rollback(v)
      end)

    case outcome do
      {:ok, v} -> v
      {:error, v} -> v
    end
  end

  defp assert_locked_at_once(result, label) do
    assert {ms, {:ok, %{num_rows: 1}}} = result, "#{label}: the FOR UPDATE on the device row did not succeed: #{inspect(result)}"
    assert ms < 300, "#{label}: the FOR UPDATE took #{ms} ms"
  end

  # ═══ the headline: no row lock on `devices` while a send is evicting ═════════════════════════════════════════════════════════

  describe "a send holds no row lock on devices while it evicts" do
    test "explicit target: a FOR UPDATE NOWAIT on the recipient's device row succeeds while the eviction of the send sleeps" do
      f = pair!()
      TD.seam(:max_per_sender_device, 1)
      TD.tell!(f.alice, f.bob, "m.dummy", %{"n" => 1, "m" => @slow})
      _ = TD.slow_statement_trigger!(@slow, 1.5, :delete)

      task = Task.async(fn -> TD.put_send(f.alice, "m.dummy", TD.txn(), TD.msg(f.bob, %{"n" => 2})) end)
      TD.wait_sleeping(1)

      assert_locked_at_once(lock_device(f.bob.uid, f.bob.dev, " NOWAIT"), "NOWAIT")
      assert %{status: 200, resp_body: "{}"} = Task.await(task, 15_000)
      assert ns(TD.sync(f.bob)) == [2], "the old row was evicted, the new one is delivered"
    end

    test "`*` target: the lateral device lookup holds no lock during the eviction either" do
      f = pair!()
      TD.seam(:max_per_sender_device, 1)
      TD.tell!(f.alice, f.bob, "m.dummy", %{"n" => 1, "m" => @slow})
      _ = TD.slow_statement_trigger!(@slow, 1.5, :delete)

      task = Task.async(fn -> TD.put_send(f.alice, "m.dummy", TD.txn(), TD.star(f.bob, %{"n" => 2})) end)
      TD.wait_sleeping(1)

      assert_locked_at_once(lock_device(f.bob.uid, f.bob.dev, " NOWAIT"), "NOWAIT with a `*` target")
      assert %{status: 200, resp_body: "{}"} = Task.await(task, 15_000)
    end

    test "four overlapping sends of four senders are all inside their eviction: a bounded FOR UPDATE (300 ms lock_timeout) succeeds at once, again and again" do
      f = pair!()
      senders = for _ <- 1..4, do: sender_for!(f.bob)
      TD.seam(:max_per_sender_device, 1)
      for {s, i} <- Enum.with_index(senders, 1), do: TD.tell!(s, f.bob, "m.dummy", %{"n" => i, "m" => @slow})
      _ = TD.slow_statement_trigger!(@slow, 1.5, :delete)

      tasks = for {s, i} <- Enum.with_index(senders, 1), do: Task.async(fn -> TD.put_send(s, "m.dummy", TD.txn(), TD.msg(f.bob, %{"n" => 100 + i})) end)
      TD.wait_sleeping(4)

      for round <- 1..5, do: assert_locked_at_once(lock_device(f.bob.uid, f.bob.dev), "round #{round} with four evictions in flight")

      for c <- Enum.map(tasks, &Task.await(&1, 15_000)), do: assert({c.status, c.resp_body} == {200, "{}"})
      assert ns(TD.sync(f.bob)) |> Enum.sort() == [101, 102, 103, 104]
    end

    test "the rows are committed BEFORE the eviction starts: the new message is queued, recorded and deliverable while the eviction sleeps" do
      f = pair!()
      TD.seam(:max_per_sender_device, 1)
      TD.tell!(f.alice, f.bob, "m.dummy", %{"n" => 1, "m" => @slow})
      _ = TD.slow_statement_trigger!(@slow, 1.5, :delete)
      before_txns = TD.txn_count(f.alice.uid, f.alice.dev)

      task = Task.async(fn -> TD.put_send(f.alice, "m.dummy", TD.txn(), TD.msg(f.bob, %{"n" => 2})) end)
      TD.wait_sleeping(1)

      assert TD.queue_count(f.bob.uid, f.bob.dev) == 2, "the old marked row and the new row: phase 1 is committed"
      assert TD.txn_count(f.alice.uid, f.alice.dev) == before_txns + 1, "the transaction record is committed"
      assert 2 in ns(TD.sync(f.bob)), "a sync already delivers the new message while the eviction runs"
      assert %{status: 200} = Task.await(task, 15_000)
    end

    test "the target device is woken right after phase 1: a waiting long poll returns while the eviction of the send is still running" do
      f = pair!()
      TD.seam(:max_per_sender_device, 1)
      TD.tell!(f.alice, f.bob, "m.dummy", %{"n" => 1, "m" => @slow})
      t0 = TD.next(TD.sync(f.bob))
      _ = TD.slow_statement_trigger!(@slow, 2.5, :delete)

      poll = Task.async(fn -> TD.sync(f.bob, t0, timeout: 10_000) end)
      TD.wait_polling(f.bob.uid)
      send_task = Task.async(fn -> TD.put_send(f.alice, "m.dummy", TD.txn(), TD.msg(f.bob, %{"n" => 2})) end)
      TD.wait_sleeping(1)

      assert {:ok, body} = Task.yield(poll, 1_200), "the long poll was not woken before the eviction ended"
      assert 2 in ns(body)
      assert Task.yield(send_task, 0) == nil, "the eviction was still running when the poll returned"
      assert %{status: 200} = Task.await(send_task, 15_000)
    end

    test "the key share around the INSERT stays: a send inside its INSERT still blocks a FOR UPDATE on the device row (the cycle 0 device-delete fix holds)" do
      f = pair!()
      _ = TD.slow_statement_trigger!("SLOWINS", 1.5, :insert)
      task = Task.async(fn -> TD.put_send(f.alice, "m.dummy", TD.txn(), TD.msg(f.bob, %{"n" => 1, "m" => "SLOWINS"})) end)
      TD.wait_sleeping(1)

      assert {_ms, {:error, %Postgrex.Error{postgres: %{code: :lock_not_available}}}} = lock_device(f.bob.uid, f.bob.dev, " NOWAIT")
      assert %{status: 200} = Task.await(task, 15_000)
    end
  end

  # ═══ a phase 2 failure never fails the send ═══════════════════════════════════════════════════════════════════════════════════

  describe "a failing eviction (phase 2) never fails the send" do
    test "statement timeout in the eviction: 200 {}, the rows are queued, the txn id is recorded, the retry is a no-op, the next send evicts" do
      f = pair!()
      TD.seam(:max_per_sender_device, 1)
      TD.seam(:statement_timeout_ms, 300)
      TD.tell!(f.alice, f.bob, "m.dummy", %{"n" => 1, "m" => @slow})
      remove = TD.slow_statement_trigger!(@slow, 2, :delete)
      txns = TD.txn_count(f.alice.uid, f.alice.dev)
      t = TD.txn()

      {micros, c} = :timer.tc(fn -> TD.put_send(f.alice, "m.dummy", t, TD.msg(f.bob, %{"n" => 2})) end)
      assert {c.status, c.resp_body} == {200, "{}"}
      assert div(micros, 1000) < 1_800, "cancelled by the statement timeout, not after the 2 s of the statement"
      assert TD.queue_count(f.bob.uid, f.bob.dev) == 2, "the new row is queued, the excess old row stays until the next send"
      assert TD.txn_count(f.alice.uid, f.alice.dev) == txns + 1, "the transaction id is recorded"

      assert %{status: 200, resp_body: "{}"} = TD.put_send(f.alice, "m.dummy", t, TD.msg(f.bob, %{"n" => 2}))
      assert TD.queue_count(f.bob.uid, f.bob.dev) == 2, "the retry of the recorded transaction queues nothing"

      remove.()
      TD.tell!(f.alice, f.bob, "m.dummy", %{"n" => 3})
      assert TD.queue_count(f.bob.uid, f.bob.dev) == 1, "the next send caught the queue up to its cap"
      assert ns(TD.sync(f.bob)) == [3]
    end

    test "a fresh send runs the seven eviction statements of phase 2, the retry of a recorded transaction runs none (no phase 2, nothing queued)" do
      f = pair!()
      t = TD.txn()
      {_, fresh} = TD.statements(fn -> TD.put_send(f.alice, "m.dummy", t, TD.msg(f.bob, %{"n" => 1})) end, "row_number")
      {resp, retry} = TD.statements(fn -> TD.put_send(f.alice, "m.dummy", t, TD.msg(f.bob, %{"n" => 1})) end, "row_number")

      assert length(fresh) == 7, "phase 2 of a fresh send: #{length(fresh)} eviction statements"
      assert retry == [], "the retry of a recorded transaction runs no eviction"
      assert {resp.status, resp.resp_body} == {200, "{}"}
      assert TD.queue_count(f.bob.uid, f.bob.dev) == 1
    end

    test "an eviction whose error message quotes the row: 200 {}, the log names the kind only (no row, no content)" do
      f = pair!()
      TD.seam(:max_per_sender_device, 1)
      canary = "EVICT-CANARY-" <> T.rand(6)
      TD.tell!(f.alice, f.bob, "m.dummy", %{"ciphertext" => canary})

      name = "atdd_td_evfault_" <> T.rand(4)
      T.privileged_sql!("CREATE FUNCTION #{name}() RETURNS trigger AS $$ BEGIN RAISE EXCEPTION 'quoted row: %', row_to_json(OLD)::text; END $$ LANGUAGE plpgsql")
      T.privileged_sql!("CREATE TRIGGER #{name} BEFORE DELETE ON to_device_messages FOR EACH ROW EXECUTE FUNCTION #{name}()")

      on_exit(fn ->
        T.privileged_sql!("DROP TRIGGER IF EXISTS #{name} ON to_device_messages")
        T.privileged_sql!("DROP FUNCTION IF EXISTS #{name}()")
      end)

      log =
        TD.with_log_level(:debug, fn ->
          capture_log([level: :debug], fn -> send(self(), {:resp, TD.put_send(f.alice, "m.dummy", TD.txn(), TD.msg(f.bob, %{"ciphertext" => "NEW-" <> canary}))}) end)
        end)

      assert_received {:resp, resp}
      assert {resp.status, resp.resp_body} == {200, "{}"}
      assert TD.queue_count(f.bob.uid, f.bob.dev) == 2
      refute log =~ canary
      refute log =~ "quoted row"
      assert log =~ ~r/evict/i, "the failed eviction is logged (kind only)"
    end
  end

  # ═══ the caps hold once the last phase 2 has finished ═════════════════════════════════════════════════════════════════════════

  describe "quiescent caps after the two phases" do
    test "sequential sends: right after every response the device queue is within its cap (phase 2 ends before the answer)" do
      f = pair!()
      TD.seam(:max_per_device, 5)

      for n <- 1..12 do
        TD.tell!(f.alice, f.bob, "m.dummy", %{"n" => n})
        assert TD.queue_count(f.bob.uid, f.bob.dev) == min(n, 5), "after send #{n}"
      end

      assert ns(TD.sync(f.bob)) == [8, 9, 10, 11, 12]
    end

    test "sender-device share after sequential sends of two senders to one device" do
      f = pair!()
      carol = sender_for!(f.bob)
      TD.seam(:max_per_sender_device, 4)
      for n <- 1..10, do: TD.tell!(f.alice, f.bob, "m.dummy", %{"n" => n})
      for n <- 1..3, do: TD.tell!(carol, f.bob, "m.dummy", %{"n" => 100 + n})
      assert {TD.sent_count(f.alice.uid), TD.sent_count(carol.uid)} == {4, 3}
    end

    test "a burst of overlapping sends of four senders: one more send of each leaves the queue at its cap and every sender within its share" do
      f = pair!()
      senders = for _ <- 1..4, do: sender_for!(f.bob)
      TD.seam(:max_per_device, 5)
      TD.seam(:max_per_sender_device, 2)

      # (one task per sender: four sends in flight at a time, below the 6 node slots)
      tasks = for s <- senders, do: Task.async(fn -> for n <- 1..3, do: TD.put_send(s, "m.dummy", TD.txn(), TD.msg(f.bob, %{"n" => n})).status end)

      assert tasks |> Enum.flat_map(&Task.await(&1, 30_000)) == List.duplicate(200, 12)

      for s <- senders, do: TD.tell!(s, f.bob, "m.dummy", %{"n" => 9})
      assert TD.queue_count(f.bob.uid, f.bob.dev) == 5
      for s <- senders, do: assert(TD.sent_count(s.uid) <= 2)
    end
  end
end
