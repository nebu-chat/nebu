defmodule Nebu.Admin.LayoutsMediaNavGroupingTest do
  @moduledoc """
  RED-phase ATDD tests for `bugfix/admin-media-nav-grouping` (AC1-AC7).

  Story: docs/stories/bugfix/admin-media-nav-grouping.md

  ## Why these MUST FAIL right now

  `Nebu.Admin.Layouts.live/1` (server/lib/nebu/admin/layouts.ex) currently renders THREE flat
  top-level `<.nav_item>` leaves for the media feature:

    * `key="media"` (an `<a>` leaf, label "Medien", carrying the `nav-media-attention-badge`
      span) → `/admin/media`
    * `key="media-settings"` (an `<a>` leaf, label "Media Settings") → `/admin/media/settings`
    * `key="media-health"` (an `<a>` leaf, label "Media Health") → `/admin/media/health`

  There is no `@media_nav_children` module attribute, no `media_nav_children/0` accessor, and no
  `#nav-media-children` nested list anywhere in the file — `Nebu.Admin.Layouts.nav_item/1` itself
  already supports a generic parent/children disclosure mode (shipped by
  `enhanced-logging/admin-sidebar-nesting`, exercised by `layouts_nested_nav_test.exs`'s
  `@config_nav_children`/`@logs_nav_children` precedent), but `layouts.ex`'s own template never
  invokes it for media. Every test below fails against today's code for that reason: either a
  `button[data-navkey="media"]` / `#nav-media-children` / `a[data-navkey="media-explorer"]` node
  that does not exist yet, or a stale `"Medien"`/`"Story 0"` label/comment that AC1-3 and AC7
  require to be gone.

  ## Component contract this file assumes (already shipped, NOT under test here)

  `Nebu.Admin.Layouts.nav_item/1`'s generic parent/children rendering (highlight priority,
  `aria-expanded`/`aria-controls`, toggle icon, `hidden` on the child `<ul>`, `aria-current` on
  the active child) is the SAME mechanism `@logs_nav_children`/`@config_nav_children` already use
  and is already covered by `layouts_nested_nav_test.exs`. AC5's "keyboard/expand-collapse
  behavior matches the Logs/Configuration precedent exactly" is therefore re-verified here only at
  the level of "Media uses the same button+toggle-icon+aria-* markup", not re-proving the generic
  mechanism itself (real-keyboard interaction for that mechanism is Playwright/E2E territory,
  already shipped by `admin-sidebar-nesting.feature`; no new interaction pattern is introduced by
  this story per AC5, so no new E2E scenario is added here either).

  ## Auth / rendering strategy

  Component-level tests call `render_component(&Nebu.Admin.Layouts.live/1, assigns)` directly
  (mirrors `layouts_war_room_indicator_test.exs`'s `base_assigns/1` pattern) — no router, no DB.

  Integration-level tests mirror `layouts_nested_nav_test.exs`'s `build_admin_conn/2` +
  `Nebu.Admin.Endpoint.call/2` pattern EXACTLY, dispatching real GETs through the router to
  `Nebu.Admin.MediaLive` / `Nebu.Admin.MediaSettingsController` / `Nebu.Admin.MediaHealthLive`.
  None of the three's `mount/index` actions require a live `Nebu.Repo` (each defensively guards
  DB reads with `Process.whereis(Nebu.Repo)`), so these run under plain `mix test`, no
  `@moduletag :integration` needed.
  """

  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn
  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Nebu.Admin.Layouts

  @endpoint Nebu.Admin.Endpoint
  @secret_key_base String.duplicate("nebu-media-nav-grouping-test-key", 2)

  # ── shared helpers (mirrors layouts_nested_nav_test.exs / layouts_war_room_indicator_test.exs) ──

  defp parsed(html), do: Floki.parse_document!(html)
  defp find(html, selector), do: html |> Floki.find(selector) |> List.first()
  defp find_all(html, selector), do: Floki.find(html, selector)
  defp attr(node, name), do: node |> List.wrap() |> Floki.attribute(name) |> List.first()

  defp class_includes?(node, class_name) do
    case attr(node, "class") do
      nil -> false
      class -> class |> String.split() |> Enum.member?(class_name)
    end
  end

  defp base_assigns(overrides) do
    Map.merge(
      %{
        __changed__: nil,
        active_nav: nil,
        bootstrap_completed: true,
        inner_content: "content",
        war_room_active: false,
        war_room_started_at: nil,
        war_room_started_by: nil,
        media_attention_count: nil
      },
      overrides
    )
  end

  defp render_live(overrides) do
    render_component(&Layouts.live/1, base_assigns(overrides)) |> parsed()
  end

  defp top_level_keys(html) do
    html
    |> find_all(
      ~s(nav[aria-label="Admin navigation"] > ul[role="list"] > li > a) <>
        ~s(, nav[aria-label="Admin navigation"] > ul[role="list"] > li > button)
    )
    |> Enum.map(&attr(&1, "data-navkey"))
  end

  # ── integration helpers ──────────────────────────────────────────────────

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
  # AC1: One parent, not three leaves
  # ══════════════════════════════════════════════════════════════════════

  describe "AC1: the three flat media leaves collapse into one top-level 'media' parent" do
    test "media-settings and media-health are no longer separate top-level items; media is" do
      html = render_live(%{})
      keys = top_level_keys(html)

      refute "media-settings" in keys,
             "AC1: Media Settings must no longer be a flat top-level nav item"
      refute "media-health" in keys,
             "AC1: Media Health must no longer be a flat top-level nav item"
      assert "media" in keys, "AC1: Media must remain as a single top-level entry"

      assert Enum.filter(keys, &(&1 in ["media", "media-settings", "media-health"])) == ["media"],
             "AC1: exactly one top-level media-related nav entry may exist"
    end

    test "the single 'media' entry is positioned immediately after Spaces and before Configuration" do
      html = render_live(%{})
      keys = top_level_keys(html)

      media_index = Enum.find_index(keys, &(&1 == "media"))
      assert media_index, "AC1: expected a top-level 'media' entry"

      assert Enum.at(keys, media_index - 1) == "spaces",
             "AC1: Media must be positioned immediately after Spaces"
      assert Enum.at(keys, media_index + 1) == "config",
             "AC1: Media must be positioned immediately before Configuration"
    end

    test "the 'media' entry renders as a disclosure button with children, not a plain leaf link" do
      html = render_live(%{})

      assert find(html, ~s(button[data-navkey="media"])),
             "AC1: Media must render as a parent disclosure <button>, mirroring config/logs"
      refute find(html, ~s(nav > ul > li > a[data-navkey="media"])),
             "AC1: Media must no longer render as a top-level plain <a> leaf"

      assert find(html, "#nav-media-children"),
             "AC1: expected a nested #nav-media-children list under the Media parent"
    end

    test "the Media parent's own label is the English 'Media', not the old German 'Medien'" do
      html = render_live(%{})

      parent_node =
        find(html, ~s(button[data-navkey="media"])) || find(html, ~s(a[data-navkey="media"]))

      assert parent_node, "expected a 'media' nav entry to inspect its label"

      label_text = parent_node |> Floki.text() |> String.trim()

      refute label_text =~ "Medien",
             "AC1 (Problem item 3): the parent label must be 'Media' (English), not 'Medien'"
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC2: Child labels
  # ══════════════════════════════════════════════════════════════════════

  describe "AC2: the three children are labeled/keyed/linked as Media Explorer / Settings / Health" do
    test "exactly 3 children exist, keyed media-explorer / media-settings / media-health" do
      html = render_live(%{})
      children_ul = find(html, "#nav-media-children")
      assert children_ul, "AC2: expected a #nav-media-children nested list"

      children = find_all(children_ul, "li > a")
      assert length(children) == 3, "AC2: expected exactly 3 media children"

      keys = Enum.map(children, &attr(&1, "data-navkey"))
      assert "media-explorer" in keys
      assert "media-settings" in keys
      assert "media-health" in keys
    end

    test "media-explorer -> /admin/media, labeled 'Media Explorer' (keeps the full prefix)" do
      html = render_live(%{})
      children_ul = find(html, "#nav-media-children")
      assert children_ul, "AC2: expected a #nav-media-children nested list"

      explorer = find(children_ul, ~s(a[data-navkey="media-explorer"]))
      assert explorer, "AC2: expected a child keyed media-explorer"
      assert attr(explorer, "href") == "/admin/media"
      assert Floki.text(explorer) =~ "Media Explorer"
    end

    test "media-settings -> /admin/media/settings, labeled 'Settings' (prefix dropped)" do
      html = render_live(%{})
      children_ul = find(html, "#nav-media-children")
      assert children_ul, "AC2: expected a #nav-media-children nested list"

      settings = find(children_ul, ~s(a[data-navkey="media-settings"]))
      assert settings, "AC2: expected a child keyed media-settings"
      assert attr(settings, "href") == "/admin/media/settings"
      assert Floki.text(settings) =~ "Settings"
      refute Floki.text(settings) =~ "Media Settings",
             "AC2: the redundant 'Media' prefix must be dropped for the Settings child"
    end

    test "media-health -> /admin/media/health, labeled 'Health' (prefix dropped)" do
      html = render_live(%{})
      children_ul = find(html, "#nav-media-children")
      assert children_ul, "AC2: expected a #nav-media-children nested list"

      health = find(children_ul, ~s(a[data-navkey="media-health"]))
      assert health, "AC2: expected a child keyed media-health"
      assert attr(health, "href") == "/admin/media/health"
      assert Floki.text(health) =~ "Health"
      refute Floki.text(health) =~ "Media Health",
             "AC2: the redundant 'Media' prefix must be dropped for the Health child"
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC3: Attention badge moves to the Media Explorer child, not the parent
  # ══════════════════════════════════════════════════════════════════════

  describe "AC3: the nav-media-attention-badge attaches to the Media Explorer child, not the Media parent" do
    test "with a positive media_attention_count, the badge renders on the media-explorer child" do
      html = render_live(%{media_attention_count: 3})

      children_ul = find(html, "#nav-media-children")
      assert children_ul, "AC2: expected a #nav-media-children nested list"

      explorer = find(children_ul, ~s(a[data-navkey="media-explorer"]))
      assert explorer, "AC2: expected a child keyed media-explorer"

      badge = find(explorer, ~s([data-testid="nav-media-attention-badge"]))
      assert badge, "AC3: expected the attention badge to render on the Media Explorer child"
      assert attr(badge, "role") == "status"

      # code review (cycle 0, MINOR-1) fix: assert the actual preserved
      # aria-hidden numeral and sr-only sentence content, not just that
      # role="status" is present — mirrors the exact markup in
      # server/lib/nebu/admin/layouts.ex's badge span (AC3's byte-for-byte
      # preservation contract): an aria-hidden visible count, and a
      # sr-only span concatenating the count with the German
      # "Datei(en) benötigen Aufmerksamkeit" sentence.
      aria_hidden_numeral = find(badge, ~s(span[aria-hidden="true"]))
      assert aria_hidden_numeral, "AC3: expected an aria-hidden numeral span inside the badge"
      assert Floki.text(aria_hidden_numeral) |> String.trim() == "3"

      sr_only_span = find(badge, "span.sr-only")
      assert sr_only_span, "AC3: expected a sr-only sentence span inside the badge"

      assert Floki.text(sr_only_span) |> String.trim() ==
               "3 Datei(en) benötigen Aufmerksamkeit"
    end

    test "with a positive media_attention_count, the Media parent button does NOT carry the badge" do
      html = render_live(%{media_attention_count: 3})

      parent_button = find(html, ~s(button[data-navkey="media"]))
      assert parent_button, "expected the Media parent to render as a <button>"

      refute find(parent_button, ~s([data-testid="nav-media-attention-badge"])),
             "AC3: the attention badge must NOT render on the Media parent label"
    end

    test "with media_attention_count nil, no badge renders anywhere in the media nav (unchanged behavior)" do
      html = render_live(%{media_attention_count: nil})

      refute find(html, ~s([data-testid="nav-media-attention-badge"])),
             "unchanged behavior: no positive count -> no badge at all"
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC4: Active-state highlighting for direct navigation to each child
  # ══════════════════════════════════════════════════════════════════════

  describe "AC4: active-nav highlighting works for all three children when navigated directly" do
    setup do
      install_bootstrap_completed()
      :ok
    end

    test "/admin/media directly highlights the Media Explorer child; Media parent gets secondary highlight" do
      html = get_page_html("/admin/media")

      parent_button = find(html, ~s(button[data-navkey="media"]))
      assert parent_button, "AC1/AC4: expected Media to render as a parent <button> on /admin/media"
      assert class_includes?(parent_button, "bg-base-300"),
             "AC4: Media parent must get the secondary highlight while a child is active"
      refute class_includes?(parent_button, "bg-primary"),
             "AC4: Media parent must never get the primary highlight from a child being active"

      explorer_link = find(html, ~s(a[data-navkey="media-explorer"]))
      assert explorer_link, "AC2/AC4: expected a media-explorer child link"
      assert class_includes?(explorer_link, "bg-primary"),
             "AC4: the Media Explorer child must be primary-highlighted on /admin/media"
      assert attr(explorer_link, "aria-current") == "page"
    end

    test "/admin/media/settings directly highlights the Settings child" do
      html = get_page_html("/admin/media/settings")

      settings_link = find(html, ~s(a[data-navkey="media-settings"]))
      assert settings_link, "AC2/AC4: expected a media-settings child link"
      assert class_includes?(settings_link, "bg-primary"),
             "AC4: the Settings child must be primary-highlighted on /admin/media/settings"
      assert attr(settings_link, "aria-current") == "page"

      parent_button = find(html, ~s(button[data-navkey="media"]))
      assert parent_button, "expected Media to render as a parent <button>"
      assert class_includes?(parent_button, "bg-base-300")
    end

    test "/admin/media/health directly highlights the Health child" do
      html = get_page_html("/admin/media/health")

      health_link = find(html, ~s(a[data-navkey="media-health"]))
      assert health_link, "AC2/AC4: expected a media-health child link"
      assert class_includes?(health_link, "bg-primary"),
             "AC4: the Health child must be primary-highlighted on /admin/media/health"
      assert attr(health_link, "aria-current") == "page"

      parent_button = find(html, ~s(button[data-navkey="media"]))
      assert parent_button, "expected Media to render as a parent <button>"
      assert class_includes?(parent_button, "bg-base-300")
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC5: Keyboard/expand-collapse behavior matches the Logs/Configuration precedent
  # ══════════════════════════════════════════════════════════════════════

  describe "AC5: Media disclosure markup matches the Logs/Configuration precedent exactly" do
    test "Media parent carries aria-expanded, aria-controls, and the same toggle icon as Logs/Config" do
      html = render_live(%{})

      button = find(html, ~s(button[data-navkey="media"]))
      assert button, "AC5: Media must render as a disclosure <button>, same as Logs/Configuration"

      assert attr(button, "aria-expanded") in ["true", "false"],
             "AC5: expected an aria-expanded attribute, mirroring Logs/Configuration"
      assert attr(button, "aria-controls") == "nav-media-children",
             "AC5: aria-controls must point at #nav-media-children"

      assert find(button, ~s([data-testid="nav-toggle-icon"])),
             "AC5: expected the same toggle-icon element Logs/Configuration use"
    end

    test "the #nav-media-children list is present regardless of expanded state (only `hidden` toggles)" do
      html = render_live(%{})

      children_ul = find(html, "#nav-media-children")
      assert children_ul, "AC5: expected #nav-media-children to exist in the DOM"
      assert class_includes?(children_ul, "ml-4"),
             "AC5: expected the same indentation class Logs/Configuration's children use"
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC6: No regression to routes, backing modules, or page content
  # ══════════════════════════════════════════════════════════════════════

  describe "AC6: the Media Explorer/Settings/Health nav children still resolve to the unchanged real pages" do
    setup do
      install_bootstrap_completed()
      :ok
    end

    test "the media-explorer child's href resolves to the real, unchanged MediaLive page" do
      html = get_page_html("/admin/media")

      explorer_link = find(html, ~s(a[data-navkey="media-explorer"]))
      assert explorer_link, "AC2: expected the media-explorer child nav link to exist"
      assert attr(explorer_link, "href") == "/admin/media",
             "AC6: the Media Explorer child must navigate to the unchanged /admin/media route"

      assert find(html, "h1"), "expected MediaLive's own page heading to still render"
    end

    test "the media-settings child's href resolves to the real, unchanged MediaSettingsController page" do
      html = get_page_html("/admin/media/settings")

      settings_link = find(html, ~s(a[data-navkey="media-settings"]))
      assert settings_link, "AC2: expected the media-settings child nav link to exist"
      assert attr(settings_link, "href") == "/admin/media/settings",
             "AC6: the Settings child must navigate to the unchanged /admin/media/settings route"
    end

    test "the media-health child's href resolves to the real, unchanged MediaHealthLive page" do
      html = get_page_html("/admin/media/health")

      health_link = find(html, ~s(a[data-navkey="media-health"]))
      assert health_link, "AC2: expected the media-health child nav link to exist"
      assert attr(health_link, "href") == "/admin/media/health",
             "AC6: the Health child must navigate to the unchanged /admin/media/health route"
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # AC7: Stale "no Story 0 parent exists yet" comments are removed
  # ══════════════════════════════════════════════════════════════════════

  describe "AC7: the stale 'no Story 0 Media parent exists yet' comments are gone from layouts.ex" do
    test "the source file no longer references the since-fixed 'Story 0' gap" do
      source = File.read!(Path.join([__DIR__, "..", "..", "..", "lib", "nebu", "admin", "layouts.ex"]))

      refute source =~ "Story 0",
             "AC7: the stale inline comments citing the (now-fixed) 'Story 0' gap must be " <>
               "removed or rewritten"
      refute source =~ "no nested \"Medien\" parent nav item",
             "AC7: the stale badge comment about no 'Medien' parent existing yet must be " <>
               "removed or rewritten"
    end
  end
end
