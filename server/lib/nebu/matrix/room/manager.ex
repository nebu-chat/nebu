defmodule Nebu.Matrix.Room.Manager do
  @moduledoc """
  Room Manager — high-level room management facade.

  Delegates to `Nebu.Matrix.Room.RoomSupervisor` for process start/lookup operations.
  Extended with room state management in Story 4-2.
  """

  defdelegate start_room(room_id), to: Nebu.Matrix.Room.RoomSupervisor
  defdelegate lookup_room(room_id), to: Nebu.Matrix.Room.RoomSupervisor
end
