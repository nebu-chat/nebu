defmodule Nebu.Media.ScanEnqueue do
  @moduledoc """
  Production boundary for the async malware-scan enqueue step
  (`media-security-admin-control/2b-put-media-upload`, AC8).

  `media-security-admin-control/4b-media-scan-worker` wires this module's
  body to a real `Oban.insert/1` call against `Nebu.Workers.MediaScanWorker`
  (queue `:media_scan`, args `%{media_id: media_id}` — Oban serializes args
  through JSON, so the worker reads the string key `"media_id"`). The call
  site in `Nebu.Media` (the `:media_scan_enqueue_module` seam) did not need
  to change — only this module's internals, per 4b's own wiring instruction.
  """

  require Logger

  @spec enqueue(String.t()) :: :ok
  def enqueue(media_id) when is_binary(media_id) do
    case %{media_id: media_id} |> Nebu.Workers.MediaScanWorker.new() |> Oban.insert() do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.error("Nebu.Media.ScanEnqueue: failed to enqueue scan job for media_id=#{media_id}: #{inspect(reason)}")
        :ok
    end
  end
end
