# Code Review — oidc-session-refresh (cycle 1, 2026-05-27)

## Cycle-0 Issues: ALL FIXED
MAJOR-A (logout revocation), MAJOR-B (withAuth param), MINOR-1 (MarkTokenUsed perf),
MINOR-3 (slog.Warn), MINOR-4 (encryption error log), MINOR-5 (zero-value expiry) — verified.

## MINOR Findings (new)

### MINOR-1 — WithOpaqueSessionCheck: HasGraceWindow branch has no unit tests
gateway/internal/middleware/auth.go:254 — new branch `if sess.HasGraceWindow { lookup.MarkTokenUsed(...) }`
has no unit test coverage. Also: LookupOpaqueToken sibling-query (matrix_session_store.go:313-328)
not tested for HasGraceWindow output.
Fix: add 2 unit tests — (a) skips MarkTokenUsed when HasGraceWindow=false; (b) calls it when true.

### MINOR-2 — LookupOpaqueToken makes 2 DB roundtrips per request
matrix_session_store.go:316-323 adds a separate SELECT COUNT(*) for the sibling check.
Fix: fold both SELECTs into one query using a correlated EXISTS subquery returning has_grace
as an extra column. Single roundtrip.

### MINOR-3 — Redundant condition in login.go
login.go:340: inner `if len(h.internalSecret) > 0 && oidcRefreshTokenFromSSO != ""` —
second clause is dead (outer guard already ensures oidcRefreshTokenFromSSO != "").
Fix: remove `&& oidcRefreshTokenFromSSO != ""` from inner condition.

## INFO Findings (not blocking)
INFO-1: MINOR-3 cycle-0 warn not gated on req.RefreshToken (over-warns for AC7 clients — acceptable)
INFO-2: HasGraceWindow sibling query drops gErr silently — add slog.Debug on error
INFO-3: Concurrent rotation may miss sibling (microsecond window; combine queries fixes it)
INFO-4: Logout test doesn't assert Warn log emission
INFO-5: ci_gate.py Keycloak→Dex switch unrelated to story (cosmetic)
INFO-6: cycle_count=1 semantics check (cosmetic)

## Spec MUST compliance: ALL SATISFIED
