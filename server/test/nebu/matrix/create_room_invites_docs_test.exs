defmodule Nebu.Matrix.CreateRoomInvitesDocsTest do
  @moduledoc """
  Static checks (no DB, no network) for story `create-room-invites-direct` (follow-up `eb`), AC17 (docs): the follow-ups rows (`eb` closed,
  `ez` / `fa` / `fb` new, the notes on `ev`, `ey`, `eq`, the id line), `docs/matrix-api-scope.md` (createRoom, invite, sync, kick / ban,
  the identity line of "Intentionally Excluded"), the behaviour-change paragraph and the RELEASE GATE paragraph of
  `docs/architecture/07-deployment.md` and the pointer in `docs/architecture/06-runtime.md` Scenario 3b.

  The pins are facts and unique new terms, not whole sentences, so the wording stays free. The sibling `create_room_presets_docs_test.exs`
  keeps pinning the texts of its own story; the assertions that the new story makes obsolete (the `eb` row text, the id line `ez onward`,
  the createRoom row naming `eb`, the "DMs do not work" wording) moved HERE with their new content (see the report of the ATDD step).
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)
  @deploy Path.join(@root, "docs/architecture/07-deployment.md")
  @runtime Path.join(@root, "docs/architecture/06-runtime.md")
  @scope Path.join(@root, "docs/matrix-api-scope.md")
  @followups Path.join(@root, "docs/stories/oauth-broker/follow-ups.md")
  @story "create-room-invites-direct"

  defp read(p), do: File.read!(p) |> String.replace(~r/\s+/, " ")

  # the table row that starts with `| <id> | `
  defp followup_row(id) do
    f = read(@followups)

    case String.split(f, "| #{id} | ", parts: 2) do
      [_, rest] -> rest |> String.split(" | ", parts: 2) |> hd()
      _ -> flunk("the follow-up row #{id} does not exist")
    end
  end

  # the markdown table rows of the scope doc that start with the given prefix
  defp scope_rows(prefix) do
    @scope |> File.read!() |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, prefix)) |> Enum.map(&String.replace(&1, ~r/\s+/, " "))
  end

  defp scope_row(prefix) do
    assert [row | _] = scope_rows(prefix), "the scope doc has no row starting with #{prefix}"
    row
  end

  # From the TITLE of this story's behaviour-change paragraph (a bold title that names the story within its first 200 characters, like the
  # presets paragraph) to the next markdown heading, whitespace normalised. The RELEASE GATE paragraph and other paragraphs may mention
  # the story id later in their text: they do not start with a bold title that names it, so they cannot anchor the section.
  defp deploy_section do
    raw = File.read!(@deploy)

    case Regex.run(~r/\n\*\*[^*\n]{0,200}story #{@story}/, raw, return: :index) do
      [{at, _}] ->
        rest = binary_part(raw, at, byte_size(raw) - at)
        [section | _] = Regex.split(~r/\n\#{2,4} /, rest, parts: 2)
        String.replace(section, ~r/\s+/, " ")

      nil ->
        flunk("07-deployment has no behaviour-change paragraph titled with story #{@story}")
    end
  end

  # the RELEASE GATE paragraph (it sits under the presets story's heading and is updated by this story)
  defp gate_paragraph do
    raw = File.read!(@deploy)

    case :binary.match(raw, "**RELEASE GATE") do
      {at, _} ->
        rest = binary_part(raw, at, byte_size(raw) - at)
        [para | _] = String.split(rest, "\n\n", parts: 2)
        String.replace(para, ~r/\s+/, " ")

      :nomatch ->
        flunk("07-deployment has no RELEASE GATE paragraph")
    end
  end

  # ── follow-ups ──────────────────────────────────────────────────────────────

  test "follow-ups: eb is CLOSED by this story and names what changed (invite, invite_3pid, is_direct, trusted_private_chat, D3 / D5 / D6 / D9 / D11)" do
    assert read(@followups) =~ "| eb | **CLOSED by story #{@story}"
    eb = followup_row("eb")

    for word <- ["invite", "`invite_3pid`", "`is_direct`", "`trusted_private_chat`", "M_NOT_FOUND", "M_THREEPID_DENIED", "50", "guard"] do
      assert eb =~ word, "the eb row mentions #{word}"
    end
  end

  test "follow-ups: ez is the SECURITY row (HIGH, release gate with ev; CLOSED by sync-membership-partition): left / kicked / banned / declined users and invitees receive rooms in rooms.join" do
    ez = followup_row("ez")
    assert ez =~ @story, "attributed to #{@story}"

    for word <- ["SECURITY", "HIGH", "`rooms.join`", "`rooms.leave`", "left", "kicked", "banned", "declined", "`ev`", "release gate", "forget"] do
      assert ez =~ word, "ez mentions #{word}"
    end

    assert ez =~ ~r/data minimi[sz]ation|access after removal/i, "the compliance relevance"
    # story sync-membership-partition (DELIBERATE re-pin): `ez` was open here ("fixed together with ev in the NEXT story"); that story closed
    # it. The original text (every word asserted above) stays in the closed row, like `ea` keeps its original item.
    assert read(@followups) =~ "| ez | **CLOSED by story sync-membership-partition", "ez is closed by the next story"
  end

  test "follow-ups: fa lists the invite API leftovers: reason, M_INVITE_BLOCKED / m.invite_permission_config, ignored users, the audit decision, displayname / avatar_url" do
    fa = followup_row("fa")
    assert fa =~ @story

    for word <- ["`reason`", "M_INVITE_BLOCKED", "m.invite_permission_config", "m.ignored_user_list", "audit", "displayname", "avatar_url"] do
      assert fa =~ word, "fa mentions #{word}"
    end

    assert fa =~ ~r/known deviation/i, "the reason handling is labelled a known deviation"
  end

  test "follow-ups: fb is the membership state model row: build_state_events lists joined members only, row-only invitations, a kick / revoke of a pending invitee (D9 (f))" do
    fb = followup_row("fb")
    assert fb =~ @story

    for word <- ["build_state_events", "kick_user", "revoke", "strictly greater", "trusted_private_chat", "upgrade"] do
      assert fb =~ word, "fb mentions #{word}"
    end
  end

  for {id, words} <- [
        {"ev", ["is_direct", "m.room.create", "getDMInviter", "synthesi", "pending-feature", "interim guard"]},
        {"ey", ["createRoom", "50", "invite"]},
        {"eq", ["`trusted_private_chat`", "100", "DM"]}
      ] do
    test "follow-ups: the existing row #{id} carries the note of this story" do
      row = followup_row(unquote(id))
      assert row =~ @story, "the note names the story"
      for word <- unquote(words), do: assert(row =~ word, "#{unquote(id)} mentions #{word}")
    end
  end

  test "follow-ups: the id line lists ez - fb for this story and continues at ga (story sync-membership-partition used fc - fg, story rate-limits-join-invite-create-room fh - fj)" do
    f = read(@followups)
    assert f =~ "`ez`-`fb`: #{@story}"
    # story sync-membership-partition (DELIBERATE re-pin): the unused ids continue at `fh` ("`fc` onward" before; fc - fg are used by that story,
    # its docs suite pins "`fc`-`fg`: sync-membership-partition")
    # story rate-limits-join-invite-create-room (DELIBERATE re-pin, AC9): `fh` - `fj` are used by that story, the unused ids continue at `fk`
    # story member-event-prev-content (DELIBERATE re-pin, AC9 (b); old -> new): `fk` - `fl` are used by that story, the unused ids continue at `fn` (review cycle 1 of the same story added `fm`) ("`fk` onward" before)
    # story event-size-limit (DELIBERATE re-pin, AC9 (b); old -> new): `fn` - `fp` are used by that story, the unused ids continue at `fq` ("`fn` onward" before)
    # story moderation-routes-atomic-ban (DELIBERATE re-pin, AC18; old -> new): `fq` - `fr` are used by that story, the unused ids continue at `fs` ("`fq` onward" before)
    # moderation-routes-atomic-ban review cycles 1 / 2 (DELIBERATE re-pin): `fs`-`fu` are used, unused ids continue at `fv`
    # story power-levels-enforcement (DELIBERATE re-pin, AC15 / AC16; old -> new): `fv`-`fz` are used by that story, the unused ids continue at `ga` ("`fv` onward" before)
    # story state-writer-redaction (DELIBERATE re-pin, AC15 (a); old -> new): `ga`-`gd` are used by that story, the unused ids continue at `ge` ("`ga` onward" before; the old note is refuted by state_writer_redaction_docs_test.exs)
    # story membership-state-model (DELIBERATE re-pin, AC15 (a); old -> new): `ge`-`gi` are used by that story, the unused ids continue at `gj` ("`ge` onward" before; the old note is refuted by membership_state_model_docs_test.exs)
    # story history-visibility-enforcement (DELIBERATE re-pin, AC21 (a); old -> new): `gj`-`gl` are used by that story, the unused ids continue at `gm` ("`gj` onward" before; the old note is refuted by history_visibility_docs_test.exs)
    assert f =~ ~r/unused:[^.]*`gm` onward/, "unused ids continue at gm (ez, fa, fb, fc - fg, fh - fj and fk - fl are used)"
    refute f =~ "`ez` onward", "the old `ez` onward note is gone"
  end

  # ── scope doc ───────────────────────────────────────────────────────────────

  test "scope doc: the createRoom row reads invite, invite_3pid and is_direct; the not-read list no longer names eb" do
    row = scope_row("| POST | `/_matrix/client/v3/createRoom` | ")

    for key <- ["`invite`", "`invite_3pid`", "`is_direct`"], do: assert(row =~ key, key)
    refute row =~ ~r/Not read yet\*\*[^|]{0,200}`eb`/, "`eb` is no longer a gap"
  end

  test "scope doc: the createRoom row documents the decisions with the Nebu-policy / Nebu-choice labels" do
    row = scope_row("| POST | `/_matrix/client/v3/createRoom` | ")

    # only terms and phrases that exist ONLY in the new text (the scope doc of today already has M_BAD_JSON, M_INVALID_PARAM,
    # M_INVALID_ROOM_STATE, trusted_private_chat, "Nebu policy", "fatal", "override", v10 and the cap of 50 for initial_state)
    for word <- ["Nebu choice", "M_NOT_FOUND", "M_FORBIDDEN", "M_THREEPID_DENIED", "`additional_creators`", "all-or-nothing", "invite must not contain the room creator", "at most 50"] do
      assert row =~ word, word
    end

    assert row =~ ~r/de-?dup|duplicates/i, "the silent de-duplication"
    assert row =~ ~r/fatal step 8|step 8[^|]{0,100}fatal/i, "step 8 is fatal (500, cleanup)"
  end

  test "scope doc: the invite row documents the shared path: the invite event, already invited 200, the body checks, user_id wins, reason as a known deviation, the Nebu-choice labels" do
    row = scope_row("| POST | `/_matrix/client/v3/rooms/{roomId}/invite` |")

    for word <- ["`m.room.member`", "M_NOT_JSON", "M_BAD_JSON", "M_MISSING_PARAM", "M_INVALID_PARAM", "M_THREEPID_DENIED", "M_NOT_FOUND", "M_FORBIDDEN", "`reason`", "Nebu choice"] do
      assert row =~ word, word
    end

    assert row =~ ~r/already invited/i, "an already invited user is 200 and nothing is written"
    assert row =~ ~r/known deviation/i, "reason is ignored: a known deviation"
    assert row =~ ~r/user_id[^.]*(wins|selects|takes precedence|precedence)|(wins|precedence)[^.]*user_id/i, "a present user_id selects the user-id form"
    assert row =~ ~r/banned/i and row =~ "403", "the earlier rows' rules stay"
  end

  # story sync-membership-partition (DELIBERATE re-pin; old -> new): the row named the interim guard of D11 and said rooms.invite / rooms.leave
  # were "still always empty" (follow-ups ev + ez). Now: both sections are served, the interim guard and the "still always empty" words are
  # gone, the row still names `ev` / `ez` (as the closed follow-ups that the partition delivers). The full new text: sync_membership_partition_docs_test.exs.
  test "scope doc: the sync row names rooms.invite / rooms.leave and the closed ev / ez, and no longer the interim guard or 'still always empty'" do
    row = scope_row("| GET | `/_matrix/client/v3/sync` | ")

    refute row =~ ~r/interim guard/i, "the interim guard of D11 is replaced"
    refute row =~ ~r/still always empty/i
    assert row =~ "`rooms.invite`" and row =~ "`rooms.leave`"
    assert row =~ "`ev`" and row =~ "`ez`"
  end

  test "scope doc: the kick and ban rows say that DM partners are at an equal level, so neither can kick or ban the other once the routes exist" do
    for prefix <- ["| POST | `/_matrix/client/v3/rooms/{roomId}/kick` |", "| POST | `/_matrix/client/v3/rooms/{roomId}/ban` |"] do
      row = scope_row(prefix)
      assert row =~ "DM", prefix
      assert row =~ ~r/equal/i, prefix
    end
  end

  test "scope doc: the Intentionally Excluded identity line says that 3pid invites are 403 M_THREEPID_DENIED" do
    row = scope_row("| `/_matrix/identity/*` |")
    assert row =~ "M_THREEPID_DENIED"
  end

  # ── 07-deployment ───────────────────────────────────────────────────────────

  test "07-deployment: the paragraph of this story names the clients' view: invitations from createRoom, invite events in the timeline, the new 4xx incl. the former 500s, DM partners at 100, no backfill" do
    sec = deploy_section()

    for word <- ["invite", "`invite_3pid`", "`is_direct`", "M_NOT_FOUND", "M_FORBIDDEN", "M_THREEPID_DENIED", "M_BAD_JSON", "M_INVALID_PARAM", "`ez`", "`ev`"] do
      assert sec =~ word, word
    end

    assert sec =~ ~r/power level 100|level 100|at 100/i, "DM partners are at power level 100"
    assert sec =~ ~r/500/, "the former 500s of POST /invite are named"
    assert sec =~ ~r/not backfilled|no backfill|NOT backfilled/i, "existing pending invitations are not backfilled"
    assert sec =~ ~r/(no|without) invite (member )?event/i, "existing pending invitations have no invite event"
  end

  # story sync-membership-partition (DELIBERATE re-pin; old -> new): the paragraph said eb was done and the gate was ev + ez ("the INVITEE does
  # not see the invitation or the DM", "/join <room id>", "the creator side of a DM works"). Now ev + ez are CLOSED and the gate is `ey` (+ `ex`
  # for the ban route); the assertions about the invitee's view move to refutations (the old claims must be gone), "must not be released" stays.
  # The full new text: sync_membership_partition_docs_test.exs.
  # story rate-limits-join-invite-create-room (DELIBERATE re-pin, AC9; old -> new): "must not be released" -> refuted (the gate is lifted, `ey` is
  # CLOSED); "`ey`" stays asserted (the paragraph names the closed follow-up). The other refutations stay.
  test "07-deployment: the RELEASE GATE paragraph no longer says the branch must not be released (ey is CLOSED, the gate is lifted) and still does not claim that the invitee does not see invitations" do
    gate = gate_paragraph()

    refute gate =~ ~r/must not be released/i, "the gate is lifted by story rate-limits-join-invite-create-room"
    assert gate =~ "`ey`", "the paragraph names ey (CLOSED)"
    refute gate =~ ~r/gate is now `ev` \+ `ez`/, "ev + ez are closed"
    refute gate =~ ~r/invitee[^.]*(does not|cannot|not) see/i, "the invitee sees the invitation now"
    refute gate =~ "does not process `invite`", "createRoom processes invite now"
    refute gate =~ ~r/DMs? (do|does) not work|DMs cannot be created/i, "the old release-note wording is rewritten"
  end

  # ── 06-runtime ──────────────────────────────────────────────────────────────

  test "06-runtime: Scenario 3b says that the described buildLeaveRooms is the Go design and is NOT ported (pointer to ev / ez)" do
    raw = File.read!(@runtime)
    assert [_, from_3b] = String.split(raw, "## Scenario 3b", parts: 2)
    [section | _] = String.split(from_3b, "\n## ", parts: 2)
    section = String.replace(section, ~r/\s+/, " ")

    assert section =~ ~r/not ported|NOT ported|never ported/i
    assert section =~ "`ev`" and section =~ "`ez`"
  end
end
