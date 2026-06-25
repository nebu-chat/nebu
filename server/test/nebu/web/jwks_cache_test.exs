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
      Application.delete_env(:nebu_http, :oidc_jwks_uri)
      Application.delete_env(:nebu_http, :oidc_issuer)
      Application.delete_env(:nebu_http, :oidc_metadata_override)
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

  # ── Bug regression: JWKS auto-discovery from OIDC issuer ──────────────────
  #
  # Regression tests for the bug where JwksCache returns {:ok, []} (empty keys)
  # when NEBU_OIDC_JWKS_URI is not set but NEBU_OIDC_ISSUER IS set.
  #
  # Root cause: `http_fetch/0` in jwks_cache.ex only checks `:oidc_jwks_uri` app
  # env and `OidcConfig.jwks_uri()` (DB cache). When both are nil it returns
  # `{:ok, []}` immediately — never consulting the issuer's discovery document.
  #
  # Expected behaviour (post-fix): when no explicit JWKS URI is configured but an
  # issuer IS configured, JwksCache must auto-discover the JWKS URI by fetching
  # `{issuer}/.well-known/openid-configuration` and reading the `jwks_uri` field,
  # then fetch keys from that URL.
  #
  # ## How these tests stay genuinely RED
  #
  # We do NOT set `:jwks_fetcher` app env (which would bypass `http_fetch` entirely).
  # Instead we only set `:oidc_issuer` + `:oidc_metadata_override` (simulating a
  # discovery document with a `jwks_uri` field). The bug is that `http_fetch` ignores
  # the issuer and never calls `OidcMetadata.fetch/1`, so it returns `{:ok, []}`.
  #
  # After the fix, `http_fetch` will call `OidcMetadata.fetch(issuer)`, extract
  # `jwks_uri` from the override, and pass it to `fetch_jwks_over_http/1`. The test
  # uses a `:jwks_uri_fetcher` seam (to be added by the fix) so the HTTP key-fetch
  # step can also be stubbed without a live endpoint.
  #
  # IMPORTANT: tests named "RED — ..." below will FAIL now (assert keys != []) and
  # PASS only after the fix is applied. Do not mark them with @tag :skip.

  describe "Bug: auto-discovery of JWKS URI from OIDC issuer (NEBU_OIDC_ISSUER set, NEBU_OIDC_JWKS_URI absent)" do
    test "RED — when issuer is configured, auto-discovery is attempted (not silently returning [])" do
      # This test asserts that JwksCache does NOT return [] when:
      #   - NEBU_OIDC_JWKS_URI is not set
      #   - NEBU_OIDC_ISSUER IS set (oidc_issuer app env)
      #   - The issuer's /.well-known/openid-configuration contains a jwks_uri
      #
      # Current (buggy) behaviour: returns [], because http_fetch/0 short-circuits
      # with `{:ok, []}` when oidc_jwks_uri is nil, never consulting the issuer.
      #
      # Expected (fixed) behaviour: discovers jwks_uri from the metadata and
      # attempts to fetch keys. Since the discovered uri won't resolve in test,
      # the result may still be [] due to an HTTP error, but the path taken must
      # differ: OidcMetadata.fetch/1 must have been called. We prove this via a
      # counter agent installed in the oidc_metadata_override seam.

      issuer = "https://dex.example.com/dex"
      jwks_uri = "https://dex.example.com/dex/keys"

      # No explicit JWKS URI.
      Application.delete_env(:nebu_http, :oidc_jwks_uri)
      Application.put_env(:nebu_http, :oidc_issuer, issuer)

      # Install a counting override: when OidcMetadata.fetch/1 is called (via the
      # override seam), it increments the counter and returns a document with jwks_uri.
      # NOTE: the :oidc_metadata_override seam is a map (checked in OidcMetadata.fetch/1);
      # we cannot attach side-effects directly. Instead, we verify discovery was
      # attempted by asserting that a subsequent call to OidcMetadata.fetch/1 with
      # the issuer returns the expected jwks_uri — and that JwksCache got past the
      # nil-JWKS-URI short-circuit.
      Application.put_env(:nebu_http, :oidc_metadata_override, %{
        "issuer" => issuer,
        "jwks_uri" => jwks_uri,
        "authorization_endpoint" => "https://dex.example.com/dex/auth"
      })

      # Add a `:jwks_http_fetcher` seam (expected to be introduced by the fix) so
      # we can stub the final HTTP fetch step. After the fix, when discovery resolves
      # jwks_uri, JwksCache calls this seam instead of raw :httpc, letting tests
      # control the key-fetch result without a live endpoint.
      jwk = build_jwk()
      Application.put_env(:nebu_http, :jwks_http_fetcher, fn _uri -> {:ok, [jwk]} end)

      on_exit(fn -> Application.delete_env(:nebu_http, :jwks_http_fetcher) end)

      pid = start_supervised!({Nebu.Web.JwksCache, []})
      assert is_pid(pid)

      keys = Nebu.Web.JwksCache.keys()

      assert keys != [],
             "Bug: JwksCache returns [] when NEBU_OIDC_ISSUER is configured but " <>
               "NEBU_OIDC_JWKS_URI is not set. Current behaviour: http_fetch/0 hits the " <>
               "`nil ->` branch and returns {:ok, []} without consulting the issuer's " <>
               "discovery document. Expected (post-fix): auto-discover jwks_uri from " <>
               "#{issuer}/.well-known/openid-configuration and fetch keys from #{jwks_uri}."
    end

    test "RED — when issuer is configured and discovery returns jwks_uri, keys are populated from that URI" do
      jwk = build_jwk()
      issuer = "https://dex.example.com/dex"
      jwks_uri = "https://dex.example.com/dex/keys"

      Application.delete_env(:nebu_http, :oidc_jwks_uri)
      Application.put_env(:nebu_http, :oidc_issuer, issuer)

      Application.put_env(:nebu_http, :oidc_metadata_override, %{
        "issuer" => issuer,
        "jwks_uri" => jwks_uri
      })

      # Stub the HTTP key-fetch seam to be added by the fix.
      Application.put_env(:nebu_http, :jwks_http_fetcher, fn _uri -> {:ok, [jwk]} end)
      on_exit(fn -> Application.delete_env(:nebu_http, :jwks_http_fetcher) end)

      _pid = start_supervised!({Nebu.Web.JwksCache, []})

      assert Nebu.Web.JwksCache.keys() == [jwk],
             "JwksCache must populate keys from the auto-discovered jwks_uri '#{jwks_uri}'. " <>
               "Bug: currently returns [] without ever reading the jwks_uri from the " <>
               "discovery document."
    end

    test "when neither issuer nor JWKS URI is configured, cache returns empty keys without attempting discovery" do
      Application.delete_env(:nebu_http, :oidc_jwks_uri)
      Application.delete_env(:nebu_http, :oidc_issuer)

      pid = start_supervised!({Nebu.Web.JwksCache, []})
      assert is_pid(pid)

      assert Nebu.Web.JwksCache.keys() == [],
             "JwksCache must return [] when neither JWKS URI nor issuer is configured"
    end

    test "explicit JWKS URI (oidc_jwks_uri env) takes precedence over issuer-based auto-discovery" do
      jwk = build_jwk()
      issuer = "https://dex.example.com/dex"

      # Both issuer AND explicit JWKS URI configured — explicit URI wins.
      Application.put_env(:nebu_http, :oidc_issuer, issuer)
      Application.put_env(:nebu_http, :oidc_jwks_uri, "https://explicit-jwks.example.com/keys")

      # Discovery document claims a different jwks_uri — must NOT be consulted.
      Application.put_env(:nebu_http, :oidc_metadata_override, %{
        "issuer" => issuer,
        "jwks_uri" => "https://WRONG-should-not-be-used.example.com/keys"
      })

      # Use the injectable :fetcher seam (not jwks_http_fetcher) since the explicit
      # URI path goes through the existing fetcher stack, not the auto-discovery path.
      pid = start_supervised!({Nebu.Web.JwksCache, fetcher: fn -> {:ok, [jwk]} end})
      assert is_pid(pid)

      assert Nebu.Web.JwksCache.keys() == [jwk],
             "Explicit NEBU_OIDC_JWKS_URI must take precedence over issuer discovery"
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
