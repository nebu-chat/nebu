defmodule Nebu.Admin.UsersLive do
  @moduledoc """
  User Overview LiveView (admin-ui-migration, AC1).

  Ports the Go admin User Overview (gateway/internal/admin/users.go) read view to
  Phoenix LiveView: a read-only list of OIDC-provisioned users with their system role
  and active/deactivated status.

  ## ADR-018 — inline SQL, locality of behavior

  The read is inline SQL against `Nebu.Repo` (`SELECT user_id, system_role, is_active,
  created_at FROM users`). The `users` table stores display name + email *encrypted*
  (Tier-1/Tier-2 PII columns `display_name_encrypted` / `email_encrypted`); this
  overview deliberately shows only the non-PII identity columns (user_id is the Matrix
  ID, already public) so it needs no PII-decryption dependency. Decryption-bearing
  detail views remain a follow-up (parity with the Go detail panel).

  Stateless / DB-backed (Persistenz Option C) — no GenServer state to recover.
  """
  use Phoenix.LiveView, layout: {Nebu.Admin.Layouts, :live}

  @sql_list_users """
  SELECT user_id, system_role, is_active, created_at
  FROM users
  ORDER BY created_at DESC, user_id
  LIMIT 500
  """

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok, assign(socket, users: load_users(), page_title: "Users", active_nav: "users")}
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

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div class="admin-users" data-page="users">
      <h1 class="text-2xl font-bold mb-4">Users</h1>

      <p :if={@users == []} class="text-base-content/70">No users found.</p>

      <table :if={@users != []} class="table w-full" role="table">
        <thead>
          <tr>
            <th scope="col">User</th>
            <th scope="col">Role</th>
            <th scope="col">Status</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={user <- @users} data-user-id={user.user_id}>
            <td>{user.user_id}</td>
            <td>{user.role}</td>
            <td>
              <span
                class={"badge " <> if(user.is_active, do: "badge-success", else: "badge-error")}
                data-status={if user.is_active, do: "active", else: "deactivated"}
              >
                {if user.is_active, do: "active", else: "deactivated"}
              </span>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end
end
