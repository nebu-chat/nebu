defmodule Nebu.Matrix.PowerLevelsDocsTest do
  @moduledoc """
  Static checks (no network) for story `power-levels-enforcement` (epic oauth-broker, follow-ups `eq`, `er`, `fr`), AC15:

    * (a) `docs/matrix-api-scope.md`: the PUT state rows document the `m.room.power_levels` branch (the D2 order and texts, the D3 shape, the no-op, the tier labelled a divergence
      from "Rate-limited: No", the `@` rule, `events[type]` enforcement), the `/send` row the per-type enforcement, the in-process membership check and the risk note of the
      redaction, the createRoom row the APPLIED `initial_state` levels entry, the upgrade row the carried levels, a new unrouted `redact` row, and the labels word for word;
    * (b) `docs/architecture/07-deployment.md`: the paragraph "Power levels (story power-levels-enforcement ...)" with the operator query **Q-pl** (its SQL is executed here, against
      fixture rows in a rolled-back transaction), the moderation paragraph says the levels are carried now;
    * (c) `CHANGELOG.md` `[Unreleased]`: `### Added` and the `### Changed` warning entry;
    * (d) `docs/stories/oauth-broker/follow-ups.md`: `eq`, `er`, `fr` CLOSED (the pinned words of the older suites stay), the notes on `ad`, `eu`, `fp`, `fe`, `fs`, `ft`, the new
      rows `fv` - `fz`, the id line (`fv`-`fz`: this story, unused from `ga`; re-pinned to `ge` by story state-writer-redaction);
    * (e) the removed phrases are refuted.

  The pins are facts and unique new terms, not whole sentences, so the wording stays free; the LABELS are pinned word for word (they are the contract of the story's "labelled"
  decisions: the dev copies them). The `fv` onward id-line assertions of the eight older docs suites are DELIBERATELY re-pinned to `ga` onward (each with a comment naming this
  story); the old `fv` onward is refuted HERE.

  The file reads are `async`-safe; the one database test (Q-pl) only works inside a transaction it rolls back.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)
  @scope Path.join(@root, "docs/matrix-api-scope.md")
  @deploy Path.join(@root, "docs/architecture/07-deployment.md")
  @followups Path.join(@root, "docs/stories/oauth-broker/follow-ups.md")
  @changelog Path.join(@root, "CHANGELOG.md")
  @story "power-levels-enforcement"

  @put_state "| PUT | `/_matrix/client/v3/rooms/{roomId}/state/{eventType}/{stateKey}` | "
  @put_state_short "| PUT | `/_matrix/client/v3/rooms/{roomId}/state/{eventType}` | "
  @send "| PUT | `/_matrix/client/v3/rooms/{roomId}/send/{eventType}/{txnId}` | "
  @create "| POST | `/_matrix/client/v3/createRoom` | "
  @upgrade "| POST | `/_matrix/client/v3/rooms/{roomId}/upgrade` | "
  @redact "| PUT | `/_matrix/client/v3/rooms/{roomId}/redact/{eventId}/{txnId}` | "

  @title "**Power levels (story power-levels-enforcement, follow-ups `eq`, `er`, `fr`).**"

  defp read(p), do: File.read!(p) |> String.replace(~r/\s+/, " ")
  defp lines(p), do: p |> File.read!() |> String.split("\n")

  defp scope_row(prefix) do
    row = Enum.find(lines(@scope), &String.starts_with?(&1, prefix))
    assert row, "the scope doc has no row starting with #{prefix}"
    String.replace(row, ~r/\s+/, " ")
  end

  defp followup_line(id) do
    line = Enum.find(lines(@followups), &String.starts_with?(&1, "| #{id} | "))
    assert line, "the follow-up row #{id} does not exist"
    String.replace(line, ~r/\s+/, " ")
  end

  # [id, text, origin, status]
  defp followup_cells(id), do: id |> followup_line() |> String.trim_leading("| ") |> String.trim_trailing(" |") |> String.split(" | ")

  # From the bold title of the power-levels paragraph to the next markdown heading (the paragraph and its SQL block), whitespace normalised
  defp power_levels_section(normalise? \\ true) do
    raw = File.read!(@deploy)

    case :binary.match(raw, @title) do
      {at, _} ->
        rest = binary_part(raw, at, byte_size(raw) - at)
        [section | _] = Regex.split(~r/\n\#{2,4} /, rest, parts: 2)
        if normalise?, do: String.replace(section, ~r/\s+/, " "), else: section

      :nomatch ->
        flunk("07-deployment has no paragraph titled #{@title}")
    end
  end

  defp unreleased_section(heading) do
    changelog = File.read!(@changelog)
    assert [_, from_unreleased] = String.split(changelog, "## [Unreleased]", parts: 2)
    [unreleased | _] = String.split(from_unreleased, ~r/\n## \[/, parts: 2)

    assert [_, from_heading] = String.split(unreleased, "### #{heading}", parts: 2), "[Unreleased] has a #{heading} section"
    [section | _] = String.split(from_heading, ~r/\n### /, parts: 2)
    section
  end

  # the two PUT state rows as ONE text (the details may sit on either)
  defp put_state_rows, do: Enum.map_join([@put_state, @put_state_short], " ", &scope_row/1)

  # ═══ (a) the scope doc ═══════════════════════════════════════════════════════════

  test "scope doc (a): the PUT state rows name the story and the m.room.power_levels branch: the room process, ONE transaction, the audit action" do
    rows = put_state_rows()

    assert rows =~ @story
    assert rows =~ "`m.room.power_levels`"
    assert rows =~ "room process"
    assert rows =~ ~r/ONE (database )?transaction|one (database )?transaction/
    assert rows =~ "`room_power_levels_changed`"
    assert rows =~ "`changed_keys`" and rows =~ "`users_changed`" and rows =~ "`users_changed_count`"
    refute rows =~ ~r/m\.room\.power_levels[^|]{0,60}(is|are) (refused|not writable)/i, "the old 403 of this type is gone"
  end

  test "scope doc (a): the PUT state rows carry the D2 order and the five fixed 403 / 400 texts, the D3 shape and the empty state key" do
    rows = put_state_rows()

    assert rows =~ ~r/first failure wins/i
    assert rows =~ ~r/charged FIRST/i, "the token is charged before the body checks"

    for text <- [
          "You are not a member of this room",
          "You do not have a high enough power level to change the power levels",
          "You cannot grant a power level above your own",
          "You cannot change a power level above your own",
          "You cannot change the power level of a user whose level is not lower than yours",
          "m.room.power_levels requires an empty state key"
        ] do
      assert rows =~ text, "the rows carry the fixed text #{inspect(text)}"
    end

    for term <- ["`429 M_LIMIT_EXCEEDED`", "`Retry-After`", "`400 M_BAD_JSON`", "`403 M_FORBIDDEN`", "integers within +-(2^53 - 1)", "valid user ids"] do
      assert rows =~ term, "the rows name #{term}"
    end

    assert rows =~ ~r/lower or remove his own entry|lowers? or removes? his own/i, "the self-entry exemption of rule 7"
  end

  test "scope doc (a): the no-op is an idempotent 200 with the CURRENT event id, no new event, no audit row, checked last" do
    rows = put_state_rows()

    assert rows =~ ~r/idempotent/i
    assert rows =~ ~r/CURRENT event id/
    assert rows =~ ~r/no new event/i and rows =~ ~r/no audit row/i
    assert rows =~ ~r/checked last/i
  end

  test "scope doc (a): the PUT state rows state the tier as a divergence from Rate-limited: No, and the `@` state key rule and events[type] enforcement" do
    rows = put_state_rows()

    assert rows =~ "`moderation`" and rows =~ "divergence" and rows =~ "Rate-limited: No"
    assert rows =~ "You cannot set a state event whose state key is another user's id"
    assert rows =~ ~r/state key that starts with `@`/
    assert rows =~ "`events[type]`" and rows =~ "`state_default`"
  end

  test "scope doc (a): every label of a decision is on the PUT state rows word for word (Nebu choices, not evaluated, the 503 text)" do
    rows = put_state_rows()

    for label <- [
          "the tier on `m.room.power_levels`: divergence from Rate-limited: No",
          "non-empty state key refused: Nebu choice",
          "no-op on identical content: Nebu choice",
          "empty levels content denies every change: Nebu choice",
          "absent `users`: Nebu choice (spec ambiguous, Synapse parity)",
          "`notifications` not evaluated",
          # story state-writer-redaction (DELIBERATE re-pin, AC15 (b); old -> new): the label "`redact` not evaluated: no redaction route" is GONE (the redaction
          # writer evaluates `redact`); its absence is pinned by state_writer_redaction_docs_test.exs
          "`503 M_UNAVAILABLE` is not a spec errcode"
        ] do
      assert rows =~ label, "the PUT state rows carry the label #{inspect(label)}"
    end

    assert rows =~ "no server-side push", "notifications: validated, stored, delivered, not evaluated (no server-side push)"
    # story state-writer-redaction (DELIBERATE re-pin, AC15 (b); old -> new): `fv` is CLOSED, the rows still name it ("the other state types are decided in the caller" before)
    assert rows =~ "`fv`", "the rows still name follow-up fv"
  end

  test "scope doc (a): the /send row documents the per-type enforcement and the in-process membership check (the risk note of the redaction, fw, is gone: story state-writer-redaction)" do
    row = scope_row(@send)

    assert row =~ @story
    assert row =~ "`events[type]`" and row =~ "`events_default`"
    assert row =~ "You do not have a high enough power level to send this event"
    assert row =~ ~r/room process/ and row =~ ~r/re-checks that the sender is still a member/
    # story state-writer-redaction (DELIBERATE re-pin, AC15 (b); old -> new): the risk note "an `m.room.redaction` is stored as-is and delivered; clients may apply it
    # without the `redact` level (`fw`)" and "`redact` is stored, not evaluated" are GONE (`fw` is closed: /send redactions go through the redaction writer); their absence
    # is pinned by state_writer_redaction_docs_test.exs
  end

  test "scope doc (a): the createRoom row says the `m.room.power_levels` entry is APPLIED at step 6 as a replacement; the words skipped / deviation are gone for it, the five other types stay skipped" do
    row = scope_row(@create)

    assert row =~ ~r/step 6/ and row =~ ~r/replacement/
    assert row =~ "`er`"
    refute row =~ ~r/deviation/i, "the deviation of the skipped entry is gone"
    refute row =~ "`m.room.member`, `m.room.power_levels`, `m.room.encryption`", "the levels entry is no longer in the skipped list"
    refute row =~ ~r/`m\.room\.power_levels` entry of `initial_state` stays \*\*skipped\*\*/, "the old wording is gone"
    assert row =~ ~r/five other skipped types/
    for type <- ["`m.room.create`", "`m.room.member`", "`m.room.encryption`", "`m.room.tombstone`", "`m.room.third_party_invite`"], do: assert(row =~ type, "#{type} stays skipped")

    assert row =~ "The initial power levels cannot grant more than the room creator has"
    assert row =~ "levels in effect"
    assert row =~ "does not replace a preset event"
  end

  test "scope doc (a): the createRoom row labels the default events map NON-SPEC (Synapse-derived) with the eight entries and says existing rooms are not backfilled (fy)" do
    row = scope_row(@create)

    assert row =~ "non-spec, Synapse-derived"
    assert row =~ "default `events` map for new rooms: Nebu choice (non-spec, Synapse-derived)"

    for entry <- ["`m.room.power_levels`", "`m.room.history_visibility`", "`m.room.tombstone`", "`m.room.server_acl`", "`m.room.encryption`", "`m.room.name`", "`m.room.avatar`", "`m.room.canonical_alias`"] do
      assert row =~ entry, "the default events map names #{entry}"
    end

    assert row =~ "`fy`"
  end

  # story state-writer-redaction (DELIBERATE re-pin, AC15 (b); old -> new): the title said "the permission stays 100 (fx)"; `fx` is closed (the tombstone level with a floor of
  # 100), the assertions of this test are unchanged
  test "scope doc (a): the upgrade row says the levels are carried AFTER the bans (labelled), the old room is not lowered (archived), `fx` and `fr` are named" do
    row = scope_row(@upgrade)

    assert row =~ ~r/Power levels are carried/
    assert row =~ "bans before the copied levels"
    assert row =~ "old room not lowered: archived"
    assert row =~ "`fx`" and row =~ "`fr`"
    assert row =~ "\"power_levels_carried\": true" or row =~ "`power_levels_carried`"
    assert row =~ "The room has power levels above yours: a user with the highest level must upgrade it"
    assert row =~ "upgrade refused above the upgrader's level: Nebu choice"
    assert row =~ ~r/project's own Oracle note|not spec text/
    refute row =~ "The power levels are NOT carried", "the old sentence is gone"
  end

  # story state-writer-redaction (DELIBERATE re-pin, AC15 (b); old -> new): the row is ✅ now ("is 🔲 and says Unrouted (follow-up `fw`)" before)
  test "scope doc (a): the row for PUT .../redact/{eventId}/{txnId} is ✅ (routed by story state-writer-redaction, follow-up `fw` closed)" do
    row = scope_row(@redact)

    assert String.starts_with?(row, @redact <> "✅ |")
    refute row =~ "Unrouted (follow-up `fw`)"
  end

  # ═══ (b) 07-deployment ═══════════════════════════════════════════════════════════

  test "07-deployment (b): the paragraph states what clients can see: the route works, Roles & Permissions and /op / /deop, the changed answers, the tier and the audit action" do
    sec = power_levels_section()

    for word <- ["Roles & Permissions", "`/op`", "`/deop`", "`403`", "`events[type]`", "`@`", "`initial_state`", "`moderation`", "`room_power_levels_changed`", "upgrade", "non-spec, Synapse-derived"] do
      assert sec =~ word, "the paragraph mentions #{word}"
    end

    assert sec =~ ~r/behaviou?r change/i
    assert sec =~ ~r/Rate-limited: No/
  end

  test "07-deployment (b): legacy rooms (fy) and the operator query Q-pl are described: non-integer value, no content, no events[\"m.room.power_levels\"], a rolled-back transaction with fixture rows" do
    sec = power_levels_section()

    assert sec =~ "`fy`"
    assert sec =~ "Q-pl"
    assert sec =~ ~r/non-integer/
    assert sec =~ ~r/no content/i
    assert sec =~ "events[\"m.room.power_levels\"]"
    assert sec =~ ~r/rolled-back transaction/i
    assert sec =~ ~r/fixture rows/i
    assert sec =~ "```sql", "the query is shown as a SQL block"
  end

  test "07-deployment (b): the moderation paragraph no longer says the power levels are still not carried: carried (story power-levels-enforcement)" do
    raw = read(@deploy)

    refute raw =~ "the power levels are still not carried, follow-up `fr`"
    assert raw =~ "carried (story power-levels-enforcement)" or raw =~ "carried (story power-levels-enforcement"
  end

  @tag :integration
  test "07-deployment (b): the Q-pl SQL lists a room with a non-integer value, a room without content and a room without events[\"m.room.power_levels\"], and not a healthy room (rolled-back transaction, fixture rows)" do
    sql =
      case Regex.run(~r/```sql\n(.*?)```/s, power_levels_section(false)) do
        [_, block] -> block
        nil -> flunk("the power-levels paragraph has no SQL block")
      end

    assert sql =~ ~r/\A\s*(SELECT|WITH)/i, "Q-pl is read-only"
    refute sql =~ ~r/\b(INSERT|UPDATE|DELETE|DROP|ALTER|TRUNCATE)\b/i

    suffix = Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    # fix cycle 2 (review MINOR-2, Kassandra D-I3): broken rows (unparsable, an array, JSON null) and out-of-range / non-integer values
    # in events / notifications are listed too, and none of them aborts the query
    broken = ~w(badjson array jsonnull huge evstr notiflt)
    ids = for kind <- ~w(odd empty legacy fine) ++ broken, into: %{}, do: {kind, "!qpl#{kind}#{suffix}:test.local"}

    healthy = ~s({"ban":50,"kick":50,"invite":0,"redact":50,"state_default":50,"events_default":0,"users_default":0,"users":{"@a:test.local":100},"events":{"m.room.power_levels":100}})

    fixtures = [
      {ids["odd"], ~s({"ban":50,"users":{"@a:test.local":"100"},"events":{"m.room.power_levels":100}})},
      {ids["empty"], "{}"},
      {ids["legacy"], ~s({"ban":50,"kick":50,"users":{"@a:test.local":100},"events":{}})},
      {ids["fine"], healthy},
      {ids["badjson"], "{bad"},
      {ids["array"], "[1,2]"},
      {ids["jsonnull"], "null"},
      {ids["huge"], ~s({"ban":9007199254740992,"users":{"@a:test.local":100},"events":{"m.room.power_levels":100}})},
      {ids["evstr"], ~s({"ban":50,"users":{"@a:test.local":100},"events":{"m.room.power_levels":100,"m.room.name":"50"}})},
      {ids["notiflt"], ~s({"ban":50,"users":{"@a:test.local":100},"events":{"m.room.power_levels":100},"notifications":{"room":50.5}})}
    ]

    result =
      Nebu.Repo.transaction(fn ->
        for {room_id, json} <- fixtures do
          Ecto.Adapters.SQL.query!(Nebu.Repo, "INSERT INTO rooms (room_id, visibility, created_at, power_levels_json) VALUES ($1, 'private', $2, $3)", [room_id, System.system_time(:millisecond), json])
        end

        listed = Ecto.Adapters.SQL.query!(Nebu.Repo, sql, []).rows |> List.flatten() |> Enum.filter(&is_binary/1)
        Nebu.Repo.rollback({:listed, listed})
      end)

    assert {:error, {:listed, listed}} = result

    for kind <- ~w(odd empty legacy) ++ broken, do: assert(ids[kind] in listed, "Q-pl lists the #{kind} room")
    refute ids["fine"] in listed, "Q-pl does not list a healthy room"

    leftovers = Ecto.Adapters.SQL.query!(Nebu.Repo, "SELECT count(*) FROM rooms WHERE room_id = ANY($1)", [Map.values(ids)]).rows
    assert leftovers == [[0]], "the fixture rows were rolled back"
  end

  # ═══ (c) CHANGELOG ═══════════════════════════════════════════════════════════════

  test "CHANGELOG (c): [Unreleased] ### Added has the route and the audit action" do
    added = unreleased_section("Added") |> String.replace(~r/\s+/, " ")

    assert added =~ "PUT /_matrix/client/v3/rooms/{roomId}/state/m.room.power_levels"
    assert added =~ "`room_power_levels_changed`"
    assert added =~ @story
    assert added =~ "`eq`" and added =~ "`er`" and added =~ "`fr`"
    assert added =~ "Q-pl"
  end

  test "CHANGELOG (c): [Unreleased] ### Changed has a warning entry: events[type] enforced, the @ rule, the default events map, initial_state levels applied, upgrades carry the levels" do
    changed = unreleased_section("Changed")
    entry = changed |> String.split(~r/\n- /) |> Enum.find(&(&1 =~ "⚠" and &1 =~ "events[type]"))

    assert entry, "a Changed entry with the warning sign about the power levels"
    flat = String.replace(entry, ~r/\s+/, " ")

    for term <- ["events[type]", "`@`", "default `events` map", "`initial_state`", "upgrade", "highest level", @story], do: assert(flat =~ term, "the entry mentions #{term}")
  end

  # ═══ (d) follow-ups ══════════════════════════════════════════════════════════════

  for {id, words} <- [
        # the words the older suites pin on these rows (create_room_presets / create_room_invites / event_size_limit / moderation_routes), kept by the CLOSED rewrite
        {"eq", ["events", "redact", "notifications", "m.room.power_levels", "EventSize", "power level", "`trusted_private_chat`", "100", "DM", "D13", "unban needs the ban AND the kick level", "`events`"]},
        {"er", ["initial_state", "m.room.power_levels", "replacement"]},
        {"fr", ["m.room.power_levels", "copy_state_events/3", "BEFORE", "`eq`", "`ew`", "LOWER"]}
      ] do
    test "follow-ups (d): #{id} is CLOSED by this story (CLOSED style, status closed, the original item kept) and keeps the words the older suites pin" do
      f = read(@followups)
      assert f =~ ~r/\| #{unquote(id)} \| \*\*CLOSED by story #{@story} \(\d{4}-\d{2}-\d{2}\)/, "the CLOSED prefix like ea / ep / ex"

      line = followup_line(unquote(id))
      assert line =~ ~r/\| closed \|\s*\z/, "the status column says closed"
      refute line =~ ~r/\| open[^|]*\|\s*\z/
      assert line =~ ~r/Original item/i, "the original text stays"

      for word <- unquote(words), do: assert(line =~ word, "#{unquote(id)} keeps #{inspect(word)}")
    end
  end

  test "follow-ups (d): the residuals of eq (fv, fw, fy, notifications on ad) and fr (fx, LOWER) are named on the CLOSED rows" do
    eq = followup_line("eq")
    for word <- ["`fv`", "`fw`", "`fy`", "`ad`"], do: assert(eq =~ word, "eq names #{word}")

    fr = followup_line("fr")
    for word <- ["`fx`", "AFTER the bans"], do: assert(fr =~ word, "fr names #{word}")
  end

  for {id, patterns} <- [
        {"ad", ["sender_notification_permission", "normalised"]},
        {"eu", ["`fv`", "latest + 1"]},
        {"fp", ["m.room.power_levels", "`moderation` tier"]},
        {"fe", [":pg.get_members/1"]},
        {"fs", ["room_power_levels_changed"]},
        {"ft", ["format_status/1", "change_power_levels"]}
      ] do
    test "follow-ups (d): the existing row #{id} carries a '**Note (power-levels-enforcement, <date>):**' with the facts of this story" do
      row = followup_line(unquote(id))

      assert row =~ ~r/\*\*Note \(#{@story}, [^)]+\):\*\*/, "#{unquote(id)}: the note is labelled like the other notes of this file"
      [_, note] = String.split(row, "**Note (#{@story}, ", parts: 2)
      for pattern <- unquote(patterns), do: assert(note =~ pattern, "#{unquote(id)}: the note mentions #{pattern}")
    end
  end

  # story state-writer-redaction (DELIBERATE re-pin, AC15 (b); old -> new): `fv`, `fw`, `fx` and `fz` are CLOSED ("open, non-gating" before; the fact words are kept), `fy`
  # stays open
  test "follow-ups (d): the new rows fv, fw, fx, fy, fz exist and are attributed to this story, name their facts; fy is open, the others are closed" do
    for {id, words} <- [
          {"fv", ["write_state/5", "state-writer-room-process", "`eu`", "emit_state_event_at/6"]},
          {"fw", ["redact", "m.room.redaction", "/send", "events_default", "RAISED", "events[\"m.room.redaction\"]"]},
          {"fx", ["m.room.tombstone", "required_level", "`users[requester] >= 100`" |> String.replace("`", "")]},
          {"fy", ["Q-pl", "legacy", "owner decision", "`events: {}`" |> String.replace("`", "")]},
          {"fz", ["rooms", "lazily", "fetch_room_state/1", "403", "pre-existing"]}
        ] do
      [_, text, origin, status] = followup_cells(id)
      assert origin =~ @story, "#{id} is attributed to this story"

      if id == "fy" do
        assert String.downcase(status) =~ "open", "#{id} is open"
        assert String.downcase(status) =~ "non-gating", "#{id} is non-gating"
      else
        assert String.downcase(status) =~ "closed", "#{id} is closed by story state-writer-redaction"
      end

      flat = String.replace(text, "`", "")
      for word <- words, do: assert(flat =~ String.replace(word, "`", ""), "#{id} mentions #{word}")
    end
  end

  test "follow-ups (d): the id line lists fv - fz for this story and continues at ga (the old 'fv onward' is gone, the earlier attributions stay)" do
    f = read(@followups)

    assert f =~ "`fv`-`fz`: #{@story}"
    # story state-writer-redaction (DELIBERATE re-pin, AC15 (a); old -> new): `ga`-`gd` are used by that story, the unused ids continue at `ge` ("`ga` onward" before; the old note is refuted by state_writer_redaction_docs_test.exs)
    # story membership-state-model (DELIBERATE re-pin, AC15 (a); old -> new): `ge`-`gi` are used by that story, the unused ids continue at `gj` ("`ge` onward" before; the old note is refuted by membership_state_model_docs_test.exs)
    # story history-visibility-enforcement (DELIBERATE re-pin, AC21 (a); old -> new): `gj`-`gl` are used by that story, the unused ids continue at `gm` ("`gj` onward" before; the old note is refuted by history_visibility_docs_test.exs)
    assert f =~ ~r/unused:[^.]*`gm` onward/, "unused ids continue at gm"
    refute f =~ ~r/unused:[^.]*`(fv|fz)` onward/, "the old `fv` / `fz` onward notes are gone"
    assert f =~ "`fq`-`fr`: moderation-routes-atomic-ban", "the earlier attribution stays"
  end

  # ═══ (e) the removed phrases ═════════════════════════════════════════════════════

  test "(e): the phrases of the old state are gone from the docs (skipped entry, not carried, open eq / er / fr)" do
    scope = read(@scope)
    followups = read(@followups)

    refute scope =~ "An `m.room.power_levels` entry of `initial_state` stays **skipped**"
    refute scope =~ "The power levels are NOT carried (follow-up `fr`)"
    refute followups =~ "| er | **An `initial_state` `m.room.power_levels` entry stays skipped**"
    refute followups =~ "| fr | **`upgrade_room` does not carry the power levels.**"
    refute followups =~ ~r/\| eq \| \*\*Power-level enforcement gaps[^|]*\|[^|]*\|[^|]*\| open/
  end
end
