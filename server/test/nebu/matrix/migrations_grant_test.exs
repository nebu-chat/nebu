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
    String.match?(
      sql,
      ~r/\bBIGSERIAL\b|\bSERIAL\b(?!IZABLE)|\bCREATE\s+SEQUENCE\b|\bGENERATED\s+ALWAYS\s+AS\s+IDENTITY\b/i
    )
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
  # AC1/AC2 — 000022: media_state_transitions needs DML + sequence GRANT
  # ---------------------------------------------------------------------------

  describe "AC1/AC2: 000022_media_state_machine_foundation.up.sql grants" do
    setup do
      {:ok, sql: read_migration!("000022_media_state_machine_foundation.up.sql")}
    end

    test "creates media_state_transitions table", %{sql: sql} do
      assert contains_create_table?(sql),
             "000022 must create the media_state_transitions table (pre-condition check)"
    end

    test "grants SELECT, INSERT, UPDATE, DELETE on media_state_transitions to nebu_app", %{
      sql: sql
    } do
      assert String.match?(
               sql,
               ~r/GRANT\s+SELECT\s*,\s*INSERT\s*,\s*UPDATE\s*,\s*DELETE\s+ON\s+media_state_transitions\s+TO\s+nebu_app/i
             ),
             "000022 must GRANT DML on media_state_transitions to nebu_app"
    end

    test "has SERIAL/BIGSERIAL columns", %{sql: sql} do
      assert has_serial_columns?(sql),
             "000022 must have SERIAL/BIGSERIAL columns (pre-condition check)"
    end

    test "grants USAGE, SELECT on media_state_transitions_id_seq to nebu_app", %{sql: sql} do
      assert String.match?(
               sql,
               ~r/GRANT\s+USAGE\s*,\s*SELECT\s+ON\s+SEQUENCE\s+media_state_transitions_id_seq\s+TO\s+nebu_app/i
             ),
             "000022 must GRANT USAGE, SELECT on media_state_transitions_id_seq to nebu_app"
    end
  end

  # ---------------------------------------------------------------------------
  # AC1/AC2 — 000023: media_config needs DML GRANT (no sequences)
  #
  # Security review (Kassandra, 2026-07-13, F-1 — HIGH): this exact migration
  # shipped WITHOUT a GRANT initially, and stayed green in CI/dev because the
  # dev docker-compose setup's ALTER DEFAULT PRIVILEGES masks the omission —
  # production (UpCloud managed PostgreSQL, no default-privileges compensation)
  # would have silently fail-opened media_config's security-relevant values
  # (mime_denylist, upload/scan size limits) to compile-time defaults. This
  # describe block is the regression guard closing that exact gap.
  # ---------------------------------------------------------------------------

  describe "AC1: 000023_media_config.up.sql DML grants" do
    setup do
      {:ok, sql: read_migration!("000023_media_config.up.sql")}
    end

    test "creates media_config table", %{sql: sql} do
      assert contains_create_table?(sql),
             "000023 must create the media_config table (pre-condition check)"
    end

    test "grants SELECT, INSERT, UPDATE, DELETE on media_config to nebu_app", %{sql: sql} do
      assert String.match?(
               sql,
               ~r/GRANT\s+SELECT\s*,\s*INSERT\s*,\s*UPDATE\s*,\s*DELETE\s+ON\s+media_config\s+TO\s+nebu_app/i
             ),
             "000023 must GRANT DML on media_config to nebu_app"
    end
  end

  # AC2 guard for 000023 — no sequences
  describe "AC2: 000023_media_config.up.sql has no SERIAL columns" do
    test "000023 has no SERIAL/BIGSERIAL columns so no sequence GRANT is needed" do
      sql = read_migration!("000023_media_config.up.sql")
      refute has_serial_columns?(sql),
             "000023 must have no SERIAL/BIGSERIAL columns (static consistency check)"
    end
  end

  # ---------------------------------------------------------------------------
  # AC1/AC2 — 000024: media_storage_config needs DML GRANT (no sequences)
  #
  # Added pre-dev test-review, cycle 1, for story 11a-storage-config-schema-
  # secrets: same F-1/HIGH class of gap Kassandra found in 9a's original
  # media_config migration (see the 000023 describe block above) — this
  # describe block is the regression guard for media_storage_config's own
  # GRANT, mirrored exactly.
  # ---------------------------------------------------------------------------

  describe "AC1: 000024_media_storage_config.up.sql DML grants" do
    setup do
      {:ok, sql: read_migration!("000024_media_storage_config.up.sql")}
    end

    test "creates media_storage_config table", %{sql: sql} do
      assert contains_create_table?(sql),
             "000024 must create the media_storage_config table (pre-condition check)"
    end

    test "grants SELECT, INSERT, UPDATE, DELETE on media_storage_config to nebu_app", %{
      sql: sql
    } do
      assert String.match?(
               sql,
               ~r/GRANT\s+SELECT\s*,\s*INSERT\s*,\s*UPDATE\s*,\s*DELETE\s+ON\s+media_storage_config\s+TO\s+nebu_app/i
             ),
             "000024 must GRANT DML on media_storage_config to nebu_app"
    end
  end

  # AC2 guard for 000024 — no sequences
  describe "AC2: 000024_media_storage_config.up.sql has no SERIAL columns" do
    test "000024 has no SERIAL/BIGSERIAL columns so no sequence GRANT is needed" do
      sql = read_migration!("000024_media_storage_config.up.sql")
      refute has_serial_columns?(sql),
             "000024 must have no SERIAL/BIGSERIAL columns (static consistency check)"
    end
  end

  # ---------------------------------------------------------------------------
  # AC1/AC2 — 000026: oban_jobs / oban_peers need DML + sequence GRANT
  #
  # media-security-admin-control/2e-reserved-upload-cleanup-cron bootstraps Oban
  # (see the migration's own header comment for why this lands here instead of
  # 4b). Mirrors the 000022 describe block: both new tables need an explicit
  # GRANT since production (UpCloud managed PostgreSQL) has no ALTER DEFAULT
  # PRIVILEGES to compensate for the missing one, and oban_jobs has a BIGSERIAL
  # id needing a sequence GRANT too (oban_peers' PK is a plain TEXT column).
  # ---------------------------------------------------------------------------

  describe "AC1/AC2: 000026_oban_jobs.up.sql grants" do
    setup do
      {:ok, sql: read_migration!("000026_oban_jobs.up.sql")}
    end

    test "creates oban_jobs and oban_peers tables", %{sql: sql} do
      assert contains_create_table?(sql),
             "000026 must create the oban_jobs/oban_peers tables (pre-condition check)"
    end

    test "grants SELECT, INSERT, UPDATE, DELETE on oban_jobs to nebu_app", %{sql: sql} do
      assert String.match?(
               sql,
               ~r/GRANT\s+SELECT\s*,\s*INSERT\s*,\s*UPDATE\s*,\s*DELETE\s+ON\s+oban_jobs\s+TO\s+nebu_app/i
             ),
             "000026 must GRANT DML on oban_jobs to nebu_app"
    end

    test "grants SELECT, INSERT, UPDATE, DELETE on oban_peers to nebu_app", %{sql: sql} do
      assert String.match?(
               sql,
               ~r/GRANT\s+SELECT\s*,\s*INSERT\s*,\s*UPDATE\s*,\s*DELETE\s+ON\s+oban_peers\s+TO\s+nebu_app/i
             ),
             "000026 must GRANT DML on oban_peers to nebu_app"
    end

    test "has SERIAL/BIGSERIAL columns (oban_jobs.id)", %{sql: sql} do
      assert has_serial_columns?(sql),
             "000026 must have SERIAL/BIGSERIAL columns (pre-condition check)"
    end

    test "grants USAGE, SELECT on oban_jobs_id_seq to nebu_app", %{sql: sql} do
      assert String.match?(
               sql,
               ~r/GRANT\s+USAGE\s*,\s*SELECT\s+ON\s+SEQUENCE\s+oban_jobs_id_seq\s+TO\s+nebu_app/i
             ),
             "000026 must GRANT USAGE, SELECT on oban_jobs_id_seq to nebu_app"
    end
  end

  describe "AC1/AC2: 000032_media_scan_stats.up.sql grants" do
    setup do
      {:ok, sql: read_migration!("000032_media_scan_stats.up.sql")}
    end

    test "creates media_scan_stats table", %{sql: sql} do
      assert contains_create_table?(sql),
             "000032 must create the media_scan_stats table (pre-condition check)"
    end

    test "grants SELECT, INSERT, UPDATE, DELETE on media_scan_stats to nebu_app", %{sql: sql} do
      assert String.match?(
               sql,
               ~r/GRANT\s+SELECT\s*,\s*INSERT\s*,\s*UPDATE\s*,\s*DELETE\s+ON\s+media_scan_stats\s+TO\s+nebu_app/i
             ),
             "000032 must GRANT DML on media_scan_stats to nebu_app"
    end

    test "has SERIAL/BIGSERIAL columns", %{sql: sql} do
      assert has_serial_columns?(sql),
             "000032 must have SERIAL/BIGSERIAL columns (pre-condition check)"
    end

    test "grants USAGE, SELECT on media_scan_stats_id_seq to nebu_app", %{sql: sql} do
      assert String.match?(
               sql,
               ~r/GRANT\s+USAGE\s*,\s*SELECT\s+ON\s+SEQUENCE\s+media_scan_stats_id_seq\s+TO\s+nebu_app/i
             ),
             "000032 must GRANT USAGE, SELECT on media_scan_stats_id_seq to nebu_app"
    end
  end

  # ---------------------------------------------------------------------------
  # AC1/AC2 — 000033: media_alerts needs a NARROWER (3-verb) DML grant +
  # sequence grant
  #
  # media-security-admin-control/10c-media-alerts-triggers: unlike every
  # other table in this file, `media_alerts`' own migration deliberately
  # grants only SELECT, INSERT, UPDATE — no DELETE — since alerts are opened
  # and auto-resolved (UPDATE) in place by the periodic checker but never
  # deleted by app code (see the story's Dev Agent Guardrails). This is the
  # exact epic gotcha flagged for this story (cf. 9a's/8a's own initial
  # missed-grant misses, see the 000023 describe block above): the grant
  # regex here MUST match the narrower 3-verb set, not copy 000032's 4-verb
  # GRANT literally — and must additionally assert DELETE is NOT granted, so
  # a future edit that "helpfully" widens the grant back to the AC1/AC2
  # 4-verb boilerplate other tables use gets caught here immediately.
  #
  # `media_alerts.id` uses `BIGINT GENERATED ALWAYS AS IDENTITY` (not
  # BIGSERIAL) — Postgres still creates an implicit `media_alerts_id_seq`
  # backing sequence for an identity column, so the USAGE/SELECT sequence
  # grant is still required; `has_serial_columns?/1` above has been extended
  # to also recognize `GENERATED ALWAYS AS IDENTITY` for this reason.
  # ---------------------------------------------------------------------------

  describe "AC1/AC2: 000033_media_alerts.up.sql grants" do
    setup do
      {:ok, sql: read_migration!("000033_media_alerts.up.sql")}
    end

    test "creates media_alerts table", %{sql: sql} do
      assert contains_create_table?(sql),
             "000033 must create the media_alerts table (pre-condition check)"
    end

    test "grants SELECT, INSERT, UPDATE (NOT DELETE) on media_alerts to nebu_app", %{sql: sql} do
      assert String.match?(
               sql,
               ~r/GRANT\s+SELECT\s*,\s*INSERT\s*,\s*UPDATE\s+ON\s+media_alerts\s+TO\s+nebu_app/i
             ),
             "000033 must GRANT exactly SELECT, INSERT, UPDATE (no DELETE) on media_alerts to nebu_app"

      refute String.match?(sql, ~r/GRANT[^;]*\bDELETE\b[^;]*\bmedia_alerts\b/i),
             "000033 must NOT grant DELETE on media_alerts to nebu_app — alerts are opened/updated " <>
               "in place but never deleted by app code (Dev Agent Guardrails)"
    end

    test "has SERIAL/BIGSERIAL/IDENTITY columns", %{sql: sql} do
      assert has_serial_columns?(sql),
             "000033 must have an auto-incrementing id column (pre-condition check)"
    end

    test "grants USAGE, SELECT on media_alerts_id_seq to nebu_app", %{sql: sql} do
      assert String.match?(
               sql,
               ~r/GRANT\s+USAGE\s*,\s*SELECT\s+ON\s+SEQUENCE\s+media_alerts_id_seq\s+TO\s+nebu_app/i
             ),
             "000033 must GRANT USAGE, SELECT on media_alerts_id_seq to nebu_app"
    end

    # MINOR-1 (test-review, folded in during the ATDD-fix cycle): AC1's full
    # schema shape (CHECK list, media_alert_severity ENUM, FK to media_files,
    # partial unique index) was previously only proven indirectly via the
    # worker/AT8 functional tests. Direct DDL assertions fail faster/more
    # legibly than "concurrency test mysteriously raised".
    test "alert_type is a CHECK-constrained TEXT column covering all four alert types", %{
      sql: sql
    } do
      assert String.match?(sql, ~r/alert_type\s+TEXT\s+NOT\s+NULL\s+CHECK/i),
             "000033 must constrain alert_type via a TEXT + CHECK column, not an ENUM " <>
               "(this list is expected to grow; ENUM ADD VALUE mid-transaction restrictions " <>
               "were the reason 4a had to work around them for scan_failed)"

      for alert_type <- ~w(clamav_disconnected signature_stale backlog_depth scan_failed_rate) do
        assert String.contains?(sql, alert_type),
               "000033's alert_type CHECK list must include '#{alert_type}'"
      end
    end

    test "creates the media_alert_severity ENUM with warning and critical", %{sql: sql} do
      assert String.match?(sql, ~r/CREATE\s+TYPE\s+media_alert_severity\s+AS\s+ENUM/i),
             "000033 must create the media_alert_severity ENUM type"

      assert String.contains?(sql, "'warning'") and String.contains?(sql, "'critical'"),
             "media_alert_severity must have exactly the warning/critical values"
    end

    test "media_id is a nullable FK to media_files", %{sql: sql} do
      # Dev-story correction (verified empirically against a real Postgres,
      # per this epic's own "verify the illustrative SQL, don't just trust
      # it" precedent, cf. media_scan_stats_rollup_worker.ex's own documented
      # LEAD-window-function bug fix): the story's own illustrative SQL types
      # media_id as UUID, but media_files.media_id (000001_init.up.sql) is
      # TEXT, not UUID — a UUID FK to a TEXT primary key fails migration
      # outright with Postgres error 42804 ("incompatible types: uuid and
      # text"). The assertion's strength (nullable FK to media_files(media_id))
      # is unchanged; only the literal column type is corrected to match
      # reality.
      assert String.match?(
               sql,
               ~r/media_id\s+TEXT\s+NULL\s+REFERENCES\s+media_files\s*\(\s*media_id\s*\)/i
             ),
             "000033's media_id column must be a nullable TEXT FK to media_files(media_id) — " <>
               "three of the four alert types are pipeline-level and always carry NULL"
    end

    test "has a partial unique index preventing duplicate open alerts (AC5)", %{sql: sql} do
      assert String.match?(
               sql,
               ~r/CREATE\s+UNIQUE\s+INDEX\s+media_alerts_open_unique_idx\s+ON\s+media_alerts/i
             ),
             "000033 must create media_alerts_open_unique_idx — the belt-and-suspenders guard " <>
               "for AC5's idempotent check-and-open under real concurrency (see AT8)"

      assert String.match?(sql, ~r/WHERE\s+resolved_at\s+IS\s+NULL/i),
             "media_alerts_open_unique_idx must be a PARTIAL index scoped to open " <>
               "(resolved_at IS NULL) rows — an unscoped unique index would wrongly forbid " <>
               "re-opening a resolved-then-recurring alert (AT9)"
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
      "000012_device_management_uia.down.sql",
      "000022_media_state_machine_foundation.down.sql",
      "000023_media_config.down.sql",
      "000024_media_storage_config.down.sql",
      "000026_oban_jobs.down.sql",
      "000028_media_scan_failed_state.down.sql",
      "000029_media_state_transitions_actor_id_text.down.sql",
      "000030_media_admin_override_role.down.sql",
      "000031_events_content_gin_index.down.sql",
      "000032_media_scan_stats.down.sql",
      "000033_media_alerts.down.sql"
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
