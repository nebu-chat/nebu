//go:build integration

package migrations_test

// migrations_042_integration_test.go — Story 11.1 / Story 13.14 squash:
// Integration tests for search_vector column, GIN index, and trigger on events table.
// After Story 13.14 squash, all schema from migrations 1–49 is in a single 000001_init.up.sql.
// These tests verify the final schema state after applying the squashed migration.
//
// Run:  go test -tags=integration ./gateway/migrations/...

import (
	"database/sql"
	"errors"
	"strings"
	"testing"

	"github.com/golang-migrate/migrate/v4"
	_ "github.com/golang-migrate/migrate/v4/database/pgx/v5"
	_ "github.com/jackc/pgx/v5/stdlib"
)

// ─────────────────────────────────────────────────────────────────────────────
// AC1 — Column + GIN index exist after squashed migration
// ─────────────────────────────────────────────────────────────────────────────

// TestMigration042_ColumnAndIndexExist verifies that after the squashed migration is applied:
//   - events.search_vector tsvector column exists
//   - events_search_vector_gin_idx GIN index exists
func TestMigration042_ColumnAndIndexExist(t *testing.T) {
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

	if err := db.Ping(); err != nil {
		t.Fatalf("cannot connect to PostgreSQL at %q: %v", dbURL, err)
	}

	// ── 1. events table must exist ────────────────────────────────────────────
	var tableExists bool
	if err := db.QueryRow(`
		SELECT EXISTS (
			SELECT 1
			FROM information_schema.tables
			WHERE table_schema = 'public'
			  AND table_name   = 'events'
		)
	`).Scan(&tableExists); err != nil {
		t.Fatalf("querying events table existence: %v", err)
	}
	if !tableExists {
		t.Fatal("table 'events' does not exist — squashed migration not applied")
	}

	// ── 2. search_vector column — tsvector, nullable ──────────────────────────
	var colDataType string
	err = db.QueryRow(`
		SELECT udt_name
		FROM information_schema.columns
		WHERE table_schema = 'public'
		  AND table_name   = 'events'
		  AND column_name  = 'search_vector'
	`).Scan(&colDataType)
	if err == sql.ErrNoRows {
		t.Fatal("AC1 FAIL: column events.search_vector is missing after squashed migration")
	}
	if err != nil {
		t.Fatalf("querying events.search_vector column: %v", err)
	}
	if colDataType != "tsvector" {
		t.Errorf("AC1 FAIL: events.search_vector udt_name: expected 'tsvector', got %q", colDataType)
	}

	// ── 3. GIN index exists ───────────────────────────────────────────────────
	var indexName string
	err = db.QueryRow(`
		SELECT indexname
		FROM pg_indexes
		WHERE schemaname = 'public'
		  AND tablename  = 'events'
		  AND indexname  = 'events_search_vector_gin_idx'
	`).Scan(&indexName)
	if err == sql.ErrNoRows {
		t.Fatal("AC1 FAIL: GIN index events_search_vector_gin_idx is missing after squashed migration")
	}
	if err != nil {
		t.Fatalf("querying pg_indexes for events_search_vector_gin_idx: %v", err)
	}

	// Verify it is actually a GIN index.
	var indexDef string
	if err := db.QueryRow(`
		SELECT indexdef
		FROM pg_indexes
		WHERE schemaname = 'public'
		  AND tablename  = 'events'
		  AND indexname  = 'events_search_vector_gin_idx'
	`).Scan(&indexDef); err != nil {
		t.Fatalf("querying indexdef for events_search_vector_gin_idx: %v", err)
	}
	if !strings.Contains(strings.ToUpper(indexDef), "USING GIN") {
		t.Errorf("AC1 FAIL: index events_search_vector_gin_idx is not a GIN index — indexdef: %q", indexDef)
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// AC2 — Automatic population via trigger
// ─────────────────────────────────────────────────────────────────────────────

// TestMigration042_TriggerPopulatesSearchVector verifies that:
//   - Inserting an m.room.message event with body content populates search_vector
//   - The populated search_vector matches a tsquery for a word in the body
//   - Non-message events (state events) get a non-null (empty) tsvector
func TestMigration042_TriggerPopulatesSearchVector(t *testing.T) {
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

	if err := db.Ping(); err != nil {
		t.Fatalf("cannot connect to PostgreSQL at %q: %v", dbURL, err)
	}

	// We need a valid room to satisfy the FK constraint on events.room_id.
	testRoomID := "!test-trigger-042:test.nebu.local"
	_, _ = db.Exec(`DELETE FROM events WHERE room_id = $1`, testRoomID)
	_, _ = db.Exec(`DELETE FROM rooms WHERE room_id = $1`, testRoomID)

	_, err = db.Exec(`
		INSERT INTO rooms (room_id, visibility, created_at)
		VALUES ($1, 'private', 1000)
	`, testRoomID)
	if err != nil {
		t.Fatalf("inserting test room %q: %v", testRoomID, err)
	}
	t.Cleanup(func() {
		_, _ = db.Exec(`DELETE FROM events WHERE room_id = $1`, testRoomID)
		_, _ = db.Exec(`DELETE FROM rooms WHERE room_id = $1`, testRoomID)
	})

	// Insert a message event. The trigger should populate search_vector automatically.
	testEventID := "$test-trigger-042-ev1"
	_, err = db.Exec(`
		INSERT INTO events (event_id, room_id, sender, event_type, content, origin_server_ts)
		VALUES ($1, $2, '@test-trigger-042:test.nebu.local', 'm.room.message',
		        '{"msgtype":"m.text","body":"hello world"}', 1000)
	`, testEventID, testRoomID)
	if err != nil {
		t.Fatalf("inserting test event %q: %v", testEventID, err)
	}

	// ── 1. search_vector must be non-null ─────────────────────────────────────
	var searchVector sql.NullString
	if err := db.QueryRow(`
		SELECT search_vector::text FROM events WHERE event_id = $1
	`, testEventID).Scan(&searchVector); err != nil {
		t.Fatalf("querying search_vector for event %q: %v", testEventID, err)
	}
	if !searchVector.Valid || searchVector.String == "" {
		t.Fatalf("AC2 FAIL: events.search_vector is NULL after INSERT — " +
			"trigger events_search_vector_trigger was not fired. Got: NULL")
	}

	// ── 2. search_vector matches 'hello' via tsquery ──────────────────────────
	var matches bool
	if err := db.QueryRow(`
		SELECT search_vector @@ to_tsquery('pg_catalog.simple', 'hello')
		FROM events
		WHERE event_id = $1
	`, testEventID).Scan(&matches); err != nil {
		t.Fatalf("tsquery match check for event %q: %v", testEventID, err)
	}
	if !matches {
		t.Errorf("AC2 FAIL: search_vector does not match to_tsquery('pg_catalog.simple', 'hello') "+
			"for event %q. Got search_vector=%q", testEventID, searchVector.String)
	}

	// ── 3. Non-message (state) event gets non-null tsvector ───────────────────
	stateEventID := "$test-trigger-042-state"
	_, err = db.Exec(`
		INSERT INTO events (event_id, room_id, sender, event_type, content, origin_server_ts)
		VALUES ($1, $2, '@test-trigger-042:test.nebu.local', 'm.room.name',
		        '{"name":"Test Room"}', 1001)
	`, stateEventID, testRoomID)
	if err != nil {
		t.Fatalf("inserting non-message test event %q: %v", stateEventID, err)
	}

	var stateSearchVector sql.NullString
	if err := db.QueryRow(`
		SELECT search_vector::text FROM events WHERE event_id = $1
	`, stateEventID).Scan(&stateSearchVector); err != nil {
		t.Fatalf("querying search_vector for non-message event %q: %v", stateEventID, err)
	}
	if !stateSearchVector.Valid {
		t.Errorf("MINOR-2 FAIL: events.search_vector is NULL for non-message event %q after INSERT — "+
			"trigger must set search_vector = to_tsvector('pg_catalog.simple', '') for events with no body "+
			"(empty tsvector is acceptable, NULL is not)", stateEventID)
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// Down migration test is removed after squash:
// The squashed 000001_init.down.sql drops everything cleanly.
// Version-stepping tests (migrate to 41, apply 42, rollback to 41) are no longer
// meaningful because all schema is in version 1. The down-migration test for
// the squashed migration is covered by TestSquashedMigrationApplies in
// migrations_squash_integration_test.go (AC8).
// ─────────────────────────────────────────────────────────────────────────────
