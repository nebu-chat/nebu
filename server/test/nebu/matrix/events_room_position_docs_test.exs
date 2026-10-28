defmodule Nebu.Matrix.EventsRoomPositionDocsTest do
  @moduledoc """
  Static check (no DB, no network) for story `events-room-position` (epic oauth-broker, follow-up `fc`, story 1 of 2), D5 and the Test list item 4: the operator note of migration
  `000053_events_room_position` in `docs/architecture/07-deployment.md` (the story: "Operator note in the file and in `07-deployment.md`"; the note IN THE FILE is pinned by
  `migration/000053_events_room_position_test.exs`). `docs/stories/oauth-broker/follow-ups.md` is deliberately NOT pinned (the story names no follow-up row; story 2 edits it).

  ## Decisions of the ATDD step (ambiguities of the story)

    * The note is found by the migration number: the first PARAGRAPH (text between blank lines) of `07-deployment.md` that contains `000053`, plus the paragraphs directly after it up to the next one
      that starts with `**` or `#` (so a fenced block with the manual statements counts); its place in the file is free. The pins are facts and unique terms, not whole sentences.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)
  @deploy Path.join(@root, "docs/architecture/07-deployment.md")
  @story "events-room-position"

  defp squash(text), do: String.replace(text, ~r/\s+/, " ")

  # the note: the first paragraph that mentions migration 000053 and the paragraphs after it up to the next heading-like one, whitespace normalised and joined
  defp note do
    paragraphs = @deploy |> File.read!() |> String.split(~r/\n\s*\n/)

    case Enum.drop_while(paragraphs, &(not String.contains?(&1, "000053"))) do
      [] ->
        flunk("docs/architecture/07-deployment.md has no paragraph about migration 000053 (the operator note, D5)")

      [first | rest] ->
        following = Enum.take_while(rest, &(not (String.starts_with?(String.trim_leading(&1), "**") or String.starts_with?(String.trim_leading(&1), "#"))))
        [first | following] |> Enum.map_join(" ", &squash/1)
    end
  end

  describe "07-deployment: the operator note of migration 000053 (D5)" do
    test "it names the story, the migration, both columns, the index and the trigger" do
      note = note()
      assert note =~ @story
      for term <- ["000053", "rooms.event_pos", "events.room_pos", "events_room_pos_idx"], do: assert(note =~ term, "the note names #{term}")
      assert note =~ ~r/trigger/i, "the position is drawn by a BEFORE INSERT trigger"
    end

    test "it states the locks: one transaction, ACCESS EXCLUSIVE on events during the index build, reads and writes wait, maintenance window" do
      note = note()
      assert note =~ "ACCESS EXCLUSIVE"
      assert note =~ ~r/maintenance window/i
      assert note =~ ~r/one transaction|single transaction|inside a transaction|migration transaction/i
      assert note =~ ~r/reads and writes/i
    end

    test "it gives the manual pre-create path: two ADD COLUMN IF NOT EXISTS statements and CREATE UNIQUE INDEX CONCURRENTLY" do
      note = note()
      assert note =~ "ALTER TABLE events ADD COLUMN IF NOT EXISTS room_pos BIGINT"
      assert note =~ "ALTER TABLE rooms ADD COLUMN IF NOT EXISTS event_pos BIGINT NOT NULL DEFAULT 0"
      assert note =~ ~r/CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS events_room_pos_idx ON events \(room_id, room_pos\) WHERE room_pos IS NOT NULL/
      assert note =~ ~r/no-?op/i, "the file is then a no-op except the trigger"
    end

    test "it states the rollback: the down step, and that story sync-stream-position (the reader) comes first" do
      note = note()
      assert note =~ ~r/\bdown\b/i
      assert note =~ "sync-stream-position"
    end

    test "it tells the operator to check for an INVALID index after a failed CONCURRENTLY build (pg_index.indisvalid)" do
      assert note() =~ ~r/indisvalid/i
    end
  end
end
