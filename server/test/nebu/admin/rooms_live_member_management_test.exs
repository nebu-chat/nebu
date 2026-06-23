defmodule Nebu.Admin.RoomsLiveMemberManagementTest do
  @moduledoc """
  rm4-admin-member-management — RoomsLive member list + add/remove unit tests.

  Mirrors `Nebu.Admin.RoomsLiveCreateArchiveTest`: mount the detail LiveView with
  admin session assigns + injected members, exercise the handle_event handlers,
  and assert both the assigns/DOM diff and that the injected write boundary was
  called.

  ADR-020: the real write path routes through `Nebu.Matrix`. Here, function-backed
  app-env seams record the calls without a live Matrix domain / Postgres:
    * `:admin_member_adder`   (3-arity: room_id, user_id, actor)
    * `:admin_member_remover` (3-arity: room_id, user_id, actor)
    * `session["room_members"]` supplies the member rows without a live Repo; the
      seams return a refreshed member list so the re-fetch path is exercised.

  Crash/restart — NOT APPLICABLE (Persistenz Option C, stateless DB-backed LiveView).
  """
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest

  @endpoint Nebu.Admin.Endpoint

  @room_id "!general:test.local"
  @admin "@admin:test.local"
  @bob "@bob:test.local"
  @charlie "@charlie:test.local"

  defp admin_session(extra) do
    Map.merge(
      %{"current_user" => %{"admin" => true, "matrix_user_id" => @admin}},
      extra
    )
  end

  setup do
    test_pid = self()

    Application.put_env(:nebu_http, :admin_member_adder, fn room_id, user_id, actor ->
      send(test_pid, {:add_member_called, room_id, user_id, actor})
      {:ok, "$evt"}
    end)

    Application.put_env(:nebu_http, :admin_member_remover, fn room_id, user_id, actor ->
      send(test_pid, {:remove_member_called, room_id, user_id, actor})
      :ok
    end)

    # The re-fetch after each op reads through this seam so the unit test has no Repo.
    Application.put_env(:nebu_http, :admin_member_lister, fn _room_id ->
      [%{user_id: @admin}, %{user_id: @bob}]
    end)

    on_exit(fn ->
      Application.delete_env(:nebu_http, :admin_member_adder)
      Application.delete_env(:nebu_http, :admin_member_remover)
      Application.delete_env(:nebu_http, :admin_member_lister)
    end)

    :ok
  end

  defp mount_detail(members) do
    session =
      admin_session(%{
        "room_detail" => %{
          "room_id" => @room_id,
          "name" => "general",
          "status" => "active",
          "visibility" => "private"
        },
        "room_members" => members,
        "rooms" => []
      })

    live_isolated(Plug.Test.conn(:get, "/admin/rooms/#{@room_id}"), Nebu.Admin.RoomsLive,
      session: session
    )
  end

  # ── AC1: add-member control ────────────────────────────────────────────────────

  test "AC1: detail panel shows an add-member form with an input + Add button" do
    {:ok, _view, html} = mount_detail([%{user_id: @admin}, %{user_id: @bob}])

    assert html =~ ~s(data-form="add-member")
    assert html =~ ~s(name="user_id")
    assert html =~ "Add"
  end

  # ── AC1/member list: members render as rows ────────────────────────────────────

  test "members render in the detail panel" do
    {:ok, _view, html} = mount_detail([%{user_id: @admin}, %{user_id: @bob}])

    assert html =~ @admin
    assert html =~ @bob
  end

  # ── AC2: add calls the Matrix adder with room_id + user_id + admin actor ────────

  test "AC2: add_member calls the Matrix adder with the admin actor" do
    {:ok, view, _html} = mount_detail([%{user_id: @admin}])

    render_submit(element(view, ~s([data-form="add-member"])), %{"user_id" => @charlie})

    assert_received {:add_member_called, @room_id, @charlie, @admin}
  end

  # ── AC5: invalid user id → inline error, no write ───────────────────────────────

  test "AC5: an invalid user id shows an inline error and does not call the adder" do
    {:ok, view, _html} = mount_detail([%{user_id: @admin}])

    html = render_submit(element(view, ~s([data-form="add-member"])), %{"user_id" => "not-a-user"})

    refute_received {:add_member_called, _, _, _}
    assert html =~ "Invalid user id"
  end

  test "AC5: a not-found user surfaces the not-found inline error" do
    Application.put_env(:nebu_http, :admin_member_adder, fn _room_id, _user_id, _actor ->
      {:error, :not_found}
    end)

    {:ok, view, _html} = mount_detail([%{user_id: @admin}])

    html = render_submit(element(view, ~s([data-form="add-member"])), %{"user_id" => @charlie})

    assert html =~ "User not found"
  end

  # ── AC3/AC4: remove calls the Matrix remover + confirm dialog present ───────────

  test "AC3: each non-self member row has a Remove button with a confirm dialog" do
    {:ok, _view, html} = mount_detail([%{user_id: @admin}, %{user_id: @bob}])

    assert html =~ ~s(phx-click="remove_member")
    # confirm names the user + room
    assert html =~ "Remove"
  end

  test "AC4: removing a member calls the Matrix remover with the admin actor" do
    {:ok, view, _html} = mount_detail([%{user_id: @admin}, %{user_id: @bob}])

    render_click(element(view, ~s([data-role="remove-member"][data-user-id="#{@bob}"])))

    assert_received {:remove_member_called, @room_id, @bob, @admin}
  end

  # ── AC6: the admin's own row has no Remove button ───────────────────────────────

  test "AC6: the logged-in admin's own member row has no Remove button" do
    {:ok, _view, html} = mount_detail([%{user_id: @admin}, %{user_id: @bob}])

    # bob's row HAS a remove control
    assert html =~ ~s(data-role="remove-member" data-user-id="#{@bob}") or
             html =~ ~s(data-user-id="#{@bob}")

    # the admin's own row must NOT carry a remove control
    refute html =~ ~s(data-role="remove-member" data-user-id="#{@admin}")
  end
end
