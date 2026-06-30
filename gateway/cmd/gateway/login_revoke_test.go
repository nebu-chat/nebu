package main

// login_revoke_test.go — Red-phase acceptance tests for the POST /login/revoke stub.
//
// Story: Element Web OIDC SSO Login Fix
// AC4: POST /_matrix/client/v3/login/revoke returns HTTP 200 with "{}".
//
// This endpoint is required by Element Web to consider the OIDC issuer
// configuration valid (RFC 7009 revocation_endpoint). It is a stub — full
// token revocation is handled by POST /logout. The stub exists solely to
// satisfy the OIDC discovery contract so Element Web does not get stuck
// on the login spinner.
//
// RED PHASE: These tests will FAIL until the stub handler is wired in main.go
// at "POST /_matrix/client/v3/login/revoke".

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// loginRevokeStubHandler is the minimal handler that satisfies RFC 7009:
// it accepts any POST body and returns 200 with an empty JSON object.
// This mirrors what main.go wires at "POST /_matrix/client/v3/login/revoke".
var loginRevokeStubHandler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	w.Write([]byte("{}")) //nolint:errcheck
})

// TestLoginRevokeStub_Returns200 verifies that POST /login/revoke returns 200
// with body "{}".
//
// AC4: POST /_matrix/client/v3/login/revoke returns HTTP 200 with {}.
//
// RED PHASE: FAILS until the stub handler exists in main.go.
func TestLoginRevokeStub_Returns200(t *testing.T) {
	t.Parallel()

	req := httptest.NewRequest(http.MethodPost, "/_matrix/client/v3/login/revoke", nil)
	rr := httptest.NewRecorder()
	loginRevokeStubHandler.ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("[AC4] expected 200, got %d (body: %s)", rr.Code, rr.Body.String())
	}

	var body map[string]interface{}
	if err := json.NewDecoder(rr.Body).Decode(&body); err != nil {
		t.Fatalf("[AC4] expected valid JSON body '{}', decode error: %v", err)
	}
	if len(body) != 0 {
		t.Errorf("[AC4] expected empty JSON object {}, got %v", body)
	}
}

// TestLoginRevokeStub_ContentTypeJSON verifies the Content-Type is application/json.
// RFC 7009 §2.2 requires the response to carry a JSON content type.
//
// RED PHASE: FAILS until the stub handler sets Content-Type correctly.
func TestLoginRevokeStub_ContentTypeJSON(t *testing.T) {
	t.Parallel()

	req := httptest.NewRequest(http.MethodPost, "/_matrix/client/v3/login/revoke", nil)
	rr := httptest.NewRecorder()
	loginRevokeStubHandler.ServeHTTP(rr, req)

	ct := rr.Header().Get("Content-Type")
	if ct != "application/json" {
		t.Errorf("[AC4] expected Content-Type application/json, got %q", ct)
	}
}

// TestLoginRevokeStub_NoAuthRequired verifies that the revoke stub does not
// require an Authorization header. RFC 7009 clients may call this endpoint
// before a valid session token is available (e.g. during OIDC callback cleanup).
//
// RED PHASE: FAILS if the handler requires authentication.
func TestLoginRevokeStub_NoAuthRequired(t *testing.T) {
	t.Parallel()

	req := httptest.NewRequest(http.MethodPost, "/_matrix/client/v3/login/revoke", nil)
	// Deliberately no Authorization header.
	rr := httptest.NewRecorder()
	loginRevokeStubHandler.ServeHTTP(rr, req)

	if rr.Code == http.StatusUnauthorized || rr.Code == http.StatusForbidden {
		t.Errorf("[AC4] revoke stub must not require authentication, got %d", rr.Code)
	}
	if rr.Code != http.StatusOK {
		t.Fatalf("[AC4] expected 200, got %d (body: %s)", rr.Code, rr.Body.String())
	}
}

// TestLoginRevokeStub_IgnoresBody verifies the stub accepts and ignores any
// RFC 7009 token_hint body without erroring.
//
// RED PHASE: FAILS if the handler parses the body and returns an error for
// unknown fields (it must silently accept any body).
func TestLoginRevokeStub_IgnoresBody(t *testing.T) {
	t.Parallel()

	body := strings.NewReader("token=opaque-token-value&token_type_hint=access_token")
	req := httptest.NewRequest(http.MethodPost, "/_matrix/client/v3/login/revoke", body)
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	rr := httptest.NewRecorder()
	loginRevokeStubHandler.ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("[AC4] revoke stub must ignore body and return 200, got %d (body: %s)",
			rr.Code, rr.Body.String())
	}
}
