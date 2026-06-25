defmodule Nebu.Admin.SpacesController do
  @moduledoc """
  HTTP controller for Admin Space management (admin-http-refactor story).

  Replaces Nebu.Admin.SpacesLive. Mirrors RoomsController structure for Spaces.
  All write paths follow the Post-Redirect-Get pattern.

  ADR-018: SQL inline / DB helpers, no domain model.
  ADR-019: Single OTP app.
  ADR-020: Writes go through Nebu.Matrix.*.
  """
  use Phoenix.Controller, formats: [:html]

  import Plug.Conn

  plug Nebu.Admin.Auth, :require_admin

  # ── GET /admin/spaces ─────────────────────────────────────────────────────────

  def index(conn, _params) do
    spaces = load_spaces()

    conn
    |> assign(:spaces, spaces)
    |> assign(:create_error, nil)
    |> assign(:page_title, "Spaces")
    |> assign(:active_nav, "spaces")
    |> assign(:bootstrap_completed, Nebu.Admin.Auth.bootstrap_completed?())
    |> put_layout(html: {Nebu.Admin.Layouts, :live})
    |> render(:index)
  end

  # ── GET /admin/spaces/:space_id ───────────────────────────────────────────────

  def show(conn, %{"space_id" => space_id}) do
    space_id = URI.decode(space_id)
    space = real_get_space(space_id)
    children = real_children(space_id)
    members = if space, do: fetch_members(space.room_id), else: []

    conn
    |> assign(:space, space)
    |> assign(:children, children)
    |> assign(:members, members)
    |> assign(:actor_id, actor_id(conn))
    |> assign(:detail_error, nil)
    |> assign(:member_error, nil)
    |> assign(:page_title, if(space, do: (if space.name == "", do: space.room_id, else: space.name), else: "Space"))
    |> assign(:active_nav, "spaces")
    |> assign(:bootstrap_completed, Nebu.Admin.Auth.bootstrap_completed?())
    |> put_layout(html: {Nebu.Admin.Layouts, :live})
    |> render(:show)
  end

  # ── POST /admin/spaces (create) ───────────────────────────────────────────────

  def create(conn, params) do
    name = String.trim(params["name"] || "")
    actor = actor_id(conn)

    cond do
      name == "" ->
        spaces = load_spaces()

        conn
        |> assign(:spaces, spaces)
        |> assign(:create_error, "Name is required")
        |> assign(:page_title, "Spaces")
        |> assign(:active_nav, "spaces")
        |> assign(:bootstrap_completed, Nebu.Admin.Auth.bootstrap_completed?())
        |> put_layout(html: {Nebu.Admin.Layouts, :live})
        |> put_status(200)
        |> render(:index)

      String.length(name) > 100 ->
        spaces = load_spaces()

        conn
        |> assign(:spaces, spaces)
        |> assign(:create_error, "Name must be at most 100 characters")
        |> assign(:page_title, "Spaces")
        |> assign(:active_nav, "spaces")
        |> assign(:bootstrap_completed, Nebu.Admin.Auth.bootstrap_completed?())
        |> put_layout(html: {Nebu.Admin.Layouts, :live})
        |> put_status(200)
        |> render(:index)

      true ->
        case do_create_space(actor, name) do
          {:ok, room_id} ->
            encoded = URI.encode(room_id, &URI.char_unreserved?(&1))

            conn
            |> put_flash(:info, "Space created")
            |> redirect(to: "/admin/spaces/#{encoded}")

          {:error, reason} ->
            spaces = load_spaces()

            conn
            |> assign(:spaces, spaces)
            |> assign(:create_error, "Could not create space: #{inspect(reason)}")
            |> assign(:page_title, "Spaces")
            |> assign(:active_nav, "spaces")
            |> assign(:bootstrap_completed, Nebu.Admin.Auth.bootstrap_completed?())
            |> put_layout(html: {Nebu.Admin.Layouts, :live})
            |> put_status(200)
            |> render(:index)
        end
    end
  end

  # ── POST /admin/spaces/:space_id (save name/topic) ────────────────────────────

  def save(conn, %{"space_id" => space_id} = params) do
    space_id = URI.decode(space_id)
    name = String.trim(params["name"] || "")
    topic = String.trim(params["topic"] || "")
    actor = actor_id(conn)
    encoded = URI.encode(space_id, &URI.char_unreserved?(&1))

    with {:ok, _} <- do_set_state(space_id, actor, "m.room.name", "", %{"name" => name}),
         {:ok, _} <- do_set_state(space_id, actor, "m.room.topic", "", %{"topic" => topic}) do
      conn
      |> put_flash(:info, "Space saved")
      |> redirect(to: "/admin/spaces/#{encoded}")
    else
      {:error, reason} ->
        space = real_get_space(space_id)
        children = real_children(space_id)
        members = if space, do: fetch_members(space.room_id), else: []

        conn
        |> assign(:space, space)
        |> assign(:children, children)
        |> assign(:members, members)
        |> assign(:actor_id, actor)
        |> assign(:detail_error, "Could not save: #{inspect(reason)}")
        |> assign(:member_error, nil)
        |> assign(:page_title, "Space")
        |> assign(:active_nav, "spaces")
        |> assign(:bootstrap_completed, Nebu.Admin.Auth.bootstrap_completed?())
        |> put_layout(html: {Nebu.Admin.Layouts, :live})
        |> put_status(200)
        |> render(:show)
    end
  end

  # ── POST /admin/spaces/:space_id/auto-join ────────────────────────────────────

  def toggle_auto_join(conn, %{"space_id" => space_id}) do
    space_id = URI.decode(space_id)
    actor = actor_id(conn)
    encoded = URI.encode(space_id, &URI.char_unreserved?(&1))

    # Read current value to flip it (or default false if space not found).
    # When a test seam is installed the DB is bypassed entirely.
    current =
      if running?(Nebu.Repo) do
        case Nebu.Admin.DB.get_space(space_id) do
          {:ok, s} -> !!s.is_auto_join
          _ -> false
        end
      else
        false
      end

    # Guard: if no seam is installed and the repo is running, verify the space exists.
    no_seam = Application.get_env(:nebu_http, :admin_spaces_auto_join_writer) == nil
    space_missing = no_seam and running?(Nebu.Repo) and
      match?({:error, _}, Nebu.Admin.DB.get_space(space_id))

    if space_missing do
      conn
      |> put_flash(:error, "Space not found")
      |> redirect(to: "/admin/spaces/#{encoded}")
    else
      case do_set_auto_join(actor, space_id, !current) do
        :ok ->
          conn
          |> put_flash(:info, "Auto-join updated")
          |> redirect(to: "/admin/spaces/#{encoded}")

        {:error, _reason} ->
          conn
          |> put_flash(:error, "Failed to update auto-join")
          |> redirect(to: "/admin/spaces/#{encoded}")
      end
    end
  end

  # ── POST /admin/spaces/:space_id/children (add child) ────────────────────────

  def add_child(conn, %{"space_id" => space_id} = params) do
    space_id = URI.decode(space_id)
    child_id = String.trim(params["child_room_id"] || "")
    actor = actor_id(conn)
    encoded = URI.encode(space_id, &URI.char_unreserved?(&1))

    if child_id == "" do
      space = real_get_space(space_id)
      children = real_children(space_id)
      members = if space, do: fetch_members(space.room_id), else: []

      conn
      |> assign(:space, space)
      |> assign(:children, children)
      |> assign(:members, members)
      |> assign(:actor_id, actor)
      |> assign(:detail_error, "Child room id is required")
      |> assign(:member_error, nil)
      |> assign(:page_title, "Space")
      |> assign(:active_nav, "spaces")
      |> assign(:bootstrap_completed, Nebu.Admin.Auth.bootstrap_completed?())
      |> put_layout(html: {Nebu.Admin.Layouts, :live})
      |> put_status(200)
      |> render(:show)
    else
      content = %{"via" => [server_name()]}

      case do_set_state(space_id, actor, "m.space.child", child_id, content) do
        {:ok, _} ->
          conn
          |> put_flash(:info, "Child added")
          |> redirect(to: "/admin/spaces/#{encoded}")

        {:error, reason} ->
          conn
          |> put_flash(:error, "Could not add child: #{inspect(reason)}")
          |> redirect(to: "/admin/spaces/#{encoded}")
      end
    end
  end

  # ── DELETE /admin/spaces/:space_id/children/:child_id ────────────────────────

  def remove_child(conn, %{"space_id" => space_id, "child_id" => child_id}) do
    space_id = URI.decode(space_id)
    child_id = URI.decode(child_id)
    actor = actor_id(conn)
    encoded = URI.encode(space_id, &URI.char_unreserved?(&1))

    case do_set_state(space_id, actor, "m.space.child", child_id, %{}) do
      {:ok, _} ->
        conn
        |> put_flash(:info, "Child removed")
        |> redirect(to: "/admin/spaces/#{encoded}")

      {:error, reason} ->
        conn
        |> put_flash(:error, "Could not remove child: #{inspect(reason)}")
        |> redirect(to: "/admin/spaces/#{encoded}")
    end
  end

  # ── POST /admin/spaces/:space_id/members ──────────────────────────────────────

  def add_member(conn, %{"space_id" => space_id} = params) do
    space_id = URI.decode(space_id)
    user_id = String.trim(params["user_id"] || "")
    actor = actor_id(conn)
    encoded = URI.encode(space_id, &URI.char_unreserved?(&1))

    if not Nebu.Matrix.UserId.valid?(user_id) do
      space = real_get_space(space_id)
      children = real_children(space_id)
      members = if space, do: fetch_members(space.room_id), else: []

      conn
      |> assign(:space, space)
      |> assign(:children, children)
      |> assign(:members, members)
      |> assign(:actor_id, actor)
      |> assign(:detail_error, nil)
      |> assign(:member_error, "Invalid user id")
      |> assign(:page_title, "Space")
      |> assign(:active_nav, "spaces")
      |> assign(:bootstrap_completed, Nebu.Admin.Auth.bootstrap_completed?())
      |> put_layout(html: {Nebu.Admin.Layouts, :live})
      |> put_status(200)
      |> render(:show)
    else
      case do_add_member(space_id, user_id, actor) do
        {:ok, _} ->
          conn
          |> put_flash(:info, "Added #{user_id}")
          |> redirect(to: "/admin/spaces/#{encoded}")

        {:error, reason} ->
          conn
          |> put_flash(:error, "Could not add member: #{inspect(reason)}")
          |> redirect(to: "/admin/spaces/#{encoded}")
      end
    end
  end

  # ── Data loading ──────────────────────────────────────────────────────────────

  defp load_spaces do
    if running?(Nebu.Repo) do
      {spaces, _next} = Nebu.Admin.DB.list_spaces(500, "", "active", "")
      spaces
    else
      []
    end
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

  defp fetch_members(room_id) do
    case Application.get_env(:nebu_http, :admin_member_lister) do
      fun when is_function(fun, 1) ->
        Enum.map(fun.(room_id), fn
          %{user_id: uid} -> %{user_id: uid}
          %{"user_id" => uid} -> %{user_id: uid}
        end)

      _ ->
        if running?(Nebu.Repo) do
          {:ok, rows} = Nebu.Admin.DB.list_room_members(room_id)
          Enum.map(rows, fn
            %{user_id: uid} -> %{user_id: uid}
            %{"user_id" => uid} -> %{user_id: uid}
          end)
        else
          []
        end
    end
  end

  # ── Write seams ───────────────────────────────────────────────────────────────

  defp do_create_space(actor_id, name) do
    case Application.get_env(:nebu_http, :admin_spaces_creator) do
      fun when is_function(fun, 2) -> fun.(actor_id, name)
      _ -> Nebu.Matrix.create_space(actor_id, name)
    end
  end

  defp do_set_state(room_id, actor_id, event_type, state_key, content) do
    case Application.get_env(:nebu_http, :admin_spaces_state_writer) do
      fun when is_function(fun, 5) -> fun.(room_id, actor_id, event_type, state_key, content)
      _ -> Nebu.Matrix.set_space_state(room_id, actor_id, event_type, state_key, content)
    end
  end

  defp do_set_auto_join(actor_id, room_id, value) do
    case Application.get_env(:nebu_http, :admin_spaces_auto_join_writer) do
      fun when is_function(fun, 3) -> fun.(actor_id, room_id, value)
      _ -> Nebu.Matrix.set_room_auto_join(actor_id, room_id, value)
    end
  end

  defp do_add_member(room_id, user_id, actor_id) do
    case Application.get_env(:nebu_http, :admin_member_adder) do
      fun when is_function(fun, 3) -> fun.(room_id, user_id, actor_id)
      _ -> Nebu.Matrix.admin_add_room_member(room_id, user_id, actor_id)
    end
  end

  defp actor_id(conn) do
    case conn.assigns[:current_user] do
      %{"matrix_user_id" => uid} when is_binary(uid) and uid != "" -> uid
      %{"sub" => sub} when is_binary(sub) -> sub
      _ -> nil
    end
  end

  defp server_name, do: Application.get_env(:nebu_http, :server_name, "localhost")

  defp running?(name), do: Process.whereis(name) != nil
end
