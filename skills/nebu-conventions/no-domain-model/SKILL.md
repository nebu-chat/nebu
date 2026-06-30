---
name: no-domain-model
description: Nebu-Konvention ADR-018 — kein ORM, kein Repository-Pattern, kein Service-Layer.
  SQL inline im Handler. Für dev-story und code-review-Steps.
---

# No Domain Model (ADR-018)

## Prinzip: Locality of Behavior

SQL steht inline im Handler — nicht in separaten Repository- oder Service-Modulen.
Duplication ist intentional, kein Finding.

## Pflicht

- `Postgrex.query/4` oder `Nebu.Repo` direkt im Endpoint/Handler aufrufen
- Keine `Ecto.Schema`-Module (ausser für Repo-Verbindungspool-Konfiguration)
- Keine Repository-Module (`UserRepository`, `RoomRepository` o.ä.)
- Keine Service-Layer-Module (`UserService`, `RoomService` o.ä.)

## Erlaubt

```elixir
# Korrekt: SQL inline im Handler
def handle_join(conn, %{"roomId" => room_id}) do
  case Postgrex.query(Nebu.Repo, """
    INSERT INTO room_members (room_id, user_id, joined_at)
    VALUES ($1, $2, NOW())
    ON CONFLICT DO NOTHING
    RETURNING id
  """, [room_id, conn.assigns.user_id]) do
    {:ok, %{rows: [[id]]}} -> {:ok, id}
    {:error, err} -> {:error, err}
  end
end
```

## Violation (Code-Review-Finding: MAJOR)

```elixir
# ❌ Repository-Pattern
defmodule Nebu.Matrix.RoomRepository do
  def join_room(room_id, user_id), do: ...
end

# ❌ Ecto.Schema
defmodule Nebu.Matrix.Room do
  use Ecto.Schema
  schema "rooms" do ...
end
```
