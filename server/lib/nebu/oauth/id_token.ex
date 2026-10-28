defmodule Nebu.OAuth.IdToken do
  @moduledoc """
  Nebu-signed OpenID Connect id_token (story oauth-token-endpoint, T15-T17, AC12). Pure: claims
  and signing, no I/O; the key comes from `Nebu.OAuth.SigningKeyStore`.

  Claims (T16, data minimization): exactly `iss` (the normalized Nebu issuer, byte-equal to the
  metadata `issuer`), `sub` (the Matrix user id: stable, never the IdP `sub`), `aud` (the
  `client_id` as a STRING), `iat`, `exp = iat + 300`, `auth_time` (omitted when unknown) and
  `nonce` (only on the authorization_code grant and only when the client sent one; OIDC Core 12.2).
  Nothing else (no e-mail/name, no `at_hash`/`azp`).

  Signing (T17): the algorithm is the code constant `ES256` — never read from input, from the key
  map or from the stored row. The protected header is exactly `alg` / `kid` / `typ`. The key is
  never logged or inspected.
  """

  @alg "ES256"
  @lifetime_seconds 300

  @type input :: %{
          issuer: String.t(),
          user_id: String.t(),
          client_id: String.t(),
          auth_time: integer() | nil,
          nonce: String.t() | nil
        }

  @doc "The exact claim set for `input` at unix time `now`."
  @spec claims(input(), integer()) :: map()
  def claims(%{issuer: iss, user_id: sub, client_id: aud} = input, now) when is_integer(now) do
    %{"iss" => iss, "sub" => sub, "aud" => aud, "iat" => now, "exp" => now + @lifetime_seconds}
    |> put_optional("auth_time", Map.get(input, :auth_time))
    |> put_optional("nonce", Map.get(input, :nonce))
  end

  defp put_optional(claims, _key, nil), do: claims
  defp put_optional(claims, key, value), do: Map.put(claims, key, value)

  @doc "Signs `claims` with `key` (`%{kid:, jwk: %JOSE.JWK{}}`) as a compact JWS (ES256)."
  @spec sign(map(), %{kid: String.t(), jwk: JOSE.JWK.t()}) :: String.t()
  def sign(claims, %{kid: kid, jwk: %JOSE.JWK{} = jwk}) when is_map(claims) and is_binary(kid) do
    # The JWS header is built here; JOSE signs with the algorithm named in it (a stray "alg" member
    # of the key map cannot change it).
    {_, compact} =
      jwk
      |> JOSE.JWT.sign(%{"alg" => @alg, "kid" => kid, "typ" => "JWT"}, claims)
      |> JOSE.JWS.compact()

    compact
  end
end
