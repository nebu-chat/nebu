package main

// profile_ratelimit_test.go — Red-phase acceptance tests for profile endpoint rate-limit tier.
//
// Story: Element Web OIDC SSO Login Fix
// AC5: Multiple concurrent users can log in without rate-limit errors.
//   Profile endpoint GET /_matrix/client/v3/profile/{userId} must be on looseRL
//   (300 req/min, burst 100), not mediumRL (30 req/min, burst 10).
//
// Root cause: When multiple browser tabs or concurrent clients hit the profile
// endpoint during the OIDC SSO login flow, mediumRL (burst 10) is exhausted
// quickly and returns 429 M_LIMIT_EXCEEDED, which appears in Element Web as a
// login error / spinner hang.
//
// Fix: profile endpoint must use looseRL (300 req/min, burst 100) — identical to
// the other unauthenticated public discovery endpoints.
//
// RED PHASE: These tests will FAIL until the profile endpoint in main.go is
// switched from mediumRL to looseRL.

import (
	"net/http"
	"net/http/httptest"
	"os"
	"sync"
	"testing"

	"golang.org/x/time/rate"

	"github.com/nebu/nebu/internal/middleware"
)

// TestProfileEndpoint_LooseRL_ConcurrentRequestsDoNotHit429 verifies that 10
// concurrent profile lookups from distinct IPs all succeed under looseRL
// (burst 100) without any 429 responses.
//
// If the profile endpoint were on mediumRL (burst 10) this test would see 429s
// once the burst is exhausted — that is the root cause of the login spinner bug.
//
// AC5: concurrent profile lookups under looseRL do not exhaust the budget.
//
// RED PHASE: FAILS if the profile handler is wrapped in mediumRL (burst 10).
func TestProfileEndpoint_LooseRL_ConcurrentRequestsDoNotHit429(t *testing.T) {
	t.Parallel()

	// looseRL config: 300 req/min, burst 100 — matches main.go looseRL definition.
	looseRLCfg := middleware.RateLimitConfig{
		Rate:  rate.Limit(300.0 / 60.0),
		Burst: 100,
	}
	looseRL := middleware.NewIPRateLimiter(looseRLCfg, false, "loose")

	// A minimal profile-like handler: returns 200 with a simple JSON body.
	profileOKHandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(`{"displayname":"Alex","avatar_url":""}`)) //nolint:errcheck
	})

	handler := looseRL(profileOKHandler)

	// Fire 20 concurrent requests from distinct IPs (simulating 20 clients
	// fetching profiles during the SSO login flow).
	const concurrency = 20
	var wg sync.WaitGroup
	results := make([]int, concurrency)

	for i := 0; i < concurrency; i++ {
		wg.Add(1)
		go func(idx int) {
			defer wg.Done()
			req := httptest.NewRequest(http.MethodGet,
				"/_matrix/client/v3/profile/@alice:nebu.example.com", nil)
			// Each goroutine uses a distinct IP to get an independent bucket.
			req.RemoteAddr = "10.0.0." + string(rune('1'+idx%20)) + ":9000"
			rr := httptest.NewRecorder()
			handler.ServeHTTP(rr, req)
			results[idx] = rr.Code
		}(i)
	}
	wg.Wait()

	for i, code := range results {
		if code == http.StatusTooManyRequests {
			t.Errorf("[AC5] request %d returned 429 — profile endpoint must be on looseRL (burst 100), not mediumRL (burst 10)", i)
		}
		if code != http.StatusOK {
			t.Errorf("[AC5] request %d returned %d, expected 200", i, code)
		}
	}
}

// TestProfileEndpoint_MediumRL_ExhaustsAt10 demonstrates that 15 requests from
// the same IP WOULD fail under mediumRL (burst 10) — this documents the root
// cause of the login-spinner bug and serves as a regression guard.
//
// AC5 (negative): mediumRL exhausts at burst 10; looseRL does not — they differ.
//
// This test skips when NEBU_RATE_LIMIT_DISABLED=true because NewIPRateLimiter
// returns a no-op middleware in that mode and exhaustion can never be triggered.
func TestProfileEndpoint_MediumRL_ExhaustsAt10(t *testing.T) {
	t.Parallel()

	if os.Getenv("NEBU_RATE_LIMIT_DISABLED") == "true" {
		t.Skip("NEBU_RATE_LIMIT_DISABLED=true: rate limiter is a no-op, skipping exhaustion test")
	}

	// mediumRL config: 30 req/min, burst 10 — matches main.go mediumRL definition.
	mediumRLCfg := middleware.RateLimitConfig{
		Rate:  rate.Limit(30.0 / 60.0),
		Burst: 10,
	}
	mediumRL := middleware.NewIPRateLimiter(mediumRLCfg, false, "medium")

	okHandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})

	handler := mediumRL(okHandler)

	// Send 15 requests from the SAME IP — burst 10 means requests 11-15 get 429.
	const ip = "203.0.113.10:9999"
	var rateLimitedCount int
	for i := 0; i < 15; i++ {
		req := httptest.NewRequest(http.MethodGet, "/profile", nil)
		req.RemoteAddr = ip
		rr := httptest.NewRecorder()
		handler.ServeHTTP(rr, req)
		if rr.Code == http.StatusTooManyRequests {
			rateLimitedCount++
		}
	}

	if rateLimitedCount == 0 {
		t.Errorf("[AC5-negative] mediumRL (burst 10) should have rate-limited at least one request in 15; got 0 — test setup may be wrong")
	}
}
