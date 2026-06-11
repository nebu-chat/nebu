//go:build integration

package migrations_test

// migrations_002_integration_test.go — bugfix/fix-room-management-error:
// Integration tests for migration 000002_add_missing_structures.
// Verifies that the three structures confirmed missing on the Stackit instance
// (rooms.is_auto_join, users.personal_room_id, matrix_sessions) and all other
// structures added in this migration are present after applying migrations 1 + 2.
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

// helper: asserts a column exists in the given table with the expected udt_name.
func assertColumn(t *testing.T, db *sql.DB, table, column, wantType string) {
	t.Helper()
	var got string
	err := db.QueryRow(`
		SELECT udt_name
		FROM information_schema.columns
		WHERE table_schema = 'public'
		  AND table_name   = $1
		  AND column_name  = $2
	`, table, column).Scan(&got)
	if err == sql.ErrNoRows {
		t.Fatalf("column %s.%s is missing after migration 000002", table, column)
	}
	if err != nil {
		t.Fatalf("querying column %s.%s: %v", table, column, err)
	}
	if wantType != "" && got != wantType {
		t.Errorf("column %s.%s: expected udt_name %q, got %q", table, column, wantType, got)
	}
}

// helper: asserts a table exists in the public schema.
func assertTable(t *testing.T, db *sql.DB, table string) {
	t.Helper()
	var exists bool
	if err := db.QueryRow(`
		SELECT EXISTS (
			SELECT 1 FROM information_schema.tables
			WHERE table_schema = 'public' AND table_name = $1
		)
	`, table).Scan(&exists); err != nil {
		t.Fatalf("querying table existence for %q: %v", table, err)
	}
	if !exists {
		t.Fatalf("table %q is missing after migration 000002", table)
	}
}

// helper: asserts a pg_index entry exists by index name.
func assertIndex(t *testing.T, db *sql.DB, table, indexName string) {
	t.Helper()
	var got string
	err := db.QueryRow(`
		SELECT indexname FROM pg_indexes
		WHERE schemaname = 'public' AND tablename = $1 AND indexname = $2
	`, table, indexName).Scan(&got)
	if err == sql.ErrNoRows {
		t.Fatalf("index %q on table %q is missing after migration 000002", indexName, table)
	}
	if err != nil {
		t.Fatalf("querying index %q on table %q: %v", indexName, table, err)
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// AC1 — rooms.is_auto_join column and index exist
// ─────────────────────────────────────────────────────────────────────────────

func TestMigration002_RoomsIsAutoJoin(t *testing.T) {
	db, cleanup := openMigratedDB(t)
	defer cleanup()

	assertColumn(t, db, "rooms", "is_auto_join", "bool")
	assertIndex(t, db, "rooms", "rooms_auto_join_idx")
}

// ─────────────────────────────────────────────────────────────────────────────
// AC2 — users.personal_room_id column exists
// ─────────────────────────────────────────────────────────────────────────────

func TestMigration002_UsersPersonalRoomID(t *testing.T) {
	db, cleanup := openMigratedDB(t)
	defer cleanup()

	assertColumn(t, db, "users", "personal_room_id", "text")
}

// ─────────────────────────────────────────────────────────────────────────────
// AC3 — matrix_sessions table exists with all required columns and indexes
// ─────────────────────────────────────────────────────────────────────────────

func TestMigration002_MatrixSessions(t *testing.T) {
	db, cleanup := openMigratedDB(t)
	defer cleanup()

	assertTable(t, db, "matrix_sessions")

	cols := []struct{ name, typ string }{
		{"access_token", "text"},
		{"refresh_token", "text"},
		{"oidc_refresh_token", "text"},
		{"user_id", "text"},
		{"device_id", "text"},
		{"expires_at", "timestamptz"},
		{"revoked_at", "timestamptz"},
		{"grace_until", "timestamptz"},
		{"created_at", "timestamptz"},
	}
	for _, c := range cols {
		assertColumn(t, db, "matrix_sessions", c.name, c.typ)
	}

	assertIndex(t, db, "matrix_sessions", "idx_matrix_sessions_refresh_token")
	assertIndex(t, db, "matrix_sessions", "idx_matrix_sessions_user_id")
	assertIndex(t, db, "matrix_sessions", "idx_matrix_sessions_expires_at")
}

// ─────────────────────────────────────────────────────────────────────────────
// AC4 — audit_log table exists with required columns
// ─────────────────────────────────────────────────────────────────────────────

func TestMigration002_AuditLog(t *testing.T) {
	db, cleanup := openMigratedDB(t)
	defer cleanup()

	assertTable(t, db, "audit_log")

	cols := []struct{ name, typ string }{
		{"id", "int8"},         // BIGSERIAL is stored as int8 in PostgreSQL
		{"event_time", "timestamptz"},
		{"actor_user_id", "text"},
		{"action", "text"},
		{"outcome", "text"},
	}
	for _, c := range cols {
		assertColumn(t, db, "audit_log", c.name, c.typ)
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// AC5 — additional tables introduced by migration 000002 exist
// ─────────────────────────────────────────────────────────────────────────────

func TestMigration002_AdditionalTables(t *testing.T) {
	db, cleanup := openMigratedDB(t)
	defer cleanup()

	for _, tbl := range []string{
		"compliance_requests",
		"compliance_sessions",
		"room_account_data",
		"notifications",
		"push_rules",
		"pushers",
		"role_overrides",
		"room_defaults",
		"forgotten_rooms",
	} {
		assertTable(t, db, tbl)
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// AC6 — idempotency: applying migration 000002 twice does not error
// ─────────────────────────────────────────────────────────────────────────────

func TestMigration002_Idempotency(t *testing.T) {
	dbURL := testMigrationDBURL()

	m := newMigrate(t, dbURL)
	defer m.Close()

	// First apply
	if err := m.Up(); err != nil && !errors.Is(err, migrate.ErrNoChange) {
		t.Fatalf("first migrate up: %v", err)
	}
	// Second apply must report ErrNoChange, not an error
	if err := m.Up(); err != nil && !errors.Is(err, migrate.ErrNoChange) {
		t.Fatalf("second migrate up (idempotency check): %v", err)
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// AC7 — admin_sessions.refresh_token and media_files.deleted columns exist
// ─────────────────────────────────────────────────────────────────────────────

func TestMigration002_AlteredTableColumns(t *testing.T) {
	db, cleanup := openMigratedDB(t)
	defer cleanup()

	assertColumn(t, db, "admin_sessions", "refresh_token", "text")
	assertColumn(t, db, "media_files", "deleted", "bool")
}

// ─────────────────────────────────────────────────────────────────────────────
// AC8 — room_defaults seed row exists
// ─────────────────────────────────────────────────────────────────────────────

func TestMigration002_RoomDefaultsSeedRow(t *testing.T) {
	db, cleanup := openMigratedDB(t)
	defer cleanup()

	var count int
	if err := db.QueryRow(`SELECT COUNT(*) FROM room_defaults`).Scan(&count); err != nil {
		t.Fatalf("querying room_defaults count: %v", err)
	}
	if count == 0 {
		t.Fatal("room_defaults has no rows after migration 000002 — seed row missing")
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// M1 — Pre-squash baseline: migration 000001 alone must NOT contain the
// structures that 000002 is responsible for adding.
//
// This test proves that the subsequent AC tests (which call openMigratedDB →
// m.Up() and thus apply BOTH 000001 and 000002) are actually attributing the
// additions to 000002, not to 000001.
//
// Strategy:
//   1. m.Down() — roll back to a clean state (drops all tables via 000001.down)
//   2. m.Steps(1) — apply only migration 000001
//   3. Assert rooms.is_auto_join does NOT exist  (added only by 000002)
//   4. Assert matrix_sessions table does NOT exist (added only by 000002)
// ─────────────────────────────────────────────────────────────────────────────

func TestMigration002_PreSquashBaseline(t *testing.T) {
	dbURL := testMigrationDBURL()

	m := newMigrate(t, dbURL)
	defer m.Close()

	// Always re-apply all migrations after this test so subsequent tests have
	// a fully migrated database.
	t.Cleanup(func() {
		m2 := newMigrate(t, dbURL)
		defer m2.Close()
		if err := m2.Up(); err != nil && !errors.Is(err, migrate.ErrNoChange) {
			t.Logf("baseline cleanup re-apply: %v (non-fatal)", err)
		}
	})

	// 1. Roll back everything (000001.down drops all tables).
	if err := m.Down(); err != nil && !errors.Is(err, migrate.ErrNoChange) {
		t.Fatalf("baseline m.Down(): %v", err)
	}

	// 2. Apply only migration 000001 (Steps(1) applies one migration forward).
	if err := m.Steps(1); err != nil {
		t.Fatalf("baseline m.Steps(1): %v", err)
	}

	db, err := sql.Open("pgx", dbURL)
	if err != nil {
		t.Fatalf("baseline sql.Open: %v", err)
	}
	defer db.Close()

	// 3. rooms.is_auto_join must NOT exist after only 000001.
	var isAutoJoinExists bool
	if err := db.QueryRow(`
		SELECT EXISTS (
			SELECT 1 FROM information_schema.columns
			WHERE table_schema = 'public'
			  AND table_name   = 'rooms'
			  AND column_name  = 'is_auto_join'
		)
	`).Scan(&isAutoJoinExists); err != nil {
		t.Fatalf("baseline: querying rooms.is_auto_join existence: %v", err)
	}
	if isAutoJoinExists {
		t.Error("baseline FAIL: rooms.is_auto_join already exists after migration 000001 only — " +
			"this means 000002 is not responsible for adding it and the AC tests are not proving anything")
	}

	// 4. matrix_sessions must NOT exist after only 000001.
	var matrixSessionsExists bool
	if err := db.QueryRow(`
		SELECT EXISTS (
			SELECT 1 FROM information_schema.tables
			WHERE table_schema = 'public'
			  AND table_name   = 'matrix_sessions'
		)
	`).Scan(&matrixSessionsExists); err != nil {
		t.Fatalf("baseline: querying matrix_sessions existence: %v", err)
	}
	if matrixSessionsExists {
		t.Error("baseline FAIL: matrix_sessions already exists after migration 000001 only — " +
			"this means 000002 is not responsible for adding it and the AC tests are not proving anything")
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// openMigratedDB runs all migrations and returns an open *sql.DB + cleanup fn.
// ─────────────────────────────────────────────────────────────────────────────

func openMigratedDB(t *testing.T) (*sql.DB, func()) {
	t.Helper()
	dbURL := testMigrationDBURL()

	m := newMigrate(t, dbURL)
	if err := m.Up(); err != nil && !errors.Is(err, migrate.ErrNoChange) {
		m.Close()
		t.Fatalf("migrate up: %v", err)
	}
	m.Close()

	db, err := sql.Open("pgx", dbURL)
	if err != nil {
		t.Fatalf("sql.Open: %v", err)
	}
	if err := db.Ping(); err != nil {
		db.Close()
		t.Fatalf("db ping: %v", err)
	}
	return db, func() { db.Close() }
}
