defmodule Nebu.Admin.LogsLive.TraceMap do
  @moduledoc """
  Trace Map "Leitstand" — the dedicated, full-page radial health map at
  `/admin/logs/trace-map` (enhanced-logging/trace-map-leitstand).

  Story: docs/stories/enhanced-logging/trace-map-leitstand.md
  Design: _bmad-output/nebu/epics/enhanced-logging/design/trace-map-leitstand-spec.md
  Visual reference: trace-map-leitstand-dummy.html (same directory).

  ## Why this is a SEPARATE LiveView module, not a new action on `Nebu.Admin.LogsLive`

  AC5 hard-requires URL-driven filter state via `push_patch/2` +
  `handle_params/3` (the lesson of trace-map-filter-reset-bugfix: filter
  state must live in LiveView assigns seeded from the URL, NEVER in
  client-DOM-only state). Merely EXPORTING a `handle_params/3` callback on a
  LiveView module makes every `live_isolated/3`-mounted test of that module
  fail at mount (empirically verified against the installed
  `phoenix_live_view` — see `Nebu.Admin.LogsLive`'s own moduledoc). The
  existing `Nebu.Admin.LogsLive` (Live Stream page) has a large,
  deliberately-`live_isolated/3`-based suite, so the Leitstand gets its own
  module and `Nebu.Admin.LogsLive` stays `handle_params/3`-free.

  ## State model

    * `@selected` — the active endpoint filters (satellite routes and/or
      domain keys), URL-driven: `handle_params/3` seeds it from the
      bracket-array `?endpoint[]=X&endpoint[]=Y` query params; every node
      click round-trips through `handle_event("toggle_node"/"clear_filters")`
      -> `push_patch/2` -> `handle_params/3`. Bracket-array (not the story's
      literal repeated bare `?endpoint=X&endpoint=Y`) per the story's own
      "Story Amendments": `Plug.Conn.Query.decode/1` is last-wins on repeated
      bare keys, so the bare form cannot round-trip.
    * `@node_states` — one `Nebu.Admin.LogsLive.TraceMapStatus` state per map
      node (`"nebu"`, each domain key, each satellite route): the AC3
      60-second sliding window. Events are recorded at ALL THREE levels on
      ingest so every node carries its own windowed request/warning/error
      counts; a parent's STATUS is still derived via
      `TraceMapStatus.worst/1` over its children (worst-child propagation,
      spec §2), with the parent's own aggregated state included defensively
      (covers nil-route entries that belong to no domain, for nebu).
    * `@active_levels` — the stream panel's level filter (AC9), plain
      assigns state (the leitstand shortcut is computed server-side in
      `handle_event("toggle_level", ...)`).
    * Geometry is computed server-side by `Nebu.Admin.TraceMapGeometry`
      (spec §8 constraint 3); domain grouping REUSES
      `Nebu.Admin.LogsLive.TraceMapTree.domain_for_endpoint/1` via
      `group_endpoints_by_domain/1` (never duplicated).

  ## PubSub / data source

  Same source as the Live Stream page: mount-time history from
  `Nebu.Web.LogStore.get_logs/1` (guarded behind `Process.whereis(Nebu.Repo)`
  so plain unit-test runs stay DB-free) + live `"operational_logs"` PubSub
  broadcasts of bare entry maps.

  ## No sensitive data (spec §8 constraint 5)

  The map, tooltips, aria-labels and the live announcer only ever carry
  route templates + counts. Log MESSAGE text appears only in the stream
  panel and the inspector's recent-events list — the same already-redacted
  `message` field the Live Stream page shows (LogStore's writer owns
  redaction) — never in tooltips/labels/announcements.

  ## CSP (spec §8 constraint 2)

  No inline JS anywhere. Client-only behavior (tooltip positioning, resizer
  drag/keyboard, Enter/Space activation of SVG nodes, stream autoscroll,
  war-room elapsed clock, status-transition pings) lives in the
  `TraceMapLeitstand` phx-hook in `server/priv/static/assets/app.js`;
  animations (error pulse, recording dot, pings) are pure CSS `@keyframes`
  in `server/assets/css/app.css`, disabled under `prefers-reduced-motion`.
  """
  use Phoenix.LiveView, layout: {Nebu.Admin.Layouts, :live}

  require Logger

  alias Nebu.Admin.LogsLive.TraceMapStatus
  alias Nebu.Admin.LogsLive.TraceMapTree
  alias Nebu.Admin.MediaAttentionBadge
  alias Nebu.Admin.TemporaryCaptureManager
  alias Nebu.Admin.TraceMapGeometry
  alias Nebu.Admin.WarRoomIndicator

  @topic "operational_logs"
  @base_path "/admin/logs/trace-map"

  # UI level-pill vocabulary (spec §7) <-> LogStore level strings. The pill
  # labels are the spec's abbreviated forms; `Nebu.Web.LogStore` entries use
  # "warning"/"error" — mapped via ui_level/1 below.
  @ui_levels ["DEBUG", "INFO", "WARN", "ERROR"]

  @domain_labels %{
    "/_matrix/client" => "Matrix Client",
    "/_matrix/media" => "Matrix Media",
    "/admin" => "Admin",
    "/health" => "Health"
  }

  # enhanced-logging/trace-map-node-controls (AC4/AC13): the canonical,
  # reusable off-by-default long-polling endpoint list. This is the SAME
  # backend concept the superseded `noise-endpoint-bucketing` story would
  # have used — `long_polling_endpoints/0` is the single source of truth,
  # reused by `Nebu.Web.LogStore.should_persist?/2` (server-side
  # enforcement) and available for future stories (war-room-dedicated-page's
  # "safe scope" option, trace-map-hierarchy's domain-grouping).
  @long_polling_endpoints [
    "/_matrix/client/v3/sync",
    "/admin/keepalive",
    "/admin/live/longpoll",
    "/health"
  ]

  @retention_options [{"1", "1 d"}, {"7", "7 d"}, {"30", "30 d"}]

  @doc """
  The config-driven off-by-default long-polling endpoint list (AC4/AC13).
  """
  @spec long_polling_endpoints() :: [String.t()]
  def long_polling_endpoints, do: @long_polling_endpoints

  @doc """
  Whether `route` is one of the off-by-default long-polling endpoints
  (AC4). `nil`/non-binary routes are never off-tier.
  """
  @spec off_endpoint?(term()) :: boolean()
  def off_endpoint?(route) when is_binary(route), do: route in @long_polling_endpoints
  def off_endpoint?(_route), do: false

  @doc """
  Pure computation of which OBSERVED endpoint route templates (from
  `endpoint_order`) a config change on `node_key` applies to (AC1/AC2):

    * a satellite key (anything that is not its own domain, and not
      `"nebu"`) cascades only to itself ("Applies to this endpoint only") —
      returned regardless of whether it is actually present in
      `endpoint_order` yet.
    * a domain key (`TraceMapTree.domain_for_endpoint/1` maps it to
      itself) cascades to every endpoint in `endpoint_order` whose domain
      is that key — this correctly includes the domain key itself when it
      is ALSO a satellite (a single-segment route, e.g. `/health`, is
      simultaneously its own domain and a satellite — deduplicated via
      `Enum.uniq/1`, never double-counted).
    * `"nebu"` cascades to every observed endpoint on the map.
  """
  @spec cascade_targets(String.t(), [String.t()]) :: [String.t()]
  def cascade_targets("nebu", endpoint_order), do: Enum.uniq(endpoint_order)

  def cascade_targets(node_key, endpoint_order) do
    if TraceMapTree.domain_for_endpoint(node_key) == node_key do
      endpoint_order
      |> Enum.filter(&(TraceMapTree.domain_for_endpoint(&1) == node_key))
      |> Enum.uniq()
    else
      [node_key]
    end
  end

  # Bounded in-memory buffers (per-LiveView-process).
  @max_stream_lines 250
  @max_inspector_events 5
  @history_seed_cap 200

  @tick_interval_ms 1_000
  @war_room_refresh_interval_ms 2_000
  @announce_debounce_ms 2_000

  # ══════════════════════════════════════════════════════════════════════════
  # Mount / handle_params
  # ══════════════════════════════════════════════════════════════════════════

  @impl Phoenix.LiveView
  def mount(_params, session, socket) do
    Phoenix.PubSub.subscribe(Nebu.PubSub, @topic)
    MediaAttentionBadge.subscribe()
    war_room_status = initial_war_room_status()

    socket =
      socket
      # admin-sidebar-nesting coordination (AC1 / UX gate advisory A2): the
      # Leitstand highlights the "Trace Map" CHILD of the nested Logs section.
      |> assign(:active_nav, "logs-trace-map")
      |> assign(:page_title, "Trace Map")
      |> assign(:endpoint_order, [])
      |> assign(:extra_domains, [])
      |> assign(:node_states, %{})
      |> assign(:node_events, %{})
      |> assign(:stream_entries, [])
      |> assign(:selected, [])
      |> assign(:active_levels, MapSet.new(@ui_levels))
      |> assign(:inspected, nil)
      |> assign(:war_room, war_room_status)
      # enhanced-logging/war-room-dedicated-page (amendment 4): threaded
      # through to Nebu.Admin.Layouts.live/1 for the sidebar recording dot /
      # topbar pill (in addition to this page's OWN in-page banner above).
      |> WarRoomIndicator.assign_status(war_room_status)
      |> assign(:announcement, "")
      |> assign(:last_announce_ms, 0)
      |> assign(:now_ms, System.system_time(:millisecond))
      # enhanced-logging/trace-map-node-controls: DB-backed captures
      # (ANSWERED design question 1 — "state is a row, expiry is a
      # comparison against now()"). @captures is keyed by endpoint route,
      # refreshed here and on every :trace_map_tick (mirrors the war-room
      # banner's own poll pattern).
      |> assign(:captures, load_active_captures())
      |> assign(:current_admin_id, admin_id_from_session(session))
      |> assign(:cascade_flash, "")
      # media-security-admin-control/5b-live-updates-nav-badges.
      |> assign(:media_attention_count, MediaAttentionBadge.initial_count())

    socket =
      Enum.reduce(initial_entries(), socket, fn entry, acc ->
        ingest_entry(acc, entry, announce: false)
      end)

    if connected?(socket) do
      schedule_tick()
      # `WarRoomManager.status/0` is a live DB read — only poll when
      # `Nebu.Repo` is running (mirrors `Nebu.Admin.LogsLive`'s guard).
      if Process.whereis(Nebu.Repo), do: schedule_war_room_refresh()
    end

    {:ok, socket}
  end

  # Mirrors Nebu.Admin.LogsLive's own admin_id_from_session/1 (this module
  # is deliberately a separate LiveView, see moduledoc — the small helper
  # duplication follows the same precedent as initial_war_room_status/0).
  # Prefer matrix_user_id (`@kai:localhost`-shaped, human-readable) over the
  # raw OIDC `sub` claim (protobuf-encoded by Dex, opaque to operators) — this
  # value is the actor recorded in the compliance audit log for capture
  # enable/disable (design-conformance fix, 2026-07-08).
  defp admin_id_from_session(%{"current_user" => %{"matrix_user_id" => uid}})
       when is_binary(uid) and uid != "",
       do: uid

  defp admin_id_from_session(%{"current_user" => %{"sub" => sub}})
       when is_binary(sub) and sub != "",
       do: sub

  defp admin_id_from_session(_session), do: "unknown-admin"

  # AC5: URL query params are the single source of truth for the endpoint
  # selection — seeded here on mount AND after every push_patch round trip.
  # A bookmarked URL may select endpoints/domains no traffic has been
  # observed for yet: those are added to the map (as satellite or
  # domain-only nodes) so the restored view renders its selection rings and
  # chips immediately (bookmarkable-URL contract, AC5/AC12 Scenario 10).
  @impl Phoenix.LiveView
  def handle_params(params, _uri, socket) do
    selected = params |> Map.get("endpoint") |> normalize_selected()

    {endpoint_order, extra_domains} =
      Enum.reduce(selected, {socket.assigns.endpoint_order, socket.assigns.extra_domains}, fn key,
                                                                                              {order,
                                                                                               extras} ->
        cond do
          TraceMapTree.domain_for_endpoint(key) == key ->
            # A key that IS its own domain (e.g. "/admin", "/health") is a
            # domain selection — render it as a domain node, never as a
            # synthetic satellite.
            if key in extras or Enum.any?(order, &(TraceMapTree.domain_for_endpoint(&1) == key)) do
              {order, extras}
            else
              {order, extras ++ [key]}
            end

          key in order ->
            {order, extras}

          true ->
            {order ++ [key], extras}
        end
      end)

    {:noreply,
     socket
     |> assign(:selected, selected)
     |> assign(:endpoint_order, endpoint_order)
     |> assign(:extra_domains, extra_domains)}
  end

  defp normalize_selected(nil), do: []
  defp normalize_selected(value) when is_binary(value), do: [value]

  # code-review m1 (dev cycle 3): Enum.uniq/1 — a crafted/bookmarked URL with
  # the same endpoint[] value repeated would otherwise seed duplicate chips,
  # and toggle_node's List.delete/2 only removes ONE occurrence per click.
  defp normalize_selected(values) when is_list(values) do
    values |> Enum.filter(&is_binary/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq()
  end

  defp normalize_selected(_other), do: []

  # ══════════════════════════════════════════════════════════════════════════
  # handle_event — node filter toggles (AC5) + level pills (AC9)
  # ══════════════════════════════════════════════════════════════════════════

  # An ordinary server round trip (unlike the Live Stream page's
  # client-side-instant bubbles — no zero-lag constraint applies here, per
  # the ATDD contract): toggle the key in the selection, then push_patch so
  # handle_params/3 re-seeds @selected from the URL. The clicked node also
  # becomes the inspected node (AC8; mirrors the dummy's `activate()`).
  @impl Phoenix.LiveView
  # AC5/AC7 (one-click enable, story amendment 2026-07-07): clicking an
  # off-tier, NON-capturing satellite enables temporary capture instead of
  # toggling the stream filter — the second click, once capturing, is an
  # ordinary filter toggle (falls through to the clause below).
  def handle_event("toggle_node", %{"key" => key}, socket)
      when is_binary(key) do
    if off_endpoint?(key) and not Map.has_key?(socket.assigns.captures, key) do
      {:noreply, enable_capture(socket, key)}
    else
      selected = socket.assigns.selected

      new_selected =
        if key in selected, do: List.delete(selected, key), else: selected ++ [key]

      {:noreply,
       socket
       |> assign(:inspected, key)
       |> push_patch(to: patch_path(new_selected))}
    end
  end

  def handle_event("toggle_node", _params, socket), do: {:noreply, socket}

  # ── AC1/AC2: inspector logging controls (Min level + Retention selects) ──
  #
  # phx-change on the logging form (AC10 — LiveView event, CSRF-safe by
  # construction, no inline JS). node_key/min_level/retention_days per the
  # Dev Notes hidden-field variant. Cascades to every endpoint
  # cascade_targets/2 computes for node_key (domain/nebu -> all descendants;
  # satellite -> itself only).
  def handle_event(
        "configure_logging",
        %{"node_key" => node_key, "min_level" => min_level, "retention_days" => retention_days},
        socket
      ) do
    # Kassandra security review (2026-07-08, MEDIUM): min_level/retention_days
    # arrive over the LiveView socket as client-controlled strings — a
    # crafted `pushEvent`/raw socket frame can send ANYTHING here,
    # bypassing the HTML <select>'s own option list entirely. Previously
    # persisted unvalidated (harmless TODAY only because nothing reads
    # these per-route keys back into the actual pruner yet — a landmine
    # for whenever that wiring lands). Validated against this module's own
    # `@ui_levels` allowlist and the SAME 1..90 day bound
    # `Nebu.Admin.LogsController.validate_bound/4` enforces for the
    # sibling log_retention_<level>_days keys (mirrored here, not
    # reinvented — see `validate_retention_days/1`) BEFORE anything is
    # persisted. Invalid input rejects the WHOLE update (no partial
    # writes, matching that controller's own all-or-nothing
    # `validate_and_normalize/1`) and logs a warning; the socket
    # connection itself is not torn down (a malformed one-off event must
    # not crash the LiveView).
    with {:ok, level} <- validate_min_level(min_level),
         {:ok, days} <- validate_retention_days(retention_days) do
      groups = domain_groups(socket.assigns.endpoint_order, socket.assigns.extra_domains)
      observed = groups |> Enum.flat_map(fn {_domain, leaves} -> leaves end) |> Enum.uniq()
      targets = cascade_targets(node_key, observed)

      changes =
        Enum.reduce(targets, %{}, fn target, acc ->
          acc
          |> Map.put("log_min_level_" <> target, level)
          |> Map.put("log_retention_days_" <> target, days)
        end)

      # `Process.whereis/1` returns a pid or nil, not a boolean — `and` (unlike
      # `&&`) requires an actual boolean on its left side and raises
      # BadBooleanError otherwise (crashed this exact handler live, cycle 0
      # debugging). `if` alone already treats nil as falsy, so a single guard
      # is both correct and sufficient.
      if Process.whereis(Nebu.Repo) do
        Nebu.Admin.DB.upsert_server_config(changes)
      end

      socket =
        if length(targets) > 1 do
          assign(socket, :cascade_flash, "Updated #{length(targets)} endpoints")
        else
          socket
        end

      {:noreply, socket}
    else
      {:error, reason} ->
        Logger.warning(
          "Nebu.Admin.LogsLive.TraceMap: rejected invalid configure_logging params " <>
            "(node_key=#{inspect(node_key)}, min_level=#{inspect(min_level)}, " <>
            "retention_days=#{inspect(retention_days)}): #{reason}"
        )

        {:noreply, socket}
    end
  end

  def handle_event("configure_logging", _params, socket), do: {:noreply, socket}

  # AC5: the inspector's "Enable for 5 min" button (the post-early-disable
  # re-enable path, test-review m4) — same enable_capture/1 helper the
  # one-click node activation above uses.
  def handle_event("enable_capture", params, socket) do
    key = Map.get(params, "key", socket.assigns.inspected)

    if is_binary(key) do
      {:noreply, enable_capture(socket, key)}
    else
      {:noreply, socket}
    end
  end

  # AC5/AC7: the inspector's "Disable now" button — ends the capture early
  # without touching the stream filter (Known Challenge 4).
  def handle_event("disable_capture", params, socket) do
    key = Map.get(params, "key", socket.assigns.inspected)

    if is_binary(key) do
      {:noreply, disable_capture(socket, key)}
    else
      {:noreply, socket}
    end
  end

  # Clicking nebu (or the stream header's "Clear all") clears every filter.
  # AC1 (trace-map-node-controls): nebu is ALSO the map-wide cascade
  # target — clicking it inspects it (harmless when triggered by the
  # unrelated "Clear all" button too, since inspecting nebu is always a
  # safe, side-effect-free default view).
  def handle_event("clear_filters", _params, socket) do
    {:noreply, socket |> assign(:inspected, "nebu") |> push_patch(to: patch_path([]))}
  end

  # AC9's leitstand shortcut: all active + click one -> ONLY that one;
  # the sole active one clicked again -> all active; otherwise plain toggle.
  def handle_event("toggle_level", %{"level" => level}, socket) when level in @ui_levels do
    active = socket.assigns.active_levels
    all = MapSet.new(@ui_levels)

    new_active =
      cond do
        MapSet.equal?(active, all) -> MapSet.new([level])
        MapSet.equal?(active, MapSet.new([level])) -> all
        MapSet.member?(active, level) -> MapSet.delete(active, level)
        true -> MapSet.put(active, level)
      end

    {:noreply, assign(socket, :active_levels, new_active)}
  end

  def handle_event("toggle_level", _params, socket), do: {:noreply, socket}

  # ── AC1/AC2 input validation (Kassandra security review, 2026-07-08) ─────

  # AC1: validated against this module's OWN level vocabulary — the exact
  # allowlist the select's own <option> values are drawn from — never a
  # loosely-typed passthrough.
  defp validate_min_level(min_level) when is_binary(min_level) do
    upcased = String.upcase(min_level)

    if upcased in @ui_levels do
      {:ok, String.downcase(upcased)}
    else
      {:error, "min_level #{inspect(min_level)} is not one of #{inspect(@ui_levels)}"}
    end
  end

  defp validate_min_level(other), do: {:error, "min_level must be a string, got #{inspect(other)}"}

  # Mirrors Nebu.Admin.LogsController.validate_bound/4's integer-parsing
  # shape and EXACT bound (@days_bounds {1, 90} there) — reused, not
  # reinvented, so both retention-window surfaces enforce the same policy.
  # Unlike that controller's own field, blank/"0" is NOT treated as "no
  # limit" here: this story's retention select only ever offers 1/7/30
  # (day-granularity, AC2 test-review M1) with no "no limit" concept for
  # per-route retention, so anything outside a plain 1..90 integer is
  # simply invalid.
  @retention_days_bounds {1, 90}

  defp validate_retention_days(retention_days) when is_binary(retention_days) do
    {min, max} = @retention_days_bounds

    case Integer.parse(String.trim(retention_days)) do
      {n, ""} when n >= min and n <= max ->
        {:ok, Integer.to_string(n)}

      _ ->
        {:error, "retention_days #{inspect(retention_days)} is not an integer between #{min} and #{max}"}
    end
  end

  defp validate_retention_days(other),
    do: {:error, "retention_days must be a string, got #{inspect(other)}"}

  # AC5 URL format (story amendment): bracket-array `endpoint[]=...` params,
  # percent-encoded (`endpoint%5B%5D=...`) — `Plug.Conn.Query.decode/1`
  # natively decodes this into `%{"endpoint" => [...]}` with no data loss.
  defp patch_path([]), do: @base_path

  defp patch_path(selected) do
    query = Enum.map_join(selected, "&", fn key -> "endpoint%5B%5D=" <> URI.encode_www_form(key) end)
    @base_path <> "?" <> query
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Temporary capture (AC5/AC6/AC9/AC12) — DB-backed timer, DB-free guard
  # ══════════════════════════════════════════════════════════════════════════

  # DB-free unit-test contract (mirrors initial_war_room_status/0): with no
  # Nebu.Repo running, a capture is impossible — inspect the node (AC1's
  # "clicking a node inspects it" contract still applies) without touching
  # the DB or the filter/selection state (AC5/AC7: enabling is never a
  # filter toggle).
  defp enable_capture(socket, key) do
    if Process.whereis(Nebu.Repo) do
      # TemporaryCaptureManager.enable/2 always returns {:ok, capture} (an
      # upsert on the endpoint's own primary key never conflicts) — no
      # error branch to match.
      {:ok, capture} = TemporaryCaptureManager.enable(key, socket.assigns.current_admin_id)

      socket
      |> assign(:inspected, key)
      |> update(:captures, &Map.put(&1, key, capture))
      |> assign(:announcement, "Temporary capture enabled for #{key} · 5 minutes")
    else
      assign(socket, :inspected, key)
    end
  end

  defp disable_capture(socket, key) do
    if Process.whereis(Nebu.Repo) do
      case TemporaryCaptureManager.disable(key, socket.assigns.current_admin_id) do
        :ok ->
          socket
          |> update(:captures, &Map.delete(&1, key))
          |> assign(:announcement, "Temporary capture disabled for #{key}")

        {:error, :not_found} ->
          socket
      end
    else
      socket
    end
  end

  # AC5/Known Challenge 2: on mount AND on every tick, the captures table is
  # the single source of truth (DB row -> expires_at comparison, never a
  # process timer). DB-free guard mirrors initial_war_room_status/0.
  defp load_active_captures do
    if Process.whereis(Nebu.Repo) do
      TemporaryCaptureManager.active_captures() |> Map.new(&{&1.endpoint, &1})
    else
      %{}
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # handle_info — live PubSub ingest (AC3) + tick (auto-heal) + war-room poll
  # ══════════════════════════════════════════════════════════════════════════

  # Advancing `@now_ms` every second is what makes the AC3 window actually
  # SLIDE for the reader: statuses/counts are pure functions of
  # `(state, now_ms)` (see TraceMapStatus), so a node with no new traffic
  # auto-heals to :ok the moment its last warning/error falls out of the
  # window — no acknowledge, no cleanup pass, just a fresher `now`.
  @impl Phoenix.LiveView
  def handle_info(:trace_map_tick, socket) do
    schedule_tick()

    # AC5/AC6/Known Challenge 2: the captures table is the timer — every
    # tick re-reads it (DB-free guarded) so an expiry is discovered by a
    # fresh `now()` comparison, never by a process-owned countdown. A key
    # that drops out of the fresh read (and was not already removed by an
    # explicit disable_capture/2, which updates @captures itself) has
    # auto-expired — announce it (AC5's "no manual intervention").
    previous_keys = socket.assigns.captures |> Map.keys() |> MapSet.new()
    fresh_captures = load_active_captures()
    expired_keys = MapSet.difference(previous_keys, fresh_captures |> Map.keys() |> MapSet.new())

    socket =
      socket
      |> assign(:captures, fresh_captures)
      |> assign(:now_ms, System.system_time(:millisecond))

    socket =
      case Enum.to_list(expired_keys) do
        [] -> socket
        [key | _rest] -> assign(socket, :announcement, "Temporary capture expired for #{key}")
      end

    {:noreply, socket}
  end

  # AC6: the banner reacts to sessions starting/stopping while the page is
  # open. Always rescheduled (unlike the Live Stream page's
  # only-while-active refresh) because the banner must also APPEAR when a
  # session starts later.
  #
  # UX gate V1: the banner itself is not a live region (it contains a
  # per-second clock) — a session START/STOP transition is announced as a
  # one-shot state-change sentence through the sr-only announcer instead.
  def handle_info(:refresh_war_room_status, socket) do
    if Process.whereis(Nebu.Repo), do: schedule_war_room_refresh()

    previous = socket.assigns.war_room
    current = initial_war_room_status()

    socket =
      case {previous, current} do
        {:none, {:ok, session}} ->
          assign(socket, :announcement, "War Room session started — capturing " <> session.started_by)

        {{:ok, _session}, :none} ->
          assign(socket, :announcement, "War Room session ended")

        _unchanged ->
          socket
      end

    # enhanced-logging/war-room-dedicated-page (amendment 4): keeps the
    # sidebar dot/topbar pill assigns current alongside this page's own
    # in-page banner.
    {:noreply, socket |> assign(:war_room, current) |> WarRoomIndicator.assign_status(current)}
  end

  # `Nebu.Web.LogStore.Handler.safe_broadcast/1` broadcasts a BARE MAP (not a
  # tagged tuple) — same match as `Nebu.Admin.LogsLive.handle_info/2`.
  def handle_info(%{level: _, source: _, request_id: _} = entry, socket) do
    {:noreply, ingest_entry(socket, entry, announce: true)}
  end

  # media-security-admin-control/5b-live-updates-nav-badges.
  def handle_info({:media_state_transition, _media_id, old_state, new_state}, socket) do
    {:noreply, MediaAttentionBadge.apply_transition(socket, old_state, new_state)}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  defp schedule_tick, do: Process.send_after(self(), :trace_map_tick, @tick_interval_ms)

  defp schedule_war_room_refresh do
    Process.send_after(self(), :refresh_war_room_status, @war_room_refresh_interval_ms)
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Ingest
  # ══════════════════════════════════════════════════════════════════════════

  defp ingest_entry(socket, entry, opts) do
    level = normalize_level(entry[:level])
    route = normalize_route(entry[:route_template])
    {ts_ms, ts_text} = entry_timestamp(entry)

    if should_ingest?(socket, route, level) do
      # code-review M1 (dev cycle 3): DEDUPLICATED — a single-segment route is
      # its own domain (`TraceMapTree.domain_for_endpoint("/health") ==
      # "/health"`), so without Enum.uniq/1 every /health event recorded TWICE
      # into that node's state (badge counts, tooltip, inspector stats and
      # aria-labels all showed 2x reality).
      node_keys =
        case route do
          nil -> ["nebu"]
          route -> Enum.uniq([route, TraceMapTree.domain_for_endpoint(route), "nebu"])
        end

      socket
      |> track_endpoint(route)
      |> record_event(node_keys, level, ts_ms)
      |> push_node_event(node_keys, level, ts_text, entry[:message])
      |> push_stream_line(route, level, ts_text, entry[:message])
      |> maybe_announce(route, level, ts_ms, ts_text, opts)
      |> assign(:now_ms, max(ts_ms, socket.assigns.now_ms))
    else
      socket
    end
  end

  # AC4 (+ the errors-always-persist amendment, 2026-07-07): an off-list
  # route with NO active capture is not part of the leitstand's signal at
  # all for DEBUG/INFO/WARN — no counts, no stream line, no nebu
  # aggregation. ERROR always ingests (off silences noise, never failures).
  # A nil route (no route_template) or a non-off route always ingests
  # normally.
  defp should_ingest?(_socket, _route, "error"), do: true

  defp should_ingest?(socket, route, _level) do
    not off_endpoint?(route) or Map.has_key?(socket.assigns.captures, route)
  end

  defp track_endpoint(socket, nil), do: socket

  defp track_endpoint(socket, route) do
    update(socket, :endpoint_order, fn order ->
      if route in order, do: order, else: order ++ [route]
    end)
  end

  # Every entry counts as a :request in its node's window; warnings/errors
  # are ADDITIONALLY recorded so the badge/tooltip counts match the dummy's
  # semantics (total = all events, warn/err = level subsets).
  defp record_event(socket, node_keys, level, ts_ms) do
    kinds =
      case level do
        "error" -> [:request, :error]
        "warning" -> [:request, :warning]
        _ -> [:request]
      end

    update(socket, :node_states, fn states ->
      Enum.reduce(node_keys, states, fn key, acc ->
        state = Map.get(acc, key, TraceMapStatus.new())
        state = Enum.reduce(kinds, state, &TraceMapStatus.record(&2, &1, ts_ms))
        Map.put(acc, key, state)
      end)
    end)
  end

  defp push_node_event(socket, node_keys, level, ts_text, message) do
    event = %{ts: ts_text, level: ui_level(level), message: truncate(message)}

    update(socket, :node_events, fn events ->
      Enum.reduce(node_keys, events, fn key, acc ->
        Map.update(acc, key, [event], &Enum.take([event | &1], @max_inspector_events))
      end)
    end)
  end

  defp push_stream_line(socket, route, level, ts_text, message) do
    line = %{
      ts: ts_text,
      ui_level: ui_level(level),
      route: route,
      domain: route && TraceMapTree.domain_for_endpoint(route),
      message: truncate(message)
    }

    update(socket, :stream_entries, fn lines ->
      (lines ++ [line]) |> Enum.take(-@max_stream_lines)
    end)
  end

  # AC10: aria-live announcements for new errors — throttled (2s debounce),
  # endpoint name + windowed count, no message content (spec §8's
  # no-sensitive-data rule). UX gate A2: the count and the timestamp are part
  # of the sentence so (a) the announcement matches AC10's own example
  # ("3 new errors detected in sync endpoint") and (b) a REPEATED error burst
  # on the same endpoint after the debounce still produces a DOM change —
  # identical text would never re-fire a polite live region.
  defp maybe_announce(socket, route, "error", ts_ms, ts_text, opts) do
    if Keyword.get(opts, :announce, true) and is_binary(route) and
         ts_ms - socket.assigns.last_announce_ms >= @announce_debounce_ms do
      errors = TraceMapStatus.counts(node_state(socket.assigns.node_states, route), ts_ms).errors

      socket
      |> assign(
        :announcement,
        "#{pluralize(errors, "new error")} detected in #{route} at #{ts_text}"
      )
      |> assign(:last_announce_ms, ts_ms)
    else
      socket
    end
  end

  defp maybe_announce(socket, _route, _level, _ts_ms, _ts_text, _opts), do: socket

  # ══════════════════════════════════════════════════════════════════════════
  # Data-source guards (DB-free unit-test contract, see moduledoc)
  # ══════════════════════════════════════════════════════════════════════════

  defp initial_war_room_status do
    if Process.whereis(Nebu.Repo) do
      Nebu.Admin.WarRoomManager.status()
    else
      :none
    end
  end

  defp initial_entries do
    if Process.whereis(Nebu.Repo) do
      {:ok, rows} = Nebu.Web.LogStore.get_logs(%{})

      # most-recent-first from get_logs/1; reverse to oldest-first so the
      # stream panel reads chronologically and inspector events stack
      # newest-first correctly.
      rows |> Enum.take(@history_seed_cap) |> Enum.reverse()
    else
      []
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Normalization helpers
  # ══════════════════════════════════════════════════════════════════════════

  defp normalize_level(level) when is_binary(level), do: level
  defp normalize_level(level) when is_atom(level) and not is_nil(level), do: Atom.to_string(level)
  defp normalize_level(_), do: "info"

  defp normalize_route(nil), do: nil
  defp normalize_route(""), do: nil
  defp normalize_route(route) when is_binary(route), do: route
  defp normalize_route(route), do: to_string(route)

  defp ui_level("debug"), do: "DEBUG"
  defp ui_level("warning"), do: "WARN"
  defp ui_level("error"), do: "ERROR"
  defp ui_level(_), do: "INFO"

  defp truncate(nil), do: ""

  defp truncate(message) when is_binary(message) do
    if String.length(message) > 120, do: String.slice(message, 0, 120) <> "…", else: message
  end

  defp truncate(message), do: truncate(to_string(message))

  # Live broadcasts carry no timestamp -> "now"; mount-time LogStore history
  # rows carry `inserted_at` (DateTime/NaiveDateTime) -> converted so the
  # 60-second window judges seeded rows by their REAL age, not by mount time.
  defp entry_timestamp(entry) do
    case entry[:inserted_at] do
      %DateTime{} = dt ->
        {DateTime.to_unix(dt, :millisecond), Calendar.strftime(dt, "%H:%M:%S")}

      %NaiveDateTime{} = naive ->
        dt = DateTime.from_naive!(naive, "Etc/UTC")
        {DateTime.to_unix(dt, :millisecond), Calendar.strftime(dt, "%H:%M:%S")}

      _ ->
        now = DateTime.utc_now()
        {DateTime.to_unix(now, :millisecond), Calendar.strftime(now, "%H:%M:%S")}
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Render
  # ══════════════════════════════════════════════════════════════════════════

  @impl Phoenix.LiveView
  def render(assigns) do
    groups = domain_groups(assigns.endpoint_order, assigns.extra_domains)

    layout =
      TraceMapGeometry.layout(
        Enum.map(groups, fn {domain, leaves} -> %{key: domain, satellites: leaves} end)
      )

    assigns =
      assigns
      |> assign(:nodes, build_nodes(groups, layout, assigns))
      |> assign(:edges, build_edges(groups, layout))
      |> assign(:visible_lines, visible_lines(assigns))
      |> assign(:inspected_node, inspected_node(assigns))
      |> assign(:ui_levels, @ui_levels)

    ~H"""
    <div
      id="trace-map-leitstand"
      phx-hook="TraceMapLeitstand"
      class="flex flex-col gap-3"
      style="height: calc(100vh - 6.5rem);"
    >
      <div class="flex items-center justify-between shrink-0">
        <h1 class="text-heading font-semibold">Trace Map</h1>
      </div>

      <%!-- AC1/AC11 Scenario B: cascade success message ("Updated N endpoints").
            A dedicated assign (not Phoenix's built-in @flash — this LiveView's
            shared admin layout does not render @flash today) so both the
            LiveView test's `render(view) =~ regex` and the E2E getByText probe
            can find it. --%>
      <p
        :if={@cascade_flash != ""}
        data-testid="trace-map-cascade-flash"
        class="alert alert-success mb-2 shrink-0"
        role="status"
      >
        {@cascade_flash}
      </p>

      <%!-- AC6: war-room banner — always present in markup, toggled via the
            boolean `hidden` attribute. Deliberately NOT a live region (UX gate
            V1): it contains the per-second-ticking elapsed clock, and
            role="status" (implicitly aria-atomic) would make screen readers
            re-announce the whole banner every second. Session start/stop is
            announced as a one-shot sentence through the sr-only announcer at
            the bottom of the page instead (see handle_info
            :refresh_war_room_status). --%>
      <%!-- No `flex` utility here, deliberately: an author-stylesheet
            `.flex { display: flex }` beats the UA's `[hidden] { display: none }`
            in the cascade, so the "hidden" banner would still render (the exact
            trace-map-hierarchy/admin-sidebar-nesting flex-beats-hidden bug —
            reconfirmed live in dev cycle 1). `.tm-wr-banner` owns display:flex
            AND a `[hidden]` override in app.css. --%>
      <div
        data-testid="trace-map-war-room-banner"
        hidden={not war_room_active?(@war_room)}
        class="tm-wr-banner items-center gap-3 rounded-lg border border-error bg-status-error-bg px-4 py-2 text-sm shrink-0"
      >
        <span data-testid="trace-map-war-room-dot" class="tm-recdot" aria-hidden="true"></span>
        <span :if={war_room_active?(@war_room)}>
          War Room session active — capturing
          <b class="font-mono font-medium">{war_room_session(@war_room).started_by}</b>
          · <span
            data-testid="trace-map-war-room-elapsed"
            id="trace-map-war-room-elapsed"
            data-started-at={war_room_started_at_unix(@war_room)}
          >{war_room_elapsed(@war_room)}</span>
          <span :if={war_room_session(@war_room).reason} class="text-text-secondary">
            · {war_room_session(@war_room).reason}
          </span>
        </span>
        <.link
          navigate="/admin/logs/war-room"
          data-testid="trace-map-war-room-open-link"
          class="btn btn-outline btn-xs ml-auto border-error text-status-error-text hover:bg-error hover:text-error-content hover:border-error"
        >
          Open War Room
        </.link>
      </div>

      <div class="flex gap-4 flex-1 min-h-0">
        <div class="flex-1 flex flex-col min-w-0" id="trace-map-left">
          <div class="relative flex-1 min-h-0 rounded-lg bg-base-400 border border-base-300" id="trace-map-map-wrap">
            <svg
              data-testid="trace-map-svg"
              viewBox="-780 -650 1560 1300"
              preserveAspectRatio="xMidYMid meet"
              role="group"
              tabindex="0"
              aria-label="Service health map. Keyboard accessible — use arrow keys to pan and +/- (or PageUp/PageDown) to zoom."
              class="w-full h-full block"
            >
              <g>
                <line
                  :for={edge <- @edges}
                  class="tm-edge"
                  x1={edge.x1}
                  y1={edge.y1}
                  x2={edge.x2}
                  y2={edge.y2}
                />
              </g>
              <g id="trace-map-pings"></g>
              <g>
                <.map_node :for={node <- @nodes} node={node} />
              </g>
            </svg>
            <%!-- UX gate A5: aria-hidden — the tooltip only duplicates the
                  hovered/focused node's own aria-label content for sighted
                  users; virtual-cursor users would otherwise meet it twice. --%>
            <div
              data-testid="trace-map-tooltip"
              id="trace-map-tooltip"
              class="tm-tooltip"
              aria-hidden="true"
              hidden
            >
            </div>
            <%!-- enhanced-logging/trace-map-zoom-pan (AC1/AC3/AC4/AC5/AC7/AC9):
                  map-app-style zoom/pan controls. 100% client-side — wired
                  through the TraceMapLeitstand hook's own addEventListener,
                  never phx-click/onclick (CSP `script-src 'self'`, no inline
                  JS; AC9 zoom/pan is never a LiveView round trip / never
                  persisted). --%>
            <div
              data-testid="trace-map-zoom-controls"
              id="trace-map-zoom-controls"
              role="group"
              aria-label="Zoom controls"
              class="tm-zoom-controls absolute bottom-3 right-3 z-10 flex items-center gap-1 rounded-lg border border-base-300 bg-base-100/90 p-1 shadow"
            >
              <button
                type="button"
                data-testid="trace-map-zoom-in"
                aria-label="Zoom in"
                class="btn btn-sm btn-square btn-ghost focus-visible:outline focus-visible:outline-2 focus-visible:outline-primary focus-visible:outline-offset-2"
              >
                +
              </button>
              <button
                type="button"
                data-testid="trace-map-zoom-out"
                aria-label="Zoom out"
                class="btn btn-sm btn-square btn-ghost focus-visible:outline focus-visible:outline-2 focus-visible:outline-primary focus-visible:outline-offset-2"
              >
                −
              </button>
              <button
                type="button"
                data-testid="trace-map-zoom-reset"
                aria-label="Reset view"
                class="btn btn-sm btn-ghost focus-visible:outline focus-visible:outline-2 focus-visible:outline-primary focus-visible:outline-offset-2"
              >
                Reset view
              </button>
            </div>
            <%!-- enhanced-logging/trace-map-zoom-pan UX gate finding 2:
                  drag-to-pan is pointer-only, and the SVG's own keydown
                  arrow-key handler is not a reliable screen-reader path
                  (role="group" + tabindex="0" does not dependably put
                  NVDA/JAWS into "focus mode"). These four discoverable
                  buttons give a dependable AT-accessible pan path — same
                  pattern as the zoom controls (plain <button>, no
                  phx-click/onclick, wired via the hook's own
                  addEventListener, reusing the exact 32px keyboard-pan
                  step). --%>
            <div
              data-testid="trace-map-pan-controls"
              id="trace-map-pan-controls"
              role="group"
              aria-label="Pan controls"
              class="tm-pan-controls absolute bottom-3 left-3 z-10 flex flex-col items-center gap-1 rounded-lg border border-base-300 bg-base-100/90 p-1 shadow"
            >
              <button
                type="button"
                data-testid="trace-map-pan-up"
                aria-label="Pan up"
                class="btn btn-sm btn-square btn-ghost focus-visible:outline focus-visible:outline-2 focus-visible:outline-primary focus-visible:outline-offset-2"
              >
                ↑
              </button>
              <div class="flex items-center gap-1">
                <button
                  type="button"
                  data-testid="trace-map-pan-left"
                  aria-label="Pan left"
                  class="btn btn-sm btn-square btn-ghost focus-visible:outline focus-visible:outline-2 focus-visible:outline-primary focus-visible:outline-offset-2"
                >
                  ←
                </button>
                <button
                  type="button"
                  data-testid="trace-map-pan-down"
                  aria-label="Pan down"
                  class="btn btn-sm btn-square btn-ghost focus-visible:outline focus-visible:outline-2 focus-visible:outline-primary focus-visible:outline-offset-2"
                >
                  ↓
                </button>
                <button
                  type="button"
                  data-testid="trace-map-pan-right"
                  aria-label="Pan right"
                  class="btn btn-sm btn-square btn-ghost focus-visible:outline focus-visible:outline-2 focus-visible:outline-primary focus-visible:outline-offset-2"
                >
                  →
                </button>
              </div>
            </div>
          </div>

          <%!-- AC9: resizable drag handle — pointer drag + ArrowUp/Down ±32px,
                Home/End max/min, dblclick resets to 218px (TraceMapLeitstand hook). --%>
          <%!-- UX gate V4: a focusable role="separator" requires
                aria-valuenow (ARIA window-splitter pattern). The server
                renders an approximate initial value (218px default stream on
                a typical column); the TraceMapLeitstand hook recomputes the
                exact percentage on mount and on every resize. --%>
          <div
            data-testid="trace-map-resizer"
            id="trace-map-resizer"
            role="separator"
            aria-orientation="horizontal"
            tabindex="0"
            aria-valuemin="0"
            aria-valuemax="100"
            aria-valuenow="30"
            aria-label="Resize log stream (drag, or arrow up/down; double-click resets)"
            class="tm-resizer shrink-0"
          >
          </div>

          <section
            data-testid="trace-map-stream"
            id="trace-map-stream"
            aria-label="Live log stream"
            class="tm-stream flex flex-col shrink-0 border border-base-300 rounded-b-lg bg-base-100"
          >
            <div class="flex items-center gap-2 flex-wrap px-3 py-2 border-b border-base-300 shrink-0">
              <span class="text-caption uppercase text-text-secondary">Live stream</span>
              <span role="group" aria-label="Level filter" class="inline-flex gap-1">
                <button
                  :for={level <- @ui_levels}
                  type="button"
                  data-testid="trace-map-level-pill"
                  data-level={level}
                  aria-pressed={to_string(MapSet.member?(@active_levels, level))}
                  phx-click="toggle_level"
                  phx-value-level={level}
                  class={[
                    "font-mono text-xs font-bold px-2 py-0.5 rounded-full border",
                    "focus-visible:outline focus-visible:outline-2 focus-visible:outline-primary focus-visible:outline-offset-2",
                    level_pill_class(level, MapSet.member?(@active_levels, level))
                  ]}
                >
                  {level}
                </button>
              </span>
              <span
                :for={key <- @selected}
                data-testid="trace-map-filter-chip"
                data-chip-value={key}
                class="inline-flex items-center gap-1 font-mono text-xs border border-primary rounded-full px-2 py-0.5 bg-base-200"
              >
                {key}
                <button
                  type="button"
                  data-testid="trace-map-filter-chip-remove"
                  phx-click="toggle_node"
                  phx-value-key={key}
                  aria-label={"Remove filter " <> key}
                  class="text-primary font-bold px-0.5 rounded focus-visible:outline focus-visible:outline-2 focus-visible:outline-primary focus-visible:outline-offset-2"
                >
                  ×
                </button>
              </span>
              <button
                :if={@selected != []}
                type="button"
                data-testid="trace-map-clear-all"
                phx-click="clear_filters"
                class="inline-flex items-center font-mono text-xs border border-base-300 text-text-secondary rounded-full px-2 py-0.5 hover:bg-base-300 focus-visible:outline focus-visible:outline-2 focus-visible:outline-primary focus-visible:outline-offset-2"
              >
                Clear all
              </button>
            </div>
            <%!-- UX gate A5: the tabbable scroll container gets an accessible
                  name. Deliberately NOT role="log" — that role carries an
                  implicit polite live region, which would announce every
                  incoming line on a high-volume stream. --%>
            <div
              id="trace-map-stream-body"
              aria-label="Log stream lines"
              class="flex-1 overflow-y-auto px-3 py-1 font-mono text-xs"
              tabindex="0"
            >
              <div
                :for={line <- @visible_lines}
                data-testid="trace-map-stream-line"
                data-level={line.ui_level}
                data-route={line.route || ""}
                class="flex gap-2 whitespace-nowrap py-px"
              >
                <span class="text-text-secondary">{line.ts}</span>
                <span class={["w-12 shrink-0 font-bold", level_text_class(line.ui_level)]}>{line.ui_level}</span>
                <span class="text-base-content">{line.route}</span>
                <span class="text-text-secondary">{line.message}</span>
              </div>
            </div>
          </section>
        </div>

        <%!-- AC8: sticky right column — inspector card + always-visible legend. --%>
        <aside class="w-80 shrink-0 flex flex-col gap-3 overflow-y-auto">
          <div data-testid="trace-map-inspector" class="rounded-lg border border-base-300 bg-base-200 p-4">
            <h2 class="text-caption uppercase text-text-secondary font-semibold mb-2">Node inspector</h2>
            <p :if={is_nil(@inspected_node)} data-testid="trace-map-inspector-empty" class="text-sm text-text-secondary">
              Hover or select a node to see its live health details.
            </p>
            <div :if={@inspected_node}>
              <div data-testid="trace-map-inspector-name" class="font-semibold text-base">
                {@inspected_node.label}
              </div>
              <div data-testid="trace-map-inspector-route" class="font-mono text-xs text-text-secondary break-all mb-2">
                {@inspected_node.route}
              </div>
              <span
                data-testid="trace-map-inspector-status-pill"
                data-status={@inspected_node.status}
                class={[
                  "inline-flex items-center gap-1 rounded-full text-xs font-semibold px-2.5 py-0.5 mb-3",
                  status_pill_class(@inspected_node.status)
                ]}
              >
                {status_pill_text(@inspected_node.status)}
              </span>
              <div class="flex justify-between text-sm text-text-secondary py-0.5">
                <span>Requests / 60 s</span>
                <b data-testid="trace-map-inspector-stat-requests" class="font-mono font-medium text-base-content">
                  {@inspected_node.counts.requests}
                </b>
              </div>
              <div class="flex justify-between text-sm text-text-secondary py-0.5">
                <span>Warnings / 60 s</span>
                <b data-testid="trace-map-inspector-stat-warnings" class="font-mono font-medium text-base-content">
                  {@inspected_node.counts.warnings}
                </b>
              </div>
              <div class="flex justify-between text-sm text-text-secondary py-0.5">
                <span>Errors / 60 s</span>
                <b data-testid="trace-map-inspector-stat-errors" class="font-mono font-medium text-base-content">
                  {@inspected_node.counts.errors}
                </b>
              </div>
              <h3 class="text-caption uppercase text-text-secondary font-semibold mt-3 mb-1">Recent events</h3>
              <p :if={@inspected_node.events == []} class="font-mono text-xs text-text-secondary">—</p>
              <div
                :for={event <- @inspected_node.events}
                data-testid="trace-map-inspector-event"
                class="font-mono text-xs text-text-secondary py-px"
              >
                {event.ts} · {event.level} · {event.message}
              </div>

              <%!-- AC1/AC2/AC3: the "Logging" control panel — BUILT ONCE per
                    inspected node (spec §4/AC3): the select's id/selected
                    value are pure functions of (@inspected key, stored
                    server_config) — never of @now_ms/counts — so a stat-tick
                    re-render produces byte-identical markup for these
                    elements (pinned by the AC3 select-survives-stat-patch
                    test; real focus preservation is E2E Scenario A). --%>
              <div
                data-testid="trace-map-inspector-logging"
                class="mt-3 border-t border-base-300 pt-3"
              >
                <h3 class="text-caption uppercase text-text-secondary font-semibold mb-2">Logging</h3>
                <form
                  id={"tm-insp-logging-form-" <> node_dom_key(@inspected_node.key)}
                  data-testid="trace-map-inspector-logging-form"
                  phx-change="configure_logging"
                  class="flex flex-col gap-2"
                >
                  <input type="hidden" name="node_key" value={@inspected_node.key} />
                  <div class="flex items-center justify-between gap-2">
                    <label
                      for={"tm-insp-level-" <> node_dom_key(@inspected_node.key)}
                      class="text-sm text-text-secondary"
                    >
                      Min level
                    </label>
                    <select
                      id={"tm-insp-level-" <> node_dom_key(@inspected_node.key)}
                      name="min_level"
                      data-testid="trace-map-inspector-level-select"
                      class="select select-bordered select-sm"
                    >
                      <option
                        :for={level <- @ui_levels}
                        value={level}
                        selected={level == @inspected_node.min_level}
                      >
                        {level}
                      </option>
                    </select>
                  </div>
                  <div class="flex items-center justify-between gap-2">
                    <label
                      for={"tm-insp-retention-" <> node_dom_key(@inspected_node.key)}
                      class="text-sm text-text-secondary"
                    >
                      Retention
                    </label>
                    <select
                      id={"tm-insp-retention-" <> node_dom_key(@inspected_node.key)}
                      name="retention_days"
                      data-testid="trace-map-inspector-retention-select"
                      class="select select-bordered select-sm"
                    >
                      <option
                        :for={{value, text} <- retention_options()}
                        value={value}
                        selected={value == @inspected_node.retention_days}
                      >
                        {text}
                      </option>
                    </select>
                  </div>
                </form>
                <p
                  data-testid="trace-map-inspector-scope-note"
                  class="text-xs text-text-secondary mt-1"
                >
                  {@inspected_node.scope_note}
                </p>

                <%!-- AC5/AC6/AC9: capture controls — only for off-by-default
                      long-polling endpoints (any inspected key satisfying
                      off_endpoint?/1, regardless of its domain/satellite
                      display kind — /health is simultaneously both). --%>
                <div
                  :if={@inspected_node.off_tier}
                  data-testid="trace-map-inspector-capture"
                  class="mt-2 border-t border-base-300 pt-2"
                >
                  <div
                    data-testid="trace-map-inspector-capture-state"
                    class="text-sm text-text-secondary flex items-center gap-2"
                  >
                    <%= if @inspected_node.capture do %>
                      Capture active ·
                      <span
                        data-testid="trace-map-inspector-capture-countdown"
                        data-expires-at={capture_expires_at_unix(@inspected_node.capture)}
                      >{capture_countdown_text(@inspected_node.capture, @now_ms)}</span>
                    <% else %>
                      Logging off (long-polling)
                    <% end %>
                  </div>
                  <%!-- AC9: the accessible name STARTS WITH the visible
                        button text ("Disable now" / "Enable for 5 min") and
                        then names the endpoint — WCAG 2.5.3 Label-in-Name
                        compliant (an aria-label that silently REPLACES the
                        visible text with unrelated wording breaks voice
                        control AND `getByRole(name:)`'s substring match on
                        the visible label; this format satisfies both). --%>
                  <button
                    type="button"
                    data-testid="trace-map-inspector-capture-toggle"
                    phx-click={if @inspected_node.capture, do: "disable_capture", else: "enable_capture"}
                    phx-value-key={@inspected_node.key}
                    aria-label={
                      if @inspected_node.capture,
                        do: "Disable now — capture for " <> @inspected_node.route,
                        else: "Enable for 5 min — capture for " <> @inspected_node.route
                    }
                    class="btn btn-sm btn-outline mt-1 focus-visible:outline focus-visible:outline-2 focus-visible:outline-primary focus-visible:outline-offset-2"
                  >
                    {if @inspected_node.capture, do: "Disable now", else: "Enable for 5 min"}
                  </button>
                  <p class="text-xs text-text-secondary mt-1">
                    Long-polling endpoints stay off by default and fall back automatically.
                  </p>
                </div>
              </div>
            </div>
          </div>

          <div data-testid="trace-map-legend" class="rounded-lg border border-base-300 bg-base-200 p-4">
            <h2 class="text-caption uppercase text-text-secondary font-semibold mb-2">Legend</h2>
            <div
              :for={{state, dot_class, text} <- legend_rows()}
              data-testid="trace-map-legend-row"
              data-legend-state={state}
              class="flex items-center gap-2.5 py-1 text-sm text-text-secondary"
            >
              <span class={["tm-legend-dot", dot_class]} aria-hidden="true"></span>
              <span>{text}</span>
            </div>
            <p class="text-xs text-text-secondary mt-2">
              Domains inherit the worst status of their satellites; nebu inherits the worst domain.
              Nodes heal automatically once the 60 s window passes.
            </p>
          </div>
        </aside>
      </div>

      <%!-- AC10: throttled aria-live announcer for new errors (endpoint name
            + no message content — spec §8). --%>
      <div data-testid="trace-map-announcer" role="status" aria-live="polite" class="sr-only">
        {@announcement}
      </div>
    </div>
    """
  end

  # ── One SVG map node (nebu / domain / satellite) ──────────────────────────
  #
  # Focusable `role="button"` per AC10; Enter/Space activation is wired by
  # the TraceMapLeitstand hook (SVG <g> has no native keyboard activation).
  # `aria-pressed` reflects selection; nebu is never a toggle target (always
  # "false" — clicking it CLEARS filters instead).
  attr(:node, :map, required: true)

  defp map_node(assigns) do
    ~H"""
    <g
      id={@node.dom_id}
      data-testid="trace-map-node"
      data-node-key={@node.key}
      data-node-kind={@node.kind}
      data-node-status={@node.status}
      data-node-off={to_string(@node.off_tier)}
      data-node-selected={to_string(@node.selected)}
      role="button"
      tabindex="0"
      aria-pressed={@node.kind != "nebu" && to_string(@node.pressed)}
      aria-label={@node.aria_label}
      data-tooltip-name={@node.label}
      data-tooltip-route={@node.route}
      data-tooltip-status={@node.tooltip_status}
      data-tooltip-counts={@node.tooltip_counts}
      data-tooltip-cta={@node.tooltip_cta}
      transform={"translate(#{@node.x} #{@node.y})"}
      phx-click={@node.click_event}
      phx-value-key={@node.kind != "nebu" && @node.key}
      class={"tm-node tm-node--" <> @node.status}
    >
      <circle class="tm-selring" r={@node.r + 7} />
      <circle data-testid="trace-map-node-core" class="tm-node-core" r={@node.r} />
      <%= case @node.kind do %>
        <% "nebu" -> %>
          <text class="tm-nname" y="-2">nebu</text>
          <text class="tm-ncount" y="16">{@node.counts.requests}/min</text>
        <% "domain" -> %>
          <text class="tm-nname" y="-1">{@node.label}</text>
          <text class="tm-ncount" y="14">{@node.counts.requests}</text>
        <% _satellite -> %>
          <%!-- AC4/AC6/AC8: an off-tier (quiescent-or-erroring) satellite
                shows "off" text, never a number (spec: "count shows 'off'
                text"); a capturing (temp) satellite shows the countdown
                instead of the plain count (AC6 — mm:ss, data-expires-at for
                the TraceMapLeitstand hook's client tick, no server tick
                needed); everything else shows the plain numeric count. --%>
          <%= cond do %>
            <% @node.off_tier and is_nil(@node.capture) -> %>
              <text class="tm-ncount" y="4">off</text>
            <% @node.status == "temp" -> %>
              <text
                data-testid="trace-map-node-countdown"
                data-expires-at={@node.countdown_expires_at}
                class="tm-ncount tm-countdown"
                y="4"
              >{@node.countdown_text}</text>
            <% true -> %>
              <text class="tm-ncount" y="4">{@node.counts.requests}</text>
          <% end %>
          <text class="tm-nlabel" y={@node.r + 15}>{@node.label}</text>
      <% end %>
      <g
        :if={@node.status == "warn"}
        data-testid="trace-map-badge-warn"
        class="tm-badge tm-badge--warn"
        transform={badge_transform(@node.r)}
      >
        <circle r="9" />
        <text y="3.5">▲{badge_count(@node.counts.warnings)}</text>
      </g>
      <g
        :if={@node.status == "error"}
        data-testid="trace-map-badge-error"
        class="tm-badge tm-badge--error"
        transform={badge_transform(@node.r)}
      >
        <circle r="9" />
        <text y="3.5">✕{badge_count(@node.counts.errors)}</text>
      </g>
    </g>
    """
  end

  # ══════════════════════════════════════════════════════════════════════════
  # View-model builders
  # ══════════════════════════════════════════════════════════════════════════

  # Groups observed endpoints by domain (REUSING TraceMapTree's canonical
  # heuristic), merges in the always-present off-list endpoints (AC4), then
  # appends URL-selected domains no traffic has produced a satellite for yet.
  defp domain_groups(endpoint_order, extra_domains) do
    groups =
      endpoint_order
      |> TraceMapTree.group_endpoints_by_domain()
      |> merge_off_endpoints(@long_polling_endpoints)

    known = Enum.map(groups, fn {domain, _leaves} -> domain end)

    groups ++ (extra_domains |> Enum.reject(&(&1 in known)) |> Enum.map(&{&1, []}))
  end

  # enhanced-logging/trace-map-node-controls (AC4): the off-list endpoints
  # are ALWAYS on the map, appended to their domain's existing leaves (or as
  # a brand-new domain group, for a domain with no other observed traffic
  # yet) — deliberately AFTER any REAL-traffic groups/leaves, and never
  # duplicating a leaf already present (a broadcast for the off-list route
  # itself, e.g. the geometry test's own `/health` traffic). This ordering
  # preserves the pre-existing, shipped trace-map-leitstand geometry
  # contract: `TraceMapGeometry.domain_angles/1`'s fixed spec angles apply
  # only on an EXACT domain-key-list match against the canonical 4 — as
  # long as real traffic already produces that exact order, appending
  # off-list leaves/domains AFTER it (via List.update_at/2, never
  # reordering) never disturbs that match.
  defp merge_off_endpoints(groups, off_endpoints) do
    Enum.reduce(off_endpoints, groups, fn off_route, acc ->
      domain = TraceMapTree.domain_for_endpoint(off_route)

      case Enum.find_index(acc, fn {d, _leaves} -> d == domain end) do
        nil ->
          acc ++ [{domain, [off_route]}]

        idx ->
          List.update_at(acc, idx, fn {d, leaves} ->
            if off_route in leaves, do: {d, leaves}, else: {d, leaves ++ [off_route]}
          end)
      end
    end)
  end

  # DOM order (AC10 natural Tab order): nebu first, then each domain followed
  # by its own satellites.
  defp build_nodes(groups, layout, assigns) do
    now = assigns.now_ms
    states = assigns.node_states
    selected = assigns.selected
    captures = assigns.captures

    satellite_statuses =
      Map.new(layout.satellites, fn {key, _pos} ->
        {key, TraceMapStatus.status(node_state(states, key), now)}
      end)

    # AC4/AC5/AC6/AC8: the DISPLAYED status per satellite — "temp" while
    # capturing, "off"/"error" for a quiescent/erroring off-tier satellite
    # (errors-always-persist amendment), else the plain raw status. This is
    # an OVERLAY on top of satellite_statuses: propagation math (below)
    # keeps using the RAW ok/warn/error rank, only the rendered attribute
    # and badge/count/aria-label logic ever see the display string.
    satellite_display =
      Map.new(layout.satellites, fn {key, _pos} ->
        {key, display_status(key, Map.fetch!(satellite_statuses, key), captures)}
      end)

    domain_statuses =
      Map.new(groups, fn {domain, leaves} ->
        child_statuses = Enum.map(leaves, &Map.fetch!(satellite_statuses, &1))
        own = TraceMapStatus.status(node_state(states, domain), now)
        {domain, TraceMapStatus.worst([own | child_statuses])}
      end)

    # Known Challenge 1: a domain whose satellites are ALL currently
    # displayed "off" is itself "off" (gray/dashed, no status) — derived
    # from the CHILDREN'S DISPLAY strings (not the off-list membership of
    # the domain key itself), so a domain with a capturing or erroring
    # off-tier child correctly falls through to the normal worst-child
    # rendering instead.
    domain_display =
      Map.new(groups, fn {domain, leaves} ->
        child_display = Enum.map(leaves, &Map.fetch!(satellite_display, &1))

        display =
          if leaves != [] and Enum.all?(child_display, &(&1 == "off")) do
            "off"
          else
            Atom.to_string(Map.fetch!(domain_statuses, domain))
          end

        {domain, display}
      end)

    nebu_status =
      TraceMapStatus.worst([
        TraceMapStatus.status(node_state(states, "nebu"), now)
        | Map.values(domain_statuses)
      ])

    nebu_node =
      build_node(
        "nebu",
        "nebu",
        layout.nebu,
        nebu_status,
        Atom.to_string(nebu_status),
        "nebu",
        "all traffic",
        selected,
        states,
        now,
        captures
      )

    domain_and_satellite_nodes =
      Enum.flat_map(groups, fn {domain, leaves} ->
        domain_node =
          build_node(
            domain,
            "domain",
            Map.fetch!(layout.domains, domain),
            Map.fetch!(domain_statuses, domain),
            Map.fetch!(domain_display, domain),
            domain_label(domain),
            domain,
            selected,
            states,
            now,
            captures
          )

        satellite_nodes =
          Enum.map(leaves, fn route ->
            build_node(
              route,
              "satellite",
              Map.fetch!(layout.satellites, route),
              Map.fetch!(satellite_statuses, route),
              Map.fetch!(satellite_display, route),
              satellite_label(route),
              route,
              selected,
              states,
              now,
              captures
            )
          end)

        [domain_node | satellite_nodes]
      end)

    [nebu_node | domain_and_satellite_nodes]
  end

  # AC4/AC5/AC6/AC8: overlays the off-by-default/temp-capture states on top
  # of a satellite's raw worst-status rank. ERROR always wins (the
  # errors-always-persist amendment) — an off-tier satellite with a
  # windowed error renders "error" (with data-node-off still true, so the
  # dashed off-tier stroke stays — see map_node/1), not the healthy-looking
  # "off" state.
  defp display_status(key, raw_status, captures) do
    cond do
      Map.has_key?(captures, key) -> "temp"
      off_endpoint?(key) and raw_status == :error -> "error"
      off_endpoint?(key) -> "off"
      true -> Atom.to_string(raw_status)
    end
  end

  defp build_node(key, kind, position, raw_status, display_status, label, route, selected, states, now, captures) do
    counts = TraceMapStatus.counts(node_state(states, key), now)
    is_selected = kind != "nebu" and key in selected
    off_tier = kind == "satellite" and off_endpoint?(key)
    capture = if kind == "satellite", do: Map.get(captures, key), else: nil

    %{
      key: key,
      kind: kind,
      # A stable DOM id per node: LiveView's DOM patching matches keyed
      # elements in place, so a selection/status patch can never replace the
      # <g> element itself — keyboard focus survives Enter/Space toggles
      # (AC10; verified against the live stack in dev cycle 1).
      #
      # KIND-prefixed (dev cycle 2): "/health" is simultaneously a domain key
      # AND a satellite key (a single-segment route is its own domain per
      # TraceMapTree.domain_for_endpoint/1) — a key-only id produced two
      # elements with the SAME id, which corrupts LiveView's id-keyed DOM
      # patching for exactly those nodes (observed live: the toggle patch for
      # the /health domain never applied).
      dom_id: "tm-node-" <> kind <> "-" <> Base.url_encode64(key, padding: false),
      x: coord(position.x),
      y: coord(position.y),
      r: position.r,
      status: display_status,
      off_tier: off_tier,
      capture: capture,
      countdown_text: if(capture, do: capture_countdown_text(capture, now), else: nil),
      countdown_expires_at: if(capture, do: capture_expires_at_unix(capture), else: nil),
      selected: is_selected,
      pressed: is_selected,
      label: label,
      route: route,
      counts: counts,
      aria_label:
        node_aria_label(kind, label, route, display_status, raw_status, counts, capture, now, off_tier),
      tooltip_status: status_word(raw_status),
      tooltip_counts: counts_text(counts),
      tooltip_cta: tooltip_cta(kind),
      click_event: if(kind == "nebu", do: "clear_filters", else: "toggle_node")
    }
  end

  defp node_state(states, key), do: Map.get(states, key, TraceMapStatus.new())

  defp build_edges(groups, layout) do
    domain_edges =
      Enum.map(layout.domains, fn {_key, domain} ->
        edge(layout.nebu, domain)
      end)

    satellite_edges =
      Enum.flat_map(groups, fn {domain, leaves} ->
        domain_pos = Map.fetch!(layout.domains, domain)
        Enum.map(leaves, fn route -> edge(domain_pos, Map.fetch!(layout.satellites, route)) end)
      end)

    domain_edges ++ satellite_edges
  end

  defp edge(a, b) do
    {x1, y1, x2, y2} = TraceMapGeometry.trim_edge(a, b)
    %{x1: coord(x1), y1: coord(y1), x2: coord(x2), y2: coord(y2)}
  end

  defp coord(value), do: :erlang.float_to_binary(value / 1, decimals: 2)

  defp visible_lines(assigns) do
    Enum.filter(assigns.stream_entries, fn line ->
      MapSet.member?(assigns.active_levels, line.ui_level) and
        endpoint_match?(line, assigns.selected)
    end)
  end

  # AC5: OR within the endpoint dimension; a selected DOMAIN matches all its
  # satellites' lines.
  defp endpoint_match?(_line, []), do: true

  defp endpoint_match?(line, selected) do
    line.route in selected or (line.domain != nil and line.domain in selected)
  end

  defp inspected_node(%{inspected: nil}), do: nil

  defp inspected_node(assigns) do
    key = assigns.inspected
    now = assigns.now_ms
    state = node_state(assigns.node_states, key)

    {kind, label, route} =
      cond do
        key == "nebu" -> {"nebu", "nebu", "all traffic"}
        TraceMapTree.domain_for_endpoint(key) == key -> {"domain", domain_label(key), key}
        true -> {"satellite", satellite_label(key), key}
      end

    %{
      key: key,
      kind: kind,
      label: label,
      route: route,
      status: state |> TraceMapStatus.status(now) |> Atom.to_string(),
      counts: TraceMapStatus.counts(state, now),
      events: Map.get(assigns.node_events, key, []),
      # AC1/AC2/AC3: the "Logging" panel — built once per inspected node.
      # min_level/retention_days are pure functions of (key, stored
      # server_config), never of @now_ms/counts, so a stat-tick re-render
      # produces byte-identical select markup (AC3).
      scope_note: scope_note(kind),
      min_level: current_min_level(key),
      retention_days: current_retention_days(key),
      # AC5/AC6/AC9: capture controls apply to ANY off-list key regardless
      # of its domain/satellite display kind (/health is simultaneously
      # both — see TraceMap.off_endpoint?/1's moduledoc).
      off_tier: off_endpoint?(key),
      capture: Map.get(assigns.captures, key)
    }
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Labels / text helpers
  # ══════════════════════════════════════════════════════════════════════════

  defp domain_label(domain), do: Map.get(@domain_labels, domain, domain)

  defp satellite_label(route) do
    route
    |> String.split("/")
    |> Enum.reject(&(&1 == ""))
    |> List.last()
    |> case do
      nil -> route
      segment -> segment
    end
  end

  # AC1/AC2: the inspector's scope note (dummy copy).
  defp scope_note("satellite"), do: "Applies to this endpoint only"
  defp scope_note("domain"), do: "Applies to all endpoints in this domain"
  defp scope_note("nebu"), do: "Applies to all endpoints on the map"

  # AC1/AC2: pre-population from server_config (Dev Notes key format:
  # log_min_level_<route> / log_retention_days_<route>). DB-free guard
  # mirrors the rest of this module's Process.whereis(Nebu.Repo) contract —
  # sensible defaults (INFO / 7 d) when unset or DB-free.
  defp current_min_level(key) do
    read_config_value("log_min_level_" <> key, "info") |> to_string() |> String.upcase()
  end

  defp current_retention_days(key) do
    read_config_value("log_retention_days_" <> key, "7") |> to_string()
  end

  defp read_config_value(key, default) do
    if Process.whereis(Nebu.Repo) do
      {:ok, config} = Nebu.Admin.DB.get_server_config()
      Map.get(config, key, default)
    else
      default
    end
  end

  # AC2 (story amendment 2026-07-07 / test-review M1): 1 d / 7 d / 30 d —
  # the dummy's "1 h" option is dropped, day-granularity only.
  defp retention_options, do: @retention_options

  # A stable id-safe fragment for the inspected node's <label for=...>/
  # <select id=...> pairing (AC9) — reuses the same Base64 scheme as each
  # SVG node's own dom_id.
  defp node_dom_key(key), do: Base.url_encode64(key, padding: false)

  defp capture_expires_at_unix(%{expires_at: %DateTime{} = expires_at}) do
    Integer.to_string(DateTime.to_unix(expires_at))
  end

  defp capture_countdown_text(capture, now_ms) do
    now = DateTime.from_unix!(div(now_ms, 1000))
    format_clock(TemporaryCaptureManager.remaining_seconds(capture, now))
  end

  # AC10: name + route + status + counts, e.g.
  # "users endpoint · /admin/users · errors · 1 error · 0 warnings · 1 request in the last 60 seconds"
  #
  # AC4/AC8/AC9: an "off" display status names the state in text ("logging
  # off") rather than the generic status word (status is never color-alone);
  # "temp" names the capture state + remaining time.
  # UX gate (2026-07-08, V3 fix): the off+error composite state (AC4
  # errors-always-persist amendment) previously fell through to the
  # generic `_` branch below, losing the "logging off" information
  # entirely — the dashed-vs-solid stroke became the ONLY signal
  # distinguishing an off-tier node with a windowed error from an
  # ordinary always-on error node, violating status-never-color/shape-
  # alone. `off_tier` is now threaded through so this composite state
  # gets its own branch, naming BOTH facts in text.
  defp node_aria_label(kind, label, route, display_status, raw_status, counts, capture, now_ms, off_tier) do
    name =
      case kind do
        "nebu" -> "nebu"
        "domain" -> label <> " domain"
        _ -> label <> " endpoint"
      end

    base = Enum.join([name, route], " · ")

    cond do
      display_status == "off" ->
        base <> " · logging off"

      display_status == "temp" ->
        base <> " · temporary capture · " <> capture_remaining_phrase(capture, now_ms)

      display_status == "error" and off_tier ->
        base <>
          " · logging off · errors detected · " <>
          pluralize(counts.errors, "error") <> " in the last 60 seconds"

      true ->
        Enum.join(
          [
            base,
            status_word(raw_status),
            pluralize(counts.errors, "error"),
            pluralize(counts.warnings, "warning"),
            pluralize(counts.requests, "request") <> " in the last 60 seconds"
          ],
          " · "
        )
    end
  end

  defp capture_remaining_phrase(nil, _now_ms), do: "5 minutes remaining"

  defp capture_remaining_phrase(capture, now_ms) do
    now = DateTime.from_unix!(div(now_ms, 1000))
    remaining = TemporaryCaptureManager.remaining_seconds(capture, now)
    minutes = div(remaining, 60)
    seconds = rem(remaining, 60)
    pluralize(minutes, "minute") <> " " <> pluralize(seconds, "second") <> " remaining"
  end

  defp status_word(:ok), do: "healthy"
  defp status_word(:warn), do: "warnings"
  defp status_word(:error), do: "errors"

  defp counts_text(counts) do
    "#{pluralize(counts.requests, "request")} · #{pluralize(counts.warnings, "warning")} · " <>
      "#{pluralize(counts.errors, "error")} in the last 60s"
  end

  defp pluralize(1, word), do: "1 " <> word
  defp pluralize(n, word), do: "#{n} #{word}s"

  defp tooltip_cta("nebu"), do: "Click to clear all filters"
  defp tooltip_cta(_kind), do: "Click to filter the stream"

  defp badge_count(count) when count > 9, do: "9+"
  defp badge_count(count), do: Integer.to_string(count)

  defp badge_transform(radius) do
    offset = coord(radius * 0.72)
    "translate(#{offset} -#{offset})"
  end

  defp legend_rows do
    [
      {"ok", "tm-legend-dot--ok", "Healthy — recedes into the background"},
      {"warn", "tm-legend-dot--warn", "▲ Warnings in the last 60 s"},
      {"error", "tm-legend-dot--error", "✕ Errors in the last 60 s — pulses"},
      {"selected", "tm-legend-dot--selected", "Selected as stream filter"},
      {"off", "tm-legend-dot--off",
       "Long-polling endpoint — logging off by default; click to capture for 5 min"},
      {"temp", "tm-legend-dot--temp", "Dashed = temporary capture, falls back to off automatically"}
    ]
  end

  defp level_pill_class("DEBUG", true), do: "text-text-secondary border-text-secondary"
  defp level_pill_class("INFO", true), do: "text-base-content border-text-secondary"
  defp level_pill_class("WARN", true), do: "text-warning border-warning bg-status-warn-bg"
  # UX gate V5: #ef4444 on status-error-bg is only 4.29:1 — the dummy's own
  # pairing (#fca5a5, status-error-text token, 8.51:1) is used for text on
  # that background.
  defp level_pill_class("ERROR", true), do: "text-status-error-text border-error bg-status-error-bg"
  # UX gate V3: inactive pills are ENABLED toggle buttons — the disabled-text
  # token (#4b5563, 2.35:1) fails WCAG 1.4.3 for them; text-secondary still
  # reads clearly dimmed next to the colored active pills.
  defp level_pill_class(_level, false), do: "text-text-secondary border-base-300"

  defp level_text_class("ERROR"), do: "text-error"
  defp level_text_class("WARN"), do: "text-warning"
  defp level_text_class("DEBUG"), do: "text-text-secondary"
  defp level_text_class(_), do: "text-text-secondary"

  defp status_pill_class("ok"), do: "bg-status-ok-bg text-success"
  defp status_pill_class("warn"), do: "bg-status-warn-bg text-warning"
  defp status_pill_class("error"), do: "bg-status-error-bg text-status-error-text"

  defp status_pill_text("ok"), do: "● Healthy"
  defp status_pill_text("warn"), do: "▲ Warnings"
  defp status_pill_text("error"), do: "✕ Errors"

  # ══════════════════════════════════════════════════════════════════════════
  # War-room banner helpers (AC6)
  # ══════════════════════════════════════════════════════════════════════════

  defp war_room_active?({:ok, _session}), do: true
  defp war_room_active?(_), do: false

  # Only ever called inside `:if={war_room_active?(@war_room)}` blocks, so a
  # fallback clause would be dead code (flagged by --warnings-as-errors).
  defp war_room_session({:ok, session}), do: session

  defp war_room_started_at_unix({:ok, %{started_at: %DateTime{} = started_at}}) do
    Integer.to_string(DateTime.to_unix(started_at))
  end

  defp war_room_started_at_unix(_), do: nil

  defp war_room_elapsed({:ok, %{started_at: %DateTime{} = started_at}}) do
    total = max(DateTime.diff(DateTime.utc_now(), started_at, :second), 0)
    format_clock(total)
  end

  defp war_room_elapsed(_), do: "00:00"

  defp format_clock(total_seconds) when total_seconds >= 3600 do
    hours = div(total_seconds, 3600)
    rest = rem(total_seconds, 3600)
    "#{pad2(hours)}:#{pad2(div(rest, 60))}:#{pad2(rem(rest, 60))}"
  end

  defp format_clock(total_seconds) do
    "#{pad2(div(total_seconds, 60))}:#{pad2(rem(total_seconds, 60))}"
  end

  defp pad2(n), do: String.pad_leading(Integer.to_string(n), 2, "0")
end
