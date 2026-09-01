defmodule Nebu.Admin.ClamAVStatusIndicator do
  @moduledoc """
  Shared helper for the ClamAV connection status + freshclam signature-age
  section on `/admin/media/health`
  (media-security-admin-control/10b-clamav-status-freshclam-age).

  Mirrors `Nebu.Admin.WarRoomIndicator`'s poll-based shape exactly:
  `status/0` does a fresh read (routed entirely through
  `Nebu.Media.ClamAV`'s existing single managed connection — no new,
  independent TCP probe), `schedule/0` reschedules an unconditional
  `Process.send_after/3` tick, `assign_status/2` updates assigns. A periodic
  poll (rather than a PubSub broadcast wired into `Nebu.Media.ClamAV`) is the
  right fit here because ClamAV connectivity and signature age are *sampled*
  properties of an external daemon, not domain events Nebu itself decides to
  emit (AC6).

      Nebu.Admin.ClamAVStatusIndicator.status()
        # -> %{healthy: bool, changed_at: DateTime.t(),
        #      signature_age: {:ok, DateTime.t()} | {:error, term()}}
      Nebu.Admin.ClamAVStatusIndicator.schedule()
      Nebu.Admin.ClamAVStatusIndicator.assign_status(socket, status)
        # -> assigns :clamav_healthy, :clamav_down_since,
        #    :clamav_signature_age, :clamav_signature_stale?

  ## Not-running guard (AT2's second test)

  `status/0` guards on `Process.whereis(Nebu.Media.ClamAV)`, mirroring
  `WarRoomIndicator.status/0`'s own `Process.whereis(Nebu.Repo)` guard, so
  plain unit-test runs without the ClamAV client started (e.g.
  `config :nebu_http, start_clamav_client: false`, per Story 3) degrade to a
  clear "unknown"/unhealthy state rather than raising.
  """

  import Phoenix.Component, only: [assign: 3]

  @refresh_interval_ms 2_000
  @refresh_message :refresh_clamav_status

  @doc "The message name `handle_info/2` should match on for the scheduled refresh tick."
  @spec refresh_message() :: atom()
  def refresh_message, do: @refresh_message

  @doc """
  A live read of ClamAV connectivity + signature age, sourced entirely from
  `Nebu.Media.ClamAV.health_check/0` and `signature_info/0` (10b AC1/AC2/AC3
  — not a new, independent TCP probe). Degrades to a safe unhealthy/unknown
  default when the ClamAV client process isn't running at all.

  ## Call order matters: `signature_info/0` before `health_check/0`

  The real `clamd` peer closes its TCP connection after every `zVERSION\\0`
  reply (`Nebu.Media.ClamAV.signature_info/0`'s underlying query), but
  `Nebu.Media.ClamAV`'s `ensure_connected/1` only probes/reconnects when its
  managed socket is `nil` — a socket that's dead only because the PEER just
  closed it (not yet discovered by this process) is otherwise reused blindly
  by the next call. Calling `health_check/0` first would risk returning a
  stale `healthy: true` for one poll tick right as clamd goes down, because
  the socket still *looks* alive until something actually sends/receives on
  it. `signature_info/0` is the call that exercises the socket (send +
  recv) on every tick, so calling it FIRST means it's the one that
  discovers a dead/peer-closed socket, clears it, and flips `healthy` to
  `false` in the GenServer's own state — so the `health_check/0` call that
  follows sees `socket: nil` and performs a real reconnect probe instead of
  reusing a stale non-nil socket, giving an accurate `healthy` value in the
  same poll tick rather than one tick late. Do NOT swap this order back
  without re-reading this note (code-review cycle 1, MINOR-1/MINOR-2).
  """
  @spec status() :: %{
          healthy: boolean(),
          changed_at: DateTime.t(),
          signature_age: {:ok, DateTime.t()} | {:error, term()}
        }
  def status do
    if Process.whereis(Nebu.Media.ClamAV) do
      # Order matters — see "Call order matters" in this function's doc.
      signature_age = Nebu.Media.ClamAV.signature_info()
      %{healthy: healthy, changed_at: changed_at} = Nebu.Media.ClamAV.health_check()

      %{healthy: healthy, changed_at: changed_at, signature_age: signature_age}
    else
      %{
        healthy: false,
        changed_at: DateTime.utc_now(),
        signature_age: {:error, :clamav_client_not_running}
      }
    end
  end

  @doc "Schedules the next refresh tick (`schedule/0`'s own `refresh_message/0`, 2s)."
  @spec schedule() :: reference()
  def schedule, do: Process.send_after(self(), @refresh_message, @refresh_interval_ms)

  @doc """
  Assigns `:clamav_healthy`/`:clamav_down_since`/`:clamav_signature_age`/
  `:clamav_signature_stale?` from `status/0`'s return shape.

  `:clamav_signature_age` is either `{:ok, DateTime.t()}` (a successfully
  parsed build date) or the atom `:unknown` (connection error, timeout, or
  unparseable `VERSION` reply — AT6: never a raised exception, never
  misclassified as stale). `:clamav_signature_stale?` uses second-level
  precision against the configured `signature_max_age_hours` threshold
  (strictly greater-than — AT5's boundary pin; do NOT switch to an
  hour-truncated `DateTime.diff/3`, which cannot distinguish "48h-1s" from
  "48h+1s").
  """
  @spec assign_status(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def assign_status(socket, %{healthy: healthy, changed_at: changed_at, signature_age: signature_age}) do
    {clamav_signature_age, stale?} = classify_signature_age(signature_age)

    socket
    |> assign(:clamav_healthy, healthy)
    |> assign(:clamav_down_since, changed_at)
    |> assign(:clamav_signature_age, clamav_signature_age)
    |> assign(:clamav_signature_stale?, stale?)
  end

  defp classify_signature_age({:ok, built_at}) do
    {{:ok, built_at}, stale?(built_at)}
  end

  defp classify_signature_age({:error, _reason}) do
    {:unknown, false}
  end

  defp stale?(built_at) do
    DateTime.diff(DateTime.utc_now(), built_at, :second) > signature_max_age_hours() * 3600
  end

  defp signature_max_age_hours do
    :nebu
    |> Application.get_env(Nebu.Media.ClamAV, [])
    |> Keyword.get(:signature_max_age_hours, 48)
  end
end
