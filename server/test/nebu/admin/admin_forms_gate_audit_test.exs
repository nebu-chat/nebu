defmodule Nebu.Admin.AdminFormsGateAuditTest do
  @moduledoc """
  Story `admin-forms-gate-sweep` (follow-up `de`), AC5 / AC6 (decisions D5, D6): the two audit changes of the sweep.

    * L1, the log retention save (`POST /admin/logs/config/retention`): value and audit row in ONE transaction
      (`OAuthAdminHelpers.save_config_audited/3`), action `log_settings_changed` (`@known_actions`), target `log_settings`; when the audit row cannot be written the save is
      REFUSED, except a pure "collection off" change (every changed key is a `log_collect_*` key set to `false`: less collection, the way back).
    * R2, the room auto-join toggle (`POST /admin/rooms/:id/auto-join`): the default path calls the audited `Nebu.Matrix.set_room_auto_join/3` (row `room_auto_join_changed`),
      no raw SQL in the controller.

  Part 1 uses the seams (`:admin_config_tx`, the audit writer module), part 2 is integration (real PostgreSQL, the real `Nebu.Compliance.AuditWriter`).
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn
  import ExUnit.CaptureLog

  alias Nebu.OAuth.TestSupport, as: T

  @endpoint Nebu.Admin.Endpoint
  @secret_key_base String.duplicate("nebu-forms-gate-audit-key-base", 3)
  @path "/admin/logs/config/retention"

  defmodule CaptureAudit do
    @moduledoc false
    def log(actor, action, target_type, target_id, metadata, outcome, error_detail \\ nil) do
      send(Application.get_env(:nebu_http, :forms_gate_audit_sink), {:audit, actor, action, target_type, target_id, metadata, outcome, error_detail})
      Application.get_env(:nebu_http, :forms_gate_audit_result, :ok)
    end
  end

  defp admin_conn(method, path, params) do
    %{conn(method, path) | secret_key_base: @secret_key_base}
    |> @endpoint.admin_session([])
    |> fetch_session()
    |> put_session("current_user", %{"admin" => true, "sub" => "admin-1", "matrix_user_id" => "@admin:test.local"})
    |> Map.put(:body_params, params)
    |> Map.put(:params, params)
    |> T.put_strict_fetch_headers()
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

  describe "L1 — log retention: one transaction with a log_settings_changed row (unit, seams)" do
    setup do
      test_pid = self()
      Application.put_env(:nebu_http, :admin_csrf_bypass, true)
      T.put_env_scoped(:forms_gate_audit_sink, self())
      T.put_env_scoped(:forms_gate_audit_result, :ok)
      T.put_env_scoped(:audit_writer, CaptureAudit, :compliance)

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

      on_exit(fn -> for k <- [:admin_csrf_bypass, :admin_config_tx], do: Application.delete_env(:nebu_http, k) end)
      :ok
    end

    test "saved: ONE transaction with the audit function, committed, one row (actor, action, target, the new values), the success flash" do
      conn = admin_conn(:post, @path, %{"info_enabled" => "true", "info_days" => "14", "info_max_entries" => "500", "debug_enabled" => "false"}) |> call()

      assert conn.status in [302, 303]
      assert flash(conn, :info) == "Logging settings saved"
      assert_received {:tx, changes, true}
      assert changes["log_collect_info"] == "true"
      assert changes["log_retention_info_days"] == "14"
      assert changes["log_collect_debug"] == "false"
      assert_received {:committed, ^changes}
      refute_received {:tx, _, _}
      assert_received {:audit, "@admin:test.local", "log_settings_changed", "server_config", "log_settings", metadata, "success", _}
      assert metadata["log_collect_info"] == "true"
      refute_received {:audit, _, _, _, _, _, _, _}
    end

    test "a failing audit REFUSES enabling a level and changing a retention window: nothing committed, the refusal flash, redirect back" do
      Application.put_env(:nebu_http, :forms_gate_audit_result, {:error, :audit_write_failed})

      for params <- [%{"info_enabled" => "true", "info_days" => "14", "info_max_entries" => "7351", "debug_enabled" => "false"}, %{"debug_enabled" => "true", "debug_days" => "1", "info_enabled" => "false"}] do
        {conn, log} = with_log(fn -> admin_conn(:post, @path, params) |> call() end)
        assert conn.status in [302, 303]
        assert flash(conn, :error) =~ "not saved: the audit entry could not be written"
        assert get_resp_header(conn, "location") == ["/admin/logs/config"]
        assert_received {:tx, _, true}
        refute_received {:tx, _, false}
        refute_received {:committed, _}
        refute log =~ "log_retention_info_days"
        refute log =~ "7351"
      end
    end

    test "a failing audit lets a pure 'collection off' change through (the way back): applied without the row, the flash says so" do
      Application.put_env(:nebu_http, :forms_gate_audit_result, {:error, :audit_write_failed})

      {conn, log} = with_log(fn -> admin_conn(:post, @path, %{"info_enabled" => "false", "debug_enabled" => "false"}) |> call() end)

      assert conn.status in [302, 303]
      assert flash(conn, :error) =~ "saved, but the audit entry could not be written"
      assert_received {:tx, _, true}
      assert_received {:tx, _, false}
      assert_received {:committed, %{"log_collect_info" => "false", "log_collect_debug" => "false"}}
      assert log =~ ~r/audit/i
    end

    test "a validation error never reaches the transaction (no audit attempt either)" do
      conn = admin_conn(:post, @path, %{"info_enabled" => "true", "info_days" => "999"}) |> call()
      assert conn.status == 200
      refute_received {:tx, _, _}
      refute_received {:audit, _, _, _, _, _, _, _}
    end
  end

  describe "static" do
    test "log_settings_changed is a known audit action (without it the real writer answers :audit_unknown_action and the transaction rolls back)" do
      src = File.read!(Path.expand("../../../lib/nebu/compliance/audit_writer.ex", __DIR__))
      assert src =~ ~r/@known_actions ~w\([^)]*\blog_settings_changed\b/s
    end

    test "the logs controller saves through save_config_audited and keeps no unguarded writer seam; the rooms controller has no raw auto-join SQL" do
      logs = File.read!(Path.expand("../../../lib/nebu/admin/logs_controller.ex", __DIR__))
      assert logs =~ "save_config_audited("
      guarded = Regex.replace(~r/  if Mix\.env\(\) == :test do.*?\n  else\n/s, logs, "")
      refute guarded |> String.replace(~r/^\s*#.*$/m, "") =~ ":admin_logs_retention_writer"

      rooms = File.read!(Path.expand("../../../lib/nebu/admin/rooms_controller.ex", __DIR__))
      assert rooms =~ "Nebu.Matrix.set_room_auto_join("
      refute rooms =~ "UPDATE rooms SET is_auto_join"
    end
  end

  describe "integration — the real database and the real AuditWriter" do
    @describetag :integration

    @keys ~w(log_collect_info log_collect_debug log_retention_info_days log_retention_info_max_count log_retention_debug_days log_retention_debug_max_count)

    setup do
      for k <- [:admin_config_tx, :admin_logs_retention_writer, :admin_auto_join_writer], do: Application.delete_env(:nebu_http, k)
      T.put_env_scoped(:audit_writer, Nebu.Compliance.AuditWriter, :compliance)
      Application.put_env(:nebu_http, :admin_csrf_bypass, true)

      prior = T.privileged_sql!("SELECT key, value, set_at FROM server_config WHERE key = ANY($1)", [@keys]).rows
      T.privileged_sql!("DELETE FROM server_config WHERE key = ANY($1)", [@keys])
      T.privileged_sql!("INSERT INTO server_config (key, value, set_at) VALUES ('log_collect_info', 'false', 1), ('log_collect_debug', 'true', 1)")
      T.privileged_sql!("DELETE FROM audit_log WHERE action IN ('log_settings_changed', 'room_auto_join_changed')")
      room_id = "!#{Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)}_aj:test.local"
      T.privileged_sql!("INSERT INTO rooms (room_id, visibility, created_at, status, is_auto_join) VALUES ($1, 'private', $2, 'active', false)", [room_id, System.system_time(:millisecond)])

      on_exit(fn ->
        Application.delete_env(:nebu_http, :admin_csrf_bypass)
        T.privileged_sql!("DELETE FROM server_config WHERE key = ANY($1)", [@keys])
        for [k, v, at] <- prior, do: T.privileged_sql!("INSERT INTO server_config (key, value, set_at) VALUES ($1, $2, $3)", [k, v, at])
        T.privileged_sql!("DELETE FROM audit_log WHERE action IN ('log_settings_changed', 'room_auto_join_changed')")
        T.privileged_sql!("DELETE FROM rooms WHERE room_id = $1", [room_id])
        Nebu.Web.LogStore.refresh_policy_cache()
      end)

      {:ok, room_id: room_id}
    end

    defp value_of(key), do: T.sql!("SELECT value FROM server_config WHERE key = $1", [key]).rows |> List.first() |> List.wrap() |> List.first()
    defp audit_rows(action), do: T.privileged_sql!("SELECT actor_user_id, target_type, outcome FROM audit_log WHERE action = $1", [action]).rows

    test "L1: the real writer writes the log_settings_changed row together with the value" do
      conn = admin_conn(:post, @path, %{"info_enabled" => "true", "info_days" => "14", "info_max_entries" => "500", "debug_enabled" => "true", "debug_days" => "", "debug_max_entries" => ""}) |> call()
      assert conn.status in [302, 303]
      assert value_of("log_collect_info") == "true"
      assert value_of("log_retention_info_days") == "14"
      assert [["@admin:test.local", "server_config", "success"]] = audit_rows("log_settings_changed")
    end

    test "L1: a failing audit writer leaves the old values when a retention window is shortened, and lets a pure collection-off change through" do
      defmodule FailingAudit do
        @moduledoc false
        def log(_a, _b, _c, _d, _e, _f, _g \\ nil), do: {:error, :audit_write_failed}
      end

      T.put_env_scoped(:audit_writer, FailingAudit, :compliance)

      capture_log(fn -> send(self(), {:c, admin_conn(:post, @path, %{"info_enabled" => "true", "info_days" => "1", "info_max_entries" => "", "debug_enabled" => "true", "debug_days" => "", "debug_max_entries" => ""}) |> call()}) end)
      assert_received {:c, refused}
      assert refused.status in [302, 303]
      assert value_of("log_collect_info") == "false", "refused: nothing changed"

      capture_log(fn -> send(self(), {:d, admin_conn(:post, @path, %{"info_enabled" => "false", "debug_enabled" => "false"}) |> call()}) end)
      assert_received {:d, off}
      assert off.status in [302, 303]
      assert value_of("log_collect_debug") == "false", "collection off is the way back: applied without its row"
      assert audit_rows("log_settings_changed") == []
    end

    test "L1: a SHORTER retention window alone (no level turned on) is refused with a failing audit; the realistic way back (debug off, info unchanged) is applied" do
      defmodule FailingAudit2 do
        @moduledoc false
        def log(_a, _b, _c, _d, _e, _f, _g \\ nil), do: {:error, :audit_write_failed}
      end

      T.privileged_sql!("DELETE FROM server_config WHERE key = ANY($1)", [@keys])
      T.privileged_sql!("INSERT INTO server_config (key, value, set_at) VALUES ('log_collect_info', 'true', 1), ('log_retention_info_days', '30', 1), ('log_retention_info_max_count', '', 1), ('log_collect_debug', 'true', 1), ('log_retention_debug_days', '', 1), ('log_retention_debug_max_count', '', 1)")
      T.put_env_scoped(:audit_writer, FailingAudit2, :compliance)
      same = %{"info_enabled" => "true", "info_days" => "30", "info_max_entries" => "", "debug_enabled" => "true", "debug_days" => "", "debug_max_entries" => ""}

      capture_log(fn -> send(self(), {:short, admin_conn(:post, @path, %{same | "info_days" => "14"} |> Map.put("info_days", "14")) |> call()}) end)
      assert_received {:short, shortened}
      assert shortened.status in [302, 303]
      assert value_of("log_retention_info_days") == "30", "refused: a shorter window deletes rows, it needs its audit row"

      capture_log(fn -> send(self(), {:off, admin_conn(:post, @path, %{"info_enabled" => "true", "info_days" => "30", "info_max_entries" => "", "debug_enabled" => "false"}) |> call()}) end)
      assert_received {:off, off}
      assert off.status in [302, 303]
      assert value_of("log_collect_debug") == "false", "debug off with info unchanged is the way back"
      assert value_of("log_retention_info_days") == "30"
      assert audit_rows("log_settings_changed") == []
    end

    test "R2: the default path of the room toggle flips is_auto_join and writes ONE room_auto_join_changed row through the audited Matrix function", %{room_id: room_id} do
      path = "/admin/rooms/" <> URI.encode(room_id, &URI.char_unreserved?(&1)) <> "/auto-join"
      conn = admin_conn(:post, path, %{}) |> call()
      assert conn.status in [302, 303]
      assert [[true]] = T.sql!("SELECT is_auto_join FROM rooms WHERE room_id = $1", [room_id]).rows
      assert [["@admin:test.local", "room", "success"]] = audit_rows("room_auto_join_changed")
    end
  end
end
