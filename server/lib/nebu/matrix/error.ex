defmodule Nebu.Matrix.Error do
  @moduledoc """
  Error raised by the in-process Matrix command layer
  (`Nebu.Matrix.EventDispatcher.Server`) to signal a failure with a status the
  HTTP layer maps to a Matrix error envelope.

  Native replacement for `GRPC.RPCError` (epic `grpc-removal`, ADR-021). It is a
  plain exception with the same two fields the old `%GRPC.RPCError{}` carried, so
  raise/rescue sites read identically:

      raise Nebu.Matrix.Error, status: Nebu.Matrix.Status.not_found(), message: "Room not found"

      # or, struct form:
      raise %Nebu.Matrix.Error{status: :permission_denied, message: "..."}

  `Nebu.Matrix.Http.call_core/1` rescues this and maps `:status`
  (a `Nebu.Matrix.Status.t/0` atom) to `{http_status, errcode, message}`.

  The optional `:errcode` (story `create-room-input-validation`, D6) names a specific Matrix errcode for a
  `:invalid_argument` error (e.g. `"M_UNSUPPORTED_ROOM_VERSION"`, `"M_ROOM_IN_USE"`, `"M_BAD_ALIAS"`,
  `"M_BAD_JSON"`): `call_core/1` then answers `{400, errcode, message}`. It defaults to `nil`, and every error
  without it maps exactly as before. For `:permission_denied` the `errcode` and `message` are honoured the same
  way (story `create-room-presets-power-levels-topic`, D1: the two fixed join refusal texts). The `message` of such an error reaches the client: fixed text, never a
  client-supplied value.
  """

  @type t :: %__MODULE__{status: Nebu.Matrix.Status.t(), message: String.t(), errcode: String.t() | nil}

  defexception status: :internal, message: "Internal server error", errcode: nil
end
