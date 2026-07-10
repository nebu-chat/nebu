defmodule Nebu.Admin.LayoutsWarRoomIndicatorTest do
  @moduledoc """
  RED-phase ATDD tests for `enhanced-logging/war-room-dedicated-page`,
  Story Amendment 4 (2026-07-08) — a pulsing recording dot on the sidebar's
  "War Room" nav item, and a recording pill in the topbar, while a War Room
  session is active. This closes the gap left after `trace-map-leitstand`
  shipped only the Trace Map page's OWN in-page banner: an operator on ANY
  other admin page (Dashboard, Users, Rooms, ...) previously had no way to
  tell a session was running without navigating to `/admin/logs` or
  `/admin/logs/trace-map` first.

  Story: docs/stories/enhanced-logging/war-room-dedicated-page.md
  Approved visual reference (amendment 4's own citation):
  `_bmad-output/nebu/epics/enhanced-logging/design/trace-map-leitstand-dummy.html`
  — topbar `.pill--warroom` (`"War Room recording · " <> mm:ss`) and sidebar
  `#wr-navdot`.

  ## Why these MUST FAIL right now

  `Nebu.Admin.Layouts.live/1` (server/lib/nebu/admin/layouts.ex) has no
  `:war_room_active`/`:war_room_session` assign at all today — the topbar
  `<header>` renders only the static "Nebu Admin" brand text, and the
  sidebar's "Logs" section's children (`@logs_nav_children`, including the
  already-shipped `"logs-war-room"` key from `admin-sidebar-nesting`) render
  via the existing, dot-agnostic `nav_item/1` child markup. Every test below
  fails because neither `[data-testid="nav-war-room-dot"]` nor
  `[data-testid="topbar-war-room-pill"]` exist in the rendered markup at
  all, regardless of the assign passed in.

  ## Contract pinned by this file

    * `Nebu.Admin.Layouts.live/1` accepts new assigns (safely defaulted via
      `assign_new/3` for every OTHER existing LiveView call site that does
      not set them, mirroring the existing `:active_nav`/
      `:bootstrap_completed` precedent):
        - `:war_room_active` (boolean, default `false`)
        - `:war_room_started_at` (`DateTime.t() | nil`, default `nil`) —
          used to compute the topbar pill's elapsed `mm:ss` text
        - `:war_room_started_by` (`String.t() | nil`, default `nil`) —
          optional, for a fuller pill label
      Amendment 4's own wording: "sourced from
      `Nebu.Admin.WarRoomManager.status/0`, polled the same way
      `LogsLive`/`LogsLive.TraceMap` already do" — this file pins the
      RENDER contract only; the poll wiring itself is exercised end-to-end
      by the `@describetag :integration` block below and by
      `e2e/features/admin/war-room-dedicated-page.feature`.
    * Sidebar: `[data-testid="nav-war-room-dot"]` renders inside the
      `<li>` for `[data-navkey="logs-war-room"]` ONLY when
      `@war_room_active` is `true`; absent when `false` (the default).
    * Topbar: `[data-testid="topbar-war-room-pill"]` in the `<header>`
      renders ONLY when `@war_room_active` is `true`; absent when `false`.
      When present, it contains the text "War Room recording" (per the
      approved dummy's `.pill--warroom` copy) — the exact `mm:ss` ticking
      value is client-side/E2E territory (mirrors
      `trace-map-war-room-elapsed`'s own `data-started-at` + app.js-tick
      precedent), so this file only pins a `data-started-at` attribute
      carrying the session's start time for that same client-side tick
      mechanism to consume.
    * Both indicators are ADDITIVE — the pre-existing "Nebu Admin" brand
      text and the "Logs" section's other children render unchanged
      regardless of `@war_room_active`.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn
  import Phoenix.LiveViewTest
  import Phoenix.ConnTest

  @endpoint Nebu.Admin.Endpoint
  @secret_key_base String.duplicate("nebu-wr-indicator-test-key", 2)

  defp find(html, selector), do: html |> Floki.find(selector) |> List.first()
  defp attr(node, name), do: node |> List.wrap() |> Floki.attribute(name) |> List.first()

  # ══════════════════════════════════════════════════════════════════════
  # Component-level contract (no DB, no router) — mirrors
  # trace_map_bubble_test.exs's render_component/2 pattern.
  # ══════════════════════════════════════════════════════════════════════

  describe "amendment 4: Nebu.Admin.Layouts.live/1 renders the dot/pill from assigns" do
    defp base_assigns(overrides) do
      Map.merge(
        %{
          __changed__: nil,
          active_nav: "dashboard",
          bootstrap_completed: true,
          inner_content: "content",
          war_room_active: false,
          war_room_started_at: nil,
          war_room_started_by: nil
        },
        overrides
      )
    end

    test "with war_room_active: false (default), neither the nav dot nor the topbar pill render" do
      html = render_component(&Nebu.Admin.Layouts.live/1, base_assigns(%{})) |> Floki.parse_document!()

      refute find(html, ~s([data-testid="nav-war-room-dot"])),
             "amendment 4: no session active -> no sidebar recording dot"

      refute find(html, ~s([data-testid="topbar-war-room-pill"])),
             "amendment 4: no session active -> no topbar recording pill"
    end

    test "with war_room_active: true, the sidebar recording dot renders on the War Room nav item" do
      html =
        render_component(
          &Nebu.Admin.Layouts.live/1,
          base_assigns(%{
            war_room_active: true,
            war_room_started_at: ~U[2026-07-08 10:00:00Z],
            war_room_started_by: "@admin:test.local"
          })
        )
        |> Floki.parse_document!()

      war_room_li =
        html
        |> Floki.find(~s(li))
        |> Enum.find(fn li -> Floki.find(li, ~s([data-navkey="logs-war-room"])) != [] end)

      assert war_room_li, "expected the 'War Room' nav item (data-navkey=\"logs-war-room\") to exist"

      assert Floki.find(war_room_li, ~s([data-testid="nav-war-room-dot"])) != [],
             "amendment 4: an active session must show a recording dot on the sidebar's " <>
               "War Room nav item"
    end

    # UX gate (2026-07-08, BLOCKING VIOLATION): the recording dot above is
    # `aria-hidden` (a purely decorative pulse) — without a text equivalent, a
    # screen-reader user hears the SAME accessible name ("War Room") whether
    # or not a session is recording, unlike the topbar pill's own visible
    # "War Room recording · mm:ss" text. This test pins the accessible-name
    # EQUIVALENT the dot's presence must never be able to slip by without
    # (the fix: an sr-only span alongside the dot).
    test "with war_room_active: true, the War Room nav link's accessible name changes too — not just the (aria-hidden) dot" do
      html =
        render_component(
          &Nebu.Admin.Layouts.live/1,
          base_assigns(%{
            war_room_active: true,
            war_room_started_at: ~U[2026-07-08 10:00:00Z],
            war_room_started_by: "@admin:test.local"
          })
        )
        |> Floki.parse_document!()

      war_room_link = find(html, ~s(a[data-navkey="logs-war-room"]))
      assert war_room_link, "expected the 'War Room' nav link to exist"

      assert Floki.text(war_room_link) =~ ~r/recording/i,
             "UX gate violation: the War Room nav link must carry an accessible-name " <>
               "equivalent to the recording dot (e.g. an sr-only \"(recording)\" span) — " <>
               "a screen reader must not hear the same \"War Room\" name regardless of " <>
               "whether a session is active"
    end

    test "with war_room_active: false, the War Room nav link's accessible name has no recording indicator" do
      html =
        render_component(&Nebu.Admin.Layouts.live/1, base_assigns(%{}))
        |> Floki.parse_document!()

      war_room_link = find(html, ~s(a[data-navkey="logs-war-room"]))
      assert war_room_link, "expected the 'War Room' nav link to exist"

      refute Floki.text(war_room_link) =~ ~r/recording/i,
             "no session active -> the War Room nav link's accessible name must not " <>
               "mention recording"
    end

    test "with war_room_active: true, the topbar recording pill renders with the expected copy" do
      html =
        render_component(
          &Nebu.Admin.Layouts.live/1,
          base_assigns(%{
            war_room_active: true,
            war_room_started_at: ~U[2026-07-08 10:00:00Z],
            war_room_started_by: "@admin:test.local"
          })
        )
        |> Floki.parse_document!()

      pill = find(html, ~s([data-testid="topbar-war-room-pill"]))
      assert pill, "amendment 4: expected a topbar recording pill while a session is active"

      assert Floki.text(pill) =~ "War Room recording",
             "amendment 4: the pill copy must match the approved dummy's " <>
               "'War Room recording · mm:ss' wording"

      assert attr(pill, "data-started-at"),
             "amendment 4: the pill must carry a data-started-at attribute for the " <>
               "client-side elapsed-time tick (mirrors trace-map-war-room-elapsed)"
    end

    test "other Logs children and the brand text are unaffected by war_room_active" do
      html =
        render_component(
          &Nebu.Admin.Layouts.live/1,
          base_assigns(%{war_room_active: true, war_room_started_at: ~U[2026-07-08 10:00:00Z]})
        )
        |> Floki.parse_document!()

      assert Floki.find(html, ~s([data-navkey="logs-monitoring"])) != [],
             "amendment 4: unrelated sidebar children must render unchanged"

      assert Floki.text(html) =~ "Nebu Admin",
             "amendment 4: the topbar brand text must remain, alongside the pill"
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # Full-stack integration — a genuinely active session (DB-backed)
  # ══════════════════════════════════════════════════════════════════════

  describe "amendment 4: a real active session shows the dot/pill on an UNRELATED admin page" do
    @describetag :integration

    defp admin_conn(path) do
      %{conn(:get, path) | secret_key_base: @secret_key_base}
      |> @endpoint.admin_session([])
      |> fetch_session()
      |> put_session("current_user", %{
        "admin" => true,
        "sub" => "admin-wr-indicator-tests",
        "matrix_user_id" => "@admin:test.local"
      })
    end

    setup do
      Nebu.Release.migrate()

      Ecto.Adapters.SQL.query(
        Nebu.Repo,
        "UPDATE war_room_sessions SET ended_at = now(), ended_reason = 'manual_stop' WHERE ended_at IS NULL",
        []
      )

      :ok
    end

    test "visible from /admin/logs (an unrelated admin LiveView page), not just the War Room page itself" do
      {:ok, session} =
        Nebu.Admin.WarRoomManager.start_session(%{
          started_by: "@wr-indicator-tests:nebu.example",
          reason: "amendment 4 dot/pill ATDD probe",
          max_entries: 100,
          max_duration_s: 300
        })

      on_exit(fn -> Nebu.Admin.WarRoomManager.stop_session(session.id) end)

      sent_conn = "/admin/logs" |> admin_conn() |> @endpoint.call(@endpoint.init([]))
      {:ok, _view, html} = live(sent_conn)
      doc = Floki.parse_document!(html)

      assert find(doc, ~s([data-testid="nav-war-room-dot"])),
             "amendment 4: 'visible from anywhere' — an active session must show the sidebar " <>
               "dot even while viewing the UNRELATED /admin/logs page, not only the dedicated " <>
               "/admin/logs/war-room page"

      assert find(doc, ~s([data-testid="topbar-war-room-pill"])),
             "amendment 4: the topbar pill must likewise be visible from /admin/logs"
    end
  end
end
