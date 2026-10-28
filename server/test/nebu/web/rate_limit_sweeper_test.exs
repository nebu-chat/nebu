defmodule Nebu.Web.RateLimitSweeperTest do
  @moduledoc """
  Idle-bucket eviction of the node-local rate-limit ETS table (story oauth-trusted-proxy-client-ip,
  security review cycle 1, finding 2).

  Rows are `{key, tokens, last_ms}`. `sweep_idle/0` removes rows idle for more than one hour (every
  bucket refills completely within one hour, so eviction never grants extra budget); it uses the
  injectable `:rate_limit_clock_fn`. The sweeper GenServer is supervised, stateless and does not own
  the table. `async: false`: shared ETS table and application env.
  """
  use ExUnit.Case, async: false

  alias Nebu.Web.Plugs.RateLimit
  alias Nebu.Web.RateLimitSweeper

  @table :nebu_http_rate_limit_buckets
  @hour 3_600_000

  setup do
    prev = Application.fetch_env(:nebu_http, :rate_limit_clock_fn)
    Application.put_env(:nebu_http, :rate_limit_clock_fn, fn -> 10 * @hour end)
    RateLimit.init_table()
    :ets.delete_all_objects(@table)

    on_exit(fn ->
      case prev do
        {:ok, f} -> Application.put_env(:nebu_http, :rate_limit_clock_fn, f)
        :error -> Application.delete_env(:nebu_http, :rate_limit_clock_fn)
      end

      if :ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table)
    end)

    :ok
  end

  defp keys, do: @table |> :ets.tab2list() |> Enum.map(&elem(&1, 0)) |> Enum.sort()

  test "sweep_idle/0 deletes rows idle for more than one hour and keeps recent ones (all key shapes)" do
    now = 10 * @hour
    :ets.insert(@table, {"198.51.100.1", 3.0, now - @hour - 1})
    :ets.insert(@table, {"2001:db8:1:2::/64", 0.0, now - 5 * @hour})
    :ets.insert(@table, {{"oauth_jwks", "203.0.113.7"}, 1.0, now - @hour - 1})
    :ets.insert(@table, {{"oauth_register", :global}, 1.0, now - 2 * @hour})
    :ets.insert(@table, {"198.51.100.2", 3.0, now - @hour})
    :ets.insert(@table, {{"login", "@alice:test.local"}, 3.0, now - 1000})
    :ets.insert(@table, {"198.51.100.3", 3.0, now})

    assert RateLimit.sweep_idle() == 4
    assert keys() == Enum.sort(["198.51.100.2", "198.51.100.3", {"login", "@alice:test.local"}])
  end

  test "sweep_idle/0 on an empty table is a no-op" do
    assert RateLimit.sweep_idle() == 0
  end

  test "sweep_idle/0 re-creates a vanished table instead of raising" do
    :ets.delete(@table)
    assert RateLimit.sweep_idle() == 0
    assert :ets.whereis(@table) != :undefined
  end

  test "an evicted bucket behaves like a fresh one (full burst again)" do
    Application.put_env(:nebu_http, :rate_limit_clock_fn, fn -> 20 * @hour end)
    assert :ok = RateLimit.take({"t", "x"}, 1, 1)
    assert {:deny, _} = RateLimit.take({"t", "x"}, 1, 1)

    Application.put_env(:nebu_http, :rate_limit_clock_fn, fn -> 22 * @hour end)
    assert RateLimit.sweep_idle() == 1
    assert :ok = RateLimit.take({"t", "x"}, 1, 1)
  end

  test "the registered sweeper process handles :sweep (no timer in test env) and keeps running" do
    pid = Process.whereis(RateLimitSweeper)
    assert is_pid(pid), "RateLimitSweeper must run in the supervision tree"
    :ets.insert(@table, {"198.51.100.1", 3.0, 0})
    send(pid, :sweep)
    :sys.get_state(pid)
    assert keys() == []
    assert Process.alive?(pid)
  end

  test "a timer-driven sweep fires on its interval (own instance, short interval)" do
    {:ok, pid} = RateLimitSweeper.start_link(name: :rate_limit_sweeper_timer_test, interval_ms: 20)
    :ets.insert(@table, {"198.51.100.1", 3.0, 0})
    Process.sleep(120)
    assert keys() == []
    GenServer.stop(pid)
  end

  test "crash/restart: the supervisor restarts the sweeper and the bucket table is intact" do
    :ets.insert(@table, {"198.51.100.9", 3.0, 10 * @hour})
    pid = Process.whereis(RateLimitSweeper)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1_000

    new_pid = wait_for_restart(pid)
    assert is_pid(new_pid) and new_pid != pid
    # the table is not owned by the sweeper: it survived with its rows
    assert keys() == ["198.51.100.9"]
    send(new_pid, :sweep)
    :sys.get_state(new_pid)
    assert keys() == ["198.51.100.9"], "a fresh row survives the sweep"
  end

  defp wait_for_restart(old, tries \\ 50) do
    case Process.whereis(RateLimitSweeper) do
      pid when is_pid(pid) and pid != old -> pid
      _ when tries > 0 -> Process.sleep(20) && wait_for_restart(old, tries - 1)
      _ -> nil
    end
  end

  test "the sweeper is a supervised child of Nebu.Supervisor" do
    assert Enum.any?(Supervisor.which_children(Nebu.Supervisor), fn {id, _pid, _type, _mods} -> id == RateLimitSweeper end)
  end
end
