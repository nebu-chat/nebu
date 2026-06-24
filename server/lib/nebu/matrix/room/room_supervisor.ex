defmodule Nebu.Matrix.Room.RoomSupervisor do
  @moduledoc """
  Public API for starting and looking up Room GenServer processes.

  Wraps `Horde.DynamicSupervisor` and `Horde.Registry` to provide a clean
  interface for room lifecycle operations. Full room state management is added
  in Story 4-2.
  """

  @doc """
  Starts a Room GenServer for the given `room_id` under the Horde DynamicSupervisor.

  Returns `{:ok, pid}` on success. If the room is already running, returns
  `{:ok, pid}` of the existing process.
  """
  @spec start_room(String.t()) :: {:ok, pid()} | {:error, term()}
  def start_room(room_id) do
    case Horde.DynamicSupervisor.start_child(
           Nebu.Matrix.Room.HordeSupervisor,
           {Nebu.Matrix.Room.Server, room_id}
         ) do
      {:ok, pid} -> await_registry(room_id, pid)
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Starts a Room GenServer for a *brand-new* `room_id`, distinguishing a freshly
  started room from one that was already running.

  Unlike `start_room/1`, this collapses the `{:already_started, pid}` case into
  an explicit `{:error, :already_started, pid}` instead of `{:ok, pid}`. The
  create-room command path (`Nebu.Matrix.EventDispatcher.Server.create_room/2`)
  uses this so it can refuse to operate on a pre-existing room — its orphan
  cleanup hard-deletes events/members/row and must therefore only ever target a
  room this call actually created. For a freshly `generate_room_id/0`-d id the
  `:already_started` branch is practically impossible, but treating it as a
  conflict (rather than silently proceeding) is what makes the cleanup safe.

  Returns:
    * `{:ok, pid}` — a new Room GenServer was started for `room_id`.
    * `{:error, :already_started, pid}` — a Room GenServer was already running.
    * `{:error, reason}` — start failed.
  """
  @spec start_new_room(String.t()) ::
          {:ok, pid()} | {:error, :already_started, pid()} | {:error, term()}
  def start_new_room(room_id) do
    case Horde.DynamicSupervisor.start_child(
           Nebu.Matrix.Room.HordeSupervisor,
           {Nebu.Matrix.Room.Server, room_id}
         ) do
      {:ok, pid} ->
        case await_registry(room_id, pid) do
          {:ok, pid} -> {:ok, pid}
          other -> other
        end

      {:error, {:already_started, pid}} ->
        {:error, :already_started, pid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Horde.Registry uses CRDT replication — the pid may not be visible via lookup
  # immediately after start_child returns. Poll until the entry appears (max 500 ms).
  defp await_registry(room_id, pid, retries \\ 100) do
    case Horde.Registry.lookup(Nebu.Matrix.Room.Registry, room_id) do
      [{^pid, _}] ->
        {:ok, pid}

      _ when retries > 0 ->
        Process.sleep(5)
        await_registry(room_id, pid, retries - 1)

      _ ->
        {:error, :registry_timeout}
    end
  end

  @doc """
  Looks up the PID of a running Room GenServer for the given `room_id`.

  Returns `{:ok, pid}` if the room process is running, or `{:error, :not_found}`
  if no process is registered under `room_id`.
  """
  @spec lookup_room(String.t()) :: {:ok, pid()} | {:error, :not_found}
  def lookup_room(room_id) do
    case Horde.Registry.lookup(Nebu.Matrix.Room.Registry, room_id) do
      [{pid, _value}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end
end
