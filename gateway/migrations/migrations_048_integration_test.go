//go:build integration

package migrations_test

// migrations_048_integration_test.go — Story 14-2a / Story 13.14 squash:
// Integration tests for OIDC directory config seeds.
// After Story 13.14 squash, all seeds from migrations 44–49 are in 000001_init.up.sql.
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
// AT-15 — oidc_directory_enabled and oidc_directory_endpoint rows seeded [AC1]
// ─────────────────────────────────────────────────────────────────────────────

// TestMigration048_OidcDirectoryRowsSeeded verifies that after the squashed migration,
// the server_config table contains both OIDC directory rows with correct default values.
func TestMigration048_OidcDirectoryRowsSeeded(t *testing.T) {
	dbURL := testMigrationDBURL()
	m := newMigrate(t, dbURL)
	defer m.Close()

	// Apply all migrations (single squashed migration 000001).
	if err := m.Up(); err != nil && !errors.Is(err, migrate.ErrNoChange) {
		t.Fatalf("migrate up: %v", err)
	}

	db, err := sql.Open("pgx", dbURL)
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	defer db.Close()

	rows, err := db.Query(
		`SELECT key, value FROM server_config WHERE key IN ('oidc_directory_enabled', 'oidc_directory_endpoint') ORDER BY key`,
	)
	if err != nil {
		t.Fatalf("[AT-15] query server_config: %v", err)
	}
	defer rows.Close()

	found := make(map[string]string)
	for rows.Next() {
		var k, v string
		if err := rows.Scan(&k, &v); err != nil {
			t.Fatalf("[AT-15] scan row: %v", err)
		}
		found[k] = v
	}
	if err := rows.Err(); err != nil {
		t.Fatalf("[AT-15] rows.Err: %v", err)
	}

	if v, ok := found["oidc_directory_enabled"]; !ok {
		t.Error("[AT-15] expected row 'oidc_directory_enabled' in server_config, not found")
	} else if v != "false" {
		t.Errorf("[AT-15] expected oidc_directory_enabled='false', got %q", v)
	}

	if _, ok := found["oidc_directory_endpoint"]; !ok {
		t.Error("[AT-15] expected row 'oidc_directory_endpoint' in server_config, not found")
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// AT-16 — oidc_directory keys are mutable via nebu_app RLS policy [AC1]
// ─────────────────────────────────────────────────────────────────────────────

// TestMigration048_OidcDirectoryKeysAreMutable verifies that after the squashed migration,
// nebu_app can UPDATE both OIDC directory server_config keys (they are in the mutable allowlist).
func TestMigration048_OidcDirectoryKeysAreMutable(t *testing.T) {
	dbURL := testMigrationDBURL()
	m := newMigrate(t, dbURL)
	defer m.Close()

	if err := m.Up(); err != nil && !errors.Is(err, migrate.ErrNoChange) {
		t.Fatalf("migrate up: %v", err)
	}

	// Connect as nebu_app (default connection URL from testDB048URL already uses nebu_app).
	appDB, err := sql.Open("pgx", dbURL)
	if err != nil {
		t.Fatalf("open db as nebu_app: %v", err)
	}
	defer appDB.Close()

	// Ensure rows exist (seeded by squashed migration, but just in case).
	_, _ = appDB.Exec(`INSERT INTO server_config (key, value, set_at) VALUES ('oidc_directory_enabled', 'false', 0) ON CONFLICT (key) DO NOTHING`)
	_, _ = appDB.Exec(`INSERT INTO server_config (key, value, set_at) VALUES ('oidc_directory_endpoint', '', 0) ON CONFLICT (key) DO NOTHING`)

	// UPDATE oidc_directory_enabled — must succeed.
	result, err := appDB.Exec(`UPDATE server_config SET value = 'true', set_at = 1 WHERE key = 'oidc_directory_enabled'`)
	if err != nil {
		t.Fatalf("[AT-16] UPDATE oidc_directory_enabled as nebu_app: expected success, got error: %v", err)
	}
	rowsAffected, _ := result.RowsAffected()
	if rowsAffected != 1 {
		t.Errorf("[AT-16] expected 1 row updated for oidc_directory_enabled, got %d", rowsAffected)
	}

	// UPDATE oidc_directory_endpoint — must succeed.
	result, err = appDB.Exec(`UPDATE server_config SET value = 'https://idp.example.com/admin/users', set_at = 1 WHERE key = 'oidc_directory_endpoint'`)
	if err != nil {
		t.Fatalf("[AT-16] UPDATE oidc_directory_endpoint as nebu_app: expected success, got error: %v", err)
	}
	rowsAffected, _ = result.RowsAffected()
	if rowsAffected != 1 {
		t.Errorf("[AT-16] expected 1 row updated for oidc_directory_endpoint, got %d", rowsAffected)
	}

	// Restore default values.
	_, _ = appDB.Exec(`UPDATE server_config SET value = 'false', set_at = 0 WHERE key = 'oidc_directory_enabled'`)
	_, _ = appDB.Exec(`UPDATE server_config SET value = '', set_at = 0 WHERE key = 'oidc_directory_endpoint'`)
}
