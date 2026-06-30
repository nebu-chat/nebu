---
name: sql-placement
description: Wo SQL in Nebu hingehört — inline im HTTP-Handler, Migrations unter
  server/priv/migrations/. Für dev-story relevant.
---

# SQL-Placement-Konventionen (ADR-018)

## Wo SQL hingehört

| Kontext | Ort |
|---|---|
| Runtime-Queries (SELECT, INSERT, UPDATE) | Inline im HTTP-Handler / GenServer |
| Schema-Definitionen | `server/priv/migrations/*.sql` |
| Einmalige Aufräumarbeiten | `server/priv/migrations/*.sql` |

## Migration-Format

Raw SQL, kein Ecto.Migration DSL:

```sql
-- server/priv/migrations/20260101_000001_add_room_members.sql
CREATE TABLE room_members (
  id          BIGSERIAL PRIMARY KEY,
  room_id     TEXT      NOT NULL REFERENCES rooms(id),
  user_id     TEXT      NOT NULL,
  joined_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE UNIQUE INDEX room_members_room_user ON room_members(room_id, user_id);
```

Migrations laufen via `Nebu.Release.migrate/0`. Nicht über Ecto.Migrator.

## Multi-Tenant-Kontext (Compliance)

PII-Felder werden via `NEBU_PII_ENCRYPTION_KEY` verschlüsselt gespeichert.
Encryption/Decryption im Handler, nicht in einem separaten Service.

## Anti-Patterns

- ❌ SQL in einem separaten Modul (`RoomQueries.join/2`)
- ❌ Ecto.Migration DSL statt raw SQL
- ❌ Dynamic SQL via String-Concatenation (SQL-Injection-Risiko — CRITICAL)
