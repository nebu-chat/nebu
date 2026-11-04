defmodule Nebu.Workers.ToDevicePurgeWorker do
  @moduledoc """
  Oban-cron job (story to-device-messaging, epic e2ee-client-support) that deletes to-device messages older than the TTL (7 days, seam
  `:nebu, :to_device_ttl_seconds`) and idempotency records older than 24 hours through the facade `Nebu.Matrix.purge_expired_to_device/0` (ADR-020).

  Housekeeping only: delivery never returns an expired message. Cluster safe like `OAuthFlowPurgeWorker`: Cron enqueues from the Oban leader only and the
  purge is batched atomic SQL (`FOR UPDATE SKIP LOCKED`) that concurrent runs split between them; no node-local state. Logs counts only.
  """
  use Oban.Worker, queue: :oauth_cleanup, max_attempts: 3

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case Nebu.Matrix.purge_expired_to_device() do
      {:ok, %{messages: 0, txns: 0}} ->
        :ok

      {:ok, %{messages: messages, txns: txns}} ->
        Logger.info("to-device: purged #{messages} expired message(s) and #{txns} expired transaction record(s)")
        :ok

      {:error, reason} ->
        Logger.error("to-device: purge failed: #{kind(reason)}")
        {:error, kind(reason)}
    end
  end

  defp kind(%{__struct__: module}), do: inspect(module)
  defp kind(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp kind(_), do: "error"
end
