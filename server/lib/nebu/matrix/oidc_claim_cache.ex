defmodule Nebu.Matrix.OidcClaimCache do
  @moduledoc """
  In-memory cache of the operator-configured `server_config.oidc_user_id_claim`
  (story `oidc-claim-boot-cache`).

  ## Why this exists

  `Nebu.Matrix.UserId.configured_claim/0` used to read
  `server_config.oidc_user_id_claim` from PostgreSQL on **every** identity
  derivation — i.e. on `POST /login` and on `OidcPlug.call/2` for every protected
  request. A prior fix wrapped that read in `try/rescue -> nil` so a
  registered-but-non-Ecto `Nebu.Repo` (boot/shutdown window, test placeholder)
  could not crash an authenticated request. Kassandra's SEC review flagged the
  **MEDIUM** residual: that rescue turns a fail-closed crash into a transient
  *fail-open-to-weaker-claim* — for an operator who set a **non-default**
  `oidc_user_id_claim` (e.g. `email`), two verified tokens could transiently
  collide on the same Matrix user_id (the identity-collision the `UserId`
  moduledoc calls CRITICAL) during any window where the live DB read fails.

  The claim changes **only** via the admin Claim-Mapping page and the equivalent
  gRPC `SetServerConfig` path — all three write paths route through
  `Nebu.Admin.DB.upsert_server_config/1`. So the value can be read **once** and
  cached, with explicit invalidation on update.

  This eliminates the per-request DB read and the fail-open window in
  **steady state**: once the claim has been read successfully even once, every
  later identity derivation is served from `persistent_term` with no DB query, so
  a DB outage at request time can no longer change how a token is attributed.

  Residual (accepted, much smaller than the original MEDIUM): the cache populates
  **lazily on first read**, so before the first successful read — a cold-start /
  boot window in which the Repo is unavailable — `get/0` still attempts a
  best-effort read and falls back to `nil` (the weaker claim chain) if it fails.
  The fail-open window is therefore bounded to "node start until the first
  successful claim read" instead of being perpetual/per-request. Closing it
  entirely would require a blocking eager read at boot (rejected: it would block
  startup on the DB and still cannot help when the Repo is genuinely not yet
  queryable — the very window that motivated the original rescue).

  ## Persistence / restart strategy (CLAUDE.md GenServer-state rule)

  State is VOLATILE node-local `persistent_term` — the same trade-off class as
  `Nebu.Web.JwksCache` / `Nebu.Web.TokenDenylist` / `Nebu.Matrix.SsoStore`. The
  hot path (`get/0`) reads `persistent_term` directly on the **caller** process,
  with no GenServer call — an O(1), lock-free read. The GenServer owns lazy
  population, explicit refresh, and `:pg` group membership. On a restart the
  `persistent_term` is reset to `:unset` and the next `get/0` repopulates lazily
  via re-read — so a crash never serves a stale value and never crashes a request.

  Three cache states distinguish a never-read miss from a confirmed value, so the
  boot-window miss is retried but a confirmed value (including confirmed-absent) is
  never re-queried on the hot path:

    * `:unset`        — never successfully read; `get/0` attempts a one-time
                        best-effort read on the caller and, on success, caches it.
    * `{:value, v}`   — a confirmed string claim (`v`) → returned verbatim.
    * `{:value, nil}` — confirmed-absent (no row / empty value) → `nil` fallback,
                        NOT re-queried.

  ## Cluster propagation (ADR-020)

  The cache holder joins the `nebu_matrix_oidc_claim_cache` `:pg` group on init.
  `refresh/0` re-reads the DB, updates the local `persistent_term`, and broadcasts
  an invalidation message to every OTHER group member so peer nodes refresh their
  own `persistent_term`. Behaviour is identical single-node and clustered: on a
  single node the broadcast is a no-op beyond the local refresh.

  The admin write path triggers invalidation through the `Nebu.Matrix` public
  function `Nebu.Matrix.invalidate_oidc_claim_cache/0` (ADR-020 Public-API rule),
  never by reaching into this module from `Nebu.Admin`.

  ## DB read seam (ADR-018)

  The actual read is the existing inline SQL
  (`SELECT value FROM server_config WHERE key = 'oidc_user_id_claim'`), guarded
  exactly like the old `configured_claim/0` (only query a started, queryable
  `Nebu.Repo`; any failure → `nil`). Tests inject a fake reader via
  `Application.put_env(:matrix, :oidc_claim_reader, fun)`.
  """
  use GenServer

  @pt_key :nebu_oidc_user_id_claim
  @pg_group "nebu_matrix_oidc_claim_cache"

  @sql_user_id_claim "SELECT value FROM server_config WHERE key = 'oidc_user_id_claim' LIMIT 1"

  # ── Public API ──────────────────────────────────────────────────────────────

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc """
  Returns the configured `oidc_user_id_claim` (a string), or `nil` when no claim
  is configured OR the cache has never been successfully populated and the DB is
  currently unavailable (boot window). Never raises.

  Hot path: reads `persistent_term` on the caller. On an `:unset` miss it does a
  one-time best-effort read inline (on the caller process — no GenServer round
  trip) and, on success, caches it. A confirmed value (including confirmed-absent
  `nil`) is served from the cache and never re-queried.
  """
  @spec get() :: String.t() | nil
  def get do
    case :persistent_term.get(@pt_key, :unset) do
      {:value, v} ->
        v

      :unset ->
        # Never successfully read yet. Attempt a one-time best-effort read; cache
        # the result on success, otherwise stay :unset and degrade to nil so the
        # next call retries (boot window). Reading here (not in the GenServer)
        # keeps a transient DB hiccup off a single request without serialising
        # every caller behind one process.
        case read_claim() do
          {:ok, v} ->
            :persistent_term.put(@pt_key, {:value, v})
            v

          :error ->
            nil
        end
    end
  end

  @doc """
  Re-reads the DB and replaces the cached value, then broadcasts an invalidation
  to the `:pg` group so peer nodes refresh too. Called by
  `Nebu.Matrix.invalidate_oidc_claim_cache/0` from the admin write path.

  Returns `:ok`. A DB read failure leaves the cache `:unset` (a subsequent `get/0`
  retries) rather than serving a stale value.
  """
  @spec refresh() :: :ok
  def refresh do
    case GenServer.whereis(__MODULE__) do
      nil ->
        # Holder not running (e.g. unit env without the supervised child). Refresh
        # locally so behaviour is still correct, then best-effort broadcast.
        refresh_local()
        broadcast()
        :ok

      _pid ->
        GenServer.call(__MODULE__, :refresh)
    end
  end

  @doc "The `:pg` group the cache holder joins (exposed for tests / diagnostics)."
  @spec pg_group() :: String.t()
  def pg_group, do: @pg_group

  @doc """
  Test helper: resets the cache to `:unset`. Not used in prod paths.
  """
  @spec reset_for_test() :: :ok
  def reset_for_test do
    :persistent_term.put(@pt_key, :unset)
    :ok
  end

  # ── GenServer ────────────────────────────────────────────────────────────────

  @impl true
  def init(:ok) do
    ensure_pg()
    :pg.join(@pg_group, self())
    # Reset to :unset on (re)start so a crash never serves a stale value; the next
    # get/0 repopulates lazily by re-read (volatile persistent_term, AC6).
    :persistent_term.put(@pt_key, :unset)
    {:ok, %{}}
  end

  @impl true
  def handle_call(:refresh, _from, state) do
    refresh_local()
    broadcast()
    {:reply, :ok, state}
  end

  # A peer node (or this node's admin write path) broadcast an invalidation —
  # re-read locally so this node's persistent_term reflects the new value.
  @impl true
  def handle_info({:invalidate_oidc_claim_cache}, state) do
    refresh_local()
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # ── Internals ────────────────────────────────────────────────────────────────

  # Re-read the DB and store the result (or :unset on read failure so the next
  # get/0 retries rather than caching a degraded miss as a confirmed value).
  defp refresh_local do
    case read_claim() do
      {:ok, v} -> :persistent_term.put(@pt_key, {:value, v})
      :error -> :persistent_term.put(@pt_key, :unset)
    end

    :ok
  end

  # Broadcast an invalidation to every OTHER group member (peer nodes). On a
  # single node this is a no-op (only self in the group). Mirrors SsoStore.
  defp broadcast do
    self_pid = self()

    for pid <- :pg.get_members(@pg_group), pid != self_pid do
      send(pid, {:invalidate_oidc_claim_cache})
    end

    :ok
  end

  # Best-effort claim read behind an injectable seam. Returns:
  #   {:ok, value | nil} — a confirmed read (string value, or nil = no row/empty)
  #   :error             — the read failed (Repo not ready / raised); caller stays :unset
  #
  # Default reader reuses the existing inline SQL, guarded exactly like the old
  # configured_claim/0 (only a started, queryable Nebu.Repo; any failure → :error).
  defp read_claim do
    reader = Application.get_env(:matrix, :oidc_claim_reader, &default_read_claim/0)

    try do
      case reader.() do
        v when is_binary(v) and v != "" -> {:ok, v}
        # nil / "" → confirmed-absent. Distinct from :error: it IS cached so it is
        # not re-queried on every call (AC2 confirmed-absent).
        _ -> {:ok, nil}
      end
    rescue
      # The reader raised (Repo not ready, non-Ecto placeholder, transient error).
      # Degrade to a miss so get/0 returns nil without crashing and retries later.
      _ -> :error
    end
  end

  defp default_read_claim do
    if Code.ensure_loaded?(Nebu.Repo) and Process.whereis(Nebu.Repo) do
      # Process.whereis/1 only proves a process is registered under Nebu.Repo — NOT
      # that it is a started, queryable Ecto repo. Querying a non-Ecto process
      # raises inside Ecto.Repo.Registry; read_claim/0 rescues that to :error.
      case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_user_id_claim, []) do
        {:ok, %{rows: [[v]]}} when is_binary(v) -> v
        _ -> nil
      end
    else
      nil
    end
  end

  defp ensure_pg do
    case :pg.start_link() do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      _ -> :ok
    end
  end
end
