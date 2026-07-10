defmodule Nebu.Admin.WarRoomManagerTest do
  @moduledoc """
  RED-phase ATDD tests for `enhanced-logging/war-room-mode` (AC1, AC2, AC3,
  AC6, AC10 — `Nebu.Admin.WarRoomManager`'s public API: `start_session/1`,
  `stop_session/1`, `status/0`).

  Story: docs/stories/enhanced-logging/war-room-mode.md
  Design decisions (read FIRST): _bmad-output/nebu/epics/enhanced-logging/step-results/war-room-mode/design-decisions.md

  ## Why these MUST FAIL right now

  Neither `Nebu.Admin.WarRoomManager` (server/lib/nebu/admin/war_room_manager.ex)
  nor the `war_room_sessions` table exist yet. Every test below fails with
  `UndefinedFunctionError` (the module doesn't exist) or a Postgres
  `relation "war_room_sessions" does not exist` error.

  ## Architecture note (design-decisions.md #6)

  There is deliberately NO `war_room_controller.ex`/HTTP endpoint here — the
  story's own Dev Notes assumed a JSON HTTP API
  (`POST /admin/war-room/start` -> 409/session-id), but `admin-logs-monitoring-view`
  shipped `/admin/logs` as a LiveView, and every admin mutation in this
  codebase is either a LiveView `handle_event` round-trip or a plain HTML
  `<form>` POST — never a JSON API. `Nebu.Admin.WarRoomManager` is kept
  exactly as the story's own File List specifies: a pure-functional,
  inline-SQL Admin-domain module (ADR-018/020) with NO `Plug.Conn`/controller
  knowledge, directly unit-testable without an HTTP round trip — the
  `Nebu.Admin.LogsLive` `handle_event("start_war_room"/"stop_war_room", ...)`
  clauses (tested separately, in `logs_live_test.exs`) call straight into
  this module's functions.

  AC2's literal "the API returns a 409 Conflict error" is reinterpreted, per
  design-decisions.md, as `start_session/1` returning
  `{:error, :conflict, message}`. AC3's "the API returns the session id" is
  `{:ok, %{id: uuid, ...}}`.
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  setup do
    Nebu.Release.migrate()

    on_exit(fn ->
      if Process.whereis(Nebu.Repo) do
        Ecto.Adapters.SQL.query(
          Nebu.Repo,
          "DELETE FROM war_room_sessions WHERE started_by LIKE 'distinctive-wrm-test-%'",
          []
        )
      end
    end)

    :ok
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp run_id, do: "#{System.unique_integer([:positive])}-#{:erlang.phash2(self())}"

  defp new_started_by, do: "distinctive-wrm-test-#{run_id()}"

  # AC2 guarantees at most one row with ended_at IS NULL exists at all —
  # defensively ends it so every test's "nothing is active yet" precondition
  # holds regardless of test order / a prior test's failure to clean up.
  defp end_all_active! do
    Ecto.Adapters.SQL.query!(
      Nebu.Repo,
      "UPDATE war_room_sessions SET ended_at = now(), ended_reason = 'manual_stop' WHERE ended_at IS NULL",
      []
    )
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC1 / AC10 — schema exists (table + operational_logs.war_room_id + FK)
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC1: war_room_sessions table exists with the full schema" do
    test "war_room_sessions has every column the story specifies" do
      result =
        Ecto.Adapters.SQL.query!(
          Nebu.Repo,
          "SELECT column_name FROM information_schema.columns WHERE table_name = 'war_room_sessions'",
          []
        )

      columns = result.rows |> List.flatten() |> MapSet.new()

      expected =
        ~w(id started_at started_by reason scope filter max_entries max_duration_s
           ended_at ended_reason entries_collected)

      for column <- expected do
        assert column in columns, "expected war_room_sessions to have a #{column} column"
      end
    end

    test "exactly one active session is enforced at the DB level via a partial unique index" do
      end_all_active!()

      Ecto.Adapters.SQL.query!(
        Nebu.Repo,
        """
        INSERT INTO war_room_sessions (started_by, reason, max_entries, max_duration_s)
        VALUES ($1, $2, $3, $4)
        """,
        [new_started_by(), "first raw row, still active", 100, 300]
      )

      assert_raise Postgrex.Error, ~r/duplicate key|unique constraint/i, fn ->
        Ecto.Adapters.SQL.query!(
          Nebu.Repo,
          """
          INSERT INTO war_room_sessions (started_by, reason, max_entries, max_duration_s)
          VALUES ($1, $2, $3, $4)
          """,
          [new_started_by(), "second raw row — must violate the single-active constraint", 50, 60]
        )
      end
    end
  end

  describe "AC10: operational_logs.war_room_id is a nullable UUID FK to war_room_sessions" do
    test "the column exists with the right type/nullability, and an FK constraint references war_room_sessions" do
      col_result =
        Ecto.Adapters.SQL.query!(
          Nebu.Repo,
          """
          SELECT data_type, is_nullable FROM information_schema.columns
          WHERE table_name = 'operational_logs' AND column_name = 'war_room_id'
          """,
          []
        )

      assert col_result.rows == [["uuid", "YES"]],
             "expected operational_logs.war_room_id to be a nullable uuid column, got: #{inspect(col_result.rows)}"

      # test-quality fix (dev-story, not a design decision): this project's
      # docker-compose deployment (`server/Dockerfile`'s ENTRYPOINT +
      # `docker-compose.yml`'s `NEBU_DB_URL_MIGRATE`) ALWAYS runs migrations
      # as the `nebu_migrate` role — including in a genuinely fresh volume,
      # not merely a legacy/pre-squash one — so `war_room_sessions` and
      # `operational_logs` are owned by `nebu_migrate`, while this test
      # (like every OTHER integration test) connects as `nebu_app`.
      # `information_schema.constraint_column_usage`'s own view definition
      # (verified via `pg_get_viewdef/2`) filters rows with ONLY
      # `pg_has_role(tableowner, 'USAGE')` — no `has_table_privilege`
      # fallback, unlike `table_constraints`/`key_column_usage` (which DO
      # have that fallback, and therefore stay visible even to a
      # non-member role holding plain DML grants). Since `nebu_app` is
      # never a member of `nebu_migrate`, the original 3-way
      # information_schema join above can NEVER return a row for this
      # constraint under `nebu_app`, regardless of whether the FK genuinely
      # exists — reproduced and confirmed directly against a FRESH
      # (`docker compose down --volumes` + up) Postgres volume. Querying
      # `pg_constraint`/`pg_class` (`pg_catalog`, not the ownership-scoped
      # `information_schema` views) verifies the identical fact — an FK
      # constraint on `operational_logs.war_room_id` referencing
      # `war_room_sessions` — without that role-visibility restriction.
      fk_result =
        Ecto.Adapters.SQL.query!(
          Nebu.Repo,
          """
          SELECT con.conname
          FROM pg_constraint con
          JOIN pg_class rel ON rel.oid = con.conrelid
          JOIN pg_class frel ON frel.oid = con.confrelid
          JOIN pg_attribute att
            ON att.attrelid = con.conrelid AND att.attnum = con.conkey[1]
          WHERE con.contype = 'f'
            AND rel.relname = 'operational_logs'
            AND frel.relname = 'war_room_sessions'
            AND att.attname = 'war_room_id'
          """,
          []
        )

      assert fk_result.num_rows > 0,
             "expected a FOREIGN KEY constraint on operational_logs.war_room_id referencing " <>
               "war_room_sessions(id) — migration 000017 deliberately deferred this (the table " <>
               "didn't exist yet); this story's migration must add it"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC2 — exactly one active session
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC2: exactly one active war room session" do
    test "starting a second session while one is active returns {:error, :conflict, message}" do
      end_all_active!()

      {:ok, existing} =
        Nebu.Admin.WarRoomManager.start_session(%{
          started_by: new_started_by(),
          reason: "first session, still active",
          max_entries: 100,
          max_duration_s: 300
        })

      result =
        Nebu.Admin.WarRoomManager.start_session(%{
          started_by: new_started_by(),
          reason: "second session, must be rejected",
          max_entries: 50,
          max_duration_s: 60
        })

      assert {:error, :conflict, message} = result
      assert is_binary(message)
      assert message =~ existing.started_by
      assert message =~ existing.reason

      count_result =
        Ecto.Adapters.SQL.query!(
          Nebu.Repo,
          "SELECT count(*) FROM war_room_sessions WHERE ended_at IS NULL",
          []
        )

      assert count_result.rows == [[1]],
             "the second, conflicting session must NOT be created"
    end

    test "idempotent restart with identical params returns {:ok, existing_session} without a duplicate row" do
      end_all_active!()

      started_by = new_started_by()

      params = %{
        started_by: started_by,
        reason: "idempotent restart test",
        scope: "all",
        max_entries: 100,
        max_duration_s: 300
      }

      {:ok, first} = Nebu.Admin.WarRoomManager.start_session(params)
      {:ok, second} = Nebu.Admin.WarRoomManager.start_session(params)

      assert first.id == second.id,
             "restarting the SAME session with identical params must return the existing " <>
               "session, not create/return a different one"

      count_result =
        Ecto.Adapters.SQL.query!(
          Nebu.Repo,
          "SELECT count(*) FROM war_room_sessions WHERE ended_at IS NULL",
          []
        )

      assert count_result.rows == [[1]],
             "an idempotent restart with identical params must not create a second row"
    end

    test "restarting with DIFFERENT params while one is active is a conflict, not treated as idempotent" do
      end_all_active!()

      started_by = new_started_by()

      {:ok, _existing} =
        Nebu.Admin.WarRoomManager.start_session(%{
          started_by: started_by,
          reason: "original reason",
          max_entries: 100,
          max_duration_s: 300
        })

      result =
        Nebu.Admin.WarRoomManager.start_session(%{
          started_by: started_by,
          reason: "a DIFFERENT reason — must NOT be treated as an idempotent restart",
          max_entries: 100,
          max_duration_s: 300
        })

      assert {:error, :conflict, _message} = result
    end

    test "the DB-level partial unique index is the real backstop, independent of the app-level check" do
      end_all_active!()

      {:ok, _first} =
        Nebu.Admin.WarRoomManager.start_session(%{
          started_by: new_started_by(),
          reason: "race winner",
          max_entries: 100,
          max_duration_s: 300
        })

      # Simulates a raced concurrent start bypassing the app-level check
      # entirely (e.g. two nodes/processes both passing the "is one active?"
      # SELECT before either INSERTs) — the UNIQUE INDEX itself must still
      # reject the second row.
      assert_raise Postgrex.Error, ~r/duplicate key|unique constraint/i, fn ->
        Ecto.Adapters.SQL.query!(
          Nebu.Repo,
          """
          INSERT INTO war_room_sessions (started_by, reason, max_entries, max_duration_s)
          VALUES ($1, $2, $3, $4)
          """,
          [new_started_by(), "raw insert racing the app-level check", 10, 10]
        )
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC3 — required + optional session parameters
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC3: required + optional session params" do
    test "start_session/1 persists all required params with entries_collected starting at 0" do
      end_all_active!()

      started_by = new_started_by()

      params = %{
        started_by: started_by,
        reason: "sync investigation",
        max_entries: 50,
        max_duration_s: 120
      }

      {:ok, session} = Nebu.Admin.WarRoomManager.start_session(params)

      assert session.started_by == started_by
      assert session.reason == "sync investigation"
      assert session.max_entries == 50
      assert session.max_duration_s == 120
      assert session.entries_collected == 0
      refute is_nil(session.id)
      refute is_nil(session.started_at)
      assert is_nil(session.ended_at)

      row =
        Ecto.Adapters.SQL.query!(
          Nebu.Repo,
          """
          SELECT started_by, reason, max_entries, max_duration_s, entries_collected, ended_at
          FROM war_room_sessions WHERE id = $1
          """,
          [session.id]
        )

      assert [[db_started_by, "sync investigation", 50, 120, 0, nil]] = row.rows
      assert db_started_by == started_by
    end

    test "optional scope and filter parameters are persisted as given" do
      end_all_active!()

      {:ok, session} =
        Nebu.Admin.WarRoomManager.start_session(%{
          started_by: new_started_by(),
          reason: "sync investigation with scope+filter",
          scope: "/_matrix/client/v3/sync",
          filter: %{"user_id" => "@alice:localhost"},
          max_entries: 100,
          max_duration_s: 300
        })

      assert session.scope == "/_matrix/client/v3/sync"
      assert session.filter == %{"user_id" => "@alice:localhost"}

      row =
        Ecto.Adapters.SQL.query!(
          Nebu.Repo,
          "SELECT scope, filter FROM war_room_sessions WHERE id = $1",
          [session.id]
        )

      # JSONB columns are decoded back into native Elixir terms by
      # Ecto/Postgrex — never a raw JSON-text string (see
      # Nebu.Matrix.Room.Db.insert_event/1's documented convention, and
      # Nebu.Web.LogStore.get_logs/1's own `metadata`/`war_room_id` passthrough).
      assert [["/_matrix/client/v3/sync", %{"user_id" => "@alice:localhost"}]] = row.rows
    end

    test "omitted scope/filter default to nil (treated as \"all\"/no filtering) without error" do
      end_all_active!()

      {:ok, session} =
        Nebu.Admin.WarRoomManager.start_session(%{
          started_by: new_started_by(),
          reason: "no scope/filter given",
          max_entries: 100,
          max_duration_s: 300
        })

      assert is_nil(session.scope)
      assert is_nil(session.filter)
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Security review (Kassandra, 2026-07-06, F-1 MEDIUM) — start_session/1
  # itself must enforce the AC8/AC11 numeric bounds (10..10_000 /
  # 10..3_600), not just Nebu.Admin.LogsLive's parse_int_bounded/5. Calling
  # the manager DIRECTLY (bypassing the LiveView entirely) must still be
  # rejected for an out-of-bounds max_entries/max_duration_s.
  # ══════════════════════════════════════════════════════════════════════════

  describe "F-1: start_session/1 enforces max_entries/max_duration_s bounds directly" do
    test "rejects a max_entries below the 10..10_000 bound, called directly" do
      end_all_active!()

      result =
        Nebu.Admin.WarRoomManager.start_session(%{
          started_by: new_started_by(),
          reason: "max_entries too low",
          max_entries: 1,
          max_duration_s: 300
        })

      assert {:error, :invalid_params, message} = result
      assert message =~ "max_entries"

      count_result =
        Ecto.Adapters.SQL.query!(
          Nebu.Repo,
          "SELECT count(*) FROM war_room_sessions WHERE ended_at IS NULL",
          []
        )

      assert count_result.rows == [[0]],
             "an out-of-bounds max_entries must NOT create a session"
    end

    test "rejects a max_entries above the 10..10_000 bound (unbounded flooding case), called directly" do
      end_all_active!()

      result =
        Nebu.Admin.WarRoomManager.start_session(%{
          started_by: new_started_by(),
          reason: "unbounded max_entries with scope=all — the exact flooding scenario",
          scope: "all",
          max_entries: 1_000_000,
          max_duration_s: 300
        })

      assert {:error, :invalid_params, message} = result
      assert message =~ "max_entries"

      count_result =
        Ecto.Adapters.SQL.query!(
          Nebu.Repo,
          "SELECT count(*) FROM war_room_sessions WHERE ended_at IS NULL",
          []
        )

      assert count_result.rows == [[0]]
    end

    test "rejects a max_duration_s below the 10..3_600 bound, called directly" do
      end_all_active!()

      result =
        Nebu.Admin.WarRoomManager.start_session(%{
          started_by: new_started_by(),
          reason: "max_duration_s too low",
          max_entries: 100,
          max_duration_s: 1
        })

      assert {:error, :invalid_params, message} = result
      assert message =~ "max_duration_s"
    end

    test "rejects a max_duration_s above the 10..3_600 bound, called directly" do
      end_all_active!()

      result =
        Nebu.Admin.WarRoomManager.start_session(%{
          started_by: new_started_by(),
          reason: "max_duration_s too high",
          max_entries: 100,
          max_duration_s: 999_999
        })

      assert {:error, :invalid_params, message} = result
      assert message =~ "max_duration_s"
    end

    test "accepts values at the exact bound edges (10, 10_000, 10, 3_600)" do
      end_all_active!()

      {:ok, session} =
        Nebu.Admin.WarRoomManager.start_session(%{
          started_by: new_started_by(),
          reason: "boundary values are valid",
          max_entries: 10,
          max_duration_s: 10
        })

      assert session.max_entries == 10
      assert session.max_duration_s == 10

      :ok = Nebu.Admin.WarRoomManager.stop_session(session.id)

      {:ok, session2} =
        Nebu.Admin.WarRoomManager.start_session(%{
          started_by: new_started_by(),
          reason: "upper boundary values are valid",
          max_entries: 10_000,
          max_duration_s: 3_600
        })

      assert session2.max_entries == 10_000
      assert session2.max_duration_s == 3_600
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC6 — manual stop
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC6: manual stop via stop_session/1" do
    test "stop_session/1 sets ended_at + ended_reason=\"manual_stop\"" do
      end_all_active!()

      {:ok, session} =
        Nebu.Admin.WarRoomManager.start_session(%{
          started_by: new_started_by(),
          reason: "to be manually stopped",
          max_entries: 100,
          max_duration_s: 300
        })

      assert :ok = Nebu.Admin.WarRoomManager.stop_session(session.id)

      row =
        Ecto.Adapters.SQL.query!(
          Nebu.Repo,
          "SELECT ended_at, ended_reason FROM war_room_sessions WHERE id = $1",
          [session.id]
        )

      assert [[ended_at, "manual_stop"]] = row.rows
      refute is_nil(ended_at)
    end

    test "stopping an already-ended session is a safe no-op / clear error, never a crash" do
      end_all_active!()

      {:ok, session} =
        Nebu.Admin.WarRoomManager.start_session(%{
          started_by: new_started_by(),
          reason: "double-stop test",
          max_entries: 100,
          max_duration_s: 300
        })

      :ok = Nebu.Admin.WarRoomManager.stop_session(session.id)

      result = Nebu.Admin.WarRoomManager.stop_session(session.id)

      assert result in [:ok, {:error, :not_found}, {:error, :already_ended}],
             "stopping an already-ended session must return a well-defined result, not raise"
    end

    test "status/0 reflects the active session, then :none once it is stopped" do
      end_all_active!()

      assert Nebu.Admin.WarRoomManager.status() == :none

      {:ok, session} =
        Nebu.Admin.WarRoomManager.start_session(%{
          started_by: new_started_by(),
          reason: "status check",
          max_entries: 100,
          max_duration_s: 300
        })

      assert {:ok, active} = Nebu.Admin.WarRoomManager.status()
      assert active.id == session.id
      assert active.started_by == session.started_by
      assert active.entries_collected == 0

      :ok = Nebu.Admin.WarRoomManager.stop_session(session.id)

      assert Nebu.Admin.WarRoomManager.status() == :none
    end
  end
end
