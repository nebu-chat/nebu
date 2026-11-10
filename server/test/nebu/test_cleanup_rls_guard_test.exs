defmodule Nebu.TestCleanupRlsGuardTest do
  @moduledoc """
  Static guard (no DB, no network) for bugfix `test-cleanup-rls-noop-delete`.

  `server_config` (FORCE row level security, no DELETE policy) and `audit_log` (policy `audit_log_no_delete`, the runtime role is not the table owner) cannot be
  deleted from through `Nebu.Repo`: a cleanup `DELETE FROM server_config ...` / `DELETE FROM audit_log ...` affects 0 rows and the leftover value leaks into the
  following tests and the live stack. A test that has to remove such rows goes through the privileged role (`Nebu.OAuth.TestSupport.privileged_sql!/2`, or a
  migrate-role `Postgrex` connection); a test that has to put a config key back uses `Nebu.OAuth.TestSupport.restore_server_config_on_exit!/2`.

  The check: every non-comment line of a test file that names one of the two tables in a delete statement must have a privileged call on the same line or
  in the call-opening lines (up to three) before it. (A statement split across lines between `DELETE` and `FROM` is not recognised.)
  """
  use ExUnit.Case, async: true

  @test_root Path.expand("..", __DIR__)
  # functions, not module attributes: a compiled regex cannot be stored in an attribute on OTP 28
  defp no_op_delete, do: ~r/DELETE\s+FROM\s+(server_config|audit_log)\b/i
  defp privileged, do: ~r/privileged_sql!|Postgrex\.query|migrate_role_conn|with_privileged_conn/

  def offending_lines(lines) do
    lines
    |> Enum.with_index()
    |> Enum.filter(fn {line, i} ->
      not String.match?(line, ~r/^\s*#/) and Regex.match?(no_op_delete(), line) and not privileged_call?(lines, i)
    end)
    |> Enum.map(fn {_line, i} -> i + 1 end)
  end

  # the line itself, or the (up to three) lines before it that open the call: the look-back stops at an earlier delete statement, so a privileged
  # delete directly above a runtime-role delete does not sanction the second one
  defp privileged_call?(lines, i) do
    before = lines |> Enum.take(i) |> Enum.reverse() |> Enum.take(3) |> Enum.take_while(&(not Regex.match?(no_op_delete(), &1)))
    Enum.any?([Enum.at(lines, i) | before], &Regex.match?(privileged(), &1))
  end

  test "the detector flags a runtime-role DELETE and accepts a privileged one (not vacuous)" do
    runtime = ["Ecto.Adapters.SQL.query(Nebu.Repo, \"DELETE FROM server_config WHERE key = $1\", [key])"]
    audit = ["x = 1", "Ecto.Adapters.SQL.query(Repo, \"delete from audit_log WHERE target_id = $1\", [id])"]
    privileged = ["T.privileged_sql!(", "  \"DELETE FROM server_config WHERE key = ANY($1)\",", "  [keys]", ")"]
    migrate_conn = ["Postgrex.query(conn, \"DELETE FROM audit_log WHERE target_id = $1\", [id])"]
    adjacent = [
      "T.privileged_sql!(\"DELETE FROM audit_log WHERE action = 'x'\")",
      "Ecto.Adapters.SQL.query(Nebu.Repo, \"DELETE FROM server_config WHERE key = 'y'\", [])"
    ]

    comment = ["# the old cleanup was DELETE FROM server_config WHERE key = 'x'"]

    assert offending_lines(runtime) == [1]
    assert offending_lines(audit) == [2]
    assert offending_lines(privileged) == []
    assert offending_lines(migrate_conn) == []
    assert offending_lines(adjacent) == [2]
    assert offending_lines(comment) == []
  end

  test "no test file deletes from server_config / audit_log through the runtime role (a silent no-op)" do
    self_file = Path.expand(__ENV__.file)

    offenders =
      for file <- Path.wildcard(Path.join(@test_root, "**/*.{ex,exs}")),
          Path.expand(file) != self_file,
          line_no <- file |> File.read!() |> String.split("\n") |> offending_lines() do
        "#{Path.relative_to(file, @test_root)}:#{line_no}"
      end

    assert offenders == [],
           "DELETE FROM server_config / audit_log through Nebu.Repo deletes nothing (row level security): use Nebu.OAuth.TestSupport.privileged_sql!/2 " <>
             "or restore_server_config_on_exit!/2 at: #{Enum.join(offenders, ", ")}"
  end
end
