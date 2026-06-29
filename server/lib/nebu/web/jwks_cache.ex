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
  (same shape), and finally to a real HTTP fetch against the JWKS URI resolved from
  `server_config` via `Nebu.Web.OidcConfig` (ADR-022 — no env-var config path).

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
  Fetches JWKS for an EXPLICIT jwks_uri/issuer WITHOUT touching the GenServer cache
  or `OidcConfig`.

  Used by the bootstrap operator-login callback (story
  oidc-bootstrap-only-e2e-regressions): during the wizard the OIDC config lives in the
  `bootstrap_draft`, not yet in `server_config`, so the global cache cannot be used. This
  helper reuses the SAME TLS-verifying HTTP fetch + discovery logic as the global path
  (including the `:jwks_http_fetcher` test seam and `http_opts_for/1` TLS), but reads
  NOTHING from `OidcConfig` and never mutates the cache — preserving the ADR-022
  fail-closed invariant.

    * `jwks_uri` a non-empty `http(s)://` binary → fetch directly.
    * else `issuer` non-empty binary → discover the jwks_uri from the issuer's
      well-known document, then fetch.
    * else → `{:ok, []}` (nothing to fetch).

  SSRF hardening (code-review MINOR-1): the explicit `jwks_uri` is scheme-validated to
  `http(s)://` BEFORE any fetch — parity with the discovery branch's
  `extract_valid_jwks_uri/1`. A non-`http(s)` draft URI (e.g. `file://`) is rejected with
  `:error` rather than handed to `:httpc`. A scheme-invalid `jwks_uri` does NOT silently
  fall through to issuer discovery: an operator who set an explicit (but bad) URI must fix
  it, not get a surprise discovery fetch against a different endpoint.
  """
  @spec fetch_keys_for(String.t() | nil, String.t() | nil) :: {:ok, [map()]} | :error
  def fetch_keys_for(jwks_uri, issuer) do
    cond do
      is_binary(jwks_uri) and jwks_uri != "" ->
        if http_scheme?(jwks_uri) do
          fetch_jwks_over_http(jwks_uri)
        else
          Logger.warning("JwksCache.fetch_keys_for: rejecting non-http(s) jwks_uri scheme")
          :error
        end

      is_binary(issuer) and issuer != "" ->
        discover_jwks_uri_and_fetch_for(issuer)

      true ->
        {:ok, []}
    end
  end

  defp http_scheme?(uri),
    do: String.starts_with?(uri, "https://") or String.starts_with?(uri, "http://")

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
    # oidc-bootstrap-only-config (ADR-022): the JWKS URI comes SOLELY from
    # server_config (stored via the wizard's step-2 form), read through the
    # DB-backed OidcConfig cache. There is no NEBU_OIDC_JWKS_URI env path.
    uri = Nebu.Web.OidcConfig.jwks_uri()

    case uri do
      nil ->
        # No explicit JWKS URI in server_config: try auto-discovery from the OIDC
        # issuer's well-known openid-configuration document. This handles a bootstrap
        # config that set only the issuer (not the JWKS URI) — valid per the OIDC spec.
        discover_jwks_uri_and_fetch()

      uri ->
        fetch_jwks_over_http(uri)
    end
  end

  # Global path: read the issuer from OidcConfig (server_config), then delegate to the
  # explicit-issuer discovery shared with fetch_keys_for/2. OidcConfig is read ONLY here,
  # never inside the explicit-issuer branch.
  defp discover_jwks_uri_and_fetch do
    # oidc-bootstrap-only-config (ADR-022): issuer comes solely from server_config.
    case Nebu.Web.OidcConfig.get()[:issuer] do
      nil ->
        # No issuer and no explicit JWKS URI: nothing to discover. Treat as
        # an empty (but successful) key set rather than a failure.
        {:ok, []}

      issuer ->
        discover_jwks_uri_and_fetch_for(issuer)
    end
  end

  # Discovery for an EXPLICIT issuer (no OidcConfig read). Shared by the global path
  # above and the public fetch_keys_for/2 (bootstrap draft) helper.
  defp discover_jwks_uri_and_fetch_for(issuer) do
    with {:ok, body} <- Nebu.Matrix.OidcMetadata.fetch(issuer),
         {:ok, doc} <- Jason.decode(body),
         {:ok, jwks_uri} <- extract_valid_jwks_uri(doc) do
      fetch_jwks_over_http(jwks_uri)
    else
      _ ->
        # Return :error so the caller keeps the last-known-good key set (global path)
        # or fails the bootstrap callback cleanly (fetch_keys_for/2) rather than
        # overwriting/accepting on a transient discovery failure.
        Logger.warning("JwksCache: could not discover jwks_uri from issuer #{issuer}")
        :error
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
