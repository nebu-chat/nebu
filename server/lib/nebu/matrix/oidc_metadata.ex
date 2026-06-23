defmodule Nebu.Matrix.OidcMetadata do
  @moduledoc """
  Fetches (and TTL-caches) the OIDC provider's
  `/.well-known/openid-configuration` document for the MSC2965 `auth_metadata`
  endpoint.

  Mirrors `gateway/internal/matrix/oidc_discovery.go` AuthMetadataHandler: a
  5-minute cache avoids hammering the provider on every client request. The
  document is returned verbatim (raw JSON bytes) so the response shape exactly
  matches what the provider serves (issuer, authorization_endpoint,
  token_endpoint, jwks_uri, ...).

  ## Test seam

  When `Application.get_env(:nebu_http, :oidc_metadata_override)` is set to a map,
  that map is JSON-encoded and returned without any network call (used by unit
  tests, which assert only on shape, not on a live provider).
  """

  @ttl_ms 5 * 60 * 1000

  @doc """
  Returns `{:ok, raw_json_binary}` or `{:error, reason}` for the issuer's
  discovery document.
  """
  @spec fetch(String.t()) :: {:ok, binary()} | {:error, term()}
  def fetch(issuer) do
    case Application.get_env(:nebu_http, :oidc_metadata_override) do
      override when is_map(override) ->
        {:ok, Jason.encode!(override)}

      _ ->
        fetch_cached(issuer)
    end
  end

  defp fetch_cached(issuer) do
    now = System.monotonic_time(:millisecond)

    case :persistent_term.get({__MODULE__, issuer}, nil) do
      {body, expires_at} when expires_at > now ->
        {:ok, body}

      _ ->
        with {:ok, body} <- do_fetch(issuer) do
          :persistent_term.put({__MODULE__, issuer}, {body, now + @ttl_ms})
          {:ok, body}
        end
    end
  end

  defp do_fetch(issuer) do
    full_url = "#{issuer}/.well-known/openid-configuration"
    url = String.to_charlist(full_url)

    request = {url, []}
    # F-2 (Kassandra): enable TLS peer + hostname verification for https issuers,
    # mirroring Nebu.Web.JwksCache.http_opts_for/1. Without verify: :verify_peer an
    # on-path attacker could swap in a forged discovery document (e.g. a malicious
    # authorization_endpoint). http:// issuers (Docker-internal dev Dex per ADR-012)
    # have no TLS to verify.
    http_opts = [timeout: 5_000, connect_timeout: 5_000] ++ tls_opts_for(full_url)
    opts = [body_format: :binary]

    case :httpc.request(:get, request, http_opts, opts) do
      {:ok, {{_http, status, _reason}, _headers, body}} when status in 200..299 ->
        {:ok, body}

      {:ok, {{_http, status, _reason}, _headers, _body}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # TLS peer + hostname verification for https discovery endpoints.
  # http:// (dev-only internal Dex per ADR-012) has no TLS to verify → empty opts.
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
