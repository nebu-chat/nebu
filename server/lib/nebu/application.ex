defmodule Nebu.Application do
  @moduledoc """
  The single OTP application for Nebu (ADR-019).

  All former umbrella apps (nebu_db, signature, permissions, presence, compliance,
  session_manager, room_manager, event_dispatcher, nebu_http) are consolidated into
  this one supervisor tree. Domains are module namespaces under `lib/nebu/`.

  Boot-time invariants (created here, owned by the application master process so they
  survive any supervised GenServer crash/restart):

    * ETS tables `:NebuSessions`, `:NebuPresence`, `:NebuTxnDedup` — guarded, idempotent.
    * `:pg` scope — started once.
    * `:nebu_signing_key` persistent_term — server-level Ed25519 key (MVP).
  """
  use Application

  @impl true
  def start(_type, _args) do
    # ── Boot-time ETS tables (idempotent guard — survive same-VM restarts) ──
    for {name, opts} <- [
          {:NebuSessions, [:named_table, :set, :public]},
          {:NebuPresence, [:named_table, :set, :public]},
          {:NebuTxnDedup, [:named_table, :set, :public]}
        ] do
      if :ets.whereis(name) == :undefined, do: :ets.new(name, opts)
    end

    # ── Request-time ETS tables created eagerly so the lazy fast path never races
    #    under concurrent first requests (security re-review R-2). ──
    Nebu.Web.TokenDenylist.init_table()
    Nebu.Web.Plugs.RateLimit.init_table()

    # ── :pg scope for room/presence process-group broadcast (ADR-002/005). ──
    case :pg.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    # ── Server-level Ed25519 signing key for MVP event signing (room_manager). ──
    # WARNING (MVP): regenerated on every OS/VM restart — events signed before a
    # restart are not verifiable with the new key. Phase 2 persists per-user keys to
    # the DB. Guarded so a same-VM re-entry (hot reload / test re-invocation of
    # start/2) does NOT swap the key out from under running signing processes.
    if :persistent_term.get(:nebu_signing_key, nil) == nil do
      {pub_key, priv_key} = :crypto.generate_key(:eddsa, :ed25519)
      :persistent_term.put(:nebu_signing_key, {pub_key, priv_key})
    end

    children =
      repo_children() ++
        libcluster_children() ++
        [
          # Crash-prone stateful Matrix processes (Presence, Session, Horde rooms),
          # isolated under a high-intensity child supervisor so individual crashes
          # never cascade to the root supervisor.
          Nebu.StatefulSupervisor,
          # Cluster-aware, single-use, TTL-bounded store for the Matrix client SSO
          # flow (state + opaque loginToken). Owns an ETS table and replicates
          # writes/deletes across the cluster via :pg so the /sso/redirect,
          # callback, and POST /login hops can land on different nodes (ADR-020).
          Nebu.Matrix.SsoStore,
          # Node-local cache of server_config.oidc_user_id_claim (story
          # oidc-claim-boot-cache). Owns its :pg group membership for cross-node
          # invalidation; the cached value lives in persistent_term for an O(1)
          # hot-path read. Supervised so a crash repopulates lazily on next get/0.
          Nebu.Matrix.OidcClaimCache,
          # Nebu.Compliance (cross-cutting) — child supervisor reads :compliance, :workers
          Nebu.Compliance.Supervisor
        ] ++
        jwks_cache_children() ++
        media_children() ++
        admin_children() ++
        [
          # The single Bandit HTTP listener serves everything: Matrix API, media,
          # /admin, and /health + /info. (The gRPC network listener was removed —
          # ADR-021/grpc-legacy-removal; the Matrix HTTP layer calls
          # Nebu.Matrix.EventDispatcher.Server in-process. The former standalone
          # Nebu.Health.Server gen_tcp listener was removed too — it bound the same
          # port 4000 as Bandit and only ever worked by losing the race; /health and
          # /info are now Bandit routes.)
          {Bandit, plug: Nebu.Web.Router, port: http_port()}
        ]

    opts = [strategy: :one_for_one, name: Nebu.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Start the Repo only when its config is present (unit runs without NEBU_DB_URL
  # start zero DB children). Repo config lives under the unified :nebu app key.
  defp repo_children do
    if Application.get_env(:nebu, Nebu.Repo), do: [Nebu.Repo], else: []
  end

  # Story 13-6: libcluster Cluster.Supervisor only when topologies are configured
  # (prod/dev with CLUSTER_STRATEGY set). Test / single-node mode skip it.
  defp libcluster_children do
    case Application.get_env(:libcluster, :topologies) do
      nil -> []
      [] -> []
      topologies -> [{Cluster.Supervisor, [topologies, [name: Nebu.ClusterSupervisor]]}]
    end
  end

  # JWKS cache (OIDC). Not started in test — jwks_cache_test starts its own instance
  # under the same registered name (config :nebu_http, :start_jwks_cache false).
  defp jwks_cache_children do
    if Application.get_env(:nebu_http, :start_jwks_cache, true) do
      [{Nebu.Web.JwksCache, []}]
    else
      []
    end
  end

  # Finch pool for media preview_url fetching. Disabled in test (fake fetch boundary).
  defp media_children do
    if Application.get_env(:nebu_http, :start_finch, true) do
      [{Finch, name: Nebu.Media.Finch}]
    else
      []
    end
  end

  # Phoenix LiveView Admin UI. Local PubSub (LiveView socket) + AdminEndpoint (server:
  # false; the main Bandit listener forwards /admin into it). Disabled in test so the
  # pure-unit children-count assertions are unaffected.
  defp admin_children do
    if Application.get_env(:nebu_http, :start_admin_endpoint, true) do
      [{Phoenix.PubSub, name: Nebu.Admin.PubSub}, Nebu.Admin.Endpoint]
    else
      []
    end
  end

  defp http_port, do: Application.get_env(:nebu_http, :port, 4000)
end
