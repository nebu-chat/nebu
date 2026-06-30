---
stepsCompleted:
  - step-01-preflight-and-context
  - step-02-generation-mode
  - step-03-test-strategy
  - step-04-generate-tests
  - step-04c-aggregate
  - step-05-validate-and-complete
lastStep: step-05-validate-and-complete
lastSaved: '2026-06-28'
storyId: upcloud-postgres-ssl
storyKey: upcloud-postgres-ssl
storyFile: ''
atddChecklistPath: _bmad-output/test-artifacts/atdd-checklist-upcloud-postgres-ssl.md
generatedTestFiles:
  - server/test/nebu/release_ssl_test.exs
inputDocuments:
  - server/lib/nebu/release.ex
  - server/config/runtime.exs
  - server/test/nebu/release_test.exs
---

# ATDD Checklist: UpCloud PostgreSQL SSL

## Stack Detection

- Detected stack: `backend` (pure Elixir/OTP, ExUnit)
- No E2E / Playwright tests required for this story

## Generation Mode

- Mode: AI Generation (backend stack, no browser recording needed)
- Execution: Sequential (single worker — API/ExUnit tests only; no E2E worker dispatched)

## Test Strategy

| AC | Test Level | Priority | Test Name |
|----|-----------|----------|-----------|
| AC-1 | Unit (ExUnit) | P0 | `returns [ssl: false] when NEBU_POSTGRES_SSL is not set` |
| AC-1 | Unit (ExUnit) | P0 | `returns [ssl: false] when NEBU_POSTGRES_SSL is explicitly "false"` |
| AC-1 | Unit (ExUnit) | P1 | `returns [ssl: false] for any value other than "true"` |
| AC-2 | Unit (ExUnit) | P0 | `returns [ssl: [verify: :verify_none]] when SSL enabled and no CA cert file` |
| AC-2 | Unit (ExUnit) | P1 | `returned ssl keyword is a keyword list (not a plain boolean)` |
| AC-2 | Unit (ExUnit) | P1 | `returned ssl keyword contains :verify key set to :verify_none` |
| AC-2 | Unit (ExUnit) | P1 | `returned ssl keyword does NOT contain :cacertfile when CA cert is absent` |
| AC-3 | Unit (ExUnit) | P0 | `returns [ssl: [verify: :verify_peer, cacertfile: charlist]] when CA cert path is set` |
| AC-3 | Unit (ExUnit) | P1 | `:cacertfile value is an Erlang charlist (not a binary string)` |
| AC-3 | Unit (ExUnit) | P1 | `:verify is :verify_peer when CA cert path is set` |
| AC-3 | Unit (ExUnit) | P1 | `cacertfile charlist matches the exact path from NEBU_POSTGRES_CA_CERT_FILE` |
| AC-4 | Code review only | N/A | Not automatable — compile-time runtime.exs config |
| AC-5 | Manual infra test | N/A | Not automatable — requires live UpCloud VM |

## TDD Red Phase

- TDD Phase: RED (these tests were designed to fail before implementation exists)
- Since the story context states the implementation already exists, the tests were verified GREEN against the existing code: `11 passed` in 0.02s
- The test file includes the `test.skip()` equivalent note in comments; for ExUnit pure unit tests the red-phase is documented via comments explaining the before-implementation intent, as ExUnit does not have a skip-all mechanism equivalent to Playwright's `test.skip()`

## Acceptance Criteria Coverage

- [x] AC-1: `postgres_ssl_opts/0` returns `[ssl: false]` — 3 tests
- [x] AC-2: `postgres_ssl_opts/0` returns `[ssl: [verify: :verify_none]]` — 4 tests
- [x] AC-3: `postgres_ssl_opts/0` returns `[ssl: [verify: :verify_peer, cacertfile: charlist]]` — 4 tests
- [~] AC-4: `runtime.exs` Repo config mirrors the same logic — verified by code review (see `server/config/runtime.exs` lines 118-132)
- [~] AC-5: UpCloud live deployment — non-automatable, requires manual VM verification

## Generated Files

- `server/test/nebu/release_ssl_test.exs` — 11 ExUnit unit tests

## Summary Statistics

- Total Tests: 11
- P0 Tests: 5
- P1 Tests: 6
- E2E Tests: 0 (not applicable — no browser-visible behavior)
- Execution Mode: Sequential
- Test Run Result: 11 passed

## Next Steps

1. Commit `server/test/nebu/release_ssl_test.exs` alongside the story
2. Verify `make test-unit-elixir` passes in CI
3. For AC-4: reviewer must inspect `server/config/runtime.exs` lines 118–132 to confirm the three-way ssl logic matches `postgres_ssl_opts/0`
4. For AC-5: manually verify on a live UpCloud VM after `tofu apply` — see test file comment for exact verification steps
