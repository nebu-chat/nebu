defmodule Nebu.Matrix.MigrationsGrantTest do
  @moduledoc """
  Static analysis tests for database migration GRANT correctness.

  In the Nebu UpCloud deployment two PostgreSQL roles exist:
    - `nebu_migrate` — DDL role, table owner, runs migrations
    - `nebu_app`     — runtime role, must have DML access

  Migration 000001 ends with `GRANT ... ON ALL TABLES ... TO nebu_app` which
  covers every table created in that file. Post-squash migrations (000002+)
  that create new tables must individually GRANT DML access to nebu_app,
  because in production (UpCloud managed PostgreSQL) no ALTER DEFAULT PRIVILEGES
  compensates (unlike the dev docker-compose setup).

  These tests parse the SQL files and assert on their content.
  No database connection is required — this is purely static analysis.

  AC1 — Every post-squash migration that creates tables includes a GRANT to nebu_app.
  AC2 — Sequences are granted in migrations with SERIAL/BIGSERIAL columns.
  AC3 — Migration 000001 GRANT is unchanged (regression guard).
  AC4 — Down migrations do not contain GRANT statements.
  """

  use ExUnit.Case, async: true

  @migrations_dir Path.expand("../../../priv/migrations", __DIR__)

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp migration_path(filename) do
    Path.join(@migrations_dir, filename)
  end

  defp read_migration!(filename) do
    path = migration_path(filename)
    File.read!(path)
  end

  defp contains_create_table?(sql) do
    String.match?(sql, ~r/CREATE\s+TABLE\s+IF\s+NOT\s+EXISTS|CREATE\s+TABLE\b/i)
  end

  defp has_serial_columns?(sql) do
    String.match?(sql, ~r/\bBIGSERIAL\b|\bSERIAL\b(?!IZABLE)|\bCREATE\s+SEQUENCE\b/i)
  end

  defp has_any_grant_to_nebu_app?(sql) do
    String.match?(sql, ~r/GRANT\s+.+\s+TO\s+nebu_app/i)
  end

  # ---------------------------------------------------------------------------
  # AC3 — Migration 000001 GRANT is unchanged (regression guard)
  # ---------------------------------------------------------------------------

  describe "AC3: migration 000001 GRANT regression guard" do
    test "000001_init.up.sql contains GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES to nebu_app" do
      sql = read_migration!("000001_init.up.sql")

      assert String.contains?(
               sql,
               "GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO nebu_app;"
             ),
             "000001_init.up.sql must retain the blanket GRANT on ALL TABLES to nebu_app"
    end

    test "000001_init.up.sql contains GRANT USAGE, SELECT ON ALL SEQUENCES to nebu_app" do
      sql = read_migration!("000001_init.up.sql")

      assert String.contains?(
               sql,
               "GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO nebu_app;"
             ),
             "000001_init.up.sql must retain the blanket GRANT on ALL SEQUENCES to nebu_app"
    end
  end

  # ---------------------------------------------------------------------------
  # AC1 — 000002: tables need DML GRANT
  # ---------------------------------------------------------------------------

  describe "AC1: 000002_add_missing_structures.up.sql DML grants" do
    setup do
      {:ok, sql: read_migration!("000002_add_missing_structures.up.sql")}
    end

    test "creates tables", %{sql: sql} do
      assert contains_create_table?(sql),
             "000002 must create tables (pre-condition check)"
    end

    test "grants SELECT, INSERT, UPDATE, DELETE on matrix_sessions to nebu_app", %{sql: sql} do
      assert String.match?(
               sql,
               ~r/GRANT\s+SELECT\s*,\s*INSERT\s*,\s*UPDATE\s*,\s*DELETE\s+ON\s+matrix_sessions\s+TO\s+nebu_app/i
             ),
             "000002 must GRANT DML on matrix_sessions to nebu_app"
    end

    test "grants SELECT, INSERT, UPDATE, DELETE on audit_log to nebu_app", %{sql: sql} do
      assert String.match?(
               sql,
               ~r/GRANT\s+SELECT\s*,\s*INSERT\s*,\s*UPDATE\s*,\s*DELETE\s+ON\s+audit_log\s+TO\s+nebu_app/i
             ),
             "000002 must GRANT DML on audit_log to nebu_app"
    end

    test "grants SELECT, INSERT, UPDATE, DELETE on compliance_requests to nebu_app", %{sql: sql} do
      assert String.match?(
               sql,
               ~r/GRANT\s+SELECT\s*,\s*INSERT\s*,\s*UPDATE\s*,\s*DELETE\s+ON\s+compliance_requests\s+TO\s+nebu_app/i
             ),
             "000002 must GRANT DML on compliance_requests to nebu_app"
    end

    test "grants SELECT, INSERT, UPDATE, DELETE on compliance_sessions to nebu_app", %{sql: sql} do
      assert String.match?(
               sql,
               ~r/GRANT\s+SELECT\s*,\s*INSERT\s*,\s*UPDATE\s*,\s*DELETE\s+ON\s+compliance_sessions\s+TO\s+nebu_app/i
             ),
             "000002 must GRANT DML on compliance_sessions to nebu_app"
    end

    test "grants SELECT, INSERT, UPDATE, DELETE on room_account_data to nebu_app", %{sql: sql} do
      assert String.match?(
               sql,
               ~r/GRANT\s+SELECT\s*,\s*INSERT\s*,\s*UPDATE\s*,\s*DELETE\s+ON\s+room_account_data\s+TO\s+nebu_app/i
             ),
             "000002 must GRANT DML on room_account_data to nebu_app"
    end

    test "grants SELECT, INSERT, UPDATE, DELETE on notifications to nebu_app", %{sql: sql} do
      assert String.match?(
               sql,
               ~r/GRANT\s+SELECT\s*,\s*INSERT\s*,\s*UPDATE\s*,\s*DELETE\s+ON\s+notifications\s+TO\s+nebu_app/i
             ),
             "000002 must GRANT DML on notifications to nebu_app"
    end

    test "grants SELECT, INSERT, UPDATE, DELETE on push_rules to nebu_app", %{sql: sql} do
      assert String.match?(
               sql,
               ~r/GRANT\s+SELECT\s*,\s*INSERT\s*,\s*UPDATE\s*,\s*DELETE\s+ON\s+push_rules\s+TO\s+nebu_app/i
             ),
             "000002 must GRANT DML on push_rules to nebu_app"
    end

    test "grants SELECT, INSERT, UPDATE, DELETE on pushers to nebu_app", %{sql: sql} do
      assert String.match?(
               sql,
               ~r/GRANT\s+SELECT\s*,\s*INSERT\s*,\s*UPDATE\s*,\s*DELETE\s+ON\s+pushers\s+TO\s+nebu_app/i
             ),
             "000002 must GRANT DML on pushers to nebu_app"
    end

    test "grants SELECT, INSERT, UPDATE, DELETE on role_overrides to nebu_app", %{sql: sql} do
      assert String.match?(
               sql,
               ~r/GRANT\s+SELECT\s*,\s*INSERT\s*,\s*UPDATE\s*,\s*DELETE\s+ON\s+role_overrides\s+TO\s+nebu_app/i
             ),
             "000002 must GRANT DML on role_overrides to nebu_app"
    end

    test "grants SELECT, INSERT, UPDATE, DELETE on room_defaults to nebu_app", %{sql: sql} do
      assert String.match?(
               sql,
               ~r/GRANT\s+SELECT\s*,\s*INSERT\s*,\s*UPDATE\s*,\s*DELETE\s+ON\s+room_defaults\s+TO\s+nebu_app/i
             ),
             "000002 must GRANT DML on room_defaults to nebu_app"
    end

    test "grants SELECT, INSERT, UPDATE, DELETE on forgotten_rooms to nebu_app", %{sql: sql} do
      assert String.match?(
               sql,
               ~r/GRANT\s+SELECT\s*,\s*INSERT\s*,\s*UPDATE\s*,\s*DELETE\s+ON\s+forgotten_rooms\s+TO\s+nebu_app/i
             ),
             "000002 must GRANT DML on forgotten_rooms to nebu_app"
    end
  end

  # ---------------------------------------------------------------------------
  # AC2 — 000002: sequences need GRANT (has BIGSERIAL/SERIAL columns)
  # ---------------------------------------------------------------------------

  describe "AC2: 000002_add_missing_structures.up.sql sequence grants" do
    setup do
      {:ok, sql: read_migration!("000002_add_missing_structures.up.sql")}
    end

    test "has SERIAL/BIGSERIAL columns", %{sql: sql} do
      assert has_serial_columns?(sql),
             "000002 must have SERIAL/BIGSERIAL columns (pre-condition check)"
    end

    test "grants USAGE, SELECT on audit_log_id_seq to nebu_app", %{sql: sql} do
      assert String.match?(
               sql,
               ~r/GRANT\s+USAGE\s*,\s*SELECT\s+ON\s+SEQUENCE\s+audit_log_id_seq\s+TO\s+nebu_app/i
             ),
             "000002 must GRANT USAGE, SELECT on audit_log_id_seq to nebu_app"
    end

    test "grants USAGE, SELECT on notifications_id_seq to nebu_app", %{sql: sql} do
      assert String.match?(
               sql,
               ~r/GRANT\s+USAGE\s*,\s*SELECT\s+ON\s+SEQUENCE\s+notifications_id_seq\s+TO\s+nebu_app/i
             ),
             "000002 must GRANT USAGE, SELECT on notifications_id_seq to nebu_app"
    end

    test "grants USAGE, SELECT on push_rules_id_seq to nebu_app", %{sql: sql} do
      assert String.match?(
               sql,
               ~r/GRANT\s+USAGE\s*,\s*SELECT\s+ON\s+SEQUENCE\s+push_rules_id_seq\s+TO\s+nebu_app/i
             ),
             "000002 must GRANT USAGE, SELECT on push_rules_id_seq to nebu_app"
    end

    test "grants USAGE, SELECT on pushers_id_seq to nebu_app", %{sql: sql} do
      assert String.match?(
               sql,
               ~r/GRANT\s+USAGE\s*,\s*SELECT\s+ON\s+SEQUENCE\s+pushers_id_seq\s+TO\s+nebu_app/i
             ),
             "000002 must GRANT USAGE, SELECT on pushers_id_seq to nebu_app"
    end

    test "grants USAGE, SELECT on room_defaults_id_seq to nebu_app", %{sql: sql} do
      assert String.match?(
               sql,
               ~r/GRANT\s+USAGE\s*,\s*SELECT\s+ON\s+SEQUENCE\s+room_defaults_id_seq\s+TO\s+nebu_app/i
             ),
             "000002 must GRANT USAGE, SELECT on room_defaults_id_seq to nebu_app"
    end
  end

  # ---------------------------------------------------------------------------
  # AC1 — 000006: auto_join_opt_outs needs DML GRANT (no sequences)
  # ---------------------------------------------------------------------------

  describe "AC1: 000006_auto_join_opt_outs.up.sql DML grants" do
    setup do
      {:ok, sql: read_migration!("000006_auto_join_opt_outs.up.sql")}
    end

    test "creates auto_join_opt_outs table", %{sql: sql} do
      assert contains_create_table?(sql),
             "000006 must create the auto_join_opt_outs table (pre-condition check)"
    end

    test "grants SELECT, INSERT, UPDATE, DELETE on auto_join_opt_outs to nebu_app", %{sql: sql} do
      assert String.match?(
               sql,
               ~r/GRANT\s+SELECT\s*,\s*INSERT\s*,\s*UPDATE\s*,\s*DELETE\s+ON\s+auto_join_opt_outs\s+TO\s+nebu_app/i
             ),
             "000006 must GRANT DML on auto_join_opt_outs to nebu_app"
    end
  end

  # AC2 guard for 000006 — no sequences
  describe "AC2: 000006_auto_join_opt_outs.up.sql has no SERIAL columns" do
    test "000006 has no SERIAL/BIGSERIAL columns so no sequence GRANT is needed" do
      sql = read_migration!("000006_auto_join_opt_outs.up.sql")
      refute has_serial_columns?(sql),
             "000006 must have no SERIAL/BIGSERIAL columns (static consistency check)"
    end
  end

  # ---------------------------------------------------------------------------
  # AC1 — 000008: room_aliases needs DML GRANT (no sequences)
  # ---------------------------------------------------------------------------

  describe "AC1: 000008_room_aliases.up.sql DML grants" do
    setup do
      {:ok, sql: read_migration!("000008_room_aliases.up.sql")}
    end

    test "creates room_aliases table", %{sql: sql} do
      assert contains_create_table?(sql),
             "000008 must create the room_aliases table (pre-condition check)"
    end

    test "grants SELECT, INSERT, UPDATE, DELETE on room_aliases to nebu_app", %{sql: sql} do
      assert String.match?(
               sql,
               ~r/GRANT\s+SELECT\s*,\s*INSERT\s*,\s*UPDATE\s*,\s*DELETE\s+ON\s+room_aliases\s+TO\s+nebu_app/i
             ),
             "000008 must GRANT DML on room_aliases to nebu_app"
    end
  end

  # AC2 guard for 000008 — no sequences
  describe "AC2: 000008_room_aliases.up.sql has no SERIAL columns" do
    test "000008 has no SERIAL/BIGSERIAL columns so no sequence GRANT is needed" do
      sql = read_migration!("000008_room_aliases.up.sql")
      refute has_serial_columns?(sql),
             "000008 must have no SERIAL/BIGSERIAL columns (static consistency check)"
    end
  end

  # ---------------------------------------------------------------------------
  # AC1 — 000009: device_keys tables need DML GRANT (no sequences)
  # ---------------------------------------------------------------------------

  describe "AC1: 000009_device_keys.up.sql DML grants" do
    setup do
      {:ok, sql: read_migration!("000009_device_keys.up.sql")}
    end

    test "creates device_keys table", %{sql: sql} do
      assert contains_create_table?(sql),
             "000009 must create tables (pre-condition check)"
    end

    test "grants SELECT, INSERT, UPDATE, DELETE on device_keys to nebu_app", %{sql: sql} do
      assert String.match?(
               sql,
               ~r/GRANT\s+SELECT\s*,\s*INSERT\s*,\s*UPDATE\s*,\s*DELETE\s+ON\s+device_keys\s+TO\s+nebu_app/i
             ),
             "000009 must GRANT DML on device_keys to nebu_app"
    end

    test "grants SELECT, INSERT, UPDATE, DELETE on device_one_time_keys to nebu_app", %{sql: sql} do
      assert String.match?(
               sql,
               ~r/GRANT\s+SELECT\s*,\s*INSERT\s*,\s*UPDATE\s*,\s*DELETE\s+ON\s+device_one_time_keys\s+TO\s+nebu_app/i
             ),
             "000009 must GRANT DML on device_one_time_keys to nebu_app"
    end

    test "grants SELECT, INSERT, UPDATE, DELETE on device_fallback_keys to nebu_app", %{sql: sql} do
      assert String.match?(
               sql,
               ~r/GRANT\s+SELECT\s*,\s*INSERT\s*,\s*UPDATE\s*,\s*DELETE\s+ON\s+device_fallback_keys\s+TO\s+nebu_app/i
             ),
             "000009 must GRANT DML on device_fallback_keys to nebu_app"
    end
  end

  # AC2 guard for 000009 — no sequences
  describe "AC2: 000009_device_keys.up.sql has no SERIAL columns" do
    test "000009 has no SERIAL/BIGSERIAL columns so no sequence GRANT is needed" do
      sql = read_migration!("000009_device_keys.up.sql")
      refute has_serial_columns?(sql),
             "000009 must have no SERIAL/BIGSERIAL columns (static consistency check)"
    end
  end

  # ---------------------------------------------------------------------------
  # AC1 — 000010: devices table needs DML GRANT (no sequences)
  # ---------------------------------------------------------------------------

  describe "AC1: 000010_devices.up.sql DML grants" do
    setup do
      {:ok, sql: read_migration!("000010_devices.up.sql")}
    end

    test "creates devices table", %{sql: sql} do
      assert contains_create_table?(sql),
             "000010 must create the devices table (pre-condition check)"
    end

    test "grants SELECT, INSERT, UPDATE, DELETE on devices to nebu_app", %{sql: sql} do
      assert String.match?(
               sql,
               ~r/GRANT\s+SELECT\s*,\s*INSERT\s*,\s*UPDATE\s*,\s*DELETE\s+ON\s+devices\s+TO\s+nebu_app/i
             ),
             "000010 must GRANT DML on devices to nebu_app"
    end
  end

  # AC2 guard for 000010 — no sequences
  describe "AC2: 000010_devices.up.sql has no SERIAL columns" do
    test "000010 has no SERIAL/BIGSERIAL columns so no sequence GRANT is needed" do
      sql = read_migration!("000010_devices.up.sql")
      refute has_serial_columns?(sql),
             "000010 must have no SERIAL/BIGSERIAL columns (static consistency check)"
    end
  end

  # ---------------------------------------------------------------------------
  # AC1 — 000011: jwt_device_bindings needs DML GRANT (no sequences)
  # ---------------------------------------------------------------------------

  describe "AC1: 000011_jwt_device_bindings.up.sql DML grants" do
    setup do
      {:ok, sql: read_migration!("000011_jwt_device_bindings.up.sql")}
    end

    test "creates jwt_device_bindings table", %{sql: sql} do
      assert contains_create_table?(sql),
             "000011 must create the jwt_device_bindings table (pre-condition check)"
    end

    test "grants SELECT, INSERT, UPDATE, DELETE on jwt_device_bindings to nebu_app", %{sql: sql} do
      assert String.match?(
               sql,
               ~r/GRANT\s+SELECT\s*,\s*INSERT\s*,\s*UPDATE\s*,\s*DELETE\s+ON\s+jwt_device_bindings\s+TO\s+nebu_app/i
             ),
             "000011 must GRANT DML on jwt_device_bindings to nebu_app"
    end
  end

  # AC2 guard for 000011 — no sequences
  describe "AC2: 000011_jwt_device_bindings.up.sql has no SERIAL columns" do
    test "000011 has no SERIAL/BIGSERIAL columns so no sequence GRANT is needed" do
      sql = read_migration!("000011_jwt_device_bindings.up.sql")
      refute has_serial_columns?(sql),
             "000011 must have no SERIAL/BIGSERIAL columns (static consistency check)"
    end
  end

  # ---------------------------------------------------------------------------
  # AC1 — 000012: uia_sessions needs DML GRANT (no sequences)
  # ---------------------------------------------------------------------------

  describe "AC1: 000012_device_management_uia.up.sql DML grants" do
    setup do
      {:ok, sql: read_migration!("000012_device_management_uia.up.sql")}
    end

    test "creates uia_sessions table", %{sql: sql} do
      assert contains_create_table?(sql),
             "000012 must create the uia_sessions table (pre-condition check)"
    end

    test "grants SELECT, INSERT, UPDATE, DELETE on uia_sessions to nebu_app", %{sql: sql} do
      assert String.match?(
               sql,
               ~r/GRANT\s+SELECT\s*,\s*INSERT\s*,\s*UPDATE\s*,\s*DELETE\s+ON\s+uia_sessions\s+TO\s+nebu_app/i
             ),
             "000012 must GRANT DML on uia_sessions to nebu_app"
    end
  end

  # AC2 guard for 000012 — no sequences
  describe "AC2: 000012_device_management_uia.up.sql has no SERIAL columns" do
    test "000012 has no SERIAL/BIGSERIAL columns so no sequence GRANT is needed" do
      sql = read_migration!("000012_device_management_uia.up.sql")
      refute has_serial_columns?(sql),
             "000012 must have no SERIAL/BIGSERIAL columns (static consistency check)"
    end
  end

  # ---------------------------------------------------------------------------
  # AC4 — Down migrations must NOT contain GRANT statements
  # ---------------------------------------------------------------------------

  describe "AC4: down migrations must not contain GRANT statements" do
    @down_migrations [
      "000002_add_missing_structures.down.sql",
      "000006_auto_join_opt_outs.down.sql",
      "000008_room_aliases.down.sql",
      "000009_device_keys.down.sql",
      "000010_devices.down.sql",
      "000011_jwt_device_bindings.down.sql",
      "000012_device_management_uia.down.sql"
    ]

    for filename <- @down_migrations do
      test "#{filename} contains no GRANT to nebu_app" do
        sql = read_migration!(unquote(filename))

        refute has_any_grant_to_nebu_app?(sql),
               "#{unquote(filename)} must NOT contain GRANT statements (rollback drops tables, grants are moot)"
      end
    end
  end
end
