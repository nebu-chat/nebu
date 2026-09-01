defmodule Nebu.Admin.LogsLive do
  @moduledoc """
  Admin Logs Monitoring View (enhanced-logging/admin-logs-monitoring-view).

  Live request-stream at `/admin/logs`, grouped by `request_id`, with
  live-updating Trace Map filter bubbles for the log-level and source
  dimensions.

  ## Endpoint dimension retired (enhanced-logging/trace-map-leitstand, AC13)

  The embedded Endpoints section (flat bubble list + the trace-map-hierarchy
  disclosure tree) was removed from this page: endpoint filtering now lives
  on the dedicated `/admin/logs/trace-map` Leitstand page
  (`Nebu.Admin.LogsLive.TraceMap`, radial map). `@active_filters` here
  tracks only the `level`/`source` dimensions. `TraceMapTree` (the retired
  tree component) is KEPT as a module — its `domain_for_endpoint/1`/
  `group_endpoints_by_domain/1` heuristics are the canonical domain grouping
  the Leitstand page reuses.

  ## PubSub message shape (AC11/AC12)

  `Nebu.Web.LogStore.Handler.safe_broadcast/1` broadcasts a BARE MAP over
  `Phoenix.PubSub.broadcast(Nebu.PubSub, "operational_logs", entry)` — NOT a
  `{:operational_log_entry, entry}` tuple. `handle_info/2` below matches the
  bare map directly.

  ## Trace Map filter toggle is server-tracked (bug fix trace-map-filter-reset-bugfix)

  Originally (admin-logs-monitoring-view, AC3) the filter toggle was
  CLIENT-SIDE ONLY — no `handle_event("toggle_filter", ...)` clause existed,
  and every re-render hardcoded `active: false` for each Trace Map bubble.
  That was the root cause of trace-map-filter-reset-bugfix: any unrelated
  re-render (e.g. a new log entry bumping a sibling bubble's live count)
  silently reasserted `active: false`, wiping out the client-side click.

  The fix: `@active_filters` is now real, persistent `socket.assigns` state.
  Every Trace Map bubble's `phx-click` still fires
  `Phoenix.LiveView.JS.dispatch/2` FIRST (`nebu:trace-bubble-click`,
  UNCHANGED — `priv/static/assets/app.js`'s `wireTraceMapFilters` still owns
  the INSTANT, client-side-only DOM toggle + AND-filtering, so clicking has
  no perceptible lag regardless of server latency), followed by
  `JS.push("toggle_filter", ...)`, a genuine, asynchronous server round trip
  handled by `handle_event("toggle_filter", ...)`/`handle_event("remove_filter",
  ...)` below — see `bubble_js/2`'s own comment for the full rationale,
  including why native `handle_params/3` was evaluated and rejected. Browser
  back/forward navigation additionally round-trips through
  `handle_event("sync_filters", ...)` (see its own comment below) — `app.js`'s
  `popstate` listener pushes this event so a URL-restored filter state also
  updates `@active_filters`, not just the DOM.

  ### Multi-select within a dimension (dev-story cycle 1, code-review MAJOR
  finding M1)

  `@active_filters` stores a LIST of active values PER DIMENSION (e.g.
  `%{"level" => [...], "source" => [...]}`), not a
  single scalar value — this matches the pre-existing CLIENT-side filter
  (`app.js`'s `activeTraceMapFilters`/`traceMapRowMatches`, which already
  OR-combines multiple active values within the same dimension; the click
  handler toggles each bubble independently, with no mutual exclusion).
  Storing only one value per dimension server-side reintroduced this
  story's exact bug for the multi-select case: clicking `level=error` then
  `level=warning` left the server thinking only `warning` was active, so
  the next unrelated re-render silently deactivated the `error` bubble.
  `toggle_filter`/`remove_filter`/`sync_filters` all operate on these lists
  (add/remove one value, or wholesale-replace the list), and every bubble's
  `active:` attribute is computed via list membership
  (`value in Map.get(@active_filters, dimension, [])`), not `==`.

  `open_detail`/`close_detail`/`pause_live_updates`/`resume_live_updates` are
  unrelated, pre-existing real server round-trips (bare event-name
  `phx-click`), unaffected by any of the above.

  ## Embedded War Room panel retired (enhanced-logging/war-room-dedicated-page,
  amendment 2)

  The `Nebu.Admin.LogsLive.WarRoomPanel` "start a new session" panel no
  longer renders here — it moved entirely to the dedicated
  `/admin/logs/war-room` page (`Nebu.Admin.LogsLive.WarRoom`). This module
  still POLLS `Nebu.Admin.WarRoomManager.status/0` every 2s (unchanged
  cadence) so the sidebar recording dot / topbar pill
  (`Nebu.Admin.Layouts.live/1`, amendment 4) stay live while an operator is
  on this page — see `@war_room_active`/`@war_room_started_at`/
  `@war_room_started_by`. The pre-existing `war-room-viewing-banner`
  (`?war_room_id=...`, a DIFFERENT, read-only feature from `war-room-mode`'s
  own AC12) is unaffected.
  """
  use Phoenix.LiveView, layout: {Nebu.Admin.Layouts, :live}

  alias Nebu.Admin.LogsLive.DetailPanel
  alias Nebu.Admin.LogsLive.TraceMapBubble
  alias Nebu.Admin.MediaAttentionBadge
  alias Nebu.Admin.WarRoomIndicator
  alias Phoenix.LiveView.JS

  @topic "operational_logs"

  @levels ["error", "warning", "info", "debug"]
  @sources ["http", "ecto", "other"]

  @severity_rank %{"error" => 4, "warning" => 3, "info" => 2, "debug" => 1}

  # Bug fix (trace-map-filter-reset-bugfix, dev-story cycle 1, code-review
  # MINOR finding): whitelist of the only dimensions `@active_filters`
  # tracks — `toggle_filter`/`remove_filter` guard on this so a malformed or
  # unexpected `dimension` string (e.g. a stale/crafted client payload)
  # cannot insert a junk key into `@active_filters` that no bubble ever
  # reads.
  #
  # enhanced-logging/trace-map-leitstand (AC13): the "endpoint" dimension was
  # RETIRED from this page along with the embedded Trace Map's Endpoints
  # section — endpoint filtering now lives on the dedicated
  # /admin/logs/trace-map Leitstand page (`Nebu.Admin.LogsLive.TraceMap`).
  # Only the Levels and Sources filter sections remain here.
  @filter_dimensions ["level", "source"]

  # M3 fix (bug-fix cycle 5, code-review MAJOR finding): caps the number of
  # DISTINCT `request_id` rows kept in `@entries_by_request`/`@row_order`/
  # `@row_meta`/the `:rows` stream for the lifetime of this LiveView process.
  # Matches `initial_entries/0`'s own DB-seed cap (`Enum.take(200)`) — the
  # story's Dev Notes explicitly call for "Keep the loaded data size
  # reasonable (e.g., last 100 requests)"; 200 is chosen to match the
  # existing seed cap rather than introduce a second, different magic number.
  # See `maybe_evict_oldest_row/1` for the eviction policy.
  #
  # NOT implemented via `stream/4`'s/`stream_configure/3`'s built-in `:limit`
  # option: that option evicts by PHYSICAL STREAM POSITION (first/last
  # inserted slot), but this stream is kept sorted by SEVERITY-THEN-RECENCY
  # (AC7), not by arrival order — the physically-last row in the stream is
  # whichever one currently sorts lowest (e.g. the oldest DEBUG row), not
  # necessarily the oldest-ARRIVED one. Using `:limit` here would therefore
  # evict the wrong row (e.g. discard a low-severity row that just arrived,
  # while a truly ancient but currently-still-highest-severity row survives
  # indefinitely). `maybe_evict_oldest_row/1` below evicts explicitly by
  # `first_seq` (arrival order) instead, independent of the stream's own
  # sort position.
  @max_rows 200

  # ══════════════════════════════════════════════════════════════════════════
  # Mount
  # ══════════════════════════════════════════════════════════════════════════

  @impl Phoenix.LiveView
  def mount(params, session, socket) do
    Phoenix.PubSub.subscribe(Nebu.PubSub, @topic)
    MediaAttentionBadge.subscribe()

    {:ok, policy} = Nebu.Web.LogStore.get_policy()

    # enhanced-logging/war-room-mode (AC12): `live_isolated/3` (used by
    # every OTHER test in this LiveView's suite) always passes the literal
    # atom `:not_mounted_at_router` here, never a real query-param map —
    # this clause only ever matches when mounted through the real router
    # (`Phoenix.LiveViewTest.live/2` + `Phoenix.ConnTest.get/3`), which is
    # exactly how a bookmarked `/admin/logs?war_room_id=...` link arrives.
    viewing_war_room_id = war_room_id_param(params)
    war_room_status = initial_war_room_status()

    socket =
      socket
      # admin-sidebar-nesting coordination contract (story Dev Notes item 5):
      # the monitoring view highlights the "Live Stream" CHILD of the nested
      # "Logs" nav section; the parent gets its secondary accent from the
      # child match in Nebu.Admin.Layouts.nav_item/1.
      |> assign(:active_nav, "logs-monitoring")
      |> assign(:page_title, "Logs")
      |> assign(:policy, policy)
      |> assign(:detail_request_id, nil)
      |> assign(:paused, false)
      |> assign(:pending_count, 0)
      |> assign(:next_seq, 0)
      |> assign(:entries_by_request, %{})
      |> assign(:levels, @levels)
      |> assign(:sources, @sources)
      |> assign(:level_counts, Map.new(@levels, &{&1, 0}))
      |> assign(:source_counts, Map.new(@sources, &{&1, 0}))
      # V3 fix (UX/accessibility gate, blocking): `row_order`/`row_meta` back
      # the incremental `upsert_row/2` sort-position bookkeeping below — see
      # its moduledoc-style comment for why a full `reset: true` stream
      # rebuild on every ingest was wrong. The `dom_id` function MUST be
      # configured on THIS initial call (a stream "may not be re-configured"
      # once items exist — see `Phoenix.LiveView.stream_configure/3`'s docs);
      # every later `stream_insert`/`stream_delete_by_dom_id` call reuses it.
      |> assign(:row_order, [])
      |> assign(:row_meta, %{})
      # enhanced-logging/war-room-mode (AC11/AC12).
      |> assign(:viewing_war_room_id, viewing_war_room_id)
      |> assign(:current_admin_id, admin_id_from_session(session))
      # enhanced-logging/war-room-dedicated-page (amendment 4): threaded
      # through to Nebu.Admin.Layouts.live/1 for the sidebar recording dot /
      # topbar pill.
      |> WarRoomIndicator.assign_status(war_room_status)
      # Bug fix (trace-map-filter-reset-bugfix, AC1/AC3): seeds the Trace
      # Map's filter state from the page's own URL query params
      # (`?endpoint=...&level=...&source=...`) — read HERE, directly in
      # `mount/3`, exactly like the existing `war_room_id_param/1` pattern
      # just above, rather than via a `handle_params/3` callback.
      #
      # WHY NOT `handle_params/3` (the mechanism the Dev Notes' primary
      # proposal originally named): empirically verified against the real
      # `phoenix_live_view 1.2.3` dependency (not merely assumed) that simply
      # EXPORTING a `handle_params/3` callback on this module makes EVERY
      # `live_isolated/3`-mounted test in this LiveView's OWN, pre-existing
      # suite (the large majority of `logs_live_test.exs`) fail at mount —
      # `live_isolated/3` deliberately runs a LiveView "not mounted... with
      # the live/3 macro" (per that function's own docs: "features such as
      # live navigation require routable LiveViews"), and `handle_params/3`
      # is unconditionally rejected for such a socket, regardless of
      # whether a patch is ever actually attempted. Breaking ~20 existing,
      # deliberately-`live_isolated/3`-based tests would itself violate this
      # story's own AC4 ("all existing admin-logs-monitoring-view tests
      # continue to pass unmodified"). Reading query params directly in
      # `mount/3` sidesteps this entirely: `mount/3` receives the real query
      # params for ANY router-mounted view (confirmed by the pre-existing
      # `war_room_id_param/1` precedent) and the harmless `:not_mounted_at_router`
      # atom for `live_isolated/3` (safely defaulting to "no active filters"
      # below), with NO dependency on `handle_params/3` at all.
      |> assign(:active_filters, active_filters_from_params(params, policy))
      # media-security-admin-control/5b-live-updates-nav-badges.
      |> assign(:media_attention_count, MediaAttentionBadge.initial_count())
      |> stream(:rows, [], dom_id: &row_dom_id/1)

    socket =
      Enum.reduce(initial_entries(viewing_war_room_id), socket, fn entry, acc ->
        ingest_entry(acc, entry)
      end)

    # enhanced-logging/war-room-dedicated-page (amendment 4): unconditional
    # (not gated on "already active") — the sidebar dot/topbar pill must be
    # able to APPEAR later while this page stays open, mirroring
    # Nebu.Admin.LogsLive.TraceMap's own "always rescheduled... because the
    # banner must also appear when a session starts later" war-room poll.
    if connected?(socket) and Process.whereis(Nebu.Repo) do
      WarRoomIndicator.schedule()
    end

    {:ok, socket}
  end

  # Bug fix (trace-map-filter-reset-bugfix, AC1/AC3): seeds `@active_filters`
  # from the page's own URL query params. `params` is a real query-param map
  # for any router-mounted view (mirrors `war_room_id_param/1` just below —
  # both read directly off `mount/3`'s own `params` argument), and the
  # literal atom `:not_mounted_at_router` for `live_isolated/3` (which falls
  # through to the second clause, defaulting to "no active filters").
  #
  # dev-story cycle 1, code-review M1: each dimension's query-param value is
  # a COMMA-JOINED list of values (e.g. `?level=error,warning`), not a
  # single scalar — `app.js`'s `syncTraceMapUrlFromBubbles`/
  # `pushFilterSyncToServer` encode multiple active values this way (chosen
  # over repeated bare params like `?level=error&level=warning`, since
  # `Plug.Conn.Query.decode/1` documents "if a value is given more than
  # once, the LAST value takes precedence" — a repeated bare param would
  # silently lose every value but the last one; a comma-joined value
  # round-trips cleanly through `mount/3`'s param parsing with no extra
  # bracket-array ceremony).
  #
  # code-review MINOR finding: a URL can seed an "off"/uncollected value
  # (e.g. `?level=debug` while `log_collect_debug` is false) even though the
  # click handler's own off-bubble guard (`app.js`'s `bubbleOff === "true"`
  # early-return) would never let a real click activate it — bypassing that
  # guard via a hand-crafted/bookmarked URL. `policy` (already computed at
  # the top of `mount/3`) is used here to drop any "off" level value before
  # it ever reaches `@active_filters`. Only the `level` dimension has an
  # "off" concept (`level_off?/2`, mirroring `render/1`'s own `off={...}`
  # attribute) — `endpoint`/`source` have none.
  defp active_filters_from_params(%{} = params, policy) do
    Map.new(@filter_dimensions, fn dimension ->
      values = params[dimension] |> parse_filter_values() |> reject_off_tier(dimension, policy)
      {dimension, values}
    end)
  end

  defp active_filters_from_params(_params, _policy) do
    Map.new(@filter_dimensions, &{&1, []})
  end

  defp parse_filter_values(nil), do: []
  defp parse_filter_values(""), do: []

  defp parse_filter_values(value) when is_binary(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  # enhanced-logging/war-room-mode (AC12): present only when mounted through
  # the real router with a `?war_room_id=...` query param — `params` is the
  # literal atom `:not_mounted_at_router` for every `live_isolated/3` mount,
  # which never matches the map pattern below and falls through to `nil`.
  defp war_room_id_param(%{"war_room_id" => id}) when is_binary(id) and id != "", do: id
  defp war_room_id_param(_params), do: nil

  # Prefer matrix_user_id (`@kai:localhost`-shaped, human-readable) over the
  # raw OIDC `sub` claim (protobuf-encoded by Dex, opaque to operators) — this
  # value is displayed verbatim in the War Room recording pill/banner/session
  # list, so an opaque sub defeats the whole point of showing "who is
  # recording" at a glance (design-conformance fix, 2026-07-08).
  defp admin_id_from_session(%{"current_user" => %{"matrix_user_id" => uid}})
       when is_binary(uid) and uid != "",
       do: uid

  defp admin_id_from_session(%{"current_user" => %{"sub" => sub}})
       when is_binary(sub) and sub != "",
       do: sub

  defp admin_id_from_session(_session), do: "unknown-admin"

  # `Nebu.Admin.WarRoomManager.status/0` always performs a live DB read —
  # never call it when `Nebu.Repo` is not running (plain unit test runs).
  # Delegates to the shared `Nebu.Admin.WarRoomIndicator` helper (amendment 4).
  defp initial_war_room_status do
    WarRoomIndicator.status()
  end

  # `Nebu.Web.LogStore.get_logs/1` always performs a live DB read — never call
  # it when `Nebu.Repo` is not running (plain unit test runs, or a genuinely
  # DB-less deploy). Mirrors `Nebu.Admin.AuditLogLive.load_events/0`'s guard.
  defp initial_entries(nil) do
    if Process.whereis(Nebu.Repo) do
      {:ok, rows} = Nebu.Web.LogStore.get_logs(%{})

      # get_logs/1 returns most-recent-first; reverse to oldest-first so
      # ingest_entry/2's monotonic `next_seq` counter preserves the real
      # chronological arrival order across the whole seeded window (AC6's
      # "load the most recent N requests" perf note — capped at 200 here).
      rows
      |> Enum.take(200)
      |> Enum.reverse()
    else
      []
    end
  end

  # enhanced-logging/war-room-mode (AC12): a bookmarked war-room session
  # slice is a HISTORICAL, filtered view — potentially spanning well beyond
  # the default 200-row cap (a session's own max_entries can be up to
  # 10 000) — not the live/most-recent-N window the default mount uses. No
  # Enum.take/2 cap here: the war room's own max_entries bound already keeps
  # this bounded by design.
  defp initial_entries(war_room_id) do
    if Process.whereis(Nebu.Repo) do
      {:ok, rows} = Nebu.Web.LogStore.get_logs(%{war_room_id: war_room_id})
      Enum.reverse(rows)
    else
      []
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # handle_info/2 — live PubSub subscription (AC11/AC12)
  # ══════════════════════════════════════════════════════════════════════════

  @impl Phoenix.LiveView
  def handle_info(%{level: _level, source: _source, request_id: _request_id} = entry, socket) do
    {:noreply, ingest_entry(socket, entry)}
  end

  # enhanced-logging/war-room-mode (AC11) + war-room-dedicated-page
  # (amendment 4): re-polls the active session's budget/elapsed-time so the
  # live status bar actually ticks, AND keeps the sidebar dot/topbar pill
  # assigns current. Unconditionally rescheduled (see mount/3's own
  # comment) — the indicator must be able to APPEAR later, not merely
  # persist while already active.
  def handle_info(:refresh_war_room_status, socket) do
    status = initial_war_room_status()
    if Process.whereis(Nebu.Repo), do: WarRoomIndicator.schedule()

    {:noreply, WarRoomIndicator.assign_status(socket, status)}
  end

  # media-security-admin-control/5b-live-updates-nav-badges.
  def handle_info({:media_state_transition, _media_id, old_state, new_state}, socket) do
    {:noreply, MediaAttentionBadge.apply_transition(socket, old_state, new_state)}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  # ══════════════════════════════════════════════════════════════════════════
  # handle_event/3 — server-side events (detail panel + pause/resume banner +
  # Bug fix trace-map-filter-reset-bugfix's "toggle_filter"/"remove_filter").
  # ══════════════════════════════════════════════════════════════════════════

  # Bug fix (trace-map-filter-reset-bugfix, AC1/AC2/AC5): fixes the root
  # cause directly — `@active_filters` becomes real, persistent
  # `socket.assigns` state instead of the original, permanently-`false`
  # `active:` value every Trace Map bubble used to render with. Any LATER,
  # unrelated re-render (e.g. `handle_info/2` ingesting a new log entry,
  # which changes `@level_counts`/`@source_counts` — `@endpoint_counts` was
  # retired with the Endpoints dimension, trace-map-leitstand AC13) now
  # reads THIS real state for the `active:` attr instead of a hardcoded
  # constant, so it can no longer silently overwrite an operator's click.
  #
  # Pushed via `JS.push/2` (see `bubble_js/3` below), NOT `JS.push` blocking
  # the click — `JS.dispatch("nebu:trace-bubble-click")` (UNCHANGED from the
  # original admin-logs-monitoring-view story) is always the FIRST command
  # in the list and fires synchronously/instantly in the browser; this
  # `handle_event` round-trip happens asynchronously alongside it, so AC2's
  # "no perceptible click lag" holds regardless of server latency.
  #
  # dev-story cycle 1, code-review MAJOR finding M1: each dimension holds a
  # LIST of active values, not a single scalar — toggling ADDS the value if
  # absent, REMOVES it if present, mirroring the client-side
  # `wireTraceMapFilters` click handler's OR-within-a-dimension semantics
  # (each bubble toggles independently, no mutual exclusion within the same
  # dimension). The `dimension in @filter_dimensions` guard (code-review
  # MINOR finding) rejects any unexpected dimension string outright — no
  # `handle_event` clause below matches it, so no junk key is ever inserted
  # into `@active_filters`.
  #
  # dev-story cycle 3, code-review MINOR finding: this is the MOST directly
  # reachable of the three `@active_filters` write paths (an ordinary click
  # — no URL-crafting or back/forward navigation needed), yet it was the
  # only one of the three missing the off-tier `level` guard that
  # `active_filters_from_params/2` (mount) and `sync_filters` (popstate)
  # already applied — a crafted `toggle_filter` push (e.g.
  # `liveSocket.main.pushEvent(...)` from devtools) could mark an off-tier
  # level as active server-side. `toggle_filter_value/4` now runs every
  # toggle result through the same shared `reject_off_tier/3` helper those
  # other two paths call, closing this the same way instead of a fourth
  # bespoke copy.
  @impl Phoenix.LiveView
  def handle_event("toggle_filter", %{"dimension" => dimension, "value" => value}, socket)
      when dimension in @filter_dimensions do
    new_filters =
      toggle_filter_value(socket.assigns.active_filters, dimension, value, socket.assigns.policy)

    {:noreply, assign(socket, :active_filters, new_filters)}
  end

  def handle_event("toggle_filter", _params, socket), do: {:noreply, socket}

  # Chip "×" removal (AC3/AC4) — always clears the ONE specific value the
  # chip is paired to (never the whole dimension — a dimension can hold
  # MULTIPLE active values per the M1 fix above, and removing one chip must
  # not clear its siblings), mirroring the pre-existing client-side
  # chip-remove contract (`app.js`'s `nebu:trace-chip-remove` listener only
  # ever deactivates the ONE bubble paired to the clicked chip).
  def handle_event("remove_filter", %{"dimension" => dimension, "value" => value}, socket)
      when dimension in @filter_dimensions do
    new_filters =
      Map.update(socket.assigns.active_filters, dimension, [], &List.delete(&1, value))

    {:noreply, assign(socket, :active_filters, new_filters)}
  end

  def handle_event("remove_filter", _params, socket), do: {:noreply, socket}

  # Bug fix (trace-map-filter-reset-bugfix, AC3, code-review finding, dev-story
  # cycle 0 follow-up): browser back/forward navigation fires `popstate`,
  # which `priv/static/assets/app.js`'s listener handles ENTIRELY
  # client-side (`applyTraceMapFiltersFromUrl/0` only mutates
  # `aria-pressed`/CSS classes/row visibility directly in the DOM from the
  # now-current URL) — it never informed the server. That left
  # `@active_filters` silently stale after a back/forward jump: e.g. click
  # endpoint, click level:error (server now tracks BOTH active via
  # `toggle_filter` above), then go back (DOM/URL correctly show only
  # endpoint active, server still thinks both are). The NEXT
  # server-triggered re-render of the mismatched bubble (any incoming log
  # entry touching that bubble's `:for` comprehension item) then
  # re-asserted the STALE server state over the just-restored client
  # state — reintroducing this story's exact bug via the back/forward path
  # instead of a plain click.
  #
  # Fix: `app.js`'s `popstate` listener also pushes THIS event (see that
  # file's `pushFilterSyncToServer/0`), reading the URL query params it
  # just restored, so `@active_filters` gets replaced WHOLESALE to match.
  # A wholesale replace (not a per-dimension toggle) is required because a
  # single back/forward jump can change more than one dimension's value at
  # once (e.g. two clicks, then one "back" undoes both). Missing dimensions
  # in `filters` default to "no active value" for that dimension, mirroring
  # `active_filters_from_params/2`'s own mount-time defaulting.
  #
  # dev-story cycle 1, code-review MAJOR finding M1: each dimension's
  # pushed value is normalized to a LIST via `normalize_filter_values/1` —
  # accepting either a real list (what `app.js`'s `pushFilterSyncToServer`
  # now sends, one entry per currently-`aria-pressed="true"` bubble in that
  # dimension) OR a bare scalar/`nil` (kept for backward compatibility with
  # the pre-existing single-value regression tests below, and because a
  # comma-joined scalar is just as valid a wire format as an actual list).
  #
  # dev-story cycle 2, code-review MINOR follow-up (residual half-fix of a
  # cycle-1 MINOR): `active_filters_from_params/2` (the mount-time URL-seed
  # path) already drops any "off"-tier `level` value (e.g. `?level=debug`
  # while `log_collect_debug` is false) before it reaches `@active_filters`
  # — but THIS handler (the `popstate`-driven `sync_filters` path) built
  # `@active_filters` straight from `normalize_filter_values/1` with no such
  # guard. A hand-crafted/bookmarked `?level=debug` URL (while `debug` is
  # off) followed by any browser back/forward re-opens the exact bypass that
  # cycle-1 MINOR was meant to close.
  #
  # dev-story cycle 3: this handler and `active_filters_from_params/2` now
  # both call the SAME shared `reject_off_tier/3` helper (also used by
  # `toggle_filter_value/4`) instead of each keeping its own copy of the
  # guard — see that helper's own comment for why.
  # enhanced-logging/trace-map-leitstand (AC13): the "toggle_domain" handler
  # (trace-map-hierarchy's disclosure toggle) was removed together with the
  # embedded Endpoints tree it served — domain grouping now lives on the
  # dedicated /admin/logs/trace-map page as a radial map, not a disclosure
  # tree.
  def handle_event("sync_filters", %{"filters" => filters}, socket) when is_map(filters) do
    policy = socket.assigns.policy

    new_filters =
      Map.new(@filter_dimensions, fn dimension ->
        values =
          filters[dimension] |> normalize_filter_values() |> reject_off_tier(dimension, policy)

        {dimension, values}
      end)

    {:noreply, assign(socket, :active_filters, new_filters)}
  end

  def handle_event("open_detail", %{"request_id" => request_id}, socket) do
    # V5(b) fix (UX/accessibility gate, blocking): AC8/AC10 — "if the user
    # has scrolled down OR opened a detail row" — opening the detail panel
    # pauses live updates server-side directly (no client round-trip needed;
    # this handler is already a genuine server event). Scroll-triggered pause
    # is handled client-side (see priv/static/assets/app.js's
    # `wireLiveUpdatesPause`, which clicks the hidden
    # `[data-testid="pause-live-updates-trigger"]` button).
    {:noreply,
     socket
     |> assign(:detail_request_id, request_id)
     |> assign(:paused, true)}
  end

  def handle_event("close_detail", _params, socket) do
    {:noreply, assign(socket, :detail_request_id, nil)}
  end

  def handle_event("pause_live_updates", _params, socket) do
    {:noreply, socket |> assign(:paused, true) |> assign(:pending_count, 0)}
  end

  def handle_event("resume_live_updates", _params, socket) do
    {:noreply, socket |> assign(:paused, false) |> assign(:pending_count, 0)}
  end

  # dev-story cycle 1, code-review MAJOR finding M1: adds `value` to the
  # dimension's list if absent, removes it if already present — mirrors
  # `app.js`'s own click-handler semantics exactly (toggle THIS ONE value,
  # independent of any other value already active in the same dimension).
  #
  # dev-story cycle 3, code-review MINOR finding: the toggle result is run
  # through the SAME `reject_off_tier/3` guard `active_filters_from_params/2`
  # and `sync_filters` already apply (see that helper's own comment) — a
  # crafted `toggle_filter` push (e.g. from devtools, bypassing app.js's own
  # `bubbleOff === "true"` early-return that a real click would hit) can no
  # longer leave an off-tier `level` value marked active in `@active_filters`.
  # Filtering AFTER the toggle (rather than short-circuiting the add) also
  # correctly handles removal: deleting an already-off-tier value (however it
  # got there) still works, since rejecting it again is a no-op.
  defp toggle_filter_value(active_filters, dimension, value, policy) do
    active_filters
    |> Map.update(dimension, [value], fn values ->
      if value in values, do: List.delete(values, value), else: values ++ [value]
    end)
    |> Map.update!(dimension, &reject_off_tier(&1, dimension, policy))
  end

  # dev-story cycle 3, code-review MINOR finding (whack-a-mole across 3
  # cycles): the single, centralized guard for "an off-tier `level` value
  # (per `level_off?/2`, e.g. `?level=debug` while `log_collect_debug` is
  # false) must never end up stored in `@active_filters`" — no bubble click
  # (real or crafted) and no bookmarked/pushed URL state can ever activate a
  # bubble the UI itself renders as "off" (`btn-outline`, greyed out).
  #
  # Cycle 0 added this guard only to `active_filters_from_params/2` (mount);
  # cycle 1/2 added a SEPARATE, hand-copied instance of the same
  # `Enum.reject(&level_off?(policy, &1))` line to `sync_filters`
  # (popstate) after the mount-only guard was found to have a residual gap
  # there; cycle 2's reverify then found a THIRD entry point —
  # `toggle_filter_value/4` (the plain click path, the MOST directly
  # reachable of the three) — missing the guard entirely. Every one of
  # `active_filters_from_params/2`, `handle_event("sync_filters", ...)`, and
  # `toggle_filter_value/4` now calls THIS ONE function instead of
  # reimplementing the check, so a hypothetical fourth write path is forced
  # to either reuse it (safe) or conspicuously skip calling any off-tier
  # guard at all (easy to spot in review) — it cannot silently duplicate a
  # slightly-different, slightly-wrong copy of the same logic again.
  #
  # Only `level` has an "off" concept (`level_off?/2`, mirroring `render/1`'s
  # own `off={...}` attribute) — `endpoint`/`source` have none, so this is a
  # no-op for those dimensions.
  defp reject_off_tier(values, "level", policy), do: Enum.reject(values, &level_off?(policy, &1))
  defp reject_off_tier(values, _dimension, _policy), do: values

  # dev-story cycle 1, code-review MAJOR finding M1: normalizes a
  # `sync_filters`-pushed dimension value (a real list from `app.js`'s
  # `pushFilterSyncToServer`, OR a bare scalar/`nil` from the pre-existing
  # single-value regression tests) into the list shape `@active_filters`
  # now stores. Blank/`nil` list entries are dropped; a scalar is delegated
  # to `parse_filter_values/1` (comma-split, same as the URL-param path).
  defp normalize_filter_values(values) when is_list(values) do
    values
    |> Enum.map(&blank_to_nil/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_filter_values(value), do: parse_filter_values(value)

  # ══════════════════════════════════════════════════════════════════════════
  # Ingest — updates counts + the rows stream for one operational_logs entry
  # ══════════════════════════════════════════════════════════════════════════

  # `request_id` can be `nil` for system/background log lines that are not
  # tied to any HTTP request (e.g. Ecto/Oban/scheduled-job entries logged
  # outside a `Plug.Conn` lifecycle) — plausible and expected in a live
  # system (bug-fix cycle 4, CI-gate finding: `initial_entries/0`'s live-DB
  # seed can include real `operational_logs` rows with a `nil` `request_id`).
  # The request-stream groups entries by `request_id` and shows "one row per
  # request" (AC6) — an entry with NO request_id belongs to no request
  # thread and must NOT produce/upsert a row in the `:rows` stream (doing so
  # crashed `row_dom_id/1`'s `Base.url_encode64(row.request_id, ...)`, which
  # requires a binary). The Trace Map's level/source bubble counts (AC1) are
  # NOT request-scoped — they count all loaded/ingested events regardless of
  # whether that event belongs to a request thread — so those counts (and
  # endpoint tracking) are updated unconditionally below, only the row-stream
  # upsert (and the `entries_by_request` bookkeeping that solely feeds it) is
  # skipped for a `nil` request_id.
  defp ingest_entry(socket, entry) do
    level = normalize_level(entry[:level])

    # Security review finding F-1 (2026-07-05, MEDIUM, security-reports/
    # admin-logs-monitoring-view-security-review-2026-07-05.md) noted that
    # `safe_broadcast/1` (upstream) fires for EVERY log event regardless of
    # `should_persist?/1` — broadcast and persistence are DELIBERATELY
    # decoupled by design (see this module's own moduledoc, "PubSub message
    # shape", and `Nebu.Web.LogStore`'s moduledoc: "ALWAYS broadcasts...
    # independent of persistence"). An attempted fix (bug-fix cycle 7) added
    # an ingest-time `level_off?/2` guard to suppress "off"-tier entries from
    # the live view entirely — but `get_policy/0`'s documented default is
    # `log_collect_info: false`/`log_collect_debug: false` whenever
    # `server_config` is unset OR `Nebu.Repo` isn't running (plain unit-test
    # runs), so that guard silently dropped ALL "info"-level entries (the
    # default/most common test fixture level) under `make test-unit-elixir`,
    # regressing ~7 existing tests — a direct conflict with the documented
    # broadcast-independent-of-persistence architecture, not a genuine bug.
    # REVERTED. Kassandra's finding remains: CLEAN/APPROVED, MEDIUM
    # (non-blocking) — accepted as a follow-up for a future story to
    # reconsider deliberately (e.g. a distinct "live-view visibility" policy
    # dimension, separate from the persistence-gating `log_collect_*` keys,
    # if the product decides the "⚫ off" bubble should also suppress live
    # broadcast display — out of scope here to avoid destabilizing the
    # already-shipped broadcast-decoupled-from-persistence design).
    do_ingest_entry(socket, entry, level)
  end

  defp do_ingest_entry(socket, entry, level) do
    seq = socket.assigns.next_seq
    entry = Map.put(entry, :__seq__, seq)
    source = bucket_source(entry[:source])
    request_id = entry.request_id

    socket =
      socket
      |> assign(:next_seq, seq + 1)
      |> update(:level_counts, &Map.update(&1, level, 1, fn c -> c + 1 end))
      |> update(:source_counts, &Map.update(&1, source, 1, fn c -> c + 1 end))

    if is_nil(request_id) do
      socket
    else
      socket =
        socket
        |> update(:entries_by_request, fn map ->
          Map.update(map, request_id, [entry], &(&1 ++ [entry]))
        end)

      socket =
        if socket.assigns.paused do
          update(socket, :pending_count, &(&1 + 1))
        else
          socket
        end

      upsert_row(socket, request_id)
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp normalize_level(level) when is_binary(level), do: level
  defp normalize_level(level) when is_atom(level) and not is_nil(level), do: Atom.to_string(level)
  defp normalize_level(_), do: "info"

  defp bucket_source("http"), do: "http"
  defp bucket_source("ecto"), do: "ecto"
  defp bucket_source(_), do: "other"

  defp normalize_route(nil), do: nil
  defp normalize_route(""), do: nil
  defp normalize_route(route) when is_binary(route), do: route
  defp normalize_route(route), do: to_string(route)

  # ══════════════════════════════════════════════════════════════════════════
  # Upsert a single row into the stream — V3 fix (UX/accessibility gate,
  # BLOCKING violation). The previous implementation called
  # `stream(socket, :rows, rows, reset: true)` on EVERY ingest, which tears
  # down and recreates every row's DOM node on every single incoming log
  # line. Since the Trace Map's client-side filter (app.js) applies via
  # `row.style.display = "none"` directly on those DOM nodes, `reset: true`
  # silently wiped any active filter (and the user's scroll position / open
  # detail state) the instant a new entry arrived anywhere — defeating
  # AC9/AC10's explicit "additive, no collapsing" requirement under the exact
  # live-update conditions it exists to support.
  #
  # This upserts ONLY the single row whose `request_id` this entry belongs
  # to, using `Phoenix.LiveView.stream_insert/4`. Per `stream_insert/4`'s own
  # docs, `:at` has NO effect on an item that already exists in the client's
  # DOM — to actually MOVE an existing row (its severity tier changed, e.g. a
  # previously-INFO request just received an ERROR entry, per AC7) it must
  # first be deleted via `stream_delete_by_dom_id/3`, then re-inserted at the
  # new index. All OTHER rows' DOM nodes are left completely untouched, so
  # their filter visibility / scroll position / open-detail state survive.
  #
  # Sort order (AC7: severity first, then newest-first within a tier) is
  # maintained incrementally in `@row_order` (list of request_ids in current
  # stream order) + `@row_meta` (request_id => %{highest_level, first_seq}),
  # avoiding an O(n) `entries_by_request` scan on every ingest.
  # ══════════════════════════════════════════════════════════════════════════
  defp upsert_row(socket, request_id) do
    entries = Map.fetch!(socket.assigns.entries_by_request, request_id)
    row = build_row({request_id, entries})
    new_meta = %{highest_level: row.highest_level, first_seq: row.first_seq}
    old_meta = Map.get(socket.assigns.row_meta, request_id)

    order_without = Enum.reject(socket.assigns.row_order, &(&1 == request_id))
    index = insertion_index(order_without, socket.assigns.row_meta, new_meta)
    new_order = List.insert_at(order_without, index, request_id)

    socket =
      socket
      |> assign(:row_order, new_order)
      |> update(:row_meta, &Map.put(&1, request_id, new_meta))

    socket =
      if old_meta != nil and sort_key(old_meta) != sort_key(new_meta) do
        socket
        |> stream_delete_by_dom_id(:rows, row_dom_id(row))
        |> stream_insert(:rows, row, at: index)
      else
        stream_insert(socket, :rows, row, at: index)
      end

    # M3 fix: only a GENUINELY NEW row (`old_meta == nil`) can grow the total
    # distinct-request-id count past `@max_rows` — a tier-migration move (the
    # branch above) re-positions an EXISTING row and leaves the count
    # unchanged, so eviction is only ever considered here.
    if is_nil(old_meta) do
      maybe_evict_oldest_row(socket)
    else
      socket
    end
  end

  # Evicts the single OLDEST row (by `first_seq`, i.e. arrival order) once the
  # distinct-request-id count exceeds `@max_rows` — "last N requests" means the
  # LEAST-RECENTLY-ARRIVED request drops off, regardless of its severity tier
  # (evicting by severity would perversely discard freshly-arrived ERROR rows
  # first, exactly the ones an operator most needs during an incident).
  # Removes the row from every place it is tracked: `@row_order`/`@row_meta`
  # (sort-order bookkeeping), `@entries_by_request` (the row's own log
  # entries — freed so they don't hold memory indefinitely), and the `:rows`
  # stream itself (`stream_delete_by_dom_id/3`, so the evicted row's DOM node
  # is actually removed from the client, bounding browser memory/DOM size
  # too, not just server-side process memory).
  #
  # Deliberately does NOT touch `@level_counts`/`@source_counts` (nor, when
  # it still existed pre-trace-map-leitstand-AC13, `@endpoint_counts`):
  # bug-fix cycle 4 already established (see
  # `ingest_entry/2`'s moduledoc-style comment above, and its own regression
  # test) that these Trace Map bubble counts are NOT request-scoped — they
  # count every ingested event since mount, independent of whether that event
  # produced/still has a backing row at all (a `nil`-request_id entry updates
  # them but never has a row to evict in the first place). Acceptance Test 1's
  # own baseline+delta assertions rely on this "cumulative since page load"
  # semantics. Making the bubble counts track the row-eviction window instead
  # would require re-deriving them from the entries of every evicted row (an
  # O(entries-per-row) decrement on every eviction) and would contradict that
  # already-shipped, already-tested design — so they are intentionally left
  # as cumulative "since page load" counters, independent of this row-count
  # cap.
  defp maybe_evict_oldest_row(socket) do
    order = socket.assigns.row_order

    if length(order) > @max_rows do
      oldest_id =
        Enum.min_by(order, fn id -> Map.fetch!(socket.assigns.row_meta, id).first_seq end)

      socket
      |> stream_delete_by_dom_id(:rows, row_dom_id(%{request_id: oldest_id}))
      |> update(:row_order, &Enum.reject(&1, fn id -> id == oldest_id end))
      |> update(:row_meta, &Map.delete(&1, oldest_id))
      |> update(:entries_by_request, &Map.delete(&1, oldest_id))
    else
      socket
    end
  end

  defp sort_key(meta), do: {-severity_rank(meta.highest_level), -meta.first_seq}

  defp insertion_index(order_without, row_meta, new_meta) do
    new_key = sort_key(new_meta)

    Enum.find_index(order_without, fn other_id ->
      other_meta = Map.fetch!(row_meta, other_id)
      sort_key(other_meta) > new_key
    end) || length(order_without)
  end

  defp row_dom_id(row), do: "request-row-" <> Base.url_encode64(row.request_id, padding: false)

  defp build_row({request_id, entries}) do
    sorted_entries = Enum.sort_by(entries, & &1.__seq__)
    first_entry = List.first(sorted_entries)
    first_seq = first_entry.__seq__

    levels = Enum.map(sorted_entries, fn e -> normalize_level(e[:level]) end)
    highest_level = Enum.max_by(levels, &severity_rank/1, fn -> "info" end)

    sources =
      sorted_entries |> Enum.map(fn e -> e[:source] end) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    http_entry = Enum.find(sorted_entries, fn e -> e[:source] == "http" end)

    # AC6 micro-summary ("N debug, N info, N warn, N error"): counts the
    # events that happened DURING the request (Ecto queries, warnings, etc)
    # — the top-level HTTP request/response line itself is already
    # summarized separately (method+path/status/duration) and is excluded
    # here, matching Acceptance Test 4's literal expectation (an HTTP entry
    # + 5 "ecto" entries yields a count of 5, not 6). `highest_level` above
    # still considers EVERY entry, including the HTTP line.
    counted_levels =
      sorted_entries
      |> Enum.reject(fn e -> e[:source] == "http" end)
      |> Enum.map(fn e -> normalize_level(e[:level]) end)

    %{
      id: request_id,
      request_id: request_id,
      first_seq: first_seq,
      entries: sorted_entries,
      highest_level: highest_level,
      counts: %{
        "debug" => Enum.count(counted_levels, &(&1 == "debug")),
        "info" => Enum.count(counted_levels, &(&1 == "info")),
        "warning" => Enum.count(counted_levels, &(&1 == "warning")),
        "error" => Enum.count(counted_levels, &(&1 == "error"))
      },
      sources: sources,
      endpoint: http_entry && normalize_route(http_entry[:route_template]),
      method: http_entry && meta_get(http_entry, "method"),
      status: http_entry && meta_get(http_entry, "status"),
      duration_ms: http_entry && meta_get(http_entry, "duration_ms"),
      timestamp: display_timestamp(first_entry)
    }
  end

  defp severity_rank(level), do: Map.get(@severity_rank, level, 0)

  defp meta_get(entry, key) do
    case entry[:metadata] do
      map when is_map(map) -> Map.get(map, key) || Map.get(map, String.to_atom(key))
      _ -> nil
    end
  end

  defp display_timestamp(%{inserted_at: %_{} = ts}), do: to_string(ts)
  defp display_timestamp(%{inserted_at: ts}) when is_binary(ts), do: ts
  defp display_timestamp(entry), do: "seq:" <> to_string(entry.__seq__)

  # ══════════════════════════════════════════════════════════════════════════
  # Render
  # ══════════════════════════════════════════════════════════════════════════

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div class="flex items-center justify-between mb-4">
      <h1 class="text-heading font-semibold">Logs</h1>
      <.link navigate="/admin/logs/config" class="link link-primary text-sm">
        Sammlung konfigurieren →
      </.link>
    </div>

    <div
      :if={@viewing_war_room_id}
      data-testid="war-room-viewing-banner"
      class="alert alert-info mb-4 flex items-center justify-between"
    >
      <span>Viewing War Room session {@viewing_war_room_id}</span>
      <.link navigate="/admin/logs" class="link link-primary text-sm">← Back to all logs</.link>
    </div>

    <section aria-label="Trace Map" class="mb-4">
      <h2 class="font-semibold mb-2">Trace Map</h2>

      <%!--
        dev-story cycle 1, code-review MINOR finding (blast-radius): `app.js`'s
        `pushFilterSyncToServer/0` (fired from a WINDOW-level `popstate`
        listener bound once at boot — see that function's own comment) needs
        a `pushEvent` target element. It used to target `document.body`,
        which sets a PAGE-WIDE `data-phx-ref-lock` during the round trip
        (blocking patches to the whole page, not just the Trace Map — e.g.
        the `new-entries-banner` aria-live region). This tiny, hidden,
        purely structural marker exists ONLY on `/admin/logs` (i.e. only
        while THIS LiveView — the one that actually owns the Trace Map — is
        mounted), so it doubles as the fix for code-review MAJOR finding M2:
        `pushFilterSyncToServer` checks for this element's presence before
        pushing anything, so a `popstate` firing while a SIBLING LiveView
        (Dashboard/AuditLog, same `live_session :admin`, neither of which
        has a `handle_event("sync_filters", ...)` clause) is mounted instead
        is now a safe no-op rather than an `UndefinedFunctionError` crash.
      --%>
      <span id="trace-map-sync-anchor" class="hidden" aria-hidden="true"></span>

      <%!--
        enhanced-logging/trace-map-leitstand (AC13): the "Endpoints" dimension
        section (the flat bubble list from admin-logs-monitoring-view and the
        domain-grouped disclosure tree from trace-map-hierarchy) was RETIRED
        from this page — endpoint filtering now lives on the dedicated
        /admin/logs/trace-map Leitstand page (`Nebu.Admin.LogsLive.TraceMap`,
        radial map). Only the Levels and Sources sections below remain.
      --%>
      <div class="mb-3">
        <h3 class="text-sm font-medium text-text-secondary mb-1">Levels</h3>
        <div class="flex flex-wrap gap-2">
          <TraceMapBubble.trace_map_bubble
            :for={lvl <- @levels}
            dimension={:level}
            value={lvl}
            count={Map.get(@level_counts, lvl, 0)}
            active={lvl in Map.get(@active_filters, "level", [])}
            off={level_off?(@policy, lvl)}
            mode={:filter}
            on_click={bubble_js("level", lvl)}
          />
        </div>
      </div>

      <div class="mb-3">
        <h3 class="text-sm font-medium text-text-secondary mb-1">Sources</h3>
        <div class="flex flex-wrap gap-2">
          <TraceMapBubble.trace_map_bubble
            :for={src <- @sources}
            dimension={:source}
            value={src}
            count={Map.get(@source_counts, src, 0)}
            active={src in Map.get(@active_filters, "source", [])}
            mode={:filter}
            on_click={bubble_js("source", src)}
          />
        </div>
      </div>
    </section>

    <div data-testid="active-filter-chips" aria-label="Active filters" class="flex flex-wrap gap-2 mb-4">
      <span
        :for={lvl <- @levels}
        data-testid="filter-chip"
        data-chip-dimension="level"
        data-chip-value={lvl}
        class="badge badge-outline gap-1"
        style="display:none;"
      >{String.upcase(lvl)}<.chip_remove dimension="level" value={lvl} /></span>
      <span
        :for={src <- @sources}
        data-testid="filter-chip"
        data-chip-dimension="source"
        data-chip-value={src}
        class="badge badge-outline gap-1"
        style="display:none;"
      >{src}<.chip_remove dimension="source" value={src} /></span>
    </div>

    <div :if={@paused and @pending_count > 0} data-testid="new-entries-banner" aria-live="polite" class="alert alert-info flex items-center justify-between mb-4">
      <span>{@pending_count} new {plural(@pending_count)} available</span>
      <button type="button" phx-click="resume_live_updates" class="btn btn-sm btn-primary">Resume live updates</button>
    </div>

    <%!--
      V1 fix (UX/accessibility gate, BLOCKING — WCAG 2.1.1): rows used to be a
      `<div role="listitem" tabindex="0" phx-click=...>`. A `tabindex="0"` div
      does NOT get native Space/Enter-to-activate keyboard behavior — only
      `<button>`/`<a>` do. Rows are now real `<button>` elements: natural Tab
      order, native Space/Enter activation, no hand-rolled keydown handler
      needed. `role="list"`/`role="listitem"` (a mismatched pairing for a
      list of BUTTONS, not `<li>`s) is dropped in favor of a plain
      `aria-label` on the container — screen readers announce each row via
      its own accessible name (built from the row's visible text) exactly
      like any other button in a toolbar.
    --%>
    <div id="request-rows" phx-update="stream" aria-label="Request stream" class="flex flex-col gap-1">
      <button
        :for={{dom_id, row} <- @streams.rows}
        id={dom_id}
        type="button"
        data-testid="request-row"
        data-request-id={row.request_id}
        data-highest-level={row.highest_level}
        data-endpoint={row.endpoint || ""}
        data-sources={Enum.join(row.sources, " ")}
        data-count-debug={row.counts["debug"]}
        data-count-info={row.counts["info"]}
        data-count-warn={row.counts["warning"]}
        data-count-error={row.counts["error"]}
        phx-click="open_detail"
        phx-value-request_id={row.request_id}
        class={[
          "w-full text-left card card-compact bg-base-100 border-l-4 p-3 cursor-pointer hover:bg-base-200",
          "focus:outline-none focus-visible:ring-2 focus-visible:ring-primary",
          accent_class(row.highest_level)
        ]}
      >
        <div class="flex items-center gap-3 text-sm flex-wrap">
          <span class="font-mono text-xs text-text-secondary whitespace-nowrap">{row.timestamp}</span>
          <span class="font-mono">{method_path_text(row)}</span>
          <span data-testid="status-badge" aria-label={status_aria_label(row)}>{status_icon(row)} {status_text(row)}</span>
          <span data-testid="level-badge" class={["badge badge-sm", level_badge_class(row.highest_level)]} aria-label={level_aria_label(row.highest_level)}>{level_icon(row.highest_level)} {String.upcase(row.highest_level)}</span>
          <span class="text-xs text-text-secondary">{micro_summary(row.counts)}</span>
          <span class="font-mono text-xs">{duration_text(row)}</span>
        </div>
      </button>
    </div>

    <%!--
      V5(b) fix (UX/accessibility gate, BLOCKING): AC10's "pause live updates
      once the operator has scrolled away from the top" trigger has no real
      client-side source — this hidden button IS a genuine
      `phx-click="pause_live_updates"` (a real server round-trip, wired to
      the existing `handle_event/3` clause below). `app.js`'s
      `wireLiveUpdatesPause` clicks it programmatically once the admin
      scrolls `#main-content` away from the top. It carries no visible text
      and is not part of the tab order — it is a pure JS-to-LiveView bridge,
      never meant to be discovered by a keyboard/screen-reader user (compare
      the VISIBLE "Resume live updates" button above, which already is a
      real `phx-click="resume_live_updates"`).
    --%>
    <button
      type="button"
      phx-click="pause_live_updates"
      data-testid="pause-live-updates-trigger"
      class="hidden"
      aria-hidden="true"
      tabindex="-1"
    >Pause live updates (scroll trigger)</button>

    <DetailPanel.detail_panel :if={@detail_request_id} request_id={@detail_request_id} entries={detail_entries(@entries_by_request, @detail_request_id)} />
    """
  end

  # Small helper component: a chip's own "×" remove control. Distinct DOM
  # node from the Trace Map bubble it mirrors (test-review finding #4/#5 —
  # Acceptance Test 1b). Client-side-only for the INSTANT visual toggle
  # (AC2): `phx-click`'s FIRST op stays the pre-existing
  # `JS.dispatch("nebu:trace-chip-remove")`, handled entirely in the browser
  # by `app.js`'s `wireTraceMapFilters` — no server round-trip is awaited
  # before the chip disappears / the bubble dims.
  #
  # Bug fix (trace-map-filter-reset-bugfix, AC1/AC3): a SECOND op,
  # `JS.push("remove_filter", ...)`, is appended so the removal ALSO informs
  # the server which value was cleared (`handle_event("remove_filter",
  # ...)` above) — otherwise the server's own `@active_filters` (now the
  # source of truth for what each bubble renders as `active`, per the
  # root-cause fix) would still think this value is active, and the very
  # next unrelated re-render would silently re-show it.
  #
  # dev-story cycle 1, code-review MAJOR finding M1: passes `value` (not
  # just `dimension`) — a dimension can now hold MULTIPLE active values, so
  # the server needs to know WHICH ONE this specific chip's "×" removes,
  # not just which dimension to clear entirely.
  attr(:dimension, :string, required: true)
  attr(:value, :string, required: true)

  defp chip_remove(assigns) do
    ~H"""
    <button
      type="button"
      data-testid="filter-chip-remove"
      data-chip-dimension={@dimension}
      data-chip-value={@value}
      aria-label={"Remove filter " <> @value}
      phx-click={
        JS.dispatch("nebu:trace-chip-remove")
        |> JS.push("remove_filter", value: %{"dimension" => @dimension, "value" => @value})
      }
      class="btn btn-ghost btn-xs px-1"
    >×</button>
    """
  end

  # ── filter toggle (AC1/AC2/AC3/AC5): a JS command list, never a bare
  # event name. The FIRST op, `JS.dispatch("nebu:trace-bubble-click")`, is
  # UNCHANGED from the original admin-logs-monitoring-view story —
  # `priv/static/assets/app.js`'s `wireTraceMapFilters` still listens for it
  # and performs the instant, client-side-only aria-pressed toggle +
  # AND-across-dimensions row/chip visibility update, with NO server
  # round-trip awaited (AC2: no perceptible click lag).
  #
  # Bug fix (trace-map-filter-reset-bugfix, AC1/AC5): a SECOND op,
  # `JS.push("toggle_filter", ...)`, is appended so the SAME click also
  # asynchronously informs the server which filter is now active
  # (`handle_event("toggle_filter", ...)` above) — this is the actual root
  # -cause fix: `@active_filters` becomes real, persistent socket state, so
  # a LATER, unrelated re-render (e.g. a new incoming log entry bumping this
  # bubble's own live count) can no longer silently reset it back to
  # inactive. `JS.push/2` is fire-and-forget from the CLICK's perspective —
  # it does not block or delay the `dispatch` op's instant visual toggle
  # above, so AC2 holds regardless of server latency.
  #
  # NOTE ON AC3 (shareable/bookmarkable URL): a native `Phoenix.LiveView.JS.
  # patch/2` + `handle_params/3` round trip was evaluated FIRST as the
  # primary mechanism (per this story's own Dev Notes) and rejected after
  # empirically confirming — against the real, installed `phoenix_live_view
  # 1.2.3` dependency, not merely assumed — that simply EXPORTING a
  # `handle_params/3` callback on this module makes EVERY `live_isolated/3`-
  # mounted test in this LiveView's large, pre-existing test suite fail at
  # mount (`live_isolated/3` is documented as NOT "mounted... with the
  # live/3 macro", which `handle_params/3` unconditionally requires,
  # regardless of whether a patch is ever attempted). Breaking that
  # existing suite would itself violate this story's AC4. The URL-reflects-
  # active-filters requirement is instead satisfied client-side, in
  # `priv/static/assets/app.js` (`history.pushState`/`popstate`), driven by
  # the SAME `nebu:trace-bubble-click`/`nebu:trace-chip-remove` events this
  # dispatch already fires — see that file's own comments — while the
  # SERVER-side fix above independently and completely resolves the
  # reported bug (AC1/AC5): the filter no longer resets under live traffic,
  # regardless of how the URL bar itself is kept in sync.
  defp bubble_js(dimension_key, value) do
    JS.dispatch("nebu:trace-bubble-click")
    |> JS.push("toggle_filter", value: %{"dimension" => dimension_key, "value" => value})
  end

  defp level_off?(policy, "info"), do: policy.log_collect_info != true
  defp level_off?(policy, "debug"), do: policy.log_collect_debug != true
  defp level_off?(_policy, _level), do: false

  defp detail_entries(entries_by_request, request_id) do
    entries_by_request
    |> Map.get(request_id, [])
    |> Enum.sort_by(& &1.__seq__)
  end

  defp method_path_text(%{method: method, endpoint: endpoint})
       when is_binary(method) and is_binary(endpoint) do
    method <> " " <> endpoint
  end

  defp method_path_text(_row), do: "—"

  defp status_icon(%{method: method}) when not is_binary(method), do: "🔵"
  defp status_icon(%{status: status}), do: status_bucket(status) |> elem(0)

  defp status_text(%{method: method}) when not is_binary(method), do: "unknown"
  defp status_text(%{status: status}), do: status_bucket(status) |> elem(1)

  defp status_aria_label(row), do: "HTTP status " <> status_text(row)

  defp status_bucket(status) when is_integer(status) do
    cond do
      status in 200..299 -> {"🟢", "2xx"}
      status in 300..399 -> {"🟡", "3xx"}
      status in 400..499 -> {"🟠", "4xx"}
      status >= 500 -> {"🔴", "5xx"}
      true -> {"🔵", "unknown"}
    end
  end

  defp status_bucket(_), do: {"🔵", "unknown"}

  defp duration_text(%{duration_ms: ms}) when is_integer(ms), do: "#{ms}ms"
  defp duration_text(_row), do: "—"

  defp micro_summary(counts) do
    "#{counts["debug"]} debug, #{counts["info"]} info, #{counts["warning"]} warn, #{counts["error"]} error"
  end

  defp level_icon("error"), do: "🔴"
  defp level_icon("warning"), do: "🟠"
  defp level_icon("info"), do: "🟢"
  defp level_icon("debug"), do: "⚪"
  defp level_icon(_), do: "⚪"

  defp level_badge_class("error"), do: "badge-error"
  defp level_badge_class("warning"), do: "badge-warning"
  defp level_badge_class("info"), do: "badge-info"
  defp level_badge_class(_), do: "badge-neutral"

  defp level_aria_label("error"), do: "Error level"
  defp level_aria_label("warning"), do: "Warning level"
  defp level_aria_label("info"), do: "Info level"
  defp level_aria_label(_), do: "Debug level"

  defp accent_class("error"), do: "border-error"
  defp accent_class("warning"), do: "border-warning"
  defp accent_class(_), do: "border-success"

  defp plural(1), do: "entry"
  defp plural(_), do: "entries"
end
