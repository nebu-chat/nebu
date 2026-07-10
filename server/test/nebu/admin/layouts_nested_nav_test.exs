defmodule Nebu.Admin.LayoutsNestedNavTest do
  @moduledoc """
  RED-phase ATDD tests for `enhanced-logging/admin-sidebar-nesting`
  (Acceptance Tests 1-11 and 13 from the story's "Acceptance Tests" section;
  Acceptance Test 12 — zero-regression of the existing Playwright/BDD E2E
  suite under the refactored nav — is a genuinely browser-only proof and
  lives in `e2e/features/admin/admin-sidebar-nesting.feature` +
  `e2e/step-definitions/admin/admin-sidebar-nesting.steps.ts` instead. That
  file also carries the real-keyboard half of AC9/AC10 (Tab/Space/Enter on
  an actual focused DOM node — not reproducible against
  `Phoenix.LiveViewTest`'s server-rendered HTML string). This mirrors the
  codebase's established split between component-level ExUnit coverage and
  real-browser Playwright coverage for the sibling `trace-map-hierarchy`
  story (see `logs_live/trace_map_tree_test.exs`'s own moduledoc for the
  identical pattern, and `logs-trace-map-hierarchy.feature`'s header comment
  for the browser-only half).

  Story: docs/stories/enhanced-logging/admin-sidebar-nesting.md

  ## Why these MUST FAIL right now

  `Nebu.Admin.Layouts.nav_item/1` (server/lib/nebu/admin/layouts.ex) is
  currently a PRIVATE (`defp`) 3-attr leaf-only component with no
  `:children`/`:expanded` attr and no parent-with-toggle rendering mode at
  all. Every `render_component(&Nebu.Admin.Layouts.nav_item/1, ...)` call
  below fails with `** (UndefinedFunctionError) function
  Nebu.Admin.Layouts.nav_item/1 is undefined or private` — calling a private
  function via a remote capture is a compile-time-valid, runtime-failing
  reference (mirrors this codebase's own `trace_map_tree_test.exs`
  precedent for a target function that doesn't exist at all yet). The two
  integration `describe` blocks at the bottom fail for a different, equally
  real reason: `Nebu.Admin.Layouts.live/1` still renders "Role Mapping" /
  "Claim Mapping" / "Configuration" as three flat sibling `<li>` items and
  has no "Logs" parent with child stubs at all.

  ## Component contract this file proposes (for the dev agent to implement —
  concretizes the story's Dev Notes "File Structure" section, which only
  sketches an example)

  `Nebu.Admin.Layouts.nav_item/1` becomes PUBLIC and gains two new attrs on
  top of the three (`:navigate`, `:key`, `:active`) that already exist:

    * `:children` — list of `%{navigate: String.t(), key: String.t(),
      label: String.t()}` maps, default `[]`. Empty (the default) renders
      EXACTLY today's leaf markup (`<li><a data-navkey=... aria-current=...
      class=...>label</a></li>`) — zero behavior change for every existing
      call site that does not pass `:children` (AC2's "a leaf item ...
      renders exactly as before"). This plain-map shape (rather than the
      Dev Notes' sketched `:child` slot) mirrors the sibling
      `TraceMapTree.endpoint_tree/1` component's own precedent of plain
      data attrs over slots for a repeated child structure — the dev agent
      may implement it with a slot instead IF the resulting HTML satisfies
      every assertion below unchanged.
    * `:expanded` — boolean, default `true` (Dev Notes Q3's recommended
      "all expanded by default"). This file only pins down the RENDER
      contract for a given `:expanded` value; what `live/1` computes that
      value FROM (Dev Notes item 2's `parent_is_active?/3` sketch) is the
      dev agent's wiring choice, exercised instead by the integration
      `describe` blocks below via real `active_nav` values already assigned
      by unrelated, unchanged controllers.

  When `:children` is non-empty, `nav_item/1` renders a PARENT:

    * A `<button type="button" data-navkey={key} aria-expanded={to_string(
      expanded)} aria-controls={"nav-\#{key}-children"}>` (NOT an `<a>` —
      AC9), containing a toggle-icon element (`data-testid=
      "nav-toggle-icon"`, AC13) followed by the slot content (the parent's
      own label).
    * Toggle-icon element carries a class that differs between expanded and
      collapsed (AC13's "rotates/changes when expanded/collapsed") — this
      file pins down `"rotate-90"` present in the icon's class list when
      `expanded: true`, absent when `expanded: false`, as the concrete,
      testable proxy for that rotation (a CSS `transition` on that class
      swap is an implementation detail this file does not test).
    * Highlight classes on that `<button>`, in priority order (AC3/AC4):
        1. `key == active` (the parent itself is the active nav) → the
           SAME primary classes leaf items use today (`bg-primary
           text-primary-content font-semibold`).
        2. `active` matches one of `children`'s `:key`s (a child is active)
           → a SECONDARY/accent class, `bg-base-300` (already used
           elsewhere in this file for hover state — AC14's "no new color
           classes"), explicitly NOT `bg-primary`.
        3. otherwise (active belongs to neither this parent nor any of its
           children — e.g. it names a key in a wholly different section)
           → the same neutral classes leaf items use today. This is the
           render-contract half of Acceptance Test 13.
    * A sibling `<ul id={"nav-\#{key}-children"} role="list" class="ml-4 ...">`
      (AC12's indentation) carrying the boolean `hidden` attribute whenever
      `expanded` is `false` (AC10 — children stay in the DOM either way,
      Floki can always find them; only the `hidden` attribute toggles).
      Each child renders `<li><a navigate={child.navigate}
      data-navkey={child.key} aria-current={if child.key == active, do:
      "page"} class={...}>{child.label}</a></li>` — primary classes when
      `child.key == active`, neutral otherwise (AC4's "other children ...
      neutral").

  `live/1` itself must additionally: (a) reorganize "Configuration" into a
  parent with `role-mapping`/`claim-mapping` children (AC5/AC6, removing
  the two flat top-level items), (b) introduce a new "Logs" parent with
  child stubs `logs-monitoring` (label "Monitoring", already-shipped
  `/admin/logs`), `logs-config` (label "Configuration", `/admin/logs/config`)
  and `logs-war-room` (label "War Room", `/admin/logs/war-room`) per
  AC7/AC8, PLUS — per the story's later "Design Update (2026-07-07)"
  addendum — a 4th child `logs-trace-map` (label "Trace Map",
  `/admin/logs/trace-map`, the not-yet-built page from the Leitstand spec).
  The addendum's wording ("gains a third child 'Trace Map'") does not
  literally square with AC7's own enumeration of 3 stubs; per this
  pipeline run's explicit instruction that "the story is authoritative
  where it and the spec differ in scope," this file treats the addendum as
  ADDITIVE to AC7 (4 children total) rather than replacing any of AC7's 3
  named stubs. See the dedicated describe block below and this run's ATDD
  report for the full reasoning — a deviation worth the dev/reviewer's
  explicit attention.

  ## Auth / rendering strategy for the two integration `describe` blocks

  Mirrors `config_controller_test.exs`'s `build_admin_conn/2` +
  `Nebu.Admin.Endpoint.call/2` pattern EXACTLY. A full router-dispatched
  request is required here (unlike `live_isolated/3` elsewhere in this test
  suite) because `live_isolated/3` explicitly skips both the root AND the
  `:live` layout — it would never render the sidebar at all. Real GETs to
  the already-shipped `/admin/config` and `/admin/config/role-mapping`
  controller routes exercise the REAL, production `Nebu.Admin.Layouts.live/1`
  nav list and the REAL `active_nav` values `RoleMappingController` already
  assigns (`"role-mapping"`) — nothing about those two controllers changes
  in this story, only how the shared layout renders their (unchanged)
  `active_nav`.
  """

  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn
  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Nebu.Admin.Layouts

  @endpoint Nebu.Admin.Endpoint
  @secret_key_base String.duplicate("nebu-admin-sidebar-nesting-test-key", 2)

  # ── component-level helpers (mirrors trace_map_tree_test.exs) ──────────

  defp parsed(html), do: Floki.parse_fragment!(html)

  defp render_nav_item(assigns) do
    render_component(&Layouts.nav_item/1, assigns) |> parsed()
  end

  @config_children [
    %{navigate: "/admin/config/role-mapping", key: "role-mapping", label: "Role Mapping"},
    %{navigate: "/admin/config/claim-mapping", key: "claim-mapping", label: "Claim Mapping"}
  ]

  defp find(html, selector), do: html |> Floki.find(selector) |> List.first()
  defp find_all(html, selector), do: Floki.find(html, selector)
  defp attr(node, name), do: node |> List.wrap() |> Floki.attribute(name) |> List.first()

  defp class_includes?(node, class_name) do
    case attr(node, "class") do
      nil -> false
      class -> class |> String.split() |> Enum.member?(class_name)
    end
  end

  defp hidden?(node), do: attr(node, "hidden") != nil

  # ── integration-level helpers ───────────────────────────────────────────

  defp build_admin_conn(method, path) do
    %{conn(method, path) | secret_key_base: @secret_key_base}
    |> @endpoint.admin_session([])
    |> fetch_session()
    |> put_session("current_user", %{
      "admin" => true,
      "sub" => "admin-1",
      "matrix_user_id" => "@admin:test.local"
    })
  end

  defp endpoint_call(conn), do: @endpoint.call(conn, @endpoint.init([]))

  defp install_bootstrap_completed do
    Application.put_env(:nebu_http, :admin_bootstrap_store, fn
      :bootstrap_completed?, [] -> {:ok, true}
      _op, _args -> :default
    end)

    on_exit(fn -> Application.delete_env(:nebu_http, :admin_bootstrap_store) end)
  end

  defp get_page_html(path) do
    conn = build_admin_conn(:get, path) |> endpoint_call()
    assert conn.status == 200, "expected 200 rendering #{path}, got #{conn.status}"
    Floki.parse_document!(conn.resp_body)
  end

  # ══════════════════════════════════════════════════════════════════════
  # Acceptance Test 1 [AC1-AC2]
  # ══════════════════════════════════════════════════════════════════════

  describe "Acceptance Test 1 [AC1-AC2]: nested nav items render with expand/collapse toggle" do
    test "a parent item with children renders a toggle icon and a nested <ul> of children" do
      html =
        render_nav_item(%{
          navigate: "/admin/config",
          key: "config",
          active: nil,
          children: @config_children
        })

      assert find(html, ~s([data-testid="nav-toggle-icon"])),
             "AC1: expected a toggle/chevron icon inside the parent button"

      children_ul = find(html, "#nav-config-children")
      assert children_ul, "AC1: expected a nested <ul id=\"nav-config-children\">"

      assert length(find_all(children_ul, "li > a")) == 2,
             "AC1: expected exactly 2 rendered children"
    end

    test "a leaf item (no children) renders exactly as before — no toggle icon, plain <a>, no <button>" do
      html = render_nav_item(%{navigate: "/admin/dashboard", key: "dashboard", active: nil})

      refute find(html, ~s([data-testid="nav-toggle-icon"])),
             "AC1: a leaf item must NOT render a toggle icon"

      assert find(html, ~s(a[data-navkey="dashboard"])),
             "AC2: leaf item must render as a plain <a data-navkey=\"dashboard\">"

      refute find(html, "button"), "AC2: leaf item must not render a <button>"
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # Acceptance Test 2 [AC3-AC4]
  # ══════════════════════════════════════════════════════════════════════

  describe "Acceptance Test 2 [AC3-AC4]: active-nav extends to parent when a child is active" do
    test "child active: child gets primary highlight, parent gets secondary, other children neutral" do
      html =
        render_nav_item(%{
          navigate: "/admin/config",
          key: "config",
          active: "role-mapping",
          children: @config_children
        })

      parent_button = find(html, ~s(button[data-navkey="config"]))
      assert parent_button, "expected the Configuration parent to render as a <button>"

      assert class_includes?(parent_button, "bg-base-300"),
             "AC4: parent must get the secondary/accent highlight when a child is active"
      refute class_includes?(parent_button, "bg-primary"),
             "AC4: parent must NEVER get the full primary highlight, even when a child is active"

      role_mapping_link = find(html, ~s(a[data-navkey="role-mapping"]))
      assert class_includes?(role_mapping_link, "bg-primary"),
             "AC4: the active child must get the full primary highlight"
      assert attr(role_mapping_link, "aria-current") == "page"

      claim_mapping_link = find(html, ~s(a[data-navkey="claim-mapping"]))
      refute class_includes?(claim_mapping_link, "bg-primary"),
             "AC4: other (inactive) children must be neutral"

      # Test-review MINOR-2: aria-current="" is INVALID ARIA — on an inactive
      # item the attribute must be entirely ABSENT. (Phoenix's
      # `aria-current={if cond, do: "page"}` idiom omits nil attribute values,
      # so `nil` is the only correct rendered outcome here.)
      assert attr(claim_mapping_link, "aria-current") == nil,
             "AC4: an inactive child must not carry aria-current at all (\"\" is invalid ARIA)"
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # Acceptance Test 3 [AC3]
  # ══════════════════════════════════════════════════════════════════════

  describe "Acceptance Test 3 [AC3]: parent itself active" do
    test "parent gets primary highlight, all children remain neutral" do
      html =
        render_nav_item(%{
          navigate: "/admin/config",
          key: "config",
          active: "config",
          children: @config_children
        })

      parent_button = find(html, ~s(button[data-navkey="config"]))
      assert class_includes?(parent_button, "bg-primary"),
             "AC3: the parent itself must get the primary highlight when it is the active nav"

      for key <- ["role-mapping", "claim-mapping"] do
        link = find(html, ~s(a[data-navkey="#{key}"]))
        refute class_includes?(link, "bg-primary"),
               "AC3: child #{key} must be neutral while the parent itself is active"
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # Acceptance Test 6 [AC9]
  # ══════════════════════════════════════════════════════════════════════

  describe "Acceptance Test 6 [AC9]: parent items render as buttons with aria-expanded" do
    test "aria-expanded is \"true\" when expanded: true" do
      html =
        render_nav_item(%{
          navigate: "/admin/config",
          key: "config",
          active: nil,
          children: @config_children,
          expanded: true
        })

      button = find(html, ~s(button[data-navkey="config"]))
      assert button, "AC9: parent must render as a <button>, not an <a>"
      assert attr(button, "aria-expanded") == "true"
    end

    test "aria-expanded is \"false\" when expanded: false" do
      html =
        render_nav_item(%{
          navigate: "/admin/config",
          key: "config",
          active: nil,
          children: @config_children,
          expanded: false
        })

      button = find(html, ~s(button[data-navkey="config"]))
      assert attr(button, "aria-expanded") == "false"
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # Acceptance Test 7 [AC9]
  # ══════════════════════════════════════════════════════════════════════

  describe "Acceptance Test 7 [AC9]: aria-controls establishes relationship to the child list" do
    test "button's aria-controls matches the child <ul>'s id" do
      html =
        render_nav_item(%{
          navigate: "/admin/config",
          key: "config",
          active: nil,
          children: @config_children
        })

      button = find(html, ~s(button[data-navkey="config"]))
      assert attr(button, "aria-controls") == "nav-config-children"

      children_ul = find(html, "#nav-config-children")
      assert children_ul, "expected a <ul id=\"nav-config-children\"> matching aria-controls"
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # Acceptance Test 8 [AC10-AC11] (render-contract half — see moduledoc for
  # the real-keyboard half in the Playwright feature file)
  # ══════════════════════════════════════════════════════════════════════

  describe "Acceptance Test 8 [AC10]: collapsed children remain present in the DOM" do
    test "when expanded: false, child <li>/<a> elements are still found by Floki (not removed), only `hidden`" do
      html =
        render_nav_item(%{
          navigate: "/admin/config",
          key: "config",
          active: nil,
          children: @config_children,
          expanded: false
        })

      children_ul = find(html, "#nav-config-children")
      assert hidden?(children_ul),
             "AC10: the collapsed child list must carry the `hidden` attribute"

      assert find(children_ul, ~s(a[data-navkey="role-mapping"])),
             "AC10: children must remain in the DOM (not conditionally excluded) even when collapsed"
      assert find(children_ul, ~s(a[data-navkey="claim-mapping"]))
    end

    test "when expanded: true, the child list does not carry `hidden`" do
      html =
        render_nav_item(%{
          navigate: "/admin/config",
          key: "config",
          active: nil,
          children: @config_children,
          expanded: true
        })

      refute hidden?(find(html, "#nav-config-children"))
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # Acceptance Test 10 [AC12]
  # ══════════════════════════════════════════════════════════════════════

  describe "Acceptance Test 10 [AC12]: nested children are visually indented" do
    test "the child <ul> carries the ml-4 indentation class" do
      html =
        render_nav_item(%{
          navigate: "/admin/config",
          key: "config",
          active: nil,
          children: @config_children
        })

      assert class_includes?(find(html, "#nav-config-children"), "ml-4"),
             "AC12: expected the nested child <ul> to carry ml-4 (or equivalent) indentation"
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # Acceptance Test 11 [AC13]
  # ══════════════════════════════════════════════════════════════════════

  describe "Acceptance Test 11 [AC13]: parent items show a toggle chevron that changes with state" do
    test "the toggle icon's class differs between expanded and collapsed" do
      expanded_html =
        render_nav_item(%{
          navigate: "/admin/config",
          key: "config",
          active: nil,
          children: @config_children,
          expanded: true
        })

      collapsed_html =
        render_nav_item(%{
          navigate: "/admin/config",
          key: "config",
          active: nil,
          children: @config_children,
          expanded: false
        })

      expanded_icon = find(expanded_html, ~s([data-testid="nav-toggle-icon"]))
      collapsed_icon = find(collapsed_html, ~s([data-testid="nav-toggle-icon"]))

      assert class_includes?(expanded_icon, "rotate-90"),
             "AC13: expected the toggle icon to carry a rotation class when expanded"
      refute class_includes?(collapsed_icon, "rotate-90"),
             "AC13: expected the toggle icon's rotation class to be absent when collapsed"
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # Acceptance Test 13 [AC3-AC4] (component-level half — proves the
  # highlight-priority logic correctly falls through to "neutral" when
  # `active` names a key from an entirely different, unrelated section;
  # the two real top-level sections never share render state in `live/1`
  # either, so testing one `nav_item/1` instance in isolation IS the
  # correct unit boundary for this invariant)
  # ══════════════════════════════════════════════════════════════════════

  describe "Acceptance Test 13 [AC3-AC4]: parent has no highlight when active_nav belongs to a different section" do
    test "Configuration gets neutral classes when active_nav is \"logs-monitoring\" (a Logs child, not its own)" do
      html =
        render_nav_item(%{
          navigate: "/admin/config",
          key: "config",
          active: "logs-monitoring",
          children: @config_children
        })

      button = find(html, ~s(button[data-navkey="config"]))
      refute class_includes?(button, "bg-primary"),
             "must not be primary-highlighted for an unrelated section's active key"
      refute class_includes?(button, "bg-base-300"),
             "must not be secondary-highlighted for an unrelated section's active key"

      for key <- ["role-mapping", "claim-mapping"] do
        refute class_includes?(find(html, ~s(a[data-navkey="#{key}"])), "bg-primary")
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # Acceptance Test 4 [AC5-AC6] — full-layout integration
  # ══════════════════════════════════════════════════════════════════════

  describe "Acceptance Test 4 [AC5-AC6]: Configuration nesting removes flat Role Mapping / Claim Mapping" do
    setup do
      install_bootstrap_completed()
      :ok
    end

    test "Role Mapping / Claim Mapping are no longer top-level items, but ARE nested Configuration children" do
      html = get_page_html("/admin/config")

      # Test-review MAJOR-1: Floki 0.38.4 silently treats a LEADING child
      # combinator (`find_all(li_node, "> a")`) as a DESCENDANT selector,
      # which would have made this list include correctly-NESTED children and
      # fail the refutes below against a CORRECT implementation. Full-path
      # child combinators ARE honored, so select the direct top-level items in
      # one shot: only <a>/<button> elements that are DIRECT children of a
      # top-level <li> (nested children live one level deeper, inside the
      # parent's own <ul id="nav-*-children"> > li > a — never matched here).
      top_level_keys =
        html
        |> find_all(
          ~s(nav[aria-label="Admin navigation"] > ul[role="list"] > li > a) <>
            ~s(, nav[aria-label="Admin navigation"] > ul[role="list"] > li > button)
        )
        |> Enum.map(&attr(&1, "data-navkey"))

      refute "role-mapping" in top_level_keys,
             "AC6: Role Mapping must be removed as a flat top-level item"
      refute "claim-mapping" in top_level_keys,
             "AC6: Claim Mapping must be removed as a flat top-level item"
      assert "config" in top_level_keys,
             "AC5: Configuration must remain as a single top-level item"

      config_children = find(html, "#nav-config-children")
      assert config_children, "AC5: expected a #nav-config-children nested list"

      nested_keys = config_children |> find_all("a") |> Enum.map(&attr(&1, "data-navkey"))

      assert "role-mapping" in nested_keys,
             "AC6: Role Mapping must be visible nested under Configuration when expanded"
      assert "claim-mapping" in nested_keys,
             "AC6: Claim Mapping must be visible nested under Configuration when expanded"
    end

    test "real active_nav wiring: on /admin/config/role-mapping, Configuration is secondary-highlighted and Role Mapping is primary-highlighted" do
      html = get_page_html("/admin/config/role-mapping")

      config_button = find(html, ~s(button[data-navkey="config"]))
      assert config_button, "expected Configuration to render as a parent <button>"
      assert class_includes?(config_button, "bg-base-300")
      refute class_includes?(config_button, "bg-primary")

      role_mapping_link = find(html, ~s(a[data-navkey="role-mapping"]))
      assert class_includes?(role_mapping_link, "bg-primary")
      assert attr(role_mapping_link, "aria-current") == "page"
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # Acceptance Test 5 [AC7-AC8] — full-layout integration
  # ══════════════════════════════════════════════════════════════════════

  describe "Acceptance Test 5 [AC7-AC8]: Logs section is created with child stubs" do
    setup do
      install_bootstrap_completed()
      :ok
    end

    test "a Logs parent item is visible, and expanding it shows Monitoring / Configuration / War Room stubs" do
      html = get_page_html("/admin/config")

      logs_button = find(html, ~s(button[data-navkey="logs"]))
      assert logs_button, "AC7: expected a \"Logs\" parent item"

      logs_children = find(html, "#nav-logs-children")
      assert logs_children, "AC7: expected a #nav-logs-children nested list"

      nested_keys = logs_children |> find_all("a") |> Enum.map(&attr(&1, "data-navkey"))

      assert "logs-monitoring" in nested_keys,
             "AC7-AC8: expected a \"Monitoring\" stub with key logs-monitoring"
      assert "logs-config" in nested_keys,
             "AC7-AC8: expected a \"Configuration\" stub with key logs-config"
      assert "logs-war-room" in nested_keys,
             "AC7-AC8: expected a \"War Room\" stub with key logs-war-room"

      for key <- nested_keys do
        assert String.starts_with?(key, "logs-"),
               "AC8: every Logs child key must be namespaced with \"logs-\" to avoid collisions, got #{key}"
      end

      # AC7: the child link actually points somewhere navigable (no dead href).
      monitoring_link = find(logs_children, ~s(a[data-navkey="logs-monitoring"]))
      assert attr(monitoring_link, "href") == "/admin/logs"
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # Design Update (2026-07-07, appended to the story) — Trace Map nav item
  # ══════════════════════════════════════════════════════════════════════

  describe "Design Update: Logs section additionally includes a Trace Map child (additive to AC7's 3 stubs)" do
    setup do
      install_bootstrap_completed()
      :ok
    end

    test "a 4th Logs child \"Trace Map\" (key logs-trace-map, /admin/logs/trace-map) exists alongside the 3 AC7 stubs" do
      html = get_page_html("/admin/config")

      logs_children = find(html, "#nav-logs-children")
      nested_keys = logs_children |> find_all("a") |> Enum.map(&attr(&1, "data-navkey"))

      assert "logs-trace-map" in nested_keys,
             "Design Update: expected an additional \"Trace Map\" nav item under Logs " <>
               "(key logs-trace-map) — the page itself is a later story, only the nav item " <>
               "is in scope here"

      # The 3 original AC7 stubs must still be present — the addendum is additive.
      for key <- ["logs-monitoring", "logs-config", "logs-war-room"] do
        assert key in nested_keys,
               "Design Update must not remove any of AC7's original 3 stub children (#{key} missing)"
      end

      trace_map_link = find(logs_children, ~s(a[data-navkey="logs-trace-map"]))
      assert attr(trace_map_link, "href") == "/admin/logs/trace-map"
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # Acceptance Test 9 [AC11] — full-layout integration
  # ══════════════════════════════════════════════════════════════════════

  describe "Acceptance Test 9 [AC11]: data-navkey preserved on all items, including nested children" do
    setup do
      install_bootstrap_completed()
      :ok
    end

    test "every nav item (parent and child) has a data-navkey attribute matching its key" do
      html = get_page_html("/admin/config")

      for key <- ["dashboard", "compliance", "logs", "users", "rooms", "spaces", "config"] do
        assert find(html, ~s([data-navkey="#{key}"])),
               "expected a top-level nav item with data-navkey=\"#{key}\""
      end

      for key <- ["role-mapping", "claim-mapping"] do
        assert find(html, ~s([data-navkey="#{key}"])),
               "AC11: [data-navkey=\"#{key}\"] must still resolve after the item moves under a parent"
      end

      for key <- ["logs-monitoring", "logs-config", "logs-war-room", "logs-trace-map"] do
        assert find(html, ~s([data-navkey="#{key}"])),
               "AC11: [data-navkey=\"#{key}\"] must resolve for the new Logs child stubs"
      end
    end
  end
end
