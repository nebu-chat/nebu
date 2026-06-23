---
stepsCompleted: ['step-01', 'step-02', 'step-03', 'step-04', 'step-05']
lastStep: 'step-05-validate-and-complete'
lastSaved: '2026-06-17'
story_key: elixir-http-foundation
story_id: elixir-http-foundation
---

## Stack Detection
- detected_stack: backend
- Indicators: mix.exs (Elixir umbrella), *_test.exs files, no package.json

## Generation Mode
- Mode: AI Generation (backend project, no browser recording needed)

## Test Strategy

| AC | Test Level | File | Priority | Red-phase mechanism |
|----|-----------|------|----------|---------------------|
| AC1 (health endpoint 200) | Integration (ExUnit) | `test/nebu_http/http_foundation_test.exs` | P0 | `NebuHttp.Application` missing → compile error |
| AC2 (X-Request-Id header) | Integration (ExUnit) | `test/nebu_http/http_foundation_test.exs` | P0 | same |
| AC3 (structured log fields) | Integration + CaptureLog | `test/nebu_http/http_foundation_test.exs` | P1 | same |
| AC4 (CORS preflight headers) | Unit (Plug.Test) | `test/nebu_http/cors_plug_test.exs` | P0 | `NebuHttp.Router.init([])` at module attr → compile error |
| AC5 (Bandit, no Cowboy) | Config assertion | `test/nebu_http/http_foundation_test.exs` | P1 | `NebuHttp.Application` missing + deps check |

## Generated Test Files (Red Phase)

### core/apps/nebu_http/test/nebu_http/http_foundation_test.exs
- `NebuHttp.HttpFoundationTest` — 4 integration tests (tagged `:integration`)
  - AC1: `GET /health returns 200 OK with status ok body`
  - AC2: `response includes X-Request-Id header with UUID-v4 format`
  - AC3: `structured log is emitted with method, path, status, duration_ms, and request_id`
  - AC5 (runtime): `server is reachable on port 4000 (Bandit, not Cowboy)`
- `NebuHttp.DepsTest` — 2 unit tests (config assertions)
  - AC5a: `cowboy is not listed as a mix dependency`
  - AC5b: `bandit is listed as a mix dependency`

### core/apps/nebu_http/test/nebu_http/cors_plug_test.exs
- `NebuHttp.CorsPlugTest` — 3 unit tests (Plug.Test)
  - AC4a: `OPTIONS preflight with Origin returns CORS headers`
  - AC4b: `GET request includes Access-Control-Allow-Origin header`
  - AC4c: `request without Origin header does not add CORS headers`

## Red-Phase Verification
- `cors_plug_test.exs`: `@opts NebuHttp.Router.init([])` is a module attribute evaluated at
  compile time → fails immediately with `UndefinedFunctionError` before a single test runs.
- `http_foundation_test.exs`: `Application.ensure_all_started(:nebu_http)` in `setup_all` →
  fails because `NebuHttp.Application` does not exist yet.
- Both files will compile-fail until `NebuHttp.Router` and `NebuHttp.Application` exist.

## Coverage Summary
- P0 criteria covered: AC1, AC2, AC4 ✓
- P1 criteria covered: AC3, AC5 ✓
- Total: 5/5 acceptance criteria → 9 failing tests
