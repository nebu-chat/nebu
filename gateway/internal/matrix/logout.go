package matrix

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"strings"
	"time"

	pb "github.com/nebu/nebu/internal/grpc/pb"
	"github.com/nebu/nebu/internal/middleware"
	"google.golang.org/grpc"
)

// LogoutCoreClient is the subset of pb.CoreServiceClient used by LogoutHandler.
// Defined here by the consumer (Go interface convention, ADR-009).
type LogoutCoreClient interface {
	InvalidateUserSessions(ctx context.Context, req *pb.InvalidateUserSessionsRequest, opts ...grpc.CallOption) (*pb.InvalidateUserSessionsResponse, error)
}

type LogoutHandler struct {
	store          middleware.TokenStore
	coreClient     LogoutCoreClient         // optional; nil = skip per-device sync-token cleanup
	matrixSessions MatrixSessionStoreInterface // optional; nil = skip opaque token revocation
}

// LogoutConfig holds configuration for LogoutHandler.
type LogoutConfig struct {
	Store          middleware.TokenStore
	CoreClient     LogoutCoreClient         // Optional: when set, per-device sync_tokens cleanup runs on logout (AC4, Story 9-22)
	// MatrixSessions enables revocation of opaque Nebu access tokens on logout.
	// When set, PostLogout calls Revoke(rawToken) for opaque tokens (no "." in token string).
	// nil = opaque token revocation disabled (backward compat when store not configured).
	MatrixSessions MatrixSessionStoreInterface
}

// NewLogoutHandler creates a LogoutHandler without a Core gRPC client.
// It invalidates the JWT in the local denylist but does NOT clean up
// per-device sync_tokens in the Elixir Core.
// Use NewLogoutHandlerWithCore in production to ensure per-device sync-token
// cleanup runs on POST /logout (AC4, Story 9-22).
func NewLogoutHandler(store middleware.TokenStore) *LogoutHandler {
	return &LogoutHandler{store: store}
}

// NewLogoutHandlerWithCore creates a LogoutHandler with an optional Core gRPC client
// for per-device sync-token cleanup on POST /logout (AC4, Story 9-22).
func NewLogoutHandlerWithCore(cfg LogoutConfig) *LogoutHandler {
	return &LogoutHandler{
		store:          cfg.Store,
		coreClient:     cfg.CoreClient,
		matrixSessions: cfg.MatrixSessions,
	}
}

func (h *LogoutHandler) PostLogout(w http.ResponseWriter, r *http.Request) {
	rawToken := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")

	// Determine whether this is a Nebu opaque token or a raw OIDC JWT.
	// Opaque tokens (no ".") issued by PostLogin are tracked in matrix_sessions.
	// JWT tokens (always contain exactly 2 ".") are tracked in the denylist.
	//
	// MINOR-5 fix: WithOpaqueSessionCheck does NOT set ContextKeyTokenExpiry, so for opaque
	// tokens the expiry is always zero in the context — calling Invalidate with a zero time
	// would result in the token being immediately "expired" in the denylist (not truly invalidated).
	// We therefore use the MatrixSessionStore.Revoke path for opaque tokens and skip Invalidate.
	//
	// When matrixSessions is nil (e.g. in older tests or before the store is wired), fall back
	// to Invalidate so that backward-compat callers still work correctly.
	if !strings.Contains(rawToken, ".") && h.matrixSessions != nil {
		// Opaque Nebu access token path: hard-revoke via MatrixSessionStore.
		if err := h.matrixSessions.Revoke(rawToken); err != nil {
			// Non-fatal: log and return 200 anyway (client should treat logout as done).
			slog.Warn("PostLogout: failed to revoke opaque matrix session", "err", err)
		}
	} else {
		// JWT path (or opaque without store configured): invalidate in the denylist.
		// ContextKeyTokenExpiry is set by JWTMiddleware for JWT tokens.
		expiry, _ := r.Context().Value(middleware.ContextKeyTokenExpiry).(time.Time)
		_ = h.store.Invalidate(rawToken, expiry)
	}

	// AC4 (Story 9-22): clean up the per-device sync_tokens row in Core.
	// device_id is set by JWTMiddleware from the "did" JWT claim.
	// If coreClient is nil (legacy / test), skip this call (best-effort).
	if h.coreClient != nil {
		userID, _ := r.Context().Value(middleware.ContextKeyUserID).(string)
		deviceID, _ := r.Context().Value(middleware.ContextKeyDeviceID).(string)
		if userID != "" {
			_, err := h.coreClient.InvalidateUserSessions(r.Context(), &pb.InvalidateUserSessionsRequest{
				UserId:   userID,
				DeviceId: deviceID,
			})
			if err != nil {
				// Non-fatal: the JWT is already invalidated in the denylist.
				// Log and continue so the client still gets a 200 response.
				slog.Warn("PostLogout: failed to clean up per-device sync token", "userID", userID, "deviceID", deviceID, "err", err)
			}
		}
	}

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(struct{}{})
}
