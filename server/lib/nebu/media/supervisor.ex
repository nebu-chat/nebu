defmodule Nebu.Media.Supervisor do
  @moduledoc """
  Child supervisor for the media domain, started by `Nebu.Application`.

  Modeled directly on `Nebu.Compliance.Supervisor` — a plain child `Supervisor`
  (NOT an OTP application, per ADR-019). Currently supervises only
  `Nebu.Media.ClamAV` (story `media-security-admin-control/3-clamav-genserver`).
  """
  use Supervisor

  def start_link(_opts), do: Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    Supervisor.init([Nebu.Media.ClamAV], strategy: :one_for_one)
  end
end
