defmodule Nebu.Web.LogStore.RetentionTest do
  @moduledoc """
  RED-phase ATDD tests for `enhanced-logging/operational-log-store` (AC8 —
  retention pruning via the Sweeper extension).

  Story: docs/stories/enhanced-logging/operational-log-store.md

  ## Why these MUST FAIL right now

  `Nebu.Web.LogStore.Retention` (server/lib/nebu/web/log_store/retention.ex)
  does not exist yet, and `operational_logs` does not exist yet either. Every
  test here either fails to resolve `Nebu.Web.LogStore.Retention.*` at
  runtime (`UndefinedFunctionError`) or fails against a real Postgres because
  the table it prunes does not exist.

  Kept in its own file (rather than folded into log_store_test.exs) because
  it needs its own Sweeper-shaped setup: seeding rows with an EXPLICIT past
  `inserted_at` (not `now()`) to simulate age, which none of the other
  operational_logs tests need.
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  setup do
    Nebu.Release.migrate()

    # Defensive reset — NOT relying on the on_exit DELETEs below actually
    # working. `server_config` has FORCE ROW LEVEL SECURITY and (by design;
    # no production code path ever deletes a config row) NO policy permits
    # DELETE for any key, so every `DELETE FROM server_config WHERE key = ...`
    # below silently affects 0 rows — a stale value set by an EARLIER test
    # (in this file, or another file sharing the same live Nebu.Repo
    # connection within one `mix test` run) otherwise leaks forward and
    # breaks a later test's "this key is unset" assumption (e.g. the
    # WARN/ERROR safety-net test below, which must see a genuinely absent
    # `log_retention_info_days`). UPSERT-ing each key to the neutral "no
    # limit" value ("" reads back as `nil` via `Nebu.Web.LogStore.to_int/1`)
    # IS permitted by the `config_update_mutable` RLS policy (unlike
    # DELETE), so this reliably re-establishes a clean baseline before every
    # test in this file. Tests that need a specific value still set it
    # explicitly afterward (an UPDATE, which works).
    #
    # ALSO forces `log_collect_info`/`log_collect_debug` to "false" here:
    # this file's own tests seed exact row counts (e.g. exactly 500 kept
    # after a max-count cap) directly via raw SQL INSERTs, entirely
    # independent of the live `Nebu.Web.LogStore.Handler`/`Writer` pipeline.
    # But that pipeline IS shared, process-wide, with every OTHER test file
    # in the same `mix test` run (e.g. `logs_controller_test.exs`, which
    # legitimately flips these same two flags on/off many times as part of
    # its own ATDD coverage) — if either flag is left `true` when THIS
    # file's tests run, any incidental `Logger.info/1`/`Logger.debug/1` call
    # firing ANYWHERE in the app during that window (the Writer batches
    # asynchronously, so timing is not tightly coupled to which test
    # triggered the log call) gets genuinely persisted to
    # `operational_logs`, silently inflating the level's row count and
    # breaking this file's exact-count assertions. Forcing both off here
    # removes that shared-fixture cross-file hazard for this file's own
    # synthetic-dataset tests.
    Nebu.Admin.DB.upsert_server_config(%{
      "log_collect_info" => "false",
      "log_collect_debug" => "false",
      "log_retention_info_days" => "",
      "log_retention_debug_days" => "",
      "log_retention_info_max_count" => "",
      "log_retention_debug_max_count" => ""
    })

    on_exit(fn ->
      Ecto.Adapters.SQL.query(
        Nebu.Repo,
        "DELETE FROM operational_logs WHERE message LIKE 'distinctive-retention-%'",
        []
      )

      Ecto.Adapters.SQL.query(Nebu.Repo, "DELETE FROM server_config WHERE key = $1", [
        "log_retention_info_days"
      ])

      Ecto.Adapters.SQL.query(Nebu.Repo, "DELETE FROM server_config WHERE key = $1", [
        "log_retention_debug_max_count"
      ])

      Ecto.Adapters.SQL.query(Nebu.Repo, "DELETE FROM server_config WHERE key = $1", [
        "log_retention_info_max_count"
      ])

      Ecto.Adapters.SQL.query(
        Nebu.Repo,
        "DELETE FROM operational_logs WHERE message LIKE 'distinctive-warnerror-%' OR message LIKE 'distinctive-infocap-%'",
        []
      )

      Ecto.Adapters.SQL.query(
        Nebu.Repo,
        "DELETE FROM war_room_sessions WHERE reason LIKE 'distinctive-retention-warroom-%'",
        []
      )
    end)

    :ok
  end

  defp insert_log(level, message, age_days) do
    Ecto.Adapters.SQL.query!(
      Nebu.Repo,
      """
      INSERT INTO operational_logs (level, source, message, inserted_at)
      VALUES ($1, 'test', $2, now() - ($3 || ' days')::interval)
      """,
      [level, message, to_string(age_days)]
    )
  end

  # Safety-net-for-war-room-tagged-rows tests below need a real
  # war_room_sessions row to satisfy operational_logs.war_room_id's FK
  # constraint (000019_war_room_sessions.up.sql) — a bare random UUID would
  # raise a foreign-key-violation Postgrex.Error on INSERT.
  defp insert_war_room_session do
    result =
      Ecto.Adapters.SQL.query!(
        Nebu.Repo,
        """
        INSERT INTO war_room_sessions (started_by, reason, max_entries, max_duration_s, ended_at)
        VALUES ('test-admin', 'distinctive-retention-warroom-fixture', 1000, 3600, now())
        RETURNING id
        """,
        []
      )

    [[id]] = result.rows
    id
  end

  defp insert_war_room_log(level, message, age_days, war_room_id) do
    Ecto.Adapters.SQL.query!(
      Nebu.Repo,
      """
      INSERT INTO operational_logs (level, source, message, inserted_at, war_room_id)
      VALUES ($1, 'test', $2, now() - ($3 || ' days')::interval, $4)
      """,
      [level, message, to_string(age_days), war_room_id]
    )
  end

  defp remaining_messages(pattern) do
    Ecto.Adapters.SQL.query!(
      Nebu.Repo,
      "SELECT message FROM operational_logs WHERE message LIKE $1",
      [pattern]
    )
    |> Map.fetch!(:rows)
    |> List.flatten()
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC8 — per-level day-based TTL pruning
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC8: TTL-based retention pruning" do
    test "INFO entries older than log_retention_info_days are deleted; newer INFO and all WARN/ERROR entries survive" do
      insert_log("info", "distinctive-retention-info-old-10d", 10)
      insert_log("info", "distinctive-retention-info-fresh-1d", 1)
      insert_log("warning", "distinctive-retention-warn-old-10d", 10)
      insert_log("error", "distinctive-retention-error-old-10d", 10)

      Nebu.Admin.DB.upsert_server_config(%{"log_retention_info_days" => "7"})

      assert :ok = Nebu.Web.LogStore.Retention.prune_operational_logs()

      remaining = remaining_messages("distinctive-retention-%")

      refute "distinctive-retention-info-old-10d" in remaining,
             "an INFO entry older than the 7-day TTL must be pruned"

      assert "distinctive-retention-info-fresh-1d" in remaining,
             "an INFO entry younger than the TTL must survive"

      assert "distinctive-retention-warn-old-10d" in remaining,
             "WARN entries must never be pruned by the INFO TTL clause"

      assert "distinctive-retention-error-old-10d" in remaining,
             "ERROR entries must never be pruned by the INFO TTL clause"
    end

    test "running prune_operational_logs/0 twice in a row is idempotent (no error, no further deletions on the second run)" do
      insert_log("info", "distinctive-retention-idempotent-old-10d", 10)
      Nebu.Admin.DB.upsert_server_config(%{"log_retention_info_days" => "7"})

      assert :ok = Nebu.Web.LogStore.Retention.prune_operational_logs()
      assert :ok = Nebu.Web.LogStore.Retention.prune_operational_logs()

      remaining = remaining_messages("distinctive-retention-idempotent-%")
      assert remaining == []
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC8 — DEBUG max-count cap
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC8: DEBUG max-count cap" do
    test "1000 DEBUG entries capped to log_retention_debug_max_count=500 leaves only the 500 most recent" do
      Ecto.Adapters.SQL.query!(
        Nebu.Repo,
        """
        INSERT INTO operational_logs (level, source, message, inserted_at)
        SELECT 'debug', 'test', 'distinctive-retention-debugcap-' || gs,
               now() - (gs * interval '1 second')
        FROM generate_series(1, 1000) AS gs
        """,
        []
      )

      # A handful of non-DEBUG rows must be UNAFFECTED by the DEBUG cap.
      insert_log("warning", "distinctive-retention-debugcap-warn-sentinel", 0)

      Nebu.Admin.DB.upsert_server_config(%{"log_retention_debug_max_count" => "500"})

      assert :ok = Nebu.Web.LogStore.Retention.prune_operational_logs()

      count_result =
        Ecto.Adapters.SQL.query!(
          Nebu.Repo,
          "SELECT COUNT(*) FROM operational_logs WHERE message LIKE 'distinctive-retention-debugcap-%' AND level = 'debug'",
          []
        )

      assert [[500]] = count_result.rows,
             "expected exactly 500 DEBUG rows to remain after the cap prune"

      # The 500 remaining rows must be the 500 MOST RECENT (smallest `gs`,
      # i.e. the ones inserted with the smallest age offset — gs=1..500).
      kept =
        Ecto.Adapters.SQL.query!(
          Nebu.Repo,
          "SELECT message FROM operational_logs WHERE message LIKE 'distinctive-retention-debugcap-%' AND level = 'debug'",
          []
        )
        |> Map.fetch!(:rows)
        |> List.flatten()

      assert "distinctive-retention-debugcap-1" in kept

      refute "distinctive-retention-debugcap-999" in kept,
             "the oldest DEBUG entries (largest age offset) must be the ones pruned, not survive the cap"

      sentinel =
        Ecto.Adapters.SQL.query!(
          Nebu.Repo,
          "SELECT COUNT(*) FROM operational_logs WHERE message = 'distinctive-retention-debugcap-warn-sentinel'",
          []
        )

      assert [[1]] = sentinel.rows,
             "the WARN sentinel row must be untouched by the DEBUG max-count cap"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # admin-logs-retention-settings — closing the WARN/ERROR unbounded-retention
  # gap (Kassandra's operational-log-store review, MEDIUM, explicitly deferred
  # to this story). Per design-decisions.md #4: NOT admin-configurable (this
  # story's own AC6 forbids a UI control for WARN/ERROR retention) — a
  # hardcoded backend safety-net TTL, same 90-day upper bound already used
  # elsewhere in this story's AC10 validation.
  # ══════════════════════════════════════════════════════════════════════════

  describe "WARN/ERROR hardcoded retention TTL (no server_config key, no UI)" do
    test "WARN/ERROR entries older than 90 days are pruned; newer WARN/ERROR and all INFO/DEBUG survive" do
      insert_log("warning", "distinctive-warnerror-warn-old-91d", 91)
      insert_log("error", "distinctive-warnerror-error-old-91d", 91)
      insert_log("warning", "distinctive-warnerror-warn-fresh-1d", 1)
      insert_log("error", "distinctive-warnerror-error-fresh-1d", 1)
      insert_log("info", "distinctive-warnerror-info-old-91d", 91)
      insert_log("debug", "distinctive-warnerror-debug-old-91d", 91)

      assert :ok = Nebu.Web.LogStore.Retention.prune_operational_logs()

      remaining = remaining_messages("distinctive-warnerror-%")

      refute "distinctive-warnerror-warn-old-91d" in remaining,
             "a WARN entry older than the hardcoded 90-day safety-net TTL must be pruned"

      refute "distinctive-warnerror-error-old-91d" in remaining,
             "an ERROR entry older than the hardcoded 90-day safety-net TTL must be pruned"

      assert "distinctive-warnerror-warn-fresh-1d" in remaining,
             "a WARN entry younger than 90 days must survive"

      assert "distinctive-warnerror-error-fresh-1d" in remaining,
             "an ERROR entry younger than 90 days must survive"

      # INFO/DEBUG have their own independent TTL/cap policy (unset here, so
      # no policy prunes them) — the WARN/ERROR safety net must never touch
      # them.
      assert "distinctive-warnerror-info-old-91d" in remaining,
             "the WARN/ERROR safety-net TTL must never prune INFO entries"

      assert "distinctive-warnerror-debug-old-91d" in remaining,
             "the WARN/ERROR safety-net TTL must never prune DEBUG entries"
    end

    test "running prune_operational_logs/0 twice in a row is idempotent for the WARN/ERROR safety net" do
      insert_log("warning", "distinctive-warnerror-idempotent-old-91d", 91)

      assert :ok = Nebu.Web.LogStore.Retention.prune_operational_logs()
      assert :ok = Nebu.Web.LogStore.Retention.prune_operational_logs()

      assert remaining_messages("distinctive-warnerror-idempotent-%") == []
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # admin-logs-retention-settings — AC8/AC9 extend the DEBUG max-count cap
  # pattern (already shipped) symmetrically to INFO via the NEW
  # log_retention_info_max_count key.
  # ══════════════════════════════════════════════════════════════════════════

  describe "INFO max-count cap (new, symmetric with the existing DEBUG cap)" do
    test "1000 INFO entries capped to log_retention_info_max_count=500 leaves only the 500 most recent" do
      Ecto.Adapters.SQL.query!(
        Nebu.Repo,
        """
        INSERT INTO operational_logs (level, source, message, inserted_at)
        SELECT 'info', 'test', 'distinctive-infocap-' || gs,
               now() - (gs * interval '1 second')
        FROM generate_series(1, 1000) AS gs
        """,
        []
      )

      insert_log("warning", "distinctive-infocap-warn-sentinel", 0)

      Nebu.Admin.DB.upsert_server_config(%{"log_retention_info_max_count" => "500"})

      assert :ok = Nebu.Web.LogStore.Retention.prune_operational_logs()

      count_result =
        Ecto.Adapters.SQL.query!(
          Nebu.Repo,
          "SELECT COUNT(*) FROM operational_logs WHERE message LIKE 'distinctive-infocap-%' AND level = 'info'",
          []
        )

      assert [[500]] = count_result.rows,
             "expected exactly 500 INFO rows to remain after the cap prune"

      kept =
        Ecto.Adapters.SQL.query!(
          Nebu.Repo,
          "SELECT message FROM operational_logs WHERE message LIKE 'distinctive-infocap-%' AND level = 'info'",
          []
        )
        |> Map.fetch!(:rows)
        |> List.flatten()

      assert "distinctive-infocap-1" in kept

      refute "distinctive-infocap-999" in kept,
             "the oldest INFO entries (largest age offset) must be the ones pruned, not survive the cap"

      sentinel =
        Ecto.Adapters.SQL.query!(
          Nebu.Repo,
          "SELECT COUNT(*) FROM operational_logs WHERE message = 'distinctive-infocap-warn-sentinel'",
          []
        )

      assert [[1]] = sentinel.rows,
             "the WARN sentinel row must be untouched by the INFO max-count cap"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # epic-wide security review (SEC Gate 2, finding X1, MEDIUM) — a
  # level-INDEPENDENT 90-day safety-net TTL for any row with a non-NULL
  # war_room_id. Closes the gap where war-room-tagged INFO/DEBUG rows
  # persisted while ambient INFO/DEBUG collection is off (the normal
  # war-room operating condition, per war-room-mode's AC4: war-room-tagged
  # entries are always persisted regardless of the collection policy) had
  # NO TTL bound at all — the per-level INFO/DEBUG TTLs are no-ops when
  # unset, and the pre-existing WARN/ERROR safety net only covers WARN/ERROR
  # rows, not INFO/DEBUG. Reuses the same @warn_error_safety_net_days (90)
  # constant, not a new magic number.
  # ══════════════════════════════════════════════════════════════════════════

  describe "war-room safety-net TTL (level-independent, closes epic SEC gate finding X1)" do
    test "a war-room-tagged INFO row older than 90 days is pruned even when log_retention_info_days is unset (collection off)" do
      war_room_id = insert_war_room_session()

      insert_war_room_log(
        "info",
        "distinctive-retention-warroom-info-old-100d",
        100,
        war_room_id
      )

      # Explicitly confirm the "collection off" state this finding is about:
      # log_retention_info_days is unset (nil), so the per-level TTL clause
      # is a no-op for this row.
      assert :ok = Nebu.Web.LogStore.Retention.prune_operational_logs()

      remaining = remaining_messages("distinctive-retention-warroom-%")

      refute "distinctive-retention-warroom-info-old-100d" in remaining,
             "a war-room-tagged INFO row older than the 90-day safety net must be pruned " <>
               "even when the per-level INFO TTL is unset"
    end

    test "a war-room-tagged INFO row younger than 90 days survives the safety net" do
      war_room_id = insert_war_room_session()

      insert_war_room_log(
        "info",
        "distinctive-retention-warroom-info-fresh-1d",
        1,
        war_room_id
      )

      assert :ok = Nebu.Web.LogStore.Retention.prune_operational_logs()

      remaining = remaining_messages("distinctive-retention-warroom-%")

      assert "distinctive-retention-warroom-info-fresh-1d" in remaining,
             "a war-room-tagged INFO row younger than 90 days must survive the safety net"
    end

    test "the war-room safety net does not interfere with the WARN/ERROR safety net's independent operation" do
      war_room_id = insert_war_room_session()

      # A war-room-tagged WARN row older than 90 days must still be pruned
      # (by either safety net — the point is it must not survive twice-over
      # due to some interaction bug between the two clauses).
      insert_war_room_log(
        "warning",
        "distinctive-retention-warroom-warn-old-91d",
        91,
        war_room_id
      )

      # A non-war-room WARN row older than 90 days (the pre-existing
      # behavior) must still be pruned, unaffected by the new clause.
      insert_log("warning", "distinctive-retention-warroom-warn-plain-old-91d", 91)

      # A non-war-room WARN row younger than 90 days must still survive,
      # unaffected by the new clause.
      insert_log("warning", "distinctive-retention-warroom-warn-plain-fresh-1d", 1)

      assert :ok = Nebu.Web.LogStore.Retention.prune_operational_logs()

      remaining = remaining_messages("distinctive-retention-warroom-%")

      refute "distinctive-retention-warroom-warn-old-91d" in remaining
      refute "distinctive-retention-warroom-warn-plain-old-91d" in remaining
      assert "distinctive-retention-warroom-warn-plain-fresh-1d" in remaining
    end

    test "running prune_operational_logs/0 twice in a row is idempotent for the war-room safety net" do
      war_room_id = insert_war_room_session()

      insert_war_room_log(
        "debug",
        "distinctive-retention-warroom-idempotent-old-100d",
        100,
        war_room_id
      )

      assert :ok = Nebu.Web.LogStore.Retention.prune_operational_logs()
      assert :ok = Nebu.Web.LogStore.Retention.prune_operational_logs()

      assert remaining_messages("distinctive-retention-warroom-idempotent-%") == []
    end
  end
end
