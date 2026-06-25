defmodule Nebu.Admin.UsersController do
  @moduledoc """
  HTTP controller for the Admin Users page (admin-http-refactor story).

  Replaces Nebu.Admin.UsersLive with a plain Phoenix controller. GET /admin/users
  renders the user list as dead HTML — no WebSocket upgrade required.

  ADR-018: SQL inline in the action, no domain model.
  ADR-019: Single OTP app — all code under Nebu.Admin.
  """
  use Phoenix.Controller, formats: [:html]

  import Plug.Conn

  plug Nebu.Admin.Auth, :require_admin

  @sql_list_users """
  SELECT user_id, system_role, is_active, created_at
  FROM users
  ORDER BY created_at DESC, user_id
  LIMIT 500
  """

  def index(conn, _params) do
    users = load_users()

    conn
    |> assign(:users, users)
    |> assign(:page_title, "Users")
    |> assign(:active_nav, "users")
    |> assign(:bootstrap_completed, Nebu.Admin.Auth.bootstrap_completed?())
    |> put_layout(html: {Nebu.Admin.Layouts, :live})
    |> render(:index)
  end

  defp load_users do
    if running?(Nebu.Repo) do
      case Ecto.Adapters.SQL.query(Nebu.Repo, @sql_list_users, []) do
        {:ok, %{rows: rows}} ->
          Enum.map(rows, fn [user_id, role, is_active, created_at] ->
            %{user_id: user_id, role: role, is_active: !!is_active, created_at: created_at}
          end)

        _ ->
          []
      end
    else
      []
    end
  end

  defp running?(name), do: Process.whereis(name) != nil
end
