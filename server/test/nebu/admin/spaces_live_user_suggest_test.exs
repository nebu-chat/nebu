defmodule Nebu.Admin.SpacesLiveUserSuggestTest do
  @moduledoc """
  Story admin-add-user-autocomplete — SpacesLive add-user autocomplete unit tests.

  A Space is a room, so the Space detail page gets the SAME add-user typeahead as the
  room detail page, reusing `Nebu.Admin.UserSuggest` + the identical event contract
  (suggest_users / select_user_suggestion / add_member). Adding a member routes through
  the same audited Matrix public-API seam (:admin_member_adder → admin_add_room_member/3).

  Crash/restart — NOT APPLICABLE (Persistenz Option C, stateless DB-backed LiveView).
  """
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest

  @endpoint Nebu.Admin.Endpoint

  @space_id "!engineering:test.local"
  @admin "@admin:test.local"
  @alex "@alex:localhost"
  @alice "@alice:test.local"

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

    # MINOR-2: the roster re-fetch after a successful add routes through the
    # :admin_member_lister seam (a Space is a room → list_room_members on the space id).
    # Returns the just-added user so the roster shows visible confirmation.
    Application.put_env(:nebu_http, :admin_member_lister, fn _room_id ->
      [%{user_id: @alex}]
    end)

    Application.put_env(:nebu_http, :admin_user_searcher, fn query, _limit ->
      if String.length(query) >= 2 and String.contains?("#{@alex} #{@alice}", query),
        do: [%{user_id: @alex}, %{user_id: @alice}],
        else: []
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
        "space_detail" => %{room_id: @space_id, name: "Engineering", topic: "", is_auto_join: false},
        "children" => []
      })

    live_isolated(Plug.Test.conn(:get, "/admin/spaces/#{@space_id}"), Nebu.Admin.SpacesLive,
      session: session
    )
  end

  test "the spaces add-member input is an ARIA combobox wired for suggestions" do
    {:ok, _view, html} = mount_detail()

    assert html =~ ~s(role="combobox")
    assert html =~ ~s(aria-autocomplete="list")
    assert html =~ ~s(phx-change="suggest_users")
    assert html =~ "phx-debounce"
  end

  test "typing >=2 chars renders matching users in a listbox" do
    {:ok, view, _html} = mount_detail()

    html = render_change(element(view, ~s([data-form="add-member"])), %{"user_id" => "al"})

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

  test "selecting a suggestion fills the input and submit adds the member via Matrix" do
    {:ok, view, _html} = mount_detail()

    render_change(element(view, ~s([data-form="add-member"])), %{"user_id" => "al"})

    html =
      render_click(element(view, ~s([data-role="user-suggestion"][data-user-id="#{@alex}"])))

    assert html =~ ~s(value="#{@alex}")

    render_submit(element(view, ~s([data-form="add-member"])), %{"user_id" => @alex})

    assert_received {:add_member_called, @space_id, @alex, @admin}
  end

  test "MINOR-2: a successful add shows visible confirmation (success flash + roster row)" do
    {:ok, view, _html} = mount_detail()

    html = render_submit(element(view, ~s([data-form="add-member"])), %{"user_id" => @alex})

    assert_received {:add_member_called, @space_id, @alex, @admin}

    # Success flash naming the added user.
    assert html =~ ~s(data-role="flash-info")
    assert html =~ "Added #{@alex}"

    # Roster row for the added member (re-fetched via the :admin_member_lister seam).
    assert html =~ ~s(data-role="member-row")
    assert html =~ ~s(data-user-id="#{@alex}")
  end

  test "an invalid user id shows an inline error and does not call the adder" do
    {:ok, view, _html} = mount_detail()

    html = render_submit(element(view, ~s([data-form="add-member"])), %{"user_id" => "not-a-user"})

    refute_received {:add_member_called, _, _, _}
    assert html =~ "Invalid user id"
  end
end
