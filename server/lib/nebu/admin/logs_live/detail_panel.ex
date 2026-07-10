defmodule Nebu.Admin.LogsLive.DetailPanel do
  @moduledoc """
  The slide-in detail panel (enhanced-logging/admin-logs-monitoring-view, AC8).

  Stateless component rendering the full chronological thread of every
  `operational_logs` entry for one `request_id` — the "one click from error to
  full context" requirement. Slides in from the right via
  `transform transition-transform` (no extra JS library, AC16).

  ## The `data-testid="detail-entry"` contract

  `test/nebu/admin/logs_live_test.exs` (Acceptance Test 6) asserts
  `Floki.text(detail_entry) == entry.message` EXACTLY for each entry — i.e. the
  element carrying `data-testid="detail-entry"` must contain ONLY the raw
  message text as its text content, nothing else (no timestamp/level/source
  text inside the SAME node). Those metadata fields are therefore rendered in a
  SIBLING element, never nested inside the `data-testid="detail-entry"` node.

  Close (`phx-click="close_detail"`) is a genuine server round-trip (AC8 needs
  the LiveView to clear `@detail_request_id`) — unlike the Trace Map bubbles,
  AC3's client-side-only requirement does NOT apply here.

  ## Focus management (WCAG 2.4.3 — V4 fix, UX/accessibility gate, BLOCKING)

  `role="dialog"` now carries `aria-modal="true"` (this panel visually and
  logically takes over the interaction surface while open, per AC8's
  "slide-in... not a modal" being about VISUAL treatment, not about whether
  it behaves like one for focus purposes — a screen-reader user still needs
  `aria-modal` so accessibility tooling treats content behind it as
  background). `priv/static/assets/app.js`'s `wireDetailPanelFocus` (a
  `MutationObserver` on `document.body`) moves focus into this panel's first
  focusable control (the copy-thread button) when it appears in the DOM, and
  returns focus to the request row that triggered it when it is removed.
  NOTE: a full Tab/Shift+Tab focus TRAP is NOT implemented here (only
  focus-in-on-open + focus-return-on-close) — flagged explicitly rather than
  silently left out; a real trap would need to intercept Tab keydowns inside
  the panel and wrap between its first/last focusable elements, which was
  judged out of scope for this fix pass given the panel already has a small,
  fixed set of controls (copy button, close button) that a keyboard user can
  reach via normal Tab flow into the rest of the page.
  """
  use Phoenix.Component
  alias Phoenix.LiveView.JS

  attr(:request_id, :string, required: true)
  attr(:entries, :list, required: true)

  def detail_panel(assigns) do
    ~H"""
    <div
      data-testid="detail-panel"
      data-request-id={@request_id}
      role="dialog"
      aria-modal="true"
      aria-label={"Log thread for request #{@request_id}"}
      class="fixed top-0 right-0 h-full w-full sm:w-[36rem] bg-base-100 shadow-2xl z-50 transform transition-transform duration-200 translate-x-0 flex flex-col border-l border-base-300"
    >
      <div class="flex items-center justify-between p-4 border-b border-base-300 shrink-0">
        <h2 class="font-semibold text-heading font-mono">{@request_id}</h2>
        <div class="flex items-center gap-2">
          <button
            type="button"
            data-testid="copy-thread-button"
            class="btn btn-sm btn-ghost"
            data-copy-text={thread_text(@entries)}
            phx-click={JS.dispatch("nebu:copy-thread")}
            aria-label="Copy thread to clipboard"
          >
            Copy thread
          </button>
          <button type="button" phx-click="close_detail" class="btn btn-sm btn-ghost" aria-label="Close detail panel">
            ✕
          </button>
        </div>
      </div>

      <div class="flex-1 overflow-y-auto p-4 space-y-3">
        <div :for={entry <- @entries} class="border-b border-base-200 pb-2 last:border-b-0">
          <div class="flex items-center gap-2 text-xs text-text-secondary mb-1">
            <span class="font-mono">{format_seq(entry)}</span>
            <span class={["badge badge-sm", level_badge_class(level_of(entry))]} aria-label={level_aria_label(level_of(entry))}>{level_icon(level_of(entry))} {String.upcase(level_of(entry))}</span>
            <span class="opacity-70">{entry[:source]}</span>
          </div><div data-testid="detail-entry" data-level={level_of(entry)} data-source={entry[:source]} class="font-mono text-mono whitespace-pre-wrap break-words">{entry[:message]}</div>
          <details :if={has_metadata?(entry)} class="mt-1">
            <summary class="cursor-pointer text-xs text-text-secondary">metadata</summary>
            <pre class="text-xs font-mono whitespace-pre-wrap">{inspect(entry[:metadata])}</pre>
          </details>
        </div>
      </div>
    </div>
    """
  end

  defp level_of(entry), do: to_string(entry[:level] || "info")

  defp has_metadata?(entry) do
    case entry[:metadata] do
      nil -> false
      map when map == %{} -> false
      _ -> true
    end
  end

  defp format_seq(entry) do
    case entry[:inserted_at] do
      nil -> "#" <> to_string(entry[:__seq__] || 0)
      ts -> to_string(ts)
    end
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

  defp thread_text(entries) do
    entries
    |> Enum.map(fn e -> "[#{level_of(e)}] #{e[:source]}: #{e[:message]}" end)
    |> Enum.join("\n")
  end
end
