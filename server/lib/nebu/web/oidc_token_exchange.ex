defmodule Nebu.Web.OidcTokenExchange do
  @moduledoc """
  Single shared IdP `grant_type=refresh_token` exchange (story
  `matrix-refresh-revalidates-with-idp`, epic `oidc-simplification`).

  Extracts the ~20-line "HTTP-POST to the token endpoint + parse the JSON
  response + `OidcPlug.verify_token/2` the returned `id_token`" leg that used
  to live ONLY in `Nebu.Admin.Auth.exchange_refresh_token/1`, so the Matrix
  refresh path (`Nebu.Matrix.HttpPublic.do_refresh_with/2`) can reuse the exact
  same logic instead of maintaining a second, independent copy (AC5).

  ## Module boundary

  This module knows NOTHING about which domain (Admin vs Matrix) is calling
  it, nor about that domain's test seam (`:admin_oidc_refresh_override` /
  `:matrix_oidc_refresh_override` stay in each domain's own caller, per the
  story: "Login-Kontext (Audience, Client-Config) unterschiedlich sein kann").
  The caller resolves its OWN config (issuer, client_id, client_secret) and
  passes it in — this module never reads `server_config` / bootstrap draft
  itself, and never touches Application env for domain-specific seams.

  ## Contract

  `refresh/2` takes the plaintext OIDC refresh token and a config map with
  keys `:issuer`, `:client_id`, `:client_secret`, and returns:

    * `{:ok, claims, new_refresh_token_or_nil}` — the exchange succeeded, the
      returned `id_token` was verified via `OidcPlug.verify_token/2` (audience
      = `client_id`), and `new_refresh_token_or_nil` is the provider-rotated
      OIDC refresh token (or `nil` when the provider did not rotate).
    * `{:error, reason}` — discovery failure, network failure, non-2xx
      response, malformed body, missing `id_token`, or ID-token verification
      failure. Callers MUST fail closed on any `{:error, _}` — there is no
      local-only fallback baked into this module or expected of its callers.

  TLS peer verification for the token-endpoint POST mirrors
  `Nebu.Web.JwksCache.http_opts_for/1` (https endpoints only; plain `http://`
  is the dev-internal Dex container) — the same posture the admin path already
  had, now shared instead of duplicated.
  """

  @doc """
  Exchanges `refresh_token` at the IdP's discovered token endpoint
  (`grant_type=refresh_token`) and verifies the returned `id_token`.

  `cfg` must have `:issuer`, `:client_id`, `:client_secret`.
  """
  @spec refresh(String.t(), map()) ::
          {:ok, map(), String.t() | nil} | {:error, term()}
  def refresh(refresh_token, %{issuer: issuer, client_id: client_id, client_secret: client_secret})
      when is_binary(refresh_token) do
    with {:ok, token_endpoint} <- discover(issuer, "token_endpoint"),
         body =
           URI.encode_query(%{
             "grant_type" => "refresh_token",
             "refresh_token" => refresh_token,
             "client_id" => client_id
           }),
         {:ok, resp_body} <-
           token_endpoint_post(token_endpoint, body, client_id, client_secret),
         {:ok, id_token, new_rt} <- extract_tokens(resp_body),
         {:ok, claims} <-
           Nebu.Web.Plugs.OidcPlug.verify_token(id_token, audience: client_id) do
      {:ok, claims, new_rt}
    end
  end

  # Resolves one endpoint from the provider discovery document via the
  # existing TLS-verifying fetcher (which honours the :oidc_metadata_override
  # test seam) — the SAME discovery path the login/admin flows already use.
  defp discover(issuer, field) do
    with {:ok, body} <- Nebu.Matrix.OidcMetadata.fetch(issuer),
         {:ok, doc} <- Jason.decode(body) do
      case doc[field] do
        url when is_binary(url) and url != "" -> {:ok, url}
        _ -> {:error, {:discovery_missing, field}}
      end
    else
      {:error, reason} -> {:error, {:discovery_failed, reason}}
    end
  end

  defp token_endpoint_post(token_endpoint, body, client_id, client_secret) do
    basic = Base.encode64("#{client_id}:#{client_secret}")

    headers = [
      {~c"content-type", ~c"application/x-www-form-urlencoded"},
      {~c"accept", ~c"application/json"},
      {~c"authorization", String.to_charlist("Basic " <> basic)}
    ]

    request = {String.to_charlist(token_endpoint), headers, ~c"application/x-www-form-urlencoded", body}
    http_opts = [timeout: 5_000, connect_timeout: 5_000] ++ tls_opts_for(token_endpoint)

    case :httpc.request(:post, request, http_opts, body_format: :binary) do
      {:ok, {{_http, status, _reason}, _headers, resp_body}} when status in 200..299 ->
        {:ok, resp_body}

      {:ok, {{_http, status, _reason}, _headers, _resp_body}} ->
        {:error, {:token_endpoint_status, status}}

      {:error, reason} ->
        {:error, {:token_endpoint_unreachable, reason}}
    end
  end

  defp extract_tokens(resp_body) do
    case Jason.decode(resp_body) do
      {:ok, %{"id_token" => id_token} = body} when is_binary(id_token) and id_token != "" ->
        {:ok, id_token, refresh_token_from(body)}

      {:ok, _} ->
        {:error, :no_id_token}

      {:error, _} ->
        {:error, :malformed_token_response}
    end
  end

  defp refresh_token_from(%{"refresh_token" => rt}) when is_binary(rt) and rt != "", do: rt
  defp refresh_token_from(_), do: nil

  defp tls_opts_for(url) do
    if String.starts_with?(url, "https://") do
      [
        ssl: [
          verify: :verify_peer,
          cacerts: :public_key.cacerts_get(),
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ]
        ]
      ]
    else
      []
    end
  end
end
