defmodule Nebu.Media.AlertNotifier do
  @moduledoc """
  Subscribes to Story 5b's broad `"media:admin"` broadcast and enqueues an
  optional outbound webhook Oban job whenever a file becomes `:infected` or
  exhausts its scan retries into `scan_failed`
  (media-security-admin-control/7-admin-notifications, AC1-AC5).

  A `GenServer` started under `Nebu.Application`'s supervision tree, after
  `Nebu.PubSub` is started (same ordering constraint 4b's Oban child already
  documents for needing its dependency started first).

  ## Does NOT subscribe per-`media_id`, does NOT invent a new topic (AC1)

  Consumes `Nebu.Media.StateMachine`'s existing 4-tuple broadcast
  `{:media_state_transition, media_id, old_state, new_state}` on `"media:admin"`
  — the same broad, system-wide topic Story 5b introduced for the nav
  "attention" badge, for the identical reason (a system-wide concern that
  needs every file's transitions, not one topic per file). This module never
  subscribes to the older, per-file `"media:\#{media_id}"` 3-tuple topic
  `Nebu.Workers.MediaScanWorker` broadcasts on (Story 2d/4b) — that topic has
  no `old_state`, which this module's no-op guard (AC2) requires.

  ## Never calls out synchronously (AC2)

  On a broadcast whose `new_state` is `:infected` or `scan_failed` (and
  `old_state != new_state`, guarding against a re-broadcast of the same state
  being treated as a fresh event), and a webhook URL is configured (AC4), this
  module enqueues exactly one `Nebu.Workers.MediaAlertWebhookWorker` Oban job
  on the dedicated `:media_alerts` queue — never calling the webhook endpoint
  itself. Delivery (HTTP call, retry/backoff, discard) is entirely the Oban
  worker's concern.

  ## Webhook URL config source (see Dev Agent Record / dependency-research.md)

  The story's own Technical Requirements illustrative code reads the webhook
  URL from a NEW static app-env key (`config :nebu, :media_alerts,
  webhook_url:`), with an explicit "confirm at dev-story time" note: if Story
  9a/9b's `media_config` table / `Nebu.Media.Config` module (ADR-027) has
  already landed, wire directly to it instead. It HAS landed —
  `Nebu.Media.Config` already ships a `webhook_url` key in its 10-key
  `media_config` catalog (including its own `https://`-scheme +
  `Nebu.Media.SSRF.check/1` write-time validation and an admin settings UI).
  This module therefore reads `Nebu.Media.Config.get()[:webhook_url]` — the
  real API is `get/0` (returning the full catalog map), not the `get/1`
  arity the story's prose describes.

  ## Cluster-safety via Oban's own unique constraint, not a singleton GenServer

  `Nebu.PubSub` broadcasts are visible to every connected node (this app runs
  clustered via `libcluster`/`horde`), so more than one node's own
  `AlertNotifier` could observe the same broadcast and attempt to enqueue the
  same job. `Nebu.Workers.MediaAlertWebhookWorker`'s `unique: [period: 300,
  keys: [:media_id, :state]]` Oban option deduplicates this cheaply via
  Postgres's own unique index (one row wins, the rest are no-ops) — consistent
  with this epic's general preference (ADR-025) for Oban's built-in guarantees
  over a bespoke leader-election scheme for this GenServer itself.
  """

  use GenServer

  @topic "media:admin"
  @notify_states [:infected, :scan_failed]

  @doc false
  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    Phoenix.PubSub.subscribe(Nebu.PubSub, @topic)
    {:ok, %{}}
  end

  @impl true
  def handle_info({:media_state_transition, media_id, old_state, new_state}, state) do
    handle_broadcast({:media_state_transition, media_id, old_state, new_state})
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @doc """
  Pure(ish) delegate `handle_info/2` calls into so tests can drive it without
  a running `GenServer`/`PubSub` round-trip (per the story's own Acceptance
  Tests section).
  """
  @spec handle_broadcast(tuple()) :: :ok
  def handle_broadcast({:media_state_transition, _media_id, same, same}), do: :ok

  def handle_broadcast({:media_state_transition, media_id, _old_state, new_state})
      when new_state in @notify_states do
    if webhook_url() do
      %{
        media_id: media_id,
        state: to_string(new_state),
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
      }
      |> Nebu.Workers.MediaAlertWebhookWorker.new()
      |> Oban.insert()
    end

    :ok
  end

  def handle_broadcast(_other), do: :ok

  defp webhook_url, do: Nebu.Media.Config.get()[:webhook_url]
end
