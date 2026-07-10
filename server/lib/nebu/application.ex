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
    Nebu.Matrix.AccountDataStore.init_table()

    # enhanced-logging/matrix-payload-debug-logging (CI-gate cycle-2, global fix):
    # `Nebu.Repo` runs with `log: false` (server/config/config.exs) — Ecto's own
    # query logger prints bound SQL parameter values (which include credentials
    # such as opaque tokens) verbatim at :debug level, so it is disabled globally.
    # This attaches the sanitized replacement (source + duration only, never bound
    # params) to Ecto's `[:nebu, :repo, :query]` telemetry event, which Ecto still
    # emits unconditionally. Attaching is harmless when no Repo is configured (no
    # DB in pure unit runs) — the event simply never fires.
    Nebu.Repo.QueryTelemetry.attach()

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

    # enhanced-logging/operational-log-store (AC2): attaches the central
    # :logger handler that intercepts every Logger.* call app-wide. Safe to
    # call before the supervisor tree starts — the handler's own broadcast
    # (Nebu.PubSub, started as a child below) and persistence (Writer, also
    # below) paths each guard against their target process not being up yet.
    #
    # Gated behind :attach_log_store_handler (default true; test env sets it
    # false, mirroring start_jwks_cache/start_admin_endpoint/start_finch) so
    # `log_store_test.exs`'s own "registers exactly one new handler"
    # idempotency-count test (which must observe a handler_ids delta of
    # exactly +1 from ITS OWN call) is not pre-empted by a boot-time attach
    # that already happened before any test runs — the handler still gets
    # attached explicitly wherever a test/AC needs it (attach_handler/0 is
    # idempotent either way), and in prod/dev it is attached unconditionally
    # at boot per AC2.
    if Application.get_env(:nebu_http, :attach_log_store_handler, true) do
      :ok = Nebu.Web.LogStore.attach_handler()
    end

    children =
      # Nebu.PubSub: the central :logger handler (attached above) broadcasts
      # EVERY Logger.* call here, regardless of whether DB persistence is
      # enabled (and regardless of whether Nebu.Repo is configured at all —
      # plain unit runs have no DB but still exercise attach_handler/0's
      # broadcast-only path, AC2/AC10). Started unconditionally (unlike
      # Nebu.Admin.PubSub, which is gated behind start_admin_endpoint) so it
      # is available in every environment, including a DB-less unit run.
      [Supervisor.child_spec({Phoenix.PubSub, name: Nebu.PubSub}, id: Nebu.PubSub)] ++
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
  # S3: the auth-row sweeper (expired jwt_device_bindings + uia_sessions) is started
  # alongside the Repo — it has nothing to sweep without a DB, and gating it here keeps
  # the no-DB unit child count unchanged.
  # server-paced-session-refresh: RefreshWorker (proactive background renewal of
  # opaque matrix_sessions rows nearing their bound expires_at) is started the
  # same way — it has nothing to refresh without a DB either.
  # enhanced-logging/operational-log-store: Nebu.Web.LogStore.Writer (batches
  # operational_logs INSERTs) is started the same way — it has nothing to
  # flush to without a DB either. Supervised with the Supervisor default
  # (:permanent) restart strategy, same as every other child here, so a
  # crashed Writer is restarted under the same registered name (AC6).
  # Nebu.Web.LogStore.PolicyCache (refreshes the should_persist?/1 cache from
  # server_config) is started alongside it — nothing to cache without a DB
  # either.
  # enhanced-logging/war-room-mode (design-decisions.md #4):
  # Nebu.Web.LogStore.WarRoom (caches the single active war room session +
  # owns the increment/timeout atomicity boundary) is started the same way,
  # right alongside Writer/PolicyCache — nothing to cache without a DB
  # either, and the same :permanent supervisor-restart contract applies (a
  # crashed WarRoom is restarted under the same registered name; its own
  # init/1 reloads the active session from the DB, immediately ending it if
  # it is already past its max_duration_s deadline — AC5 across a restart).
  # enhanced-logging/trace-map-node-controls: Nebu.Web.LogStore.CaptureCache
  # (caches which off-list endpoints have an active temporary capture, for
  # should_persist?/2's hot path) is started the same way — nothing to
  # cache without a DB either.
  defp repo_children do
    if Application.get_env(:nebu, Nebu.Repo),
      do: [
        Nebu.Repo,
        Nebu.Matrix.Session.Sweeper,
        Nebu.Matrix.Session.RefreshWorker,
        Nebu.Web.LogStore.Writer,
        Nebu.Web.LogStore.PolicyCache,
        Nebu.Web.LogStore.WarRoom,
        Nebu.Web.LogStore.CaptureCache
      ],
      else: []
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
      [
        # oidc-env-optional-bootstrap: OidcConfig caches issuer/audience from
        # server_config so OidcPlug can read them without a per-request DB query.
        # Started before JwksCache so the config is warm before any key fetch.
        Nebu.Web.OidcConfig,
        {Nebu.Web.JwksCache, []}
      ]
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
      # enhanced-logging/operational-log-store: gave this child an explicit
      # :id (default would be Phoenix.PubSub.Supervisor for every
      # {Phoenix.PubSub, ...} child, colliding with the always-started
      # Nebu.PubSub child above — Supervisor.start_link/2 rejects duplicate
      # child ids).
      [
        Supervisor.child_spec({Phoenix.PubSub, name: Nebu.Admin.PubSub}, id: Nebu.Admin.PubSub),
        Nebu.Admin.Endpoint
      ]
    else
      []
    end
  end

  defp http_port, do: Application.get_env(:nebu_http, :port, 4000)
end
