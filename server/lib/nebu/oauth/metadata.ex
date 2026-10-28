defmodule Nebu.OAuth.Metadata do
  @moduledoc """
  Builds Nebu's OAuth 2.0 Authorization-Server Metadata document (RFC 8414) for
  `GET /_matrix/client/v1/auth_metadata` (epic oauth-broker, ADR-033).

  Nebu is the authorization server (broker model O2); the `issuer` is NEBU'S public https URL,
  never the corporate IdP's. Pure functions — no I/O.

  ## Fields

  Required by the Matrix spec (v1.18): `issuer`, `authorization_endpoint`, `token_endpoint`,
  `revocation_endpoint`, `registration_endpoint`, `response_types_supported` (>= `code`),
  `grant_types_supported` (>= `authorization_code`, `refresh_token`), `response_modes_supported`
  (>= `query`, `fragment`), `code_challenge_methods_supported` (>= `S256`).

  Additionally advertised (truthful for what the OAuth surface is specified to do):
  `token_endpoint_auth_methods_supported` and `revocation_endpoint_auth_methods_supported`
  (`["none"]`: public clients, revocation needs no client authentication), and
  `authorization_response_iss_parameter_supported: true` (RFC 9207: every response of
  `GET /oauth2/authorize`, success and error, carries `iss` = this issuer).

  Story oauth-token-endpoint (story 3, T30): `jwks_uri` = `<issuer>/oauth2/jwks` — NEBU'S OWN JWKS
  (the ES256 keys Nebu signs its id_tokens with, `Nebu.OAuth.SigningKeyStore`), never the IdP's —
  and `id_token_signing_alg_values_supported: ["ES256"]`. matrix-js-sdk requires `jwks_uri`
  (`validateAuthMetadataAndKeys`). The same document is served at
  `<issuer>/.well-known/openid-configuration` (T31).

  Story oauth-account-management (story 6, A18): `account_management_uri` = `<issuer>/account` and
  `account_management_actions_supported` = the five actions the page implements (pinned order:
  `org.matrix.profile`, `org.matrix.devices_list`, `org.matrix.device_view`, `org.matrix.device_delete`,
  `org.matrix.cross_signing_reset`; NOT `org.matrix.account_deactivate`, which the page does not
  offer). Truthful by construction: the page is live under exactly the predicate this document
  answers 200 under (`Nebu.OAuth.Config.live_state/0`). Clients cache the document for 3 days, so the
  fields become visible to them only after the cache expires.

  Deliberately NOT advertised until implemented: `device_authorization_endpoint`,
  `prompt_values_supported`;
  and never `auth_issuer` (not part of this document) or any IdP-derived field.

  ## https-for-all-URLs (Nebu rule, ADR-033)

  Stricter than RFC 8414 (which only demands an https `issuer`): EVERY advertised URL is https.
  An issuer that is not an absolute https URL without userinfo/query/fragment is a misconfiguration
  and yields `:unavailable` — the caller answers `404 M_UNRECOGNIZED` (fail closed, the invalid
  value is never echoed).

  ## Issuer without a path (T31)

  matrix-js-sdk resolves `new URL(".well-known/openid-configuration", issuer)`, which DROPS the
  issuer's last path segment, and every Nebu OAuth endpoint lives at the host root. The issuer
  therefore MUST have an empty path (`https://chat.example.com`; a single trailing `/` is allowed
  and stripped); an issuer with any other path is rejected like an http issuer.
  """

  @doc "Builds the metadata document for `issuer_url`, or `:unavailable` when it is not a valid https issuer."
  @spec build(String.t() | nil) :: {:ok, map()} | :unavailable
  def build(issuer_url) do
    case normalize_issuer(issuer_url) do
      {:ok, issuer} ->
        {:ok,
         %{
           "issuer" => issuer,
           "authorization_endpoint" => issuer <> "/oauth2/authorize",
           "token_endpoint" => issuer <> "/oauth2/token",
           "revocation_endpoint" => issuer <> "/oauth2/revoke",
           "registration_endpoint" => issuer <> "/oauth2/register",
           "response_types_supported" => ["code"],
           "grant_types_supported" => ["authorization_code", "refresh_token"],
           "response_modes_supported" => ["query", "fragment"],
           "code_challenge_methods_supported" => ["S256"],
           "token_endpoint_auth_methods_supported" => ["none"],
           "revocation_endpoint_auth_methods_supported" => ["none"],
           # RFC 9207: every authorization response (success and error) carries `iss`
           # (story oauth-authorize-idp-delegation-code, D15)
           "authorization_response_iss_parameter_supported" => true,
           # story oauth-token-endpoint (T30): Nebu's OWN id_token signing keys
           "jwks_uri" => issuer <> "/oauth2/jwks",
           "id_token_signing_alg_values_supported" => ["ES256"],
           # story oauth-account-management (A18): the account page is live under this document's predicate
           "account_management_uri" => issuer <> "/account",
           "account_management_actions_supported" => [
             "org.matrix.profile",
             "org.matrix.devices_list",
             "org.matrix.device_view",
             "org.matrix.device_delete",
             "org.matrix.cross_signing_reset"
           ]
         }}

      :error ->
        :unavailable
    end
  end

  @doc """
  Validates an issuer URL: absolute `https`, a host, no userinfo, no query, no fragment and an
  EMPTY path (T31; a single trailing `/` is stripped so endpoint URLs never contain `//`).
  """
  @spec normalize_issuer(term()) :: {:ok, String.t()} | :error
  def normalize_issuer(url) when is_binary(url) do
    uri = URI.parse(String.trim(url))

    if uri.scheme == "https" and is_binary(uri.host) and uri.host != "" and uri.userinfo == nil and
         uri.query == nil and uri.fragment == nil and not String.contains?(url, "#") and
         not String.contains?(url, "?") and uri.path in [nil, "", "/"] do
      {:ok, url |> String.trim() |> String.trim_trailing("/")}
    else
      :error
    end
  end

  def normalize_issuer(_), do: :error
end
