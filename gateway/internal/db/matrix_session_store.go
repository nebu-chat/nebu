package db

import (
	"database/sql"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/nebu/nebu/internal/matrix"
	"github.com/nebu/nebu/internal/middleware"
)

// ErrMatrixSessionNotFound is a type alias for matrix.ErrMatrixSessionNotFound.
// Declared here for db_test package access without importing the matrix package.
var ErrMatrixSessionNotFound = matrix.ErrMatrixSessionNotFound

// MatrixSessionStoreInterface is a compile-time type alias for matrix.MatrixSessionStoreInterface.
// Declared here so that db_test package tests can use db.MatrixSessionStoreInterface
// without importing the matrix package (avoiding test import graph issues).
type MatrixSessionStoreInterface = matrix.MatrixSessionStoreInterface

// MatrixSessionCreateParams is a type alias for matrix.MatrixSessionCreateParams.
// Declared here for db_test package access.
type MatrixSessionCreateParams = matrix.MatrixSessionCreateParams

// MatrixSessionRotateParams is a type alias for matrix.MatrixSessionRotateParams.
// Declared here for db_test package access.
type MatrixSessionRotateParams = matrix.MatrixSessionRotateParams

// MatrixSessionStore implements matrix.MatrixSessionStoreInterface using PostgreSQL.
type MatrixSessionStore struct {
	db *sql.DB
}

// NewMatrixSessionStore creates a new MatrixSessionStore backed by the given *sql.DB.
func NewMatrixSessionStore(db *sql.DB) *MatrixSessionStore {
	return &MatrixSessionStore{db: db}
}

// Create inserts a new session row into matrix_sessions.
func (s *MatrixSessionStore) Create(params matrix.MatrixSessionCreateParams) error {
	var encOIDCRT *string
	if params.EncryptedOIDCRefreshToken != "" {
		encOIDCRT = &params.EncryptedOIDCRefreshToken
	}
	_, err := s.db.Exec(
		`INSERT INTO matrix_sessions
			(access_token, refresh_token, oidc_refresh_token, user_id, device_id, expires_at, created_at)
		 VALUES ($1, $2, $3, $4, $5, $6, NOW())`,
		params.AccessToken,
		params.RefreshToken,
		encOIDCRT,
		params.UserID,
		params.DeviceID,
		params.ExpiresAt,
	)
	if err != nil {
		return fmt.Errorf("inserting matrix session: %w", err)
	}
	return nil
}

// GetByAccessToken looks up a session by opaque access_token.
// Returns (nil, ErrMatrixSessionNotFound) when no matching row exists.
func (s *MatrixSessionStore) GetByAccessToken(accessToken string) (*matrix.MatrixSession, error) {
	var sess matrix.MatrixSession
	var revokedAt sql.NullTime
	var graceUntil sql.NullTime
	var encOIDCRT sql.NullString

	err := s.db.QueryRow(
		`SELECT access_token, refresh_token, oidc_refresh_token, user_id, device_id,
		        expires_at, revoked_at, grace_until
		 FROM matrix_sessions WHERE access_token = $1`,
		accessToken,
	).Scan(
		&sess.AccessToken,
		&sess.RefreshToken,
		&encOIDCRT,
		&sess.UserID,
		&sess.DeviceID,
		&sess.ExpiresAt,
		&revokedAt,
		&graceUntil,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrMatrixSessionNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("querying matrix session by access_token: %w", err)
	}
	if revokedAt.Valid {
		t := revokedAt.Time
		sess.RevokedAt = &t
	}
	if graceUntil.Valid {
		t := graceUntil.Time
		sess.GraceUntil = &t
	}
	if encOIDCRT.Valid {
		sess.EncryptedOIDCRefreshToken = encOIDCRT.String
	}
	return &sess, nil
}

// GetByRefreshToken looks up a session by opaque refresh_token.
// Returns the session if:
//   - revoked_at IS NULL (active session), OR
//   - revoked_at IS NOT NULL but grace_until > NOW() (old RT in grace period)
//
// Returns (nil, ErrMatrixSessionNotFound) when not found or grace expired.
func (s *MatrixSessionStore) GetByRefreshToken(refreshToken string) (*matrix.MatrixSession, error) {
	var sess matrix.MatrixSession
	var revokedAt sql.NullTime
	var graceUntil sql.NullTime
	var encOIDCRT sql.NullString

	err := s.db.QueryRow(
		`SELECT access_token, refresh_token, oidc_refresh_token, user_id, device_id,
		        expires_at, revoked_at, grace_until
		 FROM matrix_sessions
		 WHERE refresh_token = $1
		   AND (revoked_at IS NULL OR grace_until > NOW())`,
		refreshToken,
	).Scan(
		&sess.AccessToken,
		&sess.RefreshToken,
		&encOIDCRT,
		&sess.UserID,
		&sess.DeviceID,
		&sess.ExpiresAt,
		&revokedAt,
		&graceUntil,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrMatrixSessionNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("querying matrix session by refresh_token: %w", err)
	}
	if revokedAt.Valid {
		t := revokedAt.Time
		sess.RevokedAt = &t
	}
	if graceUntil.Valid {
		t := graceUntil.Time
		sess.GraceUntil = &t
	}
	if encOIDCRT.Valid {
		sess.EncryptedOIDCRefreshToken = encOIDCRT.String
	}
	return &sess, nil
}

// RotateTokens atomically replaces the session's AT+RT pair.
// The old session row is soft-revoked: revoked_at = NOW(), grace_until = NOW() + 60s.
// A new row is inserted with the new AT, RT, and expiry.
// Returns ErrMatrixSessionNotFound if oldAccessToken is not found.
func (s *MatrixSessionStore) RotateTokens(params matrix.MatrixSessionRotateParams) error {
	tx, err := s.db.Begin()
	if err != nil {
		return fmt.Errorf("beginning RotateTokens transaction: %w", err)
	}
	defer tx.Rollback() //nolint:errcheck

	// 1. Soft-revoke old session row. grace_until gives the old RT a 60s grace window.
	res, err := tx.Exec(
		`UPDATE matrix_sessions
		 SET revoked_at = NOW(), grace_until = NOW() + INTERVAL '60 seconds'
		 WHERE access_token = $1 AND revoked_at IS NULL`,
		params.OldAccessToken,
	)
	if err != nil {
		return fmt.Errorf("soft-revoking old matrix session: %w", err)
	}
	rowsAffected, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("checking RotateTokens rows affected: %w", err)
	}
	if rowsAffected == 0 {
		return ErrMatrixSessionNotFound
	}

	// 2. Read old row to copy user_id and device_id to the new row.
	var userID, deviceID string
	var encOIDCRT sql.NullString
	err = tx.QueryRow(
		`SELECT user_id, device_id, oidc_refresh_token FROM matrix_sessions WHERE access_token = $1`,
		params.OldAccessToken,
	).Scan(&userID, &deviceID, &encOIDCRT)
	if err != nil {
		return fmt.Errorf("reading old matrix session for rotate: %w", err)
	}

	// Use new encrypted OIDC RT if provided, otherwise carry over the old one.
	newEncOIDCRT := params.NewEncryptedOIDCRefreshToken
	if newEncOIDCRT == "" && encOIDCRT.Valid {
		newEncOIDCRT = encOIDCRT.String
	}
	var newEncOIDCRTPtr *string
	if newEncOIDCRT != "" {
		newEncOIDCRTPtr = &newEncOIDCRT
	}

	// 3. Insert new session row.
	_, err = tx.Exec(
		`INSERT INTO matrix_sessions
			(access_token, refresh_token, oidc_refresh_token, user_id, device_id, expires_at, created_at)
		 VALUES ($1, $2, $3, $4, $5, $6, NOW())`,
		params.NewAccessToken,
		params.NewRefreshToken,
		newEncOIDCRTPtr,
		userID,
		deviceID,
		params.NewExpiresAt,
	)
	if err != nil {
		return fmt.Errorf("inserting new matrix session after rotate: %w", err)
	}

	return tx.Commit()
}

// MarkAccessTokenUsed immediately expires the grace period on any old RT that was
// soft-revoked as part of producing this AT. Called on every authenticated request
// when the AT was obtained via /refresh (but harmless to call unconditionally).
// This implements the Matrix spec MUST: old RT becomes invalid once new tokens are used.
func (s *MatrixSessionStore) MarkAccessTokenUsed(accessToken string) error {
	// Find the AT row and check if it was part of a rotation (i.e. the old row has
	// a non-null grace_until pointing to a row that supersedes this AT).
	// Strategy: expire grace_until on any soft-revoked row whose new replacement
	// is this accessToken. We do this by looking for the AT's device_id + user_id
	// and expiring old grace windows for the same user.
	//
	// Simpler correct approach: the AT row was inserted by RotateTokens which
	// soft-revoked the old row. We expire all soft-revoked rows for the same user
	// that have grace_until in the future. This is safe because:
	//   - Multiple concurrent sessions are possible (different devices)
	//   - We only expire old rows that are already soft-revoked (revoked_at IS NOT NULL)
	//   - Each rotation produces exactly one old-revoked + one new-active pair
	//
	// To scope correctly, we look up the user_id from the new AT row.
	var userID, deviceID string
	err := s.db.QueryRow(
		`SELECT user_id, device_id FROM matrix_sessions WHERE access_token = $1`,
		accessToken,
	).Scan(&userID, &deviceID)
	if errors.Is(err, sql.ErrNoRows) {
		// AT not found — nothing to expire
		return nil
	}
	if err != nil {
		return fmt.Errorf("looking up matrix session for MarkAccessTokenUsed: %w", err)
	}

	// Expire grace windows for all soft-revoked rows of this user+device (old RTs).
	// This ensures that once the new AT is used, the old RT's grace window is closed.
	_, err = s.db.Exec(
		`UPDATE matrix_sessions
		 SET grace_until = NOW()
		 WHERE user_id = $1 AND device_id = $2
		   AND revoked_at IS NOT NULL
		   AND grace_until > NOW()
		   AND access_token != $3`,
		userID, deviceID, accessToken,
	)
	if err != nil {
		return fmt.Errorf("expiring grace period on old matrix sessions: %w", err)
	}
	return nil
}

// Revoke hard-revokes a session row by deleting it.
// Called on logout. Subsequent GetByAccessToken returns ErrMatrixSessionNotFound.
func (s *MatrixSessionStore) Revoke(accessToken string) error {
	_, err := s.db.Exec(
		`DELETE FROM matrix_sessions WHERE access_token = $1`,
		accessToken,
	)
	if err != nil {
		return fmt.Errorf("revoking matrix session: %w", err)
	}
	return nil
}

// ─── middleware.OpaqueSessionLookup implementation ───────────────────────────

// LookupOpaqueToken implements middleware.OpaqueSessionLookup.
// Returns the session for the given opaque access token, or nil if not found.
// HasGraceWindow is set to true when there is a soft-revoked sibling row for the
// same user+device whose grace_until is still in the future. This tells the caller
// that MarkTokenUsed should be called to expire that grace window (AC4).
//
// Both the session lookup and the sibling grace-window check are folded into a
// single DB round-trip using a correlated EXISTS subquery (MINOR-2).
func (s *MatrixSessionStore) LookupOpaqueToken(accessToken string) (*middleware.OpaqueSessionLookupResult, error) {
	var userID, deviceID string
	var expiresAt time.Time
	var revokedAt sql.NullTime
	var hasGrace bool

	err := s.db.QueryRow(
		`SELECT m.user_id, m.device_id, m.expires_at, m.revoked_at,
		        EXISTS(
		            SELECT 1 FROM matrix_sessions s2
		            WHERE s2.user_id  = m.user_id
		              AND s2.device_id = m.device_id
		              AND s2.access_token != m.access_token
		              AND s2.revoked_at IS NOT NULL
		              AND s2.grace_until > NOW()
		        ) AS has_grace
		 FROM matrix_sessions m
		 WHERE m.access_token = $1`,
		accessToken,
	).Scan(&userID, &deviceID, &expiresAt, &revokedAt, &hasGrace)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		slog.Debug("LookupOpaqueToken: query failed", "err", err)
		return nil, fmt.Errorf("LookupOpaqueToken: %w", err)
	}

	// HasGraceWindow is only meaningful when the current AT is itself not revoked.
	// A revoked AT cannot have active siblings that need their grace window expired.
	hasGraceWindow := !revokedAt.Valid && hasGrace

	return &middleware.OpaqueSessionLookupResult{
		UserID:         userID,
		DeviceID:       deviceID,
		ExpiresAt:      expiresAt,
		Revoked:        revokedAt.Valid,
		HasGraceWindow: hasGraceWindow,
	}, nil
}

// MarkTokenUsed implements middleware.OpaqueSessionLookup.
// Delegates to MarkAccessTokenUsed to expire grace-period windows on old refresh tokens.
func (s *MatrixSessionStore) MarkTokenUsed(accessToken string) error {
	return s.MarkAccessTokenUsed(accessToken)
}

// CleanupExpired deletes rows where expires_at < NOW() - INTERVAL '7 days'.
// Returns the number of rows deleted.
func (s *MatrixSessionStore) CleanupExpired() (int64, error) {
	res, err := s.db.Exec(
		`DELETE FROM matrix_sessions WHERE expires_at < NOW() - INTERVAL '7 days'`,
	)
	if err != nil {
		return 0, fmt.Errorf("cleaning up expired matrix sessions: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return 0, fmt.Errorf("checking CleanupExpired rows affected: %w", err)
	}
	return n, nil
}
