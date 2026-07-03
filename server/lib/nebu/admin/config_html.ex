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

  defp scope_value(config, key) do
    config_value(config, key) || ""
  end

  # Story fix-and-configure-sso-redirect-schemes (AC8): mirrors scope_value/2 —
  # returns the current sso_extra_redirect_schemes config value, or "" when unset.
  defp sso_schemes_value(config, key) do
    config_value(config, key) || ""
  end

  defp config_value(config, key) when is_list(config) do
    case List.keyfind(config, key, 0) do
      {_, v} -> v
      nil -> nil
    end
  end
end
