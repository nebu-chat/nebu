defmodule Nebu.Web.AdminLiveViewUnitTest do
  @moduledoc """
  RED-phase ATDD unit test for the `admin-ui-migration` story — AC2 at the
  LiveView boundary.

  Story-declared test (test #4):

      Given a LiveView mounted with admin assigns,
      When `handle_event("toggle_auto_join", %{"room_id" => id}, socket)` is called,
      Then `socket.assigns.rooms` is updated AND a DB call to `update_auto_join`
      is made.

  ## ADR-018 compliance

  There is NO repository / schema / service layer to mock. The auto-join write is
  inline SQL (`UPDATE rooms SET is_auto_join = $1 WHERE room_id = $2`) living in the
  LiveView's `handle_event/3`, executed against `Nebu.Repo` via
  `Ecto.Adapters.SQL.query/3`.

  To assert "a DB call to `update_auto_join` was made" WITHOUT a repository mock and
  WITHOUT a live Postgres in the unit suite, we use the project's established
  thin-injectable-boundary pattern (see `Nebu.Web.MediaFakes` + `Application.get_env`
  seams in media/db.ex): the LiveView reads an injectable writer from app env
  (`:admin_auto_join_writer`) and falls back to the real inline SQL when unset. The
  test installs a function-backed fake that records the call. The fake is the SAME
  seam shape the dev step will wire — it is NOT a domain repository. The actual SQL
  remains inline in the LiveView; only its execution point is injectable for tests.

  ## Why this MUST FAIL now (RED)

    * `phoenix` / `phoenix_live_view` are not yet dependencies of `nebu_http`
      (see test/nebu_http/http_foundation_test.exs DepsTest — only :bandit is wired).
      `Phoenix.LiveViewTest` and `Phoenix.LiveView.Socket` therefore do not compile.
    * `Nebu.Admin.RoomsLive` does not exist — there is no LiveView module, no
      mount/3, and no handle_event("toggle_auto_join", ...).

    The dev step adds the deps and the module; this test then turns GREEN.

  ## Crash/restart test — NOT APPLICABLE

  A LiveView holds no durable server state: per-connection socket assigns are derived
  from the DB on mount, and the source of truth is `rooms.is_auto_join` in Postgres.
  There is no GenServer state to recover, so no `Process.exit(:kill)` recovery test is
  required (ADR/CLAUDE.md Persistenz-Strategie: Option C — stateless, DB-backed).
  """
  use ExUnit.Case, async: false

  # RED: this import fails to compile until phoenix_live_view is a dependency.
  import Phoenix.LiveViewTest

  # `live_isolated/3` reads the endpoint from the caller module's `@endpoint`
  # attribute at compile time (Phoenix.LiveViewTest), raising "no @endpoint set in
  # test module" otherwise. The dev step (admin-ui-migration) added this single
  # required attribute — it points at the real Admin LiveView endpoint configured
  # for :nebu_http (config/test.exs). No behavioural change to the assertions below.
  @endpoint Nebu.Admin.Endpoint

  @room_id "!general:test.local"

  setup do
    # Install the function-backed write boundary (ADR-018: inline SQL execution point,
    # injected only for the unit suite — NOT a repository abstraction).
    test_pid = self()

    writer = fn room_id, value ->
      send(test_pid, {:update_auto_join_called, room_id, value})
      :ok
    end

    Application.put_env(:nebu_http, :admin_auto_join_writer, writer)

    # Initial room list the LiveView would have loaded on mount: "general" is OFF.
    rooms = [%{room_id: @room_id, name: "general", is_auto_join: false}]

    on_exit(fn -> Application.delete_env(:nebu_http, :admin_auto_join_writer) end)

    {:ok, rooms: rooms}
  end

  test "handle_event toggle_auto_join updates assigns and calls the DB writer", %{rooms: rooms} do
    # Mount the LiveView with admin assigns (admin gate satisfied) and a known room list.
    # `live_isolated` mounts the module without a full Endpoint/router; the dev step's
    # mount/3 must accept these session assigns.
    {:ok, view, _html} =
      live_isolated(build_conn_stub(), Nebu.Admin.RoomsLive,
        session: %{
          "current_user" => %{"admin" => true, "sub" => "admin-1"},
          "rooms" => rooms
        }
      )

    # The room starts rendered as auto-join OFF.
    refute render(view) =~ ~s(data-room-id="#{@room_id}" data-auto-join="true")

    # Fire the toggle event the story names exactly.
    render_click(element(view, ~s([phx-click="toggle_auto_join"][phx-value-room_id="#{@room_id}"])))

    # Assertion 1 — socket.assigns.rooms updated: the rendered DOM now reflects ON.
    assert render(view) =~ ~s(data-room-id="#{@room_id}" data-auto-join="true")

    # Assertion 2 — a DB call to update_auto_join was made with (room_id, true).
    assert_received {:update_auto_join_called, @room_id, true}
  end

  # Minimal Plug.Conn stub for live_isolated/3. The real connect info is irrelevant to
  # this handle_event assertion; the dev step's mount/3 must tolerate a bare conn.
  defp build_conn_stub do
    Plug.Test.conn(:get, "/admin/rooms")
  end
end
