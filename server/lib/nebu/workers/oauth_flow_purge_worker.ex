defmodule Nebu.Workers.OAuthFlowPurgeWorker do
  @moduledoc """
  Oban-cron job every 10 minutes (epic oauth-broker, story oauth-authorize-idp-delegation-code,
  AC11) that purges expired OAuth flow state through `Nebu.OAuth.purge_expired_flow_state/0`:
  `oauth_authz_requests` past their `expires_at`, `oauth_consent_requests` past their `expires_at` (story
  oauth-authorize-freshness, FR6) and `oauth_codes` more than 24 h past their
  `expires_at` (used and expired codes are kept that long for reuse detection, D17). Story
  oauth-account-management (A23) adds `Nebu.OAuth.purge_expired_account_state/0` (expired login
  requests and browser sessions of the account page) and `Nebu.Matrix.purge_expired_uia_sessions/0`
  (expired UIA sessions, delegating to the so far never scheduled `Uia.cleanup_expired/0`).

  Housekeeping only: correctness never depends on it (consuming a request or a code checks
  `expires_at` in the same atomic statement). Cluster safe like `OAuthPendingPurgeWorker`: Cron
  enqueues from the Oban leader only, and the purge itself is batched atomic SQL that concurrent
  runs split between them. Logs counts only. A failure returns `{:error, reason}` so Oban retries.
  """
  use Oban.Worker, queue: :oauth_cleanup, max_attempts: 3

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    # Every purge runs even when an earlier one failed (each is independent housekeeping); the job
    # fails (Oban retries) when any of them did.
    results = [purge_flow_state(), purge_account_state(), purge_uia_sessions()]
    Enum.find(results, :ok, &(&1 != :ok))
  end

  defp purge_flow_state do
    case Nebu.OAuth.purge_expired_flow_state() do
      {:ok, %{authz_requests: 0, codes: 0, consents: 0}} ->
        :ok

      {:ok, %{authz_requests: requests, codes: codes, consents: consents}} ->
        Logger.info(
          "OAuth: purged #{requests} expired authorization request(s), #{consents} expired consent request(s) and #{codes} expired code(s)"
        )

        :ok

      {:error, reason} ->
        Logger.error("OAuth: flow-state purge failed: #{log_reason(reason)}")
        {:error, reason}
    end
  end

  # story oauth-account-management (A23): expired login requests and browser sessions of the account page
  defp purge_account_state do
    case Nebu.OAuth.purge_expired_account_state() do
      {:ok, %{login_requests: 0, sessions: 0}} ->
        :ok

      {:ok, %{login_requests: requests, sessions: sessions}} ->
        Logger.info("OAuth: purged #{requests} expired account login request(s) and #{sessions} expired account session(s)")
        :ok

      {:error, reason} ->
        Logger.error("OAuth: account-state purge failed: #{log_reason(reason)}")
        {:error, reason}
    end
  end

  # story oauth-account-management (A23): expired UIA sessions (`Uia.cleanup_expired/0`, expired rows only,
  # so the legacy UIA behaviour is unchanged); the count is all there is to report.
  defp purge_uia_sessions do
    case Nebu.Matrix.purge_expired_uia_sessions() do
      n when is_integer(n) and n > 0 ->
        Logger.info("OAuth: purged #{n} expired UIA session(s)")
        :ok

      _ ->
        :ok
    end
  end

  # Only the exception type / SQLSTATE, never row data.
  defp log_reason(%Postgrex.Error{postgres: %{code: code}}), do: "postgres #{code}"
  defp log_reason(%{__struct__: struct}), do: inspect(struct)
  defp log_reason(other) when is_atom(other), do: inspect(other)
  defp log_reason(_other), do: "unexpected error"
end
