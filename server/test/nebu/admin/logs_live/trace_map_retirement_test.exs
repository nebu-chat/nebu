defmodule Nebu.Admin.LogsLive.TraceMapRetirementTest do
  @moduledoc """
  RED-phase ATDD tests for `enhanced-logging/trace-map-leitstand`, AC13
  (retiring the embedded Trace Map from the `/admin/logs` Live Stream page).

  Story: docs/stories/enhanced-logging/trace-map-leitstand.md

  ## Why this MUST FAIL right now

  `Nebu.Admin.LogsLive`'s `render/1` (`server/lib/nebu/admin/logs_live.ex`,
  the "Endpoints" section around line 1056) still renders
  `Nebu.Admin.LogsLive.TraceMapTree.endpoint_tree/1` — the embedded,
  flat/hierarchical Endpoint-dimension Trace Map this story retires from the
  Live Stream page in favor of the new dedicated `/admin/logs/trace-map`
  page. These tests currently FAIL because that markup is exactly what is
  asserted ABSENT below (the opposite of every existing assertion in
  `logs_live_test.exs`, which still expects `[data-testid="trace-map-tree"]`
  to be present — see AC13's own text: "Update the relevant tests to
  reflect the removal of endpoint filtering from `/admin/logs`", which is
  the dev-story's job for THAT file; this NEW file exists precisely so the
  ATDD step does not have to hand-edit the large, pre-existing
  `logs_live_test.exs` suite wholesale).

  ## What AC13 requires, and what stays

    * REMOVED from `/admin/logs`: the "Endpoints" dimension section
      entirely (`TraceMapTree.endpoint_tree/1` and, transitively, every
      `TraceMapBubble` instance rendered for `dimension: :endpoint`) — this
      dimension moves to the new radial map page.
    * KEPT on `/admin/logs`, unchanged: the "Levels" and "Sources"
      dimension sections (`TraceMapBubble` instances for `dimension: :level`
      / `dimension: :source`), the request-stream rows, the detail panel,
      and the War Room panel — none of those are in scope for this story.

  ## `TraceMapBubble`/`TraceMapTree` component retirement (AC13's own
  "Dev Notes" — component-level decision, not testable here)

  AC13 asks the dev to explicitly DOCUMENT (in the story's own Dev Notes,
  not in a test) whether `Nebu.Admin.LogsLive.TraceMapBubble` and
  `Nebu.Admin.LogsLive.TraceMapTree` are kept (reused by the new Leitstand
  page or its legend) or deleted. This file does not assert either way — it
  only pins down the OBSERVABLE render contract of `/admin/logs` itself, per
  the moduledoc-level "why this MUST FAIL" note above.
  """

  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest

  @endpoint Nebu.Admin.Endpoint
  @admin_session %{"current_user" => %{"admin" => true, "sub" => "admin-trace-map-retirement-tests"}}

  defp mount_logs_live(session \\ @admin_session) do
    live_isolated(Plug.Test.conn(:get, "/admin/logs"), Nebu.Admin.LogsLive, session: session)
  end

  defp parsed(html), do: Floki.parse_document!(html)
  defp find(html, selector), do: html |> Floki.find(selector) |> List.first()
  defp find_all(html, selector), do: Floki.find(html, selector)

  describe "AC13: the Endpoints dimension (Trace Map tree/bubbles) is gone from /admin/logs" do
    test "no [data-testid=\"trace-map-tree\"] renders on the Live Stream page" do
      {:ok, _view, html} = mount_logs_live()
      doc = parsed(html)

      refute find(doc, ~s([data-testid="trace-map-tree"])),
             "AC13: the hierarchical Endpoint tree must be removed from /admin/logs " <>
               "(it now lives on the dedicated /admin/logs/trace-map page)"

      refute find(doc, ~s([data-testid="trace-map-bubble"][data-bubble-dimension="endpoint"])),
             "AC13: no endpoint-dimension bubble may remain on /admin/logs, " <>
               "even as a flat (non-tree) list"
    end

    test "the page no longer advertises an \"Endpoints\" section heading" do
      {:ok, _view, html} = mount_logs_live()
      doc = parsed(html)

      headings = doc |> find_all("h3") |> Enum.map(&Floki.text/1)
      refute Enum.any?(headings, &(&1 =~ "Endpoints")),
             "AC13: the \"Endpoints\" dimension heading must be removed alongside its content"
    end
  end

  describe "AC13: the Levels and Sources dimensions are UNCHANGED and still present" do
    test "level bubbles (DEBUG/INFO/WARN/ERROR-equivalent) are still rendered" do
      {:ok, _view, html} = mount_logs_live()
      doc = parsed(html)

      for level <- ["error", "warning", "info", "debug"] do
        assert find(doc, ~s([data-testid="trace-map-bubble"][data-bubble-dimension="level"][data-bubble-value="#{level}"])),
               "AC13: the \"#{level}\" level bubble must remain on /admin/logs, unchanged"
      end
    end

    test "source bubbles (http/ecto/other) are still rendered" do
      {:ok, _view, html} = mount_logs_live()
      doc = parsed(html)

      for source <- ["http", "ecto", "other"] do
        assert find(doc, ~s([data-testid="trace-map-bubble"][data-bubble-dimension="source"][data-bubble-value="#{source}"])),
               "AC13: the \"#{source}\" source bubble must remain on /admin/logs, unchanged"
      end
    end
  end
end
