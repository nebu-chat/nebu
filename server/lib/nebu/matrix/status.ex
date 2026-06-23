defmodule Nebu.Matrix.Status do
  @moduledoc """
  Canonical status codes for the in-process Matrix command layer
  (`Nebu.Matrix.EventDispatcher.Server`).

  Native replacement for `GRPC.Status.*` (epic `grpc-removal`, ADR-021). The
  command layer was historically a gRPC service; after the Go gateway was removed
  the handlers are called in-process by the Matrix HTTP routers, so the gRPC
  status integers carried no meaning beyond "a tag the HTTP layer maps to a
  Matrix error". These functions return plain atoms instead — same names as the
  old `GRPC.Status.*` helpers so call sites read identically — and
  `Nebu.Matrix.Http.call_core/1` maps them to `{http_status, errcode, message}`
  tuples (the Go gateway's status switch).

  A handler signals an error by raising `Nebu.Matrix.Error` with one of these as
  its `:status`.
  """

  @type t ::
          :ok
          | :invalid_argument
          | :not_found
          | :already_exists
          | :permission_denied
          | :resource_exhausted
          | :failed_precondition
          | :unauthenticated
          | :unavailable
          | :internal

  @spec ok() :: :ok
  def ok, do: :ok

  @spec invalid_argument() :: :invalid_argument
  def invalid_argument, do: :invalid_argument

  @spec not_found() :: :not_found
  def not_found, do: :not_found

  @spec already_exists() :: :already_exists
  def already_exists, do: :already_exists

  @spec permission_denied() :: :permission_denied
  def permission_denied, do: :permission_denied

  @spec resource_exhausted() :: :resource_exhausted
  def resource_exhausted, do: :resource_exhausted

  @spec failed_precondition() :: :failed_precondition
  def failed_precondition, do: :failed_precondition

  @spec unauthenticated() :: :unauthenticated
  def unauthenticated, do: :unauthenticated

  @spec unavailable() :: :unavailable
  def unavailable, do: :unavailable

  @spec internal() :: :internal
  def internal, do: :internal
end
