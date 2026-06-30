---
name: matrix-spec-rules
description: Matrix Client-Server API Spec-Regeln für Nebu. Für nebu-oracle.
  Welche Endpoints implementiert sind, was E2EE-Status ist, welche MSCs aktiv.
---

# Matrix Client-Server API — Nebu Scope

## Implementierte Endpoints (MVP)

```
POST /_matrix/client/v3/login
POST /_matrix/client/v3/logout
GET  /_matrix/client/v3/sync
PUT  /_matrix/client/v3/rooms/{roomId}/send/{eventType}/{txnId}
GET  /_matrix/client/v3/rooms/{roomId}/messages
POST /_matrix/client/v3/createRoom
POST /_matrix/client/v3/join/{roomIdOrAlias}
PUT  /_matrix/client/v3/rooms/{roomId}/typing/{userId}
POST /_matrix/client/v3/rooms/{roomId}/receipt/{receiptType}/{eventId}
GET/PUT /_matrix/client/v3/profile/{userId}
GET  /_matrix/client/v3/presence/{userId}/status
GET  /_matrix/client/unstable/org.matrix.msc2965/auth_issuer   (+ stable v1/ path)
GET  /_matrix/client/unstable/org.matrix.msc2965/auth_metadata (+ stable v1/ path)
POST /_matrix/client/v3/keys/upload
POST /_matrix/client/v3/keys/query
GET  /_matrix/client/v3/devices
GET  /_matrix/client/v3/devices/{deviceId}
GET  /_matrix/client/v3/account/whoami
POST /_matrix/client/v3/keys/signatures/upload   (stub → {"failures": {}})
```

## Intentional Exclusions

- **Kein Federation** — `/_matrix/federation/*`, `/_matrix/identity/*`, `/_matrix/key/*`
- **Kein E2EE** — `m.room.encryption` wird rejected/skipped (ADR-011)
  - `createRoom` `initial_state` → E2EE-Events werden übersprungen
  - Direct state-PUT → `403 M_FORBIDDEN`
- **Kein ROPC** — OIDC nur via Authorization Code + PKCE (MSC2965/MSC3861)

## Error Code Konventionen

Matrix-Fehlercodes: `M_FORBIDDEN`, `M_NOT_FOUND`, `M_UNKNOWN`, `M_UNRECOGNIZED`, etc.
HTTP-Status entspricht Matrix-Spec (401, 403, 404, 429, 500).
Implementierung via `Nebu.Matrix.Error` + `Nebu.Matrix.Status`.

## MSC-Status

| MSC | Status |
|---|---|
| MSC2965 — OIDC Discovery | Aktiv (auth_issuer, auth_metadata) |
| MSC3861 — OIDC Login | Basis-Implementierung (login via OIDC) |

## Spec-Compliance-Prüfung

Für Oracle: Matrix CS API Spec v1.18 ist lokal gebündelt unter
`skills/nebu-agent-oracle/matrix-spec/v1.18/`. MUST-Anforderungen aus der Spec
gelten als MAJOR-Findings wenn sie fehlen.
