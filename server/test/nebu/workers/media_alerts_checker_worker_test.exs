defmodule Nebu.Workers.MediaAlertsCheckerWorkerTest do
  @moduledoc """
  RED-phase acceptance tests for `Nebu.Workers.MediaAlertsCheckerWorker`
  (media-security-admin-control/10c-media-alerts-triggers, Acceptance Tests
  1-9; Acceptance Test 10, the dashboard LiveView test, lives in
  `test/nebu/admin/media_health_live_test.exs` per this story's own File
  List, added to Story 10a's/10b's existing LiveView test file rather than a
  new one).

  Story: docs/stories/media-security-admin-control/10c-media-alerts-triggers.md

  ## Why every test here fails right now (RED phase, no implementation yet)

  `Nebu.Workers.MediaAlertsCheckerWorker` does not exist. `Oban.Testing`'s
  `perform_job/2,3` calls `assert_valid_worker/1`
  (`deps/oban/lib/oban/testing.ex`), which checks
  `Code.ensure_loaded?(worker) and implements_worker?(worker)` BEFORE ever
  invoking `perform/1` — every test below therefore fails with an
  `ExUnit.AssertionError` ("Expected worker to be a module that implements
  the Oban.Worker behaviour"), the SAME documented RED-phase mechanism
  `media_scan_worker_test.exs` (Story 4b) already relies on. This means most
  of these tests fail even WITHOUT a live Postgres connection — only the
  handful of tests that seed fixtures directly against `media_scan_stats`
  (AT4/AT5/AT6/AT7's backlog/rate branches) or `media_alerts` (the `setup`
  block's own table wipe) need `NEBU_DB_URL` to even get that far; those
  additionally fail on "relation \"media_alerts\" does not exist" (migration
  000033 not yet written) if they ever get past the missing-worker check.

  ## Reconciled facts this file bakes in (see
  `_bmad-output/nebu/epics/media-security-admin-control/step-results/
  10c-media-alerts-triggers/reconciliation-notes.md` — authoritative over
  the story's own illustrative Technical Requirements code):

    * `Nebu.Media.Config.get/0` is ATOM-keyed (`config.clamav_down_alert_minutes`),
      not string-keyed as the story's illustrative worker snippet assumed.
      Thresholds are overridden per-test via `Nebu.Media.Config`'s OWN
      existing test seam, `Application.put_env(:nebu_http,
      :media_config_source, fn -> %{"string_key" => "value"} end)` (already
      established across this codebase — `config_test.exs`,
      `media_released_auto_delete_worker_test.exs`, etc.) — no NEW config
      seam is invented for this worker.
    * `Nebu.Media.ClamAV.health_check/0` -> `%{healthy: boolean(),
      changed_at: DateTime.t()}` (NOT a `{:down, down_since}`/`:up` tuple).
      `Nebu.Media.ClamAV.signature_info/0` -> `{:ok, DateTime.t()} |
      {:error, term()}` (signature DB build date — the worker computes the
      age delta itself). The worker is expected to translate `healthy:
      false` + `changed_at` into "down since" itself.
    * Seam convention: `Application.get_env(:nebu_http, :media_clamav_module,
      Nebu.Media.ClamAV)` — the EXACT existing key `Nebu.Workers.MediaScanWorker`
      already uses (`server/lib/nebu/workers/media_scan_worker.ex`), reused
      here rather than inventing `:media_clamav_status_module` as the
      story's own illustrative code did. One fake module backs BOTH
      `health_check/0` and `signature_info/0` (both live on the same real
      `Nebu.Media.ClamAV` module).
    * There is no reusable public reader for `media_scan_stats` backlog
      depth / rolling scan-failed rate (10a only ships a rollup WRITER,
      `MediaScanStatsRollupWorker`; the only existing READS are private
      inline-SQL functions inside `Nebu.Admin.MediaHealthLive`). This
      worker is expected to own its SAME KIND of inline SQL (ADR-018) rather
      than call into a nonexistent public function — so AT4/AT5 (and the
      backlog_depth/scan_failed_rate branches of AT6/AT7) seed REAL rows
      into `media_scan_stats` and let the worker's own query read them,
      rather than faking a reader module.
    * Design decision (this file's own, since the story is silent on the
      exact windowing shape): both `backlog_depth` and `scan_failed_rate`
      read the SINGLE MOST RECENT `media_scan_stats` row (`ORDER BY
      window_start DESC LIMIT 1`), mirroring `MediaHealthLive.fetch_latest_row/0`'s
      existing shape. 10a's rollup only ever produces one row per hour, and
      this checker's "rolling 1h" language (AC2) is naturally satisfied by
      that single latest hourly row — a wider multi-row rolling sum would
      duplicate 10a's own separately-rendered 24h/7d dashboard aggregates,
      which is out of scope here. The dev-story implementing this worker
      MUST read `scans_failed`/`scans_total`/`backlog_depth` off that same
      latest row (its own new `SELECT`, since `MediaHealthLive`'s existing
      `@sql_latest_row` doesn't select `scans_failed`).
    * `media_alerts` has NO admin-facing DELETE grant (deliberately, this
      story's own migration: `GRANT SELECT, INSERT, UPDATE` only) — test
      cleanup that needs to actually remove rows (rather than just resolve
      them) goes through the `nebu_migrate` role connection, mirroring
      `media_scan_stats_rollup_worker_test.exs`'s own `migrate_role_conn!/0`
      helper for `media_state_transitions`.
    * `media_alerts` enforces AT MOST ONE OPEN row per `alert_type` globally
      (partial unique index on `(alert_type, COALESCE(media_id, sentinel))
      WHERE resolved_at IS NULL` — all four of this story's alert types
      always carry `media_id = NULL`). Since this table is brand new and
      only this story's own tests touch it (same precedent
      `media_scan_stats_rollup_worker_test.exs` documents for
      `media_scan_stats`), every test here wipes the WHOLE table in `setup`
      rather than attempting per-test row scoping.
  """

  use ExUnit.Case, async: false
  use Oban.Testing, repo: Nebu.Repo

  @moduletag :integration

  alias Nebu.Repo
  alias Nebu.Workers.MediaAlertsCheckerWorker

  @alert_types ~w(clamav_disconnected signature_stale backlog_depth scan_failed_rate)

  # Far-future anchor for media_scan_stats fixtures in this file — guarantees
  # OUR row is always the "most recent" (`ORDER BY window_start DESC LIMIT 1`)
  # no matter what real-time or other-fixture rows exist elsewhere in the
  # suite (mirrors media_scan_stats_rollup_worker_test.exs's own far-PAST
  # anchor trick, just pointed the other direction since this worker reads
  # the LATEST row, not a fixed historical one).
  @scan_stats_anchor ~U[2999-01-01 00:00:00Z]

  # ── FakeClamAV (test-private, mirrors media_scan_worker_test.exs's own
  #    FakeClamAV convention) — backs BOTH health_check/0 and
  #    signature_info/0 via the SAME existing :media_clamav_module seam
  #    Nebu.Workers.MediaScanWorker already established. Defined BEFORE the
  #    setup block below (dev-story fix): a nested `defmodule FakeClamAV`
  #    only establishes the automatic `Foo.FakeClamAV` alias for code
  #    appearing AFTER it lexically in this same enclosing module — a
  #    `setup do ... Application.put_env(..., FakeClamAV) ... end` block
  #    placed BEFORE this definition would otherwise resolve the bare
  #    `FakeClamAV` atom to the top-level `Elixir.FakeClamAV` (which is never
  #    defined), not this nested test-private module — confirmed empirically
  #    (`UndefinedFunctionError: function FakeClamAV.health_check/0 is
  #    undefined (module FakeClamAV is not available)`). ──────────────────

  defmodule FakeClamAV do
    @moduledoc "Test-private fake for Nebu.Media.ClamAV.health_check/0 and signature_info/0."

    def health_check do
      Application.get_env(:nebu_http, :fake_clamav_health_check, %{
        healthy: true,
        changed_at: DateTime.utc_now()
      })
    end

    def signature_info do
      Application.get_env(:nebu_http, :fake_clamav_signature_info, {:ok, DateTime.utc_now()})
    end
  end

  setup do
    if Process.whereis(Nebu.Repo) == nil do
      flunk(
        "Nebu.Repo is not started — run with a live PostgreSQL (NEBU_DB_URL must be set), " <>
          "e.g. `make test-integration`"
      )
    end

    clear_media_alerts!()
    Application.put_env(:nebu_http, :media_clamav_module, FakeClamAV)
    Application.put_env(:nebu_http, :fake_clamav_health_check, %{
      healthy: true,
      changed_at: DateTime.utc_now()
    })
    Application.put_env(:nebu_http, :fake_clamav_signature_info, {:ok, DateTime.utc_now()})

    on_exit(fn ->
      Application.delete_env(:nebu_http, :media_clamav_module)
      Application.delete_env(:nebu_http, :fake_clamav_health_check)
      Application.delete_env(:nebu_http, :fake_clamav_signature_info)
      Application.delete_env(:nebu_http, :media_config_source)
      clear_media_alerts!()
      clear_far_future_scan_stats!()
    end)

    :ok
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Fixture / assertion helpers
  # ══════════════════════════════════════════════════════════════════════════

  defp migrate_role_conn! do
    url =
      System.get_env("NEBU_DB_URL") ||
        raise "NEBU_DB_URL is not set — this test requires a live PostgreSQL connection"

    uri = URI.parse(url)

    {:ok, conn} =
      Postgrex.start_link(
        hostname: uri.host || "localhost",
        port: uri.port || 5432,
        database: String.trim_leading(uri.path || "", "/"),
        username: "nebu_migrate",
        password: "nebu_migrate_dev_pw"
      )

    conn
  end

  # media_alerts grants no DELETE to nebu_app (deliberately, per this story's
  # own migration) — cleanup goes through the migrate role, same pattern
  # media_scan_stats_rollup_worker_test.exs uses for media_state_transitions.
  # Tolerant of the table not existing yet (pre-migration RED phase).
  defp clear_media_alerts! do
    conn = migrate_role_conn!()
    Postgrex.query(conn, "DELETE FROM media_alerts", [])
  rescue
    _ -> :ok
  end

  defp clear_far_future_scan_stats! do
    Ecto.Adapters.SQL.query(
      Repo,
      "DELETE FROM media_scan_stats WHERE window_start >= $1",
      [@scan_stats_anchor]
    )
  rescue
    _ -> :ok
  end

  defp put_fake_clamav(opts) do
    if Keyword.has_key?(opts, :healthy) do
      Application.put_env(:nebu_http, :fake_clamav_health_check, %{
        healthy: Keyword.fetch!(opts, :healthy),
        changed_at: Keyword.fetch!(opts, :changed_at)
      })
    end

    if Keyword.has_key?(opts, :signature_info) do
      Application.put_env(
        :nebu_http,
        :fake_clamav_signature_info,
        Keyword.fetch!(opts, :signature_info)
      )
    end

    :ok
  end

  defp set_media_config(overrides) do
    Application.put_env(:nebu_http, :media_config_source, fn -> overrides end)
  end

  # One "everything healthy" fixture shared by AT6's table-driven cases —
  # satisfies all four conditions simultaneously (ClamAV up, fresh signature,
  # empty backlog, zero failure rate) so seeding an already-OPEN alert for
  # any single type is the only thing under test in each loop iteration.
  defp make_everything_healthy! do
    put_fake_clamav(healthy: true, changed_at: DateTime.utc_now())
    put_fake_clamav(signature_info: {:ok, DateTime.utc_now()})

    set_media_config(%{
      "clamav_down_alert_minutes" => "5",
      "signature_stale_alert_hours" => "48",
      "backlog_depth_alert_threshold" => "3",
      "scan_failed_rate_alert_pct" => "10"
    })

    window_start = DateTime.add(@scan_stats_anchor, 1, :hour)
    insert_scan_stats_row!(window_start, released: 100, failed: 0, backlog_depth: 0)
  end

  defp insert_scan_stats_row!(window_start, released: released, failed: failed, backlog_depth: backlog_depth) do
    Ecto.Adapters.SQL.query!(
      Repo,
      """
      INSERT INTO media_scan_stats
        (window_start, scans_released, scans_infected, scans_failed, backlog_depth)
      VALUES ($1, $2, 0, $3, $4)
      ON CONFLICT (window_start) DO UPDATE
        SET scans_released = EXCLUDED.scans_released,
            scans_failed = EXCLUDED.scans_failed,
            backlog_depth = EXCLUDED.backlog_depth
      """,
      [window_start, released, failed, backlog_depth]
    )
  end

  defp fetch_alerts(alert_type) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        SELECT id, severity, message, media_id, condition_metadata, opened_at, resolved_at
          FROM media_alerts
         WHERE alert_type = $1
         ORDER BY opened_at
        """,
        [alert_type]
      )

    Enum.map(rows, fn [id, severity, message, media_id, metadata, opened_at, resolved_at] ->
      %{
        id: id,
        severity: severity,
        message: message,
        media_id: media_id,
        condition_metadata: metadata,
        opened_at: opened_at,
        resolved_at: resolved_at
      }
    end)
  end

  defp open_alerts(alert_type) do
    alert_type |> fetch_alerts() |> Enum.filter(&is_nil(&1.resolved_at))
  end

  defp fetch_alert_by_id(id) do
    %{rows: [[severity, resolved_at]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT severity, resolved_at FROM media_alerts WHERE id = $1",
        [id]
      )

    %{severity: severity, resolved_at: resolved_at}
  end

  defp severity_for("clamav_disconnected"), do: "critical"
  defp severity_for(_other), do: "warning"

  defp insert_open_alert!(alert_type) do
    %{rows: [[id]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        INSERT INTO media_alerts (alert_type, severity, message, media_id, condition_metadata)
        VALUES ($1, $2, $3, NULL, '{}'::jsonb)
        RETURNING id
        """,
        [alert_type, severity_for(alert_type), "seeded open alert for #{alert_type}"]
      )

    id
  end

  defp insert_resolved_alert!(alert_type) do
    %{rows: [[id]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        INSERT INTO media_alerts
          (alert_type, severity, message, media_id, condition_metadata, opened_at, resolved_at)
        VALUES ($1, $2, $3, NULL, '{}'::jsonb, now() - interval '1 hour', now() - interval '30 minutes')
        RETURNING id
        """,
        [alert_type, severity_for(alert_type), "seeded resolved alert for #{alert_type}"]
      )

    id
  end

  defp minutes_ago(n), do: DateTime.utc_now() |> DateTime.add(-n, :minute) |> DateTime.truncate(:second)
  defp hours_ago(n), do: DateTime.utc_now() |> DateTime.add(-n, :hour) |> DateTime.truncate(:second)

  # ══════════════════════════════════════════════════════════════════════════
  # AT1/AT2: clamav_disconnected — threshold crossing
  # ══════════════════════════════════════════════════════════════════════════

  test "clamav_disconnected alert opens once ClamAV has been down longer than the configured threshold" do
    put_fake_clamav(healthy: false, changed_at: minutes_ago(6))
    set_media_config(%{"clamav_down_alert_minutes" => "5"})

    assert :ok = perform_job(MediaAlertsCheckerWorker, %{})

    assert [alert] = open_alerts("clamav_disconnected")
    assert alert.severity == "critical"
    assert alert.media_id == nil
    assert alert.resolved_at == nil
    assert is_binary(alert.message)
  end

  test "clamav_disconnected alert does not open while ClamAV has been down for less than the configured threshold" do
    put_fake_clamav(healthy: false, changed_at: minutes_ago(2))
    set_media_config(%{"clamav_down_alert_minutes" => "5"})

    assert :ok = perform_job(MediaAlertsCheckerWorker, %{})

    assert open_alerts("clamav_disconnected") == []
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AT3: signature_stale — threshold crossing
  # ══════════════════════════════════════════════════════════════════════════

  test "signature_stale alert opens once signature age exceeds the configured threshold" do
    put_fake_clamav(healthy: true, changed_at: DateTime.utc_now())
    put_fake_clamav(signature_info: {:ok, hours_ago(50)})
    set_media_config(%{"signature_stale_alert_hours" => "48"})

    assert :ok = perform_job(MediaAlertsCheckerWorker, %{})

    assert [alert] = open_alerts("signature_stale")
    assert alert.severity == "warning"
    assert alert.media_id == nil
    assert alert.resolved_at == nil
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AT4: backlog_depth — threshold crossing (real media_scan_stats fixture,
  # no fake reader — see moduledoc)
  # ══════════════════════════════════════════════════════════════════════════

  test "backlog_depth alert opens once the quarantined+scanning backlog exceeds the configured threshold" do
    window_start = DateTime.add(@scan_stats_anchor, 2, :hour)
    insert_scan_stats_row!(window_start, released: 0, failed: 0, backlog_depth: 10)
    set_media_config(%{"backlog_depth_alert_threshold" => "3"})

    assert :ok = perform_job(MediaAlertsCheckerWorker, %{})

    assert [alert] = open_alerts("backlog_depth")
    assert alert.severity == "warning"
    assert alert.media_id == nil
    assert alert.resolved_at == nil
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AT5: scan_failed_rate — threshold crossing (real media_scan_stats fixture)
  # ══════════════════════════════════════════════════════════════════════════

  test "scan_failed_rate alert opens once the rolling 1h scan_failed rate exceeds the configured threshold" do
    window_start = DateTime.add(@scan_stats_anchor, 3, :hour)
    # 2/10 = 20% > 10% threshold.
    insert_scan_stats_row!(window_start, released: 8, failed: 2, backlog_depth: 0)
    set_media_config(%{"scan_failed_rate_alert_pct" => "10"})

    assert :ok = perform_job(MediaAlertsCheckerWorker, %{})

    assert [alert] = open_alerts("scan_failed_rate")
    assert alert.severity == "warning"
    assert alert.media_id == nil
    assert alert.resolved_at == nil
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AT6: auto-resolve once condition clears (table-driven, all 4 types)
  # ══════════════════════════════════════════════════════════════════════════

  test "an open alert auto-resolves on the next checker run once its condition clears" do
    make_everything_healthy!()

    for alert_type <- @alert_types do
      id = insert_open_alert!(alert_type)

      assert :ok = perform_job(MediaAlertsCheckerWorker, %{})

      alert = fetch_alert_by_id(id)
      refute is_nil(alert.resolved_at), "expected #{alert_type} alert id=#{id} to be resolved"
      assert open_alerts(alert_type) == []
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AT7: idempotent check-and-open across two sequential runs (all 4 types)
  # ══════════════════════════════════════════════════════════════════════════

  test "no duplicate open alerts for a still-ongoing condition across two consecutive checker runs" do
    put_fake_clamav(healthy: false, changed_at: minutes_ago(6))
    put_fake_clamav(signature_info: {:ok, hours_ago(50)})

    set_media_config(%{
      "clamav_down_alert_minutes" => "5",
      "signature_stale_alert_hours" => "48",
      "backlog_depth_alert_threshold" => "3",
      "scan_failed_rate_alert_pct" => "10"
    })

    window_start = DateTime.add(@scan_stats_anchor, 4, :hour)
    insert_scan_stats_row!(window_start, released: 8, failed: 2, backlog_depth: 10)

    assert :ok = perform_job(MediaAlertsCheckerWorker, %{})
    assert :ok = perform_job(MediaAlertsCheckerWorker, %{})

    for alert_type <- @alert_types do
      assert length(open_alerts(alert_type)) == 1,
             "expected exactly one open #{alert_type} alert after two runs"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AT8: concurrent racing runs — partial unique index regression guard
  # ══════════════════════════════════════════════════════════════════════════

  test "two concurrent checker runs racing on the same still-ongoing condition still leave exactly one open alert row" do
    put_fake_clamav(healthy: false, changed_at: minutes_ago(6))
    set_media_config(%{"clamav_down_alert_minutes" => "5"})

    results =
      [Task.async(fn -> perform_job(MediaAlertsCheckerWorker, %{}) end),
       Task.async(fn -> perform_job(MediaAlertsCheckerWorker, %{}) end)]
      |> Task.await_many(15_000)

    assert Enum.all?(results, &(&1 == :ok)),
           "both concurrent runs must complete without raising/erroring: #{inspect(results)}"

    assert length(open_alerts("clamav_disconnected")) == 1
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AT9: a resolved alert never blocks a fresh occurrence of the same condition
  # ══════════════════════════════════════════════════════════════════════════

  test "a resolved alert does not block a new alert from opening if the same condition recurs later" do
    _old_id = insert_resolved_alert!("clamav_disconnected")

    put_fake_clamav(healthy: false, changed_at: minutes_ago(6))
    set_media_config(%{"clamav_down_alert_minutes" => "5"})

    assert :ok = perform_job(MediaAlertsCheckerWorker, %{})

    assert length(open_alerts("clamav_disconnected")) == 1
  end
end
