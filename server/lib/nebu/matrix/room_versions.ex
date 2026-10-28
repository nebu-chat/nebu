defmodule Nebu.Matrix.RoomVersions do
  @moduledoc """
  The single source of truth for the room versions Nebu supports (story `create-room-input-validation`, D1).

  Nebu implements ONE rule set, so it can create exactly one room version: `"10"`. `GET /capabilities`
  advertises exactly this list, `POST /createRoom` and `POST /rooms/{id}/upgrade` answer
  `400 M_UNSUPPORTED_ROOM_VERSION` for every other string. The Matrix spec SHOULD default is v12; Nebu's `"10"`
  is a documented deviation (v12 changes room ids and the creator power level).

  Pure module, no state: cluster-safe.
  """

  @default "10"
  @supported [@default]

  @doc "The version of a room created without an explicit `room_version`."
  @spec default() :: String.t()
  def default, do: @default

  @doc "All room versions Nebu can create."
  @spec supported() :: [String.t()]
  def supported, do: @supported

  @doc "True when `version` is a supported room version string (exact match, no normalisation)."
  @spec supported?(term()) :: boolean()
  def supported?(version) when is_binary(version), do: version in @supported
  def supported?(_other), do: false

  @doc "The `m.room_versions` capability: the default plus the available versions (`stable`)."
  @spec capability() :: %{String.t() => term()}
  def capability do
    %{"default" => @default, "available" => Map.new(@supported, &{&1, "stable"})}
  end
end
