defmodule Nebu.Compliance.UserDeletionFailureStepsTest do
  @moduledoc """
  Review cycle 0 of story `gdpr-erasure-global-data` (decision D18 (d), (e), and the GRANT check of D18 (d)), real database:

    * D18 (d): a failing step of the erasure is NAMED: the `error_detail` of the `user_keys_deletion_attempted` audit row is `step=<name>` and the log says
      `... in step <name>`; the answer is `{:error, reason}` with `reason` reduced to an atom / the SQLSTATE (`{:db_error, :raise_exception}`), never a Postgrex
      error struct (its statement and constraint detail can quote row values). Everything stays rolled back (the existing S5 suite proves the rollback).
    * D18 (e): without the delete policy of migration 000055 the `DELETE FROM oauth_codes` silently deletes nothing for an unexpired code (FORCE ROW LEVEL SECURITY
      hides the row): the erasure counts what is left and FAILS CLOSED (step `oauth_codes_not_erased`, rolled back, attempted audit) instead of reporting success
      while the `idp_rt_enc` ciphertext survives. The test puts the 000041 policy back (privileged, restored by `on_exit`).
    * D18 (d): the runtime role can DELETE from every table the erasure deletes from (`account_data` and `cross_signing_keys` have no explicit GRANT in
      migrations 000014 / 000015).

  async: false (real `AuditWriter` seam, DDL on `oauth_codes`, trigger DDL, committed rows).
  """
  use ExUnit.Case, async: false

  alias Nebu.Compliance.UserDeletion
  alias Nebu.Compliance.UserDeletionTestSupport, as: E
  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration

  @migrations Path.expand("../../../priv/migrations", __DIR__)

  setup do
    env = E.setup_env!()
    previous = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous) end)
    {:ok, env}
  end

  defp erase!(uid), do: UserDeletion.delete_user_keys(E.admin(), uid, "atdd erasure")

  defp attempted_detail(uid) do
    assert [[_actor, "attempted", metadata, detail]] = E.audit_rows(uid, "user_keys_deletion_attempted")
    {metadata, detail}
  end

  describe "D18 (d) - the failing step is named" do
    for table <- UserDeletion.erased_tables() do
      test "a failing DELETE FROM #{table}: step=delete_#{table} in the audit error_detail and the log, the reason is a SQLSTATE atom", %{cid: cid} do
        a = E.seed_user!(cid, "a")
        E.block!(unquote(table), "DELETE", a.uid)

        log = ExUnit.CaptureLog.capture_log([level: :debug], fn -> assert {:error, {:db_error, :raise_exception}} = erase!(a.uid) end)

        assert {metadata, "step=delete_#{unquote(table)}"} = attempted_detail(a.uid)
        assert log =~ "in step delete_#{unquote(table)}"
        refute metadata =~ "Postgrex", "the audit row carries the SQLSTATE atom, not the error struct"
        refute log =~ a.canary
        assert E.user_row(a.uid)["deletion_status"] == nil, "rolled back"
      end
    end

    test "a failing user_keys update (step 3), the profile anonymisation, the first and the last users update are named", %{cid: cid} do
      a = E.seed_user!(cid, "a")
      remove = E.block!("user_keys", "UPDATE", a.uid)
      assert {:error, {:db_error, :raise_exception}} = erase!(a.uid)
      assert {_, "step=delete_signing_key"} = attempted_detail_last(a.uid)
      remove.()

      remove = E.block!("profiles", "UPDATE", a.uid)
      assert {:error, {:db_error, :raise_exception}} = erase!(a.uid)
      assert {_, "step=anonymise_profile"} = attempted_detail_last(a.uid)
      remove.()

      # the first write of the transaction (the in-progress mark)
      remove = E.block!("users", "UPDATE", a.uid)
      assert {:error, {:db_error, :raise_exception}} = erase!(a.uid)
      assert {_, "step=mark_in_progress"} = attempted_detail_last(a.uid)
      remove.()

      # the last write (the status flip): a trigger that only fires for the new status
      name = "atdd_ck_flip_" <> T.rand(5)

      T.privileged_sql!(
        "CREATE FUNCTION #{name}() RETURNS trigger AS $$ BEGIN IF NEW.deletion_status = 'keys_deleted' THEN RAISE EXCEPTION 'atdd: forced failure'; END IF; RETURN NEW; END $$ LANGUAGE plpgsql"
      )

      T.privileged_sql!("CREATE TRIGGER #{name} BEFORE UPDATE ON users FOR EACH ROW EXECUTE FUNCTION #{name}()")

      on_exit(fn ->
        T.privileged_sql!("DROP TRIGGER IF EXISTS #{name} ON users")
        T.privileged_sql!("DROP FUNCTION IF EXISTS #{name}()")
      end)

      assert {:error, {:db_error, :raise_exception}} = erase!(a.uid)
      assert {_, "step=mark_keys_deleted"} = attempted_detail_last(a.uid)
      assert E.user_row(a.uid)["deletion_status"] == nil, "rolled back"
      assert E.count("account_data", a.uid) == 6, "every earlier step is rolled back"
    end
  end

  # the newest attempted audit row of the user
  defp attempted_detail_last(uid) do
    rows = E.audit_rows(uid, "user_keys_deletion_attempted")
    assert rows != []
    [_actor, "attempted", metadata, detail] = List.last(rows)
    {metadata, detail}
  end

  describe "D18 (e) - fail closed without migration 000055" do
    # the policy of migration 000041 (reuse detection only), put back for the test and restored from the migration file
    defp old_policy!() do
      T.privileged_sql!("DROP POLICY IF EXISTS oauth_codes_delete ON oauth_codes")
      T.privileged_sql!("CREATE POLICY oauth_codes_delete ON oauth_codes FOR DELETE USING (expires_at < now() - interval '24 hours')")

      restore = fn ->
        statements =
          Path.join(@migrations, "000055_oauth_codes_erasure_delete.up.sql")
          |> File.read!()
          |> String.split("\n")
          |> Enum.reject(&String.starts_with?(String.trim(&1), "--"))
          |> Enum.join("\n")
          |> String.split(";")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        for s <- statements, do: T.privileged_sql!(s)
      end

      ExUnit.Callbacks.on_exit(restore)
      restore
    end

    test "the erasure answers an error, names the step, rolls everything back, and a retry with the policy succeeds", %{cid: cid} do
      a = E.seed_user!(cid, "a")
      restore = old_policy!()
      assert E.count("oauth_codes", a.uid) >= 1, "precondition: a pending authorization code (idp_rt_enc)"
      before = E.snapshot(a.uid)

      log = ExUnit.CaptureLog.capture_log([level: :debug], fn -> assert {:error, :rows_left} = erase!(a.uid) end)

      assert {_metadata, "step=oauth_codes_not_erased"} = attempted_detail(a.uid)
      assert log =~ "in step oauth_codes_not_erased"
      assert E.audit_count(a.uid, "user_keys_deleted") == 0, "no success audit row"
      assert E.user_row(a.uid)["deletion_status"] == nil, "the in-progress marker is rolled back"
      assert E.snapshot(a.uid) == before, "every row of A, the room account data and the account data included, is still there"

      restore.()
      assert {:ok, _} = erase!(a.uid)
      for t <- E.expected_erased(), do: assert(E.count(t, a.uid) == 0, "after the retry A has no rows in #{t}")
    end

    test "with the policy of 000055 the same erasure succeeds (the check is not a false alarm)", %{cid: cid} do
      a = E.seed_user!(cid, "a")
      assert E.count("oauth_codes", a.uid) >= 1
      assert {:ok, _} = erase!(a.uid)
      assert E.count("oauth_codes", a.uid) == 0
    end
  end

  describe "D18 (d) - the privilege to delete" do
    test "the runtime role has the DELETE privilege on every table of erased_tables/0, and UPDATE on profiles and users" do
      for table <- UserDeletion.erased_tables() do
        assert T.sql!("SELECT has_table_privilege(current_user, $1, 'DELETE')", [table]).rows == [[true]], "the runtime role cannot DELETE from #{table}"
      end

      for table <- ~w(profiles users user_keys) do
        assert T.sql!("SELECT has_table_privilege(current_user, $1, 'UPDATE')", [table]).rows == [[true]], "the runtime role cannot UPDATE #{table}"
      end
    end
  end
end
