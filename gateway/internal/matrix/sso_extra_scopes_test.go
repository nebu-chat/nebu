package matrix

// Bug 5-31: Hardcoded `groups` Scope in Matrix SSO Handlers Breaks Keycloak Login
//
// These tests verify the configurable extra-scopes behaviour introduced by Bug 5-31.
// The matrix SSO flow previously hardcoded `groups` as an extra scope
// (sso.go lines 303 and 363).  Keycloak does not support `groups` in its
// scopes_supported, causing every Matrix SSO login to fail.
//
// Fix: read NEBU_OIDC_EXTRA_SCOPES at startup, pass it through
//   Config.OIDCExtraScopes → LoginConfig.ExtraScopes → LoginHandler.extraScopes
// and call buildSSOScopeList(h.extraScopes) in both GetSSORedirect and GetSSOCallback.
//
// AC1: Standard scopes always sent; no extra scopes unless NEBU_OIDC_EXTRA_SCOPES is set.
// AC2: Extra scopes from env var applied to matrix SSO.
// AC3: Keycloak matrix SSO works without custom scopes (empty extra → no groups).
// AC4: Dex environment unaffected (groups + offline_access still work when configured).

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	"github.com/nebu/nebu/internal/auth"
)

// ─── AC4 (helper): TestBuildSSOScopeList ──────────────────────────────────────

// TestBuildSSOScopeList is a direct unit test for the buildSSOScopeList helper
// that must be added to sso.go.
//
// RED PHASE: buildSSOScopeList does not exist yet.  This file will not compile
// until the helper is added to sso.go (Bug 5-31 implementation step 3).
func TestBuildSSOScopeList(t *testing.T) {
	t.Parallel()

	// Note: offline_access is always included in the base scope list since
	// story oidc-session-refresh — required for Keycloak/Dex to issue OIDC refresh tokens.
	cases := []struct {
		name  string
		extra []string
		want  []string
	}{
		{
			name:  "nil extra returns base scopes only",
			extra: nil,
			want:  []string{"openid", "profile", "email", "offline_access"},
		},
		{
			name:  "empty extra returns base scopes only",
			extra: []string{},
			want:  []string{"openid", "profile", "email", "offline_access"},
		},
		{
			name:  "non-empty extra appended after base scopes",
			extra: []string{"groups", "offline_access"},
			want:  []string{"openid", "profile", "email", "offline_access", "groups"},
		},
		{
			name:  "duplicate openid in extra is dropped",
			extra: []string{"openid", "roles"},
			want:  []string{"openid", "profile", "email", "offline_access", "roles"},
		},
		{
			name:  "duplicate email in extra is dropped",
			extra: []string{"roles", "email"},
			want:  []string{"openid", "profile", "email", "offline_access", "roles"},
		},
		{
			name:  "duplicate profile in extra is dropped",
			extra: []string{"profile", "roles"},
			want:  []string{"openid", "profile", "email", "offline_access", "roles"},
		},
		{
			name:  "empty strings in extra are ignored",
			extra: []string{"", "groups", ""},
			want:  []string{"openid", "profile", "email", "offline_access", "groups"},
		},
		{
			name:  "all three base scopes duplicated in extra are all dropped",
			extra: []string{"openid", "roles", "email"},
			want:  []string{"openid", "profile", "email", "offline_access", "roles"},
		},
	}

	for _, tc := range cases {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			got := buildSSOScopeList(tc.extra)
			if !scopeListEqual(got, tc.want) {
				t.Errorf("buildSSOScopeList(%v)\n  got:  %v\n  want: %v", tc.extra, got, tc.want)
			}
		})
	}
}

// ─── AC1 + AC3: TestMatrixSSORedirectScopesDefault ────────────────────────────

// TestMatrixSSORedirectScopesDefault verifies that GetSSORedirect sends only
// the standard openid, profile, and email scopes when ExtraScopes is nil —
// i.e., when NEBU_OIDC_EXTRA_SCOPES is unset (AC1, AC3).
//
// RED PHASE: LoginConfig.ExtraScopes does not exist yet.  This file will not
// compile until the field is added to LoginConfig in login.go (step 2 of the
// Bug 5-31 fix) and wired through NewLoginHandler into LoginHandler.extraScopes.
//
// After the fix, GetSSORedirect must call buildSSOScopeList(h.extraScopes)
// instead of the hardcoded []string{oidc.ScopeOpenID, "profile", "email", "groups"}.
func TestMatrixSSORedirectScopesDefault(t *testing.T) {
	t.Parallel()

	oidcSrv, _ := setupOIDCServer(t)
	t.Cleanup(oidcSrv.Close)

	provider := auth.NewProvider(context.Background(), oidcSrv.URL)
	if provider.Inner() == nil {
		t.Fatal("OIDC discovery failed — provider.Inner() is nil; mock server may not be ready")
	}

	// ExtraScopes: nil → NEBU_OIDC_EXTRA_SCOPES unset scenario.
	h := NewLoginHandler(LoginConfig{
		DisplayName:  "Test SSO",
		Provider:     provider,
		ClientID:     "nebu-gateway",
		ClientSecret: "secret",
		ExtraScopes:  nil, // RED: field does not exist yet
	})

	req := httptest.NewRequest(
		http.MethodGet,
		"/_matrix/client/v3/login/sso/redirect?redirectUrl=https://app.example.com/callback",
		nil,
	)
	req.Host = "localhost:8008"
	w := httptest.NewRecorder()

	h.GetSSORedirect(w, req)

	if w.Code != http.StatusFound {
		t.Fatalf("expected HTTP 302 Found, got %d; body: %s", w.Code, w.Body.String())
	}

	location := w.Header().Get("Location")
	if location == "" {
		t.Fatal("Location header is missing from 302 response")
	}

	scopeParam := extractScopeParam(t, location)

	// AC1: standard scopes must be present.
	assertScopePresent(t, scopeParam, "openid", location)
	assertScopePresent(t, scopeParam, "profile", location)
	assertScopePresent(t, scopeParam, "email", location)
	// offline_access is always included (story: oidc-session-refresh) to request OIDC RT.
	assertScopePresent(t, scopeParam, "offline_access", location)

	// AC1 + AC3: no extra scopes (beyond base + offline_access) when ExtraScopes is nil.
	assertScopeAbsent(t, scopeParam, "groups", location)
}

// ─── AC2: TestMatrixSSORedirectScopesFromExtraScopes ─────────────────────────

// TestMatrixSSORedirectScopesFromExtraScopes verifies that extra scopes
// configured via ExtraScopes (i.e. NEBU_OIDC_EXTRA_SCOPES=groups offline_access)
// are appended to the standard scopes in the OIDC authorization URL (AC2).
//
// RED PHASE: see TestMatrixSSORedirectScopesDefault — same prerequisite.
func TestMatrixSSORedirectScopesFromExtraScopes(t *testing.T) {
	t.Parallel()

	oidcSrv, _ := setupOIDCServer(t)
	t.Cleanup(oidcSrv.Close)

	provider := auth.NewProvider(context.Background(), oidcSrv.URL)
	if provider.Inner() == nil {
		t.Fatal("OIDC discovery failed — provider.Inner() is nil; mock server may not be ready")
	}

	h := NewLoginHandler(LoginConfig{
		DisplayName:  "Test SSO",
		Provider:     provider,
		ClientID:     "nebu-gateway",
		ClientSecret: "secret",
		ExtraScopes:  []string{"groups", "offline_access"}, // RED: field does not exist yet
	})

	req := httptest.NewRequest(
		http.MethodGet,
		"/_matrix/client/v3/login/sso/redirect?redirectUrl=https://app.example.com/callback",
		nil,
	)
	req.Host = "localhost:8008"
	w := httptest.NewRecorder()

	h.GetSSORedirect(w, req)

	if w.Code != http.StatusFound {
		t.Fatalf("expected HTTP 302 Found, got %d; body: %s", w.Code, w.Body.String())
	}

	location := w.Header().Get("Location")
	if location == "" {
		t.Fatal("Location header is missing from 302 response")
	}

	scopeParam := extractScopeParam(t, location)

	// AC2: all standard scopes must be present.
	assertScopePresent(t, scopeParam, "openid", location)
	assertScopePresent(t, scopeParam, "profile", location)
	assertScopePresent(t, scopeParam, "email", location)

	// AC2: extra scopes must also appear.
	assertScopePresent(t, scopeParam, "groups", location)
	assertScopePresent(t, scopeParam, "offline_access", location)
}

// ─── AC1 + dedup: TestMatrixSSORedirectScopesDedup ────────────────────────────

// TestMatrixSSORedirectScopesDedup verifies that scopes already present in the
// base list (openid, profile, email) are not duplicated even if they appear in
// ExtraScopes (AC1 — no duplicate scope values in the authorization URL).
//
// RED PHASE: see TestMatrixSSORedirectScopesDefault — same prerequisite.
func TestMatrixSSORedirectScopesDedup(t *testing.T) {
	t.Parallel()

	oidcSrv, _ := setupOIDCServer(t)
	t.Cleanup(oidcSrv.Close)

	provider := auth.NewProvider(context.Background(), oidcSrv.URL)
	if provider.Inner() == nil {
		t.Fatal("OIDC discovery failed — provider.Inner() is nil; mock server may not be ready")
	}

	h := NewLoginHandler(LoginConfig{
		DisplayName:  "Test SSO",
		Provider:     provider,
		ClientID:     "nebu-gateway",
		ClientSecret: "secret",
		// openid and email are already in the base list — they must not appear twice.
		ExtraScopes: []string{"openid", "roles", "email"}, // RED: field does not exist yet
	})

	req := httptest.NewRequest(
		http.MethodGet,
		"/_matrix/client/v3/login/sso/redirect?redirectUrl=https://app.example.com/callback",
		nil,
	)
	req.Host = "localhost:8008"
	w := httptest.NewRecorder()

	h.GetSSORedirect(w, req)

	if w.Code != http.StatusFound {
		t.Fatalf("expected HTTP 302 Found, got %d; body: %s", w.Code, w.Body.String())
	}

	location := w.Header().Get("Location")
	if location == "" {
		t.Fatal("Location header is missing from 302 response")
	}

	scopeParam := extractScopeParam(t, location)
	scopes := strings.Fields(scopeParam)

	// AC1: the non-duplicate scope "roles" must appear exactly once.
	assertScopePresent(t, scopeParam, "roles", location)

	// Dedup: openid must appear exactly once (not twice).
	assertScopeExactlyOnce(t, scopes, "openid", location)
	// Dedup: email must appear exactly once (not twice).
	assertScopeExactlyOnce(t, scopes, "email", location)
	// Dedup: profile must appear exactly once (it was not in extra, just base).
	assertScopeExactlyOnce(t, scopes, "profile", location)
}

// ─── AC1 + AC3: TestMatrixSSORedirectScopesEmptyEnvVar ────────────────────────

// TestMatrixSSORedirectScopesEmptyEnvVar verifies that an explicitly empty
// ExtraScopes slice (equivalent to NEBU_OIDC_EXTRA_SCOPES="" — strings.Fields("")
// returns []string{}) produces the same result as nil: only the standard
// openid, profile, and email scopes are sent (AC1, AC3, MINOR-1).
func TestMatrixSSORedirectScopesEmptyEnvVar(t *testing.T) {
	t.Parallel()

	oidcSrv, _ := setupOIDCServer(t)
	t.Cleanup(oidcSrv.Close)

	provider := auth.NewProvider(context.Background(), oidcSrv.URL)
	if provider.Inner() == nil {
		t.Fatal("OIDC discovery failed — provider.Inner() is nil; mock server may not be ready")
	}

	// ExtraScopes: []string{} — equivalent to NEBU_OIDC_EXTRA_SCOPES="" after strings.Fields.
	h := NewLoginHandler(LoginConfig{
		DisplayName:  "Test SSO",
		Provider:     provider,
		ClientID:     "nebu-gateway",
		ClientSecret: "secret",
		ExtraScopes:  []string{},
	})

	req := httptest.NewRequest(
		http.MethodGet,
		"/_matrix/client/v3/login/sso/redirect?redirectUrl=https://app.example.com/callback",
		nil,
	)
	req.Host = "localhost:8008"
	w := httptest.NewRecorder()

	h.GetSSORedirect(w, req)

	if w.Code != http.StatusFound {
		t.Fatalf("expected HTTP 302 Found, got %d; body: %s", w.Code, w.Body.String())
	}

	location := w.Header().Get("Location")
	if location == "" {
		t.Fatal("Location header is missing from 302 response")
	}

	scopeParam := extractScopeParam(t, location)

	// AC1: standard scopes must be present.
	assertScopePresent(t, scopeParam, "openid", location)
	assertScopePresent(t, scopeParam, "profile", location)
	assertScopePresent(t, scopeParam, "email", location)
	// offline_access is always included (story: oidc-session-refresh) to request OIDC RT.
	assertScopePresent(t, scopeParam, "offline_access", location)

	// AC1 + AC3: no extra scopes (beyond base + offline_access) when ExtraScopes is empty.
	assertScopeAbsent(t, scopeParam, "groups", location)
}

// ─── MINOR-2 + MINOR-4: TestMatrixSSOCallbackDelegatesScopes ────────────────

// TestMatrixSSOCallbackDelegatesScopes verifies that calling GetSSOCallback
// WITHOUT code/state parameters (the delegation branch at sso.go:351) delegates
// to GetSSORedirect — and that the resulting redirect URL picks up ExtraScopes.
//
// This proves the initiation-via-callback path (used by IDP-specific clients that
// hit /_matrix/client/v3/login/sso/redirect/oidc directly) also applies extraScopes,
// closing the indirect coverage gap noted in MINOR-2 / MINOR-4.
func TestMatrixSSOCallbackDelegatesScopes(t *testing.T) {
	t.Parallel()

	oidcSrv, _ := setupOIDCServer(t)
	t.Cleanup(oidcSrv.Close)

	provider := auth.NewProvider(context.Background(), oidcSrv.URL)
	if provider.Inner() == nil {
		t.Fatal("OIDC discovery failed — provider.Inner() is nil; mock server may not be ready")
	}

	// Set ExtraScopes so we can assert the scope appears in the authorization URL.
	h := NewLoginHandler(LoginConfig{
		DisplayName:  "Test SSO",
		Provider:     provider,
		ClientID:     "nebu-gateway",
		ClientSecret: "secret",
		ExtraScopes:  []string{"groups"},
	})

	// Call GetSSOCallback WITHOUT code or state — this triggers the delegation branch
	// (sso.go: if code == "" || state == "" { h.GetSSORedirect(w, r); return }).
	req := httptest.NewRequest(
		http.MethodGet,
		"/_matrix/client/v3/login/sso/redirect/oidc?redirectUrl=https://app.example.com/cb",
		nil,
	)
	req.Host = "localhost:8008"
	w := httptest.NewRecorder()

	h.GetSSOCallback(w, req)

	if w.Code != http.StatusFound {
		t.Fatalf("expected HTTP 302 Found from GetSSOCallback delegation, got %d; body: %s",
			w.Code, w.Body.String())
	}

	location := w.Header().Get("Location")
	if location == "" {
		t.Fatal("Location header is missing from 302 response")
	}

	scopeParam := extractScopeParam(t, location)

	// Standard scopes must be present (delegation path must not drop them).
	assertScopePresent(t, scopeParam, "openid", location)
	assertScopePresent(t, scopeParam, "profile", location)
	assertScopePresent(t, scopeParam, "email", location)

	// Extra scope from ExtraScopes must appear — proving delegation picks up extraScopes.
	assertScopePresent(t, scopeParam, "groups", location)
}

// TestMatrixSSOCallbackIdPError verifies that when the IdP redirects back with
// ?error=...&state=... (RFC 6749 §4.1.2.1), the handler returns M_FORBIDDEN
// instead of the confusing M_MISSING_PARAM that occurred before this fix.
func TestMatrixSSOCallbackIdPError(t *testing.T) {
	t.Parallel()

	oidcSrv, _ := setupOIDCServer(t)
	t.Cleanup(oidcSrv.Close)

	provider := auth.NewProvider(context.Background(), oidcSrv.URL)
	if provider.Inner() == nil {
		t.Fatal("OIDC discovery failed")
	}

	h := NewLoginHandler(LoginConfig{
		DisplayName:  "Test SSO",
		Provider:     provider,
		ClientID:     "nebu-gateway",
		ClientSecret: "secret",
	})

	t.Run("with error_description", func(t *testing.T) {
		req := httptest.NewRequest(http.MethodGet,
			"/_matrix/client/v3/login/sso/redirect/oidc?error=invalid_scope&error_description=Invalid+scopes%3A+groups&state=deadbeef",
			nil)
		req.Host = "localhost:8008"
		w := httptest.NewRecorder()
		h.GetSSOCallback(w, req)

		if w.Code != http.StatusForbidden {
			t.Fatalf("expected 403 Forbidden, got %d; body: %s", w.Code, w.Body.String())
		}
		var resp struct {
			Errcode string `json:"errcode"`
			Error   string `json:"error"`
		}
		if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
			t.Fatalf("response body is not valid JSON: %v\nbody: %s", err, w.Body.String())
		}
		if resp.Errcode != "M_FORBIDDEN" {
			t.Errorf("expected errcode M_FORBIDDEN, got %q", resp.Errcode)
		}
		if !strings.Contains(resp.Error, "invalid_scope") {
			t.Errorf("expected IdP error code in error field, got %q", resp.Error)
		}
		if !strings.Contains(resp.Error, "Invalid scopes") {
			t.Errorf("expected error_description in Error field, got %q", resp.Error)
		}
	})

	t.Run("without error_description", func(t *testing.T) {
		req := httptest.NewRequest(http.MethodGet,
			"/_matrix/client/v3/login/sso/redirect/oidc?error=access_denied&state=deadbeef2",
			nil)
		req.Host = "localhost:8008"
		w := httptest.NewRecorder()
		h.GetSSOCallback(w, req)

		if w.Code != http.StatusForbidden {
			t.Fatalf("expected 403 Forbidden, got %d; body: %s", w.Code, w.Body.String())
		}
		var resp struct {
			Errcode string `json:"errcode"`
			Error   string `json:"error"`
		}
		if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
			t.Fatalf("response body is not valid JSON: %v\nbody: %s", err, w.Body.String())
		}
		if resp.Errcode != "M_FORBIDDEN" {
			t.Errorf("expected errcode M_FORBIDDEN, got %q", resp.Errcode)
		}
		if !strings.Contains(resp.Error, "access_denied") {
			t.Errorf("expected IdP error in error field, got %q", resp.Error)
		}
	})

	t.Run("without state returns 403", func(t *testing.T) {
		req := httptest.NewRequest(http.MethodGet,
			"/_matrix/client/v3/login/sso/redirect/oidc?error=server_error",
			nil)
		req.Host = "localhost:8008"
		w := httptest.NewRecorder()
		h.GetSSOCallback(w, req)

		if w.Code != http.StatusForbidden {
			t.Fatalf("expected 403 Forbidden, got %d; body: %s", w.Code, w.Body.String())
		}
	})

	t.Run("truncates long error_description", func(t *testing.T) {
		longDesc := strings.Repeat("a", 400)
		req := httptest.NewRequest(http.MethodGet,
			"/_matrix/client/v3/login/sso/redirect/oidc?error=too_long&error_description="+longDesc+"&state=trunctest",
			nil)
		req.Host = "localhost:8008"
		w := httptest.NewRecorder()
		h.GetSSOCallback(w, req)

		if w.Code != http.StatusForbidden {
			t.Fatalf("expected 403 Forbidden, got %d; body: %s", w.Code, w.Body.String())
		}
		var resp struct {
			Errcode string `json:"errcode"`
			Error   string `json:"error"`
		}
		if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
			t.Fatalf("response body is not valid JSON: %v\nbody: %s", err, w.Body.String())
		}
		if resp.Errcode != "M_FORBIDDEN" {
			t.Errorf("expected errcode M_FORBIDDEN, got %q", resp.Errcode)
		}
		if len(resp.Error) >= 512 {
			t.Errorf("expected truncated error description (< 512 chars total), got len=%d: %q", len(resp.Error), resp.Error)
		}
	})
}

// ─── Test helpers ─────────────────────────────────────────────────────────────

// extractScopeParam parses the Location header URL and returns the decoded
// value of the `scope` query parameter (space-separated scope list).
func extractScopeParam(t *testing.T, location string) string {
	t.Helper()
	parsed, err := url.Parse(location)
	if err != nil {
		t.Fatalf("Location header is not a valid URL: %v\nURL: %s", err, location)
	}
	scope := parsed.Query().Get("scope")
	if scope == "" {
		t.Fatalf("scope parameter is missing from authorization URL\nFull URL: %s", location)
	}
	return scope
}

// assertScopePresent fails the test if scope is not found in the space-separated
// scopeParam string.
func assertScopePresent(t *testing.T, scopeParam, scope, location string) {
	t.Helper()
	for _, s := range strings.Fields(scopeParam) {
		if s == scope {
			return
		}
	}
	t.Errorf("expected scope %q in authorization URL scope parameter\n  scope param: %q\n  full URL: %s",
		scope, scopeParam, location)
}

// assertScopeAbsent fails the test if scope IS found in the space-separated
// scopeParam string.
func assertScopeAbsent(t *testing.T, scopeParam, scope, location string) {
	t.Helper()
	for _, s := range strings.Fields(scopeParam) {
		if s == scope {
			t.Errorf("unexpected scope %q in authorization URL scope parameter — must NOT be present when ExtraScopes is nil\n  scope param: %q\n  full URL: %s",
				scope, scopeParam, location)
			return
		}
	}
}

// assertScopeExactlyOnce fails if scope appears 0 or more than 1 times in scopes.
func assertScopeExactlyOnce(t *testing.T, scopes []string, scope, location string) {
	t.Helper()
	count := 0
	for _, s := range scopes {
		if s == scope {
			count++
		}
	}
	if count != 1 {
		t.Errorf("expected scope %q exactly once in authorization URL, got %d occurrence(s)\n  scopes: %v\n  full URL: %s",
			scope, count, scopes, location)
	}
}

// scopeListEqual returns true if a and b contain the same elements in the same
// order (used in TestBuildSSOScopeList where order is significant).
func scopeListEqual(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
