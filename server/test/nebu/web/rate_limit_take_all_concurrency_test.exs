defmodule Nebu.Web.RateLimitTakeAllConcurrencyTest do
  @moduledoc """
  Story `rate-limits-join-invite-create-room`, review cycle 1 (code review MINOR-1): the limiter takes tokens with a compare-and-swap,
  so concurrent requests of ONE key on one node can never take more than the bucket holds. Before, `take/3`, the plug and `take_all/1`
  read the row and wrote it back (lookup + insert): a burst of simultaneous requests all saw the full bucket (measured: up to about
  twice the burst once per bucket fill).

  Frozen clock (no refill), N pre-spawned processes released together by one message, repeated for several rounds; no `Process.sleep`.
  """
  use ExUnit.Case, async: false

  alias Nebu.Web.Plugs.RateLimit

  @table :nebu_http_rate_limit_buckets
  @env_keys [:rate_limit_disabled, :rate_limit_clock_fn]
  @procs 80
  @rounds 15

  setup do
    if :ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table)
    snapshot = for key <- @env_keys, do: {key, Application.fetch_env(:nebu_http, key)}
    Application.delete_env(:nebu_http, :rate_limit_disabled)
    Application.put_env(:nebu_http, :rate_limit_clock_fn, fn -> 1_000_000 end)
    assert System.get_env("NEBU_RATE_LIMIT_DISABLED") != "true"

    on_exit(fn ->
      for {key, previous} <- snapshot do
        case previous do
          {:ok, value} -> Application.put_env(:nebu_http, key, value)
          :error -> Application.delete_env(:nebu_http, key)
        end
      end

      if :ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table)
    end)

    :ok
  end

  # `n` processes that all wait for one message and then run `fun.(index)`; returns their results
  defp race(n, fun) do
    parent = self()

    pids =
      for i <- 1..n do
        spawn_link(fn ->
          receive do
            :go -> send(parent, {:result, self(), fun.(i)})
          end
        end)
      end

    for pid <- pids, do: send(pid, :go)
    for pid <- pids, do: (receive do {:result, ^pid, result} -> result end)
  end

  defp key(label), do: {:atdd_concurrency, label, System.unique_integer([:positive])}

  defp tokens(key) do
    case :ets.lookup(@table, key) do
      [{^key, tokens, _}] -> tokens
      [] -> nil
    end
  end

  test "take_all, one bucket: of #{@procs} simultaneous requests exactly the burst (20) pass, in every one of #{@rounds} rounds (fresh bucket each round)" do
    RateLimit.init_table()

    for round <- 1..@rounds do
      k = key("single-#{round}")
      results = race(@procs, fn _ -> RateLimit.take_all([{k, 1, 60, 20}]) end)

      assert Enum.count(results, &(&1 == :ok)) == 20, "round #{round}: #{Enum.count(results, &(&1 == :ok))} passed, the bucket holds 20"
      assert Enum.all?(results, &(&1 == :ok or match?({:deny, s} when s >= 1, &1)))
      assert_in_delta tokens(k), 0.0, 1.0e-9
    end
  end

  test "take/3 and the plug share the guarantee (the same compare-and-swap)" do
    RateLimit.init_table()

    for round <- 1..@rounds do
      k = key("take-#{round}")
      results = race(@procs, fn _ -> RateLimit.take(k, 60, 20) end)
      assert Enum.count(results, &(&1 == :ok)) == 20, "take/3 round #{round}"
    end

    tier = "atdd-conc-" <> Integer.to_string(System.unique_integer([:positive]))
    user = "@conc#{System.unique_integer([:positive])}:test.local"
    opts = RateLimit.init(rate_per_min: 60, burst: 20, tier: tier, key: :user)

    results =
      race(@procs, fn _ ->
        conn = %{Plug.Test.conn(:post, "/x") | remote_ip: {10, 9, 8, 7}} |> Plug.Conn.assign(:current_user, user) |> RateLimit.call(opts)
        conn.halted
      end)

    assert Enum.count(results, &(&1 == false)) == 20, "the plug lets exactly the burst through"
  end

  test "take_all, two buckets (createRoom shape: 1 create + n invite units): every admitted request is paid in BOTH buckets, never more than either holds" do
    RateLimit.init_table()

    for round <- 1..@rounds do
      create = key("create-#{round}")
      invite = key("invite-#{round}")
      # burst 20 creates, 50 invite units, 5 units per request: the invite bucket admits 10, the create bucket 20
      results = race(@procs, fn _ -> RateLimit.take_all([{create, 1, 60, 20}, {invite, 5, 60, 50}]) end)

      assert Enum.count(results, &(&1 == :ok)) == 10, "round #{round}: the invite bucket (50 / 5) decides"
      assert_in_delta tokens(invite), 0.0, 1.0e-9
      assert_in_delta tokens(create), 10.0, 1.0e-9, "round #{round}: the create bucket paid for the 10 admitted requests only (the refunds of the refused ones are complete)"
    end
  end

  test "take_all, a bucket that can never pay: every request is refused and the other bucket is refunded in full (no token is lost to the refunds)" do
    RateLimit.init_table()
    first = key("refund-first")
    empty = key("refund-empty")
    assert :ok = RateLimit.take_all([{empty, 1, 6, 1}])

    for _ <- 1..@rounds do
      results = race(@procs, fn _ -> RateLimit.take_all([{first, 1, 60, 20}, {empty, 1, 6, 1}]) end)
      assert Enum.all?(results, &match?({:deny, 10}, &1)), "the empty bucket needs 10 s: #{inspect(Enum.uniq(results))}"
    end

    assert_in_delta tokens(first) || 20.0, 20.0, 1.0e-9, "every charge of the first bucket was refunded"
    assert :ok = RateLimit.take_all([{first, 20, 60, 20}]), "all 20 tokens are still there"
  end
end
