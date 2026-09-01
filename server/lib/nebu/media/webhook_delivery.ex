defmodule Nebu.Media.WebhookDelivery do
  @moduledoc """
  Thin Finch wrapper — the production default for
  `Nebu.Workers.MediaAlertWebhookWorker`'s `:media_webhook_http_module` seam
  (media-security-admin-control/7-admin-notifications).

  Reuses the `Nebu.Media.Finch` pool `Nebu.Media.HttpFetch` already
  starts/uses rather than starting a second Finch pool.

  ## Send-time SSRF re-check (Kassandra security review, F-2 carry-forward from
  Story 9a's own security review)

  `webhook_url` is SSRF-validated once at config-SAVE time
  (`Nebu.Media.Config`'s `validate_value/2` calls `Nebu.Media.SSRF.check/1`
  before persisting). That check alone is insufficient at SEND time: this
  webhook can fire arbitrarily long after the admin last saved the URL (only
  on the next `:infected`/`scan_failed` transition), giving an attacker who
  can influence DNS resolution for the saved hostname (a classic
  DNS-rebinding TOCTOU) an unbounded window to repoint it at a loopback,
  private, link-local, or cloud-metadata (`169.254.169.254`) address after
  the save-time check already passed. 9a's own security report explicitly
  flagged this and required this story to re-check with `checked_target/1`
  before every send — this module does exactly that: `post/2` calls
  `Nebu.Media.SSRF.checked_target/1` immediately before the Finch request,
  every time, so a rebound hostname is caught at the moment of use, not
  trusted from a stale save-time check. Since `Nebu.Media.Config` only
  persists `https://` URLs, IP-pinning the connection (as `HttpFetch` does
  for `http`) is not applicable here — SNI/cert-hostname validation requires
  keeping the hostname in the URL, matching `HttpFetch`'s own documented
  residual caveat for `https` targets: the window between this re-check and
  Finch's own connect is real but small (a single request), not the
  effectively-unbounded "since the admin last saved the setting" window this
  fix closes.

  No redirect-following exists in this module (`Finch.request/2` returns the
  raw response, including any 3xx status, without following it) — an
  "unvalidated redirect" SSRF bypass has no code path to exploit here.

  The payload/response are both tiny, so buffering `Finch.request/2` (not
  `HttpFetch`'s streaming `stream_while/5`, used for arbitrarily large
  preview targets) is appropriate.
  """

  alias Nebu.Media.SSRF

  @finch Nebu.Media.Finch
  @recv_timeout 5_000

  @spec post(String.t(), map()) :: {:ok, non_neg_integer()} | {:error, term()}
  def post(url, payload) do
    case SSRF.checked_target(url) do
      {:ok, _target} -> do_post(url, payload)
      {:error, _reason} = err -> err
    end
  end

  defp do_post(url, payload) do
    body = Jason.encode!(payload)
    req = Finch.build(:post, url, [{"content-type", "application/json"}], body)

    case Finch.request(req, @finch, receive_timeout: @recv_timeout) do
      {:ok, %Finch.Response{status: status}} -> {:ok, status}
      {:error, reason} -> {:error, reason}
    end
  end
end
