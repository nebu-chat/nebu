defmodule Nebu.Web.LogStore.Writer do
  @moduledoc """
  Non-blocking, batching writer GenServer for the operational log store
  (enhanced-logging/operational-log-store, AC6/AC7/AC11).

  Mirrors the `Nebu.Matrix.Session.Sweeper` pattern: entries are queued via a
  cheap `GenServer.cast/2` (`write_async/1`), buffered in process state, and
  flushed to `operational_logs` via a single batched multi-row `INSERT` —
  either periodically (every `@flush_interval_ms`) or once the buffer reaches
  `@flush_threshold` entries, whichever comes first.

  Let-it-crash, but SCOPED: a flush that fails (e.g. a DB constraint
  violation, or `Nebu.Repo` being unreachable) is caught and logged at WARN —
  it must NEVER crash this GenServer itself (AC6's "writer survives INSERT
  failures"). A genuine `Process.exit(pid, :kill)` (or any other real crash
  outside a flush attempt) is a DIFFERENT matter: this process is started as
  a normal supervised child of `Nebu.Application` (`:permanent`, the
  `Supervisor` default), so the supervisor restarts it under the same
  registered name — "let-it-crash, natural backpressure" per AC6's own design
  language.

  ## Bounded single-row fallback on batch failure (code-review N1)

  `flush_buffer/1` normally issues ONE multi-row `INSERT` for the whole
  buffer (up to `@flush_threshold` entries). If that batched INSERT fails
  (e.g. one entry violates a `NOT NULL`/other constraint), retrying the
  WHOLE batch would just fail again identically — but silently dropping ALL
  co-batched entries (as the previous implementation did) loses up to 99
  perfectly good, unrelated rows because of a single bad one. Instead, on a
  batch failure, each entry is retried as its OWN single-row INSERT; only
  the individually-failing row(s) are dropped (and logged at WARN), every
  other entry in the same flush still lands. Deliberately simple — this is
  best-effort diagnostic data, not something warranting elaborate
  retry/backoff.

  ## `war_room_id` (enhanced-logging/war-room-mode)

  This module's own moduledoc previously suggested `war_room_id`
  budget-counting/assignment would attach here, in `flush_buffer/1`, before
  the INSERT. That turned out to be wrong for correctness (see
  `war-room-mode/design-decisions.md` #3): the match/tag/budget-check must
  happen synchronously, per-entry, in `Nebu.Web.LogStore.Handler.log/2`
  (via `Nebu.Web.LogStore.WarRoom.check/1`) — BEFORE the
  `should_persist?/1` gate, not deferred into this Writer's batched flush.
  By the time an entry reaches here, `entry[:war_room_id]` (if any) is
  already set — this module only needs to carry that column through to the
  INSERT, which is all `@columns`/`row_values/1` below do.
  """

  use GenServer

  require Logger

  @flush_interval_ms 5_000
  @flush_threshold 100

  @columns ~w(level source route_template request_id message metadata war_room_id)a

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc """
  Queues `entry` for batched insertion. Non-blocking (`GenServer.cast/2`) —
  safe to call even when the Writer is not currently running/registered (a
  cast to an unregistered name is a silent no-op, never raises), so callers
  (the central `:logger` handler) never need their own defensive guard.
  """
  @spec write_async(map()) :: :ok
  def write_async(entry) do
    GenServer.cast(__MODULE__, {:write, entry})
  end

  @impl true
  def init(:ok) do
    schedule_flush()
    {:ok, %{buffer: []}}
  end

  @impl true
  def handle_cast({:write, entry}, state) do
    new_buffer = [entry | state.buffer]

    if length(new_buffer) >= @flush_threshold do
      flush_buffer(new_buffer)
      {:noreply, %{state | buffer: []}}
    else
      {:noreply, %{state | buffer: new_buffer}}
    end
  end

  def handle_cast(_other, state), do: {:noreply, state}

  @impl true
  def handle_info(:flush, state) do
    flush_buffer(state.buffer)
    schedule_flush()
    {:noreply, %{state | buffer: []}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp schedule_flush, do: Process.send_after(self(), :flush, @flush_interval_ms)

  defp flush_buffer([]), do: :ok

  defp flush_buffer(entries) do
    insert_batch(entries)
    :ok
  rescue
    error ->
      Logger.warning(
        "Nebu.Web.LogStore.Writer batch INSERT of #{length(entries)} entries to " <>
          "operational_logs failed (#{inspect(error)}) — retrying as individual " <>
          "single-row inserts so only genuinely bad row(s) are lost, not the whole batch"
      )

      insert_individually(entries)
      :ok
  end

  # code-review N1: bounded fallback — one INSERT per entry, so a single
  # malformed row does not take down the other (up to 99) good rows in the
  # same co-batched flush. Each row failure is caught and logged
  # independently; never re-raises (this is called from the already-rescuing
  # `flush_buffer/1`, and must not crash the GenServer either).
  defp insert_individually(entries) do
    Enum.each(entries, fn entry ->
      try do
        insert_batch([entry])
      rescue
        row_error ->
          Logger.warning(
            "Nebu.Web.LogStore.Writer dropped one entry after its individual-insert " <>
              "fallback also failed: #{inspect(row_error)}"
          )
      end
    end)
  end

  defp insert_batch(entries) do
    {values_sql, params} =
      entries
      |> Enum.reverse()
      |> Enum.with_index()
      |> Enum.map_reduce([], fn {entry, idx}, params_acc ->
        base = idx * length(@columns)
        placeholders = Enum.map(1..length(@columns), fn n -> "$#{base + n}" end)
        row_sql = "(" <> Enum.join(placeholders, ", ") <> ")"
        {row_sql, params_acc ++ row_values(entry)}
      end)

    sql =
      "INSERT INTO operational_logs (#{Enum.join(@columns, ", ")}) VALUES " <>
        Enum.join(values_sql, ", ")

    Ecto.Adapters.SQL.query!(Nebu.Repo, sql, params)
  end

  defp row_values(entry) do
    [
      Map.get(entry, :level),
      Map.get(entry, :source) || "unknown",
      Map.get(entry, :route_template),
      Map.get(entry, :request_id),
      Map.get(entry, :message),
      Map.get(entry, :metadata),
      Map.get(entry, :war_room_id)
    ]
  end
end
