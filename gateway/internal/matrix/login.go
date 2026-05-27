package matrix

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/coreos/go-oidc/v3/oidc"
	"github.com/nebu/nebu/internal/admin"
	"github.com/nebu/nebu/internal/auth"
	coregrpc "github.com/nebu/nebu/internal/grpc"
	pb "github.com/nebu/nebu/internal/grpc/pb"
	"github.com/nebu/nebu/internal/middleware"
	"github.com/nebu/nebu/internal/validate"
	"google.golang.org/grpc/codes"
	grpcstatus "google.golang.org/grpc/status"
)

// UserIDClaimLoader is a function type that returns the configured oidc_user_id_claim
// from server_config for a given request context. Returns "" if the key is absent
// (fallback to legacy "name" claim behavior, AC7 Story 11-10).
type UserIDClaimLoader func(ctx context.Context) string

// CoreClient is a consumer-defined interface for gRPC calls to the Elixir core.
type CoreClient interface {
	ValidateToken(ctx context.Context, req *pb.ValidateTokenRequest) (*pb.ValidateTokenResponse, error)
}

type IdentityProvider struct {
	ID   string  `json:"id"`
	Name string  `json:"name"`
	Icon *string `json:"icon"`
}

type LoginFlow struct {
	Type              string             `json:"type"`
	IdentityProviders []IdentityProvider `json:"identity_providers,omitempty"`
}

type LoginResponse struct {
	Flows []LoginFlow `json:"flows"`
}

type LoginRequest struct {
	Type         string `json:"type"`
	Token        string `json:"token"`
	RefreshToken bool   `json:"refresh_token"` // v1.3: client supports refresh tokens
}

type LoginTokenResponse struct {
	AccessToken  string  `json:"access_token"`
	DeviceID     string  `json:"device_id"`
	UserID       string  `json:"user_id"`
	TokenType    string  `json:"token_type"`
	ExpiresInMs  *int64  `json:"expires_in_ms,omitempty"`  // v1.3, only when RefreshToken=true
	RefreshToken *string `json:"refresh_token,omitempty"`  // v1.3, only when RefreshToken=true
}

type matrixError struct {
	ErrCode string `json:"errcode"`
	Err     string `json:"error"`
}

func writeMatrixError(w http.ResponseWriter, status int, errcode, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(matrixError{ErrCode: errcode, Err: message})
}

func generateDeviceID() string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	b[6] = (b[6] & 0x0f) | 0x40 // UUID version 4
	b[8] = (b[8] & 0x3f) | 0x80 // UUID variant 2
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:])
}

type LoginHandler struct {
	displayName            string
	provider               *auth.Provider
	coreClient             CoreClient
	store                  middleware.TokenStore // optional; nil = skip denylist check in PostLogin
	matrixSessions         MatrixSessionStoreInterface // optional; nil = refresh not supported
	internalSecret         []byte // AES-256-GCM key for encrypting OIDC refresh tokens; nil = no encryption
	serverName             string
	clientID               string
	clientSecret           string
	clientIDLoader         func(ctx context.Context) string // nil = use static clientID field
	clientSecretLoader     func(ctx context.Context) string // nil = use static clientSecret field
	roleClaimName          string
	ssoRedirectSchemes     []string          // extra deep-link schemes from NEBU_SSO_REDIRECT_SCHEMES
	extraScopes            []string          // extra OIDC scopes from NEBU_OIDC_EXTRA_SCOPES
	userIDClaimLoader      UserIDClaimLoader // nil = fall back to legacy "name" claim (AC7)
	displaynameClaimLoader UserIDClaimLoader // nil = use hardcoded preferred_username→name→email chain
	emailClaimLoader       UserIDClaimLoader // nil = use hardcoded "email" claim
}

// resolveClientID returns the OIDC client ID for the current request.
// When clientIDLoader is set, it delegates to the loader (DB-backed, TTL-cached).
// Falls back to the static clientID field when the loader is nil (pre-bootstrap state).
func (h *LoginHandler) resolveClientID(ctx context.Context) string {
	if h.clientIDLoader != nil {
		return h.clientIDLoader(ctx)
	}
	return h.clientID
}

// resolveClientSecret returns the OIDC client secret for the current request.
// When clientSecretLoader is set, it delegates to the loader (DB-backed, TTL-cached, decrypted).
// Falls back to the static clientSecret field when the loader is nil (pre-bootstrap state).
func (h *LoginHandler) resolveClientSecret(ctx context.Context) string {
	if h.clientSecretLoader != nil {
		return h.clientSecretLoader(ctx)
	}
	return h.clientSecret
}

type LoginConfig struct {
	DisplayName        string
	Provider           *auth.Provider
	CoreClient         CoreClient
	Store              middleware.TokenStore // optional; when set, PostLogin rejects invalidated JWTs
	// MatrixSessions enables opaque token issuance and refresh support.
	// When set, PostLogin returns opaque AT+RT when client sends refresh_token:true.
	// nil = refresh not supported (backward compat).
	MatrixSessions     MatrixSessionStoreInterface
	// InternalSecret is the AES-256-GCM key used to encrypt OIDC refresh tokens
	// stored in matrix_sessions. Required when MatrixSessions is set.
	InternalSecret     []byte
	ServerName         string
	ClientID           string
	ClientSecret       string
	// ClientIDLoader returns the OIDC client_id from server_config (DB-backed, TTL-cached).
	// When set, it overrides the static ClientID field. nil = use ClientID (pre-bootstrap fallback).
	ClientIDLoader func(ctx context.Context) string
	// ClientSecretLoader returns the decrypted OIDC client_secret from server_config.
	// When set, it overrides the static ClientSecret field. nil = use ClientSecret (pre-bootstrap fallback).
	ClientSecretLoader func(ctx context.Context) string
	RoleClaimName      string
	SSORedirectSchemes []string          // extra deep-link schemes from NEBU_SSO_REDIRECT_SCHEMES
	// ExtraScopes holds additional OIDC scopes beyond [openid, profile, email].
	// Populated from NEBU_OIDC_EXTRA_SCOPES at startup. NOTE: unlike the admin auth
	// flow (story 5-30), this value is startup-only — there is no live DB override
	// via server_config. A gateway restart is required to pick up env-var changes.
	ExtraScopes        []string
	UserIDClaimLoader  UserIDClaimLoader // nil = fall back to legacy "name" claim behavior (AC7)
	// DisplaynameClaimLoader returns the configured oidc_displayname_claim from server_config.
	// nil = use hardcoded preferred_username→name→email fallback chain (backward compat).
	DisplaynameClaimLoader UserIDClaimLoader
	// EmailClaimLoader returns the configured oidc_email_claim from server_config.
	// nil = use hardcoded "email" claim (backward compat).
	EmailClaimLoader UserIDClaimLoader
}

func NewLoginHandler(cfg LoginConfig) *LoginHandler {
	if cfg.Store == nil {
		slog.Warn("LoginHandler: no TokenStore configured — denylist check disabled; PostLogin will not reject invalidated JWTs")
	}
	return &LoginHandler{
		displayName:            cfg.DisplayName,
		provider:               cfg.Provider,
		coreClient:             cfg.CoreClient,
		store:                  cfg.Store,
		matrixSessions:         cfg.MatrixSessions,
		internalSecret:         cfg.InternalSecret,
		serverName:             cfg.ServerName,
		clientID:               cfg.ClientID,
		clientSecret:           cfg.ClientSecret,
		clientIDLoader:         cfg.ClientIDLoader,
		clientSecretLoader:     cfg.ClientSecretLoader,
		roleClaimName:          cfg.RoleClaimName,
		ssoRedirectSchemes:     cfg.SSORedirectSchemes,
		extraScopes:            cfg.ExtraScopes,
		userIDClaimLoader:      cfg.UserIDClaimLoader,
		displaynameClaimLoader: cfg.DisplaynameClaimLoader,
		emailClaimLoader:       cfg.EmailClaimLoader,
	}
}

func (h *LoginHandler) PostLogin(w http.ResponseWriter, r *http.Request) {
	var req LoginRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeMatrixError(w, http.StatusBadRequest, "M_NOT_JSON", "Request body is not valid JSON")
		return
	}

	if req.Type != "m.login.token" {
		writeMatrixError(w, http.StatusBadRequest, "M_UNKNOWN", "Unsupported login type")
		return
	}

	inner := h.provider.Inner()
	if inner == nil {
		writeMatrixError(w, http.StatusServiceUnavailable, "M_UNKNOWN", "Authentication service unavailable")
		return
	}

	// MAJOR-2 fix: req.Token may be an opaque SSO loginToken (64 hex chars) or a
	// raw JWT. Try the opaque store first (single-use, 30s TTL). Fall back to
	// treating it as a raw JWT for any client that calls POST /login directly.
	rawJWT := req.Token
	var oidcRefreshTokenFromSSO string // non-empty when GetSSOCallback stored an OIDC refresh token
	if entry, found := globalLoginTokens.pop(req.Token); found {
		rawJWT = entry.idToken
		oidcRefreshTokenFromSSO = entry.oidcRefreshToken
	}

	verifier := inner.Verifier(&oidc.Config{
		ClientID:             h.resolveClientID(r.Context()),
		SupportedSigningAlgs: validate.SupportedAlgs(),
	})
	idToken, err := verifier.Verify(r.Context(), rawJWT)
	if err != nil {
		writeMatrixError(w, http.StatusForbidden, "M_FORBIDDEN", "Invalid or expired token")
		return
	}

	// Denylist check: reject JWTs that were previously invalidated on logout.
	// This guards against two scenarios:
	//   1. Dex returned a cached id_token despite prompt=login (nonce mismatch already
	//      caught in GetSSOCallback, but defense-in-depth for direct POST /login calls).
	//   2. A client submitting a raw JWT directly (fallback path) that was already logged out.
	//
	// 403 M_FORBIDDEN (not 401 M_UNKNOWN_TOKEN) is intentional here: POST /login is an
	// authentication attempt, not a session validation. 403 signals the credential is
	// forbidden; JWTMiddleware returns 401 M_UNKNOWN_TOKEN for invalidated session tokens.
	if h.store != nil && h.store.IsInvalidated(rawJWT) {
		slog.Warn("PostLogin: rejected invalidated JWT — token is in the denylist", "event", "denylist_hit_login")
		writeMatrixError(w, http.StatusForbidden, "M_FORBIDDEN", "Token has been logged out — please log in again")
		return
	}

	var allClaims map[string]interface{}
	if err := idToken.Claims(&allClaims); err != nil {
		writeMatrixError(w, http.StatusForbidden, "M_FORBIDDEN", "Invalid token claims")
		return
	}
	rawRole := auth.ExtractRoleClaim(allClaims, h.roleClaimName)
	systemRole := auth.MapSystemRole(rawRole)

	// Resolve email using configured oidc_email_claim (Story 11-10 MAJOR-2 fix).
	// Falls back to hardcoded "email" claim when emailClaimLoader is nil (backward compat).
	emailClaim := "email"
	if h.emailClaimLoader != nil {
		if loaded := h.emailClaimLoader(r.Context()); loaded != "" {
			emailClaim = loaded
		}
	}
	email, _ := allClaims[emailClaim].(string)

	// Resolve display name using configured oidc_displayname_claim (Story 11-10 MAJOR-2 fix).
	// When displaynameClaimLoader is set, use the configured claim directly.
	// When nil (or value empty), fall back to legacy priority chain for backward compat:
	//   1. preferred_username (OIDC standard)
	//   2. name (Dex maps username → name claim for local passwords)
	//   3. email local part as fallback
	var displayName string
	if h.displaynameClaimLoader != nil {
		if dnClaim := h.displaynameClaimLoader(r.Context()); dnClaim != "" {
			displayName, _ = allClaims[dnClaim].(string)
		}
	}
	if displayName == "" {
		// Fallback chain (backward compat or displaynameClaimLoader not set)
		displayName, _ = allClaims["preferred_username"].(string)
		if displayName == "" {
			displayName, _ = allClaims["name"].(string)
		}
		if displayName == "" && email != "" {
			// Fall back to local part of email (before @)
			for i, c := range email {
				if c == '@' {
					displayName = email[:i]
					break
				}
			}
		}
	}

	// Determine Matrix user ID using DB-loaded oidc_user_id_claim (AC5, Story 11-10).
	// Per-request DB read (no restart required). Falls back to "name" claim behavior
	// when oidc_user_id_claim is absent from server_config (AC7 backward compat).
	uidClaim := "name"
	if h.userIDClaimLoader != nil {
		if loaded := h.userIDClaimLoader(r.Context()); loaded != "" {
			uidClaim = loaded
		}
	}
	userID := coregrpc.FormatUserIDFromClaims(uidClaim, allClaims, h.serverName)
	grpcCtx := coregrpc.WithUserMetadata(r.Context(), userID, systemRole)
	_, err = h.coreClient.ValidateToken(grpcCtx, &pb.ValidateTokenRequest{
		DisplayName: displayName,
		Email:       email,
	})
	if err != nil {
		// Map gRPC PERMISSION_DENIED with "deactivated" in the message to 403 M_USER_DEACTIVATED.
		// The Elixir core raises PermissionDenied when is_active=false on the user record.
		// All other errors remain 500 M_UNKNOWN (defensive: avoid leaking internals).
		st, _ := grpcstatus.FromError(err)
		if st.Code() == codes.PermissionDenied && strings.Contains(strings.ToLower(st.Message()), "deactivated") {
			slog.Warn("PostLogin: rejected deactivated user", "user_id", userID)
			writeMatrixError(w, http.StatusForbidden, "M_USER_DEACTIVATED", "This account has been deactivated")
			return
		}
		slog.Error("ValidateToken gRPC failed", "err", err, "user_id", userID)
		writeMatrixError(w, http.StatusInternalServerError, "M_UNKNOWN", "Internal server error")
		return
	}

	deviceID := generateDeviceID()

	// v1.3: Create a MatrixSession when matrixSessions is configured AND the login
	// came via SSO (so we have the OIDC refresh token). This produces opaque AT+RT.
	// AC7: clients without refresh_token:true still get the raw JWT (backward compat).
	// The session is always created (not just when req.RefreshToken==true) so that
	// subsequent requests via JWTMiddleware can validate the opaque token.
	//
	// MINOR-3: Warn admins when the OIDC refresh token is absent despite MatrixSessions
	// being configured. This indicates a Keycloak misconfiguration (e.g. missing
	// offline_access scope or the OIDC client lacks offline access capability).
	var nebuOpaqueAT, nebuOpaqueRT string
	var nebuExpiresAt time.Time
	if h.matrixSessions != nil && oidcRefreshTokenFromSSO == "" {
		slog.Warn("PostLogin: OIDC refresh token missing — opaque session cannot be created; "+
			"check that the Keycloak client has 'offline_access' scope enabled and offline access is granted",
			"user_id", userID)
	}
	if h.matrixSessions != nil && oidcRefreshTokenFromSSO != "" {
		at, err := generateOpaqueToken()
		if err == nil {
			rt, err := generateOpaqueToken()
			if err == nil {
				// Encrypt OIDC RT if we have an internal secret.
				// Note: oidcRefreshTokenFromSSO is guaranteed non-empty here because
				// the outer guard (line above) already checks oidcRefreshTokenFromSSO != "".
				var encOIDCRT string
				if len(h.internalSecret) > 0 {
					var encErr error
					encOIDCRT, encErr = encryptOIDCRefreshToken(h.internalSecret, oidcRefreshTokenFromSSO)
					if encErr != nil {
						// MINOR-4: log encryption failure so admins notice the misconfiguration
						// (e.g. internal_secret too short for AES-256-GCM).
						slog.Warn("PostLogin: failed to encrypt OIDC refresh token — session created without encrypted RT",
							"err", encErr, "user_id", userID)
					}
				}
				nebuExpiresAt = time.Now().Add(8 * time.Hour)
				createErr := h.matrixSessions.Create(MatrixSessionCreateParams{
					AccessToken:               at,
					RefreshToken:              rt,
					EncryptedOIDCRefreshToken: encOIDCRT,
					UserID:                    userID,
					DeviceID:                  deviceID,
					ExpiresAt:                 nebuExpiresAt,
				})
				if createErr != nil {
					slog.Error("PostLogin: failed to create MatrixSession — falling back to JWT", "err", createErr)
				} else {
					nebuOpaqueAT = at
					nebuOpaqueRT = rt
				}
			}
		}
	}

	// Determine which access_token to return.
	// When a MatrixSession was created, use the opaque Nebu AT.
	// Otherwise fall back to the raw JWT (AC7 backward compat for direct POST /login clients).
	accessToken := rawJWT
	if nebuOpaqueAT != "" {
		accessToken = nebuOpaqueAT
	}

	resp := LoginTokenResponse{
		AccessToken: accessToken,
		DeviceID:    deviceID,
		UserID:      userID,
		TokenType:   "Bearer",
	}

	// v1.3: include refresh_token and expires_in_ms only when the client requested
	// refresh_token:true AND we successfully created a MatrixSession (AC1).
	if req.RefreshToken && nebuOpaqueRT != "" {
		expiresInMs := time.Until(nebuExpiresAt).Milliseconds()
		resp.ExpiresInMs = &expiresInMs
		resp.RefreshToken = &nebuOpaqueRT
	}

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(resp)
}

// encryptOIDCRefreshToken encrypts the OIDC refresh token using AES-256-GCM.
// Uses the same encryption as the admin package.
func encryptOIDCRefreshToken(secret []byte, refreshToken string) (string, error) {
	return admin.EncryptAES256GCM(secret, refreshToken)
}

func (h *LoginHandler) GetLogin(w http.ResponseWriter, r *http.Request) {
	resp := LoginResponse{
		Flows: []LoginFlow{
			{
				Type: "m.login.sso",
				IdentityProviders: []IdentityProvider{
					{
						ID:   "oidc",
						Name: h.displayName,
						Icon: nil,
					},
				},
			},
			// m.login.token must be advertised alongside m.login.sso so that
			// Element Web 1.12+ uses the loginToken that GetSSOCallback embeds
			// in the redirect URL instead of re-initiating a fresh SSO flow.
			// Without this, Element ignores the loginToken and loops back to Dex.
			{Type: "m.login.token"},
		},
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(resp)
}
