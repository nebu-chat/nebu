defmodule Nebu.OAuth.Config do
  @moduledoc """
  Runtime configuration of Nebu's OAuth 2.0 authorization-server surface (epic oauth-broker,
  ADR-033): `oauth_enabled` and the public issuer URL.

  ## Source of truth

  Both live in `server_config` (ADR-022 idiom: configuration is persisted, there is no env path):

    * `oauth_enabled` — `"true"` switches the OAuth endpoints on. `"false"`, ANY other value, an
      unparsable value, an absent key, an unreachable DB: OAuth is OFF (fail closed; story:
      "`oauth_enabled` (boolean, default false)"). The migration 000040 extends the
      `config_update_mutable` RLS allowlist with the key, so later UPDATEs are not silent no-ops.
    * `oauth_issuer_url` — the PUBLIC https base URL of this Nebu instance (no path/query/fragment
      expected), advertised as `issuer` in `GET /_matrix/client/v1/auth_metadata`. Absent => `nil`
      (the metadata endpoint then answers `404 M_UNRECOGNIZED`: OAuth is not advertised without an
      issuer). Validation (https only, Nebu rule "https-for-all-URLs") lives in
      `Nebu.OAuth.Metadata`, not here.

  ## Three states (security review N-4)

  `get/0` reports `state: :enabled | :disabled | :unknown` next to the boolean `enabled`:

    * `:enabled` / `:disabled` — `server_config` was READ (`:disabled` includes an absent key or any
      value other than `"true"`).
    * `:unknown` — `server_config` could not be read (query error, DB timeout, crash). Still fail
      closed for the OAuth endpoints (`enabled: false`), but a caller that has a legacy alternative
      (`Nebu.Web.Plugs.OAuthDiscovery`) must NOT fall back to it on `:unknown` — only on a positively
      read `:disabled` — or a transient outage would advertise the IdP issuer while OAuth is on.

  No repository process at all (`Nebu.Repo` not started: unit runs, early boot) is `:disabled`, the
  pre-broker behaviour: there is no database to be "unreadable".

  ## Pending-registration limits (`pending_limits/0`)

    * `oauth_pending_ttl_days` — a `pending` registration older than this is purged (default
      30 days, see `Nebu.OAuth.ClientStore.purge_expired_pending/1`).
    * `oauth_pending_cap` — at most this many `pending` rows exist; a registration of NEW metadata
      above it is refused with 503 (default 5000; a dedup hit is still answered).
    * `oauth_pending_host_cap` — at most this many `pending` rows per (registrable domain of the
      `client_uri` host, client source) (default 20; story oauth-dcr-abuse-hardening AH1, the key name
      is kept): one registrant cannot use up the global cap, and cannot block another source's
      registrations. Same 503 / dedup-hit rules.

  All are positive integers stored as text; an absent, unparsable, non-positive or absurd value
  (TTL > 3650 days, cap > 10 million) falls back to the default — never to "unlimited".

  ## Per-node TTL cache (story oauth-hardening-hygiene, HY1 / HY2)

  `get/1` (and with it `live_state/1`, `enabled?/0`, `Nebu.OAuth.oauth_aware?/1`) serves the normalized
  `%{enabled, issuer_url, state, matrix_session_ttl_seconds}` from a per-node ETS entry `{:config, map, loaded_at_ms}` (table
  `:nebu_oauth_config_cache`, owned by `Nebu.OAuth.CacheOwner`) while `now - loaded_at < ttl`. The TTL is
  `:nebu_http, :oauth_config_cache_ms` (`NEBU_OAUTH_CONFIG_CACHE_MS`, integer `0..5000`, default 2000, `0` =
  cache off; `config/test.exs` sets `0`). ONLY a successful read (`:enabled` / `:disabled`) is cached:
  `:unknown` (read error, timeout, exception) and the `:no_repo` answer are NEVER cached, so every request
  during an outage re-reads and fails closed exactly as before. A missing table is a miss (read-through,
  never an exception, never created by the caller).

  ADR-020 exception (bounded staleness): an operator write of `oauth_enabled` / `oauth_issuer_url` takes
  effect on every node within the TTL (default 2 s, at most 5 s), never later. The cache is the same class
  as `Nebu.Web.OidcConfig` and the JWT denylist cache; no correctness property (single-use codes, rotation,
  revocation) depends on it, those stay atomic SQL. `pending_limits/0` and `token_settings/0` stay
  UNCACHED (rate limited / authenticated callers; their values must apply on the next registration / refresh).

  ## The saved Matrix session lifetime (story session-lifetime-setting)

  The same read (one SQL, one cache entry) also carries `matrix_session_ttl_seconds`, the Admin-saved lifetime of a Matrix session (whole seconds,
  `3600..7_776_000`; ONE parser, `parse_matrix_session_ttl/1`, shared with the Admin form). It is read at every login, `/refresh` and background refresh row,
  so with the cache off (`NEBU_OAUTH_CONFIG_CACHE_MS=0`) that is one query per call. A saved value must never turn LONGER because a read failed: the
  **last-known-good** rule keeps, per node and without a TTL (`Nebu.OAuth.LastGood`), the last successfully read valid value. A failed read or a damaged /
  out of range row answers it; the env value / 8 hours apply only when no good value was ever loaded on this node or after a successful read that found no
  row (removed on purpose). A deliberate Admin save on this node replaces it at once (`note_saved_matrix_session_ttl/1`, after the commit). The warning for a
  damaged row is rate limited (one per minute per node) and never names the value. `get/1` itself stays fail closed for the OAuth switch (`state: :unknown`).

  ## Test seam (same idiom as `Nebu.Web.OidcConfig` / `:oidc_config_source`)

  `Application.put_env(:nebu_http, :oauth_config_source, fn -> %{enabled: true, issuer_url: "https://..."} end)`
  replaces the DB read. A partial map is normalized (`enabled` must be exactly `true` to count).
  The fun may return `:unknown` (or `{:error, _}`) to simulate an unreadable `server_config`.
  `:nebu_http, :oauth_config_repo` replaces the repo module of the DB read (default `Nebu.Repo`); the
  seam bypasses the cache entirely. `:oauth_config_cache_clock_fn` (0-arity, integer milliseconds) injects
  the cache clock. All three seams are read through `seam/2`, which exists only in `Mix.env() == :test`
  builds (a stray `Application.put_env` in a release can never switch OAuth on, HY5).
  """

  require Logger

  @type state :: :enabled | :disabled | :unknown
  @type t :: %{enabled: boolean(), issuer_url: String.t() | nil, state: state(), matrix_session_ttl_seconds: pos_integer() | nil}
  @type pending_limits :: %{ttl_days: pos_integer(), cap: pos_integer(), host_cap: pos_integer()}
  @type token_settings :: %{access_token_ttl_seconds: 60..3600, idp_revalidation: :per_refresh | :off}

  @default_pending_ttl_days 30
  @default_pending_cap 5000
  @default_pending_host_cap 20
  @max_pending_ttl_days 3650
  @max_pending_cap 10_000_000

  @default_access_token_ttl_seconds 900
  @min_access_token_ttl_seconds 60
  @max_access_token_ttl_seconds 3600

  # at most one WARNING per minute per node on the bounded (health check) path and for a damaged saved lifetime
  @bounded_warning_per_min 1

  # story session-lifetime-setting: the Admin-saved Matrix session lifetime (whole seconds), read with the switch state through the same cache
  @min_matrix_session_ttl_seconds 3600
  @max_matrix_session_ttl_seconds 7_776_000

  @sql """
  SELECT key, value FROM server_config
  WHERE key IN ('oauth_enabled', 'oauth_issuer_url', 'oauth_pending_ttl_days', 'oauth_pending_cap',
                'oauth_pending_host_cap', 'oauth_access_token_ttl_seconds', 'oauth_idp_revalidation',
                'matrix_session_ttl_seconds')
  """

  @doc "The bounds of the saved Matrix session lifetime in seconds: `{3600, 7_776_000}` (1 hour .. 90 days)."
  @spec matrix_session_ttl_bounds() :: {pos_integer(), pos_integer()}
  def matrix_session_ttl_bounds, do: {@min_matrix_session_ttl_seconds, @max_matrix_session_ttl_seconds}

  @doc """
  The saved Matrix session lifetime (`server_config.matrix_session_ttl_seconds`, whole seconds `3600..7_776_000`) or `nil` when none is saved and none was
  ever loaded on this node. A failed read of `server_config` or a damaged / out of range row answers the last known good value of this node
  (`Nebu.OAuth.LastGood`), never a longer fallback. Served from the per-node cache of `get/1` (at most one `server_config` query per TTL window). Never raises.
  """
  @spec matrix_session_ttl_seconds() :: pos_integer() | nil
  def matrix_session_ttl_seconds, do: get().matrix_session_ttl_seconds

  @doc """
  The ONE parser of the bounded lifetime (used by the Admin form and by the reader, so they never disagree): text (white space trimmed, plain decimal
  digits) or an integer inside `matrix_session_ttl_bounds/0` -> `{:ok, seconds}`, everything else `:error`. Never raises.
  """
  @spec parse_matrix_session_ttl(term()) :: {:ok, pos_integer()} | :error
  def parse_matrix_session_ttl(value) when is_integer(value) and value >= @min_matrix_session_ttl_seconds and value <= @max_matrix_session_ttl_seconds, do: {:ok, value}

  def parse_matrix_session_ttl(value) when is_binary(value) do
    trimmed = String.trim(value)

    with true <- Regex.match?(~r/\A[0-9]{1,12}\z/, trimmed),
         n = String.to_integer(trimmed),
         true <- n >= @min_matrix_session_ttl_seconds and n <= @max_matrix_session_ttl_seconds do
      {:ok, n}
    else
      _ -> :error
    end
  end

  def parse_matrix_session_ttl(_other), do: :error

  # the raw value of the config SEAM (no database, no last known good): a damaged one is ignored with the rate limited warning
  defp seam_session_ttl(nil), do: nil

  defp seam_session_ttl(raw) do
    case parse_matrix_session_ttl(raw) do
      {:ok, n} ->
        n

      :error ->
        warn_damaged_session_ttl()
        nil
    end
  end

  # at most one WARNING per minute per node (abuse / log-volume control only): the cache refills about every 2 s, with the cache off on every call
  defp warn_damaged_session_ttl do
    if Nebu.Web.Plugs.RateLimit.take({"oauth_config_read_warning", :matrix_session_ttl}, @bounded_warning_per_min, 1) == :ok do
      Logger.warning("OAuth.Config: server_config matrix_session_ttl_seconds is not a whole number of seconds between 3600 and 7776000: ignored, the last good value / env value / default applies")
    end

    :ok
  end

  # The value of a SUCCESSFUL read of the row: valid -> it becomes the last good one; no row -> the saved value ended on purpose (env / 8 hours apply);
  # damaged -> ignored, the last good one stays.
  defp resolve_saved_ttl(nil, gen), do: Nebu.OAuth.LastGood.clear_if(gen)

  defp resolve_saved_ttl(raw, gen) do
    case parse_matrix_session_ttl(raw) do
      {:ok, n} ->
        Nebu.OAuth.LastGood.put_if(gen, n)

      :error ->
        warn_damaged_session_ttl()
        Nebu.OAuth.LastGood.get()
    end
  end

  @doc """
  A deliberate Admin save on THIS node (called after the commit): `value` (the saved text) becomes the last known good lifetime at once, without a read in
  between, and the cache entry is dropped. Never raises.
  """
  @spec note_saved_matrix_session_ttl(term()) :: :ok
  def note_saved_matrix_session_ttl(value) do
    case parse_matrix_session_ttl(value) do
      {:ok, n} -> Nebu.OAuth.LastGood.put_saved(n)
      :error -> nil
    end

    invalidate_cache()
  end

  if Mix.env() == :test do
    @doc false
    def reset_last_good_for_test do
      Nebu.OAuth.LastGood.reset()
      :ok
    end
  end

  @doc """
  Returns `%{enabled: boolean, issuer_url: binary | nil, state: :enabled | :disabled | :unknown, matrix_session_ttl_seconds: pos_integer | nil}`. The OAuth switch
  fails closed (an unreadable `server_config` is `state: :unknown`, `enabled: false`); `matrix_session_ttl_seconds` is the saved lifetime with the
  last-known-good rule (see the moduledoc). Never raises.
  """
  @spec get(keyword()) :: t()
  def get(opts \\ []) do
    case seam(:oauth_config_source, nil) do
      fun when is_function(fun, 0) -> normalize(fun.())
      _ -> cached_load(opts)
    end
  end

  @default_cache_ms 2000
  @max_cache_ms 5000
  @cache_table :nebu_oauth_config_cache

  @doc """
  Parses `NEBU_OAUTH_CONFIG_CACHE_MS` (pure): an integer in `0..#{@max_cache_ms}` (milliseconds, `0` = cache off);
  `nil`, junk, a negative or too large value => #{@default_cache_ms}.
  """
  @spec parse_cache_ms(term()) :: 0..5000
  def parse_cache_ms(value) when is_integer(value) and value >= 0 and value <= @max_cache_ms, do: value

  def parse_cache_ms(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} -> parse_cache_ms(n)
      _ -> @default_cache_ms
    end
  end

  def parse_cache_ms(_other), do: @default_cache_ms

  # Seams exist only in test builds (HY5): the default is returned everywhere else.
  if Mix.env() == :test do
    defp seam(key, default), do: Application.get_env(:nebu_http, key, default)
  else
    defp seam(_key, default), do: default
  end

  defp cache_ttl_ms do
    case Application.get_env(:nebu_http, :oauth_config_cache_ms, @default_cache_ms) do
      ms when is_integer(ms) and ms > 0 and ms <= @max_cache_ms -> ms
      _ -> 0
    end
  end

  @doc "The effective TTL of the per-node switch cache in milliseconds (`0` = the cache is off). Never raises."
  @spec cache_ms() :: 0..5000
  def cache_ms, do: cache_ttl_ms()

  @doc """
  Drops this node's cache entry of the switch state (story admin-oauth-switch, AS8): called by the Admin UI writer
  (`Nebu.OAuth.SwitchStore`) after the commit, so the saving node answers with the new state at once. Other nodes expire their
  entry within the TTL. A missing table (owner not running, early boot, unit runs) is a no-op. Never raises.
  """
  @spec invalidate_cache() :: :ok
  def invalidate_cache do
    :ets.delete(@cache_table, :config)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp cache_now_ms do
    case seam(:oauth_config_cache_clock_fn, nil) do
      fun when is_function(fun, 0) -> fun.()
      _ -> System.monotonic_time(:millisecond)
    end
  end

  # Only `{:cache, map}` results (a successful server_config read) are written; `{:nocache, map}`
  # (`:unknown`, `:no_repo`) never. A missing table is a miss and a skipped write (never created here).
  defp cached_load(opts) do
    case cache_ttl_ms() do
      0 ->
        {_kind, config} = load_from_db(opts, Nebu.OAuth.LastGood.generation())
        config

      ttl ->
        now = cache_now_ms()

        case cache_lookup(now, ttl) do
          {:hit, config} ->
            config

          :miss ->
            # the generation is captured BEFORE the query: a save that commits while this read is in flight bumps it, and the (older) answer is then
            # neither remembered as last good nor written into the cache entry the save dropped (cycle 2, Kassandra delta LOW #1)
            gen = Nebu.OAuth.LastGood.generation()

            case load_from_db(opts, gen) do
              {:cache, config} ->
                if Nebu.OAuth.LastGood.generation() == gen, do: cache_store(config, now)
                config

              {:nocache, config} ->
                config
            end
        end
    end
  end

  defp cache_lookup(now, ttl) do
    case :ets.lookup(@cache_table, :config) do
      [{:config, %{} = config, loaded_at}] when is_integer(loaded_at) and now - loaded_at >= 0 and now - loaded_at < ttl ->
        {:hit, config}

      _ ->
        :miss
    end
  rescue
    ArgumentError -> :miss
  end

  defp cache_store(config, now) do
    :ets.insert(@cache_table, {:config, config, now})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  The ONE liveness predicate of the OAuth surface (story oauth-legacy-coexistence, C1): `{:live, issuer}`
  when `state` is `:enabled` AND the issuer normalizes (`Nebu.OAuth.Metadata.normalize_issuer/1`),
  `:unknown` when `server_config` is unreadable, `:off` otherwise (disabled, or an enabled switch with a
  missing / non-https / path-carrying issuer: fail closed). Shared by `Nebu.OAuth.Http` (kill switch of
  token / JWKS / openid-configuration), `Nebu.OAuth.oauth_aware?/0` (OAuth-aware login flags, SSO
  `action`, the `GET /_matrix/client/versions` list v1.1-v1.15, story oauth-versions-switch),
  `Nebu.OAuth.Authorize.live_issuer/0` (authorize, the account page), `Nebu.OAuth.Http.auth_issuer/1` and — by
  construction — the `auth_metadata` answer: they are present IFF it is `200`.
  Evaluated per call on top of the per-node config cache (at most `NEBU_OAUTH_CONFIG_CACHE_MS` stale, HY1). Never raises beyond `get/0`'s own guarantees.

  Option `bounded: true` (used ONLY by `GET /_matrix/client/versions`, the load-balancer health check,
  story oauth-versions-switch review cycle 1 / Kassandra F-1): the `server_config` read gets a 500 ms pool
  checkout and query timeout (a slow or locked table is `:unknown`, i.e. fail closed, instead of a hanging
  health check) and its WARNING is throttled to one per minute per node. Every other caller keeps the
  default timeouts and the per-request warning.
  """
  @spec live_state(keyword()) :: {:live, String.t()} | :unknown | :off
  def live_state(opts \\ []) do
    config = get(opts)

    case config.state do
      :unknown ->
        :unknown

      :enabled ->
        case Nebu.OAuth.Metadata.normalize_issuer(config.issuer_url) do
          {:ok, issuer} -> {:live, issuer}
          :error -> :off
        end

      _ ->
        :off
    end
  end

  @doc """
  The normalized configured issuer URL (`Nebu.OAuth.Metadata.normalize_issuer/1`) REGARDLESS of `oauth_enabled`
  (story legacy-sso-redirect-confirmation, G3-3, D6: the issuer's origin is trusted by the legacy SSO login also
  while OAuth is off): `{:ok, issuer}`, or `:none` for an absent / invalid issuer or an unreadable `server_config`.
  Options as `get/1` (`bounded: true` = the 500 ms bound). Never raises beyond `get/1`'s own guarantees.
  """
  @spec configured_issuer(keyword()) :: {:ok, String.t()} | :none
  def configured_issuer(opts \\ []) do
    case get(opts) do
      %{issuer_url: url} when is_binary(url) ->
        case Nebu.OAuth.Metadata.normalize_issuer(url) do
          {:ok, issuer} -> {:ok, issuer}
          :error -> :none
        end

      _ ->
        :none
    end
  end

  @doc "True when OAuth is enabled (fail closed)."
  @spec enabled?() :: boolean()
  def enabled?, do: get().enabled

  @doc """
  `%{ttl_days:, cap:, host_cap:}` (all positive integers) — the pending-registration TTL, the global
  pending cap and the per-`client_uri`-host pending cap (defaults 30, 5000 and 20 when the key is
  absent/invalid or the database is unreachable). Never raises.

  With the `:oauth_config_source` seam installed the optional `:pending_ttl_days` / `:pending_cap` /
  `:pending_host_cap` keys of its map are used (absent => defaults), so DB-less tests stay
  deterministic.
  """
  @spec pending_limits() :: pending_limits()
  def pending_limits do
    raw =
      case seam(:oauth_config_source, nil) do
        fun when is_function(fun, 0) ->
          case fun.() do
            %{} = m ->
              %{
                ttl: Map.get(m, :pending_ttl_days),
                cap: Map.get(m, :pending_cap),
                host_cap: Map.get(m, :pending_host_cap)
              }
            _ -> %{}
          end

        _ ->
          case load_raw() do
            {:ok, map} ->
              %{
                ttl: map["oauth_pending_ttl_days"],
                cap: map["oauth_pending_cap"],
                host_cap: map["oauth_pending_host_cap"]
              }
            _unreadable -> %{}
          end
      end

    %{
      ttl_days: positive(raw[:ttl], @default_pending_ttl_days, @max_pending_ttl_days),
      cap: positive(raw[:cap], @default_pending_cap, @max_pending_cap),
      host_cap: positive(raw[:host_cap], @default_pending_host_cap, @max_pending_cap)
    }
  end

  @doc """
  `%{access_token_ttl_seconds:, idp_revalidation:}` for the token endpoint (story oauth-token-endpoint,
  AC15, T4/T5):

    * `oauth_access_token_ttl_seconds` — lifetime of a Nebu OAuth access token, an integer in
      #{@min_access_token_ttl_seconds}..#{@max_access_token_ttl_seconds}; anything else (absent, junk, out of range) => #{@default_access_token_ttl_seconds}
      (never "unlimited").
    * `oauth_idp_revalidation` — `"off"` => `:off` (only `users.is_active` is re-checked on a
      refresh); everything else, also absent or unknown values => `:per_refresh` (fail safe: the
      stored IdP refresh token is redeemed on every Nebu refresh).

  Defaults also when `server_config` cannot be read. Never raises. With the `:oauth_config_source`
  seam the optional `:access_token_ttl_seconds` / `:idp_revalidation` map keys are used (raw text as
  stored, or an integer / atom).
  """
  @spec token_settings() :: token_settings()
  def token_settings do
    raw =
      case seam(:oauth_config_source, nil) do
        fun when is_function(fun, 0) ->
          case fun.() do
            %{} = m -> %{ttl: Map.get(m, :access_token_ttl_seconds), mode: Map.get(m, :idp_revalidation)}
            _ -> %{}
          end

        _ ->
          case load_raw() do
            {:ok, map} -> %{ttl: map["oauth_access_token_ttl_seconds"], mode: map["oauth_idp_revalidation"]}
            _unreadable -> %{}
          end
      end

    %{access_token_ttl_seconds: access_ttl(raw[:ttl]), idp_revalidation: revalidation_mode(raw[:mode])}
  end

  defp access_ttl(value)
       when is_integer(value) and value >= @min_access_token_ttl_seconds and value <= @max_access_token_ttl_seconds,
       do: value

  defp access_ttl(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} when is_integer(n) -> if n >= @min_access_token_ttl_seconds and n <= @max_access_token_ttl_seconds, do: n, else: @default_access_token_ttl_seconds
      _ -> @default_access_token_ttl_seconds
    end
  end

  defp access_ttl(_value), do: @default_access_token_ttl_seconds

  defp revalidation_mode(:off), do: :off
  defp revalidation_mode(value) when is_binary(value), do: if(String.trim(value) == "off", do: :off, else: :per_refresh)
  defp revalidation_mode(_value), do: :per_refresh

  defp positive(value, _default, max) when is_integer(value) and value >= 1 and value <= max, do: value

  defp positive(value, default, max) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} -> positive(n, default, max)
      _ -> default
    end
  end

  defp positive(_value, default, _max), do: default

  defp load_from_db(opts, gen) do
    case load_raw(opts) do
      {:ok, map} ->
        {:cache,
         normalize(%{
           enabled: map["oauth_enabled"] == "true",
           issuer_url: map["oauth_issuer_url"],
           matrix_session_ttl_seconds: resolve_saved_ttl(map["matrix_session_ttl_seconds"], gen)
         })}

      :error ->
        # a failed read is never cached; the lifetime keeps its last known good value (the OAuth switch stays fail closed: state :unknown)
        {:nocache, %{unknown() | matrix_session_ttl_seconds: Nebu.OAuth.LastGood.get()}}

      :no_repo ->
        # no repository process (a Repo restart): still the last known good lifetime, the OAuth switch stays disabled (fail closed)
        {:nocache, %{disabled() | matrix_session_ttl_seconds: Nebu.OAuth.LastGood.get()}}
    end
  end

  # `{:ok, %{key => value}}` for the oauth_* server_config keys, `:error` when they cannot be read,
  # `:no_repo` when there is no repository process at all.
  @bounded_timeout_ms 500

  defp load_raw(opts \\ []) do
    repo = seam(:oauth_config_repo, Nebu.Repo)
    bounded = Keyword.get(opts, :bounded, false)
    query_opts = if bounded, do: [timeout: @bounded_timeout_ms, pool_timeout: @bounded_timeout_ms], else: []

    if Process.whereis(repo) != nil do
      case Ecto.Adapters.SQL.query(repo, @sql, [], query_opts) do
        {:ok, %{rows: rows}} ->
          {:ok, Map.new(rows, fn [k, v] -> {k, v} end)}

        {:error, reason} ->
          warn(bounded, "OAuth.Config: could not read server_config: #{log_reason(reason)}")
          :error
      end
    else
      :no_repo
    end
  rescue
    e ->
      warn(Keyword.get(opts, :bounded, false), "OAuth.Config: unexpected error reading server_config: #{log_reason(e)}")
      :error
  catch
    :exit, _ ->
      warn(Keyword.get(opts, :bounded, false), "OAuth.Config: server_config read exited")
      :error
  end

  # The bounded path is a health check hit by every load balancer probe: during a database outage it must
  # not write one line per probe. Abuse / log-volume control only (node-local bucket), never correctness.
  defp warn(false, message), do: Logger.warning(message)

  defp warn(true, message) do
    if Nebu.Web.Plugs.RateLimit.take({"oauth_config_read_warning", :versions}, @bounded_warning_per_min, 1) == :ok,
      do: Logger.warning(message)
  end

  # Only the exception type / SQLSTATE is logged (no `inspect` of a driver error).
  defp log_reason(%Postgrex.Error{postgres: %{code: code}}), do: "postgres #{code}"
  defp log_reason(%{__struct__: struct}), do: inspect(struct)
  defp log_reason(_other), do: "unexpected error"

  defp normalize(:unknown), do: unknown()
  defp normalize({:error, _reason}), do: unknown()

  defp normalize(%{} = raw) do
    enabled = Map.get(raw, :enabled) == true

    %{
      enabled: enabled,
      issuer_url: nilify(Map.get(raw, :issuer_url)),
      state: if(enabled, do: :enabled, else: :disabled),
      matrix_session_ttl_seconds: seam_session_ttl(Map.get(raw, :matrix_session_ttl_seconds))
    }
  end

  defp normalize(_other), do: disabled()

  defp disabled, do: %{enabled: false, issuer_url: nil, state: :disabled, matrix_session_ttl_seconds: nil}
  defp unknown, do: %{enabled: false, issuer_url: nil, state: :unknown, matrix_session_ttl_seconds: nil}

  defp nilify(v) when is_binary(v) do
    case String.trim(v) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp nilify(_), do: nil
end
