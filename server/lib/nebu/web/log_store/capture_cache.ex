defmodule Nebu.Web.LogStore.CaptureCache do
  @moduledoc """
  Lock-free, node-local cache of which off-list endpoints currently have an
  ACTIVE temporary capture (enhanced-logging/trace-map-node-controls,
  AC4/AC5), backed by `:persistent_term` and refreshed periodically by this
  GenServer — the exact `Nebu.Web.LogStore.PolicyCache` /
  `Nebu.Web.LogStore.WarRoom` precedent.

  ## Why this exists

  `Nebu.Web.LogStore.should_persist?/2` is called from
  `Nebu.Web.LogStore.Handler.log/2`, which runs SYNCHRONOUSLY in the
  arbitrary calling process for EVERY `Logger.*` call app-wide — including
  from within `Nebu.Repo.QueryTelemetry`'s own logging, which fires from
  inside an Ecto query's telemetry callback (see `PolicyCache`'s moduledoc
  for the exact connection-pool deadlock this already caused once). A live
  `Ecto.Adapters.SQL.query!/3` against `admin_temporary_captures` on that
  hot path would risk the same class of bug. This cache keeps the
  persistence-decision path a pure, in-memory, non-blocking read.

  `active?/1` is safe to call even when this process is not running (e.g.
  plain unit test runs with no DB): `:persistent_term.get/2`'s default
  clause returns an empty set (no active captures).

  ## This process does NOT call `TemporaryCaptureManager.cleanup_expired/0`

  Code review (2026-07-08, MINOR-1): the periodic `handle_info(:refresh,
  ...)` tick below only re-reads `active_captures/0` (already
  `expires_at > now()`-filtered at the SQL level) — it never deletes
  expired rows. Wiring `cleanup_expired/0` into this GenServer's own
  refresh would self-deadlock: `cleanup_expired/0` ends by calling
  `refresh_now/0`, which is a `GenServer.call/2` into THIS process — called
  from inside this process's own `handle_info/2`, that blocks forever.
  Expired-row cleanup is a manual, unscheduled hygiene helper (see its own
  moduledoc) — never load-bearing for correctness, since `active?/1` and
  `active_captures/0` already treat an unswept expired row as inactive.
  """

  use GenServer

  require Logger

  @cache_key :nebu_log_store_capture_cache
  @refresh_interval_ms 2_000

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc """
  Whether `endpoint` currently has an active temporary capture, per the
  cached snapshot (refreshed every #{@refresh_interval_ms}ms, and forced
  synchronously on every `Nebu.Admin.TemporaryCaptureManager` write via
  `refresh_now/0`). NEVER touches the DB itself.
  """
  @spec active?(String.t()) :: boolean()
  def active?(endpoint) when is_binary(endpoint) do
    MapSet.member?(:persistent_term.get(@cache_key, MapSet.new()), endpoint)
  end

  def active?(_endpoint), do: false

  @doc """
  Forces an immediate, synchronous refresh from the DB. Called by
  `Nebu.Admin.TemporaryCaptureManager`'s `enable/2`/`disable/2`/
  `cleanup_expired/0` so `should_persist?/2` reflects the change on the
  VERY NEXT `Logger.*` call — no waiting for the periodic tick. Safe no-op
  when this process is not currently running.
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
    endpoints =
      Nebu.Admin.TemporaryCaptureManager.active_captures()
      |> MapSet.new(& &1.endpoint)

    :persistent_term.put(@cache_key, endpoints)
    :ok
  rescue
    e ->
      Logger.warning("Nebu.Web.LogStore.CaptureCache failed to refresh: #{inspect(e)}")
      :ok
  end
end
