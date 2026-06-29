defmodule Nebu.Web.OidcTestSupport do
  @moduledoc """
  Shared test helper for the OIDC bootstrap-only config path (ADR-022).

  Production code resolves the OIDC issuer/audience SOLELY from `server_config`
  via `Nebu.Web.OidcConfig.get/0`; there is no environment-variable config path.
  In unit tests there is no live Postgres, so `OidcConfig.get/0` reads the
  `:nebu_http, :oidc_config_source` seam — a 0-arity fun returning
  `%{issuer: _, audience: _}`.

  `configure/2` installs that seam so a test can make `OidcPlug`/`SsoLogin`/
  `Admin.Auth` resolve a known issuer+audience without a DB. `clear/0` removes it.

  This replaces the old `Application.put_env(:nebu_http, :oidc_issuer/:oidc_audience)`
  test idiom, which drove behavior through the (now removed) env path.
  """

  @doc """
  Installs the OidcConfig DB seam returning the given issuer + audience.
  Returns `:ok`. Pass `nil` for either value to simulate an unconfigured server
  (fail-closed). `jwks_uri` is optional and surfaced via `OidcConfig.jwks_uri/0`.
  """
  def configure(issuer, audience, jwks_uri \\ nil) do
    Application.put_env(:nebu_http, :oidc_config_source, fn ->
      %{issuer: issuer, audience: audience, jwks_uri: jwks_uri}
    end)

    :ok
  end

  @doc "Removes the OidcConfig DB seam."
  def clear, do: Application.delete_env(:nebu_http, :oidc_config_source)
end
