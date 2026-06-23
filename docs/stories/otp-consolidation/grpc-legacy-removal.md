---
story_id: grpc-legacy-removal
title: "Legacy gRPC Cleanup — Remove the Dead Network Transport + Node Registration"
epic: otp-consolidation
status: done
security_review: required
created: 2026-06-17
branch: feature/otp-consolidation
---

## Summary

With the Go gateway gone (ADR-021), the gRPC **network transport** is dead: nothing dials
core's port 9000. This story removes the dead network pieces while keeping the in-process
command layer that the HTTP routers still depend on.

## What is dead vs. load-bearing (investigated)

**Dead — remove:**
- `GRPC.Server.Supervisor` child in `Nebu.Application` (the port-9000 listener — nothing connects).
- `Nebu.Matrix.EventDispatcher.Endpoint` (gRPC endpoint definition — only the listener used it).
- `Nebu.Matrix.Grpc.AuthInterceptor` (network-call interceptor — only the Endpoint used it; in-process callers build the identity stream themselves).
- `Nebu.NodeRegistration` + its `Task.start` in `Nebu.Application` (registered with the deleted Go gateway; reads `NEBU_GATEWAY_INTERNAL_URL`).

**Load-bearing — KEEP (do NOT touch):**
- `Nebu.Matrix.EventDispatcher.Server` — `use GRPC.Server, service: Core.CoreService.Service`; its functions are the in-process command layer the HTTP layer calls directly.
- `Core.*` message structs (`core.pb.ex`) and `Core.CoreService.Service` (`core_grpc.pb.ex`) — required by `use GRPC.Server` and used as in-process DTOs.
- `Nebu.Matrix.Grpc.Metadata` — used in-process by `Nebu.Matrix.Http*` / `Nebu.Web.Router.Protected` to read the trusted identity from the stream the HTTP layer builds.
- `GRPC.RPCError` — raised throughout `Server` and mapped to HTTP status by `Nebu.Matrix.Http.map_grpc_error/1`.
- the `:grpc` + `:protobuf` deps — still required by all of the above.

> Fully excising gRPC types from the in-process command layer (replace `use GRPC.Server`,
> `GRPC.RPCError`, and `Core.*` DTOs) is a large re-architecture, explicitly out of scope —
> it is not "legacy cleanup", it is a rewrite. Documented as a possible future story.

## Acceptance Criteria

1. **Given** `Nebu.Application`, **When** inspected, **Then** it no longer starts `GRPC.Server.Supervisor` and no longer `Task.start`s node registration; the boot tree contains no port-9000 listener.
2. **Given** the codebase, **When** searched, **Then** `Nebu.Matrix.EventDispatcher.Endpoint`, `Nebu.Matrix.Grpc.AuthInterceptor`, and `Nebu.NodeRegistration` modules (and their tests) are removed.
3. **Given** `core/config/runtime.exs` and deploy configs, **When** searched, **Then** no `NEBU_GATEWAY_INTERNAL_URL` reference remains (its only consumer is gone).
4. **Given** the kept in-process layer, **When** searched, **Then** `Nebu.Matrix.EventDispatcher.Server`, `Core.*`, `Nebu.Matrix.Grpc.Metadata`, and `GRPC.RPCError` mapping are intact and the `:grpc` dep remains.
5. **Given** `make build-core` + `make test-unit-elixir`, **When** run, **Then** green — same count minus only the removed modules' own tests (auth_interceptor_test, node_registration_test), which are deleted with their modules.
6. **Given** ADR-005/ADR-021, **When** read, **Then** they record that the gRPC network listener has been removed (in-process command layer retained).
7. **Given** `docker-compose*.yml`, **When** inspected, **Then** any now-meaningless port-9000/gRPC health wiring for core is removed (MinIO's own 9000 is unaffected).

## Acceptance Tests

Cleanup story — the existing ExUnit suite is the regression gate:
- `make test-unit-elixir` green after removal (parity minus the 2 deleted modules' tests).
- `MIX_ENV=prod mix release` still assembles and boots (no missing-child / undefined-module at boot).
- grep guard: no remaining reference to `GRPC.Server.Supervisor`, `EventDispatcher.Endpoint`, `AuthInterceptor`, `NodeRegistration`, `NEBU_GATEWAY_INTERNAL_URL` outside historical ADR text.

## Implementation Notes

- Order: do this AFTER `deploy-ci-env-cleanup` per the request, but it finalises the env
  contract (drops `NEBU_GATEWAY_INTERNAL_URL`).
- Removing `AuthInterceptor` removes the ONLY external (network) entry to the command layer
  — this is a security improvement (no unauthenticated network gRPC surface), not a
  regression: in-process auth is `OidcPlug` → HTTP router → built identity stream.
- Verify `Nebu.Health.Server` is independent of the gRPC listener before/after (it is a
  separate health endpoint) — keep it.
