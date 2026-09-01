defmodule Nebu.Media.ScanFailedMigrationTest do
  @moduledoc """
  Static SQL-analysis tests for the `scan_failed` ENUM-value migration
  (media-security-admin-control/4a-scan-failed-enum-migration, AC1/AC2/AC6).
  Mirrors the style of `Nebu.Media.StateTransitionsMigrationTest` — no
  database connection required; these tests parse the migration's `.sql`
  files as plain text.

  ## Migration number: 000028, not 000023

  The story's own Technical Requirements section names this migration
  `000023_media_scan_failed_state.*.sql`, written when Story 1a's foundation
  migration (000022) was the newest migration on this branch. By the time
  this story actually landed, 000023-000027 had already been claimed by
  other stories that shipped first (000023_media_config,
  000024_media_storage_config, 000025_media_files_filename,
  000026_oban_jobs, 000027_media_files_uploader_user_id_nullable) — so the
  real migration here is 000028, the next free slot. This is a pure
  filename/number correction; the SQL content and every other acceptance
  criterion are unchanged from the story text.

  RED by design: `server/priv/migrations/000028_media_scan_failed_state.up.sql`
  and `.down.sql` do not exist yet (this story's dev step creates them).
  """

  use ExUnit.Case, async: true

  @migrations_dir Path.expand("../../../priv/migrations", __DIR__)
  @up_migration "000028_media_scan_failed_state.up.sql"
  @down_migration "000028_media_scan_failed_state.down.sql"

  defp migration_path(filename), do: Path.join(@migrations_dir, filename)
  defp read_migration!(filename), do: File.read!(migration_path(filename))

  # Strips SQL line comments ("-- ...") before looking for statements, so a
  # comment merely mentioning a keyword (e.g. "ALTER TYPE" inside prose, or
  # "GRANT" inside an explanation) cannot cause a false positive/negative.
  defp strip_comments(sql) do
    sql
    |> String.split("\n")
    |> Enum.map(fn line ->
      case String.split(line, "--", parts: 2) do
        [code, _comment] -> code
        [code] -> code
      end
    end)
    |> Enum.join("\n")
  end

  defp statements(sql) do
    sql
    |> strip_comments()
    |> String.split(";")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  # ---------------------------------------------------------------------------
  # Test 1 — up migration is exactly one ALTER TYPE ... ADD VALUE statement
  # ---------------------------------------------------------------------------

  describe "000028 up migration applies cleanly on top of 000022's media_state ENUM" do
    setup do
      {:ok, sql: read_migration!(@up_migration)}
    end

    test "contains exactly one statement, ALTER TYPE media_state ADD VALUE 'scan_failed'", %{
      sql: sql
    } do
      stmts = statements(sql)

      assert length(stmts) == 1,
             "000028 up migration must contain exactly one SQL statement, got #{length(stmts)}: #{inspect(stmts)}"

      [only_stmt] = stmts

      assert String.match?(
               only_stmt,
               ~r/^ALTER\s+TYPE\s+media_state\s+ADD\s+VALUE\s+(IF\s+NOT\s+EXISTS\s+)?'scan_failed'$/i
             ),
             "000028's only statement must be ALTER TYPE media_state ADD VALUE 'scan_failed' " <>
               "(optionally with IF NOT EXISTS), got: #{inspect(only_stmt)}"
    end

    test "adds exactly the value 'scan_failed', nothing else", %{sql: sql} do
      assert String.match?(sql, ~r/ADD\s+VALUE\s+(IF\s+NOT\s+EXISTS\s+)?'scan_failed'/i)

      code_only = strip_comments(sql)

      refute String.match?(code_only, ~r/ADD\s+VALUE\s+(?!(IF\s+NOT\s+EXISTS\s+)?'scan_failed')/i),
             "000028 must not add any enum value other than 'scan_failed'"
    end
  end

  # ---------------------------------------------------------------------------
  # Test 2 — regression guard: no other DDL/DML anywhere in the up migration
  # ---------------------------------------------------------------------------

  describe "000028 up migration does not touch media_files, media_state_transitions, or any other type" do
    setup do
      {:ok, sql: read_migration!(@up_migration)}
    end

    test "no ALTER TABLE statement", %{sql: sql} do
      refute String.match?(strip_comments(sql), ~r/ALTER\s+TABLE/i),
             "000028 up migration must not ALTER TABLE anything (AC6: no data migration, purely additive DDL on the type only)"
    end

    test "no INSERT statement", %{sql: sql} do
      refute String.match?(strip_comments(sql), ~r/\bINSERT\b/i),
             "000028 up migration must not INSERT anything (AC6: no data migration)"
    end

    test "no UPDATE statement", %{sql: sql} do
      refute String.match?(strip_comments(sql), ~r/\bUPDATE\b/i),
             "000028 up migration must not UPDATE anything (AC6: no data migration/backfill)"
    end

    test "no CREATE TYPE / DROP TYPE referencing anything other than adding the value to media_state",
         %{sql: sql} do
      refute String.match?(strip_comments(sql), ~r/CREATE\s+TYPE/i),
             "000028 up migration must not CREATE TYPE (media_state already exists from 000022)"

      refute String.match?(strip_comments(sql), ~r/DROP\s+TYPE/i),
             "000028 up migration must not DROP TYPE"
    end
  end

  # ---------------------------------------------------------------------------
  # Test 3 — down migration is a documented no-op, no destructive DDL
  # ---------------------------------------------------------------------------

  describe "000028 down migration contains no destructive DDL" do
    setup do
      {:ok, sql: read_migration!(@down_migration)}
    end

    test "contains no DROP TYPE", %{sql: sql} do
      refute String.match?(strip_comments(sql), ~r/DROP\s+TYPE/i),
             "000028 down migration must not DROP TYPE media_state (that would destroy every " <>
               "media_files row's state, not just undo the scan_failed addition)"
    end

    test "contains no ALTER TYPE ... DROP VALUE (does not exist in Postgres, would be a runtime error)",
         %{sql: sql} do
      refute String.match?(strip_comments(sql), ~r/ALTER\s+TYPE.*DROP\s+VALUE/is),
             "000028 down migration must not attempt ALTER TYPE ... DROP VALUE — this statement " <>
               "does not exist in PostgreSQL and would error at migration time"
    end

    test "documents the manual recreate-type rollback procedure as a comment", %{sql: sql} do
      assert String.match?(sql, ~r/CREATE\s+TYPE\s+media_state_old/i),
             "000028 down migration must document the manual CREATE TYPE media_state_old " <>
               "recreate procedure as a comment (AC2)"

      assert String.match?(sql, ~r/--.*no-op/i) or String.match?(sql, ~r/--.*deliberately/i),
             "000028 down migration must explain, in a comment, that it is deliberately a no-op"
    end

    test "contains no executable SQL statement at all (comment-only file)", %{sql: sql} do
      assert statements(sql) == [],
             "000028 down migration must contain zero executable statements " <>
               "(it is a documented no-op, not a real reversal), found: #{inspect(statements(sql))}"
    end
  end

  # ---------------------------------------------------------------------------
  # Test 4 — down migration contains no GRANT (AC4-style regression net)
  # ---------------------------------------------------------------------------

  describe "down migration has no GRANT statement (AC4-style, mirrors MigrationsGrantTest)" do
    test "000028 down migration contains no GRANT statement" do
      sql = read_migration!(@down_migration)

      refute String.match?(sql, ~r/GRANT\s+.+\s+TO\s+nebu_app/i),
             "000028_media_scan_failed_state.down.sql must NOT contain GRANT statements " <>
               "(trivially true for a no-op file, but keeps the convention's regression net " <>
               "covering every down migration, not just the ones with real grants — see also " <>
               "the mirrored entry added to Nebu.Matrix.MigrationsGrantTest's @down_migrations)"
    end
  end
end
