---
stepsCompleted: ['step-01-preflight-and-context', 'step-02-generation-mode', 'step-03-test-strategy', 'step-04-generate-tests', 'step-04c-aggregate', 'step-05-validate-and-complete']
lastStep: 'step-05-validate-and-complete'
lastSaved: '2026-06-25'
storyId: 'element-startup-phase-stubs'
storyKey: 'element-startup-phase-stubs'
storyFile: ''
atddChecklistPath: '_bmad-output/test-artifacts/atdd/atdd-checklist-element-startup-phase-stubs.md'
generatedTestFiles:
  - 'server/test/nebu/matrix/matrix_client_compat_test.exs (appended — 12 new tests)'
---

# ATDD Checklist: Element Startup-Phase Stub Endpoints

## TDD Red Phase (Current)

Red-phase ExUnit test scaffolds generated and appended to the existing test file.

- API Tests: 12 tests (6 auth-gate + 6 static-contract)
- E2E Tests: N/A — no browser-visible behavior; HTTP protocol only (ExUnit/Plug.Test)

## Acceptance Criteria Coverage

| AC | Description | Test (auth gate) | Test (static contract) | Red? |
|----|-------------|------------------|------------------------|------|
| AC 1 | `GET /thirdparty/protocols` → 200 `{}` | auth gate: no Bearer → 401 | valid Bearer → 200 `{}` | YES |
| AC 2 | `GET /voip/turnServer` → 404 M_NOT_FOUND | auth gate: no Bearer → 401 | valid Bearer → 404 `M_NOT_FOUND` + exact error | YES |
| AC 3 | `GET /room_keys/version` → 404 M_NOT_FOUND | auth gate: no Bearer → 401 | valid Bearer → 404 `M_NOT_FOUND` + exact error | YES |
| AC 4 | `GET /unstable/msc3814.v1/dehydrated_device` → 404 | auth gate: no Bearer → 401 | valid Bearer → 404 `M_NOT_FOUND` + exact error | YES |
| AC 5 | `GET /unstable/msc4143/rtc/transports` → 404 | auth gate: no Bearer → 401 | valid Bearer → 404 `M_NOT_FOUND` + exact error | YES |
| AC 6 | `POST /keys/device_signing/upload` → 200 `{}` | auth gate: no Bearer → 401 | valid Bearer → 200 `{}` | YES |
| AC 7 | All endpoints behind OidcPlug | Covered by all 6 auth-gate tests | — | YES |
| AC 8 | No regressions to existing tests | Existing tests are untouched | — | Assumed |

## Why These Tests Are Currently Failing

The 12 new tests are in the `@tag :red_phase` state. When run against the current codebase:

**Auth gate tests (6):** The auth gate tests for the *new* endpoints currently pass (OidcPlug catches all
unrecognized paths through the `match _` catch-all), so they may incidentally be green today. This is
acceptable — the test assertion is correct and will stay green after implementation.

**Static-contract tests (6):** These will FAIL:
- `GET /thirdparty/protocols` → expects `200 {}` but gets `404 M_NOT_FOUND` (catch-all)
- `GET /voip/turnServer` → expects `404` with `"No TURN server configured"` but gets `404` with `"Unrecognized request"`
- `GET /room_keys/version` → expects `404` with `"No backup found"` but gets `404` with `"Unrecognized request"`
- `GET /unstable/.../dehydrated_device` → expects `404` with `"No dehydrated device found"` but gets `404` with `"Unrecognized request"`
- `GET /unstable/.../rtc/transports` → expects `404` with `"No RTC transports"` but gets `404` with `"Unrecognized request"`
- `POST /keys/device_signing/upload` → expects `200 {}` but gets `404 M_NOT_FOUND`

## Generated Test File

File: `server/test/nebu/matrix/matrix_client_compat_test.exs`

**Appended to describe block:** `"auth gate on the client-compat endpoints — no DB"` — 6 new tests

**Appended to describe block:** `"static contract responses — valid Bearer, no DB"` — 6 new tests

All new tests are tagged `@tag :red_phase` for easy filtering.

## Implementation Guidance

Routes to add to `server/lib/nebu/web/router/protected.ex`:

```elixir
# GET /client/v3/thirdparty/protocols → 200 {}
get "/client/v3/thirdparty/protocols" do
  send_json(conn, 200, %{})
end

# GET /client/v3/voip/turnServer → 404 M_NOT_FOUND
get "/client/v3/voip/turnServer" do
  error(conn, 404, "M_NOT_FOUND", "No TURN server configured")
end

# GET /client/v3/room_keys/version → 404 M_NOT_FOUND
get "/client/v3/room_keys/version" do
  error(conn, 404, "M_NOT_FOUND", "No backup found")
end

# GET /client/unstable/org.matrix.msc3814.v1/dehydrated_device → 404 M_NOT_FOUND
get "/client/unstable/org.matrix.msc3814.v1/dehydrated_device" do
  error(conn, 404, "M_NOT_FOUND", "No dehydrated device found")
end

# GET /client/unstable/org.matrix.msc4143/rtc/transports → 404 M_NOT_FOUND
get "/client/unstable/org.matrix.msc4143/rtc/transports" do
  error(conn, 404, "M_NOT_FOUND", "No RTC transports")
end

# POST /client/v3/keys/device_signing/upload → 200 {} (no-op)
post "/client/v3/keys/device_signing/upload" do
  send_json(conn, 200, %{})
end
```

All routes must be placed **before** the `match _` catch-all at the bottom of the file.

## Next Steps (TDD Green Phase)

1. Implement the 6 routes in `server/lib/nebu/web/router/protected.ex` (above the `match _`)
2. Run `make test-unit-elixir` — verify all 12 new tests pass
3. Verify the existing tests still pass (AC 8 — no regressions)
4. Remove the `@tag :red_phase` annotations or keep them as metadata — your choice
5. Commit

## Performance

- Execution Mode: SEQUENTIAL (backend only — no browser E2E needed)
- Test framework: ExUnit + Plug.Test (Elixir native)
- No Playwright E2E needed: endpoints have no browser-visible UI behavior
