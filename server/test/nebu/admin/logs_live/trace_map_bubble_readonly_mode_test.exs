defmodule Nebu.Admin.LogsLive.TraceMapBubbleReadonlyModeTest do
  @moduledoc """
  RED-phase ATDD test for `enhanced-logging/war-room-dedicated-page`
  (AC8 + Story Amendments 2026-07-08, item 3 — reusing
  `Nebu.Admin.LogsLive.TraceMapBubble` in a NEW `:readonly` mode for the War
  Room scoping form's live-activity preview).

  Story: docs/stories/enhanced-logging/war-room-dedicated-page.md

  ## Amendment 3 (supersedes the story's original literal AC8 text)

  The scoping form's "live activity shape" preview reuses `TraceMapBubble`
  for the LEVEL and SOURCE dimensions only (NOT a second radial Leitstand
  map — that already moved to the dedicated `/admin/logs/trace-map` page in
  `trace-map-leitstand`, and building a second radial-map instance for this
  small preview widget would be out of proportion to the need). The "Trace
  Map Mode Decision" in the story's own Dev Notes/Design Decisions section
  (unchanged, still correct) calls for a new `:readonly` mode: "renders a
  disabled/non-interactive button" — clearly signaling the bubble is a
  live-count LEGEND, not a filter, on this page (unlike its `:filter` usage
  on `/admin/logs`, or its `:configure` usage on the retention-settings
  page).

  ## Why this MUST FAIL right now

  `trace_map_bubble.ex`'s `mode` attr only declares `values: [:filter,
  :configure]`, and `trace_map_bubble/1` unconditionally renders
  `phx-click={@on_click}` regardless of mode — there is no special-casing
  for a non-interactive bubble at all yet. This file pins the OBSERVABLE
  behavioral contract (rather than relying on `Phoenix.Component`'s internal
  attr-declaration reflection, which is not part of this component's public
  contract): rendered with `mode: :readonly`, the bubble must be a genuinely
  non-interactive, disabled `<button>` with NO `phx-click` attribute at all
  — even when a (deliberately non-nil, "should never fire") `on_click` value
  is passed, proving the component itself refuses to wire it up in this
  mode rather than merely trusting the caller to pass `on_click: nil`.

  This composes with `trace_map_bubble_test.exs` — nothing here contradicts
  that file's pinned `:filter`/`:configure` contract, this only adds a THIRD
  mode.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Nebu.Admin.LogsLive.TraceMapBubble

  defp parsed(html), do: Floki.parse_fragment!(html)

  describe "AC8 (amendment 3): mode: :readonly renders a non-interactive, disabled bubble" do
    test "no phx-click is rendered, even when on_click is a non-nil value the caller mistakenly passes" do
      html =
        render_component(&TraceMapBubble.trace_map_bubble/1, %{
          dimension: :level,
          value: "error",
          count: 5,
          active: false,
          mode: :readonly,
          on_click: "toggle_filter"
        })
        |> parsed()

      assert [button] = Floki.find(html, "button")
      attrs = Map.new(elem(button, 1))

      refute Map.has_key?(attrs, "phx-click"),
             "AC8/amendment 3: a :readonly bubble must NEVER wire up a click handler, " <>
               "regardless of what on_click the caller passes — it is a live-count legend, " <>
               "not a filter, on the War Room scoping form"
    end

    test "the button carries the native disabled attribute" do
      html =
        render_component(&TraceMapBubble.trace_map_bubble/1, %{
          dimension: :source,
          value: "http",
          count: 42,
          active: false,
          mode: :readonly,
          on_click: nil
        })
        |> parsed()

      assert [button] = Floki.find(html, "button")
      attrs = Map.new(elem(button, 1))

      assert Map.has_key?(attrs, "disabled"),
             "AC8/amendment 3: a :readonly bubble is genuinely non-interactive — " <>
               "the Trace Map Mode Decision calls for 'a disabled/non-interactive button'"
    end

    test "the accessible name does not misleadingly claim to be a filter" do
      html =
        render_component(&TraceMapBubble.trace_map_bubble/1, %{
          dimension: :level,
          value: "warning",
          count: 2,
          active: false,
          mode: :readonly,
          on_click: nil
        })
        |> parsed()

      assert [button] = Floki.find(html, "button")
      attrs = Map.new(elem(button, 1))

      refute String.starts_with?(attrs["aria-label"] || "", "Filter by"),
             "AC8/amendment 3: a screen-reader user must not be told this non-interactive " <>
               "live-count legend is a 'Filter by ...' control (that wording is reserved for " <>
               "the genuinely-interactive :filter mode on /admin/logs)"
    end

    # UX gate advisory 4 (2026-07-08): a disabled button with aria-pressed
    # still describes itself as a TOGGLE to assistive tech (the pressed/
    # unpressed distinction is meaningless once the control can never be
    # activated) — a :readonly bubble is a legend, not a toggle, so
    # aria-pressed must be omitted entirely, not merely stuck at "false".
    test "aria-pressed is omitted entirely — a legend is not a toggle" do
      html =
        render_component(&TraceMapBubble.trace_map_bubble/1, %{
          dimension: :source,
          value: "ecto",
          count: 3,
          active: false,
          mode: :readonly,
          on_click: nil
        })
        |> parsed()

      assert [button] = Floki.find(html, "button")
      attrs = Map.new(elem(button, 1))

      refute Map.has_key?(attrs, "aria-pressed"),
             "UX gate advisory 4: a :readonly bubble must never render aria-pressed " <>
               "(even \"false\") — it is a live-count legend, not a toggle"
    end

    test "the live count itself still renders (it is a LEGEND, not merely hidden)" do
      html =
        render_component(&TraceMapBubble.trace_map_bubble/1, %{
          dimension: :level,
          value: "info",
          count: 17,
          active: false,
          mode: :readonly,
          on_click: nil
        })
        |> parsed()

      assert Floki.text(html) =~ "17",
             "AC8: the readonly bubble still shows the live count — it previews current " <>
               "activity shape, it just is not clickable"
    end
  end
end
