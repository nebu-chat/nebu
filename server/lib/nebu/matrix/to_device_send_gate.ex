defmodule Nebu.Matrix.ToDeviceSendGate do
  @moduledoc """
  The slots of the to-device SENDS (`PUT /sendToDevice/{eventType}/{txnId}`; story to-device-messaging): at most `max_per_user/0` sends in flight per user (default 4,
  `config :nebu, :to_device_max_concurrent_sends_per_user`) and at most `max_per_node/0` on this node (default 6, below the pool of 10 connections, `:to_device_max_concurrent_sends_per_node`), both read
  per admission. A rate limit is not a concurrency limit: this bounds the memory of the bodies being parsed and fanned out and the pooled connections a burst of
  accounts can occupy at once, and no single user can take the node's slots (cross-user starvation).

  Node-local by design, like the rate tiers (documented: N x the limit in a cluster). A supervised GenServer: a holder is a MONITORED request process, its slot is freed by
  `run/2` and, when the process is killed in flight, on its `:DOWN`. A sender that finds no slot is refused at once (the caller answers 429 before the body is read).
  """
  use GenServer

  @default_per_user 4
  @default_per_node 6

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @spec max_per_user() :: pos_integer()
  def max_per_user, do: positive(:to_device_max_concurrent_sends_per_user, @default_per_user)

  @spec max_per_node() :: pos_integer()
  def max_per_node, do: positive(:to_device_max_concurrent_sends_per_node, @default_per_node)

  defp positive(key, default) do
    case Application.get_env(:nebu, key, default) do
      n when is_integer(n) and n > 0 -> n
      _ -> default
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
    GenServer.call(__MODULE__, {:acquire, user_id, self(), max_per_user(), max_per_node()}, 5_000)
  catch
    :exit, {:timeout, _} ->
      GenServer.cast(__MODULE__, {:cancel, self()})
      :overflow

    :exit, _reason ->
      :overflow
  end

  @impl GenServer
  def init(:ok), do: {:ok, %{holders: %{}}}

  @impl GenServer
  def handle_call({:acquire, user_id, pid, per_user, per_node}, _from, state) do
    user_count = Enum.count(state.holders, fn {_slot, {user, _pid}} -> user == user_id end)

    if user_count >= per_user or map_size(state.holders) >= per_node do
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
