defmodule Nebu.Admin.LogsLive.TraceMapTreeTest do
  @moduledoc """
  RED-phase ATDD tests for `enhanced-logging/trace-map-hierarchy`
  (Acceptance Tests 1-5 and 7 from the story's "Acceptance Tests" section,
  mapped onto AC1/AC2/AC4/AC5/AC7/AC9, plus two Oracle-context display-layer
  edge cases not enumerated as their own numbered test in the story but
  called out explicitly in its ATDD handoff: a route with no recognized
  domain prefix, and an empty/no-observations dataset).

  Story: docs/stories/enhanced-logging/trace-map-hierarchy.md

  Acceptance Test 6 [AC6, AC8] (URL param persistence with tree expansion,
  restored via a real pasted/reloaded URL) and Acceptance Test 8 [AC8] (zero
  regression of the pre-existing flat-list-era assertions, now traversing the
  nested tree) are NOT in this file — per the story's own Dev Notes ("File
  Structure & Component Design"), those two require a REAL `Nebu.Admin.LogsLive`
  mount (router-dispatched query params / `handle_event("toggle_filter", ...)`
  round trips surviving a later broadcast-triggered re-render) and therefore
  live in `test/nebu/admin/logs_live_test.exs` instead, mirroring the sibling
  `trace-map-filter-reset-bugfix` story's own split between component-level
  and LiveView-integration-level tests.

  ## Why these MUST FAIL right now

  `Nebu.Admin.LogsLive.TraceMapTree` (server/lib/nebu/admin/logs_live/trace_map_tree.ex)
  does not exist yet — this story's entire point is to INTRODUCE it (the
  Endpoints section today is a flat `:for={ep <- @endpoint_order}` comprehension
  directly in `logs_live.ex`, lines 1017-1031, with no grouping component at
  all). `render_component(&TraceMapTree.endpoint_tree/1, ...)` below fails with
  `** (UndefinedFunctionError) function Nebu.Admin.LogsLive.TraceMapTree.endpoint_tree/1
  is undefined` (mirrors `trace_map_bubble_test.exs`'s own moduledoc precedent
  for a not-yet-existing `Phoenix.Component` — HEEx/function-component calls
  compile to a plain remote call, so Elixir does not check the target module
  exists at compile time), NOT a compile error in this file.

  ## Component contract this file proposes (for the dev agent to implement)

  Per the story's Dev Notes ("New: server/lib/nebu/admin/logs_live/trace_map_tree.ex"),
  `endpoint_tree/1` is a `Phoenix.Component` with attrs:

    * `endpoints` — list of all observed endpoint strings (e.g.
      `["/admin/users", "/_matrix/client/sync", ...]`), same shape as
      `@endpoint_order` today.
    * `counts` — map of endpoint string -> live integer count, same shape as
      `@endpoint_counts` today.
    * `active_filters` — list of currently-active endpoint values (e.g.
      `["/admin/users"]`), same shape as
      `Map.get(@active_filters, "endpoint", [])` today.
    * `on_click` — a 1-arity function, `(endpoint_value :: String.t() -> any())`,
      that the component calls PER LEAF to obtain that leaf's `on_click` value
      (mirrors `logs_live.ex`'s existing per-item `on_click={bubble_js("endpoint", ep)}`
      call inside its own `:for` comprehension — the tree component now owns
      that iteration, so it needs a callback rather than a single static value).
      This is this ATDD file's own concretization of the Dev Notes' looser
      "on_click={bubble_js(\"endpoint\", _)}" pseudo-code; the dev agent may
      adjust the exact calling convention as long as each leaf ends up wired
      to the SAME `Phoenix.LiveView.JS` command list `bubble_js/2` already
      produces for that endpoint value today (AC1's "Leaf bubbles preserve all
      existing behavior").

  ## Data-attribute contract this file proposes (NEW test-ids, on top of the
  already-established `trace-map-bubble` contract from `admin-logs-monitoring-view`,
  which is unchanged — see `trace_map_bubble_test.exs`):

    * Tree root: `data-testid="trace-map-tree"` — wraps the whole grouped
      structure (lets the empty-dataset edge case assert "no domain groups,
      no crash" without depending on any group-specific markup existing).
    * Domain group wrapper: `data-testid="trace-map-domain-group"
      data-domain={domain}` — one per top-level domain, containing exactly one
      header and one leaves container.
    * Domain header (AC1/AC4/AC5): a native `<button data-testid=
      "trace-map-domain-header" data-domain={domain} aria-expanded={"true"|"false"}
      aria-label={"..." <> domain <> "..."}>`, DaisyUI `btn btn-ghost` (or
      `btn btn-link`) styling — NEVER `btn btn-sm` (that class is reserved for
      leaf bubbles per AC5, so headers must be visually distinguishable), plus
      a chevron icon element.
    * Collapsible leaves container (AC4's "semantic nesting"): `<div
      data-testid="trace-map-domain-leaves" data-domain={domain} role="group"
      aria-label={"Endpoints under " <> domain}>`, carrying the boolean `hidden`
      attribute when collapsed and NOT carrying it when expanded (AC2) — chosen
      over e.g. a `display:none` inline style because `hidden` is a semantic
      HTML/ARIA-authoring-practices-aligned disclosure signal a screen reader
      already understands natively, independent of any CSS.
    * Leaf items: unchanged `Nebu.Admin.LogsLive.TraceMapBubble.trace_map_bubble/1`
      instances (`data-testid="trace-map-bubble"` etc.), nested inside their
      domain's `trace-map-domain-leaves` container (AC1/AC8) — this is the ONLY
      change to how a leaf bubble is *reached* in the DOM; its own markup is
      byte-for-byte unchanged (AC5's "no visual change to TraceMapBubble").

  ## Domain-grouping heuristic assumed by these fixtures (Dev Notes item 4,
  "Endpoint-hierarchy parsing"):

    * `/admin/*`             -> domain `/admin`
    * `/_matrix/client/*`    -> domain `/_matrix/client`
    * `/_matrix/media/*`     -> domain `/_matrix/media`
    * `/health` (singleton)  -> domain `/health`
    * anything else (no recognized prefix) -> some catch-all domain grouping
      that still contains the endpoint as a leaf SOMEWHERE in the rendered
      tree (the exact catch-all domain LABEL is deliberately left as an
      implementation detail per the Dev Notes' own "exact grouping heuristic
      is an implementation detail" — this file only pins down "not silently
      dropped", not the label).
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Nebu.Admin.LogsLive.TraceMapTree

  # See `trace_map_bubble_test.exs`'s own identical helper/comment —
  # `render_component/2` returns a raw HTML STRING; `Floki.find/2` does not
  # implicitly parse a binary argument, so every call below routes through
  # this first.
  defp parsed(html), do: Floki.parse_fragment!(html)

  defp render_tree(assigns) do
    render_component(&TraceMapTree.endpoint_tree/1, assigns) |> parsed()
  end

  defp default_on_click, do: fn value -> "toggle_filter:" <> value end

  @fixture_endpoints [
    "/admin/users",
    "/admin/logs",
    "/_matrix/client/sync",
    "/_matrix/media/download",
    "/health"
  ]

  @fixture_counts %{
    "/admin/users" => 5,
    "/admin/logs" => 2,
    "/_matrix/client/sync" => 41,
    "/_matrix/media/download" => 3,
    "/health" => 9
  }

  defp find_domain_groups(html), do: Floki.find(html, ~s([data-testid="trace-map-domain-group"]))

  defp find_domain_header(html, domain) do
    html
    |> Floki.find(~s([data-testid="trace-map-domain-header"][data-domain="#{domain}"]))
    |> List.first()
  end

  defp find_leaves_container(html, domain) do
    html
    |> Floki.find(~s([data-testid="trace-map-domain-leaves"][data-domain="#{domain}"]))
    |> List.first()
  end

  defp find_leaf_bubble(html, value) do
    html
    |> Floki.find(~s([data-testid="trace-map-bubble"][data-bubble-value="#{value}"]))
    |> List.first()
  end

  defp attr(node, name), do: node |> List.wrap() |> Floki.attribute(name) |> List.first()

  defp class_includes?(node, class_name) do
    case attr(node, "class") do
      nil -> false
      class -> class |> String.split() |> Enum.member?(class_name)
    end
  end

  defp leaves_hidden?(leaves_container) do
    # `hidden` is a boolean HTML attribute — Floki surfaces it as the empty
    # string `""` when present (mirroring how the browser DOM itself reports
    # a valueless boolean attribute), and `attr/2` returns `nil` when absent.
    attr(leaves_container, "hidden") != nil
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Acceptance Test 1 [AC1-AC2] — grouped domains, all collapsed by default
  # ══════════════════════════════════════════════════════════════════════════

  describe "Acceptance Test 1 [AC1-AC2]: Endpoint tree renders with grouped domains, all collapsed when no active filters" do
    test "5 endpoints produce 4 domain groups (/admin: 2 leaves, /_matrix/client: 1, /_matrix/media: 1, /health: 1), all collapsed" do
      html =
        render_tree(%{
          endpoints: @fixture_endpoints,
          counts: @fixture_counts,
          active_filters: [],
          on_click: default_on_click()
        })

      groups = find_domain_groups(html)

      assert length(groups) == 4,
             "expected exactly 4 domain groups (/admin, /_matrix/client, /_matrix/media, " <>
               "/health) for the 5 fixture endpoints, got #{length(groups)}: " <>
               inspect(Enum.map(groups, &attr(&1, "data-domain")))

      admin_leaves = find_leaves_container(html, "/admin")

      assert admin_leaves, "expected a leaves container for the /admin domain group"

      admin_leaf_values =
        admin_leaves
        |> Floki.find(~s([data-testid="trace-map-bubble"]))
        |> Enum.map(&attr(&1, "data-bubble-value"))
        |> Enum.sort()

      assert admin_leaf_values == ["/admin/logs", "/admin/users"],
             "expected /admin/logs and /admin/users to be grouped as the 2 leaves under " <>
               "domain /admin, got #{inspect(admin_leaf_values)}"

      for domain <- ["/admin", "/_matrix/client", "/_matrix/media", "/health"] do
        header = find_domain_header(html, domain)
        assert header, "expected a domain header for #{domain}"

        assert attr(header, "aria-expanded") == "false",
               "AC2: with no active endpoint filters, EVERY domain group must render " <>
                 "COLLAPSED (aria-expanded=\"false\") by default — #{domain}'s header did not"

        leaves = find_leaves_container(html, domain)
        assert leaves, "expected a leaves container for #{domain}"

        assert leaves_hidden?(leaves),
               "AC1: with no active filters, #{domain}'s leaf bubbles must not be visible " <>
                 "(leaves container should carry the `hidden` attribute)"
      end
    end

    test "toggling a domain's expanded state (simulating the header's click effect) flips aria-expanded and un-hides its leaves" do
      # Pure-render-contract half of Acceptance Test 1's "clicking a domain
      # group header toggles its aria-expanded state and shows/hides its leaf
      # bubbles" clause: `endpoint_tree/1` is a stateless `Phoenix.Component`,
      # so a real click-then-re-render round trip (proving the click ACTUALLY
      # reaches a `phx-click` handler and that the resulting expanded state
      # then SURVIVES an unrelated later broadcast, per AC2's "not overridden
      # by filter clicks") is tested against a REAL `Nebu.Admin.LogsLive`
      # mount instead — see `logs_live_test.exs`'s "Acceptance Test 1
      # [AC1-AC2] (dynamic half)" describe block. This half only pins down
      # that the component's rendered output actually DIFFERS correctly
      # between the two expansion states a click is supposed to toggle
      # between — i.e. that expansion state is a genuine, observable render
      # input, not something the header can be wired to without any visible
      # effect.
      collapsed_html =
        render_tree(%{
          endpoints: @fixture_endpoints,
          counts: @fixture_counts,
          active_filters: [],
          expanded_domains: [],
          on_click: default_on_click()
        })

      expanded_html =
        render_tree(%{
          endpoints: @fixture_endpoints,
          counts: @fixture_counts,
          active_filters: [],
          expanded_domains: ["/admin"],
          on_click: default_on_click()
        })

      collapsed_header = find_domain_header(collapsed_html, "/admin")
      expanded_header = find_domain_header(expanded_html, "/admin")

      assert attr(collapsed_header, "aria-expanded") == "false"
      assert attr(expanded_header, "aria-expanded") == "true"

      assert leaves_hidden?(find_leaves_container(collapsed_html, "/admin"))
      refute leaves_hidden?(find_leaves_container(expanded_html, "/admin"))
    end

    test "regression (UX gate): a collapsed leaves container's class list never carries `flex` alongside `hidden`" do
      # UX gate finding: `hidden` (from Tailwind preflight, `[hidden]{display:none}`)
      # and `.flex` (from Tailwind utilities, `.flex{display:flex}`) have EQUAL
      # CSS specificity (0,1,0) with no cascade layers in this codebase's
      # compiled `app.css` to reorder them, so `.flex` (later in source order)
      # wins the cascade — an UNCONDITIONALLY-applied `class="flex ..."` on the
      # SAME element as a dynamic `hidden={...}` attribute means the element is
      # still `display: flex` (visible, Tab-reachable) even while collapsed,
      # contradicting the `hidden` attribute and the header's own
      # `aria-expanded="false"`. Floki has no CSS engine (can't observe the
      # actual computed `display`), but it CAN verify the fix's actual
      # mechanism: `flex` must never appear in the leaves container's `class`
      # while `hidden` is present, and must reappear once `hidden` is gone.
      collapsed_html =
        render_tree(%{
          endpoints: @fixture_endpoints,
          counts: @fixture_counts,
          active_filters: [],
          expanded_domains: [],
          on_click: default_on_click()
        })

      expanded_html =
        render_tree(%{
          endpoints: @fixture_endpoints,
          counts: @fixture_counts,
          active_filters: [],
          expanded_domains: ["/admin"],
          on_click: default_on_click()
        })

      collapsed_leaves = find_leaves_container(collapsed_html, "/admin")
      expanded_leaves = find_leaves_container(expanded_html, "/admin")

      assert leaves_hidden?(collapsed_leaves)

      refute class_includes?(collapsed_leaves, "flex"),
             "a collapsed (hidden=true) leaves container must NOT carry the `flex` class — " <>
               "`hidden` and `.flex` have equal CSS specificity and no cascade layers order " <>
               "them, so an unconditional `flex` class would win the cascade and render the " <>
               "\"collapsed\" container visible and Tab-reachable, contradicting `hidden` and " <>
               "the header's aria-expanded=\"false\", got class=#{inspect(attr(collapsed_leaves, "class"))}"

      refute leaves_hidden?(expanded_leaves)

      assert class_includes?(expanded_leaves, "flex"),
             "an expanded (hidden=false) leaves container must carry `flex` so its leaf " <>
               "bubbles actually lay out as a wrapping row, got class=" <>
               "#{inspect(attr(expanded_leaves, "class"))}"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Acceptance Test 2 [AC1-AC2, AC6] — auto-expansion on URL-seeded active filter
  # ══════════════════════════════════════════════════════════════════════════

  describe "Acceptance Test 2 [AC1-AC2, AC6]: auto-expansion when a domain's leaf is active" do
    test "active_filters containing /admin/users auto-expands ONLY the /admin domain group" do
      html =
        render_tree(%{
          endpoints: @fixture_endpoints,
          counts: @fixture_counts,
          active_filters: ["/admin/users"],
          on_click: default_on_click()
        })

      admin_header = find_domain_header(html, "/admin")

      assert attr(admin_header, "aria-expanded") == "true",
             "AC2: /admin must auto-expand because /admin/users (one of its leaves) is in " <>
               "@active_filters[\"endpoint\"]"

      refute leaves_hidden?(find_leaves_container(html, "/admin")),
             "AC1: the /admin leaves container must be visible (not `hidden`) once " <>
               "auto-expanded"

      for other_domain <- ["/_matrix/client", "/_matrix/media", "/health"] do
        header = find_domain_header(html, other_domain)

        assert attr(header, "aria-expanded") == "false",
               "AC2: #{other_domain} has no active leaves and must stay COLLAPSED — auto-" <>
                 "expansion must not leak across unrelated domains"
      end

      admin_users_bubble = find_leaf_bubble(html, "/admin/users")

      assert attr(admin_users_bubble, "aria-pressed") == "true",
             "AC7 (unchanged filter semantics): the /admin/users leaf bubble itself must " <>
               "still reflect its own active state via aria-pressed, independent of the " <>
               "grouping change"

      assert class_includes?(admin_users_bubble, "btn-active")
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Acceptance Test 3 [AC1, AC5] — domain group header ARIA/styling contract
  # ══════════════════════════════════════════════════════════════════════════

  describe "Acceptance Test 3 [AC1, AC5]: domain group header has correct ARIA and styling" do
    test "the /admin domain header is a native <button> with aria-expanded, aria-label, a chevron, and btn-ghost (not btn-sm) styling" do
      html =
        render_tree(%{
          endpoints: @fixture_endpoints,
          counts: @fixture_counts,
          active_filters: [],
          on_click: default_on_click()
        })

      header = find_domain_header(html, "/admin")
      assert header, "expected a domain header for /admin"

      # `find_domain_header/2`'s selector already required
      # `data-testid="trace-map-domain-header"` to exist on SOME element — this
      # assertion additionally proves that element's TAG is a native <button>
      # (AC4's "native elements" requirement), not e.g. a styled <div>.
      assert {"button", _attrs, _children} = header,
             "AC4: the domain header must be a native <button> element (natural Tab order, " <>
               "Space/Enter activation), got a #{elem(header, 0)}"

      assert attr(header, "aria-expanded") in ["true", "false"]

      label = attr(header, "aria-label")
      assert label, "expected an aria-label on the domain header"
      assert label =~ "/admin", "expected the aria-label to name the domain it controls (/admin)"

      refute label =~ ~r/expand/i,
             "code-review MINOR-2: the aria-label must be verb-free/state-agnostic (e.g. " <>
               "\"Endpoints under /admin\") — a verb like \"Expand\" contradicts `aria-expanded` " <>
               "once the group IS expanded (a screen reader would announce \"Expand endpoints " <>
               "under /admin, expanded, button\"), got #{inspect(label)}"

      refute class_includes?(header, "btn-sm"),
             "AC5: a domain header must NOT use the leaf bubble's `btn btn-sm` styling — it " <>
               "needs a visually lighter treatment (e.g. `btn btn-ghost`/`btn btn-link`) so " <>
               "domain headers and leaf bubbles are visually distinguishable"

      assert class_includes?(header, "btn-ghost") or class_includes?(header, "btn-link"),
             "AC5: expected DaisyUI `btn-ghost` or `btn-link` styling on the domain header, " <>
               "got class=#{inspect(attr(header, "class"))}"

      chevron_present? =
        Floki.text(header) =~ ~r/[▶▼]/ or
          header |> Floki.find("[data-testid=\"trace-map-chevron\"]") != []

      assert chevron_present?,
             "AC5: expected a chevron icon (▶/▼ text, or a `data-testid=\"trace-map-chevron\"` " <>
               "element) inside the domain header that reflects its aria-expanded state"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Acceptance Test 4 [AC1, AC5, AC8] — leaf bubbles remain real TraceMapBubble instances
  # ══════════════════════════════════════════════════════════════════════════

  describe "Acceptance Test 4 [AC1, AC5, AC8]: leaf bubbles remain real TraceMapBubble component instances, unchanged" do
    test "a leaf endpoint renders with the EXACT same markup contract as the pre-tree flat-list TraceMapBubble" do
      html =
        render_tree(%{
          endpoints: @fixture_endpoints,
          counts: @fixture_counts,
          active_filters: [],
          on_click: default_on_click()
        })

      bubble = find_leaf_bubble(html, "/admin/users")
      assert bubble, "expected a leaf bubble for /admin/users"

      # Same markup contract `trace_map_bubble_test.exs` and
      # `logs_live_test.exs`'s pre-existing bubble assertions already pin
      # down for `Nebu.Admin.LogsLive.TraceMapBubble.trace_map_bubble/1` —
      # proving this is genuinely THAT component (reused, not reinvented
      # inline), not merely a lookalike `<button>` the tree component
      # hand-rolls itself.
      assert attr(bubble, "data-bubble-dimension") == "endpoint"
      assert attr(bubble, "data-bubble-value") == "/admin/users"
      assert attr(bubble, "data-bubble-count") == "5"
      assert attr(bubble, "aria-pressed") == "false"
      assert attr(bubble, "aria-label"), "expected an aria-label (TraceMapBubble's own contract)"
      assert class_includes?(bubble, "btn-sm"), "leaf bubbles keep their own btn-sm styling"
      assert attr(bubble, "phx-click") == "toggle_filter:/admin/users",
             "expected the tree to wire each leaf's on_click through the per-value callback " <>
               "this file's contract proposes, mirroring logs_live.ex's own bubble_js(\"endpoint\", ep)"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Acceptance Test 5 [AC2, AC7] — multi-select across multiple domains
  # ══════════════════════════════════════════════════════════════════════════

  describe "Acceptance Test 5 [AC2, AC7]: multi-select within endpoint dimension across multiple domains" do
    test "active_filters with one leaf in /admin and one in /_matrix/client expands both, leaves /_matrix/media collapsed" do
      html =
        render_tree(%{
          endpoints: @fixture_endpoints,
          counts: @fixture_counts,
          active_filters: ["/admin/users", "/_matrix/client/sync"],
          on_click: default_on_click()
        })

      for expanded_domain <- ["/admin", "/_matrix/client"] do
        header = find_domain_header(html, expanded_domain)

        assert attr(header, "aria-expanded") == "true",
               "expected #{expanded_domain} to auto-expand (it has an active leaf)"

        refute leaves_hidden?(find_leaves_container(html, expanded_domain))
      end

      media_header = find_domain_header(html, "/_matrix/media")

      assert attr(media_header, "aria-expanded") == "false",
             "AC2/AC7: /_matrix/media has no active leaves and must stay collapsed even " <>
               "though OTHER domains have active leaves"

      assert attr(find_leaf_bubble(html, "/admin/users"), "aria-pressed") == "true"
      assert attr(find_leaf_bubble(html, "/_matrix/client/sync"), "aria-pressed") == "true"
      assert attr(find_leaf_bubble(html, "/_matrix/media/download"), "aria-pressed") == "false"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Acceptance Test 7 [AC1, AC5, AC9] — keyboard navigation (static DOM-order half)
  # ══════════════════════════════════════════════════════════════════════════

  describe "Acceptance Test 7 [AC1, AC5, AC9]: keyboard navigation through tree in logical order" do
    # `Phoenix.LiveViewTest`/`Floki` cannot press Tab or observe real browser
    # focus movement — that half of AC9 (actual Tab traversal, and Space/Enter
    # dispatched from a REAL focused element) is covered by
    # `e2e/features/admin/logs-trace-map-hierarchy.feature` (Playwright, real
    # browser, no mocks — mirrors this codebase's own established division of
    # labor, e.g. the pre-existing "Trace Map bubbles are keyboard-navigable"
    # test in `logs_live_test.exs`, which likewise only proves the STATIC
    # native-<button> contract that guarantees correct Tab order/activation
    # semantics in ANY real browser, rather than simulating the keypress
    # itself). This test proves the STATIC contract a real Tab traversal
    # depends on: every domain header AND every leaf bubble is a native
    # <button> (so the browser's own default Tab order applies, no
    # `tabindex` needed), and the DOM emission order is domain-then-its-own-
    # leaves-then-next-domain (so that default Tab order IS the logical tree
    # order the AC requires).
    test "every domain header and leaf bubble is a native <button>, emitted in domain -> its leaves -> next domain order" do
      html =
        render_tree(%{
          endpoints: @fixture_endpoints,
          counts: @fixture_counts,
          active_filters: [],
          on_click: default_on_click()
        })

      # Depth-first walk of the parsed tree collecting every <button> in
      # document order — proves the emission order directly from the actual
      # rendered structure, rather than assuming it.
      buttons_in_order = collect_buttons_in_order(html)

      testids = Enum.map(buttons_in_order, &attr(&1, "data-testid"))

      assert Enum.all?(testids, &(&1 in ["trace-map-domain-header", "trace-map-bubble"])),
             "expected every interactive element in the tree to be either a domain header or " <>
               "a leaf bubble, got test-ids: #{inspect(testids)}"

      admin_index = Enum.find_index(buttons_in_order, &(attr(&1, "data-testid") == "trace-map-domain-header" and attr(&1, "data-domain") == "/admin"))

      admin_users_index =
        Enum.find_index(buttons_in_order, &(attr(&1, "data-bubble-value") == "/admin/users"))

      admin_logs_index =
        Enum.find_index(buttons_in_order, &(attr(&1, "data-bubble-value") == "/admin/logs"))

      next_domain_index =
        Enum.find_index(buttons_in_order, &(attr(&1, "data-testid") == "trace-map-domain-header" and attr(&1, "data-domain") != "/admin"))

      assert admin_index && admin_users_index && admin_logs_index && next_domain_index,
             "expected to find the /admin header, its two leaves, and at least one other " <>
               "domain's header among the rendered buttons"

      assert admin_index < admin_users_index and admin_index < admin_logs_index,
             "AC9: the /admin domain header must appear BEFORE its own leaves in Tab order"

      assert admin_users_index < next_domain_index and admin_logs_index < next_domain_index,
             "AC9: /admin's own leaves must appear before the NEXT domain's header in Tab " <>
               "order (logical tree traversal, not e.g. all headers first then all leaves)"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Additional edge cases (Oracle context — not their own numbered Acceptance
  # Test in the story, but explicitly flagged as real display-layer edge
  # cases to cover: a route with no recognized domain prefix, and an empty
  # dataset)
  # ══════════════════════════════════════════════════════════════════════════

  describe "Edge case [display-layer]: an endpoint with no recognized domain prefix falls into a catch-all group, not dropped" do
    test "a single-segment, unrecognized-prefix endpoint still renders as a leaf bubble somewhere in the tree" do
      endpoints = ["/admin/users", "/some-random-unrecognized-thing"]

      counts = %{
        "/admin/users" => 5,
        "/some-random-unrecognized-thing" => 1
      }

      html =
        render_tree(%{
          endpoints: endpoints,
          counts: counts,
          active_filters: [],
          on_click: default_on_click()
        })

      groups = find_domain_groups(html)
      assert length(groups) >= 1, "expected at least one domain group to render"

      all_leaf_values =
        html
        |> Floki.find(~s([data-testid="trace-map-bubble"]))
        |> Enum.map(&attr(&1, "data-bubble-value"))
        |> Enum.sort()

      assert all_leaf_values == ["/admin/users", "/some-random-unrecognized-thing"],
             "the endpoint-grouping heuristic must not SILENTLY DROP a route it cannot " <>
               "classify into a known domain prefix — got #{inspect(all_leaf_values)}"

      catch_all_bubble = find_leaf_bubble(html, "/some-random-unrecognized-thing")

      assert catch_all_bubble,
             "expected /some-random-unrecognized-thing to still render as a real leaf " <>
               "TraceMapBubble instance (in some catch-all/singleton domain group — the " <>
               "exact grouping label is an implementation detail this test deliberately " <>
               "does not pin down)"

      assert attr(catch_all_bubble, "data-bubble-count") == "1"
    end
  end

  describe "Edge case [display-layer]: an empty dataset (no observed routes yet) renders an empty tree with no crash" do
    test "endpoints: [] renders the tree root with zero domain groups and does not raise" do
      html =
        render_tree(%{
          endpoints: [],
          counts: %{},
          active_filters: [],
          on_click: default_on_click()
        })

      assert Floki.find(html, ~s([data-testid="trace-map-tree"])) != [],
             "expected the tree root container to render even with zero observed endpoints"

      assert find_domain_groups(html) == [],
             "expected zero domain groups when no endpoints have been observed yet"

      assert Floki.find(html, ~s([data-testid="trace-map-bubble"])) == [],
             "expected zero leaf bubbles when no endpoints have been observed yet"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # media-security-admin-control/10e-trace-map-war-room-integration (AC4):
  # pure-function regression pinning that "/media/clamav" and
  # "/media/scan_worker" group under a NEW "/media" domain via the EXISTING,
  # UNMODIFIED domain_for_endpoint/1 heuristic — no TraceMapTree code change
  # is needed OR permitted for this story (Dev Agent Guardrails: "Do not
  # modify Nebu.Admin.LogsLive.TraceMapTree.domain_for_endpoint/1 or
  # group_endpoints_by_domain/1").
  #
  # Unlike every other 10e test added across this epic slice, this one is
  # expected to PASS already, today, unmodified — it exists to PIN that fact
  # down as a regression guard (proving the choice of slash-separated route
  # names in Story 10e's AC1-AC3 groups "for free"), not to drive new
  # implementation work.
  # ══════════════════════════════════════════════════════════════════════════

  describe "10e AC4: /media/clamav and /media/scan_worker group under a new \"/media\" domain, unmodified heuristic" do
    test "domain_for_endpoint/1 groups both media routes under \"/media\"" do
      assert TraceMapTree.domain_for_endpoint("/media/clamav") == "/media"
      assert TraceMapTree.domain_for_endpoint("/media/scan_worker") == "/media"
    end

    test "group_endpoints_by_domain/1 produces two groups: \"/media\" (2 leaves) and \"/admin\" (1 leaf)" do
      groups =
        TraceMapTree.group_endpoints_by_domain([
          "/media/clamav",
          "/media/scan_worker",
          "/admin/users"
        ])

      assert groups == [
               {"/media", ["/media/clamav", "/media/scan_worker"]},
               {"/admin", ["/admin/users"]}
             ]
    end
  end

  # ── shared depth-first-order helper ─────────────────────────────────────────

  defp collect_buttons_in_order(nodes) when is_list(nodes) do
    Enum.flat_map(nodes, &collect_buttons_in_order/1)
  end

  defp collect_buttons_in_order({"button", _attrs, children} = node) do
    # A domain header is itself a <button> that may contain further markup
    # (chevron/label) but never a NESTED interactive <button> of its own, so
    # recursing into its children here is harmless (a leaf bubble's own
    # children are text/badge spans, never another <button>).
    [node | collect_buttons_in_order(children)]
  end

  defp collect_buttons_in_order({_tag, _attrs, children}), do: collect_buttons_in_order(children)
  defp collect_buttons_in_order(_text_or_other), do: []
end
