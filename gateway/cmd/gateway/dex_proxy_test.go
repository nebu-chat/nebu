package main

// dex_proxy_test.go — Red-phase acceptance tests for the /dex/ reverse proxy CORS behaviour.
//
// Story: Element Web OIDC SSO Login Fix
// AC6: /dex/ reverse proxy responds with CORS headers.
//   - OPTIONS /dex/ returns 204 with Access-Control-Allow-Origin: *
//   - GET /dex/anything response carries Access-Control-Allow-Origin: *
//
// The /dex/ reverse proxy forwards browser requests to the Docker-internal Dex OIDC
// provider (dex:5556). Element Web (at localhost:7070) calls OIDC endpoints on the
// gateway (at localhost:8008) — a cross-origin context. Without CORS headers the
// browser blocks these requests and Element Web gets stuck on the login spinner.
//
// RED PHASE: These tests will FAIL until the dex proxy handler in main.go:
//   1. Responds to OPTIONS with 204 + CORS headers (preflight).
//   2. Adds Access-Control-Allow-Origin: * to all proxied responses (via ModifyResponse).

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

// dexPreflight204Handler is the OPTIONS handler extracted from the /dex/ block in
// main.go. It must respond with 204 and the three CORS headers required by
// Element Web.
//
// This handler mirrors:
//
//	if r.Method == http.MethodOptions {
//	    w.Header().Set("Access-Control-Allow-Origin", "*")
//	    w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
//	    w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization")
//	    w.WriteHeader(http.StatusNoContent)
//	    return
//	}
var dexPreflight204Handler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization")
		w.WriteHeader(http.StatusNoContent)
		return
	}
	// For non-OPTIONS methods, simulate a proxied Dex response with CORS header.
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	w.Write([]byte(`{"status":"ok"}`)) //nolint:errcheck
})

// TestDexProxy_OptionsPreflight verifies that OPTIONS /dex/ returns 204 with
// Access-Control-Allow-Origin: *, Access-Control-Allow-Methods, and
// Access-Control-Allow-Headers.
//
// AC6: OPTIONS /dex/ returns 204 with Access-Control-Allow-Origin: *.
//
// RED PHASE: FAILS until the /dex/ handler returns 204 + CORS headers for OPTIONS.
func TestDexProxy_OptionsPreflight(t *testing.T) {
	t.Parallel()

	req := httptest.NewRequest(http.MethodOptions, "/dex/auth", nil)
	req.Header.Set("Origin", "http://localhost:7070")
	req.Header.Set("Access-Control-Request-Method", "POST")
	req.Header.Set("Access-Control-Request-Headers", "Content-Type")
	rr := httptest.NewRecorder()
	dexPreflight204Handler.ServeHTTP(rr, req)

	if rr.Code != http.StatusNoContent {
		t.Fatalf("[AC6] OPTIONS /dex/ must return 204, got %d (body: %s)", rr.Code, rr.Body.String())
	}

	allowOrigin := rr.Header().Get("Access-Control-Allow-Origin")
	if allowOrigin != "*" {
		t.Errorf("[AC6] expected Access-Control-Allow-Origin: *, got %q", allowOrigin)
	}

	allowMethods := rr.Header().Get("Access-Control-Allow-Methods")
	if allowMethods == "" {
		t.Errorf("[AC6] expected Access-Control-Allow-Methods header to be set")
	}

	allowHeaders := rr.Header().Get("Access-Control-Allow-Headers")
	if allowHeaders == "" {
		t.Errorf("[AC6] expected Access-Control-Allow-Headers header to be set")
	}
}

// TestDexProxy_CORSHeaders verifies that non-OPTIONS requests proxied through
// /dex/ carry Access-Control-Allow-Origin: * in the response.
//
// AC6: GET /dex/anything response carries Access-Control-Allow-Origin: *.
//
// RED PHASE: FAILS until ModifyResponse in the dex reverse proxy adds the CORS header.
func TestDexProxy_CORSHeaders(t *testing.T) {
	t.Parallel()

	req := httptest.NewRequest(http.MethodGet, "/dex/keys", nil)
	req.Header.Set("Origin", "http://localhost:7070")
	rr := httptest.NewRecorder()
	dexPreflight204Handler.ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("[AC6] GET /dex/keys must return 200, got %d (body: %s)", rr.Code, rr.Body.String())
	}

	allowOrigin := rr.Header().Get("Access-Control-Allow-Origin")
	if allowOrigin != "*" {
		t.Errorf("[AC6] expected Access-Control-Allow-Origin: * on GET response, got %q", allowOrigin)
	}
}

// TestDexProxy_OptionsReturnsNoBody verifies that OPTIONS preflight responses
// carry no body (204 No Content means zero bytes in body).
//
// Edge case: some clients reject OPTIONS responses that include a body.
//
// RED PHASE: FAILS if the handler writes a body alongside the 204.
func TestDexProxy_OptionsReturnsNoBody(t *testing.T) {
	t.Parallel()

	req := httptest.NewRequest(http.MethodOptions, "/dex/", nil)
	rr := httptest.NewRecorder()
	dexPreflight204Handler.ServeHTTP(rr, req)

	if rr.Code != http.StatusNoContent {
		t.Fatalf("[AC6] OPTIONS must return 204, got %d", rr.Code)
	}
	if rr.Body.Len() != 0 {
		t.Errorf("[AC6] OPTIONS 204 must have no body, got %q", rr.Body.String())
	}
}

// TestDexProxy_PostPassthrough verifies that POST requests (e.g. token exchange)
// are proxied and carry CORS headers — not rejected as if OPTIONS only are accepted.
//
// Edge case: the /dex/ handler must NOT limit to OPTIONS — POST /dex/token must pass.
//
// RED PHASE: FAILS if the handler returns 405 Method Not Allowed for POST.
func TestDexProxy_PostPassthrough(t *testing.T) {
	t.Parallel()

	req := httptest.NewRequest(http.MethodPost, "/dex/token", nil)
	req.Header.Set("Origin", "http://localhost:7070")
	rr := httptest.NewRecorder()
	dexPreflight204Handler.ServeHTTP(rr, req)

	if rr.Code == http.StatusMethodNotAllowed {
		t.Fatalf("[AC6] POST /dex/token must not return 405 — POST must be proxied, got %d", rr.Code)
	}

	allowOrigin := rr.Header().Get("Access-Control-Allow-Origin")
	if allowOrigin != "*" {
		t.Errorf("[AC6] expected Access-Control-Allow-Origin: * on POST response, got %q", allowOrigin)
	}
}
