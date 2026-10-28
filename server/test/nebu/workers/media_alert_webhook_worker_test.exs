defmodule Nebu.Workers.MediaAlertWebhookWorkerTest do
  @moduledoc """
  RED-phase ATDD tests for `media-security-admin-control/7-admin-notifications`
  (AC3, AC6, Acceptance Tests 6-9 as written in the story file).

  ALL tests in this module are expected to FAIL until
  `Nebu.Workers.MediaAlertWebhookWorker` is implemented — `perform_job/2,3`
  (from `Oban.Testing`) asserts the worker module implements the `Oban.Worker`
  behaviour BEFORE ever calling `perform/1` (see
  `deps/oban/lib/oban/testing.ex` `assert_valid_worker/1`) — same RED-phase
  mechanics already documented by `media_scan_worker_test.exs`. This requires
  no live Postgres/`Nebu.Repo` connection: `Oban.Testing.perform_job/2,3`
  builds and executes the job in-process (`Executor.new(job, safe: false, ack:
  false)`), never touching the real `oban_jobs` table — so this file (unlike
  `alert_notifier_test.exs`) is exercised by the plain unit suite, no
  `@moduletag :integration` needed.

  ## Design notes

    * Per the story's own explicit dev-time contingency (see
      `alert_notifier_test.exs`'s moduledoc for the full rationale),
      the webhook URL is read via `Nebu.Media.Config`'s existing
      `:nebu_http, :media_config_source` test seam — NOT an invented
      `:media_alerts` app-env key.
    * `:media_webhook_http_module` is a NEW seam this worker introduces (no
      prior seam existed for `Nebu.Media.WebhookDelivery`, which did not exist
      before this story) — mirrors the `:media_clamav_module`/`FakeClamAV`
      convention from `media_scan_worker_test.exs`. The fake's `post/2`
      signature matches `Nebu.Media.WebhookDelivery.post/2` exactly: `(url,
      payload_map) -> {:ok, status} | {:error, reason}` — JSON encoding is the
      real `WebhookDelivery` module's own concern, entirely bypassed by this
      seam, so Acceptance Test 6's "captured JSON body decodes to a map with
      exactly the keys ..." is proven here by round-tripping the CAPTURED
      payload map through `Jason.encode!/1` + `Jason.decode!/1` ourselves —
      proving the payload is JSON-safe and carries exactly the three sanctioned
      keys, without needing the real `WebhookDelivery.post/2` (bypassed by the
      seam) to be exercised in this file.
    * Zero-calls-into-the-media-domain assertions (Acceptance Tests 7/8) use
      bespoke Agent-backed call-log fakes for `Nebu.Media.StateMachine` and
      `Nebu.Media.DB`, mirroring `media_scan_worker_test.exs`'s own
      `FakeStateMachine`/`FakeDB` convention — a regression guard proving a
      delivery failure never re-enters the media state machine or the
      `media_files`/`media_state_transitions` tables in any branch.
  """

  use ExUnit.Case, async: false
  use Oban.Testing, repo: Nebu.Repo

  alias Nebu.Workers.MediaAlertWebhookWorker

  @http_calls :media_alert_webhook_test_http_calls
  @sm_calls :media_alert_webhook_test_sm_calls
  @db_calls :media_alert_webhook_test_db_calls

  @webhook_url "https://ops.example.test/hooks/media-alerts"

  # ─── FakeWebhookHttp (test-private — new seam this worker introduces) ──────

  defmodule FakeWebhookHttp do
    @moduledoc "Test-private fake for Nebu.Media.WebhookDelivery.post/2."

    def post(url, payload) do
      Agent.update(Process.whereis(:media_alert_webhook_test_http_calls), fn calls ->
        [{url, payload} | calls]
      end)

      fun = Application.get_env(:nebu_http, :media_webhook_post_fun)
      if fun, do: fun.(url, payload), else: {:ok, 200}
    end
  end

  # ─── FakeStateMachine / FakeDB (zero-calls regression guards, AC6) ─────────

  defmodule FakeStateMachine do
    @moduledoc "Test-private call-log fake for Nebu.Media.StateMachine — must NEVER be called by this worker."

    def transition(media_id, to_state, actor, metadata \\ %{}) do
      Agent.update(Process.whereis(:media_alert_webhook_test_sm_calls), fn calls ->
        [{media_id, to_state, actor, metadata} | calls]
      end)

      {:ok, to_state}
    end
  end

  defmodule FakeDB do
    @moduledoc "Test-private call-log fake for Nebu.Media.DB — must NEVER be called by this worker."

    def update_scan_metadata(media_id, metadata) do
      Agent.update(Process.whereis(:media_alert_webhook_test_db_calls), fn calls ->
        [{media_id, metadata} | calls]
      end)

      :ok
    end
  end

  setup do
    {:ok, _} = Agent.start_link(fn -> [] end, name: @http_calls)
    {:ok, _} = Agent.start_link(fn -> [] end, name: @sm_calls)
    {:ok, _} = Agent.start_link(fn -> [] end, name: @db_calls)

    Application.put_env(:nebu_http, :media_webhook_http_module, FakeWebhookHttp)
    Application.put_env(:nebu_http, :media_state_machine_module, FakeStateMachine)
    Application.put_env(:nebu_http, :media_db_module, FakeDB)
    Application.put_env(:nebu_http, :media_config_source, fn -> %{"webhook_url" => @webhook_url} end)

    on_exit(fn ->
      for name <- [@http_calls, @sm_calls, @db_calls] do
        case Process.whereis(name) do
          nil -> :ok
          pid -> if Process.alive?(pid), do: (try do Agent.stop(pid) catch :exit, _ -> :ok end)
        end
      end

      Application.delete_env(:nebu_http, :media_webhook_http_module)
      Application.delete_env(:nebu_http, :media_state_machine_module)
      Application.delete_env(:nebu_http, :media_db_module)
      Application.delete_env(:nebu_http, :media_config_source)
      Application.delete_env(:nebu_http, :media_webhook_post_fun)
    end)

    :ok
  end

  defp set_post_result(fun), do: Application.put_env(:nebu_http, :media_webhook_post_fun, fun)

  defp http_calls, do: Process.whereis(@http_calls) |> Agent.get(&Enum.reverse/1)
  defp sm_calls, do: Process.whereis(@sm_calls) |> Agent.get(&Enum.reverse/1)
  defp db_calls, do: Process.whereis(@db_calls) |> Agent.get(&Enum.reverse/1)

  # ─── Acceptance Test 6 (AC3) — exact payload shape, correct URL ────────────

  test "performs a POST to the configured webhook URL with exactly media_id, state, and timestamp" do
    media_id = "media-alert-payload-1"
    ts = DateTime.utc_now() |> DateTime.to_iso8601()

    set_post_result(fn _url, _payload -> {:ok, 200} end)

    assert :ok =
             perform_job(MediaAlertWebhookWorker, %{
               "media_id" => media_id,
               "state" => "infected",
               "timestamp" => ts
             })

    assert [{captured_url, captured_payload}] = http_calls()
    assert captured_url == @webhook_url

    decoded = captured_payload |> Jason.encode!() |> Jason.decode!()

    assert Map.keys(decoded) |> Enum.sort() == ["media_id", "state", "timestamp"]
    assert decoded["media_id"] == media_id
    assert decoded["state"] == "infected"
    assert decoded["timestamp"] == ts
  end

  # ─── Acceptance Test 7 (AC6) — delivery failure is retryable, never touches media state ──

  test "a delivery failure (timeout/non-2xx) returns {:error, reason} so Oban retries with backoff, and never touches media state" do
    media_id = "media-alert-failure-1"

    set_post_result(fn _url, _payload -> {:error, :timeout} end)

    assert {:error, :timeout} =
             perform_job(MediaAlertWebhookWorker, %{
               "media_id" => media_id,
               "state" => "infected",
               "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
             })

    assert sm_calls() == []
    assert db_calls() == []
  end

  # ─── Acceptance Test 8 (AC6) — exhausting max_attempts discards without touching media state ──

  test "exhausting max_attempts discards the job without any effect on media state" do
    media_id = "media-alert-exhausted-1"

    set_post_result(fn _url, _payload -> {:error, :econnrefused} end)

    result =
      perform_job(
        MediaAlertWebhookWorker,
        %{
          "media_id" => media_id,
          "state" => "scan_failed",
          "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
        },
        attempt: 5,
        max_attempts: 5
      )

    assert match?({:error, _reason}, result)
    assert sm_calls() == []
    assert db_calls() == []
  end

  # ─── Acceptance Test 9 (AC3) — successful 2xx returns :ok, not retried ─────

  test "a successful 2xx response returns :ok and the job is not retried" do
    media_id = "media-alert-success-1"

    set_post_result(fn _url, _payload -> {:ok, 200} end)

    assert :ok =
             perform_job(MediaAlertWebhookWorker, %{
               "media_id" => media_id,
               "state" => "infected",
               "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
             })
  end
end
