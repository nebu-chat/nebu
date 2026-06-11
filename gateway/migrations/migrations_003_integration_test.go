//go:build integration

package migrations_test

// migrations_003_integration_test.go — Story: Fix Compliance RLS UPDATE Policies
// Integration tests for migration 000003_compliance_rls_hardening.
//
// Tests are RED until migration 000003 is applied:
//   - Tests 2 and 4 (blocked paths) fail because the current USING (true) policy
//     allows UPDATE on all rows. After migration 003, USING (status = 'pending')
//     and USING (revoked_at IS NULL) restrict the policy.
//
// Run:  go test -tags=integration ./gateway/migrations/...

import (
	"database/sql"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/golang-migrate/migrate/v4"
	_ "github.com/golang-migrate/migrate/v4/database/pgx/v5"
	_ "github.com/jackc/pgx/v5/stdlib"

	"github.com/nebu/nebu/migrations"
)

// TestMigration_ComplianceRequestsUpdatePolicy verifies that nebu_app can UPDATE
// a compliance_requests row when status = 'pending'.
//
// AC1 — allowed path:
//   Given: compliance_requests row with status = 'pending'
//   When:  UPDATE status = 'approved' via nebu_app
//   Then:  1 row affected
func TestMigration_ComplianceRequestsUpdatePolicy(t *testing.T) {
	dbURL := testMigrationDBURL()
	m := newMigrate(t, dbURL)
	defer m.Close()

	if err := m.Up(); err != nil && !errors.Is(err, migrate.ErrNoChange) {
		t.Fatalf("migrate up: %v", err)
	}

	db, err := sql.Open("pgx", dbURL)
	if err != nil {
		t.Fatalf("open db as nebu_app: %v", err)
	}
	defer db.Close()

	var id string
	err = db.QueryRow(`
		INSERT INTO compliance_requests
		  (requester_user_id, room_id, time_range_start, time_range_end, justification, status)
		VALUES ('sub-rls-001', '!test:server.example', NOW() - INTERVAL '1 hour', NOW(),
		        'RLS update allowed — pending row', 'pending')
		RETURNING id
	`).Scan(&id)
	if err != nil {
		t.Fatalf("inserting pending compliance_request: %v", err)
	}

	// Update status — USING (status = 'pending') matches, WITH CHECK (true) allows any new value.
	result, err := db.Exec(`UPDATE compliance_requests SET status = 'approved' WHERE id = $1`, id)
	if err != nil {
		t.Fatalf("[AC1] UPDATE pending→approved: unexpected error: %v", err)
	}

	rowsAffected, _ := result.RowsAffected()
	if rowsAffected != 1 {
		t.Errorf("[AC1] expected 1 row affected (UPDATE on pending row allowed), got %d", rowsAffected)
	}

	// Verify non-status columns are also updateable on pending rows (WITH CHECK is permissive).
	var id2 string
	err = db.QueryRow(`
		INSERT INTO compliance_requests
		  (requester_user_id, room_id, time_range_start, time_range_end, justification, status)
		VALUES ('sub-rls-001b', '!test:server.example', NOW() - INTERVAL '1 hour', NOW(),
		        'RLS update allowed — pending justification', 'pending')
		RETURNING id
	`).Scan(&id2)
	if err != nil {
		t.Fatalf("[AC1-justification] inserting second pending row: %v", err)
	}

	result2, err := db.Exec(`UPDATE compliance_requests SET justification = 'updated justification' WHERE id = $1`, id2)
	if err != nil {
		t.Fatalf("[AC1-justification] UPDATE justification on pending row: unexpected error: %v", err)
	}
	rowsAffected2, _ := result2.RowsAffected()
	if rowsAffected2 != 1 {
		t.Errorf("[AC1-justification] expected 1 row affected (non-status column also updateable on pending), got %d", rowsAffected2)
	}
}

// TestMigration_ComplianceRequestsUpdatePolicyBlocked verifies that nebu_app cannot
// UPDATE a compliance_requests row when status != 'pending'.
//
// AC1 — blocked path:
//   Given: compliance_requests row with status = 'approved'
//   When:  UPDATE justification = 'tampered' via nebu_app
//   Then:  0 rows affected (RLS blocks)
func TestMigration_ComplianceRequestsUpdatePolicyBlocked(t *testing.T) {
	dbURL := testMigrationDBURL()
	m := newMigrate(t, dbURL)
	defer m.Close()

	if err := m.Up(); err != nil && !errors.Is(err, migrate.ErrNoChange) {
		t.Fatalf("migrate up: %v", err)
	}

	db, err := sql.Open("pgx", dbURL)
	if err != nil {
		t.Fatalf("open db as nebu_app: %v", err)
	}
	defer db.Close()

	var id string
	err = db.QueryRow(`
		INSERT INTO compliance_requests
		  (requester_user_id, room_id, time_range_start, time_range_end, justification, status)
		VALUES ('sub-rls-002', '!test:server.example', NOW() - INTERVAL '1 hour', NOW(),
		        'RLS update blocked — approved row', 'approved')
		RETURNING id
	`).Scan(&id)
	if err != nil {
		t.Fatalf("inserting approved compliance_request: %v", err)
	}

	result, err := db.Exec(`UPDATE compliance_requests SET justification = 'tampered' WHERE id = $1`, id)
	if err != nil {
		// RLS with FORCE can surface as an error — also acceptable.
		t.Logf("[AC1-blocked] UPDATE on approved row returned error (RLS blocked): %v", err)
		return
	}

	rowsAffected, _ := result.RowsAffected()
	if rowsAffected != 0 {
		t.Errorf("[AC1-blocked] expected 0 rows affected (UPDATE on approved row blocked by RLS), got %d", rowsAffected)
	}
}

// TestMigration_ComplianceSessionsUpdatePolicy verifies that nebu_app can UPDATE
// a compliance_sessions row when revoked_at IS NULL.
//
// AC2 — allowed path:
//   Given: compliance_sessions row with revoked_at IS NULL
//   When:  UPDATE revoked_at = NOW() via nebu_app
//   Then:  1 row affected
func TestMigration_ComplianceSessionsUpdatePolicy(t *testing.T) {
	dbURL := testMigrationDBURL()
	m := newMigrate(t, dbURL)
	defer m.Close()

	if err := m.Up(); err != nil && !errors.Is(err, migrate.ErrNoChange) {
		t.Fatalf("migrate up: %v", err)
	}

	db, err := sql.Open("pgx", dbURL)
	if err != nil {
		t.Fatalf("open db as nebu_app: %v", err)
	}
	defer db.Close()

	var requestID string
	err = db.QueryRow(`
		INSERT INTO compliance_requests
		  (requester_user_id, room_id, time_range_start, time_range_end, justification, status)
		VALUES ('sub-rls-003', '!test:server.example', NOW() - INTERVAL '1 hour', NOW(),
		        'RLS sessions update allowed — active', 'approved')
		RETURNING id
	`).Scan(&requestID)
	if err != nil {
		t.Fatalf("inserting compliance_request for FK: %v", err)
	}

	fakeTokenHash := make([]byte, 32)
	var sessionID string
	err = db.QueryRow(`
		INSERT INTO compliance_sessions (request_id, token_hash, expires_at)
		VALUES ($1, $2, NOW() + INTERVAL '86400 seconds')
		RETURNING id
	`, requestID, fakeTokenHash).Scan(&sessionID)
	if err != nil {
		t.Fatalf("inserting active compliance_session: %v", err)
	}

	result, err := db.Exec(`UPDATE compliance_sessions SET revoked_at = NOW() WHERE id = $1`, sessionID)
	if err != nil {
		t.Fatalf("[AC2] UPDATE active session: unexpected error: %v", err)
	}

	rowsAffected, _ := result.RowsAffected()
	if rowsAffected != 1 {
		t.Errorf("[AC2] expected 1 row affected (UPDATE on active session allowed), got %d", rowsAffected)
	}
}

// TestMigration_ComplianceSessionsUpdatePolicyBlocked verifies that nebu_app cannot
// UPDATE a compliance_sessions row when revoked_at IS NOT NULL.
//
// AC2 — blocked path:
//   Given: compliance_sessions row with revoked_at IS NOT NULL
//   When:  UPDATE revoked_at = NULL via nebu_app
//   Then:  0 rows affected (RLS blocks)
func TestMigration_ComplianceSessionsUpdatePolicyBlocked(t *testing.T) {
	dbURL := testMigrationDBURL()
	m := newMigrate(t, dbURL)
	defer m.Close()

	if err := m.Up(); err != nil && !errors.Is(err, migrate.ErrNoChange) {
		t.Fatalf("migrate up: %v", err)
	}

	db, err := sql.Open("pgx", dbURL)
	if err != nil {
		t.Fatalf("open db as nebu_app: %v", err)
	}
	defer db.Close()

	var requestID string
	err = db.QueryRow(`
		INSERT INTO compliance_requests
		  (requester_user_id, room_id, time_range_start, time_range_end, justification, status)
		VALUES ('sub-rls-004', '!test:server.example', NOW() - INTERVAL '1 hour', NOW(),
		        'RLS sessions update blocked — revoked', 'approved')
		RETURNING id
	`).Scan(&requestID)
	if err != nil {
		t.Fatalf("inserting compliance_request for FK: %v", err)
	}

	fakeTokenHash := make([]byte, 32)
	revokedAt := time.Now()
	var sessionID string
	err = db.QueryRow(`
		INSERT INTO compliance_sessions (request_id, token_hash, expires_at, revoked_at)
		VALUES ($1, $2, NOW() + INTERVAL '86400 seconds', $3)
		RETURNING id
	`, requestID, fakeTokenHash, revokedAt).Scan(&sessionID)
	if err != nil {
		t.Fatalf("inserting revoked compliance_session: %v", err)
	}

	// Attempt to clear revoked_at — USING (revoked_at IS NULL) filters out this row.
	result, err := db.Exec(`UPDATE compliance_sessions SET revoked_at = NULL WHERE id = $1`, sessionID)
	if err != nil {
		// RLS with FORCE can surface as an error — also acceptable.
		t.Logf("[AC2-blocked] UPDATE revoked_at=NULL on revoked session returned error (RLS blocked): %v", err)
	} else {
		rowsAffected, _ := result.RowsAffected()
		if rowsAffected != 0 {
			t.Errorf("[AC2-blocked] expected 0 rows affected (UPDATE on revoked session blocked by RLS), got %d", rowsAffected)
		}
	}

	// Prove the whole row is immutable (not just the revoked_at column).
	// A compromised app cannot extend the expiry on a revoked session either.
	result2, err := db.Exec(`UPDATE compliance_sessions SET expires_at = NOW() + INTERVAL '365 days' WHERE id = $1`, sessionID)
	if err != nil {
		t.Logf("[AC2-blocked-whole-row] UPDATE expires_at on revoked session returned error (RLS blocked): %v", err)
	} else {
		rowsAffected2, _ := result2.RowsAffected()
		if rowsAffected2 != 0 {
			t.Errorf("[AC2-blocked-whole-row] expected 0 rows affected (whole revoked row is immutable), got %d", rowsAffected2)
		}
	}
}

// TestMigration_ComplianceRequestsRejectedUpdateBlocked verifies that the blocked
// path applies to 'rejected' status as well as 'approved' (AC1 covers both).
//
// AC1 — rejected variant:
//   Given: compliance_requests row with status = 'rejected'
//   When:  UPDATE justification via nebu_app
//   Then:  0 rows affected (RLS blocks)
func TestMigration_ComplianceRequestsRejectedUpdateBlocked(t *testing.T) {
	dbURL := testMigrationDBURL()
	m := newMigrate(t, dbURL)
	defer m.Close()

	if err := m.Up(); err != nil && !errors.Is(err, migrate.ErrNoChange) {
		t.Fatalf("migrate up: %v", err)
	}

	db, err := sql.Open("pgx", dbURL)
	if err != nil {
		t.Fatalf("open db as nebu_app: %v", err)
	}
	defer db.Close()

	var id string
	err = db.QueryRow(`
		INSERT INTO compliance_requests
		  (requester_user_id, room_id, time_range_start, time_range_end, justification, status)
		VALUES ('sub-rls-005', '!test:server.example', NOW() - INTERVAL '1 hour', NOW(),
		        'RLS update blocked — rejected row', 'rejected')
		RETURNING id
	`).Scan(&id)
	if err != nil {
		t.Fatalf("inserting rejected compliance_request: %v", err)
	}

	result, err := db.Exec(`UPDATE compliance_requests SET justification = 'tampered' WHERE id = $1`, id)
	if err != nil {
		t.Logf("[AC1-rejected] UPDATE on rejected row returned error (RLS blocked): %v", err)
		return
	}

	rowsAffected, _ := result.RowsAffected()
	if rowsAffected != 0 {
		t.Errorf("[AC1-rejected] expected 0 rows affected (UPDATE on rejected row blocked by RLS), got %d", rowsAffected)
	}
}

// TestMigration_ComplianceRLSHardening_Idempotent verifies that the up migration SQL
// can be applied a second time without error (AC3).
//
// AC3 — idempotency:
//   The migration uses DROP POLICY IF EXISTS before CREATE POLICY, so applying the
//   SQL twice must not raise an error.
func TestMigration_ComplianceRLSHardening_Idempotent(t *testing.T) {
	dbURL := testMigrationDBURL()
	m := newMigrate(t, dbURL)
	defer m.Close()

	if err := m.Up(); err != nil && !errors.Is(err, migrate.ErrNoChange) {
		t.Fatalf("migrate up: %v", err)
	}

	db, err := sql.Open("pgx", dbURL)
	if err != nil {
		t.Fatalf("open db as nebu_app: %v", err)
	}
	defer db.Close()

	upSQL, err := migrations.FS.ReadFile("000003_compliance_rls_hardening.up.sql")
	if err != nil {
		t.Fatalf("[AC3] reading 000003_compliance_rls_hardening.up.sql from embedded FS: %v", err)
	}

	_, err = db.Exec(string(upSQL))
	if err != nil {
		t.Errorf("[AC3] idempotent re-apply of 000003_compliance_rls_hardening.up.sql errored: %v", err)
	}

	// Verify the policy was actually created with the correct USING clause.
	var qual string
	err = db.QueryRow(`
		SELECT pg_get_expr(polqual, polrelid)
		FROM pg_policy
		WHERE polrelid = 'public.compliance_requests'::regclass
		  AND polname = 'compliance_requests_update'
	`).Scan(&qual)
	if err != nil {
		t.Fatalf("[AC3] compliance_requests_update policy not found after migration: %v", err)
	}
	if !strings.Contains(qual, "pending") {
		t.Errorf("[AC3] compliance_requests_update USING clause missing 'pending': %q", qual)
	}
}

// TestMigration_ComplianceInsertSelectUnchanged verifies that INSERT and SELECT
// policies on both compliance tables remain unrestricted after migration 003 (AC4).
//
// AC4 — INSERT WITH CHECK (true) and SELECT USING (true) unchanged:
//   nebu_app can still insert any row and select all rows.
func TestMigration_ComplianceInsertSelectUnchanged(t *testing.T) {
	dbURL := testMigrationDBURL()
	m := newMigrate(t, dbURL)
	defer m.Close()

	if err := m.Up(); err != nil && !errors.Is(err, migrate.ErrNoChange) {
		t.Fatalf("migrate up: %v", err)
	}

	db, err := sql.Open("pgx", dbURL)
	if err != nil {
		t.Fatalf("open db as nebu_app: %v", err)
	}
	defer db.Close()

	// Use a transaction so the test row is cleaned up on rollback — prevents cross-run pollution.
	tx, err := db.Begin()
	if err != nil {
		t.Fatalf("begin tx: %v", err)
	}
	defer tx.Rollback() //nolint:errcheck

	// AC4 — INSERT policy unchanged: INSERT any row via nebu_app must succeed.
	result, err := tx.Exec(`
		INSERT INTO compliance_requests
		  (requester_user_id, room_id, time_range_start, time_range_end, justification, status)
		VALUES ('sub-rls-ac4', '!test:server.example', NOW() - INTERVAL '1 hour', NOW(),
		        'AC4 INSERT policy unchanged test row', 'approved')
	`)
	if err != nil {
		t.Errorf("[AC4] INSERT via nebu_app failed after migration 003: %v", err)
	} else {
		rowsAffected, _ := result.RowsAffected()
		if rowsAffected != 1 {
			t.Errorf("[AC4] INSERT: expected 1 row affected, got %d", rowsAffected)
		}
	}

	// AC4 — SELECT policy unchanged: inserted row must be visible within the same transaction.
	var count int
	if err = tx.QueryRow(
		`SELECT COUNT(*) FROM compliance_requests WHERE requester_user_id = 'sub-rls-ac4'`,
	).Scan(&count); err != nil {
		t.Errorf("[AC4] SELECT via nebu_app failed after migration 003: %v", err)
	} else if count != 1 {
		t.Errorf("[AC4] SELECT policy changed: expected exactly 1 row visible, got count=%d", count)
	}
}
