defmodule Nebu.Matrix.ModerationRoutesDocsTest do
  @moduledoc """
  Static checks (no DB, no network) for story `moderation-routes-atomic-ban` (epic oauth-broker, follow-ups `ex`, `ew`, the revoke part of `fb`), AC17 (and the
  `docker-compose.yml` pin of AC2):

    * (a) `docs/matrix-api-scope.md`: the kick, ban and unban rows are green ticks with the D2-D6 / D10 rules and the seven explicit Oracle labels (each word for
      word), the `moderation` tier is labelled a divergence from "Rate-limited: No", the join row's open event-order caveat is rewritten as closed, the invite
      row says the ban check and the invite event are decided in the room process, the upgrade row says bans are carried (the S8 label, `fr`);
    * (b) `docs/architecture/07-deployment.md`: the paragraph "Room moderation: kick, ban, unban" (the tier and its two variables, the audit actions, Element's
      "Banned users" list, the upgrade, the operator query Q-half), the rewritten RELEASE GATE paragraph and release notes (1) and (4);
    * (c) `CHANGELOG.md` `[Unreleased]`: `### Added` and the `### Changed` warning entry;
    * (d) `docs/stories/oauth-broker/follow-ups.md`: `ex` and `ew` CLOSED (the pinned words of the older suites stay), the notes on `fb`, `eu`, `eq`, `et`, `fi`, `fg`,
      `fe`, `fa`, `fc`, `fp`, the new rows `fq` and `fr`, the id line (`fq`-`fr`: this story, unused from `fs`);
    * (e) `server/lib` comments no longer call the ban route "a gate" or say that it "does not exist yet"; `docker-compose.yml` passes the two `moderation`
      variables with the empty default form like the other tiers.

  The pins are facts and unique new terms, not whole sentences, so the wording stays free. The `fq` onward id-line assertions of the seven older docs suites are
  DELIBERATELY re-pinned to `fs` onward (each with a comment naming this story), in review cycle 1 to `fu` onward (`fs`-`ft` used), in review cycle 2 to `fv` onward (`fu` used); the old `fq` onward is refuted HERE.

  Pure file reads: `async: true`.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)
  @scope Path.join(@root, "docs/matrix-api-scope.md")
  @deploy Path.join(@root, "docs/architecture/07-deployment.md")
  @followups Path.join(@root, "docs/stories/oauth-broker/follow-ups.md")
  @changelog Path.join(@root, "CHANGELOG.md")
  @compose Path.join(@root, "docker-compose.yml")
  @lib Path.join(@root, "server/lib")
  @story "moderation-routes-atomic-ban"

  @kick "| POST | `/_matrix/client/v3/rooms/{roomId}/kick` | "
  @ban "| POST | `/_matrix/client/v3/rooms/{roomId}/ban` | "
  @unban "| POST | `/_matrix/client/v3/rooms/{roomId}/unban` | "
  @rows [{"kick", @kick, "room_member_kicked"}, {"ban", @ban, "room_member_banned"}, {"unban", @unban, "room_member_unbanned"}]

  @title "**Room moderation: kick, ban, unban (story moderation-routes-atomic-ban, follow-ups `ex`, `ew`).**"

  defp read(p), do: File.read!(p) |> String.replace(~r/\s+/, " ")
  defp lines(p), do: p |> File.read!() |> String.split("\n")

  defp scope_row(prefix) do
    row = Enum.find(lines(@scope), &String.starts_with?(&1, prefix))
    assert row, "the scope doc has no row starting with #{prefix}"
    String.replace(row, ~r/\s+/, " ")
  end

  # the three moderation rows as ONE text (the labels may sit on any of them)
  defp moderation_rows, do: Enum.map_join([@kick, @ban, @unban], " ", &scope_row/1)

  # the whole markdown line of a follow-up row (all cells), whitespace normalised
  defp followup_line(id) do
    line = Enum.find(lines(@followups), &String.starts_with?(&1, "| #{id} | "))
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

  # From the bold title of the moderation paragraph to the next markdown heading (the paragraphs and the SQL block), whitespace normalised
  defp moderation_section do
    raw = File.read!(@deploy)

    case :binary.match(raw, @title) do
      {at, _} ->
        rest = binary_part(raw, at, byte_size(raw) - at)
        [section | _] = Regex.split(~r/\n\#{2,4} /, rest, parts: 2)
        String.replace(section, ~r/\s+/, " ")

      :nomatch ->
        flunk("07-deployment has no paragraph titled #{@title}")
    end
  end

  # the `[Unreleased]` block of the changelog and one of its `###` sections
  defp unreleased_section(heading) do
    changelog = File.read!(@changelog)
    assert [_, from_unreleased] = String.split(changelog, "## [Unreleased]", parts: 2)
    [unreleased | _] = String.split(from_unreleased, ~r/\n## \[/, parts: 2)

    assert [_, from_heading] = String.split(unreleased, "### #{heading}", parts: 2), "[Unreleased] has a #{heading} section"
    [section | _] = String.split(from_heading, ~r/\n### /, parts: 2)
    section
  end

  # ═══ (a) the scope doc ═══════════════════════════════════════════════════════════

  for {label, prefix, action} <- @rows do
    test "scope doc (a): the #{label} row is a green tick now and names the story, not unrouted, not internal only, no gap words" do
      row = scope_row(unquote(prefix))

      assert String.starts_with?(row, unquote(prefix) <> "✅ |"), "the #{unquote(label)} row is ✅ (it was 🔲)"
      refute row =~ "🔲"
      assert row =~ @story, "the row names the story"

      for phrase <- ["Unrouted", "internal only", "No API can issue a ban yet", "event order is not"] do
        refute row =~ phrase, "the #{unquote(label)} row no longer says #{inspect(phrase)}"
      end

      refute row =~ ~r/partial/i, "the guarantee is no longer partial"
    end

    test "scope doc (a): the #{label} row names the moderation tier as a divergence from Rate-limited: No, and the audit action #{action}" do
      row = scope_row(unquote(prefix))

      assert row =~ "`moderation`", "the tier"
      assert row =~ "divergence", "labelled a divergence"
      assert row =~ "Rate-limited: No", "from the endpoint flag of the spec"
      assert row =~ "`#{unquote(action)}`", "the audit action of the #{unquote(label)} route"
    end

    test "scope doc (a): the #{label} row names the one-transaction guarantee, the room process and the 1024-byte reason cap with the NUL refusal as Nebu choices" do
      row = scope_row(unquote(prefix))

      assert row =~ ~r/ONE (database )?transaction|one (database )?transaction/, "one transaction per change"
      assert row =~ "room process", "decided and written in the room process"
      assert row =~ "the 1024-byte `reason` cap and the NUL refusal: Nebu choices"
    end
  end

  test "scope doc (a): the seven explicit Oracle labels appear word for word on the moderation rows (self-kick, 404, foreign-id ban, unban of a non-banned user, tier divergence, reason cap, 503)" do
    rows = moderation_rows()

    for label <- [
          "self-kick refused: Nebu choice (v10 would allow a self-leave)",
          "foreign-id ban `403`: Nebu choice",
          "`404` for an unknown room: Nebu choice (existence oracle `403` vs `404`, as `/invite`)",
          "unban of a non-banned user `403`: Nebu choice",
          "the `moderation` tier: divergence from Rate-limited: No",
          "the 1024-byte `reason` cap and the NUL refusal: Nebu choices",
          "`503 M_UNAVAILABLE` is not a spec errcode"
        ] do
      assert rows =~ label, "the moderation rows carry the label #{inspect(label)}"
    end
  end

  test "scope doc (a): each label sits on the row it is about (self-kick on kick, foreign-id on ban, non-banned unban on unban)" do
    assert scope_row(@kick) =~ "self-kick refused: Nebu choice (v10 would allow a self-leave)"
    assert scope_row(@ban) =~ "foreign-id ban `403`: Nebu choice"
    assert scope_row(@unban) =~ "unban of a non-banned user `403`: Nebu choice"
  end

  test "scope doc (a): the rows keep the words pinned by the older suites: DM + equal (create-room-invites-direct) on kick and ban, enforced + join (presets) on ban" do
    for prefix <- [@kick, @ban] do
      row = scope_row(prefix)
      assert row =~ "DM", prefix
      assert row =~ ~r/equal/i, prefix
    end

    ban = scope_row(@ban)
    assert ban =~ ~r/enforced/i and ban =~ ~r/join/i, "the ban row says that a ban is enforced on join"
  end

  test "scope doc (a): the order of the checks, the codes and the fixed texts of the three routes (D2-D6)" do
    rows = moderation_rows()

    for code <- ["`200 {}`", "`429 M_LIMIT_EXCEEDED`", "`Retry-After`", "`400 M_NOT_JSON`", "`400 M_BAD_JSON`", "`400 M_MISSING_PARAM`", "`400 M_INVALID_PARAM`", "`404 M_NOT_FOUND`", "`403 M_FORBIDDEN`"] do
      assert rows =~ code, "the rows name #{code}"
    end

    assert rows =~ ~r/charged FIRST/i, "the charge comes first (before the body checks)"
    assert rows =~ ~r/first failure wins/i, "the order of the checks is stated"

    for text <- [
          "You do not have a high enough power level to kick from this room.",
          "You do not have a high enough power level to ban from this room.",
          "You do not have a high enough power level to unban from this room.",
          "You are not a member of this room",
          "You cannot act on a user whose power level is not lower than yours",
          "The user is banned from this room: unban them instead",
          "The user is not in this room",
          "Only users of this server can be banned",
          "The user is not banned from this room"
        ] do
      assert rows =~ text, "the rows carry the fixed text #{inspect(text)}"
    end
  end

  test "scope doc (a): kick = revocation of a pending invitee (Disinvite), ban = pre-emptive and idempotent, unban needs the ban AND the kick level" do
    kick = scope_row(@kick)
    assert kick =~ ~r/revoke|revocation/i and kick =~ "Disinvite", "the kick of an invitee"
    assert kick =~ "`sender` != `state_key`", "the revocation event has sender != state_key"
    assert kick =~ "`invitation_revoked`", "the audit metadata of a kick"
    assert kick =~ ~r/strictly higher/i, "the strictly-higher rule"

    ban = scope_row(@ban)
    assert ban =~ ~r/pre-emptive/i, "a ban of a user who never joined"
    assert ban =~ ~r/idempotent/i, "a repeated ban is an idempotent 200 with no new event"
    assert ban =~ ~r/no new event/i

    unban = scope_row(@unban)
    assert unban =~ ~r/BOTH the `ban` level AND the `kick` level/, "S3: unban needs ban AND kick"
    assert unban =~ ~r/fresh invitation|new invitation/i, "the unbanned user needs a new invitation in an invite-only room"
  end

  test "scope doc (a): the reason rules (D10): no key for absent / null / empty, a non-string and a NUL are 400 M_BAD_JSON, above 1024 bytes 400 M_INVALID_PARAM, never in the audit row" do
    rows = moderation_rows()

    assert rows =~ "reason must be a string" and rows =~ "reason must not contain NUL" and rows =~ "reason exceeds 1024 bytes"
    assert rows =~ "1024 bytes"
    assert rows =~ ~r/never copied[^|]{0,40}audit/i, "the reason is not copied to the audit row"
  end

  test "scope doc (a): the moderation tier defaults (30 per minute, burst 60), its two variables and the shared bucket of the three routes" do
    rows = moderation_rows()

    assert rows =~ ~r/30 \/ min[^|]{0,40}burst 60/, "30 / min, burst 60"
    assert rows =~ "`NEBU_RATE_LIMIT_MODERATION_PER_MIN`" and rows =~ "`NEBU_RATE_LIMIT_MODERATION_BURST`"
    assert rows =~ ~r/one shared bucket|alike/i, "kick, ban and unban draw from the same bucket"
  end

  test "scope doc (a): PUT state of m.room.member stays refused (fq) and the 503 text of an unanswering room is named" do
    rows = moderation_rows()

    assert rows =~ "`fq`", "the PUT state alternative path stays refused (follow-up fq)"
    assert rows =~ "The room did not answer, the change may or may not have been applied"
  end

  test "scope doc (a): the join row rewrites the open caveat as closed (ex CLOSED, the event order IS protected) and no longer says the event order is not" do
    row = scope_row("| POST | `/_matrix/client/v3/join/{roomIdOrAlias}` | ")

    assert row =~ "`ex`" and row =~ "CLOSED", "ex is CLOSED"
    refute row =~ ~r/a gate for the ban route/, "the gate wording is gone"
    refute row =~ ~r/NOT the event order|event order is not/i, "the open caveat is gone"
    refute row =~ "second removal", "the two-removal design of ban_user/2 is gone"
    assert row =~ ~r/member set AND the event order are protected/, "both are protected now"
    assert row =~ "`403`" and row =~ "You are banned from this room", "the ban refusal stays"
  end

  test "scope doc (a): the invite row says the ban check and the invite event are decided in the room process (ex / Kassandra M-1)" do
    row = scope_row("| POST | `/_matrix/client/v3/rooms/{roomId}/invite` | ")

    assert row =~ "room process", "the ban check and the invite event are decided in the room process"
    assert row =~ "`ex`" and row =~ "M-1"
    assert row =~ "write_invite/5"
    assert row =~ ~r/banned/i and row =~ "403", "the earlier rules stay"
  end

  test "scope doc (a): the upgrade row says bans are carried, labels the ban copy a deliberate deviation from the SHOULD NOT, and points to fr for the power levels" do
    row = scope_row("| POST | `/_matrix/client/v3/rooms/{roomId}/upgrade` | ")

    assert row =~ "deliberate deviation from the SHOULD NOT (membership events not transferred; bans re-issued in the upgrader's name)"
    assert row =~ ~r/Bans are carried/i
    assert row =~ "`ew`" and row =~ "`fr`", "ew closed, fr for the power levels"
    assert row =~ "`bans_carried`", "the audit row counts the carried bans"
  end

  # ═══ (b) 07-deployment ═══════════════════════════════════════════════════════════

  test "07-deployment (b): the moderation paragraph states what clients can see: the three routes answer 200, Disinvite, a kick of a non-member is 403, unban needs the kick level too" do
    sec = moderation_section()

    for word <- ["/kick", "/ban", "/unban", "M_UNRECOGNIZED", "Disinvite", "`kick` level", "`403`"], do: assert(sec =~ word, "the paragraph mentions #{word}")
    assert sec =~ ~r/behaviou?r change/i
  end

  test "07-deployment (b): the moderation paragraph names the moderation tier, its defaults and both variables, the divergence from Rate-limited: No and the audit actions" do
    sec = moderation_section()

    assert sec =~ "`moderation`" and sec =~ ~r/30 per minute[^.]{0,40}burst 60/
    assert sec =~ "`NEBU_RATE_LIMIT_MODERATION_PER_MIN`" and sec =~ "`NEBU_RATE_LIMIT_MODERATION_BURST`"
    assert sec =~ "divergence" and sec =~ "Rate-limited: No"
    for action <- ["`room_member_kicked`", "`room_member_banned`", "`room_member_unbanned`", "`bans_carried`"], do: assert(sec =~ action, "the paragraph names #{action}")
  end

  test "07-deployment (b): the moderation paragraph says Element's Banned users list is empty after a fresh initial sync until story 2 (fb) and how to unban meanwhile" do
    sec = moderation_section()

    assert sec =~ "Banned users", "Element's list"
    assert sec =~ ~r/initial sync/i
    assert sec =~ "`fb`" and sec =~ ~r/story 2/
    assert sec =~ "`/unban <user id>`" or sec =~ "`/unban <user-id>`", "the composer command"
  end

  test "07-deployment (b): the moderation paragraph says the upgrade carries bans (fr: power levels not carried) and that one transaction makes a change all or nothing" do
    sec = moderation_section()

    assert sec =~ ~r/upgrade[^.]{0,200}carries the bans|carries the bans[^.]{0,200}upgrade/i
    assert sec =~ "`fr`"
    assert sec =~ ~r/ONE database transaction/
    assert sec =~ "`503 M_UNAVAILABLE`" and sec =~ ~r/not a spec errcode/
  end

  test "07-deployment (b): the operator query Q-half lists ACTIVE room_members rows whose LATEST member event is a ban, reads both JSONB forms and the tie order, and a repeated ban repairs them" do
    sec = moderation_section()

    assert sec =~ "Q-half"
    assert sec =~ "ACTIVE `room_members`", "active room_members rows"
    assert sec =~ ~r/LATEST member event/, "the latest member event"
    assert sec =~ ~r/\bban\b/
    assert sec =~ ~r/rolled-back transaction/i, "how to run it safely"
    assert sec =~ ~r/both JSONB forms/i, "the membership extraction of @sql_member_membership_raw: an object or a string"
    assert sec =~ "jsonb_typeof", "the extraction branches on the JSONB type"
    assert sec =~ "room_members" and sec =~ "left_at IS NULL", "the query reads the active member rows"
    assert sec =~ ~r/repeated `?POST \/rooms\/\{roomId\}\/ban`?[^.]{0,80}repair|repeated ban[^.]{0,80}repair/i, "a repeated ban repairs a row"
    assert sec =~ ~r/most restrictive first/i, "the D3 tie order"
  end

  test "07-deployment (b): the RELEASE GATE paragraph says ex is CLOSED by this story (the ban route exists), keeps the words ex and ban route, and no longer says there is no ban API" do
    gate = gate_paragraph()

    assert gate =~ "`ex` is CLOSED by story #{@story}"
    assert gate =~ "`ex`" and gate =~ ~r/ban route/i, "the pinned words of the older suites"
    refute gate =~ ~r/`ex` remains the gate/, "ex is no longer the gate"
    refute gate =~ "there is no ban API yet"
    refute gate =~ "half-state bans", "the ex residual is closed"
  end

  test "07-deployment (b): release note (1) says a ban can be issued and that the member set AND event order are protected, without NO API / PARTIAL / event order is not" do
    gate = gate_paragraph()

    refute gate =~ ~r/no API can issue a ban/i
    refute gate =~ "PARTIAL"
    refute gate =~ ~r/event order is not/i
    assert gate =~ ~r/a ban can be issued now/
    assert gate =~ ~r/member set AND event order are protected/
    assert gate =~ ~r/one atomic call in the room process/i
  end

  test "07-deployment (b): release note (4) keeps 'the Admin UI has no unban' but no longer says there is no API to ban or unban at all yet; the old-behaviour sentence stays" do
    gate = gate_paragraph()

    assert gate =~ ~r/no (Admin )?unban|has no unban/i, "the presets pin"
    refute gate =~ "there is no API to ban or unban a user at all yet"
    assert read(@deploy) =~ "Bans and kicks were not enforced on join", "the old-behaviour sentence stays"
  end

  # ═══ (c) CHANGELOG ═══════════════════════════════════════════════════════════════

  test "CHANGELOG (c): [Unreleased] ### Added has the three routes, the moderation tier with its variables and the three audit actions" do
    added = unreleased_section("Added") |> String.replace(~r/\s+/, " ")

    for term <- ["/kick", "/ban", "/unban", "`moderation`", "NEBU_RATE_LIMIT_MODERATION_PER_MIN", "NEBU_RATE_LIMIT_MODERATION_BURST", "room_member_kicked", "room_member_banned", "room_member_unbanned", "`ex`", "`ew`"] do
      assert added =~ term, "the Added entry mentions #{term}"
    end

    assert added =~ "Q-half", "the operator query"
  end

  test "CHANGELOG (c): [Unreleased] ### Changed has a warning entry: unban needs the kick level too, a kick of a non-member is 403 (was an internal 404), /upgrade carries bans" do
    changed = unreleased_section("Changed")
    entry = changed |> String.split(~r/\n- /) |> Enum.find(&(&1 =~ "⚠" and &1 =~ "unban"))

    assert entry, "a Changed entry with the warning sign about the moderation answers"
    flat = String.replace(entry, ~r/\s+/, " ")

    for term <- ["`kick` level", "`ban` level", "403", "404", "/upgrade", "`fr`", "1024"], do: assert(flat =~ term, "the entry mentions #{term}")
    assert flat =~ ~r/carries the bans/i
  end

  # ═══ (d) follow-ups ══════════════════════════════════════════════════════════════

  for {id, words} <- [
        # the words the older suites pin on these rows (create_room_presets / membership_write_limits / event_size_limit), kept by the CLOSED rewrite
        {"ex", ["gate for the ban route", "ONE atomic", "Room.Server", "N-1b", "N-6", "EVENT order", "join event", "MEMBER SET", "AFTER the ban event", "EventSize", "reason", "`join` tier", "ban route"]},
        {"ew", ["upgrade_room", "ban"]}
      ] do
    test "follow-ups (d): #{id} is CLOSED by this story (CLOSED style, status closed, the original item kept) and keeps the words the older suites pin" do
      f = read(@followups)
      assert f =~ ~r/\| #{unquote(id)} \| \*\*CLOSED by story #{@story} \(\d{4}-\d{2}-\d{2}\)/, "the CLOSED prefix like ea / ep / ff"

      line = followup_line(unquote(id))
      assert line =~ ~r/\| closed \|\s*\z/, "the status column says closed"
      refute line =~ ~r/\| open[^|]*\|\s*\z/
      assert line =~ ~r/Original item/i, "the original text stays"
      assert line =~ @story

      for word <- unquote(words), do: assert(line =~ word, "#{unquote(id)} keeps #{inspect(word)}")
    end
  end

  test "follow-ups (d): ex names the closure facts: moderate/5, the invite writer and the decline, one transaction, the satisfied gate items and Q-half" do
    line = followup_line("ex")

    for word <- ["moderate/5", "write_invite/5", "write_decline/2", "ONE database transaction", "Q-half", "satisfied", "1024"], do: assert(line =~ word, "ex mentions #{word}")
    assert line =~ ~r/CLOSED by story #{@story}[^|]{0,80}ban route exists/
  end

  test "follow-ups (d): ew names the carried bans, the audit count and the open power levels (fr)" do
    line = followup_line("ew")

    for word <- ["bans_carried", "`fr`", "SHOULD NOT"], do: assert(line =~ word, "ew mentions #{word}")
  end

  for {id, patterns} <- [
        {"fb", [{:re, "revoke", "i"}, "kick", {:re, "membership-state-model|story 2", ""}, "trusted_private_chat"]},
        {"eu", ["moderate/5", "write_invite/5", "write_decline/2", "create_personal_room"]},
        {"eq", ["D13", {:re, "unban needs the ban AND the kick level", ""}, "`events`"]},
        {"et", ["unban", {:re, "membership-state-model|story 2", ""}, {:re, "owner decision", ""}]},
        {"fi", ["(c)", {:re, "withdraw", "i"}, "`kick` level"]},
        {"fg", ["(f)", "(h)", "moderate/5"]},
        {"fe", [":pg.get_members/1"]},
        {"fa", ["(a)", "`reason`", "D10"]},
        {"fc", ["latest + 1", "(d)"]},
        {"fp", [{:re, "pre-emptive", "i"}, "`moderation` tier"]}
      ] do
    test "follow-ups (d): the existing row #{id} carries a '**Note (moderation-routes-atomic-ban, <date>):**' with the facts of this story" do
      row = followup_line(unquote(id))

      assert row =~ ~r/\*\*Note \(#{@story}, [^)]+\):\*\*/, "#{unquote(id)}: the note is labelled like the other notes of this file"
      [_, note] = String.split(row, "**Note (#{@story}, ", parts: 2)

      for pattern <- unquote(Macro.escape(patterns)) do
        case pattern do
          p when is_binary(p) -> assert note =~ p, "#{unquote(id)}: the note mentions #{p}"
          {:re, source, opts} -> assert note =~ Regex.compile!(source, opts), "#{unquote(id)}: the note matches /#{source}/"
        end
      end
    end
  end

  test "follow-ups (d): the new rows fq (PUT state of m.room.member stays refused) and fr (upgrade does not carry the power levels) exist, are attributed to this story (fq open, fr closed by power-levels-enforcement)" do
    [_, fq_text, fq_origin, fq_status] = followup_cells("fq")
    [_, fr_text, fr_origin, fr_status] = followup_cells("fr")

    assert fq_origin =~ @story and fr_origin =~ @story
    # story power-levels-enforcement (DELIBERATE re-pin, AC15 / AC16; old -> new): `fr` was open, it is CLOSED by that story now (the words of its text stay)
    assert String.downcase(fq_status) =~ "open" and String.downcase(fr_status) =~ "closed"

    for word <- ["m.room.member", "PUT", "moderate/5", "emit_state_event_at/6"], do: assert(fq_text =~ word, "fq mentions #{word}")
    for word <- ["m.room.power_levels", "copy_state_events/3", "BEFORE", "`eq`", "`ew`", "LOWER"], do: assert(fr_text =~ word, "fr mentions #{word}")
  end

  test "follow-ups (d): the id line lists fq - fr for this story and continues at ga (the old 'fq onward' is gone, the earlier attributions stay)" do
    f = read(@followups)

    assert f =~ "`fq`-`fr`: #{@story}"
    # moderation-routes-atomic-ban review cycles 1 / 2 (DELIBERATE re-pin): `fs`-`fu` are used, unused ids continue at `fv`
    # story power-levels-enforcement (DELIBERATE re-pin, AC15 / AC16; old -> new): `fv`-`fz` are used by that story, the unused ids continue at `ga` ("`fv` onward" before)
    # story state-writer-redaction (DELIBERATE re-pin, AC15 (a); old -> new): `ga`-`gd` are used by that story, the unused ids continue at `ge` ("`ga` onward" before; the old note is refuted by state_writer_redaction_docs_test.exs)
    # story membership-state-model (DELIBERATE re-pin, AC15 (a); old -> new): `ge`-`gi` are used by that story, the unused ids continue at `gj` ("`ge` onward" before; the old note is refuted by membership_state_model_docs_test.exs)
    # story history-visibility-enforcement (DELIBERATE re-pin, AC21 (a); old -> new): `gj`-`gl` are used by that story, the unused ids continue at `gm` ("`gj` onward" before; the old note is refuted by history_visibility_docs_test.exs)
    assert f =~ ~r/unused:[^.]*`gm` onward/, "unused ids continue at gm"
    refute f =~ ~r/unused:[^.]*`fq` onward/, "the old `fq` onward note is gone"
    assert f =~ "`fn`-`fp`: event-size-limit", "the earlier attribution stays"
  end

  test "follow-ups (d), review cycles 1 / 2: the rows fs (timed-out call unaudited), ft (format_status), fu (requester membership, closed) exist and are attributed" do
    for {id, words} <- [
          {"fs", ["503", "apply_member_change/4", "lock_timeout", "forensic record"]},
          {"ft", ["format_status/1", "reason", "member_identity"]},
          {"fu", ["upgrade_room", "old_state.members", "power level"]}
        ] do
      [_, text, origin, status] = followup_cells(id)
      assert origin =~ @story, "#{id} is attributed to this story"
      # review cycle 3 (DELIBERATE re-pin, old -> new): `fu` was open, it is CLOSED by this story's review cycle 3 now
      expected = if id == "fu", do: "closed", else: "open"
      assert String.downcase(status) =~ expected, "#{id} is #{expected}"
      for word <- words, do: assert(text =~ word, "#{id} mentions #{word}")
    end

    assert read(@followups) =~ "`fs`-`ft`: #{@story} review cycle 1" and read(@followups) =~ "`fu`: #{@story} review cycle 2"
  end

  test "follow-ups (d), review cycle 1: the fe header names the remaining node-local senders, not kick / ban / unban / decline" do
    [_, text, _origin, _status] = followup_cells("fe")
    [header | _] = String.split(text, "**Note", parts: 2)

    assert header =~ "emit_membership_event/4" and header =~ "emit_decline_event/2" and header =~ "send_event"
    refute header =~ "kick / ban / unban / decline use"
  end

  test "docs (a) / (d), review cycles 1 / 2: the cap of carried bans (10 000, 403 before anything is written) is stated in the scope doc, fp and the CHANGELOG" do
    upgrade = scope_row("| POST | `/_matrix/client/v3/rooms/{roomId}/upgrade` | ")
    assert upgrade =~ "10 000 bans" and upgrade =~ "The room has too many bans to be upgraded" and upgrade =~ "before anything is written"
    assert upgrade =~ ~r/freeze first/i, "the freeze-first order of review cycle 2"
    assert followup_line("fp") =~ "10 000 bans" and followup_line("fp") =~ ~r/un-upgradable/
    assert unreleased_section("Changed") |> String.replace(~r/\s+/, " ") =~ "10 000 bans"
  end

  # ═══ (e) server/lib comments and the compose pass-through ════════════════════════

  test "server/lib (e): the Room.Server comments no longer call the ban route a gate or say that it does not exist yet" do
    files = Path.wildcard(Path.join(@lib, "**/*.ex"))
    assert length(files) > 100, "positive control: the lib tree was found"
    sources = for f <- files, into: %{}, do: {Path.relative_to(f, @lib), File.read!(f)}

    for {file, src} <- sources do
      flat = String.replace(src, ~r/\s*\n\s*#\s*/, " ")
      refute flat =~ "a gate for the ban route", "#{file} still calls the ban route a gate"
      refute flat =~ "which does not exist yet", "#{file} still says the ban route does not exist yet"
      refute flat =~ ~r/ban route[^.]{0,40}does not exist yet/, "#{file} still says the ban route does not exist yet"
    end

    server = sources["nebu/matrix/room/server.ex"]
    assert server =~ "defp check_not_banned(", "positive control: the commented function is still there"
    refute server =~ "the EVENT order is not protected", "the residual of the join comment is gone"
  end

  test "docker-compose (e): the two moderation variables are passed through in the empty default form like the other tiers, and the comment names the tier" do
    compose = File.read!(@compose)

    for name <- ["NEBU_RATE_LIMIT_MODERATION_PER_MIN", "NEBU_RATE_LIMIT_MODERATION_BURST"] do
      assert compose =~ ~s(#{name}: "${#{name}:-}"), "#{name} is passed through with the empty default"
    end

    assert compose =~ ~s(NEBU_RATE_LIMIT_JOIN_BURST: "${NEBU_RATE_LIMIT_JOIN_BURST:-}"), "positive control: the other tiers use the same form"

    [_, from_comment] = String.split(compose, "# Per-user limits of the room membership writes", parts: 2)
    [block | _] = String.split(from_comment, "NEBU_RATE_LIMIT_CREATE_ROOM_PER_MIN", parts: 2)
    assert block =~ "moderation", "the comment above the variables names the moderation tier"
    refute block =~ "the three tiers", "four tiers are switched off by NEBU_RATE_LIMIT_DISABLED now"
  end
end
