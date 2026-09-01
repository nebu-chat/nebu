defmodule Nebu.Media.Config do
  @moduledoc """
  ETS-backed cache for the `media_config` key/value table (ADR-027, story
  `media-security-admin-control/9a-media-config-table-module`).

  ## Purpose

  Ten media-policy values that have been hardcoded in `config.exs`/app-env by
  Stories 2a/2b/2d/3/7/8a/8b/8d/9c — upload/scan size limits, pending-upload
  and stall limits, retention windows, the admin-notification webhook URL, the
  released-file auto-delete window, and the MIME denylist — converge here as a
  single admin-configurable table with ONE validated write path (`upsert/2`).
  This module is the sole public-API module (ADR-020) for `media_config`; no
  other module reads or writes it directly.

  This story only builds the table + module. It does NOT rewire any existing
  consumer (`Nebu.Media.max_upload_bytes/0`, `Nebu.Media.ClamAV`'s
  `max_file_size_bytes`, the Story 8a/8b/8d retention workers, Story 7's
  webhook sender) — each of those keeps reading its own `config.exs`/app-env
  key for now; rewiring is each citing story's own follow-up work.

  ## Interface

  - `get/0` — returns the full 15-key catalog map (atom keys) — 9a's original
    10 keys plus 10c's 4 alert-threshold keys plus 10d's `scan_kill_switch` —
    DB override merged over the `config.exs`-matching defaults below. Every
    key is always present, whether or not a row has ever been written.
  - `upsert/2` — `upsert(key, value)`. The ONLY write path to `media_config`.
    Validates before touching the DB (AC4); on success writes a
    `media_config_updated` audit-log entry (`Nebu.Compliance.AuditWriter`) and
    refreshes this node's own cache synchronously before returning `:ok`.
  - `refresh/1` — forces a synchronous DB re-read + `:pg` broadcast to peer
    nodes. Mirrors `Nebu.Web.OidcConfig.refresh/1`.
  - `pg_group/0` — the `:pg` group this cache holder joins (tests/diagnostics).

  ## ETS table

  A named `:protected` set `:nebu_media_config` with `read_concurrency: true`,
  owned by this GenServer (mirrors `Nebu.Web.OidcConfig` exactly, but as
  `Nebu.Media`'s OWN dedicated instance — ADR-027 explicitly rejects reusing
  `OidcConfig`'s table/`:pg` group: a `media_config` write must never trigger
  `server_config`'s OIDC/SSO/logging cache invalidation, and vice versa).

  ## Cluster propagation + TTL fallback (AC5)

  The GenServer joins the `nebu_media_config` `:pg` group on init. Every
  successful `upsert/2` re-reads the DB, updates the local ETS cache, and
  broadcasts `{:invalidate_media_config}` to every OTHER `:pg` group member so
  peer nodes also refresh (single-node deployments: a no-op beyond the local
  refresh). A `Process.send_after(self(), :ttl_tick, 60_000)` self-message
  loop forces a re-read every 60 seconds regardless of broadcast receipt, so a
  node that misses an invalidation (e.g. during a network partition) cannot
  serve a stale security-relevant value (`mime_denylist`, upload/scan size
  limits) indefinitely.

  ## Supervision

  Started unconditionally by `Nebu.Application` (via the dedicated
  `Nebu.Media.Config.Supervisor`, not gated behind any `:start_xxx` test flag)
  — mirrors `Nebu.Matrix.OidcClaimCache`'s placement. AC5 requires config
  changes to take effect cluster-wide without a restart, which requires this
  to be a genuinely supervised, always-running process: a crash must
  repopulate the ETS cache automatically, not merely "eventually" via some
  caller's next lazy start.

  ## Read/write seams (ADR-018 / test isolation)

  - `Application.get_env(:nebu_http, :media_config_source)` — 0-arity fun.
    When set, `get/0` calls it directly (bypassing ETS/GenServer/DB entirely)
    and merges the returned STRING-keyed override map over the config.exs
    defaults. Test-only fast path.
  - `Application.get_env(:nebu_http, :media_config_loader)` — 0-arity fun
    returning a STRING-keyed map of ALL currently persisted `media_config`
    overrides (typed Elixir terms). Consulted by the GenServer's DB-refresh
    step (populates ETS) and by `upsert/2`'s old-value lookup. Defaults to a
    real `SELECT key, value FROM media_config` when unset.
  - `Application.get_env(:nebu_http, :media_config_writer)` — arity-3 fun
    `fn key, value, set_at -> :ok | {:error, term()} end`. Defaults to a real
    `INSERT ... ON CONFLICT (key) DO UPDATE` when unset.

  Read/write is inline SQL per ADR-018 (no repository/service layer) — this
  module is the coherent single owner of the `media_config` capability.
  """

  use GenServer
  require Logger

  alias Nebu.Compliance.AuditWriter
  alias Nebu.Media.SSRF

  @table :nebu_media_config
  @pg_group "nebu_media_config"
  @ttl_ms 60_000
  @audit_actor "system:media_config"

  @defaults %{
    "max_upload_size_bytes" => 52_428_800,
    "max_file_size_bytes" => 104_857_600,
    "max_pending_per_user" => 20,
    "max_stall_ms" => 20_000,
    "deleted_days" => 30,
    "infected_days" => 90,
    "orphaned_hours" => 24,
    "webhook_url" => nil,
    "released_delete_after_days" => nil,
    "mime_denylist" => "",
    # media-security-admin-control/10c-media-alerts-triggers (AC2): the four
    # alert-threshold keys the periodic MediaAlertsCheckerWorker reads via
    # get/0 — never hardcoded, per that story's AC2. Do NOT touch 9a's
    # original 10 keys above (Dev Agent Guardrails).
    "clamav_down_alert_minutes" => 5,
    "signature_stale_alert_hours" => 48,
    "backlog_depth_alert_threshold" => 500,
    "scan_failed_rate_alert_pct" => 10,
    # media-security-admin-control/10d-scan-kill-switch (AC1): the fail-open/
    # fail-closed kill-switch policy for Nebu.Workers.MediaScanWorker when
    # Nebu.Media.ClamAV.health_check/0 reports the scanner unavailable.
    # Default MUST be "fail_closed" (Dev Agent Guardrails — never silently
    # default to "fail_open") unless an admin explicitly upserts "fail_open".
    "scan_kill_switch" => "fail_closed"
  }

  @key_to_atom %{
    "max_upload_size_bytes" => :max_upload_size_bytes,
    "max_file_size_bytes" => :max_file_size_bytes,
    "max_pending_per_user" => :max_pending_per_user,
    "max_stall_ms" => :max_stall_ms,
    "deleted_days" => :deleted_days,
    "infected_days" => :infected_days,
    "orphaned_hours" => :orphaned_hours,
    "webhook_url" => :webhook_url,
    "released_delete_after_days" => :released_delete_after_days,
    "mime_denylist" => :mime_denylist,
    "clamav_down_alert_minutes" => :clamav_down_alert_minutes,
    "signature_stale_alert_hours" => :signature_stale_alert_hours,
    "backlog_depth_alert_threshold" => :backlog_depth_alert_threshold,
    "scan_failed_rate_alert_pct" => :scan_failed_rate_alert_pct,
    "scan_kill_switch" => :scan_kill_switch
  }

  # Non-negative-integer keys (AC4) — released_delete_after_days is a
  # nonneg-integer-OR-nil key, validated/coerced separately since nil is its
  # explicit "disabled" value (not valid for any key in this list). The four
  # 10c alert-threshold keys are plain nonneg integers (minutes/hours/count/
  # percent), same shape as 9a's original nonneg-int keys.
  @nonneg_int_keys ~w(
    max_upload_size_bytes
    max_file_size_bytes
    max_pending_per_user
    max_stall_ms
    deleted_days
    infected_days
    orphaned_hours
    clamav_down_alert_minutes
    signature_stale_alert_hours
    backlog_depth_alert_threshold
    scan_failed_rate_alert_pct
  )

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc """
  Returns the full 15-key media-policy catalog (AC2; 9a's original 10 keys
  plus 10c's 4 alert-threshold keys plus 10d's `scan_kill_switch`), DB
  override merged over the config.exs-matching defaults. Every key is always
  present.
  """
  @spec get() :: map()
  def get do
    case Application.get_env(:nebu_http, :media_config_source) do
      fun when is_function(fun, 0) ->
        build_catalog(fun.())

      _ ->
        case :ets.whereis(@table) do
          :undefined -> build_catalog(safe_load())
          _ -> read_from_ets()
        end
    end
  end

  @doc """
  The ONLY write path to `media_config` (AC3). Validates `value` for `key`
  before any DB call (AC4) — an invalid value or unknown key returns
  `{:error, reason}` with zero DB/audit side effects. On success, writes a
  `media_config_updated` audit-log entry (AC6) and refreshes this node's own
  cache synchronously before broadcasting the invalidation to `:pg` peers.

  `actor` (code review m4) attributes the `media_config_updated` audit entry
  to the caller performing the change — Story 9b's admin settings UI passes
  the real admin's identity. Defaults to `@audit_actor` ("system:media_config")
  so every existing arity-2 call site keeps its current behavior unchanged.
  """
  @spec upsert(String.t(), term(), String.t()) :: :ok | {:error, atom()}
  def upsert(key, value, actor \\ @audit_actor) do
    with :ok <- validate_known_key(key),
         :ok <- validate_value(key, value) do
      do_upsert(key, value, actor)
    end
  end

  @doc """
  Forces a synchronous re-read from `media_config` and updates the ETS cache.
  Broadcasts an invalidation to peer `:pg` members. Pass a pid/name when
  targeting a non-default-registered instance (e.g. in tests).
  """
  @spec refresh(GenServer.server()) :: :ok
  def refresh(server \\ __MODULE__) do
    GenServer.call(server, :refresh)
  end

  @doc "The `:pg` group used for cross-node cache invalidation (ADR-020)."
  @spec pg_group() :: String.t()
  def pg_group, do: @pg_group

  # ── GenServer ────────────────────────────────────────────────────────────────

  @doc """
  Ensures a running, SUPERVISED instance is registered under `__MODULE__` and
  returns its pid.

  `Nebu.Media.Config.Supervisor` starts its child via `raw_start_link/1`
  directly (see that module's `init/1`) — never via this function, to avoid
  calling back into the very supervisor that is still in the middle of
  starting it. Every OTHER caller (e.g. a test's own `ensure_started/0`
  helper) goes through here: if the supervised child is currently stopped
  (its `:transient` restart type does not auto-restart a NORMAL exit — see
  `Nebu.Media.Config.Supervisor`'s moduledoc), `Supervisor.restart_child/2`
  brings it back up SYNCHRONOUSLY as a genuine child of that supervisor
  before returning — never a bare, unsupervised process sharing the
  registered name. Falls back to a raw, unsupervised start only if the
  dedicated supervisor itself is not running (e.g. this module used in
  isolation, without the full `Nebu.Application` supervision tree).
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts \\ []) do
    case Supervisor.restart_child(Nebu.Media.Config.Supervisor, __MODULE__) do
      {:ok, pid} -> {:ok, pid}
      {:ok, pid, _info} -> {:ok, pid}
      {:error, :running} -> {:error, {:already_started, Process.whereis(__MODULE__)}}
      {:error, :restarting} -> {:error, :restarting}
      {:error, _reason} -> raw_start_link(opts)
    end
  catch
    :exit, _ -> raw_start_link(opts)
  end

  @doc false
  @spec raw_start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def raw_start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl GenServer
  def init(_opts) do
    ensure_pg()
    :pg.join(@pg_group, self())
    ensure_table()
    do_refresh()
    schedule_ttl_tick()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call(:refresh, _from, state) do
    do_refresh()
    broadcast()
    {:reply, :ok, state}
  end

  # A peer node broadcast an invalidation (or our own upsert/2 triggered one
  # via handle_call(:refresh, ...) above already re-read locally on THIS
  # node) — re-read locally.
  @impl GenServer
  def handle_info({:invalidate_media_config}, state) do
    do_refresh()
    {:noreply, state}
  end

  # AC5 TTL fallback: force a re-read every @ttl_ms regardless of whether a
  # :pg broadcast was received, so a partitioned/missed-broadcast node cannot
  # serve a stale security-relevant value indefinitely.
  @impl GenServer
  def handle_info(:ttl_tick, state) do
    do_refresh()
    schedule_ttl_tick()
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # ── Write path internals ─────────────────────────────────────────────────

  defp validate_known_key(key) when is_binary(key) do
    if Map.has_key?(@defaults, key), do: :ok, else: {:error, :unknown_config_key}
  end

  defp validate_known_key(_), do: {:error, :unknown_config_key}

  defp validate_value("webhook_url", nil), do: :ok

  defp validate_value("webhook_url", value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: "https"} ->
        case SSRF.check(value) do
          :ok -> :ok
          {:error, _} = err -> err
        end

      _ ->
        {:error, :invalid_webhook_url}
    end
  end

  defp validate_value("webhook_url", _), do: {:error, :invalid_webhook_url}

  defp validate_value("mime_denylist", value) when is_binary(value) do
    if valid_mime_denylist?(value), do: :ok, else: {:error, :invalid_mime_denylist}
  end

  defp validate_value("mime_denylist", _), do: {:error, :invalid_mime_denylist}

  # media-security-admin-control/10d-scan-kill-switch (AC1): exactly
  # "fail_open" or "fail_closed" — anything else (including atoms, nil, or
  # near-miss strings like "sometimes") is rejected with zero DB side
  # effects, mirroring this module's existing per-key validation style.
  defp validate_value("scan_kill_switch", value) when value in ["fail_open", "fail_closed"],
    do: :ok

  defp validate_value("scan_kill_switch", _), do: {:error, :invalid_scan_kill_switch}

  defp validate_value("released_delete_after_days", nil), do: :ok

  defp validate_value("released_delete_after_days", value)
       when is_integer(value) and value >= 0,
       do: :ok

  defp validate_value("released_delete_after_days", _), do: {:error, :invalid_value}

  defp validate_value(key, value) when key in @nonneg_int_keys do
    if is_integer(value) and value >= 0, do: :ok, else: {:error, :invalid_value}
  end

  # Unreachable for a known key (validate_known_key/1 already rejected any
  # other key) — kept as a safe default rather than a raising catch-all.
  defp validate_value(_key, _value), do: {:error, :invalid_value}

  # mime_denylist (AC4): a comma-separated string of syntactically plausible
  # MIME-type-prefix tokens — non-empty, no embedded whitespace per token,
  # each containing a "/". The empty string is valid (denylist disabled).
  defp valid_mime_denylist?(""), do: true

  defp valid_mime_denylist?(value) do
    tokens = String.split(value, ",")
    tokens != [] and Enum.all?(tokens, &valid_mime_token?/1)
  end

  defp valid_mime_token?(token) do
    token != "" and
      not String.contains?(token, " ") and
      not String.contains?(token, "\t") and
      not String.contains?(token, "\n") and
      not String.contains?(token, "\r") and
      String.contains?(token, "/")
  end

  defp do_upsert(key, value, actor) do
    loader = Application.get_env(:nebu_http, :media_config_loader, &default_loader/0)
    writer = Application.get_env(:nebu_http, :media_config_writer, &default_writer/3)

    old_value =
      case loader.() do
        map when is_map(map) -> Map.get(map, key, Map.get(@defaults, key))
        _ -> Map.get(@defaults, key)
      end

    set_at = System.system_time(:millisecond)

    case writer.(key, value, set_at) do
      :ok ->
        # Code review (Cycle 0, m3): the config write above already
        # succeeded — per the accepted m2 finding, this is NOT rolled back
        # on an audit failure (the DB write and the audit write are
        # sequential, not atomic). AuditWriter.log/6 never raises; on its
        # own Repo failure it returns {:error, :audit_write_failed} and
        # already Logger.error/2s internally. We additionally log here with
        # the key/actor context AuditWriter's own generic message lacks, for
        # ops visibility — matching this codebase's existing audit-bridge
        # call sites (session_expiry_worker.ex, user_deletion.ex,
        # temporary_capture_manager.ex, users_controller.ex), none of which
        # propagate {:error, :audit_write_failed} to their caller either.
        # upsert/2 keeps returning :ok: the config value itself was written
        # successfully, which is the contract callers (Story 9b's settings
        # UI) depend on.
        case AuditWriter.log(
               actor,
               "media_config_updated",
               "media_config",
               key,
               %{key: key, old_value: old_value, new_value: value},
               "success"
             ) do
          :ok ->
            :ok

          {:error, audit_reason} ->
            Logger.error(
              "Nebu.Media.Config: media_config_updated audit write failed after " <>
                "successful config write key=#{inspect(key)} actor=#{inspect(actor)} " <>
                "reason=#{inspect(audit_reason)}"
            )
        end

        trigger_refresh()
        :ok

      {:error, _reason} = err ->
        err
    end
  end

  # Refresh only if the cache holder is actually running. It always should be
  # (unconditionally supervised) but a defensive no-op here keeps upsert/2
  # from crashing its caller in the unlikely event it is not.
  defp trigger_refresh do
    case GenServer.whereis(__MODULE__) do
      nil -> :ok
      _pid -> refresh()
    end
  end

  # ── Read path internals ─────────────────────────────────────────────────

  defp do_refresh do
    catalog = build_catalog(safe_load())
    :ets.insert(@table, {:catalog, catalog})
    catalog
  end

  defp safe_load do
    loader = Application.get_env(:nebu_http, :media_config_loader, &default_loader/0)

    case loader.() do
      map when is_map(map) -> map
      _ -> %{}
    end
  rescue
    e ->
      Logger.warning("Nebu.Media.Config: loader raised: #{inspect(e)}")
      %{}
  end

  defp read_from_ets do
    case :ets.lookup(@table, :catalog) do
      [{:catalog, catalog}] -> catalog
      _ -> build_catalog(%{})
    end
  rescue
    e ->
      Logger.warning("Nebu.Media.Config: unexpected error reading ETS table: #{inspect(e)}")
      build_catalog(%{})
  end

  defp build_catalog(override) when is_map(override) do
    # Code review (Cycle 0, M1): `override` is whatever the loader seam
    # returned — for the real default_loader/0 that is EVERY row currently in
    # `media_config`, unconditionally. Later stories (10c thresholds, 10d
    # fail-open/fail-closed) add their OWN new keys to this SAME table via
    # their own migrations, sharing this loader — in a rolling deploy an
    # old-code node reads a new-code node's freshly written key on its next
    # TTL tick/refresh. Map.fetch!/2 on @key_to_atom would raise KeyError for
    # any such unrecognized key (or any stray/manual row) and crash this
    # GenServer. Filter to the known 15-key catalog BEFORE merging so an
    # unrecognized key is silently ignored by get/0 rather than crashing.
    @defaults
    |> Map.merge(Map.take(override, Map.keys(@defaults)))
    |> Enum.into(%{}, fn {k, v} -> {Map.fetch!(@key_to_atom, k), coerce_value(k, v)} end)
  end

  defp build_catalog(_), do: build_catalog(%{})

  defp coerce_value("released_delete_after_days", nil), do: nil
  defp coerce_value("released_delete_after_days", v) when is_integer(v), do: v
  defp coerce_value("released_delete_after_days", v) when is_binary(v), do: String.to_integer(v)

  defp coerce_value(key, v) when key in @nonneg_int_keys and is_integer(v), do: v
  defp coerce_value(key, v) when key in @nonneg_int_keys and is_binary(v), do: String.to_integer(v)

  defp coerce_value(_key, v), do: v

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:set, :protected, :named_table, read_concurrency: true])

      _ ->
        :ok
    end
  end

  defp schedule_ttl_tick do
    Process.send_after(self(), :ttl_tick, @ttl_ms)
  end

  defp broadcast do
    self_pid = self()

    for pid <- :pg.get_members(@pg_group), pid != self_pid do
      send(pid, {:invalidate_media_config})
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

  # ── Default (real) DB read/write — only exercised when no test seam is set ──

  @sql_load_media_config "SELECT key, value FROM media_config"

  defp default_loader do
    if Process.whereis(Nebu.Repo) != nil do
      case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_load_media_config, []) do
        {:ok, %{rows: rows}} ->
          Map.new(rows, fn [k, v] -> {k, decode_value(k, v)} end)

        {:error, reason} ->
          Logger.warning("Nebu.Media.Config: failed to load media_config: #{inspect(reason)}")
          %{}
      end
    else
      %{}
    end
  rescue
    e ->
      Logger.warning("Nebu.Media.Config: unexpected error loading media_config: #{inspect(e)}")
      %{}
  end

  @sql_upsert_media_config """
  INSERT INTO media_config (key, value, set_at) VALUES ($1, $2, $3)
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, set_at = EXCLUDED.set_at
  """

  defp default_writer(key, value, set_at) do
    case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_upsert_media_config, [
           key,
           encode_value(key, value),
           set_at
         ]) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, e}
  end

  # media_config.value is TEXT NOT NULL — nil (the "disabled" sentinel for
  # webhook_url / released_delete_after_days) is encoded as "" on write and
  # decoded back to nil on read. mime_denylist's own "" is genuine data (its
  # own "disabled" value), never ambiguous with a nil-encoding round-trip.
  defp encode_value("webhook_url", nil), do: ""
  defp encode_value("released_delete_after_days", nil), do: ""
  defp encode_value(_key, value), do: to_string(value)

  defp decode_value("webhook_url", ""), do: nil
  defp decode_value("released_delete_after_days", ""), do: nil
  defp decode_value("released_delete_after_days", v), do: String.to_integer(v)
  defp decode_value(key, v) when key in @nonneg_int_keys, do: String.to_integer(v)
  defp decode_value(_key, v), do: v
end
