---
paths: server/lib/nebu/matrix/**
---

# Nebu.Matrix Namespace

Public API Entry-Point: `Nebu.Matrix` — andere Domains dürfen nur dieses Modul aufrufen, nicht `Nebu.Matrix.*`-Submodule direkt.

## HTTP-Handler-Konventionen

- Handler-Module: `Nebu.Matrix.Http*` Namensschema
- SQL inline im Handler — kein Repository-Pattern (ADR-018)
- Fehlerbehandlung via `Nebu.Matrix.Error` + `Nebu.Matrix.Status`
- Matrix-Fehlercodes: `M_FORBIDDEN`, `M_NOT_FOUND`, `M_UNKNOWN`, `M_UNRECOGNIZED`

## Event-Dispatch

- `Nebu.Matrix.EventDispatcher.Server` ist das zentrale Command-Layer
- `Core.*`-Structs (`server/lib/pb/`) sind plain Elixir-Structs (keine protobuf-Generierung)
- kein `:grpc`, kein `use GRPC.Server` — gRPC ist vollständig entfernt (ADR-021)

## Room-Management

- Room-Prozesse via `Horde.DynamicSupervisor` + `Horde.Registry`
- Room-State: GenServer (`handle_*` Callbacks only)
- Crash/Restart-Test verpflichtend für alle Stories die Room-State berühren

## E2EE — ausdrücklich verboten (ADR-011)

- `m.room.encryption` Events werden rejected/skipped in jedem State-Write-Pfad
- Kein Endpoint für `/_matrix/client/v3/keys/claim` (Olm-Schlüssel)
- Device-Key-Directory (keys/upload, keys/query) existiert — ist aber NICHT E2EE
