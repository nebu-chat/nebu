defmodule Nebu.Admin.LogsLive.WarRoomPanelRetirementTest do
  @moduledoc """
  RED-phase ATDD tests for `enhanced-logging/war-room-dedicated-page`,
  Story Amendment 2 (2026-07-08) — retiring the embedded
  `Nebu.Admin.LogsLive.WarRoomPanel.war_room_panel/1` from `/admin/logs`
  (Live Stream) now that the dedicated `/admin/logs/war-room` page exists.

  Story: docs/stories/enhanced-logging/war-room-dedicated-page.md

  ## Why this MUST FAIL right now

  `Nebu.Admin.LogsLive`'s `render/1` (`server/lib/nebu/admin/logs_live.ex`,
  around line 1007) still renders `<WarRoomPanel.war_room_panel
  war_room={@war_room} />` unconditionally — exactly the markup this file
  asserts ABSENT below (the mirror image of every assertion in
  `logs_live_test.exs`'s own "AC11: War Room panel" describe blocks, which
  still expect `[data-testid="war-room-panel"]`/`[data-testid=
  "start-war-room-button"]`/etc. to be PRESENT — updating THAT large,
  pre-existing suite is the dev-story's job, mirroring exactly how
  `trace_map_retirement_test.exs` did the same thing for the Endpoints
  dimension's own retirement in `trace-map-leitstand`, AC13).

  ## What amendment 2 requires, and what stays

    * REMOVED from `/admin/logs`: the embedded "start a new session" panel
      (`WarRoomPanel.war_room_panel/1` — the `[data-testid="war-room-panel"]`
      container, its `[data-testid="war-room-start-form"]`, and the
      `[data-testid="start-war-room-button"]`/`[data-testid=
      "stop-war-room-button"]` controls). This entire "start a new session"
      form moves to the new `/admin/logs/war-room` page (this story's own
      AC7/AC8).
    * KEPT on `/admin/logs`, unchanged: the pre-existing
      `[data-testid="war-room-viewing-banner"]` (the read-only "Viewing War
      Room session {id}" banner shown when `?war_room_id=...` is present —
      a DIFFERENT, pre-existing feature from `war-room-mode`'s own AC12,
      not superseded by this story), the request-stream rows, the detail
      panel, and the Levels/Sources Trace Map bubbles — none of those are
      in scope for amendment 2.
    * `WarRoomPanel`'s status-badge/warning sub-components MAY be reused by
      the new page "if convenient" (amendment 2's own wording) — this file
      does not assert either way on internal reuse, only on `/admin/logs`'s
      own observable render contract, per the identical
      `trace_map_retirement_test.exs` precedent.
  """

  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest

  @endpoint Nebu.Admin.Endpoint
  @admin_session %{
    "current_user" => %{"admin" => true, "sub" => "admin-war-room-panel-retirement-tests"}
  }

  defp mount_logs_live(session \\ @admin_session) do
    live_isolated(Plug.Test.conn(:get, "/admin/logs"), Nebu.Admin.LogsLive, session: session)
  end

  defp parsed(html), do: Floki.parse_document!(html)
  defp find(html, selector), do: html |> Floki.find(selector) |> List.first()

  describe "amendment 2: the embedded War Room start/stop panel is gone from /admin/logs" do
    test "no [data-testid=\"war-room-panel\"] renders on the Live Stream page" do
      {:ok, _view, html} = mount_logs_live()
      doc = parsed(html)

      refute find(doc, ~s([data-testid="war-room-panel"])),
             "amendment 2: the embedded War Room panel must be removed from /admin/logs " <>
               "now that /admin/logs/war-room is the dedicated page for starting a session"
    end

    test "no [data-testid=\"war-room-start-form\"] renders on the Live Stream page" do
      {:ok, _view, html} = mount_logs_live()
      doc = parsed(html)

      refute find(doc, ~s([data-testid="war-room-start-form"])),
             "amendment 2: the 'start a new session' form moves entirely to the dedicated page"
    end

    test "no [data-testid=\"start-war-room-button\"] or [data-testid=\"stop-war-room-button\"] renders" do
      {:ok, _view, html} = mount_logs_live()
      doc = parsed(html)

      refute find(doc, ~s([data-testid="start-war-room-button"])),
             "amendment 2: starting a session no longer happens from /admin/logs"

      refute find(doc, ~s([data-testid="stop-war-room-button"])),
             "amendment 2: stopping a session no longer happens from /admin/logs"
    end

    test "the page no longer renders the '🚨 Start War Room' / '🚨 War Room Active' panel copy" do
      {:ok, _view, html} = mount_logs_live()

      refute html =~ "🚨 Start War Room",
             "amendment 2: the panel's inactive-state copy must be gone from /admin/logs"

      refute html =~ "🚨 War Room Active",
             "amendment 2: the panel's active-state copy must be gone from /admin/logs"
    end
  end
end
