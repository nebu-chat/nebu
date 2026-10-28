defmodule Nebu.Matrix.SyncRejoinRangeScanBoundDocsTest do
  @moduledoc """
  Static check (no DB, no network) for story `sync-rejoin-range-scan-bound`, D8: the deliberate documentation edits of the story, and only those.

    * `docs/stories/oauth-broker/follow-ups.md`: in row `cq`, item (f) becomes "(f) **CLOSED by story sync-rejoin-range-scan-bound (date): ...** **Original item:** <the original text of (f), verbatim>"
      (the closure names the gate, the segmented read, the floor and its documented residual, the replay guarantee, the rejected clamp and that design (1) needed the floor, and that the stretch
      also existed for a `join` base); the items (a)-(e) and (g) and the status `open, non-gating` stay; `cq` stays ONE row; the note on `gk` says the range read of a room with a cursor is
      segment-driven where a hidden stretch is possible while (4) (no statement timeout on `/sync`) stays.
    * **The id line stays BYTE-IDENTICAL** (the paragraph "**Follow-up ids.**": this story takes no id). It is pinned by its length and SHA-256 (the exact line of the commit before this
      story) and by the two pins the older docs suites use (`unused:[^.]*`gm` onward` and `unused: `go` onward`). A LATER story that takes an id must amend THIS pin deliberately (old -> new).
    * `docs/architecture/06-runtime.md` (the "Incremental `/sync` by stream position" paragraph) and `docs/matrix-api-scope.md` (the `/sync` row) name the segmented re-join read.

  The closure of (f) and one paragraph of `06-runtime.md` must also name the two accepted residuals beyond the floor: skew plus an overflowing segment (a late
  commit with the highest position and an old timestamp is not read in the `limited` window, reachable by `/messages`, class `cq` (b)) and the O(M) cost of NEW visible events in the worst plan,
  never O(hidden history).

  The pins are facts and unique new terms (case-insensitive where the wording is the dev's), not whole sentences. They do NOT pin the state of any other follow-up row.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)
  @followups Path.join(@root, "docs/stories/oauth-broker/follow-ups.md")
  @runtime Path.join(@root, "docs/architecture/06-runtime.md")
  @scope Path.join(@root, "docs/matrix-api-scope.md")
  @story "sync-rejoin-range-scan-bound"

  # the byte-identical id line (D8): length in bytes and SHA-256 of the paragraph as it stands before this story
  @id_line_bytes 2680
  @id_line_sha256 "1773564f8df3a19fcc78a3f298bf4410f889e21edb93fbf56a2cc474075ba778"

  # the text of item (f) of row `cq` as it stands before this story (the closure keeps it verbatim after "**Original item:**")
  @original_f ~S"""
  the range read of a joined room WITH a cursor filters row by row in position order: after a re-join into a `joined` / `invited` room (base of class `leave` / `invite`) with fewer than 21 visible events since, it scans the invisible stretch between the old cursor and the re-join, and replaying the previous `next_batch` repeats that scan on every replay (Kassandra delta cycle 1, MEDIUM-1b: MUST be fixed or owner-accepted before the epic security gate; fix: treat a base of class `invite` / `leave` like an absent base and read the segment-driven page with an extra `room_pos > base.pos` bound, or clamp the range start to the viewer's join position; code review cycle 0 INFO-3; a room without a cursor uses the segment-driven page read, MEDIUM-1 of the security review; no statement timeout on `/sync` reads, `gk`)
  """

  # the accepted residuals beyond the floor (skew plus an overflowing segment; the cost of NEW visible events), named in the closure of (f) AND in the 06-runtime paragraph (wording is the dev's)
  @residual_pins [
    {~r/skew/i, "skew ..."},
    {~r/`limit \+ 1`|at least (21|`limit \+ 1`)|overflow|more than (20|21)/i, "... plus an overflow of one visible segment (limit + 1 events newer by timestamp)"},
    {~r/limited/i, "... only in a `limited` window"},
    {~r/`\/messages`/, "... the event stays reachable through `/messages` (timestamp order)"},
    {~r/new visible events/i, "the cost grows with the NEW VISIBLE events (O(M)) ..."},
    {~r/plan/i, "... in the worst plan (the bound is plan dependent) ..."},
    {~r/never[^.]*hidden history|independent of the hidden history/i, "... never with the hidden history"},
    # the floor residual is a TIME span, the cost regression for shared rooms, no hidden row returned (the floor probe reads at most 64), the empty window, and what the gated base-0 read of a
    # `join`-class base means for the user
    {~r/time span/i, "the floor residual is a TIME span (skew exceeding the time spread of the newest 64 events), not a count of positions"},
    {~r/`shared`[^;]*plain read was cheap/i, "for a `shared` / `world_readable` room the plain read was cheap, so the worst-plan cost is a regression there"},
    {~r/no hidden (ordinary )?row/i, "no hidden row is returned (the floor probe reads at most 64 rows, only their timestamp)"},
    {~r/empty window|window that is empty/i, "an empty floor window falls back"},
    {~r/next 64 positions/i, "the fallback is the next 64 POSITIONS above the base (a range, like the window)"},
    {~r/no floor/i, "when both ranges are empty there is no floor (cost only, no lost event)"},
    {~r/whose? (is|are) empty|when that is empty/i, "the hidden rows read are those of the window or, when that is empty, of its fallback range"},
    {~r/up to 20 legacy events/i, "the gated base-0 read of a join-class base can re-send up to 20 legacy events (limited / prev_batch possible)"}
  ]

  defp squash(text), do: String.replace(text, ~r/\s+/, " ")

  defp line(id) do
    lines = @followups |> File.read!() |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "| #{id} | "))
    assert length(lines) == 1, "the follow-up row #{id} must exist exactly once (found #{length(lines)})"
    squash(hd(lines))
  end

  defp text(id), do: line(id) |> String.split(" | ", parts: 3) |> Enum.at(1)
  defp status(id), do: line(id) |> String.split(" | ") |> List.last() |> String.trim_trailing(" |")

  # the closure of (f): from "(f) **CLOSED" up to "**Original item:**"; the original: from there up to the next item "; (d)"
  defp f_parts do
    row = text("cq")
    assert row =~ ~r/\(f\) \*\*CLOSED by story #{@story} \(\d{4}-\d{2}-\d{2}\)/, "item (f) opens with \"(f) **CLOSED by story #{@story} (date)\""
    [_before, from_f] = String.split(row, "(f) **CLOSED by story #{@story}", parts: 2)
    [closure, rest] = String.split(from_f, "**Original item:**", parts: 2)
    [original, _after] = String.split(rest, "; (d) the cursor storage", parts: 2)
    {closure, String.trim(original)}
  end

  # ─── cq (f) ─────────────────────────────────────────────────────────────────────

  describe "follow-ups: item (f) of row cq is closed by this story" do
    test "(f) opens with the CLOSED marker of this story and a date; the row keeps 4 cells and the status open, non-gating" do
      {_closure, _original} = f_parts()
      row = line("cq")
      assert length(String.split(row, " | ")) == 4, "a ` | ` inside the text shifts the table columns"
      assert status("cq") == "open, non-gating", "(a)-(e) and (g) stay open: the row stays open"
    end

    test "after **Original item:** the ORIGINAL text of (f) stands verbatim" do
      {_closure, original} = f_parts()
      assert original == squash(String.trim(@original_f)), "the original text of (f) must be kept word for word"
    end

    test "the closure names the gate, the segmented read, the floor and its residual, the replay, the clamp, design (1), the `join` base" do
      {closure, _original} = f_parts()

      pins = [
        {~r/gate/i, "the gate (which rooms use the segmented read: a base of class invite / leave, or the viewer's membership changed since the base)"},
        {~r/segment/i, "the segment-driven (segmented) range read"},
        {~r/floor/i, "the time floor"},
        {~r/\b64\b/, "the lookback of 64 positions"},
        {~r/residual/i, "the documented residual of the floor"},
        {~r/`cq` \(b\)/, "the residual is of class cq (b)"},
        {~r/replay/i, "the replay guarantee (D6)"},
        {~r/design \(2\)/i, "design (2) of the original item (the clamp) ..."},
        {~r/reject/i, "... was rejected"},
        {~r/design \(1\)/i, "design (1) of the original item needed the floor"},
        {~r/between (two|the) syncs|without (a|an intervening) sync|never synced in between/i, "the stretch also existed for a base of class `join` (the user left and re-joined between two syncs)"},
        {~r/`join`/, "... named by its class `join`"}
      ]

      for {pin, what} <- pins, do: assert(closure =~ pin, "the closure of (f) names #{what}")
      assert closure =~ "`delta_events!/5`", "the gate lives in delta_events!/5 (the arity is part of the pointer)"
      refute closure =~ "delta_events!/4"
    end

    test "the closure names the segment-overflow residual (skew, limited, /messages, cq (b)) and the O(M) cost of new visible events" do
      {closure, _original} = f_parts()
      for {pin, what} <- @residual_pins ++ [{~r/`cq` \(b\)/, "class cq (b)"}], do: assert(closure =~ pin, "the closure of (f) names #{what}")
    end

    test "the other items (a)-(e) and (g) are intact, in their order" do
      row = text("cq")

      items = [
        "(a) the partition read and the `:pg` room subscription are separate reads (former `fc` (g))",
        "(b) `/messages`, `/context`, the latest-per-slot reads, the D3 tie order and the history-visibility segments still order by `origin_server_ts`",
        "(c) events stored before migration 000053 have no position",
        "(d) the cursor storage is one row per (device, partition room) without a separate cap",
        "(e) a newly joined room keeps the joined-slice state of the incremental sync (`gg`)",
        # story cross-signing-upload-races closes (g): the item then reads "(g) **CLOSED by story ...** **Original item:** pre-existing first ...", so the
        # pin is the original wording WITHOUT the "(g) " label (the label of the closed item is pinned by cross_signing_upload_races_docs_test.exs)
        "pre-existing first cross-signing upload race (Kassandra INFO-3 of sync-token-per-device)"
      ]

      for item <- items, do: assert(row =~ item, "item kept: #{String.slice(item, 0, 40)}")
      positions = for item <- items, do: :binary.match(row, item) |> elem(0)
      assert positions == Enum.sort(positions), "the order of the items is unchanged"
      assert row =~ ~r/\A\*\*Residuals of the per-room stream positions \(story sync-stream-position\)\.\*\*/
    end

    test "cq is still ONE row, no follow-up id was taken: the id line is byte-identical and both older pins match" do
      cq_rows = @followups |> File.read!() |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "| cq | "))
      assert length(cq_rows) == 1

      id_lines = @followups |> File.read!() |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "**Follow-up ids.**"))
      assert [id_line] = id_lines, "the id paragraph exists once, as ONE line"
      assert byte_size(id_line) == @id_line_bytes, "the id line changed length: this story takes no id and must not touch the line"
      assert :crypto.hash(:sha256, id_line) |> Base.encode16(case: :lower) == @id_line_sha256, "the id line is not byte-identical"

      file = File.read!(@followups)
      assert file =~ ~r/unused:[^.]*`gm` onward/, "the pin of the older docs suites"
      assert file =~ "unused: `go` onward"
    end
  end

  describe "follow-ups: the note on gk" do
    test "gk: the range read is segment-driven where a hidden stretch is possible, (4) stays, the old sentence is gone" do
      gk = text("gk")
      assert gk =~ ~r/segment-driven where a hidden stretch is possible/i
      refute gk =~ "is not segment-driven", "the sentence of story sync-stream-position (the range read of a room with a cursor is not segment-driven) is obsolete"
      assert gk =~ "the `/sync` reads have NO statement timeout on purpose", "(4) is unchanged: NO statement timeout on /sync"
    end
  end

  # ─── 06-runtime.md ──────────────────────────────────────────────────────────────

  describe "docs/architecture/06-runtime.md" do
    # the "Incremental `/sync` by stream position" paragraph still exists, and ONE paragraph of the file (that one edited in place, or a paragraph the story adds right behind it) carries all the
    # facts about the segmented read: the wording and the place are the dev's
    test "a paragraph names the plain range, the segmented read (segments, floor of 64) for a re-join, and the replay cost" do
      paragraphs = @runtime |> File.read!() |> String.split(~r/\n[ \t]*\n/) |> Enum.map(&squash/1)
      assert Enum.any?(paragraphs, &String.starts_with?(&1, "**Incremental `/sync` by stream position")), "the paragraph \"Incremental `/sync` by stream position\" exists"
      candidates = Enum.filter(paragraphs, &(&1 =~ ~r/segmented/i and &1 =~ "sync-rejoin-range-scan-bound"))
      assert candidates != [], "a paragraph names the segmented read and this story"

      pins = [
        {~r/visible (history-visibility )?segments?/i, "driven by the visible segments"},
        {~r/\b64\b/, "the time floor of 64 positions"},
        {~r/floor/i, "the floor"},
        {~r/invitation|invite/i, "a base that is an invitation ..."},
        {~r/leave/i, "... or a leave"},
        {~r/plain/i, "the plain position range for a continuously joined room"},
        {~r/replay/i, "the replay cost"}
      ] ++ @residual_pins

      assert Enum.any?(candidates, fn paragraph -> Enum.all?(pins, fn {pin, _what} -> paragraph =~ pin end) end),
             "no single paragraph names all of: " <> Enum.map_join(pins, "; ", fn {_pin, what} -> what end)
    end
  end

  # ─── matrix-api-scope.md ────────────────────────────────────────────────────────

  describe "docs/matrix-api-scope.md" do
    test "the /sync row has one sentence for the re-join read and its cost bound, and keeps `does not move the anchor` and the s2_ wording" do
      row = @scope |> File.read!() |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "| GET | `/_matrix/client/v3/sync` | ")) |> squash()

      assert row =~ "sync-rejoin-range-scan-bound", "names this story (the unique term: `re-join` and `bounded` are in the row already)"
      assert row =~ ~r/re-join/i, "the re-join"
      assert row =~ ~r/segmented/i, "names the segmented read"
      assert row =~ ~r/bounded|independent of|does not depend/i, "and its cost bound"
      assert row =~ "does not move the anchor", "pinned by the wake-ups docs suite"
      assert row =~ "`s2_`", "the existing s2_ wording"
    end
  end
end
