defmodule Nebu.Workers.MediaAlertWebhookWorker do
  @moduledoc """
  Delivers the outbound admin-notification webhook enqueued by
  `Nebu.Media.AlertNotifier` (media-security-admin-control/7-admin-notifications,
  AC3, AC6).

  Runs on its own dedicated `:media_alerts` Oban queue — separate from Story
  4b's `:media_scan` queue — so a slow or permanently-down webhook endpoint can
  never delay or starve scan-job processing (AC2/AC6).

  ## Payload shape (AC3): exactly `media_id`, `state`, `timestamp` — nothing else

  The JSON body POSTed is exactly `{"media_id": ..., "state": ...,
  "timestamp": ...}`. No `filename`, `uploader_id`, ClamAV signature text, file
  content, or any other `media_files`/`media_state_transitions` column is ever
  included — see the story's Summary for the compliance rationale. This
  module has no code path that could add such a field: `perform/1` only ever
  reads the three job args it is given and forwards them verbatim.

  ## Never touches media state (AC6)

  This worker never calls `Nebu.Media.StateMachine` and never writes to
  `media_files`/`media_state_transitions` in any branch — its only side effect
  is the outbound HTTP POST. A delivery failure (non-2xx, timeout, connection
  refused) is handled entirely by Oban's own retry/backoff on the
  `:media_alerts` queue (bounded `max_attempts`, then `discard`); it can never
  cause a scan-worker retry and never re-enters the media state machine.

  ## Webhook URL config source

  Reads `Nebu.Media.Config.get()[:webhook_url]` — see
  `Nebu.Media.AlertNotifier`'s moduledoc for why this reads Story 9a/9b's
  already-shipped `media_config` table rather than a static app-env key. A
  `nil` result here (config changed to disabled between enqueue and job
  pickup) is a no-op, not an error.
  """

  use Oban.Worker,
    queue: :media_alerts,
    max_attempts: 5,
    unique: [period: 300, keys: [:media_id, :state]]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"media_id" => media_id, "state" => state, "timestamp" => ts}}) do
    case webhook_url() do
      # config changed to disabled between enqueue and pickup — no-op, not an error
      nil -> :ok
      url -> deliver(url, %{media_id: media_id, state: state, timestamp: ts})
    end
  end

  defp deliver(url, payload) do
    case webhook_http().post(url, payload) do
      {:ok, status} when status in 200..299 -> :ok
      {:ok, status} -> {:error, {:unexpected_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp webhook_url, do: Nebu.Media.Config.get()[:webhook_url]

  defp webhook_http,
    do: Application.get_env(:nebu_http, :media_webhook_http_module, Nebu.Media.WebhookDelivery)
end
