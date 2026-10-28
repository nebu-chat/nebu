defmodule Nebu.Web.OidcConfig do
  @moduledoc """
  ETS-backed cache for OIDC issuer, audience, and JWKS URI resolved from
  `server_config`.

  ## Purpose

  OIDC is configured EXCLUSIVELY through the Bootstrap Wizard (ADR-022) — there is
  no environment-variable config path. After the wizard writes issuer/audience/JWKS
  URI to `server_config`, `OidcPlug` (and `SsoLogin`/`Admin.Auth`) resolve those
  values through this cache. A per-request DB call on the hot token-validation path
  is unacceptable, so this module caches the values in a named ETS table.

  ## Operational contract: `issuer` must be reachable from BOTH sides (bugfix-oidc-public-endpoint-urls)

  `:issuer` is the IdP's identity — used BOTH for Nebu's own outbound calls
  (discovery fetch, token exchange, JWKS fetch, all via this same URL) AND, via
  the fetched discovery document's `authorization_endpoint`, as the target of the
  browser-facing SSO redirect (`Nebu.Matrix.SsoLogin`, `Nebu.Admin.Auth`). This is
  the same single-URL contract every OIDC library/framework expects — Nebu does
  NOT maintain a separate "internal" vs. "public" issuer, and does NOT rewrite any
  fetched discovery document's endpoint URLs (an earlier cycle of this bugfix
  tried that; code review rejected it as fragile — see
  `Nebu.Matrix.OidcMetadata` moduledoc for why).
  Operators deploying against a real IdP (Keycloak, Dex, ...) MUST therefore
  ensure the URL configured here resolves and connects both from the Nebu
  server's own network AND from end users' browsers. For a real deployment this
  is standard OIDC practice — a public DNS name, or split-horizon DNS in an
  enterprise network, resolving to the IdP from both vantage points. For local
  Docker Compose dev, see `dev/dex/config.yaml` + the `dex` service's network
  alias in `docker-compose.yml`: Dex is configured with a public-DNS-resolvable
  issuer hostname (`dex.localtest.me`, via the `*.localtest.me` wildcard-to-
  127.0.0.1 convention) that ALSO resolves to the same container from inside the
  compose network via that alias — no `/etc/hosts` edit needed, no origin
  rewriting anywhere in this codebase.

  ## Interface

  - `get/0` — returns `%{issuer: binary() | nil, audience: binary() | nil}`.
  - `jwks_uri/0` — returns the `oidc_jwks_uri` from `server_config` (used by
    `JwksCache` to resolve the signing-key endpoint).
  - `get_scopes/0` — returns `%{matrix_oidc_extra_scopes:, matrix_oidc_refresh_mode:,
    admin_oidc_extra_scopes:, admin_oidc_refresh_mode:}` (story
    `centralize-scope-resolution`, AC2). Consumed by `Nebu.Web.OidcScopes` instead
    of a second, independent cache — the four scope/refresh-mode keys live in the
    SAME ETS table and are refreshed/broadcast by the SAME `refresh/0` path as
    issuer/audience/jwks_uri.
  - `get_sso_extra_redirect_schemes/0` — returns the raw (unsplit) comma-separated
    `sso_extra_redirect_schemes` string from `server_config`, or `nil` when unset
    (story `fix-and-configure-sso-redirect-schemes`, AC6/AC7). Consumed by
    `Nebu.Matrix.SsoLogin.extra_redirect_schemes/0`. Reuses this SAME ETS table /
    GenServer / `:pg` broadcast — the SSO redirect allowlist is, like OIDC scopes,
    a bootstrap-only, infrequently-changed, hot-request-path SSO setting; a
    dedicated cache module would just duplicate this exact machinery.
  - `refresh/0` (or `refresh/1` with pid) — forces a synchronous re-read from
    `server_config` and updates the ETS cache. Called by the Bootstrap Wizard after
    it promotes the draft into `server_config` (AC2, AC5). Also broadcasts to
    peer nodes via `:pg` so the whole cluster refreshes (M-3, ADR-020).

  ## ETS table

  A named `protected` set `:nebu_http_oidc_config` with `read_concurrency: true`.
  The GenServer owns the table (`:protected` so only it can write). The table is
  node-local — that is correct because OIDC config is identical on all nodes and
  each node's ETS cache is refreshed via `:pg` broadcast.

  ## Cluster propagation (ADR-020 / M-3)

  The GenServer joins the `nebu_web_oidc_config` `:pg` group on init. On
  `refresh/0` it re-reads the DB, updates its local ETS cache, and broadcasts an
  invalidation to every OTHER group member so peer nodes also refresh. Single-node
  deployments are unaffected — the broadcast is a no-op.

  ## Seam (ADR-018 / test isolation)

  When `:nebu_http, :oidc_config_source` is set to a 0-arity fun, `get/0` calls it
  directly instead of reading from ETS or the DB. This lets unit tests inject the
  issuer/audience pair without a running GenServer or a live database.
  """

  use GenServer

  require Logger

  @table :nebu_http_oidc_config
  @pg_group "nebu_web_oidc_config"

  # Story centralize-scope-resolution (AC2): the cached config map now also
  # carries these 4 scope/refresh-mode keys, read/written by the SAME
  # do_refresh/0 -> load_from_db/0 path (and the SAME :pg broadcast on refresh/0)
  # as issuer/audience/jwks_uri — no second, independently-lived cache.
  @empty_config %{
    issuer: nil,
    audience: nil,
    jwks_uri: nil,
    matrix_oidc_extra_scopes: nil,
    matrix_oidc_refresh_mode: nil,
    admin_oidc_extra_scopes: nil,
    admin_oidc_refresh_mode: nil,
    sso_extra_redirect_schemes: nil,
    sso_redirect_allowed_origins: nil
  }

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc """
  Returns the currently cached OIDC config.

  Checks, in order:
  1. `:nebu_http, :oidc_config_source` seam (for unit tests)
  2. ETS cache populated by this GenServer
  3. Falls back to `%{issuer: nil, audience: nil, jwks_uri: nil}` when nothing is configured.

  The result always has the `:issuer`, `:audience`, and `:jwks_uri` keys (a partial
  seam map is normalized with nil defaults) so callers can read them without a KeyError.
  """
  @spec get() :: %{issuer: binary() | nil, audience: binary() | nil, jwks_uri: binary() | nil}
  def get do
    raw =
      case Application.get_env(:nebu_http, :oidc_config_source) do
        fun when is_function(fun, 0) -> fun.()
        _ -> read_from_ets()
      end

    %{
      issuer: Map.get(raw, :issuer),
      audience: Map.get(raw, :audience),
      jwks_uri: Map.get(raw, :jwks_uri)
    }
  end

  @doc """
  Returns the cached JWKS URI from `server_config`, or nil when not set.

  Used by `JwksCache` as the sole source of the JWKS URI (ADR-022): the bootstrap
  wizard stores it in `server_config` via its step-2 form field. Falls back to `nil`
  when not configured.
  """
  @spec jwks_uri() :: binary() | nil
  def jwks_uri do
    # Consult the same `:oidc_config_source` seam as get/0 so unit tests can inject
    # the JWKS URI without a running GenServer or DB (the seam map carries :jwks_uri).
    case Application.get_env(:nebu_http, :oidc_config_source) do
      fun when is_function(fun, 0) ->
        case fun.() do
          %{jwks_uri: uri} -> uri
          _ -> nil
        end

      _ ->
        case read_from_ets() do
          %{jwks_uri: uri} -> uri
          _ -> nil
        end
    end
  end

  @doc """
  Returns the cached OIDC scope/refresh-mode config (story
  `centralize-scope-resolution`, AC2): `matrix_oidc_extra_scopes`,
  `matrix_oidc_refresh_mode`, `admin_oidc_extra_scopes`, `admin_oidc_refresh_mode`.

  Extra-scope values default to `""` (never a hardcoded scope literal — OIDC
  Scopes Law); refresh-mode values default to `nil` when not yet populated (the
  caller, `Nebu.Web.OidcScopes`, applies its own per-client enum default).

  Reads through the SAME ETS table `get/0` and `jwks_uri/0` use when the owning
  GenServer is running (AC2 — the cache is warmed/broadcast via `refresh/0`,
  invalidated cluster-wide via `:pg` on an Admin-Config write). When the ETS
  table does not exist yet (the GenServer is not started — e.g. gated off under
  `mix test`, see `config/test.exs` `start_jwks_cache: false`), falls back to a
  direct, uncached `server_config` read so scope resolution stays correct even
  before/without a running cache process — mirroring the historical per-call SQL
  read behaviour the pre-refactor per-domain readers had. Once the GenServer
  starts, subsequent reads go through the ETS cache as normal.
  """
  @spec get_scopes() :: %{
          matrix_oidc_extra_scopes: binary(),
          matrix_oidc_refresh_mode: binary() | nil,
          admin_oidc_extra_scopes: binary(),
          admin_oidc_refresh_mode: binary() | nil
        }
  def get_scopes do
    raw =
      case :ets.whereis(@table) do
        :undefined -> load_from_db()
        _ -> read_from_ets()
      end

    %{
      matrix_oidc_extra_scopes: Map.get(raw, :matrix_oidc_extra_scopes) || "",
      matrix_oidc_refresh_mode: Map.get(raw, :matrix_oidc_refresh_mode),
      admin_oidc_extra_scopes: Map.get(raw, :admin_oidc_extra_scopes) || "",
      admin_oidc_refresh_mode: Map.get(raw, :admin_oidc_refresh_mode)
    }
  end

  @doc """
  Returns the raw `sso_extra_redirect_schemes` string from `server_config` (comma-
  separated, un-split), or `nil` when not set (story
  `fix-and-configure-sso-redirect-schemes`, AC6/AC7).

  Reads through the SAME ETS table as `get/0`/`get_scopes/0` when the owning
  GenServer is running; falls back to a direct, uncached `server_config` read when
  the ETS table does not exist yet (e.g. gated off under plain `mix test`).
  """
  @spec get_sso_extra_redirect_schemes() :: binary() | nil
  def get_sso_extra_redirect_schemes do
    raw =
      case :ets.whereis(@table) do
        :undefined -> load_from_db()
        _ -> read_from_ets()
      end

    Map.get(raw, :sso_extra_redirect_schemes)
  end

  @doc """
  Returns the raw `sso_redirect_allowed_origins` string from `server_config` (the normalized, comma+space
  separated https origins of the operator list, story `legacy-sso-redirect-confirmation`, D5), or `nil` when
  not set. Same shape and ETS fallback as `get_sso_extra_redirect_schemes/0`; a failed `server_config` read
  yields `nil` (an empty list: every https target is confirmed, fail closed).
  """
  @spec get_sso_redirect_allowed_origins() :: binary() | nil
  def get_sso_redirect_allowed_origins do
    raw =
      case :ets.whereis(@table) do
        :undefined -> load_from_db()
        _ -> read_from_ets()
      end

    Map.get(raw, :sso_redirect_allowed_origins)
  end

  @doc """
  Forces a synchronous re-read from `server_config` and updates the ETS cache.
  Also broadcasts an invalidation to peer nodes via `:pg` (ADR-020 / M-3).
  Pass a pid when targeting a non-registered instance (e.g. in tests).
  """
  @spec refresh(GenServer.server()) :: :ok
  def refresh(server \\ __MODULE__) do
    GenServer.call(server, :refresh)
  end

  @doc "The `:pg` group used for cross-node cache invalidation (ADR-020)."
  @spec pg_group() :: String.t()
  def pg_group, do: @pg_group

  # ── GenServer ────────────────────────────────────────────────────────────────

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl GenServer
  def init(_opts) do
    ensure_pg()
    :pg.join(@pg_group, self())
    ensure_table()
    do_refresh()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call(:refresh, _from, state) do
    do_refresh()
    broadcast()
    {:reply, :ok, state}
  end

  # A peer node broadcast an invalidation — re-read locally.
  @impl GenServer
  def handle_info({:invalidate_oidc_config}, state) do
    do_refresh()
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # ── Internals ────────────────────────────────────────────────────────────────

  defp do_refresh do
    config = load_from_db()
    :ets.insert(@table, {:config, config})
    config
  end

  defp read_from_ets do
    case :ets.whereis(@table) do
      :undefined ->
        @empty_config

      _ ->
        case :ets.lookup(@table, :config) do
          [{:config, config}] -> config
          _ -> @empty_config
        end
    end
  rescue
    e ->
      Logger.warning("OidcConfig: unexpected error reading ETS table: #{inspect(e)}")
      @empty_config
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        # M-4: use :protected (only the owning GenServer can write)
        :ets.new(@table, [:set, :protected, :named_table, read_concurrency: true])

      _ ->
        :ok
    end
  end

  @sql_load_oidc_config "SELECT key, value FROM server_config WHERE key IN (" <>
                          "'oidc_issuer', 'oidc_audience', 'oidc_jwks_uri', " <>
                          "'matrix_oidc_extra_scopes', 'matrix_oidc_refresh_mode', " <>
                          "'admin_oidc_extra_scopes', 'admin_oidc_refresh_mode', " <>
                          "'sso_extra_redirect_schemes', 'sso_redirect_allowed_origins')"

  defp load_from_db do
    if Process.whereis(Nebu.Repo) != nil do
      case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_load_oidc_config, []) do
        {:ok, %{rows: rows}} ->
          map = Map.new(rows, fn [k, v] -> {k, v} end)

          %{
            issuer: nilify(map["oidc_issuer"]),
            audience: nilify(map["oidc_audience"]),
            jwks_uri: nilify(map["oidc_jwks_uri"]),
            # Story centralize-scope-resolution (AC2): extra-scope values default to
            # "" (never nil→hardcoded-default — OIDC Scopes Law), refresh-mode
            # values are passed through raw (nil when absent) so
            # Nebu.Web.OidcScopes applies its own per-client enum default.
            matrix_oidc_extra_scopes: map["matrix_oidc_extra_scopes"] || "",
            matrix_oidc_refresh_mode: nilify(map["matrix_oidc_refresh_mode"]),
            admin_oidc_extra_scopes: map["admin_oidc_extra_scopes"] || "",
            admin_oidc_refresh_mode: nilify(map["admin_oidc_refresh_mode"]),
            # story fix-and-configure-sso-redirect-schemes (AC6/AC7): nil when unset
            # (Nebu.Matrix.SsoLogin.extra_redirect_schemes/0 treats nil/"" as []).
            sso_extra_redirect_schemes: nilify(map["sso_extra_redirect_schemes"]),
            # story legacy-sso-redirect-confirmation (G3-3, D5): the operator list of https origins whose legacy
            # SSO logins skip the confirmation page; nil when unset (read as an empty list).
            sso_redirect_allowed_origins: nilify(map["sso_redirect_allowed_origins"])
          }

        {:error, reason} ->
          Logger.warning("OidcConfig: failed to load from server_config: #{inspect(reason)}")
          @empty_config
      end
    else
      @empty_config
    end
  end

  # m-2: trim before nil-check so whitespace-only values are treated as absent
  defp nilify(v) when is_binary(v) do
    trimmed = String.trim(v)
    if trimmed != "", do: trimmed, else: nil
  end

  defp nilify(_), do: nil

  # Broadcast an invalidation to every OTHER group member (peer nodes).
  # On a single node this is a no-op (only self in the group).
  defp broadcast do
    self_pid = self()

    for pid <- :pg.get_members(@pg_group), pid != self_pid do
      send(pid, {:invalidate_oidc_config})
    end

    :ok
  end

  defp ensure_pg do
    case :pg.start_link() do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      _ -> :ok
    end
  end
end
