defmodule Nebu.Admin.ConfigController do
  @moduledoc """
  HTTP controller for Admin Configuration page (admin-http-refactor story).

  Replaces Nebu.Admin.ConfigLive. GET /admin/config renders the config overview.
  POST /admin/config/refresh-mode updates the OIDC refresh mode (offline|online)
  for BOTH the Matrix and admin clients — mirroring the bootstrap-wizard contract
  (story oidc-refresh-mode-config, AC5/AC6). Each key is validated independently;
  only valid (offline|online) values are persisted.

  ADR-018: DB helpers inline, no domain model.
  ADR-019: Single OTP app.
  """
  use Phoenix.Controller, formats: [:html]

  import Plug.Conn

  plug Nebu.Admin.Auth, :require_admin

  # server_config keys this page may write, with their valid value set.
  @refresh_mode_keys ["matrix_oidc_refresh_mode", "admin_oidc_refresh_mode"]
  @valid_modes ["offline", "online"]

  def index(conn, _params) do
    render_config(conn)
  end

  def save_refresh_mode(conn, params) do
    # Collect only the keys present in the form whose value is valid (offline|online).
    # A garbage value for a key is silently dropped — it is never persisted.
    changes =
      @refresh_mode_keys
      |> Enum.filter(fn key -> params[key] in @valid_modes end)
      |> Map.new(fn key -> {key, params[key]} end)

    cond do
      changes == %{} ->
        # Nothing valid to save — re-render (200) without touching the DB.
        conn
        |> put_status(200)
        |> render_config()

      true ->
        case persist(changes) do
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
  end

  # Persist via the injectable writer seam (tests) or the DB (runtime).
  defp persist(changes) do
    case Application.get_env(:nebu_http, :admin_config_refresh_mode_writer) do
      writer when is_function(writer, 1) ->
        writer.(changes)

      _ ->
        if Process.whereis(Nebu.Repo) do
          Nebu.Admin.DB.upsert_server_config(changes)
        else
          {:error, :no_repo}
        end
    end
  end

  defp render_config(conn) do
    conn
    |> assign(:config, load_config())
    |> assign(:page_title, "Configuration")
    |> assign(:active_nav, "config")
    |> assign(:bootstrap_completed, Nebu.Admin.Auth.bootstrap_completed?())
    |> put_layout(html: {Nebu.Admin.Layouts, :live})
    |> render(:index)
  end

  defp load_config do
    case Process.whereis(Nebu.Repo) && Nebu.Admin.DB.get_server_config() do
      {:ok, cfg} -> Enum.sort(cfg)
      _ -> []
    end
  end

end
