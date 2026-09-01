defmodule Nebu.Media.WebhookDeliveryTest do
  @moduledoc """
  Regression tests for the send-time SSRF re-check added to
  `Nebu.Media.WebhookDelivery.post/2` (Kassandra security review, F-2
  carry-forward from Story 9a: "SSRF on webhook_url is validated at
  STORE-time only ... Story 7 MUST re-check w/ `checked_target/1`").

  Exercises the REAL module directly (not through the
  `:media_webhook_http_module` seam every worker-level test fakes out — see
  `media_alert_webhook_worker_test.exs`'s own moduledoc for why that seam
  exists) — mirroring `Nebu.Media.ScanEnqueueTest`'s convention of testing a
  seam's real production implementation in its own dedicated file.

  Uses literal IP addresses (no live DNS lookup needed — `SSRF.checked_target/1`
  parses a literal IP directly via `:inet.parse_address/1`), same convention
  as `url_preview_test.exs`'s own `SSRF.checked_target/1` tests.
  """

  use ExUnit.Case, async: false

  alias Nebu.Media.WebhookDelivery

  setup do
    # `:start_finch` is `false` in config/test.exs (a plain unit run has no
    # media_children Finch pool started) — start it here, same pattern
    # media_scan_worker_test.exs's own ensure_pubsub_started!/0 uses for
    # Nebu.PubSub. Guarded so this is a no-op if the full app already started it.
    case Process.whereis(Nebu.Media.Finch) do
      nil -> start_supervised!({Finch, name: Nebu.Media.Finch})
      _pid -> :ok
    end

    :ok
  end

  test "rejects a URL whose host resolves to a blocked/private/loopback/metadata address" do
    assert {:error, :blocked_address} = WebhookDelivery.post("https://127.0.0.1:1/hook", %{a: 1})
    assert {:error, :blocked_address} = WebhookDelivery.post("https://10.0.0.5:1/hook", %{a: 1})

    assert {:error, :blocked_address} =
             WebhookDelivery.post("https://169.254.169.254/latest/meta-data", %{a: 1})
  end

  test "rejects a non-http(s) scheme" do
    assert {:error, :bad_scheme} = WebhookDelivery.post("file:///etc/passwd", %{a: 1})
  end

  test "a public IP passes the SSRF re-check and reaches the real Finch request (not pre-emptively blocked)" do
    # 93.184.216.34 (example.com) is public — SSRF.checked_target/1 allows it,
    # so the request proceeds to Finch. Nothing listens on port 1 there, so
    # Finch itself returns a connection error — this PROVES the request was
    # not blocked by the SSRF guard (a :blocked_address error would have come
    # back instead), without depending on a live network round-trip.
    assert {:error, _reason} = WebhookDelivery.post("https://93.184.216.34:1/hook", %{a: 1})
  end
end
