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

## E2EE — Client-Infrastruktur ja, verschlüsselte Räume nein (ADR-011, Update 2026-11-02)

Entscheidung 2026-10-30 (Epic `e2ee-client-support`): Der Server unterstützt die Client-seitige E2EE-Infrastruktur
(Schlüssel-Backup, To-Device, Geräte-Schlüsselverzeichnis, Geräteverifikation). Er speichert nur opake Blobs bzw.
öffentliche Schlüssel und Geräteliste-Metadaten, entschlüsselt nichts und loggt kein Schlüsselmaterial.

- **Weiterhin verboten:** `m.room.encryption` Events werden rejected/skipped in jedem State-Write-Pfad — Räume bleiben unverschlüsselt
- Erlaubt und implementiert: `keys/upload`, `keys/query`, `keys/claim`, `keys/changes`, `keys/signatures/upload`, `room_keys/*` (Backup), `sendToDevice`
  sowie die E2E-Felder im `/sync` (`to_device`, `device_lists`, `device_one_time_keys_count`, `device_unused_fallback_key_types`)
- Neue Endpoints dieser Familie: Limits, Rate-Limits und GDPR-Erasure sind Pflicht (siehe `11-risks.md`, `gdpr-deletion-runbook.md`);
  Schlüsselmaterial, Tokens und Nachrichteninhalt dürfen nie in Logs landen
- Verschlüsselte Räume (Einschalten von `m.room.encryption`) wären eine neue ADR-Entscheidung, kein Nebeneffekt einer Story
