defmodule Nebu.Web.LogStore.Retention do
  @moduledoc """
  Retention-pruning helper for the operational log store
  (enhanced-logging/operational-log-store, AC8).

  Called from `Nebu.Matrix.Session.Sweeper.sweep/0` (same hourly cadence as
  the existing auth-row sweeps), so `operational_logs` does not grow
  unbounded even when INFO/DEBUG collection is enabled. All deletes are
  idempotent `DELETE ... WHERE ...` — safe to run more than once per cycle
  with no further effect once the older rows are already gone.

  Three independent policies, all read from `Nebu.Web.LogStore.get_policy/0`:

    * Per-level day-based TTL (`log_retention_info_days` /
      `log_retention_debug_days`) — deletes rows of that level older than N
      days. `nil` (unset) means "no TTL for this level", i.e. a no-op.
    * Per-level max-count cap (`log_retention_info_max_count` /
      `log_retention_debug_max_count`) — caps the total number of rows for
      that level, keeping only the N most recent (by `inserted_at`). `nil`
      means "no cap", i.e. a no-op.

  Plus a hardcoded (NOT admin-configurable, no `server_config` key, no UI)
  WARN/ERROR safety-net TTL (enhanced-logging/admin-logs-retention-settings,
  design-decisions.md #4): WARN and ERROR rows older than 90 days are always
  pruned, closing the disk-exhaustion/GDPR-storage-limitation gap flagged by
  Kassandra's operational-log-store review (MEDIUM, explicitly deferred to
  the admin-logs-retention-settings story). This story's own AC6 forbids a
  UI control for WARN/ERROR retention ("always collected... non-interactive"),
  so this is pure backend housekeeping — the 90-day bound mirrors the same
  upper bound already used for INFO/DEBUG days validation elsewhere in that
  story, so it is not an arbitrary new magic number.

  Plus a third, LEVEL-INDEPENDENT safety-net TTL for war-room-tagged rows
  (epic-wide security review, SEC Gate 2, finding X1, MEDIUM): any row with
  a non-NULL `war_room_id` older than 90 days is always pruned, regardless
  of its `level`. `Nebu.Web.LogStore.Handler.log/2` persists war-room-tagged
  entries unconditionally (war-room-mode's AC4), independent of whether
  INFO/DEBUG collection is currently enabled — which is exactly the state a
  war room typically runs in (operators use war rooms to get temporary
  DEBUG capture without turning DEBUG on globally). That meant war-room-
  tagged INFO/DEBUG rows had NO TTL bound at all: the per-level INFO/DEBUG
  TTLs are no-ops when collection is off (`nil`), and the WARN/ERROR safety
  net above only covers WARN/ERROR rows. This third policy closes that
  GDPR storage-limitation gap, reusing the same `@warn_error_safety_net_days`
  constant (not a second magic number) and the existing
  `operational_logs_war_room_id_idx` index (000019_war_room_sessions.up.sql).
  """

  require Logger

  alias Nebu.Web.LogStore

  # admin-logs-retention-settings, design-decisions.md #4: hardcoded
  # safety-net TTL for WARN/ERROR — NOT admin-configurable, matches the same
  # upper bound already used for INFO/DEBUG day-based validation.
  @warn_error_safety_net_days 90

  @doc """
  Runs all configured retention prunes. Best-effort: a failing query is
  caught and logged (mirrors `Nebu.Matrix.Session.Sweeper`'s
  `safe_query/2` — a sweep failure just retries next hourly tick, never
  crashes the caller).
  """
  @spec prune_operational_logs() :: :ok
  def prune_operational_logs do
    {:ok, policy} = LogStore.get_policy()

    prune_ttl("info", policy.log_retention_info_days)
    prune_ttl("debug", policy.log_retention_debug_days)
    prune_max_count("info", policy.log_retention_info_max_count)
    prune_max_count("debug", policy.log_retention_debug_max_count)

    prune_ttl("warning", @warn_error_safety_net_days)
    prune_ttl("error", @warn_error_safety_net_days)

    prune_war_room_safety_net()

    :ok
  end

  defp prune_ttl(_level, nil), do: :ok

  defp prune_ttl(level, days) when is_integer(days) do
    safe_query(
      """
      DELETE FROM operational_logs
      WHERE level = $1 AND inserted_at < now() - ($2 || ' days')::interval
      """,
      [level, to_string(days)]
    )

    :ok
  end

  defp prune_max_count(_level, nil), do: :ok

  defp prune_max_count(level, max_count) when is_integer(max_count) do
    safe_query(
      """
      DELETE FROM operational_logs
      WHERE level = $1 AND id NOT IN (
        SELECT id FROM operational_logs WHERE level = $1
        ORDER BY inserted_at DESC LIMIT $2
      )
      """,
      [level, max_count]
    )

    :ok
  end

  # Epic SEC gate finding X1: level-independent safety net for war-room-
  # tagged rows — any row with war_room_id set is pruned once it is older
  # than @warn_error_safety_net_days, regardless of `level`. Uses the
  # existing operational_logs_war_room_id_idx index, so no schema change is
  # needed.
  defp prune_war_room_safety_net do
    safe_query(
      """
      DELETE FROM operational_logs
      WHERE war_room_id IS NOT NULL
        AND inserted_at < now() - ($1 || ' days')::interval
      """,
      [to_string(@warn_error_safety_net_days)]
    )

    :ok
  end

  defp safe_query(sql, params) do
    if Process.whereis(Nebu.Repo) do
      Ecto.Adapters.SQL.query(Nebu.Repo, sql, params)
    else
      {:error, :repo_not_started}
    end
  rescue
    e ->
      Logger.warning("Nebu.Web.LogStore.Retention query failed: #{inspect(e)}")
      {:error, e}
  end
end
