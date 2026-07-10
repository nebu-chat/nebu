defmodule Nebu.Web.LogStore.PolicyCache do
  @moduledoc """
  Lock-free, node-local cache of `Nebu.Web.LogStore`'s admin-configurable
  logging policy, backed by `:persistent_term` and refreshed periodically by
  this GenServer.

  ## Why this exists (integration-test-uncovered deadlock)

  `Nebu.Web.LogStore.Handler.log/2` runs SYNCHRONOUSLY, in the arbitrary
  calling process, for EVERY `Logger.*` call app-wide (AC2) — including
  `Nebu.Repo.QueryTelemetry`'s own `Logger.debug/1` call, which fires from
  WITHIN the telemetry callback of an Ecto query, in the SAME process that
  is using (or just used) a `Nebu.Repo` connection checkout. If
  `Nebu.Web.LogStore.should_persist?/1` read the policy via a live
  `Ecto.Adapters.SQL.query!/3` call synchronously on that path, it re-entered
  `Nebu.Repo`'s connection pool from inside another query's completion
  callback — observed as a genuine connection-pool timeout in the
  integration suite (`Nebu.Repo.QueryTelemetryTest` hung for 60s) before this
  cache was introduced. This module keeps `Handler.log/2`'s
  persistence-decision path a pure, in-memory, non-blocking read — no
  `Nebu.Repo` call at all on that hot path.

  Started as a supervised child alongside `Nebu.Web.LogStore.Writer` (same
  `repo_children/0` gating — nothing to cache without a DB either).
  `get/0` is safe to call even when this process is not running (e.g. plain
  unit test runs with no DB): `:persistent_term.get/2`'s default clause
  returns conservative fallback defaults (INFO/DEBUG collection disabled).
  """

  use GenServer

  require Logger

  @cache_key :nebu_log_store_policy_cache
  @refresh_interval_ms 2_000

  @defaults %{
    log_collect_info: false,
    log_retention_info_days: nil,
    log_retention_info_max_count: nil,
    log_collect_debug: false,
    log_retention_debug_days: nil,
    log_retention_debug_max_count: nil
  }

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc """
  Returns the cached policy map. NEVER touches the DB. Returns conservative
  defaults (INFO/DEBUG collection disabled) if the cache has not been
  populated yet (e.g. immediately after boot, before the first refresh
  tick, or when this process has never been started at all).
  """
  @spec get() :: map()
  def get, do: :persistent_term.get(@cache_key, @defaults)

  @doc """
  Forces an immediate, synchronous refresh from the DB. Called by
  `Nebu.Admin.DB.upsert_server_config/1` (via `Nebu.Web.LogStore`) whenever a
  change touches one of the 5 log-policy keys, so `should_persist?/1`
  reflects the new value on the VERY NEXT `Logger.*` call — no waiting for
  the periodic refresh tick (AC7's "flip the policy, next call persists"
  requirement). Safe no-op when this process is not currently running (e.g.
  a plain unit test with no DB).
  """
  @spec refresh_now() :: :ok
  def refresh_now do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, :refresh_now)
    else
      :ok
    end
  end

  @impl true
  def init(:ok) do
    refresh()
    schedule_refresh()
    {:ok, %{}}
  end

  @impl true
  def handle_call(:refresh_now, _from, state) do
    refresh()
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:refresh, state) do
    refresh()
    schedule_refresh()
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp schedule_refresh, do: Process.send_after(self(), :refresh, @refresh_interval_ms)

  defp refresh do
    policy = Nebu.Web.LogStore.read_policy_from_db()
    :persistent_term.put(@cache_key, policy)
    :ok
  rescue
    e ->
      Logger.warning("Nebu.Web.LogStore.PolicyCache failed to refresh: #{inspect(e)}")
      :ok
  end
end
