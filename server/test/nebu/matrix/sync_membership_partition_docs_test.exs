defmodule Nebu.Matrix.SyncMembershipPartitionDocsTest do
  @moduledoc """
  Static checks (no DB, no network) for story `sync-membership-partition` (follow-ups `ev` + `ez`), AC15 (docs): the `docs/matrix-api-scope.md`
  rows (`GET /sync`, `POST .../forget`, `POST /join`, `POST .../leave`), the RELEASE GATE paragraph and the release notes of
  `docs/architecture/07-deployment.md`, the pointer paragraph of story create-room-invites-direct, Scenario 3b of
  `docs/architecture/06-runtime.md`, the follow-ups file (`ev` / `ez` CLOSED, the notes to `eu` / `ey` / `fa` / `fb` / `es`, the new rows
  `fc` - `fg`, the id line) and the code-level docs (the `Nebu.Matrix.Http` moduledoc "MINOR-2" paragraph and the interim guard of the
  incremental sync are gone).

  The pins are facts and unique new terms, not whole sentences, so the wording stays free. Sibling suites keep pinning the texts of their own
  stories; the assertions that this story made obsolete moved HERE with their new content (`create_room_invites_docs_test.exs`,
  `create_room_presets_docs_test.exs`: their DELIBERATE re-pins are listed in the story's Change Log).
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)
  @deploy Path.join(@root, "docs/architecture/07-deployment.md")
  @runtime Path.join(@root, "docs/architecture/06-runtime.md")
  @scope Path.join(@root, "docs/matrix-api-scope.md")
  @followups Path.join(@root, "docs/stories/oauth-broker/follow-ups.md")
  @http Path.join(@root, "server/lib/nebu/matrix/http.ex")
  @core Path.join(@root, "server/lib/nebu/matrix/event_dispatcher/server.ex")
  @story "sync-membership-partition"

  defp read(p), do: File.read!(p) |> String.replace(~r/\s+/, " ")

  # the table row that starts with `| <id> | ` (the first cell)
  defp followup_row(id) do
    case String.split(read(@followups), "| #{id} | ", parts: 2) do
      [_, rest] -> rest |> String.split(" | ", parts: 2) |> hd()
      _ -> flunk("the follow-up row #{id} does not exist")
    end
  end

  # the whole markdown line of a follow-up row (all cells), whitespace normalised
  defp followup_line(id) do
    line = @followups |> File.read!() |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "| #{id} | "))
    assert line, "the follow-up row #{id} does not exist"
    String.replace(line, ~r/\s+/, " ")
  end

  defp scope_row(prefix) do
    row = @scope |> File.read!() |> String.split("\n") |> Enum.find(&String.starts_with?(&1, prefix))
    assert row, "the scope doc has no row starting with #{prefix}"
    String.replace(row, ~r/\s+/, " ")
  end

  # the RELEASE GATE paragraph of 07-deployment (up to the first blank line)
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

  # the behaviour-change section of a story: from its bold title (naming the story within 200 characters) to the next heading
  defp deploy_section(story) do
    raw = File.read!(@deploy)

    case Regex.run(~r/\n\*\*[^*\n]{0,200}story #{story}/, raw, return: :index) do
      [{at, _}] ->
        rest = binary_part(raw, at, byte_size(raw) - at)
        [section | _] = Regex.split(~r/\n\#{2,4} /, rest, parts: 2)
        String.replace(section, ~r/\s+/, " ")

      nil ->
        flunk("07-deployment has no behaviour-change paragraph titled with story #{story}")
    end
  end

  # ── follow-ups ──────────────────────────────────────────────────────────────

  for id <- ["ev", "ez"] do
    test "follow-ups: #{id} is CLOSED by this story (a CLOSED prefix like ea, the status column says closed) and keeps its original text" do
      id = unquote(id)
      assert read(@followups) =~ "| #{id} | **CLOSED by story #{@story} (2026-10-17)"
      assert followup_line(id) =~ ~r/\| closed \|\s*\z/, "#{id}: the status column is `closed`"
      assert followup_row(id) =~ ~r/Original item/i or followup_row(id) =~ "`rooms.join`" or followup_row(id) =~ "`rooms.invite`", "#{id}: the original item text stays (as ea does)"
    end
  end

  test "follow-ups: the ev closure names the partition, the invite_state, the newness anchor, the replaced interim guard, ignored users, the L-4 wake deferral and the real e2e scenario" do
    ev = followup_row("ev")

    for word <- ["partition", "invite_state", "D5", "interim guard", "ignored", "L-4", "e2e"] do
      assert ev =~ word, "ev mentions #{word}"
    end
  end

  test "follow-ups: the ez closure names the leave window, the tie rule, declined / left / kicked / banned / Admin-removed / re-invited and the re-pinned forget test" do
    ez = followup_row("ez")

    for word <- ["leave window", "tie", "declined", "kicked", "banned", "re-invited", "forget_room_membership_purge"] do
      assert ez =~ word, "ez mentions #{word}"
    end
  end

  for {id, words} <- [
        {"eu", ["READ side", "D3"]},
        {"ey", ["`ev` is shipped", "VISIBLE", "`ex`"]},
        {"fa", ["D8", "sync side"]},
        {"fb", ["synthesized"]},
        {"es", ["re-joined"]}
      ] do
    test "follow-ups: the existing row #{id} carries the note of this story" do
      row = followup_row(unquote(id))
      assert row =~ @story, "the note names the story"
      for word <- unquote(words), do: assert(row =~ word, "#{unquote(id)} mentions #{word}")
    end
  end

  for {id, words} <- [
        {"fc", ["timestamp anchor", "same millisecond", "committed", "stream position"]},
        {"fd", ["per user", "device", "`sync_tokens`", "fall"]},
        {"fe", ["get_local_members", "get_members", "node-local"]},
        {"ff", ["prev_content", "prev_sender", "getDMInviter", "m.direct"]},
        {"fg", ["include_leave", "pre-leave history", "forget", "knock", "ignored users", "taken-back"]}
      ] do
    test "follow-ups: the new row #{id} exists and is attributed to this story" do
      row = followup_row(unquote(id))
      assert followup_line(unquote(id)) =~ @story, "attributed to #{@story}"
      for word <- unquote(words), do: assert(row =~ word, "#{unquote(id)} mentions #{word}")
    end
  end

  test "follow-ups: the id line lists fc - fg for this story and continues at ga (ez - fb stay with create-room-invites-direct, fh - fj: rate-limits-join-invite-create-room)" do
    f = read(@followups)
    assert f =~ "`fc`-`fg`: #{@story}"
    assert f =~ "`ez`-`fb`: create-room-invites-direct", "the earlier attribution stays"
    # story rate-limits-join-invite-create-room (DELIBERATE re-pin, AC9): `fh` - `fj` are used by that story, the unused ids continue at `fk` ("`fh` onward" before)
    # story member-event-prev-content (DELIBERATE re-pin, AC9 (b); old -> new): `fk` - `fl` are used by that story, the unused ids continue at `fn` (review cycle 1 of the same story added `fm`) ("`fk` onward" before)
    # story event-size-limit (DELIBERATE re-pin, AC9 (b); old -> new): `fn` - `fp` are used by that story, the unused ids continue at `fq` ("`fn` onward" before)
    # story moderation-routes-atomic-ban (DELIBERATE re-pin, AC18; old -> new): `fq` - `fr` are used by that story, the unused ids continue at `fs` ("`fq` onward" before)
    # moderation-routes-atomic-ban review cycles 1 / 2 (DELIBERATE re-pin): `fs`-`fu` are used, unused ids continue at `fv`
    # story power-levels-enforcement (DELIBERATE re-pin, AC15 / AC16; old -> new): `fv`-`fz` are used by that story, the unused ids continue at `ga` ("`fv` onward" before)
    # story state-writer-redaction (DELIBERATE re-pin, AC15 (a); old -> new): `ga`-`gd` are used by that story, the unused ids continue at `ge` ("`ga` onward" before; the old note is refuted by state_writer_redaction_docs_test.exs)
    # story membership-state-model (DELIBERATE re-pin, AC15 (a); old -> new): `ge`-`gi` are used by that story, the unused ids continue at `gj` ("`ge` onward" before; the old note is refuted by membership_state_model_docs_test.exs)
    # story history-visibility-enforcement (DELIBERATE re-pin, AC21 (a); old -> new): `gj`-`gl` are used by that story, the unused ids continue at `gm` ("`gj` onward" before; the old note is refuted by history_visibility_docs_test.exs)
    assert f =~ ~r/unused:[^.]*`gm` onward/, "unused ids continue at gm"
    refute f =~ ~r/unused:[^.]*`fc` onward/, "the old `fc` onward note is gone"
  end

  # ── scope doc ───────────────────────────────────────────────────────────────

  test "scope doc: the sync row is rewritten: join / invite / leave, invite_state with m.room.create and the own invite event with is_direct, row-only synthesis, ignored users, once, the tie rule" do
    row = scope_row("| GET | `/_matrix/client/v3/sync` | ")

    for word <- ["`rooms.join`", "`rooms.invite`", "`rooms.leave`", "invite_state", "m.room.create", "is_direct", "row-only", "m.ignored_user_list", "`ban`"] do
      assert row =~ word, word
    end

    assert row =~ ~r/synthesi[sz]ed/i, "a row-only invitation gets a synthesized own member event"
    assert row =~ ~r/(never|not) repeated|once/i, "a leave is delivered once"
    assert row =~ ~r/same millisecond|most restrictive/i, "the tie rule"
    assert row =~ ~r/joined rooms only|only joined rooms/i, "rooms.join = joined rooms only"
    assert row =~ ~r/initial sync[^|]{0,120}invit/i, "the initial sync = join + invite"
  end

  test "scope doc: the sync row documents the Nebu choices: empty leave state, the state gap of a limited window, taken-back invitations, 503 M_UNAVAILABLE (not a spec errcode)" do
    row = scope_row("| GET | `/_matrix/client/v3/sync` | ")

    assert row =~ ~r/`state`[^|]{0,80}empty|empty[^|]{0,40}`state`/i, "the leave state is empty (Nebu choice)"
    assert row =~ ~r/limited[^|]{0,200}(gap|state changes)/i, "the state gap of a limited leave window"
    assert row =~ ~r/taken.back/i, "a taken-back invitation is a leave"
    assert row =~ "M_UNAVAILABLE"
    assert row =~ ~r/not a spec errcode|non-spec|not in the spec/i, "M_UNAVAILABLE is not a spec errcode (kept for consistency)"
  end

  test "scope doc: the sync row names the known deviations and decisions: filters / include_leave ignored (fg), full_state honoured, use_state_after not supported with /versions below v1.16" do
    row = scope_row("| GET | `/_matrix/client/v3/sync` | ")

    assert row =~ "`include_leave`" and row =~ ~r/KNOWN DEVIATION/i and row =~ "`fg`"
    assert row =~ "`full_state`"
    assert row =~ "`use_state_after`" and row =~ ~r/v1\.16/
    refute row =~ ~r/interim guard/i, "the interim guard is gone"
    refute row =~ ~r/still always empty/i
    refute row =~ ~r/rooms\.invite[^|]{0,40}rooms\.leave[^|]{0,40}still/i
  end

  test "scope doc: the forget row says an invitation clears a forget and a pending invitee can forget (200, spec 400: known deviation fg (c))" do
    row = scope_row("| POST | `/_matrix/client/v3/rooms/{roomId}/forget` |")

    assert row =~ ~r/invitation[^|]{0,40}clears[^|]{0,30}forget/i
    assert row =~ ~r/pending invitee[^|]{0,60}forget/i
    assert row =~ "400" and row =~ ~r/known deviation/i and row =~ "`fg`"
  end

  test "scope doc: the join row says a taken-back invitation does not grant the join; the leave row says the leaver gets rooms.leave once" do
    join = scope_row("| POST | `/_matrix/client/v3/join/{roomIdOrAlias}` | ")
    assert join =~ ~r/taken.back invitation[^|]{0,80}(does not|not) grant/i

    leave = scope_row("| POST | `/_matrix/client/v3/rooms/{roomId}/leave` |")
    assert leave =~ ~r/`rooms\.leave`[^|]{0,60}once/i
  end

  # ── 07-deployment ───────────────────────────────────────────────────────────

  # story rate-limits-join-invite-create-room (DELIBERATE re-pin, AC9; old -> new): the gate said "must not be released" before `ey`. `ey` is
  # CLOSED now and the gate is LIFTED: `must not be released` -> refuted, the paragraph names the closing story and says `ey` is CLOSED /
  # lifted. Everything else stays asserted (the new text still names ev / ez, M_INVITE_BLOCKED (split to `fh`), the per-inviter cap, `ex` and
  # the ban route). The full new text: membership_write_limits_docs_test.exs.
  test "07-deployment: the RELEASE GATE says ev and ez are CLOSED by this story; the gate is LIFTED by story rate-limits-join-invite-create-room (ey CLOSED); ex remains the gate for the ban route" do
    gate = gate_paragraph()

    refute gate =~ ~r/must not be released/i, "the gate is lifted"
    assert gate =~ "rate-limits-join-invite-create-room", "the paragraph names the story that lifts the gate"
    assert gate =~ ~r/LIFTED/i
    assert gate =~ @story
    assert gate =~ ~r/CLOSED/i
    assert gate =~ "`ev`" and gate =~ "`ez`"
    assert gate =~ "`ey`" and gate =~ ~r/rate limits?/i and gate =~ "M_INVITE_BLOCKED" and gate =~ ~r/per-inviter cap/i
    assert gate =~ "`ex`" and gate =~ ~r/ban route/i
    assert gate =~ ~r/invitations are now (VISIBLE|visible)|invite-spam vector is live/i
    refute gate =~ ~r/INVITEE does not see/i, "the old wording is gone"
    refute gate =~ ~r/gate is now `ev` \+ `ez`/, "ev + ez are no longer the gate"
  end

  test "07-deployment: the release notes say invitations are shown (older ones after the next initial sync) and a removed user stops receiving the room's events (SECURITY fix ez; fd)" do
    deploy = read(@deploy)

    assert deploy =~ ~r/invitations are shown/i
    assert deploy =~ ~r/Clear cache and reload|new login/i, "how invitations that exist before the update appear"
    assert deploy =~ ~r/initial sync/i
    assert deploy =~ ~r/stops receiving[^.]{0,80}events/i
    assert deploy =~ ~r/SECURITY fix, `ez`/, "named as a security fix"
    assert deploy =~ "`fd`", "multi-device leaves are missed (fd)"
    refute deploy =~ ~r/invitations are NOT shown in Element \(no `rooms.invite` in `\/sync`\)/, "release note (3) is replaced"
  end

  test "07-deployment: the paragraph of create-room-invites-direct points to this story (the invitee does see the invitation now)" do
    sec = deploy_section("create-room-invites-direct")

    assert sec =~ @story
    refute sec =~ ~r/INVITEE does not see/i
    assert sec =~ ~r/replaced|no longer/i, "the interim guard is described as replaced"
  end

  # ── 06-runtime ──────────────────────────────────────────────────────────────

  test "06-runtime: Scenario 3b says the Elixir partition replaces the Go buildLeaveRooms design (anchor-based newness, not sync_tokens.updated_at) and points to this story" do
    raw = File.read!(@runtime)
    assert [_, from_3b] = String.split(raw, "## Scenario 3b", parts: 2)
    [section | _] = String.split(from_3b, "\n## ", parts: 2)
    section = String.replace(section, ~r/\s+/, " ")

    assert section =~ @story
    assert section =~ ~r/partition/i
    assert section =~ ~r/anchor/i
    assert section =~ "updated_at"
    assert section =~ "buildLeaveRooms"
  end

  # ── code-level docs ─────────────────────────────────────────────────────────

  test "code docs: the Nebu.Matrix.Http moduledoc / comments no longer describe invite and leave as deferred (the MINOR-2 paragraph is gone) and name invite_state" do
    src = File.read!(@http)

    refute src =~ "MINOR-2", "the deferred-gap paragraph and its comment are replaced"
    refute src =~ ~r/invite\/leave deferred/i
    assert src =~ "invite_state"
  end

  test "code docs: the interim guard (pending_only_room_ids / pending_only_event?) and the stale 'Go buildInviteRooms / buildLeaveRooms can find it' comments are gone from the core" do
    src = File.read!(@core)

    refute src =~ "pending_only_room_ids"
    refute src =~ "pending_only_event?"
    refute src =~ "buildInviteRooms"
    refute src =~ "buildLeaveRooms"
  end
end
