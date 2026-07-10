defmodule Nebu.Admin.LogsLive.TraceMapBubble do
  @moduledoc """
  Reusable Trace Map "bubble" component (enhanced-logging/admin-logs-monitoring-view,
  AC1/AC2/AC5/AC13/AC14/AC16).

  A single toggleable pill-shaped button that is BOTH legend (shows a live count)
  and interactive filter. Renders identically regardless of `mode` — the component
  itself has NO opinion on what clicking it does server-side; it simply wires
  whatever `on_click` value the caller passes onto the rendered `<button>`'s
  `phx-click` attribute. That is the entire "designed for reuse" contract (see
  `test/nebu/admin/logs_live/trace_map_bubble_test.exs`, Acceptance Test 11):

    * `mode: :filter` (THIS story, `Nebu.Admin.LogsLive`) — the caller passes a
      `Phoenix.LiveView.JS` command list as `on_click` (client-side DOM toggle +
      a `nebu:trace-bubble-click` custom-event dispatch picked up by
      `priv/static/assets/app.js` — see that file's `wireTraceMapFilters`).
      AC3 requires this to be genuinely client-side-only (no `handle_event`
      server round-trip per click), so `on_click` here is NEVER a bare event-name
      string in real `LogsLive` usage.
    * `mode: :configure` (sibling `admin-logs-retention-settings` story, REUSING
      this same component) — that story passes a bare event-name string as
      `on_click` (a normal `phx-click="configure_retention"` push), since
      AC3's client-side-only requirement is scoped to `:filter` mode only.
    * `mode: :readonly` (enhanced-logging/war-room-dedicated-page, AC8 +
      amendment 3 — REUSING this same component for the War Room scoping
      form's live-activity preview, level+source dimensions only) — the
      bubble is a live-count LEGEND, never a filter: it renders as a
      genuinely non-interactive, `disabled` `<button>` with NO `phx-click`
      attribute at all, regardless of what `on_click` value the caller
      passes (the component itself refuses to wire it up in this mode,
      rather than merely trusting the caller to pass `on_click: nil`). The
      accessible name never uses the `:filter` mode's "Filter by ..."
      wording (that phrasing is reserved for a genuinely interactive
      bubble).

  ## Accessibility (AC13/AC14)

  Every bubble is a native `<button>` (natural Tab order, Space/Enter activation),
  carries `aria-pressed` (true/false) and a descriptive `aria-label` — never a
  `<div onclick>`. Level indication pairs an icon with text (never color alone).

  ## "Off" (uncollected) bubbles (AC2)

  When `off: true`, the bubble renders a distinct "⚫ off" visual marker
  (`data-bubble-off="true"`) instead of a live count — this represents a
  STRUCTURAL absence (the level/source is not currently being collected per the
  retention policy), not "zero events in the active window".
  """
  use Phoenix.Component

  attr(:dimension, :atom, required: true, doc: "One of :endpoint, :level, :source")

  attr(:value, :string,
    required: true,
    doc: "The specific value, e.g. \"/login\", \"error\", \"ecto\""
  )

  attr(:count, :integer, required: true, doc: "Live count of matching events in the current view")
  attr(:active, :boolean, default: false, doc: "Whether this filter is currently active")
  attr(:mode, :atom, default: :filter, values: [:filter, :configure, :readonly])

  attr(:on_click, :any,
    required: true,
    doc:
      "phx-click value: a Phoenix.LiveView.JS command list (:filter) or a bare event name (:configure)"
  )

  attr(:off, :boolean,
    default: false,
    doc: "True when this dimension value is not currently collected (AC2)"
  )

  attr(:id, :string, default: nil)
  attr(:label, :string, default: nil, doc: "Override the default auto-generated label")

  def trace_map_bubble(assigns) do
    assigns =
      assigns
      |> assign_new(:label, fn -> default_label(assigns.dimension, assigns.value) end)
      |> assign_new(:id, fn -> bubble_dom_id(assigns.dimension, assigns.value) end)

    ~H"""
    <button
      type="button"
      id={@id}
      data-testid="trace-map-bubble"
      data-bubble-dimension={to_string(@dimension)}
      data-bubble-value={@value}
      data-bubble-count={to_string(@count)}
      data-bubble-off={to_string(@off)}
      aria-pressed={if @mode != :readonly, do: to_string(@active)}
      aria-label={aria_label(@mode, @dimension, @value, @off)}
      title={off_title(@off, @dimension, @value)}
      disabled={@mode == :readonly}
      phx-click={if @mode != :readonly, do: @on_click}
      class={[
        "btn btn-sm gap-1 normal-case",
        @off && "opacity-60",
        @active && not @off && "btn-active",
        (not @active or @off) && "btn-outline"
      ]}
    ><span>{@label}</span><span :if={@off} class="text-xs">⚫ off</span><span class="badge badge-sm">{@count}</span></button>
    """
  end

  @doc false
  def bubble_dom_id(dimension, value) do
    "trace-bubble-" <> Atom.to_string(dimension) <> "-" <> slug(value)
  end

  defp slug(value) do
    value
    |> to_string()
    |> String.replace(~r/[^a-zA-Z0-9_-]/, "-")
  end

  defp default_label(:level, value),
    do: level_icon(value) <> " " <> String.upcase(to_string(value))

  defp default_label(_dimension, value), do: to_string(value)

  defp level_icon("error"), do: "🔴"
  defp level_icon("warning"), do: "🟠"
  defp level_icon("info"), do: "🟢"
  defp level_icon("debug"), do: "⚪"
  defp level_icon(_), do: "⚪"

  defp aria_label(:configure, dimension, value, _off) do
    "Configure retention for #{dimension_label(dimension)} #{value}"
  end

  # AC8/amendment 3: a :readonly bubble is a live-count LEGEND, never a
  # filter — its accessible name must never use the :filter mode's "Filter
  # by ..." wording, which would misleadingly claim interactivity.
  defp aria_label(:readonly, dimension, value, _off) do
    "#{String.capitalize(dimension_label(dimension))} #{value}, live count"
  end

  # V5(a) fix (UX/accessibility gate, BLOCKING): a visual "⚫ off" marker and a
  # hover-only `title` tooltip communicate the "not currently collected"
  # (structural absence, AC2) state to sighted mouse users only. A screen
  # reader announcing this button's accessible name previously heard the
  # exact same generic "Filter by debug level" whether or not debug was being
  # collected — the not-collected state must be in the aria-label itself.
  defp aria_label(_mode, dimension, value, true) do
    "Filter by #{value} #{dimension_label(dimension)} — not currently collected"
  end

  defp aria_label(_mode, dimension, value, _off) do
    "Filter by #{value} #{dimension_label(dimension)}"
  end

  defp dimension_label(:endpoint), do: "endpoint"
  defp dimension_label(:level), do: "level"
  defp dimension_label(:source), do: "source"
  defp dimension_label(other), do: to_string(other)

  defp off_title(false, _dimension, _value), do: nil

  defp off_title(true, dimension, value) do
    "#{String.capitalize(dimension_label(dimension))} #{value} is not currently collected"
  end
end
