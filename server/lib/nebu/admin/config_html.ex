defmodule Nebu.Admin.ConfigHTML do
  @moduledoc "Template module for ConfigController."
  use Phoenix.Component

  embed_templates "templates/config/*"

  @refresh_mode_defaults %{
    "matrix_oidc_refresh_mode" => "offline",
    "admin_oidc_refresh_mode" => "online"
  }

  defp refresh_mode(config, key) do
    case config_value(config, key) do
      v when v in ["offline", "online"] -> v
      _ -> @refresh_mode_defaults[key]
    end
  end

  defp config_value(config, key) when is_list(config) do
    case List.keyfind(config, key, 0) do
      {_, v} -> v
      nil -> nil
    end
  end
end
