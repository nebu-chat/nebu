defmodule Nebu.OAuth.SessionLifetimeCacheTest do
  @moduledoc """
  Story `session-lifetime-setting` (epic oauth-session-and-consent), the design points of the read side, against the REAL database (integration):

    * HOT PATH: `Nebu.Web.SessionConfig.matrix_session_ttl_seconds/0` is called at every Matrix login, `/refresh` re-mint, background refresh and every
      refresh-token lookup; it must not issue a `server_config` query per call. The stored value is served from the per-node TTL cache of `Nebu.OAuth.Config`
      (`:nebu_http, :oauth_config_cache_ms`, default 2 s, `0` = off; clock seam `:oauth_config_cache_clock_fn`, same idiom as `oauth_config_cache_test.exs`):
      at most ONE query per TTL window for any number of calls.
    * PROPAGATION: the saving node serves the new value at once (the write drops this node's cache entry after the commit); another node, which cannot be
      told, serves the old value for at most one TTL (bounded staleness, the same as the OAuth switch).
    * A failed read is never cached and never raises: an unreadable `server_config` answers the env value / 8 hours (fail safe: a login is never refused
      because the setting cannot be read), and a damaged stored value is ignored with ONE warning naming the key, never the raw value.
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  import ExUnit.CaptureLog

  alias Nebu.Admin.ReauthButtonFlowSupport, as: S
  alias Nebu.OAuth.TestSupport, as: T
  alias Nebu.SessionLifetime.TestSupport, as: L
  alias Nebu.Web.SessionConfig

  @cache :nebu_oauth_config_cache
  @t0 1_000_000

  setup do
    T.clear_oauth_config()
    T.put_env_scoped(:admin_csrf_bypass, true)
    L.clear_env_ttl!()
    L.delete_row!()
    L.clear_audit_rows!()
    L.real_seams!()

    clock = :atomics.new(1, [])
    :atomics.put(clock, 1, @t0)
    prior_ttl = Application.fetch_env(:nebu_http, :oauth_config_cache_ms)
    prior_clock = Application.fetch_env(:nebu_http, :oauth_config_cache_clock_fn)
    Application.put_env(:nebu_http, :oauth_config_cache_ms, 2000)
    Application.put_env(:nebu_http, :oauth_config_cache_clock_fn, fn -> :atomics.get(clock, 1) end)
    clear_cache()

    on_exit(fn ->
      restore(:oauth_config_cache_ms, prior_ttl)
      restore(:oauth_config_cache_clock_fn, prior_clock)
      Application.delete_env(:nebu_http, :oauth_config_repo)
      clear_cache()
      L.clear_audit_rows!()
    end)

    {:ok, clock: clock}
  end

  defp restore(key, {:ok, value}), do: Application.put_env(:nebu_http, key, value)
  defp restore(key, :error), do: Application.delete_env(:nebu_http, key)

  defp clear_cache, do: if(:ets.whereis(@cache) != :undefined, do: :ets.delete_all_objects(@cache))
  defp set_clock(clock, offset_ms), do: :atomics.put(clock, 1, @t0 + offset_ms)
  defp ttl, do: SessionConfig.matrix_session_ttl_seconds()

  @doc false
  def handle_query(_event, _measurements, %{query: query}, %{pid: pid}) do
    if self() == pid, do: send(pid, {:db_query, query})
    :ok
  end

  # Runs `fun` and returns `{result, [sql of every query the TEST process issued]}`.
  defp with_queries(fun) do
    id = "lifetime-cache-" <> T.rand()
    :telemetry.attach(id, [:nebu, :repo, :query], &__MODULE__.handle_query/4, %{pid: self()})

    try do
      result = fun.()
      {result, drain([])}
    after
      :telemetry.detach(id)
    end
  end

  defp drain(acc) do
    receive do
      {:db_query, q} -> drain([q | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp config_reads(queries), do: Enum.count(queries, &(&1 =~ "server_config"))

  defp break_repo! do
    {:ok, pid} = Agent.start_link(fn -> :ok end, name: Nebu.OAuth.TestSupport.BrokenRepo)
    Application.put_env(:nebu_http, :oauth_config_repo, Nebu.OAuth.TestSupport.BrokenRepo)
    on_exit(fn -> if Process.alive?(pid), do: (try do Agent.stop(pid) catch :exit, _ -> :ok end) end)
  end

  # ════════════════════════════════════════════════════════════════════════════

  describe "hot path: no query per call" do
    test "many calls inside the TTL window issue ONE server_config query; the value is right", %{clock: clock} do
      L.set_row!("7200")

      {values, queries} =
        with_queries(fn ->
          for offset <- [0, 1, 500, 1999], do: (set_clock(clock, offset); ttl())
        end)

      assert values == [7200, 7200, 7200, 7200]
      assert config_reads(queries) == 1, "one read for the window, got #{config_reads(queries)}: #{inspect(queries)}"
    end

    test "at now - loaded_at = TTL the entry is stale: the next call reads again and picks up a change made by another node", %{clock: clock} do
      L.set_row!("7200")
      assert ttl() == 7200

      # another node (or the operator) changes the row: this node cannot be told
      L.set_row!("10800")
      set_clock(clock, 1999)
      assert ttl() == 7200, "inside the window the cached value is served (bounded staleness)"

      set_clock(clock, 2000)
      {value, queries} = with_queries(fn -> ttl() end)
      assert value == 10_800, "within one TTL every other node follows"
      assert config_reads(queries) == 1
    end

    test "nothing saved is a successful read too: it is cached (no query per login for an instance that never set it)", %{clock: clock} do
      {values, queries} =
        with_queries(fn ->
          for offset <- [0, 10, 20], do: (set_clock(clock, offset); ttl())
        end)

      assert values == [28_800, 28_800, 28_800]
      assert config_reads(queries) == 1
    end

    test "with the cache off (0) every call reads: the saved value is live", %{clock: _clock} do
      Application.put_env(:nebu_http, :oauth_config_cache_ms, 0)
      L.set_row!("7200")
      assert ttl() == 7200
      L.set_row!("3600")
      assert ttl() == 3600
    end
  end

  describe "propagation" do
    test "the saving node serves the new value at once: the admin save drops this node's cache entry", %{clock: clock} do
      L.set_row!("28800")
      assert ttl() == 28_800
      set_clock(clock, 100)
      assert ttl() == 28_800, "cached"

      conn = S.post("/admin/config/session-lifetime", %{"matrix_session_ttl_seconds" => "7200"}, "/admin/config", ago: 10)
      assert conn.status in [302, 303]
      assert L.row_value() == "7200"

      assert ttl() == 7200, "same clock, no TTL elapsed: the write invalidated this node's entry"
      assert [row] = L.audit_rows()
      assert row["metadata"] == %{"before_seconds" => 28_800, "after_seconds" => 7200}
    end

    test "a refused save (out of range) leaves the cache and the row alone", %{clock: clock} do
      L.set_row!("28800")
      assert ttl() == 28_800
      set_clock(clock, 100)

      conn = S.post("/admin/config/session-lifetime", %{"matrix_session_ttl_seconds" => "8640000"}, "/admin/config", ago: 10)
      assert conn.status == 200
      assert L.row_value() == "28800"
      assert L.audit_rows() == []
      assert ttl() == 28_800
    end
  end

  describe "fail safe: an unreadable or damaged setting never breaks the login path" do
    test "the cache table is gone (its owner is stopped): the saved value is still served, not the 8 hour fallback, and the caller never creates the table" do
      L.set_row!("3600")
      on_exit(fn -> Supervisor.restart_child(Nebu.Supervisor, Nebu.OAuth.CacheOwner) end)
      assert :ok = Supervisor.terminate_child(Nebu.Supervisor, Nebu.OAuth.CacheOwner)
      assert :ets.whereis(@cache) == :undefined

      assert ttl() == 3600
      assert ttl() == 3600
      assert :ets.whereis(@cache) == :undefined, "a reader is read-through only: it never creates the owner's table"
    end

    test "an unreadable server_config answers the env value / 8 hours and is not cached", %{clock: clock} do
      L.set_row!("7200")
      break_repo!()

      capture_log(fn -> send(self(), {:v1, ttl()}) end)
      assert_received {:v1, 28_800}

      L.put_env_ttl!(600)
      capture_log(fn -> send(self(), {:v2, ttl()}) end)
      assert_received {:v2, 600}

      # healed: the very next call reads the row (the failure was not cached)
      Application.delete_env(:nebu_http, :oauth_config_repo)
      set_clock(clock, 1)
      assert ttl() == 7200
    end

    test "a damaged row (text, out of range, blank) is ignored with a warning that names the key and never the raw value", %{clock: _clock} do
      Application.put_env(:nebu_http, :oauth_config_cache_ms, 0)

      # the warning is rate limited to one per minute per node (cycle 1, Kassandra #3): every value starts with a fresh bucket
      on_exit(&T.restore_rate_limits/0)

      for raw <- ["canary-lt-8812-xyz", "100", "99999999999", " ", "7200.5"] do
        T.reset_rate_limits()
        L.set_row!(raw)
        log = capture_log([level: :warning], fn -> send(self(), {:v, ttl()}) end)
        assert_received {:v, 28_800}
        assert log =~ "matrix_session_ttl_seconds", "a warning names the key for #{inspect(raw)}: #{inspect(log)}"
        assert log =~ ~r/warn/i
        refute log =~ "canary-lt-8812", log
      end
    end

    test "a damaged row falls back to the ENV value when one is set", %{clock: _clock} do
      Application.put_env(:nebu_http, :oauth_config_cache_ms, 0)
      L.put_env_ttl!(14_400)
      L.set_row!("junk")
      capture_log(fn -> send(self(), {:v, ttl()}) end)
      assert_received {:v, 14_400}
    end

    test "a valid row produces no warning at all" do
      Application.put_env(:nebu_http, :oauth_config_cache_ms, 0)
      L.set_row!("7200")
      log = capture_log([level: :warning], fn -> assert ttl() == 7200 end)
      refute log =~ "matrix_session_ttl_seconds", log
    end
  end
end
