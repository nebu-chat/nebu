defmodule Nebu.Admin.ClaimMappingController do
  @moduledoc """
  HTTP controller for OIDC Claim Mapping editor (admin-http-refactor story).

  Replaces Nebu.Admin.ClaimMappingLive. GET renders form; POST validates and persists.
  On validation error: re-render with 200 and inline errors (no redirect).
  On success: persist via Nebu.Admin.DB.upsert_server_config and redirect.

  ADR-018: DB helpers, no domain model.
  ADR-019: Single OTP app.
  """
  use Phoenix.Controller, formats: [:html]

  import Plug.Conn

  plug Nebu.Admin.Auth, :require_admin

  @keys ~w(oidc_user_id_claim oidc_displayname_claim oidc_email_claim)
  @defaults %{
    "oidc_user_id_claim" => "name",
    "oidc_displayname_claim" => "name",
    "oidc_email_claim" => "email"
  }

  def index(conn, _params) do
    conn
    |> assign(:values, current_values())
    |> assign(:errors, %{})
    |> assign(:page_title, "Claim Mapping")
    |> assign(:active_nav, "claim-mapping")
    |> assign(:bootstrap_completed, Nebu.Admin.Auth.bootstrap_completed?())
    |> put_layout(html: {Nebu.Admin.Layouts, :live})
    |> render(:index)
  end

  def update(conn, params) do
    changes = Map.new(@keys, fn k -> {k, String.trim(params[k] || "")} end)

    errors =
      for {k, v} <- changes, v == "", into: %{}, do: {k, "must not be empty"}

    if errors != %{} do
      # Re-render with validation errors (200, no redirect)
      conn
      |> assign(:values, changes)
      |> assign(:errors, errors)
      |> assign(:page_title, "Claim Mapping")
      |> assign(:active_nav, "claim-mapping")
      |> assign(:bootstrap_completed, Nebu.Admin.Auth.bootstrap_completed?())
      |> put_layout(html: {Nebu.Admin.Layouts, :live})
      |> put_status(200)
      |> render(:index)
    else
      case Process.whereis(Nebu.Repo) && Nebu.Admin.DB.upsert_server_config(changes) do
        :ok ->
          conn
          |> put_flash(:info, "Claim mapping updated")
          |> redirect(to: "/admin/config/claim-mapping")

        _ ->
          conn
          |> assign(:values, changes)
          |> assign(:errors, %{})
          |> assign(:page_title, "Claim Mapping")
          |> assign(:active_nav, "claim-mapping")
          |> assign(:bootstrap_completed, Nebu.Admin.Auth.bootstrap_completed?())
          |> put_layout(html: {Nebu.Admin.Layouts, :live})
          |> put_status(200)
          |> put_flash(:error, "Could not save (database unavailable).")
          |> render(:index)
      end
    end
  end

  defp current_values do
    cfg =
      case Process.whereis(Nebu.Repo) && Nebu.Admin.DB.get_server_config() do
        {:ok, c} -> c
        _ -> %{}
      end

    Map.new(@keys, fn k -> {k, Map.get(cfg, k) || @defaults[k]} end)
  end
end
