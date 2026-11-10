---
story: unit-tests-junk-token-503-after-lookup-fix
epic: bugfix
status: ready
security_review: none
matrix: false
ui: false
---

# Bugfix — unit tests with a junk bearer token answer 503 since the access-token lookup fix

Follow-up of `matrix-token-lookup-db-error-not-401` (commit f9f58c45). Test-only; the one `server/lib` touch is inside the `Mix.env() == :test` compile-time block
of the existing lookup fault seam (a new "no such row" outcome), production paths are unchanged.

## Problem

Since f9f58c45 `OidcPlug.call_opaque/2` answers a FAILED token lookup (DB error, pool timeout, `:repo_not_started`) with `503 M_UNKNOWN` + `Retry-After: 5`.
The unit suite (`make test-unit-elixir`) runs without a database, so every unit test that presents a junk OPAQUE bearer token and expects `401 M_UNKNOWN_TOKEN`
now gets the 503 (17 tests in 10 files: media create / upload / async upload, device key directory routes, matrix router, room summary, room keys routes,
mutual rooms, client compat, to-device routes). Verified: the same files are green on d8841dd3 (191 passed) and fail on HEAD; the test files did not change in between.
The 503 behaviour is correct and stays; these tests mean "an unknown token is a 401", which needs a deterministic "no such row" answer, not a missing database.

## Acceptance criteria

```gherkin
Scenario: A junk opaque token is unknown (401), also in a unit run without a database
  Given the access-token lookup answers "no such row" (test seam, no database)
  When a request presents a junk opaque bearer token
  Then the answer is 401 M_UNKNOWN_TOKEN without Retry-After and nothing is authenticated

Scenario: A failed lookup is still a retryable 503
  Given the access-token lookup fails (DB error, pool timeout, repo not started)
  When a request presents any opaque bearer token
  Then the answer is still 503 M_UNKNOWN + Retry-After (oidc_plug_lookup_failure_test.exs unchanged)

Scenario: The unit suite is green
  When `make test-unit-elixir` runs
  Then it exits 0 (the 17 junk-token tests pass through one shared helper, no per-test fault plumbing)
```

## Notes

- Seam: `:nebu_http, :matrix_session_lookup_fault` gets the outcome `:no_row` (`{:ok, %{rows: []}}` as the query result) in the existing test-only block of
  `MatrixSessionStore.lookup_fault/1`.
- Helper: `Nebu.Web.SessionLookupTestSupport.setup_no_row_lookup/0` (loaded by `test_helper.exs`) sets the seam and restores the previous value on exit.
  The seam is process-global, so it is used only from `async: false` modules (all ten are).
- Pinned by `session_lookup_no_row_seam_test.exs` (3 unit tests).
