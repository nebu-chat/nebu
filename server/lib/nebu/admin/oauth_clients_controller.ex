defmodule Nebu.Admin.OAuthClientsController do
  @moduledoc """
  The approved / revoked OAuth clients and the revocation of an approved client (epic oauth-broker, story
  oauth-client-revocation, CR7-CR9, SO2-SO4). Plain controller, dead renders, Post-Redirect-Get, behind
  `Nebu.Admin.Auth, :require_admin`.

    * `GET  /admin/oauth/clients`                    — APPROVED clients, newest approval first, 50 per page
      (`?page=N`): claimed name (labelled unverified), verified `client_host`, type, approved by / at,
      `last_used_at`, live session count (devices with an unexpired session; `?` when it cannot be read, never
      `0`), a "Revoke" link
    * `GET  /admin/oauth/clients/revoked`            — REVOKED clients: revoked by / at, reason
    * `GET  /admin/oauth/clients/:client_id/revoke`  — the confirm page (read only; names client, verified host,
      device count and the consequences; no JavaScript confirm: a plain user-clicked submit, SO3)
    * `POST /admin/oauth/clients/:client_id/revoke`  — the revocation

  The POST checks, in this order: admin (plug), CSRF (router pipeline), STRICT fetch metadata (`403` page
  `fetch_metadata`), the fresh re-authentication marker BOUND TO THIS confirm page, valid 300 s and consumed by a
  successful revocation (`303` to `/admin/login/start?mode=reauth&return_to=<confirm page>`), the TYPED confirmation (`confirm_host` equals the client's verified host, trimmed and case-insensitive;
  the client id when the client has no stored host; it stops misclicks, not a same-origin script that can read the
  host, SO7), then `Nebu.OAuth.revoke_client/3`: status, sessions, devices (with their E2EE keys), codes and the
  audit row `oauth_client_revoked` (`devices`, `reauth`, optional `reason`; never client metadata or ids of users)
  in ONE transaction. A failed audit rolls everything back. The optional `reason` is normalised like the reject
  reason (`Nebu.OAuth.normalize_reason/1`). The only log lines: `OAuth admin: client revoked client_id=<id>
  devices=<n>` and error TYPES, never the reason text.

  ADR-018: no domain model here. ADR-020: the OAuth domain is reached only through `Nebu.OAuth`.
  """
  use Phoenix.Controller, formats: [:html]

  import Plug.Conn

  require Logger

  alias Nebu.Admin.OAuthAdminHelpers, as: Helpers

  plug Nebu.Admin.Auth, :require_admin

  @list_path "/admin/oauth/clients"

  def index(conn, params) do
    {clients, paging, load_error?} =
      case Nebu.OAuth.approved_clients(parse_page(params["page"])) do
        {:ok, %{clients: list} = paging} -> {Enum.map(list, &present/1), paging, false}
        {:error, _reason} -> {[], empty_paging(), true}
      end

    conn
    |> maybe_load_error(load_error?, "The approved clients could not be loaded. Please try again.")
    |> assign_paging(paging)
    |> assign(:clients, clients)
    |> assign(:load_error, load_error?)
    |> shell("Approved OAuth Clients", "oauth-approved-clients")
    |> render(:index)
  end

  def revoked(conn, params) do
    {clients, paging, load_error?} =
      case Nebu.OAuth.revoked_clients(parse_page(params["page"])) do
        {:ok, %{clients: list} = paging} -> {Enum.map(list, &present/1), paging, false}
        {:error, _reason} -> {[], empty_paging(), true}
      end

    conn
    |> maybe_load_error(load_error?, "The revoked clients could not be loaded. Please try again.")
    |> assign_paging(paging)
    |> assign(:clients, clients)
    |> assign(:load_error, load_error?)
    |> shell("Revoked OAuth Clients", "oauth-revoked-clients")
    |> render(:revoked)
  end

  def revoke_confirm(conn, %{"client_id" => client_id}) do
    case approved(client_id) do
      {:ok, client} ->
        conn
        |> assign(:client, present(client))
        |> assign(:expected, expected_confirmation(client))
        |> assign(:device_count, device_count(client_id))
        |> Nebu.Admin.OAuthAdminHelpers.assign_reauth(revoke_path(client_id))
        |> assign(:revoke_path, revoke_path(client_id))
        |> shell("Revoke OAuth client", "oauth-approved-clients")
        |> render(:revoke_confirm)

      :error ->
        conn
        |> put_flash(:error, "This client is unknown or not approved (it may already be revoked).")
        |> redirect(to: @list_path)
    end
  end

  def revoke(conn, %{"client_id" => client_id} = params) do
    confirm_path = revoke_path(client_id)

    with {:actor, actor} when is_binary(actor) <- {:actor, Helpers.actor_id(conn)},
         {:gate, {:ok, conn, kind}} <- {:gate, Helpers.gate(conn, :marker, confirm_path)},
         {:client, {:ok, client}} <- {:client, approved(client_id)},
         {:typed, true} <- {:typed, confirmed?(params["confirm_host"], client)} do
      do_revoke(conn, client, actor, kind, Nebu.OAuth.normalize_reason(params["reason"]))
    else
      {:gate, {:halt, conn}} ->
        conn

      {:actor, _} ->
        conn |> put_flash(:error, "Could not determine the admin user id.") |> redirect(to: @list_path)

      {:client, :error} ->
        conn
        |> put_flash(:error, "This client is unknown or not approved (it may already be revoked). Nothing was changed.")
        |> redirect(to: @list_path)

      {:typed, false} ->
        conn
        |> put_flash(:error, "The confirmation did not match. Type the host shown on this page exactly. Nothing was changed.")
        # also shown WITH the field (aria-describedby / aria-invalid), see revoke_confirm.html.heex
        |> put_flash(:confirm_host_error, "The text does not match the host shown above. Nothing was changed.")
        |> redirect(to: confirm_path)
    end
  end

  defp do_revoke(conn, client, actor, kind, reason) do
    client_id = client.client_id

    audit = fn pairs ->
      metadata =
        %{"devices" => length(pairs), "reauth" => kind}
        |> then(fn m -> if reason, do: Map.put(m, "reason", reason), else: m end)

      Helpers.write_audit(actor, "oauth_client_revoked", client_id, metadata)
    end

    case Nebu.OAuth.revoke_client(client_id, actor, reason: reason, audit: audit) do
      {:ok, %{devices: devices}} ->
        Logger.info("OAuth admin: client revoked client_id=#{client_id} devices=#{devices}")

        # one fresh sign-in, one decision (Kassandra M-1)
        conn
        |> Nebu.Admin.Auth.consume_reauth()
        |> put_flash(:info, "#{Helpers.client_label(client, client_id)} revoked. #{devices_text(devices)}")
        |> redirect(to: @list_path)

      {:error, :not_approved} ->
        conn
        |> put_flash(:error, "This client is unknown or not approved (it may already be revoked). Nothing was changed.")
        |> redirect(to: @list_path)

      {:error, {:audit, reason}} ->
        # Revocation and audit row share one transaction: everything was rolled back.
        Logger.error("OAuth admin: audit entry for client revocation client_id=#{client_id} could not be written, revocation rolled back: #{Helpers.error_type(reason)}")

        conn
        |> put_flash(
          :error,
          "The revocation was not saved because its audit log entry could not be written. " <>
            "Nothing was changed; the client is still approved. Please try again or contact the operator."
        )
        |> redirect(to: revoke_path(client_id))

      {:error, other} ->
        Logger.error("OAuth admin: client revocation client_id=#{client_id} could not be saved: #{Helpers.error_type(other)}")

        conn
        |> put_flash(:error, "The revocation could not be saved; nothing was changed. Please try again.")
        |> redirect(to: revoke_path(client_id))
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp approved(client_id) do
    case Nebu.OAuth.registration(client_id) do
      %{status: "approved"} = client -> {:ok, client}
      _ -> :error
    end
  end

  # What the admin has to type: the verified client host, or the client id when the client has none.
  defp expected_confirmation(%{client_host: host}) when is_binary(host) and host != "", do: {:host, host}
  defp expected_confirmation(%{client_id: id}), do: {:client_id, id}

  # Trimmed; hosts are compared case-insensitively, a client id exactly. A non-binary value (`confirm_host[]=`) never matches.
  defp confirmed?(value, client) when is_binary(value) do
    typed = String.trim(value)

    case expected_confirmation(client) do
      {:host, host} -> typed != "" and String.downcase(typed) == String.downcase(host)
      {:client_id, id} -> typed != "" and typed == id
    end
  end

  defp confirmed?(_value, _client), do: false

  defp device_count(client_id) do
    case Nebu.OAuth.client_session_count(client_id) do
      {:ok, n} -> n
      {:error, _} -> :unknown
    end
  end

  defp devices_text(0), do: "No device was signed in."
  defp devices_text(1), do: "1 device was signed out and removed."
  defp devices_text(n), do: "#{n} devices were signed out and removed."

  defp revoke_path(client_id), do: @list_path <> "/" <> Helpers.seg(client_id) <> "/revoke"

  defp shell(conn, title, nav) do
    conn
    |> assign(:oauth_enabled, Nebu.OAuth.config().enabled)
    |> assign(:page_title, title)
    |> assign(:active_nav, nav)
    |> assign(:bootstrap_completed, Nebu.Admin.Auth.bootstrap_completed?())
    |> put_layout(html: {Nebu.Admin.Layouts, :live})
  end

  defp assign_paging(conn, paging) do
    conn
    |> assign(:total, paging.total)
    |> assign(:page, paging.page)
    |> assign(:page_size, paging.page_size)
    |> assign(:total_pages, paging.total_pages)
  end

  defp empty_paging, do: %{total: 0, page: 1, page_size: Nebu.OAuth.page_size(), total_pages: 1}

  # An unreadable database is NOT "no clients": say so instead of rendering the empty state.
  defp maybe_load_error(conn, true, message), do: put_flash(conn, :error, message)
  defp maybe_load_error(conn, false, _message), do: conn

  defp parse_page(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n >= 1 -> n
      _ -> 1
    end
  end

  defp parse_page(_), do: 1

  defp present(%{client_id: id, metadata: meta} = client) do
    client
    |> Map.take([:application_type, :client_host, :approved_by, :approved_at, :last_used_at, :revoked_by, :revoked_at, :revoked_reason, :sessions])
    |> Map.merge(%{
      client_id: id,
      client_name: string_field(meta, "client_name"),
      client_uri: string_field(meta, "client_uri"),
      redirect_uris: list_field(meta, "redirect_uris")
    })
  end

  defp string_field(meta, key) do
    case Map.get(meta, key) do
      v when is_binary(v) -> v
      _ -> nil
    end
  end

  defp list_field(meta, key) do
    case Map.get(meta, key) do
      list when is_list(list) -> Enum.filter(list, &is_binary/1)
      _ -> []
    end
  end
end
