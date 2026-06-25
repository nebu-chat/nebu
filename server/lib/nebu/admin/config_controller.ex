defmodule Nebu.Admin.ConfigController do
  @moduledoc """
  HTTP controller for Admin Configuration page (admin-http-refactor story).

  Replaces Nebu.Admin.ConfigLive. GET /admin/config renders the config overview.
  POST /admin/config/refresh-mode updates the refresh mode (offline|online only).

  ADR-018: DB helpers inline, no domain model.
  ADR-019: Single OTP app.
  """
  use Phoenix.Controller, formats: [:html]

  import Plug.Conn

  plug Nebu.Admin.Auth, :require_admin

  def index(conn, _params) do
    conn
    |> assign(:config, load_config())
    |> assign(:page_title, "Configuration")
    |> assign(:active_nav, "config")
    |> assign(:bootstrap_completed, Nebu.Admin.Auth.bootstrap_completed?())
    |> put_layout(html: {Nebu.Admin.Layouts, :live})
    |> render(:index)
  end

  def save_refresh_mode(conn, params) do
    mode = params["refresh_mode"]

    if mode in ["offline", "online"] do
      writer = Application.get_env(:nebu_http, :admin_config_refresh_mode_writer)

      if is_function(writer, 1) do
        writer.(mode)

        conn
        |> put_flash(:info, "Configuration saved")
        |> redirect(to: "/admin/config")
      else
        case Process.whereis(Nebu.Repo) &&
               Nebu.Admin.DB.upsert_server_config(%{"matrix_oidc_refresh_mode" => mode}) do
          :ok ->
            conn
            |> put_flash(:info, "Configuration saved")
            |> redirect(to: "/admin/config")

          _ ->
            conn
            |> put_flash(:error, "Failed to save configuration")
            |> redirect(to: "/admin/config")
        end
      end
    else
      # Invalid value — re-render with 200 (consistent with other validation re-renders)
      conn
      |> assign(:config, load_config())
      |> assign(:page_title, "Configuration")
      |> assign(:active_nav, "config")
      |> assign(:bootstrap_completed, Nebu.Admin.Auth.bootstrap_completed?())
      |> put_layout(html: {Nebu.Admin.Layouts, :live})
      |> put_status(200)
      |> render(:index)
    end
  end

  defp load_config do
    case Process.whereis(Nebu.Repo) && Nebu.Admin.DB.get_server_config() do
      {:ok, cfg} -> Enum.sort(cfg)
      _ -> []
    end
  end

end
