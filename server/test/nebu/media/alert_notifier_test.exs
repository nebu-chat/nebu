defmodule Nebu.Media.AlertNotifierTest do
  @moduledoc """
  RED-phase ATDD tests for `media-security-admin-control/7-admin-notifications`
  (AC1-AC5, Acceptance Tests 1-5 as written in the story file).

  ALL tests in this module are expected to FAIL until `Nebu.Media.AlertNotifier`
  is implemented — `Code.ensure_loaded?(Nebu.Media.AlertNotifier)` fails first
  (module does not exist), so every test below fails with a `UndefinedFunctionError`
  before reaching any assertion.

  ## Design notes (grounded against the actual tree, not just the story's own
  illustrative sketch — same correction class prior ATDD files in this epic make)

    * The story's Technical Requirements illustrative code reads the webhook URL
      via a NEW static app-env key (`config :nebu, :media_alerts, webhook_url:`).
      That plan predates Story 9a/9b landing. `Nebu.Media.Config`
      (`server/lib/nebu/media/config.ex`, ADR-027) ALREADY ships a `webhook_url`
      key in its 10-key `media_config` catalog — including its own
      `https://`-scheme + `Nebu.Media.SSRF.check/1` write-time validation and an
      admin settings UI (`Nebu.Admin.MediaSettingsController`) — confirmed by
      reading `config.ex` directly. Per the story's own explicit dev-time
      contingency ("if 9a/9b has already landed ... prefer wiring directly to
      `Nebu.Media.Config...` from the start"), this test file drives
      `AlertNotifier`/`MediaAlertWebhookWorker` against `Nebu.Media.Config`'s
      EXISTING `:nebu_http, :media_config_source` test seam (a 0-arity fun
      returning a STRING-keyed override map — see `config_test.exs`), NOT an
      invented `:media_alerts` app-env key. `nil`/unset `webhook_url` is the
      catalog's real default (AC4's "no webhook URL configured" case), matching
      `Nebu.Media.Config`'s own `@defaults`.
    * `AlertNotifier.handle_broadcast/1` (the pure delegate `handle_info/2` calls
      into) is exercised directly, per the story's Acceptance Tests section —
      no live `AlertNotifier` GenServer/PubSub round-trip is needed for these
      assertions.
    * `handle_broadcast/1` enqueues via a REAL `Oban.insert/1` call (per the
      story's Technical Requirements — the notifier "only enqueues", Oban owns
      delivery). This app runs the same Oban config in every env (no
      `Oban.Testing, testing: :manual` override in `config/test.exs`), so this
      requires a live `Nebu.Repo`/`oban_jobs` table — same real-Postgres pattern
      already established by `Nebu.Media.ScanEnqueueTest`
      (`test/nebu/media/scan_enqueue_test.exs`) and
      `Nebu.MediaAdminActionsTest`. Hence `@moduletag :integration`. No
      `Ecto.Sandbox` isolation is used in this codebase; unique `media_id`s
      (via `@run_id`) avoid cross-test collisions instead.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  alias Nebu.Media.AlertNotifier
  alias Nebu.Workers.MediaAlertWebhookWorker

  @run_id Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)

  defp media_id(suffix), do: "alertnotif_#{@run_id}_#{suffix}"

  # bugfix integration-test-flakes-fix (F): `assert_enqueued/1` / `refute_enqueued/1` only look at jobs that are still `available` / `scheduled`.
  # This app runs Oban with live queues in the test process AND in the server stack on the same database, so a job inserted by the code under test
  # can already be `executing` / `completed` / `retryable` / `discarded` (the webhook URL is unreachable) when the assertion looks: the assertion
  # then failed sporadically, and a refute could pass vacuously. These helpers ask `oban_jobs` for the media alert jobs of one media id in ANY state.
  defp alert_jobs(media_id) do
    worker = MediaAlertWebhookWorker |> Atom.to_string() |> String.replace_leading("Elixir.", "")

    Ecto.Adapters.SQL.query!(
      Nebu.Repo,
      "SELECT args FROM oban_jobs WHERE worker = $1 AND queue = 'media_alerts' AND args @> $2::jsonb",
      [worker, %{"media_id" => media_id}]
    ).rows
    |> Enum.map(fn [args] -> args end)
  end

  defp assert_alert_job(media_id, state) do
    jobs = alert_jobs(media_id)

    assert Enum.any?(jobs, &(&1["state"] == state)),
           "expected a media alert job for #{media_id} with state #{inspect(state)} (any job state), got #{inspect(jobs)}"
  end

  defp refute_alert_job(media_id) do
    assert alert_jobs(media_id) == [], "no media alert job may exist for #{media_id} (any job state)"
  end

  setup do
    if Process.whereis(Nebu.Repo) == nil do
      flunk(
        "Nebu.Repo is not started — run with a live PostgreSQL (NEBU_DB_URL must be set), e.g. `make test-integration`"
      )
    end

    on_exit(fn -> Application.delete_env(:nebu_http, :media_config_source) end)

    :ok
  end

  defp with_webhook_url(url) do
    Application.put_env(:nebu_http, :media_config_source, fn ->
      %{"webhook_url" => url}
    end)
  end

  defp without_webhook_url do
    Application.put_env(:nebu_http, :media_config_source, fn -> %{} end)
  end

  # ─── Acceptance Test 1 (AC2) — :infected enqueues the webhook job ──────────

  test "a broadcast into :infected enqueues a MediaAlertWebhookWorker job for that media_id and state" do
    with_webhook_url("https://ops.example.test/hooks/media-alerts")
    id = media_id("infected")

    assert :ok = AlertNotifier.handle_broadcast({:media_state_transition, id, :scanning, :infected})

    assert_alert_job(id, "infected")
  end

  # ─── Acceptance Test 2 (AC2) — scan_failed enqueues the webhook job ────────

  test "a broadcast into scan_failed enqueues a MediaAlertWebhookWorker job" do
    with_webhook_url("https://ops.example.test/hooks/media-alerts")
    id = media_id("scanfailed")

    assert :ok =
             AlertNotifier.handle_broadcast({:media_state_transition, id, :quarantined, :scan_failed})

    assert_alert_job(id, "scan_failed")
  end

  # ─── Acceptance Test 3 (AC4) — no webhook URL configured is a no-op ────────

  test "no job is enqueued when no webhook URL is configured" do
    without_webhook_url()
    id = media_id("nowebhook")

    assert :ok = AlertNotifier.handle_broadcast({:media_state_transition, id, :scanning, :infected})

    refute_alert_job(id)
  end

  # ─── Acceptance Test 4 (AC5) — only :infected/:scan_failed notify ──────────

  test "a broadcast into any non-notify terminal state never enqueues a webhook job" do
    with_webhook_url("https://ops.example.test/hooks/media-alerts")

    for new_state <- [:released, :quarantined, :scanning, :admin_blocked, :deleted, :hard_deleted] do
      id = media_id("nonnotify_#{new_state}")

      assert :ok = AlertNotifier.handle_broadcast({:media_state_transition, id, :scanning, new_state})

      refute_alert_job(id)
    end
  end

  # ─── Acceptance Test 5 (AC2 no-op guard) — old_state == new_state is ignored ──

  test "a broadcast where old_state == new_state is ignored (no duplicate notification)" do
    with_webhook_url("https://ops.example.test/hooks/media-alerts")
    id = media_id("noop_guard")

    assert :ok = AlertNotifier.handle_broadcast({:media_state_transition, id, :infected, :infected})

    refute_alert_job(id)
  end
end
