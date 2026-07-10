defmodule Nebu.Matrix.Session.Sweeper do
  @moduledoc """
  Periodic best-effort eviction of expired auth rows (story s3-matrix-device-endpoints).

  Two tables grow with login activity and must be swept so they do not accumulate
  dead rows forever:

    * `jwt_device_bindings` — a row whose `exp` (the verified JWT's expiry, unix
      seconds) has passed can never resolve a live token again (OidcPlug rejects an
      expired JWT before reaching the binding), so it is deleted. Rows with a NULL
      `exp` (written before migration 000012) are left untouched.
    * `uia_sessions` — single-use UIA challenges whose `expires_at` has passed.

  Cluster note (ADR-020): the sweep is idempotent `DELETE … WHERE expires < now`,
  so every node running it converges on the same result; no coordination needed.
  let-it-crash: a failed sweep just logs and retries next tick (the supervisor
  restarts the process if it ever dies).
  """
  use GenServer

  # Hourly — these tables churn slowly and lazy expiry already keeps reads correct,
  # so the sweep is purely about bounding table size.
  @interval_ms 60 * 60 * 1000

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    schedule()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep()
    schedule()
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp sweep do
    now = System.system_time(:second)

    _ = safe_query("DELETE FROM jwt_device_bindings WHERE exp IS NOT NULL AND exp < $1", [now])
    _ = Nebu.Matrix.Uia.cleanup_expired()
    # enhanced-logging/operational-log-store (AC8): per-level TTL + DEBUG
    # max-count pruning of operational_logs, same hourly cadence as the
    # sweeps above.
    _ = Nebu.Web.LogStore.Retention.prune_operational_logs()
    :ok
  end

  defp schedule, do: Process.send_after(self(), :sweep, @interval_ms)

  defp safe_query(sql, params) do
    if Process.whereis(Nebu.Repo) do
      Ecto.Adapters.SQL.query(Nebu.Repo, sql, params)
    else
      {:error, :repo_not_started}
    end
  rescue
    e -> {:error, e}
  end
end
