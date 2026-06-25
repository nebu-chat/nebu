defmodule Nebu.Admin.RoomsController do
  @moduledoc """
  HTTP controller for Admin Room management (admin-http-refactor story).

  Replaces Nebu.Admin.RoomsLive with plain Phoenix GET/POST/DELETE controller actions.
  All write paths follow the Post-Redirect-Get pattern. Write seams are carried over
  from RoomsLive unchanged so existing tests can inject test doubles.

  ADR-018: SQL inline in actions, no domain model.
  ADR-019: Single OTP app.
  ADR-020: Writes that go through Nebu.Matrix.* continue to do so.
  """
  use Phoenix.Controller, formats: [:html]

  import Plug.Conn

  plug Nebu.Admin.Auth, :require_admin

  @sql_list_rooms_template """
  SELECT room_id, COALESCE(name, '') AS name, is_auto_join, status,
         (SELECT COUNT(*) FROM room_members m WHERE m.room_id = r.room_id AND m.left_at IS NULL) AS member_count
  FROM rooms r
  __WHERE__
  ORDER BY COALESCE(name, ''), room_id
  LIMIT 500
  """

  @sql_update_auto_join """
  UPDATE rooms SET is_auto_join = $1 WHERE room_id = $2
  """

  @valid_filters ~w(all active archived stale)

  # ── GET /admin/rooms ──────────────────────────────────────────────────────────

  def index(conn, params) do
    status = if params["status"] in @valid_filters, do: params["status"], else: "all"
    rooms = load_rooms(status)

    conn
    |> assign(:rooms, rooms)
    |> assign(:status_filter, status)
    |> assign(:page_title, "Rooms")
    |> assign(:active_nav, "rooms")
    |> assign(:bootstrap_completed, Nebu.Admin.Auth.bootstrap_completed?())
    |> put_layout(html: {Nebu.Admin.Layouts, :live})
    |> render(:index)
  end

  # ── GET /admin/rooms/:room_id ─────────────────────────────────────────────────

  def show(conn, %{"room_id" => room_id}) do
    room_id = URI.decode(room_id)
    room = real_get_room(room_id)
    members = fetch_members(room_id)

    conn
    |> assign(:room_id, room_id)
    |> assign(:room, room)
    |> assign(:members, members)
    |> assign(:actor_id, actor_id(conn))
    |> assign(:detail_error, nil)
    |> assign(:member_error, nil)
    |> assign(:page_title, if(room, do: (if room.name == "", do: room.room_id, else: room.name), else: "Room"))
    |> assign(:active_nav, "rooms")
    |> assign(:bootstrap_completed, Nebu.Admin.Auth.bootstrap_completed?())
    |> put_layout(html: {Nebu.Admin.Layouts, :live})
    |> render(:show)
  end

  # ── GET /admin/rooms/new ──────────────────────────────────────────────────────

  def new(conn, _params) do
    conn
    |> assign(:page_title, "Create Room")
    |> assign(:active_nav, "rooms")
    |> assign(:bootstrap_completed, Nebu.Admin.Auth.bootstrap_completed?())
    |> put_layout(html: {Nebu.Admin.Layouts, :live})
    |> render(:new)
  end

  # ── POST /admin/rooms/:room_id/auto-join ──────────────────────────────────────

  def toggle_auto_join(conn, %{"room_id" => room_id}) do
    room_id = URI.decode(room_id)
    actor = actor_id(conn)

    # Read current value to flip it (or default false if room not found).
    # When a test seam is installed the DB is bypassed entirely.
    current =
      if running?(Nebu.Repo) do
        case Nebu.Admin.DB.get_room(room_id) do
          {:ok, r} -> !!r.is_auto_join
          _ -> false
        end
      else
        false
      end

    # Guard: if no seam is installed and the repo is running, verify the room exists.
    no_seam = Application.get_env(:nebu_http, :admin_auto_join_writer) == nil
    room_missing = no_seam and running?(Nebu.Repo) and
      match?({:error, _}, Nebu.Admin.DB.get_room(room_id))

    if room_missing do
      conn
      |> put_flash(:error, "Room not found")
      |> redirect(to: "/admin/rooms")
    else
      case update_auto_join(actor, room_id, !current) do
        :ok ->
          conn
          |> put_flash(:info, "Auto-join updated")
          |> redirect(to: "/admin/rooms")

        {:error, _reason} ->
          conn
          |> put_flash(:error, "Failed to update auto-join")
          |> redirect(to: "/admin/rooms")
      end
    end
  end

  # ── POST /admin/rooms/:room_id/settings ───────────────────────────────────────

  def save_settings(conn, %{"room_id" => room_id} = params) do
    room_id = URI.decode(room_id)
    visibility = params["visibility"]
    actor = actor_id(conn)

    if visibility not in ["public", "private"] do
      # Re-render with error
      room = real_get_room(room_id)
      members = fetch_members(room_id)

      conn
      |> assign(:room_id, room_id)
      |> assign(:room, room)
      |> assign(:members, members)
      |> assign(:actor_id, actor)
      |> assign(:detail_error, "Invalid visibility")
      |> assign(:member_error, nil)
      |> assign(:page_title, "Room")
      |> assign(:active_nav, "rooms")
      |> assign(:bootstrap_completed, Nebu.Admin.Auth.bootstrap_completed?())
      |> put_layout(html: {Nebu.Admin.Layouts, :live})
      |> put_status(200)
      |> render(:show)
    else
      case update_visibility(actor, room_id, visibility) do
        :ok ->
          encoded = URI.encode(room_id, &URI.char_unreserved?(&1))

          conn
          |> put_flash(:info, "Settings saved")
          |> redirect(to: "/admin/rooms/#{encoded}")

        {:error, reason} ->
          room = real_get_room(room_id)
          members = fetch_members(room_id)

          conn
          |> assign(:room_id, room_id)
          |> assign(:room, room)
          |> assign(:members, members)
          |> assign(:actor_id, actor)
          |> assign(:detail_error, "Could not save visibility: #{inspect(reason)}")
          |> assign(:member_error, nil)
          |> assign(:page_title, "Room")
          |> assign(:active_nav, "rooms")
          |> assign(:bootstrap_completed, Nebu.Admin.Auth.bootstrap_completed?())
          |> put_layout(html: {Nebu.Admin.Layouts, :live})
          |> put_status(200)
          |> render(:show)
      end
    end
  end

  # ── POST /admin/rooms/:room_id/archive ────────────────────────────────────────

  def archive(conn, %{"room_id" => room_id}) do
    room_id = URI.decode(room_id)
    actor = actor_id(conn)
    encoded = URI.encode(room_id, &URI.char_unreserved?(&1))

    case archive_room(actor, room_id) do
      :ok ->
        conn
        |> put_flash(:info, "Room archived")
        |> redirect(to: "/admin/rooms/#{encoded}")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Could not archive room")
        |> redirect(to: "/admin/rooms/#{encoded}")
    end
  end

  # ── POST /admin/rooms/:room_id/unarchive ──────────────────────────────────────

  def unarchive(conn, %{"room_id" => room_id}) do
    room_id = URI.decode(room_id)
    actor = actor_id(conn)
    encoded = URI.encode(room_id, &URI.char_unreserved?(&1))

    case unarchive_room(actor, room_id) do
      :ok ->
        conn
        |> put_flash(:info, "Room unarchived")
        |> redirect(to: "/admin/rooms/#{encoded}")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Could not unarchive room")
        |> redirect(to: "/admin/rooms/#{encoded}")
    end
  end

  # ── POST /admin/rooms/:room_id/members ────────────────────────────────────────

  def add_member(conn, %{"room_id" => room_id} = params) do
    room_id = URI.decode(room_id)
    user_id = String.trim(params["user_id"] || "")
    actor = actor_id(conn)
    encoded = URI.encode(room_id, &URI.char_unreserved?(&1))

    if not Nebu.Matrix.UserId.valid?(user_id) do
      room = real_get_room(room_id)
      members = fetch_members(room_id)

      conn
      |> assign(:room_id, room_id)
      |> assign(:room, room)
      |> assign(:members, members)
      |> assign(:actor_id, actor)
      |> assign(:detail_error, nil)
      |> assign(:member_error, "Invalid user id: not a valid Matrix user id")
      |> assign(:page_title, "Room")
      |> assign(:active_nav, "rooms")
      |> assign(:bootstrap_completed, Nebu.Admin.Auth.bootstrap_completed?())
      |> put_layout(html: {Nebu.Admin.Layouts, :live})
      |> put_status(200)
      |> render(:show)
    else
      case do_add_member(room_id, user_id, actor) do
        {:ok, _} ->
          conn
          |> put_flash(:info, "Member added")
          |> redirect(to: "/admin/rooms/#{encoded}")

        {:error, reason} ->
          room = real_get_room(room_id)
          members = fetch_members(room_id)

          conn
          |> assign(:room_id, room_id)
          |> assign(:room, room)
          |> assign(:members, members)
          |> assign(:actor_id, actor)
          |> assign(:detail_error, nil)
          |> assign(:member_error, "Could not add member: #{inspect(reason)}")
          |> assign(:page_title, "Room")
          |> assign(:active_nav, "rooms")
          |> assign(:bootstrap_completed, Nebu.Admin.Auth.bootstrap_completed?())
          |> put_layout(html: {Nebu.Admin.Layouts, :live})
          |> put_status(200)
          |> render(:show)
      end
    end
  end

  # ── DELETE /admin/rooms/:room_id/members/:user_id (via _method=DELETE) ────────

  def remove_member(conn, %{"room_id" => room_id, "user_id" => user_id}) do
    room_id = URI.decode(room_id)
    user_id = URI.decode(user_id)
    actor = actor_id(conn)
    encoded_room = URI.encode(room_id, &URI.char_unreserved?(&1))

    # Defence-in-depth: no self-removal
    if user_id == actor do
      conn
      |> put_flash(:error, "Cannot remove yourself")
      |> redirect(to: "/admin/rooms/#{encoded_room}")
    else
      case do_remove_member(room_id, user_id, actor) do
        :ok ->
          conn
          |> put_flash(:info, "Member removed")
          |> redirect(to: "/admin/rooms/#{encoded_room}")

        {:error, reason} ->
          conn
          |> put_flash(:error, "Could not remove member: #{inspect(reason)}")
          |> redirect(to: "/admin/rooms/#{encoded_room}")
      end
    end
  end

  # ── POST /admin/rooms (create) ────────────────────────────────────────────────

  def create(conn, params) do
    name = String.trim(params["name"] || "")
    visibility = params["visibility"] || "private"
    actor = actor_id(conn)

    cond do
      name == "" ->
        rooms = load_rooms("all")

        conn
        |> assign(:rooms, rooms)
        |> assign(:status_filter, "all")
        |> assign(:create_error, "Name is required")
        |> assign(:page_title, "Rooms")
        |> assign(:active_nav, "rooms")
        |> assign(:bootstrap_completed, Nebu.Admin.Auth.bootstrap_completed?())
        |> put_layout(html: {Nebu.Admin.Layouts, :live})
        |> put_status(200)
        |> render(:index)

      String.length(name) > 100 ->
        rooms = load_rooms("all")

        conn
        |> assign(:rooms, rooms)
        |> assign(:status_filter, "all")
        |> assign(:create_error, "Name must be at most 100 characters")
        |> assign(:page_title, "Rooms")
        |> assign(:active_nav, "rooms")
        |> assign(:bootstrap_completed, Nebu.Admin.Auth.bootstrap_completed?())
        |> put_layout(html: {Nebu.Admin.Layouts, :live})
        |> put_status(200)
        |> render(:index)

      visibility not in ["public", "private"] ->
        rooms = load_rooms("all")

        conn
        |> assign(:rooms, rooms)
        |> assign(:status_filter, "all")
        |> assign(:create_error, "Invalid visibility")
        |> assign(:page_title, "Rooms")
        |> assign(:active_nav, "rooms")
        |> assign(:bootstrap_completed, Nebu.Admin.Auth.bootstrap_completed?())
        |> put_layout(html: {Nebu.Admin.Layouts, :live})
        |> put_status(200)
        |> render(:index)

      true ->
        case do_create_room(actor, name: name, visibility: visibility) do
          {:ok, room_id} ->
            encoded = URI.encode(room_id, &URI.char_unreserved?(&1))

            conn
            |> put_flash(:info, "Room created")
            |> redirect(to: "/admin/rooms/#{encoded}")

          {:error, reason} ->
            rooms = load_rooms("all")

            conn
            |> assign(:rooms, rooms)
            |> assign(:status_filter, "all")
            |> assign(:create_error, "Could not create room: #{inspect(reason)}")
            |> assign(:page_title, "Rooms")
            |> assign(:active_nav, "rooms")
            |> assign(:bootstrap_completed, Nebu.Admin.Auth.bootstrap_completed?())
            |> put_layout(html: {Nebu.Admin.Layouts, :live})
            |> put_status(200)
            |> render(:index)
        end
    end
  end

  # ── Data loading ──────────────────────────────────────────────────────────────

  defp load_rooms(status_filter) do
    if running?(Nebu.Repo) do
      sql = String.replace(@sql_list_rooms_template, "__WHERE__", filter_clause(status_filter))

      case Ecto.Adapters.SQL.query(Nebu.Repo, sql, []) do
        {:ok, %{rows: rows}} ->
          Enum.map(rows, fn [room_id, name, is_auto_join, status, member_count] ->
            count = member_count || 0

            %{
              room_id: room_id,
              name: name,
              is_auto_join: !!is_auto_join,
              member_count: count,
              status: Nebu.Admin.DB.room_effective_status(status || "active", count)
            }
          end)

        _ ->
          []
      end
    else
      []
    end
  end

  defp filter_clause("active"), do: "WHERE status = 'active'"
  defp filter_clause("archived"), do: "WHERE status = 'archived'"

  defp filter_clause("stale"),
    do:
      "WHERE status = 'active' AND " <>
        "(SELECT COUNT(*) FROM room_members m WHERE m.room_id = r.room_id AND m.left_at IS NULL) = 0"

  defp filter_clause(_), do: ""

  defp real_get_room(room_id) do
    if running?(Nebu.Repo) do
      case Nebu.Admin.DB.get_room(room_id) do
        {:ok, room} -> room
        _ -> nil
      end
    else
      nil
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

  # ── Write seams (carry over from RoomsLive unchanged) ─────────────────────────

  defp update_auto_join(actor, room_id, value) do
    case Application.get_env(:nebu_http, :admin_auto_join_writer) do
      fun when is_function(fun, 3) -> fun.(actor, room_id, value)
      fun when is_function(fun, 2) -> fun.(room_id, value)

      _ ->
        case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_update_auto_join, [value, room_id]) do
          {:ok, _} -> :ok
          {:error, _} = err -> err
        end
    end
  end

  defp update_visibility(actor_id, room_id, visibility) do
    case Application.get_env(:nebu_http, :admin_room_visibility_writer) do
      fun when is_function(fun, 3) -> fun.(actor_id, room_id, visibility)
      _ -> Nebu.Matrix.set_room_visibility(actor_id, room_id, visibility)
    end
  end

  defp do_create_room(actor_id, opts) do
    case Application.get_env(:nebu_http, :admin_room_creator) do
      fun when is_function(fun, 2) -> fun.(actor_id, opts)
      _ -> Nebu.Matrix.create_room(actor_id, opts)
    end
  end

  defp archive_room(actor_id, room_id) do
    case Application.get_env(:nebu_http, :admin_room_archiver) do
      fun when is_function(fun, 2) -> fun.(actor_id, room_id)
      _ -> Nebu.Matrix.archive_room(actor_id, room_id)
    end
  end

  defp unarchive_room(actor_id, room_id) do
    case Application.get_env(:nebu_http, :admin_room_unarchiver) do
      fun when is_function(fun, 2) -> fun.(actor_id, room_id)
      _ -> Nebu.Matrix.unarchive_room(actor_id, room_id)
    end
  end

  defp do_add_member(room_id, user_id, actor_id) do
    case Application.get_env(:nebu_http, :admin_member_adder) do
      fun when is_function(fun, 3) -> fun.(room_id, user_id, actor_id)
      _ -> Nebu.Matrix.admin_add_room_member(room_id, user_id, actor_id)
    end
  end

  defp do_remove_member(room_id, user_id, actor_id) do
    case Application.get_env(:nebu_http, :admin_member_remover) do
      fun when is_function(fun, 3) -> fun.(room_id, user_id, actor_id)
      _ -> Nebu.Matrix.admin_remove_room_member(room_id, user_id, actor_id)
    end
  end

  defp actor_id(conn) do
    case conn.assigns[:current_user] do
      %{"matrix_user_id" => uid} when is_binary(uid) and uid != "" -> uid
      %{"sub" => sub} when is_binary(sub) -> sub
      _ -> nil
    end
  end

  defp running?(name), do: Process.whereis(name) != nil
end
