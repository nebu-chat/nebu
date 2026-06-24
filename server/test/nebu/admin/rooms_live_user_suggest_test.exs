defmodule Nebu.Admin.RoomsLiveUserSuggestTest do
  @moduledoc """
  Story admin-add-user-autocomplete — RoomsLive add-user autocomplete unit tests.

  Mounts the room detail LiveView with admin session assigns + injected members,
  exercises the debounced `suggest_users` handle_event, and asserts the suggestion
  listbox renders matching options. Selecting an option fills the field; submit still
  calls the existing add-member seam (autocomplete is assistive, submit path unchanged).

  The user search routes through the `:admin_user_searcher` app-env seam (so no live
  Repo is needed). The shared suggestion logic lives in `Nebu.Admin.UserSuggest`, used
  by BOTH RoomsLive and SpacesLive.

  Crash/restart — NOT APPLICABLE (Persistenz Option C, stateless DB-backed LiveView).
  """
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest

  @endpoint Nebu.Admin.Endpoint

  @room_id "!general:test.local"
  @admin "@admin:test.local"
  @alex "@alex:localhost"
  @alice "@alice:test.local"

  defp admin_session(extra) do
    Map.merge(%{"current_user" => %{"admin" => true, "matrix_user_id" => @admin}}, extra)
  end

  setup do
    # The add-member seam (submit path stays unchanged).
    test_pid = self()

    Application.put_env(:nebu_http, :admin_member_adder, fn room_id, user_id, actor ->
      send(test_pid, {:add_member_called, room_id, user_id, actor})
      {:ok, "$evt"}
    end)

    Application.put_env(:nebu_http, :admin_member_lister, fn _room_id -> [%{user_id: @admin}] end)

    # The user-search seam: returns matching users for a query, [] otherwise.
    Application.put_env(:nebu_http, :admin_user_searcher, fn query, _limit ->
      cond do
        String.contains?("alex", query) or String.starts_with?(@alex, "@" <> query) or
            String.contains?(@alex, query) ->
          if String.length(query) >= 2 and String.contains?("#{@alex} #{@alice}", query),
            do: [%{user_id: @alex}, %{user_id: @alice}],
            else: []

        true ->
          []
      end
    end)

    on_exit(fn ->
      Application.delete_env(:nebu_http, :admin_member_adder)
      Application.delete_env(:nebu_http, :admin_member_lister)
      Application.delete_env(:nebu_http, :admin_user_searcher)
    end)

    :ok
  end

  defp mount_detail do
    session =
      admin_session(%{
        "room_detail" => %{
          "room_id" => @room_id,
          "name" => "general",
          "status" => "active",
          "visibility" => "private"
        },
        "room_members" => [%{user_id: @admin}],
        "rooms" => []
      })

    live_isolated(Plug.Test.conn(:get, "/admin/rooms/#{@room_id}"), Nebu.Admin.RoomsLive,
      session: session
    )
  end

  test "the add-member input is an ARIA combobox wired for suggestions" do
    {:ok, _view, html} = mount_detail()

    assert html =~ ~s(role="combobox")
    assert html =~ ~s(aria-autocomplete="list")
    assert html =~ ~s(aria-expanded)
    # phx-change drives the debounced suggestion event.
    assert html =~ ~s(phx-change="suggest_users")
    assert html =~ "phx-debounce"
  end

  test "typing >=2 chars renders matching users in a listbox" do
    {:ok, view, _html} = mount_detail()

    html =
      render_change(element(view, ~s([data-form="add-member"])), %{"user_id" => "al"})

    assert html =~ ~s(role="listbox")
    assert html =~ ~s(role="option")
    assert html =~ @alex
    assert html =~ @alice
  end

  test "a query shorter than 2 chars yields no suggestions" do
    {:ok, view, _html} = mount_detail()

    html = render_change(element(view, ~s([data-form="add-member"])), %{"user_id" => "a"})

    refute html =~ ~s(role="option")
  end

  test "a query matching no user shows an empty/no-matches state, not options" do
    {:ok, view, _html} = mount_detail()

    html = render_change(element(view, ~s([data-form="add-member"])), %{"user_id" => "zzzz"})

    refute html =~ ~s(role="option")
  end

  test "selecting a suggestion fills the input with the full Matrix id" do
    {:ok, view, _html} = mount_detail()

    render_change(element(view, ~s([data-form="add-member"])), %{"user_id" => "al"})

    html =
      render_click(element(view, ~s([data-role="user-suggestion"][data-user-id="#{@alex}"])))

    # The input now carries the selected id as its value.
    assert html =~ ~s(value="#{@alex}")
    # And selecting collapses the listbox (no options shown after pick).
    refute html =~ ~s(data-role="user-suggestion" data-user-id="#{@alice}")
  end

  test "the submit (add_member) path is unchanged after using autocomplete" do
    {:ok, view, _html} = mount_detail()

    render_change(element(view, ~s([data-form="add-member"])), %{"user_id" => "al"})
    render_click(element(view, ~s([data-role="user-suggestion"][data-user-id="#{@alex}"])))

    render_submit(element(view, ~s([data-form="add-member"])), %{"user_id" => @alex})

    assert_received {:add_member_called, @room_id, @alex, @admin}
  end
end
