defmodule Nebu.Session.TokenValidator do
  @moduledoc """
  Validates a user's identity for the ValidateToken gRPC handler.

  Orchestrates: user lookup → provision if new → decrypt display_name → return user data.
  Returns {:ok, user_map} or {:error, :deactivated} or {:error, reason}.

  Delegates to a configurable module for testability.
  Real implementation: Nebu.Session.TokenValidator.Postgres
  Test implementation: configured via Application.put_env in test setup.
  """

  # Story admin-auto-join-rooms: is_new = true on first-ever login, false on re-login.
  # Absent (not in map) is treated as false in Server.validate_token/2.
  @type user_data :: %{
          required(:user_id) => String.t(),
          required(:system_role) => String.t(),
          required(:display_name) => String.t(),
          required(:is_active) => boolean(),
          optional(:is_new) => boolean()
        }

  @callback validate(
              user_id :: String.t(),
              system_role :: String.t(),
              display_name :: String.t(),
              email :: String.t()
            ) :: {:ok, user_data()} | {:error, :deactivated} | {:error, term()}

  @doc """
  Validates user identity: looks up user, provisions if new, decrypts display_name.

  - user_id: Matrix user ID from gRPC metadata (e.g. "@kai:nebu.local")
  - system_role: from gRPC metadata (e.g. "user", "instance_admin")
  - display_name: from ValidateTokenRequest (OIDC preferred_username)
  - email: from ValidateTokenRequest (OIDC email claim)

  Returns {:ok, %{user_id, system_role, display_name, is_active}} on success.
  Returns {:error, :deactivated} if user exists but is_active = false.
  Returns {:error, reason} on DB failure.
  """
  @spec validate(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, user_data()} | {:error, :deactivated} | {:error, term()}
  def validate(user_id, system_role, display_name, email) do
    validator_module().validate(user_id, system_role, display_name, email)
  end

  defp validator_module do
    Application.get_env(:session_manager, :validator_module, Nebu.Session.TokenValidator.Postgres)
  end
end
