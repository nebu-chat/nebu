package admin

// auth_extra_scopes_test.go — RED-PHASE acceptance tests for story 5-30
//
// Acceptance Criteria tested:
//   AC1: Standard scopes (openid, profile, email) are always sent; no extra scopes when
//        neither NEBU_OIDC_EXTRA_SCOPES nor oidc_extra_scopes (DB key) is set.
//   AC2: NEBU_OIDC_EXTRA_SCOPES=groups offline_access → those scopes appear in auth URL.
//   AC3: DB oidc_extra_scopes key overrides the env-var fallback when present.
//   AC4 (bootstrap path): bootstrap_draft with oidc_extra_scopes="" → only standard scopes.
//
// All tests call LoginStartHandler via httptest and inspect the OIDC redirect URL.
// These tests are written FIRST (red phase) — they FAIL until the implementation is done.

import (
	"context"
	"database/sql"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

// scopedFakeConfigReader is a ServerConfigReader that returns configurable extra-scopes
// from LoadServerConfigKey and delegates everything else to fakeServerConfigReader.
// This allows individual tests to simulate the presence or absence of oidc_extra_scopes
// in server_config without touching fakeServerConfigReader (which is shared).
type scopedFakeConfigReader struct {
	base fakeServerConfigReader
	// extraScopes is returned for key "oidc_extra_scopes".
	extraScopes string
	// extraScopesAbsent simulates a missing DB row: LoadServerConfigKey returns ("", sql.ErrNoRows).
	extraScopesAbsent bool
}

func (s *scopedFakeConfigReader) LoadOIDCConfig(ctx context.Context) (string, string, string, string, error) {
	return s.base.LoadOIDCConfig(ctx)
}

func (s *scopedFakeConfigReader) CompleteBootstrap(ctx context.Context) error {
	return s.base.CompleteBootstrap(ctx)
}

func (s *scopedFakeConfigReader) LoadAdminGroupClaim(ctx context.Context) (string, error) {
	return s.base.LoadAdminGroupClaim(ctx)
}

func (s *scopedFakeConfigReader) SaveAdminGroupClaim(ctx context.Context, v string) error {
	return s.base.SaveAdminGroupClaim(ctx, v)
}

func (s *scopedFakeConfigReader) LoadClaimMapping(ctx context.Context) (string, string, string, error) {
	return s.base.LoadClaimMapping(ctx)
}

func (s *scopedFakeConfigReader) SaveClaimMapping(ctx context.Context, a, b, c string) error {
	return s.base.SaveClaimMapping(ctx, a, b, c)
}

func (s *scopedFakeConfigReader) LoadServerConfigKey(ctx context.Context, key string) (string, error) {
	if key == "oidc_extra_scopes" {
		if s.extraScopesAbsent {
			return "", sql.ErrNoRows
		}
		return s.extraScopes, nil
	}
	return s.base.LoadServerConfigKey(ctx, key)
}

// extractScopeParam parses the OIDC redirect URL and returns the space-separated scope
// values as a slice. Calls t.Fatal if Location is absent or unparseable.
func extractScopeParam(t *testing.T, rr *httptest.ResponseRecorder) []string {
	t.Helper()
	location := rr.Header().Get("Location")
	if location == "" {
		t.Fatal("expected Location header in response, got empty string")
	}
	parsed, err := url.Parse(location)
	if err != nil {
		t.Fatalf("url.Parse(%q): %v", location, err)
	}
	raw := parsed.Query().Get("scope")
	if raw == "" {
		t.Fatalf("scope parameter missing from OIDC redirect URL: %s", location)
	}
	return strings.Fields(raw)
}

// scopeContainsAll returns true when every item in want appears in got.
func scopeContainsAll(got []string, want ...string) bool {
	set := make(map[string]bool, len(got))
	for _, s := range got {
		set[s] = true
	}
	for _, w := range want {
		if !set[w] {
			return false
		}
	}
	return true
}

// scopeContainsAny returns true when at least one item in any appears in got.
func scopeContainsAny(got []string, any ...string) bool {
	set := make(map[string]bool, len(got))
	for _, s := range got {
		set[s] = true
	}
	for _, a := range any {
		if set[a] {
			return true
		}
	}
	return false
}

// ── AC1: No env var, no DB key → only openid profile email ───────────────────

// TestLoginStartScopesDefaultEmpty verifies that LoginStartHandler only sends the standard
// scopes (openid, profile, email) in the OIDC auth URL when neither NEBU_OIDC_EXTRA_SCOPES
// nor the server_config oidc_extra_scopes key is configured.
//
// RED PHASE — fails because the current implementation hardcodes "groups" and "offline_access"
// in the Scopes field of the oauth2.Config (~line 512 of auth.go).
func TestLoginStartScopesDefaultEmpty(t *testing.T) {
	// Ensure env var is unset for this test.
	t.Setenv("NEBU_OIDC_EXTRA_SCOPES", "")

	srv, _ := setupAdminOIDCServer(t)

	reader := &scopedFakeConfigReader{
		base: fakeServerConfigReader{
			issuer:       srv.URL,
			clientID:     "test-client-id",
			clientSecret: "test-secret",
		},
		// Simulate the absence of oidc_extra_scopes in server_config.
		extraScopesAbsent: true,
	}

	a := newTestAdminAuthWithReader(t, reader, nil)

	req := httptest.NewRequest("GET", "/admin/login/start", nil)
	req.Host = "localhost"
	rr := httptest.NewRecorder()
	a.LoginStartHandler(rr, req)

	if rr.Code != http.StatusFound {
		t.Fatalf("[AC1] expected 302, got %d; body: %s", rr.Code, rr.Body.String())
	}

	scopes := extractScopeParam(t, rr)

	// Standard scopes must always be present.
	if !scopeContainsAll(scopes, "openid", "profile", "email") {
		t.Errorf("[AC1] expected standard scopes (openid, profile, email) in scope list %v", scopes)
	}

	// Extra scopes must NOT be present when nothing is configured.
	if scopeContainsAny(scopes, "groups", "offline_access") {
		t.Errorf("[AC1] scope list contains extra scopes (groups/offline_access) but neither env var nor DB key is set; got %v", scopes)
	}
}

// ── AC2: NEBU_OIDC_EXTRA_SCOPES set → extra scopes appear in auth URL ─────────

// TestLoginStartScopesFromEnvVar verifies that setting NEBU_OIDC_EXTRA_SCOPES causes
// LoginStartHandler to include those scopes alongside the standard ones.
//
// The env var is set to "custom_scope_ac2" — a value that is NOT in the current hardcoded list
// (which contains "groups" and "offline_access"). This ensures the test is genuinely red:
// the assertion fails iff the env var is not actually read by the handler.
//
// RED PHASE — fails because NEBU_OIDC_EXTRA_SCOPES is not read anywhere in the current code.
func TestLoginStartScopesFromEnvVar(t *testing.T) {
	t.Setenv("NEBU_OIDC_EXTRA_SCOPES", "custom_scope_ac2")

	srv, _ := setupAdminOIDCServer(t)

	reader := &scopedFakeConfigReader{
		base: fakeServerConfigReader{
			issuer:       srv.URL,
			clientID:     "test-client-id",
			clientSecret: "test-secret",
		},
		// No DB override — the handler must fall back to the env var.
		extraScopesAbsent: true,
	}

	a := newTestAdminAuthWithReader(t, reader, nil)

	req := httptest.NewRequest("GET", "/admin/login/start", nil)
	req.Host = "localhost"
	rr := httptest.NewRecorder()
	a.LoginStartHandler(rr, req)

	if rr.Code != http.StatusFound {
		t.Fatalf("[AC2] expected 302, got %d; body: %s", rr.Code, rr.Body.String())
	}

	scopes := extractScopeParam(t, rr)

	// Standard scopes must always be present.
	if !scopeContainsAll(scopes, "openid", "profile", "email") {
		t.Errorf("[AC2] expected standard scopes (openid, profile, email) in scope list %v", scopes)
	}

	// The env-var scope must appear — proving NEBU_OIDC_EXTRA_SCOPES is actually read.
	if !scopeContainsAll(scopes, "custom_scope_ac2") {
		t.Errorf("[AC2] expected env-var scope 'custom_scope_ac2' from NEBU_OIDC_EXTRA_SCOPES but got %v", scopes)
	}
}

// ── AC3: DB oidc_extra_scopes overrides env var ───────────────────────────────

// TestLoginStartScopesFromDBOverridesEnv verifies that when the server_config table contains
// oidc_extra_scopes=roles and the env var is set to "groups offline_access", the DB value
// wins: only "roles" appears as an extra scope; "groups" and "offline_access" must be absent.
//
// RED PHASE — fails because the DB key is not read yet and the env var is not read yet.
func TestLoginStartScopesFromDBOverridesEnv(t *testing.T) {
	t.Setenv("NEBU_OIDC_EXTRA_SCOPES", "groups offline_access")

	srv, _ := setupAdminOIDCServer(t)

	reader := &scopedFakeConfigReader{
		base: fakeServerConfigReader{
			issuer:       srv.URL,
			clientID:     "test-client-id",
			clientSecret: "test-secret",
		},
		// DB has oidc_extra_scopes=roles — this must override the env var.
		extraScopes:       "roles",
		extraScopesAbsent: false,
	}

	a := newTestAdminAuthWithReader(t, reader, nil)

	req := httptest.NewRequest("GET", "/admin/login/start", nil)
	req.Host = "localhost"
	rr := httptest.NewRecorder()
	a.LoginStartHandler(rr, req)

	if rr.Code != http.StatusFound {
		t.Fatalf("[AC3] expected 302, got %d; body: %s", rr.Code, rr.Body.String())
	}

	scopes := extractScopeParam(t, rr)

	// Standard scopes must always be present.
	if !scopeContainsAll(scopes, "openid", "profile", "email") {
		t.Errorf("[AC3] expected standard scopes (openid, profile, email) in scope list %v", scopes)
	}

	// DB-configured extra scope must be present.
	if !scopeContainsAll(scopes, "roles") {
		t.Errorf("[AC3] expected DB-configured scope 'roles' in scope list %v", scopes)
	}

	// Env-var scopes must NOT be present because the DB key overrides.
	if scopeContainsAny(scopes, "groups", "offline_access") {
		t.Errorf("[AC3] env-var scopes (groups/offline_access) must be overridden by DB oidc_extra_scopes=roles, but found them in %v", scopes)
	}
}

// ── AC4 (bootstrap path): draft with empty oidc_extra_scopes → only standard scopes ─

// TestBootstrapFlowScopesFromDraft verifies that when the bootstrap_draft table contains
// oidc_extra_scopes="" (empty, explicitly set by the wizard) and no env var is set, the OIDC
// auth URL for mode=bootstrap contains only the standard scopes.
//
// RED PHASE — fails because oidc_extra_scopes is not read from bootstrap_draft yet and the
// hardcoded scope list still includes "groups" and "offline_access".
func TestBootstrapFlowScopesFromDraft(t *testing.T) {
	// No env var — the empty bootstrap_draft value must yield only standard scopes.
	t.Setenv("NEBU_OIDC_EXTRA_SCOPES", "")

	srv, _ := setupAdminOIDCServer(t)

	// The oidc_client_secret in the draft must be encrypted with the test HMAC key.
	testSecret := []byte("test-secret-key")
	encryptedClientSecret, err := encryptAES256GCM(testSecret, "test-secret")
	if err != nil {
		t.Fatalf("encryptAES256GCM: %v", err)
	}

	// Populate a bootstrap_draft store with the minimum OIDC fields and empty extra scopes.
	draft := &fakeBootstrapDraftStore{
		data: map[string]string{
			"oidc_issuer":       srv.URL,
			"oidc_client_id":    "test-client-id",
			"oidc_client_secret": encryptedClientSecret,
			"oidc_extra_scopes": "", // explicitly set to empty
		},
	}

	// server_config reader — never used in bootstrap path when draft is complete.
	reader := &scopedFakeConfigReader{
		base: fakeServerConfigReader{
			issuer:       srv.URL,
			clientID:     "test-client-id",
			clientSecret: "test-secret",
		},
		extraScopesAbsent: true,
	}

	// Build AdminAuth with the draft store and a bootstrap checker that says active.
	a := NewAdminAuth(nil, "test-client-id", "test-secret", "nebu_role", testSecret, nil, nil)
	a.configReader = reader
	a.draftStore = draft
	a.bootstrapChecker = &fakeBootstrapChecker{active: true}

	req := httptest.NewRequest("GET", "/admin/login/start?mode=bootstrap", nil)
	req.Host = "localhost"
	rr := httptest.NewRecorder()
	a.LoginStartHandler(rr, req)

	if rr.Code != http.StatusFound {
		t.Fatalf("[AC4] expected 302, got %d; body: %s", rr.Code, rr.Body.String())
	}

	scopes := extractScopeParam(t, rr)

	// Standard scopes must always be present.
	if !scopeContainsAll(scopes, "openid", "profile", "email") {
		t.Errorf("[AC4] expected standard scopes (openid, profile, email) in scope list %v", scopes)
	}

	// No extra scopes — bootstrap_draft oidc_extra_scopes is empty.
	if scopeContainsAny(scopes, "groups", "offline_access") {
		t.Errorf("[AC4] expected NO extra scopes when bootstrap_draft oidc_extra_scopes is empty, but found them in %v", scopes)
	}
}

// ── AC2 negative sub-case: explicit empty NEBU_OIDC_EXTRA_SCOPES ─────────────

// TestLoginStartScopesEmptyEnvVar verifies that explicitly setting NEBU_OIDC_EXTRA_SCOPES
// to an empty string ("") behaves the same as the unset case — only standard scopes are sent.
// This is a separate isolated test for the negative sub-case (MINOR finding from pre-dev review).
func TestLoginStartScopesEmptyEnvVar(t *testing.T) {
	// Explicitly set to empty string — must behave the same as unset.
	t.Setenv("NEBU_OIDC_EXTRA_SCOPES", "")

	srv, _ := setupAdminOIDCServer(t)

	reader := &scopedFakeConfigReader{
		base: fakeServerConfigReader{
			issuer:       srv.URL,
			clientID:     "test-client-id",
			clientSecret: "test-secret",
		},
		extraScopesAbsent: true,
	}

	a := newTestAdminAuthWithReader(t, reader, nil)

	req := httptest.NewRequest("GET", "/admin/login/start", nil)
	req.Host = "localhost"
	rr := httptest.NewRecorder()
	a.LoginStartHandler(rr, req)

	if rr.Code != http.StatusFound {
		t.Fatalf("[AC2-neg] expected 302, got %d; body: %s", rr.Code, rr.Body.String())
	}

	scopes := extractScopeParam(t, rr)

	if !scopeContainsAll(scopes, "openid", "profile", "email") {
		t.Errorf("[AC2-neg] expected standard scopes in scope list %v", scopes)
	}
	if scopeContainsAny(scopes, "groups", "offline_access") {
		t.Errorf("[AC2-neg] expected NO extra scopes when NEBU_OIDC_EXTRA_SCOPES is empty string, but got %v", scopes)
	}
}

// ── AC3 multi-token sub-case: DB value with multiple space-separated tokens ──

// TestLoginStartScopesDBMultiToken verifies that when server_config has
// oidc_extra_scopes="roles offline_access" (two tokens), both appear in the auth URL
// and the env var is ignored.
func TestLoginStartScopesDBMultiToken(t *testing.T) {
	t.Setenv("NEBU_OIDC_EXTRA_SCOPES", "groups") // env var must be ignored

	srv, _ := setupAdminOIDCServer(t)

	reader := &scopedFakeConfigReader{
		base: fakeServerConfigReader{
			issuer:       srv.URL,
			clientID:     "test-client-id",
			clientSecret: "test-secret",
		},
		// DB has two tokens — both must appear in the auth URL.
		extraScopes:       "roles offline_access",
		extraScopesAbsent: false,
	}

	a := newTestAdminAuthWithReader(t, reader, nil)

	req := httptest.NewRequest("GET", "/admin/login/start", nil)
	req.Host = "localhost"
	rr := httptest.NewRecorder()
	a.LoginStartHandler(rr, req)

	if rr.Code != http.StatusFound {
		t.Fatalf("[AC3-multi] expected 302, got %d; body: %s", rr.Code, rr.Body.String())
	}

	scopes := extractScopeParam(t, rr)

	if !scopeContainsAll(scopes, "openid", "profile", "email") {
		t.Errorf("[AC3-multi] expected standard scopes in scope list %v", scopes)
	}
	if !scopeContainsAll(scopes, "roles", "offline_access") {
		t.Errorf("[AC3-multi] expected DB-configured scopes (roles, offline_access) in %v", scopes)
	}
	// The env-var "groups" must NOT appear — DB overrides env var.
	if scopeContainsAny(scopes, "groups") {
		t.Errorf("[AC3-multi] env-var scope 'groups' must be absent when DB oidc_extra_scopes is set, but found in %v", scopes)
	}
}

// ── MINOR-2: resolveExtraScopes DB-error fallback path ───────────────────────
//
// CallbackHandler (and LoginStartHandler) both follow the same switch/default logic:
// when LoadServerConfigKey returns a non-ErrNoRows DB error, they set extraScopesAbsent=true
// and extraScopesFromSource="" (zero value — never assigned in the error branch), then call
// resolveExtraScopes("", true). This test exercises that code path at the unit level.

// TestResolveExtraScopesDBError verifies that when the DB returns a non-ErrNoRows error
// (simulated by the handler setting dbAbsent=true and dbVal=""), resolveExtraScopes falls
// back to the NEBU_OIDC_EXTRA_SCOPES env var and returns its value.
//
// This is the same function called by CallbackHandler (and LoginStartHandler) in the
// default/error branch of the LoadServerConfigKey switch.
func TestResolveExtraScopesDBError(t *testing.T) {
	t.Setenv("NEBU_OIDC_EXTRA_SCOPES", "fallback_scope")

	// DB error path: handler sets dbAbsent=true (env-var fallback) and dbVal="" (not assigned).
	// This mirrors what both LoginStartHandler and CallbackHandler do in the default switch case.
	got := resolveExtraScopes("", true)

	if got != "fallback_scope" {
		t.Errorf("resolveExtraScopes(\"\", true): expected env-var fallback \"fallback_scope\", got %q", got)
	}
}

// ── Dedup regression: duplicate base scopes in extra-scopes input are dropped ─

// TestBuildScopeListDedup verifies that buildScopeList deduplicates extra-scope tokens
// that already appear in the standard base list (openid, profile, email).
//
// This is a regression guard for the dedup fix introduced in review cycle 1 (MINOR-1).
// Input "openid roles email custom" overlaps with two base scopes; the final list must
// contain exactly [openid, profile, email, roles, custom] — no duplicates.
func TestBuildScopeListDedup(t *testing.T) {
	// "openid" and "email" already exist in the base list — they must NOT appear twice.
	scopes := buildScopeList("openid roles email custom")

	want := []string{"openid", "profile", "email", "roles", "custom"}

	// Length check: duplicates would inflate the slice.
	if len(scopes) != len(want) {
		t.Errorf("expected %d scopes (no duplicates), got %d: %v", len(want), len(scopes), scopes)
	}

	// Order check: base scopes first, extra scopes appended in order.
	for i, w := range want {
		if i >= len(scopes) {
			break
		}
		if scopes[i] != w {
			t.Errorf("scopes[%d]: want %q, got %q (full list: %v)", i, w, scopes[i], scopes)
		}
	}

	// Presence check: every expected scope must be in the list.
	if !scopeContainsAll(scopes, want...) {
		t.Errorf("expected all of %v in scope list, got %v", want, scopes)
	}
}
