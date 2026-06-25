defmodule Nebu.Admin.SpacesHTML do
  @moduledoc "Template module for SpacesController."
  use Phoenix.Component

  embed_templates "templates/spaces/*"

  defp space_display_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp space_display_name(%{room_id: id}), do: id
end
