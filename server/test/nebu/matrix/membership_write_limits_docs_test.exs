defmodule Nebu.Matrix.MembershipWriteLimitsDocsTest do
  @moduledoc """
  Static checks (no DB, no network) for story `rate-limits-join-invite-create-room` (follow-up `ey`), AC8 (docs) and the e2e override of D5:

    * `docs/matrix-api-scope.md`: the rows of `POST /createRoom`, `POST /join/{roomIdOrAlias}`, `POST /rooms/{roomId}/invite` and `GET /sync`;
    * `docs/architecture/07-deployment.md`: the RELEASE GATE paragraph (kept under the bold `**RELEASE GATE` prefix the docs helpers find)
      is LIFTED, the release note about the limits and the nine variables;
    * `docs/architecture/08-concepts.md`: the "Rate limiting (per user) - room membership writes" block;
    * `CHANGELOG.md` `[Unreleased]`: one entry;
    * `docs/stories/oauth-broker/follow-ups.md`: `ey` CLOSED (the old text kept after the closure sentence), the notes on `fa`, `eo`, `ex`,
      `fb`, the new rows `fh` and `fi`, the id line;
    * `scripts/e2e-ci.sh`: `NEBU_RATE_LIMIT_DISABLED` is overridable (CI default unchanged). This pin is GREEN from the ATDD step on: the
      script change is part of the e2e work the ATDD step was asked to do, the pin only guards it against a regression.

  The pins are facts and unique new terms, never whole sentences, so the wording stays free. Older docs suites keep pinning the texts of
  their own stories; the assertions this story made obsolete were re-pinned deliberately (the story's Change Log).
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)
  @deploy Path.join(@root, "docs/architecture/07-deployment.md")
  @concepts Path.join(@root, "docs/architecture/08-concepts.md")
  @scope Path.join(@root, "docs/matrix-api-scope.md")
  @followups Path.join(@root, "docs/stories/oauth-broker/follow-ups.md")
  @changelog Path.join(@root, "CHANGELOG.md")
  @e2e_script Path.join(@root, "scripts/e2e-ci.sh")
  @story "rate-limits-join-invite-create-room"

  @variables ~w(NEBU_RATE_LIMIT_CREATE_ROOM_PER_MIN NEBU_RATE_LIMIT_CREATE_ROOM_BURST NEBU_RATE_LIMIT_INVITE_PER_MIN NEBU_RATE_LIMIT_INVITE_BURST
                NEBU_RATE_LIMIT_JOIN_PER_MIN NEBU_RATE_LIMIT_JOIN_BURST NEBU_INVITE_MAX_PENDING_PER_INVITER NEBU_INVITE_MAX_PENDING_PER_INVITEE
                NEBU_INVITE_MAX_PENDING_PER_PAIR)

  defp read(p), do: File.read!(p) |> String.replace(~r/\s+/, " ")

  defp scope_row(prefix) do
    row = @scope |> File.read!() |> String.split("\n") |> Enum.find(&String.starts_with?(&1, prefix))
    assert row, "the scope doc has no row starting with #{prefix}"
    String.replace(row, ~r/\s+/, " ")
  end

  # the whole markdown line of a follow-up row (all cells), whitespace normalised
  defp followup_line(id) do
    line = @followups |> File.read!() |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "| #{id} | "))
    assert line, "the follow-up row #{id} does not exist"
    String.replace(line, ~r/\s+/, " ")
  end

  # the cells of a follow-up row: [id, text, origin, status]
  defp followup_cells(id), do: id |> followup_line() |> String.trim_leading("| ") |> String.trim_trailing(" |") |> String.split(" | ")

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

  # ── scope doc ───────────────────────────────────────────────────────────────

  test "scope doc: the createRoom row names the create_room tier, the per-invitee invite charge, the 429 as a divergence from the Rate-limited flag, the three caps with their 403 texts and the check order" do
    row = scope_row("| POST | `/_matrix/client/v3/createRoom` | ")

    assert row =~ "`create_room`"
    assert row =~ ~r/10\s*\/\s*min/ and row =~ ~r/burst\s*20/i, "10 / min, burst 20"
    assert row =~ "`invite`" and row =~ ~r/per invitee|for each invitee|per invited user/i, "the invite tier is charged per invitee"
    assert row =~ "429" and row =~ "M_LIMIT_EXCEEDED"
    assert row =~ ~r/divergence/i, "limiting createRoom is a divergence from the endpoint's flag, not a violation"
    assert row =~ ~r/Rate-limited[^|]{0,60}No/i, "spec: createRoom is 'Rate-limited: No'"

    for number <- ["500", "100", "10"], do: assert(row =~ number)
    assert row =~ "too many pending invitations", "the fixed 403 texts"
    assert row =~ "to this user" and row =~ "The invited user has too many pending invitations"
    assert row =~ "M_FORBIDDEN"
    assert row =~ ~r/existence[^|]{0,120}(pending|cap)/i, "the caps are the LAST step, after the existence read (D7 order)"
    assert row =~ ~r/all.or.nothing/i
  end

  test "scope doc: the join row names the join tier (12 / min, burst 30); an idempotent re-join is charged" do
    row = scope_row("| POST | `/_matrix/client/v3/join/{roomIdOrAlias}` | ")

    assert row =~ "`join`"
    assert row =~ ~r/12\s*\/\s*min/ and row =~ ~r/burst\s*30/i
    assert row =~ ~r/re-join/i and row =~ ~r/charged/i
    assert row =~ "429"
  end

  test "scope doc: the invite row names the invite tier (20 / min, burst 50), the caps, M_INVITE_BLOCKED as not implemented (fh), the charge before the no-op" do
    row = scope_row("| POST | `/_matrix/client/v3/rooms/{roomId}/invite` |")

    assert row =~ "`invite`"
    assert row =~ ~r/20\s*\/\s*min/ and row =~ ~r/burst\s*50/i
    assert row =~ "429"
    assert row =~ "too many pending invitations" and row =~ "500" and row =~ "100"
    assert row =~ "M_INVITE_BLOCKED" and row =~ "`fh`" and row =~ ~r/not implemented/i
    assert row =~ ~r/already.invited[^|]{0,120}(charged|429)|charged[^|]{0,120}already.invited/i, "the charge comes before the already-invited no-op"
  end

  test "scope doc: the sync row says rooms.invite has no per-response cap, bounded by the per-invitee cap (D10)" do
    row = scope_row("| GET | `/_matrix/client/v3/sync` | ")

    assert row =~ ~r/no per-response (invite )?cap/i
    assert row =~ ~r/per-invitee cap/i
  end

  # ── 07-deployment ───────────────────────────────────────────────────────────

  test "07-deployment: the RELEASE GATE paragraph says the gate is LIFTED by this story (ey CLOSED), the batch may be released to Element-based deployments, fh is split off, ex remains the gate for the ban route" do
    gate = gate_paragraph()

    assert gate =~ ~r/LIFTED/i
    assert gate =~ @story
    assert gate =~ "`ey`" and gate =~ ~r/CLOSED/i
    assert gate =~ ~r/may be released|can be released|is released|safe to release/i
    assert gate =~ ~r/Element-based deployments/i
    assert gate =~ "`fh`" and gate =~ "M_INVITE_BLOCKED"
    assert gate =~ ~r/per-inviter cap|pending caps?|caps of pending/i
    assert gate =~ "`ex`" and gate =~ ~r/ban route/i
    refute gate =~ ~r/must (still )?NOT be released[^.]{0,80}before `ey`/i, "the old gate sentence is gone"
  end

  test "07-deployment: the existing release-note points stay (security fix, Q1, invitations are shown, no unban, createRoom 400s, Q2) in the gate paragraph" do
    gate = gate_paragraph()

    assert gate =~ ~r/security fix/i
    assert gate =~ "Q1" and gate =~ "Q2"
    assert gate =~ ~r/invitations are shown/i
    # story moderation-routes-atomic-ban (DELIBERATE re-pin, AC18; old -> new): release note (1) said "NO API can issue a ban yet" and that the
    # guarantees are PARTIAL; the ban route exists and the member set AND event order are protected now, both phrases are REFUTED (the second one,
    # the PARTIAL line, is covered by AC17 (b), see the story's Change Log: it sits in the same test and is part of the same release note)
    refute gate =~ ~r/no API can issue a ban/i
    refute gate =~ ~r/PARTIAL/
  end

  test "07-deployment: the new release note: the tiers per node with their defaults, the three caps, the nine variables, the two rules, what Element users see, the disable switch (tiers yes, caps no), the per-node honesty sentence" do
    deploy = read(@deploy)

    for variable <- @variables, do: assert(deploy =~ variable, "07-deployment names #{variable}")

    assert deploy =~ ~r/`create_room`[^.]{0,200}10[^.]{0,80}20/, "create_room 10 / min, burst 20"
    assert deploy =~ ~r/`join`[^.]{0,200}12[^.]{0,80}30/, "join 12 / min, burst 30"
    assert deploy =~ ~r/burst\s*\/\s*rate[^.]{0,80}60/i, "the rule burst / rate <= 60"
    assert deploy =~ ~r/invite burst[^.]{0,80}50|burst of the `invite`[^.]{0,80}50/i, "the rule invite burst >= 50"
    assert deploy =~ "You do not have permission to invite", "what Element shows for a cap"
    assert deploy =~ ~r/Failed to join/i and deploy =~ ~r/Failure to create room/i, "the Element dialogs of a refused join / createRoom"
    assert deploy =~ ~r/NEBU_RATE_LIMIT_DISABLED[^.]{0,200}(not|does not|never)[^.]{0,80}cap/i, "the switch disables the tiers but not the caps"
    assert deploy =~ ~r/per node/i and deploy =~ ~r/N x|N times|up to N/, "with N nodes a user can spend up to N x the budget"
    assert deploy =~ "000050", "the migration"
  end

  # ── 08-concepts ─────────────────────────────────────────────────────────────

  # story membership-state-model (security cycle 2, DELIBERATE re-pin, AC19 (h); old -> new): the block heading is "room membership tiers (writes and the `members_read` read tier)":
  # "room membership writes" -> "room membership tiers" (the three tier rows, the caps and the per-node note are unchanged)
  test "08-concepts: a 'Rate limiting (per user) - room membership tiers' block with the three tiers (one table row each), the caps and the per-node note" do
    raw = File.read!(@concepts)
    assert [_, from_block] = String.split(raw, "Rate limiting (per user)", parts: 2), "the block exists"
    [block | _] = String.split(from_block, "\n**", parts: 2)

    for {tier, rate, burst} <- [{"create_room", "10", "20"}, {"invite", "20", "50"}, {"join", "12", "30"}] do
      line = block |> String.split("\n") |> Enum.find(&(&1 =~ "`#{tier}`"))
      assert line, "a line for the #{tier} tier"
      assert line =~ rate and line =~ burst, "#{tier}: #{rate} / min, burst #{burst}: #{line}"
    end

    flat = String.replace(block, ~r/\s+/, " ")
    assert flat =~ "room membership tiers"
    assert flat =~ ~r/pending/i and flat =~ "500" and flat =~ "100"
    assert flat =~ ~r/per node/i
  end

  # ── CHANGELOG ───────────────────────────────────────────────────────────────

  test "CHANGELOG: [Unreleased] has ONE entry for the behaviour change: tiers, caps, variables, the 403 texts, migration 000050" do
    raw = File.read!(@changelog)
    assert [_, after_unreleased] = String.split(raw, "## [Unreleased]", parts: 2)
    [unreleased | _] = String.split(after_unreleased, ~r/\n## \[/, parts: 2)

    entries = unreleased |> String.split(~r/\n- \*\*/) |> Enum.filter(&(&1 =~ "000050"))
    assert [entry] = entries, "exactly one entry names migration 000050"
    entry = String.replace(entry, ~r/\s+/, " ")

    assert entry =~ ~r/behaviou?r change/i
    assert entry =~ "`create_room`" and entry =~ "`invite`" and entry =~ "`join`"
    assert entry =~ "NEBU_RATE_LIMIT_" and entry =~ "NEBU_INVITE_MAX_PENDING_"
    assert entry =~ "too many pending invitations" and entry =~ "M_FORBIDDEN" and entry =~ "403"
    assert entry =~ "429"
  end

  # ── follow-ups ──────────────────────────────────────────────────────────────

  test "follow-ups: ey is CLOSED by this story (status column closed, closure sentence first, the old text kept after it so the older pins stay true)" do
    [id, text, origin, status] = followup_cells("ey")

    assert id == "ey"
    assert String.starts_with?(text, "**CLOSED by story #{@story} ("), "the text starts with the closure sentence: #{String.slice(text, 0, 120)}"
    assert String.downcase(status) =~ ~r/^closed/ and not (String.downcase(status) =~ "open"), "status column: #{status}"
    assert origin =~ @story or text =~ @story

    # the pins of the older suites on this row
    for word <- ["createRoom", "50", "invite", "rate limit", "/join", "/createRoom", "`ev` is shipped", "VISIBLE", "`ex`"] do
      assert text =~ word, "ey keeps #{inspect(word)}"
    end

    for word <- ["create_room", "per invitee", "500", "100", "10", "`fh`", "`fi`", "M_FORBIDDEN"] do
      assert text =~ word, "the closure sentence names #{inspect(word)}"
    end
  end

  test "follow-ups: the notes on fa, eo, ex and fb name the story (invite permission moved to fh; the namespace policy stays an owner decision; ex stays the ban-route gate; no revoke for the inviter)" do
    for {id, words} <- [
          {"fa", ["`fh`"]},
          {"eo", ["rate", "owner decision"]},
          {"ex", [~r/`?join`? tier/, "ban route"]},
          {"fb", ["`fi`"]}
        ] do
      line = followup_line(id)
      assert line =~ @story, "#{id} carries the note of #{@story}"
      for word <- words, do: assert(line =~ word, "#{id} mentions #{inspect(word)}")
    end
  end

  for {id, words} <- [
        {"fh", ["M_INVITE_BLOCKED", "m.invite_permission_config", "org.matrix.msc4155", "createRoom", "/sync", "v1.18"]},
        {"fi", ["per node", "soft", "concurren", "upgrade_room", "deactivated", "profile", "Helm"]}
      ] do
    test "follow-ups: the new row #{id} exists, is attributed to this story and is open (non-gating)" do
      [_, text, origin, status] = followup_cells(unquote(id))
      assert origin =~ @story
      assert String.downcase(status) =~ "open"
      for word <- unquote(words), do: assert(text =~ word, "#{unquote(id)} mentions #{word}")
    end
  end

  test "follow-ups: the id line lists fh - fj for this story and continues at ga" do
    f = read(@followups)
    assert f =~ "`fh`-`fj`: #{@story}"
    # story member-event-prev-content (DELIBERATE re-pin, AC9 (b); old -> new): `fk` - `fl` are used by that story, the unused ids continue at `fn` (review cycle 1 of the same story added `fm`) ("`fk` onward" before)
    # story event-size-limit (DELIBERATE re-pin, AC9 (b); old -> new): `fn` - `fp` are used by that story, the unused ids continue at `fq` ("`fn` onward" before)
    # story moderation-routes-atomic-ban (DELIBERATE re-pin, AC18; old -> new): `fq` - `fr` are used by that story, the unused ids continue at `fs` ("`fq` onward" before)
    # moderation-routes-atomic-ban review cycles 1 / 2 (DELIBERATE re-pin): `fs`-`fu` are used, unused ids continue at `fv`
    # story power-levels-enforcement (DELIBERATE re-pin, AC15 / AC16; old -> new): `fv`-`fz` are used by that story, the unused ids continue at `ga` ("`fv` onward" before)
    # story state-writer-redaction (DELIBERATE re-pin, AC15 (a); old -> new): `ga`-`gd` are used by that story, the unused ids continue at `ge` ("`ga` onward" before; the old note is refuted by state_writer_redaction_docs_test.exs)
    # story membership-state-model (DELIBERATE re-pin, AC15 (a); old -> new): `ge`-`gi` are used by that story, the unused ids continue at `gj` ("`ge` onward" before; the old note is refuted by membership_state_model_docs_test.exs)
    # story history-visibility-enforcement (DELIBERATE re-pin, AC21 (a); old -> new): `gj`-`gl` are used by that story, the unused ids continue at `gm` ("`gj` onward" before; the old note is refuted by history_visibility_docs_test.exs)
    assert f =~ ~r/unused:[^.]*`gm` onward/, "unused ids continue at gm"
    refute f =~ ~r/unused:[^.]*`fh` onward/, "the old `fh` onward note is gone"
  end

  # ── e2e override (D5) ───────────────────────────────────────────────────────

  test "scripts/e2e-ci.sh: NEBU_RATE_LIMIT_DISABLED is overridable with the CI default true (run B sets it to false)" do
    script = File.read!(@e2e_script)

    assert script =~ ~s(export NEBU_RATE_LIMIT_DISABLED="${NEBU_RATE_LIMIT_DISABLED:-true}"),
           "the export keeps the CI behaviour (true) unless the caller sets the variable"

    refute script =~ ~r/^\s*export NEBU_RATE_LIMIT_DISABLED=true\s*$/m, "no unconditional export left"
  end
end
