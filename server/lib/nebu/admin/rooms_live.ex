defmodule Nebu.Admin.RoomsLive do
  @moduledoc """
  Room Management LiveView (admin-ui-migration AC1+AC2; rm1-room-visibility).

  Ports the Go admin Room Management page (gateway/internal/admin/rooms.go) to Phoenix
  LiveView. Two live_actions behind the `{Nebu.Admin.Auth, :require_admin}` on_mount gate:

    * `:index`  → `/admin/rooms`           — a list of rooms, each with a per-room
      auto-join toggle. Clicking a toggle fires
      `handle_event("toggle_auto_join", %{"room_id" => id}, socket)`, which flips
      `rooms.is_auto_join` in the DB (inline SQL — ADR-018) and updates assigns so
      LiveView pushes a DOM-diff (no full reload).
    * `:detail` → `/admin/rooms/:room_id`  — a single room's settings panel with a
      visibility `<select>` (Private ↔ Public). Submitting fires
      `handle_event("save_room_settings", %{"visibility" => v}, socket)`, which routes
      the change through `Nebu.Matrix.set_room_visibility/3` (the Matrix public API,
      ADR-020 — the Admin domain never calls Matrix internals directly), and re-assigns
      the room so the panel reflects the new value immediately (rm1 AC1/AC2/AC3).

  ## ADR-018 — no domain model, locality of behavior

  The auto-join list read/write and the room-detail read are inline SQL executed via
  `Ecto.Adapters.SQL.query/3` against `Nebu.Repo`. No Ecto.Schema / Changeset / Query
  builder / repository.

  ## ADR-020 — Admin → Matrix public API only

  The visibility WRITE goes through `Nebu.Matrix.set_room_visibility/3` (audited,
  validated, parameterised), never into Matrix internals. The acting identity is the
  operator's Matrix user id (`current_user["matrix_user_id"]`), so the change is
  attributed to a real Matrix user in the audit log.

  ## Test seams

    * `:admin_auto_join_writer` (2-arity) — the inline auto-join SQL execution point.
    * `:admin_room_visibility_writer` (3-arity) — the visibility write boundary; falls
      back to `Nebu.Matrix.set_room_visibility/3` when unset (production default). The
      seam is the execution point, not a domain abstraction.
    * `session["rooms"]` / `session["room_detail"]` supply data without a live Repo.

  ## Persistenz-Strategie — Option C (stateless, DB-backed)

  A LiveView holds no durable server state: socket assigns are derived from the DB on
  mount and the source of truth is the `rooms` table. A crashed LiveView is re-mounted
  from the DB on the next connect, so there is no GenServer state to recover (no
  `Process.exit(:kill)` recovery test required).
  """
  use Phoenix.LiveView, layout: {Nebu.Admin.Layouts, :live}

  # rm2: list query now carries status + active-member count so the list can render a
  # status badge (Active / Stale / Archived). The WHERE clause is composed from a FIXED
  # per-filter fragment (see filter_clause/1) — the filter value is never interpolated.
  @sql_list_rooms_template """
  SELECT room_id, COALESCE(name, '') AS name, is_auto_join, status,
         (SELECT COUNT(*) FROM room_members m WHERE m.room_id = r.room_id AND m.left_at IS NULL) AS member_count
  FROM rooms r
  __WHERE__
  ORDER BY COALESCE(name, ''), room_id
  LIMIT 500
  """

  @valid_filters ~w(all active archived stale)

  @sql_update_auto_join """
  UPDATE rooms SET is_auto_join = $1 WHERE room_id = $2
  """

  @impl Phoenix.LiveView
  def mount(params, session, socket) do
    actor_id =
      case session["current_user"] do
        %{"matrix_user_id" => uid} when is_binary(uid) and uid != "" -> uid
        %{"sub" => sub} when is_binary(sub) -> sub
        _ -> nil
      end

    rooms =
      case session["rooms"] do
        list when is_list(list) -> Enum.map(list, &normalize_room/1)
        _ -> load_rooms("all")
      end

    socket =
      socket
      |> assign(
        rooms: rooms,
        status_filter: "all",
        page_title: "Rooms",
        active_nav: "rooms",
        actor_id: actor_id,
        view_mode: :index,
        room: nil,
        detail_error: nil,
        create_error: nil,
        members: [],
        member_error: nil,
        # admin-add-user-autocomplete: the current add-user field value (so a selected
        # suggestion can be reflected back into the input) + the suggestion listbox.
        add_member_user_id: "",
        user_suggestions: []
      )

    # Detail-view selection. Production: the `/admin/rooms/:room_id` route supplies
    # `params["room_id"]`. Unit suite: a `room_detail` in the injected session selects
    # detail mode (live_isolated has no router params). We deliberately do NOT define
    # handle_params/3 — that would break live_isolated/3 (the established unit pattern).
    # live_isolated passes params as the atom :not_mounted_at_router (not a map).
    param_room_id = if is_map(params), do: params["room_id"], else: nil

    detail_room_id =
      param_room_id ||
        case session["room_detail"] do
          %{} = rd -> rd["room_id"] || rd[:room_id]
          _ -> nil
        end

    socket =
      if detail_room_id do
        socket
        |> assign(:view_mode, :detail)
        |> assign(:room, load_room_detail(detail_room_id, session))
        |> assign(:members, load_members(detail_room_id, session))
      else
        socket
      end

    {:ok, socket}
  end

  @impl Phoenix.LiveView
  def handle_event("toggle_auto_join", %{"room_id" => room_id}, socket) do
    current = Enum.find(socket.assigns.rooms, &(&1.room_id == room_id))
    new_value = !(current && current.is_auto_join)

    # AC2: persist to the DB via the inline-SQL write boundary (real impl below).
    :ok = update_auto_join(room_id, new_value)

    # AC2: update assigns so LiveView pushes a DOM-diff (no full page reload).
    rooms =
      Enum.map(socket.assigns.rooms, fn room ->
        if room.room_id == room_id, do: %{room | is_auto_join: new_value}, else: room
      end)

    {:noreply, assign(socket, :rooms, rooms)}
  end

  # rm2 AC1: status filter change (<form phx-change="filter">). Unknown values fall back
  # to "all" (default-deny on the filter token; the SQL fragment is fixed, not interpolated).
  @impl Phoenix.LiveView
  def handle_event("filter", %{"status" => status}, socket) do
    status = if status in @valid_filters, do: status, else: "all"

    {:noreply,
     socket
     |> assign(:status_filter, status)
     |> assign(:rooms, load_rooms(status))}
  end

  # rm1 AC2/AC3/AC5: save the visibility from the room detail settings form.
  @impl Phoenix.LiveView
  def handle_event("save_room_settings", %{"visibility" => visibility}, socket) do
    room = socket.assigns.room

    cond do
      is_nil(room) ->
        {:noreply, socket}

      # AC5 (default-deny): reject anything that is not a known visibility value
      # server-side; never forward an invalid value to the write path.
      visibility not in ["public", "private"] ->
        {:noreply, assign(socket, :detail_error, "Invalid visibility")}

      true ->
        case update_visibility(socket.assigns.actor_id, room.room_id, visibility) do
          :ok ->
            {:noreply,
             socket
             |> assign(:room, %{room | visibility: visibility})
             |> assign(:detail_error, nil)}

          {:error, reason} ->
            {:noreply,
             assign(socket, :detail_error, "Could not save visibility: #{inspect(reason)}")}
        end
    end
  end

  # rm3 AC1–AC4: create a room from the list-header modal. Validates the name length
  # (1–100) and the visibility allowlist server-side (default-deny, not just client),
  # then routes through Nebu.Matrix.create_room/2 (the audited createRoom path). On
  # success the new room is added to the list and the admin is navigated to its detail
  # panel. On a validation/error the modal-error assign is set (the modal stays open).
  @impl Phoenix.LiveView
  def handle_event("create_room", params, socket) do
    name = String.trim(params["name"] || "")
    visibility = params["visibility"] || "private"

    cond do
      name == "" ->
        {:noreply, assign(socket, :create_error, "Name is required")}

      String.length(name) > 100 ->
        {:noreply, assign(socket, :create_error, "Name must be at most 100 characters")}

      # AC2 default-deny: only the known visibility values are forwarded to the
      # create path; any other value is rejected server-side.
      visibility not in ["public", "private"] ->
        {:noreply, assign(socket, :create_error, "Invalid visibility")}

      true ->
        case create_room(socket.assigns.actor_id, name: name, visibility: visibility) do
          {:ok, room_id} ->
            new_room = %{
              room_id: room_id,
              name: name,
              is_auto_join: false,
              member_count: 1,
              status: "active"
            }

            {:noreply,
             socket
             |> assign(:rooms, socket.assigns.rooms ++ [new_room])
             |> assign(:create_error, nil)
             # AC2: take the admin to the new room's detail panel.
             |> push_navigate(to: "/admin/rooms/" <> room_id)}

          {:error, reason} ->
            {:noreply, assign(socket, :create_error, "Could not create room: #{inspect(reason)}")}
        end
    end
  end

  # rm3 AC5–AC8: archive / unarchive the room shown in the detail panel. Routes through
  # Nebu.Matrix.archive_room/2 / unarchive_room/2 (audited, GenServer-independent). On
  # success the room status assign flips and a success flash is shown; a not-found room
  # shows an error flash (never a 500/crash).
  @impl Phoenix.LiveView
  def handle_event("archive_room", _params, socket) do
    room = socket.assigns.room

    if is_nil(room) do
      {:noreply, socket}
    else
      case archive_room(socket.assigns.actor_id, room.room_id) do
        :ok ->
          {:noreply,
           socket
           |> assign(:room, %{room | status: "archived"})
           |> put_flash(:info, "Room archived")}

        {:error, :not_found} ->
          {:noreply, put_flash(socket, :error, "Room not found")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Could not archive room: #{inspect(reason)}")}
      end
    end
  end

  @impl Phoenix.LiveView
  def handle_event("unarchive_room", _params, socket) do
    room = socket.assigns.room

    if is_nil(room) do
      {:noreply, socket}
    else
      case unarchive_room(socket.assigns.actor_id, room.room_id) do
        :ok ->
          {:noreply,
           socket
           |> assign(:room, %{room | status: "active"})
           |> put_flash(:info, "Room unarchived")}

        {:error, :not_found} ->
          {:noreply, put_flash(socket, :error, "Room not found")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Could not unarchive room: #{inspect(reason)}")}
      end
    end
  end

  # rm4 AC2/AC5: add a member from the detail panel add-member form. The user_id is
  # shape-validated server-side BEFORE the write (default-deny — the Matrix delegate
  # validates too, but rejecting here avoids a needless round-trip and gives the inline
  # error). Routes through Nebu.Matrix.admin_add_room_member/3 (the audited join path,
  # ADR-020) with the logged-in admin as actor. On success the member list is re-fetched.
  # admin-add-user-autocomplete: debounced typeahead on the add-user input. phx-change
  # fires with the current field value; the shared helper applies the >=2-char gate and
  # the LIMIT-capped, parameter-bound user search (ADR-018/ADR-020). The submit path is
  # unchanged — these suggestions are assistive (the field stays free-text).
  @impl Phoenix.LiveView
  def handle_event("suggest_users", params, socket) do
    query = params["user_id"] || ""

    {:noreply,
     socket
     |> assign(:add_member_user_id, query)
     |> assign(:user_suggestions, Nebu.Admin.UserSuggest.search(query))}
  end

  # The admin picked a suggestion: fill the input with the full Matrix id and collapse
  # the listbox. Submit still runs the unchanged add_member path.
  @impl Phoenix.LiveView
  def handle_event("select_user_suggestion", %{"user_id" => user_id}, socket) do
    {:noreply,
     socket
     |> assign(:add_member_user_id, user_id)
     |> assign(:user_suggestions, [])}
  end

  # admin-add-user-autocomplete: Esc dismisses the listbox (the combobox hook pushes this).
  @impl Phoenix.LiveView
  def handle_event("dismiss_user_suggestions", _params, socket) do
    {:noreply, assign(socket, :user_suggestions, [])}
  end

  @impl Phoenix.LiveView
  def handle_event("add_member", params, socket) do
    room = socket.assigns.room
    user_id = String.trim(params["user_id"] || "")

    cond do
      is_nil(room) ->
        {:noreply, socket}

      not Nebu.Matrix.UserId.valid?(user_id) ->
        {:noreply, assign(socket, :member_error, "Invalid user id")}

      true ->
        case add_member(room.room_id, user_id, socket.assigns.actor_id) do
          {:ok, _} ->
            {:noreply,
             socket
             |> assign(:members, fetch_members(room.room_id))
             |> assign(:member_error, nil)
             # admin-add-user-autocomplete: clear the input + listbox after a successful add.
             |> assign(:add_member_user_id, "")
             |> assign(:user_suggestions, [])}

          {:error, :invalid_user_id} ->
            {:noreply, assign(socket, :member_error, "Invalid user id")}

          {:error, :not_found} ->
            {:noreply, assign(socket, :member_error, "User not found: #{user_id}")}

          {:error, reason} ->
            {:noreply, assign(socket, :member_error, "Could not add member: #{inspect(reason)}")}
        end
    end
  end

  # rm4 AC4/AC6: remove a member from the detail panel. The Remove control is hidden for
  # the admin's own row in the UI; the server ALSO rejects self-removal defensively (the
  # Matrix delegate returns {:error, :self_removal}). Routes through
  # Nebu.Matrix.admin_remove_room_member/3 (the audited leave path, ADR-020). On success
  # the member list is re-fetched so the removed user disappears.
  @impl Phoenix.LiveView
  def handle_event("remove_member", %{"user_id" => user_id}, socket) do
    room = socket.assigns.room

    cond do
      is_nil(room) ->
        {:noreply, socket}

      # Defence-in-depth: never issue a self-removal write even if the UI is bypassed.
      user_id == socket.assigns.actor_id ->
        {:noreply, socket}

      true ->
        case remove_member(room.room_id, user_id, socket.assigns.actor_id) do
          :ok ->
            {:noreply,
             socket
             |> assign(:members, fetch_members(room.room_id))
             |> assign(:member_error, nil)}

          {:error, reason} ->
            {:noreply,
             assign(socket, :member_error, "Could not remove member: #{inspect(reason)}")}
        end
    end
  end

  # ── inline-SQL READ (ADR-018) ──────────────────────────────────────────────────

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
              # rm2 AC2: effective status computed server-side via the shared helper.
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

  # rm2 AC3: map the filter value to a FIXED WHERE fragment — never interpolate the
  # filter string. Unknown values fall back to "all" (no status restriction).
  defp filter_clause("active"), do: "WHERE status = 'active'"
  defp filter_clause("archived"), do: "WHERE status = 'archived'"

  defp filter_clause("stale"),
    do:
      "WHERE status = 'active' AND " <>
        "(SELECT COUNT(*) FROM room_members m WHERE m.room_id = r.room_id AND m.left_at IS NULL) = 0"

  defp filter_clause(_), do: ""

  defp load_room_detail(room_id, session) do
    case session["room_detail"] do
      %{} = rd -> normalize_room_detail(rd)
      _ -> real_get_room(room_id)
    end
  end

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

  # ── inline-SQL WRITE via the :admin_auto_join_writer seam (ADR-018) ────────────

  defp update_auto_join(room_id, value) do
    case Application.get_env(:nebu_http, :admin_auto_join_writer) do
      fun when is_function(fun, 2) ->
        fun.(room_id, value)

      _ ->
        # Production default: inline SQL. UPDATE rooms SET is_auto_join = $1 WHERE room_id = $2.
        case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_update_auto_join, [value, room_id]) do
          {:ok, _} -> :ok
          {:error, _} = err -> err
        end
    end
  end

  # ── visibility WRITE via the Matrix public API (ADR-020) ───────────────────────

  defp update_visibility(actor_id, room_id, visibility) do
    case Application.get_env(:nebu_http, :admin_room_visibility_writer) do
      fun when is_function(fun, 3) -> fun.(actor_id, room_id, visibility)
      _ -> Nebu.Matrix.set_room_visibility(actor_id, room_id, visibility)
    end
  end

  # ── create / archive / unarchive WRITE via the Matrix public API (ADR-020) ─────
  # rm3: each routes through Nebu.Matrix (the audited, validated command path), never
  # into Matrix internals. Test seams (:admin_room_creator/archiver/unarchiver) record
  # the call without a live Matrix domain / Postgres; default = the real Matrix call.

  defp create_room(actor_id, opts) do
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

  # ── member add/remove WRITE via the Matrix public API (ADR-020) ─────────────────
  # rm4: each routes through Nebu.Matrix (the audited join/leave path). Test seams
  # (:admin_member_adder / :admin_member_remover) record the call without a live Matrix
  # domain / Postgres; default = the real Matrix call.

  defp add_member(room_id, user_id, actor_id) do
    case Application.get_env(:nebu_http, :admin_member_adder) do
      fun when is_function(fun, 3) -> fun.(room_id, user_id, actor_id)
      _ -> Nebu.Matrix.admin_add_room_member(room_id, user_id, actor_id)
    end
  end

  defp remove_member(room_id, user_id, actor_id) do
    case Application.get_env(:nebu_http, :admin_member_remover) do
      fun when is_function(fun, 3) -> fun.(room_id, user_id, actor_id)
      _ -> Nebu.Matrix.admin_remove_room_member(room_id, user_id, actor_id)
    end
  end

  # ── member-list READ ────────────────────────────────────────────────────────────
  # mount supplies session["room_members"] in the unit suite (no live Repo); production
  # reads through fetch_members/1 (the :admin_member_lister seam → Nebu.Admin.DB). Each
  # member is normalised to a %{user_id: ...} map — the user_id is the only field the
  # add/remove path and the row rendering need (display names are Tier-1 PII handled
  # elsewhere; the admin member surface keys off the Matrix user_id).

  defp load_members(room_id, session) do
    case session["room_members"] do
      list when is_list(list) -> Enum.map(list, &normalize_member/1)
      _ -> fetch_members(room_id)
    end
  end

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

  defp normalize_room(%{room_id: id} = room) do
    count = Map.get(room, :member_count, 0)

    %{
      room_id: id,
      name: Map.get(room, :name, ""),
      is_auto_join: !!Map.get(room, :is_auto_join, false),
      member_count: count,
      status: Nebu.Admin.DB.room_effective_status(Map.get(room, :status, "active"), count)
    }
  end

  defp normalize_room(%{"room_id" => id} = room) do
    count = Map.get(room, "member_count", 0)

    %{
      room_id: id,
      name: Map.get(room, "name", ""),
      is_auto_join: !!Map.get(room, "is_auto_join", false),
      member_count: count,
      status: Nebu.Admin.DB.room_effective_status(Map.get(room, "status", "active"), count)
    }
  end

  defp normalize_room_detail(%{room_id: _} = room) do
    %{
      room_id: room.room_id,
      name: Map.get(room, :name, ""),
      status: Map.get(room, :status, "active"),
      visibility: Map.get(room, :visibility, "private"),
      is_auto_join: !!Map.get(room, :is_auto_join, false)
    }
  end

  defp normalize_room_detail(%{"room_id" => id} = room) do
    %{
      room_id: id,
      name: Map.get(room, "name", ""),
      status: Map.get(room, "status", "active"),
      visibility: Map.get(room, "visibility", "private"),
      is_auto_join: !!Map.get(room, "is_auto_join", false)
    }
  end

  defp running?(name), do: Process.whereis(name) != nil

  # ── render (HEEx) ───────────────────────────────────────────────────────────────

  @impl Phoenix.LiveView
  def render(%{view_mode: :detail} = assigns) do
    ~H"""
    <div class="admin-room-detail" data-page="room-detail">
      <.link navigate="/admin/rooms" class="text-sm text-primary">&larr; Back to Rooms</.link>

      <p :if={Phoenix.Flash.get(@flash, :info)} class="alert alert-success my-4" role="status">
        {Phoenix.Flash.get(@flash, :info)}
      </p>
      <p :if={Phoenix.Flash.get(@flash, :error)} class="alert alert-error my-4" role="alert">
        {Phoenix.Flash.get(@flash, :error)}
      </p>

      <p :if={@room == nil} class="text-base-content/70 mt-4">Room not found.</p>

      <div :if={@room != nil}>
        <h1 class="text-2xl font-bold mb-4 flex items-center gap-3" data-room-id={@room.room_id}>
          {room_display_name(@room)}
          <span
            class={"badge " <> status_badge_class(room_status(@room))}
            data-role="status-badge"
            data-status={room_status(@room)}
          >
            {status_label(room_status(@room))}
          </span>
        </h1>

        <p :if={@detail_error} class="text-error mb-4" role="alert">{@detail_error}</p>

        <form
          id="room-settings-form"
          phx-submit="save_room_settings"
          class="mb-8 max-w-lg"
          data-form="room-settings"
        >
          <label class="form-control w-full mb-3">
            <span class="label-text">Visibility</span>
            <select
              name="visibility"
              class="select select-bordered w-full"
              data-field="visibility"
              aria-label="Room visibility"
            >
              <option value="private" selected={@room.visibility == "private"}>Private</option>
              <option value="public" selected={@room.visibility == "public"}>Public</option>
            </select>
          </label>
          <p class="text-sm text-base-content/70 mb-3" data-current-visibility={@room.visibility}>
            Current visibility: {visibility_label(@room.visibility)}
          </p>
          <button type="submit" class="btn btn-primary" role="button">Save settings</button>
        </form>

        <div class="mt-4 max-w-lg" data-section="archive-controls">
          <%!-- rm3 AC5: archive control + confirm (browser confirm dialog names the room).
                rm3 AC7: when archived, the Archive control is hidden and Unarchive is shown. --%>
          <button
            :if={room_status(@room) != "archived"}
            type="button"
            class="btn btn-error"
            role="button"
            data-role="archive-room"
            phx-click="archive_room"
            data-confirm={"Archive the room \"" <> room_display_name(@room) <> "\"? Members will no longer be able to send messages."}
          >
            Archive room
          </button>
          <button
            :if={room_status(@room) == "archived"}
            type="button"
            class="btn btn-primary"
            role="button"
            data-role="unarchive-room"
            phx-click="unarchive_room"
          >
            Unarchive
          </button>
        </div>

        <%!-- rm4 AC1–AC6: members section — list + add form + per-row remove. --%>
        <div class="mt-10 max-w-2xl" data-section="members">
          <h2 class="text-lg font-bold mb-3">Members</h2>

          <p :if={@member_error} class="text-error mb-3" role="alert" data-role="member-error">
            {@member_error}
          </p>

          <%!-- AC1: add-member form with an ARIA-combobox user typeahead (assistive;
                the field stays free-text). phx-change drives the debounced suggestion
                query; the listbox below is a role="listbox" of role="option" rows. --%>
          <form
            id="add-member-form"
            phx-submit="add_member"
            phx-change="suggest_users"
            class="flex items-end gap-2 mb-4"
            data-form="add-member"
          >
            <div class="form-control grow relative" role="none">
              <label for="add-member-user-id" class="label-text" id="add-member-user-id-label">
                Add user
              </label>
              <input
                type="text"
                id="add-member-user-id"
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
                aria-controls="add-member-user-suggestions"
                aria-labelledby="add-member-user-id-label"
                aria-label="Matrix user id to add"
                phx-debounce="200"
              />
              <ul
                :if={@user_suggestions != []}
                id="add-member-user-suggestions"
                role="listbox"
                aria-label="Matching users"
                class="menu bg-base-200 rounded-box shadow absolute z-10 mt-1 w-full max-h-60 overflow-auto"
              >
                <li
                  :for={s <- @user_suggestions}
                  role="option"
                  id={"user-suggestion-" <> s.user_id}
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

          <p :if={@members == []} class="text-base-content/70" data-role="no-members">
            No members.
          </p>

          <ul :if={@members != []} class="divide-y divide-base-300" role="list">
            <li
              :for={member <- @members}
              class="flex items-center justify-between py-2"
              data-role="member-row"
              data-user-id={member.user_id}
            >
              <span class="font-mono text-sm">{member.user_id}</span>
              <%!-- AC6: no Remove control for the logged-in admin's own row. --%>
              <button
                :if={member.user_id != @actor_id}
                type="button"
                class="btn btn-sm btn-error"
                role="button"
                data-role="remove-member"
                data-user-id={member.user_id}
                phx-click="remove_member"
                phx-value-user_id={member.user_id}
                data-confirm={"Remove " <> member.user_id <> " from " <> room_display_name(@room) <> "?"}
              >
                Remove
              </button>
            </li>
          </ul>
        </div>
      </div>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div class="admin-rooms" data-page="rooms">
      <div class="flex items-center justify-between mb-4">
        <h1 class="text-2xl font-bold">Rooms</h1>
        <%!-- rm3 AC1: open the create-room modal. DaisyUI modal toggled via the
              hidden checkbox controlling #create-room-modal. --%>
        <label for="create-room-modal" class="btn btn-primary" role="button" data-role="open-create-room">
          Create room
        </label>
      </div>

      <%!-- rm3 AC1/AC2/AC3: DaisyUI modal — name (required, 1–100) + visibility select. --%>
      <input type="checkbox" id="create-room-modal" class="modal-toggle" />
      <div class="modal" role="dialog">
        <div class="modal-box">
          <h2 class="text-lg font-bold mb-4">Create room</h2>

          <p :if={@create_error} class="text-error mb-3" role="alert" data-role="create-error">
            {@create_error}
          </p>

          <form id="create-room-form" phx-submit="create_room" data-form="create-room">
            <label class="form-control w-full mb-3">
              <span class="label-text">Room name</span>
              <input
                type="text"
                name="name"
                maxlength="100"
                placeholder="General"
                class="input input-bordered w-full"
                data-field="room-name"
                aria-label="Room name"
              />
            </label>
            <label class="form-control w-full mb-4">
              <span class="label-text">Visibility</span>
              <select
                name="visibility"
                class="select select-bordered w-full"
                data-field="visibility"
                aria-label="Room visibility"
              >
                <option value="private" selected>Private</option>
                <option value="public">Public</option>
              </select>
            </label>
            <div class="modal-action">
              <label for="create-room-modal" class="btn" role="button">Cancel</label>
              <button type="submit" class="btn btn-primary" role="button">Create</button>
            </div>
          </form>
        </div>
        <label class="modal-backdrop" for="create-room-modal">Close</label>
      </div>

      <form id="room-filter-form" phx-change="filter" class="mb-4 max-w-xs" data-form="room-filter">
        <label class="form-control w-full">
          <span class="label-text">Status</span>
          <select
            name="status"
            class="select select-bordered w-full"
            data-field="status-filter"
            aria-label="Filter rooms by status"
          >
            <option value="all" selected={@status_filter == "all"}>All</option>
            <option value="active" selected={@status_filter == "active"}>Active</option>
            <option value="archived" selected={@status_filter == "archived"}>Archived</option>
            <option value="stale" selected={@status_filter == "stale"}>Stale</option>
          </select>
        </label>
      </form>

      <p :if={@rooms == []} class="text-base-content/70">No rooms found.</p>

      <table :if={@rooms != []} class="table w-full" role="table">
        <thead>
          <tr>
            <th scope="col">Room</th>
            <th scope="col">Status</th>
            <th scope="col">Auto-join</th>
          </tr>
        </thead>
        <tbody>
          <tr
            :for={room <- @rooms}
            data-room-id={room.room_id}
            data-auto-join={to_string(room.is_auto_join)}
            data-status={room_status(room)}
          >
            <td>
              <.link navigate={"/admin/rooms/" <> room.room_id} class="text-primary">
                {room_display_name(room)}
              </.link>
            </td>
            <td>
              <span class={"badge " <> status_badge_class(room_status(room))} data-role="status-badge">
                {status_label(room_status(room))}
              </span>
            </td>
            <td>
              <label class="cursor-pointer label gap-2">
                <span class="sr-only">
                  Toggle auto-join for {room_display_name(room)}
                </span>
                <input
                  type="checkbox"
                  class="toggle toggle-primary"
                  name="is_auto_join"
                  role="switch"
                  data-role="auto-join-toggle"
                  data-room-id={room.room_id}
                  checked={room.is_auto_join}
                  aria-checked={to_string(room.is_auto_join)}
                  aria-label={"Auto-join " <> room_display_name(room)}
                  phx-click="toggle_auto_join"
                  phx-value-room_id={room.room_id}
                />
              </label>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp room_display_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp room_display_name(%{room_id: id}), do: id

  # rm2 AC2: the room's effective status, defaulting to "active" when absent (e.g. the
  # rm1 detail-mode session map that predates rm2 carries no member_count).
  defp room_status(%{status: status}) when is_binary(status), do: status
  defp room_status(_), do: "active"

  defp status_badge_class("stale"), do: "badge-warning"
  defp status_badge_class("archived"), do: "badge-ghost"
  defp status_badge_class(_), do: "badge-success"

  defp status_label("stale"), do: "Stale"
  defp status_label("archived"), do: "Archived"
  defp status_label(_), do: "Active"

  defp visibility_label("public"), do: "Public"
  defp visibility_label(_), do: "Private"
end
