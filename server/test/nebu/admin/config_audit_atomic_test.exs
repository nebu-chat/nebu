defmodule Nebu.Admin.ConfigAuditAtomicTest do
  @moduledoc """
  Story `admin-config-audit-atomic` (follow-up `dh`, X2-4), AC2 - AC4 (decisions D2, D3, D4): the six privileged `server_config` forms save the value and
  its audit row in ONE transaction (`Nebu.Admin.DB.save_config_audited/2`); the transaction is replaced here by the seam `:nebu_http, :admin_config_tx`
  (`fn changes, audit -> :ok | {:error, term}`; this fake COMMITS only when the audit function answers `:ok` or is `nil`, which models the rollback).

  The policy when the audit row cannot be written (D2): role and claim mapping refused; SSO origin and scheme lists refused for a widening and applied
  without the row for a subset (narrowing / clearing: the way back); scopes refused unless every changed key narrows (a clear included); refresh mode
  applied without the row. The flashes and the marker behaviour are D3.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn
  import ExUnit.CaptureLog

  alias Nebu.Admin.Auth
  alias Nebu.OAuth.TestSupport, as: T

  @endpoint Nebu.Admin.Endpoint
  @secret_key_base String.duplicate("nebu-config-audit-atomic-key-base", 3)
  @config "/admin/config"
  @role "/admin/config/role-mapping"
  @claim "/admin/config/claim-mapping"
  @refused "not saved: the audit entry could not be written, so nothing was changed."
  @unaudited "saved, but the audit entry could not be written"

  defmodule CaptureAudit do
    @moduledoc false
    def log(actor, action, target_type, target_id, metadata, outcome, error_detail \\ nil) do
      send(Application.get_env(:nebu_http, :atomic_audit_sink), {:audit, actor, action, target_type, target_id, metadata, outcome, error_detail})
      Application.get_env(:nebu_http, :atomic_audit_result, :ok)
    end
  end

  setup do
    test_pid = self()
    Application.put_env(:nebu_http, :admin_csrf_bypass, true)
    T.put_env_scoped(:atomic_audit_sink, self())
    T.put_env_scoped(:atomic_audit_result, :ok)
    T.put_env_scoped(:audit_writer, CaptureAudit, :compliance)

    # the transaction: commits only when the audit function succeeds (or is nil)
    Application.put_env(:nebu_http, :admin_config_tx, fn changes, audit ->
      send(test_pid, {:tx, changes, audit != nil})

      case audit && audit.() do
        r when r in [nil, :ok] ->
          send(test_pid, {:committed, changes})
          :ok

        {:error, reason} ->
          {:error, {:audit, reason}}
      end
    end)

    Application.put_env(:nebu_http, :admin_oidc_config_reader, fn _ -> nil end)
    stored(%{})

    on_exit(fn ->
      for k <- [:admin_csrf_bypass, :admin_config_tx, :admin_server_config_reader, :admin_oidc_config_reader], do: Application.delete_env(:nebu_http, k)
    end)

    :ok
  end

  defp stored(map), do: Application.put_env(:nebu_http, :admin_server_config_reader, fn -> {:ok, map} end)
  defp audit_fails, do: Application.put_env(:nebu_http, :atomic_audit_result, {:error, :audit_write_failed})

  defp admin_conn(method, path, params, user \\ %{"admin" => true, "sub" => "admin-1", "matrix_user_id" => "@admin:test.local"}) do
    %{conn(method, path) | secret_key_base: @secret_key_base}
    |> @endpoint.admin_session([])
    |> fetch_session()
    |> put_session("current_user", user)
    |> Map.put(:body_params, params)
    |> Map.put(:params, params)
    |> T.put_strict_fetch_headers()
  end

  defp marker(conn, path) do
    m = T.fresh_marker("admin-1", 0, "auth_time", path)
    m = if path == @role, do: Map.merge(m, Auth.role_claim_fingerprint(%{"groups" => ["ops-admins"]})), else: m
    put_session(conn, "admin_reauth", m)
  end

  defp call(conn), do: @endpoint.call(conn, @endpoint.init([]))

  defp flash(conn, key) do
    k = to_string(key)
    from_assigns = if is_map(conn.assigns[:flash]), do: conn.assigns[:flash][k]
    from_session =
      case conn.private[:plug_session] do
        %{"phoenix_flash" => m} when is_map(m) -> m[k]
        _ -> nil
      end

    from_assigns || get_in(conn.private, [:phoenix_flash, k]) || from_session
  end

  defp marker_kept?(conn), do: conn.private.plug_session["admin_reauth"] != nil

  # the six forms: {label, path, marker page | nil, params, stored config, audit action, audit target, expected metadata keys, success flash, status}
  @forms [
    {:origins, "/admin/config/sso-origins", @config, %{"sso_redirect_allowed_origins" => "https://a.example, https://new.example"}, %{"sso_redirect_allowed_origins" => "https://a.example"},
     "sso_redirect_origins_changed", "sso_redirect_allowed_origins", ["count", "origins"], "SSO origins saved", 302},
    {:schemes, "/admin/config/sso-schemes", @config, %{"sso_extra_redirect_schemes" => "x-app, y-app"}, %{"sso_extra_redirect_schemes" => "x-app"}, "sso_redirect_schemes_changed",
     "sso_extra_redirect_schemes", ["count", "schemes"], "SSO schemes saved", 302},
    {:claim, @claim, @claim, %{"oidc_user_id_claim" => "preferred_username", "oidc_displayname_claim" => "given_name", "oidc_email_claim" => "mail"}, %{}, "oidc_claim_mapping_changed",
     "oidc_user_id_claim", ["displayname_claim", "email_claim", "user_id_claim"], "Claim mapping updated", 302},
    {:role, @role, @role, %{"admin_group_claim" => "ops-admins"}, %{}, "admin_group_claim_changed", "admin_group_claim", ["admin_group_claim"], "Role mapping saved.", 302},
    {:scopes, "/admin/config/scopes", nil, %{"matrix_oidc_extra_scopes" => "profile groups", "admin_oidc_extra_scopes" => ""}, %{"matrix_oidc_extra_scopes" => "profile"}, "oidc_scopes_changed",
     "oidc_extra_scopes", ["admin_oidc_extra_scopes", "matrix_oidc_extra_scopes"], "Scopes saved", 302},
    {:refresh, "/admin/config/refresh-mode", nil, %{"matrix_oidc_refresh_mode" => "online", "admin_oidc_refresh_mode" => "offline"}, %{"matrix_oidc_refresh_mode" => "offline"},
     "oidc_refresh_mode_changed", "oidc_refresh_mode", ["admin_oidc_refresh_mode", "matrix_oidc_refresh_mode"], "Configuration saved", 302}
  ]

  defp post(path, page, params, user \\ nil) do
    conn = if user, do: admin_conn(:post, path, params, user), else: admin_conn(:post, path, params)
    conn = if page, do: marker(conn, page), else: conn
    call(conn)
  end

  # ─── AC2 / AC4 — the success path: ONE transaction with the audit function, one row, the old observable behaviour ─────

  describe "AC2 / AC4 — every form saves value and audit row in one transaction" do
    for {label, path, page, params, cfg, action, target, meta_keys, success_flash, status} <- @forms do
      test "#{label}: one transaction WITH the audit function, committed once, one audit row (action, target, metadata keys), the success flash, the marker consumed" do
        stored(unquote(Macro.escape(cfg)))
        conn = post(unquote(path), unquote(page), unquote(Macro.escape(params)))

        assert conn.status == unquote(status)
        assert_received {:tx, changes, true}
        assert changes != %{}
        assert_received {:committed, ^changes}
        refute_received {:tx, _, _}
        assert_received {:audit, "@admin:test.local", unquote(action), "server_config", unquote(target), metadata, "success", _}
        assert metadata |> Map.keys() |> Enum.sort() == unquote(meta_keys)
        refute_received {:audit, _, _, _, _, _, _, _}, "exactly one row per save"
        if unquote(page), do: refute(marker_kept?(conn), "a saved change consumes the marker")
        assert flash(conn, :info) == unquote(success_flash)
        assert flash(conn, :error) == nil
      end
    end

    test "the changes handed to the transaction are the normalized values (schemes: trimmed and rejoined)" do
      post("/admin/config/sso-schemes", @config, %{"sso_extra_redirect_schemes" => " x-app ,y-app "})
      assert_received {:tx, %{"sso_extra_redirect_schemes" => "x-app, y-app"}, true}
    end
  end

  # ─── AC3 — an audit that fails ───────────────────────────────────────────

  describe "AC3 / D2 — role mapping and claim mapping: the audit failure REFUSES the save" do
    for {label, path, page, params} <- [{"role mapping", @role, @role, %{"admin_group_claim" => "ops-admins"}}, {"claim mapping", @claim, @claim, %{"oidc_user_id_claim" => "preferred_username", "oidc_displayname_claim" => "given_name", "oidc_email_claim" => "mail"}}] do
      test "#{label}: nothing committed, 200 re-render with the refusal flash (role alert), the typed value kept, the marker kept, exactly one attempt" do
        audit_fails()

        {conn, log} = with_log(fn -> post(unquote(path), unquote(page), unquote(Macro.escape(params))) end)

        assert conn.status == 200
        assert_received {:tx, _, true}
        refute_received {:tx, _, _}
        refute_received {:committed, _}
        assert flash(conn, :error) =~ @refused
        assert marker_kept?(conn)
        refute log =~ "ops-admins"
        refute log =~ "preferred_username"
        {:ok, doc} = Floki.parse_document(conn.resp_body)
        assert [alert] = Floki.find(doc, "p[role=alert]")
        assert Floki.text(alert) =~ @refused

        for {name, value} <- unquote(Macro.escape(params)) do
          assert [input] = Floki.find(doc, ~s(input[name="#{name}"]))
          assert Floki.attribute(input, "value") == [value], "#{name}: the admin does not retype"
        end
      end
    end

    test "a missing actor is a failed audit: scopes widening refused, refresh mode applied without the row (marker forms need a sub)" do
      stored(%{"matrix_oidc_extra_scopes" => "profile"})
      widening = post("/admin/config/scopes", nil, %{"matrix_oidc_extra_scopes" => "profile groups", "admin_oidc_extra_scopes" => ""}, %{"admin" => true})
      assert flash(widening, :error) =~ @refused
      refute_received {:committed, _}

      stored(%{"matrix_oidc_refresh_mode" => "offline"})
      capture_log(fn -> send(self(), {:c, post("/admin/config/refresh-mode", nil, %{"matrix_oidc_refresh_mode" => "online"}, %{"admin" => true})}) end)
      assert_received {:c, refresh}
      assert flash(refresh, :error) =~ @unaudited
      assert_received {:committed, _}
    end
  end

  describe "AC3 / D2 — SSO origins and schemes: a widening is refused, a subset is applied without its row" do
    test "origins: widening (a new origin) + failing audit: refused, redirect to /admin/config, flash, marker kept, nothing committed" do
      audit_fails()
      stored(%{"sso_redirect_allowed_origins" => "https://a.example"})
      conn = post("/admin/config/sso-origins", @config, %{"sso_redirect_allowed_origins" => "https://a.example, https://new.example"})

      assert conn.status in [302, 303]
      refute_received {:committed, _}
      assert flash(conn, :error) =~ @refused
      assert marker_kept?(conn)
    end

    test "origins: narrowing and clearing with a failing audit are APPLIED (retry without audit), flash says so, marker consumed" do
      audit_fails()
      stored(%{"sso_redirect_allowed_origins" => "https://a.example, https://b.example"})

      for new <- ["https://a.example", "", "https://B.example, https://a.example"] do
        {conn, log} = with_log(fn -> post("/admin/config/sso-origins", @config, %{"sso_redirect_allowed_origins" => new}) end)
        assert conn.status in [302, 303], inspect(new)
        assert_received {:tx, _, true}
        assert_received {:tx, _, false}
        assert_received {:committed, _}
        assert flash(conn, :error) =~ @unaudited, inspect(new)
        refute marker_kept?(conn)
        refute log =~ "a.example"
        refute log =~ "@admin"
      end
    end

    test "schemes: widening refused, subset (case-insensitive, order free) and clearing applied without the row" do
      audit_fails()
      stored(%{"sso_extra_redirect_schemes" => "x-app, Y-App"})

      refused = post("/admin/config/sso-schemes", @config, %{"sso_extra_redirect_schemes" => "x-app, z-app"})
      assert flash(refused, :error) =~ @refused
      refute_received {:committed, _}
      assert marker_kept?(refused)
      flush()

      for new <- ["y-app", "Y-APP, x-app", ""] do
        log = capture_log(fn -> send(self(), {:c, post("/admin/config/sso-schemes", @config, %{"sso_extra_redirect_schemes" => new})}) end)
        assert_received {:c, conn}
        assert flash(conn, :error) =~ @unaudited, inspect(new)
        assert_received {:tx, _, true}
        assert_received {:tx, _, false}
        assert_received {:committed, _}
        refute marker_kept?(conn), "the write happened: the marker is spent"
        refute log =~ "x-app"
        refute log =~ "@admin"
        flush()
      end
    end

    test "an unreadable, missing or non-text stored value counts as the empty set: only the empty value is a subset (origins, schemes, scopes)" do
      audit_fails()

      for reader <- [fn -> {:ok, %{}} end, fn -> {:error, :db_down} end, fn -> {:ok, %{"sso_extra_redirect_schemes" => nil, "sso_redirect_allowed_origins" => 5, "admin_oidc_extra_scopes" => nil}} end] do
        Application.put_env(:nebu_http, :admin_server_config_reader, reader)

        for {path, params} <- [
              {"/admin/config/sso-schemes", %{"sso_extra_redirect_schemes" => "x-app"}},
              {"/admin/config/sso-origins", %{"sso_redirect_allowed_origins" => "https://new.example"}},
              {"/admin/config/scopes", %{"matrix_oidc_extra_scopes" => "", "admin_oidc_extra_scopes" => "groups"}}
            ] do
          refused = post(path, if(String.contains?(path, "scopes"), do: nil, else: @config), params)
          assert flash(refused, :error) =~ @refused, path
          refute_received {:committed, _}
          flush()
        end
      end
    end

    test "scopes are case-sensitive tokens: Groups is not groups (a widening), schemes and origins are compared case-insensitively" do
      audit_fails()
      stored(%{"matrix_oidc_extra_scopes" => "groups", "admin_oidc_extra_scopes" => ""})
      refused = post("/admin/config/scopes", nil, %{"matrix_oidc_extra_scopes" => "Groups", "admin_oidc_extra_scopes" => ""})
      assert flash(refused, :error) =~ @refused
      refute_received {:committed, _}
    end

    test "a narrowing with a WORKING audit is audited, not skipped: one transaction with the audit function, one row" do
      stored(%{"sso_extra_redirect_schemes" => "x-app, y-app"})
      post("/admin/config/sso-schemes", @config, %{"sso_extra_redirect_schemes" => "x-app"})
      assert_received {:tx, _, true}
      refute_received {:tx, _, _}
      assert_received {:audit, "@admin:test.local", "sso_redirect_schemes_changed", _, _, %{"schemes" => "x-app", "count" => 1}, "success", _}
    end
  end

  describe "AC3 / D2 — scopes and refresh mode" do
    test "scopes: a widening (a new scope token) is refused; no marker involved, redirect with the flash, nothing committed" do
      audit_fails()
      stored(%{"matrix_oidc_extra_scopes" => "profile", "admin_oidc_extra_scopes" => ""})
      conn = post("/admin/config/scopes", nil, %{"matrix_oidc_extra_scopes" => "profile groups", "admin_oidc_extra_scopes" => ""})
      assert conn.status in [302, 303]
      assert flash(conn, :error) =~ @refused
      refute_received {:committed, _}
    end

    test "scopes: narrowing, clearing and a reordering are applied without the row (the way out of a scope that breaks the sign-in)" do
      audit_fails()
      stored(%{"matrix_oidc_extra_scopes" => "profile groups", "admin_oidc_extra_scopes" => "email"})

      for {m, a} <- [{"groups", "email"}, {"", ""}, {"groups profile", "email"}] do
        log = capture_log(fn -> send(self(), {:c, post("/admin/config/scopes", nil, %{"matrix_oidc_extra_scopes" => m, "admin_oidc_extra_scopes" => a})}) end)
        assert_received {:c, conn}
        assert flash(conn, :error) =~ @unaudited, inspect({m, a})
        assert_received {:tx, _, true}
        assert_received {:tx, _, false}
        assert_received {:committed, _}
        refute log =~ "profile"
        refute log =~ "groups"
        flush()
      end
    end

    test "scopes: one key narrows and the other widens: refused" do
      audit_fails()
      stored(%{"matrix_oidc_extra_scopes" => "profile groups", "admin_oidc_extra_scopes" => "email"})
      conn = post("/admin/config/scopes", nil, %{"matrix_oidc_extra_scopes" => "profile", "admin_oidc_extra_scopes" => "email offline_access"})
      assert flash(conn, :error) =~ @refused
      refute_received {:committed, _}
    end

    test "refresh mode: online (or unchanged) is applied without its row, offline (offline_access, SEC L-2) is refused" do
      audit_fails()
      stored(%{"matrix_oidc_refresh_mode" => "offline", "admin_oidc_refresh_mode" => "online"})

      for params <- [%{"matrix_oidc_refresh_mode" => "online", "admin_oidc_refresh_mode" => "online"}, %{"matrix_oidc_refresh_mode" => "offline", "admin_oidc_refresh_mode" => "online"}, %{"matrix_oidc_refresh_mode" => "online"}] do
        {conn, log} = with_log(fn -> post("/admin/config/refresh-mode", nil, params) end)
        assert conn.status in [302, 303]
        assert flash(conn, :error) =~ @unaudited
        assert_received {:tx, _, true}
        assert_received {:tx, _, false}
        assert_received {:committed, _}
        assert log =~ ~r/audit/i
        refute log =~ "offline"
        flush()
      end

      widening = post("/admin/config/refresh-mode", nil, %{"matrix_oidc_refresh_mode" => "offline", "admin_oidc_refresh_mode" => "offline"})
      assert flash(widening, :error) =~ @refused
      assert_received {:tx, _, true}
      refute_received {:tx, _, false}
      refute_received {:committed, _}
    end
  end

  describe "AC3 — a refused or unaudited save keeps the old observable behaviour elsewhere" do
    test "a validation error never reaches the transaction (no audit attempt either)" do
      conn = post("/admin/config/sso-schemes", @config, %{"sso_extra_redirect_schemes" => "javascript"})
      assert conn.status == 200
      refute_received {:tx, _, _}
      refute_received {:audit, _, _, _, _, _, _, _}
    end

    test "a database failure of the transaction (not the audit) keeps its own message: 'Failed to save', the marker is kept" do
      Application.put_env(:nebu_http, :admin_config_tx, fn _changes, _audit -> {:error, :db_down} end)
      capture_log(fn -> send(self(), {:c, post("/admin/config/sso-schemes", @config, %{"sso_extra_redirect_schemes" => "x-app"})}) end)
      assert_received {:c, conn}
      assert flash(conn, :error) =~ "Failed to save"
      refute flash(conn, :error) =~ "audit"
      assert marker_kept?(conn)
    end
  end

  # ─── AC5 / D5 — the seams are compile-guarded ────────────────────────────

  describe "AC5 / D5 — the test seams are read only inside `if Mix.env() == :test`" do
    @seams [":admin_config_sso_schemes_writer", ":admin_config_sso_origins_writer", ":admin_config_scopes_writer", ":admin_config_refresh_mode_writer", ":admin_config_role_mapping_writer", ":admin_config_claim_mapping_writer", ":admin_config_tx", ":admin_server_config_reader"]

    for file <- ["config_controller.ex", "claim_mapping_controller.ex", "role_mapping_controller.ex", "oauth_admin_helpers.ex", "db.ex"] do
      test "#{file}: no admin_config_*_writer, admin_config_tx or admin_server_config_reader read outside a test-only block" do
        src = File.read!(Path.expand("../../../lib/nebu/admin/#{unquote(file)}", __DIR__))
        guards = Regex.scan(~r/^  if Mix\.env\(\) == :test do$/m, src) |> length()
        elses = Regex.scan(~r/^  else$/m, src) |> length()
        assert guards == elses, "every test guard has its `else` branch at the module level (the regex below relies on it)"

        guarded = Regex.replace(~r/  if Mix\.env\(\) == :test do.*?\n  else\n/s, src, "")
        code = guarded |> String.replace(~r/@(module)?doc """.*?"""/s, "") |> String.replace(~r/^\s*#.*$/m, "")

        for seam <- @seams do
          refute code =~ seam, "#{unquote(file)} reads #{seam} outside `if Mix.env() == :test`"
        end
      end
    end

    test "the after-the-save audit helper is gone: no controller audits after the write any more" do
      helpers = File.read!(Path.expand("../../../lib/nebu/admin/oauth_admin_helpers.ex", __DIR__))
      refute helpers =~ "def audit_config_change("
      assert helpers =~ "def save_config_audited("

      for file <- ["config_controller.ex", "claim_mapping_controller.ex", "role_mapping_controller.ex"] do
        src = File.read!(Path.expand("../../../lib/nebu/admin/#{file}", __DIR__))
        refute src =~ "audit_config_change(", file
        refute src =~ "audit_sso_origins", file
        assert src =~ "save_config_audited(", file
      end
    end
  end

  defp flush do
    receive do
      _ -> flush()
    after
      0 -> :ok
    end
  end
end
