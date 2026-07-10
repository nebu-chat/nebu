defmodule Nebu.Web.LogStore.WriterTest do
  @moduledoc """
  RED-phase ATDD tests for `enhanced-logging/operational-log-store` (AC6, AC7
  — the Writer GenServer's batching/flush behaviour and level-based filtering).

  Story: docs/stories/enhanced-logging/operational-log-store.md

  ## Why these MUST FAIL right now

  `Nebu.Web.LogStore.Writer` (server/lib/nebu/web/log_store/writer.ex) does not
  exist yet, and `operational_logs` does not exist yet either. Every test here
  either fails to start/resolve the Writer GenServer (`UndefinedFunctionError`
  / start_supervised! raising) or fails against a real Postgres because the
  table it flushes into does not exist.

  All tests need a live `Nebu.Repo` (batched INSERT is the whole point) and are
  tagged `:integration` — run via `make test-integration`, excluded from plain
  `mix test` (see test/test_helper.exs).
  """
  use ExUnit.Case, async: false

  require Logger
  import ExUnit.CaptureLog

  @moduletag :integration

  setup do
    Nebu.Release.migrate()

    # The Writer is not yet wired into Nebu.Application's supervision tree
    # (that is this story's AC6/AC2 boot-wiring work) — start it directly for
    # the test, mirroring how config/test.exs documents doing this for
    # SessionExpiryWorker ("Tests that require the worker start it directly").
    pid =
      case Process.whereis(Nebu.Web.LogStore.Writer) do
        nil -> start_supervised!(Nebu.Web.LogStore.Writer)
        existing -> existing
      end

    on_exit(fn ->
      if Process.whereis(Nebu.Repo) do
        Ecto.Adapters.SQL.query(
          Nebu.Repo,
          "DELETE FROM operational_logs WHERE message LIKE 'distinctive-writer-%'",
          []
        )

        Ecto.Adapters.SQL.query(Nebu.Repo, "DELETE FROM server_config WHERE key IN ($1, $2)", [
          "log_collect_info",
          "log_collect_debug"
        ])
      end
    end)

    {:ok, writer: pid}
  end

  # Polls the DB every 200ms (up to `timeout_ms`) until `sql` returns at
  # least `min_rows` rows, or fails the test. Avoids hardcoding a long
  # `Process.sleep(5_000)` for the writer's periodic flush interval while
  # remaining agnostic to the EXACT interval/threshold dev-story picks.
  defp wait_until_rows(sql, params, timeout_ms \\ 7_000, min_rows \\ 1) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until_rows(sql, params, deadline, min_rows)
  end

  defp do_wait_until_rows(sql, params, deadline, min_rows) do
    result = Ecto.Adapters.SQL.query!(Nebu.Repo, sql, params)

    cond do
      result.num_rows >= min_rows ->
        result

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("timed out waiting for rows matching #{sql} #{inspect(params)}")

      true ->
        Process.sleep(200)
        do_wait_until_rows(sql, params, deadline, min_rows)
    end
  end

  # code-review N2: deterministic replacement for a hardcoded
  # `Process.sleep(@flush_interval_ms + slack)` — forces the Writer to
  # process its buffered entries IMMEDIATELY (rather than waiting for its
  # periodic timer) by sending the same `:flush` message its own scheduled
  # timer sends, then synchronizes on the process actually having processed
  # it via `:sys.get_state/1` (a `gen_server` system call that is guaranteed
  # to be handled only after every previously-enqueued regular message —
  # our own `write_async/1` cast and the `:flush` send below — has already
  # been processed, since both originate from THIS test process and Erlang
  # preserves per-sender-pair message ordering).
  defp force_flush!(writer) do
    send(writer, :flush)
    :sys.get_state(writer)
    :ok
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC6 — accepts entries, buffers, flushes via batched INSERT
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC6: write_async/1 buffers and flushes to operational_logs" do
    test "10 entries queued via write_async/1 all appear in operational_logs, and the writer stays alive",
         %{
           writer: writer
         } do
      for i <- 1..10 do
        :ok =
          Nebu.Web.LogStore.Writer.write_async(%{
            level: "info",
            source: "test",
            message: "distinctive-writer-flush-test-#{i}",
            metadata: %{}
          })
      end

      result =
        wait_until_rows(
          "SELECT id FROM operational_logs WHERE message LIKE 'distinctive-writer-flush-test-%'",
          []
        )

      assert result.num_rows == 10,
             "expected all 10 write_async/1 entries to be flushed to operational_logs"

      assert Process.alive?(writer),
             "the writer must still be alive after a successful flush"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC6 — resilience: INSERT failures are logged at WARN, writer survives
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC6: writer survives INSERT failures" do
    test "an entry that violates operational_logs' NOT NULL level constraint logs WARN but does not crash the writer",
         %{writer: writer} do
      log_output =
        capture_log([level: :warning], fn ->
          # `level` is `NOT NULL` per AC1's schema — a nil level forces a real
          # Postgres constraint-violation error on flush, exercising the
          # "Nebu.Repo throws an error on INSERT" branch of AC6 without
          # needing to physically stop Nebu.Repo.
          :ok =
            Nebu.Web.LogStore.Writer.write_async(%{
              level: nil,
              source: "test",
              message: "distinctive-writer-insert-error-test",
              metadata: %{}
            })

          # Deterministically force the flush attempt now, instead of
          # sleeping until the periodic timer happens to fire (code-review
          # N2).
          force_flush!(writer)
        end)

      assert Process.alive?(writer),
             "the writer process must survive an INSERT failure (let-it-crash within the " <>
               "flush attempt only, not a full GenServer crash)"

      assert log_output =~ ~r/warn/i,
             "an INSERT failure must be logged at WARN level, got: #{inspect(log_output)}"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # code-review N1 — one bad row in a co-batched flush must not drop the
  # other, unrelated GOOD rows in the same buffer.
  # ══════════════════════════════════════════════════════════════════════════

  describe "code-review N1: a single malformed entry does not sink the whole co-batched flush" do
    test "9 good entries plus 1 NOT-NULL-violating entry queued together still land the 9 good rows",
         %{writer: writer} do
      capture_log([level: :warning], fn ->
        for i <- 1..9 do
          :ok =
            Nebu.Web.LogStore.Writer.write_async(%{
              level: "info",
              source: "test",
              message: "distinctive-writer-n1-cobatch-good-#{i}",
              metadata: %{}
            })
        end

        # The malformed entry (violates the NOT NULL `level` constraint) is
        # queued INTO THE SAME BUFFER as the 9 good entries above, then all
        # 10 are flushed together in one attempt.
        :ok =
          Nebu.Web.LogStore.Writer.write_async(%{
            level: nil,
            source: "test",
            message: "distinctive-writer-n1-cobatch-bad",
            metadata: %{}
          })

        force_flush!(writer)
      end)

      result =
        wait_until_rows(
          "SELECT id FROM operational_logs WHERE message LIKE 'distinctive-writer-n1-cobatch-good-%'",
          [],
          7_000,
          9
        )

      assert result.num_rows == 9,
             "all 9 good, co-batched entries must survive a single sibling entry's INSERT " <>
               "failure — the whole batch must not be dropped"

      bad_row =
        Ecto.Adapters.SQL.query!(
          Nebu.Repo,
          "SELECT id FROM operational_logs WHERE message = 'distinctive-writer-n1-cobatch-bad'",
          []
        )

      assert bad_row.num_rows == 0,
             "the genuinely malformed entry must still be the only one dropped"

      assert Process.alive?(writer),
             "the writer must still be alive after the fallback single-row retries"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC6 — genuine crash/restart: a killed Writer is restarted by its
  # supervisor (not just "survives a caught INSERT error internally", which
  # the previous describe block already covers). AC6's own design language
  # is "let-it-crash, natural backpressure" — this test proves the process
  # tree actually honors that: if the Writer dies for real, the supervisor
  # brings a fresh one back under the SAME registered name, and it resumes
  # accepting write_async/1 calls afterward.
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC6: writer crash/restart via supervisor" do
    test "a killed Writer process is restarted under the same name and resumes accepting entries",
         %{writer: writer} do
      ref = Process.monitor(writer)

      Process.exit(writer, :kill)

      assert_receive {:DOWN, ^ref, :process, ^writer, :killed}, 1_000,
        "expected the Writer to actually die from the :kill signal"

      # Poll for the supervisor to restart it under the same registered name
      # with a fresh pid (rather than assuming a fixed restart delay).
      new_pid = wait_until_registered(Nebu.Web.LogStore.Writer, writer, 5_000)

      assert new_pid != writer,
             "the restarted Writer must be a NEW process, not the killed one"

      assert Process.alive?(new_pid),
             "the restarted Writer must be alive"

      # And it must actually work again — not just be alive-but-broken.
      :ok =
        Nebu.Web.LogStore.Writer.write_async(%{
          level: "warning",
          source: "test",
          message: "distinctive-writer-post-restart-test",
          metadata: %{}
        })

      wait_until_rows(
        "SELECT id FROM operational_logs WHERE message = 'distinctive-writer-post-restart-test'",
        []
      )
    end
  end

  # Polls `Process.whereis/1` until it returns a pid different from
  # `old_pid` (the supervisor has finished restarting the child), or fails.
  defp wait_until_registered(name, old_pid, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until_registered(name, old_pid, deadline)
  end

  defp do_wait_until_registered(name, old_pid, deadline) do
    case Process.whereis(name) do
      pid when is_pid(pid) and pid != old_pid ->
        pid

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("timed out waiting for #{inspect(name)} to be restarted under a new pid")
        else
          Process.sleep(100)
          do_wait_until_registered(name, old_pid, deadline)
        end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AC7 — level-based filtering (WARN/ERROR always; INFO/DEBUG gated)
  # ══════════════════════════════════════════════════════════════════════════

  describe "AC7: level filtering respects server_config" do
    test "with log_collect_info/log_collect_debug both false, only WARN+ERROR entries persist; flipping log_collect_info to true then persists a new INFO entry" do
      # Unique per-test-run suffix: `docker compose down` (no `--volumes`) in
      # `make test-integration` does NOT reset the Postgres volume between
      # runs, so a fixed literal message string (e.g.
      # "distinctive-ac7-filter-warn-1") can collide with a leftover row from
      # an EARLIER test-integration invocation against the same volume,
      # producing spurious duplicates in the LIKE-matched result set below.
      # Scoping every message to this run (PID + unique integer) makes the
      # match set exact regardless of prior runs' leftovers.
      run_id = "#{System.unique_integer([:positive])}-#{:erlang.phash2(self())}"

      on_exit(fn ->
        if Process.whereis(Nebu.Repo) do
          Ecto.Adapters.SQL.query(
            Nebu.Repo,
            "DELETE FROM operational_logs WHERE message LIKE $1",
            ["%distinctive-ac7-filter-#{run_id}-%"]
          )
        end
      end)

      Nebu.Admin.DB.upsert_server_config(%{
        "log_collect_info" => "false",
        "log_collect_debug" => "false"
      })

      :ok = Nebu.Web.LogStore.attach_handler()

      with_log_level(:debug, fn ->
        Logger.info("distinctive-ac7-filter-#{run_id}-info-1")
        Logger.debug("distinctive-ac7-filter-#{run_id}-debug-1")
        Logger.warning("distinctive-ac7-filter-#{run_id}-warn-1")
        Logger.error("distinctive-ac7-filter-#{run_id}-error-1")
      end)

      # Poll (rather than sleep a fixed duration) until both expected rows
      # (WARN + ERROR) have landed — deterministic, and as fast as the
      # handler's cast + the writer's flush actually take (code-review N2).
      wait_until_rows(
        "SELECT message FROM operational_logs WHERE message LIKE $1",
        ["distinctive-ac7-filter-#{run_id}-%"],
        7_000,
        2
      )

      persisted =
        Ecto.Adapters.SQL.query!(
          Nebu.Repo,
          "SELECT message FROM operational_logs WHERE message LIKE $1",
          ["distinctive-ac7-filter-#{run_id}-%"]
        )
        |> Map.fetch!(:rows)
        |> List.flatten()

      assert "distinctive-ac7-filter-#{run_id}-warn-1" in persisted
      assert "distinctive-ac7-filter-#{run_id}-error-1" in persisted
      refute "distinctive-ac7-filter-#{run_id}-info-1" in persisted
      refute "distinctive-ac7-filter-#{run_id}-debug-1" in persisted

      assert length(persisted) == 2,
             "with INFO/DEBUG collection off, only WARN+ERROR (2 of 4 calls) must persist, got: #{inspect(persisted)}"

      # Flip the policy: subsequent INFO calls must now persist.
      Nebu.Admin.DB.upsert_server_config(%{"log_collect_info" => "true"})

      with_log_level(:debug, fn ->
        Logger.info("distinctive-ac7-filter-#{run_id}-info-2-after-flip")
      end)

      wait_until_rows(
        "SELECT id FROM operational_logs WHERE message = $1",
        ["distinctive-ac7-filter-#{run_id}-info-2-after-flip"]
      )
    end
  end

  defp with_log_level(level, fun) do
    original_level = Logger.level()
    Logger.configure(level: level)

    try do
      fun.()
    after
      Logger.configure(level: original_level)
    end
  end
end
