---
name: elixir-otp
description: Elixir/OTP patterns for the Nebu codebase (Pure Elixir, ADR-019/021).
  Loaded by nebu-dev-story so even smaller models write idiomatic Elixir.
  Complements cluster-safety, no-domain-model, sql-placement.
---

# Elixir / OTP Patterns (Nebu)

Nebu ist **Pure Elixir/OTP** (ADR-019: single OTP app `:nebu`, ADR-021: kein Go/gRPC).
This skill gives the minimum idiomatic patterns so any model writes correct Elixir.

## SQL — the one true pattern

SQL goes **inline in the caller**, via `Ecto.Adapters.SQL.query(Nebu.Repo, sql, params)`.
`Nebu.Repo` is an `Ecto.Repo` (Postgres adapter). Never `use Ecto.Schema` (ADR-018).
Never build SQL by string concatenation — always `$1`, `$2` placeholders.

```elixir
def get_user(user_id) do
  case Ecto.Adapters.SQL.query(Nebu.Repo, "SELECT user_id, is_active FROM users WHERE user_id = $1", [user_id]) do
    {:ok, %{rows: [[uid, active]]}} -> {:ok, %{user_id: uid, is_active: active}}
    {:ok, %{rows: []}} -> {:error, :not_found}
    {:error, err} -> {:error, err}
  end
end
```

- Result rows: `{:ok, %{rows: [[col1, col2]], columns: [...]}}` — destructure by position, not name.
- Migrations: raw SQL files in `server/priv/migrations/NNNNNN_name.up.sql` / `.down.sql`.
  Applied by `Nebu.Release.migrate/0`, **not** Ecto.Migrator. Never edit a shipped migration — add a new forward one.

## GenServer — the standard state holder

```elixir
defmodule Nebu.Matrix.Room.Server do
  use GenServer

  # ── Client API ──
  def join(room_id, user_id) do
    GenServer.call(via(room_id), {:join, user_id})
  end

  defp via(room_id), do: {:via, Horde.Registry, {Nebu.Matrix.Room.Registry, room_id}}

  # ── Callbacks ──
  @impl true
  def init(room_id) do
    {:ok, %{room_id: room_id, members: MapSet.new()}}
  end

  @impl true
  def handle_call({:join, user_id}, _from, state) do
    {:reply, :ok, Map.update!(state, :members, &MapSet.put(&1, user_id))}
  end
end
```

- Always implement `@impl true` on callbacks.
- State is a plain map. No structs for GenServer state unless the domain demands it.
- Registration is **always** via `Horde.Registry` (`{:via, Horde.Registry, {Registry, key}}`) — never `Process.register/2` or `GenServer.start_link(name: ...)` (cluster-safety).
- Room processes are started via `Horde.DynamicSupervisor`.

## PubSub — `:pg` only

```elixir
:pg.join(Nebu.Cluster.PubSub, "room:#{room_id}", self())
:pg.get_local_members("room:#{room_id}")   # local members only
:pg.get_members(Nebu.Cluster.PubSub, "room:#{room_id}")  # cluster-wide
```

Never `Phoenix.PubSub` for cluster-critical topics (single-node only).

## Supervision

```elixir
# In Nebu.Application — children list
children = [
  Nebu.Repo,
  {Horde.Registry, keys: :unique, name: Nebu.Matrix.Room.Registry},
  {Horde.DynamicSupervisor, strategy: :one_for_one, name: Nebu.Matrix.Room.Supervisor},
  {Phoenix.PubSub, name: Nebu.PubSub},
  NebuWeb.Endpoint
]
```

## HTTP — Plug pipeline (no Phoenix Router for Matrix API)

Matrix Client-Server API uses raw Plug, not Phoenix routes:

```elixir
defmodule Nebu.Matrix.HttpSync do
  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    # conn.assigns.user_id set by auth plug upstream
    # SQL inline here (ADR-018)
    Plug.Conn.send_resp(conn, 200, Jason.encode!(%{"next_batch" => token}))
  end
end
```

- Errors in the Matrix command layer: `raise Nebu.Matrix.Error, status: Nebu.Matrix.Status.not_found(), message: "Room not found"` — rescued by `Nebu.Matrix.Http.call_core/1` and mapped to `{http_status, errcode, message}`. Matrix errcodes: `M_FORBIDDEN`, `M_NOT_FOUND`, `M_UNKNOWN`, `M_UNRECOGNIZED`.
- No `Phoenix.Controller` — plain `Plug.Conn`.

## Error handling

- Return `{:ok, result}` / `{:error, reason}` tuples in public APIs. Never raise for expected domain errors.
- Inside the Matrix command layer (`Nebu.Matrix.EventDispatcher.Server` handlers), `raise Nebu.Matrix.Error` with a `Nebu.Matrix.Status` atom — the HTTP layer maps it.
- `Ecto.Adapters.SQL.query/3` raises when `Nebu.Repo` is not started — guard with `Process.whereis(Nebu.Repo) != nil` in code paths that may run without a DB (unit tests).
- Fail-open for secondary writes: apply the primary state change, log a warning if a secondary write fails.

## Testing

- Unit tests: `server/test/` — ExUnit, no `@tag :integration`.
- Integration tests: `@tag :integration` — run via `make test-integration` (full stack).
- Test command: `make test-unit-elixir` (runs in container: `mix test --warnings-as-errors`).
- DI seam: inject fake DB modules via `Application.put_env(:app, :db_module, FakeDB)` — see `Nebu.Matrix.Room.Server` `db_module/0`.
- Crash/restart test is **mandatory** for any story that touches GenServer state.

## Common anti-patterns (MAJOR findings)

| ❌ Don't | ✅ Do |
|---|---|
| `use Ecto.Schema` | Raw SQL via `Ecto.Adapters.SQL.query(Nebu.Repo, ...)` |
| `Process.register(self(), name)` | `Horde.Registry` via `{:via, Horde.Registry, {Reg, key}}` |
| `GenServer.start_link(name: Mod)` | `Horde.DynamicSupervisor.start_child` |
| `Phoenix.PubSub.broadcast` for cluster topics | `:pg.join` / `:pg.get_members` |
| String-concatenated SQL | `$1`, `$2` placeholders |
| `Ecto.Migration` DSL | Raw `.sql` files in `server/priv/migrations/` |
| `:global.register_name` | `Horde.Registry` |
| Repository/Service modules | SQL inline in the handler |
