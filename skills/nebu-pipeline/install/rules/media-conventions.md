---
paths: server/lib/nebu/media/**
---

# Nebu.Media Namespace

Public API Entry-Point: `Nebu.Media` — andere Domains rufen nur dieses Modul auf.

## Verantwortlichkeiten

- Upload/Download von Media-Files via Matrix Content Repository API
- Crypto: verschlüsselter Storage (AES-GCM via ExAws/S3-kompatibel)
- HTTP-Client: Finch für externe Requests

## Storage-Konventionen

- Dateien werden via `NEBU_PII_ENCRYPTION_KEY` server-seitig verschlüsselt
- Storage-Backend: S3-kompatibel (MinIO für lokale Dev, AWS S3 für Production)
- Media-IDs: `mxc://server/media-id` Format (Matrix Content Repository)

## Keine Federation

- `/_matrix/media/` ist ausschließlich für lokale Clients
- Keine Cross-Server Media-Requests (kein Federation by Design)
