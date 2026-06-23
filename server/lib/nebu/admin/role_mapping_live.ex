defmodule Nebu.Admin.RoleMappingLive do
  @moduledoc """
  Role Mapping editor (Go parity: templates/role-mapping.html).

  Edits the OIDC group/role claim used to grant admin access
  (server_config: admin_group_claim). Persists via Nebu.Admin.DB.upsert_server_config
  (ADR-018).
  """
  use Phoenix.LiveView, layout: {Nebu.Admin.Layouts, :live}

  @key "admin_group_claim"
  @default "groups"

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:active_nav, "role-mapping")
     |> assign(:page_title, "Role Mapping")
     |> assign(:value, current_value())}
  end

  @impl Phoenix.LiveView
  def handle_event("save", params, socket) do
    value = String.trim(params[@key] || "")

    case Process.whereis(Nebu.Repo) && Nebu.Admin.DB.upsert_server_config(%{@key => value}) do
      :ok -> {:noreply, socket |> assign(:value, value) |> put_flash(:info, "Role mapping saved.")}
      _ -> {:noreply, put_flash(socket, :error, "Could not save (database unavailable).")}
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <h1 class="text-heading font-semibold mb-4">Role Mapping</h1>
    <p class="text-text-secondary mb-4">
      The OIDC token claim whose values grant instance-admin access.
    </p>

    <p :if={Phoenix.Flash.get(@flash, :info)} class="alert alert-success mb-4">{Phoenix.Flash.get(@flash, :info)}</p>
    <p :if={Phoenix.Flash.get(@flash, :error)} class="alert alert-error mb-4">{Phoenix.Flash.get(@flash, :error)}</p>

    <form phx-submit="save" class="max-w-md flex flex-col gap-4">
      <div>
        <label for="admin_group_claim" class="block text-sm mb-1">Admin group claim</label>
        <input id="admin_group_claim" name="admin_group_claim" value={@value} class="input input-bordered w-full" />
      </div>
      <button type="submit" class="btn btn-primary self-start">Save</button>
    </form>
    """
  end

  defp current_value do
    case Process.whereis(Nebu.Repo) && Nebu.Admin.DB.get_server_config() do
      {:ok, cfg} -> Map.get(cfg, @key) || @default
      _ -> @default
    end
  end
end
