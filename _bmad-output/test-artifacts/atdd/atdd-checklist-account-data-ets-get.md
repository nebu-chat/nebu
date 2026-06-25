---
stepsCompleted:
  - step-01-preflight-and-context
  - step-02-generation-mode
  - step-03-test-strategy
  - step-04-generate-tests
  - step-05-validate-and-complete
lastStep: step-05-validate-and-complete
lastSaved: '2026-06-25'
storyId: account-data-ets-get
storyKey: account-data-ets-get
storyFile: null
atddChecklistPath: _bmad-output/test-artifacts/atdd/atdd-checklist-account-data-ets-get.md
generatedTestFiles:
  - server/test/nebu/matrix/matrix_client_compat_test.exs
inputDocuments:
  - server/lib/nebu/web/router/protected.ex
  - server/test/nebu/matrix/matrix_client_compat_test.exs
  - _bmad/tea/config.yaml
---

# ATDD Checklist — account-data-ets-get

## Story Summary

As an Element Web 1.12.15 client, I want `GET /_matrix/client/v3/user/{userId}/account_data/{type}`
to return data I previously stored via PUT, so that secret storage key setup and cross-signing
initialisation can complete without hanging on a 404.

## Stack Detection

- **Detected stack:** `backend` (Elixir/OTP, Mix, ExUnit)
- **Generation mode:** AI generation (backend, no browser recording needed)

## Test Strategy

All tests are ExUnit (no Gherkin / Playwright — this story has no browser-visible behaviour).
All new tests target `server/test/nebu/matrix/matrix_client_compat_test.exs`.

### AC → Test Mapping

| AC | Test | Level | Priority | TDD Status |
|----|------|-------|----------|------------|
| AC4 (auth gate) | GET account_data with NO Bearer → 401 M_MISSING_TOKEN | Integration/plug | P0 | GREEN (auth gate works before route exists) |
| AC3 | GET account_data for unseen type → 404 M_NOT_FOUND | Integration | P0 | RED |
| AC2 | PUT then GET round-trip → GET returns exactly stored body | Integration | P0 | RED |
| AC4 (Oracle IDOR) | GET another user's account_data → 403 M_FORBIDDEN | Integration | P0 | RED |
| AC5 | Second PUT overwrites first; GET returns latest body | Integration | P1 | RED |
| AC6 | PUT account_data → 200 {} (regression: existing PUT contract intact) | Integration | P1 | GREEN (existing route) |

### Test Locations

**Auth-gate describe block** (`describe "auth gate on the client-compat endpoints — no DB"`):

- `test "GET /user/{userId}/account_data/{type} with NO Bearer → 401 M_MISSING_TOKEN"`

**New describe block** (`describe "account_data ETS store — no DB"`):

- `test "GET account_data for unseen type → 404 M_NOT_FOUND"` — RED
- `test "PUT then GET round-trip → GET returns exactly the stored body"` — RED
- `test "GET another user's account_data → 403 M_FORBIDDEN"` — RED
- `test "second PUT overwrites first; GET returns latest body"` — RED
- `test "PUT account_data → 200 {} (regression: existing PUT contract intact)"` — GREEN

## TDD Red Phase Verification

Run: `make test-unit-elixir`

**Result (2026-06-25):** 4 tests failing as expected — all in the new `account_data ETS store` describe block.
All failures are due to `get_conn.status == 404` (catch-all) where the test expects 200, 404 M_NOT_FOUND, or 403.
No compile errors. No warnings-as-errors failures.

## Implementation Checklist (for Dev)

When the implementation is complete, all 4 RED tests must turn GREEN:

- [ ] `Nebu.Matrix.AccountDataStore` ETS module created (keyed by `{user_id, type}`)
- [ ] `GET /client/v3/user/:user_id/account_data/:type` route added to `protected.ex`
  - returns 200 with stored JSON body when data exists
  - returns 404 M_NOT_FOUND `"Account data not found"` when no data
  - enforces IDOR guard: path user_id must match `conn.assigns[:current_user]` → 403 M_FORBIDDEN
- [ ] `PUT /client/v3/user/:user_id/account_data/:type` writes to ETS (currently no-op)
- [ ] All 6 new tests pass
- [ ] Full suite still passes (`make test-unit-elixir`)
