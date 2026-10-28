defmodule Nebu.Matrix.MemberSliceGateTest do
  @moduledoc """
  Story `membership-state-model`, security cycle 2 (D19): the node-wide limit of concurrent member-state reads, unit level (no database):
  the default and the application key, the env variable `NEBU_MEMBER_SLICE_MAX_CONCURRENCY` through the real `config/runtime.exs` (in the
  style of `rate_limit_tiers_test.exs`), the value-free boot warning, and the gate itself (a full gate refuses, a released or killed
  reader frees its slot). The HTTP behaviour (503 / a degraded room) is pinned by `membership_state_http_test.exs`. Security cycle 3 (Kassandra
  M-3): the supervised GenServer gate: exact admission of simultaneous readers, the FIFO queue (bounded 4 x the limit) with the caller's
  deadline, a killed holder frees its slot at once, and a throughput sanity check.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Nebu.Matrix.MemberSliceGate, as: Gate

  @runtime Path.expand("../../../config/runtime.exs", __DIR__)
  @env "NEBU_MEMBER_SLICE_MAX_CONCURRENCY"
  @key :member_slice_max_concurrency
  # runtime.exs in :dev needs these two (it raises without them); the values are throwaway and only live during the read
  @required_env %{"NEBU_DB_URL" => "postgresql://u:p@localhost:5432/gate", "NEBU_PII_ENCRYPTION_KEY" => String.duplicate("ab", 32)}

  setup do
    prior = Application.fetch_env(:nebu, @key)
    env_snapshot = for {name, value} <- System.get_env(), String.starts_with?(name, "NEBU_"), do: {name, value}
    Application.delete_env(:nebu, @key)

    on_exit(fn ->
      case prior do
        {:ok, value} -> Application.put_env(:nebu, @key, value)
        :error -> Application.delete_env(:nebu, @key)
      end

      for {name, _} <- System.get_env(), String.starts_with?(name, "NEBU_"), do: System.delete_env(name)
      for {name, value} <- env_snapshot, do: System.put_env(name, value)
    end)

    :ok
  end

  defp runtime_value(value) do
    for {name, _} <- System.get_env(), String.starts_with?(name, "NEBU_"), do: System.delete_env(name)
    for {name, v} <- Map.put(@required_env, @env, value), do: System.put_env(name, v)
    @runtime |> Config.Reader.read!(env: :dev, target: :host) |> Keyword.get(:nebu, []) |> Keyword.get(@key, :unset)
  end

  test "the default limit is 3; a strictly positive integer of the application key applies, anything else falls back to 3" do
    assert Gate.max_concurrency() == 3

    Application.put_env(:nebu, @key, 7)
    assert Gate.max_concurrency() == 7

    for junk <- [0, -1, 1.5, "4", nil, :on] do
      Application.put_env(:nebu, @key, junk)
      assert Gate.max_concurrency() == 3, "junk #{inspect(junk)}"
    end
  end

  test "config/runtime.exs: NEBU_MEMBER_SLICE_MAX_CONCURRENCY lands under :nebu, :member_slice_max_concurrency; junk and empty set nothing" do
    assert runtime_value("5") == 5

    for junk <- ["0", "-2", "abc", "", "1.5", "9223372036854775808"], do: assert(runtime_value(junk) == :unset, "junk #{inspect(junk)}")
  end

  test "the boot warning names the variable (never the value) for an invalid setting, and says nothing for a valid or an unset one" do
    System.put_env(@env, "lots-xyz")
    log = capture_log([level: :warning], fn -> assert :ok = Gate.warn_invalid_setting() end)
    assert log =~ @env
    refute log =~ "lots-xyz"

    for ok <- ["4", ""] do
      System.put_env(@env, ok)
      assert capture_log([level: :warning], fn -> Gate.warn_invalid_setting() end) == ""
    end

    System.delete_env(@env)
    assert capture_log([level: :warning], fn -> Gate.warn_invalid_setting() end) == ""
  end

  test "the gate: a full gate refuses (the function is not run), a finished reader frees its slot, a killed reader's slot is reclaimed" do
    Application.put_env(:nebu, @key, 1)
    parent = self()

    holder =
      spawn(fn ->
        Gate.run(fn ->
          send(parent, :holding)

          receive do
            :release -> :ok
          end
        end)

        send(parent, :released)
      end)

    assert_receive :holding, 2_000
    assert Gate.run(fn -> flunk("must not run while the gate is full") end) == :overflow

    send(holder, :release)
    assert_receive :released, 2_000
    assert Gate.run(fn -> :ran end) == {:ok, :ran}, "the slot is free after the reader finished"

    killed =
      spawn(fn ->
        Gate.run(fn ->
          send(parent, :holding)
          Process.sleep(:infinity)
        end)
      end)
    assert_receive :holding, 2_000
    ref = Process.monitor(killed)
    Process.exit(killed, :kill)
    assert_receive {:DOWN, ^ref, :process, _, :killed}, 2_000

    assert Gate.run(fn -> :ran end) == {:ok, :ran}, "the killed reader's slot is reclaimed"

    assert_raise RuntimeError, fn -> Gate.run(fn -> raise "boom" end) end
    assert Gate.run(fn -> :ran end) == {:ok, :ran}, "a raising reader frees its slot (the after)"
  end

  # ─── security cycle 3 (M-3): the GenServer gate ───────────────────────────────────────────────────────────────────

  # `n` readers that hold a slot until they get :release; returns their pids once all of them hold
  defp hold!(n) do
    parent = self()

    pids =
      for _ <- 1..n//1 do
        spawn(fn ->
          Gate.run(fn ->
            send(parent, {:holding, self()})

            receive do
              :release -> :ok
            end
          end)
        end)
      end

    for pid <- pids, do: assert_receive({:holding, ^pid}, 2_000)
    pids
  end

  defp hold_briefly(ms) do
    Process.sleep(ms)
    :ran
  end

  # a reader in its own process: reports {:result, tag, result, elapsed_ms}
  defp reader(tag, wait_ms, fun \\ fn -> :ran end) do
    parent = self()

    spawn(fn ->
      started = System.monotonic_time(:millisecond)
      result = Gate.run(fun, wait_ms)
      send(parent, {:result, tag, result, System.monotonic_time(:millisecond) - started})
    end)
  end

  test "N + k simultaneous readers on an idle gate at the limit 3: exactly 3 run at once, the others overflow at once with wait 0" do
    tasks = for _ <- 1..10, do: Task.async(fn -> Gate.run(fn -> hold_briefly(200) end, 0) end)
    results = Enum.map(tasks, &Task.await(&1, 5_000))

    assert Enum.count(results, &(&1 == {:ok, :ran})) == 3
    assert Enum.count(results, &(&1 == :overflow)) == 7
  end

  test "simultaneous readers that wait are served in FIFO order within the deadline, never more than the limit at a time" do
    Application.put_env(:nebu, @key, 2)
    holders = hold!(2)
    current = :atomics.new(2, [])
    parent = self()

    fun = fn i ->
      fn ->
        now = :atomics.add_get(current, 1, 1)
        :atomics.put(current, 2, max(now, :atomics.get(current, 2)))
        send(parent, {:order, i})
        Process.sleep(20)
        :atomics.sub(current, 1, 1)
        :ran
      end
    end

    for i <- 1..6 do
      reader(i, 5_000, fun.(i))
      # the queue order is the arrival order at the gate
      Process.sleep(5)
    end

    for pid <- holders, do: send(pid, :release)

    for i <- 1..6, do: assert_receive({:result, ^i, {:ok, :ran}, _}, 5_000)
    order = for _ <- 1..6, do: (receive do {:order, i} -> i end)
    assert order == Enum.to_list(1..6), "FIFO: #{inspect(order)}"
    assert :atomics.get(current, 2) <= 2, "never more than the limit at a time"
  end

  test "a wait-0 probe succeeds whenever a slot is free, also right after a crowd of waiters was served; it overflows only while every slot is held" do
    holders = hold!(2)
    assert Gate.run(fn -> :probe end, 0) == {:ok, :probe}, "2 of 3 slots held: the probe runs"

    [third] = hold!(1)
    short_read = fn ->
      Process.sleep(5)
      :ran
    end

    for i <- 1..10, do: reader(i, 5_000, short_read)
    Process.sleep(50)
    assert Gate.run(fn -> :probe end, 0) == :overflow, "every slot held"

    for pid <- [third | holders], do: send(pid, :release)
    results = for _ <- 1..10, do: (receive do {:result, _i, result, _} -> result after 5_000 -> :missing end)
    assert Enum.count(results, &(&1 == {:ok, :ran})) == 10
    assert Gate.run(fn -> :probe end, 0) == {:ok, :probe}, "the crowd is gone: the probe runs at once"
  end

  test "the waiter queue is bounded (4 x the limit): beyond it a reader is refused at once, also with a long wait" do
    Application.put_env(:nebu, @key, 1)
    [holder] = hold!(1)

    for i <- 1..4, do: reader(i, 10_000)
    Process.sleep(50)
    reader(:fifth, 10_000)

    assert_receive {:result, :fifth, :overflow, elapsed}, 2_000
    assert elapsed < 500, "refused at once (#{elapsed} ms)"

    send(holder, :release)
    for i <- 1..4, do: assert_receive({:result, ^i, {:ok, :ran}, _}, 5_000)
  end

  test "a wait that succeeds (a slot freed after 100 ms) and a wait that times out after about wait_ms" do
    Application.put_env(:nebu, @key, 1)
    [holder] = hold!(1)

    reader(:short, 200)
    assert_receive {:result, :short, :overflow, elapsed}, 2_000
    assert elapsed >= 180 and elapsed < 1_000, "timed out after about 200 ms (#{elapsed} ms)"

    reader(:long, 2_000)
    Process.sleep(100)
    send(holder, :release)
    assert_receive {:result, :long, {:ok, :ran}, elapsed}, 2_000
    assert elapsed >= 90 and elapsed < 1_000, "admitted when the slot was freed (#{elapsed} ms)"
  end

  test "a killed holder frees its slot at once: a waiting reader is admitted right after the kill" do
    Application.put_env(:nebu, @key, 1)
    [holder] = hold!(1)
    reader(:waiting, 5_000)
    Process.sleep(50)

    killed_at = System.monotonic_time(:millisecond)
    Process.exit(holder, :kill)

    assert_receive {:result, :waiting, {:ok, :ran}, _}, 2_000
    assert System.monotonic_time(:millisecond) - killed_at < 500
  end

  test "throughput sanity: 500 readers (5 ms reads, retrying for 1 s) complete at least 60 % of the ideal number of reads of 3 slots (80 % when idle)" do
    # the ideal: 3 slots x 1000 ms / the measured duration of one 5 ms read on this machine (Process.sleep has a 1 ms granularity)
    {micros, _} = :timer.tc(fn -> for _ <- 1..20, do: Process.sleep(5) end)
    ideal = div(3 * 1_000 * 20 * 1_000, micros)
    deadline = System.monotonic_time(:millisecond) + 1_000
    done = :counters.new(1, [])

    worker = fn worker ->
      if System.monotonic_time(:millisecond) < deadline do
        case Gate.run(fn -> Process.sleep(5) end, 200) do
          {:ok, _} -> :counters.add(done, 1, 1)
          # a refused reader comes back a little later (a client retry), it does not spin on the gate
          :overflow -> Process.sleep(10)
        end

        worker.(worker)
      end
    end

    1..500 |> Enum.map(fn _ -> Task.async(fn -> worker.(worker) end) end) |> Enum.each(&Task.await(&1, 10_000))

    completed = :counters.get(done, 1)
    IO.puts(:stderr, "[member_slice_gate_test] throughput: #{completed} reads in 1 s, ideal #{ideal}")
    # 80 % on an idle machine (measured 402-498 of an ideal of 407-440); the bar is 60 % so that a CI host under load (another job on
    # the same CPUs) does not fail a sanity check: the polling gate this replaced reached about 50 % with an idle CPU
    assert completed >= div(ideal * 6, 10), "completed #{completed} reads in 1 s, ideal #{ideal}"
  end

  @tag timeout: 60_000
  test "a grant that arrives after the caller's call timed out (a suspended gate) is cancelled: no slot stays held by the still-living caller" do
    Application.put_env(:nebu, @key, 1)
    gate = Process.whereis(Gate)
    parent = self()
    :ok = :sys.suspend(gate)

    caller =
      spawn(fn ->
        # wait 0: the call gives up after the 5 s margin, the gate later grants (it is resumed) and then processes the cancel
        send(parent, {:caller_result, Gate.run(fn -> :ran end, 0)})

        receive do
          :stop -> :ok
        end
      end)

    try do
      assert_receive {:caller_result, :overflow}, 15_000
    after
      :ok = :sys.resume(gate)
    end

    assert Process.alive?(caller), "the caller lives on (a keep-alive connection process)"
    assert Gate.run(fn -> :ran end, 0) == {:ok, :ran}, "no slot is held by the caller: a new reader is admitted at the limit 1"
    send(caller, :stop)
  end

  test "an unexpected message to the gate is ignored (the gate keeps serving)" do
    send(Process.whereis(Gate), :unexpected)
    assert Gate.run(fn -> :ran end, 0) == {:ok, :ran}
  end
end
