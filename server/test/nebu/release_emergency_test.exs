defmodule Nebu.ReleaseEmergencyTest do
  @moduledoc """
  SEC delta gate admin-switch (X2-6): the operator emergency paths of the Admin UI settings, for instances without a database console
  (`bin/nebu rpc`): `Nebu.Release.disable_oauth/0`, `reset_admin_group_claim/1`, `reset_oidc_scopes/0`. Integration (real PostgreSQL, the runtime role).
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  alias Nebu.OAuth.TestSupport, as: T

  @issuer "https://chat.example.com"

  defmodule CaptureAudit do
    @moduledoc false
    def log(actor, action, target_type, target_id, metadata, outcome, _detail \\ nil) do
      send(Application.get_env(:nebu_http, :release_emergency_sink), {:audit, actor, action, target_type, target_id, metadata, outcome})
      Application.get_env(:nebu_http, :release_emergency_result, :ok)
    end
  end

  setup do
    T.set_oauth_rows!(%{"oauth_enabled" => "true", "oauth_issuer_url" => @issuer})
    prior = T.privileged_sql!("SELECT key, value, set_at FROM server_config WHERE key = ANY($1)", [["admin_group_claim", "matrix_oidc_extra_scopes", "admin_oidc_extra_scopes"]]).rows

    on_exit(fn ->
      T.privileged_sql!("DELETE FROM server_config WHERE key = ANY($1)", [["admin_group_claim", "matrix_oidc_extra_scopes", "admin_oidc_extra_scopes"]])
      for [k, v, at] <- prior, do: T.privileged_sql!("INSERT INTO server_config (key, value, set_at) VALUES ($1, $2, $3)", [k, v, at])
      Nebu.OAuth.Config.invalidate_cache()
    end)

    T.privileged_sql!("INSERT INTO server_config (key, value, set_at) VALUES ('admin_group_claim', 'wrong', 1) ON CONFLICT (key) DO UPDATE SET value = 'wrong'")
    T.put_env_scoped(:release_emergency_sink, self())
    T.put_env_scoped(:audit_writer, CaptureAudit, :compliance)
    T.put_env_scoped(:release_emergency_result, :ok)
    :ok
  end

  defp value_of(key), do: T.sql!("SELECT value FROM server_config WHERE key = $1", [key]).rows |> List.first() |> List.wrap() |> List.first()

  test "disable_oauth/0 switches OAuth off at once, keeps a valid issuer and writes one oauth_switch_changed row (actor operator:rpc)" do
    assert Nebu.OAuth.oauth_aware?()
    assert {:ok, %{audited: true}} = Nebu.Release.disable_oauth()
    assert value_of("oauth_enabled") == "false"
    assert value_of("oauth_issuer_url") == @issuer
    refute Nebu.OAuth.oauth_aware?()
    assert_received {:audit, "operator:rpc", "oauth_switch_changed", "server_config", "oauth_enabled", %{"enabled_after" => false, "reauth" => "rpc"}, "success"}
  end

  test "disable_oauth/0 is applied even when the audit row cannot be written (the kill switch is never blocked)" do
    Application.put_env(:nebu_http, :release_emergency_result, {:error, :audit_write_failed})

    ExUnit.CaptureLog.capture_log(fn -> assert {:ok, %{audited: false}} = Nebu.Release.disable_oauth() end)
    assert value_of("oauth_enabled") == "false"
  end

  test "disable_oauth/0 clears an invalid stored issuer instead of failing" do
    T.set_oauth_rows!(%{"oauth_enabled" => "true", "oauth_issuer_url" => "http://not-https.example"})
    assert {:ok, _} = Nebu.Release.disable_oauth()
    assert value_of("oauth_enabled") == "false"
    assert value_of("oauth_issuer_url") == ""
  end

  test "reset_admin_group_claim/1 sets the default or the given value (trimmed), refuses an empty one, writes the audit row" do
    assert :ok = Nebu.Release.reset_admin_group_claim()
    assert value_of("admin_group_claim") == "instance_admin"
    assert_received {:audit, "operator:rpc", "admin_group_claim_changed", "server_config", "admin_group_claim", %{"admin_group_claim" => "instance_admin", "reauth" => "rpc"}, "success"}

    assert :ok = Nebu.Release.reset_admin_group_claim("  ops-admins ")
    assert value_of("admin_group_claim") == "ops-admins"
    assert {:error, :empty_value} = Nebu.Release.reset_admin_group_claim("   ")
    assert value_of("admin_group_claim") == "ops-admins"
  end

  test "reset_oidc_scopes/0 clears both scope keys and writes one oidc_scopes_changed row" do
    T.privileged_sql!("INSERT INTO server_config (key, value, set_at) VALUES ('matrix_oidc_extra_scopes', 'bad scope', 1), ('admin_oidc_extra_scopes', 'bad', 1) ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value")
    assert :ok = Nebu.Release.reset_oidc_scopes()
    assert value_of("matrix_oidc_extra_scopes") == ""
    assert value_of("admin_oidc_extra_scopes") == ""
    assert_received {:audit, "operator:rpc", "oidc_scopes_changed", "server_config", "oidc_extra_scopes", %{"reauth" => "rpc"}, "success"}
  end
end
