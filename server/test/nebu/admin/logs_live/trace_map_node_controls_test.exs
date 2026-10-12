defmodule Nebu.Admin.LogsLive.TraceMapNodeControlsTest do
  @moduledoc """
  RED-phase ATDD tests for `enhanced-logging/trace-map-node-controls` — the
  LiveView rendering/event half (AC1, AC2, AC3, AC4, AC5, AC6, AC7, AC8,
  AC9, AC10, AC12).

  Story: docs/stories/enhanced-logging/trace-map-node-controls.md
  Design: _bmad-output/nebu/epics/enhanced-logging/design/trace-map-leitstand-spec.md §4/§5
  Visual/copy authority: trace-map-leitstand-dummy.html (same directory) —
  "the dummy IS the spec for visual treatment, copy, and interaction feel".

  Pure-logic contracts (off-list, cascade set, expiry comparison, duration
  env, should_persist?/2, audit vocabulary) live in
  `trace_map_node_controls_contract_test.exs`; the DB-backed
  `Nebu.Admin.TemporaryCaptureManager` API in
  `temporary_capture_manager_test.exs`; the browser-only half (REAL focus
  preservation across live patches, per-second countdown ticking, aria-live
  in a real AT tree) in `e2e/features/admin/logs-trace-map-node-controls.feature`
  (@pending-feature, Scenarios A–F per the story's AC11).

  This file COMPOSES with the shipped `trace_map_leitstand_test.exs` — its
  helpers are mirrored, none of its pinned contracts are contradicted. All
  selectors on `/health` are KIND-scoped (`[data-node-kind=...]`): a
  single-segment route is simultaneously its own domain AND a satellite
  (accepted design, leitstand code-review i3), so a key-only selector
  matches two elements.

  ## Why these MUST FAIL right now

  The shipped Leitstand renders off-list endpoints like any other node
  (they only appear once traffic is observed, with numeric counts and
  ok/warn/error statuses), and the inspector has NO "Logging" section — no
  selects, no capture controls, no `configure_logging`/`enable_capture`/
  `disable_capture` events. Every test below red-fails on missing markup or
  missing event handlers — never on a compile error in this file.

  ## Data-attribute / event contract this file pins down (extends, never
  ## replaces, the leitstand file's contract)

    * Off-list endpoints (`TraceMap.long_polling_endpoints/0`) are ALWAYS
      on the map — rendered from mount, traffic or not (they collect no
      data, so waiting for traffic would never show them):
      `data-node-status="off"`, node count text "off" (not a number), no
      warn/error badges, aria-label contains "logging off" (AC4/AC8/AC9).
    * Off propagation (AC4 / Known Challenge 1): a domain whose observed
      children are ALL off is itself `data-node-status="off"` (at a clean
      mount that includes `/_matrix/client` — its only child is the off
      `/sync` — and `/admin` — only child `/admin/keepalive` — and the
      `/health` domain node). Once a NON-off child exists, the domain
      reflects its children's health again while off children stay off.
    * Off DEBUG/INFO/WARN entries are NOT part of the leitstand's signal
      (AC4 "the status window shows zero requests"): a live PubSub
      broadcast for an off-list route with no active capture updates
      NOTHING — no node counts, no badges, no stream line, no nebu
      aggregation. **EXCEPTION (story amendment 2026-07-07, AC4
      errors-always-persist): ERROR-level entries are always collected and
      always drive node status** — an off node with errors in the 60 s
      window renders the error state on its dashed off stroke
      (`data-node-status="error"` + `data-node-off="true"` for the dashed
      styling + ✕ badge with count), the error line appears in the stream,
      and it aggregates up to domain and nebu. "Off" silences noise, never
      failures.
    * Inspector logging section (AC1/AC2, dummy copy):
      `[data-testid="trace-map-inspector-logging"]` with heading "Logging";
      `select[data-testid="trace-map-inspector-level-select"]` (options
      DEBUG/INFO/WARN/ERROR) and
      `select[data-testid="trace-map-inspector-retention-select"]` (option
      labels "1 d" / "7 d" / "30 d" — story amendment 2026-07-07: the
      dummy's "1 h" option is dropped, hour-granularity retention is out
      of scope; day labels map to `log_retention_days_*` integer-string
      values "1"/"7"/"30"), each wired to a `<label
      for=...>` ("Min level" / "Retention", AC9). Both live inside
      `form[data-testid="trace-map-inspector-logging-form"]` with
      `phx-change="configure_logging"` (AC10: LiveView event, CSRF-safe by
      construction, no inline JS). The change params carry `node_key`,
      `min_level`, `retention_days` (Dev Notes' hidden-field variant).
    * Scope note `[data-testid="trace-map-inspector-scope-note"]` (AC1):
      satellite -> "Applies to this endpoint only"; domain -> "Applies to
      all endpoints in this domain"; nebu -> "... on the map". Clicking
      nebu therefore ALSO inspects it (it still clears filters — the
      leitstand contract is unchanged).
    * Capture row in the inspector for an inspected off satellite (dummy
      copy): `[data-testid="trace-map-inspector-capture-state"]` reading
      "Logging off (long-polling)" with an enable button
      `[data-testid="trace-map-inspector-capture-toggle"]`
      (`phx-click="enable_capture"`); while capturing the state reads
      "Capture active" with countdown and the button becomes "Disable now"
      (`phx-click="disable_capture"`, aria-label naming the endpoint —
      AC5/AC6/AC9).
    * Temp-capture node state (AC6/AC8): `data-node-status="temp"`, a
      `[data-testid="trace-map-node-countdown"]` text element in mm:ss
      carrying `data-expires-at` (unix seconds — the war-room banner's
      `data-started-at` precedent) so the TraceMapLeitstand hook can tick
      the countdown client-side with no server tick.
    * Interaction (AC5/AC7, the dummy's `activate()`): clicking an off,
      non-capturing satellite ENABLES capture (and inspects it) — it never
      toggles the stream filter; clicking it again WHILE capturing toggles
      the filter like any other node; "Disable now" ends the capture
      without clearing an active filter (Known Challenge 4).
    * Announcements (AC5/AC9) go through the existing
      `[data-testid="trace-map-announcer"]` live region: enable ->
      "Temporary capture enabled for <endpoint> · 5 minutes"; disable ->
      "Temporary capture disabled for <endpoint>"; expiry -> "Temporary
      capture expired for <endpoint>" (asserted via =~ on the stable
      phrases, exact interpuncts not pinned).

  ## One-click enable — CONFIRMED by story amendment (2026-07-07)

  AC11's Scenario C prose originally showed a two-step enable; the story
  amendment confirms the dummy's `activate()` behavior: clicking an off
  node enables capture immediately (AC5/AC7 contract), and the inspector's
  "Enable for 5 min" button exists for the post-early-disable state only —
  that re-enable path is itself pinned below (test-review m4).

  ## DB-free vs :integration split

  Mirrors trace_map_leitstand_test.exs exactly: markup/event tests run
  DB-free under `make test-unit-elixir` (every capture/config DB touch in
  the implementation MUST be guarded behind `Process.whereis(Nebu.Repo)`);
  everything that genuinely persists (capture rows, server_config writes,
  cascade, pre-population, audit) is `@describetag :integration` and runs
  under `make test-integration` only.
  """

  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn
  import Phoenix.LiveViewTest
  import Phoenix.ConnTest

  @endpoint Nebu.Admin.Endpoint
  @secret_key_base String.duplicate("nebu-trace-map-node-controls-key", 2)
  @topic "operational_logs"

  @off_sync "/_matrix/client/v3/sync"
  @off_keepalive "/admin/keepalive"
  @off_health "/health"

  # ══════════════════════════════════════════════════════════════════════
  # Helpers — mirror trace_map_leitstand_test.exs's admin_conn/mount pattern
  # ══════════════════════════════════════════════════════════════════════

  defp admin_conn(path) do
    %{conn(:get, path) | secret_key_base: @secret_key_base}
    |> @endpoint.admin_session([])
    |> fetch_session()
    |> put_session("current_user", %{
      "admin" => true,
      "sub" => "admin-trace-map-node-controls-tests",
      "matrix_user_id" => "@admin:test.local"
    })
  end

  defp mount_trace_map(query_string \\ "") do
    path =
      if query_string == "",
        do: "/admin/logs/trace-map",
        else: "/admin/logs/trace-map?" <> query_string

    sent_conn = path |> admin_conn() |> @endpoint.call(@endpoint.init([]))
    live(sent_conn)
  end

  defp parsed(html), do: Floki.parse_document!(html)

  defp find(html, selector), do: html |> Floki.find(selector) |> List.first()
  defp find_all(html, selector), do: Floki.find(html, selector)
  defp attr(node, name), do: node |> List.wrap() |> Floki.attribute(name) |> List.first()

  # KIND-scoped node locator — mandatory for /health (domain AND satellite).
  defp node_locator(html, key, kind) do
    find(
      html,
      ~s([data-testid="trace-map-node"][data-node-key="#{key}"][data-node-kind="#{kind}"])
    )
  end

  defp node_selector(key, kind) do
    ~s([data-testid="trace-map-node"][data-node-key="#{key}"][data-node-kind="#{kind}"])
  end

  defp entry(overrides) do
    Map.merge(
      %{
        level: "info",
        source: "http",
        route_template: "/foo",
        request_id: "req-" <> Integer.to_string(System.unique_integer([:positive])),
        message: "distinctive-node-controls-probe",
        metadata: %{}
      },
      Map.new(overrides)
    )
  end

  defp broadcast_entry(overrides) do
    e = entry(overrides)
    Phoenix.PubSub.broadcast(Nebu.PubSub, @topic, e)
    e
  end

  defp click_node(view, key, kind) do
    view |> element(node_selector(key, kind)) |> render_click()
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC4/AC8: off-by-default rendering — always on the map, gray/dashed/"off"
  # ══════════════════════════════════════════════════════════════════════

  describe "AC4: the off-list endpoints are on the map from mount, with no traffic" do
    @describetag :no_repo
    test "all three default off endpoints render as satellite nodes with status off" do
      {:ok, _view, html} = mount_trace_map()
      doc = parsed(html)

      for route <- [@off_sync, @off_keepalive, @off_health] do
        node = node_locator(doc, route, "satellite")

        assert node,
               "AC4: off-list endpoint #{route} must be rendered WITHOUT traffic " <>
                 "(it collects no data, so it can never appear by observation)"

        assert attr(node, "data-node-status") == "off",
               "AC4: #{route} must render in the off state"
      end
    end

    test "an off node's count reads the text \"off\", not a number, and carries no badges" do
      {:ok, _view, html} = mount_trace_map()
      doc = parsed(html)

      node = node_locator(doc, @off_health, "satellite")
      assert Floki.text(node) =~ "off", "AC4: the node count must show the text \"off\""

      refute find(node, ~s([data-testid="trace-map-badge-warn"]))
      refute find(node, ~s([data-testid="trace-map-badge-error"]))
    end

    test "off nodes' aria-labels read \"logging off\" (AC9, never color-alone)" do
      {:ok, _view, html} = mount_trace_map()
      doc = parsed(html)

      for route <- [@off_sync, @off_keepalive, @off_health] do
        label = attr(node_locator(doc, route, "satellite"), "aria-label")

        assert label =~ route
        assert label =~ ~r/logging off/i,
               "AC9: #{route}'s aria-label must state the off state in text"
      end
    end

    test "a domain whose children are ALL off is itself off (Known Challenge 1)" do
      {:ok, _view, html} = mount_trace_map()
      doc = parsed(html)

      # At a clean mount each of these domains exists solely because of its
      # off child: /_matrix/client <- /sync, /admin <- /admin/keepalive,
      # /health <- itself.
      assert attr(node_locator(doc, "/_matrix/client", "domain"), "data-node-status") == "off"
      assert attr(node_locator(doc, "/admin", "domain"), "data-node-status") == "off"
      assert attr(node_locator(doc, @off_health, "domain"), "data-node-status") == "off"
    end

    test "a non-off sibling brings the domain back to health-status while the off child stays off" do
      {:ok, view, _html} = mount_trace_map()
      broadcast_entry(route_template: "/_matrix/client/v3/login", level: "info")

      doc = render(view) |> parsed()

      assert attr(node_locator(doc, "/_matrix/client/v3/login", "satellite"), "data-node-status") ==
               "ok"

      assert attr(node_locator(doc, "/_matrix/client", "domain"), "data-node-status") == "ok",
             "AC4: with one live child, the domain reflects that child's health again"

      assert attr(node_locator(doc, @off_sync, "satellite"), "data-node-status") == "off",
             "AC4: the off sibling must stay off"
    end
  end

  describe "AC4: debug/info/warn broadcasts for off-list endpoints (no capture) are not part of the signal" do
    @describetag :no_repo
    test "a warning broadcast for an off endpoint changes neither its node nor its domain" do
      {:ok, view, _html} = mount_trace_map()
      broadcast_entry(route_template: @off_keepalive, level: "warning")

      doc = render(view) |> parsed()
      node = node_locator(doc, @off_keepalive, "satellite")

      assert attr(node, "data-node-status") == "off",
             "AC4: an uncaptured off endpoint never leaves the off state for WARN"

      refute find(node, ~s([data-testid="trace-map-badge-warn"]))
      assert Floki.text(node) =~ "off"

      assert attr(node_locator(doc, "/admin", "domain"), "data-node-status") == "off",
             "AC4: no status propagation from an uncaptured off endpoint's warnings"
    end

    test "a warning broadcast for an off endpoint produces no stream line and no nebu aggregation" do
      {:ok, view, _html} = mount_trace_map()

      broadcast_entry(
        route_template: @off_health,
        level: "warning",
        message: "distinctive-off-endpoint-line"
      )

      doc = render(view) |> parsed()

      texts =
        doc
        |> find_all(~s([data-testid="trace-map-stream-line"]))
        |> Enum.map(&Floki.text/1)

      refute Enum.any?(texts, &(&1 =~ "distinctive-off-endpoint-line")),
             "AC4: uncollected off-endpoint entries must not appear in the stream panel"

      nebu_label = attr(node_locator(doc, "nebu", "nebu"), "aria-label")

      assert nebu_label =~ "0 requests",
             "AC4: an uncaptured off WARN entry must not count into nebu's window " <>
               "(got aria-label #{inspect(nebu_label)})"

      assert nebu_label =~ "0 warnings"
    end
  end

  describe "AC4 amendment: ERRORS on an off endpoint are never silenced (errors-always-persist)" do
    @describetag :no_repo
    # Story amendment 2026-07-07 (test-review m3, design owner): "logging
    # off" suppresses DEBUG/INFO/WARN collection AND status, but ERROR-level
    # entries always drive node status — an off node with errors in the 60 s
    # window renders the error state on its dashed off stroke (red dashed +
    # ✕ badge + count). A silently-red zone contradicts the leitstand
    # mission.
    test "an error broadcast flips the off node to the error state on its dashed stroke" do
      {:ok, view, _html} = mount_trace_map()

      broadcast_entry(
        route_template: @off_health,
        level: "error",
        message: "distinctive-off-error-line"
      )

      doc = render(view) |> parsed()
      node = node_locator(doc, @off_health, "satellite")

      assert attr(node, "data-node-status") == "error",
             "amendment: an off node with a windowed error must render the ERROR state"

      assert attr(node, "data-node-off") == "true",
             "amendment: the node stays visually off-tier (dashed stroke) — " <>
               "data-node-off carries the off marker while status carries the error"

      badge = find(node, ~s([data-testid="trace-map-badge-error"]))
      assert badge, "amendment: the ✕ badge must appear on the off node"
      assert Floki.text(badge) =~ "1"

      assert attr(node, "aria-label") =~ ~r/1 error/,
             "the error must be announced in the node's aria-label, never color-alone"

      # code-review MINOR-2 (2026-07-08): `/1 error/` alone is ALSO
      # satisfied by the generic (non-off) error branch — this pins the
      # off+error COMPOSITE branch specifically, so a regression that
      # silently falls back to the generic branch (losing the "logging
      # off" fact — the amendment's whole point, see AC4/AC9) fails here.
      aria_label = attr(node, "aria-label")

      assert aria_label =~ "logging off",
             "amendment: the off+error composite aria-label must still say " <>
               "\"logging off\" — the dashed stroke must not be the ONLY signal " <>
               "that this node is off-tier"

      assert aria_label =~ "errors detected",
             "amendment: the off+error composite aria-label must name the " <>
               "error condition distinctly from the generic always-on error wording"
    end

    test "the off endpoint's error line reaches the stream and aggregates to domain and nebu" do
      {:ok, view, _html} = mount_trace_map()

      broadcast_entry(
        route_template: @off_health,
        level: "error",
        message: "distinctive-off-error-line"
      )

      doc = render(view) |> parsed()

      # Ties this test to the OFF-TIER contract (without this it would pass
      # vacuously against the shipped code, which has no off concept at all
      # and streams /health errors like any node): the satellite must
      # actually be off-tier-marked while its error streams/aggregates.
      assert attr(node_locator(doc, @off_health, "satellite"), "data-node-off") == "true",
             "amendment precondition: the node is off-tier (dashed marker) — " <>
               "the whole point is that the error escapes the OFF suppression"

      texts =
        doc
        |> find_all(~s([data-testid="trace-map-stream-line"]))
        |> Enum.map(&Floki.text/1)

      assert Enum.any?(texts, &(&1 =~ "distinctive-off-error-line")),
             "amendment: ERROR entries for off endpoints are collected and streamed"

      assert attr(node_locator(doc, @off_health, "domain"), "data-node-status") == "error",
             "amendment: the error propagates to the (otherwise off) domain"

      assert attr(node_locator(doc, "nebu", "nebu"), "aria-label") =~ "1 error",
             "amendment: the error aggregates into nebu's window"
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC1/AC2/AC9: inspector logging controls markup
  # ══════════════════════════════════════════════════════════════════════

  describe "AC1/AC2: the inspected node's Logging section renders labelled selects" do
    @describetag :no_repo
    test "clicking a satellite shows the Logging section with min-level and retention selects" do
      {:ok, view, _html} = mount_trace_map()
      broadcast_entry(route_template: "/admin/users", level: "info")
      render(view)

      html = click_node(view, "/admin/users", "satellite") |> parsed()

      section = find(html, ~s([data-testid="trace-map-inspector-logging"]))
      assert section, "AC1: expected a Logging section in the inspector"
      assert Floki.text(section) =~ "Logging"

      level_select = find(section, ~s(select[data-testid="trace-map-inspector-level-select"]))
      assert level_select, "AC1: expected the min-level select"

      level_options = level_select |> Floki.find("option") |> Enum.map(&String.trim(Floki.text(&1)))
      assert level_options == ["DEBUG", "INFO", "WARN", "ERROR"]

      retention_select =
        find(section, ~s(select[data-testid="trace-map-inspector-retention-select"]))

      assert retention_select, "AC2: expected the retention select"

      retention_options =
        retention_select |> Floki.find("option") |> Enum.map(&String.trim(Floki.text(&1)))

      # Story amendment 2026-07-07 (test-review M1): "1 h" is dropped —
      # day-granularity only, matching the log_retention_days_* backend.
      assert retention_options == ["1 d", "7 d", "30 d"]
    end

    test "both selects are wired to <label for=...> elements (AC9)" do
      {:ok, view, _html} = mount_trace_map()
      broadcast_entry(route_template: "/admin/users", level: "info")
      render(view)

      html = click_node(view, "/admin/users", "satellite") |> parsed()

      for {select_testid, label_text} <- [
            {"trace-map-inspector-level-select", ~r/min level/i},
            {"trace-map-inspector-retention-select", ~r/retention/i}
          ] do
        select = find(html, ~s(select[data-testid="#{select_testid}"]))
        select_id = attr(select, "id")

        assert select_id not in [nil, ""],
               "AC9: #{select_testid} needs an id a <label for> can target"

        label = find(html, ~s(label[for="#{select_id}"]))
        assert label, "AC9: expected a <label for=\"#{select_id}\">"
        assert Floki.text(label) =~ label_text
      end
    end

    test "the controls live in a form with phx-change=configure_logging (AC10 — no inline JS)" do
      {:ok, view, _html} = mount_trace_map()
      broadcast_entry(route_template: "/admin/users", level: "info")
      render(view)

      html = click_node(view, "/admin/users", "satellite") |> parsed()

      form = find(html, ~s(form[data-testid="trace-map-inspector-logging-form"]))
      assert form, "AC10: expected the logging controls to be a LiveView form"
      assert attr(form, "phx-change") == "configure_logging"
    end

    test "a satellite's scope note reads \"Applies to this endpoint only\"" do
      {:ok, view, _html} = mount_trace_map()
      broadcast_entry(route_template: "/admin/users", level: "info")
      render(view)

      html = click_node(view, "/admin/users", "satellite") |> parsed()
      note = find(html, ~s([data-testid="trace-map-inspector-scope-note"]))

      assert note
      assert Floki.text(note) =~ "Applies to this endpoint only"
    end

    test "a domain's scope note reads \"Applies to all endpoints in this domain\"" do
      {:ok, view, _html} = mount_trace_map()
      broadcast_entry(route_template: "/admin/users", level: "info")
      render(view)

      html = click_node(view, "/admin", "domain") |> parsed()
      note = find(html, ~s([data-testid="trace-map-inspector-scope-note"]))

      assert Floki.text(note) =~ "Applies to all endpoints in this domain"
    end

    test "clicking nebu inspects it (scope note \"on the map\") AND still clears filters" do
      {:ok, view, _html} = mount_trace_map()
      broadcast_entry(route_template: "/admin/users", level: "info")
      render(view)

      click_node(view, "/admin/users", "satellite")

      html = click_node(view, "nebu", "nebu") |> parsed()

      # Leitstand contract unchanged: nebu clears every filter.
      assert find_all(html, ~s([data-testid="trace-map-filter-chip"])) == []

      # New (AC1): nebu is also inspectable — the map-wide cascade target.
      assert Floki.text(find(html, ~s([data-testid="trace-map-inspector-name"]))) =~ "nebu"

      note = find(html, ~s([data-testid="trace-map-inspector-scope-note"]))
      assert Floki.text(note) =~ "on the map"
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC3: panel built once per node — stat patches never rebuild the selects
  # ══════════════════════════════════════════════════════════════════════

  describe "AC3: only stat values update on a live tick; the selects survive verbatim" do
    @describetag :no_repo
    test "a new log entry patches the stats but leaves the select markup identical" do
      {:ok, view, _html} = mount_trace_map()
      broadcast_entry(route_template: "/admin/users", level: "info")
      render(view)

      html_before = click_node(view, "/admin/users", "satellite") |> parsed()

      select_node = find(html_before, ~s(select[data-testid="trace-map-inspector-level-select"]))

      assert select_node,
             "AC3 precondition: the level select must exist once a node is inspected (AC1) — " <>
               "without this the before/after comparison below would pass vacuously"

      select_before = Floki.raw_html(select_node)

      assert Floki.text(find(html_before, ~s([data-testid="trace-map-inspector-stat-requests"]))) =~
               "1"

      # The stat tick: a second live entry for the inspected endpoint.
      broadcast_entry(route_template: "/admin/users", level: "info")
      html_after = render(view) |> parsed()

      assert Floki.text(find(html_after, ~s([data-testid="trace-map-inspector-stat-requests"]))) =~
               "2",
             "the stat patch itself must have happened for this test to mean anything"

      select_after =
        html_after
        |> find(~s(select[data-testid="trace-map-inspector-level-select"]))
        |> Floki.raw_html()

      assert select_after == select_before,
             "AC3: a stat update must not rebuild the level select (same id, same " <>
               "options, same selected value — the build-once/update-stats-only contract; " <>
               "the authoritative real-focus check is E2E Scenario A)"
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC5/AC7 — the DB-free half: an off-node click is never a filter toggle
  # ══════════════════════════════════════════════════════════════════════

  describe "AC5/AC7: clicking an off, non-capturing node never toggles the stream filter" do
    @describetag :no_repo
    test "no filter chip appears and the node is not marked selected" do
      {:ok, view, _html} = mount_trace_map()

      html = click_node(view, @off_health, "satellite") |> parsed()

      assert find_all(html, ~s([data-testid="trace-map-filter-chip"])) == [],
             "AC5: the first click on an off node enables capture — it must NOT filter"

      assert attr(node_locator(html, @off_health, "satellite"), "data-node-selected") == "false"
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC10: CSP — the new controls introduce no inline JS
  # ══════════════════════════════════════════════════════════════════════

  describe "AC10: with the inspector controls open, the page still carries no inline JS" do
    @describetag :no_repo
    # DELIBERATELY GREEN against the shipped Leitstand too (the same class of
    # cheap-insurance regression guard as the leitstand file's own
    # unauthenticated-redirect test): the page is inline-JS-free today, and
    # this pins that the NEW inspector controls/capture markup never breaks
    # that (spec §8 constraint 2 — script-src 'self').
    test "no inline <script> and no on*= handlers after inspecting a node" do
      {:ok, view, _html} = mount_trace_map()
      broadcast_entry(route_template: "/admin/users", level: "info")
      render(view)

      html = click_node(view, "/admin/users", "satellite")

      refute Regex.match?(~r/<script(?![^>]*\bsrc=)[^>]*>/i, html)
      refute Regex.match?(~r/\son[a-z]+\s*=/i, html)
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC5/AC6/AC7/AC8/AC9: the capture lifecycle (requires Nebu.Repo)
  # ══════════════════════════════════════════════════════════════════════

  describe "AC5/AC6: enabling temporary capture by clicking an off node" do
    @describetag :integration

    setup do
      Nebu.Release.migrate()
      Ecto.Adapters.SQL.query!(Nebu.Repo, "DELETE FROM admin_temporary_captures", [])
      :ok
    end

    test "one click inserts the DB-backed capture row and flips the node to temp with countdown" do
      {:ok, view, _html} = mount_trace_map()

      html = click_node(view, @off_health, "satellite") |> parsed()

      # DB-backed timer (ANSWERED design question 1) — the row IS the state.
      result =
        Ecto.Adapters.SQL.query!(
          Nebu.Repo,
          "SELECT endpoint, started_by FROM admin_temporary_captures " <>
            "WHERE endpoint = $1 AND expires_at > now()",
          [@off_health]
        )

      assert [[@off_health, started_by]] = result.rows
      assert is_binary(started_by) and started_by != "",
             "AC5: the capture row must record who enabled it (started_by)"

      node = node_locator(html, @off_health, "satellite")
      assert attr(node, "data-node-status") == "temp", "AC5/AC8: the node becomes temp-capture"

      countdown = find(node, ~s([data-testid="trace-map-node-countdown"]))
      assert countdown, "AC6: the node must show a countdown while capturing"
      assert String.trim(Floki.text(countdown)) =~ ~r/^\d{2}:\d{2}$/

      expires_at = attr(countdown, "data-expires-at")
      assert expires_at, "AC6: the hook needs data-expires-at (unix seconds) to tick client-side"

      now = System.system_time(:second)
      duration = Application.get_env(:nebu, :temporary_capture_duration_s, 300)
      assert_in_delta String.to_integer(expires_at), now + duration, 5

      # AC9: temp aria-label announces the capture state (countdown wording
      # is updated by the hook client-side; the server's own label must at
      # least name the temporary capture).
      assert attr(node, "aria-label") =~ ~r/temporary capture/i

      # AC5/AC9: the enable announcement through the live region.
      announcement = find(html, ~s([data-testid="trace-map-announcer"])) |> Floki.text()
      assert announcement =~ "Temporary capture enabled"
      assert announcement =~ @off_health
      assert announcement =~ "5 minutes"

      # AC5: enabling is not a filter toggle.
      assert find_all(html, ~s([data-testid="trace-map-filter-chip"])) == []
    end

    test "while capturing, the inspector shows Capture active + countdown + Disable now" do
      {:ok, view, _html} = mount_trace_map()

      html = click_node(view, @off_health, "satellite") |> parsed()

      state = find(html, ~s([data-testid="trace-map-inspector-capture-state"]))
      assert state, "AC5: expected the capture-state line in the inspector"
      assert Floki.text(state) =~ "Capture active"

      inspector_countdown =
        find(html, ~s([data-testid="trace-map-inspector-capture-countdown"]))

      assert inspector_countdown,
             "AC6: the inspector shows the same countdown as the node"

      assert attr(inspector_countdown, "data-expires-at")

      button = find(html, ~s([data-testid="trace-map-inspector-capture-toggle"]))
      assert button, "AC5: expected the Disable now button while capture is active"
      assert Floki.text(button) =~ "Disable now"
      assert attr(button, "phx-click") == "disable_capture"

      assert attr(button, "aria-label") =~ @off_health,
             "AC9: the disable button's aria-label must name the endpoint"
    end

    test "an inspected off satellite (no capture) offers Logging off + Enable for 5 min" do
      {:ok, view, _html} = mount_trace_map()

      # Reach the off-inspected state via enable -> early disable (the
      # one-click contract makes it unreachable by a plain first click).
      click_node(view, @off_health, "satellite")

      html =
        view
        |> element(~s([data-testid="trace-map-inspector-capture-toggle"]))
        |> render_click()
        |> parsed()

      state = find(html, ~s([data-testid="trace-map-inspector-capture-state"]))
      assert Floki.text(state) =~ "Logging off (long-polling)",
             "dummy copy: the off capture-state line"

      button = find(html, ~s([data-testid="trace-map-inspector-capture-toggle"]))
      assert Floki.text(button) =~ ~r/Enable/i
      assert attr(button, "phx-click") == "enable_capture"
    end

    test "the Enable button re-enables capture after an early disable (test-review m4)" do
      {:ok, view, _html} = mount_trace_map()

      # enable (click) -> early disable (button) -> RE-ENABLE (button).
      click_node(view, @off_health, "satellite")

      view
      |> element(~s([data-testid="trace-map-inspector-capture-toggle"]))
      |> render_click()

      html =
        view
        |> element(~s([data-testid="trace-map-inspector-capture-toggle"]))
        |> render_click()
        |> parsed()

      node = node_locator(html, @off_health, "satellite")
      assert attr(node, "data-node-status") == "temp",
             "m4: the re-enable path must bring the node back to temp-capture"

      assert find(node, ~s([data-testid="trace-map-node-countdown"]))

      result =
        Ecto.Adapters.SQL.query!(
          Nebu.Repo,
          "SELECT count(*) FROM admin_temporary_captures " <>
            "WHERE endpoint = $1 AND expires_at > now()",
          [@off_health]
        )

      assert result.rows == [[1]],
             "m4: a FRESH capture row must exist after re-enabling (the disabled " <>
               "one is gone — endpoint is the primary key)"
    end
  end

  describe "AC5/AC7: early disable and filter orthogonality" do
    @describetag :integration

    setup do
      Nebu.Release.migrate()
      Ecto.Adapters.SQL.query!(Nebu.Repo, "DELETE FROM admin_temporary_captures", [])
      :ok
    end

    test "Disable now removes the row, reverts the node, and announces the disable" do
      {:ok, view, _html} = mount_trace_map()
      click_node(view, @off_health, "satellite")

      html =
        view
        |> element(~s([data-testid="trace-map-inspector-capture-toggle"]))
        |> render_click()
        |> parsed()

      result =
        Ecto.Adapters.SQL.query!(
          Nebu.Repo,
          "SELECT count(*) FROM admin_temporary_captures WHERE endpoint = $1 AND expires_at > now()",
          [@off_health]
        )

      assert result.rows == [[0]], "AC5: Disable now must end the capture server-side"

      node = node_locator(html, @off_health, "satellite")
      assert attr(node, "data-node-status") == "off"
      refute find(node, ~s([data-testid="trace-map-node-countdown"]))

      announcement = find(html, ~s([data-testid="trace-map-announcer"])) |> Floki.text()
      assert announcement =~ "Temporary capture disabled"
      assert announcement =~ @off_health
    end

    test "a second click while capturing toggles the filter; disable keeps the filter (AC7)" do
      {:ok, view, _html} = mount_trace_map()

      # First click: enable capture.
      click_node(view, @off_health, "satellite")

      # Second click: an ordinary filter toggle.
      html = click_node(view, @off_health, "satellite") |> parsed()

      assert find(html, ~s([data-testid="trace-map-filter-chip"][data-chip-value="#{@off_health}"])),
             "AC7: while capturing, a second click toggles the stream filter"

      assert attr(node_locator(html, @off_health, "satellite"), "data-node-status") == "temp",
             "AC7: the capture timer continues regardless of filter state"

      # Early disable must NOT clear the active filter (Known Challenge 4).
      html2 =
        view
        |> element(~s([data-testid="trace-map-inspector-capture-toggle"]))
        |> render_click()
        |> parsed()

      assert attr(node_locator(html2, @off_health, "satellite"), "data-node-status") == "off"

      assert find(
               html2,
               ~s([data-testid="trace-map-filter-chip"][data-chip-value="#{@off_health}"])
             ),
             "AC7: disabling capture must not remove the endpoint's filter chip"
    end
  end

  describe "AC5/AC6: capture survives reloads and auto-reverts on expiry (DB is the truth)" do
    @describetag :integration

    setup do
      Nebu.Release.migrate()
      Ecto.Adapters.SQL.query!(Nebu.Repo, "DELETE FROM admin_temporary_captures", [])
      :ok
    end

    test "a fresh mount renders an ALREADY-ACTIVE capture as temp (Known Challenge 2)" do
      Ecto.Adapters.SQL.query!(
        Nebu.Repo,
        "INSERT INTO admin_temporary_captures (endpoint, enabled_at, expires_at, started_by) " <>
          "VALUES ($1, now(), now() + interval '1 hour', 'e2e-precedent')",
        [@off_health]
      )

      {:ok, _view, html} = mount_trace_map()
      node = node_locator(parsed(html), @off_health, "satellite")

      assert attr(node, "data-node-status") == "temp",
             "a page opened during an active capture must render it capturing"

      assert find(node, ~s([data-testid="trace-map-node-countdown"]))
    end

    test "a fresh mount renders an EXPIRED capture row as off — expiry is a comparison, not a timer" do
      Ecto.Adapters.SQL.query!(
        Nebu.Repo,
        "INSERT INTO admin_temporary_captures (endpoint, enabled_at, expires_at, started_by) " <>
          "VALUES ($1, now() - interval '10 minutes', now() - interval '5 minutes', 'e2e-precedent')",
        [@off_health]
      )

      {:ok, _view, html} = mount_trace_map()
      node = node_locator(parsed(html), @off_health, "satellite")

      assert attr(node, "data-node-status") == "off",
             "AC5: an expired row means OFF, no cleanup pass required first"

      refute find(node, ~s([data-testid="trace-map-node-countdown"]))
    end

    test "expiry while the page is open auto-reverts the node and announces it" do
      # Env-config duration (ANSWERED design question 3): a 1-second capture
      # so the test waits ~1.2s, not 5 minutes.
      Application.put_env(:nebu, :temporary_capture_duration_s, 1)
      on_exit(fn -> Application.delete_env(:nebu, :temporary_capture_duration_s) end)

      {:ok, view, _html} = mount_trace_map()
      html = click_node(view, @off_health, "satellite") |> parsed()
      assert attr(node_locator(html, @off_health, "satellite"), "data-node-status") == "temp"

      Process.sleep(1_200)
      send(view.pid, :trace_map_tick)
      html2 = render(view) |> parsed()

      node = node_locator(html2, @off_health, "satellite")
      assert attr(node, "data-node-status") == "off", "AC5: auto-revert, no manual intervention"
      refute find(node, ~s([data-testid="trace-map-node-countdown"]))

      announcement = find(html2, ~s([data-testid="trace-map-announcer"])) |> Floki.text()
      assert announcement =~ "Temporary capture expired"
      assert announcement =~ @off_health
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC1/AC2: persistence, cascade, pre-population (requires Nebu.Repo)
  # ══════════════════════════════════════════════════════════════════════

  describe "AC1/AC2: configure_logging persists per-endpoint config via upsert_server_config" do
    @describetag :integration

    setup do
      Nebu.Release.migrate()

      Ecto.Adapters.SQL.query!(
        Nebu.Repo,
        "DELETE FROM server_config WHERE key LIKE 'log_min_level_%' OR key LIKE 'log_retention_days_%'",
        []
      )

      :ok
    end

    defp seed_log_row(route) do
      Ecto.Adapters.SQL.query!(
        Nebu.Repo,
        "INSERT INTO operational_logs (level, source, route_template, request_id, message, metadata) " <>
          "VALUES ('info', 'http', $1, $2, 'node-controls seed', '{}'::jsonb)",
        [route, "req-nc-" <> Integer.to_string(System.unique_integer([:positive]))]
      )
    end

    defp config_value(key) do
      result =
        Ecto.Adapters.SQL.query!(
          Nebu.Repo,
          "SELECT value FROM server_config WHERE key = $1",
          [key]
        )

      case result.rows do
        [[value]] -> value
        [] -> nil
      end
    end

    test "changing level+retention on a satellite writes that endpoint's two config keys" do
      seed_log_row("/admin/users")
      {:ok, view, _html} = mount_trace_map()
      click_node(view, "/admin/users", "satellite")

      render_change(view, "configure_logging", %{
        "node_key" => "/admin/users",
        "min_level" => "DEBUG",
        "retention_days" => "7"
      })

      assert config_value("log_min_level_/admin/users") == "debug",
             "AC1: the endpoint's min level must be persisted (Dev Notes key format)"

      assert config_value("log_retention_days_/admin/users") == "7",
             "AC2: the endpoint's retention window must be persisted"
    end

    test "the 1 d retention option maps to the stored day value \"1\" (amendment/test-review M1)" do
      seed_log_row("/admin/users")
      {:ok, view, _html} = mount_trace_map()
      click_node(view, "/admin/users", "satellite")

      render_change(view, "configure_logging", %{
        "node_key" => "/admin/users",
        "min_level" => "INFO",
        "retention_days" => "1"
      })

      assert config_value("log_retention_days_/admin/users") == "1",
             "amendment: the \"1 d\" option is day-granularity — stored as \"1\", " <>
               "completing the 1/7/30 mapping pins"
    end

    test "changing a domain's level cascades to every observed satellite and flashes the count" do
      seed_log_row("/admin/users")
      seed_log_row("/admin/rooms")

      {:ok, view, _html} = mount_trace_map()
      click_node(view, "/admin", "domain")

      render_change(view, "configure_logging", %{
        "node_key" => "/admin",
        "min_level" => "WARN",
        "retention_days" => "7"
      })

      assert config_value("log_min_level_/admin/users") == "warn",
             "AC1: the domain cascade must reach /admin/users"

      assert config_value("log_min_level_/admin/rooms") == "warn",
             "AC1: the domain cascade must reach /admin/rooms"

      # Deliberately NOT pinned to "2": the always-rendered off endpoint
      # /admin/keepalive may legitimately be part of the /admin cascade set
      # (its stored config applies whenever it is captured) — the dev agent
      # decides inclusion; the message just has to name a count.
      assert render(view) =~ ~r/Updated \d+ endpoints/,
             "AC1/AC11 Scenario B: the success message names the affected count"
    end

    test "the selects are pre-populated from server_config on inspect (AC1/AC2)" do
      seed_log_row("/admin/users")

      Ecto.Adapters.SQL.query!(
        Nebu.Repo,
        "INSERT INTO server_config (key, value, set_at) VALUES " <>
          "('log_min_level_/admin/users', 'error', extract(epoch from now())::bigint), " <>
          "('log_retention_days_/admin/users', '30', extract(epoch from now())::bigint) " <>
          "ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value",
        []
      )

      {:ok, view, _html} = mount_trace_map()
      html = click_node(view, "/admin/users", "satellite") |> parsed()

      level_select = find(html, ~s(select[data-testid="trace-map-inspector-level-select"]))
      selected_level = level_select |> Floki.find("option[selected]") |> Floki.text() |> String.trim()

      assert selected_level == "ERROR",
             "AC1: the level select must be pre-populated from the stored config"

      retention_select =
        find(html, ~s(select[data-testid="trace-map-inspector-retention-select"]))

      selected_retention =
        retention_select |> Floki.find("option[selected]") |> Floki.text() |> String.trim()

      assert selected_retention == "30 d",
             "AC2: the retention select must be pre-populated from the stored config"
    end

    # Kassandra security review (2026-07-08, MEDIUM): min_level/retention_days
    # arrive as client-controlled strings over the LiveView socket — a
    # crafted event bypasses the HTML <select>'s own option list entirely.
    # These two tests exercise that DIRECT `render_change/3` path (exactly
    # how a forged socket frame would look) and pin that invalid input is
    # REJECTED wholesale (no partial write), never silently clamped/coerced.
    test "an out-of-allowlist min_level is rejected — no config is persisted" do
      seed_log_row("/admin/users")
      {:ok, view, _html} = mount_trace_map()
      click_node(view, "/admin/users", "satellite")

      render_change(view, "configure_logging", %{
        "node_key" => "/admin/users",
        "min_level" => "TRACE",
        "retention_days" => "7"
      })

      refute config_value("log_min_level_/admin/users"),
             "a min_level outside the @ui_levels allowlist must not be persisted"

      refute config_value("log_retention_days_/admin/users"),
             "an invalid min_level must reject the WHOLE update — no partial write " <>
               "of the (otherwise valid) retention_days either"
    end

    test "an out-of-range retention_days is rejected — no config is persisted" do
      seed_log_row("/admin/users")
      {:ok, view, _html} = mount_trace_map()
      click_node(view, "/admin/users", "satellite")

      render_change(view, "configure_logging", %{
        "node_key" => "/admin/users",
        "min_level" => "DEBUG",
        "retention_days" => "9999"
      })

      refute config_value("log_retention_days_/admin/users"),
             "a retention_days outside the 1..90 day bound " <>
               "(Nebu.Admin.LogsController's own @days_bounds) must not be persisted"

      refute config_value("log_min_level_/admin/users"),
             "an invalid retention_days must reject the WHOLE update — no partial " <>
               "write of the (otherwise valid) min_level either"
    end

    test "a non-numeric retention_days is rejected — no config is persisted" do
      seed_log_row("/admin/users")
      {:ok, view, _html} = mount_trace_map()
      click_node(view, "/admin/users", "satellite")

      render_change(view, "configure_logging", %{
        "node_key" => "/admin/users",
        "min_level" => "WARN",
        "retention_days" => "not-a-number"
      })

      refute config_value("log_retention_days_/admin/users")
      refute config_value("log_min_level_/admin/users")
    end
  end
end
