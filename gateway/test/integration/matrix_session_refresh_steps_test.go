//go:build integration

package integration_test

// ─── Story: oidc-session-refresh ─────────────────────────────────────────────
//
// Godog step definitions for gateway/features/matrix_session_refresh.feature.
//
// RED PHASE: All steps are registered and will fail until:
//   1. matrix_sessions table migration is applied
//   2. MatrixSessionStore (CRUD, RotateTokens, grace period) is implemented
//   3. POST /login issues opaque tokens when request has refresh_token:true
//   4. POST /_matrix/client/v3/refresh endpoint is registered (outside jwtMiddleware)
//   5. JWTMiddleware handles opaque tokens with expiry check + soft_logout:true
//
// AC coverage:
//   AC1 — opaque AT+RT+expires_in_ms on login with refresh_token:true
//   AC2 — POST /refresh returns new opaque AT+expires_in_ms
//   AC3 — new AT works for GET /sync and GET /whoami
//   AC4 — old RT valid during grace period; revoked after new AT is first used
//   AC5 — expired opaque AT → 401 M_UNKNOWN_TOKEN + soft_logout:true
//   AC6 — unknown/replaced RT → 401 M_UNKNOWN_TOKEN
//   AC7 — login without refresh_token:true returns JWT (backward compat)
//   Spec — /refresh needs no auth header; missing body/field → 400

import (
	"bytes"
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"strings"
	"time"

	"github.com/cucumber/godog"
	_ "github.com/jackc/pgx/v5/stdlib"
)

// ─── State ────────────────────────────────────────────────────────────────────

// Opaque token state for the current session refresh scenario.
var (
	// nebuOpaqueAT is the opaque access token obtained via /login (refresh_token:true).
	nebuOpaqueAT string
	// nebuOpaqueRT is the opaque refresh token obtained via /login (refresh_token:true).
	nebuOpaqueRT string
	// nebuNewAT holds the access_token from the most recent /refresh response.
	nebuNewAT string
	// capturedOldRT holds the RT_A captured before a /refresh call.
	capturedOldRT string
	// nebuExpiredAT is an opaque AT that is expired in the DB (set up via direct DB insert).
	nebuExpiredAT string
)

// opaqueHexRegex matches a 64-character lowercase hex string (32 bytes = 256 bits).
var opaqueHexRegex = regexp.MustCompile(`^[0-9a-f]{64}$`)

// ─── Step: POST /login with refresh_token:true ───────────────────────────────

// iPostLoginWithDexTokenAndRequestRefreshToken sends POST /login with the Dex
// id_token obtained in a prior step, requesting a refresh token.
// Sets lastStatusCode, lastBody, nebuOpaqueAT, nebuOpaqueRT.
//
// RED: Fails because /login does not yet issue opaque tokens when
// refresh_token:true is present — it returns the raw JWT instead.
func iPostLoginWithDexTokenAndRequestRefreshToken() error {
	payload := fmt.Sprintf(`{"type":"m.login.token","token":%q,"refresh_token":true}`, lastDexIDToken)
	loginURL := matrixURL + "/_matrix/client/v3/login"
	req, err := http.NewRequest(http.MethodPost, loginURL, strings.NewReader(payload))
	if err != nil {
		return fmt.Errorf("building POST /login (refresh) request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return fmt.Errorf("POST /login (refresh) failed: %w", err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return fmt.Errorf("reading POST /login (refresh) response: %w", err)
	}
	lastStatusCode = resp.StatusCode
	lastBody = string(body)
	if resp.StatusCode == http.StatusOK {
		var r struct {
			AccessToken  string `json:"access_token"`
			RefreshToken string `json:"refresh_token"`
		}
		if err := json.Unmarshal(body, &r); err == nil {
			nebuOpaqueAT = r.AccessToken
			nebuOpaqueRT = r.RefreshToken
		}
	}
	return nil
}

// ─── Assertions: opaque token shape ─────────────────────────────────────────

// theAccessTokenIsAnOpaqueHexStringWithNoDots asserts that the access_token in
// lastBody is a 64-character lowercase hex string (no dots, not a JWT).
//
// RED: fails because /login currently returns the raw OIDC JWT.
func theAccessTokenIsAnOpaqueHexStringWithNoDots() error {
	var r struct {
		AccessToken string `json:"access_token"`
	}
	if err := json.Unmarshal([]byte(lastBody), &r); err != nil {
		return fmt.Errorf("parsing access_token from response body: %w (body: %s)", err, lastBody)
	}
	if r.AccessToken == "" {
		return fmt.Errorf("access_token is empty in response body: %s", lastBody)
	}
	if strings.Contains(r.AccessToken, ".") {
		return fmt.Errorf("access_token must not be a JWT (contains dots): %q", r.AccessToken)
	}
	if !opaqueHexRegex.MatchString(r.AccessToken) {
		return fmt.Errorf("access_token %q does not match ^[0-9a-f]{64}$ (opaque hex)", r.AccessToken)
	}
	return nil
}

// theRefreshTokenIsAnOpaqueHexStringWithNoDots asserts that the refresh_token in
// lastBody is a 64-character lowercase hex string (no dots, not a JWT).
//
// RED: fails because /login currently returns no refresh_token field.
func theRefreshTokenIsAnOpaqueHexStringWithNoDots() error {
	var r struct {
		RefreshToken string `json:"refresh_token"`
	}
	if err := json.Unmarshal([]byte(lastBody), &r); err != nil {
		return fmt.Errorf("parsing refresh_token from response body: %w (body: %s)", err, lastBody)
	}
	if r.RefreshToken == "" {
		return fmt.Errorf("refresh_token is missing or empty in response body: %s", lastBody)
	}
	if strings.Contains(r.RefreshToken, ".") {
		return fmt.Errorf("refresh_token must not be a JWT (contains dots): %q", r.RefreshToken)
	}
	if !opaqueHexRegex.MatchString(r.RefreshToken) {
		return fmt.Errorf("refresh_token %q does not match ^[0-9a-f]{64}$ (opaque hex)", r.RefreshToken)
	}
	return nil
}

// theExpiresInMsIsGreaterThanZero asserts that expires_in_ms in lastBody is > 0.
//
// RED: fails because /login currently returns no expires_in_ms field.
func theExpiresInMsIsGreaterThanZero() error {
	var r struct {
		ExpiresInMs *int64 `json:"expires_in_ms"`
	}
	if err := json.Unmarshal([]byte(lastBody), &r); err != nil {
		return fmt.Errorf("parsing expires_in_ms from response body: %w (body: %s)", err, lastBody)
	}
	if r.ExpiresInMs == nil {
		return fmt.Errorf("expires_in_ms field is missing from response body: %s", lastBody)
	}
	if *r.ExpiresInMs <= 0 {
		return fmt.Errorf("expires_in_ms must be > 0, got %d", *r.ExpiresInMs)
	}
	return nil
}

// ─── Assertions: backward compat (AC7) ───────────────────────────────────────

// theLastLoginAccessTokenIsAJWTContainingDots asserts that the token stored in
// lastAccessToken (from the Background /login without refresh_token:true) is a
// JWT — i.e. it contains at least one dot.
//
// This must PASS in red phase (old behavior still works).
func theLastLoginAccessTokenIsAJWTContainingDots() error {
	if lastAccessToken == "" {
		return fmt.Errorf("lastAccessToken is empty — did the Background step complete?")
	}
	if !strings.Contains(lastAccessToken, ".") {
		return fmt.Errorf("expected lastAccessToken to be a JWT (containing dots), got: %q", lastAccessToken)
	}
	return nil
}

// theLastLoginResponseHasNoRefreshTokenField asserts that the most recent /login
// response body does NOT include a "refresh_token" JSON key.
//
// This must PASS in red phase (no field is the current behavior).
func theLastLoginResponseHasNoRefreshTokenField() error {
	if strings.Contains(lastBody, `"refresh_token"`) {
		return fmt.Errorf("expected no refresh_token in backward-compat login response, but found it: %s", lastBody)
	}
	return nil
}

// theLastLoginResponseHasNoExpiresInMsField asserts that the most recent /login
// response body does NOT include an "expires_in_ms" JSON key.
//
// This must PASS in red phase (no field is the current behavior).
func theLastLoginResponseHasNoExpiresInMsField() error {
	if strings.Contains(lastBody, `"expires_in_ms"`) {
		return fmt.Errorf("expected no expires_in_ms in backward-compat login response, but found it: %s", lastBody)
	}
	return nil
}

// ─── Given: establish a Nebu session ─────────────────────────────────────────

// iHaveANebuSessionWithOpaqueAccessTokenAndRefreshToken performs a full login
// with refresh_token:true for kai and stores the resulting opaque AT+RT.
//
// RED: fails because /login does not yet issue opaque tokens.
func iHaveANebuSessionWithOpaqueAccessTokenAndRefreshToken() error {
	// Re-use kai's Dex token (set by Background "kai is authenticated via OIDC").
	// We need a fresh Dex token; re-authenticate kai to ensure we have one.
	if err := iObtainDexTokenFor("kai@example.com", "changeme"); err != nil {
		return fmt.Errorf("obtaining fresh Dex token for kai: %w", err)
	}
	if err := iPostLoginWithDexTokenAndRequestRefreshToken(); err != nil {
		return fmt.Errorf("POST /login with refresh_token:true: %w", err)
	}
	if lastStatusCode != http.StatusOK {
		return fmt.Errorf("expected 200 from /login (refresh), got %d; body: %s", lastStatusCode, lastBody)
	}
	if nebuOpaqueAT == "" || nebuOpaqueRT == "" {
		return fmt.Errorf("opaque AT or RT missing after /login with refresh_token:true; body: %s", lastBody)
	}
	return nil
}

// iCaptureTheCurrentRefreshTokenAsRTA captures nebuOpaqueRT into capturedOldRT.
func iCaptureTheCurrentRefreshTokenAsRTA() error {
	if nebuOpaqueRT == "" {
		return fmt.Errorf("nebuOpaqueRT is empty — call 'I have a Nebu session' first")
	}
	capturedOldRT = nebuOpaqueRT
	return nil
}

// ─── When: POST /refresh ──────────────────────────────────────────────────────

// iPostRefreshWithCurrentRefreshToken sends POST /_matrix/client/v3/refresh
// with nebuOpaqueRT in the body. No Authorization header (spec MUST).
//
// RED: fails because the /refresh endpoint does not exist yet (404).
func iPostRefreshWithCurrentRefreshToken() error {
	return doPostRefresh(nebuOpaqueRT)
}

// iPostRefreshWithRTA sends POST /refresh using capturedOldRT (RT_A grace-period test).
//
// RED: fails because the /refresh endpoint does not exist yet.
func iPostRefreshWithRTA() error {
	return doPostRefresh(capturedOldRT)
}

// iPostRefreshWithRTAAgain is an alias for iPostRefreshWithRTA (second call in AC4 scenario).
func iPostRefreshWithRTAAgain() error {
	return doPostRefresh(capturedOldRT)
}

// iPostRefreshWithCurrentRefreshTokenAndNoAuthorizationHeader explicitly omits
// the Authorization header to verify the spec requirement that /refresh needs
// no auth header.
//
// RED: fails because the /refresh endpoint does not exist yet.
func iPostRefreshWithCurrentRefreshTokenAndNoAuthorizationHeader() error {
	return doPostRefresh(nebuOpaqueRT)
}

// iPostRefreshWithBody sends POST /refresh with an arbitrary raw JSON body.
// Used for spec edge-case tests (empty body, missing field).
//
// RED: fails because the /refresh endpoint does not exist yet.
func iPostRefreshWithBody(rawJSON string) error {
	return doPostRefreshRaw(rawJSON)
}

// iPostRefreshWithEmptyBody sends POST /refresh with an empty request body.
//
// RED: fails because the /refresh endpoint does not exist yet.
func iPostRefreshWithEmptyBody() error {
	return doPostRefreshRaw("")
}

// iPostRefreshWithOldRefreshTokenRTA sends POST /refresh with capturedOldRT
// after the new AT has been used (expects 401 in AC6 re-use scenario).
func iPostRefreshWithOldRefreshTokenRTA() error {
	return doPostRefresh(capturedOldRT)
}

// doPostRefresh performs the POST /_matrix/client/v3/refresh request.
// The spec MUST NOT require an Authorization header — no auth header is sent.
func doPostRefresh(refreshToken string) error {
	payload := fmt.Sprintf(`{"refresh_token":%q}`, refreshToken)
	return doPostRefreshRaw(payload)
}

// doPostRefreshRaw sends POST /refresh with the given raw body string.
func doPostRefreshRaw(rawBody string) error {
	refreshURL := matrixURL + "/_matrix/client/v3/refresh"
	var bodyReader io.Reader
	if rawBody != "" {
		bodyReader = strings.NewReader(rawBody)
	} else {
		bodyReader = bytes.NewReader(nil)
	}
	req, err := http.NewRequest(http.MethodPost, refreshURL, bodyReader)
	if err != nil {
		return fmt.Errorf("building POST /refresh request: %w", err)
	}
	if rawBody != "" {
		req.Header.Set("Content-Type", "application/json")
	}
	// Deliberately NO Authorization header — spec §refreshing-access-tokens: MUST NOT require auth.
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return fmt.Errorf("POST /refresh failed: %w", err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return fmt.Errorf("reading POST /refresh response: %w", err)
	}
	lastStatusCode = resp.StatusCode
	lastBody = string(body)
	if resp.StatusCode == http.StatusOK {
		var r struct {
			AccessToken string `json:"access_token"`
		}
		if err := json.Unmarshal(body, &r); err == nil && r.AccessToken != "" {
			nebuNewAT = r.AccessToken
		}
	}
	return nil
}

// ─── Then: assertions on /refresh response ───────────────────────────────────

// theNewAccessTokenIsAnOpaqueHexStringWithNoDots asserts that nebuNewAT from
// the last /refresh response is a 64-char lowercase hex string.
//
// RED: fails because /refresh endpoint does not exist yet.
func theNewAccessTokenIsAnOpaqueHexStringWithNoDots() error {
	if nebuNewAT == "" {
		return fmt.Errorf("no new access_token captured from /refresh response (body: %s)", lastBody)
	}
	if strings.Contains(nebuNewAT, ".") {
		return fmt.Errorf("new access_token must not be a JWT (contains dots): %q", nebuNewAT)
	}
	if !opaqueHexRegex.MatchString(nebuNewAT) {
		return fmt.Errorf("new access_token %q does not match ^[0-9a-f]{64}$", nebuNewAT)
	}
	return nil
}

// theNewExpiresInMsIsGreaterThanZero asserts expires_in_ms > 0 in the /refresh response.
//
// RED: fails because /refresh endpoint does not exist yet.
func theNewExpiresInMsIsGreaterThanZero() error {
	var r struct {
		ExpiresInMs *int64 `json:"expires_in_ms"`
	}
	if err := json.Unmarshal([]byte(lastBody), &r); err != nil {
		return fmt.Errorf("parsing expires_in_ms from /refresh response: %w (body: %s)", err, lastBody)
	}
	if r.ExpiresInMs == nil {
		return fmt.Errorf("expires_in_ms missing from /refresh response body: %s", lastBody)
	}
	if *r.ExpiresInMs <= 0 {
		return fmt.Errorf("expires_in_ms must be > 0, got %d", *r.ExpiresInMs)
	}
	return nil
}

// iCaptureTheNewAccessTokenFromTheRefreshResponse stores the access_token from
// the last /refresh response into nebuNewAT (already set by doPostRefreshRaw).
func iCaptureTheNewAccessTokenFromTheRefreshResponse() error {
	if nebuNewAT == "" {
		return fmt.Errorf("no new access_token in /refresh response; body: %s", lastBody)
	}
	return nil
}

// ─── When: authenticated GET requests with custom token ──────────────────────

// iCallGETSyncWithNewAccessToken calls GET /_matrix/client/v3/sync with nebuNewAT.
//
// RED: fails because /sync with an opaque AT will currently return 401 (not
// recognized as a valid token until the MatrixSessionStore lookup is implemented).
func iCallGETSyncWithNewAccessToken() error {
	return doAuthenticatedGET("/_matrix/client/v3/sync", nebuNewAT)
}

// iCallGETWhoamiWithNewAccessToken calls GET /_matrix/client/v3/account/whoami
// using nebuNewAT.
//
// RED: same failure reason as iCallGETSyncWithNewAccessToken.
func iCallGETWhoamiWithNewAccessToken() error {
	return doAuthenticatedGET("/_matrix/client/v3/account/whoami", nebuNewAT)
}

// iCallGETSyncWithExpiredAccessToken calls GET /sync using nebuExpiredAT.
//
// RED: fails because JWTMiddleware does not yet perform an opaque token DB
// lookup with expiry check + soft_logout flag.
func iCallGETSyncWithExpiredAccessToken() error {
	return doAuthenticatedGET("/_matrix/client/v3/sync", nebuExpiredAT)
}

// doAuthenticatedGET performs a GET request to matrixURL+path using the
// given Bearer token.
func doAuthenticatedGET(path, token string) error {
	reqURL := matrixURL + path
	req, err := http.NewRequest(http.MethodGet, reqURL, nil)
	if err != nil {
		return fmt.Errorf("building GET %s request: %w", path, err)
	}
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return fmt.Errorf("GET %s failed: %w", path, err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return fmt.Errorf("reading GET %s response: %w", path, err)
	}
	lastStatusCode = resp.StatusCode
	lastBody = string(body)
	return nil
}

// ─── Given: expired token setup ──────────────────────────────────────────────

// iHaveAnOpaqueAccessTokenThatIsAlreadyExpiredInTheDatabase creates a Nebu session
// in the database with expires_at set to 2 seconds in the past, then stores the
// opaque AT in nebuExpiredAT.
//
// Uses direct DB access via dbURL (defined in main_test.go) to bypass the
// MatrixSessionStore.Create method (which would enforce valid expiry times).
// This is required to set up AC5 test state (expired opaque AT).
func iHaveAnOpaqueAccessTokenThatIsAlreadyExpiredInTheDatabase() error {
	// Open a direct DB connection using dbURL from main_test.go.
	sqlDB, err := sql.Open("pgx", dbURL)
	if err != nil {
		return fmt.Errorf("opening DB for expired AT setup: %w", err)
	}
	defer sqlDB.Close()
	if err := sqlDB.Ping(); err != nil {
		return fmt.Errorf("pinging DB for expired AT setup: %w", err)
	}

	// Generate opaque AT and RT (32 random bytes each, 64-char hex).
	atBytes := make([]byte, 32)
	if _, err := rand.Read(atBytes); err != nil {
		return fmt.Errorf("generating expired opaque AT: %w", err)
	}
	rtBytes := make([]byte, 32)
	if _, err := rand.Read(rtBytes); err != nil {
		return fmt.Errorf("generating expired opaque RT: %w", err)
	}
	expiredAT := hex.EncodeToString(atBytes)
	expiredRT := hex.EncodeToString(rtBytes)

	// Insert a session row with expires_at 2 seconds in the past.
	_, err = sqlDB.ExecContext(context.Background(),
		`INSERT INTO matrix_sessions
			(access_token, refresh_token, user_id, device_id, expires_at, created_at)
		 VALUES ($1, $2, '@kai:localhost', 'EXPIRED_DEVICE', $3, NOW())`,
		expiredAT,
		expiredRT,
		time.Now().Add(-2*time.Second),
	)
	if err != nil {
		return fmt.Errorf("inserting expired matrix session: %w", err)
	}

	nebuExpiredAT = expiredAT
	return nil
}

// iCallGETWithTheExpiredAccessToken is handled by iCallGETSyncWithExpiredAccessToken.

// ─── Then: soft_logout assertion ─────────────────────────────────────────────

// theSoftLogoutFieldIsTrue asserts that the JSON response body has "soft_logout": true.
//
// RED: fails because JWTMiddleware does not yet set soft_logout.
func theSoftLogoutFieldIsTrue() error {
	var r struct {
		SoftLogout *bool `json:"soft_logout"`
	}
	if err := json.Unmarshal([]byte(lastBody), &r); err != nil {
		return fmt.Errorf("parsing soft_logout from response body: %w (body: %s)", err, lastBody)
	}
	if r.SoftLogout == nil {
		return fmt.Errorf("soft_logout field is missing from 401 response body: %s", lastBody)
	}
	if !*r.SoftLogout {
		return fmt.Errorf("expected soft_logout:true, got soft_logout:false (body: %s)", lastBody)
	}
	return nil
}

// ─── Step registration ────────────────────────────────────────────────────────

// initializeMatrixSessionRefreshSteps registers all step definitions for the
// matrix_session_refresh.feature scenarios.
func initializeMatrixSessionRefreshSteps(sc *godog.ScenarioContext) {
	// Reset scenario-local state on each scenario start.
	sc.Before(func(ctx context.Context, _ *godog.Scenario) (context.Context, error) {
		nebuOpaqueAT = ""
		nebuOpaqueRT = ""
		nebuNewAT = ""
		capturedOldRT = ""
		nebuExpiredAT = ""
		return ctx, nil
	})

	// ── When: login steps ────────────────────────────────────────────────────
	sc.Step(`^I POST /login with the Dex token and request a refresh token$`,
		iPostLoginWithDexTokenAndRequestRefreshToken)

	// ── Then: opaque token shape assertions ──────────────────────────────────
	sc.Step(`^the access_token is an opaque hex string with no dots$`,
		theAccessTokenIsAnOpaqueHexStringWithNoDots)
	sc.Step(`^the refresh_token is an opaque hex string with no dots$`,
		theRefreshTokenIsAnOpaqueHexStringWithNoDots)
	sc.Step(`^the expires_in_ms is greater than zero$`,
		theExpiresInMsIsGreaterThanZero)

	// ── Then: backward compat assertions (AC7) ───────────────────────────────
	sc.Step(`^the last login access_token is a JWT containing dots$`,
		theLastLoginAccessTokenIsAJWTContainingDots)
	sc.Step(`^the last login response has no refresh_token field$`,
		theLastLoginResponseHasNoRefreshTokenField)
	sc.Step(`^the last login response has no expires_in_ms field$`,
		theLastLoginResponseHasNoExpiresInMsField)

	// ── Given: session setup ─────────────────────────────────────────────────
	sc.Step(`^I have a Nebu session with opaque access token and refresh token$`,
		iHaveANebuSessionWithOpaqueAccessTokenAndRefreshToken)
	sc.Step(`^I capture the current refresh token as RT_A$`,
		iCaptureTheCurrentRefreshTokenAsRTA)
	sc.Step(`^I have an opaque access token that is already expired in the database$`,
		iHaveAnOpaqueAccessTokenThatIsAlreadyExpiredInTheDatabase)

	// ── When: POST /refresh steps ─────────────────────────────────────────────
	sc.Step(`^I POST /_matrix/client/v3/refresh with the current refresh token$`,
		iPostRefreshWithCurrentRefreshToken)
	sc.Step(`^I POST /_matrix/client/v3/refresh with RT_A$`,
		iPostRefreshWithRTA)
	sc.Step(`^I POST /_matrix/client/v3/refresh with RT_A again$`,
		iPostRefreshWithRTAAgain)
	sc.Step(`^I POST /_matrix/client/v3/refresh with the current refresh token and no Authorization header$`,
		iPostRefreshWithCurrentRefreshTokenAndNoAuthorizationHeader)
	sc.Step(`^I POST /_matrix/client/v3/refresh with body (.+)$`,
		iPostRefreshWithBody)
	sc.Step(`^I POST /_matrix/client/v3/refresh with an empty body$`,
		iPostRefreshWithEmptyBody)
	sc.Step(`^I POST /_matrix/client/v3/refresh with the old refresh token RT_A$`,
		iPostRefreshWithOldRefreshTokenRTA)

	// ── Then: /refresh response assertions ───────────────────────────────────
	sc.Step(`^the new access_token is an opaque hex string with no dots$`,
		theNewAccessTokenIsAnOpaqueHexStringWithNoDots)
	sc.Step(`^the new expires_in_ms is greater than zero$`,
		theNewExpiresInMsIsGreaterThanZero)
	sc.Step(`^I capture the new access token from the refresh response$`,
		iCaptureTheNewAccessTokenFromTheRefreshResponse)

	// ── When: authenticated requests with new/expired token ──────────────────
	sc.Step(`^I call GET /_matrix/client/v3/sync with the new access token$`,
		iCallGETSyncWithNewAccessToken)
	sc.Step(`^I call GET /_matrix/client/v3/account/whoami with the new access token$`,
		iCallGETWhoamiWithNewAccessToken)
	sc.Step(`^I call GET /_matrix/client/v3/sync with the expired access token$`,
		iCallGETSyncWithExpiredAccessToken)

	// ── Then: soft_logout assertion ───────────────────────────────────────────
	sc.Step(`^the soft_logout field is true$`,
		theSoftLogoutFieldIsTrue)
}
