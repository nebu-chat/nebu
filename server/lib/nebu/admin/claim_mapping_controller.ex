defmodule Nebu.Admin.ClaimMappingController do
  @moduledoc """
  HTTP controller for OIDC Claim Mapping editor (admin-http-refactor story).

  Replaces Nebu.Admin.ClaimMappingLive. GET renders form; POST validates and persists.
  On validation error: re-render with 200 and inline errors (no redirect).
  On success: persist value and audit row in one transaction via Nebu.Admin.DB.save_config_audited and redirect.

  Story admin-config-privileged-forms-sweep (follow-up `cw`): which IdP claim identifies a user decides who a login maps onto, so the POST
  is protected like the SSO trust lists: `Nebu.Admin.OAuthAdminHelpers.gate(conn, :marker, "/admin/config/claim-mapping")` (strict fetch
  metadata incl. the Safari click proof, then a fresh admin re-authentication marker bound to THIS page, consumed after a SUCCESSFUL write
  only), the page is not framable (router), one audit row `oidc_claim_mapping_changed` (claim names only) in the SAME transaction as the save (story admin-config-audit-atomic: no row, no save). The bootstrap
  wizard has its own controller and is not gated (no admin exists yet).

  ADR-018: DB helpers, no domain model.
  ADR-019: Single OTP app.
  """
  use Phoenix.Controller, formats: [:html]

  import Plug.Conn

  plug Nebu.Admin.Auth, :require_admin

  # the page the fresh re-authentication marker of the form is bound to (and where the admin returns)
  @page "/admin/config/claim-mapping"

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

  def update(conn, _params) do
    with {:ok, conn, _kind} <- Nebu.Admin.OAuthAdminHelpers.gate(conn, :marker, @page) do
      do_update(conn, conn.body_params)
    else
      {:halt, conn} -> conn
    end
  end

  defp do_update(conn, params) do
    changes = Map.new(@keys, fn k -> {k, String.trim(text(params[k]))} end)

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
      result =
        Nebu.Admin.OAuthAdminHelpers.save_config_audited(conn, changes,
          action: "oidc_claim_mapping_changed",
          target_id: "oidc_user_id_claim",
          metadata: %{"user_id_claim" => changes["oidc_user_id_claim"], "displayname_claim" => changes["oidc_displayname_claim"], "email_claim" => changes["oidc_email_claim"]},
          label: "OIDC claim mapping",
          form: :claim_mapping
        )

      case result do
        {:ok, :audited} ->
          conn
          |> Nebu.Admin.Auth.consume_reauth()
          |> put_flash(:info, "Claim mapping updated")
          |> redirect(to: "/admin/config/claim-mapping")

        {:error, :audit} ->
          rerender(conn, changes, Nebu.Admin.OAuthAdminHelpers.audit_refused_flash("Claim mapping"))

        _ ->
          rerender(conn, changes, "Could not save (database unavailable).")
      end
    end
  end

  defp rerender(conn, changes, message) do
    conn
    |> assign(:values, changes)
    |> assign(:errors, %{})
    |> assign(:page_title, "Claim Mapping")
    |> assign(:active_nav, "claim-mapping")
    |> assign(:bootstrap_completed, Nebu.Admin.Auth.bootstrap_completed?())
    |> put_layout(html: {Nebu.Admin.Layouts, :live})
    |> put_status(200)
    |> put_flash(:error, message)
    |> render(:index)
  end

  defp text(value) when is_binary(value), do: value
  defp text(_other), do: ""

  defp current_values do
    cfg =
      case Process.whereis(Nebu.Repo) && Nebu.Admin.DB.get_server_config() do
        {:ok, c} -> c
        _ -> %{}
      end

    Map.new(@keys, fn k -> {k, Map.get(cfg, k) || @defaults[k]} end)
  end
end
