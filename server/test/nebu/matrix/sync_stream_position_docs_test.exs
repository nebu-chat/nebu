defmodule Nebu.Matrix.SyncStreamPositionDocsTest do
  @moduledoc """
  Static check (no DB, no network) for story `sync-stream-position`, D17: the deliberate documentation edits of the story, and only those.

    * `docs/stories/oauth-broker/follow-ups.md`: row `fc` is CLOSED ("**CLOSED by story sync-stream-position (date): ...**" followed by "**Original item:**" and the full original text, status
      `closed`), notes on `cj`, `eu`, `gg`, `gk` and `bp`, the one new row `cq`, and the id line (`unused:[^.]*`gm` onward` stays intact, `cq` is no longer listed as unused).
    * `docs/architecture/07-deployment.md`: the release note (one full sync per client, migrations 000053 / 000054 and their locks, a mixed version is a fallback).
    * `docs/architecture/06-runtime.md` (the sync flow) and `docs/matrix-api-scope.md` (the `/sync` row) name the story and the cursors.

  The pins are facts and unique new terms, not whole sentences. They do NOT pin the state of any other follow-up row (a status, a count, an origin cell): those change with later stories. The
  original text of `fc` is pinned by the tokens the other docs suites already pin (`sync_membership_partition_docs_test.exs` and friends) plus its opening words.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)
  @followups Path.join(@root, "docs/stories/oauth-broker/follow-ups.md")
  @deploy Path.join(@root, "docs/architecture/07-deployment.md")
  @runtime Path.join(@root, "docs/architecture/06-runtime.md")
  @scope Path.join(@root, "docs/matrix-api-scope.md")
  @story "sync-stream-position"

  defp read(p), do: File.read!(p) |> String.replace(~r/\s+/, " ")

  defp line(id) do
    lines = @followups |> File.read!() |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "| #{id} | "))
    assert length(lines) == 1, "the follow-up row #{id} must exist exactly once (found #{length(lines)})"
    lines |> hd() |> String.replace(~r/\s+/, " ")
  end

  defp text(id), do: line(id) |> String.split(" | ", parts: 3) |> Enum.at(1)
  defp cells(id), do: String.split(line(id), " | ")
  defp status(id), do: line(id) |> String.split(" | ") |> List.last() |> String.trim_trailing(" |")

  # ─── fc ─────────────────────────────────────────────────────────────────────────

  describe "follow-ups: row fc is closed by this story" do
    test "the row opens with the CLOSED marker of this story and a date, its status column is closed, and it keeps exactly 4 cells" do
      assert read(@followups) =~ ~r/\| fc \| \*\*CLOSED by story #{@story} \(\d{4}-\d{2}-\d{2}\)/, "the row opens with \"**CLOSED by story #{@story} (date)\""
      assert status("fc") == "closed"
      refute line("fc") =~ "open, non-gating"
      assert length(cells("fc")) == 4, "a ` | ` inside the text shifts the table columns"
    end

    test "after the closure comes `**Original item:**` and the ORIGINAL text, all the tokens the other docs suites pin included" do
      row = text("fc")
      [closure, original] = String.split(row, "**Original item:**", parts: 2)
      assert closure =~ "CLOSED by story #{@story}"
      assert original =~ "The timestamp anchor of the since token loses events (pre-existing, data completeness)"

      for token <- ["timestamp anchor", "same millisecond", "committed", "stream position", "`503`", "D3", "invite + 1", "predecessor", "latest + 1", "(d)", "initial `/sync`", "`state`"],
          do: assert(original =~ token, "the original text keeps #{token}")
    end

    test "the closure names (a)-(e) and (h) closed, (f) moot, (g) moved to `cq`, the prev_batch fix, the rollout fallback, the previous generation" do
      [closure, _original] = text("fc") |> String.split("**Original item:**", parts: 2)

      assert closure =~ ~r/\(a\)\s*-\s*\(e\)/ and closure =~ "(h)", "the closed items"
      assert closure =~ ~r/per-room positions/i and closure =~ ~r/cursor/i
      assert closure =~ ~r/\(f\)[^.]*moot/i, "(f): no anchor event any more"
      assert closure =~ ~r/\(g\)[^.]*`cq`/, "(g) moved to cq (a)"
      assert closure =~ "`prev_batch`", "the pre-existing wrong prev_batch is fixed"
      assert closure =~ ~r/rollout|one full sync|one-time/i and closure =~ ~r/fallback/i, "the one-time rollout fallback"
      assert closure =~ ~r/previous (`next_batch`|token|generation)/i, "the previous generation"
      assert closure =~ "`cj`", "the cj (b) mitigation"
    end
  end

  # ─── the notes ──────────────────────────────────────────────────────────────────

  describe "follow-ups: notes on cj, eu, gg, gk and bp" do
    for {id, words} <- [
          {"cj", ["\\(b\\)", "(?i)mitigated", "(?i)concurrent", "(?i)two generations"]},
          {"eu", ["(?i)tie-free", "origin_server_ts", "`cq`", "`fc` \\(d\\)"]},
          {"gg", ["(?i)state delta", "(?i)positions"]},
          {"gk", ["origin_server_ts", "`cq`"]},
          {"bp", ["(?i)cursor"]}
        ] do
      test "row #{id} carries a note of this story and its facts, and keeps exactly 4 cells" do
        id = unquote(id)
        assert length(cells(id)) == 4, "#{id}: a ` | ` inside the note shifts the table columns"
        assert text(id) =~ @story, "#{id} names #{@story}"
        [_before, note] = String.split(text(id), @story, parts: 2)
        for source <- unquote(words), do: assert(note =~ Regex.compile!(source), "#{id}: the note mentions #{source}")
      end
    end
  end

  # ─── cq ─────────────────────────────────────────────────────────────────────────

  describe "follow-ups: the new row cq" do
    test "exists once with 4 cells and is attributed to this story (its status is a living value: open now, closable later)" do
      assert length(cells("cq")) == 4
      assert Enum.at(cells("cq"), 2) =~ @story
      assert status("cq") =~ ~r/\A(open|closed)/i
      assert text("cq") =~ "Residuals of the per-room stream positions"
    end

    test "carries the five residuals (a)-(e) with their facts" do
      row = text("cq")
      for marker <- ["(a)", "(b)", "(c)", "(d)", "(e)"], do: assert(row =~ marker, "cq has the item #{marker}")
      assert row =~ "`:pg`", "(a): the partition read vs the :pg subscription gap"
      assert row =~ "`/messages`" and row =~ "origin_server_ts", "(b): the timestamp-ordered reads"
      assert row =~ ~r/backfill/i, "(c): old events have no position"
      assert row =~ ~r/one row per \(device, partition room\)/i, "(d)"
    end

    test "the id appears as a row start exactly once" do
      starts = @followups |> File.read!() |> String.split("\n") |> Enum.map(&Regex.run(~r/\A\| (\w+) \| /, &1)) |> Enum.reject(&is_nil/1) |> Enum.map(&List.last/1)
      assert Enum.count(starts, &(&1 == "cq")) == 1
      assert Enum.count(starts, &(&1 == "fc")) == 1
    end
  end

  describe "follow-ups: the id line" do
    test "still matches unused:[^.]*`gm` onward (eight docs suites pin it), no longer lists cq as unused, and records where cq went" do
      f = read(@followups)
      assert f =~ ~r/unused:[^.]*`gm` onward/, "unused ids continue at gm"
      refute f =~ "unused: `cq`", "cq is no longer listed as unused"
      refute f =~ "`cq` (deliberately free)", "the old wording is gone"
      assert f =~ "; `cq`, formerly deliberately free, is the row after `cm`: story #{@story}"
    end
  end

  # ─── release notes and scope ────────────────────────────────────────────────────

  describe "07-deployment: the release note of migrations 000053 / 000054" do
    defp note do
      paragraphs = @deploy |> File.read!() |> String.split(~r/\n\s*\n/) |> Enum.map(&String.replace(&1, ~r/\s+/, " "))
      Enum.find(paragraphs, &(&1 =~ "000054" and &1 =~ @story)) || flunk("no paragraph of 07-deployment.md names migration 000054 and story #{@story}")
    end

    test "names the story, the table, the sync_tokens columns and the dependency on migration 000053" do
      n = note()
      for word <- ["sync_room_cursors", "sync_tokens", "stream_version", "000053", "`fc`"], do: assert(n =~ word, "the note mentions #{word}")
    end

    test "tells operators: one full sync per client after the update, the locks of the migration, a mixed version is a fallback" do
      n = note()
      assert n =~ ~r/after the update each client does one full (initial )?sync/i
      assert n =~ "ACCESS EXCLUSIVE", "the brief lock on sync_tokens"
      assert n =~ ~r/no lock on `events`/i, "000054 does not touch events"
      assert n =~ ~r/maintenance window/i
      assert n =~ ~r/mixed[- ]version/i and n =~ ~r/fall ?back/i, "an old node's token is a fallback, never a misread"
    end

    test "tells operators how to roll back: down drops the table and the columns, every client falls back once more" do
      n = note()
      assert n =~ ~r/down/i and n =~ ~r/once (more|again)/i
    end
  end

  describe "06-runtime and matrix-api-scope name the story" do
    test "06-runtime describes the sync flow by position: the cursor table, the head statement, the guarded transaction, the previous generation" do
      r = read(@runtime)
      assert r =~ @story
      assert r =~ "`sync_room_cursors`"
      assert r =~ ~r/previous .{0,20}generation|previous `next_batch`/i
    end

    test "the /sync row of matrix-api-scope names the story, the real prev_batch and the one-time fallback" do
      row =
        @scope |> File.read!() |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "| GET | `/_matrix/client/v3/sync` |")) |> String.replace(~r/\s+/, " ")

      assert row =~ @story
      assert row =~ "`prev_batch`" and row =~ "`/messages`"
      assert row =~ "`limited"
      assert row =~ ~r/fallback/i
    end
  end
end
