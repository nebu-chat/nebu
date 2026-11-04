defmodule Nebu.Matrix.RoomKeysReadGate do
  @moduledoc """
  The slots of the BULK key reads (`GET /room_keys/keys`, `GET /room_keys/keys/{roomId}`; story server-side-key-backup, cycle 2): at most ONE bulk read in
  flight per user and at most `max_per_node/0` (default 2, `config :nebu, :room_keys_max_concurrent_bulk_reads_per_node`, read per admission) on this node.
  Node-local by design, like the rate tiers. A supervised GenServer: a holder is a MONITORED request process, its slots are freed by `run/2` and, when the
  process is killed during the read, on its `:DOWN`. A reader that finds no slot is refused at once (the caller answers 429 before any database work).
  """
  use GenServer

  @default_per_node 2

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @spec max_per_node() :: pos_integer()
  def max_per_node do
    case Application.get_env(:nebu, :room_keys_max_concurrent_bulk_reads_per_node, @default_per_node) do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_per_node
    end
  end

  @doc "Runs `fun` in the calling process while a slot of `user_id` is held: `{:ok, result}` or `:overflow`."
  @spec run(String.t() | nil, (-> result)) :: {:ok, result} | :overflow when result: term()
  def run(user_id, fun) when is_function(fun, 0) do
    case acquire(user_id) do
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

  defp acquire(user_id) do
    GenServer.call(__MODULE__, {:acquire, user_id, self()}, 5_000)
  catch
    # not answering in time: fail closed AND cancel, so that a late grant is not held by this (possibly long-lived keep-alive connection) process; the
    # cast arrives after this process's `{:acquire, ..}` (one sender: in order)
    :exit, {:timeout, _} ->
      GenServer.cast(__MODULE__, {:cancel, self()})
      :overflow

    # not running: fail closed
    :exit, _reason ->
      :overflow
  end

  @impl GenServer
  def init(:ok), do: {:ok, %{holders: %{}}}

  @impl GenServer
  def handle_call({:acquire, user_id, pid}, _from, state) do
    busy_user? = Enum.any?(state.holders, fn {_slot, {user, _pid}} -> user == user_id end)

    if busy_user? or map_size(state.holders) >= max_per_node() do
      {:reply, :overflow, state}
    else
      slot = Process.monitor(pid)
      {:reply, {:ok, slot}, %{state | holders: Map.put(state.holders, slot, {user_id, pid})}}
    end
  end

  @impl GenServer
  def handle_cast({:release, slot}, state) do
    Process.demonitor(slot, [:flush])
    {:noreply, %{state | holders: Map.delete(state.holders, slot)}}
  end

  def handle_cast({:cancel, pid}, state) do
    {gone, kept} = Enum.split_with(state.holders, fn {_slot, {_user, holder}} -> holder == pid end)
    Enum.each(gone, fn {slot, _holder} -> Process.demonitor(slot, [:flush]) end)
    {:noreply, %{state | holders: Map.new(kept)}}
  end

  @impl GenServer
  def handle_info({:DOWN, slot, :process, _pid, _reason}, state), do: {:noreply, %{state | holders: Map.delete(state.holders, slot)}}
  def handle_info(_other, state), do: {:noreply, state}
end
