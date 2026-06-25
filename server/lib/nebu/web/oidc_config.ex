defmodule Nebu.Web.OidcConfig do
  @moduledoc """
  ETS-backed cache for OIDC issuer, audience, and JWKS URI resolved from
  `server_config`.

  ## Purpose

  When `NEBU_OIDC_ISSUER` / `NEBU_OIDC_AUDIENCE` are not set as environment
  variables (bootstrap-wizard deployment), `OidcPlug` must still be able to
  resolve those values after the Bootstrap Wizard writes them to `server_config`.
  A per-request DB call on the hot token-validation path is unacceptable, so this
  module caches the values in a named ETS table.

  ## Interface

  - `get/0` — returns `%{issuer: binary() | nil, audience: binary() | nil}`.
  - `jwks_uri/0` — returns the `oidc_jwks_uri` from `server_config` (used by
    `JwksCache` on bootstrap-wizard deployments where `NEBU_OIDC_JWKS_URI` is
    not set as an env var).
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

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc """
  Returns the currently cached OIDC config.

  Checks, in order:
  1. `:nebu_http, :oidc_config_source` seam (for unit tests)
  2. ETS cache populated by this GenServer
  3. Falls back to `%{issuer: nil, audience: nil}` when nothing is configured.
  """
  @spec get() :: %{issuer: binary() | nil, audience: binary() | nil}
  def get do
    case Application.get_env(:nebu_http, :oidc_config_source) do
      fun when is_function(fun, 0) ->
        fun.()

      _ ->
        read_from_ets()
    end
  end

  @doc """
  Returns the cached JWKS URI from `server_config`, or nil when not set.

  Used by `JwksCache` as a fallback when `NEBU_OIDC_JWKS_URI` env var is absent
  (bootstrap-wizard deployments store the JWKS URI in `server_config` via the
  wizard's step-2 form field). Falls back to `nil` when not in the ETS cache.
  """
  @spec jwks_uri() :: binary() | nil
  def jwks_uri do
    case read_from_ets() do
      %{jwks_uri: uri} -> uri
      _ -> nil
    end
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
        %{issuer: nil, audience: nil, jwks_uri: nil}

      _ ->
        case :ets.lookup(@table, :config) do
          [{:config, config}] -> config
          _ -> %{issuer: nil, audience: nil, jwks_uri: nil}
        end
    end
  rescue
    e ->
      Logger.warning("OidcConfig: unexpected error reading ETS table: #{inspect(e)}")
      %{issuer: nil, audience: nil, jwks_uri: nil}
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

  @sql_load_oidc_config """
  SELECT key, value FROM server_config
  WHERE key IN ('oidc_issuer', 'oidc_audience', 'oidc_jwks_uri')
  """

  defp load_from_db do
    if Process.whereis(Nebu.Repo) != nil do
      case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_load_oidc_config, []) do
        {:ok, %{rows: rows}} ->
          map = Map.new(rows, fn [k, v] -> {k, v} end)

          %{
            issuer: nilify(map["oidc_issuer"]),
            audience: nilify(map["oidc_audience"]),
            jwks_uri: nilify(map["oidc_jwks_uri"])
          }

        {:error, reason} ->
          Logger.warning("OidcConfig: failed to load from server_config: #{inspect(reason)}")
          %{issuer: nil, audience: nil, jwks_uri: nil}
      end
    else
      %{issuer: nil, audience: nil, jwks_uri: nil}
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
