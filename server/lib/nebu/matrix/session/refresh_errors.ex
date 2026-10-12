defmodule Nebu.Matrix.Session.RefreshErrors do
  @moduledoc """
  Single source of truth for classifying failures of the IdP re-validation
  (`Nebu.Matrix.HttpPublic.revalidate_with_idp/1`) as TRANSIENT or CONFIRMED.

  Shared by the background `Nebu.Matrix.Session.RefreshWorker` (transient: leave
  the row intact, retry next cycle; confirmed: delete exactly that row) and by
  `POST /_matrix/client/v3/refresh` (transient: `503` + `Retry-After`, session
  untouched, because Matrix clients log out on any 4xx and retry on 5xx;
  confirmed: `401 M_UNKNOWN_TOKEN` and the device's session is invalidated).

  Transient = infrastructure/availability problems that are NOT proof the IdP
  rejected this refresh token:

    * `{:transient_check_failed, _}` — DB hiccup re-checking `is_active`
    * `{:token_endpoint_unreachable, _}` — network timeout / IdP down
    * `{:discovery_failed, _}` — discovery document fetch failure
    * `{:token_endpoint_status, status}` with `status >= 500` or `429`

  Everything else (`:deactivated`, `{:token_endpoint_status, 400|401|403|...}`,
  `:invalid_grant`, `:decrypt_failed`, `:no_oidc_refresh_token`, ...) is a
  confirmed rejection (fail closed for unknown reasons).
  """

  @spec transient?(term()) :: boolean()
  def transient?({:transient_check_failed, _reason}), do: true
  def transient?({:token_endpoint_unreachable, _reason}), do: true
  def transient?({:discovery_failed, _reason}), do: true
  def transient?({:token_endpoint_status, status}) when is_integer(status) and (status >= 500 or status == 429), do: true
  def transient?(_other), do: false

  @doc """
  Seconds a client should wait before retrying a transient failure (`Retry-After`).
  """
  @spec retry_after_seconds(term()) :: pos_integer()
  def retry_after_seconds({:token_endpoint_status, 429}), do: 30
  def retry_after_seconds(_reason), do: 5

  @doc """
  Log-safe description of a failure reason: only the error tag / HTTP status, never
  the (possibly secret-bearing) payload carried inside the reason tuple.
  """
  @spec describe(term()) :: String.t()
  def describe({:token_endpoint_status, status}) when is_integer(status), do: "token_endpoint_status:#{status}"
  def describe({tag, _payload}) when is_atom(tag), do: Atom.to_string(tag)
  def describe(tag) when is_atom(tag), do: Atom.to_string(tag)
  def describe(_other), do: "unknown"
end
