---
name: cluster-safety
description: BEAM-native Clustering-Konventionen für Nebu. Verwende Horde für
  Process-Registrierung, pg für PubSub. Kein Redis, kein :global. Für dev-story
  und code-review-Steps relevant.
---

# Cluster-Safety-Konventionen (ADR-020)

## Pflicht

- Process-Registrierung NUR über `Horde.Registry` — niemals lokale `Registry` oder `Process.register/2`
- Cross-Node PubSub NUR über `:pg` — `Phoenix.PubSub` nur lokal (single-node), nie cluster-kritisch
- Node-Discovery NUR über `libcluster`
- Code muss identisch auf einem Node und in einem Cluster funktionieren

## Verboten

- `Process.register(self(), name)` ohne Horde-Wrapper
- `:global.register_name/2`
- Externe Broker als Ersatz für BEAM-Primitiven (Redis, NATS, RabbitMQ)

## Korrekte Verwendung

```elixir
# Cluster-safe Process-Registrierung
Horde.Registry.register(Nebu.Cluster.Registry, {:room, room_id}, self())

# Cluster-safe PubSub
:pg.join(Nebu.Cluster.PubSub, {:room, room_id}, self())
:pg.get_members(Nebu.Cluster.PubSub, {:room, room_id})
```

## Violation (Code-Review-Finding: MAJOR)

```elixir
Process.register(self(), :room_handler)  # ❌ nicht cluster-safe
GenServer.start_link(__MODULE__, state, name: MyModule)  # ❌ nur single-node
```
