defmodule Nebu.Admin.TemporaryCaptureManagerTest do
  @moduledoc """
  RED-phase ATDD tests for `enhanced-logging/trace-map-node-controls` — the
  DB-backed `Nebu.Admin.TemporaryCaptureManager` public API (AC4, AC5,
  AC12), the cluster-safe capture timer of the story's ANSWERED design
  question 1: "state is a row, expiry is a comparison against now() — no
  process timer owns correctness" (the `Nebu.Admin.WarRoomManager`
  precedent, ADR-018/020: a pure-functional, inline-SQL Admin-domain
  module).

  Story: docs/stories/enhanced-logging/trace-map-node-controls.md

  Pure comparisons (`expired?/2`, `remaining_seconds/2`,
  `capture_duration_s/0`, the DB-free `active?/1` guard) are pinned in
  `logs_live/trace_map_node_controls_contract_test.exs`; this file is the
  genuinely-DB half and is `:integration`-tagged throughout (runs under
  `make test-integration` only, mirroring war_room_manager's own tests).

  ## Why these MUST FAIL right now

  Neither `Nebu.Admin.TemporaryCaptureManager` nor the
  `admin_temporary_captures` table (expected migration:
  `server/priv/migrations/000020_admin_temporary_captures.{up,down}.sql`,
  next sequential number after 000019_war_room_sessions) exists yet.

  ## API contract pinned here

    * `enable(endpoint, started_by)` -> `{:ok, capture}` — inserts the row
      (`endpoint` is the primary key: at most one active capture per
      endpoint, story Dev Notes schema) with `expires_at = enabled_at +
      capture_duration_s()` and returns the capture map
      (`%{endpoint:, enabled_at:, expires_at:, started_by:}`).
    * `disable(endpoint)` -> `:ok` (capture ended) or
      `{:error, :not_found}` (no active capture — a safe no-op error,
      never a crash; the war_room stop_session/1 shape).
    * `active?(endpoint)` -> whether a NON-EXPIRED row exists; an expired
      row still sitting in the table (cleanup hasn't run yet) counts as
      inactive — expiry is the `expires_at > now()` comparison, NOT the
      row's presence.
    * `active_captures/0` -> all non-expired captures.
    * `cleanup_expired/0` -> deletes expired rows, leaves active ones (the
      periodic sweeper's work function — story Dev Notes item 3).
    * AC12 Option B (ANSWERED design question 2): `enable/2` and
      `disable/1` write compliance audit entries via
      `Nebu.Compliance.AuditWriter` — `action:
      "enable_temporary_capture"` / `"disable_temporary_capture"`,
      `target_type: "endpoint"`, `target_id: <endpoint>`, actor = the
      admin who acted (retention-settings' audit precedent).
    * AC4: `Nebu.Web.LogStore.should_persist?/2` flips to the level-only
      policy for an off-list route's NOISE levels (debug/info/warn) WHILE
      its capture is active, and back to `false` after disable. ERROR is
      exempt from the flip entirely — always persisted (story amendment
      2026-07-07, errors-always-persist).
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  alias Nebu.Admin.TemporaryCaptureManager

  @endpoint_route "/health"

  setup do
    Nebu.Release.migrate()

    Ecto.Adapters.SQL.query!(Nebu.Repo, "DELETE FROM admin_temporary_captures", [])

    Ecto.Adapters.SQL.query!(
      Nebu.Repo,
      "DELETE FROM audit_log WHERE action IN ('enable_temporary_capture', 'disable_temporary_capture')",
      []
    )

    :ok
  end

  defp insert_capture(endpoint, enabled_offset_sql, expires_offset_sql, started_by) do
    Ecto.Adapters.SQL.query!(
      Nebu.Repo,
      "INSERT INTO admin_temporary_captures (endpoint, enabled_at, expires_at, started_by) " <>
        "VALUES ($1, now() #{enabled_offset_sql}, now() #{expires_offset_sql}, $2)",
      [endpoint, started_by]
    )
  end

  defp capture_rows(endpoint) do
    Ecto.Adapters.SQL.query!(
      Nebu.Repo,
      "SELECT endpoint, started_by FROM admin_temporary_captures WHERE endpoint = $1",
      [endpoint]
    ).rows
  end

  defp audit_rows(action) do
    Ecto.Adapters.SQL.query!(
      Nebu.Repo,
      "SELECT actor_user_id, target_type, target_id FROM audit_log WHERE action = $1",
      [action]
    ).rows
  end

  describe "AC5: enable/2 — the DB row is the timer" do
    test "inserts one row with expires_at = enabled_at + configured duration" do
      Application.put_env(:nebu, :temporary_capture_duration_s, 60)
      on_exit(fn -> Application.delete_env(:nebu, :temporary_capture_duration_s) end)

      assert {:ok, capture} = TemporaryCaptureManager.enable(@endpoint_route, "@admin:test.local")

      assert capture.endpoint == @endpoint_route
      assert capture.started_by == "@admin:test.local"
      assert %DateTime{} = capture.enabled_at
      assert %DateTime{} = capture.expires_at

      assert_in_delta DateTime.diff(capture.expires_at, capture.enabled_at, :second), 60, 2

      assert [[@endpoint_route, "@admin:test.local"]] = capture_rows(@endpoint_route)
    end

    test "active?/1 and active_captures/0 see the enabled capture" do
      {:ok, _capture} = TemporaryCaptureManager.enable(@endpoint_route, "@admin:test.local")

      assert TemporaryCaptureManager.active?(@endpoint_route)
      refute TemporaryCaptureManager.active?("/admin/keepalive")

      actives = TemporaryCaptureManager.active_captures()
      assert Enum.any?(actives, &(&1.endpoint == @endpoint_route))
    end

    test "an expired row is NOT active — presence is not the state, the comparison is" do
      insert_capture(@endpoint_route, "- interval '10 minutes'", "- interval '5 minutes'", "stale")

      refute TemporaryCaptureManager.active?(@endpoint_route),
             "AC5: an expired row (cleanup pending) must never count as an active capture"

      assert TemporaryCaptureManager.active_captures() == []
    end
  end

  describe "AC5: disable/1 — early end" do
    test "disable ends an active capture; a second disable is {:error, :not_found}" do
      {:ok, _capture} = TemporaryCaptureManager.enable(@endpoint_route, "@admin:test.local")

      assert :ok = TemporaryCaptureManager.disable(@endpoint_route)
      refute TemporaryCaptureManager.active?(@endpoint_route)

      assert {:error, :not_found} = TemporaryCaptureManager.disable(@endpoint_route)
    end
  end

  describe "AC5: cleanup_expired/0 — the periodic sweeper's work function" do
    test "deletes expired rows and leaves active ones untouched" do
      insert_capture("/admin/keepalive", "- interval '10 minutes'", "- interval '5 minutes'", "stale")
      insert_capture(@endpoint_route, "", "+ interval '1 hour'", "fresh")

      TemporaryCaptureManager.cleanup_expired()

      assert capture_rows("/admin/keepalive") == [],
             "the expired row must be swept"

      assert [[@endpoint_route, "fresh"]] = capture_rows(@endpoint_route),
             "the active row must survive the sweep"
    end
  end

  describe "AC12 (Option B): enable/disable write compliance audit entries" do
    test "enable/2 records an enable_temporary_capture audit row naming actor and endpoint" do
      {:ok, _capture} = TemporaryCaptureManager.enable(@endpoint_route, "@admin:test.local")

      assert [["@admin:test.local", "endpoint", @endpoint_route]] =
               audit_rows("enable_temporary_capture"),
             "AC12: enabling collection on an off endpoint is an admin-initiated " <>
               "logging-policy change and must be audit-logged (retention-settings precedent)"
    end

    test "disable/1 records a disable_temporary_capture audit row" do
      {:ok, _capture} = TemporaryCaptureManager.enable(@endpoint_route, "@admin:test.local")
      :ok = TemporaryCaptureManager.disable(@endpoint_route)

      assert [[_actor, "endpoint", @endpoint_route]] = audit_rows("disable_temporary_capture")
    end
  end

  describe "AC4: should_persist?/2 flips with the capture lifecycle" do
    # Probe level is "warning", NOT "error": per the story amendment
    # 2026-07-07 (errors-always-persist), ERROR on an off route is true
    # regardless of capture state, so only a noise level can demonstrate
    # the capture-driven flip. "warning" is the /1 catch-all (always true
    # at level policy), so every transition below is attributable to the
    # off-list/capture branch alone.
    test "an off-list route persists noise levels exactly while its capture is active" do
      refute Nebu.Web.LogStore.should_persist?("warning", @endpoint_route),
             "precondition: off and uncaptured -> noise levels are not persisted"

      {:ok, _capture} = TemporaryCaptureManager.enable(@endpoint_route, "@admin:test.local")

      assert Nebu.Web.LogStore.should_persist?("warning", @endpoint_route),
             "AC5: while capture is active, the policy check skips the off-list"

      :ok = TemporaryCaptureManager.disable(@endpoint_route)

      refute Nebu.Web.LogStore.should_persist?("warning", @endpoint_route),
             "AC5: after disable the endpoint reverts to off-tier enforcement"
    end

    test "ERROR persists on the off route regardless of capture state (amendment 2026-07-07)" do
      assert Nebu.Web.LogStore.should_persist?("error", @endpoint_route),
             "errors-always-persist: no capture needed"

      {:ok, _capture} = TemporaryCaptureManager.enable(@endpoint_route, "@admin:test.local")
      assert Nebu.Web.LogStore.should_persist?("error", @endpoint_route)

      :ok = TemporaryCaptureManager.disable(@endpoint_route)
      assert Nebu.Web.LogStore.should_persist?("error", @endpoint_route)
    end
  end
end
