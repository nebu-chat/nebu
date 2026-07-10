defmodule Nebu.Admin.TemporaryCaptureManager do
  @moduledoc """
  Public API for temporary logging captures on off-by-default long-polling
  endpoints (enhanced-logging/trace-map-node-controls, AC4/AC5/AC6/AC12).

  Story: docs/stories/enhanced-logging/trace-map-node-controls.md
  Design: _bmad-output/nebu/epics/enhanced-logging/design/trace-map-leitstand-spec.md §5

  A pure-functional, inline-SQL Admin-domain module (ADR-018/020) — the
  `Nebu.Admin.WarRoomManager` precedent: no `Plug.Conn`/controller knowledge,
  directly callable from `Nebu.Admin.LogsLive.TraceMap`'s event handlers.

  ## Cluster-safe timer (ANSWERED design question 1)

  The capture "timer" is a ROW in `admin_temporary_captures`
  (migration 000020): `endpoint` (PRIMARY KEY — at most one active capture
  per endpoint), `enabled_at`, `expires_at = enabled_at +
  capture_duration_s()`, `started_by`. **State is a row, expiry is a
  comparison against `now()`** — no `Process.send_after/3` owns correctness,
  so a node restart/crash/multi-node deployment can never leak a capture or
  lose its expiry. An expired row still sitting in the table (cleanup
  pending) is ALREADY inactive: `active?/1`/`active_captures/0` compare
  `expires_at > now()`, never mere row presence.

  ## Duration (ANSWERED design question 3)

  `capture_duration_s/0` reads
  `Application.get_env(:nebu, :temporary_capture_duration_s, 300)` — the
  war_room_manager env-override pattern, so tests can use a 1-second capture
  instead of waiting 5 minutes.

  ## Audit (AC12 Option B — ANSWERED design question 2)

  Enabling collection on a previously-off endpoint is an admin-initiated
  change to logging policy (the retention-settings precedent): `enable/2`
  and `disable/2` write `enable_temporary_capture` /
  `disable_temporary_capture` rows via `Nebu.Compliance.AuditWriter`
  (`target_type: "endpoint"`, `target_id: <endpoint>`). Audit writes are
  best-effort by AuditWriter's own never-raise contract — a down audit path
  degrades to an error log, never a broken capture toggle (logging must not
  break on audit failure; AuditWriter itself records the failure).

  ## Cache invalidation

  Every write (`enable/2`, `disable/2`, `cleanup_expired/0`) nudges
  `Nebu.Web.LogStore.CaptureCache.refresh_now/0` afterward — mirroring
  `Nebu.Admin.WarRoomManager` -> `Nebu.Web.LogStore.WarRoom.load_active/0` —
  so the hot-path persistence gate (`Nebu.Web.LogStore.should_persist?/2`)
  reflects the change on the very next log entry.
  """

  alias Nebu.Compliance.AuditWriter

  @doc """
  The capture duration in seconds — `:temporary_capture_duration_s` env
  override, defaulting to 300 (5 minutes, AC5).
  """
  @spec capture_duration_s() :: pos_integer()
  def capture_duration_s do
    Application.get_env(:nebu, :temporary_capture_duration_s, 300)
  end

  @doc """
  Pure expiry comparison: a capture is expired at (and after) its
  `:expires_at` instant. No process timer, no DB — callable from any
  render/tick path with any `now`.
  """
  @spec expired?(%{expires_at: DateTime.t()}, DateTime.t()) :: boolean()
  def expired?(%{expires_at: %DateTime{} = expires_at}, %DateTime{} = now) do
    DateTime.compare(now, expires_at) != :lt
  end

  @doc """
  Pure countdown: whole seconds remaining until `:expires_at`, clamped at 0
  (never negative — the mm:ss display's contract, AC6).
  """
  @spec remaining_seconds(%{expires_at: DateTime.t()}, DateTime.t()) :: non_neg_integer()
  def remaining_seconds(%{expires_at: %DateTime{} = expires_at}, %DateTime{} = now) do
    expires_at |> DateTime.diff(now, :second) |> max(0)
  end

  @doc """
  Whether `endpoint` currently has a NON-EXPIRED capture row. DB-guarded
  (the `initial_war_room_status/0` contract): with no `Nebu.Repo` running
  (plain unit-test env) there is no captures table and therefore no active
  capture — answers `false`, never raises.
  """
  @spec active?(String.t()) :: boolean()
  def active?(endpoint) when is_binary(endpoint) do
    if Process.whereis(Nebu.Repo) do
      result =
        Ecto.Adapters.SQL.query!(
          Nebu.Repo,
          "SELECT 1 FROM admin_temporary_captures WHERE endpoint = $1 AND expires_at > now()",
          [endpoint]
        )

      result.rows != []
    else
      false
    end
  end

  def active?(_endpoint), do: false

  @doc """
  All non-expired captures, as maps with `:endpoint`/`:enabled_at`/
  `:expires_at`/`:started_by`. Same DB guard as `active?/1` (returns `[]`
  without a running Repo).
  """
  @spec active_captures() :: [map()]
  def active_captures do
    if Process.whereis(Nebu.Repo) do
      result =
        Ecto.Adapters.SQL.query!(
          Nebu.Repo,
          "SELECT endpoint, enabled_at, expires_at, started_by " <>
            "FROM admin_temporary_captures WHERE expires_at > now() ORDER BY endpoint",
          []
        )

      Enum.map(result.rows, &row_to_capture/1)
    else
      []
    end
  end

  @doc """
  Enables temporary capture on `endpoint` for `capture_duration_s()`
  seconds, started by admin `started_by`. Upserts the endpoint's single row
  (re-enabling an already-capturing endpoint refreshes its window — the
  PK-upsert makes "at most one active capture per endpoint" structural).

  Returns `{:ok, capture}` with the row as a map. Writes the AC12
  `enable_temporary_capture` audit entry and refreshes the hot-path
  capture cache.
  """
  @spec enable(String.t(), String.t()) :: {:ok, map()}
  def enable(endpoint, started_by) when is_binary(endpoint) and is_binary(started_by) do
    duration_s = capture_duration_s()

    result =
      Ecto.Adapters.SQL.query!(
        Nebu.Repo,
        """
        INSERT INTO admin_temporary_captures (endpoint, enabled_at, expires_at, started_by)
        VALUES ($1, now(), now() + ($2::int * interval '1 second'), $3)
        ON CONFLICT (endpoint) DO UPDATE
          SET enabled_at = EXCLUDED.enabled_at,
              expires_at = EXCLUDED.expires_at,
              started_by = EXCLUDED.started_by
        RETURNING endpoint, enabled_at, expires_at, started_by
        """,
        [endpoint, duration_s, started_by]
      )

    [row] = result.rows
    capture = row_to_capture(row)

    AuditWriter.log(
      started_by,
      "enable_temporary_capture",
      "endpoint",
      endpoint,
      %{
        "duration_s" => duration_s,
        "expires_at" => DateTime.to_iso8601(capture.expires_at)
      },
      "success"
    )

    notify_capture_cache()
    {:ok, capture}
  end

  @doc """
  Ends an ACTIVE capture on `endpoint` early (AC5's "Disable now").

  `actor` is the admin performing the disable; when omitted (e.g. callers
  that only know the endpoint), the audit entry is attributed to the
  capture's own `started_by`.

  Returns `:ok`, or `{:error, :not_found}` when no non-expired capture
  exists — a safe no-op error, never a crash (the war_room `stop_session/1`
  shape). An expired-but-unswept row counts as not found: it is already off.
  """
  @spec disable(String.t(), String.t() | nil) :: :ok | {:error, :not_found}
  def disable(endpoint, actor \\ nil) when is_binary(endpoint) do
    result =
      Ecto.Adapters.SQL.query!(
        Nebu.Repo,
        "DELETE FROM admin_temporary_captures WHERE endpoint = $1 AND expires_at > now() " <>
          "RETURNING started_by",
        [endpoint]
      )

    case result.rows do
      [[started_by]] ->
        AuditWriter.log(
          actor || started_by,
          "disable_temporary_capture",
          "endpoint",
          endpoint,
          %{},
          "success"
        )

        notify_capture_cache()
        :ok

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Deletes expired capture rows (hygiene — expiry itself is the comparison,
  story Dev Notes item 3; `active?/1`/`active_captures/0` already treat an
  expired-but-unswept row as inactive, so correctness never depends on this
  function ever running). Leaves active rows untouched. No audit entries:
  expiry is the timer doing its job, not an admin action (the enable entry
  already records the window).

  Code review (2026-07-08, MINOR-1): this is a MANUAL, UNSCHEDULED hygiene
  helper — nothing currently calls it periodically. `admin_temporary_captures`
  is capped at (at most) 3 rows (one per off-list endpoint, `endpoint` is
  the PRIMARY KEY), so an unswept expired row costs a few bytes, not
  unbounded growth. `Nebu.Web.LogStore.CaptureCache` was deliberately NOT
  wired to call this from its own periodic refresh: that would deadlock
  (`cleanup_expired/0` -> `notify_capture_cache/0` ->
  `CaptureCache.refresh_now/0` -> `GenServer.call(CaptureCache, ...)` called
  FROM INSIDE `CaptureCache`'s own `handle_info(:refresh, ...)` blocks
  forever waiting on itself). If a periodic sweep is ever wanted, it belongs
  on a genuinely separate scheduler (e.g. alongside
  `Nebu.Web.LogStore.Retention`'s hourly job), never on `CaptureCache` itself.
  """
  @spec cleanup_expired() :: :ok
  def cleanup_expired do
    Ecto.Adapters.SQL.query!(
      Nebu.Repo,
      "DELETE FROM admin_temporary_captures WHERE expires_at <= now()",
      []
    )

    notify_capture_cache()
    :ok
  end

  defp row_to_capture([endpoint, enabled_at, expires_at, started_by]) do
    %{
      endpoint: endpoint,
      enabled_at: enabled_at,
      expires_at: expires_at,
      started_by: started_by
    }
  end

  # Best-effort, mirrors WarRoomManager.notify_war_room_reload/0: forces the
  # hot-path capture cache to reload so should_persist?/2 flips on the very
  # next log entry. Safe no-op when the cache process is not running.
  defp notify_capture_cache do
    Nebu.Web.LogStore.CaptureCache.refresh_now()
  end
end
