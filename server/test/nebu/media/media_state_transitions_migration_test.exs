defmodule Nebu.Media.StateTransitionsMigrationTest do
  @moduledoc """
  Static SQL-analysis tests for the media state-machine foundation migration
  (`000022_media_state_machine_foundation`). Mirrors the style of
  `Nebu.Matrix.MigrationsGrantTest` — no database connection required; these
  tests parse the migration's `.sql` files as plain text.

  Covers the static (non-DB) acceptance tests from
  `docs/stories/media-security-admin-control/1a-media-files-migration.md`:
  the `media_state` / `media_transition_actor_type` ENUMs, the additive
  `media_files` columns + backfill statements, the `media_state_transitions`
  table shape, the append-only trigger (ADR-031), the RLS/REVOKE secondary
  layer, and the grants convention (see also the mirrored
  `"AC1/AC2: 000022_media_state_machine_foundation.up.sql grants"` describe
  block added to `Nebu.Matrix.MigrationsGrantTest` for the sweeping
  per-migration grant regression guard).

  RED by design: `server/priv/migrations/000022_media_state_machine_foundation.up.sql`
  and `.down.sql` do not exist yet (Story 1a's dev step creates them). Every
  test here reads one of those files via `File.read!/1`, which raises until
  the migration lands.
  """

  use ExUnit.Case, async: true

  @migrations_dir Path.expand("../../../priv/migrations", __DIR__)
  @up_migration "000022_media_state_machine_foundation.up.sql"
  @down_migration "000022_media_state_machine_foundation.down.sql"

  @expected_media_state_values ~w(reserved quarantined scanning released infected admin_blocked deleted hard_deleted)
  @expected_actor_type_values ~w(system admin)
  @new_media_files_columns ~w(state file_hash scan_metadata storage_key compressed archived_at deleted_at hard_deleted_at)
  @preexisting_media_files_columns ~w(media_id server_name content_type file_size aes_key_hex nonce_hex uploader_user_id uploaded_at deleted)

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp migration_path(filename), do: Path.join(@migrations_dir, filename)
  defp read_migration!(filename), do: File.read!(migration_path(filename))

  defp enum_values(sql, type_name) do
    case Regex.run(~r/CREATE\s+TYPE\s+#{type_name}\s+AS\s+ENUM\s*\(([^)]*)\)/is, sql) do
      [_, body] ->
        body
        |> String.split(",")
        |> Enum.map(&(&1 |> String.trim() |> String.trim("'") |> String.trim()))
        |> Enum.reject(&(&1 == ""))

      nil ->
        []
    end
  end

  defp media_state_transitions_column_lines(sql) do
    case Regex.run(~r/CREATE\s+TABLE\s+media_state_transitions\s*\(([^;]*?)\)\s*;/is, sql) do
      [_, body] ->
        body
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.map(&String.trim_trailing(&1, ","))
        |> Enum.reject(&(&1 == ""))

      nil ->
        []
    end
  end

  # ---------------------------------------------------------------------------
  # Test 1 / 2 — media_state ENUM
  # ---------------------------------------------------------------------------

  describe "media_state ENUM type" do
    setup do
      {:ok, sql: read_migration!(@up_migration)}
    end

    test "000022 up migration creates the media_state ENUM type", %{sql: sql} do
      assert String.match?(sql, ~r/CREATE\s+TYPE\s+media_state\s+AS\s+ENUM/i),
             "000022 up migration must CREATE TYPE media_state AS ENUM"
    end

    test "media_state ENUM has exactly the 8 expected values, no scan_failed", %{sql: sql} do
      values = enum_values(sql, "media_state")

      assert MapSet.new(values) == MapSet.new(@expected_media_state_values),
             "media_state ENUM values #{inspect(values)} must equal #{inspect(@expected_media_state_values)}"

      refute "scan_failed" in values,
             "media_state ENUM must NOT include 'scan_failed' in this migration (added later in Story 4a)"
    end

    test "media_state ENUM values are declared in the exact order given by AC2", %{sql: sql} do
      values = enum_values(sql, "media_state")

      assert values == @expected_media_state_values,
             "media_state ENUM must declare values in this exact order " <>
               "#{inspect(@expected_media_state_values)}, got #{inspect(values)} " <>
               "(AC2: \"exactly these 8 values, in this order\" — ordinal position is " <>
               "meaningful for any future lifecycle-progression comparison, e.g. Story 1b)"
    end
  end

  # ---------------------------------------------------------------------------
  # Test 3 — media_transition_actor_type ENUM
  # ---------------------------------------------------------------------------

  describe "media_transition_actor_type ENUM type" do
    setup do
      {:ok, sql: read_migration!(@up_migration)}
    end

    test "media_transition_actor_type ENUM has exactly system and admin", %{sql: sql} do
      values = enum_values(sql, "media_transition_actor_type")

      assert MapSet.new(values) == MapSet.new(@expected_actor_type_values),
             "media_transition_actor_type ENUM values #{inspect(values)} must equal #{inspect(@expected_actor_type_values)}"
    end
  end

  # ---------------------------------------------------------------------------
  # Test 4 — media_files additive columns
  # ---------------------------------------------------------------------------

  describe "media_files ADD COLUMN" do
    setup do
      {:ok, sql: read_migration!(@up_migration)}
    end

    test "media_files gains the 8 new columns via ALTER TABLE ADD COLUMN", %{sql: sql} do
      for column <- @new_media_files_columns do
        assert String.match?(sql, ~r/ADD\s+COLUMN\s+#{column}\b/i),
               "000022 must ADD COLUMN #{column} to media_files"
      end
    end

    test "none of the 9 pre-existing media_files columns is dropped or altered", %{sql: sql} do
      for column <- @preexisting_media_files_columns do
        refute String.match?(sql, ~r/DROP\s+COLUMN\s+#{column}\b/i),
               "000022 must not DROP the pre-existing column #{column}"

        refute String.match?(sql, ~r/ALTER\s+COLUMN\s+#{column}\b/i),
               "000022 must not ALTER the pre-existing column #{column}"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Test 5 / 6 — backfill statements
  # ---------------------------------------------------------------------------

  describe "backfill statements" do
    setup do
      {:ok, sql: read_migration!(@up_migration)}
    end

    test "backfills state='deleted' for legacy deleted=true rows, state='released' otherwise", %{
      sql: sql
    } do
      assert String.match?(
               sql,
               ~r/UPDATE\s+media_files\s+SET\s+state\s*=\s*'deleted'\s+WHERE\s+deleted\s*=\s*true/i
             ),
             "000022 must UPDATE media_files SET state = 'deleted' WHERE deleted = true"

      assert String.match?(
               sql,
               ~r/ADD\s+COLUMN\s+state\s+media_state\s+NOT\s+NULL\s+DEFAULT\s+'released'/i
             ),
             "000022 must default the new state column to 'released' (covers all other pre-existing rows)"
    end

    test "backfills storage_key to media_id for existing rows", %{sql: sql} do
      assert String.match?(
               sql,
               ~r/UPDATE\s+media_files\s+SET\s+storage_key\s*=\s*media_id\s+WHERE\s+storage_key\s+IS\s+NULL/i
             ),
             "000022 must UPDATE media_files SET storage_key = media_id WHERE storage_key IS NULL"
    end
  end

  # ---------------------------------------------------------------------------
  # Test 7 — media_state_transitions table shape
  # ---------------------------------------------------------------------------

  describe "media_state_transitions table shape" do
    setup do
      {:ok, sql: read_migration!(@up_migration)}
    end

    test "media_state_transitions table has the 8 exact expected columns with a media_id FK to media_files",
         %{sql: sql} do
      assert String.match?(sql, ~r/CREATE\s+TABLE\s+media_state_transitions\s*\(/i),
             "000022 must CREATE TABLE media_state_transitions"

      lines = media_state_transitions_column_lines(sql)

      assert length(lines) == 8,
             "media_state_transitions must have exactly 8 column definitions, got #{length(lines)}: #{inspect(lines)}"

      assert String.match?(sql, ~r/id\s+BIGSERIAL\s+PRIMARY\s+KEY/i),
             "media_state_transitions.id must be BIGSERIAL PRIMARY KEY"

      assert String.match?(
               sql,
               ~r/media_id\s+TEXT\s+NOT\s+NULL\s+REFERENCES\s+media_files\s*\(\s*media_id\s*\)/i
             ),
             "media_state_transitions.media_id must be TEXT NOT NULL REFERENCES media_files(media_id)"

      assert String.match?(sql, ~r/from_state\s+media_state\b/i),
             "media_state_transitions.from_state must be media_state (nullable)"

      assert String.match?(sql, ~r/to_state\s+media_state\s+NOT\s+NULL/i),
             "media_state_transitions.to_state must be media_state NOT NULL"

      assert String.match?(sql, ~r/actor_type\s+media_transition_actor_type\s+NOT\s+NULL/i),
             "media_state_transitions.actor_type must be media_transition_actor_type NOT NULL"

      assert String.match?(sql, ~r/actor_id\s+UUID\b/i),
             "media_state_transitions.actor_id must be UUID (nullable)"

      assert String.match?(sql, ~r/metadata\s+JSONB\b/i),
             "media_state_transitions.metadata must be JSONB (nullable)"

      assert String.match?(sql, ~r/inserted_at\s+TIMESTAMPTZ\s+NOT\s+NULL\s+DEFAULT\s+NOW\(\)/i),
             "media_state_transitions.inserted_at must be TIMESTAMPTZ NOT NULL DEFAULT NOW()"
    end
  end

  # ---------------------------------------------------------------------------
  # Test 8 / 9 — primary immutability guarantee (trigger)
  # ---------------------------------------------------------------------------

  describe "primary immutability trigger (ADR-031)" do
    setup do
      {:ok, sql: read_migration!(@up_migration)}
    end

    test "defines the media_state_transitions_no_mutate trigger as BEFORE UPDATE OR DELETE", %{
      sql: sql
    } do
      assert String.match?(
               sql,
               ~r/CREATE\s+TRIGGER\s+media_state_transitions_no_mutate\s+BEFORE\s+UPDATE\s+OR\s+DELETE\s+ON\s+media_state_transitions/i
             ),
             "000022 must CREATE TRIGGER media_state_transitions_no_mutate BEFORE UPDATE OR DELETE ON media_state_transitions"
    end

    test "trigger function raises SQLSTATE 23001 (restrict_violation)", %{sql: sql} do
      assert String.match?(
               sql,
               ~r/CREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION\s+media_state_transitions_immutable\s*\(\s*\)/i
             ),
             "000022 must define function media_state_transitions_immutable()"

      assert String.match?(sql, ~r/USING\s+ERRCODE\s*=\s*'restrict_violation'/i),
             "media_state_transitions_immutable() must RAISE EXCEPTION USING ERRCODE = 'restrict_violation' (SQLSTATE 23001)"
    end
  end

  # ---------------------------------------------------------------------------
  # Test 10 / 11 — secondary layer (RLS + REVOKE)
  # ---------------------------------------------------------------------------

  describe "secondary immutability layer (RLS + REVOKE, mirrors audit_log)" do
    setup do
      {:ok, sql: read_migration!(@up_migration)}
    end

    test "enables RLS and defines all 4 policies (insert, select, no_update, no_delete)", %{
      sql: sql
    } do
      assert String.match?(
               sql,
               ~r/ALTER\s+TABLE\s+media_state_transitions\s+ENABLE\s+ROW\s+LEVEL\s+SECURITY/i
             ),
             "000022 must ALTER TABLE media_state_transitions ENABLE ROW LEVEL SECURITY"

      assert String.match?(
               sql,
               ~r/CREATE\s+POLICY\s+media_state_transitions_insert\s+ON\s+media_state_transitions\s+FOR\s+INSERT\s+WITH\s+CHECK\s*\(\s*true\s*\)/i
             ),
             "000022 must define the media_state_transitions_insert policy"

      assert String.match?(
               sql,
               ~r/CREATE\s+POLICY\s+media_state_transitions_select\s+ON\s+media_state_transitions\s+FOR\s+SELECT\s+USING\s*\(\s*true\s*\)/i
             ),
             "000022 must define the media_state_transitions_select policy"

      assert String.match?(
               sql,
               ~r/CREATE\s+POLICY\s+media_state_transitions_no_update\s+ON\s+media_state_transitions\s+FOR\s+UPDATE\s+USING\s*\(\s*false\s*\)/i
             ),
             "000022 must define the media_state_transitions_no_update policy"

      assert String.match?(
               sql,
               ~r/CREATE\s+POLICY\s+media_state_transitions_no_delete\s+ON\s+media_state_transitions\s+FOR\s+DELETE\s+USING\s*\(\s*false\s*\)/i
             ),
             "000022 must define the media_state_transitions_no_delete policy"
    end

    test "REVOKEs UPDATE, DELETE ON media_state_transitions FROM nebu_app", %{sql: sql} do
      assert String.match?(
               sql,
               ~r/REVOKE\s+UPDATE\s*,\s*DELETE\s+ON\s+media_state_transitions\s+FROM\s+nebu_app/i
             ),
             "000022 must REVOKE UPDATE, DELETE ON media_state_transitions FROM nebu_app"
    end
  end

  # ---------------------------------------------------------------------------
  # Test 12 / 13 — grants (AC1/AC2-style, mirrors MigrationsGrantTest)
  # ---------------------------------------------------------------------------

  describe "grants (mirrors Nebu.Matrix.MigrationsGrantTest convention)" do
    setup do
      {:ok, sql: read_migration!(@up_migration)}
    end

    test "grants SELECT, INSERT, UPDATE, DELETE ON media_state_transitions TO nebu_app", %{
      sql: sql
    } do
      assert String.match?(
               sql,
               ~r/GRANT\s+SELECT\s*,\s*INSERT\s*,\s*UPDATE\s*,\s*DELETE\s+ON\s+media_state_transitions\s+TO\s+nebu_app/i
             ),
             "000022 must GRANT DML on media_state_transitions to nebu_app"
    end

    test "grants USAGE, SELECT ON SEQUENCE media_state_transitions_id_seq TO nebu_app", %{
      sql: sql
    } do
      assert String.match?(
               sql,
               ~r/GRANT\s+USAGE\s*,\s*SELECT\s+ON\s+SEQUENCE\s+media_state_transitions_id_seq\s+TO\s+nebu_app/i
             ),
             "000022 must GRANT USAGE, SELECT on media_state_transitions_id_seq to nebu_app"
    end
  end

  # ---------------------------------------------------------------------------
  # Test 14 — no SECURITY DEFINER function (regression guard, AC9)
  # ---------------------------------------------------------------------------

  describe "no SECURITY DEFINER purge function (AC9)" do
    setup do
      {:ok, sql: read_migration!(@up_migration)}
    end

    test "defines no SECURITY DEFINER function in this migration", %{sql: sql} do
      refute String.match?(sql, ~r/SECURITY\s+DEFINER/i),
             "000022 must NOT define a SECURITY DEFINER function (media_state_transitions retention is out of scope, epic Offene Entscheidung #5)"
    end
  end

  # ---------------------------------------------------------------------------
  # Test 15 — down migration contains no GRANT statement (AC4-style)
  # ---------------------------------------------------------------------------

  describe "down migration has no GRANT statement (AC4-style)" do
    test "000022 down migration contains no GRANT statement" do
      sql = read_migration!(@down_migration)

      refute String.match?(sql, ~r/GRANT\s+.+\s+TO\s+nebu_app/i),
             "000022_media_state_machine_foundation.down.sql must NOT contain GRANT statements"
    end
  end

  # ---------------------------------------------------------------------------
  # Test 15b — down migration drops everything in a dependency-safe order (AC11)
  # ---------------------------------------------------------------------------

  describe "down migration reverses the up migration in dependency-safe order (AC11)" do
    setup do
      {:ok, sql: read_migration!(@down_migration)}
    end

    test "drops the trigger", %{sql: sql} do
      assert String.match?(
               sql,
               ~r/DROP\s+TRIGGER\s+IF\s+EXISTS\s+media_state_transitions_no_mutate\s+ON\s+media_state_transitions/i
             ),
             "000022 down migration must DROP TRIGGER IF EXISTS media_state_transitions_no_mutate"
    end

    test "drops the trigger function", %{sql: sql} do
      assert String.match?(
               sql,
               ~r/DROP\s+FUNCTION\s+IF\s+EXISTS\s+media_state_transitions_immutable\s*\(\s*\)/i
             ),
             "000022 down migration must DROP FUNCTION IF EXISTS media_state_transitions_immutable()"
    end

    test "drops the media_state_transitions table with CASCADE", %{sql: sql} do
      assert String.match?(
               sql,
               ~r/DROP\s+TABLE\s+IF\s+EXISTS\s+media_state_transitions\s+CASCADE/i
             ),
             "000022 down migration must DROP TABLE IF EXISTS media_state_transitions CASCADE " <>
                 "(CASCADE also drops its FK/indexes)"
    end

    test "drops all 8 new media_files columns", %{sql: sql} do
      for column <- @new_media_files_columns do
        assert String.match?(sql, ~r/DROP\s+COLUMN\s+IF\s+EXISTS\s+#{column}\b/i),
               "000022 down migration must DROP COLUMN IF EXISTS #{column} from media_files"
      end
    end

    test "drops both new ENUM types", %{sql: sql} do
      assert String.match?(sql, ~r/DROP\s+TYPE\s+IF\s+EXISTS\s+media_state\b/i),
             "000022 down migration must DROP TYPE IF EXISTS media_state"

      assert String.match?(sql, ~r/DROP\s+TYPE\s+IF\s+EXISTS\s+media_transition_actor_type\b/i),
             "000022 down migration must DROP TYPE IF EXISTS media_transition_actor_type"
    end

    test "drops columns before dropping the ENUM types they reference (dependency-safe order)",
         %{sql: sql} do
      last_column_drop_idx =
        @new_media_files_columns
        |> Enum.map(fn column ->
          case Regex.run(~r/DROP\s+COLUMN\s+IF\s+EXISTS\s+#{column}\b/i, sql, return: :index) do
            [{idx, _len} | _] -> idx
            nil -> -1
          end
        end)
        |> Enum.max()

      media_state_type_drop_idx =
        case Regex.run(~r/DROP\s+TYPE\s+IF\s+EXISTS\s+media_state\b/i, sql, return: :index) do
          [{idx, _len} | _] -> idx
          nil -> -1
        end

      actor_type_drop_idx =
        case Regex.run(
               ~r/DROP\s+TYPE\s+IF\s+EXISTS\s+media_transition_actor_type\b/i,
               sql,
               return: :index
             ) do
          [{idx, _len} | _] -> idx
          nil -> -1
        end

      assert last_column_drop_idx >= 0 and media_state_type_drop_idx >= 0 and
               actor_type_drop_idx >= 0,
             "expected all DROP COLUMN and DROP TYPE statements to be present before " <>
               "checking their relative order"

      assert last_column_drop_idx < media_state_type_drop_idx,
             "every media_files DROP COLUMN must appear before DROP TYPE media_state " <>
               "(dropping the type first would error while the column still references it)"

      assert last_column_drop_idx < actor_type_drop_idx,
             "every media_files DROP COLUMN must appear before DROP TYPE media_transition_actor_type"
    end

    test "drops the table before dropping the ENUM types (dependency-safe order)", %{sql: sql} do
      table_drop_idx =
        case Regex.run(
               ~r/DROP\s+TABLE\s+IF\s+EXISTS\s+media_state_transitions\s+CASCADE/i,
               sql,
               return: :index
             ) do
          [{idx, _len} | _] -> idx
          nil -> -1
        end

      media_state_type_drop_idx =
        case Regex.run(~r/DROP\s+TYPE\s+IF\s+EXISTS\s+media_state\b/i, sql, return: :index) do
          [{idx, _len} | _] -> idx
          nil -> -1
        end

      assert table_drop_idx >= 0 and media_state_type_drop_idx >= 0,
             "expected both the table DROP and the media_state TYPE DROP to be present"

      assert table_drop_idx < media_state_type_drop_idx,
             "media_state_transitions must be dropped before DROP TYPE media_state " <>
               "(the table's columns reference this type)"
    end
  end
end
