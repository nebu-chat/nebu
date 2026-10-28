defmodule Nebu.Matrix.MemberSliceGate do
  @moduledoc """
  The node-wide concurrency limit of the member-state reads (`Room.DB.member_state_slice/2`; story membership-state-model,
  security cycles 2 and 3, D19, Kassandra M-1R / M-3): at most `max_concurrency/0` slice reads run at the same time on ONE node
  (default 3, so they hold at most 3 of the 10 pool checkouts, whatever route triggers them: `/members`, `/initialSync`, every
  kind of `/sync`). Node-local by design, like the rate tiers: N nodes allow N times the limit.

  A supervised GenServer (a child of `Nebu.Application`) admits the readers EXACTLY: the number of holders is the number of live,
  MONITORED reader processes. A holder frees its slot in the `after` of `run/2` and, when it is killed during the read, on its
  `:DOWN` at once. A reader that finds the gate full is refused at once (`wait_ms` 0: `/members`, `/initialSync`) or waits in a
  FIFO queue until a slot is handed to it or its `wait_ms` deadline passes (a timer of the gate answers `:overflow` and removes
  it; no polling). The queue is bounded (4 x the limit): beyond it a reader is refused at once. A single reader is never
  refused. A gate that is not running answers `:overflow` (the callers fail closed: the `/sync` room is degraded, `/members` /
  `/initialSync` answer 503).

  The limit comes from `Application.get_env(:nebu, :member_slice_max_concurrency)` (read per admission; a strictly positive
  integer, else the default), filled by `config/runtime.exs` from `NEBU_MEMBER_SLICE_MAX_CONCURRENCY`; `warn_invalid_setting/0`
  logs one value-free warning at boot when that variable is invalid or the limit is not below the pool size.
  """
  use GenServer
  require Logger

  @default 3
  @queue_factor 4
  @env "NEBU_MEMBER_SLICE_MAX_CONCURRENCY"
  # the call outlives the caller's own deadline: the gate answers every waiter itself (a grant or :overflow)
  @call_margin_ms 5_000

  # ─── API ───────────────────────────────────────────────────────────────────────────────────────────────────────────

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "The limit: the configured strictly positive integer, else #{@default}."
  @spec max_concurrency() :: pos_integer()
  def max_concurrency do
    case Application.get_env(:nebu, :member_slice_max_concurrency) do
      n when is_integer(n) and n > 0 -> n
      _ -> @default
    end
  end

  @doc """
  Runs `fun` in the calling process once a slot is held: `{:ok, result}`; `:overflow` when the gate is full and stays full for
  `wait_ms` (0: refused at once), the queue is full, or the gate is not running. An exception of `fun` is re-raised after the
  slot was released.
  """
  @spec run((-> result), non_neg_integer()) :: {:ok, result} | :overflow when result: term()
  def run(fun, wait_ms \\ 0) when is_function(fun, 0) and is_integer(wait_ms) and wait_ms >= 0 do
    case acquire(wait_ms) do
      {:ok, slot} ->
        try do
          {:ok, fun.()}
        after
          GenServer.cast(__MODULE__, {:release, slot})
        end

      :overflow ->
        :overflow
    end
  end

  defp acquire(wait_ms) do
    GenServer.call(__MODULE__, {:acquire, self(), wait_ms}, wait_ms + @call_margin_ms)
  catch
    # not answering in time: fail closed AND cancel, so that a late grant does not stay held by this (possibly long-lived
    # keep-alive connection) process; the cast arrives after this process's {:acquire, ...} (one sender: in order)
    :exit, {:timeout, _} ->
      GenServer.cast(__MODULE__, {:cancel, self()})
      :overflow

    # not running: fail closed
    :exit, _reason ->
      :overflow
  end

  @doc """
  Logs ONE value-free warning (the variable name only) when `NEBU_MEMBER_SLICE_MAX_CONCURRENCY` is set to something invalid, and
  one when the effective limit is not below the Repo pool size (the member reads could then take every connection).
  """
  @spec warn_invalid_setting() :: :ok
  def warn_invalid_setting do
    value = System.get_env(@env, "")

    valid? =
      case Integer.parse(value) do
        {n, ""} -> n > 0 and n <= 9_223_372_036_854_775_807
        _ -> false
      end

    if value != "" and not valid? do
      Logger.warning("#{@env} is not a strictly positive integer: the default limit of #{@default} concurrent member-state reads per node applies")
    end

    pool_size = Keyword.get(Application.get_env(:nebu, Nebu.Repo) || [], :pool_size, 10)

    if is_integer(pool_size) and max_concurrency() >= pool_size do
      Logger.warning("#{@env}: the limit of concurrent member-state reads is not below the database pool size: keep it well below")
    end

    :ok
  end

  # ─── server ────────────────────────────────────────────────────────────────────────────────────────────────────────

  @impl GenServer
  def init(:ok), do: {:ok, %{holders: %{}, queue: :queue.new()}}

  @impl GenServer
  def handle_call({:acquire, pid, wait_ms}, from, state) do
    limit = max_concurrency()

    cond do
      map_size(state.holders) < limit and :queue.is_empty(state.queue) ->
        {slot, state} = grant(state, pid)
        {:reply, {:ok, slot}, state}

      wait_ms == 0 or :queue.len(state.queue) >= @queue_factor * limit ->
        {:reply, :overflow, state}

      true ->
        ref = make_ref()
        timer = Process.send_after(self(), {:expire, ref}, wait_ms)
        {:noreply, %{state | queue: :queue.in({ref, from, pid, timer}, state.queue)}}
    end
  end

  @impl GenServer
  def handle_cast({:release, slot}, state) do
    Process.demonitor(slot, [:flush])
    {:noreply, state |> free(slot) |> admit_waiters()}
  end

  def handle_cast({:cancel, pid}, state) do
    {cancelled, waiting} = Enum.split_with(:queue.to_list(state.queue), fn {_ref, _from, waiter, _timer} -> waiter == pid end)
    for {_ref, _from, _pid, timer} <- cancelled, do: Process.cancel_timer(timer)

    held = for {slot, ^pid} <- state.holders, do: slot
    for slot <- held, do: Process.demonitor(slot, [:flush])

    state = %{state | queue: :queue.from_list(waiting), holders: Map.drop(state.holders, held)}
    {:noreply, admit_waiters(state)}
  end

  @impl GenServer
  def handle_info({:DOWN, slot, :process, _pid, _reason}, state), do: {:noreply, state |> free(slot) |> admit_waiters()}

  def handle_info({:expire, ref}, state) do
    {expired, waiting} = Enum.split_with(:queue.to_list(state.queue), fn {r, _from, _pid, _timer} -> r == ref end)
    for {_ref, from, _pid, _timer} <- expired, do: GenServer.reply(from, :overflow)
    {:noreply, %{state | queue: :queue.from_list(waiting)}}
  end

  def handle_info(_unexpected, state) do
    Logger.debug("member slice gate: an unexpected message was ignored")
    {:noreply, state}
  end

  defp grant(state, pid) do
    slot = Process.monitor(pid)
    {slot, %{state | holders: Map.put(state.holders, slot, pid)}}
  end

  defp free(state, slot), do: %{state | holders: Map.delete(state.holders, slot)}

  # FIFO: the oldest waiter gets the next free slot (a waiter whose process died meanwhile is granted and then freed by its :DOWN)
  defp admit_waiters(state) do
    with true <- map_size(state.holders) < max_concurrency(),
         {{:value, {_ref, from, pid, timer}}, queue} <- :queue.out(state.queue) do
      Process.cancel_timer(timer)
      {slot, state} = grant(%{state | queue: queue}, pid)
      GenServer.reply(from, {:ok, slot})
      admit_waiters(state)
    else
      _ -> state
    end
  end
end
