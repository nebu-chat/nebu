defmodule Nebu.Matrix.RateLimitHelperRestoreTest do
  @moduledoc """
  Regression test of bugfix `integration-test-flakes-fix` (B): the `enable_rate_limit/0` helpers of the to-device and room-keys test
  supports must leave the rate-limit seams exactly as they found them.

  The to-device helper called `T.reset_rate_limits/0` (frozen clock `fn -> 1_000_000 end`) BEFORE `put_env_restoring(:rate_limit_clock_fn, ...)`.
  `on_exit` callbacks run in reverse order, so `restore_rate_limits/0` deleted the clock and `put_env_restoring` then put the FROZEN clock back
  as "the old value": for the rest of the run no per-IP bucket refilled, and later suites (RoomAccountDataTest, SyncConcurrentTest, MatrixSsoTest,
  ForgetRoomMembershipPurgeTest) answered 429.

  How the end state is observed: the cleanup callback of this test is registered FIRST, so it runs LAST (`on_exit` is LIFO) and sees the state
  after every cleanup of the helper under test. A failing assertion in an `on_exit` callback fails the test.

  No database, no live stack: only the application environment and the (ETS) bucket table.
  """
  use ExUnit.Case, async: false

  alias Nebu.Matrix.RoomKeysTestSupport, as: RoomKeys
  alias Nebu.Matrix.ToDeviceTestSupport, as: ToDevice

  @keys [:rate_limit_clock_fn, :rate_limit_disabled]
  @bucket_table :nebu_http_rate_limit_buckets

  # registered before the helper under test: runs after all of its cleanup
  defp assert_seams_restored_at_the_end do
    before = Map.new(@keys, fn k -> {k, Application.fetch_env(:nebu_http, k)} end)

    ExUnit.Callbacks.on_exit(fn ->
      for k <- @keys do
        assert Application.fetch_env(:nebu_http, k) == before[k],
               "#{inspect(k)} was #{inspect(before[k])} before the test and is #{inspect(Application.fetch_env(:nebu_http, k))} after " <>
                 "the cleanup of enable_rate_limit/0: the seam leaked into the rest of the run"
      end

      if :ets.whereis(@bucket_table) != :undefined do
        assert :ets.info(@bucket_table, :size) == 0, "the bucket table must be empty after the cleanup"
      end
    end)
  end

  test "ToDeviceTestSupport.enable_rate_limit/0 puts the clock and disabled seams back (no frozen clock leaks out)" do
    assert_seams_restored_at_the_end()
    ToDevice.enable_rate_limit()

    assert {:ok, clock} = Application.fetch_env(:nebu_http, :rate_limit_clock_fn)
    assert is_function(clock, 0), "while the test runs the clock is frozen (deterministic bursts)"
  end

  test "RoomKeysTestSupport.enable_rate_limit/0 puts the clock and disabled seams back (no frozen clock leaks out)" do
    assert_seams_restored_at_the_end()
    RoomKeys.enable_rate_limit()

    assert {:ok, clock} = Application.fetch_env(:nebu_http, :rate_limit_clock_fn)
    assert is_function(clock, 0), "while the test runs the clock is frozen (deterministic bursts)"
  end
end
