defmodule Nebu.Web.RateLimitTakeAllTest do
  @moduledoc """
  Story `rate-limits-join-invite-create-room` (epic oauth-broker, follow-up `ey`), AC1 (unit, no DB): the new public
  `Nebu.Web.Plugs.RateLimit.take_all/1` (D3).

      take_all([{key, cost, rate_per_min, burst}, ...]) :: :ok | {:deny, retry_after_s}

  ALL-OR-NOTHING over one or two buckets of the SAME ETS table (`:nebu_http_rate_limit_buckets`, rows `{key, tokens, last_ms}`):
  every listed bucket is refilled (`elapsed_ms * rate_per_min / 60_000`, capped at `burst`), and `cost` tokens are consumed from each
  ONLY if EVERY bucket holds at least its cost. Otherwise nothing is consumed (the refilled values are stored) and the answer is
  `{:deny, s}` with `s` the LARGEST wait over the buckets that cannot pay (`ceil((cost - tokens) / rate_per_ms / 1000)`, at least 1).
  A `cost` above `burst` is charged as `burst`. Same clock seam (`:nebu_http, :rate_limit_clock_fn`) and the same disable switch as
  `take/3` and the plug.

  How the pins are read (names the story leaves open, pinned HERE):

    * the buckets are read back through the ETS rows themselves (`{key, tokens, last_ms}` is the documented row shape of the plug and
      of `Nebu.Web.RateLimitSweeper`), the clock is an Agent behind `:rate_limit_clock_fn`: no `Process.sleep` anywhere.
    * `take_all/1` is reached through `apply/3` with a variable function name, so this file compiles (no undefined-function warning
      that `--warnings-as-errors` turns into an abort) while the function does not exist yet.
    * (g) is pinned against the REAL plug (`key: :user`, `{tier, user}` keys): a token taken by one is missing for the other.
  """
  use ExUnit.Case, async: false

  import Plug.Test

  alias Nebu.Web.Plugs.RateLimit

  @table :nebu_http_rate_limit_buckets
  @env_keys [:rate_limit_disabled, :rate_limit_clock_fn]

  setup do
    if :ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table)

    snapshot = for key <- @env_keys, do: {key, Application.fetch_env(:nebu_http, key)}
    Application.delete_env(:nebu_http, :rate_limit_disabled)

    assert System.get_env("NEBU_RATE_LIMIT_DISABLED") != "true",
           "this suite requires the limiter ENABLED: NEBU_RATE_LIMIT_DISABLED must not be \"true\" in the test harness"

    {:ok, clock} = Agent.start_link(fn -> 1_000_000 end)
    Application.put_env(:nebu_http, :rate_limit_clock_fn, fn -> Agent.get(clock, & &1) end)

    on_exit(fn ->
      for {key, previous} <- snapshot do
        case previous do
          {:ok, value} -> Application.put_env(:nebu_http, key, value)
          :error -> Application.delete_env(:nebu_http, key)
        end
      end

      if Process.alive?(clock), do: Agent.stop(clock)
      if :ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table)
    end)

    {:ok, clock: clock}
  end

  # ─── helpers ─────────────────────────────────────────────────────────────────

  defp take_all(buckets), do: apply(RateLimit, fn_name(), [buckets])
  defp fn_name, do: String.to_atom("take_all")

  defp key(label), do: {:atdd_take_all, label, System.unique_integer([:positive])}
  defp advance(clock, ms), do: Agent.update(clock, &(&1 + ms))

  # the stored token count of a bucket (nil = no row)
  defp tokens(key) do
    case :ets.lookup(@table, key) do
      [{^key, tokens, _last}] -> tokens
      [] -> nil
    end
  end

  # 60 / min = one token per second, 6 / min = one token per ten seconds
  @per_second 60
  @per_ten_seconds 6

  # ═══ (a) one bucket, cost 1: the same results as take/3 ══════════════════════════

  describe "AC1 (a) - one bucket, cost 1" do
    test "gives the same results as take/3 for the same sequence: the burst passes, the next is denied with the same retry_after_s >= 1" do
      via_take = key("take")
      via_all = key("all")

      expected = for _ <- 1..4, do: RateLimit.take(via_take, 30, 3)
      actual = for _ <- 1..4, do: take_all([{via_all, 1, 30, 3}])

      assert actual == expected
      assert [:ok, :ok, :ok, {:deny, seconds}] = actual
      assert is_integer(seconds) and seconds >= 1
    end

    test "a denied request consumes nothing: the denial leaves the refilled value in the bucket" do
      k = key("denied")
      assert :ok = take_all([{k, 1, 30, 1}])
      assert {:deny, _} = take_all([{k, 1, 30, 1}])
      assert {:deny, _} = take_all([{k, 1, 30, 1}])
      assert_in_delta tokens(k), 0.0, 1.0e-9
    end
  end

  # ═══ (b) cost n ══════════════════════════════════════════════════════════════════

  describe "AC1 (b) - cost n" do
    test "a bucket holding n - 1 tokens denies and keeps its tokens: a following cost-1 take succeeds", %{clock: _clock} do
      k = key("cost")
      # burst 5: two takes of 2 leave exactly 1 token (cost 3 = n would need 3)
      assert :ok = take_all([{k, 2, @per_second, 5}])
      assert :ok = take_all([{k, 2, @per_second, 5}])
      assert_in_delta tokens(k), 1.0, 1.0e-9

      assert {:deny, seconds} = take_all([{k, 2, @per_second, 5}])
      assert seconds >= 1
      assert_in_delta tokens(k), 1.0, 1.0e-9, "the denied cost-2 request consumed nothing"
      assert :ok = take_all([{k, 1, @per_second, 5}]), "the one remaining token is still there"
      assert {:deny, _} = take_all([{k, 1, @per_second, 5}])
    end

    test "the wait of a denial is the time until the missing tokens accrue: ceil((cost - tokens) / rate), at least 1 s" do
      k = key("wait")
      # burst 4 at one token per second: spend 4, then ask for 3 -> 3 tokens missing -> 3 s
      assert :ok = take_all([{k, 4, @per_second, 4}])
      assert {:deny, 3} = take_all([{k, 3, @per_second, 4}])
      assert {:deny, 1} = take_all([{k, 1, @per_second, 4}])
    end
  end

  # ═══ (c) two buckets, all or nothing ═════════════════════════════════════════════

  describe "AC1 (c) - two buckets" do
    test "when the SECOND cannot pay the FIRST is not charged, and retry_after_s is the larger wait", %{clock: _clock} do
      first = key("first")
      second = key("second")

      # the second bucket is empty (one token per 10 s -> 10 s wait), the first holds its full burst of 5 (one token per second)
      assert :ok = take_all([{second, 1, @per_ten_seconds, 1}])

      assert {:deny, 10} = take_all([{first, 1, @per_second, 5}, {second, 1, @per_ten_seconds, 1}])

      # a fresh bucket is full (5): whether the denial stored its row or not, it was NOT charged
      assert_in_delta tokens(first) || 5.0, 5.0, 1.0e-9, "the first bucket was not charged"
      assert :ok = take_all([{first, 5, @per_second, 5}]), "all 5 tokens of the first bucket are still there"
    end

    test "when the FIRST cannot pay the second is not charged either (the order of the list does not matter)" do
      first = key("first-empty")
      second = key("second-full")

      assert :ok = take_all([{first, 1, @per_ten_seconds, 1}])
      assert {:deny, 10} = take_all([{first, 1, @per_ten_seconds, 1}, {second, 3, @per_second, 5}])

      assert_in_delta tokens(second) || 5.0, 5.0, 1.0e-9, "the second bucket was not charged"
    end

    test "the wait is the LARGER one of two buckets that both cannot pay, in both list orders" do
      slow = key("slow")
      fast = key("fast")

      assert :ok = take_all([{slow, 1, @per_ten_seconds, 1}])
      assert :ok = take_all([{fast, 1, @per_second, 1}])

      assert {:deny, 10} = take_all([{fast, 1, @per_second, 1}, {slow, 1, @per_ten_seconds, 1}])
      assert {:deny, 10} = take_all([{slow, 1, @per_ten_seconds, 1}, {fast, 1, @per_second, 1}])
    end

    test "when both can pay, both are charged by their own cost" do
      a = key("a")
      b = key("b")

      assert :ok = take_all([{a, 1, @per_second, 5}, {b, 3, @per_second, 50}])
      assert_in_delta tokens(a), 4.0, 1.0e-9
      assert_in_delta tokens(b), 47.0, 1.0e-9
    end
  end

  # ═══ (d) cost > burst ═════════════════════════════════════════════════════════════

  describe "AC1 (d) - cost above the burst" do
    test "is charged as the burst: a full bucket pays it (never an unsatisfiable request), the next one waits for a whole bucket", %{clock: clock} do
      k = key("over")

      assert :ok = take_all([{k, 10, @per_second, 3}])
      assert_in_delta tokens(k), 0.0, 1.0e-9, "charged as burst (3), not as 10"
      assert {:deny, 3} = take_all([{k, 10, @per_second, 3}])

      advance(clock, 3_000)
      assert :ok = take_all([{k, 10, @per_second, 3}])
    end
  end

  # ═══ (e) the clock seam ═══════════════════════════════════════════════════════════

  describe "AC1 (e) - the clock seam refills by elapsed * rate" do
    test "30 / min is one token per 2000 ms: nothing at +1999, one at +2000; two tokens need 4000 (one bucket per probe: no float drift of a split refill)", %{clock: clock} do
      [one_early, one_on_time, two_early, two_on_time] = for label <- ~w(one-early one-on-time two-early two-on-time), do: key(label)

      for k <- [one_early, one_on_time, two_early, two_on_time], do: assert(:ok = take_all([{k, 2, 30, 2}]))

      advance(clock, 1_999)
      assert {:deny, _} = take_all([{one_early, 1, 30, 2}])
      assert {:deny, _} = take_all([{two_early, 2, 30, 2}])

      advance(clock, 1)
      assert :ok = take_all([{one_on_time, 1, 30, 2}])
      assert {:deny, _} = take_all([{one_on_time, 1, 30, 2}]), "exactly one token had accrued"

      advance(clock, 2_000)
      assert :ok = take_all([{two_on_time, 2, 30, 2}]), "two tokens after 4000 ms (the burst of 2)"
    end

    test "the refill is capped at the burst however long the bucket was idle", %{clock: clock} do
      k = key("cap")
      assert :ok = take_all([{k, 1, @per_second, 3}])
      advance(clock, 3_600_000)

      assert :ok = take_all([{k, 3, @per_second, 3}])
      assert {:deny, _} = take_all([{k, 1, @per_second, 3}])
    end
  end

  # ═══ (f) disabled ═════════════════════════════════════════════════════════════════

  describe "AC1 (f) - the disable switch" do
    test ":rate_limit_disabled makes take_all :ok without touching the table, however many tokens are asked" do
      Application.put_env(:nebu_http, :rate_limit_disabled, true)
      k = key("disabled")

      for _ <- 1..20, do: assert(:ok = take_all([{k, 100, 1, 1}, {key("disabled-2"), 100, 1, 1}]))
      assert :ets.whereis(@table) == :undefined or :ets.match_object(@table, {{:atdd_take_all, :_, :_}, :_, :_}) == []

      # positive control: the same call with the switch off is limited (the disabled answer is not a vacuous :ok)
      Application.delete_env(:nebu_http, :rate_limit_disabled)
      assert :ok = take_all([{k, 1, 1, 1}])
      assert {:deny, _} = take_all([{k, 1, 1, 1}])
    end
  end

  # ═══ (g) the keys of the plug ═════════════════════════════════════════════════════

  describe "AC1 (g) - take_all and the plug's {tier, user} keys address the SAME bucket" do
    test "a token taken by take_all is missing for the plug, and the other way round" do
      tier = "atdd-tier-" <> Integer.to_string(System.unique_integer([:positive]))
      user = "@atdd#{System.unique_integer([:positive])}:test.local"
      opts = RateLimit.init(rate_per_min: 60, burst: 3, tier: tier, key: :user)

      plug = fn ->
        %{conn(:post, "/x") | remote_ip: {10, 9, 8, 7}}
        |> Plug.Conn.assign(:current_user, user)
        |> RateLimit.call(opts)
      end

      # burst 3: one token by take_all, one by the plug, one by take_all -> the plug is denied (3rd of 3 spent)
      assert :ok = take_all([{{tier, user}, 1, 60, 3}])
      refute plug.().halted
      assert :ok = take_all([{{tier, user}, 1, 60, 3}])

      denied = plug.()
      assert denied.halted and denied.status == 429, "the bucket of {tier, user} is shared with take_all"

      # and another user of the same tier is unaffected (positive control)
      other = "@atdd#{System.unique_integer([:positive])}:test.local"
      assert :ok = take_all([{{tier, other}, 1, 60, 3}])
    end
  end
end
