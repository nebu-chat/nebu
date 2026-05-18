//go:build integration

package migrations_test

// migrations_046_integration_test.go — Story 12.7 / Story 13.14 squash:
// Integration tests for server_config RLS policy (config_update_mutable).
// After Story 13.14 squash, the final config_update_mutable policy (from migration 000049)
// is baked directly into 000001_init.up.sql.
//
// Run:  go test -tags=integration ./gateway/migrations/...

import (
	"database/sql"
	"errors"
	"testing"

	"github.com/golang-migrate/migrate/v4"
	_ "github.com/golang-migrate/migrate/v4/database/pgx/v5"
	_ "github.com/jackc/pgx/v5/stdlib"
)

// ─────────────────────────────────────────────────────────────────────────────
// AT-13 — Immutable key (server_name) UPDATE rejected by RLS [AC5-1]
// ─────────────────────────────────────────────────────────────────────────────

// TestMigration046_ImmutableKeyUpdateBlocked verifies that after the squashed migration,
// attempting to UPDATE server_config WHERE key='server_name' as nebu_app raises
// an RLS violation (no rows updated or error).
func TestMigration046_ImmutableKeyUpdateBlocked(t *testing.T) {
	dbURL := testMigrationDBURL()
	m := newMigrate(t, dbURL)
	defer m.Close()

	// Apply all migrations (single squashed migration 000001).
	if err := m.Up(); err != nil && !errors.Is(err, migrate.ErrNoChange) {
		t.Fatalf("migrate up: %v", err)
	}

	// Connect as nebu_app (default connection URL from testDB046URL already uses nebu_app).
	db, err := sql.Open("pgx", dbURL)
	if err != nil {
		t.Fatalf("open db as nebu_app: %v", err)
	}
	defer db.Close()

	// As nebu_app, attempt to UPDATE server_name — should be blocked by RLS.
	// First ensure server_name exists (it may have been set during bootstrap).
	// Note: we insert using the same nebu_app connection since that's all we have
	// in the squashed single-role model.
	_, _ = db.Exec(`INSERT INTO server_config (key, value, set_at) VALUES ('server_name', 'test.local', 0) ON CONFLICT (key) DO NOTHING`)

	result, err := db.Exec(`UPDATE server_config SET value = 'evil.attacker.com' WHERE key = 'server_name'`)
	if err != nil {
		// RLS can surface as an error — this is also acceptable.
		t.Logf("[AT-13] UPDATE server_name returned error (RLS blocked): %v", err)
		return
	}

	// If no error, check rows affected — RLS should result in 0 rows updated.
	rowsAffected, err := result.RowsAffected()
	if err != nil {
		t.Fatalf("[AT-13] RowsAffected: %v", err)
	}
	if rowsAffected != 0 {
		t.Errorf("[AT-13] UPDATE server_name as nebu_app: expected 0 rows affected (RLS blocked), got %d", rowsAffected)
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// AT-14 — Mutable key (oidc_user_id_claim) UPDATE succeeds [AC5-2]
// ─────────────────────────────────────────────────────────────────────────────

// TestMigration046_MutableKeyUpdateSucceeds verifies that after the squashed migration,
// updating oidc_user_id_claim as nebu_app succeeds (it's in the mutable allowlist).
func TestMigration046_MutableKeyUpdateSucceeds(t *testing.T) {
	dbURL := testMigrationDBURL()
	m := newMigrate(t, dbURL)
	defer m.Close()

	if err := m.Up(); err != nil && !errors.Is(err, migrate.ErrNoChange) {
		t.Fatalf("migrate up: %v", err)
	}

	// Connect as nebu_app (default connection URL from testDB046URL already uses nebu_app).
	db, err := sql.Open("pgx", dbURL)
	if err != nil {
		t.Fatalf("open db as nebu_app: %v", err)
	}
	defer db.Close()

	// Ensure oidc_user_id_claim row exists (seeded by squashed migration, but just in case).
	_, _ = db.Exec(`INSERT INTO server_config (key, value, set_at) VALUES ('oidc_user_id_claim', 'name', 0) ON CONFLICT (key) DO NOTHING`)

	// As nebu_app, UPDATE oidc_user_id_claim — must succeed (mutable key).
	result, err := db.Exec(`UPDATE server_config SET value = 'email', set_at = 1 WHERE key = 'oidc_user_id_claim'`)
	if err != nil {
		t.Fatalf("[AT-14] UPDATE oidc_user_id_claim as nebu_app: expected success, got error: %v", err)
	}

	rowsAffected, err := result.RowsAffected()
	if err != nil {
		t.Fatalf("[AT-14] RowsAffected: %v", err)
	}
	if rowsAffected != 1 {
		t.Errorf("[AT-14] expected 1 row updated, got %d", rowsAffected)
	}

	// Restore original value.
	_, _ = db.Exec(`UPDATE server_config SET value = 'name', set_at = 0 WHERE key = 'oidc_user_id_claim'`)
}
