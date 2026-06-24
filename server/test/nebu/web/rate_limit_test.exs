defmodule Nebu.Web.Plugs.RateLimitTest do
  @moduledoc """
  Unit tests for the F-3 per-IP rate-limit plug (matrix-api-migration).

  Proves: requests up to the burst pass, the next is rejected with 429
  M_LIMIT_EXCEEDED + a Retry-After header (Go strictRL parity), distinct IPs
  have independent buckets, and the NEBU_RATE_LIMIT_DISABLED escape hatch is a
  no-op.
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  @table :nebu_http_rate_limit_buckets

  setup do
    if :ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table)

    # Defend against bleed: a sibling test (login_refresh_test, the matrix-router AC1
    # contract block, …) may have set :rate_limit_disabled=true. The 429-asserting
    # tests below REQUIRE the limiter enabled, so force the override off here in setup
    # (not just on_exit) — and assert the OS env hatch isn't "true" either, since
    # disabled?/0 ORs both. Tests that WANT it disabled (the no-op test) set it
    # explicitly after this.
    Application.delete_env(:nebu_http, :rate_limit_disabled)

    assert System.get_env("NEBU_RATE_LIMIT_DISABLED") != "true",
           "RateLimitTest requires the limiter ENABLED — NEBU_RATE_LIMIT_DISABLED must not be \"true\" " <>
             "(do not set it globally in the test harness; disable the limiter per-test via app env instead)"

    on_exit(fn ->
      if :ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table)
      Application.delete_env(:nebu_http, :rate_limit_disabled)
    end)

    :ok
  end

  # A conn with a fixed peer IP so all requests in a test share one bucket.
  defp req(ip \\ {127, 0, 0, 1}) do
    %{conn(:post, "/_matrix/client/v3/login") | remote_ip: ip}
  end

  test "requests up to the burst pass, the next is rejected with 429 M_LIMIT_EXCEEDED" do
    # rate 30/min, burst 3 — three back-to-back requests should pass, the 4th 429.
    opts = Nebu.Web.Plugs.RateLimit.init(rate_per_min: 30, burst: 3, tier: "test")

    for _ <- 1..3 do
      conn = Nebu.Web.Plugs.RateLimit.call(req(), opts)
      refute conn.halted, "requests within the burst must pass"
    end

    blocked = Nebu.Web.Plugs.RateLimit.call(req(), opts)

    assert blocked.halted, "the request past the burst must be rejected"
    assert blocked.status == 429
    body = Jason.decode!(blocked.resp_body)
    assert body["errcode"] == "M_LIMIT_EXCEEDED"

    retry_after = get_resp_header(blocked, "retry-after") |> List.first()
    assert retry_after != nil, "a 429 must carry a Retry-After header"
    assert String.to_integer(retry_after) >= 1
  end

  test "distinct IPs have independent buckets" do
    opts = Nebu.Web.Plugs.RateLimit.init(rate_per_min: 30, burst: 1, tier: "test")

    a1 = Nebu.Web.Plugs.RateLimit.call(req({10, 0, 0, 1}), opts)
    refute a1.halted

    # Second request from IP A is over its burst-1 bucket → blocked.
    a2 = Nebu.Web.Plugs.RateLimit.call(req({10, 0, 0, 1}), opts)
    assert a2.halted

    # A fresh IP B still has a full bucket → passes.
    b1 = Nebu.Web.Plugs.RateLimit.call(req({10, 0, 0, 2}), opts)
    refute b1.halted, "a different IP must have its own bucket"
  end

  test "NEBU_RATE_LIMIT_DISABLED via app env makes the plug a no-op" do
    Application.put_env(:nebu_http, :rate_limit_disabled, true)
    opts = Nebu.Web.Plugs.RateLimit.init(rate_per_min: 1, burst: 1, tier: "test")

    # Far more than the burst — none should be blocked when disabled.
    for _ <- 1..10 do
      conn = Nebu.Web.Plugs.RateLimit.call(req(), opts)
      refute conn.halted, "rate limiting must be a no-op when disabled"
    end
  end

  test "injectable clock drives refill: token refills when clock advances ≥ 2000 ms" do
    # rate 30/min, burst 1  → 1 token refills every 2000 ms exactly.
    opts = Nebu.Web.Plugs.RateLimit.init(rate_per_min: 30, burst: 1, tier: "test")

    # Use an Agent to hold a mutable "now" value.
    {:ok, clock} = Agent.start_link(fn -> 0 end)

    Application.put_env(:nebu_http, :rate_limit_clock_fn, fn ->
      Agent.get(clock, & &1)
    end)

    on_exit(fn ->
      Application.delete_env(:nebu_http, :rate_limit_clock_fn)
      if Process.alive?(clock), do: Agent.stop(clock)
    end)

    # t=0: first request — bucket starts full (burst 1), consumed → passes.
    c1 = Nebu.Web.Plugs.RateLimit.call(req(), opts)
    refute c1.halted, "first request at t=0 must pass (full bucket)"

    # t=0: second request — bucket empty → rejected.
    c2 = Nebu.Web.Plugs.RateLimit.call(req(), opts)
    assert c2.halted, "second request at t=0 must be rejected (bucket exhausted)"
    assert c2.status == 429

    # Advance the clock by 2000 ms → exactly one full token refills (rate 30/min = 1/2000ms).
    Agent.update(clock, fn _ -> 2_000 end)

    # t=2000: third request — one token has refilled → passes.
    c3 = Nebu.Web.Plugs.RateLimit.call(req(), opts)
    refute c3.halted, "request after clock advance by 2000 ms must pass (one token refilled)"
  end
end
