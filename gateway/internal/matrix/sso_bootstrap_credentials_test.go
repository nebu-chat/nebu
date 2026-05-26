package matrix

// sso_bootstrap_credentials_test.go — Red-phase acceptance tests for
// bugfix-sso-bootstrap-credentials.
//
// These tests are written BEFORE the implementation exists (TDD Red Phase).
// They will fail to compile until LoginConfig gains ClientIDLoader /
// ClientSecretLoader fields and LoginHandler wires them in sso.go.
//
// AC1: Bootstrap credentials used for SSO redirect
//   When server_config contains oidc_client_id, the SSO redirect uses that
//   value as client_id in the OAuth2 authorization URL — not the env var.
//
// AC2: Bootstrap secret used for token exchange (verified via intercepted HTTP)
//   When server_config contains a valid encrypted oidc_client_secret, the
//   gateway decrypts it and uses it for the OAuth2 token exchange.
//
// AC3: Fallback to env var when DB is empty
//   When ClientIDLoader is nil (not set), GetSSORedirect uses the static
//   ClientID field from LoginConfig.

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/nebu/nebu/internal/auth"
)

// setupOIDCDiscoveryServer starts a minimal OIDC mock that serves:
//   - /.well-known/openid-configuration (discovery doc)
//   - /keys (empty JWKS)
//
// It does NOT generate an RSA key — use this for tests that only need the
// authorization redirect URL and never issue or verify JWTs.
// For tests that sign or verify id_tokens, use setupOIDCServer from login_test.go.
func setupOIDCDiscoveryServer(t *testing.T) *httptest.Server {
	t.Helper()
	var serverURL string
	mux := http.NewServeMux()
	mux.HandleFunc("/.well-known/openid-configuration", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"issuer":                 serverURL,
			"authorization_endpoint": serverURL + "/auth",
			"token_endpoint":         serverURL + "/token",
			"jwks_uri":               serverURL + "/keys",
		})
	})
	mux.HandleFunc("/keys", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{"keys": []any{}})
	})
	srv := httptest.NewServer(mux)
	serverURL = srv.URL
	t.Cleanup(srv.Close)
	return srv
}

// TestLoginHandlerUsesClientIDFromLoader verifies AC1:
// When ClientIDLoader is set and returns "db-client-id", GetSSORedirect builds
// an OAuth2 authorization URL that contains client_id=db-client-id.
//
// RED PHASE: LoginConfig does not yet have a ClientIDLoader field, and LoginHandler
// does not yet call it. This test will fail to compile until:
//  1. LoginConfig gains: ClientIDLoader func(ctx context.Context) string
//  2. LoginHandler gains: clientIDLoader field (stored from cfg.ClientIDLoader)
//  3. sso.go's GetSSORedirect calls h.resolveClientID(ctx) instead of h.clientID directly
func TestLoginHandlerUsesClientIDFromLoader(t *testing.T) {
	oidcSrv := setupOIDCDiscoveryServer(t)

	provider := auth.NewProvider(context.Background(), oidcSrv.URL)
	if provider.Inner() == nil {
		t.Fatal("OIDC discovery failed — provider.Inner() is nil; mock server may not be ready")
	}

	// The loader simulates the DB returning "db-client-id" for oidc_client_id.
	// It should override the static ClientID field ("static-client-id").
	h := NewLoginHandler(LoginConfig{
		DisplayName:  "Test SSO",
		Provider:     provider,
		ClientID:     "static-client-id", // static fallback — must NOT appear in auth URL
		ClientSecret: "static-secret",
		ClientIDLoader: func(_ context.Context) string {
			return "db-client-id" // dynamic DB value — MUST appear in auth URL
		},
	})

	req := httptest.NewRequest(
		http.MethodGet,
		"/_matrix/client/v3/login/sso/redirect?redirectUrl=https://app.example.com/",
		nil,
	)
	req.Host = "localhost:8008"
	w := httptest.NewRecorder()

	h.GetSSORedirect(w, req)

	if w.Code != http.StatusFound {
		t.Fatalf(
			"AC1 FAIL: expected HTTP 302 Found, got %d\nbody: %s\n\n"+
				"Fix: GetSSORedirect must call h.resolveClientID(ctx) which invokes ClientIDLoader.",
			w.Code, w.Body.String(),
		)
	}

	location := w.Header().Get("Location")
	if location == "" {
		t.Fatal("AC1 FAIL: Location header missing from 302 response")
	}

	parsed, err := url.Parse(location)
	if err != nil {
		t.Fatalf("AC1 FAIL: Location header is not a valid URL: %v", err)
	}

	// AC1: The authorization URL must use "db-client-id" (from the loader), not the static value.
	clientID := parsed.Query().Get("client_id")
	if clientID != "db-client-id" {
		t.Errorf(
			"AC1 FAIL: expected client_id=db-client-id in OAuth2 auth URL, got client_id=%q\n"+
				"Full URL: %s\n\n"+
				"Fix: LoginHandler must call h.resolveClientID(ctx) when building oauth2.Config in GetSSORedirect.",
			clientID, location,
		)
	}
	if strings.Contains(location, "static-client-id") {
		t.Errorf(
			"AC1 FAIL: static-client-id must NOT appear in the auth URL when ClientIDLoader is set\n"+
				"Full URL: %s", location,
		)
	}
}

// TestLoginHandlerFallsBackToStaticClientID verifies AC3:
// When ClientIDLoader is nil, GetSSORedirect falls back to the static ClientID
// field set in LoginConfig.
//
// This test exercises the NO-loader path and must pass even before any loader
// wiring — it acts as a regression guard to confirm the fallback still works
// after the loader path is added.
func TestLoginHandlerFallsBackToStaticClientID(t *testing.T) {
	oidcSrv := setupOIDCDiscoveryServer(t)

	provider := auth.NewProvider(context.Background(), oidcSrv.URL)
	if provider.Inner() == nil {
		t.Fatal("OIDC discovery failed — provider.Inner() is nil; mock server may not be ready")
	}

	// No ClientIDLoader set — the handler must use the static ClientID.
	h := NewLoginHandler(LoginConfig{
		DisplayName:  "Test SSO",
		Provider:     provider,
		ClientID:     "env-client-id", // static value from env var
		ClientSecret: "env-secret",
		// ClientIDLoader intentionally absent (nil) — tests the fallback path
	})

	req := httptest.NewRequest(
		http.MethodGet,
		"/_matrix/client/v3/login/sso/redirect?redirectUrl=https://app.example.com/",
		nil,
	)
	req.Host = "localhost:8008"
	w := httptest.NewRecorder()

	h.GetSSORedirect(w, req)

	if w.Code != http.StatusFound {
		t.Fatalf(
			"AC3 FAIL: expected HTTP 302 Found, got %d\nbody: %s",
			w.Code, w.Body.String(),
		)
	}

	location := w.Header().Get("Location")
	if location == "" {
		t.Fatal("AC3 FAIL: Location header missing from 302 response")
	}

	parsed, err := url.Parse(location)
	if err != nil {
		t.Fatalf("AC3 FAIL: Location header is not a valid URL: %v", err)
	}

	// AC3: Without a loader, the static ClientID must appear in the auth URL.
	clientID := parsed.Query().Get("client_id")
	if clientID != "env-client-id" {
		t.Errorf(
			"AC3 FAIL: expected client_id=env-client-id (static fallback) in OAuth2 auth URL, got %q\n"+
				"Full URL: %s\n\n"+
				"Fix: when ClientIDLoader is nil, h.resolveClientID(ctx) must fall back to the static clientID field.",
			clientID, location,
		)
	}
}

// TestLoginHandlerUsesClientSecretFromLoader verifies AC2:
// When ClientSecretLoader is set and returns "db-secret", GetSSOCallback uses
// "db-secret" in the OAuth2 token exchange — visible in the HTTP POST to the
// /token endpoint via HTTP Basic Auth (client_secret in the password field) or
// the request body (client_secret form parameter per RFC 6749 §2.3.1).
//
// RED PHASE: LoginConfig does not yet have a ClientSecretLoader field, and
// GetSSOCallback does not yet call it. This test will fail to compile until:
//  1. LoginConfig gains: ClientSecretLoader func(ctx context.Context) string
//  2. LoginHandler stores and calls it when building oauth2.Config in GetSSOCallback.
func TestLoginHandlerUsesClientSecretFromLoader(t *testing.T) {
	// No t.Parallel() — shared globalSSOState and globalLoginTokens are mutated;
	// parallel Matrix tests could observe stale entries from this test.
	//
	// We need a full OIDC mock server with a /token endpoint that we can
	// inspect to verify which client_secret was used in the token exchange.

	var capturedClientSecret string

	var serverURL string
	mux := http.NewServeMux()

	// Minimal OIDC discovery doc with authorization + token endpoints.
	mux.HandleFunc("/.well-known/openid-configuration", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"issuer":                 serverURL,
			"authorization_endpoint": serverURL + "/auth",
			"token_endpoint":         serverURL + "/token",
			"jwks_uri":               serverURL + "/keys",
		})
	})

	// JWKS endpoint — empty key set is sufficient; GetSSOCallback will fail at
	// id_token verification, but we only need the credential capture from /token.
	mux.HandleFunc("/keys", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{"keys": []any{}})
	})

	// /token: capture client_secret from HTTP Basic Auth or request body form field.
	// Returns invalid_client so GetSSOCallback fails after credential capture —
	// we only need to inspect what was sent; a valid id_token is not required here.
	mux.HandleFunc("/token", func(w http.ResponseWriter, r *http.Request) {
		// OAuth2 clients send credentials either via HTTP Basic Auth (RFC 6749 §2.3.1)
		// or as client_id + client_secret in the POST body.
		if user, pass, ok := r.BasicAuth(); ok {
			_ = user
			capturedClientSecret = pass
		} else if err := r.ParseForm(); err == nil {
			capturedClientSecret = r.FormValue("client_secret")
		}
		// Return an error — GetSSOCallback will fail at token exchange, which is fine.
		// The credential capture has already happened at this point.
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		_ = json.NewEncoder(w).Encode(map[string]any{
			"error":             "invalid_client",
			"error_description": "test sentinel — credential capture complete",
		})
	})

	srv := httptest.NewServer(mux)
	serverURL = srv.URL
	t.Cleanup(srv.Close)

	provider := auth.NewProvider(context.Background(), serverURL)
	if provider.Inner() == nil {
		t.Fatal("OIDC discovery failed — provider.Inner() is nil; mock server may not be ready")
	}

	// The loader returns "db-secret" — this must be sent to the /token endpoint.
	h := NewLoginHandler(LoginConfig{
		DisplayName:  "Test SSO",
		Provider:     provider,
		ClientID:     "nebu-gateway",
		ClientSecret: "static-secret", // must NOT be used when ClientSecretLoader is set
		ClientSecretLoader: func(_ context.Context) string {
			return "db-secret" // dynamic DB value — MUST appear in /token request
		},
	})

	// Seed globalSSOState directly (bypasses GetSSORedirect) so we control verifier,
	// redirectURL, and nonce. The nonce value does not matter for this test since
	// GetSSOCallback will fail at token exchange before nonce verification.
	const testStateKey = "bootstrap-creds-secret-test-state"
	globalSSOState.mu.Lock()
	globalSSOState.store[testStateKey] = ssoStateEntry{
		verifier:    "dummy-verifier-value",
		redirectURL: "https://app.example.com/",
		nonce:       "dummy-nonce-value",
		exp:         time.Now().Add(10 * time.Minute),
	}
	globalSSOState.mu.Unlock()
	t.Cleanup(func() {
		globalSSOState.mu.Lock()
		delete(globalSSOState.store, testStateKey)
		globalSSOState.mu.Unlock()
	})

	req := httptest.NewRequest(
		http.MethodGet,
		"/_matrix/client/v3/login/sso/redirect/oidc?code=authcode&state="+testStateKey,
		nil,
	)
	req.Host = "localhost:8008"
	w := httptest.NewRecorder()

	// GetSSOCallback attempts the /token exchange. The exchange fails (mock returns
	// invalid_client) but capturedClientSecret is populated before the error.
	h.GetSSOCallback(w, req)

	// Verify the /token endpoint was reached and captured a secret.
	if capturedClientSecret == "" {
		t.Fatal(
			"AC2 FAIL: /token endpoint was not called or client_secret was not captured.\n\n" +
				"Fix: GetSSOCallback must build oauth2.Config using h.resolveClientSecret(ctx) " +
				"which invokes ClientSecretLoader.",
		)
	}

	// AC2: The captured secret must be "db-secret" (from the loader), not "static-secret".
	if capturedClientSecret != "db-secret" {
		t.Errorf(
			"AC2 FAIL: expected client_secret=db-secret (from ClientSecretLoader), got %q\n\n"+
				"Fix: GetSSOCallback must call h.resolveClientSecret(ctx) when building oauth2.Config.",
			capturedClientSecret,
		)
	}
}
