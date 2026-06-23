# ADR-021: Elixir Consolidation — Go Removal

## Status

Accepted - 2026-06-17

Builds on: ADR-001 (Elixir/OTP). Enables: ADR-019, ADR-020.

## Context

Nebu was originally a three-runtime design (ADR-001 era): a stateless **Go gateway**
(Matrix Client-Server API + TLS + rate limiting + auth middleware), a **Go media
gateway** (upload/download/crypto/storage), and an **Elixir/OTP core** (rooms,
sessions, presence, dispatch). The gateway talked to the core over **gRPC**.

This split carried ongoing cost:

- **Two toolchains, two languages, two deployment artefacts** — every cross-cutting
  change (a new endpoint, an auth tweak) touched both a Go handler and an Elixir
  function, plus the gRPC contract between them.
- **A gRPC hop on the hot path** — every Matrix request crossed a process/network
  boundary (Go → Elixir) even though the core already had to do all the stateful work.
- **Duplicated concerns** — request parsing, auth, and error mapping existed on the Go
  side and again (partially) on the Elixir side.

The `full-elixir-stack` epic migrated all Go-implemented behaviour into Elixir: the
Matrix HTTP API (Bandit + Plug), the media gateway (ExAws/Finch), the OIDC middleware
(Assent/JOSE), and the Admin UI (Phoenix LiveView). DB migrations, formerly run by the
Go gateway via `golang-migrate`, moved to `Nebu.Release.migrate/0` (raw SQL, ADR-018).

## Decision

**Go is removed from the stack.** Nebu is implemented entirely in Elixir/OTP. There is
no Go gateway, no Go media gateway, and no inter-process gRPC boundary between a gateway
and the core. All Matrix, media, and admin traffic is served by one Elixir application
(see ADR-019 for its single-OTP-application structure).

## Consequences

### Positive

- One language, one toolchain (Mix), one deployment artefact.
- No gateway↔core network hop — the HTTP layer calls the domain functions in-process.
- BEAM-native horizontal scaling (libcluster + Horde + `pg`) becomes possible because
  the whole stack runs on the BEAM (ADR-020).

### gRPC status (consciously accepted, for now)

The gRPC server module (`Nebu.Matrix.EventDispatcher.Server`) and the generated
`Core.*` protobuf structs survive the migration as the **in-process command / DTO
layer**: the Matrix HTTP router builds a `Core.*` request struct and calls the Server
function directly (no wire hop).

The gRPC **network transport** has been **removed** (story `grpc-legacy-removal`): the
port-9000 listener (`GRPC.Server.Supervisor`), the `EventDispatcher.Endpoint`, the
`Grpc.AuthInterceptor`, and `NodeRegistration` (which registered with the deleted Go
gateway, reading `NEBU_GATEWAY_INTERNAL_URL`) are gone — the server opens no gRPC port.
Removing the only external gRPC entry point is also a security improvement (in-process
auth is `OidcPlug` to HTTP router to a built identity stream).

What remains is the **in-process** command/DTO layer: `Server` still `use GRPC.Server`
for its handler definitions, raises `GRPC.RPCError` (mapped to HTTP status by
`Nebu.Matrix.Http`), reads identity via `Nebu.Matrix.Grpc.Metadata`, and uses `Core.*`
structs as DTOs — so the `:grpc` dependency stays. Replacing those gRPC types with plain
structs/errors is a **separate, larger refactor** (not "cleanup"), left for a future
story so the ~260 Server-level tests stay stable. See ADR-005 (amended).

### Negative

- The internal command layer still speaks in `Core.*` protobuf structs, a small
  conceptual leftover of the former boundary until the gRPC-removal story lands.

## Update 2026-06-22 — gRPC Fully Removed (`grpc-removal` epic)

The cleanup deferred in the original decision has been completed. The `:grpc` and
`:protobuf` Hex dependencies are removed from `mix.exs`. All remnants of the gRPC layer
have been deleted or replaced:

- `core_grpc.pb.ex` (generated gRPC service stub) — deleted.
- `use GRPC.Server` in `Nebu.Matrix.EventDispatcher.Server` — removed; it is now a plain
  Elixir module with ordinary function definitions.
- `Core.*` protobuf structs — converted to plain `defstruct` DTOs (hand-maintained; no
  `protoc` run needed).
- `GRPC.RPCError` / `GRPC.Status` — replaced by `Nebu.Matrix.Error` / `Nebu.Matrix.Status`
  (native drop-in with the same status-atom vocabulary).
- `Nebu.Matrix.Grpc.Metadata` — renamed to `Nebu.Matrix.RequestMetadata` (plain map/struct).
- The server-streaming `event_bus/2` handler — deleted (had no consumer after Go removal).
- The `make proto` Makefile target — removed.
- The vestigial port-9000 listener — confirmed gone.

`Nebu.Matrix.Http.call_core/1` maps a raised `Nebu.Matrix.Error` (status atom from
`Nebu.Matrix.Status`) to the Matrix HTTP error envelope. ADR-005 is fully superseded.

## Related ADRs

- ADR-001 — Elixir/OTP.
- ADR-005 — gRPC Server-Streaming EventBus (superseded by this ADR; gRPC fully removed 2026-06-22).
- ADR-019 — Single OTP Application (the structure of the consolidated app).
- ADR-020 — Clustering Strategy & Module Architecture.
- ADR-018 — No Domain Model (migrations as the canonical data model; `Nebu.Release`).
