defmodule Nebu.Admin.OAuthClientsHTML do
  @moduledoc "Template module for OAuthClientsController (story oauth-client-revocation)."
  use Phoenix.Component
  import Nebu.Admin.ReauthComponents

  embed_templates "templates/oauth_clients/*"

  @list_path "/admin/oauth/clients"
  @revoked_path "/admin/oauth/clients/revoked"

  @doc false
  def list_path, do: @list_path

  @doc false
  def revoked_path, do: @revoked_path

  @doc false
  # Link of a page of one of the lists: `?page=N` (omitted for page 1).
  def page_href(base, page) when page > 1, do: base <> "?page=#{page}"
  def page_href(base, _page), do: base

  @doc false
  def revoke_href(client_id), do: @list_path <> "/" <> URI.encode(client_id, &URI.char_unreserved?(&1)) <> "/revoke"

  @doc false
  # `YYYY-MM-DD HH:MM:SS UTC` (an em-dash when absent / never).
  def format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
  def format_time(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
  def format_time(_), do: "—"

  @doc false
  # The live session count, or `?` when it could not be read (never `0` for "unknown").
  def sessions_text(:unknown), do: "?"
  def sessions_text(n) when is_integer(n), do: Integer.to_string(n)
  def sessions_text(_), do: "?"

  @doc false
  def display_name(%{client_name: name}) when is_binary(name) and name != "", do: name
  def display_name(%{client_id: id}), do: "(unnamed client " <> id <> ")"

  @doc false
  def application_type_label("native"), do: "native"
  def application_type_label("web"), do: "web"
  def application_type_label(_), do: "unknown"

  @doc false
  # The back link of the 403 page names the page the admin came from.
  def back_label(path) when is_binary(path) do
    cond do
      String.ends_with?(path, "/approve") -> "Back to the approve confirmation page"
      String.ends_with?(path, "/revoke") -> "Back to the revoke confirmation page"
      path == "/admin/config" -> "Back to the configuration page"
      path == "/admin/config/claim-mapping" -> "Back to the claim mapping page"
      path == "/admin/config/role-mapping" -> "Back to the role mapping page"
      path == "/admin/rooms" -> "Back to the rooms page"
      path == "/admin/rooms/new" -> "Back to the create room form"
      String.starts_with?(path, "/admin/rooms/") -> "Back to the room page"
      path == "/admin/spaces" -> "Back to the spaces page"
      String.starts_with?(path, "/admin/spaces/") -> "Back to the space page"
      String.starts_with?(path, "/admin/users/") -> "Back to the user page"
      path == "/admin/logs/config" -> "Back to the log retention page"
      path == "/admin/media/settings" -> "Back to the media settings page"
      path == "/admin/dashboard" -> "Back to the dashboard"
      true -> "Back to pending OAuth clients"
    end
  end

  @doc false
  def plural(1, one, _many), do: "1 " <> one
  def plural(n, _one, many), do: "#{n} " <> many

  @doc false
  # The text the admin must type to confirm: `{:host, host}` or `{:client_id, id}`.
  def expected_label({:host, _}), do: "the client's verified host"
  def expected_label({:client_id, _}), do: "the client id (this client has no stored host)"

  @doc false
  def expected_value({_kind, value}), do: value
end
