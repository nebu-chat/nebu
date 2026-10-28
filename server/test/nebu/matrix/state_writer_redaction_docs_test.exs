defmodule Nebu.Matrix.StateWriterRedactionDocsTest do
  @moduledoc """
  Static checks (no network) for story `state-writer-redaction` (epic oauth-broker, follow-ups `fw`, `fv`, `fz`, `fx`), AC14 and AC16:

    * (a) `docs/matrix-api-scope.md`: the `/redact` row is ✅ (the D2 order and texts, own vs `redact`, D13, the labels word for word), the `/send` row (redactions go
      through the redaction writer, `content.redacts` moved, the risk note gone), the two PUT state rows (`write_state/5`, the slot stamp, `404` for an archived room,
      no lazy `rooms` row, explicit errcodes), the createRoom row (the `@` rule on `initial_state`), the upgrade row (the tombstone level with a floor of 100), the
      `/messages`, `/event`, `/relations` (3), `/sync` and `/search` rows (pruned / excluded);
    * (b) `docs/architecture/07-deployment.md`: the paragraph "Redaction and the room-process state writer" with the operator query **Q-rd** (its SQL is executed
      here, against fixture rows in a rolled-back transaction);
    * (c) `docs/architecture/08-concepts.md`: the audit action; (d) `CHANGELOG.md` `[Unreleased]`;
    * (e) `docs/stories/oauth-broker/follow-ups.md`: `fw`, `fv`, `fz`, `fx` CLOSED (the pinned words of `power_levels_docs_test.exs` stay), the notes on `eu`, `en`,
      `fp`, `fl`, `ft`, `fe`, `bd`, `fk`, the new rows `ga` - `gd`, the id line (`ga`-`gd`: this story, unused from `ge`);
    * (f) the removed phrases are refuted.

  The pins are facts and unique new terms, not whole sentences, so the wording stays free; the LABELS (AC16) are pinned word for word (they are the contract of the
  story's "labelled" decisions: the dev copies them). The `ga` onward id-line assertions of the nine older docs suites are DELIBERATELY re-pinned to `ge` onward (each with a
  comment naming this story); the old `ga` onward is refuted HERE.

  The file reads are `async`-safe; the one database test (Q-rd) only works inside a transaction it rolls back.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)
  @scope Path.join(@root, "docs/matrix-api-scope.md")
  @deploy Path.join(@root, "docs/architecture/07-deployment.md")
  @concepts Path.join(@root, "docs/architecture/08-concepts.md")
  @followups Path.join(@root, "docs/stories/oauth-broker/follow-ups.md")
  @changelog Path.join(@root, "CHANGELOG.md")
  @story "state-writer-redaction"

  @redact "| PUT | `/_matrix/client/v3/rooms/{roomId}/redact/{eventId}/{txnId}` | "
  @send "| PUT | `/_matrix/client/v3/rooms/{roomId}/send/{eventType}/{txnId}` | "
  @put_state "| PUT | `/_matrix/client/v3/rooms/{roomId}/state/{eventType}/{stateKey}` | "
  @put_state_short "| PUT | `/_matrix/client/v3/rooms/{roomId}/state/{eventType}` | "
  @create "| POST | `/_matrix/client/v3/createRoom` | "
  @upgrade "| POST | `/_matrix/client/v3/rooms/{roomId}/upgrade` | "
  @messages "| GET | `/_matrix/client/v3/rooms/{roomId}/messages` | "
  @event "| GET | `/_matrix/client/v3/rooms/{roomId}/event/{eventId}` | "
  @relations [
    "| GET | `/_matrix/client/v1/rooms/{roomId}/relations/{eventId}` | ",
    "| GET | `/_matrix/client/v1/rooms/{roomId}/relations/{eventId}/{relType}` | ",
    "| GET | `/_matrix/client/v1/rooms/{roomId}/relations/{eventId}/{relType}/{eventType}` | "
  ]
  @sync "| GET | `/_matrix/client/v3/sync` | "
  @search "| POST | `/_matrix/client/v3/search` | "

  @title "**Redaction and the room-process state writer (story state-writer-redaction, follow-ups `fw`, `fv`, `fz`, `fx`).**"

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

  defp put_state_rows, do: Enum.map_join([@put_state, @put_state_short], " ", &scope_row/1)

  # From the bold title of the redaction paragraph to the next markdown heading (the paragraph and its SQL block)
  defp redaction_section(normalise? \\ true) do
    raw = File.read!(@deploy)

    case :binary.match(raw, @title) do
      {at, _} ->
        rest = binary_part(raw, at, byte_size(raw) - at)
        # the paragraph ends where the next bold paragraph title or heading starts
        [section | _] = Regex.split(~r/\n\#{2,4} |\n\*\*[A-Z][^\n]{20,}\(story /, String.slice(rest, String.length(@title), String.length(rest)), parts: 2)
        section = @title <> section
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

  # ═══ (a) the scope doc: the /redact row ═══════════════════════════════════════════════

  test "scope doc (a): the /redact row is ✅, names the story, the writer and the migration; the old 'Unrouted' row text is gone" do
    row = scope_row(@redact)

    assert String.starts_with?(row, @redact <> "✅ |")
    assert row =~ @story
    assert row =~ "`Room.Server.redact/5`" and row =~ "room-process" and row =~ "`fw`"
    assert row =~ "`events.redacts`" and row =~ "000051"
    refute row =~ "Unrouted (follow-up `fw`)"
    refute row =~ "Element's \"Remove\" of a message fails"
  end

  test "scope doc (a): the /redact row carries the D2 order and the fixed texts, own vs redact, the answers 403 / 404 / 400" do
    row = scope_row(@redact)

    assert row =~ ~r/first failure wins/i
    assert row =~ "`events[\"m.room.redaction\"]`" and row =~ "`events_default`" and row =~ "`redact`"

    for text <- [
          "You are not a member of this room",
          "You do not have a high enough power level to send this event",
          "You do not have a high enough power level to redact other users' events",
          "Event not found",
          "This event cannot be redacted on this server",
          "M_ROOM_ARCHIVED: room is archived"
        ] do
      assert row =~ text, "the row carries the fixed text #{inspect(text)}"
    end

    for term <- ["`404 M_NOT_FOUND`", "`400 M_BAD_STATE`", "`403 M_FORBIDDEN`", "`503 M_UNAVAILABLE`", "`room_event_redacted`"], do: assert(row =~ term, "the row names #{term}")
  end

  test "scope doc (a): the /redact row carries the request validation (D13): the errcodes, the fixed reason texts and the 1024-byte cap" do
    row = scope_row(@redact)

    for term <- ["`400 M_NOT_JSON`", "`400 M_BAD_JSON`", "`400 M_INVALID_PARAM`", "`413 M_TOO_LARGE`", "reason must be a string", "reason exceeds 1024 bytes", "1024 bytes"],
        do: assert(row =~ term, "the row names #{term}")

    assert row =~ ~r/32 levels|nesting/i, "the depth rule is named"
    assert row =~ ~r/a body `redacts` is dropped \(the path wins\)/
  end

  test "scope doc (a): the /redact row carries the labels word for word (D2, D4, D6, D7 and the Oracle labels of AC16)" do
    row = scope_row(@redact)

    for label <- [
          "state events and redactions cannot be redacted: Nebu restriction",
          "redactions are not rate-limited (spec: Rate-limited: No)",
          "target must exist: Nebu choice",
          "stored content kept, pruned on read: compliance (`gb`)",
          "authorisation is always re-evaluated before idempotency: Nebu choice",
          "txn scope per user, not per device, node-local (`bd`)",
          "unknown room: 404 as `/send`",
          "archived room: 400 M_BAD_STATE as `/send`"
        ] do
      assert row =~ label, "the /redact row carries the label #{inspect(label)}"
    end

    assert row =~ "`ga`" and row =~ "`gc`", "the residuals are named"
    assert row =~ "`unsigned.redacted_because`" and row =~ "`content.redacts`", "the serving format"
  end

  # ═══ (a) the scope doc: the other rows ═══════════════════════════════════════════════════

  test "scope doc (a): the /send row: m.room.redaction goes through the redaction writer, content.redacts is moved to the top level, the risk note of fw is gone, the legacy label" do
    row = scope_row(@send)

    assert row =~ @story
    assert row =~ "`m.room.redaction`" and row =~ "redaction writer" and row =~ "`Room.Server.redact/5`"
    assert row =~ "`content.redacts`" and row =~ ~r/(moved|moves)[^.]{0,40}top level/i
    assert row =~ "m.room.redaction requires content.redacts"
    assert row =~ "legacy unchecked redactions are served without `redacts` (`gd`)"
    refute row =~ "stored as-is and delivered"
    refute row =~ "Risk until `fw`"
    refute row =~ "`redact` is stored, not evaluated"
  end

  test "scope doc (a): the PUT state rows: decided and written in the room process (write_state/5), the slot stamp, one transaction, no lazy rooms row, explicit errcodes" do
    rows = put_state_rows()

    assert rows =~ @story
    assert rows =~ "`write_state/5`" and rows =~ "room process"
    assert rows =~ ~r/max\(now,\s*latest[^)]*\+\s*1\)/i, "the slot stamp"
    assert rows =~ ~r/one transaction/i and rows =~ "`Room.DB.apply_state_change/3`" and rows =~ "`rooms.name`"
    assert rows =~ "`fz`" and rows =~ ~r/lazy|lazily/i and rows =~ "`rooms`"
    assert rows =~ ~r/authoritativ/i, "the room process decides again after the snapshot pre-check"
    assert rows =~ ~r/explicit[^.]{0,40}M_FORBIDDEN/i
    assert rows =~ "`M_BAD_ALIAS`" and rows =~ "`m.space.parent`", "the content rules stay in the caller"
    refute rows =~ "`redact` not evaluated: no redaction route"
  end

  test "scope doc (a): the PUT state rows carry the labels word for word (archived room, the kept inconsistency, the caller-side writers)" do
    rows = put_state_rows()

    for label <- [
          "archived room: 404 M_NOT_FOUND: Nebu choice",
          "archived answer differs from `/redact` (400 M_BAD_STATE): kept on purpose",
          "createRoom and upgrade-copy writers stay in the caller: brand-new room"
        ] do
      assert rows =~ label, "the PUT state rows carry the label #{inspect(label)}"
    end
  end

  test "scope doc (a): the createRoom row: the @ rule on every initial_state entry, the 400 text, the stricter-rule label", _ctx do
    row = scope_row(@create)

    assert row =~ "`M_INVALID_ROOM_STATE`" and row =~ "The initial state contains a state key of another user"
    assert row =~ "`@` rule on every `initial_state` entry incl. `m.room.member`: stricter Nebu rule"
    assert row =~ @story
  end

  test "scope doc (a): the upgrade row: the tombstone level with a floor of 100 (labelled), decided in the room process of the old room, the new texts; the old sentence is gone" do
    row = scope_row(@upgrade)

    assert row =~ "upgrade needs the tombstone level and at least 100: Nebu restriction"
    assert row =~ "m.room.tombstone" and row =~ "`write_state/5`" and row =~ "room process"
    assert row =~ "You do not have a high enough power level to upgrade this room"
    assert row =~ "`fx`"
    refute row =~ "the upgrade permission stays `users[requester] >= 100` and not the tombstone level"
  end

  test "scope doc (a): /messages, /event, /relations (three rows), /sync and /search say that redacted events are served pruned / excluded" do
    for prefix <- [@messages, @event, @sync | @relations] do
      row = scope_row(prefix)
      assert row =~ "`unsigned.redacted_because`" and (row =~ "`content: {}`" or row =~ ~r/empty content/i), "#{prefix}: pruned with redacted_because"
      assert row =~ @story, "#{prefix}: names the story"
      assert row =~ ~r/pruned/i, "#{prefix}: served pruned"
    end

    for prefix <- @relations do
      row = scope_row(prefix)
      assert row =~ ~r/child[^.]{0,40}exclud/i and row =~ ~r/parent[^.]{0,40}keeps?[^.]{0,20}children/i, "#{prefix}: the relation rules"
    end

    sync = scope_row(@sync)
    assert sync =~ "legacy unchecked redactions are served without `redacts` (`gd`)"

    search = scope_row(@search)
    assert search =~ ~r/redacted events? (is|are) excluded|excludes? (the )?redacted/i
  end

  # ═══ (b) 07-deployment ═══════════════════════════════════════════════════════════

  test "07-deployment (b): the paragraph says Element's Remove works, what is kept in the database and why (Compliance Mode), the migration and that it is rolling-deploy safe" do
    sec = redaction_section()

    for word <- ["\"Remove\"", "Compliance Mode", "`events.redacts`", "000051", "events_redacts_idx", "rolling-deploy safe", "ADR-023", "`gb`", "`ga`", "`403`"] do
      assert sec =~ word, "the paragraph mentions #{word}"
    end

    assert sec =~ ~r/hides? (a|the) message[^.]{0,30}(not|never) (erase|delete|remove)/i
    assert sec =~ ~r/behaviou?r change/i
    assert sec =~ ~r/never changed/, "the original event row is never changed"
  end

  test "07-deployment (b): legacy rows and the operator query Q-rd are described: NULL column, never applied, a rolled-back transaction with fixture rows, the SQL block" do
    sec = redaction_section()

    assert sec =~ "**Q-rd**" and sec =~ "`gd`"
    assert sec =~ ~r/legacy/i and sec =~ ~r/never applied/ and sec =~ ~r/`redacts` column is NULL/
    assert sec =~ ~r/rolled-back transaction/i and sec =~ ~r/fixture rows/i
    assert sec =~ "```sql", "the query is shown as a SQL block"
    assert sec =~ "event_type = 'm.room.redaction' AND redacts IS NULL"
  end

  @tag :integration
  test "07-deployment (b): the Q-rd SQL lists a legacy redaction row, and neither a writer-made redaction nor a message (rolled-back transaction, fixture rows)" do
    sql =
      case Regex.run(~r/```sql\n(.*?)```/s, redaction_section(false)) do
        [_, block] -> block
        nil -> flunk("the redaction paragraph has no SQL block")
      end

    assert sql =~ ~r/\A\s*(SELECT|WITH)/i, "Q-rd is read-only"
    refute sql =~ ~r/\b(INSERT|UPDATE|DELETE|DROP|ALTER|TRUNCATE)\b/i

    suffix = Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    room = "!qrd#{suffix}:test.local"
    ids = for kind <- ~w(legacy writer message other_legacy), into: %{}, do: {kind, "$qrd#{kind}#{suffix}"}
    now = System.system_time(:millisecond)

    result =
      Nebu.Repo.transaction(fn ->
        Ecto.Adapters.SQL.query!(Nebu.Repo, "INSERT INTO rooms (room_id, visibility, created_at, power_levels_json) VALUES ($1, 'private', $2, '{}')", [room, now])

        for {kind, type, redacts, content} <- [
              {"legacy", "m.room.redaction", nil, %{"redacts" => ids["message"], "reason" => "legacy"}},
              {"writer", "m.room.redaction", ids["message"], %{"reason" => "writer"}},
              {"message", "m.room.message", nil, %{"body" => "hello"}},
              {"other_legacy", "m.room.redaction", nil, %{}}
            ] do
          Ecto.Adapters.SQL.query!(
            Nebu.Repo,
            "INSERT INTO events (event_id, room_id, sender, event_type, content, origin_server_ts, signatures, state_key, redacts) VALUES ($1, $2, '@a:test.local', $3, $4, $5, NULL, NULL, $6)",
            [ids[kind], room, type, content, now, redacts]
          )
        end

        listed = Ecto.Adapters.SQL.query!(Nebu.Repo, sql, []).rows |> List.flatten() |> Enum.filter(&is_binary/1)
        Nebu.Repo.rollback({:listed, listed})
      end)

    assert {:error, {:listed, listed}} = result

    for kind <- ~w(legacy other_legacy), do: assert(ids[kind] in listed, "Q-rd lists the #{kind} redaction row")
    refute ids["writer"] in listed, "Q-rd does not list a writer-made redaction"
    refute ids["message"] in listed, "Q-rd does not list a message"
    assert Ecto.Adapters.SQL.query!(Nebu.Repo, "SELECT count(*) FROM events WHERE room_id = $1", [room]).rows == [[0]], "the fixture rows were rolled back"
  end

  # ═══ (c) 08-concepts, (d) CHANGELOG ══════════════════════════════════════════════════

  test "08-concepts (c): the Audit Logging section registers room_event_redacted: another user's event only, the exact metadata, no reason, no row for own / replay / refusal" do
    concepts = read(@concepts)
    [_, from_audit] = String.split(concepts, "## Audit Logging", parts: 2)
    [audit | _] = String.split(from_audit, ~r/\n## /, parts: 2)

    assert audit =~ "`room_event_redacted`"
    assert audit =~ @story
    assert audit =~ ~r/ANOTHER user's event/ and audit =~ "`event_id`" and audit =~ "`target_sender`"
    assert audit =~ ~r/(never|no|not)[^.]{0,20}reason/i and audit =~ ~r/no row for an own[- ]event redaction|own[- ]event redactions? (writes?|has|get)[^.]{0,10}no row/i
  end

  test "CHANGELOG (d): [Unreleased] ### Added has the route, the audit action and migration 000051" do
    added = unreleased_section("Added") |> String.replace(~r/\s+/, " ")

    assert added =~ "PUT /_matrix/client/v3/rooms/{roomId}/redact/{eventId}/{txnId}"
    assert added =~ "`room_event_redacted`" and added =~ "000051"
    assert added =~ @story
    assert added =~ "`fw`" and added =~ "Q-rd"
  end

  test "CHANGELOG (d): [Unreleased] ### Changed has a warning entry: /send redactions authorised and applied, pruned reads, state events cannot be redacted, PUT state in the room process, the upgrade, initial_state" do
    changed = unreleased_section("Changed")
    entry = changed |> String.split(~r/\n- /) |> Enum.find(&(&1 =~ "⚠" and &1 =~ @story))

    assert entry, "a Changed entry with the warning sign naming the story"
    flat = String.replace(entry, ~r/\s+/, " ")

    for term <- ["`/send`", "`m.room.redaction`", "`redact` level", "pruned", "state events and redactions cannot be redacted", "archived room", "`rooms` row", "tombstone level", "`initial_state`", "behaviour change"] do
      assert flat =~ term, "the entry mentions #{term}"
    end
  end

  # ═══ (e) follow-ups ══════════════════════════════════════════════════════════════════

  for {id, words} <- [
        # the words power_levels_docs_test.exs pins on these rows, kept by the CLOSED rewrite
        {"fv", ["write_state/5", "state-writer-room-process", "`eu`", "emit_state_event_at/6"]},
        {"fw", ["redact", "m.room.redaction", "/send", "events_default", "RAISED", "events[\"m.room.redaction\"]"]},
        {"fx", ["m.room.tombstone", "required_level", "users[requester] >= 100", "floor"]},
        {"fz", ["rooms", "lazily", "fetch_room_state/1", "403", "pre-existing"]}
      ] do
    test "follow-ups (e): #{id} is CLOSED by this story (CLOSED style, status closed, the original item kept) and keeps the words power_levels_docs_test pins" do
      f = read(@followups)
      assert f =~ ~r/\| #{unquote(id)} \| \*\*CLOSED by story #{@story} \(\d{4}-\d{2}-\d{2}\)/, "the CLOSED prefix like ea / ep / ex / eq"

      line = followup_line(unquote(id))
      assert line =~ ~r/\| closed \|\s*\z/, "the status column says closed"
      refute line =~ ~r/\| open[^|]*\|\s*\z/
      assert line =~ ~r/Original item/i, "the original text stays"
      assert line =~ "power-levels-enforcement", "the origin cell still names the story that raised it"

      for word <- unquote(words), do: assert(line =~ word, "#{unquote(id)} keeps #{inspect(word)}")
    end
  end

  test "follow-ups (e): the closed rows state what was done (the writer, the floor of 100, the 403 without a rooms row)" do
    assert followup_line("fw") =~ "`events.redacts`" and followup_line("fw") =~ "`gb`" and followup_line("fw") =~ "`gd`" and followup_line("fw") =~ "`ga`"
    assert followup_line("fx") =~ "floor of 100" and followup_line("fx") =~ "Nebu restriction"
    assert followup_line("fz") =~ "without a `rooms` row"
    assert followup_line("fv") =~ "`mode: :tombstone`" and followup_line("fv") =~ "stricter Nebu rule"
  end

  for {id, patterns} <- [
        {"eu", ["write_state/5", "latest"]},
        {"en", ["set_room_state failed", "`/send` depth / NUL stay"]},
        {"fp", ["not charged", "Rate-limited: No"]},
        {"fl", ["`unsigned.redacted_because`", "`age` on `/messages`"]},
        {"ft", ["`Room.Server.redact/5`", "`write_state/5`", "format_status/1"]},
        {"fe", ["`:pg.get_members/1`", "`write_state/5`"]},
        {"bd", ["/redact", "event id"]},
        {"fk", ["`Nebu.Matrix.Redaction`", "`m.replace`", "`latest_event`"]}
      ] do
    test "follow-ups (e): the existing row #{id} carries a '**Note (state-writer-redaction, <date>):**' with the facts of this story" do
      row = followup_line(unquote(id))

      assert row =~ ~r/\*\*Note \(#{@story}, \d{4}-\d{2}-\d{2}\):\*\*/, "#{unquote(id)}: the note is labelled like the other notes of this file"
      [_, note] = String.split(row, "**Note (#{@story}, ", parts: 2)
      for pattern <- unquote(patterns), do: assert(note =~ pattern, "#{unquote(id)}: the note mentions #{pattern}")
    end
  end

  test "follow-ups (e): the new rows ga, gb, gc, gd exist, are open and non-gating, attributed to this story and name their facts" do
    for {id, words} <- [
          {"ga", ["State events", "redaction events", "cannot be redacted", "Nebu restriction", "`m.room.power_levels`"]},
          {"gb", ["Compliance Mode", "retention", "mxc", "ADR-030", "prune on read", "`search_vector`"]},
          {"gc", ["Server administrators", "Admin UI"]},
          {"gd", ["**Q-rd**", "Legacy", "`redacts` column is NULL", "never applied", "`content.redacts`", "owner decision"]}
        ] do
      [_, text, origin, status] = followup_cells(id)
      assert origin =~ @story, "#{id} is attributed to this story"
      assert String.downcase(status) =~ "open" and String.downcase(status) =~ "non-gating", "#{id} is open and non-gating"
      for word <- words, do: assert(text =~ word, "#{id} mentions #{word}")
    end
  end

  test "follow-ups (e): the id line lists ga - gd for this story and continues at ge (the old 'ga onward' is gone, the earlier attributions stay)" do
    f = read(@followups)

    assert f =~ "`ga`-`gd`: #{@story}"
    # story membership-state-model (DELIBERATE re-pin, AC15 (a); old -> new): `ge`-`gi` are used by that story, the unused ids continue at `gj` ("`ge` onward" before; the old note is refuted by membership_state_model_docs_test.exs)
    # story history-visibility-enforcement (DELIBERATE re-pin, AC21 (a); old -> new): `gj`-`gl` are used by that story, the unused ids continue at `gm` ("`gj` onward" before; the old note is refuted by history_visibility_docs_test.exs)
    assert f =~ ~r/unused:[^.]*`gm` onward/, "unused ids continue at gm"
    refute f =~ ~r/unused:[^.]*`(ga|gd)` onward/, "the old `ga` onward note is gone"
    assert f =~ "`fv`-`fz`: power-levels-enforcement", "the earlier attribution stays"
  end

  # ═══ (f) the removed phrases ═════════════════════════════════════════════════════════

  test "(f): the phrases of the old state are gone from the docs (stored as-is, not evaluated, unrouted, open rows)" do
    scope = read(@scope)
    followups = read(@followups)

    refute scope =~ "an `m.room.redaction` is stored as-is and delivered"
    refute scope =~ "`redact` not evaluated: no redaction route"
    refute scope =~ "Unrouted (follow-up `fw`)"
    refute scope =~ "`redact`: stored, not evaluated"

    for id <- ~w(fv fw fx fz) do
      refute followups =~ ~r/\| #{id} \| \*\*[^|]*\|[^|]*\| open/, "#{id} is no longer an open row"
    end
  end

  # ═══ AC18 (i): the security cycle 1 / 2 operator notes (dev addition, security cycle 2, review M3 (a)) ═══════════════

  test "07-deployment AC18 (i): the lock note (ACCESS EXCLUSIVE over the SHARE-lock index scan, maintenance window, CONCURRENTLY pre-create with the column first)" do
    sec = redaction_section()

    assert sec =~ "ACCESS EXCLUSIVE" and sec =~ "SHARE lock"
    assert sec =~ ~r/READS AND WRITES on `events` wait/i
    assert sec =~ "maintenance window"
    assert sec =~ "CREATE INDEX CONCURRENTLY IF NOT EXISTS events_redacts_idx ON events (redacts, origin_server_ts, event_id) WHERE redacts IS NOT NULL"
    assert sec =~ "ALTER TABLE events ADD COLUMN IF NOT EXISTS redacts TEXT"
    assert sec =~ ~r/no long transaction is open/
  end

  test "07-deployment AC18 (i): rolling back 000051 or only the application image re-exposes removed messages" do
    sec = redaction_section()

    assert sec =~ ~r/Rollback re-exposes removed messages/i
    assert sec =~ "readable again"
    assert sec =~ ~r/rolling back only the application image[^.]*re-exposes/
  end

  test "AC18 (i): edits of a removed message stay served (scope doc /redact row and 07-deployment); retry /upgrade on 503 (scope doc upgrade row and 07-deployment)" do
    sec = redaction_section()

    assert scope_row(@redact) =~ ~r/edits of a removed message stay served/i
    assert sec =~ ~r/edits of a removed message stay served/i
    assert scope_row(@upgrade) =~ "on 503, retry the upgrade"
    assert sec =~ "on 503, retry the upgrade"
  end

  test "the migration header carries the lock note and the rollback re-exposure (AC13, D5 operator notes)" do
    header = File.read!(Path.join(@root, "server/priv/migrations/000051_events_redacts.up.sql"))

    assert header =~ "ACCESS EXCLUSIVE" and header =~ "CONCURRENTLY" and header =~ "maintenance window"
    assert header =~ "re-exposure"
  end
end
