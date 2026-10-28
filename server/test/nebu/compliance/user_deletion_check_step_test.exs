defmodule Nebu.Compliance.UserDeletionCheckStepTest do
  @moduledoc """
  Delta review cycle 1 (INFO-1): the step name of the `oauth_codes` check. `oauth_codes_not_erased` means "the count says rows are left" (the 000055 policy is missing);
  a count query that itself FAILS is the distinct step `oauth_codes_check`. Both fail closed. No database: a repo fake and an audit writer that records `error_detail`
  (the audit writer of `user_deletion_test.exs` drops it).

  async: false (injects the process-global `:compliance` repo / audit writer seams; guarded by AuditWriterSeamRaceRegressionTest).
  """
  use ExUnit.Case, async: false

  defmodule Repo do
    @moduledoc false
    def transaction(fun) do
      case fun.() do
        {:error, _} = err -> err
        other -> {:ok, other}
      end
    end

    def query(sql, args, _opts \\ []) do
      sql = String.replace(sql, ~r/\s+/, " ")

      cond do
        sql =~ "SELECT user_id, deletion_status FROM users" -> {:ok, %{rows: [[hd(args), nil]], num_rows: 1}}
        sql =~ "deletion_in_progress" -> {:ok, %{rows: [[hd(args)]], num_rows: 1}}
        sql =~ "SELECT count(*) FROM oauth_codes" -> Application.fetch_env!(:compliance, :__test_count_answer__)
        true -> {:ok, %{rows: [], num_rows: 0}}
      end
    end
  end

  defmodule Audit do
    @moduledoc false
    def log(_actor, action, _type, _target, _metadata, _outcome, error_detail \\ nil) do
      send(Application.fetch_env!(:compliance, :__test_pid__), {:audit, action, error_detail})
      :ok
    end
  end

  setup do
    Application.put_env(:compliance, :repo, Repo)
    Application.put_env(:compliance, :audit_writer, Audit)
    Application.put_env(:compliance, :__test_pid__, self())

    on_exit(fn ->
      for k <- [:repo, :audit_writer, :__test_pid__, :__test_count_answer__], do: Application.delete_env(:compliance, k)
    end)
  end

  test "rows left after the DELETE: step oauth_codes_not_erased, {:error, :rows_left}" do
    Application.put_env(:compliance, :__test_count_answer__, {:ok, %{rows: [[2]], num_rows: 1}})

    assert {:error, :rows_left} = Nebu.Compliance.UserDeletion.delete_user_keys("@admin:x", "@u:x", "r")
    assert_received {:audit, "user_keys_deletion_attempted", "step=oauth_codes_not_erased"}
  end

  test "the count query itself fails: the distinct step oauth_codes_check" do
    Application.put_env(:compliance, :__test_count_answer__, {:error, :simulated_db_error})

    assert {:error, :simulated_db_error} = Nebu.Compliance.UserDeletion.delete_user_keys("@admin:x", "@u:x", "r")
    assert_received {:audit, "user_keys_deletion_attempted", "step=oauth_codes_check"}
  end

  test "no rows left: the erasure succeeds (control)" do
    Application.put_env(:compliance, :__test_count_answer__, {:ok, %{rows: [[0]], num_rows: 1}})

    assert {:ok, %{keys_deleted_at: _}} = Nebu.Compliance.UserDeletion.delete_user_keys("@admin:x", "@u:x", "r")
    assert_received {:audit, "user_keys_deleted", nil}
  end
end
