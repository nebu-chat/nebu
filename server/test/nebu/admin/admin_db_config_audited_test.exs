defmodule Nebu.Admin.AdminDbConfigAuditedTest do
  @moduledoc """
  Story `admin-config-audit-atomic` (follow-up `dh`), AC1 / AC5 / AC8 (decisions D1, D2, D5): `Nebu.Admin.DB.save_config_audited/2`, the
  admin counterpart of `Nebu.OAuth.save_switch/2`: the upserts of `changes` and the audit function in ONE transaction.

  Part 1 (no database): the orchestration around the transaction function, which the test seam `:nebu_http, :admin_config_tx` (2-arity
  `fn changes, audit -> :ok | {:error, term}`, `audit` a 0-arity function or `nil`) replaces. Part 2 (integration, real PostgreSQL, the runtime role
  `nebu_app`): the real transaction, the rollback, the nested audit writer.

  Contract: `save_config_audited(changes, opts)`, `changes = %{String.t() => String.t()}`, options `:audit` (0-arity, `:ok | {:error, reason}`; a raise
  counts as failed) and `:unaudited_ok` (boolean, default false). `{:ok, %{audited: true}}`, `{:error, {:audit, reason}}` (nothing persisted),
  `{:ok, %{audited: false}}` after ONE retry without the audit function (only with `unaudited_ok: true`, one value-free ERROR log),
  `{:error, :audit_required}` (no audit function), `{:error, :invalid_changes}` (empty, a non-string key or value), `{:error, reason}`.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Nebu.Admin.DB
  alias Nebu.OAuth.TestSupport, as: T

  @changes %{"sso_extra_redirect_schemes" => "x-app, y-app"}

  describe "orchestration (no database)" do
    setup do
      test_pid = self()

      Application.put_env(:nebu_http, :admin_config_tx, fn changes, audit ->
        send(test_pid, {:tx, changes, audit != nil})

        case audit && audit.() do
          nil -> :ok
          :ok -> :ok
          {:error, reason} -> {:error, {:audit, reason}}
        end
      end)

      on_exit(fn -> Application.delete_env(:nebu_http, :admin_config_tx) end)
      :ok
    end

    test "the audit function succeeds: one transaction, audited: true" do
      assert {:ok, %{audited: true}} = DB.save_config_audited(@changes, audit: fn -> :ok end)
      assert_received {:tx, @changes, true}
      refute_received {:tx, _, _}
    end

    test "no audit function is refused: an unaudited change is never silently accepted" do
      assert {:error, :audit_required} = DB.save_config_audited(@changes, [])
      assert {:error, :audit_required} = DB.save_config_audited(@changes, audit: :nope)
      refute_received {:tx, _, _}
    end

    test "the audit function fails: {:error, {:audit, reason}}, ONE attempt, no retry without audit" do
      assert {:error, {:audit, :boom}} = DB.save_config_audited(@changes, audit: fn -> {:error, :boom} end)
      assert_received {:tx, _, true}
      refute_received {:tx, _, _}
    end

    test "a raising audit function and a non-ok answer count as failed (the caller never sees the exception)" do
      assert {:error, {:audit, _}} = DB.save_config_audited(@changes, audit: fn -> raise "audit boom" end)
      assert {:error, {:audit, _}} = DB.save_config_audited(@changes, audit: fn -> :surprise end)
    end

    test "unaudited_ok: the retry runs WITHOUT the audit function, audited: false, one value-free ERROR log" do
      log =
        capture_log([level: :error], fn ->
          send(self(), {:result, DB.save_config_audited(@changes, audit: fn -> {:error, :audit_write_failed} end, unaudited_ok: true)})
        end)

      assert_received {:result, {:ok, %{audited: false}}}
      assert_received {:tx, _, true}
      assert_received {:tx, @changes, false}
      refute_received {:tx, _, _}
      assert log =~ ~r/audit/i
      refute log =~ "x-app"
    end

    test "unaudited_ok with a failing retry is an error (nothing persisted); a non-audit error is returned as is, no retry" do
      Application.put_env(:nebu_http, :admin_config_tx, fn _changes, _audit -> {:error, :db_down} end)
      assert {:error, :db_down} = DB.save_config_audited(@changes, audit: fn -> :ok end, unaudited_ok: true)

      n = :counters.new(1, [])

      Application.put_env(:nebu_http, :admin_config_tx, fn _changes, audit ->
        :counters.add(n, 1, 1)
        if audit, do: {:error, {:audit, :x}}, else: {:error, :db_down}
      end)

      capture_log(fn -> assert {:error, :db_down} = DB.save_config_audited(@changes, audit: fn -> :ok end, unaudited_ok: true) end)
      assert :counters.get(n, 1) == 2
    end

    test "defence in depth: empty changes, a non-string key or a non-string value never reach the transaction" do
      for bad <- [%{}, %{:atom_key => "v"}, %{"k" => 1}, %{"k" => nil}, [{"k", "v"}], nil] do
        assert {:error, :invalid_changes} = DB.save_config_audited(bad, audit: fn -> :ok end), inspect(bad)
      end

      refute_received {:tx, _, _}
    end
  end

  describe "the real transaction (integration)" do
    @describetag :integration

    @keys ["sso_extra_redirect_schemes", "sso_redirect_allowed_origins", "oidc_user_id_claim", "admin_group_claim"]

    setup do
      prior = T.privileged_sql!("SELECT key, value, set_at FROM server_config WHERE key = ANY($1)", [@keys]).rows
      T.privileged_sql!("DELETE FROM server_config WHERE key = ANY($1)", [@keys])
      T.privileged_sql!("INSERT INTO server_config (key, value, set_at) VALUES ('sso_extra_redirect_schemes', 'old-scheme', 1)")
      T.privileged_sql!("DELETE FROM audit_log WHERE action = 'sso_redirect_schemes_changed'")

      on_exit(fn ->
        Nebu.Matrix.OidcClaimCache.reset_for_test()
        T.privileged_sql!("DELETE FROM server_config WHERE key = ANY($1)", [@keys])
        for [k, v, at] <- prior, do: T.privileged_sql!("INSERT INTO server_config (key, value, set_at) VALUES ($1, $2, $3)", [k, v, at])
        T.privileged_sql!("DELETE FROM audit_log WHERE action = 'sso_redirect_schemes_changed'")
      end)

      :ok
    end

    defp value_of(key), do: T.sql!("SELECT value FROM server_config WHERE key = $1", [key]).rows |> List.first() |> List.wrap() |> List.first()
    defp audit_rows, do: T.privileged_sql!("SELECT actor_user_id, action, target_id, metadata FROM audit_log WHERE action = 'sso_redirect_schemes_changed' ORDER BY id").rows

    defp audit(schemes \\ "x-app, y-app") do
      fn -> Nebu.Compliance.AuditWriter.log("@admin:test.local", "sso_redirect_schemes_changed", "server_config", "sso_extra_redirect_schemes", %{"schemes" => schemes}, "success", nil) end
    end

    test "the runtime role writes the keys and ONE audit row appears with the change, inside the same transaction" do
      test_pid = self()

      audit = fn ->
        send(test_pid, {:in_tx, Nebu.Repo.in_transaction?()})
        audit().()
      end

      assert {:ok, %{audited: true}} = DB.save_config_audited(%{"sso_extra_redirect_schemes" => "x-app, y-app"}, audit: audit)
      assert_received {:in_tx, true}
      assert value_of("sso_extra_redirect_schemes") == "x-app, y-app"
      assert [["@admin:test.local", "sso_redirect_schemes_changed", "sso_extra_redirect_schemes", %{"schemes" => "x-app, y-app"}]] = audit_rows()
    end

    test "an audit that fails INSIDE the transaction with a database error (not just an error tuple) rolls back; with unaudited_ok the value is applied by the retry" do
      db_error = fn ->
        Ecto.Adapters.SQL.query!(Nebu.Repo, "INSERT INTO nonexistent_table_for_the_audit_test VALUES (1)", [])
        :ok
      end

      capture_log(fn ->
        assert {:error, {:audit, _}} = DB.save_config_audited(%{"sso_extra_redirect_schemes" => "new-scheme"}, audit: db_error)
      end)

      assert value_of("sso_extra_redirect_schemes") == "old-scheme"

      capture_log(fn ->
        assert {:ok, %{audited: false}} = DB.save_config_audited(%{"sso_extra_redirect_schemes" => "new-scheme"}, audit: db_error, unaudited_ok: true)
      end)

      assert value_of("sso_extra_redirect_schemes") == "new-scheme"
    end

    test "narrowing: the retry without audit re-checks the STORED values under a row lock; a value that is no longer a narrowing is refused (SEC review L-3)" do
      failing = fn -> {:error, :audit_write_failed} end
      subset = fn stored -> stored["sso_extra_redirect_schemes"] == "old-scheme" end

      capture_log(fn ->
        assert {:ok, %{audited: false}} = DB.save_config_audited(%{"sso_extra_redirect_schemes" => ""}, audit: failing, unaudited_ok: true, narrowing: subset)
      end)

      assert value_of("sso_extra_redirect_schemes") == ""

      # the stored value changed meanwhile (another admin): the same decision no longer holds
      T.privileged_sql!("UPDATE server_config SET value = 'old-scheme, other' WHERE key = 'sso_extra_redirect_schemes'")

      capture_log(fn ->
        assert {:error, {:audit, :not_narrowing}} = DB.save_config_audited(%{"sso_extra_redirect_schemes" => "old-scheme"}, audit: failing, unaudited_ok: true, narrowing: subset)
      end)

      assert value_of("sso_extra_redirect_schemes") == "old-scheme, other", "nothing was applied"
    end

    test "several keys are written together (insert and update paths)" do
      assert {:ok, %{audited: true}} = DB.save_config_audited(%{"sso_extra_redirect_schemes" => "z", "oidc_user_id_claim" => "preferred_username"}, audit: audit("z"))
      assert value_of("sso_extra_redirect_schemes") == "z"
      assert value_of("oidc_user_id_claim") == "preferred_username"
    end

    test "a failing audit (the real writer refuses an unknown action) rolls the upsert back: the old value stays, no row, {:error, {:audit, _}}" do
      failing = fn -> Nebu.Compliance.AuditWriter.log("@admin:test.local", "no_such_action_xyz", "server_config", "k", %{}, "success", nil) end

      capture_log(fn ->
        assert {:error, {:audit, _}} = DB.save_config_audited(%{"sso_extra_redirect_schemes" => "new-scheme"}, audit: failing)
      end)

      assert value_of("sso_extra_redirect_schemes") == "old-scheme"
      assert audit_rows() == []
    end

    test "unaudited_ok: after the failed audit the value IS applied (retry without audit), audited: false, no row" do
      failing = fn -> {:error, :audit_write_failed} end

      capture_log(fn ->
        assert {:ok, %{audited: false}} = DB.save_config_audited(%{"sso_extra_redirect_schemes" => ""}, audit: failing, unaudited_ok: true)
      end)

      assert value_of("sso_extra_redirect_schemes") == ""
      assert audit_rows() == []
    end

    test "a failing UPSERT of the LAST key (keys are written in key order) rolls the earlier one back and writes no audit row: the keys are atomic with each other" do
      T.privileged_sql!("INSERT INTO server_config (key, value, set_at) VALUES ('sso_redirect_allowed_origins', 'https://old.example', 1)")
      T.privileged_sql!("CREATE OR REPLACE FUNCTION public.admin_config_test_fail() RETURNS trigger AS $$ BEGIN RAISE EXCEPTION 'admin config test failure'; END; $$ LANGUAGE plpgsql")
      T.privileged_sql!("CREATE TRIGGER admin_config_test_fail BEFORE INSERT OR UPDATE ON server_config FOR EACH ROW WHEN (NEW.key = 'sso_redirect_allowed_origins') EXECUTE FUNCTION public.admin_config_test_fail()")

      on_exit(fn ->
        T.privileged_sql!("DROP TRIGGER IF EXISTS admin_config_test_fail ON server_config")
        T.privileged_sql!("DROP FUNCTION IF EXISTS public.admin_config_test_fail()")
      end)

      capture_log(fn ->
        assert {:error, _} = DB.save_config_audited(%{"sso_extra_redirect_schemes" => "new-scheme", "sso_redirect_allowed_origins" => "https://new.example"}, audit: audit())
      end)

      assert value_of("sso_extra_redirect_schemes") == "old-scheme", "written BEFORE the failing key, rolled back"
      assert value_of("sso_redirect_allowed_origins") == "https://old.example"
      assert audit_rows() == []
    end

    test "after a successful commit the side effects of upsert_server_config run (the claim cache is refreshed); after a rollback they do not" do
      pt = :nebu_oidc_user_id_claim
      on_exit(fn -> Nebu.Matrix.OidcClaimCache.reset_for_test() end)

      :persistent_term.put(pt, {:value, "sentinel"})
      capture_log(fn -> DB.save_config_audited(%{"oidc_user_id_claim" => "sub"}, audit: fn -> {:error, :boom} end) end)
      assert :persistent_term.get(pt) == {:value, "sentinel"}, "a rolled-back save leaves the cache alone"

      assert {:ok, _} = DB.save_config_audited(%{"oidc_user_id_claim" => "sub"}, audit: fn -> :ok end)
      assert :persistent_term.get(pt) == {:value, "sub"}, "refreshed from the committed row, after the commit"
    end
  end

  describe "static hygiene" do
    @db Path.expand("../../../lib/nebu/admin/db.ex", __DIR__)

    test "the SQL lives in Nebu.Admin.DB (ADR-018) and the transaction seam is compile-guarded (D5)" do
      src = File.read!(@db)
      assert src =~ "def save_config_audited("
      assert src =~ "repo.transaction(fn"
      guarded = Regex.replace(~r/  if Mix\.env\(\) == :test do.*?\n  else\n/s, src, "")
      code = guarded |> String.replace(~r/@(module)?doc """.*?"""/s, "") |> String.replace(~r/^\s*#.*$/m, "")
      refute code =~ ":admin_config_tx", "the seam is read only inside `if Mix.env() == :test`"
    end
  end
end
