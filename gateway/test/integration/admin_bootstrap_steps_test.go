//go:build integration

package integration_test

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"strings"
	"time"

	"github.com/cucumber/godog"
	_ "github.com/jackc/pgx/v5/stdlib"
)

// encryptForStorage mirrors gateway/internal/admin/crypto.go encryptAES256GCM.
// key is derived from secret via SHA-256; output is hex-encoded nonce||ciphertext.
func encryptForStorage(secret []byte, plaintext string) (string, error) {
	keyHash := sha256.Sum256(secret)
	block, err := aes.NewCipher(keyHash[:])
	if err != nil {
		return "", err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return "", err
	}
	nonce := make([]byte, gcm.NonceSize())
	if _, err := io.ReadFull(rand.Reader, nonce); err != nil {
		return "", err
	}
	ciphertext := gcm.Seal(nonce, nonce, []byte(plaintext), nil)
	return hex.EncodeToString(ciphertext), nil
}

// lastAdminSessionCookie holds the most recently forged admin session cookie value.
var lastAdminSessionCookie string

// adminSessionCookiePayload mirrors the admin.adminSessionCookie struct exactly.
// JSON tags must match: sub, email, role, exp.
type adminSessionCookiePayload struct {
	Sub   string `json:"sub"`
	Email string `json:"email"`
	Role  string `json:"role"`
	Exp   int64  `json:"exp"`
}

// openTestDB opens a *sql.DB connection to the test PostgreSQL instance using dbURL.
func openTestDB() (*sql.DB, error) {
	return sql.Open("pgx", dbURL)
}

// signTestCookie mirrors AdminAuth.signCookie: base64url(payload) + "." + base64url(HMAC-SHA256(secret, base64url(payload))).
func signTestCookie(secret []byte, payload []byte) string {
	encoded := base64.RawURLEncoding.EncodeToString(payload)
	mac := hmac.New(sha256.New, secret)
	mac.Write([]byte(encoded))
	sig := base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
	return encoded + "." + sig
}

// adminURL returns the full URL for an admin-panel path (port 8008 = matrixURL).
func adminURL(path string) string {
	return matrixURL + path
}

// noRedirectClient returns an http.Client that does NOT follow redirects.
// Required for asserting 302/303 redirect responses.
func noRedirectClient() *http.Client {
	return &http.Client{
		CheckRedirect: func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
}

// theServerHasNoBootstrapCompleted truncates server_config and bootstrap_draft to ensure
// a clean slate (no bootstrap_completed row). Uses migrationDBURL (nebu_migrate role) which
// has BYPASSRLS and table ownership — nebu_app does not have TRUNCATE permission after Story 5.29a.
func theServerHasNoBootstrapCompleted() error {
	db, err := sql.Open("pgx", migrationDBURL)
	if err != nil {
		return fmt.Errorf("open migration db: %w", err)
	}
	defer db.Close()

	if _, err := db.Exec("TRUNCATE TABLE server_config"); err != nil {
		return fmt.Errorf("truncate server_config: %w", err)
	}
	// bootstrap_draft may or may not exist depending on applied migrations — best-effort truncate.
	_, _ = db.Exec("TRUNCATE TABLE bootstrap_draft")

	// Re-insert bootstrap_active so IsBootstrapActive returns true regardless of whether
	// users exist in the DB (users from other integration tests would otherwise suppress bootstrap mode).
	_, err = db.Exec(
		"INSERT INTO server_config (key, value, set_at) VALUES ($1, $2, $3)",
		"bootstrap_active", "true", time.Now().UnixMilli(),
	)
	return err
}

// iRequestGETWithoutCookie makes a no-redirect GET to adminURL(path) without any cookie.
// Stores status, body, and Location header in package-level vars.
func iRequestGETWithoutCookie(path string) error {
	client := noRedirectClient()
	resp, err := client.Get(adminURL(path))
	if err != nil {
		return fmt.Errorf("GET %s: %w", path, err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	lastStatusCode = resp.StatusCode
	lastBody = string(body)
	lastLocationHeader = resp.Header.Get("Location")
	return nil
}

// theResponseRedirectsTo asserts the last response was a 302 or 303 redirect
// with a Location header containing the target path.
func theResponseRedirectsTo(target string) error {
	if lastStatusCode != http.StatusFound && lastStatusCode != http.StatusSeeOther {
		return fmt.Errorf("expected redirect (302/303), got %d (body: %.200s)", lastStatusCode, lastBody)
	}
	if !strings.Contains(lastLocationHeader, target) {
		return fmt.Errorf("expected redirect to %q, got Location: %q", target, lastLocationHeader)
	}
	return nil
}

// iSeedBootstrapConfigDirectly inserts bootstrap configuration rows directly into
// server_config via raw SQL. This bypasses the HTTPS validation in the bootstrap API
// (which rejects http:// OIDC issuers) and is the correct approach for integration tests
// against a dev stack where Dex runs on HTTP.
func iSeedBootstrapConfigDirectly() error {
	db, err := openTestDB()
	if err != nil {
		return fmt.Errorf("open db: %w", err)
	}
	defer db.Close()

	encSecret, err := encryptForStorage([]byte(internalSecret), "nebu-admin-secret")
	if err != nil {
		return fmt.Errorf("encrypt oidc_client_secret: %w", err)
	}

	now := time.Now().UnixMilli()
	rows := []struct{ key, value string }{
		{"instance_name", "test-instance"},
		{"oidc_issuer", "http://dex:5556/dex"},
		// Use "nebu-gateway" (not "nebu-admin") — the Matrix login handler reads
		// oidc_client_id from server_config via clientIDCached and verifies JWT
		// audience against it. Dex issues tokens with aud="nebu-gateway"; seeding
		// "nebu-admin" causes audience mismatch → 403 on all OIDC login tests.
		{"oidc_client_id", "nebu-gateway"},
		{"oidc_client_secret", encSecret},
		{"bootstrap_completed", "true"},
	}
	for _, r := range rows {
		if _, err := db.Exec(
			"INSERT INTO server_config (key, value, set_at) VALUES ($1, $2, $3)",
			r.key, r.value, now,
		); err != nil {
			return fmt.Errorf("insert server_config[%s]: %w", r.key, err)
		}
	}
	return nil
}

// serverConfigContainsKeyValue queries server_config for the given key and asserts the value matches.
func serverConfigContainsKeyValue(key, value string) error {
	db, err := openTestDB()
	if err != nil {
		return fmt.Errorf("open db: %w", err)
	}
	defer db.Close()

	var v string
	err = db.QueryRow("SELECT value FROM server_config WHERE key = $1", key).Scan(&v)
	if err != nil {
		return fmt.Errorf("query server_config[%s]: %w", key, err)
	}
	if v != value {
		return fmt.Errorf("server_config[%s] = %q, want %q", key, v, value)
	}
	return nil
}

// bootstrapIsCompleteAndSeeded is the Given step for Scenario 2 and 3.
// It resets server_config (TRUNCATE) and then seeds it with bootstrap_completed=true
// and valid OIDC config rows.
func bootstrapIsCompleteAndSeeded() error {
	if err := theServerHasNoBootstrapCompleted(); err != nil {
		return err
	}
	return iSeedBootstrapConfigDirectly()
}

// iHaveAForgedValidAdminSessionCookie inserts a row into admin_sessions (via migrationDBURL)
// and creates a signed SID cookie matching the server-side session format used by
// SessionGuardWithRefresh (PostgresAdminSessionStore). The old stateless cookie format
// (Sub/Email/Role/Exp) is no longer accepted by the gateway after Story 5.12.
//
// ON CONFLICT DO UPDATE makes this idempotent (AC6).
func iHaveAForgedValidAdminSessionCookie() error {
	const testSID = "test-admin-session-001"

	// Insert test admin session row into DB using migrationDBURL (nebu_migrate role),
	// consistent with the pattern in audit_integration_test.go:seedAdminSessionForAudit.
	db, err := sql.Open("pgx", migrationDBURL)
	if err != nil {
		return fmt.Errorf("open migration db: %w", err)
	}
	defer db.Close()

	_, err = db.Exec(
		`INSERT INTO admin_sessions (sid, user_id, created_at, expires_at)
		 VALUES ($1, $2, $3, $4)
		 ON CONFLICT (sid) DO UPDATE SET expires_at = EXCLUDED.expires_at`,
		testSID,
		"CiQwMDAwMDAwMC0wMDAwLTAwMDAtMDAwMC0wMDAwMDAwMDAwMDE", // kai@example.com Dex sub
		time.Now(),
		time.Now().Add(8*time.Hour),
	)
	if err != nil {
		return fmt.Errorf("insert admin session: %w", err)
	}

	// Create SID cookie payload: {"sid":"test-admin-session-001"}
	payload, err := json.Marshal(struct {
		SID string `json:"sid"`
	}{SID: testSID})
	if err != nil {
		return fmt.Errorf("marshal SID cookie: %w", err)
	}
	lastAdminSessionCookie = signTestCookie([]byte(strings.TrimSpace(internalSecret)), payload)
	return nil
}

// iRequestGETAdminDashboardWithCookie makes a no-redirect GET to /admin/dashboard
// with the admin_session cookie set to lastAdminSessionCookie.
func iRequestGETAdminDashboardWithCookie() error {
	client := noRedirectClient()
	req, err := http.NewRequest(http.MethodGet, adminURL("/admin/dashboard"), nil)
	if err != nil {
		return fmt.Errorf("build request: %w", err)
	}
	req.AddCookie(&http.Cookie{Name: "admin_session", Value: lastAdminSessionCookie})
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("GET /admin/dashboard: %w", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	lastStatusCode = resp.StatusCode
	lastBody = string(body)
	lastLocationHeader = resp.Header.Get("Location")
	return nil
}

// theResponseIs200 asserts the last HTTP response had status 200.
// Kept for backward compatibility; delegates to theResponseIs.
func theResponseIs200() error {
	return theResponseIs(http.StatusOK)
}

// iHaveSeededInstanceNameIntoBootstrapDraft seeds the instance_name key into
// bootstrap_draft so the wizard handler can load it in step 2.
// Uses ON CONFLICT DO UPDATE to be idempotent (AC5).
func iHaveSeededInstanceNameIntoBootstrapDraft(instanceName string) error {
	db, err := sql.Open("pgx", dbURL)
	if err != nil {
		return fmt.Errorf("open db: %w", err)
	}
	defer db.Close()

	_, err = db.Exec(
		`INSERT INTO bootstrap_draft (key, value, set_at)
		 VALUES ('instance_name', $1, $2)
		 ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, set_at = EXCLUDED.set_at`,
		instanceName,
		time.Now().UnixMilli(),
	)
	if err != nil {
		return fmt.Errorf("upsert bootstrap_draft instance_name: %w", err)
	}
	return nil
}

// extractCSRFToken parses the CSRF token from the rendered HTML form.
// The template embeds it as: <input type="hidden" name="_csrf" value="TOKEN">
func extractCSRFToken(body string) string {
	const marker = `name="_csrf" value="`
	idx := strings.Index(body, marker)
	if idx < 0 {
		return ""
	}
	rest := body[idx+len(marker):]
	end := strings.Index(rest, `"`)
	if end < 0 {
		return ""
	}
	return rest[:end]
}

// iPostStep2WithValidOIDCConfig drives the bootstrap wizard through step 2 and step 3,
// ending at the 303 redirect to /admin/login/start?mode=bootstrap.
//
// The handler processes two distinct POST requests:
//   - POST step=2 → saves OIDC config draft → renders step 3 form (200)
//   - POST step=3 → saves claim mapping → 303 redirect to OIDC login
//
// A http.CookieJar is required so the CSRF cookie set by the initial GET is
// carried across all subsequent POSTs (double-submit cookie pattern).
func iPostStep2WithValidOIDCConfig() error {
	jar, _ := cookiejar.New(nil)
	client := &http.Client{
		CheckRedirect: func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse
		},
		Jar: jar,
	}
	bootstrapURL := adminURL("/admin/bootstrap")

	// Step A: GET /admin/bootstrap to obtain CSRF token + cookie.
	getResp, err := client.Get(bootstrapURL)
	if err != nil {
		return fmt.Errorf("GET /admin/bootstrap: %w", err)
	}
	defer getResp.Body.Close()
	getBody, _ := io.ReadAll(getResp.Body)
	csrfToken := extractCSRFToken(string(getBody))
	if csrfToken == "" {
		return fmt.Errorf("could not extract CSRF token from /admin/bootstrap GET response")
	}

	// Step B: POST step=2 with OIDC config.
	step2Values := url.Values{}
	step2Values.Set("step", "2")
	step2Values.Set("instance_name", "test-nebu")
	step2Values.Set("oidc_issuer", "http://dex:5556/dex")
	step2Values.Set("oidc_client_id", "nebu-gateway")
	step2Values.Set("oidc_client_secret", "nebu-dev-secret")
	step2Values.Set("_csrf", csrfToken)

	step2Resp, err := client.PostForm(bootstrapURL, step2Values)
	if err != nil {
		return fmt.Errorf("POST step=2: %w", err)
	}
	defer step2Resp.Body.Close()
	step2Body, _ := io.ReadAll(step2Resp.Body)
	if step2Resp.StatusCode != http.StatusOK {
		return fmt.Errorf("POST step=2: expected 200, got %d (body: %.300s)", step2Resp.StatusCode, step2Body)
	}

	// Extract fresh CSRF token from step 3 form (returned in step=2 response body).
	csrf3 := extractCSRFToken(string(step2Body))
	if csrf3 == "" {
		return fmt.Errorf("could not extract CSRF token from step 2 response (step 3 form)")
	}

	// Step C: POST step=3 with claim mapping → 303 redirect.
	step3Values := url.Values{}
	step3Values.Set("step", "3")
	step3Values.Set("oidc_user_id_claim", "name")
	step3Values.Set("oidc_displayname_claim", "name")
	step3Values.Set("oidc_email_claim", "email")
	step3Values.Set("_csrf", csrf3)

	step3Resp, err := client.PostForm(bootstrapURL, step3Values)
	if err != nil {
		return fmt.Errorf("POST step=3: %w", err)
	}
	defer step3Resp.Body.Close()

	// Capture final response for assertion by theResponseRedirectsTo.
	finalBody, _ := io.ReadAll(step3Resp.Body)
	lastStatusCode = step3Resp.StatusCode
	lastBody = string(finalBody)
	lastLocationHeader = step3Resp.Header.Get("Location")
	return nil
}

// initializeAdminBootstrapSteps registers all step definitions for the admin bootstrap
// and dashboard flow scenarios.
// Note: "the response body contains" is registered in steps_test.go and reused here.
func initializeAdminBootstrapSteps(sc *godog.ScenarioContext) {
	sc.Step(`^the server has no bootstrap_completed in server_config$`, theServerHasNoBootstrapCompleted)
	sc.Step(`^I request GET (/\S+) without a session cookie$`, iRequestGETWithoutCookie)
	sc.Step(`^the response redirects to "([^"]*)"$`, theResponseRedirectsTo)
	sc.Step(`^I seed the bootstrap configuration directly into the database$`, iSeedBootstrapConfigDirectly)
	sc.Step(`^server_config contains key "([^"]*)" with value "([^"]*)"$`, serverConfigContainsKeyValue)
	sc.Step(`^bootstrap is complete and server_config is seeded$`, bootstrapIsCompleteAndSeeded)
	sc.Step(`^I have a forged valid admin session cookie$`, iHaveAForgedValidAdminSessionCookie)
	sc.Step(`^I request GET /admin/dashboard with the admin session cookie$`, iRequestGETAdminDashboardWithCookie)
	// Note: "^the response is (\d+)$" is registered in claim_mapping_steps_test.go (theResponseIs)
	// and handles all numeric status codes including 200. theResponseIs200 is kept as a helper function.
	// NEW:
	sc.Step(`^I have seeded instance_name "([^"]*)" into the bootstrap draft$`, iHaveSeededInstanceNameIntoBootstrapDraft)
	sc.Step(`^I POST step 2 with valid OIDC config to /admin/bootstrap$`, iPostStep2WithValidOIDCConfig)
}
