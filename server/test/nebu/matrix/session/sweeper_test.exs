defmodule Nebu.Matrix.Session.SweeperTest do
  @moduledoc """
  Integration test for `enhanced-logging/operational-log-store` (AC8 —
  code-review N2): proves `Nebu.Matrix.Session.Sweeper`'s ACTUAL `:sweep`
  message handler (its real, running-process entry point — `sweep/0` itself
  is a private function, not part of any public API) really does call
  `Nebu.Web.LogStore.Retention.prune_operational_logs/0` as wired in
  `sweeper.ex`, rather than only exercising `Retention.prune_operational_logs/0`
  directly (already covered in isolation by `retention_test.exs`).
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  setup do
    Nebu.Release.migrate()

    sweeper_pid =
      case Process.whereis(Nebu.Matrix.Session.Sweeper) do
        nil -> start_supervised!(Nebu.Matrix.Session.Sweeper)
        pid -> pid
      end

    on_exit(fn ->
      if Process.whereis(Nebu.Repo) do
        Ecto.Adapters.SQL.query(
          Nebu.Repo,
          "DELETE FROM operational_logs WHERE message LIKE 'distinctive-sweeper-wiring-%'",
          []
        )

        Ecto.Adapters.SQL.query(Nebu.Repo, "DELETE FROM server_config WHERE key = $1", [
          "log_retention_info_days"
        ])
      end
    end)

    {:ok, sweeper: sweeper_pid}
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

  defp remaining_messages(pattern) do
    Ecto.Adapters.SQL.query!(
      Nebu.Repo,
      "SELECT message FROM operational_logs WHERE message LIKE $1",
      [pattern]
    )
    |> Map.fetch!(:rows)
    |> List.flatten()
  end

  # Forces the (hourly-scheduled) Sweeper to run its `:sweep` handler NOW,
  # then synchronizes on it having actually finished processing that message
  # before returning — `:sys.get_state/1` is only answered after every
  # previously-enqueued regular message (our own `:sweep` send below) has
  # already been handled, since both this send and the `:sys.get_state/1`
  # call originate from this same test process (Erlang preserves
  # per-sender-pair message ordering).
  defp force_sweep!(sweeper) do
    send(sweeper, :sweep)
    :sys.get_state(sweeper)
    :ok
  end

  describe "AC8: Sweeper.sweep/0 (via its :sweep message handler) actually invokes retention pruning" do
    test "an old INFO row seeded directly in operational_logs is pruned when the running Sweeper processes :sweep",
         %{sweeper: sweeper} do
      insert_log("info", "distinctive-sweeper-wiring-old-10d", 10)
      insert_log("info", "distinctive-sweeper-wiring-fresh-1d", 1)
      insert_log("warning", "distinctive-sweeper-wiring-warn-old-10d", 10)

      Nebu.Admin.DB.upsert_server_config(%{"log_retention_info_days" => "7"})

      force_sweep!(sweeper)

      remaining = remaining_messages("distinctive-sweeper-wiring-%")

      refute "distinctive-sweeper-wiring-old-10d" in remaining,
             "the real, running Sweeper process must prune an old INFO row via its own " <>
               "hourly :sweep handler — not just when Retention.prune_operational_logs/0 " <>
               "is called directly and separately"

      assert "distinctive-sweeper-wiring-fresh-1d" in remaining,
             "a fresh INFO row must survive the same sweep"

      assert "distinctive-sweeper-wiring-warn-old-10d" in remaining,
             "a WARN row must never be pruned by the INFO TTL clause"

      assert Process.alive?(sweeper),
             "the Sweeper process must still be alive after processing :sweep"
    end
  end
end
