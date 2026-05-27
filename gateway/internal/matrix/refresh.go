package matrix

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"time"
)

// RefreshConfig holds the dependencies for RefreshHandler.
type RefreshConfig struct {
	// Store is the MatrixSessionStore used to look up and rotate tokens.
	Store MatrixSessionStoreInterface
}

// RefreshHandler handles POST /_matrix/client/v3/refresh.
// This endpoint MUST be registered OUTSIDE of jwtMiddleware (no auth header required).
// Per Matrix spec v1.18 §refreshing-access-tokens (added v1.3).
type RefreshHandler struct {
	store MatrixSessionStoreInterface
}

// NewRefreshHandler creates a new RefreshHandler.
func NewRefreshHandler(cfg RefreshConfig) *RefreshHandler {
	return &RefreshHandler{store: cfg.Store}
}

// refreshRequest is the JSON body of POST /refresh.
type refreshRequest struct {
	RefreshToken string `json:"refresh_token"`
}

// refreshResponse is the JSON body of a successful /refresh response.
type refreshResponse struct {
	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token"`
	ExpiresInMs  int64  `json:"expires_in_ms"`
}

// generateOpaqueToken generates a cryptographically random 32-byte opaque token
// as a 64-character lowercase hex string. This format is:
//   - distinguishable from JWTs (no "." characters)
//   - 256 bits of entropy (same as generateSID in admin package)
//
// Per Matrix spec SHOULD: token format opaque.
func generateOpaqueToken() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", fmt.Errorf("generating opaque token: %w", err)
	}
	return hex.EncodeToString(b), nil
}

// PostRefresh handles POST /_matrix/client/v3/refresh.
//
// Spec: Matrix Client-Server API v1.18 §refreshing-access-tokens
//   - Takes refresh_token in body (MUST)
//   - Returns access_token (MUST), expires_in_ms (MAY), refresh_token (MAY)
//   - Old RT valid until new tokens are used (MUST — implemented via grace period)
//   - No Authorization header required (MUST — registered outside jwtMiddleware)
func (h *RefreshHandler) PostRefresh(w http.ResponseWriter, r *http.Request) {
	// Spec: rate-limited: yes — handled by the caller (strictRL wrapper in main.go).

	var req refreshRequest
	if r.ContentLength == 0 {
		writeMatrixError(w, http.StatusBadRequest, "M_BAD_JSON", "Request body is required")
		return
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeMatrixError(w, http.StatusBadRequest, "M_BAD_JSON", "Request body is not valid JSON")
		return
	}
	if req.RefreshToken == "" {
		writeMatrixError(w, http.StatusBadRequest, "M_MISSING_PARAM", "refresh_token is required")
		return
	}

	// Look up the session by the refresh token.
	sess, err := h.store.GetByRefreshToken(req.RefreshToken)
	if err != nil {
		if errors.Is(err, ErrMatrixSessionNotFound) {
			writeMatrixError(w, http.StatusUnauthorized, "M_UNKNOWN_TOKEN", "Unknown or expired refresh token")
			return
		}
		slog.Error("PostRefresh: GetByRefreshToken failed", "err", err)
		writeMatrixError(w, http.StatusInternalServerError, "M_UNKNOWN", "Internal server error")
		return
	}

	// Generate new opaque access_token and refresh_token.
	newAT, err := generateOpaqueToken()
	if err != nil {
		slog.Error("PostRefresh: generateOpaqueToken (AT) failed", "err", err)
		writeMatrixError(w, http.StatusInternalServerError, "M_UNKNOWN", "Internal server error")
		return
	}
	newRT, err := generateOpaqueToken()
	if err != nil {
		slog.Error("PostRefresh: generateOpaqueToken (RT) failed", "err", err)
		writeMatrixError(w, http.StatusInternalServerError, "M_UNKNOWN", "Internal server error")
		return
	}

	// Nebu controls the AT lifetime independently from OIDC token lifetime.
	// We issue 8-hour sessions. The OIDC RT is stored encrypted and can be used
	// to validate the user is still active in Keycloak (future enhancement).
	// For MVP, we refresh the Nebu session without calling Keycloak.
	// Trade-off: Keycloak-side logout won't immediately invalidate Nebu sessions.
	newExpiresAt := time.Now().Add(8 * time.Hour)

	// Atomically rotate tokens. Old AT row gets soft-revoked with 60s grace window
	// so the old RT remains valid until the new AT is first used (AC4, spec MUST).
	if err := h.store.RotateTokens(MatrixSessionRotateParams{
		OldAccessToken:               sess.AccessToken,
		NewAccessToken:               newAT,
		NewRefreshToken:              newRT,
		NewEncryptedOIDCRefreshToken: sess.EncryptedOIDCRefreshToken, // carry over
		NewExpiresAt:                 newExpiresAt,
	}); err != nil {
		if errors.Is(err, ErrMatrixSessionNotFound) {
			// Race condition: session was revoked between GetByRefreshToken and RotateTokens.
			writeMatrixError(w, http.StatusUnauthorized, "M_UNKNOWN_TOKEN", "Refresh token no longer valid")
			return
		}
		slog.Error("PostRefresh: RotateTokens failed", "err", err)
		writeMatrixError(w, http.StatusInternalServerError, "M_UNKNOWN", "Internal server error")
		return
	}

	slog.Info("matrix session refreshed", "user_id", sess.UserID, "device_id", sess.DeviceID)

	expiresInMs := time.Until(newExpiresAt).Milliseconds()
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_ = json.NewEncoder(w).Encode(refreshResponse{
		AccessToken:  newAT,
		RefreshToken: newRT,
		ExpiresInMs:  expiresInMs,
	})
}
