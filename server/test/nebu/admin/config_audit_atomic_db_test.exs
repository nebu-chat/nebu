defmodule Nebu.Admin.ConfigAuditAtomicDbTest do
  @moduledoc """
  Story `admin-config-audit-atomic`, AC8 (test-review MAJOR-1), integration (real PostgreSQL, the runtime role `nebu_app`, the REAL `Nebu.Compliance.AuditWriter`):
  the six privileged forms through the endpoint with NO seam except the audit writer module. Per form: an audit writer that fails leaves the stored value as it was
  and writes no row (a widening / a mapping); a working one leaves the new value and exactly ONE row of the form's action. The two ways back are checked too:
  a narrowing with a failing audit is applied without its row.
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  import Plug.Test
  import Plug.Conn
  import ExUnit.CaptureLog

  alias Nebu.Admin.Auth
  alias Nebu.OAuth.TestSupport, as: T

  @endpoint Nebu.Admin.Endpoint
  @secret_key_base String.duplicate("nebu-config-audit-db-key-base", 3)
  @config "/admin/config"
  @role "/admin/config/role-mapping"
  @claim "/admin/config/claim-mapping"
  @actions ~w(sso_redirect_origins_changed sso_redirect_schemes_changed oidc_claim_mapping_changed admin_group_claim_changed oidc_scopes_changed oidc_refresh_mode_changed)
  @keys ~w(sso_redirect_allowed_origins sso_extra_redirect_schemes oidc_user_id_claim oidc_displayname_claim oidc_email_claim admin_group_claim matrix_oidc_extra_scopes admin_oidc_extra_scopes matrix_oidc_refresh_mode admin_oidc_refresh_mode)

  defmodule FailingAudit do
    @moduledoc false
    def log(_actor, _action, _type, _id, _metadata, _outcome, _detail \\ nil), do: {:error, :audit_write_failed}
  end

  setup do
    for k <- [:admin_config_tx, :admin_server_config_reader, :admin_config_sso_origins_writer, :admin_config_sso_schemes_writer, :admin_config_scopes_writer, :admin_config_refresh_mode_writer, :admin_config_claim_mapping_writer, :admin_config_role_mapping_writer] do
      Application.delete_env(:nebu_http, k)
    end

    Application.delete_env(:compliance, :audit_writer)
    Application.put_env(:nebu_http, :admin_csrf_bypass, true)
    Application.put_env(:nebu_http, :admin_oidc_config_reader, fn _ -> nil end)

    prior = T.privileged_sql!("SELECT key, value, set_at FROM server_config WHERE key = ANY($1)", [@keys]).rows
    T.privileged_sql!("DELETE FROM server_config WHERE key = ANY($1)", [@keys])
    T.privileged_sql!("DELETE FROM audit_log WHERE action = ANY($1)", [@actions])

    for {k, v} <- [{"sso_redirect_allowed_origins", "https://a.example"}, {"sso_extra_redirect_schemes", "x-app"}, {"matrix_oidc_extra_scopes", "profile"}, {"admin_oidc_extra_scopes", ""}, {"matrix_oidc_refresh_mode", "offline"}, {"admin_oidc_refresh_mode", "offline"}, {"oidc_user_id_claim", "name"}, {"admin_group_claim", "instance_admin"}] do
      T.privileged_sql!("INSERT INTO server_config (key, value, set_at) VALUES ($1, $2, 1)", [k, v])
    end

    on_exit(fn ->
      Application.delete_env(:nebu_http, :admin_csrf_bypass)
      Application.delete_env(:nebu_http, :admin_oidc_config_reader)
      Nebu.Matrix.OidcClaimCache.reset_for_test()
      T.privileged_sql!("DELETE FROM server_config WHERE key = ANY($1)", [@keys])
      for [k, v, at] <- prior, do: T.privileged_sql!("INSERT INTO server_config (key, value, set_at) VALUES ($1, $2, $3)", [k, v, at])
      T.privileged_sql!("DELETE FROM audit_log WHERE action = ANY($1)", [@actions])
      if Process.whereis(Nebu.Web.OidcConfig), do: Nebu.Web.OidcConfig.refresh()
    end)

    :ok
  end

  defp value_of(key), do: T.sql!("SELECT value FROM server_config WHERE key = $1", [key]).rows |> List.first() |> List.wrap() |> List.first()
  defp audit_rows(action), do: T.privileged_sql!("SELECT actor_user_id, target_type, outcome FROM audit_log WHERE action = $1", [action]).rows

  defp post(path, page, params) do
    conn =
      %{conn(:post, path) | secret_key_base: @secret_key_base}
      |> @endpoint.admin_session([])
      |> fetch_session()
      |> put_session("current_user", %{"admin" => true, "sub" => "admin-1", "matrix_user_id" => "@admin:test.local"})
      |> Map.put(:body_params, params)
      |> Map.put(:params, params)
      |> T.put_strict_fetch_headers()

    conn =
      if page do
        m = T.fresh_marker("admin-1", 0, "auth_time", page)
        m = if page == @role, do: Map.merge(m, Auth.role_claim_fingerprint(%{"groups" => ["ops-admins"]})), else: m
        put_session(conn, "admin_reauth", m)
      else
        conn
      end

    @endpoint.call(conn, @endpoint.init([]))
  end

  # {label, path, marker page, params, action, [{key, old, new}]}
  @forms [
    {"SSO origins (widening)", "/admin/config/sso-origins", @config, %{"sso_redirect_allowed_origins" => "https://a.example, https://new.example"}, "sso_redirect_origins_changed", [{"sso_redirect_allowed_origins", "https://a.example", "https://a.example, https://new.example"}]},
    {"SSO schemes (widening)", "/admin/config/sso-schemes", @config, %{"sso_extra_redirect_schemes" => "x-app, y-app"}, "sso_redirect_schemes_changed", [{"sso_extra_redirect_schemes", "x-app", "x-app, y-app"}]},
    {"claim mapping", @claim, @claim, %{"oidc_user_id_claim" => "preferred_username", "oidc_displayname_claim" => "given_name", "oidc_email_claim" => "mail"}, "oidc_claim_mapping_changed", [{"oidc_user_id_claim", "name", "preferred_username"}]},
    {"role mapping", @role, @role, %{"admin_group_claim" => "ops-admins"}, "admin_group_claim_changed", [{"admin_group_claim", "instance_admin", "ops-admins"}]},
    {"OIDC scopes (widening)", "/admin/config/scopes", nil, %{"matrix_oidc_extra_scopes" => "profile groups", "admin_oidc_extra_scopes" => ""}, "oidc_scopes_changed", [{"matrix_oidc_extra_scopes", "profile", "profile groups"}]}
  ]

  for {label, path, page, params, action, [{key, old, new}]} <- @forms do
    test "#{label}: a failing audit writer leaves the stored value as it was and writes no row (one transaction)" do
      Application.put_env(:compliance, :audit_writer, FailingAudit)
      on_exit(fn -> Application.delete_env(:compliance, :audit_writer) end)

      capture_log(fn -> send(self(), {:conn, post(unquote(path), unquote(page), unquote(Macro.escape(params)))}) end)
      assert_received {:conn, conn}
      assert conn.status in [200, 302]
      assert value_of(unquote(key)) == unquote(old), "refused: the old value stays"
      assert audit_rows(unquote(action)) == []
      refute value_of(unquote(key)) == unquote(new)
    end

    test "#{label}: a working audit writer leaves the new value and exactly ONE audit row of the action" do
      conn = post(unquote(path), unquote(page), unquote(Macro.escape(params)))
      assert conn.status in [200, 302]
      assert value_of(unquote(key)) == unquote(new)
      assert [["@admin:test.local", "server_config", "success"]] = audit_rows(unquote(action))
    end
  end

  test "OIDC refresh mode: a failing audit writer does not block the way to online, and refuses offline (offline_access)" do
    Application.put_env(:compliance, :audit_writer, FailingAudit)
    on_exit(fn -> Application.delete_env(:compliance, :audit_writer) end)

    capture_log(fn ->
      send(self(), {:online, post("/admin/config/refresh-mode", nil, %{"matrix_oidc_refresh_mode" => "online", "admin_oidc_refresh_mode" => "offline"})})
    end)

    assert_received {:online, online}
    assert online.status == 302
    assert value_of("matrix_oidc_refresh_mode") == "online"
    assert value_of("admin_oidc_refresh_mode") == "offline", "unchanged"

    T.privileged_sql!("UPDATE server_config SET value = 'online' WHERE key = 'admin_oidc_refresh_mode'")
    capture_log(fn -> send(self(), {:widen, post("/admin/config/refresh-mode", nil, %{"matrix_oidc_refresh_mode" => "online", "admin_oidc_refresh_mode" => "offline"})}) end)
    assert_received {:widen, _}
    assert value_of("admin_oidc_refresh_mode") == "online", "offline is a widening: refused, the old value stays"
    assert audit_rows("oidc_refresh_mode_changed") == []
  end

  test "the ways back: a narrowing of the SSO origins and a clearing of the scopes are applied with a failing audit writer, without a row" do
    Application.put_env(:compliance, :audit_writer, FailingAudit)
    on_exit(fn -> Application.delete_env(:compliance, :audit_writer) end)

    T.privileged_sql!("UPDATE server_config SET value = 'https://a.example, https://b.example' WHERE key = 'sso_redirect_allowed_origins'")

    capture_log(fn ->
      send(self(), {:o, post("/admin/config/sso-origins", @config, %{"sso_redirect_allowed_origins" => "https://a.example"})})
      send(self(), {:s, post("/admin/config/scopes", nil, %{"matrix_oidc_extra_scopes" => "", "admin_oidc_extra_scopes" => ""})})
    end)

    assert_received {:o, origins}
    assert_received {:s, scopes}
    assert origins.status == 302 and scopes.status == 302
    assert value_of("sso_redirect_allowed_origins") == "https://a.example"
    assert value_of("matrix_oidc_extra_scopes") == ""
    assert audit_rows("sso_redirect_origins_changed") == []
    assert audit_rows("oidc_scopes_changed") == []
  end
end
