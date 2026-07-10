defmodule Nebu.Admin.LogsLive.TraceMapBubbleTest do
  @moduledoc """
  RED-phase ATDD test for `enhanced-logging/admin-logs-monitoring-view`,
  Acceptance Test 11 [AC5]: "Trace-map-bubble component is reusable".

  Story: docs/stories/enhanced-logging/admin-logs-monitoring-view.md

  ## Why this MUST FAIL right now

  `Nebu.Admin.LogsLive.TraceMapBubble` (server/lib/nebu/admin/logs_live/trace_map_bubble.ex)
  does not exist yet. `render_component/2` below fails with
  `** (UndefinedFunctionError) function
  Nebu.Admin.LogsLive.TraceMapBubble.trace_map_bubble/1 is undefined` — the
  expected RED state, not a compile error in this file (HEEx/function-component
  calls compile to a plain remote call; Elixir does not check the target
  module exists at compile time for that).

  ## What this test pins down

  Per the story's Dev Notes ("File Structure" section), `trace_map_bubble/1`
  is a `Phoenix.Component` with attributes `dimension`, `value`, `count`,
  `active`, `mode` (`:filter` | `:configure`), `on_click`, and an optional
  `:off` slot. AC5 explicitly states:

    * `mode: :filter` (THIS story) — on click, toggles filter state in the
      LiveView via a phx-click event.
    * `mode: :configure` (the sibling `admin-logs-retention-settings` story,
      REUSING this same component) — on click, opens a modal to configure
      retention for that level/source.

  The component itself does not know or care WHAT the click does server-side
  (that is entirely the caller LiveView's `handle_event/3`) — its job is
  simply to wire whatever `phx-click` event name it is given via `on_click`
  onto the rendered `<button>`. That is exactly what "designed for reuse"
  means here: the SAME component, rendering the SAME markup shape, works for
  both modes purely by varying the `on_click` prop the caller passes in — this
  test proves that by rendering with `on_click: "toggle_filter"` (this
  story's real event name, matching logs_live_test.exs) under `mode: :filter`
  and a DIFFERENT `on_click: "configure_retention"` under `mode: :configure`
  (simulating the sibling story's usage, per AT#11's own "mode: :configure
  (simulated in a test component)" instruction), and asserting `phx-click`
  reflects each in turn.

  This intentionally does NOT assert anything about what `configure_retention`
  itself does (that belongs to the sibling story, out of scope here).
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Nebu.Admin.LogsLive.TraceMapBubble

  # `Phoenix.LiveViewTest.render_component/2` returns a raw HTML STRING.
  # `Floki.find/2` (floki ~> 0.36, pinned to 0.38.4 — see mix.lock) does NOT
  # implicitly parse a binary argument — `Floki.Finder.find/2` has an explicit
  # `def find(html_as_string, _) when is_binary(html_as_string), do: []`
  # clause, by design (a raw string is treated as an opaque text leaf, not a
  # document to auto-parse). Every `Floki.find/2` call in this file therefore
  # needs an already-parsed tree, not the raw render_component/2 string —
  # `parse_fragment!/1` (not `parse_document!/1`) since this is a bare
  # `<button>` fragment, not a full HTML document.
  defp parsed(html), do: Floki.parse_fragment!(html)

  describe "Acceptance Test 11 [AC5]: trace_map_bubble/1 is reusable across modes" do
    test "mode: :filter renders a button wired to the given phx-click, with aria-pressed/aria-label" do
      html =
        render_component(&TraceMapBubble.trace_map_bubble/1, %{
          dimension: :level,
          value: "error",
          count: 3,
          active: false,
          mode: :filter,
          on_click: "toggle_filter"
        })
        |> parsed()

      assert [button] = Floki.find(html, "button")
      attrs = Map.new(elem(button, 1))

      assert attrs["phx-click"] == "toggle_filter"
      assert attrs["aria-pressed"] == "false"
      assert Map.has_key?(attrs, "aria-label")
      assert attrs["data-bubble-dimension"] == "level"
      assert attrs["data-bubble-value"] == "error"
      assert attrs["data-bubble-count"] == "3"
    end

    test "mode: :filter with active: true renders aria-pressed=\"true\"" do
      html =
        render_component(&TraceMapBubble.trace_map_bubble/1, %{
          dimension: :endpoint,
          value: "/login",
          count: 7,
          active: true,
          mode: :filter,
          on_click: "toggle_filter"
        })
        |> parsed()

      assert [button] = Floki.find(html, "button")
      attrs = Map.new(elem(button, 1))
      assert attrs["aria-pressed"] == "true"
    end

    test "mode: :configure (simulating the sibling retention-settings story's reuse) wires a DIFFERENT phx-click via the same on_click prop" do
      html =
        render_component(&TraceMapBubble.trace_map_bubble/1, %{
          dimension: :source,
          value: "ecto",
          count: 12,
          active: false,
          mode: :configure,
          on_click: "configure_retention"
        })
        |> parsed()

      assert [button] = Floki.find(html, "button")
      attrs = Map.new(elem(button, 1))

      # This is the crux of "designed for reuse": the SAME component function,
      # given a different `on_click`, wires a different phx-click — the
      # component never hardcodes "toggle_filter".
      assert attrs["phx-click"] == "configure_retention"
      refute attrs["phx-click"] == "toggle_filter"

      assert attrs["data-bubble-dimension"] == "source"
      assert attrs["data-bubble-value"] == "ecto"
    end
  end
end
