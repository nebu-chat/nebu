defmodule Nebu.Admin.WarRoomManager do
  @moduledoc """
  Public API for War Room session lifecycle (enhanced-logging/war-room-mode,
  AC1/AC2/AC3/AC6/AC10) — `start_session/1`, `stop_session/1`, `status/0`.

  Story: docs/stories/enhanced-logging/war-room-mode.md
  Design decisions (see #6 for why there is deliberately NO HTTP
  controller/route here):
  `_bmad-output/nebu/epics/enhanced-logging/step-results/war-room-mode/design-decisions.md`

  A pure-functional, inline-SQL Admin-domain module (ADR-018/020) — no
  `Plug.Conn`/controller knowledge at all, directly unit-testable without an
  HTTP round trip. `Nebu.Admin.LogsLive`'s `handle_event("start_war_room" /
  "stop_war_room", ...)` clauses call straight into these functions.

  ## AC2 — "exactly one active session"

  This module performs the app-level "is one already active?" check first
  (to return a friendly, human-readable conflict message naming the
  existing session's `started_by`/`reason`), but the REAL correctness
  backstop is the migration's partial unique index
  (`war_room_sessions_single_active_idx`) — a genuinely raced concurrent
  INSERT still fails there and is mapped to the same `{:error, :conflict,
  _}` shape.

  Restarting the SAME session (identical `started_by`/`reason`/`scope`/
  `filter`/`max_entries`/`max_duration_s`) while it is still active is
  treated as idempotent: `{:ok, existing_session}` is returned without a
  second row being created.

  ## Cache invalidation

  Every write here (`start_session/1`'s successful insert, `stop_session/1`)
  calls `Nebu.Web.LogStore.WarRoom.load_active/0` afterward — mirroring
  `Nebu.Admin.DB.upsert_server_config/1` -> `Nebu.Web.LogStore.refresh_policy_cache/0` —
  so the hot-path cache (used by `Handler.log/2` via `WarRoom.check/1`)
  reflects the change on the very next log entry, not after some future
  poll.
  """

  @required_params [:started_by, :reason, :max_entries, :max_duration_s]

  # Security review (Kassandra, 2026-07-06, F-1 MEDIUM): these are the SAME
  # bounds `Nebu.Admin.LogsLive`'s `parse_int_bounded/5` already enforces at
  # the UI layer (AC8/AC11) — duplicated here so the actual trust boundary
  # (this module's public API, the only thing a caller MUST go through to
  # create a session) enforces the flooding-safety invariant regardless of
  # caller, not only when going through the LiveView form. This is
  # defense-in-depth, the same pattern already used for AC2's "exactly one
  # active" (app-level check + DB-level partial unique index backstop) — the
  # LiveView's own bounds check stays in place as the friendly
  # early-UI-feedback layer and is NOT removed/weakened by this.
  @max_entries_bounds {10, 10_000}
  @max_duration_s_bounds {10, 3_600}

  @doc """
  Starts a new War Room session with `params` (a map with atom keys):

    * required: `:started_by`, `:reason`, `:max_entries`, `:max_duration_s`
    * optional: `:scope` (defaults to `nil`, treated as "all"), `:filter`
      (a map, e.g. `%{"user_id" => "@alice:localhost"}`, defaults to `nil`),
      `:exclusive_scope` (enhanced-logging/war-room-dedicated-page, AC9/AC10
      — a list of route_template strings to EXCLUDE from capture, defaults
      to `nil`)

  Returns:

    * `{:ok, session}` — a freshly created session, OR the existing active
      session when `params` exactly matches it (idempotent restart, AC2).
    * `{:error, :conflict, message}` — a DIFFERENT session is already
      active (AC2).
    * `{:error, :invalid_params, message}` — a required parameter is
      missing (AC3 — no acceptance test pins the exact shape of this error;
      this is the chosen, documented contract), OR `:max_entries`/
      `:max_duration_s` is outside the AC8/AC11 bounds (`10..10_000` /
      `10..3_600` — security review F-1: this is the actual trust boundary,
      not just the LiveView form's own bounds check), OR `:exclusive_scope`
      fails its defense-in-depth shape validation (see
      `validate_exclusive_scope/1` below).
  """
  @spec start_session(map()) ::
          {:ok, map()} | {:error, :conflict, String.t()} | {:error, :invalid_params, String.t()}
  def start_session(params) when is_map(params) do
    with :ok <- validate_required(params) do
      case fetch_active() do
        nil ->
          insert_session(params)

        existing ->
          if same_session?(existing, params) do
            {:ok, existing}
          else
            {:error, :conflict, conflict_message(existing)}
          end
      end
    end
  end

  @doc """
  Manually ends session `id` (AC6): sets `ended_at = now()`, `ended_reason
  = "manual_stop"`.

  Returns:

    * `:ok` — the session was active and is now ended.
    * `{:error, :not_found}` — no session with this `id` exists.
    * `{:error, :already_ended}` — the session exists but was already
      ended (by budget/duration/a previous manual stop) — a safe, clearly
      defined no-op, never a crash.
  """
  @spec stop_session(String.t()) :: :ok | {:error, :not_found | :already_ended}
  def stop_session(id) do
    result =
      Ecto.Adapters.SQL.query!(
        Nebu.Repo,
        "UPDATE war_room_sessions SET ended_at = now(), ended_reason = 'manual_stop' " <>
          "WHERE id = $1 AND ended_at IS NULL",
        [id]
      )

    case result.num_rows do
      1 ->
        notify_war_room_reload()
        :ok

      0 ->
        case fetch_by_id(id) do
          nil -> {:error, :not_found}
          _existing -> {:error, :already_ended}
        end
    end
  end

  @doc """
  Returns `{:ok, session}` for the currently active session, or `:none`
  when no session is active.
  """
  @spec status() :: {:ok, map()} | :none
  def status do
    case fetch_active() do
      nil -> :none
      session -> {:ok, session}
    end
  end

  # ── validation ───────────────────────────────────────────────────────────

  defp validate_required(params) do
    missing = Enum.filter(@required_params, fn key -> blank?(Map.get(params, key)) end)

    if missing == [] do
      validate_bounds(params)
    else
      {:error, :invalid_params,
       "missing required war room parameter(s): #{Enum.map_join(missing, ", ", &to_string/1)}"}
    end
  end

  # enhanced-logging/war-room-dedicated-page (AC9/AC10, Dev Notes item 7 —
  # defense-in-depth): the LiveView form's own checkbox/free-text "other"
  # input is NOT the trust boundary — a caller invoking `start_session/1`
  # directly (bypassing the form entirely) must still be rejected for a
  # malformed `exclusive_scope`. AC9 explicitly allows a free-text "other"
  # custom route (not just the canonical `long_polling_endpoints/0`
  # members), so this is SHAPE validation (every element is a non-empty
  # string starting with "/"), not a closed allowlist — every member of
  # `Nebu.Admin.LogsLive.TraceMap.long_polling_endpoints/0` always passes
  # this check, without needing to special-case it.
  defp validate_exclusive_scope(nil), do: :ok

  defp validate_exclusive_scope(list) when is_list(list) do
    if Enum.all?(list, &valid_route_shape?/1) do
      :ok
    else
      {:error, :invalid_params,
       "exclusive_scope must be a list of non-empty route paths starting with \"/\" " <>
         "(got #{inspect(list)})"}
    end
  end

  defp validate_exclusive_scope(other) do
    {:error, :invalid_params, "exclusive_scope must be a list, got #{inspect(other)}"}
  end

  defp valid_route_shape?(value) when is_binary(value), do: String.starts_with?(value, "/")
  defp valid_route_shape?(_value), do: false

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  # Security review (Kassandra, F-1 MEDIUM): the actual trust-boundary bounds
  # check — see the @max_entries_bounds/@max_duration_s_bounds moduledoc
  # comment above. Runs AFTER required-param presence validation (so a
  # missing param still reports the more specific "missing" error first).
  defp validate_bounds(params) do
    {min_entries, max_entries_bound} = @max_entries_bounds
    {min_duration, max_duration_bound} = @max_duration_s_bounds

    with :ok <-
           validate_in_range(
             Map.fetch!(params, :max_entries),
             "max_entries",
             min_entries,
             max_entries_bound
           ),
         :ok <-
           validate_in_range(
             Map.fetch!(params, :max_duration_s),
             "max_duration_s",
             min_duration,
             max_duration_bound
           ),
         :ok <- validate_exclusive_scope(Map.get(params, :exclusive_scope)) do
      :ok
    end
  end

  defp validate_in_range(value, _field_name, min, max)
       when is_integer(value) and value >= min and value <= max do
    :ok
  end

  defp validate_in_range(value, field_name, min, max) do
    {:error, :invalid_params,
     "#{field_name} must be an integer between #{min} and #{max} (got #{inspect(value)})"}
  end

  # ── writes ───────────────────────────────────────────────────────────────

  defp insert_session(params) do
    result =
      Ecto.Adapters.SQL.query!(
        Nebu.Repo,
        """
        INSERT INTO war_room_sessions
          (started_by, reason, scope, filter, exclusive_scope, max_entries, max_duration_s)
        VALUES ($1, $2, $3, $4, $5, $6, $7)
        RETURNING id, started_by, reason, scope, filter, exclusive_scope, max_entries,
                  max_duration_s, started_at, ended_at, ended_reason, entries_collected
        """,
        [
          Map.fetch!(params, :started_by),
          Map.fetch!(params, :reason),
          Map.get(params, :scope),
          Map.get(params, :filter),
          Map.get(params, :exclusive_scope),
          Map.fetch!(params, :max_entries),
          Map.fetch!(params, :max_duration_s)
        ]
      )

    [row] = result.rows
    session = row_to_session(row)
    notify_war_room_reload()
    {:ok, session}
  rescue
    e in Postgrex.Error ->
      if unique_violation?(e) do
        # A genuinely raced concurrent start won this INSERT before we did —
        # the app-level "is one active?" check above already passed, but
        # the DB-level partial unique index is the real backstop
        # (design-decisions.md #8).
        case fetch_active() do
          nil -> {:error, :conflict, "War Room already active — could not start a new session"}
          existing -> {:error, :conflict, conflict_message(existing)}
        end
      else
        reraise e, __STACKTRACE__
      end
  end

  defp unique_violation?(%Postgrex.Error{postgres: %{code: :unique_violation}}), do: true
  defp unique_violation?(_), do: false

  # ── idempotent-restart comparison (AC2) ─────────────────────────────────

  defp same_session?(existing, params) do
    existing.started_by == Map.get(params, :started_by) and
      existing.reason == Map.get(params, :reason) and
      existing.scope == Map.get(params, :scope) and
      existing.filter == Map.get(params, :filter) and
      existing.exclusive_scope == Map.get(params, :exclusive_scope) and
      existing.max_entries == Map.get(params, :max_entries) and
      existing.max_duration_s == Map.get(params, :max_duration_s)
  end

  defp conflict_message(existing) do
    "War Room already active, started by #{existing.started_by} at #{existing.started_at}, " <>
      "reason: #{existing.reason} — end it first"
  end

  # ── reads ────────────────────────────────────────────────────────────────

  defp fetch_active do
    result =
      Ecto.Adapters.SQL.query!(
        Nebu.Repo,
        """
        SELECT id, started_by, reason, scope, filter, exclusive_scope, max_entries,
               max_duration_s, started_at, ended_at, ended_reason, entries_collected
        FROM war_room_sessions
        WHERE ended_at IS NULL
        LIMIT 1
        """,
        []
      )

    case result.rows do
      [row] -> row_to_session(row)
      [] -> nil
    end
  end

  defp fetch_by_id(id) do
    result =
      Ecto.Adapters.SQL.query!(
        Nebu.Repo,
        """
        SELECT id, started_by, reason, scope, filter, exclusive_scope, max_entries,
               max_duration_s, started_at, ended_at, ended_reason, entries_collected
        FROM war_room_sessions
        WHERE id = $1
        """,
        [id]
      )

    case result.rows do
      [row] -> row_to_session(row)
      [] -> nil
    end
  end

  defp row_to_session([
         id,
         started_by,
         reason,
         scope,
         filter,
         exclusive_scope,
         max_entries,
         max_duration_s,
         started_at,
         ended_at,
         ended_reason,
         entries_collected
       ]) do
    %{
      id: id,
      started_by: started_by,
      reason: reason,
      scope: scope,
      filter: filter,
      exclusive_scope: exclusive_scope,
      max_entries: max_entries,
      max_duration_s: max_duration_s,
      started_at: started_at,
      ended_at: ended_at,
      ended_reason: ended_reason,
      entries_collected: entries_collected
    }
  end

  # ── cache invalidation ───────────────────────────────────────────────────

  # Best-effort: forces Nebu.Web.LogStore.WarRoom to reload the active
  # session from the DB immediately — mirrors
  # Nebu.Admin.DB.upsert_server_config/1's own cache-refresh-on-write
  # pattern for Nebu.Web.LogStore.PolicyCache. Safe no-op when the process
  # is not currently running.
  defp notify_war_room_reload do
    if Process.whereis(Nebu.Web.LogStore.WarRoom) do
      Nebu.Web.LogStore.WarRoom.load_active()
    end

    :ok
  end
end
