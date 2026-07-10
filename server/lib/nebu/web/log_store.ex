defmodule Nebu.Web.LogStore do
  @moduledoc """
  Public-facing module for the operational log store
  (enhanced-logging/operational-log-store).

  Follows the `Nebu.Web.TokenDenylist`-style naming convention: the domain
  (`Nebu.Web`, shared infrastructure, exempt from ADR-020's Public-API rule —
  same as `Nebu.Web.Plugs.RequestLogger` itself) exposes exactly one module
  other code should call into.

  ## Design (see the story's Background section for full rationale)

  The operational log store is EXPLICITLY SEPARATE from
  `Nebu.Compliance.AuditLog` — mutable/pruneable diagnostics, not the
  tamper-evident/immutable compliance audit trail.

  A single Erlang `:logger` handler (`Nebu.Web.LogStore.Handler`, attached via
  `attach_handler/0`) intercepts EVERY `Logger.*` call app-wide:

    1. ALWAYS broadcasts the parsed entry via `Phoenix.PubSub` to topic
       `"operational_logs"` (independent of persistence — feeds a later
       Admin UI live view).
    2. CONDITIONALLY queues the entry for batched INSERT via
       `Nebu.Web.LogStore.Writer.write_async/1`, gated on `should_persist?/1`
       (WARN/ERROR always; INFO/DEBUG per the `server_config` policy exposed
       by `get_policy/0`).
  """

  alias Nebu.Web.LogStore.Handler

  @handler_id :nebu_operational_log_handler

  @policy_keys ~w(
    log_collect_info log_retention_info_days log_retention_info_max_count
    log_collect_debug log_retention_debug_days log_retention_debug_max_count
  )a

  @doc """
  Attaches the central `:logger` handler (AC2). Idempotent — tolerates being
  called when the handler is already attached (does NOT register a
  duplicate).
  """
  @spec attach_handler() :: :ok
  def attach_handler do
    case :logger.add_handler(@handler_id, Handler, %{}) do
      :ok -> :ok
      {:error, {:already_exist, _id}} -> :ok
      {:error, reason} -> raise "Nebu.Web.LogStore.attach_handler/0 failed: #{inspect(reason)}"
    end
  end

  @doc """
  Returns `{:ok, policy}` — the current admin-configurable logging policy,
  read from `server_config` (AC3/AC9). Every one of the 5 policy keys is
  always present in the returned map (defaulted when unset in
  `server_config`, or when `Nebu.Repo` is not running at all — e.g. plain unit
  test runs with no live DB): INFO/DEBUG collection default to `false`
  (disabled); the 3 retention keys default to `nil` (no TTL/cap configured).
  """
  @spec get_policy() :: {:ok, map()}
  def get_policy do
    {:ok, read_policy_from_db()}
  end

  @doc false
  # Live DB read of the policy — the ONLY place that actually queries
  # server_config for these 5 keys. Called by `get_policy/0` (always a live
  # read, used by tests/AC9 and by `Nebu.Web.LogStore.Retention`, an hourly
  # background job where a live read is perfectly fine) AND by
  # `Nebu.Web.LogStore.PolicyCache` (its own periodic refresh tick — NEVER
  # called from `Handler.log/2`'s hot path, see `should_persist?/1`).
  @spec read_policy_from_db() :: map()
  def read_policy_from_db do
    raw = read_server_config()

    %{
      log_collect_info: to_bool(Map.get(raw, "log_collect_info")),
      log_retention_info_days: to_int(Map.get(raw, "log_retention_info_days")),
      log_retention_info_max_count: to_int(Map.get(raw, "log_retention_info_max_count")),
      log_collect_debug: to_bool(Map.get(raw, "log_collect_debug")),
      log_retention_debug_days: to_int(Map.get(raw, "log_retention_debug_days")),
      log_retention_debug_max_count: to_int(Map.get(raw, "log_retention_debug_max_count"))
    }
  end

  @doc """
  Forces `Nebu.Web.LogStore.PolicyCache` to refresh immediately from the DB.
  Called by `Nebu.Admin.DB.upsert_server_config/1` whenever a change touches
  one of the 5 log-policy keys (mirrors the existing
  `Nebu.Web.OidcConfig.refresh/0` / `Nebu.Matrix.invalidate_oidc_claim_cache/0`
  cache-invalidation-on-write pattern already used there). Safe no-op when
  the cache process is not running.
  """
  @spec refresh_policy_cache() :: :ok
  def refresh_policy_cache, do: Nebu.Web.LogStore.PolicyCache.refresh_now()

  @doc """
  Returns the 5 policy keys this module manages (mirrors the
  `config_update_mutable` RLS allowlist entries added by this story's
  migration).
  """
  @spec policy_keys() :: [atom()]
  def policy_keys, do: @policy_keys

  @doc """
  Decides whether a log entry at `level` (a level STRING, e.g. `"info"`) must
  be persisted to `operational_logs` (AC7): WARN and ERROR (and any other
  level not explicitly gated — fail-safe toward persisting unknown/critical
  levels) always persist; INFO/DEBUG are gated by the `server_config` policy.

  Reads the policy from `Nebu.Web.LogStore.PolicyCache` (a lock-free,
  `persistent_term`-backed cache, refreshed periodically) rather than
  `get_policy/0` directly — NEVER performs a live DB read on this path.

  This matters beyond the general "handler must not block" design goal: this
  function is called from `Nebu.Web.LogStore.Handler.log/2`, which runs
  SYNCHRONOUSLY in whatever process is currently `Logger.*`-ing, including
  `Nebu.Repo.QueryTelemetry`'s own `Logger.debug/1` call — fired from
  WITHIN the telemetry callback of an Ecto query, in the SAME process that
  is using (or just used) a `Nebu.Repo` connection checkout. A live DB read
  here would re-enter `Nebu.Repo`'s connection pool from inside another
  query's completion callback — this was observed as a genuine
  connection-pool timeout in the integration suite before the cache was
  introduced.
  """
  @spec should_persist?(String.t() | nil) :: boolean()
  def should_persist?("info") do
    policy = Nebu.Web.LogStore.PolicyCache.get()
    policy.log_collect_info == true
  end

  def should_persist?("debug") do
    policy = Nebu.Web.LogStore.PolicyCache.get()
    policy.log_collect_debug == true
  end

  def should_persist?(level) when is_binary(level), do: true
  def should_persist?(_level), do: false

  @doc """
  Route-aware persistence policy (enhanced-logging/trace-map-node-controls,
  AC4): the ingest-path check that additionally enforces the Trace Map's
  off-by-default long-polling endpoints
  (`Nebu.Admin.LogsLive.TraceMap.off_endpoint?/1` — the single canonical
  source of truth, AC13 reuse).

  ERROR-level entries are ALWAYS persisted, even on an off-list route with
  no active capture (story amendment 2026-07-07, "AC4 errors-always-persist
  exception": "off" silences noise, never failures — a silently-red zone
  contradicts the leitstand mission). An off-list route with no active
  capture suppresses every other level (DEBUG/INFO/WARN). While a capture
  IS active (checked via the non-blocking `Nebu.Web.LogStore.CaptureCache`,
  never a live DB read on this path — same hot-path reasoning as
  `should_persist?/1`), the off-list route defers to the level-only policy
  above, exactly as if it were not off-list at all. Any other route (or a
  `nil` route — no `route_template` on the log entry) also defers to the
  level-only policy unchanged.
  """
  @spec should_persist?(String.t() | nil, String.t() | nil) :: boolean()
  def should_persist?(level, route_template) do
    cond do
      level == "error" ->
        true

      Nebu.Admin.LogsLive.TraceMap.off_endpoint?(route_template) ->
        Nebu.Web.LogStore.CaptureCache.active?(route_template) and should_persist?(level)

      true ->
        should_persist?(level)
    end
  end

  @doc """
  Minimal read API (AC9) for tests and the (later) Admin UI. `filters` is an
  options map supporting `level`, `source`, `route_template`, `request_id` —
  any subset. An empty/no-filter map returns every row, most-recent first.
  """
  @spec get_logs(map()) :: {:ok, [map()]}
  def get_logs(filters) when is_map(filters) do
    {where_sql, params} = build_where(filters)

    sql = """
    SELECT id, inserted_at, level, source, route_template, request_id, message, metadata, war_room_id
    FROM operational_logs
    #{where_sql}
    ORDER BY inserted_at DESC
    """

    result = Ecto.Adapters.SQL.query!(Nebu.Repo, sql, params)
    {:ok, Enum.map(result.rows, &row_to_log/1)}
  end

  # ── policy helpers ──────────────────────────────────────────────────────────

  defp read_server_config do
    if Process.whereis(Nebu.Repo) do
      {:ok, config} = Nebu.Admin.DB.get_server_config()
      config
    else
      %{}
    end
  end

  defp to_bool(nil), do: false
  defp to_bool(true), do: true
  defp to_bool(false), do: false
  defp to_bool("true"), do: true
  defp to_bool("false"), do: false
  defp to_bool(_), do: false

  defp to_int(nil), do: nil
  defp to_int(value) when is_integer(value), do: value

  defp to_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _rest} -> int
      :error -> nil
    end
  end

  defp to_int(_), do: nil

  # ── get_logs/1 helpers ──────────────────────────────────────────────────────

  # enhanced-logging/war-room-mode (AC12): war_room_id is already SELECTed
  # and returned by row_to_log/1 below — it was just missing from this
  # allowlist, making the AC12 "filter the stream by war_room_id" use case
  # silently impossible (the filter key was accepted but ignored) even
  # though the column/SELECT already supported it.
  @allowed_filter_keys ~w(level source route_template request_id war_room_id)

  defp build_where(filters) do
    filters
    |> Enum.map(fn {k, v} -> {to_string(k), v} end)
    |> Enum.filter(fn {k, _v} -> k in @allowed_filter_keys end)
    |> Enum.map(fn {k, v} -> {k, normalize_filter_value(k, v)} end)
    |> Enum.with_index(1)
    |> Enum.reduce({[], []}, fn {{k, v}, idx}, {conds, params} ->
      {conds ++ ["#{k} = $#{idx}"], params ++ [v]}
    end)
    |> then(fn {conds, params} ->
      where_sql = if conds == [], do: "", else: "WHERE " <> Enum.join(conds, " AND ")
      {where_sql, params}
    end)
  end

  # enhanced-logging/war-room-mode (AC12): `war_room_id` is a native
  # Postgres `uuid` column — Postgrex decodes/encodes `uuid` as a 16-byte
  # BINARY (see `Postgrex.Extensions.UUID`), unlike every other identifier
  # in this codebase (room_id/user_id/device_id/request_id), which are
  # plain TEXT and therefore always the human-readable string form.
  # `Nebu.Admin.LogsLive.mount/3`'s `war_room_id` URL query param arrives
  # as a canonical hex-dash STRING (as any real bookmarked URL would carry
  # it); a value obtained directly from a prior `RETURNING id`/`SELECT id`
  # call elsewhere may already be the raw 16-byte binary form. Accept
  # EITHER here and normalize to whichever form Postgrex's own encoder
  # actually requires for a `uuid`-typed bound parameter (raw binary) —
  # `Ecto.UUID.cast/1` accepts both forms as input, `Ecto.UUID.dump!/1`
  # then converts the resulting canonical string to that raw binary.
  defp normalize_filter_value("war_room_id", v) when is_binary(v) do
    case Ecto.UUID.cast(v) do
      {:ok, canonical_string} -> Ecto.UUID.dump!(canonical_string)
      :error -> v
    end
  end

  defp normalize_filter_value(_key, v), do: v

  defp row_to_log([id, inserted_at, level, source, route_template, request_id, message, metadata, war_room_id]) do
    %{
      id: id,
      inserted_at: inserted_at,
      level: level,
      source: source,
      route_template: route_template,
      request_id: request_id,
      message: message,
      metadata: metadata,
      war_room_id: war_room_id
    }
  end
end
