defmodule Nebu.Admin.MediaHealthLiveTest do
  @moduledoc """
  Acceptance tests for `Nebu.Admin.MediaHealthLive`
  (media-security-admin-control/10a-scan-stats-rollup, Acceptance Tests 8-10).

  Story: docs/stories/media-security-admin-control/10a-scan-stats-rollup.md

  Mirrors `media_live_test.exs`'s own real-Postgres, router-mounted convention
  (`Nebu.Admin.MediaLive` has no injectable fake-DB seam either — ADR-018 puts
  every query inline against the DB directly). `admin_conn_for_live/1` /
  `non_admin_conn/1` are copied verbatim from that file's own helpers.

  ## Table-wide isolation (AT8/AT9)

  Unlike `MediaLive`'s own tests (which scope every fixture row by a unique
  `@run_id`-tagged `media_id` and filter queries accordingly),
  `Nebu.Admin.MediaHealthLive`'s rolling-window reads
  (`ORDER BY window_start DESC LIMIT N`) have no such per-test scoping
  mechanism available — the LiveView reads whatever the N MOST RECENT rows in
  `media_scan_stats` happen to be, table-wide. AT8 and AT9 each therefore
  `DELETE FROM media_scan_stats` first to establish a fully controlled
  precondition (an empty table) before seeding their own fixture — safe here
  because `media_scan_stats` is a brand-new, derived/re-computable rollup
  table (this story's own migration) that only this story's own tests touch;
  nothing else in the suite depends on its content surviving across tests.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  import Phoenix.LiveViewTest
  import Phoenix.ConnTest

  alias Nebu.Repo
  alias Nebu.Media.ClamAVFakeServer, as: FakeClamd

  @endpoint Nebu.Admin.Endpoint

  setup do
    if Process.whereis(Nebu.Repo) == nil do
      flunk(
        "Nebu.Repo is not started — run with a live PostgreSQL (NEBU_DB_URL must be set), " <>
          "e.g. `make test-integration`"
      )
    end

    Nebu.Release.migrate()
    Nebu.Admin.DB.upsert_server_config(%{"bootstrap_completed" => "true"})

    :ok
  end

  defp admin_conn_for_live(path) do
    %{
      Plug.Test.conn(:get, path)
      | secret_key_base: String.duplicate("nebu-media-health-live-test-key", 2)
    }
    |> Nebu.Admin.Endpoint.admin_session([])
    |> Plug.Conn.fetch_session()
    |> Plug.Conn.put_session("current_user", %{
      "admin" => true,
      "sub" => "admin-media-health-live-tests",
      "matrix_user_id" => "@admin:test.local"
    })
  end

  defp sent_admin_conn(path) do
    path
    |> admin_conn_for_live()
    |> @endpoint.call(@endpoint.init([]))
  end

  defp non_admin_conn(path) do
    %{
      Plug.Test.conn(:get, path)
      | secret_key_base: String.duplicate("nebu-media-health-live-test-key", 2)
    }
    |> Nebu.Admin.Endpoint.admin_session([])
    |> Plug.Conn.fetch_session()
    |> @endpoint.call(@endpoint.init([]))
  end

  defp clear_media_scan_stats! do
    Ecto.Adapters.SQL.query!(Repo, "DELETE FROM media_scan_stats", [])
  end

  defp insert_stats_row!(window_start, released, infected, failed, avg_ms, p95_ms, backlog) do
    Ecto.Adapters.SQL.query!(
      Repo,
      """
      INSERT INTO media_scan_stats
        (window_start, scans_released, scans_infected, scans_failed,
         avg_scan_duration_ms, p95_scan_duration_ms, backlog_depth)
      VALUES ($1, $2, $3, $4, $5, $6, $7)
      """,
      [window_start, released, infected, failed, avg_ms, p95_ms, backlog]
    )
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AT8: rolling 24h throughput + error rate from 24 seeded rows
  # ══════════════════════════════════════════════════════════════════════════

  test "mount renders the metrics section with correct rolling 24h throughput and error rate from 24 seeded media_scan_stats rows" do
    clear_media_scan_stats!()

    # Anchored far from "now" so nothing else in the suite (including this
    # worker's own cron-driven "current hour" row) can ever collide with
    # these 24 rows once the table has been cleared above.
    anchor = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(-3000, :hour)

    rows =
      for i <- 0..23 do
        if rem(i, 6) == 0 do
          # released: 6, infected: 0, failed: 4 -> scans_total: 10
          %{released: 6, infected: 0, failed: 4}
        else
          # released: 10, infected: 0, failed: 0 -> scans_total: 10
          %{released: 10, infected: 0, failed: 0}
        end
      end

    Enum.with_index(rows, fn row, i ->
      window_start = DateTime.add(anchor, i, :hour)

      insert_stats_row!(
        window_start,
        row.released,
        row.infected,
        row.failed,
        1000,
        1500,
        0
      )
    end)

    expected_total =
      Enum.reduce(rows, 0, fn row, acc -> acc + row.released + row.infected + row.failed end)

    expected_failed = Enum.reduce(rows, 0, fn row, acc -> acc + row.failed end)
    expected_pct = Float.round(expected_failed / expected_total * 100, 1)

    conn = sent_admin_conn("/admin/media/health")
    {:ok, _view, html} = live(conn)

    assert html =~ ~s(data-testid="throughput-24h")
    assert html =~ Integer.to_string(expected_total)
    assert html =~ ~s(data-testid="error-rate-24h")
    assert html =~ "#{expected_pct}%"
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AT9: empty state
  # ══════════════════════════════════════════════════════════════════════════

  test "mount renders the empty state when media_scan_stats has zero rows" do
    clear_media_scan_stats!()

    conn = sent_admin_conn("/admin/media/health")
    {:ok, _view, html} = live(conn)

    assert html =~ "Noch keine Scan-Daten"
    refute html =~ ~s(data-testid="current-hour-total")
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AT10: access control
  # ══════════════════════════════════════════════════════════════════════════

  test "non-admin access control: a session without the admin role is redirected away from /admin/media/health, never rendering the metrics section" do
    conn = non_admin_conn("/admin/media/health")

    assert {:error, {:redirect, %{to: "/admin/login"}}} = live(conn)
  end

  # ══════════════════════════════════════════════════════════════════════════
  # media-security-admin-control/10b-clamav-status-freshclam-age
  #
  # `Nebu.Admin.ClamAVStatusIndicator` does not exist yet and
  # `Nebu.Media.ClamAV.health_check/0`/`signature_info/0` don't have this
  # story's extended shape yet, so `Nebu.Admin.MediaHealthLive` has no
  # ClamAV status/signature-age section to render at all — every test below
  # fails (no `data-testid="clamav-*"` markup exists in the page yet, and/or
  # `start_clamav!/1` below fails once the dev-story's own extension to
  # `Nebu.Media.ClamAV`'s config/return shape doesn't match this file's
  # expectations) until dev-story wires `ClamAVStatusIndicator.status/0` +
  # `assign_status/2` into this LiveView's `mount/3` (AC5/AC6 — same page,
  # LiveView poll, per the story's own confirmed-against-10a assumption).
  #
  # Covers Acceptance Tests 1-4 end-to-end on the real dashboard page; see
  # `clamav_status_indicator_test.exs` for Acceptance Tests 1, 2, 5, 6 at
  # the helper level (AT1/AT2 deliberately covered at both layers).
  # ══════════════════════════════════════════════════════════════════════════

  describe "10b: ClamAV status + signature age section" do
    setup do
      on_exit(fn ->
        if pid = Process.whereis(Nebu.Media.ClamAV) do
          Process.exit(pid, :kill)
        end

        Application.delete_env(:nebu, Nebu.Media.ClamAV)
      end)

      :ok
    end

    defp start_clamav!(overrides) do
      base = [
        address: {:tcp, "127.0.0.1", 0},
        max_file_size_bytes: 100 * 1024 * 1024,
        signature_max_age_hours: 48
      ]

      config = Keyword.merge(base, overrides)
      Application.put_env(:nebu, Nebu.Media.ClamAV, config)

      start_supervised!(Nebu.Media.ClamAV)
    end

    defp closed_port! do
      {:ok, listen_socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listen_socket)
      :ok = :gen_tcp.close(listen_socket)
      port
    end

    # ── AT1 ──────────────────────────────────────────────────────────────

    test "AT1: connected state renders a positive ClamAV status badge, no down-since timestamp shown" do
      fresh_build = DateTime.utc_now() |> DateTime.add(-1, :hour) |> DateTime.truncate(:second)

      {:ok, fake} =
        FakeClamd.start(
          script: [fn socket -> :gen_tcp.send(socket, "stream: OK\0") end],
          version_reply: FakeClamd.format_version_reply(fresh_build)
        )

      on_exit(fn -> FakeClamd.stop(fake) end)

      start_clamav!(address: {:tcp, "127.0.0.1", fake.port}, max_file_size_bytes: 1_000_000)
      assert %{healthy: true} = Nebu.Media.ClamAV.health_check()

      conn = sent_admin_conn("/admin/media/health")
      {:ok, _view, html} = live(conn)

      assert html =~ ~s(data-testid="clamav-status-connected")
      refute html =~ ~s(data-testid="clamav-down-since")
    end

    # ── AT2 ──────────────────────────────────────────────────────────────

    test "AT2: disconnected state renders a negative ClamAV status badge with a down-since timestamp" do
      port = closed_port!()

      start_clamav!(address: {:tcp, "127.0.0.1", port}, max_file_size_bytes: 1_000_000)

      conn = sent_admin_conn("/admin/media/health")
      {:ok, _view, html} = live(conn)

      assert html =~ ~s(data-testid="clamav-status-disconnected")
      assert html =~ ~s(data-testid="clamav-down-since")
    end

    # ── AT3 ──────────────────────────────────────────────────────────────

    test "AT3: fresh signature database (1h old) shows no staleness warning" do
      fresh_build = DateTime.utc_now() |> DateTime.add(-1, :hour) |> DateTime.truncate(:second)

      {:ok, fake} =
        FakeClamd.start(
          script: [fn socket -> :gen_tcp.send(socket, "stream: OK\0") end],
          version_reply: FakeClamd.format_version_reply(fresh_build)
        )

      on_exit(fn -> FakeClamd.stop(fake) end)

      start_clamav!(address: {:tcp, "127.0.0.1", fake.port}, max_file_size_bytes: 1_000_000)

      conn = sent_admin_conn("/admin/media/health")
      {:ok, _view, html} = live(conn)

      refute html =~ ~s(data-testid="clamav-signature-warning")
      assert html =~ "Signaturen aktuell"
    end

    # ── AT4 ──────────────────────────────────────────────────────────────

    test "AT4: stale signature database (72h old) shows a staleness warning" do
      stale_build = DateTime.utc_now() |> DateTime.add(-72, :hour) |> DateTime.truncate(:second)

      {:ok, fake} =
        FakeClamd.start(
          script: [fn socket -> :gen_tcp.send(socket, "stream: OK\0") end],
          version_reply: FakeClamd.format_version_reply(stale_build)
        )

      on_exit(fn -> FakeClamd.stop(fake) end)

      start_clamav!(address: {:tcp, "127.0.0.1", fake.port}, max_file_size_bytes: 1_000_000)

      conn = sent_admin_conn("/admin/media/health")
      {:ok, _view, html} = live(conn)

      assert html =~ ~s(data-testid="clamav-signature-warning")
      assert html =~ "Signaturen veraltet"
    end

    # ── AT6 ──────────────────────────────────────────────────────────────

    test "AT6: malformed/unparseable VERSION reply renders an unknown-age state, not a crash" do
      {:ok, fake} =
        FakeClamd.start(
          script: [fn socket -> :gen_tcp.send(socket, "stream: OK\0") end],
          version_reply: "garbage-not-a-version-reply\0"
        )

      on_exit(fn -> FakeClamd.stop(fake) end)

      start_clamav!(address: {:tcp, "127.0.0.1", fake.port}, max_file_size_bytes: 1_000_000)

      conn = sent_admin_conn("/admin/media/health")
      {:ok, _view, html} = live(conn)

      refute html =~ ~s(data-testid="clamav-signature-warning")
      assert html =~ "Alter unbekannt"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # media-security-admin-control/10c-media-alerts-triggers — Acceptance Test 10
  #
  # `Nebu.Media.Alerts.list_open/0` does not exist yet and
  # `Nebu.Admin.MediaHealthLive` has no open-alerts section wired into
  # `mount/3`/`render/1` — this test fails today with an
  # `UndefinedFunctionError` the moment the LiveView (once it exists in
  # implementation and calls `Nebu.Media.Alerts.list_open/0`) tries to mount,
  # or, once `Nebu.Media.Alerts` exists but the LiveView hasn't been wired
  # yet, on the plain absence of any `data-testid="media-alert-row-*"`
  # markup in the rendered page.
  #
  # Data-testid contract (this test's own design decision — the story does
  # not specify one, only the ordering/placement requirement): each open
  # alert row carries `data-testid="media-alert-row-#{id}"` so a test can
  # assert both presence/absence of a SPECIFIC alert and, via
  # `:binary.match/2` position comparison against the row markers, the
  # documented `critical` en-bloc-before-`warning`, most-recently-opened-first
  # ordering (AC4) — mirroring how AT8/AT9 in this same file assert on
  # `data-testid="current-hour-total"` etc. rather than parsing structured
  # HTML.
  # ══════════════════════════════════════════════════════════════════════════

  describe "10c: open alerts section" do
    defp clear_media_alerts! do
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

      Postgrex.query(conn, "DELETE FROM media_alerts", [])
    rescue
      _ -> :ok
    end

    defp insert_media_alert!(alert_type, severity, message, opened_at, resolved_at \\ nil) do
      %{rows: [[id]]} =
        Ecto.Adapters.SQL.query!(
          Repo,
          """
          INSERT INTO media_alerts
            (alert_type, severity, message, media_id, condition_metadata, opened_at, resolved_at)
          VALUES ($1, $2, $3, NULL, '{}'::jsonb, $4, $5)
          RETURNING id
          """,
          [alert_type, severity, message, opened_at, resolved_at]
        )

      id
    end

    setup do
      clear_media_alerts!()
      on_exit(fn -> clear_media_alerts!() end)
      :ok
    end

    test "AT10: dashboard renders open alerts above the metrics sections, critical before warning, most-recent first" do
      now = DateTime.utc_now()

      # Only ONE open row per alert_type can exist at a time (the partial
      # unique index) and `clamav_disconnected` is the only `critical`
      # alert_type in this story's fixed 4-type catalog — so a single open
      # critical row (rather than two, to exercise "most-recent-first
      # WITHIN critical") is what's seeded here; the "most-recent-first
      # within the same severity" ordering claim is instead exercised below
      # across the two `warning`-severity rows.
      critical =
        insert_media_alert!(
          "clamav_disconnected",
          "critical",
          "ClamAV unreachable",
          DateTime.add(now, -10, :minute)
        )

      warning_signature_stale =
        insert_media_alert!(
          "signature_stale",
          "warning",
          "Signature database is stale",
          DateTime.add(now, -3, :minute)
        )

      warning_backlog_older =
        insert_media_alert!(
          "backlog_depth",
          "warning",
          "Backlog depth exceeded",
          DateTime.add(now, -20, :minute)
        )

      resolved_scan_failed_rate =
        insert_media_alert!(
          "scan_failed_rate",
          "warning",
          "Scan failure rate spike (resolved)",
          DateTime.add(now, -30, :minute),
          now
        )

      conn = sent_admin_conn("/admin/media/health")
      {:ok, _view, html} = live(conn)

      assert html =~ ~s(data-testid="media-alert-row-#{critical}")
      assert html =~ ~s(data-testid="media-alert-row-#{warning_signature_stale}")
      assert html =~ ~s(data-testid="media-alert-row-#{warning_backlog_older}")
      refute html =~ ~s(data-testid="media-alert-row-#{resolved_scan_failed_rate}")

      {critical_pos, _} = :binary.match(html, "media-alert-row-#{critical}")
      {warn_signature_pos, _} = :binary.match(html, "media-alert-row-#{warning_signature_stale}")
      {warn_backlog_pos, _} = :binary.match(html, "media-alert-row-#{warning_backlog_older}")
      {throughput_pos, _} = :binary.match(html, "media-health-throughput-heading")

      # critical before warning
      assert critical_pos < warn_signature_pos
      assert critical_pos < warn_backlog_pos
      # most-recently-opened first within warning severity
      assert warn_signature_pos < warn_backlog_pos
      # alerts section renders above the 10a/10b metrics sections
      assert critical_pos < throughput_pos
    end

    test "AT10: no data-testid for open alerts renders when there are no open alerts" do
      conn = sent_admin_conn("/admin/media/health")
      {:ok, _view, html} = live(conn)

      refute html =~ ~s(data-testid="media-alert-row-)
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # media-security-admin-control/10e-trace-map-war-room-integration
  # (AC8/AC9) — "Live-Diagnose starten" jump-off point on an unresolved
  # `critical` `media_alerts` row.
  #
  # ## Markup/event contract this test file establishes (dev-story must match)
  #
  # None of the following exist in `Nebu.Admin.MediaHealthLive` yet — chosen
  # here per the story's own Technical Requirements, which pins the exact
  # `handle_event/3` clause shape:
  # `handle_event("start_media_diagnosis", %{"reason" => reason}, socket)`.
  # Since the event carries a `"reason"` param (pre-filled from the alert's
  # message, editable), the trigger is a `<form phx-submit=
  # "start_media_diagnosis" data-testid="start-media-diagnosis-form">`
  # containing a `name="reason"` input/textarea pre-filled with the
  # triggering alert's `message`, rendered next to each unresolved `critical`
  # alert row.
  #
  # ## Why these MUST FAIL right now
  #
  # `Nebu.Admin.MediaHealthLive` has no "Live-Diagnose starten" markup and no
  # `handle_event("start_media_diagnosis", ...)` clause at all today — every
  # test below fails on the missing `data-testid="start-media-diagnosis-form"`
  # element (a `Phoenix.LiveViewTest` "could not find element" ArgumentError
  # from `form/2`/`element/2`), not a compile error.
  # ══════════════════════════════════════════════════════════════════════════

  describe "10e AC8/AC9: Live-Diagnose starten jump-off point" do
    defp end_all_active_war_rooms! do
      if Process.whereis(Nebu.Repo) do
        Ecto.Adapters.SQL.query(
          Nebu.Repo,
          "UPDATE war_room_sessions SET ended_at = now(), ended_reason = 'manual_stop' " <>
            "WHERE ended_at IS NULL",
          []
        )
      end
    end

    setup do
      clear_media_alerts!()
      end_all_active_war_rooms!()

      on_exit(fn ->
        clear_media_alerts!()
        end_all_active_war_rooms!()
      end)

      :ok
    end

    defp insert_minimal_media_file!(media_id) do
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        INSERT INTO media_files
          (media_id, server_name, content_type, file_size, aes_key_hex, nonce_hex,
           uploader_user_id, uploaded_at, deleted, state)
        VALUES ($1, 'test.local', 'application/octet-stream', 1024, 'aeskeyhex', 'noncehex',
                '@uploader:test.local', $2, false, 'infected')
        """,
        [media_id, System.system_time(:millisecond)]
      )

      on_exit(fn ->
        Ecto.Adapters.SQL.query(Repo, "DELETE FROM media_files WHERE media_id = $1", [media_id])
      end)
    end

    # AC9 needs an open alert row carrying a NON-NULL media_id — the
    # pre-existing `insert_media_alert!/5` above (10c's own helper) always
    # hardcodes `media_id` to NULL in its INSERT and uses its 5th positional
    # argument for `resolved_at`, not `media_id`, so it cannot express this
    # shape. This dedicated helper does.
    defp insert_media_alert_with_media_id!(alert_type, severity, message, opened_at, media_id) do
      %{rows: [[id]]} =
        Ecto.Adapters.SQL.query!(
          Repo,
          """
          INSERT INTO media_alerts
            (alert_type, severity, message, media_id, condition_metadata, opened_at)
          VALUES ($1, $2, $3, $4, '{}'::jsonb, $5)
          RETURNING id
          """,
          [alert_type, severity, message, media_id, opened_at]
        )

      id
    end

    test "AC8: an unresolved critical alert renders a Live-Diagnose starten action that starts a media-domain-scoped War Room session and redirects to /admin/logs" do
      insert_media_alert!(
        "clamav_disconnected",
        "critical",
        "ClamAV unreachable more than 5 minutes",
        DateTime.utc_now()
      )

      conn = sent_admin_conn("/admin/media/health")
      {:ok, view, html} = live(conn)

      assert html =~ "Live-Diagnose starten"

      view
      |> form(
        "[data-testid='start-media-diagnosis-form']",
        %{"reason" => "ClamAV unreachable more than 5 minutes"}
      )
      |> render_submit()

      assert {:ok, session} = Nebu.Admin.WarRoomManager.status()

      assert session.scope == ["/media/clamav", "/media/scan_worker", "/admin/media"]
      refute is_nil(session.started_by)

      assert_redirect(view, "/admin/logs?war_room_id=#{session.id}")
    end

    test "AC8: a conflicting active War Room session surfaces the conflict message on the dashboard instead of redirecting" do
      insert_media_alert!(
        "clamav_disconnected",
        "critical",
        "ClamAV unreachable more than 5 minutes",
        DateTime.utc_now()
      )

      {:ok, _existing} =
        Nebu.Admin.WarRoomManager.start_session(%{
          started_by: "distinctive-media-health-test-other-admin",
          reason: "unrelated investigation",
          max_entries: 100,
          max_duration_s: 300
        })

      conn = sent_admin_conn("/admin/media/health")
      {:ok, view, _html} = live(conn)

      html =
        view
        |> form(
          "[data-testid='start-media-diagnosis-form']",
          %{"reason" => "ClamAV unreachable more than 5 minutes"}
        )
        |> render_submit()

      assert html =~ "War Room already active"

      # No navigation happened — the view is still mounted on this same page
      # and still shows the conflict message on a fresh render, proving this
      # wasn't a silent failure.
      refute_redirected(view, "/admin/logs")
      assert render(view) =~ "War Room already active"
    end

    test "AC9: an alert with a non-null media_id shows a text hint next to the action; a pipeline-wide alert shows none" do
      hinted_media_id = "medialive_health_10e_#{System.unique_integer([:positive])}"
      insert_minimal_media_file!(hinted_media_id)

      hinted_alert_id =
        insert_media_alert_with_media_id!(
          "scan_failed_rate",
          "warning",
          "Scan failure rate spike",
          DateTime.utc_now(),
          hinted_media_id
        )

      pipeline_alert_id =
        insert_media_alert!(
          "clamav_disconnected",
          "critical",
          "ClamAV unreachable more than 5 minutes",
          DateTime.utc_now()
        )

      conn = sent_admin_conn("/admin/media/health")
      {:ok, view, _html} = live(conn)

      hinted_row =
        view |> element("[data-testid='media-alert-row-#{hinted_alert_id}']") |> render()

      assert hinted_row =~ ~s(data-testid="media-alert-media-id-hint")
      assert hinted_row =~ hinted_media_id

      pipeline_row =
        view |> element("[data-testid='media-alert-row-#{pipeline_alert_id}']") |> render()

      refute pipeline_row =~ ~s(data-testid="media-alert-media-id-hint"),
             "a pipeline-wide alert (media_id nil) must show no media_id hint"
    end
  end
end
