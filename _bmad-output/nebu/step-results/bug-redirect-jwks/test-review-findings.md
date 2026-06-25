# Test Review Findings — bug-redirect-jwks

## Summary: 3 MAJOR, 4 MINOR, 3 INFO

## MAJOR Findings

**MAJOR-1 (JWKS):** Tests introduce `:jwks_http_fetcher` Application env seam that does not exist in the current JwksCache implementation. The tests DEFINE this seam as the contract the implementation must fulfill — dev-story must introduce this seam in `http_fetch/0` for tests to pass for the right reason.

**MAJOR-2 (JWKS):** Test "RED — auto-discovery is attempted" uses a counter agent that is never asserted. The actual proof of discovery is the `:jwks_http_fetcher` stub (if discovery happens, keys = [jwk] != []). Comment is misleading but test logic is functionally correct. Fix: remove the dead counter agent or actually assert it.

**MAJOR-3 (Admin redirect):** Tests 1-3 in admin_redirect_uri_test.exs manually set `:admin_oidc_redirect_uri` and verify `Auth.login_start` uses it. They verify a WORKING mechanism, not the bug. Only test 4 tests the actual bug. The fix in runtime.exs cannot be unit-tested directly. Resolution: dev-story must extract the derivation logic into a function (e.g., `Nebu.Admin.Auth.derive_redirect_uri/0` or similar) that can be called from runtime.exs AND be unit-tested. Add a test for the derivation function itself.

## MINOR Findings

- JWKS polling uses 10ms flat interval without jitter (acceptable for async: false tests)
- Counter agent in MAJOR-2 is set up but never used — dead code in test
- Admin redirect tests don't show full redirect URI in error messages
- Admin redirect tests can't reset runtime.exs state between tests (inherent limitation)

## INFO

- Test "neither issuer nor URI → []" correctly documents unchanged behaviour
- TTL tests are orthogonal regression coverage
- Admin tests correctly use session stubs and metadata overrides

## Required actions before dev-story

MAJOR-1: dev-story must add `:jwks_http_fetcher` seam to `JwksCache.http_fetch/0`
MAJOR-2: Remove dead counter agent from RED test (MINOR cleanup — acceptable)
MAJOR-3: dev-story must extract redirect URI derivation into testable unit
