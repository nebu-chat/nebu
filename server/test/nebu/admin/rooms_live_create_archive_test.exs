defmodule Nebu.Admin.RoomsLiveCreateArchiveTest do
  @moduledoc """
  rm3-admin-create-archive — RoomsLive create-modal + archive/unarchive unit tests.

  Mirrors `Nebu.Admin.SpacesLiveTest` / `RoomsLiveVisibilityTest`: mount the LiveView
  with admin session assigns + injected data, exercise the handle_event handlers, and
  assert both the assigns/DOM diff and that the injected write boundary was called.

  ADR-020: the real write path routes through `Nebu.Matrix`. Here, function-backed
  app-env seams record the calls without a live Matrix domain / Postgres:
    * `:admin_room_creator`    (2-arity: actor, opts)
    * `:admin_room_archiver`   (2-arity: actor, room_id)
    * `:admin_room_unarchiver` (2-arity: actor, room_id)

  Crash/restart — NOT APPLICABLE (Persistenz Option C, stateless DB-backed LiveView).
  """
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest

  @endpoint Nebu.Admin.Endpoint

  @room_id "!general:test.local"

  defp admin_session(extra) do
    Map.merge(
      %{"current_user" => %{"admin" => true, "matrix_user_id" => "@admin:test.local"}},
      extra
    )
  end

  setup do
    test_pid = self()

    Application.put_env(:nebu_http, :admin_room_creator, fn actor, opts ->
      send(test_pid, {:create_room_called, actor, opts})
      {:ok, @room_id}
    end)

    Application.put_env(:nebu_http, :admin_room_archiver, fn actor, room_id ->
      send(test_pid, {:archive_called, actor, room_id})
      :ok
    end)

    Application.put_env(:nebu_http, :admin_room_unarchiver, fn actor, room_id ->
      send(test_pid, {:unarchive_called, actor, room_id})
      :ok
    end)

    on_exit(fn ->
      Application.delete_env(:nebu_http, :admin_room_creator)
      Application.delete_env(:nebu_http, :admin_room_archiver)
      Application.delete_env(:nebu_http, :admin_room_unarchiver)
    end)

    :ok
  end

  defp conn_stub, do: Plug.Test.conn(:get, "/admin/rooms")

  defp mount_index(extra \\ %{"rooms" => []}) do
    live_isolated(conn_stub(), Nebu.Admin.RoomsLive, session: admin_session(extra))
  end

  defp mount_detail(room_detail) do
    live_isolated(Plug.Test.conn(:get, "/admin/rooms/#{@room_id}"), Nebu.Admin.RoomsLive,
      session: admin_session(%{"room_detail" => room_detail, "rooms" => []})
    )
  end

  # ── AC1: Create room button + modal ───────────────────────────────────────────

  test "AC1: list header shows a Create room button + a modal with name + visibility" do
    {:ok, _view, html} = mount_index()

    assert html =~ "Create room"
    assert html =~ ~s(data-form="create-room")
    assert html =~ ~s(name="name")
    assert html =~ ~s(name="visibility")
  end

  # ── AC2/AC4: create on submit ──────────────────────────────────────────────────

  test "AC2: create_room calls the Matrix creator with name + visibility" do
    {:ok, view, _html} = mount_index()

    render_submit(element(view, ~s([data-form="create-room"])), %{
      "name" => "General",
      "visibility" => "public"
    })

    assert_received {:create_room_called, "@admin:test.local", opts}
    assert opts[:name] == "General"
    assert opts[:visibility] == "public"
  end

  # ── AC3: create validation inline ──────────────────────────────────────────────

  test "AC3: empty name shows 'Name is required' and does not call the creator" do
    {:ok, view, _html} = mount_index()

    html = render_submit(element(view, ~s([data-form="create-room"])), %{"name" => "", "visibility" => "private"})

    refute_received {:create_room_called, _, _}
    assert html =~ "Name is required"
  end

  test "AC3: name > 100 chars shows the length error and does not call the creator" do
    {:ok, view, _html} = mount_index()
    too_long = String.duplicate("x", 101)

    html =
      render_submit(element(view, ~s([data-form="create-room"])), %{
        "name" => too_long,
        "visibility" => "private"
      })

    refute_received {:create_room_called, _, _}
    assert html =~ "Name must be at most 100 characters"
  end

  test "AC2: visibility outside the allowlist is rejected server-side" do
    {:ok, view, _html} = mount_index()

    html =
      render_submit(element(view, ~s([data-form="create-room"])), %{
        "name" => "General",
        "visibility" => "bogus"
      })

    refute_received {:create_room_called, _, _}
    assert html =~ "Invalid visibility"
  end

  # ── AC5/AC7: archive / unarchive button visibility transitions ─────────────────

  test "AC5: active room detail shows an Archive control, no Unarchive" do
    {:ok, _view, html} =
      mount_detail(%{"room_id" => @room_id, "name" => "general", "status" => "active", "visibility" => "private"})

    assert html =~ "Archive room"
    assert html =~ ~s(phx-click="archive_room")
    refute html =~ ~s(phx-click="unarchive_room")
  end

  test "AC5/AC7: archiving flips to Archived badge + Unarchive control + flash" do
    {:ok, view, _html} =
      mount_detail(%{"room_id" => @room_id, "name" => "general", "status" => "active", "visibility" => "private"})

    html = render_click(element(view, ~s([phx-click="archive_room"])))

    assert_received {:archive_called, "@admin:test.local", @room_id}

    # AC7 — Archived badge, Unarchive control, Archive hidden, success flash.
    assert html =~ "Unarchive"
    assert html =~ ~s(phx-click="unarchive_room")
    refute html =~ ~s(phx-click="archive_room")
    assert html =~ "Room archived"
    assert html =~ ~s(data-status="archived")
  end

  test "AC7: archived room detail shows Unarchive; unarchiving flips back to active" do
    {:ok, view, html} =
      mount_detail(%{"room_id" => @room_id, "name" => "general", "status" => "archived", "visibility" => "private"})

    assert html =~ "Unarchive"
    refute html =~ ~s(phx-click="archive_room")

    after_html = render_click(element(view, ~s([phx-click="unarchive_room"])))

    assert_received {:unarchive_called, "@admin:test.local", @room_id}
    assert after_html =~ "Room unarchived"
    assert after_html =~ ~s(phx-click="archive_room")
    refute after_html =~ ~s(phx-click="unarchive_room")
  end

  # ── AC8: archive of a non-existent room → error flash, no crash ────────────────

  test "AC8: a not_found archive shows a 'Room not found' flash, no crash" do
    Application.put_env(:nebu_http, :admin_room_archiver, fn _actor, _room_id ->
      {:error, :not_found}
    end)

    {:ok, view, _html} =
      mount_detail(%{"room_id" => @room_id, "name" => "general", "status" => "active", "visibility" => "private"})

    html = render_click(element(view, ~s([phx-click="archive_room"])))

    assert html =~ "Room not found"
    # Still active — the archive did not take effect.
    assert html =~ ~s(phx-click="archive_room")
  end
end
