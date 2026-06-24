defmodule Nebu.Admin.SpacesLive do
  @moduledoc """
  Space Management LiveView (Spaces S5).

  Mirrors `Nebu.Admin.RoomsLive` for Matrix Spaces (rooms with
  `room_type = 'm.space'`). Two live_actions behind the `{Nebu.Admin.Auth,
  :require_admin}` on_mount gate:

    * `:index`  → `/admin/spaces` — lists all Spaces (name, member count, child
      count, per-Space auto-join toggle) and a "Create Space" form (AC1, AC2, AC5).
    * `:detail` → `/admin/spaces/:space_id` — a single Space: edit name/topic, the
      child-room list with add/remove, and the auto-join toggle (AC3, AC4, AC5).

  ## ADR-020 — Admin → Matrix public API only

  All Space writes go through `Nebu.Matrix` (the Matrix domain's only public entry
  point), never into Matrix internals: create via `Nebu.Matrix.create_space/2`,
  name/topic + child edges via `Nebu.Matrix.set_space_state/5` (the S2 authorized
  `set_room_state` path — allowlist + membership + power level), children read via
  `Nebu.Matrix.get_space_children/1`, and the auto-join flag via the audited
  `Nebu.Matrix.set_room_auto_join/3` (AC5, AC7). Reads of the Space list/detail use
  `Nebu.Admin.DB.list_spaces/4` and `get_space/1` (inline SQL, ADR-018).

  The acting identity is the operator's Matrix user id (`current_user["matrix_user_id"]`,
  set at login from the SAME claims `/login` uses) — so admin writes are attributed to
  a real Matrix user and the S2 authorization applies (no unauthorised write path, AC7).

  ## Persistenz-Strategie — Option C (stateless, DB-backed)

  A LiveView holds no durable server state: socket assigns are derived from the DB on
  mount, the source of truth is Postgres (rooms / events). A crashed LiveView is
  re-mounted from the DB on the next connect — no GenServer state to recover, so no
  crash/restart test is required.

  ## Test seams

  Mirrors the RoomsLive `:admin_auto_join_writer` pattern. Unit tests inject:

    * `session["spaces"]` / `session["space_detail"]` / `session["children"]` to
      supply data without a live Repo, and
    * function-backed app-env seams for the writes so assertions can record the call
      without a real Matrix domain / Postgres:
      `:admin_spaces_creator`, `:admin_spaces_state_writer`,
      `:admin_spaces_auto_join_writer`.

  Each seam falls back to the real `Nebu.Matrix` / `Nebu.Admin.DB` call when unset
  (production default) — the seam is the execution point, not a domain abstraction.
  """
  use Phoenix.LiveView, layout: {Nebu.Admin.Layouts, :live}

  @impl Phoenix.LiveView
  def mount(params, session, socket) do
    actor_id =
      case session["current_user"] do
        %{"matrix_user_id" => uid} when is_binary(uid) and uid != "" -> uid
        %{"sub" => sub} when is_binary(sub) -> sub
        _ -> nil
      end

    socket =
      socket
      |> assign(
        page_title: "Spaces",
        active_nav: "spaces",
        actor_id: actor_id,
        create_error: nil,
        detail_error: nil,
        # :index | :detail — overridden by handle_params (route-driven) in production;
        # in the unit suite a `space_detail` in the injected session selects detail mode
        # directly (live_isolated does not run handle_params for a dynamic segment).
        view_mode: :index,
        space: nil,
        children: [],
        child_input: "",
        # admin-add-user-autocomplete: shared add-user typeahead state (the add-member
        # field below reuses Nebu.Admin.UserSuggest + the same event contract as RoomsLive).
        add_member_user_id: "",
        user_suggestions: [],
        member_error: nil,
        # MINOR-2: render a member roster so a successful add has visible confirmation
        # (a Space is a room — reuse the RoomsLive member-fetch seam on the space room_id).
        members: []
      )
      |> assign(:spaces, load_spaces(session))
      |> assign(:injected_session, session)

    # Detail view selection. Production: the `/admin/spaces/:space_id` route supplies
    # `params["space_id"]`. Unit suite: a `space_detail` in the injected session selects
    # detail mode (live_isolated has no router params). We deliberately do NOT define
    # handle_params/3 — that would force every mount through the router live/3 macro and
    # break live_isolated/3 (the RoomsLive unit-test pattern).
    # live_isolated passes params as the atom :not_mounted_at_router (not a map), so
    # guard before indexing.
    param_space_id = if is_map(params), do: params["space_id"], else: nil

    detail_space_id =
      param_space_id ||
        case session["space_detail"] do
          %{} = sd -> sd["room_id"] || sd[:room_id]
          _ -> nil
        end

    socket =
      if detail_space_id do
        socket
        |> assign(:view_mode, :detail)
        |> assign_detail(detail_space_id, session)
      else
        socket
      end

    {:ok, socket}
  end

  # ── AC2: Create Space ────────────────────────────────────────────────────────

  @impl Phoenix.LiveView
  def handle_event("create_space", %{"name" => name}, socket) do
    name = String.trim(name || "")

    case create_space(socket.assigns.actor_id, name) do
      {:ok, room_id} ->
        new_space = %{
          room_id: room_id,
          name: name,
          status: "active",
          member_count: 1,
          child_count: 0,
          is_auto_join: false
        }

        {:noreply,
         socket
         |> assign(:spaces, socket.assigns.spaces ++ [new_space])
         |> assign(:create_error, nil)}

      {:error, reason} ->
        {:noreply, assign(socket, :create_error, "Could not create space: #{inspect(reason)}")}
    end
  end

  # ── AC5: auto-join toggle (audited) ────────────────────────────────────────────

  @impl Phoenix.LiveView
  def handle_event("toggle_auto_join", %{"space_id" => space_id}, socket) do
    current_value =
      cond do
        socket.assigns.space && socket.assigns.space.room_id == space_id ->
          socket.assigns.space.is_auto_join

        true ->
          case Enum.find(socket.assigns.spaces, &(&1.room_id == space_id)) do
            %{is_auto_join: v} -> v
            _ -> false
          end
      end

    new_value = !current_value

    :ok = set_auto_join(socket.assigns.actor_id, space_id, new_value)

    spaces =
      Enum.map(socket.assigns.spaces, fn s ->
        if s.room_id == space_id, do: %{s | is_auto_join: new_value}, else: s
      end)

    space =
      if socket.assigns.space && socket.assigns.space.room_id == space_id,
        do: %{socket.assigns.space | is_auto_join: new_value},
        else: socket.assigns.space

    {:noreply, socket |> assign(:spaces, spaces) |> assign(:space, space)}
  end

  # ── admin-add-user-autocomplete: add-user typeahead (shared with RoomsLive) ─────
  # A Space is a room, so adding a member routes through the same audited Matrix
  # public-API path (admin_add_room_member/3, ADR-020) the room add-member uses. The
  # suggestion query reuses Nebu.Admin.UserSuggest (shared helper, same event contract).

  @impl Phoenix.LiveView
  def handle_event("suggest_users", params, socket) do
    query = params["user_id"] || ""

    {:noreply,
     socket
     |> assign(:add_member_user_id, query)
     |> assign(:user_suggestions, Nebu.Admin.UserSuggest.search(query))}
  end

  @impl Phoenix.LiveView
  def handle_event("select_user_suggestion", %{"user_id" => user_id}, socket) do
    {:noreply,
     socket
     |> assign(:add_member_user_id, user_id)
     |> assign(:user_suggestions, [])}
  end

  @impl Phoenix.LiveView
  def handle_event("dismiss_user_suggestions", _params, socket) do
    {:noreply, assign(socket, :user_suggestions, [])}
  end

  @impl Phoenix.LiveView
  def handle_event("add_member", params, socket) do
    space = socket.assigns.space
    user_id = String.trim(params["user_id"] || "")

    cond do
      is_nil(space) ->
        {:noreply, socket}

      not Nebu.Matrix.UserId.valid?(user_id) ->
        {:noreply, assign(socket, :member_error, "Invalid user id")}

      true ->
        case add_member(space.room_id, user_id, socket.assigns.actor_id) do
          {:ok, _} ->
            # MINOR-2: visible confirmation — re-fetch the roster (the added user now
            # appears) AND show a success flash naming the user.
            {:noreply,
             socket
             |> assign(:members, fetch_members(space.room_id))
             |> assign(:member_error, nil)
             |> assign(:add_member_user_id, "")
             |> assign(:user_suggestions, [])
             |> put_flash(:info, "Added #{user_id}")}

          {:error, :invalid_user_id} ->
            {:noreply, assign(socket, :member_error, "Invalid user id")}

          {:error, :not_found} ->
            {:noreply, assign(socket, :member_error, "User not found: #{user_id}")}

          {:error, reason} ->
            {:noreply, assign(socket, :member_error, "Could not add member: #{inspect(reason)}")}
        end
    end
  end

  # ── AC3: edit name/topic ───────────────────────────────────────────────────────

  @impl Phoenix.LiveView
  def handle_event("save_space", %{"name" => name, "topic" => topic}, socket) do
    space = socket.assigns.space
    actor = socket.assigns.actor_id
    name = String.trim(name || "")
    topic = String.trim(topic || "")

    with {:ok, _} <- set_state(space.room_id, actor, "m.room.name", "", %{"name" => name}),
         {:ok, _} <- set_state(space.room_id, actor, "m.room.topic", "", %{"topic" => topic}) do
      {:noreply,
       socket
       |> assign(:space, %{space | name: name, topic: topic})
       |> update(:spaces, fn spaces ->
         Enum.map(spaces, fn s ->
           if s.room_id == space.room_id, do: %{s | name: name}, else: s
         end)
       end)
       |> assign(:detail_error, nil)}
    else
      {:error, reason} ->
        {:noreply, assign(socket, :detail_error, "Could not save: #{inspect(reason)}")}
    end
  end

  # ── AC4: child add / remove ─────────────────────────────────────────────────────

  @impl Phoenix.LiveView
  def handle_event("add_child", %{"child_room_id" => child_id}, socket) do
    space = socket.assigns.space
    child_id = String.trim(child_id || "")

    cond do
      child_id == "" ->
        {:noreply, assign(socket, :detail_error, "Child room id is required")}

      true ->
        # m.space.child content carries `via` (a server list) per MSC1772; the
        # state_key is the child room id. Non-empty content = a live edge.
        content = %{"via" => [server_name()]}

        case set_state(space.room_id, socket.assigns.actor_id, "m.space.child", child_id, content) do
          {:ok, _} ->
            children =
              [{child_id, content} | Enum.reject(socket.assigns.children, fn {c, _} -> c == child_id end)]
              |> Enum.sort_by(fn {c, _} -> c end)

            {:noreply,
             socket
             |> assign(:children, children)
             |> assign(:child_input, "")
             |> assign(:detail_error, nil)}

          {:error, reason} ->
            {:noreply, assign(socket, :detail_error, "Could not add child: #{inspect(reason)}")}
        end
    end
  end

  @impl Phoenix.LiveView
  def handle_event("remove_child", %{"child_room_id" => child_id}, socket) do
    space = socket.assigns.space

    # Empty content = unlink (S2 m.space.child unlink semantics).
    case set_state(space.room_id, socket.assigns.actor_id, "m.space.child", child_id, %{}) do
      {:ok, _} ->
        children = Enum.reject(socket.assigns.children, fn {c, _} -> c == child_id end)
        {:noreply, socket |> assign(:children, children) |> assign(:detail_error, nil)}

      {:error, reason} ->
        {:noreply, assign(socket, :detail_error, "Could not remove child: #{inspect(reason)}")}
    end
  end

  # ── data loading ────────────────────────────────────────────────────────────────

  defp load_spaces(session) do
    case session["spaces"] do
      list when is_list(list) -> Enum.map(list, &normalize_space/1)
      _ -> real_list_spaces()
    end
  end

  defp real_list_spaces do
    if running?(Nebu.Repo) do
      {spaces, _next} = Nebu.Admin.DB.list_spaces(500, "", "active", "")
      spaces
    else
      []
    end
  end

  defp assign_detail(socket, space_id, session) do
    space =
      case session["space_detail"] do
        %{} = s -> normalize_space_detail(s)
        _ -> real_get_space(space_id)
      end

    children =
      case session["children"] do
        list when is_list(list) -> Enum.map(list, &normalize_child/1)
        _ -> real_children(space_id)
      end

    members =
      case session["room_members"] do
        list when is_list(list) -> Enum.map(list, &normalize_member/1)
        _ -> if space, do: fetch_members(space.room_id), else: []
      end

    socket
    |> assign(:space, space)
    |> assign(:children, children)
    |> assign(:members, members)
  end

  defp real_get_space(space_id) do
    if running?(Nebu.Repo) do
      case Nebu.Admin.DB.get_space(space_id) do
        {:ok, space} -> space
        _ -> nil
      end
    else
      nil
    end
  end

  defp real_children(space_id) do
    if running?(Nebu.Repo) do
      case Nebu.Matrix.get_space_children(space_id) do
        {:ok, children} -> children
        _ -> []
      end
    else
      []
    end
  end

  # ── write seams (ADR-020: real impl routes through Nebu.Matrix) ────────────────

  defp create_space(actor_id, name) do
    case Application.get_env(:nebu_http, :admin_spaces_creator) do
      fun when is_function(fun, 2) -> fun.(actor_id, name)
      _ -> Nebu.Matrix.create_space(actor_id, name)
    end
  end

  defp set_state(room_id, actor_id, event_type, state_key, content) do
    case Application.get_env(:nebu_http, :admin_spaces_state_writer) do
      fun when is_function(fun, 5) -> fun.(room_id, actor_id, event_type, state_key, content)
      _ -> Nebu.Matrix.set_space_state(room_id, actor_id, event_type, state_key, content)
    end
  end

  defp set_auto_join(actor_id, room_id, value) do
    case Application.get_env(:nebu_http, :admin_spaces_auto_join_writer) do
      fun when is_function(fun, 3) -> fun.(actor_id, room_id, value)
      _ -> Nebu.Matrix.set_room_auto_join(actor_id, room_id, value)
    end
  end

  # admin-add-user-autocomplete: add a member to the Space (a Space is a room) through
  # the same audited Matrix public-API path RoomsLive uses (:admin_member_adder seam in
  # unit tests, else Nebu.Matrix.admin_add_room_member/3 — ADR-020).
  defp add_member(room_id, user_id, actor_id) do
    case Application.get_env(:nebu_http, :admin_member_adder) do
      fun when is_function(fun, 3) -> fun.(room_id, user_id, actor_id)
      _ -> Nebu.Matrix.admin_add_room_member(room_id, user_id, actor_id)
    end
  end

  # MINOR-2: a Space is a room — reuse the RoomsLive member-fetch seam
  # (:admin_member_lister → Nebu.Admin.DB.list_room_members/1) so a successful add shows
  # the new member in a roster. No space-specific membership semantics are invented.
  defp fetch_members(room_id) do
    case Application.get_env(:nebu_http, :admin_member_lister) do
      fun when is_function(fun, 1) ->
        Enum.map(fun.(room_id), &normalize_member/1)

      _ ->
        if running?(Nebu.Repo) do
          {:ok, rows} = Nebu.Admin.DB.list_room_members(room_id)
          Enum.map(rows, &normalize_member/1)
        else
          []
        end
    end
  end

  defp normalize_member(%{user_id: uid}), do: %{user_id: uid}
  defp normalize_member(%{"user_id" => uid}), do: %{user_id: uid}

  # ── normalizers (string-keyed test sessions → atom-keyed assigns) ──────────────

  defp normalize_space(%{room_id: _} = s) do
    %{
      room_id: s.room_id,
      name: Map.get(s, :name, ""),
      status: Map.get(s, :status, "active"),
      member_count: Map.get(s, :member_count, 0),
      child_count: Map.get(s, :child_count, 0),
      is_auto_join: !!Map.get(s, :is_auto_join, false)
    }
  end

  defp normalize_space(%{"room_id" => id} = s) do
    %{
      room_id: id,
      name: Map.get(s, "name", ""),
      status: Map.get(s, "status", "active"),
      member_count: Map.get(s, "member_count", 0),
      child_count: Map.get(s, "child_count", 0),
      is_auto_join: !!Map.get(s, "is_auto_join", false)
    }
  end

  defp normalize_space_detail(%{room_id: _} = s) do
    %{
      room_id: s.room_id,
      name: Map.get(s, :name, ""),
      topic: Map.get(s, :topic, ""),
      status: Map.get(s, :status, "active"),
      member_count: Map.get(s, :member_count, 0),
      is_auto_join: !!Map.get(s, :is_auto_join, false)
    }
  end

  defp normalize_space_detail(%{"room_id" => id} = s) do
    %{
      room_id: id,
      name: Map.get(s, "name", ""),
      topic: Map.get(s, "topic", ""),
      status: Map.get(s, "status", "active"),
      member_count: Map.get(s, "member_count", 0),
      is_auto_join: !!Map.get(s, "is_auto_join", false)
    }
  end

  defp normalize_child({child_id, content}) when is_map(content), do: {child_id, content}
  defp normalize_child(%{"child_room_id" => id} = m), do: {id, Map.get(m, "content", %{})}
  defp normalize_child(child_id) when is_binary(child_id), do: {child_id, %{}}

  defp running?(name), do: Process.whereis(name) != nil

  defp server_name, do: Application.get_env(:nebu_http, :server_name, "localhost")

  # ── render ────────────────────────────────────────────────────────────────────

  @impl Phoenix.LiveView
  def render(%{view_mode: :detail} = assigns) do
    ~H"""
    <div class="admin-space-detail" data-page="space-detail">
      <.link navigate="/admin/spaces" class="text-sm text-primary">&larr; Back to Spaces</.link>

      <%!-- MINOR-2: success/error flash (e.g. "Added @user:server" after a member add). --%>
      <p :if={Phoenix.Flash.get(@flash, :info)} class="alert alert-success my-4" role="status" data-role="flash-info">
        {Phoenix.Flash.get(@flash, :info)}
      </p>
      <p :if={Phoenix.Flash.get(@flash, :error)} class="alert alert-error my-4" role="alert">
        {Phoenix.Flash.get(@flash, :error)}
      </p>

      <p :if={@space == nil} class="text-base-content/70 mt-4">Space not found.</p>

      <div :if={@space != nil}>
        <h1 class="text-2xl font-bold mb-4" data-space-id={@space.room_id}>
          {space_display_name(@space)}
        </h1>

        <p :if={@detail_error} class="text-error mb-4" role="alert">{@detail_error}</p>

        <form id="edit-space-form" phx-submit="save_space" class="mb-8 max-w-lg" data-form="edit-space">
          <label class="form-control w-full mb-3">
            <span class="label-text">Name</span>
            <input type="text" name="name" value={@space.name} class="input input-bordered w-full" />
          </label>
          <label class="form-control w-full mb-3">
            <span class="label-text">Topic</span>
            <input type="text" name="topic" value={@space.topic} class="input input-bordered w-full" />
          </label>
          <button type="submit" class="btn btn-primary" role="button">Save</button>
        </form>

        <div class="mb-8">
          <label class="cursor-pointer label gap-2 justify-start">
            <span>Auto-join this space for new users</span>
            <input
              type="checkbox"
              class="toggle toggle-primary"
              role="switch"
              data-role="auto-join-toggle"
              data-space-id={@space.room_id}
              checked={@space.is_auto_join}
              aria-checked={to_string(@space.is_auto_join)}
              aria-label={"Auto-join " <> space_display_name(@space)}
              phx-click="toggle_auto_join"
              phx-value-space_id={@space.room_id}
            />
          </label>
        </div>

        <%!-- admin-add-user-autocomplete: add a member to the Space with the shared
              ARIA-combobox user typeahead (assistive; the field stays free-text). --%>
        <div class="mb-8 max-w-2xl" data-section="members">
          <h2 class="text-xl font-semibold mb-2">Add member</h2>

          <p :if={@member_error} class="text-error mb-3" role="alert" data-role="member-error">
            {@member_error}
          </p>

          <form
            id="space-add-member-form"
            phx-submit="add_member"
            phx-change="suggest_users"
            class="flex items-end gap-2"
            data-form="add-member"
          >
            <div class="form-control grow relative" role="none">
              <label
                for="space-add-member-user-id"
                class="label-text"
                id="space-add-member-user-id-label"
              >
                Add user
              </label>
              <input
                type="text"
                id="space-add-member-user-id"
                name="user_id"
                value={@add_member_user_id}
                placeholder="@user:server"
                class="input input-bordered w-full"
                data-field="add-member-user-id"
                autocomplete="off"
                phx-hook="UserCombobox"
                role="combobox"
                aria-autocomplete="list"
                aria-expanded={to_string(@user_suggestions != [])}
                aria-controls="space-add-member-user-suggestions"
                aria-labelledby="space-add-member-user-id-label"
                aria-label="Matrix user id to add"
                phx-debounce="200"
              />
              <ul
                :if={@user_suggestions != []}
                id="space-add-member-user-suggestions"
                role="listbox"
                aria-label="Matching users"
                class="menu bg-base-200 rounded-box shadow absolute z-10 mt-1 w-full max-h-60 overflow-auto"
              >
                <li
                  :for={s <- @user_suggestions}
                  role="option"
                  id={"space-user-suggestion-" <> s.user_id}
                  aria-selected="false"
                  data-role="user-suggestion"
                  data-user-id={s.user_id}
                  class="cursor-pointer px-3 py-2 font-mono text-sm hover:bg-base-300"
                  phx-click="select_user_suggestion"
                  phx-value-user_id={s.user_id}
                >
                  {s.user_id}
                </li>
              </ul>
            </div>
            <button type="submit" class="btn btn-primary" role="button">Add</button>
          </form>

          <%!-- MINOR-2: member roster — re-rendered after a successful add so the new
                member is visible (matches RoomsLive). --%>
          <p :if={@members == []} class="text-base-content/70 mt-3" data-role="no-members">
            No members.
          </p>

          <ul :if={@members != []} class="divide-y divide-base-300 mt-3" role="list" data-list="members">
            <li
              :for={member <- @members}
              class="flex items-center py-2"
              data-role="member-row"
              data-user-id={member.user_id}
            >
              <span class="font-mono text-sm">{member.user_id}</span>
            </li>
          </ul>
        </div>

        <h2 class="text-xl font-semibold mb-2">Child rooms</h2>

        <p :if={@children == []} class="text-base-content/70">No child rooms.</p>

        <ul :if={@children != []} role="list" class="mb-4" data-list="children">
          <li :for={{child_id, _content} <- @children} data-child-id={child_id} class="flex items-center gap-3 py-1">
            <span class="font-mono text-sm">{child_id}</span>
            <button
              type="button"
              class="btn btn-xs btn-error"
              role="button"
              aria-label={"Remove child " <> child_id}
              phx-click="remove_child"
              phx-value-child_room_id={child_id}
            >
              Remove
            </button>
          </li>
        </ul>

        <form id="add-child-form" phx-submit="add_child" class="flex items-end gap-2 max-w-lg" data-form="add-child">
          <label class="form-control flex-1">
            <span class="label-text">Add child room id</span>
            <input
              type="text"
              name="child_room_id"
              placeholder="!room:server"
              class="input input-bordered w-full"
            />
          </label>
          <button type="submit" class="btn btn-primary" role="button">Add child</button>
        </form>
      </div>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div class="admin-spaces" data-page="spaces">
      <h1 class="text-2xl font-bold mb-4">Spaces</h1>

      <form id="create-space-form" phx-submit="create_space" class="flex items-end gap-2 mb-6 max-w-lg" data-form="create-space">
        <label class="form-control flex-1">
          <span class="label-text">New space name</span>
          <input type="text" name="name" placeholder="Engineering" class="input input-bordered w-full" />
        </label>
        <button type="submit" class="btn btn-primary" role="button">Create Space</button>
      </form>

      <p :if={@create_error} class="text-error mb-4" role="alert">{@create_error}</p>

      <p :if={@spaces == []} class="text-base-content/70">No spaces found.</p>

      <table :if={@spaces != []} class="table w-full" role="table">
        <thead>
          <tr>
            <th scope="col">Space</th>
            <th scope="col">Members</th>
            <th scope="col">Children</th>
            <th scope="col">Auto-join</th>
          </tr>
        </thead>
        <tbody>
          <tr
            :for={space <- @spaces}
            data-space-id={space.room_id}
            data-auto-join={to_string(space.is_auto_join)}
          >
            <td>
              <.link navigate={"/admin/spaces/" <> space.room_id} class="text-primary">
                {space_display_name(space)}
              </.link>
            </td>
            <td>{space.member_count}</td>
            <td>{space.child_count}</td>
            <td>
              <label class="cursor-pointer label gap-2">
                <span class="sr-only">Toggle auto-join for {space_display_name(space)}</span>
                <input
                  type="checkbox"
                  class="toggle toggle-primary"
                  role="switch"
                  data-role="auto-join-toggle"
                  data-space-id={space.room_id}
                  checked={space.is_auto_join}
                  aria-checked={to_string(space.is_auto_join)}
                  aria-label={"Auto-join " <> space_display_name(space)}
                  phx-click="toggle_auto_join"
                  phx-value-space_id={space.room_id}
                />
              </label>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp space_display_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp space_display_name(%{room_id: id}), do: id
end
