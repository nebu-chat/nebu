defmodule Nebu.Workers.OAuthPendingPurgeWorker do
  @moduledoc """
  Hourly Oban-cron job (epic oauth-broker, story oauth-metadata-dcr-admin-approval, decision
  "pending-row protection", ADR-033) that purges `pending` OAuth client registrations older than
  the TTL (`server_config.oauth_pending_ttl_days`, default 30 days).

  `POST /oauth2/register` is unauthenticated, so `pending` rows accumulate (abuse or abandoned
  registrations). They never have a session, so deleting them does not violate the Matrix rule
  "a server MUST NOT delete a registration with an active session". `approved` and `rejected`
  registrations are NEVER purged — not by this worker (the SQL only matches `status = 'pending'`)
  and not by anything else (the runtime role's row level security refuses DELETE for them,
  migration 000040).

  ## Cluster safety (ADR-020)

  Scheduled through `Oban.Plugins.Cron` (see `config/config.exs`), which enqueues from the Oban
  leader only, so one job per tick cluster-wide. Correctness does not even depend on that: the
  work is `Nebu.OAuth.ClientStore.purge_expired_pending/1`, an atomic batched
  `DELETE ... FOR UPDATE SKIP LOCKED`, so two concurrent runs (leader hand-over, manual run)
  split the rows between them and never touch a row twice. No node-local state, no advisory lock.

  A failure returns `{:error, reason}` so Oban retries; the next hourly tick continues anyway
  (each call handles at most 20 batches of 1000 rows).
  """
  use Oban.Worker, queue: :oauth_cleanup, max_attempts: 3

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case Nebu.OAuth.purge_expired_pending() do
      {:ok, 0} ->
        :ok

      {:ok, deleted} ->
        Logger.info("OAuth: purged #{deleted} expired pending client registration(s)")
        :ok

      {:error, reason} ->
        Logger.error("OAuth: pending registration purge failed: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
