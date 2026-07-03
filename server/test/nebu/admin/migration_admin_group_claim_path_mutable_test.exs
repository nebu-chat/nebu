defmodule Nebu.Admin.MigrationAdminGroupClaimPathMutableTest do
  @moduledoc """
  Static-analysis test for story `scope-admin-claim-to-path`, AC1 (code-review MINOR m3
  fix — cycle 1 flagged migration 000016 as lacking the dedicated content test its
  siblings have).

  ## What is under test

  Migration `000016_config_admin_group_claim_path.up.sql` must:
    - DROP the existing `config_update_mutable` policy on `server_config`.
    - Re-CREATE it with `'admin_group_claim_path'` added to the `USING (key IN (...))`
      allowlist.
    - Retain every key already present in migration 000013
      (`config_oidc_scopes_mutable`), the immediate predecessor policy version.

  The corresponding `.down.sql` must restore the policy WITHOUT the new key (reverting
  to exactly migration 000013's allowlist).

  This test verifies the migration file EXISTS and contains the expected SQL content (no
  live DB required for content inspection; integration DB tests are tagged `:integration`
  and run under `make test-integration`).

  ## Pattern

  Mirrors `migration_oidc_scopes_mutable_test.exs` (migration 000013), which mirrors
  `server/test/nebu/release_test.exs`'s general migration-content-inspection approach.
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

  @up_file Path.join(@migrations_dir, "000016_config_admin_group_claim_path.up.sql")
  @down_file Path.join(@migrations_dir, "000016_config_admin_group_claim_path.down.sql")

  # Every key present in migration 000013 (config_oidc_scopes_mutable) — 000016's
  # immediate predecessor policy version. Both up.sql (plus the new key) and down.sql
  # (reverting to exactly this set) must retain all of these.
  @keys_from_000013 ~w(
    max_users registration_enabled default_room_visibility
    default_max_members bootstrap_completed
    oidc_user_id_claim oidc_displayname_claim oidc_email_claim
    oidc_directory_enabled oidc_directory_endpoint
    gdpr_retention_days signing_key_id compliance_mode_enabled
    scim_token_hash
    matrix_oidc_refresh_mode admin_oidc_refresh_mode
    matrix_oidc_extra_scopes admin_oidc_extra_scopes
  )

  # ════════════════════════════════════════════════════════════════════════════
  # AC1 — up.sql file exists and contains expected content
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC1: 000016_config_admin_group_claim_path.up.sql" do
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

    test "up migration policy includes admin_group_claim_path" do
      sql = File.read!(@up_file)

      assert sql =~ "'admin_group_claim_path'",
             "up.sql must include 'admin_group_claim_path' in the policy USING clause; got:\n#{sql}"
    end

    test "up migration policy retains every key from migration 000013" do
      sql = File.read!(@up_file)

      for key <- @keys_from_000013 do
        assert sql =~ "'#{key}'",
               "up.sql must retain '#{key}' from migration 000013; got:\n#{sql}"
      end
    end

    test "up migration is FOR UPDATE" do
      sql = File.read!(@up_file)

      assert sql =~ "FOR UPDATE",
             "config_update_mutable policy must be FOR UPDATE; got:\n#{sql}"
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC1 — down.sql file exists and restores policy without the new key
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC1: 000016_config_admin_group_claim_path.down.sql" do
    test "migration down file exists" do
      assert File.exists?(@down_file),
             "Migration down file missing: #{@down_file}"
    end

    test "down migration drops and recreates policy without the new key" do
      sql = File.read!(@down_file)

      assert sql =~ "DROP POLICY IF EXISTS config_update_mutable ON server_config",
             "down.sql must DROP config_update_mutable policy; got:\n#{sql}"

      assert sql =~ "CREATE POLICY config_update_mutable ON server_config",
             "down.sql must CREATE config_update_mutable policy; got:\n#{sql}"
    end

    test "down migration does NOT include admin_group_claim_path" do
      sql = File.read!(@down_file)

      refute sql =~ "'admin_group_claim_path'",
             "down.sql must NOT include 'admin_group_claim_path' (reverts to pre-story state); got:\n#{sql}"
    end

    test "down migration retains every key from migration 000013 (reverts only the new key)" do
      sql = File.read!(@down_file)

      for key <- @keys_from_000013 do
        assert sql =~ "'#{key}'",
               "down.sql must retain '#{key}'; got:\n#{sql}"
      end
    end
  end
end
