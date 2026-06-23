defmodule Nebu.StatefulSupervisor do
  @moduledoc """
  Child supervisor for the crash-prone stateful Matrix processes, started by
  `Nebu.Application` (ADR-019/ADR-020 — per-domain child supervisor).

  Groups the long-lived GenServers and the Horde room registry/supervisor so that
  individual process crashes are isolated here instead of bubbling to the root
  `Nebu.Supervisor`. Uses a very high restart intensity on purpose: in a
  room-per-process / session-per-user model, individual processes crashing and being
  restarted is normal operation and must NOT trip a restart-intensity cascade that
  would take down the whole node.

  In the former umbrella each domain ran in its own OTP application (and its tests in
  a separate BEAM), so these restart budgets were naturally isolated. Consolidated
  into one application they must be isolated explicitly.

  The ETS tables (`:NebuSessions`, `:NebuPresence`, `:NebuTxnDedup`) are created in
  `Nebu.Application.start/2` and owned by the application master, so they survive
  restarts of this supervisor and of the GenServers it supervises.
  """
  use Supervisor

  def start_link(_opts), do: Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    children = [
      Nebu.Matrix.Presence.Manager,
      Nebu.Matrix.Session.EtsStore,
      {Horde.Registry, [name: Nebu.Matrix.Room.Registry, keys: :unique, members: :auto]},
      {Horde.DynamicSupervisor,
       [
         name: Nebu.Matrix.Room.HordeSupervisor,
         strategy: :one_for_one,
         members: :auto,
         # Room processes crash and restart as a matter of course — never let that
         # storm kill the room host. (Horde default is max_restarts: 3 / 5s.)
         max_restarts: 1_000_000,
         max_seconds: 1
       ]}
    ]

    # High intensity: tolerate frequent individual restarts without cascading.
    Supervisor.init(children, strategy: :one_for_one, max_restarts: 1_000_000, max_seconds: 1)
  end
end
