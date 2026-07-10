defmodule Nebu.Admin.LogsLive.TraceMapTree do
  @moduledoc """
  Hierarchical, disclosure-widget-based grouping for the Trace Map's
  **Endpoints** dimension (enhanced-logging/trace-map-hierarchy).

  Wraps the pre-existing `Nebu.Admin.LogsLive.TraceMapBubble` component
  (UNCHANGED, reused as-is for every leaf) with a new domain/namespace-level
  grouping layer: each observed top-level domain (e.g. `/admin`,
  `/_matrix/client`, `/_matrix/media`, `/health`) renders as a native
  `<button aria-expanded>` disclosure header, with its specific endpoints
  nested underneath as leaf `TraceMapBubble` instances.

  ## Design Decision: disclosure-ONLY (Option B, per the story)

  Clicking a domain header ONLY toggles disclosure (shows/hides its leaves);
  it never itself activates a filter. Multi-selecting every leaf under a
  domain in one click is explicitly OUT OF SCOPE for this story (AC3) — a
  future story may add that as a separate, additive control.

  ## `expanded_domains` vs. `active_filters`-derived expansion — precedence rule

  This component accepts BOTH an explicit `expanded_domains` attr and an
  `active_filters` attr, and the two can disagree (e.g. a test wants to pin
  down "what does an explicitly-collapsed-everything render look like"
  independent of what's active). The rule, settled here to remove any
  ambiguity for future maintainers:

    * If `expanded_domains` is explicitly passed (including as an empty
      list `[]`, which means "explicitly collapse everything"), it is the
      SOLE, AUTHORITATIVE source of truth for which domains render expanded.
      `active_filters` is NOT consulted in this case.
    * If `expanded_domains` is omitted (i.e. `nil`, its default), the
      expanded set is COMPUTED from `active_filters`: a domain is expanded
      if-and-only-if at least one of its leaf endpoints is a member of
      `active_filters` (AC2's auto-expansion rule).

  In real `Nebu.Admin.LogsLive` usage, `expanded_domains` is ALWAYS passed
  explicitly — the LiveView itself merges the AC2 auto-expansion computation
  with any explicit per-domain overrides the operator has made by clicking a
  domain header (so that an explicit disclosure choice survives a later,
  unrelated re-render, e.g. a new log entry arriving — see
  `Nebu.Admin.LogsLive`'s own `effective_expanded_domains/3` and
  `handle_event("toggle_domain", ...)`). The "derive from `active_filters`
  alone" branch above exists so this component also has a sensible,
  self-contained default when used/tested in isolation (as
  `trace_map_tree_test.exs` does for several of its cases) without having to
  duplicate the LiveView's own override-merging logic in every test.

  ## Endpoint-hierarchy parsing heuristic (Dev Notes item 4)

  `domain_for_endpoint/1` splits an endpoint route on `/` and groups by the
  first 1-2 path segments:

    * `/_matrix/<namespace>/*` -> domain `/_matrix/<namespace>` (e.g.
      `/_matrix/client/v3/sync` -> `/_matrix/client`, `/_matrix/media/download`
      -> `/_matrix/media` — client and media are distinct request spaces,
      NOT collapsed into a single `/_matrix` domain).
    * `/<segment>/*` (any other single leading segment) -> domain
      `/<segment>` (e.g. `/admin/users` -> `/admin`; `/health` -> `/health`,
      a singleton domain with exactly one leaf — still rendered as a
      disclosure group for consistency, per Dev Notes item 4's "keep the
      disclosure for consistency" option).
    * Anything that matches neither shape (no leading `/`, or empty) falls
      back to treating the WHOLE endpoint string as its own domain — this is
      a deliberate catch-all, never a silent drop (see the "no recognized
      domain prefix" edge case in `trace_map_tree_test.exs`).

  ## AC5 "smooth open/close animation" — descoped (code-review cycle 2, MINOR-1)

  AC5 asks for a "smooth open/close animation" on the collapsible leaves
  container and a chevron that "rotates/toggles with `aria-expanded` state".
  This is DELIBERATELY not implemented, as a direct consequence of the
  cycle-1 accessibility fix below — this is NOT an oversight:

    * The leaves container toggles via the boolean `hidden` attribute
      (`display: none` when collapsed). `display: none` cannot be
      CSS-transitioned — there is no animatable path between "not in the
      layout/accessibility tree at all" and "rendered", by design. Cycle 1
      of this exact story fixed a real a11y bug where an unconditional
      `flex` class won the cascade over a `visibility:hidden`/`opacity:0`-
      style "animatable hidden" and left collapsed leaves focusable/
      Tab-reachable. Reintroducing an animatable hidden state (e.g.
      `opacity`/`max-height` transitions instead of `hidden`) would only be
      safe if ALSO paired with the `hidden` attribute at the end of the
      transition — which is materially more complexity (transition-end
      listeners or a timed `phx-click` + `JS.hide/show` combo) than this
      story's UX payoff warrants, especially as the SECOND
      accessibility-adjacent fix cycle in this exact area.
    * The chevron swaps the glyph TEXT (`▼`/`▶`) rather than applying a CSS
      transform, so a `transition-transform` class on it never fires (text
      content changes are not transitionable).

  The dead `transition-all duration-200` / `transition-transform duration-200`
  classes that previously sat on these two elements with no visible effect
  have been removed. See the story's AC5 text for the corresponding scope
  note.

  ## Domain header `aria-label` is verb-free/state-agnostic (code-review cycle
  ## 2, MINOR-2)

  The domain header's `aria-label` is `"Endpoints under " <> domain` (e.g.
  `"Endpoints under /admin"`), NOT `"Expand endpoints under " <> domain`.
  A verb like "Expand" is only half-true once the group is ALREADY expanded
  — a screen reader would announce "Expand endpoints under /admin, expanded,
  button", a contradictory verb-vs-state pair. `aria-expanded` alone already
  conveys state (see the Accessibility section right below); the label only
  needs to name WHAT the button controls, not command an action that may no
  longer apply.

  ## Accessibility (AC4/AC9) — no `aria-live` region, by design

  AC9 allows EITHER an `aria-live` announcement on toggle OR relying on a
  screen reader naturally encountering the `aria-expanded` change as it
  navigates. This component deliberately chooses the latter: every domain
  header is a native `<button aria-expanded="true|false">`, which IS the
  ARIA Authoring Practices Guide's own standard disclosure pattern — a
  screen reader announces the button's expanded/collapsed state as part of
  its own accessible-name/role/state computation the moment focus lands on
  (or returns to) it, with no extra live region required. This is not a gap;
  it is the spec-compliant minimal implementation.

  ## Data-attribute contract

    * Tree root: `data-testid="trace-map-tree"`.
    * Domain group wrapper: `data-testid="trace-map-domain-group"
      data-domain={domain}`.
    * Domain header: native `<button data-testid="trace-map-domain-header"
      data-domain={domain} aria-expanded aria-label>`, DaisyUI `btn
      btn-ghost` styling (never `btn-sm`, which is reserved for leaf
      bubbles).
    * Collapsible leaves container: `<div
      data-testid="trace-map-domain-leaves" data-domain={domain}
      role="group">`, carrying the boolean `hidden` attribute when
      collapsed.
    * Leaf items: unchanged `Nebu.Admin.LogsLive.TraceMapBubble.trace_map_bubble/1`
      instances, nested inside their domain's leaves container.
  """
  use Phoenix.Component

  alias Nebu.Admin.LogsLive.TraceMapBubble

  attr(:endpoints, :list, default: [], doc: "All observed endpoint strings")
  attr(:counts, :map, default: %{}, doc: "endpoint string -> live count")

  attr(:active_filters, :list,
    default: [],
    doc: "Currently-active endpoint values (list membership, not scalar equality)"
  )

  attr(:on_click, :any,
    required: true,
    doc:
      "1-arity function (endpoint_value -> phx-click value) called PER LEAF; mirrors " <>
        "logs_live.ex's own bubble_js(\"endpoint\", ep)"
  )

  attr(:expanded_domains, :list,
    default: nil,
    doc:
      "If provided (including []), the AUTHORITATIVE set of expanded domains — " <>
        "active_filters is not consulted. If omitted (nil), expansion is derived from " <>
        "active_filters (AC2). See moduledoc for the full precedence rule."
  )

  def endpoint_tree(assigns) do
    domain_groups = group_endpoints_by_domain(assigns.endpoints)

    expanded_domains =
      case assigns.expanded_domains do
        nil -> auto_expanded_domains(domain_groups, assigns.active_filters)
        explicit -> explicit
      end

    assigns =
      assigns
      |> assign(:domain_groups, domain_groups)
      |> assign(:expanded_set, MapSet.new(expanded_domains))

    ~H"""
    <div data-testid="trace-map-tree" class="flex flex-col gap-2">
      <div
        :for={{domain, leaves} <- @domain_groups}
        data-testid="trace-map-domain-group"
        data-domain={domain}
        class="flex flex-col"
      >
        <button
          type="button"
          data-testid="trace-map-domain-header"
          data-domain={domain}
          aria-expanded={to_string(domain in @expanded_set)}
          aria-label={"Endpoints under " <> domain}
          phx-click="toggle_domain"
          phx-value-domain={domain}
          class="btn btn-ghost gap-1 justify-start normal-case w-fit"
        >
          <span
            data-testid="trace-map-chevron"
            aria-hidden="true"
            class="inline-block"
          >{if domain in @expanded_set, do: "▼", else: "▶"}</span>
          <span>{domain}</span>
        </button>
        <div
          data-testid="trace-map-domain-leaves"
          data-domain={domain}
          role="group"
          aria-label={"Endpoints under " <> domain}
          hidden={domain not in @expanded_set}
          class={[
            "ml-4 pl-2 overflow-hidden",
            domain in @expanded_set && "flex flex-wrap gap-2"
          ]}
        >
          <TraceMapBubble.trace_map_bubble
            :for={ep <- leaves}
            dimension={:endpoint}
            value={ep}
            count={Map.get(@counts, ep, 0)}
            active={ep in @active_filters}
            mode={:filter}
            on_click={@on_click.(ep)}
          />
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Groups a flat list of observed endpoint strings by `domain_for_endpoint/1`,
  preserving each domain's first-observed order (both across domains, and
  for the endpoints within a domain) — NOT alphabetically sorted, so the
  rendered tree order matches the order routes were first seen in
  `@endpoint_order`.

  Exposed (not `@doc false`) because `Nebu.Admin.LogsLive` reuses this to
  compute `handle_event("toggle_domain", ...)`'s effective expanded-domain
  set without duplicating the grouping heuristic.
  """
  def group_endpoints_by_domain(endpoints) do
    domain_order =
      endpoints
      |> Enum.map(&domain_for_endpoint/1)
      |> Enum.uniq()

    groups = Enum.group_by(endpoints, &domain_for_endpoint/1)

    Enum.map(domain_order, fn domain -> {domain, Map.fetch!(groups, domain)} end)
  end

  @doc """
  Given `group_endpoints_by_domain/1`'s output and a list of active leaf
  values, returns the list of domains that should auto-expand per AC2: any
  domain with at least one leaf currently active.
  """
  def auto_expanded_domains(domain_groups, active_filters) do
    domain_groups
    |> Enum.filter(fn {_domain, leaves} -> Enum.any?(leaves, &(&1 in active_filters)) end)
    |> Enum.map(fn {domain, _leaves} -> domain end)
  end

  @doc """
  Endpoint-hierarchy parsing heuristic (Dev Notes item 4) — see moduledoc
  for the full rationale. Splits on `/`:

    * `/_matrix/<namespace>/*` -> `/_matrix/<namespace>`
    * `/<segment>/*` or `/<segment>` -> `/<segment>`
    * anything else (no leading `/`, empty string, ...) -> the endpoint
      itself (catch-all, never silently dropped)
  """
  def domain_for_endpoint(endpoint) when is_binary(endpoint) do
    case String.split(endpoint, "/") do
      ["", "_matrix", namespace | _rest] when namespace != "" -> "/_matrix/" <> namespace
      ["", segment | _rest] when segment != "" -> "/" <> segment
      _other -> endpoint
    end
  end
end
