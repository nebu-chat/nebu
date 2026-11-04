defmodule Nebu.Admin.ConfigSessionLifetimeConcurrencyTest do
  @moduledoc """
  Story `session-lifetime-setting`, CYCLE 1 (code review MINOR 4, Kassandra #2 LOW): the audit row's `before_seconds` and the "no change" decision are derived INSIDE
  the write transaction (the stored value is read under the row lock of the upsert, before it), not from the page read at the start of the request. Two admins saving
  at the same time therefore CHAIN: the second save's `before_seconds` is the first save's `after_seconds`, and a second save of the same value is "no change".

  Real database, the REAL audit writer, no config transaction seam. The interleaving is forced: the audit writer of the FIRST save (A) blocks INSIDE its transaction
  (after its upsert, before its commit) until the test lets it go; the second save (B) is started meanwhile and must wait for A's row lock; the test waits until a
  database backend is waiting for a lock, then releases A. The row exists before the test (an explicit saved value): the INSERT of a first value is a different race
  (no row to lock) and is not pinned here.
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  alias Nebu.Admin.ReauthButtonFlowSupport, as: S
  alias Nebu.OAuth.TestSupport, as: T
  alias Nebu.SessionLifetime.TestSupport, as: L

  @page "/admin/config"
  @post "/admin/config/session-lifetime"
  @field "matrix_session_ttl_seconds"

  defmodule BlockingAudit do
    @moduledoc false
    # the FIRST call announces itself to the test and waits for :go; every later call writes at once. Always the real writer in the end.
    def log(actor, action, type, id, metadata, outcome, detail \\ nil) do
      %{pid: pid, counter: counter} = Application.fetch_env!(:nebu_http, :lifetime_blocking_audit)
      first? = :counters.get(counter, 1) == 0
      :counters.add(counter, 1, 1)

      if first? do
        send(pid, {:audit_blocked, self()})

        receive do
          :go -> :ok
        after
          20_000 -> :ok
        end
      end

      Nebu.Compliance.AuditWriter.log(actor, action, type, id, metadata, outcome, detail)
    end
  end

  setup do
    T.clear_oauth_config()
    T.put_env_scoped(:admin_csrf_bypass, true)
    L.clear_env_ttl!()
    L.delete_row!()
    L.clear_audit_rows!()
    L.real_seams!()
    L.set_row!("28800")
    T.put_env_scoped(:lifetime_blocking_audit, %{pid: self(), counter: :counters.new(1, [])})
    T.put_env_scoped(:audit_writer, BlockingAudit, :compliance)

    on_exit(fn -> L.clear_audit_rows!() end)
    :ok
  end

  defp save_async(value), do: Task.async(fn -> S.post(@post, %{@field => value}, @page, ago: 10) end)

  # waits until a backend waits for a lock (B queued behind A), at most 10 seconds
  defp await_lock_waiter! do
    Enum.reduce_while(1..200, false, fn _, _ ->
      %{rows: [[n]]} = T.privileged_sql!("SELECT count(*) FROM pg_locks WHERE NOT granted", [])

      if n > 0 do
        {:halt, true}
      else
        Process.sleep(50)
        {:cont, false}
      end
    end)
    |> then(&assert(&1, "the second save did not wait for the row lock of the first one"))
  end

  # A: 28800 -> a_value (blocked in its audit); B: starts meanwhile; then A is released. Returns both responses.
  defp race(a_value, b_value) do
    a = save_async(a_value)
    assert_receive {:audit_blocked, a_pid}, 10_000
    b = save_async(b_value)
    await_lock_waiter!()
    send(a_pid, :go)
    {Task.await(a, 30_000), Task.await(b, 30_000)}
  end

  test "two concurrent saves chain: the audit row of the second has the first one's after_seconds as before_seconds" do
    {a, b} = race("7200", "10800")
    assert a.status in [302, 303]
    assert b.status in [302, 303]

    assert L.row_value() == "10800"
    rows = L.audit_rows()
    assert Enum.map(rows, & &1["metadata"]) == [%{"before_seconds" => 28_800, "after_seconds" => 7200}, %{"before_seconds" => 7200, "after_seconds" => 10_800}]
  end

  test "a concurrent save of the SAME value is 'no change' when it commits: one audit row, one write" do
    {a, b} = race("7200", "7200")
    assert a.status in [302, 303]
    assert b.status in [302, 303]

    assert L.row_value() == "7200"
    assert [row] = L.audit_rows()
    assert row["metadata"] == %{"before_seconds" => 28_800, "after_seconds" => 7200}
  end
end
