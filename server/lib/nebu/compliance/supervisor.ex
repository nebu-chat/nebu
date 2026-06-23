defmodule Nebu.Compliance.Supervisor do
  @moduledoc """
  Child supervisor for the compliance domain, started by `Nebu.Application`.

  Reads its children from `config :compliance, :workers` so tests can inject an empty
  list (config/test.exs) without the worker occupying the global name slot. Production
  defaults to the hourly `Nebu.Compliance.SessionExpiryWorker` (Story 5.5).

  This is a plain child supervisor — NOT an OTP application (ADR-019). The former
  `Nebu.Compliance.Application` is removed; its supervisor contract lives here.
  """
  use Supervisor

  def start_link(_opts), do: Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    children =
      Application.get_env(:compliance, :workers, [
        {Nebu.Compliance.SessionExpiryWorker, [name: Nebu.Compliance.SessionExpiryWorker]}
      ])

    Supervisor.init(children, strategy: :one_for_one)
  end
end
