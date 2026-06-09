defmodule Nebu.Session.BulkImporterTest do
  use ExUnit.Case, async: false
  # async: false — Application.put_env is process-global.

  # ─── Story auto-join-on-user-import: BulkImporter.import_users/1 unit tests ──
  #
  # ATDD — Written FIRST (before implementation code).
  # These tests FAIL until:
  #   1. BulkImporter.import_users/1 returns `imported_user_ids` in the result map.
  #   2. Only newly-imported users appear in `imported_user_ids` (not skipped ones).
  #
  # Acceptance Criteria covered:
  #   AC3 — Skipped (existing) users are NOT included in imported_user_ids
  #   AC4 — imported_user_ids contains exactly the 2 new user IDs, not the skipped one

  alias Nebu.Session.BulkImporter

  # ─── Fake Lookup Module ───────────────────────────────────────────────────────
  # Returns :not_provisioned for dave and eve (new users),
  # :already_provisioned for existing (skipped user).

  defmodule FakeLookup_TwoNewOneSkipped do
    def lookup("@dave:nebu.local"), do: :not_provisioned
    def lookup("@eve:nebu.local"), do: :not_provisioned
    def lookup("@existing:nebu.local"), do: :already_provisioned
  end

  # ─── Fake UserStore Module ────────────────────────────────────────────────────
  defmodule FakeUserStore do
    def upsert_user(_user_id, _role), do: {:ok, :upserted}
  end

  # ─── Fake Provisioner Module ──────────────────────────────────────────────────
  defmodule FakeProvisioner do
    def provision_user(_user_id, _display_name, _email, _server_key), do: {:ok, :provisioned}
  end

  # ─── Fake Lookup: all users new (for AC4 variant — 2 new, no skipped) ────────
  defmodule FakeLookup_AllNew do
    def lookup(_user_id), do: :not_provisioned
  end

  # ─── Setup ───────────────────────────────────────────────────────────────────

  setup do
    # Inject a no-op signing key so BulkImporter.import_users/1 doesn't call
    # Application.get_env(:signature, :pii_encryption_key) with a nil value.
    Application.put_env(:signature, :pii_encryption_key, :crypto.strong_rand_bytes(32))

    Application.put_env(:session_manager, :bulk_importer_lookup_module, FakeLookup_TwoNewOneSkipped)
    Application.put_env(:session_manager, :bulk_importer_user_store_module, FakeUserStore)
    Application.put_env(:session_manager, :bulk_importer_provisioner_module, FakeProvisioner)

    on_exit(fn ->
      Application.delete_env(:signature, :pii_encryption_key)
      Application.delete_env(:session_manager, :bulk_importer_lookup_module)
      Application.delete_env(:session_manager, :bulk_importer_user_store_module)
      Application.delete_env(:session_manager, :bulk_importer_provisioner_module)
    end)

    :ok
  end

  # ─── AC3: Skipped (existing) user is NOT in imported_user_ids ─────────────────
  #
  # GIVEN: BulkImportUsers is called with user @existing:nebu.local who already exists
  #        (BulkImporter.lookup/1 returns :already_provisioned)
  # WHEN:  BulkImporter.import_users/1 processes the batch
  # THEN:  imported_user_ids does NOT contain "@existing:nebu.local"
  #        (existing users are skipped — idempotent, not re-processed)
  #
  # THIS TEST FAILS until:
  #   1. BulkImporter.import_users/1 returns `imported_user_ids` in the result map
  #   2. The list excludes skipped users

  test "AC3: skipped (existing) user is not included in imported_user_ids" do
    users = [
      %{user_id: "@dave:nebu.local", system_role: "user", display_name: "Dave", email: "dave@example.com"},
      %{user_id: "@existing:nebu.local", system_role: "user", display_name: "Existing", email: "existing@example.com"}
    ]

    # THIS TEST FAILS — import_users/1 does not return imported_user_ids yet.
    {:ok, result} = BulkImporter.import_users(users)

    assert Map.has_key?(result, :imported_user_ids),
      "import_users/1 result must include :imported_user_ids. Got: #{inspect(result)}"

    refute "@existing:nebu.local" in result.imported_user_ids,
      "existing (skipped) user must NOT appear in imported_user_ids. " <>
      "Got: #{inspect(result.imported_user_ids)}"
  end

  # ─── AC4: imported_user_ids contains exactly the 2 new user IDs ───────────────
  #
  # GIVEN: bulk_import_users imports @dave and @eve (new), skips @existing
  # WHEN:  BulkImporter.import_users/1 processes the batch of 3 users
  # THEN:  imported_user_ids contains exactly ["@dave:nebu.local", "@eve:nebu.local"]
  #        (the 2 newly imported users, not the skipped one)
  #        AND imported: 2, skipped: 1, failed: 0
  #
  # THIS TEST FAILS until:
  #   1. BulkImporter.import_users/1 tracks and returns imported_user_ids
  #   2. The list contains only new users, in order processed

  test "AC4: imported_user_ids contains exactly the 2 new user IDs, not the skipped one" do
    users = [
      %{user_id: "@dave:nebu.local", system_role: "user", display_name: "Dave", email: "dave@example.com"},
      %{user_id: "@eve:nebu.local", system_role: "user", display_name: "Eve", email: "eve@example.com"},
      %{user_id: "@existing:nebu.local", system_role: "user", display_name: "Existing", email: "existing@example.com"}
    ]

    # THIS TEST FAILS — import_users/1 does not return imported_user_ids yet.
    {:ok, result} = BulkImporter.import_users(users)

    assert Map.has_key?(result, :imported_user_ids),
      "import_users/1 result must include :imported_user_ids. Got: #{inspect(result)}"

    assert result.imported == 2,
      "Expected imported: 2, got: #{inspect(result.imported)}"

    assert result.skipped == 1,
      "Expected skipped: 1, got: #{inspect(result.skipped)}"

    assert result.failed == 0,
      "Expected failed: 0, got: #{inspect(result.failed)}"

    imported_ids = result.imported_user_ids |> Enum.sort()
    expected_ids = ["@dave:nebu.local", "@eve:nebu.local"] |> Enum.sort()

    assert imported_ids == expected_ids,
      "imported_user_ids must be exactly the 2 new user IDs. " <>
      "Expected: #{inspect(expected_ids)}, Got: #{inspect(imported_ids)}"
  end

  # ─── AC4 baseline: existing result shape is preserved ─────────────────────────
  #
  # Regression guard: existing {:ok, %{imported: N, skipped: N, failed: N}} shape
  # must still be present (not broken by adding imported_user_ids).

  test "AC4 baseline: result still contains imported/skipped/failed counts" do
    users = [
      %{user_id: "@dave:nebu.local", system_role: "user", display_name: "Dave", email: "dave@example.com"}
    ]

    Application.put_env(:session_manager, :bulk_importer_lookup_module, FakeLookup_AllNew)
    {:ok, result} = BulkImporter.import_users(users)

    assert result.imported == 1
    assert result.skipped == 0
    assert result.failed == 0
  end

  # ─── AT-1..AT-3: imported_user_ids field — story auto-join-on-user-import ──────
  #
  # These tests verify AC5 and AC6 of the story:
  #   AT-1: All new users → imported_user_ids contains both
  #   AT-2: Mixed (1 new, 1 skipped) → only new user in imported_user_ids
  #   AT-3: All skipped → imported_user_ids is empty

  describe "import_users/1 — imported_user_ids" do
    test "AT-1: returns imported_user_ids with newly provisioned user IDs (all new)" do
      # MINOR-4: test for "all new users" scenario — 2 users, both new,
      # imported_user_ids must contain both.
      Application.put_env(:session_manager, :bulk_importer_lookup_module, FakeLookup_AllNew)

      users = [
        %{user_id: "@alice:nebu.local", system_role: "user", display_name: "Alice", email: "alice@example.com"},
        %{user_id: "@bob:nebu.local", system_role: "user", display_name: "Bob", email: "bob@example.com"}
      ]

      {:ok, result} = BulkImporter.import_users(users)

      assert result.imported == 2
      assert result.skipped == 0
      assert result.failed == 0
      assert is_list(result.imported_user_ids)
      assert length(result.imported_user_ids) == 2
      assert "@alice:nebu.local" in result.imported_user_ids
      assert "@bob:nebu.local" in result.imported_user_ids
    end

    test "AT-2: omits skipped user IDs from imported_user_ids (mixed)" do
      # FakeLookup_TwoNewOneSkipped is the default from setup — use it directly.
      # @dave and @eve are new; @existing is already provisioned.
      # But this test only submits 2 users: one new, one skipped.
      # Use FakeLookup_AllNew for the new user and a one-off override for the skipped one.
      # FakeLookup_TwoNewOneSkipped already covers the mixed case; reuse it with 2 users.
      users = [
        %{user_id: "@dave:nebu.local", system_role: "user", display_name: "Dave", email: "dave@example.com"},
        %{user_id: "@existing:nebu.local", system_role: "user", display_name: "Existing", email: "ex@example.com"}
      ]

      {:ok, result} = BulkImporter.import_users(users)

      assert result.imported == 1
      assert result.skipped == 1
      assert "@dave:nebu.local" in result.imported_user_ids
      refute "@existing:nebu.local" in result.imported_user_ids
    end

    test "AT-3: returns empty imported_user_ids when all users are skipped" do
      # FakeLookup from bulk_import_users_test returns :already_provisioned for all.
      # Define a local all-provisioned fake inline.
      defmodule FakeLookup_AllProvisioned do
        def lookup(_user_id), do: :already_provisioned
      end

      Application.put_env(:session_manager, :bulk_importer_lookup_module, FakeLookup_AllProvisioned)

      users = [
        %{user_id: "@carol:nebu.local", system_role: "user", display_name: "Carol", email: "carol@example.com"}
      ]

      {:ok, result} = BulkImporter.import_users(users)

      assert result.imported == 0
      assert result.imported_user_ids == []
    end
  end
end
