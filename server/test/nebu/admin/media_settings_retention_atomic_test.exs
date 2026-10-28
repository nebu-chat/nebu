defmodule Nebu.Admin.MediaSettingsRetentionAtomicTest do
  @moduledoc """
  Tests for story `media-retention-audit-atomic`, AC2 (Admin UI part), D5: `POST /admin/media/settings` keeps its one `Nebu.Media.Config.upsert/3`
  call per changed key; a refused shortening (`{:error, {:audit, _}}`) shows the existing value-free failure flash "Failed to save media settings", and the
  keys of the same save that were committed before it stay as they were (the known per-key limitation of the controller, unchanged).

  No database: the transaction of `Nebu.Media.Config` is replaced by the seam `:nebu_http, :media_config_tx` (contract in
  `Nebu.Media.ConfigRetentionAtomicTest`: `fn key, value, audit, guard -> :ok | {:error, term}`, `audit` / `guard` 1-arity functions over the old value or `nil`).
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn
  import ExUnit.CaptureLog

  @endpoint Nebu.Admin.Endpoint
  @secret_key_base String.duplicate("nebu-media-retention-atomic-key", 3)

  defmodule FakeAuditRepo do
    @moduledoc "A working audit table. Test-private."
    def transaction(fun) when is_function(fun, 0), do: {:ok, fun.()}
    def insert(struct, _opts \\ []), do: {:ok, struct}
    def insert!(struct, _opts \\ []), do: struct
  end

  defmodule RecordingAuditRepo do
    @moduledoc "A working audit table that reports every inserted row to the test process. Test-private."
    def transaction(fun) when is_function(fun, 0), do: {:ok, fun.()}

    def insert(struct, _opts \\ []) do
      send(Application.fetch_env!(:compliance, :__retention_actor_test_pid__), {:audit_row, struct})
      {:ok, struct}
    end

    def insert!(struct, opts \\ []) do
      {:ok, s} = insert(struct, opts)
      s
    end
  end

  defmodule FailingAuditRepo do
    @moduledoc "AuditWriter.log/6 answers {:error, :audit_write_failed}. Test-private."

    def transaction(fun) when is_function(fun, 0) do
      fun.()
      {:ok, nil}
    rescue
      _ -> {:error, :simulated_audit_failure}
    end

    def insert(_struct, _opts \\ []), do: {:error, :simulated_audit_failure}
    def insert!(_struct, _opts \\ []), do: raise("simulated audit write failure")
  end

  @baseline %{
    "max_upload_size_bytes" => "52428800",
    "max_file_size_bytes" => "104857600",
    "max_pending_per_user" => "20",
    "max_stall_ms" => "20000",
    "deleted_days" => "30",
    "infected_days" => "7",
    "orphaned_hours" => "24",
    "webhook_url" => "",
    "released_delete_after_days" => ""
  }

  setup do
    {:ok, store} = Agent.start_link(fn -> %{"deleted_days" => 30, "infected_days" => 7, "released_delete_after_days" => nil} end)
    test_pid = self()

    Application.put_env(:nebu_http, :admin_csrf_bypass, true)
    Application.put_env(:compliance, :repo, FakeAuditRepo)
    Application.put_env(:nebu_http, :media_config_source, fn -> %{} end)

    # a fake of the transaction (it cannot roll back: it commits only when the audit and the guard pass)
    Application.put_env(:nebu_http, :media_config_tx, fn key, value, audit, guard ->
      send(test_pid, {:tx, key, value, audit != nil, guard != nil})
      old = Agent.get(store, &Map.fetch!(&1, key))

      cond do
        is_function(guard, 1) and guard.(old) != true ->
          {:error, {:audit, :not_lengthening}}

        is_function(audit, 1) ->
          case audit.(old) do
            :ok ->
              Agent.update(store, &Map.put(&1, key, value))
              :ok

            {:error, reason} ->
              {:error, {:audit, reason}}
          end

        true ->
          Agent.update(store, &Map.put(&1, key, value))
          :ok
      end
    end)

    on_exit(fn ->
      Application.delete_env(:nebu_http, :admin_csrf_bypass)
      Application.delete_env(:compliance, :repo)
      for k <- [:media_config_source, :media_config_tx, :media_config_loader, :media_config_writer], do: Application.delete_env(:nebu_http, k)
    end)

    {:ok, store: store}
  end

  defp admin_conn(method, path) do
    %{conn(method, path) | secret_key_base: @secret_key_base}
    |> @endpoint.admin_session([])
    |> fetch_session()
    |> put_session("current_user", %{"admin" => true, "sub" => "admin-media-retention-1", "matrix_user_id" => "@admin:test.local"})
    |> Nebu.OAuth.TestSupport.put_strict_fetch_headers()
    |> put_session("admin_reauth", Nebu.OAuth.TestSupport.fresh_marker("admin-media-retention-1", 0, "auth_time", "/admin/media/settings"))
  end

  defp post_settings(overrides) do
    admin_conn(:post, "/admin/media/settings")
    |> Map.put(:body_params, Map.merge(@baseline, overrides))
    |> then(&@endpoint.call(&1, @endpoint.init([])))
  end

  # the failing audit paths log ERRORs: captured, the conn is handed back
  defp post_quiet(overrides) do
    me = self()
    capture_log(fn -> send(me, {:conn, post_settings(overrides)}) end)

    receive do
      {:conn, conn} -> conn
    end
  end

  defp flash_get(conn, kind) do
    flash = conn.assigns[:flash] || get_session(conn, "phoenix_flash") || get_session(conn, "_flash") || %{}
    Phoenix.Flash.get(flash, kind)
  end

  defp drain_tx(acc \\ []) do
    receive do
      {:tx, key, value, audit?, guard?} -> drain_tx([{key, value, audit?, guard?} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "AC2 / D5 Admin UI (no database, seam :media_config_tx)" do
    test "a shortening whose audit row cannot be written shows the failure flash and persists nothing", %{store: store} do
      Application.put_env(:compliance, :repo, FailingAuditRepo)

      conn = post_quiet(%{"deleted_days" => "7"})

      assert_received {:tx, "deleted_days", 7, true, false}, "the save reached the transaction of Nebu.Media.Config.upsert/3"
      assert conn.status == 200, "the form is re-rendered, not redirected"
      assert flash_get(conn, :error) == "Failed to save media settings"
      assert is_nil(flash_get(conn, :info))
      assert Agent.get(store, & &1["deleted_days"]) == 30, "nothing was persisted"
    end

    test "the failure flash is value-free: neither a reason nor the audit writer text reaches the page", %{store: store} do
      Application.put_env(:compliance, :repo, FailingAuditRepo)

      # 7 (the catalogue default) -> 3 is a SHORTENING: refused with the failing audit, no retry without it
      conn = post_quiet(%{"infected_days" => "3"})

      assert_received {:tx, "infected_days", 3, true, false}
      assert Agent.get(store, & &1["infected_days"]) == 7, "the refused shortening is not persisted (the retry without the audit re-checks the direction under the guard)"
      assert conn.status == 200
      assert flash_get(conn, :error) == "Failed to save media settings"
      refute String.downcase(to_string(flash_get(conn, :error))) =~ "audit"
      refute conn.resp_body =~ "audit_write_failed"
    end

    test "a lengthening with a failing audit is saved: the success flash (the way to MORE retention stays open)", %{store: store} do
      Application.put_env(:compliance, :repo, FailingAuditRepo)

      conn = post_quiet(%{"deleted_days" => "60"})

      assert [{"deleted_days", 60, true, false}, {"deleted_days", 60, false, true}] = drain_tx()
      assert conn.status in [302, 303]
      assert flash_get(conn, :info) =~ ~r/media settings saved/i
      assert Agent.get(store, & &1["deleted_days"]) == 60
    end

    test "the earlier keys of the same save stay committed when a later shortening is refused (known per-key limitation of the controller, unchanged)", %{store: store} do
      Application.put_env(:compliance, :repo, FailingAuditRepo)

      # the controller walks the changed keys in key order: deleted_days (a lengthening, applied without its row) before infected_days (a shortening, refused)
      conn = post_quiet(%{"deleted_days" => "60", "infected_days" => "3"})

      assert conn.status == 200
      assert flash_get(conn, :error) == "Failed to save media settings"
      assert Agent.get(store, & &1["deleted_days"]) == 60, "committed before the refused key"
      assert Agent.get(store, & &1["infected_days"]) == 7, "the refused shortening is not persisted"
    end

    test "an empty `sub` is no actor: the audit row falls back to the system actor", %{store: store} do
      Application.put_env(:compliance, :repo, RecordingAuditRepo)
      Application.put_env(:compliance, :__retention_actor_test_pid__, self())
      on_exit(fn -> Application.delete_env(:compliance, :__retention_actor_test_pid__) end)

      # the gate itself refuses an empty `sub`, so this calls the action directly with a gate-valid session and a `current_user` assign without any identity
      conn =
        admin_conn(:post, "/admin/media/settings")
        |> Map.put(:body_params, Map.merge(@baseline, %{"deleted_days" => "7"}))
        |> Map.put(:params, Map.merge(@baseline, %{"deleted_days" => "7"}))
        |> Phoenix.Controller.fetch_flash()
        |> Plug.Conn.assign(:current_user, %{"admin" => true, "sub" => "", "matrix_user_id" => ""})
        |> Nebu.Admin.MediaSettingsController.save(Map.merge(@baseline, %{"deleted_days" => "7"}))

      assert conn.status in [302, 303], "the save went through (status #{conn.status}, #{inspect(Plug.Conn.get_resp_header(conn, "location"))})"
      assert Agent.get(store, & &1["deleted_days"]) == 7
      assert_received {:audit_row, row}
      assert row.actor_user_id == "system:media_config"
    end

    test "a working audit table: a shortening is saved and audited, the success flash", %{store: store} do
      conn = post_settings(%{"deleted_days" => "7"})

      assert_received {:tx, "deleted_days", 7, true, false}
      refute_received {:tx, _, _, _, _}
      assert conn.status in [302, 303]
      assert flash_get(conn, :info) =~ ~r/media settings saved/i
      assert Agent.get(store, & &1["deleted_days"]) == 7
    end
  end
end
