defmodule Nebu.Admin.SpacesLiveTest do
  @moduledoc """
  Spaces S5 — SpacesLive LiveView unit tests (ATDD, RED before implementation).

  Mirrors `Nebu.Web.AdminLiveViewUnitTest` (RoomsLive): mount the LiveView with admin
  session assigns + injected data and exercise the handle_event handlers, asserting both
  the assigns/DOM diff and that the (injected) write boundary was called.

  ADR-020: the real write path routes through `Nebu.Matrix`. Here, function-backed
  app-env seams record the calls without a live Matrix domain / Postgres — the same
  thin-injectable-boundary pattern RoomsLive uses for `:admin_auto_join_writer`.

  Crash/restart — NOT APPLICABLE (Persistenz Option C, stateless DB-backed LiveView).
  """
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest

  @endpoint Nebu.Admin.Endpoint

  @space_id "!engineering:test.local"
  @child_id "!backend:test.local"

  defp admin_session(extra) do
    Map.merge(
      %{
        "current_user" => %{
          "admin" => true,
          "sub" => "admin-1",
          "matrix_user_id" => "@admin:test.local"
        }
      },
      extra
    )
  end

  setup do
    test_pid = self()

    Application.put_env(:nebu_http, :admin_spaces_creator, fn actor_id, name ->
      send(test_pid, {:create_space_called, actor_id, name})
      {:ok, @space_id}
    end)

    Application.put_env(:nebu_http, :admin_spaces_state_writer, fn room_id, actor_id, type, key, content ->
      send(test_pid, {:set_state_called, room_id, actor_id, type, key, content})
      {:ok, "$evt"}
    end)

    Application.put_env(:nebu_http, :admin_spaces_auto_join_writer, fn actor_id, room_id, value ->
      send(test_pid, {:auto_join_called, actor_id, room_id, value})
      :ok
    end)

    on_exit(fn ->
      Application.delete_env(:nebu_http, :admin_spaces_creator)
      Application.delete_env(:nebu_http, :admin_spaces_state_writer)
      Application.delete_env(:nebu_http, :admin_spaces_auto_join_writer)
    end)

    :ok
  end

  defp conn_stub, do: Plug.Test.conn(:get, "/admin/spaces")

  # ── AC1: list renders only spaces ────────────────────────────────────────────

  test "list renders injected spaces with member + child counts" do
    spaces = [
      %{room_id: @space_id, name: "Engineering", member_count: 3, child_count: 2, is_auto_join: false}
    ]

    {:ok, view, _html} =
      live_isolated(conn_stub(), Nebu.Admin.SpacesLive, session: admin_session(%{"spaces" => spaces}))

    html = render(view)
    assert html =~ "Engineering"
    assert html =~ ~s(data-space-id="#{@space_id}")
  end

  # ── AC2: create space ─────────────────────────────────────────────────────────

  test "create_space calls the Matrix creator and the new space appears in the list" do
    {:ok, view, _html} =
      live_isolated(conn_stub(), Nebu.Admin.SpacesLive, session: admin_session(%{"spaces" => []}))

    render_submit(element(view, ~s([data-form="create-space"])), %{"name" => "Engineering"})

    assert_received {:create_space_called, "@admin:test.local", "Engineering"}
    assert render(view) =~ ~s(data-space-id="#{@space_id}")
  end

  # ── AC5: auto-join toggle persists via the audited writer ──────────────────────

  test "toggle_auto_join updates assigns and calls the audited auto-join writer" do
    spaces = [%{room_id: @space_id, name: "Engineering", member_count: 1, child_count: 0, is_auto_join: false}]

    {:ok, view, _html} =
      live_isolated(conn_stub(), Nebu.Admin.SpacesLive, session: admin_session(%{"spaces" => spaces}))

    refute render(view) =~ ~s(data-space-id="#{@space_id}" data-auto-join="true")

    render_click(element(view, ~s([phx-click="toggle_auto_join"][phx-value-space_id="#{@space_id}"])))

    assert render(view) =~ ~s(data-space-id="#{@space_id}" data-auto-join="true")
    assert_received {:auto_join_called, "@admin:test.local", @space_id, true}
  end

  # ── AC3: detail edit name/topic via authorized set_room_state ──────────────────

  test "save_space writes m.room.name and m.room.topic via the authorized state writer" do
    session =
      admin_session(%{
        "space_detail" => %{room_id: @space_id, name: "Engineering", topic: "", is_auto_join: false},
        "children" => []
      })

    {:ok, view, _html} =
      live_isolated(conn_stub(), Nebu.Admin.SpacesLive, session: session)

    render_submit(element(view, ~s([data-form="edit-space"])), %{
      "name" => "Platform",
      "topic" => "The platform space"
    })

    assert_received {:set_state_called, @space_id, "@admin:test.local", "m.room.name", "", %{"name" => "Platform"}}
    assert_received {:set_state_called, @space_id, "@admin:test.local", "m.room.topic", "", %{"topic" => "The platform space"}}
    assert render(view) =~ "Platform"
  end

  # ── AC4: child add / remove via authorized set_room_state ──────────────────────

  test "add_child writes a non-empty m.space.child and remove_child writes empty content" do
    session =
      admin_session(%{
        "space_detail" => %{room_id: @space_id, name: "Engineering", topic: "", is_auto_join: false},
        "children" => []
      })

    {:ok, view, _html} =
      live_isolated(conn_stub(), Nebu.Admin.SpacesLive, session: session)

    render_submit(element(view, ~s([data-form="add-child"])), %{"child_room_id" => @child_id})

    assert_received {:set_state_called, @space_id, "@admin:test.local", "m.space.child", @child_id, content}
    refute content == %{}
    assert render(view) =~ @child_id

    render_click(element(view, ~s([phx-click="remove_child"][phx-value-child_room_id="#{@child_id}"])))

    assert_received {:set_state_called, @space_id, "@admin:test.local", "m.space.child", @child_id, %{}}
  end

  # ── AC7: non-admin mount of SpacesLive is redirected to /admin/login ───────────
  #
  # The admin gate is the live_session on_mount hook ({Nebu.Admin.Auth, :require_admin}),
  # applied via the router — live_isolated bypasses it. So we assert the gate directly
  # against a SpacesLive socket (same approach as auth_bootstrap_gate_test.exs), with a
  # completed-bootstrap seam so an unauthenticated/non-admin mount routes to /admin/login.
  test "non-admin mount of SpacesLive is redirected to /admin/login (on_mount gate)" do
    store = start_supervised!({Agent, fn -> %{completed: true} end})
    dispatcher = fn :bootstrap_completed?, [] -> {:ok, Agent.get(store, & &1.completed)} end
    Application.put_env(:nebu_http, :admin_bootstrap_store, dispatcher)
    on_exit(fn -> Application.delete_env(:nebu_http, :admin_bootstrap_store) end)

    socket = %Phoenix.LiveView.Socket{view: Nebu.Admin.SpacesLive}

    # Non-admin session.
    assert {:halt, redirected} =
             Nebu.Admin.Auth.on_mount(:require_admin, %{}, %{"current_user" => %{"admin" => false}}, socket)

    assert {:redirect, %{to: "/admin/login"}} = redirected.redirected
  end
end
