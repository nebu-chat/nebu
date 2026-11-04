defmodule Nebu.OAuth.SessionLifetimeStaleRefillTest do
  @moduledoc """
  Story `session-lifetime-setting`, CYCLE 2 (Kassandra delta LOW #1, code review delta MINOR 3): a read of `server_config` that is IN FLIGHT while the admin saves
  must not write its OLDER answer over the newer saved value, neither into the last-known-good slot (`Nebu.OAuth.LastGood`: a longer old value would stay until
  the next successful read, longer than "at most one TTL") nor into the TTL cache (the entry dropped by the save would be refilled with the old config).
  Contract: a generation (compare-and-set) that the deliberate save (`note_saved_matrix_session_ttl/1`) bumps; the reader captures it BEFORE its query and writes
  the last good value / the cache entry only when it is unchanged. The same for the "found no row" answer (`LastGood.clear/0`).

  The interleaving is deterministic and needs no seam in the code under test: a telemetry handler on the repo query event (it runs in the process that ran the query,
  after the answer came back and before the reader continues) parks ONE chosen reader process after its query returned; the test saves through the real admin form
  meanwhile and then releases the reader. Real database, real audit writer.
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  import ExUnit.CaptureLog

  alias Nebu.Admin.ReauthButtonFlowSupport, as: S
  alias Nebu.OAuth.TestSupport, as: T
  alias Nebu.SessionLifetime.TestSupport, as: L
  alias Nebu.Web.SessionConfig

  @t0 1_000_000
  @cache :nebu_oauth_config_cache

  # Runs in the process that issued the query: parks the process that marked itself with :lifetime_block_reader, once, after its server_config read.
  @doc false
  def handle_query(_event, _measurements, %{query: query}, _config) do
    with pid when is_pid(pid) <- Process.get(:lifetime_block_reader),
         true <- query =~ "matrix_session_ttl_seconds" do
      Process.delete(:lifetime_block_reader)
      send(pid, {:reader_blocked, self()})

      receive do
        :go -> :ok
      after
        20_000 -> :ok
      end
    else
      _ -> :ok
    end
  end

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
    Application.put_env(:nebu_http, :oauth_config_cache_clock_fn, fn -> :atomics.get(clock, 1) end)
    clear_cache()

    id = "stale-refill-" <> T.rand()
    :telemetry.attach(id, [:nebu, :repo, :query], &__MODULE__.handle_query/4, nil)

    on_exit(fn ->
      :telemetry.detach(id)
      restore(:oauth_config_cache_ms, prior_ttl)
      restore(:oauth_config_cache_clock_fn, prior_clock)
      Application.delete_env(:nebu_http, :oauth_config_repo)
      clear_cache()
      L.clear_audit_rows!()
    end)

    :ok
  end

  defp restore(key, {:ok, value}), do: Application.put_env(:nebu_http, key, value)
  defp restore(key, :error), do: Application.delete_env(:nebu_http, key)
  defp cache_ms(ms), do: Application.put_env(:nebu_http, :oauth_config_cache_ms, ms)
  defp clear_cache, do: if(:ets.whereis(@cache) != :undefined, do: :ets.delete_all_objects(@cache))
  defp ttl, do: SessionConfig.matrix_session_ttl_seconds()

  defp break_repo! do
    {:ok, pid} = Agent.start_link(fn -> :ok end, name: Nebu.OAuth.TestSupport.BrokenRepo)
    Application.put_env(:nebu_http, :oauth_config_repo, Nebu.OAuth.TestSupport.BrokenRepo)
    on_exit(fn -> if Process.alive?(pid), do: (try do Agent.stop(pid) catch :exit, _ -> :ok end) end)
  end

  defp save!(value) do
    conn = S.post("/admin/config/session-lifetime", %{"matrix_session_ttl_seconds" => value}, "/admin/config", ago: 10)
    assert conn.status in [302, 303]
  end

  # A reader that already READ the database (and saw `seen`) is parked; `during` runs while it is parked; then it is released. Returns what the reader answered.
  defp stale_read(during) do
    test_pid = self()

    task =
      Task.async(fn ->
        Process.put(:lifetime_block_reader, test_pid)
        ttl()
      end)

    assert_receive {:reader_blocked, reader}, 10_000
    during.()
    send(reader, :go)
    Task.await(task, 30_000)
  end

  describe "the last-known-good slot" do
    test "a stale read of the OLD, longer value (28800) does not overwrite the value saved meanwhile (3600)" do
      cache_ms(0)
      L.set_row!("28800")

      stale_read(fn ->
        save!("3600")
        assert L.row_value() == "3600"
      end)

      break_repo!()
      {value, _log} = with_log(fn -> ttl() end)
      assert value == 3600, "the failed read must answer the SAVED 3600, not the older 28800 that the parked reader wrote after the save"
    end

    test "a stale 'no row' answer does not clear the value saved meanwhile" do
      cache_ms(0)
      assert L.row_value() == nil

      stale_read(fn ->
        save!("3600")
        assert L.row_value() == "3600"
      end)

      break_repo!()
      {value, _log} = with_log(fn -> ttl() end)
      assert value == 3600, "LastGood.clear/0 of the parked reader (which saw no row) must not wipe the saved 3600"
    end

    test "control: a read that is NOT overtaken by a save still updates the last good value (the compare-and-set does not block honest refills)" do
      cache_ms(0)
      L.set_row!("28800")
      assert stale_read(fn -> :ok end) == 28_800

      break_repo!()
      {value, _log} = with_log(fn -> ttl() end)
      assert value == 28_800
    end
  end

  describe "the TTL cache" do
    test "a stale refill does not put the old config (28800) back into the cache entry the save just dropped" do
      cache_ms(2000)
      L.set_row!("28800")

      stale_read(fn -> save!("3600") end)

      assert ttl() == 3600, "the next read inside the TTL window must not be served the old 28800 by a refilled cache"
    end

    test "the same for a stale 'no row' answer (the old config carried no saved value)" do
      cache_ms(2000)

      stale_read(fn -> save!("3600") end)

      assert ttl() == 3600, "the cache must not be refilled with the config of a read that started before the save"
    end

    test "control: without a save in between the reader fills the cache (one query for the next call)" do
      cache_ms(2000)
      L.set_row!("28800")
      assert stale_read(fn -> :ok end) == 28_800

      L.set_row!("7200")
      assert ttl() == 28_800, "served from the cache the reader filled"
    end
  end
end
