defmodule Nebu.Web.LogStore.WarRoom do
  @moduledoc """
  In-memory cache + atomicity boundary for the SINGLE active War Room
  session (enhanced-logging/war-room-mode, AC4/AC5/AC9).

  Story: docs/stories/enhanced-logging/war-room-mode.md
  Design decisions (see #3/#4 for the full rationale behind this module's
  existence and its "own inline SQL" ownership):
  `_bmad-output/nebu/epics/enhanced-logging/step-results/war-room-mode/design-decisions.md`

  ## Why `Nebu.Web.LogStore.Handler.log/2` calls this, not
  `Nebu.Web.LogStore.Writer`

  The Writer batches up to 100 entries (or flushes every 5s) — AC4/AC9's
  "the Nth matching entry ends the session; the N+1th is not tagged" needs
  single-entry granularity, and `Handler.log/2` only ever calls
  `Writer.write_async/1` when `LogStore.should_persist?/1` is already
  `true`. AC4 explicitly requires war-room-matched entries to persist
  REGARDLESS of the ambient per-level retention policy (e.g. a DEBUG entry
  when `log_collect_debug` is `false`) — such an entry would never even
  reach the Writer if the check lived there. So the match/tag/budget-check
  decision happens HERE, synchronously, called from `Handler.log/2` BEFORE
  its `should_persist?/1` gate.

  ## Hot-path cost when inactive (Oracle gate — MUST NOT delay a `/sync`
  response, or any other request)

  `check/1`'s fast path is a single `:persistent_term.get/2` read — no
  GenServer round-trip at all — whenever no war room session is currently
  cached as active. This mirrors `Nebu.Web.LogStore.PolicyCache`'s own
  "never touch the DB / never block this hot path when nothing is going on"
  philosophy. Only when a session genuinely IS active does `check/1`
  perform a `GenServer.call/2` — necessarily synchronous, since the
  increment-and-maybe-terminate step must be serialized through ONE process
  to be atomic (see below), and a war room's own `max_entries` cap (at most
  10 000, the feature's own safety bound) keeps this call volume bounded by
  design.

  ## Atomicity — the GenServer itself is the boundary, not a DB transaction

  Every `check/1` call for the currently-active session is serialized
  through this SAME GenServer process. The single-row, single-statement SQL
  `UPDATE ... SET entries_collected = entries_collected + 1[, ended_at =
  now(), ended_reason = 'budget_exhausted']` conditionally ends the session
  in the SAME statement that increments the counter — genuinely atomic, no
  read-then-write race — and because it is only ever issued from inside
  this one process's `handle_call/3`, there is no cross-process race on the
  counter either: the in-memory `state.session` flips to `nil` (and the
  `:persistent_term` flag flips to `false`) in the very same `handle_call`
  that pushed the count past `max_entries`, before the call returns to the
  caller. This is what makes AT9's "the 6th matching entry is NOT tagged"
  hold.

  ## Redaction — no new leak path

  This module only ever reads/writes `route_template`, `metadata["user_id"
  / "device_id"]`, and `war_room_id` — never `message` or any other
  content field. The two-category redaction from
  `matrix-payload-debug-logging` (tokens/credentials + chat message
  content) happens entirely upstream, in `RequestLogger`, before an entry
  ever reaches `Handler.log/2`; this module never re-derives or touches
  that already-redacted content.
  """

  use GenServer

  require Logger

  @active_flag_key :nebu_war_room_active_flag

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc """
  Checks `entry` (the same map shape `Handler.parse_log_event/1` produces —
  atom keys `:level`/`:source`/`:route_template`/`:request_id`/`:message`/
  `:metadata`, where `:metadata` has STRING keys) against the currently
  active war room session's scope/filter.

  Returns the active session's `id` (a UUID string) when `entry` matches —
  the caller (`Handler.log/2`) is expected to tag the entry with it — or
  `nil` when no session is active, or the session is active but `entry`
  does not match its scope/filter.

  Cheap and non-blocking when inactive (see moduledoc). Never raises: a
  crashed/not-yet-started `WarRoom` process (e.g. mid-restart after a
  crash) is treated the same as "no active session" — logging must never
  turn into a request failure (Oracle gate).
  """
  @spec check(map()) :: nil | String.t()
  def check(entry) do
    if :persistent_term.get(@active_flag_key, false) do
      try do
        GenServer.call(__MODULE__, {:check, entry})
      catch
        :exit, _ -> nil
      end
    else
      nil
    end
  end

  @doc """
  (Re)loads the single active session (`ended_at IS NULL`) from the DB into
  this process's cache — called at boot (`init/1`) and after every
  `Nebu.Admin.WarRoomManager.start_session/1` / `stop_session/1` write
  (design-decisions.md #4), mirroring
  `Nebu.Admin.DB.upsert_server_config/1` -> `Nebu.Web.LogStore.refresh_policy_cache/0`.

  If the loaded session is already past its `max_duration_s` deadline
  (e.g. this process was down past the deadline and has just restarted —
  including via a crash+supervisor-restart), it is ended immediately as
  `"duration_exceeded"` right here, rather than left dangling until some
  future timer fires — AC5 applies across a restart, not only while this
  process stays up continuously.

  Safe no-op (returns `:ok`) when this process is not currently running.
  """
  @spec load_active() :: :ok
  def load_active do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.call(pid, :load_active)
    end
  end

  # ── GenServer callbacks ──────────────────────────────────────────────────

  @impl true
  def init(:ok) do
    {:ok, do_load_active(%{session: nil, timer_ref: nil})}
  end

  @impl true
  def handle_call(:load_active, _from, state) do
    new_state = state |> cancel_timer() |> do_load_active()
    {:reply, :ok, new_state}
  end

  def handle_call({:check, _entry}, _from, %{session: nil} = state) do
    {:reply, nil, state}
  end

  def handle_call({:check, entry}, _from, %{session: session} = state) do
    if matches?(session, entry) do
      case increment_and_maybe_end(session) do
        {:ok, true, _new_count} ->
          :persistent_term.put(@active_flag_key, false)
          {:reply, session.id, cancel_timer(%{state | session: nil})}

        {:ok, false, new_count} ->
          {:reply, session.id, %{state | session: %{session | entries_collected: new_count}}}

        # Defensive: the cached session's row is no longer in the DB at all
        # (e.g. a hard DELETE, not the normal ended_at UPDATE path this
        # module always uses itself — observed in practice from test
        # cleanup racing this singleton, cross-process, global-name
        # GenServer). Never crash the hot Handler.log/2 path over this —
        # simply treat it the same as "no session active" from here on.
        :gone ->
          :persistent_term.put(@active_flag_key, false)
          {:reply, nil, cancel_timer(%{state | session: nil})}
      end
    else
      {:reply, nil, state}
    end
  end

  @impl true
  def handle_info({:check_timeout, id}, %{session: %{id: id} = session} = state) do
    if past_deadline?(session) do
      end_session(session.id, "duration_exceeded")
      :persistent_term.put(@active_flag_key, false)
      {:noreply, %{state | session: nil, timer_ref: nil}}
    else
      # The timer fired slightly early (should not normally happen —
      # schedule_timeout/1 computes the remaining time exactly) — reschedule
      # defensively rather than dropping the check entirely.
      {:noreply, %{state | timer_ref: schedule_timeout(session)}}
    end
  end

  # A timer message for a session that is no longer the currently-cached one
  # (e.g. a stale message left in-flight from a fast stop+immediate-restart
  # — design-decisions.md #4) — ignored.
  def handle_info({:check_timeout, _stale_id}, state), do: {:noreply, state}
  def handle_info(_other, state), do: {:noreply, state}

  # ── loading ───────────────────────────────────────────────────────────────

  defp do_load_active(state) do
    case fetch_active_row() do
      nil ->
        :persistent_term.put(@active_flag_key, false)
        %{state | session: nil, timer_ref: nil}

      session ->
        if past_deadline?(session) do
          end_session(session.id, "duration_exceeded")
          :persistent_term.put(@active_flag_key, false)
          %{state | session: nil, timer_ref: nil}
        else
          :persistent_term.put(@active_flag_key, true)
          %{state | session: session, timer_ref: schedule_timeout(session)}
        end
    end
  rescue
    e ->
      Logger.warning("Nebu.Web.LogStore.WarRoom failed to load active session: #{inspect(e)}")
      :persistent_term.put(@active_flag_key, false)
      %{state | session: nil, timer_ref: nil}
  end

  defp cancel_timer(%{timer_ref: nil} = state), do: state

  defp cancel_timer(%{timer_ref: ref} = state) do
    Process.cancel_timer(ref)
    %{state | timer_ref: nil}
  end

  defp schedule_timeout(session) do
    elapsed_ms = DateTime.diff(DateTime.utc_now(), session.started_at, :millisecond)
    remaining_ms = max(0, session.max_duration_s * 1_000 - elapsed_ms)
    Process.send_after(self(), {:check_timeout, session.id}, remaining_ms)
  end

  defp past_deadline?(session) do
    elapsed_s = DateTime.diff(DateTime.utc_now(), session.started_at, :second)
    elapsed_s >= session.max_duration_s
  end

  # ── scope/filter matching (AC3/AC9) ──────────────────────────────────────

  # enhanced-logging/war-room-dedicated-page (AC9/AC10): the exclusion check
  # runs BEFORE, and independently of, scope/filter matching — an excluded
  # route_template is skipped even when `scope: "all"` would otherwise match
  # everything, and even when `filter` would otherwise match the entry's
  # metadata exactly (AC10's literal "if yes, skip — do not tag, do not
  # count"). `exclusive_scope: nil`/`[]` is a pure no-op, 100% backward
  # compatible with every pre-existing scope/filter test in this module.
  defp matches?(session, entry) do
    not excluded?(Map.get(session, :exclusive_scope), entry[:route_template]) and
      scope_matches?(session.scope, entry[:route_template]) and
      filter_matches?(session.filter, entry[:metadata])
  end

  defp excluded?(nil, _route), do: false
  defp excluded?([], _route), do: false
  defp excluded?(exclusive_scope, route) when is_list(exclusive_scope), do: route in exclusive_scope
  defp excluded?(_exclusive_scope, _route), do: false

  # scope = "all" or NULL/nil -> always match (AC3).
  defp scope_matches?(nil, _route), do: true
  defp scope_matches?("all", _route), do: true
  # A specific route_template -> exact string match only (AC3/AC8; the
  # Oracle gate confirms this codebase has exactly one /sync route, so exact
  # matching against "/_matrix/client/v3/sync" is complete).
  defp scope_matches?(scope, route) when is_binary(scope), do: scope == route
  # media-security-admin-control/10e-trace-map-war-room-integration (AC7):
  # a list of route templates, OR-matched — the minimal, additive extension
  # needed to scope a session to "the media domain"
  # (["/media/clamav", "/media/scan_worker", "/admin/media"]). Every
  # existing nil/"all"/single-string clause above is unchanged.
  defp scope_matches?(scope, route) when is_list(scope), do: route in scope
  defp scope_matches?(_scope, _route), do: false

  # filter = NULL/empty -> always match (no additional filtering).
  defp filter_matches?(nil, _meta), do: true
  defp filter_matches?(filter, _meta) when filter == %{}, do: true

  # AND semantics (AC9): every filter field must be PRESENT and EQUAL in the
  # entry's metadata. `device_id` matching is opaque/case-sensitive
  # (Oracle gate) — plain `==` never lowercases/normalizes either side.
  defp filter_matches?(filter, meta) when is_map(filter) do
    meta = meta || %{}
    Enum.all?(filter, fn {k, v} -> Map.get(meta, k) == v end)
  end

  defp filter_matches?(_filter, _meta), do: false

  # ── DB access (this module owns its own inline SQL — design-decisions.md
  # #4 — for the load/increment/timeout paths, ADR-018-compliant) ──────────

  defp fetch_active_row do
    if Process.whereis(Nebu.Repo) do
      result =
        Ecto.Adapters.SQL.query!(
          Nebu.Repo,
          """
          SELECT id, started_by, reason, scope, filter, exclusive_scope, max_entries,
                 max_duration_s, started_at, entries_collected
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
    else
      nil
    end
  end

  # code-review cycle 2 (media-security-admin-control/10e, MINOR-3): THREE
  # independent `row_to_session/1` functions exist in this codebase and do
  # NOT all agree on `id`'s shape — do not assume they are interchangeable.
  # This one deliberately keeps `id` as the raw 16-byte BINARY Postgrex
  # returns (never converted to the canonical hex-dash STRING): this copy
  # feeds only this module's own hot-path in-memory match cache, is never
  # rendered into a URL/markup, and converting it would cost every `check/1`
  # call something for no benefit. `Nebu.Admin.WarRoomManager.
  # row_to_session/1` and `Nebu.Admin.LogsLive.WarRoom.row_to_session/1` both
  # convert to the STRING form instead, because both DO render `id` into a
  # URL (`push_navigate`/`href`).
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
         entries_collected
       ]) do
    %{
      id: id,
      started_by: started_by,
      reason: reason,
      scope: decode_scope(scope),
      filter: filter,
      exclusive_scope: exclusive_scope,
      max_entries: max_entries,
      max_duration_s: max_duration_s,
      started_at: started_at,
      entries_collected: entries_collected
    }
  end

  # media-security-admin-control/10e-trace-map-war-room-integration (AC7):
  # `scope` is a plain TEXT column (migration 000019, confirmed by reading
  # it — not jsonb), so a list-shaped scope is JSON-encoded on write
  # (`Nebu.Admin.WarRoomManager.insert_session/1`) and must be decoded back
  # here. Every pre-existing scalar form (`nil`, `"all"`, an exact
  # route_template string) is not valid JSON, so `Jason.decode/1` fails for
  # them and the raw string is kept unchanged — 100% backward compatible.
  defp decode_scope(nil), do: nil

  defp decode_scope(scope) when is_binary(scope) do
    case Jason.decode(scope) do
      {:ok, list} when is_list(list) -> list
      _ -> scope
    end
  end

  # Single, atomic UPDATE ... RETURNING — increments the counter AND
  # conditionally ends the session in the SAME statement (no read-then-write
  # race). Returns {:ok, ended?, new_entries_collected}, or `:gone` when the
  # row no longer exists at all (defensive — this module never deletes
  # rows itself; see the `:gone` handling in handle_call/3 above).
  defp increment_and_maybe_end(session) do
    result =
      Ecto.Adapters.SQL.query!(
        Nebu.Repo,
        """
        UPDATE war_room_sessions
        SET entries_collected = entries_collected + 1,
            ended_at = CASE
              WHEN entries_collected + 1 >= max_entries THEN now()
              ELSE ended_at
            END,
            ended_reason = CASE
              WHEN entries_collected + 1 >= max_entries THEN 'budget_exhausted'
              ELSE ended_reason
            END
        WHERE id = $1
        RETURNING entries_collected, ended_at
        """,
        [session.id]
      )

    case result.rows do
      [[new_count, ended_at]] -> {:ok, not is_nil(ended_at), new_count}
      [] -> :gone
    end
  end

  defp end_session(id, reason) do
    Ecto.Adapters.SQL.query!(
      Nebu.Repo,
      "UPDATE war_room_sessions SET ended_at = now(), ended_reason = $2 WHERE id = $1 AND ended_at IS NULL",
      [id, reason]
    )

    :ok
  rescue
    e ->
      Logger.warning("Nebu.Web.LogStore.WarRoom failed to end session #{id}: #{inspect(e)}")
      :ok
  end
end
