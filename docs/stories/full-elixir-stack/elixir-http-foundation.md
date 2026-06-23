---
story_id: elixir-http-foundation
title: "Elixir HTTP Foundation — Bandit + Plug Pipeline"
epic: full-elixir-stack
status: done
security_review: not-needed
created: 2026-06-17
branch: feature/full-elixir-stack
---

## Summary

Set up Bandit as the HTTP server for the Elixir/OTP core, replacing nothing yet — this story only establishes
the foundation that subsequent stories build on. A Plug pipeline with request-ID injection, structured logging,
CORS headers, and a `/health` endpoint is all that's needed here. No Go gateway replacement yet.

## User Story

As a Nebu operator,
I want the Elixir/OTP core to expose a Plug + Bandit HTTP server with baseline middleware,
So that subsequent stories can add routes incrementally without setting up the HTTP layer from scratch.

## Acceptance Criteria

1. **Given** `make dev` brings up the stack,
   **When** `GET http://core:4000/health` is called,
   **Then** `200 OK` with body `{"status":"ok"}` is returned by Bandit (not by Go).

2. **Given** any HTTP request to Bandit,
   **When** it is processed,
   **Then** the response includes a `X-Request-Id` header with a UUID-v4 value.

3. **Given** any HTTP request to Bandit,
   **When** it is processed,
   **Then** a structured log line is emitted at `info` level containing `method`, `path`, `status`, `duration_ms`, and `request_id`.

4. **Given** a request from a browser (CORS preflight `OPTIONS` with `Origin: http://localhost`),
   **When** it arrives at Bandit,
   **Then** the response includes `Access-Control-Allow-Origin` and `Access-Control-Allow-Methods` headers.

5. **Given** the Elixir umbrella project,
   **When** it compiles,
   **Then** Bandit starts on port `4000` and Cowboy is not a dependency.

## Acceptance Tests

### Tests written FIRST (before implementation code):

1. **`test/http_foundation_test.exs`** — ExUnit integration test (hits real Bandit)
   - Given: Bandit started on port 4000
   - When: `GET /health`
   - Then: `200`, body `%{"status" => "ok"}`, `X-Request-Id` header present

2. **`test/cors_plug_test.exs`** — ExUnit unit test (Plug.Test)
   - Given: OPTIONS preflight with `Origin: http://localhost`
   - When: routed through the Plug pipeline
   - Then: response contains `Access-Control-Allow-Origin` and `Access-Control-Allow-Methods`

## Implementation Notes

- New OTP application `nebu_http` in the umbrella (or extend `event_dispatcher` — decide before implementation)
- Bandit replaces Cowboy; do NOT add Cowboy as a dependency
- Port configurable via `NEBU_HTTP_PORT` env var (default: `4000`)
- Request-ID: use `Plug.RequestId` from the `plug` library
- CORS: use `cors_plug` hex package or implement a minimal custom Plug
- Logging: use `Plug.Logger` or a custom structured-logging Plug that emits JSON
- This story does NOT disable or modify the Go gateway — both can run simultaneously on different ports
