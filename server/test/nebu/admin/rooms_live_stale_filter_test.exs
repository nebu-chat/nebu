defmodule Nebu.Admin.RoomsLiveStaleFilterTest do
  @moduledoc """
  Story rm2-stale-room-filter — RoomsLive list view: status filter control + badges.

  AC1 — RoomsLive exposes a status filter (all | active | archived | stale).
  AC2 — a stale room (active + 0 members) renders a `badge-warning` "Stale" in the list;
        an active room renders `badge-success` "Active"; archived renders `badge-ghost`.

  ATDD — written FIRST (RED before the filter control + badge helper existed).

  Crash/restart — NOT APPLICABLE (Persistenz Option C, stateless DB-backed LiveView).
  """
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest

  @endpoint Nebu.Admin.Endpoint

  defp build_conn_stub do
    Plug.Test.conn(:get, "/admin/rooms")
  end

  defp mount_list(rooms) do
    live_isolated(build_conn_stub(), Nebu.Admin.RoomsLive,
      session: %{
        "current_user" => %{"admin" => true, "sub" => "admin-1"},
        "rooms" => rooms
      }
    )
  end

  test "AC1: list view renders a status filter control with the four options" do
    {:ok, _view, html} = mount_list([])

    assert html =~ ~s(data-field="status-filter")
    assert html =~ ~s(value="all")
    assert html =~ ~s(value="active")
    assert html =~ ~s(value="archived")
    assert html =~ ~s(value="stale")
  end

  test "AC2: a stale room (active + 0 members) renders the Stale warning badge" do
    rooms = [%{room_id: "!empty:test.local", name: "empty", status: "active", member_count: 0}]
    {:ok, _view, html} = mount_list(rooms)

    assert html =~ "badge-warning"
    assert html =~ "Stale"
    refute html =~ "badge-success"
  end

  test "AC2: an active room with members renders the Active success badge" do
    rooms = [%{room_id: "!busy:test.local", name: "busy", status: "active", member_count: 3}]
    {:ok, _view, html} = mount_list(rooms)

    assert html =~ "badge-success"
    assert html =~ "Active"
    refute html =~ "badge-warning"
  end

  test "AC2: an archived room renders the ghost badge" do
    rooms = [%{room_id: "!old:test.local", name: "old", status: "archived", member_count: 0}]
    {:ok, _view, html} = mount_list(rooms)

    assert html =~ "badge-ghost"
    assert html =~ "Archived"
  end
end
