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

  ## No origin rewriting (bugfix-oidc-public-endpoint-urls, architecture v2)

  An earlier cycle of this bugfix rewrote every endpoint URL field's origin from
  the internal Docker-Compose issuer to an operator-configured "public base URL"
  before returning the document to a browser/Matrix client. Code review rejected
  that design (9 MAJOR findings — root cause: rewriting response data to
  compensate for an internally-addressed IdP is fragile, desyncs the advertised
  `issuer` from the real `iss` claim baked into tokens, and still left two routes
  unfixed).

  The REPLACEMENT fix is at the source, not here: the IdP (dev Dex, and any real
  IdP such as Keycloak) is configured with its OWN public-reachable `issuer`
  (`dev/dex/config.yaml`), made reachable from the compose network too via a
  Docker Compose network alias (`docker-compose.yml`) — so Nebu's own
  server-to-server calls (this module's `fetch/1`, token exchange, JWKS fetch)
  resolve the SAME hostname a browser would use. Every field this module fetches
  is therefore already honest and public by construction; this module never
  rewrites an origin.

  ## MSC2965 required-field synthesis

  Dex's discovery document genuinely omits 3 fields the MSC2965 profile (and the
  Matrix Dart SDK, which parses them non-nullable) requires:
  `registration_endpoint`, `response_modes_supported`, `revocation_endpoint`.
  `ensure_msc2965_fields/2` fills in ONLY these three when absent — never
  rewriting any field the upstream document does provide. See its own doc for
  the synthesized values and the fail-closed behaviour on a malformed `issuer`.

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

  @doc """
  Fills in the 3 MSC2965/RFC 8414 MUST-fields Dex's discovery document omits
  (`registration_endpoint`, `response_modes_supported`, `revocation_endpoint`) —
  and ONLY those, when absent. Every other field is passed through byte-for-byte
  (bugfix-oidc-public-endpoint-urls, architecture v2 — see moduledoc: this module
  never rewrites an origin).

  `response_modes_supported` is a spec constant (`["query", "fragment"]`) — no
  origin dependency, always synthesized when missing.

  `registration_endpoint`/`revocation_endpoint` need a real absolute URL. Dex
  does not implement dynamic client registration or token revocation, so these
  are placeholder paths — but the BASE they're appended to is always the
  CONFIGURED `issuer` (the second argument, `server_config.oidc_issuer` as read
  by the caller) INCLUDING its path (never just its origin, and never a
  hardcoded or invented host) — never the upstream document's own `issuer`
  field. Under the honest-issuer design (see moduledoc) the two are equal by
  construction on a legitimate response, but the configured value is a value
  Nebu itself trusts, while the document's `issuer` field is attacker-influenced
  network input (M-1, Kassandra security review 2026-09-02): synthesizing from
  it would let a compromised/spoofed upstream steer where these two endpoints
  point, for every client that trusts Nebu's `auth_metadata` response. Preserving
  the issuer's path matters: an issuer like `http://dex.localtest.me:5556/dex`
  or a Keycloak-style `https://keycloak.example.com/realms/nebu` mounts the IdP
  under a sub-path, and a synthesized URL built from origin-only (dropping
  `/dex` or `/realms/nebu`) would escape that mount point — in this project's
  own Stackit Terraform, where Dex's issuer is `https://<server_name>/dex` (same
  origin as Nebu itself), an origin-only synthesized URL would resolve to
  Nebu's OWN server instead of the IdP.

  Fail-closed on a malformed configured issuer: when it is missing, not a
  string, or does not parse to an absolute URI with both a scheme and a host,
  `registration_endpoint`/`revocation_endpoint` are left absent rather than
  synthesized with an invalid/garbage URL — a client parsing them non-nullable
  will not get an unusable string, it simply won't see a value for either
  (`response_modes_supported` is unaffected, since it needs no origin).

  Returns the input unchanged if it is not valid JSON (defensive — `fetch/1`
  only ever returns bytes it itself received/encoded, so this should not occur
  on the real request path).
  """
  @spec ensure_msc2965_fields(binary(), String.t()) :: binary()
  def ensure_msc2965_fields(raw_json, configured_issuer) do
    case Jason.decode(raw_json) do
      {:ok, doc} when is_map(doc) ->
        base = issuer_base(configured_issuer)

        doc
        |> put_list_if_missing("response_modes_supported", ["query", "fragment"])
        |> maybe_put_placeholder_url("registration_endpoint", "/clients/register", base)
        |> maybe_put_placeholder_url("revocation_endpoint", "/token/revoke", base)
        |> Jason.encode!()

      _ ->
        raw_json
    end
  end

  defp put_list_if_missing(doc, key, value) do
    case doc[key] do
      v when is_list(v) and v != [] -> doc
      _ -> Map.put(doc, key, value)
    end
  end

  defp maybe_put_placeholder_url(doc, key, path, base) do
    case doc[key] do
      v when is_binary(v) and v != "" ->
        doc

      _ ->
        case base do
          nil -> doc
          base -> Map.put(doc, key, base <> path)
        end
    end
  end

  # MAJOR-1 (code review, redesign cycle 1): the FULL `issuer` value, including
  # its path (e.g. `/dex`, `/realms/nebu`), with any trailing slash(es) trimmed
  # so concatenating a leading-slash `path` never produces a double slash — or
  # `nil` when `issuer` is not a binary or does not parse to an absolute URI
  # with both a scheme and a host (missing/blank/relative/malformed) — the
  # fail-closed guard for maybe_put_placeholder_url/3.
  #
  # Previously this stripped the issuer down to scheme+host[+port] only,
  # discarding the issuer's own path component. For dex
  # (`http://dex.localtest.me:5556/dex`) that produced
  # `http://dex.localtest.me:5556/clients/register` — OUTSIDE dex's own `/dex`
  # mount point — and for a Keycloak-style realm-scoped issuer
  # (`https://keycloak.example.com/realms/nebu`) it escaped the realm path
  # entirely. Worse: in this project's own Stackit Terraform
  # (deploy/tofu/examples/stackit/server.tf), dex's issuer with TLS on is
  # `https://<server_name>/dex` — the SAME origin as Nebu itself (nginx
  # path-routes `/dex/` to dex) — so an origin-only synthesized URL would have
  # resolved to NEBU'S OWN SERVER, not the IdP at all.
  defp issuer_base(issuer) when is_binary(issuer) and issuer != "" do
    case URI.parse(issuer) do
      %URI{scheme: scheme, host: host}
      when is_binary(scheme) and scheme != "" and is_binary(host) and host != "" ->
        String.trim_trailing(issuer, "/")

      _ ->
        nil
    end
  end

  defp issuer_base(_), do: nil

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
