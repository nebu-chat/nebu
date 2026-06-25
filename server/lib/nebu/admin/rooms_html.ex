defmodule Nebu.Admin.RoomsHTML do
  @moduledoc "Template module for RoomsController."
  use Phoenix.Component

  embed_templates "templates/rooms/*"

  defp room_display_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp room_display_name(%{room_id: id}), do: id

  defp room_status(%{status: status}) when is_binary(status), do: status
  defp room_status(_), do: "active"

  defp status_badge_class("stale"), do: "badge-warning"
  defp status_badge_class("archived"), do: "badge-ghost"
  defp status_badge_class(_), do: "badge-success"

  defp status_label("stale"), do: "Stale"
  defp status_label("archived"), do: "Archived"
  defp status_label(_), do: "Active"

  defp visibility_label("public"), do: "Public"
  defp visibility_label(_), do: "Private"
end
