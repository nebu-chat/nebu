defmodule Nebu.Admin.RoleMappingController do
  @moduledoc """
  HTTP controller for the Role Mapping editor (admin-http-refactor story).

  Replaces Nebu.Admin.RoleMappingLive. Analogous to ClaimMappingController
  but with a single `admin_group_claim` field.

  Story admin-config-privileged-forms-sweep (follow-up `cw`): this field decides WHO IS AN ADMINISTRATOR, so the POST is protected like the SSO
  trust lists: `Nebu.Admin.OAuthAdminHelpers.gate(conn, :marker, "/admin/config/role-mapping")` (strict fetch metadata incl. the Safari click
  proof, then a fresh admin re-authentication marker bound to THIS page, consumed after a SUCCESSFUL write only), the page is not framable
  (router), one audit row `admin_group_claim_changed` (the group VALUE the admin check looks for) after the save. The bootstrap wizard is not gated (no admin exists yet).

  Story role-mapping-self-lockout-guard (follow-up `dg`): after the empty / universal-value refusals the value must also be among the values of the
  FRESH sign-in of the saving admin (`Nebu.Admin.Auth.reauth_role_check/2`, a fingerprint in the marker): a value the admin would not satisfy
  would lock every administrator out at the next sign-in or refresh. No override (ADR-033 SO10); the operator recovers with `bin/nebu rpc`.

  ADR-018: DB helpers, no domain model.
  ADR-019: Single OTP app.
  """
  use Phoenix.Controller, formats: [:html]

  import Plug.Conn
  require Logger

  plug Nebu.Admin.Auth, :require_admin

  # the page the fresh re-authentication marker of the form is bound to (and where the admin returns)
  @page "/admin/config/role-mapping"
  @page_reauth Nebu.Admin.Auth.reauth_start_path(@page)

  @key "admin_group_claim"
  # the value the admin check looks for when none is stored (`Nebu.Admin.Auth`)
  @default "instance_admin"

  def index(conn, _params) do
    conn
    |> assign(:value, current_value())
    |> assign(:error, nil)
    |> assign(:claim_path, Nebu.Admin.Auth.configured_admin_claim_path())
    |> assign(:reauth_link, nil)
    |> assign(:page_title, "Role Mapping")
    |> assign(:active_nav, "role-mapping")
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
    value = String.trim(if is_binary(params[@key]), do: params[@key], else: "")

    case refusal(conn, value) do
      {message, link} ->
        # per-field refusal (200, nothing written, the marker kept): empty (mirrors ClaimMappingController), a value that occurs in EVERY token
        # (SEC delta gate X2-1) or a value the saving admin would not satisfy (follow-up dg)
        render_refusal(conn, value, message, link)

      nil ->
        save(conn, value)
    end
  end

  defp save(conn, value) do
    result =
      Nebu.Admin.OAuthAdminHelpers.save_config_audited(conn, %{@key => value},
        action: "admin_group_claim_changed",
        target_id: @key,
        metadata: %{"admin_group_claim" => value},
        label: "role mapping",
        form: :role_mapping
      )

    case result do
      {:ok, :audited} ->
        conn
        |> Nebu.Admin.Auth.consume_reauth()
        |> put_flash(:info, "Role mapping saved.")
        |> redirect(to: @page)

      {:error, :audit} ->
        conn
        |> put_flash(:error, Nebu.Admin.OAuthAdminHelpers.audit_refused_flash("Role mapping"))
        |> render_form(value, nil, nil)

      _ ->
        conn
        |> put_flash(:error, "Could not save (database unavailable).")
        |> render_form(value, nil, nil)
    end
  end

  # the refusals in order: empty, universal (SEC delta gate X2-1), not satisfied by the saving admin (follow-up dg); `nil` = go on and save
  defp refusal(conn, value) do
    cond do
      value == "" ->
        {"must not be empty", nil}

      universal_value?(value) ->
        {"Not saved. This value occurs in every sign-in token, it would make every user an administrator.", nil}

      true ->
        case Nebu.Admin.Auth.reauth_role_check(conn, value) do
          :ok -> nil
          reason -> lockout_refusal(reason)
        end
    end
  end

  @rpc_hint ~s|bin/nebu rpc 'IO.inspect(Nebu.Release.reset_admin_group_claim("<value>"))'|

  defp lockout_refusal(reason) do
    # value-free: the reason only
    Logger.info("admin: role mapping save refused, the saving admin would not satisfy the value (#{reason})")

    case reason do
      :not_in_token ->
        where = Nebu.Admin.Auth.configured_admin_claim_path() || "any claim"

        {"Not saved. This value is not in your own sign-in token (claim: #{where}). If it were saved, you could not sign in as an administrator again, and other administrators " <>
           "would lose access unless their tokens hold it too. Join that group at your identity provider and sign in again, or ask the person who runs the server to set it with: #{@rpc_hint}",
         @page_reauth}

      :undecidable ->
        {"Not saved. Your sign-in token has more than 32 distinct values under this claim, so this value cannot be checked here, and we cannot tell whether other administrators " <>
           "would keep access. Ask the person who runs the server to set it with: #{@rpc_hint}", nil}

      :unknown ->
        {"Not saved. This value could not be verified: your fresh sign-in did not record which values your token holds. Sign in again and enter the value once more.", @page_reauth}
    end
  end

  defp render_refusal(conn, value, message, link), do: render_form(conn, value, message, link)

  defp render_form(conn, value, error, link) do
    conn
    |> assign(:value, value)
    |> assign(:error, error)
    |> assign(:claim_path, Nebu.Admin.Auth.configured_admin_claim_path())
    |> assign(:reauth_link, link)
    |> assign(:page_title, "Role Mapping")
    |> assign(:active_nav, "role-mapping")
    |> assign(:bootstrap_completed, Nebu.Admin.Auth.bootstrap_completed?())
    |> put_layout(html: {Nebu.Admin.Layouts, :live})
    |> put_status(200)
    |> render(:index)
  end

  # Values that occur in EVERY token of an OIDC sign-in or by default in every realm: the issuer URL and the client / audience ids (iss, aud, azp), the
  # protocol scope names, the default realm roles. Refused: with an any-key claim scan (no claim path configured) or a role claim they would make every
  # user an instance administrator. A deliberately broad group is still possible with a value that is not one of these.
  defp universal_value?(value) do
    down = String.downcase(value)

    down in ["openid", "profile", "email", "offline_access", "uma_authorization", "authenticated", "user", "users", "everyone", "true"] or
      String.starts_with?(down, "default-roles-") or
      down in configured_universal_values()
  end

  defp configured_universal_values do
    case Process.whereis(Nebu.Repo) && Nebu.Admin.DB.get_server_config() do
      {:ok, cfg} ->
        ~w(oidc_issuer oidc_client_id oidc_audience)
        |> Enum.map(&Map.get(cfg, &1))
        |> Enum.filter(&is_binary/1)
        |> Enum.map(&(&1 |> String.trim() |> String.downcase()))

      _ ->
        []
    end
  end

  defp current_value do
    case Process.whereis(Nebu.Repo) && Nebu.Admin.DB.get_server_config() do
      {:ok, cfg} -> Map.get(cfg, @key) || @default
      _ -> @default
    end
  end
end
