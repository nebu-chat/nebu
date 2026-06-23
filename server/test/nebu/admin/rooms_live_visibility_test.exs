defmodule Nebu.Admin.RoomsLiveVisibilityTest do
  @moduledoc """
  Unit test for the rm1-room-visibility LiveView detail panel (AC1/AC2/AC3/AC5).

  Story-declared behaviour at the LiveView boundary:

      Given RoomsLive mounted in :detail mode for a private room,
      When `handle_event("save_room_settings", %{"visibility" => "public"}, socket)`,
      Then the visibility WRITE boundary is called with (actor, room_id, "public")
      AND the detail panel re-renders showing the new visibility (no full reload).

  ADR-018/ADR-020: there is no repository to mock. The visibility write goes through an
  injectable seam (`:admin_room_visibility_writer`) that falls back to
  `Nebu.Matrix.set_room_visibility/3` in production. The test installs a function-backed
  fake that records the call — the SAME seam shape the LiveView wires.

  Crash/restart test — NOT APPLICABLE: a LiveView holds no durable server state
  (Persistenz-Strategie Option C — stateless, DB-backed; re-mounted from DB on reconnect).
  """
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest

  @endpoint Nebu.Admin.Endpoint

  @room_id "!general:test.local"

  setup do
    test_pid = self()

    writer = fn actor_id, room_id, visibility ->
      send(test_pid, {:set_room_visibility_called, actor_id, room_id, visibility})
      :ok
    end

    Application.put_env(:nebu_http, :admin_room_visibility_writer, writer)

    on_exit(fn -> Application.delete_env(:nebu_http, :admin_room_visibility_writer) end)

    :ok
  end

  defp build_conn_stub do
    Plug.Test.conn(:get, "/admin/rooms/#{@room_id}")
  end

  defp mount_detail do
    live_isolated(build_conn_stub(), Nebu.Admin.RoomsLive,
      session: %{
        "current_user" => %{"admin" => true, "matrix_user_id" => "@admin:test.local"},
        "room_detail" => %{
          "room_id" => @room_id,
          "name" => "general",
          "visibility" => "private",
          "is_auto_join" => false
        }
      }
    )
  end

  test "AC1: detail panel renders a visibility select with the current value pre-selected" do
    {:ok, _view, html} = mount_detail()

    assert html =~ ~s(data-form="room-settings")
    assert html =~ ~s(name="visibility")
    # The current visibility ("private") must be marked selected.
    assert html =~ ~s(<option value="private" selected)
    assert html =~ ~s(data-current-visibility="private")
  end

  test "AC2/AC3: saving public calls the write boundary and the panel reflects public" do
    {:ok, view, _html} = mount_detail()

    html = render_submit(element(view, ~s([data-form="room-settings"])), %{"visibility" => "public"})

    # AC2 — the visibility write boundary was called with (actor, room_id, "public").
    assert_received {:set_room_visibility_called, "@admin:test.local", @room_id, "public"}

    # AC3 — the panel re-renders showing public, no full page reload.
    assert html =~ ~s(data-current-visibility="public")
    assert html =~ ~s(<option value="public" selected)
  end

  test "AC5: an invalid visibility is rejected server-side and never reaches the writer" do
    {:ok, view, _html} = mount_detail()

    html = render_submit(element(view, ~s([data-form="room-settings"])), %{"visibility" => "bogus"})

    refute_received {:set_room_visibility_called, _, _, _}
    assert html =~ "Invalid visibility"
    # Visibility unchanged.
    assert html =~ ~s(data-current-visibility="private")
  end
end
