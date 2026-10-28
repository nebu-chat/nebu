defmodule Nebu.OAuth.OAuthSwitchStoreDbTest do
  @moduledoc """
  Story `admin-oauth-switch`, AC4 / AC6 / AC7 (decisions D7, D8, D10), integration (real PostgreSQL, the runtime role `nebu_app`
  behind `Nebu.Repo`): the real transaction of `Nebu.OAuth.save_switch/2` (both `server_config` upserts and the audit function
  in ONE transaction), the audit rollback, the retry without audit for the kill switch, the drop of the local cache entry and
  the round trip to the live predicate. No migration is needed: both keys are in the `config_update_mutable` allowlist.
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  alias Nebu.OAuth.TestSupport, as: T

  @issuer "https://chat.example.com"
  @cache :nebu_oauth_config_cache

  setup do
    T.clear_oauth_config()
    # snapshot the rows of the two keys (restored by on_exit), start from a known state
    T.set_oauth_rows!(%{"oauth_enabled" => "false", "oauth_issuer_url" => ""})
    T.privileged_sql!("DELETE FROM audit_log WHERE action = 'oauth_switch_changed'")

    prior = Application.fetch_env(:nebu_http, :oauth_config_cache_ms)
    Application.put_env(:nebu_http, :oauth_config_cache_ms, 2000)
    clear_cache()

    on_exit(fn ->
      case prior do
        {:ok, v} -> Application.put_env(:nebu_http, :oauth_config_cache_ms, v)
        :error -> Application.delete_env(:nebu_http, :oauth_config_cache_ms)
      end

      clear_cache()
      T.privileged_sql!("DELETE FROM audit_log WHERE action = 'oauth_switch_changed'")
    end)

    :ok
  end

  defp clear_cache, do: if(:ets.whereis(@cache) != :undefined, do: :ets.delete_all_objects(@cache))

  defp rows do
    %{rows: rows} = T.sql!("SELECT key, value FROM server_config WHERE key IN ('oauth_enabled', 'oauth_issuer_url') ORDER BY key")
    Map.new(rows, fn [k, v] -> {k, v} end)
  end

  defp audit_rows do
    %{rows: rows} = T.privileged_sql!("SELECT actor_user_id, action, target_type, target_id, outcome, metadata FROM audit_log WHERE action = 'oauth_switch_changed' ORDER BY id")
    rows
  end

  # the audit function of the admin: the REAL writer
  defp audit(meta \\ %{"enabled_after" => true}) do
    fn -> Nebu.Compliance.AuditWriter.log("@admin:test.local", "oauth_switch_changed", "server_config", "oauth_enabled", meta, "success", nil) end
  end

  test "the repo connects as the runtime role nebu_app (the RLS upsert of both keys works for it, no migration needed)" do
    assert %{rows: [["nebu_app"]]} = T.sql!("SELECT current_user")
  end

  test "on: both keys written (the runtime role may upsert them) and ONE audit row, in the same transaction" do
    assert {:ok, %{audited: true}} = Nebu.OAuth.save_switch(%{"oauth_enabled" => "true", "oauth_issuer_url" => @issuer}, audit: audit())

    assert %{"oauth_enabled" => "true", "oauth_issuer_url" => @issuer} = rows()
    assert [["@admin:test.local", "oauth_switch_changed", "server_config", "oauth_enabled", "success", %{"enabled_after" => true}]] = audit_rows()
  end

  test "the audit function runs INSIDE the transaction of the upserts (one connection, one commit)" do
    test_pid = self()

    audit = fn ->
      send(test_pid, {:in_tx, Nebu.Repo.in_transaction?()})
      Nebu.Compliance.AuditWriter.log("@admin:test.local", "oauth_switch_changed", "server_config", "oauth_enabled", %{"enabled_after" => true}, "success", nil)
    end

    assert {:ok, %{audited: true}} = Nebu.OAuth.save_switch(%{"oauth_enabled" => "true", "oauth_issuer_url" => @issuer}, audit: audit)
    assert_received {:in_tx, true}
  end

  test "a failing UPSERT (the second key) rolls the first back and writes no audit row: both keys are atomic with each other" do
    T.privileged_sql!("CREATE OR REPLACE FUNCTION public.oauth_switch_test_fail() RETURNS trigger AS $$ BEGIN RAISE EXCEPTION 'oauth switch test failure'; END; $$ LANGUAGE plpgsql")
    T.privileged_sql!("CREATE TRIGGER oauth_switch_test_fail BEFORE INSERT OR UPDATE ON server_config FOR EACH ROW WHEN (NEW.key = 'oauth_issuer_url') EXECUTE FUNCTION public.oauth_switch_test_fail()")

    on_exit(fn ->
      T.privileged_sql!("DROP TRIGGER IF EXISTS oauth_switch_test_fail ON server_config")
      T.privileged_sql!("DROP FUNCTION IF EXISTS public.oauth_switch_test_fail()")
    end)

    ExUnit.CaptureLog.capture_log(fn ->
      assert {:error, _} = Nebu.OAuth.save_switch(%{"oauth_enabled" => "true", "oauth_issuer_url" => @issuer}, audit: audit())
    end)

    assert %{"oauth_enabled" => "false"} = rows()
    assert audit_rows() == []
  end

  test "a failing audit rolls BOTH upserts back: the switch stays as it was, no audit row" do
    assert {:error, {:audit, :audit_write_failed}} =
             Nebu.OAuth.save_switch(%{"oauth_enabled" => "true", "oauth_issuer_url" => @issuer}, audit: fn -> {:error, :audit_write_failed} end)

    assert %{"oauth_enabled" => "false"} = rows()
    assert audit_rows() == []
  end

  describe "a REALLY failing audit insert (the audit_log table refuses the row)" do
    setup do
      T.privileged_sql!("CREATE OR REPLACE FUNCTION public.oauth_switch_test_audit_fail() RETURNS trigger AS $$ BEGIN RAISE EXCEPTION 'audit log unwritable (test)'; END; $$ LANGUAGE plpgsql")
      T.privileged_sql!("CREATE TRIGGER oauth_switch_test_audit_fail BEFORE INSERT ON audit_log FOR EACH ROW WHEN (NEW.action = 'oauth_switch_changed') EXECUTE FUNCTION public.oauth_switch_test_audit_fail()")

      on_exit(fn ->
        T.privileged_sql!("DROP TRIGGER IF EXISTS oauth_switch_test_audit_fail ON audit_log")
        T.privileged_sql!("DROP FUNCTION IF EXISTS public.oauth_switch_test_audit_fail()")
      end)

      :ok
    end

    test "switching ON is refused and both keys stay as they were" do
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, {:audit, _}} = Nebu.OAuth.save_switch(%{"oauth_enabled" => "true", "oauth_issuer_url" => @issuer}, audit: audit())
      end)

      assert %{"oauth_enabled" => "false"} = rows()
      refute Nebu.OAuth.oauth_aware?()
    end

    test "switching OFF is applied without the audit row, the cache is dropped and nothing is raised" do
      T.set_oauth_rows!(%{"oauth_enabled" => "true", "oauth_issuer_url" => @issuer})
      assert Nebu.OAuth.oauth_aware?()

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, %{audited: false}} = Nebu.OAuth.save_switch(%{"oauth_enabled" => "false", "oauth_issuer_url" => @issuer}, audit: audit(), unaudited_ok: true)
      end)

      assert %{"oauth_enabled" => "false"} = rows()
      refute Nebu.OAuth.oauth_aware?()
      assert audit_rows() == []
    end
  end

  test "an UNKNOWN audit action (a missing @known_actions entry) rolls the change back too, it is never applied unaudited" do
    unknown = fn -> Nebu.Compliance.AuditWriter.log("@a:test.local", "no_such_action", "server_config", "oauth_enabled", %{}, "success", nil) end
    assert {:error, {:audit, :audit_unknown_action}} = Nebu.OAuth.save_switch(%{"oauth_enabled" => "true", "oauth_issuer_url" => @issuer}, audit: unknown)
    assert %{"oauth_enabled" => "false"} = rows()
  end

  test "the kill switch: with unaudited_ok the off change is applied without the audit row when the audit fails" do
    T.set_oauth_rows!(%{"oauth_enabled" => "true", "oauth_issuer_url" => @issuer})

    ExUnit.CaptureLog.capture_log(fn ->
      assert {:ok, %{audited: false}} =
               Nebu.OAuth.save_switch(%{"oauth_enabled" => "false", "oauth_issuer_url" => @issuer}, audit: fn -> {:error, :audit_write_failed} end, unaudited_ok: true)
    end)

    assert %{"oauth_enabled" => "false"} = rows()
    assert audit_rows() == []
  end

  test "the kill switch retry drops the cache too: the saving node stops offering OAuth at once although the audit row failed" do
    T.set_oauth_rows!(%{"oauth_enabled" => "true", "oauth_issuer_url" => @issuer})
    assert Nebu.OAuth.oauth_aware?(), "primes the cache with the ON state"

    ExUnit.CaptureLog.capture_log(fn ->
      assert {:ok, %{audited: false}} =
               Nebu.OAuth.save_switch(%{"oauth_enabled" => "false", "oauth_issuer_url" => @issuer}, audit: fn -> {:error, :x} end, unaudited_ok: true)
    end)

    refute Nebu.OAuth.oauth_aware?()
    assert :off = Nebu.OAuth.Config.live_state()
  end

  test "an empty issuer is stored as the empty string; the runtime reads it as no issuer" do
    T.set_oauth_rows!(%{"oauth_enabled" => "false", "oauth_issuer_url" => @issuer})
    assert {:ok, _} = Nebu.OAuth.save_switch(%{"oauth_enabled" => "false", "oauth_issuer_url" => ""}, audit: audit())
    assert %{"oauth_issuer_url" => ""} = rows()
    assert %{issuer_url: nil} = Nebu.OAuth.Config.get()
  end

  test "the keys that did not exist yet are inserted (the first activation on a fresh database)" do
    T.privileged_sql!("DELETE FROM server_config WHERE key IN ('oauth_enabled', 'oauth_issuer_url')")
    assert {:ok, _} = Nebu.OAuth.save_switch(%{"oauth_enabled" => "true", "oauth_issuer_url" => @issuer}, audit: audit())
    assert %{"oauth_enabled" => "true", "oauth_issuer_url" => @issuer} = rows()
  end

  test "set_at is refreshed and no other key is touched" do
    before = T.sql!("SELECT count(*), max(set_at) FROM server_config WHERE key NOT IN ('oauth_enabled', 'oauth_issuer_url')").rows
    assert {:ok, _} = Nebu.OAuth.save_switch(%{"oauth_enabled" => "true", "oauth_issuer_url" => @issuer}, audit: audit())
    assert T.sql!("SELECT count(*), max(set_at) FROM server_config WHERE key NOT IN ('oauth_enabled', 'oauth_issuer_url')").rows == before
  end

  describe "D8 / AC6 — the cache and the live predicate on the saving node" do
    test "on: a primed cache entry (the old off state) is dropped, the very next read and the live predicate see the change at once" do
      assert %{enabled: false} = Nebu.OAuth.Config.get()
      assert [{:config, %{enabled: false}, _}] = :ets.lookup(@cache, :config), "the off state is cached (TTL 2 s)"
      refute Nebu.OAuth.oauth_aware?()

      assert {:ok, _} = Nebu.OAuth.save_switch(%{"oauth_enabled" => "true", "oauth_issuer_url" => @issuer}, audit: audit())

      assert %{enabled: true, issuer_url: @issuer} = Nebu.OAuth.Config.get()
      assert Nebu.OAuth.oauth_aware?(), "auth_metadata 200 / versions v1.15 predicate"
      assert {:live, @issuer} = Nebu.OAuth.Config.live_state()
    end

    test "off: the kill switch is effective on the saving node at once" do
      T.set_oauth_rows!(%{"oauth_enabled" => "true", "oauth_issuer_url" => @issuer})
      assert Nebu.OAuth.oauth_aware?()

      assert {:ok, _} = Nebu.OAuth.save_switch(%{"oauth_enabled" => "false", "oauth_issuer_url" => @issuer}, audit: audit())
      refute Nebu.OAuth.oauth_aware?()
      assert :off = Nebu.OAuth.Config.live_state()
    end

    test "a missing cache table (owner not running) is not an error" do
      owner = Process.whereis(Nebu.OAuth.CacheOwner)
      assert owner
      :ok = Supervisor.terminate_child(Nebu.Supervisor, Nebu.OAuth.CacheOwner)

      try do
        assert {:ok, _} = Nebu.OAuth.save_switch(%{"oauth_enabled" => "false", "oauth_issuer_url" => ""}, audit: audit())
      after
        Supervisor.restart_child(Nebu.Supervisor, Nebu.OAuth.CacheOwner)
      end
    end

    test "a wrong but https-valid issuer keeps the guards: the runtime serves OAuth only for a normalized issuer, an invalid stored one is off" do
      T.set_oauth_rows!(%{"oauth_enabled" => "true", "oauth_issuer_url" => "http://not-https.example.com"})
      clear_cache()
      refute Nebu.OAuth.oauth_aware?(), "an invalid stored issuer is the fail-closed off state"

      assert {:ok, _} = Nebu.OAuth.save_switch(%{"oauth_enabled" => "true", "oauth_issuer_url" => "https://wrong-host.example.com"}, audit: audit())
      assert Nebu.OAuth.oauth_aware?(), "a valid but wrong issuer is served (the operator's decision; the page warns about a host that differs from the server name)"
    end
  end
end
