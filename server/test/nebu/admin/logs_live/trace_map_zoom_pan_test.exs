defmodule Nebu.Admin.LogsLive.TraceMapZoomPanTest do
  @moduledoc """
  RED-phase ATDD tests for `enhanced-logging/trace-map-zoom-pan`
  (map-app-style zoom/pan viewport controls on the Trace Map Leitstand,
  `/admin/logs/trace-map`).

  Story: docs/stories/enhanced-logging/trace-map-zoom-pan.md
  Design: _bmad-output/nebu/epics/enhanced-logging/design/trace-map-leitstand-spec.md
          (2026-07-09 addenda — current viewBox `-780 -650 1560 1300`)

  ## Scope of THIS file (what ExUnit/Phoenix.LiveViewTest CAN cover)

  The zoom/pan mechanism itself — mouse wheel, pointer drag, keyboard +/-
  and arrow keys, min/max bounds, viewBox survival across a LiveView patch —
  is PURELY CLIENT-SIDE JS behavior in the `TraceMapLeitstand` hook
  (`server/priv/static/assets/app.js`), following the exact
  `this.streamHeight` / `updated()` reassertion pattern already shipped for
  the stream resizer. `Phoenix.LiveViewTest` has no real browser, no mouse
  wheel, no pointer events, and cannot read a computed/JS-mutated SVG
  `viewBox` after client code runs — so none of that belongs here.

  This file instead pins the STATIC MARKUP CONTRACT the dev-story must ship
  so the JS hook has something correct to wire up against, and it is a
  REGRESSION GUARD proving this story does not disturb any of the already-
  shipped `trace-map-leitstand` / `trace-map-node-controls` markup (nodes,
  tooltip, inspector, resizer, legend, stream, level pills, announcer).

  The real interactive behavior (AC1-AC3, AC5, AC6, AC8's live-interaction
  half, AC9) is covered by
  `e2e/features/admin/logs-trace-map-zoom-pan.feature` +
  `e2e/step-definitions/admin/logs-trace-map-zoom-pan.steps.ts`
  (real `page.mouse.wheel`, real pointer drag, real keyboard, a real
  live-update-survival check via a genuine HTTP-triggered PubSub broadcast
  while the page stays mounted — no test-only HTTP routes, no sleeps).

  ## Why every test below is currently RED

  None of `trace-map-zoom-in`, `trace-map-zoom-out`, `trace-map-zoom-reset`,
  `trace-map-zoom-controls` exist in the shipped template
  (`Nebu.Admin.LogsLive.TraceMap.render/1`) yet, and the SVG root
  (`[data-testid="trace-map-svg"]`) carries neither a `tabindex` nor a
  keyboard-support-announcing `aria-label` yet — every assertion below fails
  against the CURRENT markup, not a compile error in this file.

  ## Concrete contract pinned here (ATDD proposal — dev may rename IF the
  same observable contract holds, but these are the numbers/testids this
  file AND the companion E2E feature file both assume, so they must agree):

    * Zoom-in button:    `[data-testid="trace-map-zoom-in"]`,
      `<button type="button">`, `aria-label="Zoom in"`.
    * Zoom-out button:   `[data-testid="trace-map-zoom-out"]`,
      `<button type="button">`, `aria-label="Zoom out"`.
    * Reset button:      `[data-testid="trace-map-zoom-reset"]`,
      `<button type="button">`, visible text AND `aria-label` both
      "Reset view" (AC4 — one exact string, chosen so
      `getByRole("button", { name: "Reset view" })` and this file's
      Floki-text assertion agree).
    * Controls container: `[data-testid="trace-map-zoom-controls"]`,
      `role="group"`, `aria-label="Zoom controls"`, wrapping all three
      buttons.
    * All three buttons carry the same
      `focus-visible:outline focus-visible:outline-2
      focus-visible:outline-primary focus-visible:outline-offset-2` classes
      every other interactive control on this page already uses (AC4
      "visible focus ring" — the actual computed-style check is E2E-only;
      this file pins the styling contract that produces it).
    * None of the three buttons carry `phx-click` or any `on*` attribute
      (AC7/AC9 — purely client-side, wired via the `TraceMapLeitstand` hook's
      own `addEventListener`, never a LiveView round trip, never inline JS).
    * The SVG map surface (`[data-testid="trace-map-svg"]`) gains
      `tabindex="0"` and an `aria-label` that (a) still identifies the map
      (contains "Service health map", preserving the existing accessible
      name other tests/E2E steps already rely on) and (b) announces
      keyboard support (mentions "keyboard" and at least one of
      "zoom"/"pan"/"arrow keys") — AC5's "the map container must announce
      that it supports keyboard navigation."
    * Proposed numeric bounds for the dev's own implementation (not
      re-derivable from static markup, so not asserted here — see this
      story's ATDD handoff report for the full rationale and the E2E
      file's "saturates at a boundary" tests):
      `MIN_ZOOM = 1.0`, `MAX_ZOOM = 4.0`, wheel/keyboard zoom step `= 0.1`,
      keyboard pan step `= 32` SVG units (mirrors the resizer's own
      `TRACE_MAP_RESIZE_STEP = 32`), pan offset clamped to
      `px ∈ [0, 1560 - 1560/zoom]`, `py ∈ [0, 1300 - 1300/zoom]` (so at
      `zoom = 1.0` panning is a no-op — AC3's "minimum zoom shows the full
      viewBox without being forced to pan" falls out for free).

  ## Regression guard (AC8)

  The SVG's server-rendered `viewBox` attribute value itself
  (`"-780 -650 1560 1300"`) MUST NOT change — node positions are computed
  once, server-side (`Nebu.Admin.TraceMapGeometry`); zoom/pan is a
  client-only viewport layer applied AFTER mount, never a template change.
  Every other AC1-14 testid from `trace-map-leitstand`/`trace-map-node-controls`
  must still render exactly as before.
  """

  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn
  import Phoenix.LiveViewTest
  # See trace_map_leitstand_test.exs's own moduledoc for why this import is
  # required even though `live/1` is called with a single arg here.
  import Phoenix.ConnTest

  @endpoint Nebu.Admin.Endpoint
  @secret_key_base String.duplicate("nebu-trace-map-zoom-pan-test-key", 2)

  # ══════════════════════════════════════════════════════════════════════
  # Test helpers — mirrors trace_map_leitstand_test.exs's own helpers
  # EXACTLY (this codebase's established per-file-duplication convention;
  # there is no shared support module for these).
  # ══════════════════════════════════════════════════════════════════════

  defp admin_conn(path) do
    %{conn(:get, path) | secret_key_base: @secret_key_base}
    |> @endpoint.admin_session([])
    |> fetch_session()
    |> put_session("current_user", %{
      "admin" => true,
      "sub" => "admin-trace-map-zoom-pan-tests",
      "matrix_user_id" => "@admin:test.local"
    })
  end

  defp mount_trace_map do
    sent_conn = "/admin/logs/trace-map" |> admin_conn() |> @endpoint.call(@endpoint.init([]))
    live(sent_conn)
  end

  defp parsed(html), do: Floki.parse_document!(html)
  defp find(html, selector), do: html |> Floki.find(selector) |> List.first()
  defp find_all(html, selector), do: Floki.find(html, selector)
  defp attr(node, name), do: node |> List.wrap() |> Floki.attribute(name) |> List.first()

  # ══════════════════════════════════════════════════════════════════════
  # AC4: Reset/fit-to-view control — static markup contract
  # ══════════════════════════════════════════════════════════════════════

  describe "AC4: a Reset view button exists with the correct testid, role, and label" do
    test "renders as a native <button> with the pinned testid/label/aria-label" do
      {:ok, _view, html} = mount_trace_map()
      doc = parsed(html)

      button = find(doc, ~s([data-testid="trace-map-zoom-reset"]))
      assert button, "AC4: expected a Reset view button with data-testid=\"trace-map-zoom-reset\""

      # Floki nodes are {tag, attrs, children} tuples — elem(node, 0) is the
      # tag name (mirrors trace_map_tree_test.exs's own `elem(header, 0)` use).
      assert elem(button, 0) == "button",
             "AC4: the Reset view control must be a native <button> (keyboard-focusable by default, " <>
               "no explicit tabindex bookkeeping needed)"

      assert attr(button, "type") == "button",
             "AC4: must be type=\"button\" so it never accidentally submits the inspector's " <>
               "phx-change logging form it may share a DOM subtree with"

      assert Floki.text(button) =~ "Reset view",
             "AC4: pinned visible label is exactly \"Reset view\" (dev may choose \"Fit to map\" " <>
               "instead per the story's own wording, but then this file and the E2E feature file " <>
               "must both be updated to match — flagged in the ATDD handoff report)"

      assert attr(button, "aria-label") =~ "Reset view",
             "AC4: aria-label must match (or start with) the visible label — WCAG 2.5.3 Label-in-Name"
    end

    test "carries a visible-focus-ring class and no LiveView/inline JS wiring" do
      {:ok, _view, html} = mount_trace_map()
      doc = parsed(html)

      button = find(doc, ~s([data-testid="trace-map-zoom-reset"]))
      assert button, "expected the Reset view button to exist"

      class = attr(button, "class") || ""

      assert class =~ "focus-visible:outline",
             "AC4: needs a visible focus ring — reuse this page's own focus-visible utility, " <>
               "as every other interactive control here already does"

      refute attr(button, "phx-click"),
             "AC7/AC9: zoom/pan is purely client-side (never persisted) — this must be wired " <>
               "through the TraceMapLeitstand hook's addEventListener, not a LiveView round trip"

      refute attr(button, "onclick"),
             "AC7: no inline event handler attributes — CSP is script-src 'self', no inline JS"
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC1/AC5: Zoom in/out controls — static markup contract
  # ══════════════════════════════════════════════════════════════════════

  describe "AC1/AC5: Zoom in / Zoom out buttons exist, grouped, correctly labeled" do
    test "both buttons render inside a labeled group, with no LiveView/inline JS wiring" do
      {:ok, _view, html} = mount_trace_map()
      doc = parsed(html)

      group = find(doc, ~s([data-testid="trace-map-zoom-controls"]))
      assert group, "expected a zoom controls group with data-testid=\"trace-map-zoom-controls\""
      assert attr(group, "role") == "group"
      assert attr(group, "aria-label"), "the zoom controls group needs an accessible name"

      zoom_in = find(doc, ~s([data-testid="trace-map-zoom-in"]))
      zoom_out = find(doc, ~s([data-testid="trace-map-zoom-out"]))

      assert zoom_in, "expected a Zoom in button with data-testid=\"trace-map-zoom-in\""
      assert zoom_out, "expected a Zoom out button with data-testid=\"trace-map-zoom-out\""

      for button <- [zoom_in, zoom_out] do
        assert elem(button, 0) == "button"
        assert attr(button, "type") == "button"
        refute attr(button, "phx-click"), "AC9: zoom is client-only, never a LiveView round trip"
        refute attr(button, "onclick"), "AC7: no inline event handlers"
      end

      assert attr(zoom_in, "aria-label") =~ ~r/zoom in/i
      assert attr(zoom_out, "aria-label") =~ ~r/zoom out/i
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC5 (UX gate finding 2): discoverable Pan Up/Down/Left/Right buttons —
  # a dependable screen-reader-accessible pan path, mirroring the zoom
  # controls' own static markup contract exactly. Drag-to-pan is
  # pointer-only, and role="group" + tabindex="0" on the SVG does not
  # reliably put NVDA/JAWS into "focus mode", so the SVG's own keydown
  # arrow-key handler cannot be relied on for AT users — these buttons give
  # a dependable, discoverable alternative path to the exact same
  # 32px-per-press pan the keyboard already does.
  # ══════════════════════════════════════════════════════════════════════

  describe "AC5: Pan Up/Down/Left/Right buttons exist, grouped, correctly labeled" do
    test "all four buttons render inside a labeled group, with no LiveView/inline JS wiring" do
      {:ok, _view, html} = mount_trace_map()
      doc = parsed(html)

      group = find(doc, ~s([data-testid="trace-map-pan-controls"]))
      assert group, "expected a pan controls group with data-testid=\"trace-map-pan-controls\""
      assert attr(group, "role") == "group"
      assert attr(group, "aria-label"), "the pan controls group needs an accessible name"

      pan_up = find(doc, ~s([data-testid="trace-map-pan-up"]))
      pan_down = find(doc, ~s([data-testid="trace-map-pan-down"]))
      pan_left = find(doc, ~s([data-testid="trace-map-pan-left"]))
      pan_right = find(doc, ~s([data-testid="trace-map-pan-right"]))

      assert pan_up, "expected a Pan up button with data-testid=\"trace-map-pan-up\""
      assert pan_down, "expected a Pan down button with data-testid=\"trace-map-pan-down\""
      assert pan_left, "expected a Pan left button with data-testid=\"trace-map-pan-left\""
      assert pan_right, "expected a Pan right button with data-testid=\"trace-map-pan-right\""

      for button <- [pan_up, pan_down, pan_left, pan_right] do
        assert elem(button, 0) == "button"
        assert attr(button, "type") == "button"
        refute attr(button, "phx-click"), "AC9: pan is client-only, never a LiveView round trip"
        refute attr(button, "onclick"), "AC7: no inline event handlers"

        class = attr(button, "class") || ""

        assert class =~ "focus-visible:outline",
               "AC5: needs a visible focus ring — same convention as every other interactive " <>
                 "control on this page"
      end

      assert attr(pan_up, "aria-label") =~ ~r/pan up/i
      assert attr(pan_down, "aria-label") =~ ~r/pan down/i
      assert attr(pan_left, "aria-label") =~ ~r/pan left/i
      assert attr(pan_right, "aria-label") =~ ~r/pan right/i
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC5: Keyboard accessibility — map container contract
  # ══════════════════════════════════════════════════════════════════════

  describe "AC5: the map surface is keyboard-focusable and announces keyboard support" do
    test "the SVG map gains tabindex=\"0\" and an aria-label mentioning keyboard support" do
      {:ok, _view, html} = mount_trace_map()
      doc = parsed(html)

      svg = find(doc, ~s([data-testid="trace-map-svg"]))
      assert svg, "expected the Trace Map SVG root to still exist"

      assert attr(svg, "tabindex") == "0",
             "AC5: the map container must be keyboard-operable without a mouse — " <>
               "needs tabindex=\"0\" (SVG has no implicit tab stop)"

      aria_label = attr(svg, "aria-label") || ""

      assert aria_label =~ "Service health map",
             "AC5/regression: the map's existing accessible name must be preserved, not replaced"

      assert aria_label =~ ~r/keyboard/i,
             "AC5: the map container must announce (via aria-label) that it supports keyboard " <>
               "navigation, e.g. \"Service health map. Use arrow keys to pan, +/- to zoom, or R to " <>
               "reset.\" — screen-reader users must discover the feature, not just sighted mouse users"

      assert aria_label =~ ~r/zoom|pan|arrow/i,
             "AC5: the keyboard-support announcement should name at least one concrete control " <>
               "(zoom/pan/arrow keys), not just the bare word \"keyboard\""
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC8: Regression guard — every already-shipped testid/attribute from
  # trace-map-leitstand + trace-map-node-controls must be unaffected.
  # ══════════════════════════════════════════════════════════════════════

  describe "AC8: no regressions to already-shipped Trace Map markup" do
    test "the SVG's server-rendered viewBox is still the exact spec value" do
      {:ok, _view, html} = mount_trace_map()
      doc = parsed(html)

      svg = find(doc, ~s([data-testid="trace-map-svg"]))

      # Floki lowercases attribute NAMES (not values) on parse — the real
      # rendered HTML still carries the required camelCase `viewBox`
      # spelling; only the Floki lookup key is lowercase (see
      # trace_map_leitstand_test.exs's own AC2 test for the same note).
      assert attr(svg, "viewbox") == "-780 -650 1560 1300",
             "the SERVER-rendered viewBox must never change — node positions are computed once " <>
               "server-side; zoom/pan is a purely client-side viewport layer applied after mount"

      assert attr(svg, "preserveaspectratio") == "xMidYMid meet"
      assert attr(svg, "role") == "group"
    end

    test "node, tooltip, inspector, legend, stream, resizer, and level-pill markup is unchanged" do
      {:ok, _view, html} = mount_trace_map()
      doc = parsed(html)

      nebu = find(doc, ~s([data-testid="trace-map-node"][data-node-key="nebu"]))
      assert nebu, "expected the nebu center node to still render"
      assert attr(nebu, "role") == "button"
      assert attr(nebu, "tabindex") == "0"

      assert find(doc, ~s([data-testid="trace-map-tooltip"])), "tooltip element must still exist"
      assert find(doc, ~s([data-testid="trace-map-inspector"])), "inspector panel must still exist"
      assert find(doc, ~s([data-testid="trace-map-inspector-empty"])),
             "inspector empty state must still render before any node is inspected"

      legend_rows = find_all(doc, ~s([data-testid="trace-map-legend-row"]))
      assert length(legend_rows) == 6, "the always-visible 6-row legend must be unaffected"

      resizer = find(doc, ~s([data-testid="trace-map-resizer"]))
      assert resizer, "the stream resizer must still exist"
      assert attr(resizer, "role") == "separator"
      assert attr(resizer, "aria-orientation") == "horizontal"
      assert attr(resizer, "tabindex") == "0"

      assert find(doc, ~s([data-testid="trace-map-stream"])), "the log stream panel must still exist"
      assert find(doc, ~s([data-testid="trace-map-announcer"][aria-live="polite"])),
             "the sr-only live announcer must still exist"

      level_pills = find_all(doc, ~s([data-testid="trace-map-level-pill"]))
      assert length(level_pills) == 4, "all 4 level filter pills must still render"
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC9: purely client-side, per-session — no new server-persisted state
  # ══════════════════════════════════════════════════════════════════════

  describe "AC9: zoom/pan introduces no new server-persisted state" do
    test "mounting the page fresh always yields the same default viewBox, regardless of URL query params" do
      {:ok, _view1, html1} = mount_trace_map()

      sent_conn =
        "/admin/logs/trace-map?endpoint%5B%5D=%2Fadmin%2Fusers"
        |> admin_conn()
        |> @endpoint.call(@endpoint.init([]))

      {:ok, _view2, html2} = live(sent_conn)

      svg1 = find(parsed(html1), ~s([data-testid="trace-map-svg"]))
      svg2 = find(parsed(html2), ~s([data-testid="trace-map-svg"]))

      assert attr(svg1, "viewbox") == attr(svg2, "viewbox"),
             "AC9: zoom/pan must never be part of URL-driven or session-driven state — unlike " <>
               "@selected (the endpoint filter), the server-rendered viewBox is always the same " <>
               "default regardless of query params or session; the ACTUAL zoom/pan reset-on-reload " <>
               "behavior is a real-browser concern and is covered by the companion E2E scenario"
    end
  end
end
