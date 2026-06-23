# ADR-005: gRPC Server-Streaming EventBus + Unary Fallback

## Status

Accepted - 2026-03-18

> **Superseded by ADR-021 (`grpc-removal` epic, 2026-06-22)**
>
> gRPC has been fully removed from the codebase. The server-streaming EventBus had no
> consumer after the Go gateway was deleted and has been dropped entirely. The unary
> command surface (`Nebu.Matrix.EventDispatcher.Server`) is now a plain Elixir module
> called in-process by the Matrix HTTP routers — no `:grpc`/`:protobuf` dependencies,
> no `use GRPC.Server`, no `GRPC.RPCError`/`GRPC.Status`. `Core.*` are hand-maintained
> plain `defstruct` DTOs; errors propagate as `Nebu.Matrix.Error` with
> `Nebu.Matrix.Status` atoms. The port-9000 listener, `make proto`, and
> `Nebu.Matrix.Grpc.Metadata` are all gone.

**Amended 2026-06-17 (ADR-021):** The Go gateway was removed and the whole stack
consolidated onto Elixir/OTP. gRPC was therefore **no longer an inter-process boundary**:
the Matrix HTTP layer called `Nebu.Matrix.EventDispatcher.Server` in-process. The gRPC
**network listener** (port 9000), its `Endpoint`, the `AuthInterceptor`, and node
registration were **removed** (story `grpc-legacy-removal`). The Server module +
`Core.*` structs + `Nebu.Matrix.Grpc.Metadata` + `GRPC.RPCError` were retained
temporarily as the in-process command/DTO layer pending full removal.

The original decision below is preserved for historical context.

## Context

The Go Gateway needs to receive new events from the Elixir Core and deliver them to waiting Matrix
client long-poll connections (`GET /sync`). Options:

1. **HTTP SSE (Server-Sent Events) from Core:** Fragile, not type-safe, harder to integrate with
   the existing gRPC infrastructure.
2. **WebSocket from Core to Gateway:** Complex, bidirectional overhead not needed here.
3. **gRPC Unary polling:** The Gateway polls Core for new events. Simple but adds latency.
4. **gRPC Server-Streaming:** Core pushes events to Gateway over a persistent stream. Low latency,
   type-safe, automatically reconnects via gRPC's built-in retry.

The architecture also needs resilience: if the streaming connection is lost, delivery must not
stop. A fallback Unary polling mode allows GELB-status delivery while the stream reconnects.

## Decision

We use **gRPC Server-Streaming** (`rpc EventBus(EventBusRequest) returns (stream Event)`) as the
primary event delivery mechanism. One stream per Go Gateway instance (not per Matrix client).

**Fallback:** When the stream is lost, the Gateway switches to **Unary polling**
(`rpc GetPendingEvents(...)`) at the GELB status. If both fail, the Gateway enters ROT status
and all writes are held in `message_buffer` (ADR-006).

**Reconnect:** Exponential backoff, max 30s, with jitter to prevent thundering herd.

Proto definition:
```protobuf
service CoreService {
  rpc EventBus(EventBusRequest) returns (stream Event);
  rpc GetPendingEvents(GetPendingRequest) returns (GetPendingResponse); // Fallback
  // ... plus unary operations
}
```

## Consequences

**Positive:**
- Low latency event delivery (stream is always open, no poll interval)
- Type-safe via protobuf
- One stream per gateway instance reduces Core-side connection overhead vs. per-client streams
- gRPC built-in flow control prevents event flooding

**Negative:**
- Stream reconnect logic must be implemented carefully (done via `stream.go` with backoff)
- GRÜN/GELB/ROT state machine adds complexity to the gateway
- Single stream per instance means the gateway must fan out events internally to per-user buffers

_Source: `_bmad-output/planning-artifacts/architecture.md`, §Core Architectural Decisions (G2, G12); `CLAUDE.md`, §ADR Table_
