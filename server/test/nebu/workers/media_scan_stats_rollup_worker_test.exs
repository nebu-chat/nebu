defmodule Nebu.Workers.MediaScanStatsRollupWorkerTest do
  @moduledoc """
  Acceptance tests for `Nebu.Workers.MediaScanStatsRollupWorker`
  (media-security-admin-control/10a-scan-stats-rollup, Acceptance Tests 1-7).

  Story: docs/stories/media-security-admin-control/10a-scan-stats-rollup.md

  ## Why real Postgres, not FakeRepo

  The rollup aggregation query needs `LEAD()`/`PERCENTILE_CONT` window
  functions and reads a `GENERATED ALWAYS` column (`scans_total`) — none of
  which a FakeRepo can meaningfully emulate. Every test here runs against a
  live PostgreSQL (`@moduletag :integration`), mirroring
  `media_cleanup_worker_integration_test.exs`'s real-DB convention
  (`Oban.Testing` + `perform_job/3` against `Nebu.Repo` directly — no seam
  swap for the worker's own `repo()`, since the worker's own SQL is exactly
  what is under test here).

  ## Isolation strategy — found necessary empirically, not part of the story's draft

  An EARLIER version of this file anchored every fixture to
  `MediaScanStatsRollupWorker.current_target_hour/0` (the real "previous
  complete hour") and hit consistent, reproducible off-by-one-or-more count
  drift: this codebase's full `:integration` suite takes several minutes and
  routinely straddles a real hour boundary, so unrelated tests elsewhere that
  drive the REAL `Nebu.Workers.MediaScanWorker`/`Nebu.Media.StateMachine` with
  default `NOW()` timestamps retroactively land inside whatever THIS worker
  later computes as "the previous hour" once the wall clock has moved on — a
  real-clock window is fundamentally not test-isolated in a long-running
  suite. Fixed by giving the worker an optional `%{"window_start" => iso8601}`
  job-arg override (see that module's own moduledoc) that every test below
  uses to target a FIXED, arbitrary historical hour, decoupled from real time
  entirely — this can never collide with real production data or with any
  other concurrently-running test, and each test in this file gets its own
  distinct hour so no two tests can collide with EACH OTHER either. The
  production cron entry (`{"5 * * * *", ...}`) always calls with `args: %{}`
  and is completely unaffected — it keeps using `current_target_hour/0`
  exactly as designed.

  `backlog_depth` (Acceptance Test 4) is the one metric that is NOT
  time-windowed at all (a live, unscoped `COUNT(*) FROM media_files WHERE
  state IN (...)`) — that test asserts a DELTA against a freshly-measured
  baseline rather than an absolute count, since concurrent unrelated tests may
  transiently leave rows in `:quarantined`/`:scanning` too.
  """

  use ExUnit.Case, async: false
  use Oban.Testing, repo: Nebu.Repo

  @moduletag :integration

  alias Nebu.Repo
  alias Nebu.Workers.MediaScanStatsRollupWorker

  @run_id Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)
          |> String.replace(["-", "_"], "a")

  # Arbitrary, far-past anchor — never collides with real production data or
  # with any real-time-driven test elsewhere in the suite. Each test below
  # picks its own distinct hour offset from this anchor so tests never
  # collide with EACH OTHER either.
  @anchor ~U[2020-06-15 10:00:00Z]

  setup do
    if Process.whereis(Nebu.Repo) == nil do
      flunk(
        "Nebu.Repo is not started — run with a live PostgreSQL (NEBU_DB_URL must be set), " <>
          "e.g. `make test-integration`"
      )
    end

    :ok
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Seeding / cleanup helpers
  # ══════════════════════════════════════════════════════════════════════════

  defp media_id(suffix), do: "mssr_#{@run_id}_#{suffix}"

  defp window_for(offset_hours), do: DateTime.add(@anchor, offset_hours, :hour)

  defp run_rollup!(window_start) do
    perform_job(MediaScanStatsRollupWorker, %{"window_start" => DateTime.to_iso8601(window_start)})
  end

  defp insert_media_file!(media_id, state) do
    Ecto.Adapters.SQL.query!(
      Repo,
      """
      INSERT INTO media_files
        (media_id, server_name, content_type, file_size, aes_key_hex, nonce_hex,
         uploader_user_id, uploaded_at, deleted, state, storage_key, file_hash)
      VALUES ($1, 'test.local', 'application/octet-stream', 1024, 'aeskeyhex', 'noncehex',
              '@tester:test.local', $2, false, $3, $1, 'deadbeef')
      """,
      [media_id, System.system_time(:millisecond), Atom.to_string(state)]
    )
  end

  defp insert_transition!(media_id, from_state, to_state, %DateTime{} = inserted_at) do
    Ecto.Adapters.SQL.query!(
      Repo,
      """
      INSERT INTO media_state_transitions
        (media_id, from_state, to_state, actor_type, actor_id, metadata, inserted_at)
      VALUES ($1, $2, $3, 'system', NULL, '{}', $4)
      """,
      [media_id, from_state && Atom.to_string(from_state), Atom.to_string(to_state), inserted_at]
    )
  end

  defp fetch_stats_row(window_start) do
    case Ecto.Adapters.SQL.query!(
           Repo,
           """
           SELECT scans_released, scans_infected, scans_failed, scans_total,
                  avg_scan_duration_ms, p95_scan_duration_ms, backlog_depth
             FROM media_scan_stats
            WHERE window_start = $1
           """,
           [window_start]
         ) do
      %{rows: [[released, infected, failed, total, avg_ms, p95_ms, backlog]]} ->
        %{
          scans_released: released,
          scans_infected: infected,
          scans_failed: failed,
          scans_total: total,
          avg_scan_duration_ms: avg_ms,
          p95_scan_duration_ms: p95_ms,
          backlog_depth: backlog
        }

      %{rows: []} ->
        nil
    end
  end

  defp count_stats_rows(window_start) do
    %{rows: [[count]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT COUNT(*) FROM media_scan_stats WHERE window_start = $1",
        [window_start]
      )

    count
  end

  defp backlog_baseline! do
    %{rows: [[count]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT COUNT(*) FROM media_files WHERE state IN ('quarantined', 'scanning')",
        []
      )

    count
  end

  # ADR-031's append-only trigger rejects UPDATE/DELETE for every role,
  # including the table owner — same migrate-role dance
  # media_cleanup_worker_integration_test.exs already established for
  # touching media_state_transitions rows in tests.
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

  defp cleanup_media_ids!(media_ids) do
    conn = migrate_role_conn!()

    try do
      Postgrex.query!(
        conn,
        "ALTER TABLE media_state_transitions DISABLE TRIGGER media_state_transitions_no_mutate",
        []
      )

      Postgrex.query(conn, "DELETE FROM media_state_transitions WHERE media_id = ANY($1)", [
        media_ids
      ])

      Postgrex.query(conn, "DELETE FROM media_files WHERE media_id = ANY($1)", [media_ids])
    after
      Postgrex.query!(
        conn,
        "ALTER TABLE media_state_transitions ENABLE TRIGGER media_state_transitions_no_mutate",
        []
      )
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AT1: released/infected/scan_failed counts
  # ══════════════════════════════════════════════════════════════════════════

  test "rollup aggregates scans_released/scans_infected/scans_failed correctly for a fixture with known outcomes" do
    window_start = window_for(0)
    ts = DateTime.add(window_start, 5, :minute)

    released_ids = for n <- 1..5, do: media_id("at1_released_#{n}")
    infected_ids = for n <- 1..2, do: media_id("at1_infected_#{n}")
    failed_id = media_id("at1_failed_1")
    all_ids = released_ids ++ infected_ids ++ [failed_id]

    on_exit(fn -> cleanup_media_ids!(all_ids) end)

    Enum.each(released_ids, fn id ->
      insert_media_file!(id, :released)
      insert_transition!(id, :scanning, :released, ts)
    end)

    Enum.each(infected_ids, fn id ->
      insert_media_file!(id, :infected)
      insert_transition!(id, :scanning, :infected, ts)
    end)

    insert_media_file!(failed_id, :scan_failed)
    insert_transition!(failed_id, :quarantined, :scan_failed, ts)

    assert :ok = run_rollup!(window_start)

    row = fetch_stats_row(window_start)
    assert row.scans_released == 5
    assert row.scans_infected == 2
    assert row.scans_failed == 1
    assert row.scans_total == 8
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AT2: avg/p95 duration from paired :scanning-entry -> terminal timestamps
  # ══════════════════════════════════════════════════════════════════════════

  test "rollup computes avg_scan_duration_ms and p95_scan_duration_ms from paired :scanning-entry to terminal-transition timestamps" do
    window_start = window_for(1)
    start_ts = DateTime.add(window_start, 2, :minute)

    # 10 hand-picked duration samples: 1000ms, 2000ms, ..., 10000ms.
    deltas_ms = for n <- 1..10, do: n * 1000
    ids = for n <- 1..10, do: media_id("at2_#{n}")

    on_exit(fn -> cleanup_media_ids!(ids) end)

    ids
    |> Enum.zip(deltas_ms)
    |> Enum.each(fn {id, delta_ms} ->
      insert_media_file!(id, :released)
      insert_transition!(id, :quarantined, :scanning, start_ts)
      insert_transition!(id, :scanning, :released, DateTime.add(start_ts, delta_ms, :millisecond))
    end)

    assert :ok = run_rollup!(window_start)

    row = fetch_stats_row(window_start)

    expected_avg = round(Enum.sum(deltas_ms) / length(deltas_ms))
    assert row.avg_scan_duration_ms == expected_avg

    # Postgres PERCENTILE_CONT(0.95) linear-interpolation, computed the same
    # way here: rank = 0.95 * (n - 1) on the 0-indexed sorted sample.
    sorted = Enum.sort(deltas_ms)
    n = length(sorted)
    rank = 0.95 * (n - 1)
    lo = trunc(rank)
    frac = rank - lo
    lo_val = Enum.at(sorted, lo)
    hi_val = Enum.at(sorted, min(lo + 1, n - 1))
    expected_p95 = round(lo_val + frac * (hi_val - lo_val))

    assert row.p95_scan_duration_ms == expected_p95
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AT3: scan_failed excluded from duration stats, included in scans_total
  # ══════════════════════════════════════════════════════════════════════════

  test "scan_failed transitions are excluded from duration statistics but included in scans_total" do
    window_start = window_for(2)
    ts = DateTime.add(window_start, 3, :minute)

    # Mirrors the REAL Nebu.Workers.MediaScanWorker.scan_error/4 flow: a
    # :scanning entry immediately followed by a retry-:quarantined transition
    # (not a terminal one), then finally :quarantined -> :scan_failed once
    # retries are exhausted. The duration CTE's LEAD sees :quarantined (not
    # :released/:infected) as the scanning entry's NEXT transition, so this
    # sample is correctly excluded without any special-casing.
    failed_id = media_id("at3_failed")

    on_exit(fn -> cleanup_media_ids!([failed_id]) end)

    insert_media_file!(failed_id, :scan_failed)
    insert_transition!(failed_id, :quarantined, :scanning, ts)
    insert_transition!(failed_id, :scanning, :quarantined, DateTime.add(ts, 500, :millisecond))
    insert_transition!(failed_id, :quarantined, :scan_failed, DateTime.add(ts, 600, :millisecond))

    assert :ok = run_rollup!(window_start)

    row = fetch_stats_row(window_start)
    assert row.scans_failed == 1
    assert row.scans_total == 1
    assert row.avg_scan_duration_ms == nil
    assert row.p95_scan_duration_ms == nil
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AT4: backlog_depth — point-in-time snapshot, not time-windowed
  # ══════════════════════════════════════════════════════════════════════════

  test "backlog_depth is a point-in-time snapshot of quarantined + scanning media_files rows at rollup time" do
    window_start = window_for(3)
    baseline = backlog_baseline!()

    q_ids = for n <- 1..3, do: media_id("at4_q_#{n}")
    s_ids = for n <- 1..2, do: media_id("at4_s_#{n}")
    r_ids = for n <- 1..2, do: media_id("at4_r_#{n}")
    all_ids = q_ids ++ s_ids ++ r_ids

    on_exit(fn -> cleanup_media_ids!(all_ids) end)

    Enum.each(q_ids, &insert_media_file!(&1, :quarantined))
    Enum.each(s_ids, &insert_media_file!(&1, :scanning))
    Enum.each(r_ids, &insert_media_file!(&1, :released))

    assert :ok = run_rollup!(window_start)

    row = fetch_stats_row(window_start)
    # Delta against a freshly-measured baseline (not an absolute count) — this
    # query is deliberately NOT time-windowed/media_id-scoped, so concurrent
    # unrelated tests may transiently hold their own :quarantined/:scanning rows.
    assert row.backlog_depth - baseline == 5
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AT5: hour-boundary exclusion
  # ══════════════════════════════════════════════════════════════════════════

  test "transitions outside the target hour window are excluded (boundary test)" do
    window_start = window_for(4)

    before_id = media_id("at5_before")
    after_id = media_id("at5_after")

    on_exit(fn -> cleanup_media_ids!([before_id, after_id]) end)

    insert_media_file!(before_id, :released)
    insert_transition!(before_id, :scanning, :released, DateTime.add(window_start, -1, :second))

    insert_media_file!(after_id, :released)

    insert_transition!(
      after_id,
      :scanning,
      :released,
      DateTime.add(window_start, 1, :hour)
    )

    assert :ok = run_rollup!(window_start)

    row = fetch_stats_row(window_start)
    assert row.scans_released == 0
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AT6: idempotent re-run
  # ══════════════════════════════════════════════════════════════════════════

  test "rollup is idempotent: running the worker twice for the same hour produces exactly one media_scan_stats row with identical values, not a duplicate" do
    window_start = window_for(5)
    ts = DateTime.add(window_start, 5, :minute)

    ids = for n <- 1..3, do: media_id("at6_#{n}")
    on_exit(fn -> cleanup_media_ids!(ids) end)

    Enum.each(ids, fn id ->
      insert_media_file!(id, :released)
      insert_transition!(id, :scanning, :released, ts)
    end)

    assert :ok = run_rollup!(window_start)
    assert count_stats_rows(window_start) == 1
    row1 = fetch_stats_row(window_start)

    assert :ok = run_rollup!(window_start)
    assert count_stats_rows(window_start) == 1
    row2 = fetch_stats_row(window_start)

    assert row1 == row2
    assert row2.scans_released == 3
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AT7: zero-activity hour
  # ══════════════════════════════════════════════════════════════════════════

  test "an hour with zero scan activity produces a row with all counts 0 and NULL duration stats, not an error" do
    window_start = window_for(6)

    assert :ok = run_rollup!(window_start)

    row = fetch_stats_row(window_start)
    assert row.scans_total == 0
    assert row.avg_scan_duration_ms == nil
    assert row.p95_scan_duration_ms == nil
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Regression guard: the production cron path (args: %{}) still uses the
  # real "previous complete hour" — not covered by the fixed-anchor tests
  # above, which all exercise the test-only override seam instead.
  # ══════════════════════════════════════════════════════════════════════════

  test "perform/1 with empty args (the real cron invocation) targets current_target_hour/0, not a fixed window" do
    window_start = MediaScanStatsRollupWorker.current_target_hour()

    assert :ok = perform_job(MediaScanStatsRollupWorker, %{})

    # Just proves the row lands at the REAL current-target-hour window — the
    # exact counts are not asserted here (unlike the fixed-anchor tests
    # above, this window is NOT isolated from the rest of the real-time
    # suite), only that perform/1 with no override arg still computes and
    # upserts a row for the correct, real window.
    assert count_stats_rows(window_start) >= 0
    refute is_nil(fetch_stats_row(window_start))
  end
end
