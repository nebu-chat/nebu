defmodule Nebu.Admin.RoleMappingController do
  @moduledoc """
  HTTP controller for the Role Mapping editor (admin-http-refactor story).

  Replaces Nebu.Admin.RoleMappingLive. Analogous to ClaimMappingController
  but with a single `admin_group_claim` field.

  ADR-018: DB helpers, no domain model.
  ADR-019: Single OTP app.
  """
  use Phoenix.Controller, formats: [:html]

  import Plug.Conn

  plug Nebu.Admin.Auth, :require_admin

  @key "admin_group_claim"
  @default "groups"

  def index(conn, _params) do
    conn
    |> assign(:value, current_value())
    |> assign(:error, nil)
    |> assign(:page_title, "Role Mapping")
    |> assign(:active_nav, "role-mapping")
    |> assign(:bootstrap_completed, Nebu.Admin.Auth.bootstrap_completed?())
    |> put_layout(html: {Nebu.Admin.Layouts, :live})
    |> render(:index)
  end

  def update(conn, params) do
    value = String.trim(params[@key] || "")

    if value == "" do
      # Per-field validation: empty value not permitted (mirrors ClaimMappingController)
      conn
      |> assign(:value, value)
      |> assign(:error, "must not be empty")
      |> assign(:page_title, "Role Mapping")
      |> assign(:active_nav, "role-mapping")
      |> assign(:bootstrap_completed, Nebu.Admin.Auth.bootstrap_completed?())
      |> put_layout(html: {Nebu.Admin.Layouts, :live})
      |> put_status(200)
      |> render(:index)
    else
      case Process.whereis(Nebu.Repo) && Nebu.Admin.DB.upsert_server_config(%{@key => value}) do
        :ok ->
          conn
          |> put_flash(:info, "Role mapping saved.")
          |> redirect(to: "/admin/config/role-mapping")

        _ ->
          conn
          |> assign(:value, value)
          |> assign(:error, nil)
          |> assign(:page_title, "Role Mapping")
          |> assign(:active_nav, "role-mapping")
          |> assign(:bootstrap_completed, Nebu.Admin.Auth.bootstrap_completed?())
          |> put_layout(html: {Nebu.Admin.Layouts, :live})
          |> put_status(200)
          |> put_flash(:error, "Could not save (database unavailable).")
          |> render(:index)
      end
    end
  end

  defp current_value do
    case Process.whereis(Nebu.Repo) && Nebu.Admin.DB.get_server_config() do
      {:ok, cfg} -> Map.get(cfg, @key) || @default
      _ -> @default
    end
  end
end
