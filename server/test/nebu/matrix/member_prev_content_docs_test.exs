defmodule Nebu.Matrix.MemberPrevContentDocsTest do
  @moduledoc """
  Static checks (no DB, no network) for story `member-event-prev-content` (epic oauth-broker, follow-up `ff`, e2e known failure K10), AC9:

    * (a) `docs/matrix-api-scope.md`: the `GET /sync`, `GET .../messages`, `GET .../event/{eventId}` rows describe the three `unsigned` keys
      (`prev_content`, `prev_sender`, `replaces_state`: one batched lookup, the D3 tie order for member slots, absent without a predecessor,
      `rooms.leave` included, `rooms.invite` stripped events unchanged), the `/context` row is "not routed" (follow-up `fk`), and one sentence says
      that `prev_sender` / `replaces_state` are Synapse-compatible extensions outside the v1.18 text;
    * (b) `docs/stories/oauth-broker/follow-ups.md`: `ff` CLOSED (CLOSED style, `closed` status, "Original item" keeps the old words), notes on
      `eu`, `es`, `fa`, `fb`, `fc`, `fg`, the new rows `fk` and `fl`, the id line (`fk`-`fl`: this story, `fm`: its review cycle 1, unused from `fn`);
    * (c) `docs/architecture/06-runtime.md`: the "Key design facts" of the predecessor lookup name `fetch_state_predecessors/1`, the three keys,
      the member-slot order, the leave-section batch and the D8 rule (replacing "Nebu does not implement `prev_content`");
    * (d) `CHANGELOG.md` `[Unreleased]` `### Fixed`;
    * (e) the e2e files: `create-dm.feature` (scenario 3 without `@known-failure` and the K10 comment, header names `prev_content`),
      `e2e/KNOWN-FAILURES.md` (no K10 row, the "K10 was a server gap" paragraph), `dm.steps.ts` (header and poll comment without
      `@known-failure`; the assertion code is byte-identical: the poll line, the 60 s timeout and `.toContain(dmRoomId)` are pinned).

  The pins are facts and unique new terms, not whole sentences, so the wording stays free. The `fk` onward id-line assertions of the five older
  docs suites are DELIBERATELY re-pinned to `fn` onward (each with a comment naming this story); the old `fk` onward is refuted HERE.

  Pure file reads: `async: true`.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)
  @runtime Path.join(@root, "docs/architecture/06-runtime.md")
  @scope Path.join(@root, "docs/matrix-api-scope.md")
  @followups Path.join(@root, "docs/stories/oauth-broker/follow-ups.md")
  @changelog Path.join(@root, "CHANGELOG.md")
  @feature Path.join(@root, "e2e/features/element/dm/create-dm.feature")
  @known_failures Path.join(@root, "e2e/KNOWN-FAILURES.md")
  @steps Path.join(@root, "e2e/step-definitions/element/dm.steps.ts")
  @proto Path.join(@root, "proto/core.proto")
  @story "member-event-prev-content"

  defp read(p), do: File.read!(p) |> String.replace(~r/\s+/, " ")

  defp lines(p), do: p |> File.read!() |> String.split("\n")

  # the whole markdown line of a follow-up row (all cells), whitespace normalised
  defp followup_line(id) do
    line = Enum.find(lines(@followups), &String.starts_with?(&1, "| #{id} | "))
    assert line, "the follow-up row #{id} does not exist"
    String.replace(line, ~r/\s+/, " ")
  end

  defp scope_row(prefix) do
    row = Enum.find(lines(@scope), &String.starts_with?(&1, prefix))
    assert row, "the scope doc has no row starting with #{prefix}"
    String.replace(row, ~r/\s+/, " ")
  end

  # `n` characters of `text` from the first occurrence of `anchor`
  defp around(text, anchor, n) do
    case :binary.match(text, anchor) do
      {at, _} -> binary_part(text, at, min(n, byte_size(text) - at))
      :nomatch -> flunk("the text does not contain #{inspect(anchor)}")
    end
  end

  # ═══ (a) the scope doc ═══════════════════════════════════════════════════════════

  @sync_prefix "| GET | `/_matrix/client/v3/sync` | "

  test "scope doc (a): the /sync row says state events carry unsigned prev_content / prev_sender / replaces_state through ONE batched lookup" do
    row = scope_row(@sync_prefix)

    for word <- ["prev_content", "prev_sender", "replaces_state"], do: assert(row =~ word, "the sync row mentions #{word}")
    assert row =~ ~r/batched/i, "one batched lookup (no N+1)"
  end

  test "scope doc (a): the /sync row documents the member-slot tie order, the absent case, rooms.leave and the unchanged stripped events" do
    row = scope_row(@sync_prefix)

    assert row =~ ~r/member slots?/i, "the D3 tie order is applied to member slots"
    assert row =~ ~r/absent[^|]{0,60}predecessor|no predecessor|without (a )?predecessor/i, "absent without a predecessor"
    assert row =~ ~r/`rooms\.leave`[^|]{0,250}(predecessor|prev_content)|(predecessor|prev_content)[^|]{0,250}`rooms\.leave`/i, "rooms.leave carries them too"
    assert row =~ ~r/stripped[^|]{0,300}(unchanged|(no|never)[^|]{0,20}`?unsigned)/i, "rooms.invite stripped events stay unchanged (no unsigned)"
  end

  test "scope doc (a): ONE sentence says prev_sender and replaces_state are Synapse-compatible extensions outside the v1.18 text" do
    doc = read(@scope)
    windows = Regex.scan(~r/.{0,300}Synapse.{0,300}/s, doc) |> List.flatten() |> Enum.filter(&(&1 =~ "prev_sender"))

    assert windows != [], "a sentence naming Synapse and prev_sender"
    assert Enum.any?(windows, &(&1 =~ "replaces_state" and &1 =~ ~r/extension/i)), "...and replaces_state, calling them extensions"
    assert Enum.any?(windows, &(&1 =~ ~r/v1\.18|spec/i)), "...outside the spec text"
  end

  for {label, prefix} <- [
        {"/messages", "| GET | `/_matrix/client/v3/rooms/{roomId}/messages` | "},
        {"/event", "| GET | `/_matrix/client/v3/rooms/{roomId}/event/{eventId}` | "}
      ] do
    test "scope doc (a): the #{label} row says the same three keys, with no age (follow-up fl)" do
      row = scope_row(unquote(prefix))

      for word <- ["prev_content", "prev_sender", "replaces_state", "`fl`"], do: assert(row =~ word, "#{unquote(label)} mentions #{word}")
      assert row =~ ~r/no `?(unsigned\.)?age`?/i, "no age on #{unquote(label)} (the fl (b) gap)"
    end
  end

  test "scope doc (a): the /context row is NOT routed (follow-up fk), no longer a green tick" do
    row = scope_row("| GET | `/_matrix/client/v3/rooms/{roomId}/context/{eventId}` | ")

    assert row =~ "❌"
    refute row =~ "✅", "context is not routed"
    assert row =~ ~r/not routed/i
    assert row =~ "`fk`"
  end

  # ═══ (b) follow-ups ══════════════════════════════════════════════════════════════

  test "follow-ups (b): ff is CLOSED by this story (CLOSED style, status closed) and keeps its original words" do
    f = read(@followups)

    assert f =~ ~r/\| ff \| \*\*CLOSED by story #{@story} \(\d{4}-\d{2}-\d{2}\)/, "the CLOSED prefix like ea / ev / ez"
    line = followup_line("ff")
    assert line =~ ~r/\| closed \|\s*\z/, "the status column says closed"
    assert line =~ ~r/Original item/i, "the original item text stays (as ea does)"

    for word <- ["prev_content", "prev_sender", "getDMInviter", "m.direct", "sync-membership-partition"] do
      assert line =~ word, "ff keeps #{word} (sync_membership_partition_docs_test pins it)"
    end
  end

  for {id, patterns} <- [
        {"eu", ["D4", {:re, "decline", "i"}, {:re, "join\\s*(->|→)\\s*invite", ""}, {:re, "minor[^|]{0,80}(timestamp|deviation)", "i"}]},
        {"es", ["D8", {:re, "\\bomit", "i"}, {:re, "binding", "i"}, "history_visibility"]},
        {"fa", ["prev_content", "displayname"]},
        {"fb", [{:re, "predecessor", "i"}, {:re, "not marked", "i"}, {:re, "upgrade", "i"}]},
        {"fc", ["D3", "invite + 1", {:re, "predecessor", "i"}]},
        {"fg", [{:re, "predecessor", "i"}, {:re, "(one|single|1)[^|]{0,40}(statement|lookup|query)", "i"}, {:re, "unparseable", "i"}]}
      ] do
    test "follow-ups (b): the existing row #{id} carries a '**Note (member-event-prev-content, <date>):**' with the facts of this story" do
      row = followup_line(unquote(id))

      assert row =~ ~r/\*\*Note \(#{@story}, [^)]+\):\*\*/, "#{unquote(id)}: the note is labelled like the other notes of this file"

      for pattern <- unquote(Macro.escape(patterns)) do
        case pattern do
          p when is_binary(p) -> assert row =~ p, "#{unquote(id)} mentions #{p}"
          {:re, source, opts} -> assert row =~ Regex.compile!(source, opts), "#{unquote(id)} matches /#{source}/"
        end
      end
    end
  end

  test "follow-ups (b): the new rows fk (/context is not routed) and fl (unsigned completeness leftovers) exist and are attributed to this story" do
    fk = followup_line("fk")
    fl = followup_line("fl")

    assert fk =~ @story and fl =~ @story, "attributed to #{@story}"
    for word <- ["/context", "not routed"], do: assert(fk =~ word, "fk mentions #{word}")
    for word <- ["unsigned.membership", "/members", "/initialSync"], do: assert(fl =~ word, "fl mentions #{word}")
    assert fl =~ ~r/redact/i, "fl (d): the redaction rule"
    assert fl =~ ~r/unsigned\.age|`age`/, "fl (b): no age on /messages, /event, /relations"
  end

  test "follow-ups (b): the id line lists fk - fl for this story, fm for its review cycle 1 and continues at ga (the old 'fk onward' is gone)" do
    f = read(@followups)

    assert f =~ "`fk`-`fl`: #{@story}"
    assert f =~ "`fm`: #{@story}", "review cycle 1 recorded its cleanup item as fm"
    # story event-size-limit (DELIBERATE re-pin, AC9 (b); old -> new): `fn` - `fp` are used by that story, the unused ids continue at `fq` ("`fn` onward" before)
    # story moderation-routes-atomic-ban (DELIBERATE re-pin, AC18; old -> new): `fq` - `fr` are used by that story, the unused ids continue at `fs` ("`fq` onward" before)
    # moderation-routes-atomic-ban review cycles 1 / 2 (DELIBERATE re-pin): `fs`-`fu` are used, unused ids continue at `fv`
    # story power-levels-enforcement (DELIBERATE re-pin, AC15 / AC16; old -> new): `fv`-`fz` are used by that story, the unused ids continue at `ga` ("`fv` onward" before)
    # story state-writer-redaction (DELIBERATE re-pin, AC15 (a); old -> new): `ga`-`gd` are used by that story, the unused ids continue at `ge` ("`ga` onward" before; the old note is refuted by state_writer_redaction_docs_test.exs)
    # story membership-state-model (DELIBERATE re-pin, AC15 (a); old -> new): `ge`-`gi` are used by that story, the unused ids continue at `gj` ("`ge` onward" before; the old note is refuted by membership_state_model_docs_test.exs)
    # story history-visibility-enforcement (DELIBERATE re-pin, AC21 (a); old -> new): `gj`-`gl` are used by that story, the unused ids continue at `gm` ("`gj` onward" before; the old note is refuted by history_visibility_docs_test.exs)
    assert f =~ ~r/unused:[^.]*`gm` onward/, "unused ids continue at gm"
    refute f =~ ~r/unused:[^.]*`fm` onward/, "fm is used since review cycle 1"
    refute f =~ ~r/unused:[^.]*`fk` onward/, "the old `fk` onward note is gone"
    assert f =~ "`fh`-`fj`: rate-limits-join-invite-create-room", "the earlier attribution stays"
  end

  # ═══ (c) 06-runtime ══════════════════════════════════════════════════════════════

  test "06-runtime (c): the key design facts name fetch_state_predecessors/1, the three keys, the member-slot order, the leave-section batch and the D8 rule" do
    doc = read(@runtime)

    assert doc =~ "fetch_state_predecessors/1"
    refute doc =~ "fetch_replaces_state/1", "the old function name is gone (renamed, no alias)"
    refute doc =~ "Nebu does not implement `prev_content`", "replaced by the D8 rule"

    # anchored on the heading of the facts block, not on the first mention of the function name (an early short mention elsewhere must not hide
    # the required words)
    assert doc =~ ~r/Key design facts/, "06-runtime keeps its 'Key design facts' block of the predecessor lookup"
    facts = around(doc, "Key design facts", 4_500)
    assert facts =~ "fetch_state_predecessors/1", "the facts block itself names the function"
    for word <- ["prev_content", "prev_sender", "replaces_state"], do: assert(facts =~ word, "the facts mention #{word}")
    assert facts =~ ~r/member slots?/i, "the D3 order for member slots"
    assert facts =~ ~r/`rooms\.leave`|leave section|leave window/i
    assert facts =~ ~r/batch|one (predecessor )?(statement|lookup|query)/i, "the leave section runs ONE batched lookup"
    assert facts =~ "history_visibility" and facts =~ "`es`", "the D8 rule: delivered whatever the visibility until es enforces it, then omitted when the predecessor is not visible"
  end

  test "proto/core.proto documents prev_content and prev_sender on Event and SyncRoomStateEvent next to replaces_state (D10)" do
    proto = File.read!(@proto)

    assert length(Regex.scan(~r/string\s+prev_content\s*=\s*\d+;/, proto)) == 2, "prev_content on the two messages"
    assert length(Regex.scan(~r/string\s+prev_sender\s*=\s*\d+;/, proto)) == 2, "prev_sender on the two messages"
    assert proto =~ ~r/prev_content[^\n]*\n?[^\n]*(JSON|predecessor)/i or proto =~ ~r/(JSON|predecessor)[^\n]*\n[^\n]*prev_content/i, "documented like replaces_state"
  end

  # ═══ (d) CHANGELOG ═══════════════════════════════════════════════════════════════

  test "CHANGELOG (d): [Unreleased] has a ### Fixed entry: prev_content / prev_sender, Element marks an accepted DM as a direct chat (ff), a declined invitation reads 'rejected the invitation'" do
    changelog = File.read!(@changelog)
    assert [_, from_unreleased] = String.split(changelog, "## [Unreleased]", parts: 2)
    [unreleased | _] = String.split(from_unreleased, ~r/\n## \[/, parts: 2)

    assert unreleased =~ "### Fixed", "[Unreleased] has a Fixed section"
    [_, from_fixed] = String.split(unreleased, "### Fixed", parts: 2)
    [fixed | _] = String.split(from_fixed, ~r/\n### /, parts: 2)
    fixed = String.replace(fixed, ~r/\s+/, " ")

    for word <- ["prev_content", "prev_sender", "`ff`"], do: assert(fixed =~ word, "the entry mentions #{word}")
    assert fixed =~ ~r/direct chat/i
    assert fixed =~ ~r/rejected the invitation/i, "the visible client effect (Element text of a declined invitation)"
  end

  # ═══ (e) the e2e files ═══════════════════════════════════════════════════════════

  defp scenario_block(feature, title) do
    [before, after_title] = String.split(feature, "Scenario: #{title}", parts: 2)
    tag_line = before |> String.split("\n") |> Enum.reverse() |> Enum.find(&(String.trim(&1) =~ ~r/^@/))
    {tag_line, after_title}
  end

  test "e2e (e): create-dm.feature scenario 3 has no @known-failure tag and no K10 comment, no stray blank lines inside the comment block, the header names prev_content" do
    feature = File.read!(@feature)

    {tag_line, _} = scenario_block(feature, "marie sees the DM invitation in Element and accepts it")
    assert tag_line =~ "@dm-invitee-ui", "the tag line of scenario 3"
    refute tag_line =~ "@known-failure", "scenario 3 is a normal scenario of the default run"
    assert tag_line =~ "@regression" and tag_line =~ "@ui"

    refute feature =~ "K10", "the K10 comment is gone"
    refute feature =~ ~r/\n  #[^\n]*\n\n  #/, "no comment lines separated by blank lines (the stray blank lines of the removed comment)"
    assert feature =~ "prev_content" and feature =~ "prev_sender", "the header comment says the DM is marked through the join's prev_content / prev_sender"

    # K9 is untouched: scenario 2 keeps its tag
    {k9_tag_line, _} = scenario_block(feature, "Starting a DM in Element Web invites the partner server-side")
    assert k9_tag_line =~ "@known-failure", "K9 (the UI scenario of the creator side) stays a known failure"
  end

  test "e2e (e): KNOWN-FAILURES.md has no K10 table row, keeps K9, and has the paragraph 'K10 was a server gap' (ff, this story)" do
    doc = File.read!(@known_failures)

    refute doc =~ ~r/^\| K10 \|/m, "the K10 table row is gone"
    assert doc =~ ~r/^\| K9 \|/m, "K9 stays"
    assert doc =~ ~r/K10 was a server gap/
    para = around(doc |> String.replace(~r/\s+/, " "), "K10 was a server gap", 700)
    assert para =~ "`ff`" and para =~ @story
  end

  test "e2e (e): dm.steps.ts header and the m.direct comment no longer talk about @known-failure; the assertion code of the step is byte-identical (poll line, 60 s timeout, toContain)" do
    src = File.read!(@steps)

    refute src =~ "@known-failure", "no @known-failure instruction in the steps file"
    refute src =~ "if it fails ONLY because", "the conditional instruction is gone"

    # the assertion of the m.direct step is NOT changed (the verified Element facts say it is exactly what Element writes)
    assert src =~ "{ message: 'm.direct lists the DM under the inviter', timeout: 60_000, intervals: [1_000, 2_000, 3_000] },"
    assert src =~ "      .toContain(dmRoomId);"
    assert src =~ "if (resp.status() !== 200) return [`m.direct answered ${resp.status()}`];"
    assert src =~ "return direct[inviter.matrixId] ?? [];"
  end
end
