defmodule Nebu.Matrix.RequestMetadata do
  @moduledoc """
  Extracts the trusted caller identity (x-user-id / x-system-role) from the
  in-process request-context map built by `Nebu.Matrix.Http.stream/1`.

  These headers are pre-validated trusted identity: the HTTP layer (Bandit + Plug)
  verifies the OIDC token and injects `x-user-id` / `x-system-role` into the
  request-context map before passing it into the EventDispatcher handlers. Elixir
  trusts these values fully — no re-validation at the handler level.

  The argument is a plain map of the form `%{http_request_headers: %{...}}`, never
  a real gRPC struct.
  """

  @user_id_key "x-user-id"
  @system_role_key "x-system-role"
  @default_role "user"

  @doc "Returns x-user-id from the request-context map, or nil if absent."
  @spec user_id(map()) :: String.t() | nil
  def user_id(stream), do: get_header(stream, @user_id_key)

  @doc "Returns x-system-role from the request-context map. Defaults to \"user\" if absent."
  @spec system_role(map()) :: String.t()
  def system_role(stream), do: get_header(stream, @system_role_key) || @default_role

  @doc "Returns {user_id, system_role} tuple. system_role defaults to \"user\" if absent."
  @spec trusted_identity(map()) :: {String.t() | nil, String.t()}
  def trusted_identity(stream), do: {user_id(stream), system_role(stream)}

  defp get_header(stream, key) do
    Map.get(stream.http_request_headers, key)
  end
end
