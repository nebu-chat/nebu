defmodule Nebu.Matrix.CreateRoomPresetsDocsTest do
  @moduledoc """
  Static checks (no DB, no network) for story `create-room-presets-power-levels-topic` (follow-ups `ec`, `ef`, `ea`), AC15 (docs):
  the follow-ups rows (`ec`, `ef`, `ea` closed, notes on `eb` / `ad` / `ep`, new rows `eq` - `eu`, the id line), `docs/matrix-api-scope.md`
  (createRoom, the join rows, the unrouted `POST /rooms/{roomId}/join`, invite, PUT state, kick / ban), the behaviour-change paragraph of
  `docs/architecture/07-deployment.md` (old implicit behaviour, new rules, no backfill, the operator queries Q1 / Q2 with their limits,
  the new 400s) and the moduledoc of `Nebu.Matrix.Room.JoinRules` (it documents the security boundary).

  The pins are facts and unique new terms, not whole sentences, so the wording stays free.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)
  @deploy Path.join(@root, "docs/architecture/07-deployment.md")
  @scope Path.join(@root, "docs/matrix-api-scope.md")
  @followups Path.join(@root, "docs/stories/oauth-broker/follow-ups.md")
  @join_rules Path.join(@root, "server/lib/nebu/matrix/room/join_rules.ex")
  @story "create-room-presets-power-levels-topic"

  defp read(p), do: File.read!(p) |> String.replace(~r/\s+/, " ")

  # the table row that starts with `| <id> | `
  defp followup_row(id) do
    f = read(@followups)
    case String.split(f, "| #{id} | ", parts: 2) do
      [_, rest] -> rest |> String.split(" | ", parts: 2) |> hd()
      _ -> flunk("the follow-up row #{id} does not exist")
    end
  end

  # a markdown table row of the scope doc that starts with the given prefix (`| POST | `...` |`)
  defp scope_rows(prefix) do
    @scope |> File.read!() |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, prefix)) |> Enum.map(&String.replace(&1, ~r/\s+/, " "))
  end

  # ── follow-ups ──────────────────────────────────────────────────────────────

  for id <- ["ec", "ef", "ea"] do
    test "follow-ups: #{id} is closed by this story" do
      f = read(@followups)
      assert f =~ "| #{unquote(id)} | **CLOSED by story #{@story}", "the #{unquote(id)} row starts with CLOSED by story #{@story}"
    end
  end

  test "follow-ups: ec names the security fix (open join of every room, bans not enforced), ef the corrected premise (replacement, not a merge), ea the topic" do
    ec = followup_row("ec")
    assert ec =~ ~r/open[- ]join/i
    assert ec =~ ~r/ban/i
    assert ec =~ "m.room.join_rules"

    ef = followup_row("ef")
    assert ef =~ "power_level_content_override"
    assert ef =~ ~r/replace/i, "the corrected premise: spec semantics of an initial_state power_levels entry is a replacement, not a merge"
    assert ef =~ "M_INVALID_ROOM_STATE"

    ea = followup_row("ea")
    assert ea =~ "m.topic"
    assert ea =~ "1024"
  end

  for {id, words} <- [
        {"eq", ["events", "redact", "notifications", "m.room.power_levels"]},
        {"er", ["initial_state", "m.room.power_levels", "replacement"]},
        {"es", ["history_visibility", "guest_access"]},
        {"et", ["visibility", "unban", "m.room.join_rules"]},
        {"eu", ["tie", "ban", "origin_server_ts"]},
        # review cycle 1
        {"ev", ["rooms.invite", "invite_state", "create-room-invites-direct", "must not be released"]},
        {"ew", ["upgrade_room", "ban"]},
        # story moderation-routes-atomic-ban (DELIBERATE re-pin, AC18; old -> new): the `ex` row is CLOSED, so the status word "OPEN" is no longer
        # asserted here (it stays inside the kept "Original item" text); every other word is kept by the CLOSED rewrite
        {"ex", ["gate for the ban route", "ONE atomic", "Room.Server", "N-1b", "N-6", "EVENT order", "join event"]},
        {"ey", ["rate limit", "/join", "/createRoom"]}
      ] do
    test "follow-ups: the new row #{id} exists and is attributed to this story" do
      row = followup_row(unquote(id))
      assert row =~ @story, "attributed to #{@story}"
      for word <- unquote(words), do: assert(row =~ word, "#{unquote(id)} mentions #{word}")
    end
  end

  # story moderation-routes-atomic-ban (DELIBERATE re-pin, AC18; old -> new): the focused re-check (N-1b) reopened `ex` as OPEN ("the room-process check
  # protects the member set, not the event order"); the ban route is ONE atomic room-process call now, `ex` is CLOSED by that story. The kept words
  # ("MEMBER SET", "AFTER the ban event") live in the "Original item" text of the CLOSED row.
  test "follow-ups: ex is CLOSED by story moderation-routes-atomic-ban (the old OPEN gate text is kept as the original item)" do
    ex = followup_row("ex")
    assert ex =~ ~r/^\*\*CLOSED by story moderation-routes-atomic-ban \(\d{4}-\d{2}-\d{2}\)/, "ex starts with the closure sentence"
    assert read(@followups) =~ ~r/\| ex \| \*\*CLOSED by story moderation-routes-atomic-ban/
    assert ex =~ ~r/MEMBER SET/
    assert ex =~ ~r/AFTER the ban event/
    assert ex =~ "Original item", "the old text is kept after the closure sentence"
  end

  # story moderation-routes-atomic-ban (DELIBERATE re-pin, AC18; old -> new): the join and ban rows said the guarantees are partial (member set yes,
  # event order no) and that no API can issue a ban yet; now the ban route exists, `ex` is CLOSED and BOTH the member set and the event order are
  # protected. "member set" / "event order" are still named, as protected; "No API can issue a ban yet" and "partial" are refuted.
  test "scope doc: the join and ban rows say that the member set AND the event order are protected (ex CLOSED) and that a ban can be issued" do
    [join | _] = scope_rows("| POST | `/_matrix/client/v3/join/{roomIdOrAlias}` | ")
    [ban] = scope_rows("| POST | `/_matrix/client/v3/rooms/{roomId}/ban` |")

    for row <- [join, ban] do
      assert row =~ ~r/member set/i
      assert row =~ ~r/event order/i
      assert row =~ "`ex`"
      assert row =~ "CLOSED", "ex is closed"
      assert row =~ ~r/member set AND (the )?event order are protected/
      refute row =~ ~r/partial/i, "the guarantees are no longer partial"
      refute row =~ ~r/event order is not/i
    end

    refute ban =~ ~r/No API can issue a ban yet/i
    refute join =~ ~r/window that remains is a ban and a join stamped in the SAME millisecond/
  end

  test "follow-ups: eb (trusted_private_chat invitee power level; CLOSED by story create-room-invites-direct since), ad (the topic part is closed, publication policy) and ep (override content bound)" do
    # story create-room-invites-direct (DATA adaptation): eb is closed by that story, its row no longer carries the note "DMs are
    # invite-only now"; the new row text is pinned in create_room_invites_docs_test.exs
    assert followup_row("eb") =~ "trusted_private_chat"

    ad = followup_row("ad")
    assert ad =~ @story
    assert ad =~ ~r/publication/i

    ep = followup_row("ep")
    assert ep =~ "power_level_content_override"
  end

  test "follow-ups: the id line lists eq - eu and ev - ey (review cycle 1) for this story and continues at ga (ez - fb: create-room-invites-direct, fc - fg: sync-membership-partition, fh - fj: rate-limits-join-invite-create-room)" do
    f = read(@followups)
    assert f =~ "`eq`-`eu`: #{@story}"
    assert f =~ "`ev`-`ey`: #{@story}"
    # story sync-membership-partition (DELIBERATE re-pin): `fc` - `fg` are used by that story, the unused ids continue at `fh` ("`fc` onward" before)
    # story rate-limits-join-invite-create-room (DELIBERATE re-pin, AC9): `fh` - `fj` are used by that story, the unused ids continue at `fk`
    # story member-event-prev-content (DELIBERATE re-pin, AC9 (b); old -> new): `fk` - `fl` are used by that story, the unused ids continue at `fn` (review cycle 1 of the same story added `fm`) ("`fk` onward" before)
    # story event-size-limit (DELIBERATE re-pin, AC9 (b); old -> new): `fn` - `fp` are used by that story, the unused ids continue at `fq` ("`fn` onward" before)
    # story moderation-routes-atomic-ban (DELIBERATE re-pin, AC18; old -> new): `fq` - `fr` are used by that story, the unused ids continue at `fs` ("`fq` onward" before)
    # moderation-routes-atomic-ban review cycles 1 / 2 (DELIBERATE re-pin): `fs`-`fu` are used, unused ids continue at `fv`
    # story power-levels-enforcement (DELIBERATE re-pin, AC15 / AC16; old -> new): `fv`-`fz` are used by that story, the unused ids continue at `ga` ("`fv` onward" before)
    # story state-writer-redaction (DELIBERATE re-pin, AC15 (a); old -> new): `ga`-`gd` are used by that story, the unused ids continue at `ge` ("`ga` onward" before; the old note is refuted by state_writer_redaction_docs_test.exs)
    # story membership-state-model (DELIBERATE re-pin, AC15 (a); old -> new): `ge`-`gi` are used by that story, the unused ids continue at `gj` ("`ge` onward" before; the old note is refuted by membership_state_model_docs_test.exs)
    # story history-visibility-enforcement (DELIBERATE re-pin, AC21 (a); old -> new): `gj`-`gl` are used by that story, the unused ids continue at `gm` ("`gj` onward" before; the old note is refuted by history_visibility_docs_test.exs)
    assert f =~ ~r/unused:[^.]*`gm` onward/, "unused ids continue at gm (eq - fl are used)"
    refute f =~ "`eq` onward", "the old `eq` onward note is gone"
  end

  # ── scope doc ───────────────────────────────────────────────────────────────

  test "scope doc: the createRoom row reads preset / visibility / topic / power_level_content_override and no longer lists them as not read" do
    [row] = scope_rows("| POST | `/_matrix/client/v3/createRoom` | 🔶 |")

    for key <- ["`preset`", "`visibility`", "`topic`", "`power_level_content_override`"], do: assert(row =~ key, key)
    refute row =~ "**Not read yet** (follow-ups `ea`, `eb`, `ec`, `ef`)", "the not-read list shrinks to what is still open"
    # story create-room-invites-direct (DATA adaptation): `invite` / `invite_3pid` / `is_direct` are READ keys now and `eb` is closed, so
    # the row no longer names `eb` as a gap (create_room_invites_docs_test.exs pins the new row)
    assert row =~ "`invite_3pid`", "invite_3pid is named (as a read key now)"
    refute row =~ ~r/Not read yet\*\*[^|]{0,200}`eb`/, "`eb` is closed"
  end

  test "scope doc: the createRoom row documents the decisions: errcodes, the Nebu-policy caps, the shallow merge, the preset skip, the initial_state power levels replacement, rooms.topic" do
    [row] = scope_rows("| POST | `/_matrix/client/v3/createRoom` | 🔶 |")

    for word <- [
          "M_INVALID_ROOM_STATE",
          "M_INVALID_PARAM",
          "1024",
          "4096",
          "Nebu policy",
          "Synapse",
          "shallow",
          "private_chat",
          "public_chat",
          "trusted_private_chat",
          "`rooms.topic`",
          "`er`"
        ] do
      assert row =~ word, word
    end

    assert row =~ ~r/replace/i, "the corrected wording for an initial_state m.room.power_levels entry (a replacement, not a merge)"
    # story power-levels-enforcement (DELIBERATE re-pin, AC15 / AC16; old -> new): the entry is APPLIED at step 6 now (follow-up `er` closed), so the
    # "documented deviation" of the skipped entry is gone from the row (power_levels_docs_test.exs refutes it and pins the new wording)
    refute row =~ ~r/deviation/i
    assert row =~ ~r/room_visibility_changed|audited/, "visibility public is stored through the audited path"
  end

  test "scope doc: the join row documents the D1 table: policy label for an absent rule, strict deny of private / unknown / malformed, ban, fail closed, the bypassing internal callers" do
    [row | _] = scope_rows("| POST | `/_matrix/client/v3/join/{roomIdOrAlias}` | ")

    for word <- ["M_FORBIDDEN", "ban", "private", "knock", "restricted", "`invite`"], do: assert(row =~ word, word)
    assert row =~ ~r/policy/i, "an absent join rule = invite is a Nebu / Synapse POLICY, not spec text"
    assert row =~ ~r/fail(s)? closed|fail-closed/i
    assert row =~ ~r/creator|auto-join/i, "the internal join callers that bypass the check are named"
    refute row =~ "Join by room ID or alias |", "the one-line description is replaced"
  end

  test "scope doc: POST /rooms/{roomId}/join is a row of its own: unrouted (🔲), and D1 must apply when it is added" do
    rows = scope_rows("| POST | `/_matrix/client/v3/rooms/{roomId}/join` | ")
    assert [row] = rows
    assert row =~ "🔲"
    assert row =~ ~r/unrouted/i
    assert row =~ ~r/D1|join decision|join rule/i, "the future route must go through the same decision"
  end

  test "scope doc: the invite row (a banned target is 403), the PUT state row (m.room.topic content rule), the kick / ban rows (a ban is enforced on join)" do
    [invite] = scope_rows("| POST | `/_matrix/client/v3/rooms/{roomId}/invite` |")
    assert invite =~ ~r/banned/i
    assert invite =~ "403"

    state_rows = scope_rows("| PUT | `/_matrix/client/v3/rooms/{roomId}/state/")
    assert Enum.any?(state_rows, &(&1 =~ "m.room.topic" and &1 =~ "1024")), "a PUT state row names the m.room.topic rule and its cap"

    [ban] = scope_rows("| POST | `/_matrix/client/v3/rooms/{roomId}/ban` |")
    assert ban =~ ~r/enforced/i and ban =~ ~r/join/i, "the ban row says that a ban is enforced on join"
  end

  # ── 07-deployment ───────────────────────────────────────────────────────────

  # From the story's paragraph to the next markdown heading (the paragraph and its SQL blocks), whitespace normalised
  defp deploy_section do
    raw = File.read!(@deploy)

    case :binary.match(raw, "story #{@story}") do
      {at, _} ->
        rest = binary_part(raw, at, byte_size(raw) - at)
        [section | _] = Regex.split(~r/\n\#{2,4} /, rest, parts: 2)
        String.replace(section, ~r/\s+/, " ")

      :nomatch ->
        flunk("07-deployment has no behaviour-change paragraph of story #{@story}")
    end
  end

  test "07-deployment: the paragraph states the OLD implicit behaviour (open join for any local user who knew the room id, explicit invite ignored, bans / kicks not enforced, no preset events)" do
    sec = deploy_section()

    assert sec =~ ~r/open.join|joined any room|any authenticated/i
    assert sec =~ ~r/room id/i
    assert sec =~ ~r/ignored/i
    assert sec =~ ~r/ban[^.]*(not enforced|were not|was not)/i
    assert sec =~ ~r/no preset|preset events/i
  end

  test "07-deployment: the new rules (join decision, presets, topic, visibility, override) and the new 400s clients can see" do
    sec = deploy_section()

    for word <- ["M_FORBIDDEN", "M_INVALID_ROOM_STATE", "M_INVALID_PARAM", "M_BAD_JSON", "`preset`", "`visibility`", "`topic`", "`power_level_content_override`", "1024"] do
      assert sec =~ word, word
    end

    assert sec =~ ~r/policy/i, "the absent-rule = invite POLICY label"
  end

  test "07-deployment: the six release-note points (security fix, Q1, invitations, DMs, Admin label, new 400s, Q2) and the release gate" do
    sec = deploy_section()

    # story rate-limits-join-invite-create-room (DELIBERATE re-pin, AC9; old -> new): the gate ("must not be released without the rooms.invite sync
    # section and eb, then before ey") is LIFTED, `ey` is CLOSED: refuted. The release-note assertions below stay.
    refute sec =~ ~r/must not be released/i, "the release gate is lifted (ey CLOSED, story rate-limits-join-invite-create-room)"
    assert sec =~ "rooms.invite"
    # story create-room-invites-direct (DATA adaptation): the old release note "DMs do not work until eb" is rewritten (the creator side of a
    # DM works, the invitee does not see the invitation until ev + ez): create_room_invites_docs_test.exs pins the new wording
    # story sync-membership-partition (DELIBERATE re-pin): release note (3) said "invitations are NOT shown in Element ... join with
    # `/join <room id>`"; ev + ez are closed, so the assertion on the `/join <room id>` wording moved to the new note:
    # "invitations are shown" (the full text: sync_membership_partition_docs_test.exs)
    assert sec =~ ~r/invitations are shown/i, "release note (3): invitations are shown now"
    assert sec =~ ~r/Visibility[^.]*label/i, "the Admin Visibility toggle is a label only"
    assert sec =~ ~r/no (Admin )?unban|has no unban/i, "no Admin unban"
    assert sec =~ ~r/leave[^.]*ban|ban[^.]*leave/i, "a leave does not lift a ban"
    assert sec =~ "jsonb_typeof(content) = 'string'", "Q1 lists the double-encoded join rule rows"
    # story moderation-routes-atomic-ban (DELIBERATE re-pin, AC18; old -> new): "NO API can issue a ban yet" and "PARTIAL" (member set yes, event
    # order no) are REFUTED, release note (1) says a ban can be issued now and that member set AND event order are protected
    refute sec =~ ~r/no API can issue a ban/i, "release notes (1) / (4): a ban can be issued now"
    refute sec =~ "PARTIAL", "the ban / join guarantees are no longer partial"
    assert sec =~ ~r/member set AND event order are protected/, "release note (1): member set AND event order are protected"
    assert sec =~ "Q3" and sec =~ "room_invitations", "the query for pending invitations held by current members"
  end

  test "07-deployment: existing rooms are NOT backfilled; rooms without a join rule are invite-only now; who is affected, how a room admin restores public access, opted-out auto-join users need an invite" do
    sec = deploy_section()

    assert sec =~ ~r/not backfilled|no backfill|NOT backfilled/i
    assert sec =~ ~r/invite-only|invite only/i
    assert sec =~ ~r/Security (&|and) Privacy|Access: Public|`m.room.join_rules`/i, "how a room admin restores public access"
    assert sec =~ ~r/opt(ed)?.out/i, "opted-out auto-join users"
  end

  test "07-deployment: the operator queries Q1 (rooms without any join rule) and Q2 (joins without an invitation) with their limits, checked in a rolled-back transaction" do
    sec = deploy_section()

    assert sec =~ "Q1"
    assert sec =~ "Q2"
    assert sec =~ ~r/rolled.back transaction/i
    assert sec =~ "room_invitations", "Q2 compares the joins with the invitation rows"
    assert sec =~ "is_auto_join", "Q2 leaves out auto-join rooms"
    assert sec =~ "creator_user_id", "Q1 / Q2 name the room creator"
    assert sec =~ "history_visibility", "Q1 shows whether a history_visibility event exists (Element private rooms have one)"
    assert sec =~ ~r/invitation row|one row per|per \(room, user\)/i, "Q2's limits: one invitation row per (room, user)"
    assert sec =~ ~r/Admin force.add/i, "Q2's limits: Admin force-adds have an invitation row"
  end

  # ── JoinRules moduledoc ─────────────────────────────────────────────────────

  test "JoinRules moduledoc: the decision table documents the security boundary (banned?, every rule, the policy label, the strict deny) and no longer says 'unchanged'" do
    src = File.read!(@join_rules)
    [_, doc] = Regex.run(~r/@moduledoc """(.*?)"""/s, src)
    doc = String.replace(doc, ~r/\s+/, " ")

    for word <- ["banned?", "knock", "knock_restricted", "private", "malformed", "policy", "`public`", "`invite`", "restricted"] do
      assert doc =~ word, word
    end

    refute doc =~ "anything else / absent | `:ok`", "the old open-join row is gone"
    refute doc =~ ~r/preserving the pre-story open-join behaviour/i
  end
end
