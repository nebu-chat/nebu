defmodule Nebu.Matrix.ToDeviceLoggingTest do
  @moduledoc """
  Acceptance tests (REAL database) of the "No Sensitive Data in Logs" law for story `to-device-messaging` (epic e2ee-client-support, REQ-2026-012): the content of a to-device message
  (Olm ciphertext, forwarded room keys, secrets: `m.secret.send`) and the client-chosen event type and txn id must never reach a log line, at ANY level, on ANY path:

    * every happy path (send, `*`, retry, sync delivery, acknowledgement, long poll) with CANARY strings in the content, the event type and the txn id, under a `:debug` Logger
      (the request line is present, so the check is not vacuous; the `RequestLogger` captures no body of `sendToDevice` and the `RouteNormalizer` replaces the type and txn id);
    * every refused path (400, 401 with a body, 413, 429, an invalid event type that carries the canary);
    * failing database statements whose database message QUOTES the row (a trigger raising `'quoted row: %'`): the answer is generic (500 on a send, a 5xx on a sync), neither the answer nor the
      log carries the canary or the database message, and nothing is half done: a failed send stores neither messages nor its txn record (the retry with the same txn id is delivered), a failed
      delivery or acknowledgement loses nothing (the retry with the same token delivers);
    * the purge worker logs counts only, an eviction logs its count only (`to_device_limits_http_test.exs`).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Nebu.Matrix.ToDeviceTestSupport, as: TD
  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration

  setup do
    T.reset_rate_limits()
    Nebu.Test.ServerName.pin!(T.server_name())
    TD.disable_rate_limit()
    on_exit(fn -> T.restore_rate_limits() end)
    alice = TD.user!("TDA")
    bob1 = TD.user!("TDB")
    bob2 = TD.device!(bob1, "TDC")
    TD.share!(alice, bob1)
    {:ok, alice: alice, bob1: bob1, bob2: bob2, canary: "CANARY-" <> T.rand(8)}
  end

  defp logged(fun), do: TD.with_log_level(:debug, fn -> capture_log([level: :debug], fun) end)

  # a fault whose database message QUOTES the row (what Postgres does for constraint details and what a trigger can do)
  defp quoting_fault!(table, event) do
    name = "atdd_td_fault_" <> T.rand(5)
    row = if event == "DELETE", do: "OLD", else: "NEW"

    T.privileged_sql!(
      "CREATE FUNCTION #{name}() RETURNS trigger AS $$ BEGIN RAISE EXCEPTION 'quoted row: %', row_to_json(#{row})::text; END $$ LANGUAGE plpgsql"
    )

    T.privileged_sql!("CREATE TRIGGER #{name} BEFORE #{event} ON #{table} FOR EACH ROW EXECUTE FUNCTION #{name}()")

    remove = fn ->
      T.privileged_sql!("DROP TRIGGER IF EXISTS #{name} ON #{table}")
      T.privileged_sql!("DROP FUNCTION IF EXISTS #{name}()")
    end

    ExUnit.Callbacks.on_exit(remove)
    remove
  end

  describe "no content, event type or txn id is ever logged" do
    test "send (specific device, `*`, own device, retry) and sync (delivery, redelivery, acknowledgement, long poll) with canaries at :debug", %{alice: a, bob1: b1, bob2: b2, canary: c} do
      # the event TYPE is not content (sync responses log the types of room events too), so the delivered messages carry a plain one; the canary type is sent but not synced
      type = "m.room_key_request"
      content = %{"ciphertext" => "ct-#{c}", "secret" => c, "nested" => %{"k" => "v-#{c}"}}
      txn = "txn-#{c}"

      log =
        logged(fn ->
          since = TD.next(TD.sync(b1))
          TD.send!(a, type, txn, TD.msg(b1, content))
          TD.send!(a, type, txn, TD.msg(b1, content))
          TD.send!(a, type, "star-#{c}", TD.star(b1, content))
          TD.send!(a, "m.dummy", "own-#{c}", TD.msg({a.uid, a.dev}, content))
          first = TD.sync(b1, since)
          assert length(TD.events(first)) == 2
          again = TD.sync(b1, since)
          assert length(TD.events(again)) == 2
          assert TD.events(TD.sync(b1, TD.next(again))) == []
          poll = Task.async(fn -> TD.sync(b2, nil, timeout: 300) end)
          assert length(TD.events(Task.await(poll, 10_000))) == 1
          # a canary TYPE is refused by the allowlist (400): the refused type is not logged either
          assert TD.put_send(a, "org.example.#{c}", "typed-#{c}", TD.msg(b2, content)).status == 400
        end)

      assert log =~ "sendToDevice", "precondition: the request logger ran for the route"
      refute log =~ c, "content, type (path) or txn id reached a log line: " <> (Regex.scan(~r/.{0,80}#{c}.{0,40}/, log) |> Enum.map(&hd/1) |> Enum.join("\n"))
      refute log =~ ~r/INSERT INTO to_device|DELETE FROM to_device|UPDATE to_device/i, "no SQL with bound parameters is logged"
    end

    test "refused requests (400, 401 with a body, 413, an invalid event type carrying the canary, a 429) log nothing of the content", %{alice: a, bob1: b1, canary: c} do
      TD.enable_rate_limit()

      log =
        logged(fn ->
          big = ~s({"messages":{"#{b1.uid}":{"#{b1.dev}":{"c":"#{c}","pad":"#{String.duplicate("a", 70_000)}"}}}})
          assert TD.put_send(a, "m.dummy", "t413-#{c}", {:raw, big}).status == 413
          assert TD.put_send(a, "m.dummy", "t400-#{c}", {:raw, ~s({"messages":{"#{b1.uid}":{"#{b1.dev}":"#{c}"}}})}).status == 400
          assert TD.put_send(a, "m.dummy", "tnj-#{c}", {:raw, ~s({"messages": {"c": "#{c}"} oops)}).status == 400
          assert TD.put_send(a, "bad type #{c}", "t-bad", TD.msg(b1, %{"c" => c})).status == 400
          assert TD.req(:put, TD.send_path("m.dummy", "tjunk-#{c}"), "junk-token-#{c}", %{"messages" => %{"x" => %{"y" => %{"c" => c}}}}).status == 401
          assert TD.req(:put, TD.send_path("org.#{c}", "tanon-#{c}"), nil, %{"messages" => %{"x" => %{"y" => %{"c" => c}}}}).status == 401
          for i <- 1..30, do: TD.put_send(a, "m.dummy", "tflood-#{i}-#{c}", %{})
          assert TD.put_send(a, "m.dummy", "t429-#{c}", TD.msg(b1, %{"c" => c})).status == 429
        end)

      assert log =~ "sendToDevice", "precondition: the request logger ran"
      refute log =~ c
    end

    test "the purge worker and the txn / TTL paths log counts only: expired rows with canaries are purged without a trace of them", %{alice: a, bob1: b1, canary: c} do
      TD.send!(a, "m.dummy", "t-#{c}", TD.msg(b1, %{"c" => c}))
      assert TD.put_send(a, "org.#{c}", "t-#{c}", TD.msg(b1, %{"c" => c})).status == 400
      TD.age_queue!(b1.uid, b1.dev, 8 * 86_400)
      TD.age_txns!(a.uid, a.dev, 25 * 3600)

      log = logged(fn -> assert :ok = apply(Nebu.Workers.ToDevicePurgeWorker, :perform, [%Oban.Job{}]) end)
      refute log =~ c
      refute log =~ b1.uid, "no user id in the purge log (counts only)"
      assert TD.queue_count(b1.uid, b1.dev) == 0
    end
  end

  describe "a failing database write: generic answer, no row data, nothing half done" do
    test "a failing queue INSERT (message quotes the row): generic 500, no queue row, NO txn record, the retry is delivered", %{alice: a, bob1: b1, canary: c} do
      remove = quoting_fault!("to_device_messages", "INSERT")
      t = "tf-#{c}"

      log = logged(fn -> send(self(), {:resp, TD.put_send(a, "m.dummy", t, TD.msg(b1, %{"ciphertext" => "INS-#{c}"}))}) end)

      assert_received {:resp, resp}
      assert resp.status == 500, "got #{resp.status} #{resp.resp_body}"
      assert TD.json(resp)["errcode"] == "M_UNKNOWN"
      refute resp.resp_body =~ c
      refute resp.resp_body =~ "quoted row"
      refute log =~ c
      refute log =~ "quoted row", "the failure is logged by its kind only, never the database message"
      assert TD.queue_count(b1.uid) == 0
      assert TD.txn_count(a.uid, a.dev) == 0, "the transaction record is part of the same transaction: a failed send burns no txn id"

      remove.()
      TD.send!(a, "m.dummy", t, TD.msg(b1, %{"ciphertext" => "INS-#{c}"}))
      assert [%{"content" => %{"ciphertext" => _}}] = TD.events(TD.sync(b1))
    end

    test "a failing INSERT of the txn record: 500, nothing queued, no canary / database message in answer or log", %{alice: a, bob1: b1, canary: c} do
      remove = quoting_fault!("to_device_txns", "INSERT")

      log = logged(fn -> send(self(), {:resp, TD.put_send(a, "m.dummy", "tx-#{c}", TD.msg(b1, %{"ciphertext" => "TXN-#{c}"}))}) end)

      assert_received {:resp, resp}
      assert resp.status == 500 and TD.json(resp)["errcode"] == "M_UNKNOWN", "got #{resp.status} #{resp.resp_body}"
      refute resp.resp_body =~ c
      refute resp.resp_body =~ "quoted row"
      refute log =~ c
      refute log =~ "quoted row"
      assert TD.queue_count(b1.uid) == 0
      remove.()
    end

    test "a failing delivery (stamping UPDATE quotes the row): the sync is 200 with an EMPTY to_device, nothing lost, the retry delivers", %{alice: a, bob1: b1, canary: c} do
      t0 = TD.next(TD.sync(b1))
      TD.tell!(a, b1, "m.dummy", %{"ciphertext" => "DEL-#{c}"})
      remove = quoting_fault!("to_device_messages", "UPDATE")

      log = logged(fn -> send(self(), {:resp, TD.sync_conn(b1, since: t0, timeout: 0)}) end)

      assert_received {:resp, resp}
      assert resp.status == 200, "got #{resp.status} #{String.slice(resp.resp_body, 0, 200)}"
      assert TD.json(resp)["to_device"] == %{"events" => []}
      refute resp.resp_body =~ c
      refute resp.resp_body =~ "quoted row"
      refute log =~ c
      refute log =~ "quoted row"
      assert log =~ "to-device", "the failure is logged (kind only)"
      assert TD.queue_count(b1.uid, b1.dev) == 1

      remove.()
      assert [%{"content" => %{"ciphertext" => "DEL-" <> _}}] = TD.events(TD.sync(b1, t0)), "the retry with the same since delivers"
    end

    test "a failing acknowledgement (DELETE quotes the row): 200 with an EMPTY to_device, the delivered message is NOT lost", %{alice: a, bob1: b1, canary: c} do
      TD.tell!(a, b1, "m.dummy", %{"ciphertext" => "ACK-#{c}"})
      first = TD.sync(b1)
      assert length(TD.events(first)) == 1
      remove = quoting_fault!("to_device_messages", "DELETE")

      log = logged(fn -> send(self(), {:resp, TD.sync_conn(b1, since: TD.next(first), timeout: 0)}) end)

      assert_received {:resp, resp}
      assert resp.status == 200, "got #{resp.status} #{String.slice(resp.resp_body, 0, 200)}"
      assert TD.json(resp)["to_device"] == %{"events" => []}
      refute resp.resp_body =~ c
      refute log =~ c
      refute log =~ "quoted row"
      assert TD.queue_count(b1.uid, b1.dev) == 1

      remove.()
      assert TD.events(TD.sync(b1, TD.next(first))) == [], "the covering token acknowledges once the database works again"
      assert TD.queue_count(b1.uid, b1.dev) == 0
    end
  end
end
