defmodule Nebu.Admin.MigrationOidcScopesMutableTest do
  @moduledoc """
  RED-phase ATDD test for story `oidc-scopes-configurable`, AC1.

  ## What is under test

  Migration `000013_config_oidc_scopes_mutable.up.sql` must:
    - DROP the existing `config_update_mutable` policy on `server_config`.
    - Re-CREATE it with `'matrix_oidc_extra_scopes'` and `'admin_oidc_extra_scopes'`
      added to the `USING (key IN (...))` allowlist.
    - Be idempotent (running the up migration twice does not error).

  The corresponding `.down.sql` must restore the policy WITHOUT the two new scope keys.

  This test verifies the migration file EXISTS and contains the expected SQL content
  (no live DB required for content inspection; integration DB tests are tagged
  `:integration` and run under `make test-integration`).

  ## Pattern

  Mirrors `server/test/nebu/release_test.exs` which validates migration file contents.
  The migration must follow the pattern of `000007_config_refresh_mode_mutable.up.sql`:
    * `DROP POLICY IF EXISTS config_update_mutable ON server_config;`
    * `CREATE POLICY config_update_mutable ON server_config ...`
    * Key list includes BOTH `'matrix_oidc_extra_scopes'` AND `'admin_oidc_extra_scopes'`.

  The `.down.sql` must contain the policy WITHOUT those two keys (same allowlist as
  migration 000007, which is the immediate predecessor for the scope-mutable policy).

  ## Why RED

  `server/priv/migrations/000013_config_oidc_scopes_mutable.up.sql` does NOT exist yet.
  `File.read!` raises `Enoent` → test fails.
  """
  use ExUnit.Case, async: true

  @migrations_dir Path.join([
                    __DIR__,
                    "..",
                    "..",
                    "..",
                    "priv",
                    "migrations"
                  ])
                  |> Path.expand()

  @up_file Path.join(@migrations_dir, "000013_config_oidc_scopes_mutable.up.sql")
  @down_file Path.join(@migrations_dir, "000013_config_oidc_scopes_mutable.down.sql")

  # ════════════════════════════════════════════════════════════════════════════
  # AC1 — up.sql file exists and contains expected content
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC1: 000013_config_oidc_scopes_mutable.up.sql" do
    test "migration up file exists" do
      assert File.exists?(@up_file),
             "Migration file missing: #{@up_file}"
    end

    test "up migration drops and recreates config_update_mutable policy" do
      sql = File.read!(@up_file)

      assert sql =~ "DROP POLICY IF EXISTS config_update_mutable ON server_config",
             "up.sql must DROP config_update_mutable policy (idempotent); got:\n#{sql}"

      assert sql =~ "CREATE POLICY config_update_mutable ON server_config",
             "up.sql must CREATE config_update_mutable policy; got:\n#{sql}"
    end

    test "up migration policy includes matrix_oidc_extra_scopes" do
      sql = File.read!(@up_file)

      assert sql =~ "'matrix_oidc_extra_scopes'",
             "up.sql must include 'matrix_oidc_extra_scopes' in the policy USING clause; got:\n#{sql}"
    end

    test "up migration policy includes admin_oidc_extra_scopes" do
      sql = File.read!(@up_file)

      assert sql =~ "'admin_oidc_extra_scopes'",
             "up.sql must include 'admin_oidc_extra_scopes' in the policy USING clause; got:\n#{sql}"
    end

    test "up migration policy still includes all previous refresh_mode keys" do
      sql = File.read!(@up_file)

      assert sql =~ "'matrix_oidc_refresh_mode'",
             "up.sql must retain 'matrix_oidc_refresh_mode' from migration 000007; got:\n#{sql}"

      assert sql =~ "'admin_oidc_refresh_mode'",
             "up.sql must retain 'admin_oidc_refresh_mode' from migration 000007; got:\n#{sql}"
    end

    test "up migration is FOR UPDATE" do
      sql = File.read!(@up_file)

      assert sql =~ "FOR UPDATE",
             "config_update_mutable policy must be FOR UPDATE; got:\n#{sql}"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC1 — down.sql file exists and restores policy without new scope keys
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC1: 000013_config_oidc_scopes_mutable.down.sql" do
    test "migration down file exists" do
      assert File.exists?(@down_file),
             "Migration down file missing: #{@down_file}"
    end

    test "down migration drops and recreates policy without new scope keys" do
      sql = File.read!(@down_file)

      assert sql =~ "DROP POLICY IF EXISTS config_update_mutable ON server_config",
             "down.sql must DROP config_update_mutable policy; got:\n#{sql}"

      assert sql =~ "CREATE POLICY config_update_mutable ON server_config",
             "down.sql must CREATE config_update_mutable policy; got:\n#{sql}"
    end

    test "down migration does NOT include matrix_oidc_extra_scopes" do
      sql = File.read!(@down_file)

      refute sql =~ "'matrix_oidc_extra_scopes'",
             "down.sql must NOT include 'matrix_oidc_extra_scopes' (reverts to pre-story state); got:\n#{sql}"
    end

    test "down migration does NOT include admin_oidc_extra_scopes" do
      sql = File.read!(@down_file)

      refute sql =~ "'admin_oidc_extra_scopes'",
             "down.sql must NOT include 'admin_oidc_extra_scopes' (reverts to pre-story state); got:\n#{sql}"
    end

    test "down migration retains refresh_mode keys (reverts only new scope keys)" do
      sql = File.read!(@down_file)

      assert sql =~ "'matrix_oidc_refresh_mode'",
             "down.sql must retain 'matrix_oidc_refresh_mode'; got:\n#{sql}"

      assert sql =~ "'admin_oidc_refresh_mode'",
             "down.sql must retain 'admin_oidc_refresh_mode'; got:\n#{sql}"
    end
  end
end
