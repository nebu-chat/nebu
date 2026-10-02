# Test Quality Review — bugfix/oidc-public-endpoint-urls (RED-phase ATDD)

Full AC coverage confirmed (AC1-AC7 + Oracle MUST-fields all have at least one test).
Recommendation: Approve with comments.

## MAJOR-1 — AC1 × AC2 interaction untested
Sparse-upstream-doc tests never combine with a configured public base URL — the real
production scenario (Dex omits fields AND public base URL is set) has a blind spot
between the two describe blocks. Need a test combining sparse override + configured
public base URL, asserting synthesized registration_endpoint/revocation_endpoint use
the PUBLIC origin, not the internal one.

## MAJOR-2 — Origin-rewrite assertions never check port; no non-default-port case
Assertions compare scheme+host only, never `.port`. An implementation leaking the
internal port or hardcoding a wrong port would pass undetected. Need: (a) port
assertion added to existing origin checks, (b) a dedicated case with an explicit
non-default port in the configured public base URL.

## MINOR-1 — no IPv6-literal-host test case (low priority)
## MINOR-2 — no empty-string oidc_public_base_url wizard-input test (low priority)
## INFO-1..6 — deliberate duplication w/ matrix_router_test.exs (justified), no
GenServer/ETS/SQL-path test yet for the new field (expected at this stage — dev
phase must wire `oidc_public_base_url` into OidcConfig's @empty_config/SQL load),
test-seam extension sound & backward-compatible, no hard waits/flaky patterns,
no test-ID convention in this codebase, file length in line with codebase norms.

Disposition: MAJOR-1 and MAJOR-2 added directly (additive test-coverage gaps,
not a design question) before proceeding to dev-story.
