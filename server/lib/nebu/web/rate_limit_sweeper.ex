defmodule Nebu.Web.RateLimitSweeper do
  @moduledoc """
  Periodic per-node eviction of idle rate-limit buckets (story oauth-trusted-proxy-client-ip,
  security review cycle 1, finding 2).

  Calls `Nebu.Web.Plugs.RateLimit.sweep_idle/0` every `:rate_limit_sweep_interval_ms`
  (default 10 minutes; `:infinity` = never, used by the test env so a background sweep cannot race
  tests that freeze the limiter clock). The bucket table is node-local ETS, so every node runs its
  own sweeper and no cluster coordination is needed (ADR-020: nothing here is correctness state; a
  missed sweep only keeps rows longer).

  ## Restart strategy

  The GenServer holds no state apart from its timer. The table is NOT owned by this process (it is
  created at boot by `Nebu.Web.Plugs.RateLimit.init_table/0` and lazily re-created by the limiter),
  so a crash of the sweeper loses nothing; the supervisor restarts it and `sweep_idle/0` re-creates
  the table if it vanished.
  """
  use GenServer

  require Logger

  @default_interval_ms 600_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @impl GenServer
  def init(opts) do
    interval = Keyword.get_lazy(opts, :interval_ms, &interval_ms/0)
    schedule(interval)
    {:ok, %{interval: interval}}
  end

  @impl GenServer
  def handle_info(:sweep, %{interval: interval} = state) do
    deleted = Nebu.Web.Plugs.RateLimit.sweep_idle()
    if deleted > 0, do: Logger.debug("RateLimit: evicted #{deleted} idle bucket(s)")
    schedule(interval)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp interval_ms, do: Application.get_env(:nebu_http, :rate_limit_sweep_interval_ms, @default_interval_ms)

  defp schedule(interval) when is_integer(interval) and interval > 0, do: Process.send_after(self(), :sweep, interval)
  defp schedule(_), do: :ok
end
