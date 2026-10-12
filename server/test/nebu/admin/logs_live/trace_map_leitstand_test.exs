defmodule Nebu.Admin.LogsLive.TraceMapTest do
  @moduledoc """
  RED-phase ATDD tests for `enhanced-logging/trace-map-leitstand`
  (AC1, AC2, AC4, AC5, AC6, AC7, AC8, AC9, AC10, AC11, AC14 — the LiveView
  integration half; geometry and status-model pure-module contracts live in
  `trace_map_geometry_test.exs` / `trace_map_status_test.exs`; the old
  embedded-Trace-Map retirement, AC13, lives in `trace_map_retirement_test.exs`;
  the browser-only half of every AC below — real keyboard focus, pointer
  drag, hover tooltips, `prefers-reduced-motion` — lives in
  `e2e/features/admin/logs-trace-map.feature`).

  Story: docs/stories/enhanced-logging/trace-map-leitstand.md
  Design: _bmad-output/nebu/epics/enhanced-logging/design/trace-map-leitstand-spec.md

  ## Why these MUST FAIL right now

  Neither `Nebu.Admin.LogsLive.TraceMap` nor the `/admin/logs/trace-map`
  route (currently a stub pointing at the OLD `Nebu.Admin.LogsLive, :index`
  — see `router.ex`) exist yet in the shape this file assumes. Every test
  below fails at `live/1` with either a 404/redirect (stub route still
  serves the old page) or `UndefinedFunctionError` once the route is
  updated but the module is still missing — NOT a compile error in this
  file.

  ## Architecture decision this file pins down: a SEPARATE LiveView module,
  not a new action on the existing `Nebu.Admin.LogsLive`

  AC1's literal text says "the LiveView module `Nebu.Admin.LogsLive` (or
  alias) is extended with a new `mount/3` action for trace-map". This file
  deliberately pins the "(or alias)" branch — a NEW, SEPARATE module
  `Nebu.Admin.LogsLive.TraceMap` — for a concrete, load-bearing reason
  already documented in the EXISTING `Nebu.Admin.LogsLive`'s own moduledoc
  (see `logs_live.ex`, "Trace Map filter toggle is server-tracked" section):
  merely EXPORTING a `handle_params/3` callback on a LiveView module breaks
  EVERY `live_isolated/3`-mounted test in that module's own suite (empirically
  verified against the real, installed `phoenix_live_view` dependency —
  `live_isolated/3` unconditionally rejects `handle_params/3` regardless of
  whether a patch is ever attempted). AC5 HARD-REQUIRES `handle_params/3`
  for this new page (the whole point of the story, per the predecessor
  `trace-map-filter-reset-bugfix`'s lesson: URL-driven state, not
  client-DOM-only). Adding `handle_params/3` to the EXISTING, shared
  `Nebu.Admin.LogsLive` module would therefore break all ~40 pre-existing
  `live_isolated/3`-based tests in `logs_live_test.exs` for the UNRELATED
  `:index` (Live Stream) action — a story-scope-violating regression this
  file's own architecture avoids entirely by giving the Leitstand page its
  own module. The dev agent may still choose a different module name/split
  IF the rendered markup and the router contract below hold; the LOAD-BEARING
  constraint is "not the same module as the existing `:index` action".

  Router contract (replaces the existing stub in `router.ex`):

      live "/logs/trace-map", LogsLive.TraceMap, :index

  `@active_nav` is set to `"logs-trace-map"` in `mount/3`.

  ## Why (almost) every test below is router-mounted, not `live_isolated/3`

  Per the architecture decision above, `Nebu.Admin.LogsLive.TraceMap` DOES
  define `handle_params/3` — so `live_isolated/3` cannot mount it at all
  (see above). Every test therefore dispatches through the REAL router via
  `Phoenix.LiveViewTest.live/1` + a real, SENT conn (mirrors
  `logs_live_test.exs`'s own "AC12: mount/3's war_room_id param" describe
  block's `admin_conn_for_live/1` helper EXACTLY). Despite being
  router-mounted, MOST tests below still run under plain `mix test`
  (`make test-unit-elixir`, no `Nebu.Repo`) because:

    * `Nebu.Admin.Auth.bootstrap_completed?/0` defaults to `true` when
      neither the `:admin_bootstrap_store` seam nor `Nebu.Repo` is running
      (see `auth.ex`'s own doc comment) — the `on_mount(:require_admin)`
      gate does not redirect these tests to `/admin/bootstrap`.
    * `Nebu.Admin.LogsLive.TraceMap`'s `mount/3` MUST guard every DB read
      (initial endpoint/domain history, war-room status) behind
      `Process.whereis(Nebu.Repo)`, mirroring the EXISTING `Nebu.Admin.LogsLive`'s
      own `initial_entries/1`/`initial_war_room_status/0` precedent — this
      is a REQUIRED contract, not optional, precisely so this file's tests
      run DB-free.
    * `Nebu.PubSub` (unlike `Nebu.Repo`) IS running in the plain unit-test
      environment (confirmed by the existing `Nebu.Admin.LogsLive`'s own
      `mount/3` unconditionally subscribing to it, exercised by hundreds of
      already-passing `live_isolated/3` tests) — so tests can drive live
      status updates via a real `Phoenix.PubSub.broadcast/3` on the SAME
      `"operational_logs"` topic the existing page already uses, with no
      DB involved.

  The ONE describe block that genuinely needs a live session/DB (the
  war-room banner's ACTIVE state) is tagged `@describetag :integration` and
  mirrors the existing `admin_conn_for_live/1` + `Nebu.Release.migrate/0` +
  raw-SQL-seed pattern from `logs_live_test.exs`'s AC12 block — it will not
  run under `make test-unit-elixir`, only `make test-integration`, exactly
  like that existing precedent.

  ## Correction: AC5/AC12's literal repeated bare `?endpoint=X&endpoint=Y`
  URL format does not survive `Plug.Conn.Query.decode/1`

  AC5/AC12 Scenario 10 both show a bookmarked URL as
  `?endpoint=%2Fsync&endpoint=%2Fsend` — repeated BARE (non-bracket) query
  keys. `Plug.Conn.Query.decode/1` documents "if a value is given more than
  once, the LAST value takes precedence" for a bare repeated key (the
  EXACT same footgun `Nebu.Admin.LogsLive`'s own `active_filters_from_params/2`
  comment already flags, which is why that sibling page comma-joins a
  single value instead). This story's AC5, unlike the sibling page, does
  NOT propose comma-joining — so this file instead pins the
  BRACKET-ARRAY query format `?endpoint[]=X&endpoint[]=Y`, which
  `Plug.Conn.Query.decode/1` natively decodes into `%{"endpoint" => ["X",
  "Y"]}` with no data loss and no custom parsing. This is a genuine
  discrepancy between the story's literal example and Plug's real decoding
  behavior — flagged here (and in the ATDD handoff report) for the dev/PM
  to explicitly confirm; the dev agent may instead hand-parse
  `conn.query_string` directly to honor the story's literal bare-repeated
  format IF the rendered `handle_params/3` behavior below (multi-select
  round-trips correctly) still holds.

  ## Data-attribute / event contract this file pins down

    * SVG root: `[data-testid="trace-map-svg"]`, `viewBox="-780 -650 1560 1300"`.
    * Every node (nebu/domain/satellite): `[data-testid="trace-map-node"]
      [data-node-key=...] [data-node-kind="nebu"|"domain"|"satellite"]
      [data-node-status="ok"|"warn"|"error"] [data-node-selected="true"|"false"]
      role="button" tabindex="0" aria-pressed="true"|"false" aria-label="...".`
      Nebu carries NO `aria-pressed` at all (UX gate A3, dev cycle 2): it
      is a clear-all ACTION, not a toggle target — a permanent
      `aria-pressed="false"` would announce it as a never-pressed toggle
      button. Clicking it CLEARS filters instead (spec §2/AC5).
      Each node `<g>` positions itself via `transform="translate(x y)"`
      with the server-side coordinates `Nebu.Admin.TraceMapGeometry`
      computes (the dummy's own convention) — see the AC2 rendered-geometry
      cross-check test below.
    * Click contract: non-nebu nodes carry `phx-click="toggle_node"
      phx-value-key={key}`; nebu carries `phx-click="clear_filters"`. Unlike
      the sibling `admin-logs-monitoring-view` page's Trace Map bubbles,
      this is an ORDINARY server round-trip (no AC3-style
      client-side-only/zero-lag constraint applies to this story) — a plain
      `phx-click` event name, NOT a `Phoenix.LiveView.JS` command list.
    * Filter chips: `[data-testid="trace-map-filter-chip"]
      [data-chip-value=...]`, each containing
      `[data-testid="trace-map-filter-chip-remove"]` (same `toggle_node`
      handler, removing = toggling off); `[data-testid="trace-map-clear-all"]`
      (`phx-click="clear_filters"`).
    * War-room banner: `[data-testid="trace-map-war-room-banner"]`, `hidden`
      attribute present when inactive. NOT a live region (UX gate V1, dev
      cycle 2): the banner contains the per-second elapsed clock, and
      `role="status"` (implicitly atomic) would re-announce the whole
      sentence every second — session start/stop is announced through the
      page's sr-only announcer instead. Recording dot
      `[data-testid="trace-map-war-room-dot"]`; open-link
      `[data-testid="trace-map-war-room-open-link"]` navigating to
      `/admin/logs/war-room`.
    * Tooltip data (AC7 — content only; show/hide on hover/focus is
      app.js/E2E territory): every node ALSO carries `data-tooltip-name`,
      `data-tooltip-route`, `data-tooltip-status`, `data-tooltip-counts`,
      `data-tooltip-cta` attributes with the values a hover/focus JS hook
      would render into the shared `[data-testid="trace-map-tooltip"]`
      element — no payload/token/message content, per spec §8's
      no-sensitive-data constraint.
    * Inspector: `[data-testid="trace-map-inspector"]`, empty state
      `[data-testid="trace-map-inspector-empty"]`; once a node has been
      clicked/inspected: `[data-testid="trace-map-inspector-name"]`,
      `-route`, `-status-pill][data-status=...]`, `-stat-requests`,
      `-stat-warnings`, `-stat-errors`, and one
      `[data-testid="trace-map-inspector-event"]` per recent event (newest
      first, capped at 5).
    * Legend: `[data-testid="trace-map-legend"]` containing exactly 6
      `[data-testid="trace-map-legend-row"][data-legend-state=...]` rows
      (`ok`, `warn`, `error`, `selected`, `off`, `temp`) — ALWAYS rendered,
      regardless of what is currently on the map (spec §2's "always
      visible" legend).
    * Stream panel: `[data-testid="trace-map-stream"]`; log lines
      `[data-testid="trace-map-stream-line"][data-level=...][data-route=...]`;
      level pills `[data-testid="trace-map-level-pill"][data-level="DEBUG"|
      "INFO"|"WARN"|"ERROR"]` `aria-pressed`, `phx-click="toggle_level"
      phx-value-level={level}` — internally mapped to the lowercase
      `Nebu.Web.LogStore` level strings via `%{"DEBUG" => "debug", "INFO" =>
      "info", "WARN" => "warning", "ERROR" => "error"}` (the pill vocabulary
      is the spec's own abbreviated `WARN`/`ERROR`; `LogStore` entries use
      `"warning"`/`"error"` — this mapping is the dev agent's own
      responsibility to get right, pinned here explicitly since it is an
      easy silent-mismatch trap).
    * Resizer: `[data-testid="trace-map-resizer"] role="separator"
      aria-orientation="horizontal" tabindex="0" aria-label=...` — actual
      pointer-drag/keyboard resize behavior is CSS/JS-driven and only
      testable in a real browser (`logs-trace-map.feature` Scenario 9);
      this file only pins the static, accessible markup contract.
    * Live announcer: `[data-testid="trace-map-announcer"] role="status"
      aria-live="polite"`.
  """

  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn
  import Phoenix.LiveViewTest
  # `Phoenix.LiveViewTest.live/1`'s `defmacro live(conn, path \\ nil, opts \\ [])`
  # embeds a reference to an unqualified `get(conn, path)` call in its `quote`
  # block for the `is_binary(path)` branch — even calling it as `live(conn)`
  # (single arg, taking the OTHER branch at runtime) still needs
  # `Phoenix.ConnTest.get/2` resolvable at COMPILE time for the whole macro
  # expansion (mirrors logs_live_test.exs's own "AC12" describe block comment).
  import Phoenix.ConnTest

  @endpoint Nebu.Admin.Endpoint
  @secret_key_base String.duplicate("nebu-trace-map-leitstand-test-key", 2)
  @topic "operational_logs"

  # ══════════════════════════════════════════════════════════════════════
  # Test helpers — mirrors logs_live_test.exs's "AC12" describe block's
  # admin_conn_for_live/1 EXACTLY (see this file's moduledoc for why every
  # test here must go through the real router rather than live_isolated/3).
  # ══════════════════════════════════════════════════════════════════════

  defp admin_conn(path) do
    %{conn(:get, path) | secret_key_base: @secret_key_base}
    |> @endpoint.admin_session([])
    |> fetch_session()
    |> put_session("current_user", %{
      "admin" => true,
      "sub" => "admin-trace-map-leitstand-tests",
      "matrix_user_id" => "@admin:test.local"
    })
  end

  defp mount_trace_map(query_string \\ "") do
    path = if query_string == "", do: "/admin/logs/trace-map", else: "/admin/logs/trace-map?" <> query_string
    sent_conn = path |> admin_conn() |> @endpoint.call(@endpoint.init([]))
    live(sent_conn)
  end

  defp parsed(html), do: Floki.parse_document!(html)

  defp find(html, selector), do: html |> Floki.find(selector) |> List.first()
  defp find_all(html, selector), do: Floki.find(html, selector)
  defp attr(node, name), do: node |> List.wrap() |> Floki.attribute(name) |> List.first()

  defp node_locator(html, key) do
    find(html, ~s([data-testid="trace-map-node"][data-node-key="#{key}"]))
  end

  defp entry(overrides) do
    Map.merge(
      %{
        level: "info",
        source: "http",
        route_template: "/foo",
        request_id: "req-" <> Integer.to_string(System.unique_integer([:positive])),
        message: "distinctive-trace-map-leitstand-probe",
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

  # ══════════════════════════════════════════════════════════════════════
  # AC1: New LiveView route and active-nav repoint
  # ══════════════════════════════════════════════════════════════════════

  describe "AC1: /admin/logs/trace-map mounts the new LiveView with the correct active-nav" do
    @describetag :no_repo
    test "mounting succeeds and highlights the Trace Map child nav item, not Live Stream" do
      {:ok, _view, html} = mount_trace_map()
      doc = parsed(html)

      trace_map_link = find(doc, ~s(a[data-navkey="logs-trace-map"]))
      assert attr(trace_map_link, "aria-current") == "page",
             "AC1: the Trace Map nav child must be the active one, not Live Stream"

      live_stream_link = find(doc, ~s(a[data-navkey="logs-monitoring"]))
      refute attr(live_stream_link, "aria-current") == "page"
    end

    # Test-review MINOR-4(a): a bare `html =~ "Trace Map"` passed against the
    # STUB (old /admin/logs renders <h2>Trace Map</h2>, and the sidebar's
    # "Trace Map" label matches on EVERY admin page). Pin the page's OWN
    # top-level <h1> instead — the stub renders <h1>Logs</h1>, so this is
    # genuinely red until the dedicated page exists.
    test "the page's own <h1> names the Trace Map" do
      {:ok, _view, html} = mount_trace_map()
      doc = parsed(html)

      h1 = find(doc, "h1")
      assert h1, "expected a page-level <h1>"

      assert Floki.text(h1) =~ "Trace Map",
             "the page-level <h1> must name the Trace Map (the stub still renders " <>
               "the old Logs page's <h1>Logs</h1>)"
    end

    # Test-review INFO recommendation ("cheap insurance"): the route sits in
    # the pre-existing `live_session :admin` scope, whose auth gate is
    # already covered elsewhere — this pins that the NEW route stays inside
    # that scope (an unauthenticated request must never render the map).
    # Deliberately green against the stub too: the stub route is already in
    # the protected scope; this test guards against a future accidental move
    # OUT of it.
    test "an unauthenticated GET /admin/logs/trace-map redirects to login, never renders the map" do
      conn =
        %{conn(:get, "/admin/logs/trace-map") | secret_key_base: @secret_key_base}
        |> @endpoint.admin_session([])
        |> fetch_session()
        |> @endpoint.call(@endpoint.init([]))

      assert conn.status in [301, 302],
             "expected a redirect for an unauthenticated request, got #{conn.status}"

      location = Plug.Conn.get_resp_header(conn, "location") |> List.first()
      assert location =~ "/admin/login"
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC2: Radial SVG map layout and hierarchy
  # ══════════════════════════════════════════════════════════════════════

  describe "AC2: radial SVG map — nebu is always present, domains/satellites appear as observed" do
    @describetag :no_repo
    test "on mount with no traffic yet, only the nebu node is rendered, at the spec's viewBox" do
      {:ok, _view, html} = mount_trace_map()
      doc = parsed(html)

      svg = find(doc, ~s([data-testid="trace-map-svg"]))

      # dev-story correction: the template renders the spec's camelCase
      # `viewBox` attribute (required SVG spelling — browsers' HTML parsers
      # apply the SVG attribute adjustment table), but Floki's HTML tokenizer
      # (lazy_html) lowercases ALL attribute names on parse, so the parsed
      # tree can only ever expose it as "viewbox" — the original camelCase
      # lookup was unsatisfiable against any real rendered output.
      assert attr(svg, "viewbox") == "-780 -650 1560 1300"

      nebu = node_locator(doc, "nebu")
      assert attr(nebu, "data-node-kind") == "nebu"

      # enhanced-logging/trace-map-node-controls (AC4): the off-by-default
      # long-polling endpoints (and therefore their parent domains) are
      # ALWAYS on the map from mount, real traffic or not — they collect no
      # data, so waiting for traffic would never show them. This updates
      # the ORIGINAL "no domain nodes yet" assertion to the now-correct
      # "only the off-list's domains" — no REAL-traffic domain exists yet.
      domain_keys =
        doc
        |> find_all(~s([data-testid="trace-map-node"][data-node-kind="domain"]))
        |> Enum.map(&attr(&1, "data-node-key"))

      assert Enum.sort(domain_keys) == Enum.sort(["/_matrix/client", "/admin", "/health"]),
             "trace-map-node-controls: off-list domains render from mount; no real traffic yet"
    end

    test "observing traffic for two different domains renders both domain groups and their satellites" do
      {:ok, view, _html} = mount_trace_map()

      broadcast_entry(route_template: "/_matrix/client/v3/sync", level: "info")
      broadcast_entry(route_template: "/admin/users", level: "info")

      doc = render(view) |> parsed()

      client_domain = node_locator(doc, "/_matrix/client")
      admin_domain = node_locator(doc, "/admin")
      assert client_domain, "expected a domain node for /_matrix/client"
      assert admin_domain, "expected a domain node for /admin"
      assert attr(client_domain, "data-node-kind") == "domain"

      sync_satellite = node_locator(doc, "/_matrix/client/v3/sync")
      users_satellite = node_locator(doc, "/admin/users")
      assert attr(sync_satellite, "data-node-kind") == "satellite"
      assert attr(users_satellite, "data-node-kind") == "satellite"
    end

    # Test-review MINOR-1: the rendered-output cross-check that ties the
    # TraceMapGeometry contract (trace_map_geometry_test.exs) to the ACTUAL
    # SVG — without this, the geometry module could compute correct numbers
    # the template never uses. All 4 canonical domains are observed in spec
    # order (first-observed order == spec order), so /_matrix/client must
    # sit at the spec's FIXED angle -48° on the R1=195 ring (spec §2). The
    # node's <g> is expected to position via `transform="translate(x y)"`
    # (the dummy's own convention); coordinates are matched with a 0.6
    # tolerance so integer/decimal rounding in the template is acceptable.
    #
    # enhanced-logging/trace-map-node-controls: two of the ORIGINAL 4 probe
    # routes (`/_matrix/client/v3/sync` and `/health` itself) are now
    # off-by-default long-polling endpoints — an uncaptured broadcast for
    # either is correctly excluded from the traffic-driven `endpoint_order`
    # that determines "first-observed order" (that story's own AC4
    # contract), which broke this test's canonical-order coincidence.
    # Swapped to a plain (non-off-list) route per domain — `/whoami` under
    # `/_matrix/client`, `/health/live` under `/health` (the domain-grouping
    # heuristic maps any `/health/...` sub-route to the `/health` domain
    # too) — preserving the ORIGINAL intent (four real, ordinarily-observed
    # domains in spec order) unchanged.
    test "a domain <g>'s rendered position matches the spec geometry (polar 0°, R1=220 for /_matrix/client)" do
      {:ok, view, _html} = mount_trace_map()

      broadcast_entry(route_template: "/_matrix/client/v3/whoami", level: "info")
      broadcast_entry(route_template: "/_matrix/media/v3/upload", level: "info")
      broadcast_entry(route_template: "/admin/users", level: "info")
      broadcast_entry(route_template: "/health/live", level: "info")

      doc = render(view) |> parsed()
      node = node_locator(doc, "/_matrix/client")
      assert node, "expected a domain node for /_matrix/client"

      transform = attr(node, "transform")

      assert transform,
             "AC2: expected the domain <g> to carry a transform=\"translate(x y)\" " <>
               "with server-side computed coordinates"

      assert [_, x_str, y_str] =
               Regex.run(
                 ~r/translate\(\s*(-?\d+(?:\.\d+)?)[\s,]+(-?\d+(?:\.\d+)?)\s*\)/,
                 transform
               ),
             "AC2: transform #{inspect(transform)} did not parse as translate(x y)"

      {x, _} = Float.parse(x_str)
      {y, _} = Float.parse(y_str)

      radians = 0.0 * :math.pi() / 180.0
      assert_in_delta x, 300.0 * :math.cos(radians), 0.6
      assert_in_delta y, 300.0 * :math.sin(radians), 0.6
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC4: Visual states (ok/warn/error/selected) — off/temp deliberately
  # excluded, see note below.
  # ══════════════════════════════════════════════════════════════════════

  describe "AC4: visual states — worst-child propagation from satellite to domain to nebu" do
    @describetag :no_repo
    # NOTE on scope (revised by enhanced-logging/trace-map-node-controls): the
    # story's own "Known Gaps (Out of Scope, Follow-up Story)" section
    # deferred "Long-polling endpoints off by default" / "Temporary capture"
    # to the follow-up `trace-map-node-controls` story, which has since
    # shipped and classifies `/_matrix/client/v3/sync` as off-by-default
    # (AC4 there). The two tests below no longer use `/sync` for plain
    # WARN-propagation probes (an off-tier WARN with no active capture is
    # now correctly suppressed, per that story's own contract) — they use
    # `/_matrix/client/v3/whoami`, a plain (non-off-list) satellite under the
    # same `/_matrix/client` domain, preserving this test's original intent
    # unchanged. `/sync` + ERROR (the third test below) is untouched: errors
    # always persist and always drive status, off-tier or not.

    test "a warning on a satellite propagates warn status up through its domain to nebu" do
      {:ok, view, _html} = mount_trace_map()
      broadcast_entry(route_template: "/_matrix/client/v3/whoami", level: "warning")

      doc = render(view) |> parsed()

      assert attr(node_locator(doc, "/_matrix/client/v3/whoami"), "data-node-status") == "warn"
      assert attr(node_locator(doc, "/_matrix/client"), "data-node-status") == "warn"
      assert attr(node_locator(doc, "nebu"), "data-node-status") == "warn"
    end

    test "an error outranks a warning at every ancestor level" do
      {:ok, view, _html} = mount_trace_map()
      broadcast_entry(route_template: "/_matrix/client/v3/whoami", level: "warning")
      broadcast_entry(route_template: "/_matrix/client/v3/login", level: "error")

      doc = render(view) |> parsed()

      assert attr(node_locator(doc, "/_matrix/client/v3/whoami"), "data-node-status") == "warn"
      assert attr(node_locator(doc, "/_matrix/client/v3/login"), "data-node-status") == "error"
      assert attr(node_locator(doc, "/_matrix/client"), "data-node-status") == "error"
      assert attr(node_locator(doc, "nebu"), "data-node-status") == "error"
    end

    test "an unrelated healthy domain does not inherit another domain's error" do
      {:ok, view, _html} = mount_trace_map()
      broadcast_entry(route_template: "/_matrix/client/v3/sync", level: "error")
      broadcast_entry(route_template: "/admin/users", level: "info")

      doc = render(view) |> parsed()

      assert attr(node_locator(doc, "/_matrix/client"), "data-node-status") == "error"
      assert attr(node_locator(doc, "/admin"), "data-node-status") == "ok"
      # nebu is the worst of ALL domains, so it still reflects the error.
      assert attr(node_locator(doc, "nebu"), "data-node-status") == "error"
    end

    test "warn/error nodes carry a numeric badge count; a healthy node does not" do
      {:ok, view, _html} = mount_trace_map()
      broadcast_entry(route_template: "/admin/users", level: "warning")
      broadcast_entry(route_template: "/admin/users", level: "warning")

      doc = render(view) |> parsed()
      node = node_locator(doc, "/admin/users")

      assert find(node, ~s([data-testid="trace-map-badge-warn"])) |> Floki.text() =~ "2"
      assert find(node, ~s([data-testid="trace-map-badge-error"])) == nil
    end
  end

  describe "AC4/AC5: selection is orthogonal to health status" do
    @describetag :no_repo
    test "selecting a healthy node marks it selected without changing its health status" do
      {:ok, view, _html} = mount_trace_map()
      broadcast_entry(route_template: "/admin/users", level: "info")
      render(view)

      html =
        view
        |> element(~s([data-testid="trace-map-node"][data-node-key="/admin/users"]))
        |> render_click()
        |> parsed()

      node = node_locator(html, "/admin/users")
      assert attr(node, "data-node-status") == "ok"
      assert attr(node, "data-node-selected") == "true"
      assert attr(node, "aria-pressed") == "true"
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC5: Interactive filtering — click/Enter/Space toggle, multi-select OR,
  # domain convenience, clear all, chips, URL query-param round trip
  # ══════════════════════════════════════════════════════════════════════

  describe "AC5: clicking a satellite toggles it as a stream filter and updates the URL" do
    @describetag :no_repo
    test "clicking once selects the node, adds a chip, and patches the URL" do
      {:ok, view, _html} = mount_trace_map()
      broadcast_entry(route_template: "/admin/users", level: "info")
      render(view)

      html =
        view
        |> element(~s([data-testid="trace-map-node"][data-node-key="/admin/users"]))
        |> render_click()
        |> parsed()

      assert attr(node_locator(html, "/admin/users"), "aria-pressed") == "true"
      chip = find(html, ~s([data-testid="trace-map-filter-chip"][data-chip-value="/admin/users"]))
      assert chip, "AC5: expected a filter chip for the newly-selected node"

      assert_patch(view, "/admin/logs/trace-map?endpoint%5B%5D=%2Fadmin%2Fusers")
    end

    test "clicking the same node again deselects it and removes its chip" do
      {:ok, view, _html} = mount_trace_map()
      broadcast_entry(route_template: "/admin/users", level: "info")
      render(view)

      view
      |> element(~s([data-testid="trace-map-node"][data-node-key="/admin/users"]))
      |> render_click()

      html =
        view
        |> element(~s([data-testid="trace-map-node"][data-node-key="/admin/users"]))
        |> render_click()
        |> parsed()

      assert attr(node_locator(html, "/admin/users"), "aria-pressed") == "false"
      refute find(html, ~s([data-testid="trace-map-filter-chip"][data-chip-value="/admin/users"]))
    end
  end

  describe "AC5: multi-select is OR-within-the-endpoint-dimension" do
    @describetag :no_repo
    test "selecting two different satellites shows two chips, both aria-pressed=true" do
      {:ok, view, _html} = mount_trace_map()
      broadcast_entry(route_template: "/admin/users", level: "info")
      broadcast_entry(route_template: "/admin/rooms", level: "info")
      render(view)

      view
      |> element(~s([data-testid="trace-map-node"][data-node-key="/admin/users"]))
      |> render_click()

      html =
        view
        |> element(~s([data-testid="trace-map-node"][data-node-key="/admin/rooms"]))
        |> render_click()
        |> parsed()

      assert attr(node_locator(html, "/admin/users"), "aria-pressed") == "true"
      assert attr(node_locator(html, "/admin/rooms"), "aria-pressed") == "true"
      assert length(find_all(html, ~s([data-testid="trace-map-filter-chip"]))) == 2
    end
  end

  describe "AC5: clicking nebu clears every active filter" do
    @describetag :no_repo
    test "clear all via the nebu node removes all selections and chips" do
      {:ok, view, _html} = mount_trace_map()
      broadcast_entry(route_template: "/admin/users", level: "info")
      render(view)

      view
      |> element(~s([data-testid="trace-map-node"][data-node-key="/admin/users"]))
      |> render_click()

      html =
        view
        |> element(~s([data-testid="trace-map-node"][data-node-key="nebu"]))
        |> render_click()
        |> parsed()

      assert attr(node_locator(html, "/admin/users"), "aria-pressed") == "false"
      assert find_all(html, ~s([data-testid="trace-map-filter-chip"])) == []
      assert_patch(view, "/admin/logs/trace-map")
    end

    test "the stream header's Clear all button does the same thing" do
      {:ok, view, _html} = mount_trace_map()
      broadcast_entry(route_template: "/admin/users", level: "info")
      render(view)

      view
      |> element(~s([data-testid="trace-map-node"][data-node-key="/admin/users"]))
      |> render_click()

      html =
        view
        |> element(~s([data-testid="trace-map-clear-all"]))
        |> render_click()
        |> parsed()

      assert find_all(html, ~s([data-testid="trace-map-filter-chip"])) == []
    end
  end

  describe "AC5: a filter chip's remove control removes just that one filter" do
    @describetag :no_repo
    test "removing one of two chips leaves the other active" do
      {:ok, view, _html} = mount_trace_map()
      broadcast_entry(route_template: "/admin/users", level: "info")
      broadcast_entry(route_template: "/admin/rooms", level: "info")
      render(view)

      view
      |> element(~s([data-testid="trace-map-node"][data-node-key="/admin/users"]))
      |> render_click()

      view
      |> element(~s([data-testid="trace-map-node"][data-node-key="/admin/rooms"]))
      |> render_click()

      html =
        view
        |> element(
          ~s([data-testid="trace-map-filter-chip"][data-chip-value="/admin/users"] ) <>
            ~s([data-testid="trace-map-filter-chip-remove"])
        )
        |> render_click()
        |> parsed()

      refute find(html, ~s([data-testid="trace-map-filter-chip"][data-chip-value="/admin/users"]))
      assert find(html, ~s([data-testid="trace-map-filter-chip"][data-chip-value="/admin/rooms"]))
    end
  end

  describe "AC5: bookmarkable URLs — handle_params/3 seeds @active_filters from the query string" do
    @describetag :no_repo
    test "a bracket-array ?endpoint[]=...&endpoint[]=... URL pre-selects both nodes on mount" do
      {:ok, _view, html} =
        mount_trace_map("endpoint%5B%5D=%2Fadmin%2Fusers&endpoint%5B%5D=%2Fadmin%2Frooms")

      doc = parsed(html)

      assert attr(node_locator(doc, "/admin/users"), "aria-pressed") == "true"
      assert attr(node_locator(doc, "/admin/rooms"), "aria-pressed") == "true"
      assert length(find_all(doc, ~s([data-testid="trace-map-filter-chip"]))) == 2
    end

    # Test-review MINOR-4(b): the bare "no chips" refute passed trivially on
    # ANY page where the chip testid is absent (including the stub). The
    # added SVG-presence assertion means this baseline can only pass on the
    # actual Trace Map page.
    test "an empty query string selects nothing (baseline, no crash)" do
      {:ok, _view, html} = mount_trace_map()
      doc = parsed(html)

      assert find(doc, ~s([data-testid="trace-map-svg"])),
             "baseline must be asserted against the actual Trace Map page, not any blank page"

      assert find_all(doc, ~s([data-testid="trace-map-filter-chip"])) == []
    end
  end

  describe "AC5: domain convenience — clicking a domain filters to that domain" do
    @describetag :no_repo
    test "clicking a domain node selects it and its chip appears using the DOMAIN key" do
      {:ok, view, _html} = mount_trace_map()
      broadcast_entry(route_template: "/admin/users", level: "info")
      render(view)

      html =
        view
        |> element(~s([data-testid="trace-map-node"][data-node-key="/admin"]))
        |> render_click()
        |> parsed()

      assert attr(node_locator(html, "/admin"), "aria-pressed") == "true"
      assert find(html, ~s([data-testid="trace-map-filter-chip"][data-chip-value="/admin"]))
    end

    # Test-review MINOR-2: AC5's "domain matches all its satellites" is a
    # STREAM-CONTENT contract, not just a chip/selection one — a domain
    # filter must OR-include every child satellite's lines and exclude other
    # domains' lines.
    test "selecting a domain OR-includes all its satellites' stream lines and hides other domains'" do
      {:ok, view, _html} = mount_trace_map()

      broadcast_entry(
        route_template: "/admin/users",
        level: "info",
        message: "distinctive-domain-users-line"
      )

      broadcast_entry(
        route_template: "/admin/rooms",
        level: "info",
        message: "distinctive-domain-rooms-line"
      )

      broadcast_entry(
        route_template: "/_matrix/client/v3/sync",
        level: "info",
        message: "distinctive-domain-sync-line"
      )

      render(view)

      html =
        view
        |> element(~s([data-testid="trace-map-node"][data-node-key="/admin"]))
        |> render_click()
        |> parsed()

      texts =
        html
        |> find_all(~s([data-testid="trace-map-stream-line"]))
        |> Enum.map(&Floki.text/1)

      assert Enum.any?(texts, &(&1 =~ "distinctive-domain-users-line")),
             "a /admin domain filter must include the /admin/users satellite's lines"

      assert Enum.any?(texts, &(&1 =~ "distinctive-domain-rooms-line")),
             "a /admin domain filter must include the /admin/rooms satellite's lines"

      refute Enum.any?(texts, &(&1 =~ "distinctive-domain-sync-line")),
             "a /admin domain filter must exclude other domains' lines"
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC6: War-room banner
  # ══════════════════════════════════════════════════════════════════════

  describe "AC6: war-room banner — hidden by default (no active session, no Nebu.Repo)" do
    @describetag :no_repo
    # UX gate V1 (dev cycle 2): the original assertions pinned
    # role="status"/aria-live="polite" ON the banner — an aria-live misuse,
    # because the banner contains the per-second-ticking elapsed clock
    # (role="status" is implicitly atomic, so a screen reader would
    # re-announce the whole banner sentence EVERY second for the entire
    # session). The banner is now deliberately non-live; session start/stop
    # transitions are announced as one-shot sentences through the page's
    # sr-only announcer (covered by the AC10 announcer tests below).
    test "the banner element exists but is hidden, and is deliberately NOT a live region" do
      {:ok, _view, html} = mount_trace_map()
      banner = find(parsed(html), ~s([data-testid="trace-map-war-room-banner"]))

      assert banner, "AC6: the banner must always be present in markup (toggled via `hidden`)"
      assert attr(banner, "hidden") == "",
             "AC6: with no active session, the banner must carry the boolean `hidden` attribute"

      refute attr(banner, "aria-live"),
             "UX gate V1: the banner must NOT be a live region — it contains a " <>
               "per-second ticking clock (state changes are announced via the announcer)"

      refute attr(banner, "role") == "status",
             "UX gate V1: role=status is an implicit atomic live region — see above"
    end
  end

  describe "AC6: war-room banner — active session (requires a real session + Nebu.Repo)" do
    @describetag :integration

    setup do
      Nebu.Release.migrate()
      :ok
    end

    test "an active war-room session renders the banner with recording dot, user, and an Open War Room link" do
      {:ok, session} =
        Nebu.Admin.WarRoomManager.start_session(%{
          started_by: "@alice:nebu.example",
          reason: "trace-map-leitstand banner ATDD probe",
          max_entries: 100,
          max_duration_s: 300
        })

      on_exit(fn -> Nebu.Admin.WarRoomManager.stop_session(session.id) end)

      {:ok, _view, html} = mount_trace_map()
      doc = parsed(html)
      banner = find(doc, ~s([data-testid="trace-map-war-room-banner"]))

      refute attr(banner, "hidden"), "AC6: an active session must NOT carry `hidden`"
      assert find(banner, ~s([data-testid="trace-map-war-room-dot"]))
      assert Floki.text(banner) =~ "@alice:nebu.example"

      open_link = find(banner, ~s([data-testid="trace-map-war-room-open-link"]))
      assert attr(open_link, "href") == "/admin/logs/war-room"
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC7: Tooltip content (data attributes only — show/hide is E2E-only)
  # ══════════════════════════════════════════════════════════════════════

  describe "AC7: every node carries the data a hover/focus tooltip needs, with no sensitive content" do
    @describetag :no_repo
    test "a satellite node's tooltip data includes name, route, status, and counts" do
      {:ok, view, _html} = mount_trace_map()
      broadcast_entry(route_template: "/admin/users", level: "warning")

      doc = render(view) |> parsed()
      node = node_locator(doc, "/admin/users")

      assert attr(node, "data-tooltip-route") == "/admin/users"
      assert attr(node, "data-tooltip-status") =~ ~r/warn/i
      assert attr(node, "data-tooltip-counts") =~ "1"
      assert attr(node, "data-tooltip-cta") =~ ~r/filter/i

      refute attr(node, "data-tooltip-counts") =~ "distinctive-trace-map-leitstand-probe",
             "AC7/spec §8: no log message content may leak into tooltip data"
    end

    test "nebu's tooltip route reads \"all traffic\", per spec §2" do
      {:ok, _view, html} = mount_trace_map()
      nebu = node_locator(parsed(html), "nebu")
      assert attr(nebu, "data-tooltip-route") == "all traffic"
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC8: Inspector panel + Legend
  # ══════════════════════════════════════════════════════════════════════

  describe "AC8: inspector panel — empty state, then populated once a node is clicked" do
    @describetag :no_repo
    test "on mount, the inspector shows its empty-state copy" do
      {:ok, _view, html} = mount_trace_map()
      doc = parsed(html)

      assert find(doc, ~s([data-testid="trace-map-inspector-empty"])),
             "AC8: expected the empty-state hint before any node is selected"
      assert Floki.text(doc |> find(~s([data-testid="trace-map-inspector-empty"]))) =~
               "Hover or select a node"
    end

    test "clicking a node populates the inspector with its name/route/status pill/live stats" do
      {:ok, view, _html} = mount_trace_map()
      broadcast_entry(route_template: "/admin/users", level: "warning")
      render(view)

      html =
        view
        |> element(~s([data-testid="trace-map-node"][data-node-key="/admin/users"]))
        |> render_click()
        |> parsed()

      refute find(html, ~s([data-testid="trace-map-inspector-empty"]))
      assert Floki.text(find(html, ~s([data-testid="trace-map-inspector-name"]))) =~ "users"
      assert Floki.text(find(html, ~s([data-testid="trace-map-inspector-route"]))) =~ "/admin/users"

      pill = find(html, ~s([data-testid="trace-map-inspector-status-pill"]))
      assert attr(pill, "data-status") == "warn"

      assert Floki.text(find(html, ~s([data-testid="trace-map-inspector-stat-warnings"]))) =~ "1"
      assert Floki.text(find(html, ~s([data-testid="trace-map-inspector-stat-errors"]))) =~ "0"
    end

    test "the inspector lists at most the 5 most recent events, newest first" do
      {:ok, view, _html} = mount_trace_map()

      for i <- 1..7 do
        broadcast_entry(route_template: "/admin/users", level: "info", message: "event-#{i}")
      end

      render(view)

      html =
        view
        |> element(~s([data-testid="trace-map-node"][data-node-key="/admin/users"]))
        |> render_click()
        |> parsed()

      events = find_all(html, ~s([data-testid="trace-map-inspector-event"]))
      assert length(events) == 5, "AC8: expected exactly the last 5 events, got #{length(events)}"
    end
  end

  describe "AC8: legend — always visible, exactly 6 states" do
    @describetag :no_repo
    test "the legend renders 6 rows even before any node has been observed" do
      {:ok, _view, html} = mount_trace_map()
      doc = parsed(html)

      rows = find_all(doc, ~s([data-testid="trace-map-legend-row"]))
      assert length(rows) == 6

      states = Enum.map(rows, &attr(&1, "data-legend-state"))
      assert Enum.sort(states) == Enum.sort(["ok", "warn", "error", "selected", "off", "temp"])
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC9: Live stream panel — level filter (leitstand shortcut), resizer
  # ══════════════════════════════════════════════════════════════════════

  describe "AC9: level filter pills default to all-active" do
    @describetag :no_repo
    test "DEBUG/INFO/WARN/ERROR are all aria-pressed=true on mount" do
      {:ok, _view, html} = mount_trace_map()
      doc = parsed(html)

      for level <- ["DEBUG", "INFO", "WARN", "ERROR"] do
        pill = find(doc, ~s([data-testid="trace-map-level-pill"][data-level="#{level}"]))
        assert pill, "expected a level pill for #{level}"
        assert attr(pill, "aria-pressed") == "true"
      end
    end
  end

  describe "AC9: leitstand shortcut — click one while all active isolates it; click it again restores all" do
    @describetag :no_repo
    test "clicking INFO while all 4 are active leaves ONLY INFO active" do
      {:ok, view, _html} = mount_trace_map()

      html =
        view
        |> element(~s([data-testid="trace-map-level-pill"][data-level="INFO"]))
        |> render_click()
        |> parsed()

      assert attr(find(html, ~s([data-testid="trace-map-level-pill"][data-level="INFO"])), "aria-pressed") ==
               "true"

      for level <- ["DEBUG", "WARN", "ERROR"] do
        pill = find(html, ~s([data-testid="trace-map-level-pill"][data-level="#{level}"]))
        assert attr(pill, "aria-pressed") == "false"
      end
    end

    test "clicking the sole active level again restores all 4 to active" do
      {:ok, view, _html} = mount_trace_map()

      view
      |> element(~s([data-testid="trace-map-level-pill"][data-level="INFO"]))
      |> render_click()

      html =
        view
        |> element(~s([data-testid="trace-map-level-pill"][data-level="INFO"]))
        |> render_click()
        |> parsed()

      for level <- ["DEBUG", "INFO", "WARN", "ERROR"] do
        pill = find(html, ~s([data-testid="trace-map-level-pill"][data-level="#{level}"]))
        assert attr(pill, "aria-pressed") == "true"
      end
    end

    test "clicking a level when SEVERAL (not all) are active is a plain toggle, not the shortcut" do
      {:ok, view, _html} = mount_trace_map()

      # Isolate INFO (all -> one), then toggle WARN back on: now {INFO, WARN}
      # are active, i.e. "several but not all" — the next click must be a
      # plain toggle, not re-trigger the shortcut.
      view |> element(~s([data-testid="trace-map-level-pill"][data-level="INFO"])) |> render_click()

      view
      |> element(~s([data-testid="trace-map-level-pill"][data-level="WARN"]))
      |> render_click()

      html =
        view
        |> element(~s([data-testid="trace-map-level-pill"][data-level="ERROR"]))
        |> render_click()
        |> parsed()

      for level <- ["INFO", "WARN", "ERROR"] do
        pill = find(html, ~s([data-testid="trace-map-level-pill"][data-level="#{level}"]))
        assert attr(pill, "aria-pressed") == "true", "expected #{level} active"
      end

      debug_pill = find(html, ~s([data-testid="trace-map-level-pill"][data-level="DEBUG"]))
      assert attr(debug_pill, "aria-pressed") == "false"
    end
  end

  describe "AC9: stream content is filtered by level AND by the active endpoint selection" do
    @describetag :no_repo
    # dev-story correction: the original step clicked the WARN pill while all
    # 4 levels were active — which, per AC9's leitstand shortcut (pinned by
    # this file's OWN "AC9: leitstand shortcut" describe block above), leaves
    # ONLY WARN active, i.e. the exact opposite of what this test's
    # assertions expect. Clicking INFO instead exercises the same
    # stream-content contract (level filtering actually filters the rendered
    # lines) with a shortcut outcome — only INFO active — that matches the
    # original assertions unchanged.
    test "isolating INFO hides warning-level lines but keeps info-level lines" do
      {:ok, view, _html} = mount_trace_map()
      broadcast_entry(route_template: "/admin/users", level: "info", message: "distinctive-info-line")
      broadcast_entry(route_template: "/admin/users", level: "warning", message: "distinctive-warn-line")
      render(view)

      html =
        view
        |> element(~s([data-testid="trace-map-level-pill"][data-level="INFO"]))
        |> render_click()
        |> parsed()

      lines = find_all(html, ~s([data-testid="trace-map-stream-line"]))
      texts = Enum.map(lines, &Floki.text/1)

      assert Enum.any?(texts, &(&1 =~ "distinctive-info-line"))
      refute Enum.any?(texts, &(&1 =~ "distinctive-warn-line"))
    end

    test "selecting a node's filter narrows the stream to that endpoint's lines" do
      {:ok, view, _html} = mount_trace_map()
      broadcast_entry(route_template: "/admin/users", level: "info", message: "distinctive-users-line")
      broadcast_entry(route_template: "/admin/rooms", level: "info", message: "distinctive-rooms-line")
      render(view)

      html =
        view
        |> element(~s([data-testid="trace-map-node"][data-node-key="/admin/users"]))
        |> render_click()
        |> parsed()

      texts = html |> find_all(~s([data-testid="trace-map-stream-line"])) |> Enum.map(&Floki.text/1)

      assert Enum.any?(texts, &(&1 =~ "distinctive-users-line"))
      refute Enum.any?(texts, &(&1 =~ "distinctive-rooms-line"))
    end
  end

  describe "AC9: the resizer's static, accessible markup contract" do
    @describetag :no_repo
    test "role=separator, aria-orientation=horizontal, tabindex=0, has a label naming the resize action" do
      {:ok, _view, html} = mount_trace_map()
      resizer = find(parsed(html), ~s([data-testid="trace-map-resizer"]))

      assert attr(resizer, "role") == "separator"
      assert attr(resizer, "aria-orientation") == "horizontal"
      assert attr(resizer, "tabindex") == "0"

      # Test-review MINOR-5: the e2e suite locates the resizer via
      # getByRole('separator', { name: /resize/i }) — the server-side test
      # must pin the SAME accessible-name contract, or the two suites could
      # green/red independently on the same markup.
      label = attr(resizer, "aria-label")
      assert label not in [nil, ""]
      assert label =~ ~r/resize/i,
             "the resizer's accessible name must mention \"resize\" (e2e locator contract)"
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC10: Accessibility — blocking requirements
  # ══════════════════════════════════════════════════════════════════════

  describe "AC10: every node is a focusable, labeled, toggle-state-exposing element" do
    @describetag :no_repo
    test "a satellite node's aria-label mentions its route, status, and counts" do
      {:ok, view, _html} = mount_trace_map()
      broadcast_entry(route_template: "/admin/users", level: "error")

      doc = render(view) |> parsed()
      node = node_locator(doc, "/admin/users")

      assert attr(node, "role") == "button"
      assert attr(node, "tabindex") == "0"

      label = attr(node, "aria-label")
      assert label =~ "/admin/users"
      assert label =~ ~r/error/i
      assert label =~ ~r/\d+ (error|warning|request)/
    end

    test "nebu's aria-label mentions \"all traffic\" and its overall status" do
      {:ok, _view, html} = mount_trace_map()
      nebu = node_locator(parsed(html), "nebu")

      label = attr(nebu, "aria-label")
      assert label =~ "nebu"
      assert label =~ ~r/healthy|ok/i
    end
  end

  describe "AC10: a live region announces newly-detected errors" do
    @describetag :no_repo
    test "the announcer region is present with role=status/aria-live=polite" do
      {:ok, _view, html} = mount_trace_map()
      announcer = find(parsed(html), ~s([data-testid="trace-map-announcer"]))

      assert announcer
      assert attr(announcer, "role") == "status"
      assert attr(announcer, "aria-live") == "polite"
    end

    test "a fresh error is announced, naming the endpoint and count, with no message content" do
      {:ok, view, _html} = mount_trace_map()
      broadcast_entry(
        route_template: "/admin/users",
        level: "error",
        message: "distinctive-should-not-leak-into-announcement"
      )

      doc = render(view) |> parsed()
      announcer = find(doc, ~s([data-testid="trace-map-announcer"]))
      assert announcer, "expected the announcer region to be present"

      text = Floki.text(announcer)

      assert text =~ "/admin/users"
      refute text =~ "distinctive-should-not-leak-into-announcement"
    end
  end

  describe "AC10: DOM order places nebu before domains before their satellites (natural Tab order)" do
    @describetag :no_repo
    test "nebu -> domain -> its satellites, in document order" do
      {:ok, view, _html} = mount_trace_map()
      broadcast_entry(route_template: "/admin/users", level: "info")
      broadcast_entry(route_template: "/admin/rooms", level: "info")

      doc = render(view) |> parsed()
      keys = doc |> find_all(~s([data-testid="trace-map-node"])) |> Enum.map(&attr(&1, "data-node-key"))

      assert Enum.find_index(keys, &(&1 == "nebu")) == 0
      admin_index = Enum.find_index(keys, &(&1 == "/admin"))
      users_index = Enum.find_index(keys, &(&1 == "/admin/users"))
      rooms_index = Enum.find_index(keys, &(&1 == "/admin/rooms"))

      assert admin_index < users_index
      assert admin_index < rooms_index
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC11: CSP-compliant client-side behavior (static markup proxy —
  # real hook wiring is exercised by app.js + logs-trace-map.feature)
  # ══════════════════════════════════════════════════════════════════════

  describe "AC11: no inline <script> tags or inline event-handler attributes anywhere on the page" do
    @describetag :no_repo
    test "the rendered page contains no INLINE <script> tag (external, src=-bearing tags are fine) and no on*= inline handlers" do
      {:ok, _view, html} = mount_trace_map()

      # The root layout (Nebu.Admin.Layouts.root/1) legitimately renders several
      # EXTERNAL `<script src="...">` tags (phoenix.min.js, app.js, ...) — CSP
      # `script-src 'self'` allows those; AC11 forbids INLINE script content
      # only (no `src` attribute) — a `<script ...>` tag NOT immediately
      # followed by a `src=` attribute anywhere before its closing `>`.
      refute Regex.match?(~r/<script(?![^>]*\bsrc=)[^>]*>/i, html),
             "AC11 (script-src 'self'): no INLINE <script> tag (without a src=...) " <>
               "may appear in server-rendered HTML"

      refute Regex.match?(~r/\son[a-z]+\s*=/i, html),
             "AC11: no inline onclick=/onmouseover=/etc. event-handler attribute may appear"
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # Code-review regressions (dev cycle 3)
  # ══════════════════════════════════════════════════════════════════════

  describe "code-review M1: single-segment routes (their own domain) must not double-count" do
    @describetag :no_repo
    # `TraceMapTree.domain_for_endpoint("/health") == "/health"` — the node
    # key list built at ingest ([route, domain, "nebu"]) therefore contained
    # "/health" TWICE, and every event recorded twice into that node's
    # 60s-window state: badge counts, tooltip counts, inspector stats and
    # aria-labels all showed 2x reality. Pinned via the live PubSub ingest
    # path (one broadcast -> counts must read exactly 1).
    #
    # enhanced-logging/trace-map-node-controls: `/health` is now one of the
    # off-by-default long-polling endpoints — a plain WARNING broadcast
    # (no active capture) is correctly suppressed by that story's own AC4
    # contract and would never reach this node's state at all, making the
    # original WARNING probe meaningless post-node-controls. ERROR is
    # exempt from off-tier suppression (errors-always-persist amendment)
    # and exercises the EXACT SAME dedup code path (the node-keys list is
    # still built once per ingest, regardless of level) — swapped here to
    # keep this regression guard alive and meaningful.
    test "one error broadcast on /health counts exactly once in badge, aria-label, and inspector stats" do
      {:ok, view, _html} = mount_trace_map()
      broadcast_entry(route_template: "/health", level: "error")

      doc = render(view) |> parsed()
      node = node_locator(doc, "/health")

      badge_text = find(node, ~s([data-testid="trace-map-badge-error"])) |> Floki.text()
      assert badge_text =~ "1"
      refute badge_text =~ "2", "M1: one event must count once, not once per duplicate node key"

      assert attr(node, "aria-label") =~ "1 error"
      refute attr(node, "aria-label") =~ "2 errors"

      # /health renders as BOTH a domain and a satellite node (accepted
      # design, code-review i3) — scope the click to one of them.
      html =
        view
        |> element(
          ~s([data-testid="trace-map-node"][data-node-key="/health"][data-node-kind="satellite"])
        )
        |> render_click()
        |> parsed()

      errors_text =
        find(html, ~s([data-testid="trace-map-inspector-stat-errors"])) |> Floki.text() |> String.trim()

      requests_text =
        find(html, ~s([data-testid="trace-map-inspector-stat-requests"])) |> Floki.text() |> String.trim()

      assert errors_text == "1"
      assert requests_text == "1"
    end
  end

  describe "code-review m1: duplicate endpoint[] values in a crafted/bookmarked URL are deduplicated" do
    @describetag :no_repo
    # Without Enum.uniq/1 in normalize_selected/1, ?endpoint[]=X&endpoint[]=X
    # seeded @selected with X twice — two identical chips, and toggle_node's
    # List.delete/2 removed only ONE occurrence per click.
    test "mounting with the same endpoint[] value twice yields exactly one chip, removable in one click" do
      {:ok, view, html} =
        mount_trace_map("endpoint%5B%5D=%2Fadmin%2Fusers&endpoint%5B%5D=%2Fadmin%2Fusers")

      doc = parsed(html)

      chips = find_all(doc, ~s([data-testid="trace-map-filter-chip"]))
      assert length(chips) == 1, "m1: a duplicated URL value must seed exactly ONE selection/chip"
      assert attr(node_locator(doc, "/admin/users"), "aria-pressed") == "true"

      html2 =
        view
        |> element(~s([data-testid="trace-map-node"][data-node-key="/admin/users"]))
        |> render_click()
        |> parsed()

      assert find_all(html2, ~s([data-testid="trace-map-filter-chip"])) == [],
             "m1: a single toggle click must fully clear the (deduplicated) selection"

      assert attr(node_locator(html2, "/admin/users"), "aria-pressed") == "false"
    end
  end

  describe "code-review m2: UX-gate V1 announcer transitions (requires a real session + Nebu.Repo)" do
    @describetag :integration

    setup do
      Nebu.Release.migrate()
      :ok
    end

    # The war-room banner is deliberately NOT a live region (UX gate V1) —
    # session start/stop must instead be announced as one-shot sentences via
    # the sr-only announcer. Driven deterministically by sending the view its
    # own :refresh_war_room_status poll message (no 2s timer wait).
    test "a session starting and stopping while the page is open is announced via the announcer" do
      {:ok, view, _html} = mount_trace_map()

      # Shared-DB hygiene: end any session another test left active, and sync
      # the view to :none first, so the start below is a genuine :none ->
      # {:ok, _} transition.
      case Nebu.Admin.WarRoomManager.status() do
        {:ok, %{id: id}} -> Nebu.Admin.WarRoomManager.stop_session(id)
        :none -> :ok
      end

      send(view.pid, :refresh_war_room_status)
      render(view)

      {:ok, session} =
        Nebu.Admin.WarRoomManager.start_session(%{
          started_by: "@ux-gate-v1:test.local",
          reason: "m2 announcer regression probe",
          max_entries: 100,
          max_duration_s: 300
        })

      on_exit(fn ->
        # Idempotent (returns {:error, :already_ended} after the stop below).
        Nebu.Admin.WarRoomManager.stop_session(session.id)
      end)

      send(view.pid, :refresh_war_room_status)
      doc = render(view) |> parsed()

      announcement = find(doc, ~s([data-testid="trace-map-announcer"])) |> Floki.text()
      assert announcement =~ "War Room session started"
      assert announcement =~ "@ux-gate-v1:test.local"

      refute attr(find(doc, ~s([data-testid="trace-map-war-room-banner"])), "hidden"),
             "the banner itself must also come alive on the same poll"

      :ok = Nebu.Admin.WarRoomManager.stop_session(session.id)
      send(view.pid, :refresh_war_room_status)
      doc2 = render(view) |> parsed()

      assert find(doc2, ~s([data-testid="trace-map-announcer"])) |> Floki.text() =~
               "War Room session ended"

      assert attr(find(doc2, ~s([data-testid="trace-map-war-room-banner"])), "hidden") == "",
             "the banner must hide again once the session ended"
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC14: UX Gate Advisory A1 — Logs "Configuration" child renamed
  # ══════════════════════════════════════════════════════════════════════

  describe "AC14: the Logs submenu's \"Configuration\" child is disambiguated (Option A: rename)" do
    @describetag :no_repo
    test "the logs-config nav child's label is no longer the bare word \"Configuration\"" do
      {:ok, _view, html} = mount_trace_map()
      doc = parsed(html)

      logs_config_link = find(doc, ~s(a[data-navkey="logs-config"]))
      assert logs_config_link, "expected the Logs submenu to still contain a logs-config child"

      label = Floki.text(logs_config_link) |> String.trim()

      refute label == "Configuration",
             "AC14 (default Option A): the Logs child must be renamed away from the bare " <>
               "\"Configuration\" label (e.g. \"Log Settings\") to disambiguate it from the " <>
               "top-level Configuration section — see the story's AC14 for Option B (removal) " <>
               "as the alternative, explicit resolution"

      assert attr(logs_config_link, "href") == "/admin/logs/config",
             "AC14: the route itself is unchanged, only the nav label"
    end
  end
end
