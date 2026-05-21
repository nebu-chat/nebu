# Security Review - Story 11-5 Search Rate-Limiting

**Diff scope:** Per-user (10 req/min) rate-limit middleware for `POST /_matrix/client/v3/search`.
**Reviewer:** Kassandra
**Date:** 2026-05-11
**Verdict:** **APPROVED - CLEAN (0 findings)**

---

## Files Reviewed

| File | Change | Lines of interest |
|---|---|---|
| `gateway/internal/middleware/ratelimit.go` | Added `NewUserRateLimiter` + `writeUserTooManyRequests` | 188–266 |
| `gateway/cmd/gateway/main.go` | Added `searchRL` instance and route wiring | 224–226, 729–737 |
| `gateway/internal/middleware/ratelimit_test.go` | Added 5 ATDD tests | (not in security scope) |

Reference docs cross-checked:
- `gateway/internal/middleware/auth.go:131–147` - `contextKey` type and `ContextKeyUserID` declaration
- `gateway/internal/middleware/auth.go:166–248` - `JWTMiddleware` populates `ContextKeyUserID` only after `verifier.Verify()` succeeds
- `gateway/cmd/gateway/main.go:471–475` - `jwtWithStatusCheck` composition
- `gateway/cmd/gateway/main.go:737` - Final handler chain
- Story spec `docs/stories/phase2/epic-11/11-5-search-rate-limiting.md`

---

## Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|

No findings.

---

## Security-Specific Checks (per task scope)

### 1. Rate-limit bypass via spoofed `user_id` context key  -  CLEAN

**Threat model:** Attacker injects a forged Matrix user_id (e.g. via HTTP header, body, or query param) and is keyed under a victim's bucket, bypassing their own limit (or filling the victim's bucket).

**Why this is not exploitable:**

- `ContextKeyUserID` is declared `contextKey("user_id")` where `contextKey` is an **unexported `string`-type alias** (`auth.go:131`). External packages cannot construct a key of this type; even another package literal `"user_id"` is a different key type and would not collide.
- HTTP and gRPC metadata cannot inject Go `context.Value` entries - `context` is purely in-process.
- The only writer to `ContextKeyUserID` is `JWTMiddleware` (`auth.go:243`), and it sets the value **after** `verifier.Verify(...)` succeeds (`auth.go:193`) and only from JWT claims via `coregrpc.FormatUserIDFromClaims(sub, name, srv)` (`auth.go:234`).
- The handler chain (`main.go:737`) places `jwtWithStatusCheck` outside `searchRL`, so the JWT middleware runs and populates the context value **before** `searchRL` reads it.

Result: the rate-limit key is provably derived from a cryptographically verified JWT and a constant server name. Spoofing is not possible without compromising the OIDC IdP.

### 2. DoS amplification on fallback IP path  -  CLEAN

**Threat model:** Unauthenticated requests reach `searchRL`, fall through to `extractClientIP`, accumulate one bucket per spoofed `RemoteAddr`/`X-Forwarded-For` until the LRU evicts. With a botnet, the attacker could churn 10 000 buckets/sec, evicting legitimate users' state.

**Why this is not exploitable:**

- Chain order (`main.go:737`): `bodyLimit1MiB(jwtWithStatusCheck(searchRL(...)))`. `jwtWithStatusCheck` rejects unauthenticated requests with `401 M_MISSING_TOKEN`/`M_UNKNOWN_TOKEN` (`auth.go:177, 198`) **before** the inner `searchRL` ever sees the request.
- The IP fallback in `NewUserRateLimiter` (lines 238–240) is therefore **unreachable** in the production chain. It exists as belt-and-suspenders for unit tests that bypass JWT and (correctly) prevents `nil`-pointer / empty-key panics if a future story wires the middleware on an unauthenticated endpoint by accident.
- LRU capacity is bounded at 10 000 (`lruCapacity` constant). Worst case memory ≈ 10 000 × (rate.Limiter struct ~64 B + map overhead ~80 B) ≈ ~1.5 MB - bounded, not amplifiable.
- `extractClientIP(r, false)` (the fallback uses `trustedProxy=false`) means `X-Forwarded-For` is NOT honored on the fallback path even if it were reachable. The bucket key is `RemoteAddr` only.

### 3. Bucket exhaustion via `user_id` manipulation  -  CLEAN

Same root cause as Check 1: there is no path through which user A can present a request that is keyed under user B's bucket without holding user B's valid JWT (`sub`+`name` claims). Forcing the key to a victim's identity requires forging or stealing the victim's OIDC token, which is out of scope for rate-limit hardening and would be a JWT/auth issue first.

### 4. LRU race condition  -  CLEAN

`NewUserRateLimiter.getLimiter` (lines 224–233) wraps the `cache.Get` + `cache.Add` sequence in `mu.Lock()` / `defer mu.Unlock()`. This is identical to the existing `NewIPRateLimiter.getLimiter` pattern (lines 131–142), which was hardened in Story 5.21 (per its inline comment: "prevents a TOCTOU race where two concurrent requests for the same new IP each create separate limiters"). The same protection now extends to per-user keys. `golang-lru` v1.0.2's internal locking is also concurrent-safe, so the explicit mutex is defense-in-depth for atomicity of the *compound* Get-or-Add operation.

### 5. `retry_after_ms` info leak  -  CLEAN

`retry_after_ms = retryAfterSeconds * 1000` where `retryAfterSeconds = int(math.Ceil(delay.Seconds()))` and `delay = reservation.Delay()` (line 250). `Delay()` is a pure function of the bucket's current token level and configured `Rate`/`Burst` - both of which are public knowledge (`10 req/min, burst 10`). Bounded between 1 and ~60 seconds. It reveals nothing about:

- Internal DB latency or query timing
- Other users' activity
- System load
- Token validation results

No timing oracle. The value is exactly what the spec requires (Matrix CS API §11.14 / §3.2.2). Note also that for the construction-time misconfiguration branch (`!reservation.OK()` at line 244), the response hardcodes `retry_after_ms = 1000` rather than leaking that the limiter is misconfigured.

### 6. `NEBU_RATE_LIMIT_DISABLED` env-var location  -  CLEAN

Checked **at limiter construction** (`NewUserRateLimiter`, line 217):

```go
if os.Getenv("NEBU_RATE_LIMIT_DISABLED") == "true" {
    return func(next http.Handler) http.Handler { return next }
}
```

If disabled, the returned middleware is a literal pass-through closure - not a closure that re-checks the env on each request. This means:

- No env-var read on the hot path → no `os.Getenv` syscall per request.
- No TOCTOU: an attacker who somehow flips the env var at runtime (e.g. via a compromised admin shell) cannot disable rate limiting on the running process; the middleware was bound at startup.
- Identical pattern to the established `NewIPRateLimiter` (line 121–123). Behavioral parity is correct.

### 7. Handler chain order - `searchRL` runs AFTER `jwtWithStatusCheck`  -  CLEAN

`gateway/cmd/gateway/main.go:737`:

```go
mux.Handle("POST /_matrix/client/v3/search",
    bodyLimit1MiB(jwtWithStatusCheck(searchRL(http.HandlerFunc(searchHandler.PostSearch)))))
```

Execution order (outer to inner):

1. `bodyLimit1MiB` - reject oversized bodies first (cheap, no auth needed)
2. `jwtWithStatusCheck` - validate JWT, populate `ContextKeyUserID`, reject 401 if absent/invalid
3. `searchRL` - read `ContextKeyUserID` from context, key bucket on it
4. `searchHandler.PostSearch` - handler

This is the **only correct ordering**. The story's "Dev Notes" section explicitly debated the chain order and arrived at this configuration, with the security trade-off documented (rate-limit budget is not consumed by unauthenticated requests; those die at the JWT gate). The implementation matches the spec exactly.

---

## Additional Adversarial Checks (out of scope, no findings)

- **Tier label injection / Prometheus cardinality blow-up:** `tier="search"` is a string literal in `main.go:226`, not user-controlled. Two labels × one tier × two decisions = 2 cardinality entries. No risk.
- **Type-assertion panic:** `r.Context().Value(ContextKeyUserID).(string)` uses comma-ok form (line 237). A nil/wrong-typed value yields `""` and falls through to the IP path. No `panic` on malformed context.
- **`Reserve()` + `Cancel()` correctness:** Pattern is copy-faithful to `NewIPRateLimiter`. When `delay > 0` the reservation is cancelled, returning the token to the bucket so denied requests do not consume budget. Established invariant.
- **User-ID length / cardinality DoS:** Keys are bounded by what `FormatUserIDFromClaims` produces (`@<localpart>:<server>`). Localpart and server are sourced from a verified JWT; the OIDC IdP is the trust anchor. LRU caps total entries at 10 000 regardless of key cardinality. No unbounded growth.
- **Context cancellation race:** If the client disconnects after `Reserve().OK() == true` and `delay == 0` (token immediately available), the token has already been consumed. This is a fairness footnote - not a security issue - and matches the existing IP limiter behavior.

---

## Summary

| Severity | Count | Disposition |
|----------|-------|-------------|
| CRITICAL | 0 | - |
| HIGH | 0 | - |
| MEDIUM | 0 | - |
| LOW | 0 | - |

**Verdict:** APPROVED. No security issues found in the staged diff. The implementation follows the established `NewIPRateLimiter` pattern with two correct deviations (key on `ContextKeyUserID` instead of IP; emit `retry_after_ms` in body per Matrix CS API §11.14). The handler-chain ordering is correct - `jwtWithStatusCheck` populates the context value before `searchRL` reads it, and unauthenticated requests are rejected before reaching the rate limiter.

The story demonstrates good security-conscious design choices: env-var gating evaluated at construction time, mutex-guarded LRU updates, defense-in-depth IP fallback that is unreachable in production but prevents a future wiring mistake from panicking, and a Retry-After value that derives from bucket arithmetic alone (no timing oracle).

---

## Memory Notes

No new recurring patterns to record. Story 11-5 reuses the hardened Story 5.21 rate-limit pattern correctly - this is exactly what re-use of vetted security primitives is supposed to look like.
