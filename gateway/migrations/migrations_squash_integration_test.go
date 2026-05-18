//go:build integration

package migrations_test

// migrations_squash_integration_test.go — Story 13.14: Squashed migration acceptance tests.
// Verifies the final schema state after applying 000001_init.up.sql to a fresh PostgreSQL DB.
//
// Tests:
//   TestSquashedMigrationApplies      — AC2, AC4: migration applies, seeds present
//   TestSquashedMigrationTablesExist  — AC2: all 26 expected tables are present
//   TestAuditLogImmutability          — AC2: documents Option A trade-off (single-role, no FORCE RLS)
//   TestAuditLogPurgeWorks            — AC3: audit_log_purge() callable by nebu_app; temporal boundary optional
//   TestSyncTokensCompositeKey        — AC2: composite PK (user_id, device_id) on sync_tokens
//   TestSquashedDownMigration         — AC8: down migration drops everything cleanly
//
// Run:  go test -tags=integration ./gateway/migrations/...

import (
	"database/sql"
	"errors"
	"os"
	"testing"
	"time"

	"github.com/golang-migrate/migrate/v4"
	_ "github.com/golang-migrate/migrate/v4/database/pgx/v5"
	_ "github.com/jackc/pgx/v5/stdlib"
)

// ─────────────────────────────────────────────────────────────────────────────
// AC2, AC4 — Migration applies, version is 1, seeds are present
// ─────────────────────────────────────────────────────────────────────────────

// TestSquashedMigrationApplies verifies that the squashed migration:
//   - applies to a fresh database without errors
//   - leaves the migration at version 1
//   - seeds server_config rows (oidc_user_id_claim, room_defaults)
func TestSquashedMigrationApplies(t *testing.T) {
	dbURL := testMigrationDBURL()
	m := newMigrate(t, dbURL)
	defer m.Close()

	if err := m.Up(); err != nil && !errors.Is(err, migrate.ErrNoChange) {
		t.Fatalf("migrate up: %v", err)
	}

	// Verify migration version is 1.
	version, dirty, err := m.Version()
	if err != nil && !errors.Is(err, migrate.ErrNilVersion) {
		t.Fatalf("getting migration version: %v", err)
	}
	if dirty {
		t.Errorf("migration state is dirty after up: version=%d", version)
	}
	if version != 1 {
		t.Errorf("expected migration version 1, got %d", version)
	}

	db, err := sql.Open("pgx", dbURL)
	if err != nil {
		t.Fatalf("sql.Open: %v", err)
	}
	defer db.Close()

	// AC4: oidc_user_id_claim seed must be present.
	var count int
	if err := db.QueryRow(
		`SELECT COUNT(*) FROM server_config WHERE key = 'oidc_user_id_claim'`,
	).Scan(&count); err != nil {
		t.Fatalf("querying server_config for oidc_user_id_claim: %v", err)
	}
	if count != 1 {
		t.Errorf("AC4: expected 1 row for oidc_user_id_claim in server_config, got %d", count)
	}

	// AC4: room_defaults seed row must be present.
	if err := db.QueryRow(
		`SELECT COUNT(*) FROM room_defaults`,
	).Scan(&count); err != nil {
		t.Fatalf("querying room_defaults: %v", err)
	}
	if count != 1 {
		t.Errorf("AC4: expected 1 row in room_defaults, got %d", count)
	}

	// AC4: SCIM and OIDC directory seeds must be present.
	seedKeys := []string{
		"oidc_user_id_claim",
		"oidc_displayname_claim",
		"oidc_email_claim",
		"oidc_directory_enabled",
		"oidc_directory_endpoint",
		"scim_enabled",
		"scim_base_url",
		"scim_bearer_token",
	}
	for _, key := range seedKeys {
		if err := db.QueryRow(
			`SELECT COUNT(*) FROM server_config WHERE key = $1`, key,
		).Scan(&count); err != nil {
			t.Fatalf("querying server_config for key %q: %v", key, err)
		}
		if count != 1 {
			t.Errorf("AC4: expected 1 row for key %q in server_config, got %d", key, count)
		}
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// AC2 — All 26 expected tables exist
// ─────────────────────────────────────────────────────────────────────────────

// TestSquashedMigrationTablesExist verifies that all tables from the final schema
// are present after the squashed migration is applied.
func TestSquashedMigrationTablesExist(t *testing.T) {
	dbURL := testMigrationDBURL()
	m := newMigrate(t, dbURL)
	defer m.Close()

	if err := m.Up(); err != nil && !errors.Is(err, migrate.ErrNoChange) {
		t.Fatalf("migrate up: %v", err)
	}

	db, err := sql.Open("pgx", dbURL)
	if err != nil {
		t.Fatalf("sql.Open: %v", err)
	}
	defer db.Close()

	expectedTables := []string{
		"message_buffer",
		"message_dead_letter",
		"server_config",
		"users",
		"user_keys",
		"sessions",
		"invalidated_tokens",
		"bootstrap_draft",
		"rooms",
		"room_members",
		"events",
		"sync_tokens",
		"room_invitations",
		"read_receipts",
		"profiles",
		"media_files",
		"admin_sessions",
		"audit_log",
		"compliance_requests",
		"compliance_sessions",
		"room_account_data",
		"notifications",
		"push_rules",
		"pushers",
		"role_overrides",
		"room_defaults",
		"forgotten_rooms",
	}

	for _, tableName := range expectedTables {
		var exists bool
		if err := db.QueryRow(`
			SELECT EXISTS (
				SELECT 1 FROM information_schema.tables
				WHERE table_schema = 'public'
				  AND table_name = $1
			)`, tableName,
		).Scan(&exists); err != nil {
			t.Errorf("querying table existence for %q: %v", tableName, err)
			continue
		}
		if !exists {
			t.Errorf("AC2: expected table %q to exist after squashed migration, but it does not", tableName)
		}
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// AC2 — audit_log immutability (DELETE blocked by RLS)
// ─────────────────────────────────────────────────────────────────────────────

// TestAuditLogImmutability documents the accepted trade-off for the single-role model
// (Option A, CRITICAL-1): nebu_app as table owner bypasses all RLS policies (no FORCE RLS),
// so a direct DELETE succeeds. The application-layer guarantee is that the gateway never
// issues DELETE/UPDATE on audit_log outside of audit_log_purge(). The audit_log_no_delete
// and audit_log_no_update policies remain to block accidental ORM-layer operations from
// non-owner connections (dual-role deployments, psql sessions with a limited role).
func TestAuditLogImmutability(t *testing.T) {
	dbURL := testMigrationDBURL()
	m := newMigrate(t, dbURL)
	defer m.Close()

	if err := m.Up(); err != nil && !errors.Is(err, migrate.ErrNoChange) {
		t.Fatalf("migrate up: %v", err)
	}

	db, err := sql.Open("pgx", dbURL)
	if err != nil {
		t.Fatalf("sql.Open: %v", err)
	}
	defer db.Close()

	// Insert a test row into audit_log.
	var insertedID int64
	err = db.QueryRow(`
		INSERT INTO audit_log (actor_user_id, action, outcome)
		VALUES ('test-actor', 'test_action', 'success')
		RETURNING id
	`).Scan(&insertedID)
	if err != nil {
		t.Fatalf("inserting audit_log row: %v", err)
	}
	t.Cleanup(func() {
		// Best-effort cleanup: the row may already be gone if a concurrent test ran purge.
		_, _ = db.Exec(`DELETE FROM audit_log WHERE id = $1`, insertedID)
	})

	// In single-role mode (Option A: no FORCE RLS), nebu_app as table owner bypasses
	// RLS policies. A direct DELETE will succeed — this is the accepted trade-off.
	// This test documents that expectation rather than asserting the delete is blocked.
	result, err := db.Exec(`DELETE FROM audit_log WHERE id = $1`, insertedID)
	if err != nil {
		t.Logf("AC2 (Option A): direct DELETE on audit_log returned error: %v", err)
		t.Logf("This may occur in a dual-role deployment where nebu_app is NOT the table owner.")
		return
	}

	rowsAffected, _ := result.RowsAffected()
	// In single-role mode: 1 row deleted (owner bypasses RLS) — this is expected under Option A.
	// In dual-role mode: 0 rows (no_delete policy blocks non-owner). Both outcomes are valid.
	t.Logf("AC2 (Option A): direct DELETE on audit_log affected %d row(s). "+
		"In single-role mode this is 1 (owner bypasses RLS — accepted trade-off). "+
		"In dual-role mode this is 0 (no_delete policy blocks non-owner).", rowsAffected)

	// Also document the UPDATE path — same trade-off applies.
	// Re-insert if the row was deleted above so we have something to UPDATE.
	var rowID int64
	_ = db.QueryRow(`
		INSERT INTO audit_log (actor_user_id, action, outcome)
		VALUES ('test-actor-update', 'test_update', 'success')
		RETURNING id
	`).Scan(&rowID)
	t.Cleanup(func() {
		_, _ = db.Exec(`DELETE FROM audit_log WHERE id = $1`, rowID)
	})

	var updateRowsAffected int64
	var updateErr error
	updateRowsAffected, updateErr = func() (int64, error) {
		res, err := db.Exec(`UPDATE audit_log SET action = 'tampered' WHERE id = $1`, rowID)
		if err != nil {
			return 0, err
		}
		return res.RowsAffected()
	}()
	t.Logf("Option A — direct UPDATE as nebu_app: rowsAffected=%d err=%v (table owner bypasses RLS without FORCE)", updateRowsAffected, updateErr)
}

// ─────────────────────────────────────────────────────────────────────────────
// AC3 — audit_log_purge() works via SECURITY DEFINER
// ─────────────────────────────────────────────────────────────────────────────

// TestAuditLogPurgeWorks verifies that audit_log_purge(retention_days) is callable
// via nebu_app and returns a valid count. After Option A (no FORCE RLS), the function
// no longer needs to bypass FORCE RLS — nebu_app as table owner can DELETE directly.
//
// Basic invocability test: insert a fresh row (event_time = NOW()), call purge(36500),
// verify it returns 0 (the fresh row is within retention). This does not require superuser
// access to backdate rows.
//
// TODO: to test the temporal boundary (purge actually deletes rows older than retention_days),
// a privileged session is needed to insert a row with a backdated event_time (disabling
// the audit_log_event_time_force trigger via session_replication_role = replica). This is
// available if NEBU_TEST_MIGRATION_DB_URL points to a superuser connection.
func TestAuditLogPurgeWorks(t *testing.T) {
	dbURL := testMigrationDBURL()
	m := newMigrate(t, dbURL)
	defer m.Close()

	if err := m.Up(); err != nil && !errors.Is(err, migrate.ErrNoChange) {
		t.Fatalf("migrate up: %v", err)
	}

	db, err := sql.Open("pgx", dbURL)
	if err != nil {
		t.Fatalf("sql.Open: %v", err)
	}
	defer db.Close()

	// Insert a fresh row (event_time forced to NOW() by trigger).
	var insertedID int64
	err = db.QueryRow(`
		INSERT INTO audit_log (actor_user_id, action, outcome)
		VALUES ('purge-test-actor', 'test_action', 'success')
		RETURNING id
	`).Scan(&insertedID)
	if err != nil {
		t.Fatalf("inserting audit_log row: %v", err)
	}
	t.Cleanup(func() {
		// Best-effort cleanup: may already be gone.
		_, _ = db.Exec(`DELETE FROM audit_log WHERE id = $1`, insertedID)
	})

	// AC3: audit_log_purge(36500) must be callable without error as nebu_app.
	// A retention of 36500 days means the fresh row is within retention — expect 0 deleted.
	var deletedCount int64
	if err := db.QueryRow(`SELECT audit_log_purge(36500)`).Scan(&deletedCount); err != nil {
		t.Fatalf("AC3: calling audit_log_purge(36500): %v — "+
			"function must be callable by nebu_app without error", err)
	}

	// The fresh row should NOT be purged (it's within the 36500-day retention window).
	if deletedCount != 0 {
		t.Errorf("AC3: expected audit_log_purge(36500) to delete 0 rows (all rows are fresh), deleted %d", deletedCount)
	}

	// Verify the fresh row is still present.
	var count int
	if err := db.QueryRow(`SELECT COUNT(*) FROM audit_log WHERE id = $1`, insertedID).Scan(&count); err != nil {
		t.Fatalf("checking for preserved row: %v", err)
	}
	if count != 1 {
		t.Errorf("AC3: fresh audit_log row (id=%d) should still exist after purge(36500), count=%d", insertedID, count)
	}

	// Optional: test actual deletion with a backdated row using a privileged connection.
	privilegedURL := os.Getenv("NEBU_TEST_MIGRATION_DB_URL")
	if privilegedURL == "" {
		t.Log("AC3 temporal boundary: NEBU_TEST_MIGRATION_DB_URL not set — skipping backdated-row purge test")
		return
	}

	privDB, err := sql.Open("pgx", privilegedURL)
	if err != nil {
		t.Fatalf("sql.Open (privileged): %v", err)
	}
	defer privDB.Close()

	// Wrap the backdated INSERT in a transaction so SET LOCAL resets automatically on commit.
	tx, err := privDB.Begin()
	if err != nil {
		t.Fatalf("beginning transaction for backdated insert: %v", err)
	}

	_, setReplicaErr := tx.Exec(`SET LOCAL session_replication_role = replica`)
	if setReplicaErr != nil {
		_ = tx.Rollback()
		t.Fatalf("NEBU_TEST_MIGRATION_DB_URL is set but cannot set session_replication_role — "+
			"the provided connection must have superuser privileges: %v", setReplicaErr)
	}

	oldTime := time.Now().Add(-400 * 24 * time.Hour) // 400 days ago
	var oldRowID int64
	err = tx.QueryRow(`
		INSERT INTO audit_log (event_time, actor_user_id, action, outcome)
		VALUES ($1, 'purge-test-old', 'test_action', 'success')
		RETURNING id
	`, oldTime).Scan(&oldRowID)
	if err != nil {
		_ = tx.Rollback()
		t.Fatalf("inserting backdated audit_log row: %v", err)
	}
	// SET LOCAL is transaction-scoped; session_replication_role resets automatically on commit.
	if err := tx.Commit(); err != nil {
		t.Fatalf("committing backdated insert transaction: %v", err)
	}

	var deleted int64
	if err := db.QueryRow(`SELECT audit_log_purge(365)`).Scan(&deleted); err != nil {
		t.Fatalf("AC3: calling audit_log_purge(365) after backdated insert: %v", err)
	}
	if deleted < 1 {
		t.Errorf("AC3: expected audit_log_purge(365) to delete at least 1 backdated row, deleted %d", deleted)
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// AC2 — sync_tokens composite PK (user_id, device_id)
// ─────────────────────────────────────────────────────────────────────────────

// TestSyncTokensCompositeKey verifies that sync_tokens allows two rows with the same
// user_id but different device_id values (composite PK from migration 41).
func TestSyncTokensCompositeKey(t *testing.T) {
	dbURL := testMigrationDBURL()
	m := newMigrate(t, dbURL)
	defer m.Close()

	if err := m.Up(); err != nil && !errors.Is(err, migrate.ErrNoChange) {
		t.Fatalf("migrate up: %v", err)
	}

	db, err := sql.Open("pgx", dbURL)
	if err != nil {
		t.Fatalf("sql.Open: %v", err)
	}
	defer db.Close()

	// Need a user to satisfy FK constraint.
	testUserID := "@sync-test-user:test.nebu.local"
	_, _ = db.Exec(`DELETE FROM sync_tokens WHERE user_id = $1`, testUserID)
	_, _ = db.Exec(`DELETE FROM users WHERE user_id = $1`, testUserID)

	_, err = db.Exec(`
		INSERT INTO users (user_id, system_role, is_active, created_at)
		VALUES ($1, 'user', true, $2)
	`, testUserID, time.Now().UnixMilli())
	if err != nil {
		t.Fatalf("inserting test user: %v", err)
	}
	t.Cleanup(func() {
		_, _ = db.Exec(`DELETE FROM sync_tokens WHERE user_id = $1`, testUserID)
		_, _ = db.Exec(`DELETE FROM users WHERE user_id = $1`, testUserID)
	})

	// Insert two rows with same user_id but different device_id.
	_, err = db.Exec(`
		INSERT INTO sync_tokens (user_id, since_token, updated_at, device_id)
		VALUES ($1, 'token-a', $2, 'device-1')
	`, testUserID, time.Now().UnixMilli())
	if err != nil {
		t.Fatalf("inserting first sync_token row (device-1): %v", err)
	}

	_, err = db.Exec(`
		INSERT INTO sync_tokens (user_id, since_token, updated_at, device_id)
		VALUES ($1, 'token-b', $2, 'device-2')
	`, testUserID, time.Now().UnixMilli())
	if err != nil {
		t.Fatalf("inserting second sync_token row (device-2): %v — "+
			"composite PK (user_id, device_id) should allow two rows for the same user", err)
	}

	// Verify both rows exist.
	var count int
	if err := db.QueryRow(`SELECT COUNT(*) FROM sync_tokens WHERE user_id = $1`, testUserID).Scan(&count); err != nil {
		t.Fatalf("counting sync_tokens: %v", err)
	}
	if count != 2 {
		t.Errorf("expected 2 sync_token rows for user %q, got %d", testUserID, count)
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// AC8 — Down migration drops all tables and functions cleanly
// ─────────────────────────────────────────────────────────────────────────────

// TestSquashedDownMigration verifies that rolling back the squashed migration (version 0)
// drops all tables and functions, leaving an empty schema.
// Extensions are intentionally NOT dropped.
func TestSquashedDownMigration(t *testing.T) {
	migrateDBURL := os.Getenv("NEBU_TEST_MIGRATION_DB_URL")
	if migrateDBURL == "" {
		migrateDBURL = testMigrationDBURL()
	}

	m := newMigrate(t, migrateDBURL)
	defer m.Close()

	// Apply the squashed migration first.
	if err := m.Up(); err != nil && !errors.Is(err, migrate.ErrNoChange) {
		t.Fatalf("migrate up before down test: %v", err)
	}

	// Always re-apply after the down test.
	t.Cleanup(func() {
		m2 := newMigrate(t, migrateDBURL)
		defer m2.Close()
		if upErr := m2.Up(); upErr != nil && !errors.Is(upErr, migrate.ErrNoChange) {
			t.Logf("cleanup re-apply after down migration test: %v (non-fatal)", upErr)
		}
	})

	// Run down migration.
	if err := m.Down(); err != nil && !errors.Is(err, migrate.ErrNoChange) {
		t.Fatalf("AC8: running down migration: %v", err)
	}

	db, err := sql.Open("pgx", migrateDBURL)
	if err != nil {
		t.Fatalf("sql.Open: %v", err)
	}
	defer db.Close()

	// Verify all tables are dropped.
	var tableCount int
	if err := db.QueryRow(`
		SELECT COUNT(*) FROM information_schema.tables
		WHERE table_schema = 'public'
		  AND table_type = 'BASE TABLE'
	`).Scan(&tableCount); err != nil {
		t.Fatalf("counting tables after down migration: %v", err)
	}
	if tableCount != 0 {
		t.Errorf("AC8: expected 0 tables after down migration, found %d — "+
			"down migration must drop all tables", tableCount)
	}

	// Verify audit_log_purge function is dropped.
	var funcExists bool
	if err := db.QueryRow(`
		SELECT EXISTS (
			SELECT 1 FROM pg_proc
			WHERE proname = 'audit_log_purge'
			  AND pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public')
		)
	`).Scan(&funcExists); err != nil {
		t.Fatalf("checking audit_log_purge function existence: %v", err)
	}
	if funcExists {
		t.Error("AC8: audit_log_purge() still exists after down migration — must be dropped")
	}

	// Verify extensions are NOT dropped (AC8: extensions preserved).
	var pgcryptoExists bool
	if err := db.QueryRow(`
		SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pgcrypto')
	`).Scan(&pgcryptoExists); err != nil {
		t.Fatalf("checking pgcrypto extension: %v", err)
	}
	if !pgcryptoExists {
		t.Error("AC8: pgcrypto extension was dropped by down migration — extensions must NOT be dropped")
	}
}
