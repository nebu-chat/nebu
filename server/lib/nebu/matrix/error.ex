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
  """

  @type t :: %__MODULE__{status: Nebu.Matrix.Status.t(), message: String.t()}

  defexception status: :internal, message: "Internal server error"
end
