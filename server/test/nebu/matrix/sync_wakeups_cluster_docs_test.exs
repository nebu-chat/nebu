defmodule Nebu.Matrix.SyncWakeupsClusterDocsTest do
  @moduledoc """
  Static check (no DB, no network) for story `sync-wakeups-cluster-wide`, Scenario 5 / D4: row `fe` of `docs/stories/oauth-broker/follow-ups.md` is closed.

  The row becomes "**CLOSED by story sync-wakeups-cluster-wide (date): ...**" followed by the ORIGINAL text, so the five docs tests that pin the `fe`
  text stay green: `sync_membership_partition_docs_test.exs` (`get_local_members`, `get_members`, `node-local`), `moderation_routes_docs_test.exs`
  and `power_levels_docs_test.exs` (`:pg.get_members/1`), `state_writer_redaction_docs_test.exs` (`:pg.get_members/1`, `write_state/5`),
  `membership_state_model_docs_test.exs` (`:pg.get_members/1`, `upgrade`). The pins are facts and unique new terms, not whole sentences.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)
  @followups Path.join(@root, "docs/stories/oauth-broker/follow-ups.md")
  @story "sync-wakeups-cluster-wide"
  @scope Path.join(@root, "docs/matrix-api-scope.md")
  @runtime Path.join(@root, "docs/architecture/06-runtime.md")
  @test_helper Path.join(@root, "server/test/test_helper.exs")
  @cluster_test Path.join(@root, "server/test/nebu/matrix/sync_wakeups_cluster_test.exs")

  defp read(p), do: File.read!(p) |> String.replace(~r/\s+/, " ")

  # the second cell of the table row that starts with `| fe | ` (the text), whitespace normalised
  defp fe_row do
    case String.split(read(@followups), "| fe | ", parts: 2) do
      [_, rest] -> rest |> String.split(" | ", parts: 2) |> hd()
      _ -> flunk("the follow-up row fe does not exist")
    end
  end

  # the whole markdown line of the row (all cells), whitespace normalised
  defp fe_line do
    line = @followups |> File.read!() |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "| fe | "))
    assert line, "the follow-up row fe does not exist"
    String.replace(line, ~r/\s+/, " ")
  end

  test "follow-ups: row fe starts with the CLOSED marker of this story and a date, and its status column is closed" do
    assert read(@followups) =~ ~r/\| fe \| \*\*CLOSED by story #{@story} \(\d{4}-\d{2}-\d{2}/, "the row opens with \"**CLOSED by story #{@story} (date)\""
    assert fe_line() =~ ~r/\| closed \|\s*\z/, "the status column is `closed` (it was `open, non-gating`)"
    refute fe_line() =~ "open, non-gating"
    # no " | " inside the text cell: the row is exactly `| fe | text | origin | closed |` (4 cells, the table does not shift)
    assert length(String.split(fe_line(), " | ")) == 4, "the row has exactly 4 cells (a ` | ` inside the text shifts the columns)"
  end

  test "follow-ups: the fe closure lists the converted sites of the sync wake-up path and the typing exception" do
    row = fe_row()

    # the converted writers (premise check table, sites 1-9); `emit_membership_event/4`, `send_event` and `emit_decline_event/2` are in the original text too
    for site <- ["emit_membership_event", "send_event", "do_create_room", "do_join_room", "leave_room", "create_personal_room", "emit_decline_event", "emit_state_event_at"] do
      assert row =~ site, "the closure lists #{site}"
    end

    # the exception, with its reason: the typing broadcasts send {:typing_update, _, _}, which no process consumes yet
    for word <- ["set_typing", "typing_expire", "typing_update"] do
      assert row =~ word, "the typing exception names #{word}"
    end

    assert row =~ ~r/no (process|consumer)|not consumed|nobody consumes|no `?server\/lib`? process/i, "the exception says why: nothing consumes the typing message"
  end

  test "follow-ups: the fe closure keeps the original text and every string the five sibling docs tests pin" do
    row = fe_row()

    assert row =~ "Long-poll wake-ups are node-local (cluster-safety)", "the original title stays"

    for word <- ["get_local_members", "get_members", "node-local", "`:pg.get_members/1`", "`write_state/5`", "upgrade", "`RoomAccountDataStore.notify_sync/2`"] do
      assert row =~ word, "the original text keeps #{word}"
    end
  end

  test "follow-ups: the fe row is still attributed to sync-membership-partition (origin column) and still listed once" do
    assert fe_line() =~ "sync-membership-partition (premise check)"
    assert length(String.split(File.read!(@followups), "\n| fe | ")) == 2, "exactly one row fe"
  end

  # ── code review cycle 0 (D5, m1 - m3, i1) ───────────────────────────────────────────────────────────────────────────────────

  test "follow-ups: the fe closure names the D5 fix (registry lag, one second per build, the anchor stays) and calls the two-node test a manual proof CI does not run" do
    row = fe_row()

    assert row =~ "D5"
    assert row =~ ~r/registry/i and row =~ ~r/1 s/ and row =~ "anchor", "the D5 sentence: the Horde registry, at most 1 s per build, the previous anchor is kept"
    assert row =~ ~r/manual/i and row =~ ~r/CI does not run|not run by CI/, "the :peer test is a manual opt-in proof"
  end

  test "follow-ups: row bz records the blocking-send risk of the Room.Server writers (open, non-gating, :nosuspend / :noconnect) and is unique" do
    assert length(String.split(File.read!(@followups), "\n| bz | ")) == 2, "exactly one row bz"
    line = @followups |> File.read!() |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "| bz | ")) |> String.replace(~r/\s+/, " ")

    assert line =~ "Room.Server writers can now block on a slow or dead distribution link"
    assert line =~ ":nosuspend" and line =~ ":noconnect"
    assert line =~ ~r/\| open, non-gating \|\s*\z/
    assert line =~ @story
    assert length(String.split(line, " | ")) == 4, "exactly 4 cells"
  end

  # ── code review cycle 1 (D5 revised: dead room dropped at once, start on demand after the bound, task budget, row be) ─────────────

  test "follow-ups: the fe closure says a dead room (archived / missing) is dropped at once, a down room is started on demand, only a transient failure keeps the anchor" do
    row = fe_row()

    assert row =~ ~r/dead room/ and row =~ ~r/archived/ and row =~ ~r/without pinning the anchor/, "a dead room does not pin the anchor"
    assert row =~ ~r/on demand/, "the room is started on demand after the bound"
    assert row =~ ~r/only a transient failure keeps the previous anchor/
    assert row =~ "`be`", "the tombstone gap is row be"
  end

  test "follow-ups: row be records the undelivered tombstone of an upgraded room (open, non-gating, freeze_old_room!) and is unique; the id line keeps its gm onward pin" do
    assert length(String.split(File.read!(@followups), "\n| be | ")) == 2, "exactly one row be"
    line = @followups |> File.read!() |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "| be | ")) |> String.replace(~r/\s+/, " ")

    assert line =~ "The tombstone of an upgraded room is not delivered"
    assert line =~ "freeze_old_room!" and line =~ ~r/from the database/
    assert line =~ ~r/\| open, non-gating \|\s*\z/
    assert line =~ @story
    assert length(String.split(line, " | ")) == 4, "exactly 4 cells"
    assert read(@followups) =~ ~r/unused:[^.]*`gm` onward/
    refute read(@followups) =~ ~r/unused: be,/, "be is used now"
  end

  # ── code review cycle 2 (m3: row bp, the never-starting room) ───────────────────────────────────────────────────────────────

  test "follow-ups: row bp records the non-archived room whose process can never start (pins the anchor, open, non-gating) and is unique; fe names it" do
    assert length(String.split(File.read!(@followups), "\n| bp | ")) == 2, "exactly one row bp"
    line = @followups |> File.read!() |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "| bp | ")) |> String.replace(~r/\s+/, " ")

    assert line =~ "whose process can never start still pins the client anchor"
    assert line =~ "load_members" and line =~ "build_init_state" and line =~ ~r/one request per second/
    assert line =~ ~r/\| open, non-gating \|\s*\z/
    assert line =~ @story
    assert length(String.split(line, " | ")) == 4, "exactly 4 cells"
    assert fe_row() =~ "`bp`", "the fe closure points to bp"
    refute read(@followups) =~ ~r/unused: bp,/, "bp is used now"
    assert read(@followups) =~ ~r/unused:[^.]*`gm` onward/
  end

  test "runtime doc and scope doc: dead rooms are dropped at once, start on demand after the bound, the task budget arithmetic (31 s of 35 s) and the known gap be" do
    runtime = read(@runtime)
    assert runtime =~ ~r/archived .*or missing is dropped at once/ and runtime =~ ~r/started once on demand/
    assert runtime =~ ~r/31 s of the 35 s task budget/ and runtime =~ ~r/which is why the bound is one second/

    scope = @scope |> File.read!() |> String.replace(~r/\s+/, " ")
    assert scope =~ ~r/started once on demand/ and scope =~ ~r/a dead room \(archived/ and scope =~ "Known gap `be`"
  end

  test "scope doc: the /sync row no longer lists fe as an open residual and says the wake-ups are cluster-wide (with the registry-lag rule)" do
    row = @scope |> File.read!() |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "| GET | `/_matrix/client/v3/sync` | ")) |> String.replace(~r/\s+/, " ")

    refute row =~ "`fe` (node-local wake-ups)"
    assert row =~ @story and row =~ "`:pg.get_members/1`"
    assert row =~ ~r/at most one second per build/ and row =~ ~r/does not move the anchor/
  end

  test "runtime doc: the /sync fanout is cluster-wide (:pg.get_members/1), the woken task re-reads from the database; the node-local wording is gone" do
    text = read(@runtime)

    refute text =~ "The sync handler runs inside the same node as the room/event-dispatch logic"
    assert text =~ "`:pg.get_members/1`" and text =~ ~r/cluster-wide/
    assert text =~ ~r/re-reads its state from the database/
  end

  test "tracked text does not name the git-excluded pipeline helper: the two-node proof is described by its plain command line" do
    helper = ".oauth-ci/" <> "cluster_test.sh"
    texts = [{"test_helper.exs", File.read!(@test_helper)}, {"sync_wakeups_cluster_test.exs", File.read!(@cluster_test)}]

    for {name, text} <- texts ++ [{"follow-ups fe row", fe_row()}, {"scope doc", File.read!(@scope)}] do
      refute text =~ helper, "#{name} names #{helper}"
    end

    for {name, text} <- texts do
      assert text =~ "elixir --name", "#{name} gives the command line (elixir --name <node>@127.0.0.1 --cookie <random> -S mix test --only cluster)"
      assert text =~ ~r/MANUAL/ and text =~ ~r/CI does not run/, "#{name}: a manual opt-in proof that CI does not run"
    end
  end
end
