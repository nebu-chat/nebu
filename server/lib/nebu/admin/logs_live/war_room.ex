defmodule Nebu.Admin.LogsLive.WarRoom do
  @moduledoc """
  War Room dedicated page (enhanced-logging/war-room-dedicated-page) —
  `/admin/logs/war-room` (session list + pre-session scoping form) and
  `/admin/logs/war-room/:room_id` (session detail/drill-down).

  Story: docs/stories/enhanced-logging/war-room-dedicated-page.md
  Story Amendments (2026-07-08) are authoritative wherever they conflict
  with the original AC text.

  ## ONE module, two router actions (amendment 1)

  Mirrors the sibling `Nebu.Admin.LogsLive.TraceMap`'s own "one module, two
  concerns" precedent, but WITHOUT a `handle_params/3` callback: `:show`'s
  `room_id` is a static PATH segment, available directly in `mount/3`'s own
  `params` argument (`%{"room_id" => id}`) — no `push_patch/2`-driven URL
  round trip is needed (the exclusive-scope checkboxes and scope-mode
  switching are ordinary `phx-change`/assigns state, not URL-driven). This
  means `live_isolated/3` (which never sets `socket.router`, and therefore
  ALWAYS calls `mount/3` with the literal atom `:not_mounted_at_router`, per
  `Nebu.Admin.LogsLive`'s own documented precedent) can mount this module
  for every list-mode test — the `%{"room_id" => id}` clause simply never
  matches that atom, falling through to list mode. Only the DETAIL view and
  the route-repoint proof need the real router.

  `@active_nav` is `"logs-war-room"` (the already-shipped sidebar child key
  from `admin-sidebar-nesting`) in BOTH actions.

  ## Embedded panel retirement (amendment 2)

  `Nebu.Admin.LogsLive.WarRoomPanel` no longer renders on `/admin/logs` —
  the "start a new session" form lives here now. `Nebu.Admin.LogsLive`
  keeps its own War Room *status poll* (for the sidebar dot / topbar pill,
  amendment 4) but no longer starts/stops sessions itself.

  ## AC8's live-activity preview reuses `TraceMapBubble` for level+source
  only (amendment 3)

  NOT a second radial Leitstand map (that already moved to
  `/admin/logs/trace-map`) — a lightweight, `:readonly`-mode reuse of the
  same bubble component already used on `/admin/logs`, previewing the
  LEVEL and SOURCE dimensions only. The actual "sync is noisy" motivation
  is solved directly by the exclusive-scope checkboxes (AC9–AC11), not by
  this preview.

  ## Exclusive scope (AC9/AC10, Dev Notes Option A)

  `war_room_sessions.exclusive_scope` is a separate, nullable JSONB column
  (migration 000021) — `scope` stays a plain string. Choosing `"exclusive"`
  in the scope selector stores `scope: "all"` + a non-empty
  `exclusive_scope` list (the "capture everything EXCEPT these endpoints"
  convenience). The exclude-list checkboxes are sourced from
  `Nebu.Admin.LogsLive.TraceMap.long_polling_endpoints/0` (amendment 5 —
  reused, not a hardcoded parallel list) plus a free-text "other" input
  (AC9); the LiveView itself (`merge_exclusive_scope/1`) merges both into
  one list before calling into `Nebu.Admin.WarRoomManager.start_session/1`,
  which performs its own defense-in-depth shape validation (Dev Notes
  item 7) — this LiveView never trusts its own client-side UI as the sole
  guard.

  ## Sidebar dot / topbar pill (amendment 4)

  This module also threads `:war_room_active`/`:war_room_started_at`/
  `:war_room_started_by` through to `Nebu.Admin.Layouts.live/1`, polled the
  same 2s-interval way `Nebu.Admin.LogsLive`/`Nebu.Admin.LogsLive.TraceMap`
  already poll `Nebu.Admin.WarRoomManager.status/0` for their own war-room
  banners.

  ## Copy-to-markdown (AC14, amendment 6)

  Reuses the EXISTING, already-CSP-safe `nebu:copy-thread` client event
  `Nebu.Admin.LogsLive.DetailPanel`'s own copy-thread button already
  dispatches (`priv/static/assets/app.js`'s generic, document-level
  listener needs no changes for this reuse) — no new inline JS. The
  "Copied to clipboard" toast is a DEDICATED `@copy_toast` assign, not
  Phoenix's built-in `@flash` (this admin layout does not render `@flash`
  today — mirrors `Nebu.Admin.LogsLive.TraceMap`'s own `@cascade_flash`
  precedent).

  ## HTML-escaping (security)

  `exclusive_scope`/`exclusive_other` values (and every other
  admin/operator-supplied field: `reason`, `filter`, custom routes) are
  ALWAYS rendered through ordinary HEEx `{...}` interpolation — auto-escaped
  by Phoenix on every render, including inside `data-copy-text` attribute
  values. `raw/1`/`Phoenix.HTML.raw/1`/`safe_html` helpers are never used on
  any of these fields anywhere in this module.
  """
  use Phoenix.LiveView, layout: {Nebu.Admin.Layouts, :live}

  alias Nebu.Admin.LogsLive.TraceMap
  alias Nebu.Admin.LogsLive.TraceMapBubble
  alias Nebu.Admin.WarRoomIndicator
  alias Nebu.Admin.WarRoomManager
  alias Phoenix.LiveView.JS

  @topic "operational_logs"

  @levels ["error", "warning", "info", "debug"]
  @sources ["http", "ecto", "other"]

  # ══════════════════════════════════════════════════════════════════════════
  # Mount
  # ══════════════════════════════════════════════════════════════════════════

  @impl Phoenix.LiveView
  def mount(params, session, socket) do
    Phoenix.PubSub.subscribe(Nebu.PubSub, @topic)

    socket =
      socket
      |> assign(:active_nav, "logs-war-room")
      |> assign(:page_title, "War Room")
      |> assign(:current_admin_id, admin_id_from_session(session))
      |> WarRoomIndicator.assign_status(WarRoomIndicator.status())

    socket =
      case room_id_param(params) do
        nil -> mount_list(socket)
        room_id -> mount_detail(socket, room_id)
      end

    if connected?(socket) and Process.whereis(Nebu.Repo) do
      WarRoomIndicator.schedule()
    end

    {:ok, socket}
  end

  # `params` is the literal atom `:not_mounted_at_router` for every
  # `live_isolated/3` mount (see moduledoc) — never matches the map pattern
  # below, falling through to `nil` (list mode).
  defp room_id_param(%{"room_id" => id}) when is_binary(id) and id != "", do: id
  defp room_id_param(_params), do: nil

  # Prefer matrix_user_id (`@kai:localhost`-shaped, human-readable) over the
  # raw OIDC `sub` claim (protobuf-encoded by Dex, opaque to operators) — this
  # value is displayed verbatim as `started_by` in the session list/detail and
  # the cross-page recording pill/banner, so an opaque sub defeats the whole
  # point of showing "who is recording" at a glance (design-conformance fix,
  # 2026-07-08). Mirrors Nebu.Admin.LogsLive/LogsLive.TraceMap's own copy.
  defp admin_id_from_session(%{"current_user" => %{"matrix_user_id" => uid}})
       when is_binary(uid) and uid != "",
       do: uid

  defp admin_id_from_session(%{"current_user" => %{"sub" => sub}})
       when is_binary(sub) and sub != "",
       do: sub

  defp admin_id_from_session(_session), do: "unknown-admin"

  defp mount_list(socket) do
    socket
    |> assign(:mode, :list)
    |> assign(:sessions, load_sessions())
    |> assign(:form_scope, "all")
    |> assign(:start_error, nil)
    |> assign(:levels, @levels)
    |> assign(:sources, @sources)
    |> assign(:level_counts, Map.new(@levels, &{&1, 0}))
    |> assign(:source_counts, Map.new(@sources, &{&1, 0}))
    |> seed_preview_counts()
  end

  defp mount_detail(socket, room_id) do
    session = load_session(room_id)

    socket
    |> assign(:mode, :detail)
    |> assign(:room_id, room_id)
    |> assign(:session, session)
    |> assign(:entries, if(session, do: load_entries(room_id), else: []))
    |> assign(:copy_toast, "")
    |> assign(:copy_toast_nonce, 0)
  end

  # ══════════════════════════════════════════════════════════════════════════
  # handle_info — PubSub live-activity preview (AC8) + war-room status poll
  # ══════════════════════════════════════════════════════════════════════════

  @impl Phoenix.LiveView
  def handle_info(%{level: _level, source: _source, request_id: _request_id} = entry, socket) do
    if socket.assigns.mode == :list do
      {:noreply, ingest_preview(socket, entry)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(:refresh_war_room_status, socket) do
    if Process.whereis(Nebu.Repo), do: WarRoomIndicator.schedule()

    {:noreply,
     WarRoomIndicator.assign_status(socket, WarRoomIndicator.status())}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  # ══════════════════════════════════════════════════════════════════════════
  # handle_event
  # ══════════════════════════════════════════════════════════════════════════

  @impl Phoenix.LiveView
  def handle_event("scope_changed", params, socket) do
    {:noreply, assign(socket, :form_scope, params["scope"])}
  end

  def handle_event("start_war_room", params, socket) do
    reason = String.trim(params["reason"] || "")
    scope = blank_to_nil(params["scope"])
    exclusive_scope = if scope == "exclusive", do: merge_exclusive_scope(params), else: nil

    if scope == "exclusive" and exclusive_scope == nil do
      # code-review MINOR (war-room-dedicated-page, cycle 3): "exclusive"
      # scope with zero checkboxes AND a blank "other" field must NOT
      # silently collapse to scope:"all", exclusive_scope:nil (i.e.
      # capture-everything — the exact noisy full capture the operator
      # picked "all except..." to avoid). Reject with a visible form error
      # instead, following the existing @start_error pattern used for
      # WarRoomManager.start_session/1 validation failures below.
      {:noreply,
       assign(
         socket,
         :start_error,
         "Select at least one endpoint to exclude, or choose a different scope"
       )}
    else
      stored_scope = if scope == "exclusive", do: "all", else: scope

      attrs = %{
        started_by: socket.assigns.current_admin_id,
        reason: reason,
        scope: stored_scope,
        filter: war_room_filter(params["user_id"], params["device_id"]),
        exclusive_scope: exclusive_scope,
        max_entries: parse_int(params["max_entries"], 100),
        max_duration_s: parse_int(params["max_duration_s"], 300)
      }

      case WarRoomManager.start_session(attrs) do
        {:ok, _session} ->
          {:noreply,
           socket
           |> assign(:sessions, load_sessions())
           |> assign(:start_error, nil)
           |> assign(:form_scope, "all")
           |> WarRoomIndicator.assign_status(WarRoomIndicator.status())}

        {:error, _kind, message} ->
          {:noreply, assign(socket, :start_error, message)}
      end
    end
  end

  # AC2 of war-room-mode: at most one session may be active at a time — while
  # one is, the list page shows a "War Room Active" banner (mirrors the
  # RETIRED embedded panel's own active-state UI, `war-room-panel`/
  # `stop-war-room-button` testids, amendment 2 wording "may be reused... if
  # convenient") in place of the start form, with a stop control.
  def handle_event("stop_war_room", %{"room_id" => room_id}, socket) do
    WarRoomManager.stop_session(room_id)

    {:noreply,
     socket
     |> assign(:sessions, load_sessions())
     |> WarRoomIndicator.assign_status(WarRoomIndicator.status())}
  end

  # UX gate advisory 3: repeated clicks with byte-identical `@copy_toast`
  # text produce NO DOM text-node mutation, so the `role="status"` live
  # region never re-announces on a second/third click. A trailing zero-width
  # space (invisible to sighted users, never a "diff string" a screen reader
  # would speak) toggled on/off by a monotonic nonce forces the text node to
  # genuinely differ between consecutive clicks, without ever changing what
  # gets read aloud or displayed.
  def handle_event("copy_to_markdown", _params, socket) do
    nonce = socket.assigns.copy_toast_nonce + 1
    # U+200B ZERO WIDTH SPACE — invisible, never spoken by screen readers,
    # used purely to make consecutive `@copy_toast` values byte-different.
    suffix = if rem(nonce, 2) == 0, do: "\u{200B}", else: ""

    {:noreply,
     socket
     |> assign(:copy_toast_nonce, nonce)
     |> assign(:copy_toast, "Copied to clipboard" <> suffix)}
  end

  # ── AC9/AC10: exclusive_scope merging (checkboxes + free-text "other") ────

  defp merge_exclusive_scope(params) do
    checked =
      params
      |> Map.get("exclusive_scope", [])
      |> List.wrap()
      |> Enum.filter(&(is_binary(&1) and &1 != ""))

    other = params |> Map.get("exclusive_other", "") |> to_string() |> String.trim()

    list = if other == "", do: checked, else: checked ++ [other]

    case Enum.uniq(list) do
      [] -> nil
      merged -> merged
    end
  end

  defp war_room_filter(user_id, device_id) do
    entries =
      [{"user_id", blank_to_nil(user_id)}, {"device_id", blank_to_nil(device_id)}]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    case entries do
      [] -> nil
      pairs -> Map.new(pairs)
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp parse_int(value, default) do
    case blank_to_nil(value) do
      nil ->
        default

      v ->
        case Integer.parse(to_string(v)) do
          {n, _rest} -> n
          :error -> default
        end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Live-activity preview (AC8, amendment 3) — level + source only
  # ══════════════════════════════════════════════════════════════════════════

  defp seed_preview_counts(socket) do
    if Process.whereis(Nebu.Repo) do
      {:ok, rows} = Nebu.Web.LogStore.get_logs(%{})
      Enum.reduce(Enum.take(rows, 500), socket, &ingest_preview(&2, &1))
    else
      socket
    end
  end

  defp ingest_preview(socket, entry) do
    level = normalize_level(entry[:level])
    source = bucket_source(entry[:source])

    socket
    |> update(:level_counts, &Map.update(&1, level, 1, fn c -> c + 1 end))
    |> update(:source_counts, &Map.update(&1, source, 1, fn c -> c + 1 end))
  end

  defp normalize_level(level) when is_binary(level), do: level
  defp normalize_level(level) when is_atom(level) and not is_nil(level), do: Atom.to_string(level)
  defp normalize_level(_), do: "info"

  defp bucket_source("http"), do: "http"
  defp bucket_source("ecto"), do: "ecto"
  defp bucket_source(_), do: "other"

  # ══════════════════════════════════════════════════════════════════════════
  # Data access — session list / detail (this module owns its own inline
  # SQL, ADR-018-compliant, mirroring Nebu.Web.LogStore.WarRoom/
  # Nebu.Admin.WarRoomManager's own precedent)
  # ══════════════════════════════════════════════════════════════════════════

  @session_columns "id, started_by, reason, scope, filter, exclusive_scope, max_entries, " <>
                      "max_duration_s, started_at, ended_at, ended_reason, entries_collected"

  # AC1: active sessions first, then most-recent-start-first.
  defp load_sessions do
    if Process.whereis(Nebu.Repo) do
      result =
        Ecto.Adapters.SQL.query!(
          Nebu.Repo,
          """
          SELECT #{@session_columns}
          FROM war_room_sessions
          ORDER BY CASE WHEN ended_at IS NULL THEN 0 ELSE 1 END, started_at DESC
          """,
          []
        )

      Enum.map(result.rows, &row_to_session/1)
    else
      []
    end
  end

  defp load_session(room_id) do
    if Process.whereis(Nebu.Repo) do
      # `room_id` arrives as the canonical hex-dash STRING (a real path
      # segment) — Postgrex's `uuid` extension requires the raw 16-byte
      # BINARY form for a bound parameter against a `uuid` column (confirmed
      # against the live stack: a plain string `$1` raises
      # `DBConnection.EncodeError`), mirroring
      # `Nebu.Web.LogStore.get_logs/1`'s own `normalize_filter_value/2`
      # precedent for the identical `war_room_id` case.
      with {:ok, binary_id} <- Ecto.UUID.cast(room_id) |> uuid_dump() do
        result =
          Ecto.Adapters.SQL.query!(
            Nebu.Repo,
            "SELECT #{@session_columns} FROM war_room_sessions WHERE id = $1",
            [binary_id]
          )

        case result.rows do
          [row] -> row_to_session(row)
          [] -> nil
        end
      else
        :error -> nil
      end
    else
      nil
    end
  rescue
    # Defensive: a malformed (non-UUID-shaped) room_id in the URL must show
    # AC6's 404, never crash the page.
    _ -> nil
  end

  defp uuid_dump({:ok, canonical}), do: {:ok, Ecto.UUID.dump!(canonical)}
  defp uuid_dump(:error), do: :error

  defp load_entries(room_id) do
    if Process.whereis(Nebu.Repo) do
      {:ok, rows} = Nebu.Web.LogStore.get_logs(%{war_room_id: room_id})
      # get_logs/1 returns most-recent-first; AC5 requires ascending
      # chronological order for the captured-logs section.
      Enum.reverse(rows)
    else
      []
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
      # `id` is a native Postgres `uuid` column — a raw `Ecto.Adapters.SQL.query!/3`
      # (this module's own inline SQL, ADR-018) returns it as a 16-byte
      # BINARY, not the canonical hex-dash STRING (see
      # `Nebu.Web.LogStore.get_logs/1`'s own moduledoc comment on this exact
      # Postgrex behavior) — converted here since `id` is rendered directly
      # into `data-room-id`/`href`/markdown text throughout this module.
      id: Ecto.UUID.load!(id),
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

  # ══════════════════════════════════════════════════════════════════════════
  # View-model helpers
  # ══════════════════════════════════════════════════════════════════════════

  # AC1 guarantees an active session (ended_at IS NULL) sorts first when one
  # exists — AC2 of war-room-mode guarantees at most one such row exists at
  # all.
  defp active_session([%{ended_at: nil} = session | _rest]), do: session
  defp active_session(_sessions), do: nil

  # UX gate advisory 5 / AC2: "Session ID (truncated or full — operator's
  # choice)" must be VISIBLE, announced text on each row — the row already
  # carries the full id in `data-room-id`, but a data attribute is invisible
  # to sighted AND screen-reader users alike. The full id is still available
  # via the `title` tooltip and the detail page.
  defp truncated_id(id) when is_binary(id), do: String.slice(id, 0, 8)

  defp scope_label(session) do
    base = session.scope || "all"

    case session.exclusive_scope do
      nil -> base
      [] -> base
      excl -> base <> " except " <> Enum.join(excl, ", ")
    end
  end

  defp filter_summary(nil), do: "—"
  defp filter_summary(filter) when filter == %{}, do: "—"

  defp filter_summary(filter) when is_map(filter) do
    Enum.map_join(filter, ", ", fn {k, v} -> "#{k}: #{v}" end)
  end

  defp status_badge_text(%{ended_at: nil}), do: "🟢 Active"

  defp status_badge_text(%{ended_reason: reason}) do
    "🔴 Ended (" <> String.replace(reason || "unknown", "_", " ") <> ")"
  end

  defp entries_badge_text(session), do: "#{session.entries_collected}/#{session.max_entries}"

  defp time_range_text(%{ended_at: nil, started_at: started_at}) do
    "started " <> ago_text(started_at) <> " ago"
  end

  defp time_range_text(%{started_at: started_at, ended_at: ended_at}) do
    format_dt(started_at) <> " → " <> format_dt(ended_at)
  end

  defp duration_text(%{ended_at: nil, started_at: started_at, max_duration_s: max_duration_s}) do
    elapsed = DateTime.diff(DateTime.utc_now(), started_at, :second)
    remaining = max(max_duration_s - elapsed, 0)
    format_clock(remaining) <> " remaining"
  end

  defp duration_text(%{started_at: started_at, ended_at: ended_at}) do
    format_clock(max(DateTime.diff(ended_at, started_at, :second), 0))
  end

  defp ago_text(started_at) do
    seconds = max(DateTime.diff(DateTime.utc_now(), started_at, :second), 0)

    cond do
      seconds < 60 -> "#{seconds}s"
      seconds < 3600 -> "#{div(seconds, 60)}m"
      true -> "#{div(seconds, 3600)}h"
    end
  end

  defp format_dt(nil), do: "—"
  defp format_dt(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  defp format_dt(dt), do: to_string(dt)

  defp format_clock(total_seconds) when total_seconds >= 3600 do
    hours = div(total_seconds, 3600)
    rest = rem(total_seconds, 3600)
    "#{pad2(hours)}:#{pad2(div(rest, 60))}:#{pad2(rem(rest, 60))}"
  end

  defp format_clock(total_seconds) do
    "#{pad2(div(total_seconds, 60))}:#{pad2(rem(total_seconds, 60))}"
  end

  defp pad2(n), do: String.pad_leading(Integer.to_string(n), 2, "0")

  # ══════════════════════════════════════════════════════════════════════════
  # Copy-to-markdown (AC14, Dev Notes template — matched exactly by the ATDD
  # regexes, see moduledoc)
  # ══════════════════════════════════════════════════════════════════════════

  defp markdown_text(session, entries) do
    """
    # War Room Session #{session.id}

    **Started by:** #{session.started_by}
    **Reason:** #{session.reason}
    **Scope:** #{scope_label(session)}
    **Filter:** #{filter_summary(session.filter)}
    **Time:** #{format_dt(session.started_at)} → #{if session.ended_at, do: format_dt(session.ended_at), else: "active"}
    **Entries collected:** #{session.entries_collected} / #{session.max_entries}

    ## Captured Logs

    #{Enum.map_join(entries, "\n", &markdown_entry_line/1)}
    """
  end

  defp markdown_entry_line(entry) do
    "- `#{entry.inserted_at}` [#{entry.level}] [#{entry.source}] #{entry.message}"
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Render
  # ══════════════════════════════════════════════════════════════════════════

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div class="flex items-center justify-between mb-4">
      <h1 class="text-heading font-semibold">War Room</h1>
      <.link
        :if={@mode == :detail}
        navigate="/admin/logs/war-room"
        data-testid="war-room-detail-back-link"
        class="link link-primary text-sm"
      >
        ← Back to War Room sessions
      </.link>
    </div>

    <.render_list :if={@mode == :list} {assigns} />
    <.render_detail :if={@mode == :detail} {assigns} />
    """
  end

  defp render_list(assigns) do
    assigns = assign(assigns, :active_session, active_session(assigns.sessions))

    ~H"""
    <section aria-label="Start a new War Room session" class="mb-6">
      <h2 class="font-semibold mb-2">Start a new War Room session</h2>

      <div data-testid="war-room-trace-preview" class="mb-3">
        <h3 class="text-sm font-medium text-text-secondary mb-1">Live activity (level + source)</h3>
        <div class="flex flex-wrap gap-2 mb-2">
          <TraceMapBubble.trace_map_bubble
            :for={lvl <- @levels}
            dimension={:level}
            value={lvl}
            count={Map.get(@level_counts, lvl, 0)}
            active={false}
            mode={:readonly}
            on_click={nil}
          />
        </div>
        <div class="flex flex-wrap gap-2">
          <TraceMapBubble.trace_map_bubble
            :for={src <- @sources}
            dimension={:source}
            value={src}
            count={Map.get(@source_counts, src, 0)}
            active={false}
            mode={:readonly}
            on_click={nil}
          />
        </div>
      </div>

      <%!-- AC2 of war-room-mode: at most one active session at a time — while
            one is active, this banner (reusing the RETIRED embedded panel's
            own `war-room-panel`/`stop-war-room-button` testids, amendment 2:
            "may be reused... if convenient") replaces the start form. --%>
      <div
        :if={@active_session}
        data-testid="war-room-panel"
        aria-label="War Room"
        class="mb-4 rounded-lg border-2 border-error bg-error/5 p-4 max-w-md"
      >
        <div class="flex items-center justify-between mb-2 gap-2">
          <h3 class="font-semibold text-error">🚨 War Room Active</h3>
          <button
            type="button"
            data-testid="stop-war-room-button"
            phx-click="stop_war_room"
            phx-value-room_id={@active_session.id}
            class="btn btn-sm btn-error"
          >
            Stop War Room
          </button>
        </div>
        <p data-testid="war-room-status" class="text-sm">
          {entries_badge_text(@active_session)} entries · started by {@active_session.started_by}
          for reason: {@active_session.reason}
        </p>
      </div>

      <form
        :if={is_nil(@active_session)}
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
          <select
            name="scope"
            data-testid="war-room-scope-select"
            phx-change="scope_changed"
            class="select select-bordered select-sm"
          >
            <option value="">-- select scope --</option>
            <option value="all" selected={@form_scope == "all"}>all endpoints</option>
            <option value="/_matrix/client/v3/sync">/_matrix/client/v3/sync</option>
            <option value="exclusive">exclusive (all except…)</option>
          </select>
        </label>

        <div
          :if={@form_scope == "exclusive"}
          data-testid="war-room-exclusive-options"
          class="border border-base-300 rounded p-2 flex flex-col gap-1"
        >
          <p class="text-xs text-text-secondary mb-1">Exclude these endpoints from capture:</p>
          <label :for={route <- TraceMap.long_polling_endpoints()} class="flex items-center gap-2 text-sm">
            <input type="checkbox" name="exclusive_scope[]" value={route} />
            <span class="font-mono">{route}</span>
          </label>
          <label class="flex items-center gap-2 text-sm mt-1">
            <span>other:</span>
            <input
              type="text"
              name="exclusive_other"
              placeholder="/custom/noisy/route"
              class="input input-bordered input-xs"
            />
          </label>
        </div>

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
          <input
            type="number"
            name="max_entries"
            value="100"
            min="10"
            max="10000"
            class="input input-bordered input-sm"
          />
        </label>

        <label class="form-control">
          <span class="label-text">max_duration_s</span>
          <input
            type="number"
            name="max_duration_s"
            value="300"
            min="10"
            max="3600"
            class="input input-bordered input-sm"
          />
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

        <p :if={@start_error} data-testid="war-room-start-error" class="text-sm text-status-error-text" role="alert">
          {@start_error}
        </p>

        <button type="submit" data-testid="start-war-room-button" class="btn btn-error btn-sm">
          🚨 Start War Room
        </button>
      </form>
    </section>

    <section aria-label="War Room sessions">
      <h2 class="font-semibold mb-2">Sessions</h2>

      <div :if={@sessions == []} data-testid="war-room-empty-state" class="text-sm text-text-secondary">
        No War Room sessions yet. Use the form above to start one and begin diagnostic
        logging.
      </div>

      <div :if={@sessions != []} class="flex flex-col gap-2">
        <.link
          :for={session <- @sessions}
          navigate={"/admin/logs/war-room/" <> session.id}
          data-testid="war-room-session-row"
          data-room-id={session.id}
          class="block card card-compact bg-base-100 border border-base-300 p-3 hover:bg-base-200 focus:outline-none focus-visible:ring-2 focus-visible:ring-primary"
        >
          <div class="flex items-center gap-3 text-sm flex-wrap">
            <span data-testid="war-room-session-status" class="font-semibold">{status_badge_text(session)}</span>
            <span
              data-testid="war-room-session-id"
              class="font-mono text-xs text-text-secondary"
              title={session.id}
            >
              {truncated_id(session.id)}
            </span>
            <span data-testid="war-room-session-started-by" class="font-mono text-xs">{session.started_by}</span>
            <span data-testid="war-room-session-reason">{session.reason}</span>
            <span data-testid="war-room-session-scope" class="font-mono text-xs">{scope_label(session)}</span>
            <span data-testid="war-room-session-filter" class="text-xs text-text-secondary">
              {filter_summary(session.filter)}
            </span>
            <span data-testid="war-room-session-time-range" class="text-xs text-text-secondary">
              {time_range_text(session)}
            </span>
            <span data-testid="war-room-session-entries" class="badge badge-sm">{entries_badge_text(session)}</span>
            <span data-testid="war-room-session-duration" class="font-mono text-xs">{duration_text(session)}</span>
          </div>
        </.link>
      </div>
    </section>
    """
  end

  defp render_detail(assigns) do
    ~H"""
    <%= if @session do %>
      <section data-testid="war-room-detail-meta" aria-label="Session details" class="mb-4 rounded-lg border border-base-300 p-4">
        <h2 class="font-semibold mb-2">Session {@session.id}</h2>
        <p><span data-testid="war-room-session-status">{status_badge_text(@session)}</span></p>
        <p>Started by: {@session.started_by}</p>
        <p>Reason: {@session.reason}</p>
        <p>Scope: {scope_label(@session)}</p>
        <p>Filter: {filter_summary(@session.filter)}</p>
        <p>Budget: {@session.max_entries} entries / {@session.max_duration_s}s</p>
        <p>Started at: {format_dt(@session.started_at)}</p>
        <p>Ended at: {if @session.ended_at, do: format_dt(@session.ended_at), else: "—"}</p>
        <p>Ended reason: {@session.ended_reason || "—"}</p>
        <p>Entries collected: {entries_badge_text(@session)}</p>

        <button
          type="button"
          data-testid="war-room-copy-markdown-button"
          data-copy-text={markdown_text(@session, @entries)}
          phx-click={JS.dispatch("nebu:copy-thread") |> JS.push("copy_to_markdown")}
          aria-label="Copy session summary to clipboard as markdown"
          class="btn btn-sm btn-ghost mt-2"
        >
          Copy to Markdown
        </button>
      </section>

      <p
        :if={@copy_toast != ""}
        data-testid="war-room-copy-toast"
        role="status"
        class="alert alert-success text-sm mb-3"
      >
        {@copy_toast}
      </p>

      <h2 class="font-semibold mb-2">Logs captured by this session</h2>
      <div aria-label="Captured request stream" class="flex flex-col gap-1">
        <div
          :for={entry <- @entries}
          data-testid="request-row"
          data-request-id={entry.request_id}
          class="card card-compact bg-base-100 border-l-4 border-base-300 p-3"
        >
          <div class="flex items-center gap-3 text-sm flex-wrap">
            <span class="font-mono text-xs text-text-secondary whitespace-nowrap">{format_dt(entry.inserted_at)}</span>
            <span class="badge badge-sm">{entry.level}</span>
            <span class="text-xs text-text-secondary">{entry.source}</span>
            <span class="font-mono text-xs">{entry.route_template}</span>
            <span>{entry.message}</span>
          </div>
        </div>
      </div>
    <% else %>
      <div data-testid="war-room-not-found" class="alert alert-error">
        War Room session not found.
      </div>
    <% end %>
    """
  end
end
