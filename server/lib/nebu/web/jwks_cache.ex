defmodule Nebu.Web.JwksCache do
  @moduledoc """
  Caches the OIDC provider's JWKS (JSON Web Key Set) public keys.

  Started under the application supervisor and registered under its module name
  (`Nebu.Web.JwksCache`) so it is reachable by name after a crash/restart.

  ## Fetch-on-start + TTL refresh (AC5)

  The cache fetches the JWKS ONCE on start (fetch-on-start) and schedules a
  periodic refresh on the configured TTL (`ttl_ms/0`). State is volatile
  (in-memory GenServer state); on a crash the supervisor restarts the child and
  it re-fetches.

  ## Injectable fetcher seam (no network in tests)

  `start_link/1` accepts a `:fetcher` option — either a 0-arity fun or a module
  exporting `fetch_jwks/0`, both returning `{:ok, [jwk_map]}` (or a bare key
  list). When absent it falls back to Application env `:nebu_http, :jwks_fetcher`
  (same shape), and finally to a real HTTP fetch against `:nebu_http,
  :oidc_jwks_uri`.

  The fetcher is resolved at fetch time (not captured once at start) so the
  Application-env stub survives a crash-induced restart.
  """
  use GenServer

  require Logger

  @default_ttl_ms 300_000

  # ── Public API ──────────────────────────────────────────────────────────

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Returns the list of currently cached JWK maps."
  @spec keys() :: [map()]
  def keys do
    GenServer.call(__MODULE__, :keys)
  end

  @doc """
  Forces an immediate re-fetch and updates the key cache.

  Used after Bootstrap Wizard completion to pull in keys for the newly-configured
  OIDC issuer without waiting for the next TTL-based refresh. Accepts a `GenServer.server()`
  so isolated test instances (started with a unique `:name`) can be targeted by pid.
  """
  @spec refresh(GenServer.server()) :: :ok
  def refresh(server \\ __MODULE__) do
    GenServer.call(server, :refresh)
  end

  @doc """
  Returns the configured cache TTL in milliseconds.

  Default 300_000 (300s). `NEBU_OIDC_JWKS_TTL` is read in SECONDS and converted
  to milliseconds (e.g. "120" → 120_000).
  """
  @spec ttl_ms() :: pos_integer()
  def ttl_ms do
    case System.get_env("NEBU_OIDC_JWKS_TTL") do
      nil ->
        @default_ttl_ms

      raw ->
        case Integer.parse(raw) do
          {seconds, _} when seconds > 0 -> seconds * 1000
          _ -> @default_ttl_ms
        end
    end
  end

  # ── GenServer callbacks ─────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    fetcher = Keyword.get(opts, :fetcher)
    # On the very first fetch there is no last-known-good set, so a failure
    # leaves us with []. Subsequent refresh failures keep the prior keys.
    keys =
      case do_fetch(fetcher) do
        {:ok, keys} -> keys
        :error -> []
      end

    schedule_refresh()
    {:ok, %{keys: keys, fetcher: fetcher}}
  end

  @impl GenServer
  def handle_call(:keys, _from, state) do
    {:reply, state.keys, state}
  end

  @impl GenServer
  def handle_call(:refresh, _from, state) do
    # oidc-env-optional-bootstrap (AC5): on-demand refresh after bootstrap completion.
    # On success, replace the key set. On failure, keep last-known-good keys
    # (same policy as the TTL refresh path in handle_info/2).
    keys =
      case do_fetch(state.fetcher) do
        {:ok, fresh} -> fresh
        :error -> state.keys
      end

    {:reply, :ok, %{state | keys: keys}}
  end

  @impl GenServer
  def handle_info(:refresh, state) do
    # On a refresh failure, KEEP the last-known-good keys rather than blanking
    # the cache to [] (which would 401 every request for a whole TTL window).
    keys =
      case do_fetch(state.fetcher) do
        {:ok, fresh} -> fresh
        :error -> state.keys
      end

    schedule_refresh()
    {:noreply, %{state | keys: keys}}
  end

  # ── Internals ───────────────────────────────────────────────────────────

  defp schedule_refresh do
    Process.send_after(self(), :refresh, ttl_ms())
  end

  # Resolve the fetcher at call time so an Application-env stub survives a
  # crash-induced restart (the init opts list may be empty after restart).
  # Returns `{:ok, keys}` on a successful fetch, or `:error` on failure so the
  # caller can preserve the last-known-good key set.
  defp do_fetch(fetcher) do
    resolved = fetcher || Application.get_env(:nebu_http, :jwks_fetcher)

    case invoke_fetcher(resolved) do
      {:ok, keys} when is_list(keys) -> {:ok, keys}
      keys when is_list(keys) -> {:ok, keys}
      :error -> :error
      other ->
        Logger.warning("JwksCache fetch returned unexpected value: #{inspect(other)}")
        :error
    end
  end

  defp invoke_fetcher(fun) when is_function(fun, 0), do: fun.()

  defp invoke_fetcher(mod) when is_atom(mod) and not is_nil(mod) do
    if function_exported?(mod, :fetch_jwks, 0) do
      mod.fetch_jwks()
    else
      # Misconfigured module fetcher: signal failure so we keep prior keys.
      :error
    end
  end

  defp invoke_fetcher(nil), do: http_fetch()

  defp http_fetch do
    # C-2 (oidc-env-optional-bootstrap): resolve the JWKS URI from env first,
    # then fall back to the DB-backed OidcConfig cache (bootstrap-wizard
    # deployments where NEBU_OIDC_JWKS_URI is absent but was stored via the
    # wizard's step-2 form into server_config.oidc_jwks_uri).
    uri =
      Application.get_env(:nebu_http, :oidc_jwks_uri) ||
        Nebu.Web.OidcConfig.jwks_uri()

    case uri do
      nil ->
        # No explicit JWKS URI configured: try auto-discovery from the OIDC
        # issuer's well-known openid-configuration document. This handles the
        # common deployment where only NEBU_OIDC_ISSUER is set (not
        # NEBU_OIDC_JWKS_URI) — which is valid per the OIDC spec.
        discover_jwks_uri_and_fetch()

      uri ->
        fetch_jwks_over_http(uri)
    end
  end

  defp discover_jwks_uri_and_fetch do
    issuer =
      Application.get_env(:nebu_http, :oidc_issuer) ||
        Nebu.Web.OidcConfig.get()[:issuer]

    case issuer do
      nil ->
        # No issuer and no explicit JWKS URI: nothing to discover. Treat as
        # an empty (but successful) key set rather than a failure.
        {:ok, []}

      issuer ->
        with {:ok, body} <- Nebu.Matrix.OidcMetadata.fetch(issuer),
             {:ok, doc} <- Jason.decode(body),
             {:ok, jwks_uri} <- extract_valid_jwks_uri(doc) do
          fetch_jwks_over_http(jwks_uri)
        else
          _ ->
            # Return :error so do_fetch/1 keeps the last-known-good key set rather
            # than overwriting it with an empty list on a transient discovery failure.
            Logger.warning("JwksCache: could not discover jwks_uri from issuer #{issuer}")
            :error
        end
    end
  end

  # Extracts the jwks_uri from an OIDC discovery document and validates its scheme.
  # Only http:// and https:// are accepted — other schemes (file://, etc.) are rejected
  # to prevent SSRF via a malicious discovery document.
  defp extract_valid_jwks_uri(%{"jwks_uri" => uri})
       when is_binary(uri) and uri != "" do
    if String.starts_with?(uri, "https://") or String.starts_with?(uri, "http://") do
      {:ok, uri}
    else
      :error
    end
  end

  defp extract_valid_jwks_uri(_), do: :error

  defp fetch_jwks_over_http(uri) do
    # Allow test injection of the HTTP key-fetch step via :jwks_http_fetcher.
    # The seam is checked before making a real HTTP request so tests can stub
    # the final key-fetch step without a live JWKS endpoint.
    case Application.get_env(:nebu_http, :jwks_http_fetcher) do
      fun when is_function(fun, 1) ->
        case fun.(uri) do
          {:ok, keys} when is_list(keys) -> {:ok, keys}
          other ->
            Logger.warning("JwksCache :jwks_http_fetcher returned unexpected value: #{inspect(other)}")
            :error
        end

      _ ->
        fetch_jwks_over_http_real(uri)
    end
  end

  defp fetch_jwks_over_http_real(uri) do
    http_opts = http_opts_for(uri)

    case :httpc.request(:get, {String.to_charlist(uri), []}, http_opts, body_format: :binary) do
      {:ok, {{_http, 200, _reason}, _headers, body}} ->
        case Jason.decode(body) do
          {:ok, %{"keys" => keys}} when is_list(keys) ->
            {:ok, keys}

          _ ->
            Logger.warning("JwksCache: malformed JWKS body from #{uri}")
            :error
        end

      other ->
        Logger.warning("JwksCache HTTP fetch failed for #{uri}: #{inspect(other)}")
        :error
    end
  end

  # TLS peer verification for https JWKS endpoints (defense against an on-path
  # attacker swapping in attacker-controlled signing keys). For http:// endpoints
  # — only the Docker-internal dev Dex per ADR-012 — there is no TLS to verify, so
  # the option list is empty. The OIDC provider URL should be https in prod.
  defp http_opts_for(uri) do
    if String.starts_with?(uri, "https://") do
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
