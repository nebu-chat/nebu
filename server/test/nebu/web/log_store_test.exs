defmodule Nebu.Web.LogStoreTest do
  @moduledoc """
  RED-phase ATDD tests for `enhanced-logging/operational-log-store` (AC1, AC2,
  AC3, AC9, AC10, AC11 — the top-level public-API surface).

  Story: docs/stories/enhanced-logging/operational-log-store.md

  ## Why these MUST FAIL right now

  `Nebu.Web.LogStore` (server/lib/nebu/web/log_store.ex) does not exist yet —
  neither does `operational_logs` (the migration hasn't been written), nor the
  5 new `server_config` policy keys' entry in the `config_update_mutable` RLS
  allowlist (server/priv/migrations/000013_config_oidc_scopes_mutable.up.sql
  is the precedent this story must follow — see the AC3 test below for why a
  single upsert is NOT sufficient proof). Every test here either fails to
  resolve `Nebu.Web.LogStore.*` at runtime (`UndefinedFunctionError`) or fails
  against a real Postgres because `operational_logs` does not exist yet.

  ## Test layering

  Tests that only touch `:logger`/`Phoenix.PubSub` (in-process, no DB) are
  tagged `:unit` implicitly (no `@describetag`). Tests that need
  `operational_logs` to exist, or need `Nebu.Repo`/`Nebu.Admin.DB` for
  server_config round trips, are tagged `:integration` (excluded from plain
  `mix test`, run via `make test-integration`) — mirrors
  `request_logger_test.exs` / `spaces_foundation_integration_test.exs`.
  """
  use ExUnit.Case, async: false

  require Logger

  @policy_keys ~w(
    log_collect_info log_retention_info_days
    log_collect_debug log_retention_debug_days log_retention_debug_max_count
  )a

  # ── shared helpers ──────────────────────────────────────────────────────────

  defp with_log_level(level, fun) do
    original_level = Logger.level()
    Logger.configure(level: level)

    try do
      fun.()
    after
      Logger.configure(level: original_level)
    end
  end

  # `Nebu.PubSub` (the topic name the story's AC2/AC10 explicitly name) is NOT
  # currently started anywhere in `Nebu.Application` — only `Nebu.Admin.PubSub`
  # (the LiveView socket) exists today (verified: `grep -rn "Phoenix.PubSub"
  # server/lib` finds only that one). Starting it here (test-owned, torn down
  # automatically by ExUnit's `start_supervised!`) lets these tests observe the
  # broadcast contract the story specifies regardless of whether dev-story ends
  # up wiring `Nebu.PubSub` into the application supervisor or reusing
  # `Nebu.Admin.PubSub` under an alias — that wiring choice is an implementation
  # detail, not part of this ATDD scaffold's job to pin down.
  defp ensure_pubsub_started! do
    case Process.whereis(Nebu.PubSub) do
      nil -> start_supervised!({Phoenix.PubSub, name: Nebu.PubSub})
      _pid -> :ok
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC1 — migration creates operational_logs with the full schema + indices
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC1: migration creates operational_logs table" do
    @describetag :integration

    test "operational_logs exists with all required columns after migration, and re-running the migration is idempotent" do
      # Applies any pending migration files (including the new one this story
      # must add) against the live integration-test Postgres. Idempotent by
      # design (Nebu.Release tracks schema_migrations.version) — calling it
      # twice in a row (once implicitly at stack boot, once here) must be a
      # safe no-op the second time, which is exactly AC1's idempotency clause.
      assert :ok = Nebu.Release.migrate()
      assert :ok = Nebu.Release.migrate()

      columns =
        Ecto.Adapters.SQL.query!(
          Nebu.Repo,
          "SELECT column_name FROM information_schema.columns WHERE table_name = 'operational_logs'",
          []
        )
        |> Map.fetch!(:rows)
        |> List.flatten()
        |> MapSet.new()

      expected =
        MapSet.new(~w(
          id inserted_at level source route_template request_id message
          metadata war_room_id
        ))

      assert MapSet.subset?(expected, columns),
             "operational_logs is missing columns: #{inspect(MapSet.difference(expected, columns))}"
    end

    test "operational_logs has an index on (level, inserted_at) and one on (route_template, inserted_at)" do
      Nebu.Release.migrate()

      index_defs =
        Ecto.Adapters.SQL.query!(
          Nebu.Repo,
          "SELECT indexdef FROM pg_indexes WHERE tablename = 'operational_logs'",
          []
        )
        |> Map.fetch!(:rows)
        |> List.flatten()

      assert Enum.any?(index_defs, fn def ->
               String.contains?(def, "level") and String.contains?(def, "inserted_at")
             end),
             "expected an index covering (level, inserted_at), got: #{inspect(index_defs)}"

      assert Enum.any?(index_defs, fn def ->
               String.contains?(def, "route_template") and String.contains?(def, "inserted_at")
             end),
             "expected an index covering (route_template, inserted_at), got: #{inspect(index_defs)}"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC11 — war_room_id extension seam
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC11: war_room_id column" do
    @describetag :integration

    test "war_room_id is a nullable UUID column" do
      Nebu.Release.migrate()

      row =
        Ecto.Adapters.SQL.query!(
          Nebu.Repo,
          """
          SELECT data_type, is_nullable FROM information_schema.columns
          WHERE table_name = 'operational_logs' AND column_name = 'war_room_id'
          """,
          []
        )
        |> Map.fetch!(:rows)

      assert [[data_type, is_nullable]] = row,
             "war_room_id column must exist on operational_logs"

      assert data_type == "uuid"
      assert is_nullable == "YES"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC2 — central :logger handler registration (idempotent, discoverable)
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC2: attach_handler/0" do
    test "registers exactly one new :logger handler, idempotently, and it actually fires on Logger calls" do
      ensure_pubsub_started!()

      before_ids = :logger.get_handler_ids()

      assert :ok = Nebu.Web.LogStore.attach_handler()
      after_first = :logger.get_handler_ids()

      # NOTE: this can't assert `+1` unconditionally — `:logger` handler
      # registration is GLOBAL, process-wide state that persists for the
      # rest of the BEAM VM's lifetime once any earlier test in the suite
      # (e.g. handler_test.exs's own `attach_handler/0` calls) has already
      # attached it, and ExUnit does not guarantee this test runs first. The
      # property that actually matters for AC2 — attaching never registers
      # MORE THAN one new handler, and never removes an existing one — holds
      # regardless of test order.
      new_ids = after_first -- before_ids

      assert length(new_ids) <= 1,
             "attach_handler/0 must register AT MOST one new :logger handler (0 if an " <>
               "earlier test already attached it, 1 otherwise), got new ids: #{inspect(new_ids)}"

      assert Enum.all?(before_ids, &(&1 in after_first)),
             "attach_handler/0 must never remove an already-attached handler"

      # Idempotency: calling it again must NOT register a second handler.
      assert :ok = Nebu.Web.LogStore.attach_handler()
      after_second = :logger.get_handler_ids()

      assert Enum.sort(after_second) == Enum.sort(after_first),
             "re-attaching must be idempotent (tolerate already-attached), not register a duplicate handler"

      # admin-logs-retention-settings hygiene fix: if `log_collect_info` is
      # `true` when this test happens to run (any earlier test in the same
      # `mix test` invocation may have enabled it, e.g.
      # `logs_controller_test.exs`'s several ATs — `:logger` handler
      # registration/broadcast above is process-global and does not itself
      # gate on this policy), the `Logger.info/1` call below is genuinely
      # PERSISTED to `operational_logs` (AC7's whole point — broadcast is
      # independent of persistence, but persistence still happens per
      # policy). Left uncleaned, this row survives (operational_logs has no
      # RLS, but nothing else deletes it either) and permanently pollutes
      # ANY later exact-row-count assertion over `level = 'info'` (e.g.
      # `Nebu.Web.LogStore.Retention` max-count-cap tests) for the remainder
      # of that BEAM's lifetime. Clean it up unconditionally.
      on_exit(fn ->
        if Process.whereis(Nebu.Repo) do
          Ecto.Adapters.SQL.query(
            Nebu.Repo,
            "DELETE FROM operational_logs WHERE message = 'distinctive-attach-handler-probe-message'",
            []
          )
        end
      end)

      # Proof the handler is actually wired, not just registered: a Logger
      # call in-process must reach it and broadcast to "operational_logs"
      # (AC2 point 1 — always broadcasts, independent of persistence).
      Phoenix.PubSub.subscribe(Nebu.PubSub, "operational_logs")

      with_log_level(:info, fn ->
        Logger.info("distinctive-attach-handler-probe-message")
      end)

      assert_receive _entry,
                     1_000,
                     "Logger.info/1 after attach_handler/0 must trigger the handler callback, " <>
                       "observed here via its PubSub broadcast side-effect"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC2/AC10 — broadcast happens regardless of DB-persistence policy
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC2/AC10: PubSub broadcast independent of persistence config" do
    @describetag :integration

    test "a DEBUG log entry still broadcasts to \"operational_logs\" even when log_collect_debug is false" do
      ensure_pubsub_started!()

      Nebu.Admin.DB.upsert_server_config(%{
        "log_collect_debug" => "false",
        "log_collect_info" => "false"
      })

      :ok = Nebu.Web.LogStore.attach_handler()
      Phoenix.PubSub.subscribe(Nebu.PubSub, "operational_logs")

      with_log_level(:debug, fn ->
        Logger.debug("distinctive-broadcast-independent-of-persistence-probe")
      end)

      assert_receive _entry,
                     1_000,
                     "the broadcast must fire even though log_collect_debug=false means this " <>
                       "entry is NOT written to operational_logs — AC10's whole point is that a " <>
                       "live view can see DEBUG entries in real time regardless of persistence"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC3 — the 5 new server_config policy keys are genuinely mutable
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC3: server_config policy keys" do
    @tag :integration
    test "upsert_server_config accepts all 5 new keys, and a SECOND upsert (an UPDATE) actually changes the stored value" do
      if Process.whereis(Nebu.Repo) do
        keys = ~w(
          log_collect_info log_retention_info_days
          log_collect_debug log_retention_debug_days log_retention_debug_max_count
        )

        on_exit(fn ->
          if Process.whereis(Nebu.Repo) do
            for key <- keys do
              Ecto.Adapters.SQL.query(Nebu.Repo, "DELETE FROM server_config WHERE key = $1", [
                key
              ])
            end
          end
        end)

        for key <- keys do
          assert :ok = Nebu.Admin.DB.upsert_server_config(%{key => "first-value"})
          {:ok, config} = Nebu.Admin.DB.get_server_config()
          assert config[key] == "first-value"

          # THE REAL AC3 GOTCHA: server_config has FORCE ROW LEVEL SECURITY;
          # the config_update_mutable policy allowlists which keys a
          # SUBSEQUENT UPDATE may touch (see
          # priv/migrations/000013_config_oidc_scopes_mutable.up.sql — the
          # precedent this story's migration must extend). The FIRST upsert
          # of a brand-new key always succeeds unconditionally (it is an
          # INSERT, allowed by the config_insert_only policy regardless of
          # the allowlist) — so asserting on a single upsert would pass even
          # if these 5 keys were never added to the allowlist. Upsert AGAIN
          # (now an UPDATE via ON CONFLICT DO UPDATE) to actually exercise
          # the RLS gate AC3 requires.
          assert :ok = Nebu.Admin.DB.upsert_server_config(%{key => "second-value"})
          {:ok, config2} = Nebu.Admin.DB.get_server_config()

          assert config2[key] == "second-value",
                 "expected #{key}'s second upsert (an UPDATE) to change the stored value — " <>
                   "if #{key} is missing from server_config's config_update_mutable RLS policy " <>
                   "allowlist, this UPDATE silently affects 0 rows and \"first-value\" survives"
        end
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC9 — public module API: get_policy/0
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC9: get_policy/0" do
    test "returns {:ok, map} with all 5 policy keys present" do
      {:ok, policy} = Nebu.Web.LogStore.get_policy()

      assert is_map(policy)

      for key <- @policy_keys do
        assert Map.has_key?(policy, key),
               "get_policy/0's map is missing key #{inspect(key)}, got: #{inspect(Map.keys(policy))}"
      end
    end

    @tag :integration
    test "reflects server_config values when they have been set" do
      if Process.whereis(Nebu.Repo) do
        on_exit(fn ->
          if Process.whereis(Nebu.Repo) do
            Ecto.Adapters.SQL.query(Nebu.Repo, "DELETE FROM server_config WHERE key = $1", [
              "log_collect_info"
            ])
          end
        end)

        Nebu.Admin.DB.upsert_server_config(%{"log_collect_info" => "true"})

        {:ok, policy} = Nebu.Web.LogStore.get_policy()

        assert policy[:log_collect_info] in [true, "true"],
               "get_policy/0 must reflect the server_config value it was just set to"
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC9 — public module API: get_logs/1
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC9: get_logs/1" do
    @describetag :integration

    setup do
      Nebu.Release.migrate()

      Ecto.Adapters.SQL.query!(
        Nebu.Repo,
        """
        INSERT INTO operational_logs (level, source, message, inserted_at)
        VALUES
          ('info', 'http', 'distinctive-get-logs-info-http', now()),
          ('warning', 'ecto', 'distinctive-get-logs-warning-ecto', now()),
          ('error', 'http', 'distinctive-get-logs-error-http', now())
        """,
        []
      )

      on_exit(fn ->
        Ecto.Adapters.SQL.query(
          Nebu.Repo,
          "DELETE FROM operational_logs WHERE message LIKE 'distinctive-get-logs-%'",
          []
        )
      end)

      :ok
    end

    test "get_logs(%{level: \"info\"}) returns only INFO-level entries" do
      {:ok, logs} = Nebu.Web.LogStore.get_logs(%{level: "info"})

      messages = Enum.map(logs, & &1[:message])
      assert "distinctive-get-logs-info-http" in messages
      refute "distinctive-get-logs-warning-ecto" in messages
      refute "distinctive-get-logs-error-http" in messages
    end

    test "get_logs(%{source: \"http\"}) returns only http-source entries" do
      {:ok, logs} = Nebu.Web.LogStore.get_logs(%{source: "http"})

      messages = Enum.map(logs, & &1[:message])
      assert "distinctive-get-logs-info-http" in messages
      assert "distinctive-get-logs-error-http" in messages
      refute "distinctive-get-logs-warning-ecto" in messages
    end

    # ────────────────────────────────────────────────────────────────────────
    # enhanced-logging/war-room-mode (AC12): the request-stream panel needs
    # to filter by war_room_id to show "all logs tagged with war-room-session-X"
    # as a coherent, bookmarkable slice. Design-decisions.md #2 notes get_logs/1
    # ALREADY selects/returns war_room_id in row_to_log/1 — it is only missing
    # from @allowed_filter_keys (currently `~w(level source route_template
    # request_id)`), a 1-line fix. This test targets THAT gap specifically —
    # it must fail with an empty result (the filter key silently ignored,
    # returning every row) until "war_room_id" is added to the allowlist.
    # ────────────────────────────────────────────────────────────────────────
    test "get_logs(%{war_room_id: id}) returns only entries tagged with that session" do
      session_result =
        Ecto.Adapters.SQL.query!(
          Nebu.Repo,
          """
          INSERT INTO war_room_sessions (started_by, reason, max_entries, max_duration_s)
          VALUES ($1, $2, $3, $4)
          RETURNING id
          """,
          ["distinctive-get-logs-war-room-filter-test", "AC12 get_logs/1 filter test", 100, 300]
        )

      [[war_room_id]] = session_result.rows

      on_exit(fn ->
        if Process.whereis(Nebu.Repo) do
          Ecto.Adapters.SQL.query(
            Nebu.Repo,
            "DELETE FROM operational_logs WHERE war_room_id = $1",
            [war_room_id]
          )

          Ecto.Adapters.SQL.query(Nebu.Repo, "DELETE FROM war_room_sessions WHERE id = $1", [
            war_room_id
          ])
        end
      end)

      Ecto.Adapters.SQL.query!(
        Nebu.Repo,
        """
        INSERT INTO operational_logs (level, source, message, war_room_id, inserted_at)
        VALUES ($1, $2, $3, $4, now())
        """,
        ["debug", "http", "distinctive-get-logs-war-room-tagged", war_room_id]
      )

      {:ok, logs} = Nebu.Web.LogStore.get_logs(%{war_room_id: war_room_id})

      messages = Enum.map(logs, & &1[:message])

      assert "distinctive-get-logs-war-room-tagged" in messages,
             "expected the war_room_id filter to include the tagged row"

      refute "distinctive-get-logs-info-http" in messages,
             "the war_room_id filter must not leak unrelated, untagged rows from this " <>
               "describe block's own setup fixtures"

      assert Enum.all?(logs, &(&1[:war_room_id] == war_room_id)),
             "every returned row must actually carry the requested war_room_id"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # admin-logs-retention-settings — get_policy/0 gains a 6th key
  # (log_retention_info_max_count), symmetric with the existing
  # log_retention_debug_max_count. This story's controller reads the policy
  # via this exact function to pre-fill the INFO retention fields (AC9/AC16).
  # ══════════════════════════════════════════════════════════════════════════

  describe "admin-logs-retention-settings: get_policy/0 includes log_retention_info_max_count" do
    test "returns {:ok, map} that also has the log_retention_info_max_count key" do
      {:ok, policy} = Nebu.Web.LogStore.get_policy()

      assert Map.has_key?(policy, :log_retention_info_max_count),
             "get_policy/0's map is missing :log_retention_info_max_count, got: #{inspect(Map.keys(policy))}"
    end

    @tag :integration
    test "reflects the server_config value when log_retention_info_max_count has been set" do
      if Process.whereis(Nebu.Repo) do
        on_exit(fn ->
          if Process.whereis(Nebu.Repo) do
            Ecto.Adapters.SQL.query(Nebu.Repo, "DELETE FROM server_config WHERE key = $1", [
              "log_retention_info_max_count"
            ])
          end
        end)

        Nebu.Admin.DB.upsert_server_config(%{"log_retention_info_max_count" => "750"})

        {:ok, policy} = Nebu.Web.LogStore.get_policy()

        assert policy[:log_retention_info_max_count] == 750,
               "get_policy/0 must reflect the just-set server_config value as an integer, got: #{inspect(policy[:log_retention_info_max_count])}"
      end
    end
  end
end
