defmodule Nebu.Admin.ConfigHTML do
  @moduledoc "Template module for ConfigController."
  use Phoenix.Component
  import Nebu.Admin.ReauthComponents

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

  # Story legacy-sso-redirect-confirmation (D14): the current `sso_redirect_allowed_origins` value, "" when unset.
  defp sso_origins_value(config, key) do
    config_value(config, key) || ""
  end

  # The field value: the SUBMITTED text again after a rejected save (the admin corrects it instead of retyping),
  # else the stored value.
  defp sso_origins_input_value(assigns, config) do
    case assigns[:sso_origins_submitted] do
      value when is_binary(value) -> value
      _ -> sso_origins_value(config, "sso_redirect_allowed_origins")
    end
  end

  defp sso_origins_describedby(assigns),
    do: if(assigns[:sso_origins_error], do: "sso-origins-help sso-origins-error", else: "sso-origins-help")

  # `https://<server_name>`, the origin that is trusted automatically for the legacy SSO login (help text).
  defp sso_server_origin do
    "https://" <> to_string(Application.get_env(:nebu_http, :server_name, "localhost"))
  end

  # Story admin-oauth-switch (AS9, AS12): the visible word of a status item (a status is never colour only).
  defp status_word(:ok), do: "OK"
  defp status_word(:attention), do: "Attention"
  defp status_word(:note), do: "Note"

  # aria-describedby of the OAuth fields: the help text, plus the error when there is one
  defp oauth_describedby(help_id, error_id, errors, key) do
    if Map.has_key?(errors, key), do: "#{error_id} #{help_id}", else: help_id
  end

  defp oauth_propagation_text(ms), do: Nebu.Admin.OAuthSwitch.propagation_text(ms)

  defp config_value(config, key) when is_list(config) do
    case List.keyfind(config, key, 0) do
      {_, v} -> v
      nil -> nil
    end
  end
end
