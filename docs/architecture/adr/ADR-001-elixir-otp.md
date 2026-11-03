# ADR-001: Elixir/OTP as Core Runtime

## Status

Accepted - 2026-03-18

> **Amended 2026-11-02.** The decision (Elixir/OTP as runtime) stands and is now the *only*
> runtime: the Go gateway was removed (ADR-021) and the whole stack is one OTP app `:nebu`
> (ADR-019). The `GRPC` library listed below is **no longer a dependency** — gRPC was fully
> removed (`grpc-removal` epic, see ADR-005). Current pins: Elixir 1.19 / OTP 27, see
> [02-constraints](../02-constraints.md).

## Context

Nebu requires a stateful messaging core capable of managing thousands of concurrent room processes,
session state, presence tracking, and event dispatch - all without external middleware like Redis
or NATS. The choice of runtime technology for this core determines the operational complexity,
scalability ceiling, and clustering strategy.

Two options were considered: Erlang/OTP directly, and Elixir/OTP.

Elixir is a functional language built on the Erlang/OTP runtime. Both share the same BEAM VM,
OTP supervision trees, ETS, and process model. Elixir adds the Mix tooling ecosystem, the `libcluster`
and `Horde` libraries for automatic cluster discovery and distributed process supervision, and a
larger library ecosystem.

The architecture requires:
- Thousands of long-lived GenServer processes (one per room, one per session)
- Horizontal clustering without external coordinator
- Native pub/sub without NATS/Kafka
- Native in-memory state without Redis

## Decision

We use **Elixir/OTP** (not bare Erlang/OTP) as the messaging core runtime.

Key libraries: `libcluster` (automatic node discovery), `Horde` (distributed GenServer supervision),
`Ecto` (PostgreSQL access), `GRPC` (gRPC server implementation).

Elixir version: 1.19 on Erlang/OTP 27.

## Consequences

**Positive:**
- OTP Supervisor trees provide self-healing without external orchestration
- ETS replaces Redis for session state and since-token cursors
- pg Process Groups replace NATS/Kafka for pub/sub fanout
- `libcluster` + `Horde` enable cluster operation with a single config change (Phase 2)
- Erlang/OTP 27 includes native Ed25519/X25519 via `:crypto` - no external crypto packages

**Negative:**
- Smaller hiring pool than Go or Java for the Core
- Mix/OTP release build process is more complex than a simple Go binary
- Alpine builder/runtime versions must be kept in sync (OpenSSL ABI dependency)

_Source: `_bmad-output/planning-artifacts/architecture.md`, §Resolved Technology Decisions; `CLAUDE.md`, §ADR Table_
