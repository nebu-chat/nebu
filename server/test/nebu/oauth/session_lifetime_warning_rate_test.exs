defmodule Nebu.OAuth.SessionLifetimeWarningRateTest do
  @moduledoc """
  Story `session-lifetime-setting`, CYCLE 1 (Kassandra #3 LOW, code review MINOR 3): the WARNING for a damaged `matrix_session_ttl_seconds` is rate limited to
  at most ONE per minute per node (the shape of the sibling `Nebu.OAuth.Config` read warning: `Nebu.Web.Plugs.RateLimit.take/3`), instead of one per cache
  refill (about 30 per minute per node) or one per call with the cache off. The text still names the key and never the value. No database: the config source
  seam delivers the damaged value; the rate limiter is the real one with a frozen clock (`T.reset_rate_limits/0`), moved by `:rate_limit_clock_fn`.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Nebu.OAuth.TestSupport, as: T
  alias Nebu.SessionLifetime.TestSupport, as: L
  alias Nebu.Web.SessionConfig

  setup do
    T.clear_oauth_config()
    L.clear_env_ttl!()
    T.reset_rate_limits()

    on_exit(fn ->
      T.clear_oauth_config()
      T.restore_rate_limits()
    end)

    :ok
  end

  defp warnings(log), do: length(Regex.scan(~r/\[warning\][^\n]*matrix_session_ttl_seconds/, log))
  defp damaged_reads(n), do: for(_ <- 1..n, do: SessionConfig.matrix_session_ttl_seconds())

  test "many reads of a damaged value within a minute log ONE warning, naming the key and never the value" do
    L.seam_stored("canary-wr-5541-junk")
    log = capture_log([level: :warning], fn -> assert Enum.uniq(damaged_reads(40)) == [28_800] end)
    assert warnings(log) == 1, log
    refute log =~ "canary-wr-5541"
  end

  test "a minute later the next damaged read warns again (once)" do
    L.seam_stored("999")

    first = capture_log([level: :warning], fn -> damaged_reads(10) end)
    assert warnings(first) == 1

    Application.put_env(:nebu_http, :rate_limit_clock_fn, fn -> 1_000_000 + 30_000 end)
    within = capture_log([level: :warning], fn -> damaged_reads(10) end)
    assert warnings(within) == 0, "30 seconds later: still the same minute"

    Application.put_env(:nebu_http, :rate_limit_clock_fn, fn -> 1_000_000 + 61_000 end)
    later = capture_log([level: :warning], fn -> damaged_reads(10) end)
    assert warnings(later) == 1, "after a minute"
  end

  test "different damaged values do not each get a warning: the limit is per node, not per value" do
    log =
      capture_log([level: :warning], fn ->
        for raw <- ["abc", "100", "99999999", "", "7200.5"] do
          L.seam_stored(raw)
          SessionConfig.matrix_session_ttl_seconds()
        end
      end)

    assert warnings(log) == 1, log
  end

  test "a valid value and no value log nothing" do
    for raw <- ["7200", :absent] do
      L.seam_stored(raw)
      log = capture_log([level: :warning], fn -> damaged_reads(5) end)
      assert warnings(log) == 0, "stored #{inspect(raw)}"
    end
  end
end
