defmodule Nebu.Admin.AdminReauthButtonFlowFilterParametersTest do
  @moduledoc """
  Story `admin-reauth-button-flow`, Decision "Scope extension": `Phoenix.Logger` prints the request parameters of every controller action at `:debug`, also when a gate
  halts the request. `config :phoenix, filter_parameters` (`server/config/config.exs`) must therefore mask the field of every marker-gated form (and keep the keys it
  already masks: the revoke form of `oauth-client-revocation`, AC11). The test uses the real application config and Phoenix's own `Phoenix.Logger.filter_values/2`, so it holds
  for a deny-list as well as for `{:keep, [...]}`.
  """
  use ExUnit.Case, async: true

  # the existing keys (oauth-client-revocation AC11) stay
  @existing ["password", "reason", "confirm_host", "_csrf_token", "csrf_token"]

  # every sensitive field name of the 9 gated forms: SSO schemes (1), SSO origins (2), OAuth switch (3), claim mapping (4), role mapping (5), media policy (6), storage target (7)
  @form_fields %{
    "SSO schemes" => ["sso_extra_redirect_schemes"],
    "SSO origins" => ["sso_redirect_allowed_origins"],
    "OAuth switch" => ["oauth_issuer_url"],
    "claim mapping" => ["oidc_user_id_claim", "oidc_displayname_claim", "oidc_email_claim"],
    "role mapping" => ["admin_group_claim"],
    "media policy" => ["webhook_url"],
    # the IAM / STS endpoints are full URLs without a user info check (`https://key:secret@host`); "endpoint" is a substring match that covers them
    "storage target" => ["access_key", "secret_key", "endpoint", "iam_endpoint", "sts_endpoint"],
    "approve / revoke" => ["reason", "confirm_host"]
  }

  for {form, names} <- @form_fields, name <- names do
    test "filter_parameters masks #{name} (#{form})" do
      filter = Application.get_env(:phoenix, :filter_parameters, [])
      masked = Phoenix.Logger.filter_values(%{unquote(name) => "canary-value-zq99"}, filter)

      assert masked[unquote(name)] == "[FILTERED]",
             "config :phoenix, filter_parameters (server/config/config.exs) must mask #{unquote(name)}: Phoenix logs the parameters at :debug, got #{inspect(masked)}"
    end
  end

  test "filter_parameters keeps masking the keys it masked before this story" do
    filter = Application.get_env(:phoenix, :filter_parameters, [])

    for name <- @existing do
      assert Phoenix.Logger.filter_values(%{name => "canary-value-zq99"}, filter)[name] == "[FILTERED]", "filter_parameters must still mask #{name}"
    end
  end

  test "a nested parameter of a gated form is masked too" do
    filter = Application.get_env(:phoenix, :filter_parameters, [])
    masked = Phoenix.Logger.filter_values(%{"form" => %{"secret_key" => "canary-value-zq99"}}, filter)
    assert masked["form"]["secret_key"] == "[FILTERED]", "filter_parameters must mask nested values (secret_key)"
  end
end
