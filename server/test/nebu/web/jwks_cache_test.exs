defmodule Nebu.Web.JwksCacheTest do
  @moduledoc """
  RED-phase ATDD test for the oidc-middleware-migration story — AC5.

  AC5: On application start the JWKS keys are fetched from the OIDC provider and
       cached; the cache TTL is configurable via `NEBU_OIDC_JWKS_TTL` (default 300s).

  This test references `Nebu.Web.JwksCache`, a GenServer that DOES NOT EXIST YET,
  so the suite MUST FAIL (undefined module / function) until the dev phase
  implements exactly the contract documented below.

  ## Nebu.Web.JwksCache — public-API contract (implement to this)

  GenServer, started under a supervisor and registered under its module name
  (`name: Nebu.Web.JwksCache`) so it is reachable by name after a crash/restart.

  Public functions:

    * `start_link(opts)` — `opts` keyword list. Supported keys:
        - `:fetcher` — INJECTABLE JWKS source. Either
            * a 0-arity fun returning `{:ok, [jwk_map]}` (or the bare key list), or
            * a module exporting `fetch_jwks/0` with the same return contract.
          If absent, the cache falls back to Application env
          `:nebu_http, :jwks_fetcher` (same shape), and finally to the real
          HTTP fetch against `:nebu_http, :oidc_jwks_uri`.
        - `:name` — registered name (defaults to `Nebu.Web.JwksCache`).
      The GenServer fetches the JWKS ONCE on start (fetch-on-start) and stores
      the resulting key list in its state.

    * `keys/0` — returns the list of currently cached JWK maps (each map has the
      usual `"kty"`, `"n"`, `"e"`, `"kid"`, ... fields). Reads from GenServer state.

    * `ttl_ms/0` — returns the configured cache TTL in MILLISECONDS as an integer.
        - Default 300_000 (300s) when `NEBU_OIDC_JWKS_TTL` is unset.
        - When `NEBU_OIDC_JWKS_TTL="120"`, returns 120_000.
      (Env value is seconds; cache converts to ms.)

  The fetcher seam guarantees NO network access in tests. The stub fetcher is
  installed via Application env (NOT a closure captured in the dead process) so
  it is still reachable after a crash-induced restart — see the recovery test.
  """
  use ExUnit.Case, async: false

  @kid "jwks-cache-key-1"

  # A deterministic, well-formed JWK the stub fetcher hands back. Generated once
  # per test from a fresh RSA keypair so the shape matches real JWKS entries.
  defp build_jwk do
    JOSE.JWK.generate_key({:rsa, 2048})
    |> JOSE.JWK.to_public()
    |> JOSE.JWK.to_map()
    |> elem(1)
    |> Map.put("kid", @kid)
    |> Map.put("alg", "RS256")
    |> Map.put("use", "sig")
  end

  setup do
    # Always start from a clean env so TTL assertions are deterministic.
    System.delete_env("NEBU_OIDC_JWKS_TTL")

    on_exit(fn ->
      System.delete_env("NEBU_OIDC_JWKS_TTL")
      Application.delete_env(:nebu_http, :jwks_fetcher)
    end)

    :ok
  end

  describe "AC5 — TTL configuration via NEBU_OIDC_JWKS_TTL" do
    test "default TTL is 300_000 ms when NEBU_OIDC_JWKS_TTL is unset" do
      System.delete_env("NEBU_OIDC_JWKS_TTL")

      assert Nebu.Web.JwksCache.ttl_ms() == 300_000,
             "default TTL must be 300s (300_000 ms) when NEBU_OIDC_JWKS_TTL is unset"
    end

    test "TTL follows NEBU_OIDC_JWKS_TTL (seconds → milliseconds)" do
      System.put_env("NEBU_OIDC_JWKS_TTL", "120")

      assert Nebu.Web.JwksCache.ttl_ms() == 120_000,
             "NEBU_OIDC_JWKS_TTL=120 must yield a 120_000 ms TTL"
    end
  end

  describe "AC5 — fetch-on-start via injectable fetcher (no network)" do
    test "GenServer fetches JWKS on start and keys/0 returns them" do
      jwk = build_jwk()

      # Inject a stub 0-arity fetcher; the cache must call it on start.
      pid = start_supervised!({Nebu.Web.JwksCache, fetcher: fn -> {:ok, [jwk]} end})
      assert is_pid(pid)

      assert Nebu.Web.JwksCache.keys() == [jwk],
             "keys/0 must return exactly the key set produced by the injected fetcher"
    end
  end

  describe "refresh failure retains last-known-good keys (MINOR-5)" do
    test "a failing refresh keeps the previously cached keys instead of blanking to []" do
      jwk = build_jwk()

      # First fetch succeeds and returns the key; every subsequent fetch (the
      # scheduled refresh) fails with :error. The cache must keep `jwk`.
      {:ok, calls} = Agent.start_link(fn -> 0 end)
      on_exit(fn -> if Process.alive?(calls), do: Agent.stop(calls) end)

      fetcher = fn ->
        n = Agent.get_and_update(calls, fn c -> {c, c + 1} end)
        if n == 0, do: {:ok, [jwk]}, else: :error
      end

      # Tiny TTL so the refresh fires almost immediately.
      System.put_env("NEBU_OIDC_JWKS_TTL", "1")
      pid = start_supervised!({Nebu.Web.JwksCache, fetcher: fetcher})

      assert Nebu.Web.JwksCache.keys() == [jwk], "initial fetch must populate keys"

      # Drive a refresh synchronously: send :refresh and confirm the fetcher ran
      # again (call count advanced) yet the keys are unchanged.
      send(pid, :refresh)

      # Wait until the failing refresh has been invoked at least twice total.
      wait_until(fn -> Agent.get(calls, & &1) >= 2 end)

      assert Nebu.Web.JwksCache.keys() == [jwk],
             "a failed refresh must retain the last-known-good keys, not reset to []"
    end
  end

  describe "AC5 — crash/restart recovery (mandatory GenServer rule)" do
    test "after Process.exit(:kill) the cache restarts and re-fetches the JWKS" do
      jwk = build_jwk()

      # Install the fetcher via Application env (NOT a closure tied to the dead
      # process) so it is still reachable after the supervisor restarts the child.
      # A counter lets us prove the fetcher was invoked AGAIN after restart.
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      on_exit(fn -> if Process.alive?(counter), do: Agent.stop(counter) end)

      Application.put_env(:nebu_http, :jwks_fetcher, fn ->
        Agent.update(counter, &(&1 + 1))
        {:ok, [jwk]}
      end)

      # Start under a supervisor so the child is restarted on crash. Registered
      # under its module name so we can re-resolve the new pid after restart.
      sup =
        start_supervised!(%{
          id: :jwks_cache_sup,
          start:
            {Supervisor, :start_link,
             [
               [{Nebu.Web.JwksCache, []}],
               [strategy: :one_for_one]
             ]}
        })

      assert is_pid(sup)

      first_pid = wait_for_named_pid(Nebu.Web.JwksCache)
      assert Nebu.Web.JwksCache.keys() == [jwk]
      assert Agent.get(counter, & &1) == 1, "fetcher must run once on initial start"

      # Kill it and deterministically wait for the supervisor to restart it:
      # monitor the dead pid, await its :DOWN, then poll for a DIFFERENT live pid
      # registered under the same name (no fixed Process.sleep).
      ref = Process.monitor(first_pid)
      Process.exit(first_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^first_pid, _reason}, 1_000

      second_pid = wait_for_restarted_pid(Nebu.Web.JwksCache, first_pid)
      refute second_pid == first_pid, "supervisor must start a fresh process"

      # State is volatile (ETS/in-memory), so recovery means re-fetching: keys
      # are repopulated and the fetcher was invoked a second time.
      assert Nebu.Web.JwksCache.keys() == [jwk],
             "keys/0 must be repopulated after a crash/restart"

      assert Agent.get(counter, & &1) == 2,
             "fetcher must be invoked again after restart (state re-fetched, not lost)"
    end
  end

  # --- deterministic polling helpers (no fixed sleeps) -----------------------

  # Poll until `name` resolves to a live pid, or fail after the timeout.
  defp wait_for_named_pid(name, timeout_ms \\ 1_000) do
    poll_until(timeout_ms, fn ->
      case Process.whereis(name) do
        pid when is_pid(pid) -> if Process.alive?(pid), do: {:ok, pid}, else: :retry
        _ -> :retry
      end
    end)
  end

  # Poll until `name` resolves to a live pid DIFFERENT from `old_pid`.
  defp wait_for_restarted_pid(name, old_pid, timeout_ms \\ 1_000) do
    poll_until(timeout_ms, fn ->
      case Process.whereis(name) do
        pid when is_pid(pid) and pid != old_pid ->
          if Process.alive?(pid), do: {:ok, pid}, else: :retry

        _ ->
          :retry
      end
    end)
  end

  # Poll until `pred` returns true, or fail after the timeout.
  defp wait_until(pred, timeout_ms \\ 1_000) do
    poll_until(timeout_ms, fn -> if pred.(), do: {:ok, :met}, else: :retry end)
  end

  defp poll_until(timeout_ms, fun) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_poll(deadline, fun)
  end

  defp do_poll(deadline, fun) do
    case fun.() do
      {:ok, value} ->
        value

      :retry ->
        now = System.monotonic_time(:millisecond)

        if now >= deadline do
          flunk("condition not met within timeout while polling JwksCache")
        else
          # Short, bounded yield — this is a poll interval, not a synchronization
          # wait on a fixed duration. The loop is gated by `deadline`.
          Process.sleep(10)
          do_poll(deadline, fun)
        end
    end
  end
end
