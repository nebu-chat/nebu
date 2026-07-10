defmodule Nebu.Admin.LogsLive.WarRoomPanel do
  @moduledoc """
  The War Room start/stop panel on `/admin/logs`
  (enhanced-logging/war-room-mode, AC7/AC8/AC9/AC11).

  Story: docs/stories/enhanced-logging/war-room-mode.md
  Design decisions (see #6): `Nebu.Admin.LogsLive`'s
  `handle_event("start_war_room" / "stop_war_room", ...)` clauses call
  straight into `Nebu.Admin.WarRoomManager` — a genuine server round trip
  over the LiveView socket (unlike the Trace Map filter bubbles, which are
  deliberately client-side-only per that sibling story's AC3). This
  component is purely presentational — it renders whichever state
  `LogsLive` hands it (`:none` | `{:ok, session}`) and emits the two
  `phx-submit`/`phx-click` events `LogsLive` handles.

  Mirrors the existing `TraceMapBubble`/`DetailPanel` "LogsLive.XxxPanel"
  sub-module convention.

  ## AC7/AC8 warnings — static markup, client-side visibility toggle

  Both warning blocks are ALWAYS present in the server-rendered markup
  (`style="display:none"` by default) — `priv/static/assets/app.js`'s
  `wireWarRoomPanel()` toggles which one is visible based on the scope
  `<select>`'s current value, following the exact CSP-`script-src
  'self'`-compliant pattern `wireLogsConfigToggles()` already established
  for the sibling `admin-logs-retention-settings` page (no inline
  `<script>`). Rendering both unconditionally (rather than only the
  currently-relevant one) is what lets `logs_live_test.exs` assert on their
  literal text without a browser JS runtime — mirrors
  `logs_controller_test.exs`'s own static-HTML-contract convention for that
  page's dynamic DEBUG warning.

  ## AC8's numeric caps (max_entries <= 100 / max_duration_s <= 300 for the
  `/sync` scope) are advisory only, not server-enforced

  Consistent with the sibling `admin-logs-retention-settings` page's own
  precedent (client-side warning text, no hard server-side rejection) —
  `Nebu.Admin.WarRoomManager.start_session/1` accepts any value within the
  general `[10, 10_000]` / `[10, 3_600]` bounds regardless of scope. This is
  a deliberate choice (documented here, per the story's test-review MINOR-2
  finding), not an oversight: the warning is the safety mechanism; an
  operator who consciously overrides it (e.g. because they ARE confident
  in a narrow user_id/device_id filter) is not blocked.
  """
  use Phoenix.Component

  attr(:war_room, :any, required: true, doc: ":none | {:ok, session_map}")

  # UX-gate fix (blocking, WCAG 2.1 AA 4.1.3 Status Messages): this outer
  # `<section>` is the STABLE, always-rendered node for the lifetime of the
  # LiveView process — only its `<.active_state>`/`<.inactive_state>` child
  # swaps (on start/stop) and the live status text inside `<.active_state>`
  # mutates every 2s (`LogsLive`'s `:refresh_war_room_status` poll, AC11).
  # Before this fix NEITHER the active/inactive transition NOR the ticking
  # budget/time-remaining text carried any `aria-live`/role-based live-region
  # signal anywhere in the subtree — a screen-reader user starting or
  # stopping a War Room session (their own action OR another admin's, OR an
  # automatic budget/duration exhaustion stop) got zero non-visual feedback.
  # `aria-live="polite"` on this always-present wrapper mirrors the exact
  # "stable wrapper, dynamic child" convention already established for
  # `#info-retention-live`/`#debug-retention-live` on the sibling
  # `admin-logs-retention-settings` page (see that page's own template
  # comment: a live region only reliably fires for mutations to content
  # already inside it, not for the wrapper itself appearing) — chosen over
  # putting `aria-live`/`role="status"` on the inner, appearing/disappearing
  # nodes themselves.
  def war_room_panel(assigns) do
    ~H"""
    <section
      data-testid="war-room-panel"
      aria-label="War Room"
      aria-live="polite"
      class={[
        "mb-4 rounded-lg border-2 p-4",
        war_room_active?(@war_room) && "border-error bg-error/5",
        not war_room_active?(@war_room) && "border-base-300"
      ]}
    >
      <.active_state :if={war_room_active?(@war_room)} session={war_room_session(@war_room)} />
      <.inactive_state :if={not war_room_active?(@war_room)} />
    </section>
    """
  end

  attr(:session, :map, required: true)

  defp active_state(assigns) do
    ~H"""
    <div class="flex items-center justify-between mb-2 gap-2">
      <h2 class="font-semibold text-error">🚨 War Room Active</h2>
      <button
        type="button"
        data-testid="stop-war-room-button"
        phx-click="stop_war_room"
        class="btn btn-sm btn-error"
      >
        Stop War Room
      </button>
    </div>
    <p data-testid="war-room-status" class="text-sm">
      {@session.entries_collected}/{@session.max_entries} entries · {remaining_text(@session)} remaining
      · started by {@session.started_by} at {@session.started_at} for reason: {@session.reason}
    </p>
    """
  end

  defp inactive_state(assigns) do
    ~H"""
    <div class="flex items-center justify-between mb-2 gap-2">
      <h2 class="font-semibold">War Room</h2>
      <span class="text-xs text-text-secondary">Bounded, self-terminating elevated logging</span>
    </div>

    <form
      id="war-room-start-form"
      data-testid="war-room-start-form"
      phx-submit="start_war_room"
      class="flex flex-col gap-2 max-w-md"
    >
      <label class="form-control">
        <span class="label-text">Reason</span>
        <input
          type="text"
          name="reason"
          required
          placeholder="e.g. sync bug investigation"
          class="input input-bordered input-sm"
        />
      </label>

      <label class="form-control">
        <span class="label-text">Scope</span>
        <select name="scope" data-testid="war-room-scope-select" class="select select-bordered select-sm">
          <option value="">-- select scope --</option>
          <option value="all">all endpoints</option>
          <option value="/_matrix/client/v3/sync">/_matrix/client/v3/sync</option>
        </select>
      </label>

      <label class="form-control">
        <span class="label-text">user_id (optional)</span>
        <input type="text" name="user_id" placeholder="@alice:localhost" class="input input-bordered input-sm" />
      </label>

      <label class="form-control">
        <span class="label-text">device_id (optional)</span>
        <input type="text" name="device_id" placeholder="GHTYAJSQZD" class="input input-bordered input-sm" />
      </label>

      <label class="form-control">
        <span class="label-text">max_entries</span>
        <input type="number" name="max_entries" value="100" min="10" max="10000" class="input input-bordered input-sm" />
      </label>

      <label class="form-control">
        <span class="label-text">max_duration_s</span>
        <input type="number" name="max_duration_s" value="300" min="10" max="3600" class="input input-bordered input-sm" />
      </label>

      <div
        data-testid="war-room-warning-all"
        class="alert alert-warning text-sm"
        style="display:none;"
        role="status"
      >
        Warning: collecting all endpoints. High-frequency endpoints like `/sync` can generate 1000s of
        entries per second. Recommend narrowing scope (by user_id/device_id) or keeping
        max_entries/max_duration_s conservative.
      </div>

      <div
        data-testid="war-room-warning-sync"
        class="alert alert-error text-sm"
        style="display:none;"
        role="alert"
      >
        ⚠️ `/sync` is called continuously by every client. Unless you are targeting a single
        user/device, this will fill your log budget in seconds. Require max_entries ≤ 100 and
        max_duration_s ≤ 300, or cancel.
      </div>

      <button type="submit" data-testid="start-war-room-button" class="btn btn-error btn-sm">
        🚨 Start War Room
      </button>
    </form>
    """
  end

  defp war_room_active?({:ok, _session}), do: true
  defp war_room_active?(_), do: false

  defp war_room_session({:ok, session}), do: session

  defp remaining_text(%{started_at: started_at, max_duration_s: max_duration_s}) do
    elapsed = DateTime.diff(DateTime.utc_now(), started_at, :second)
    remaining = max(max_duration_s - elapsed, 0)
    minutes = div(remaining, 60)
    seconds = rem(remaining, 60)

    ~c"~2..0B:~2..0B"
    |> :io_lib.format([minutes, seconds])
    |> IO.iodata_to_binary()
  end

  defp remaining_text(_session), do: "—"
end
