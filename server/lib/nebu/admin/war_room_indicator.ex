defmodule Nebu.Admin.WarRoomIndicator do
  @moduledoc """
  Shared helper for the war-room recording dot/pill assigns
  (`:war_room_active`/`:war_room_started_at`/`:war_room_started_by`)
  threaded through `Nebu.Admin.Layouts.live/1` (enhanced-logging/
  war-room-dedicated-page, amendment 4).

  Every remaining admin LiveView (`Nebu.Admin.DashboardLive`,
  `Nebu.Admin.AuditLogLive`, `Nebu.Admin.LogsLive`,
  `Nebu.Admin.LogsLive.TraceMap`, `Nebu.Admin.LogsLive.WarRoom` — the only
  LiveViews left after admin-http-refactor's controller conversions, i.e.
  the full "anywhere in the admin UI" surface) calls `status/0` at mount and
  on its own 2s `schedule/0` tick, then `assign_status/2` to set these three
  assigns. Polling is UNCONDITIONAL once connected (not gated on "already
  active") — the dot/pill must be able to APPEAR later, while the operator
  is already on an unrelated page, not merely persist while already
  showing (mirrors `Nebu.Admin.LogsLive.TraceMap`'s own pre-existing
  "always rescheduled... because the banner must also APPEAR when a session
  starts later" war-room poll, generalized here to every remaining
  LiveView).
  """
  import Phoenix.Component, only: [assign: 3]

  @refresh_interval_ms 2_000
  @refresh_message :refresh_war_room_status

  @doc "The message name `handle_info/2` should match on for the scheduled refresh tick."
  @spec refresh_message() :: atom()
  def refresh_message, do: @refresh_message

  @doc """
  A live DB read of the current War Room status — `:none` when
  `Nebu.Repo` is not running (plain unit-test runs), mirroring every other
  DB-guarded helper in this codebase.
  """
  @spec status() :: {:ok, map()} | :none
  def status do
    if Process.whereis(Nebu.Repo) do
      Nebu.Admin.WarRoomManager.status()
    else
      :none
    end
  end

  @doc "Schedules the next refresh tick (`schedule/0`'s own `refresh_message/0`, 2s)."
  @spec schedule() :: reference()
  def schedule, do: Process.send_after(self(), @refresh_message, @refresh_interval_ms)

  @doc "Assigns `:war_room_active`/`:war_room_started_at`/`:war_room_started_by` from `status`."
  @spec assign_status(Phoenix.LiveView.Socket.t(), {:ok, map()} | :none) ::
          Phoenix.LiveView.Socket.t()
  def assign_status(socket, {:ok, session}) do
    socket
    |> assign(:war_room_active, true)
    |> assign(:war_room_started_at, session.started_at)
    |> assign(:war_room_started_by, session.started_by)
  end

  def assign_status(socket, :none) do
    socket
    |> assign(:war_room_active, false)
    |> assign(:war_room_started_at, nil)
    |> assign(:war_room_started_by, nil)
  end
end
