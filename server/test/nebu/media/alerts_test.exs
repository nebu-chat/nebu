defmodule Nebu.Media.AlertsTest do
  @moduledoc """
  RED-phase acceptance tests for `Nebu.Media.Alerts.list_open/0`
  (media-security-admin-control/10c-media-alerts-triggers) — the public
  read seam (ADR-020) the `/admin/media/health` dashboard LiveView calls
  instead of querying `media_alerts` directly (mirrors `Nebu.Media.Config.get/0`'s
  "one seam, no raw queries from callers" precedent, per this story's own
  Technical Requirements / Dashboard integration section).

  Story: docs/stories/media-security-admin-control/10c-media-alerts-triggers.md

  ## Why every test here fails right now (RED phase)

  `Nebu.Media.Alerts` does not exist yet — every test below fails with an
  `UndefinedFunctionError` (`Nebu.Media.Alerts.list_open/0 is undefined`).
  This requires no live Postgres connection to observe (a straight module
  lookup failure), though the fixture-seeding helpers below do need
  `NEBU_DB_URL` once the module exists and this file's own assertions start
  driving the GREEN implementation.

  ## Contract asserted here (this file's own reasonable reading of the
  story's `SELECT * FROM media_alerts WHERE resolved_at IS NULL ORDER BY
  severity, opened_at DESC` — a `CASE severity WHEN 'critical' THEN 0 ELSE 1
  END` ordering, per the Technical Requirements' "Dashboard integration"
  section):

    * Returns a list of maps (or structs — these tests only touch `.id`,
      matching field access syntax either shape satisfies) with at least an
      `:id` field, one entry per OPEN (`resolved_at IS NULL`) row.
    * Resolved rows (`resolved_at` set) are never included.
    * `critical` rows sort before `warning` rows.
    * Within the same severity, most-recently-`opened_at` sorts first.
    * Returns `[]` (not `nil`, not an error tuple) when there are no open
      alerts.

  ## Fixture note: only one OPEN row per `alert_type` at a time

  `media_alerts`'s partial unique index (`(alert_type, COALESCE(media_id,
  sentinel)) WHERE resolved_at IS NULL`) allows at most one open row per
  `alert_type`. Since only `clamav_disconnected` is `critical` in this
  story's fixed 4-type catalog, the "most-recent-first within the same
  severity" test below uses two of the three `warning`-severity types
  (`backlog_depth`, `scan_failed_rate`) rather than two rows of the same
  type, to stay clear of that constraint.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  alias Nebu.Repo
  alias Nebu.Media.Alerts

  setup do
    if Process.whereis(Nebu.Repo) == nil do
      flunk(
        "Nebu.Repo is not started — run with a live PostgreSQL (NEBU_DB_URL must be set), " <>
          "e.g. `make test-integration`"
      )
    end

    clear_media_alerts!()
    on_exit(fn -> clear_media_alerts!() end)

    :ok
  end

  # media_alerts grants no DELETE to nebu_app (this story's own migration) —
  # cleanup goes through the migrate role, same pattern
  # media_scan_stats_rollup_worker_test.exs uses for media_state_transitions.
  # Tolerant of the table not existing yet (pre-migration RED phase).
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

  defp insert_alert!(alert_type, severity, message, opened_at, resolved_at \\ nil) do
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

  # ══════════════════════════════════════════════════════════════════════════

  test "list_open/0 returns an empty list when there are no open alerts" do
    assert Alerts.list_open() == []
  end

  test "list_open/0 excludes alerts that have been resolved" do
    open_id = insert_alert!("clamav_disconnected", "critical", "still down", DateTime.utc_now())

    _resolved_id =
      insert_alert!(
        "signature_stale",
        "warning",
        "was stale, now fixed",
        DateTime.utc_now(),
        DateTime.utc_now()
      )

    ids = Alerts.list_open() |> Enum.map(& &1.id)
    assert ids == [open_id]
  end

  test "list_open/0 orders critical alerts before warning alerts" do
    warn_id = insert_alert!("signature_stale", "warning", "stale", DateTime.utc_now())
    crit_id = insert_alert!("clamav_disconnected", "critical", "down", DateTime.utc_now())

    ids = Alerts.list_open() |> Enum.map(& &1.id)
    assert ids == [crit_id, warn_id]
  end

  test "list_open/0 orders most-recently-opened first within the same severity" do
    older_id =
      insert_alert!(
        "backlog_depth",
        "warning",
        "old backlog spike",
        DateTime.add(DateTime.utc_now(), -10, :minute)
      )

    newer_id =
      insert_alert!("scan_failed_rate", "warning", "fresh error spike", DateTime.utc_now())

    ids = Alerts.list_open() |> Enum.map(& &1.id)
    assert ids == [newer_id, older_id]
  end

  test "list_open/0 combines severity-then-recency ordering across a mixed set" do
    old_warning =
      insert_alert!(
        "backlog_depth",
        "warning",
        "old warning",
        DateTime.add(DateTime.utc_now(), -30, :minute)
      )

    new_warning =
      insert_alert!(
        "scan_failed_rate",
        "warning",
        "new warning",
        DateTime.add(DateTime.utc_now(), -5, :minute)
      )

    critical =
      insert_alert!(
        "clamav_disconnected",
        "critical",
        "critical",
        DateTime.add(DateTime.utc_now(), -60, :minute)
      )

    ids = Alerts.list_open() |> Enum.map(& &1.id)
    assert ids == [critical, new_warning, old_warning]
  end
end
