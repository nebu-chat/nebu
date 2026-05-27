package db_test

// matrix_session_store_test.go — Story: oidc-session-refresh
//
// RED PHASE: Unit + integration tests for MatrixSessionStore.
//
// These tests MUST FAIL until:
//   1. The matrix_sessions DB migration is applied
//   2. MatrixSessionStore is implemented in gateway/internal/db/
//   3. RotateTokens implements the grace-period semantics (old RT valid until
//      new AT or new RT is first used)
//
// Test coverage (maps to Acceptance Tests item 7 in the story):
//   - Create: inserts a new session row (AT hash, RT hash, user_id, device_id, expires_at)
//   - GetByAccessToken: retrieves a session by opaque AT; returns ErrNotFound for unknown AT
//   - GetByRefreshToken: retrieves a session by opaque RT; returns ErrNotFound for unknown RT
//   - RotateTokens: replaces AT+RT atomically, keeps old RT valid during grace period
//   - Revoke: deletes a session row; subsequent lookups return ErrNotFound
//   - CleanupExpired: removes rows where expires_at < now()
//
// This is an integration test (uses a real DB) — run with:
//   go test -tags=integration ./internal/db/ -run TestMatrixSessionStore
//
// The build tag is NOT set here intentionally — these are unit-level tests
// that reference the MatrixSessionStore type. They compile-fail in red phase
// because the type does not exist yet.

import (
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"testing"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"

	"github.com/nebu/nebu/internal/db"
)

// ─── Helper ───────────────────────────────────────────────────────────────────

// randomOpaqueToken generates a 32-byte (64-char hex) opaque token,
// matching the format that MatrixSessionStore.Create should produce.
func randomOpaqueToken(t *testing.T) string {
	t.Helper()
	buf := make([]byte, 32)
	if _, err := rand.Read(buf); err != nil {
		t.Fatalf("rand.Read: %v", err)
	}
	return hex.EncodeToString(buf)
}

// openTestDB opens a real PostgreSQL connection using the standard test env var.
// Skip the test gracefully when no DB URL is provided (unit-only CI runs).
func openTestDB(t *testing.T) *sql.DB {
	t.Helper()
	dsn := "postgres://nebu:nebu_dev_password@localhost:5432/nebu?sslmode=disable"
	sqlDB, err := sql.Open("pgx", dsn)
	if err != nil {
		t.Skipf("cannot open DB (skipping integration test): %v", err)
	}
	if err := sqlDB.Ping(); err != nil {
		t.Skipf("DB unreachable (skipping integration test): %v", err)
	}
	t.Cleanup(func() { _ = sqlDB.Close() })
	return sqlDB
}

// ─── RED: Type existence check ────────────────────────────────────────────────
//
// This block will cause a compile error in red phase because MatrixSessionStore
// does not yet exist. That IS the intended failure mode.

// ensureMatrixSessionStoreTypeExists is a compile-time check.
// It verifies that MatrixSessionStore satisfies the MatrixSessionStoreInterface.
// RED: compile error — neither the type nor the interface exist yet.
var _ = func() {
	// This function body is never called; it only needs to compile.
	// If MatrixSessionStore does not implement MatrixSessionStoreInterface,
	// the Go compiler will report an error at this line.
	//
	// RED FAILURE MESSAGE: "undefined: db.MatrixSessionStore" or
	//   "db.MatrixSessionStore does not implement db.MatrixSessionStoreInterface"
	var _ db.MatrixSessionStoreInterface = (*db.MatrixSessionStore)(nil)
}

// ─── AC7-Unit-1: Create ───────────────────────────────────────────────────────

// TestMatrixSessionStore_Create_InsertsRow verifies that Create inserts a session
// row into matrix_sessions and that the row can be retrieved by AT.
//
// RED: fails because MatrixSessionStore type does not exist yet.
func TestMatrixSessionStore_Create_InsertsRow(t *testing.T) {
	sqlDB := openTestDB(t)
	store := db.NewMatrixSessionStore(sqlDB)

	at := randomOpaqueToken(t)
	rt := randomOpaqueToken(t)
	expiresAt := time.Now().Add(8 * time.Hour)

	params := db.MatrixSessionCreateParams{
		AccessToken:  at,
		RefreshToken: rt,
		UserID:       "@test_user:localhost",
		DeviceID:     fmt.Sprintf("DEVICE_%s", at[:8]),
		ExpiresAt:    expiresAt,
	}

	if err := store.Create(params); err != nil {
		t.Fatalf("Create: %v", err)
	}

	// Verify the row is retrievable by access token.
	session, err := store.GetByAccessToken(at)
	if err != nil {
		t.Fatalf("GetByAccessToken after Create: %v", err)
	}
	if session.UserID != "@test_user:localhost" {
		t.Errorf("UserID: got %q, want %q", session.UserID, "@test_user:localhost")
	}
	if session.DeviceID != params.DeviceID {
		t.Errorf("DeviceID: got %q, want %q", session.DeviceID, params.DeviceID)
	}
	if session.ExpiresAt.IsZero() {
		t.Error("ExpiresAt should not be zero")
	}

	// Cleanup
	_ = store.Revoke(at)
}

// ─── AC7-Unit-2: GetByAccessToken — not found ─────────────────────────────────

// TestMatrixSessionStore_GetByAccessToken_NotFound verifies that GetByAccessToken
// returns a sentinel error (ErrNotFound or sql.ErrNoRows) for an unknown AT.
//
// RED: fails because MatrixSessionStore type does not exist yet.
func TestMatrixSessionStore_GetByAccessToken_NotFound(t *testing.T) {
	sqlDB := openTestDB(t)
	store := db.NewMatrixSessionStore(sqlDB)

	_, err := store.GetByAccessToken(randomOpaqueToken(t))
	if err == nil {
		t.Fatal("expected error for unknown access token, got nil")
	}
	// Accept either sql.ErrNoRows or a wrapped sentinel.
	if !errors.Is(err, sql.ErrNoRows) && !errors.Is(err, db.ErrMatrixSessionNotFound) {
		t.Errorf("expected ErrNoRows or ErrMatrixSessionNotFound, got: %v", err)
	}
}

// ─── AC7-Unit-3: GetByRefreshToken ────────────────────────────────────────────

// TestMatrixSessionStore_GetByRefreshToken_ReturnsSession verifies that a session
// created with Create is retrievable by its refresh token.
//
// RED: fails because MatrixSessionStore type does not exist yet.
func TestMatrixSessionStore_GetByRefreshToken_ReturnsSession(t *testing.T) {
	sqlDB := openTestDB(t)
	store := db.NewMatrixSessionStore(sqlDB)

	at := randomOpaqueToken(t)
	rt := randomOpaqueToken(t)
	if err := store.Create(db.MatrixSessionCreateParams{
		AccessToken:  at,
		RefreshToken: rt,
		UserID:       "@test_rt:localhost",
		DeviceID:     "RTDEVICE",
		ExpiresAt:    time.Now().Add(time.Hour),
	}); err != nil {
		t.Fatalf("Create: %v", err)
	}
	defer store.Revoke(at) //nolint:errcheck

	session, err := store.GetByRefreshToken(rt)
	if err != nil {
		t.Fatalf("GetByRefreshToken: %v", err)
	}
	if session.UserID != "@test_rt:localhost" {
		t.Errorf("UserID: got %q, want %q", session.UserID, "@test_rt:localhost")
	}
}

// ─── AC7-Unit-4: RotateTokens — grace period ─────────────────────────────────

// TestMatrixSessionStore_RotateTokens_OldRTValidDuringGracePeriod verifies
// the Matrix spec MUST requirement: the old RT remains valid until the new AT
// or new RT is first used.
//
// Sequence:
//   AT_A + RT_A → RotateTokens → AT_B + RT_B
//   GetByRefreshToken(RT_A) → must succeed (grace period, AT_B not yet used)
//   MarkAccessTokenUsed(AT_B)
//   GetByRefreshToken(RT_A) → must fail (grace period over)
//
// RED: fails because MatrixSessionStore type does not exist yet.
func TestMatrixSessionStore_RotateTokens_OldRTValidDuringGracePeriod(t *testing.T) {
	sqlDB := openTestDB(t)
	store := db.NewMatrixSessionStore(sqlDB)

	atA := randomOpaqueToken(t)
	rtA := randomOpaqueToken(t)
	if err := store.Create(db.MatrixSessionCreateParams{
		AccessToken:  atA,
		RefreshToken: rtA,
		UserID:       "@test_grace:localhost",
		DeviceID:     "GRACEDEVICE",
		ExpiresAt:    time.Now().Add(time.Hour),
	}); err != nil {
		t.Fatalf("Create: %v", err)
	}

	atB := randomOpaqueToken(t)
	rtB := randomOpaqueToken(t)
	if err := store.RotateTokens(db.MatrixSessionRotateParams{
		OldAccessToken:  atA,
		NewAccessToken:  atB,
		NewRefreshToken: rtB,
		NewExpiresAt:    time.Now().Add(8 * time.Hour),
	}); err != nil {
		t.Fatalf("RotateTokens: %v", err)
	}

	// Grace period: RT_A must still be valid (AT_B not used yet).
	_, err := store.GetByRefreshToken(rtA)
	if err != nil {
		t.Fatalf("GetByRefreshToken(RT_A) during grace period: expected success, got: %v", err)
	}

	// Activate new AT (first use).
	if err := store.MarkAccessTokenUsed(atB); err != nil {
		t.Fatalf("MarkAccessTokenUsed(AT_B): %v", err)
	}

	// Grace period over: RT_A must now be revoked.
	_, err = store.GetByRefreshToken(rtA)
	if err == nil {
		t.Fatal("GetByRefreshToken(RT_A) after new AT used: expected error, got nil (grace period should be over)")
	}
}

// ─── AC7-Unit-5: Revoke ───────────────────────────────────────────────────────

// TestMatrixSessionStore_Revoke_RemovesSession verifies that Revoke removes the
// session row and subsequent lookups return not-found.
//
// RED: fails because MatrixSessionStore type does not exist yet.
func TestMatrixSessionStore_Revoke_RemovesSession(t *testing.T) {
	sqlDB := openTestDB(t)
	store := db.NewMatrixSessionStore(sqlDB)

	at := randomOpaqueToken(t)
	rt := randomOpaqueToken(t)
	if err := store.Create(db.MatrixSessionCreateParams{
		AccessToken:  at,
		RefreshToken: rt,
		UserID:       "@test_revoke:localhost",
		DeviceID:     "REVOKEDEVICE",
		ExpiresAt:    time.Now().Add(time.Hour),
	}); err != nil {
		t.Fatalf("Create: %v", err)
	}

	if err := store.Revoke(at); err != nil {
		t.Fatalf("Revoke: %v", err)
	}

	_, err := store.GetByAccessToken(at)
	if err == nil {
		t.Fatal("GetByAccessToken after Revoke: expected error (session removed), got nil")
	}
}

// ─── AC7-Unit-6: CleanupExpired ───────────────────────────────────────────────

// TestMatrixSessionStore_CleanupExpired_RemovesExpiredRows verifies that
// CleanupExpired deletes rows with expires_at < now() and leaves valid rows.
//
// RED: fails because MatrixSessionStore type does not exist yet.
func TestMatrixSessionStore_CleanupExpired_RemovesExpiredRows(t *testing.T) {
	sqlDB := openTestDB(t)
	store := db.NewMatrixSessionStore(sqlDB)

	// Insert an already-expired session.
	atExpired := randomOpaqueToken(t)
	rtExpired := randomOpaqueToken(t)
	if err := store.Create(db.MatrixSessionCreateParams{
		AccessToken:  atExpired,
		RefreshToken: rtExpired,
		UserID:       "@test_expired:localhost",
		DeviceID:     "EXPIREDDEVICE",
		ExpiresAt:    time.Now().Add(-2 * time.Second), // already expired
	}); err != nil {
		t.Fatalf("Create expired session: %v", err)
	}

	// Insert a still-valid session.
	atValid := randomOpaqueToken(t)
	rtValid := randomOpaqueToken(t)
	if err := store.Create(db.MatrixSessionCreateParams{
		AccessToken:  atValid,
		RefreshToken: rtValid,
		UserID:       "@test_valid:localhost",
		DeviceID:     "VALIDDEVICE",
		ExpiresAt:    time.Now().Add(time.Hour),
	}); err != nil {
		t.Fatalf("Create valid session: %v", err)
	}
	defer store.Revoke(atValid) //nolint:errcheck

	// Run cleanup.
	n, err := store.CleanupExpired()
	if err != nil {
		t.Fatalf("CleanupExpired: %v", err)
	}
	if n < 1 {
		t.Errorf("CleanupExpired: expected at least 1 row deleted, got %d", n)
	}

	// Expired session must be gone.
	_, err = store.GetByAccessToken(atExpired)
	if err == nil {
		t.Fatal("GetByAccessToken after CleanupExpired: expired session still exists")
	}

	// Valid session must still be present.
	_, err = store.GetByAccessToken(atValid)
	if err != nil {
		t.Fatalf("GetByAccessToken: valid session should survive CleanupExpired, got: %v", err)
	}
}
