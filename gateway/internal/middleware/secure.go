package middleware

import (
	"net/http"
	"os"
)

// IsRequestSecure returns true when the request was received over HTTPS.
// When NEBU_TRUSTED_PROXY=true, also trusts X-Forwarded-Proto: https.
// Fail-closed: if the header is missing, returns false.
func IsRequestSecure(r *http.Request) bool {
	if r.TLS != nil {
		return true
	}
	if os.Getenv("NEBU_TRUSTED_PROXY") == "true" {
		return r.Header.Get("X-Forwarded-Proto") == "https"
	}
	return false
}
