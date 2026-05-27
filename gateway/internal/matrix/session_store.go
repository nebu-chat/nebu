package matrix

import (
	"errors"
	"time"
)

// ErrMatrixSessionNotFound is returned by MatrixSessionStoreInterface methods when no
// matching session row exists (or the grace period has expired).
var ErrMatrixSessionNotFound = errors.New("matrix session not found")

// MatrixSession represents one row in the matrix_sessions table.
// Opaque access_token and refresh_token are stored as-is (no hashing);
// oidc_refresh_token is AES-256-GCM encrypted.
type MatrixSession struct {
	AccessToken            string
	RefreshToken           string
	EncryptedOIDCRefreshToken string // AES-256-GCM; empty = no OIDC RT stored
	UserID                 string
	DeviceID               string
	ExpiresAt              time.Time
	RevokedAt              *time.Time // nil = not hard-revoked
	GraceUntil             *time.Time // soft-revoke grace window end (AC4)
}

// MatrixSessionStoreInterface is the injectable interface for Matrix session persistence.
// Production implementation: *MatrixSessionStore in gateway/internal/db/.
type MatrixSessionStoreInterface interface {
	// Create inserts a new session row.
	Create(params MatrixSessionCreateParams) error
	// GetByAccessToken looks up a session by opaque access_token.
	// Returns (nil, ErrMatrixSessionNotFound) when not found.
	GetByAccessToken(accessToken string) (*MatrixSession, error)
	// GetByRefreshToken looks up a session by opaque refresh_token.
	// For old (grace-period) refresh tokens this returns the session even if revoked_at is set,
	// as long as grace_until > NOW(). Returns (nil, ErrMatrixSessionNotFound) when not found or
	// grace period has expired.
	GetByRefreshToken(refreshToken string) (*MatrixSession, error)
	// RotateTokens atomically inserts a new session and soft-revokes the old one.
	// The old AT row is marked revoked_at = NOW(), grace_until = NOW() + 60s.
	RotateTokens(params MatrixSessionRotateParams) error
	// MarkAccessTokenUsed immediately expires the grace period on any old RT that was
	// replaced by this AT. Called at the start of every authenticated request.
	MarkAccessTokenUsed(accessToken string) error
	// Revoke hard-revokes a session row (called on logout).
	Revoke(accessToken string) error
	// CleanupExpired deletes rows where expires_at < NOW() - INTERVAL '7 days'.
	// Returns the number of rows deleted.
	CleanupExpired() (int64, error)
}

// MatrixSessionCreateParams holds the data required to create a new matrix session.
type MatrixSessionCreateParams struct {
	AccessToken               string
	RefreshToken              string
	EncryptedOIDCRefreshToken string // may be empty
	UserID                    string
	DeviceID                  string
	ExpiresAt                 time.Time
}

// MatrixSessionRotateParams holds the data required to rotate tokens in a matrix session.
type MatrixSessionRotateParams struct {
	OldAccessToken            string
	NewAccessToken            string
	NewRefreshToken           string
	NewEncryptedOIDCRefreshToken string
	NewExpiresAt              time.Time
}
