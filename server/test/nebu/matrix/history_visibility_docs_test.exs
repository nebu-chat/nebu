defmodule Nebu.Matrix.HistoryVisibilityDocsTest do
  @moduledoc """
  Static checks (no network) for story `history-visibility-enforcement` (epic oauth-broker, follow-up `es`), AC14, AC15 and the refutation of the old id line:

    * (a) `docs/matrix-api-scope.md`: the `/messages`, `/event`, the three `/relations`, `/search`, `/sync` and `/initialSync` rows name the enforcement ("history visibility enforced", the values `invited` /
      `joined`), the `PUT /state/{eventType}` rows name the four values and `gj`, and the fourteen labels of AC15 stand WORD FOR WORD (whitespace-normalised) in the document;
    * (b) `docs/architecture/07-deployment.md`: the paragraph "**History visibility (story history-visibility-enforcement, follow-up `es`).**" with the operator queries **Q-hv1** (the rooms whose
      CURRENT setting is `invited` or `joined`) and **Q-hv2** (the 20 rooms with the most hv events and the 20 (room, user) pairs with the most member events): both SQL blocks are EXECUTED here
      against fixture rows in a rolled-back transaction;
    * (c) `docs/architecture/06-runtime.md`: the D8 "Visibility rule" bullet is rewritten (omitted when the predecessor is not visible; the words "history_visibility" and "`es`" stay), a "History
      visibility" passage names the fragment, the read paths and the fail-closed rule;
    * (d) `CHANGELOG.md` `[Unreleased]`: `### Security` and `### Changed`;
    * (e) `docs/stories/oauth-broker/follow-ups.md`: `es` CLOSED keeping its "Original item" text, the notes on `fg`, `fk`, `fl`, `gf`, `fc`, `gb`, the new rows `gj`, `gk`, `gl`, the id line
      (`gj`-`gl`: this story, unused from `gm`; the old "`gj` onward" is refuted HERE);
    * (f) the removed phrases are refuted.

  The pins are facts and unique new terms, not whole sentences, so the wording stays free; the LABELS are pinned word for word (they are the contract of the story's "labelled" decisions: the dev copies
  them). The `gj` onward id-line assertions of the ELEVEN older docs suites are DELIBERATELY re-pinned to `gm` onward (each with a comment naming this story); the old `gj` onward is refuted HERE.

  ## Decisions of the ATDD step (ambiguities of the story)

    * "or equivalent pinned words" (AC14 (a)): each enforcing row contains the phrase `history visibility enforced` (case-insensitive) and both values `invited` and `joined`.
    * The operator queries are the first and the second ```` ```sql ```` block of the paragraph (Q-hv1, Q-hv2, in that order); the paragraph has exactly two. The SHAPE of their result is the dev's: the
      tests read every cell of every row (room id, user id, counts), the way a person reads the output.
    * The labels may live in any row or paragraph of the scope doc (the story names no row for them).
  """
  use ExUnit.Case, async: false

  @root Path.expand("../../../..", __DIR__)
  @scope Path.join(@root, "docs/matrix-api-scope.md")
  @deploy Path.join(@root, "docs/architecture/07-deployment.md")
  @runtime Path.join(@root, "docs/architecture/06-runtime.md")
  @followups Path.join(@root, "docs/stories/oauth-broker/follow-ups.md")
  @changelog Path.join(@root, "CHANGELOG.md")
  @story "history-visibility-enforcement"

  @messages "| GET | `/_matrix/client/v3/rooms/{roomId}/messages` | "
  @event "| GET | `/_matrix/client/v3/rooms/{roomId}/event/{eventId}` | "
  @relations "| GET | `/_matrix/client/v1/rooms/{roomId}/relations/{eventId}` | "
  @relations_type "| GET | `/_matrix/client/v1/rooms/{roomId}/relations/{eventId}/{relType}` | "
  @relations_type_event "| GET | `/_matrix/client/v1/rooms/{roomId}/relations/{eventId}/{relType}/{eventType}` | "
  @search "| POST | `/_matrix/client/v3/search` | "
  @sync "| GET | `/_matrix/client/v3/sync` | "
  @initial_sync "| GET | `/_matrix/client/v3/rooms/{roomId}/initialSync` | "
  @put_state "| PUT | `/_matrix/client/v3/rooms/{roomId}/state/{eventType}/{stateKey}` | "
  @put_state_short "| PUT | `/_matrix/client/v3/rooms/{roomId}/state/{eventType}` | "

  @title "**History visibility (story history-visibility-enforcement, follow-up `es`).**"

  # AC15, verbatim
  @labels [
    "the state at an event is the state before it in the `(origin_server_ts, event_id)` order; an event in the same millisecond as a history-visibility change or a member event of the viewer is visible only if both the state before and after that millisecond allow it: Nebu rule (no DAG)",
    "the events before a room's first history-visibility event are `shared` (spec default)",
    "a joined member without a join event is treated as joined since `room_members.joined_at`: legacy / fail-open writes",
    "`/messages` skips the events the viewer may not see; when no visible event remains there is no `end` token (the key is absent or empty): Nebu answers `\"\"`, spec: omitted",
    "the current state is visible to every joined member; `history_visibility` gates events, not the current state",
    "a redacted event visible to the viewer carries its `redacted_because` even when the redaction event itself is outside the viewer's visible history: Nebu choice",
    "`world_readable` rooms are not readable by non-members: no peeking (`gf`)",
    "`guest_access` has no effect: Nebu has no guest accounts",
    # security cycle 2 (MINOR-2, DELIBERATE re-pin, old -> new): "an unknown `history_visibility` value is read as `shared` (spec default; not validated on
    # write, `gj`)" -> the label below (`gj` is CLOSED: the client writers validate since security cycle 1)
    "a stored unknown `history_visibility` value (written before `gj` closed, or via the upgrade copy) is read as `shared` (spec default)",
    "search covers currently joined rooms only (spec: also left rooms; `gl`)",
    "`M_UNAVAILABLE`: Nebu errcode, as elsewhere (`protected.ex`)",
    "visibility follows the `origin_server_ts` order: hv and member events are stamped after the latest event of their slot; a message stamped before an hv change (clock skew between nodes) is judged under the earlier setting: known Nebu invariant (`gk`)",
    "the `/sync` timeline is not `limited` when fewer visible events than the limit exist",
    "`replaces_state` is omitted together with `prev_content` / `prev_sender` when the predecessor is not visible: Nebu choice (no id of an invisible event is served)"
  ]

  defp flat(text), do: String.replace(text, ~r/\s+/, " ")
  defp read(p), do: p |> File.read!() |> flat()
  defp lines(p), do: p |> File.read!() |> String.split("\n")

  defp scope_row(prefix) do
    row = Enum.find(lines(@scope), &String.starts_with?(&1, prefix))
    assert row, "the scope doc has no row starting with #{prefix}"
    flat(row)
  end

  defp followup_line(id) do
    line = Enum.find(lines(@followups), &String.starts_with?(&1, "| #{id} | "))
    assert line, "the follow-up row #{id} does not exist"
    flat(line)
  end

  defp followup_cells(id), do: id |> followup_line() |> String.trim_leading("| ") |> String.trim_trailing(" |") |> String.split(" | ")

  defp section(title, from_path, normalise?) do
    raw = File.read!(from_path)

    case :binary.match(raw, title) do
      {at, _} ->
        rest = binary_part(raw, at, byte_size(raw) - at)
        [section | _] = Regex.split(~r/\n\#{2,4} /, rest, parts: 2)
        if normalise?, do: flat(section), else: section

      :nomatch ->
        flunk("#{Path.basename(from_path)} has no paragraph titled #{title}")
    end
  end

  defp deploy_section(normalise? \\ true), do: section(@title, @deploy, normalise?)

  defp unreleased_section(heading) do
    changelog = File.read!(@changelog)
    assert [_, from_unreleased] = String.split(changelog, "## [Unreleased]", parts: 2)
    [unreleased | _] = String.split(from_unreleased, ~r/\n## \[/, parts: 2)

    assert [_, from_heading] = String.split(unreleased, "### #{heading}", parts: 2), "[Unreleased] has a #{heading} section"
    [section | _] = String.split(from_heading, ~r/\n### /, parts: 2)
    section
  end

  # ═══ (a) the scope doc ═══════════════════════════════════════════════════════════

  for {name, prefix} <- [
        messages: @messages,
        event: @event,
        relations: @relations,
        relations_type: @relations_type,
        relations_type_event: @relations_type_event,
        search: @search,
        sync: @sync,
        initial_sync: @initial_sync
      ] do
    test "scope doc (a): the #{name} row names the enforcement: history visibility enforced, invited / joined, this story" do
      row = scope_row(unquote(prefix))
      assert String.downcase(row) =~ "history visibility enforced", "the row says it"
      assert row =~ "`invited`" and row =~ "`joined`"
      assert row =~ @story
    end
  end

  test "scope doc (a): the page rule, the 404 of an invisible event, the per-result search filter, the 503 of the sync" do
    assert scope_row(@messages) =~ "no `end` token"
    event = scope_row(@event)
    assert event =~ "`404 M_NOT_FOUND`" and event =~ "`Event not found`", "an invisible and an unknown event answer the same fixed 404"

    for prefix <- [@relations, @relations_type, @relations_type_event] do
      row = scope_row(prefix)
      assert row =~ "`Event not found`" and row =~ ~r/invisible|not visible|may not see/i
    end

    search = scope_row(@search)
    assert search =~ ~r/per result|each result|every result/i
    assert search =~ "MUST", "the per-result filter is a spec MUST (S11)"
    sync = scope_row(@sync)
    assert sync =~ "`503`" and sync =~ "`M_UNAVAILABLE`", "the incremental sync fails closed with a 503"
  end

  test "scope doc (a): the PUT state rows name the four values and gj (the setting is not validated on write)" do
    rows = flat(scope_row(@put_state) <> " " <> scope_row(@put_state_short))

    for value <- ["`world_readable`", "`shared`", "`invited`", "`joined`"], do: assert(rows =~ value, "the PUT state rows name #{value}")
    assert rows =~ "`gj`"
    assert rows =~ "history_visibility"
  end

  test "scope doc (a)/AC15: the fourteen labels stand word for word" do
    doc = read(@scope)

    for label <- @labels do
      assert String.contains?(doc, label), "the scope doc lacks the label: #{String.slice(label, 0, 80)}..."
    end
  end

  # ═══ (b) 07-deployment ═══════════════════════════════════════════════════════════

  test "07-deployment (b): the behaviour change, what members see now, shared rooms unchanged, the current state stays visible, no deletion" do
    sec = deploy_section()

    assert sec =~ ~r/behaviou?r change/i
    assert sec =~ ~r/no migration/i
    for word <- ["`invited`", "`joined`", "`shared`", "search", "permalink", "thread", "preset", "current state"], do: assert(sec =~ word, "the paragraph mentions #{word}")
    assert sec =~ ~r/no backfill/i
    assert sec =~ ~r/events stay stored|stay stored|not deleted/i, "no deletion: events stay stored"
  end

  test "07-deployment (b): Q-hv1 and Q-hv2: read-only, off-peak, rolled-back transaction with fixture rows, exactly two SQL blocks" do
    sec = deploy_section()

    assert sec =~ "Q-hv1" and sec =~ "Q-hv2"
    assert sec =~ ~r/read-only/i and sec =~ ~r/off-peak/i
    assert sec =~ ~r/rolled-back transaction/i and sec =~ ~r/fixture rows/i
    assert length(Regex.scan(~r/```sql\n/, deploy_section(false))) == 2, "the two queries are shown as SQL blocks"
    assert sec =~ ~r/20 rooms/ and sec =~ ~r/20 \(room, user\) pairs|20 pairs/
  end

  @tag :integration
  test "07-deployment (b): Q-hv1 lists the rooms whose CURRENT setting is invited or joined (both JSONB forms; an unknown value, a NULL state key and a changed-back room are not listed)" do
    [q1, _q2] = sql_blocks()
    assert strip_comments(q1) =~ ~r/\A\s*(SELECT|WITH)/i, "Q-hv1 is read-only"
    refute q1 =~ ~r/\b(INSERT|UPDATE|DELETE|DROP|ALTER|TRUNCATE)\b/i

    suffix = Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    kinds = ~w(joined invited shared worldreadable none changedback unknown nullkey stringjoined stringshared tiebreak)
    ids = for k <- kinds, into: %{}, do: {k, "!qhv1#{k}#{suffix}:test.local"}

    result =
      Nebu.Repo.transaction(fn ->
        for {_k, room} <- ids, do: insert_room!(room)

        insert_hv!(ids["joined"], ~s({"history_visibility":"joined"}), 100)
        insert_hv!(ids["invited"], ~s({"history_visibility":"invited"}), 100)
        insert_hv!(ids["shared"], ~s({"history_visibility":"shared"}), 100)
        insert_hv!(ids["worldreadable"], ~s({"history_visibility":"world_readable"}), 100)
        # no hv event at all: ids["none"]
        insert_hv!(ids["changedback"], ~s({"history_visibility":"joined"}), 100)
        insert_hv!(ids["changedback"], ~s({"history_visibility":"shared"}), 200)
        insert_hv!(ids["unknown"], ~s({"history_visibility":"nonsense"}), 100)
        insert_hv!(ids["nullkey"], ~s({"history_visibility":"joined"}), 100, nil)
        insert_hv_string!(ids["stringjoined"], ~s({"history_visibility":"joined"}), 100)
        insert_hv_string!(ids["stringshared"], ~s({"history_visibility":"shared"}), 100)
        # two events in the same millisecond: the event_id DESC winner (`$z...`: joined) is the current setting
        insert_hv!(ids["tiebreak"], ~s({"history_visibility":"shared"}), 100, "", "$aaaa" <> suffix)
        insert_hv!(ids["tiebreak"], ~s({"history_visibility":"joined"}), 100, "", "$zzzz" <> suffix)

        listed = Ecto.Adapters.SQL.query!(Nebu.Repo, q1, []).rows |> List.flatten() |> Enum.filter(&is_binary/1)
        Nebu.Repo.rollback({:listed, listed})
      end)

    assert {:error, {:listed, listed}} = result

    for k <- ~w(joined invited stringjoined tiebreak), do: assert(ids[k] in listed, "Q-hv1 lists the #{k} room")
    for k <- ~w(shared worldreadable none changedback unknown nullkey stringshared), do: refute(ids[k] in listed, "Q-hv1 does not list the #{k} room")

    leftovers = Ecto.Adapters.SQL.query!(Nebu.Repo, "SELECT count(*) FROM rooms WHERE room_id = ANY($1)", [Map.values(ids)]).rows
    assert leftovers == [[0]], "the fixture rows were rolled back"
  end

  @tag :integration
  test "07-deployment (b): Q-hv2 lists the room with the most hv events and the (room, user) pair with the most member events, with their counts, at most 20 of each; read-only" do
    [_q1, q2] = sql_blocks()
    assert strip_comments(q2) =~ ~r/\A\s*(\(?SELECT|WITH)/i, "Q-hv2 is read-only"
    refute q2 =~ ~r/\b(INSERT|UPDATE|DELETE|DROP|ALTER|TRUNCATE)\b/i

    suffix = Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    busy_room = "!qhv2busy#{suffix}:test.local"
    quiet_room = "!qhv2quiet#{suffix}:test.local"
    member_room = "!qhv2member#{suffix}:test.local"
    busy_user = "@busy#{suffix}:test.local"

    result =
      Nebu.Repo.transaction(fn ->
        for room <- [busy_room, quiet_room, member_room], do: insert_room!(room)
        # 400 hv events in the busy room (more than any real room), 2 in the quiet one
        for i <- 1..400, do: insert_hv!(busy_room, ~s({"history_visibility":"shared"}), 1_000 + i)
        for i <- 1..2, do: insert_hv!(quiet_room, ~s({"history_visibility":"shared"}), 1_000 + i)
        # 450 member events of ONE user in one room
        for i <- 1..450 do
          insert_event!(member_room, "m.room.member", ~s({"membership":"#{if rem(i, 2) == 0, do: "join", else: "leave"}"}), 2_000 + i, busy_user)
        end

        rows = Ecto.Adapters.SQL.query!(Nebu.Repo, q2, []).rows
        Nebu.Repo.rollback({:rows, rows})
      end)

    assert {:error, {:rows, rows}} = result
    cells = List.flatten(rows)

    assert busy_room in cells, "Q-hv2 lists the room with the most hv events"
    assert member_room in cells and busy_user in cells, "Q-hv2 lists the (room, user) pair with the most member events"
    assert Enum.any?(cells, &(&1 in [400])), "with the count of hv events (400)"
    assert Enum.any?(cells, &(&1 in [450])), "with the count of member events (450)"
    assert length(rows) <= 40, "at most 20 rooms and 20 pairs"
  end

  defp strip_comments(sql), do: String.replace(sql, ~r/^\s*--.*\n/m, "")

  defp sql_blocks do
    blocks = Regex.scan(~r/```sql\n(.*?)```/s, deploy_section(false)) |> Enum.map(fn [_, b] -> b end)
    assert length(blocks) == 2, "Q-hv1 and Q-hv2"
    blocks
  end

  defp insert_room!(room),
    do: Ecto.Adapters.SQL.query!(Nebu.Repo, "INSERT INTO rooms (room_id, visibility, created_at) VALUES ($1, 'private', $2)", [room, System.system_time(:millisecond)])

  defp insert_hv!(room, json, ts, state_key \\ "", id \\ nil) do
    id = id || "$" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    Ecto.Adapters.SQL.query!(
      Nebu.Repo,
      "INSERT INTO events (event_id, room_id, sender, event_type, content, origin_server_ts, state_key) VALUES ($1, $2, '@a:test.local', 'm.room.history_visibility', $3::jsonb, $4, $5)",
      [id, room, json, ts, state_key]
    )
  end

  defp insert_hv_string!(room, text, ts) do
    id = "$" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    Ecto.Adapters.SQL.query!(
      Nebu.Repo,
      "INSERT INTO events (event_id, room_id, sender, event_type, content, origin_server_ts, state_key) VALUES ($1, $2, '@a:test.local', 'm.room.history_visibility', to_jsonb($3::text), $4, '')",
      [id, room, text, ts]
    )
  end

  defp insert_event!(room, type, json, ts, state_key) do
    id = "$" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    Ecto.Adapters.SQL.query!(
      Nebu.Repo,
      "INSERT INTO events (event_id, room_id, sender, event_type, content, origin_server_ts, state_key) VALUES ($1, $2, '@a:test.local', $3, $4::jsonb, $5, $6)",
      [id, room, type, json, ts, state_key]
    )
  end

  # ═══ (c) 06-runtime ══════════════════════════════════════════════════════════════

  test "06-runtime (c): the D8 visibility rule is rewritten: omitted when the predecessor is not visible to the viewer; history_visibility and `es` stay; the known deviation is gone" do
    doc = read(@runtime)

    refute doc =~ "a known deviation under `invited` / `joined`"
    refute doc =~ "known deviation under `invited` / `joined`"
    refute doc =~ "Binding rule once `es` enforces"
    facts = doc |> String.split("Key design facts") |> Enum.at(1) |> String.slice(0, 5_000)
    assert facts =~ "history_visibility" and facts =~ "`es`"
    assert facts =~ ~r/omitted when the predecessor is not visible/i
  end

  test "06-runtime (c): a History visibility passage names the ONE fragment, the read paths and the fail-closed rule" do
    doc = read(@runtime)
    assert doc =~ "History visibility", "the passage exists"
    passage = doc |> String.split("History visibility") |> Enum.drop(1) |> Enum.join(" ") |> String.slice(0, 6_000)

    for word <- ["`Room.DB.history_visibility_sql/0`", "`/messages`", "`/event`", "`/relations`", "`/search`", "`/sync`", "`/initialSync`", "`prev_content`", "`503`"] do
      assert passage =~ word, "the passage mentions #{word}"
    end

    assert passage =~ ~r/fails? closed|fail-closed/i
    assert passage =~ ~r/one SQL fragment|ONE fragment|one fragment/i
  end

  # ═══ (d) CHANGELOG ═══════════════════════════════════════════════════════════════

  test "CHANGELOG (d): [Unreleased] ### Security: history visibility is enforced on every event read path" do
    security = unreleased_section("Security") |> flat()

    assert security =~ ~r/history visibility/i and security =~ ~r/enforced/i
    for word <- ["`/messages`", "`/sync`", "`/search`", "`/event`", "`/relations`", "`es`", @story, "Q-hv1", "Q-hv2"], do: assert(security =~ word, "the Security entry mentions #{word}")
    assert security =~ ~r/behaviou?r change/i
  end

  test "CHANGELOG (d): [Unreleased] ### Changed: /event and /relations answer 404 for an invisible event, the incremental /sync answers 503 instead of dropping a room silently" do
    changed = unreleased_section("Changed")
    entry = changed |> String.split(~r/\n- /) |> Enum.find(&(&1 =~ @story and &1 =~ "`Event not found`"))
    assert entry, "a Changed entry of this story"
    flat = flat(entry)

    for word <- ["`/event`", "`/relations`", "`404`", "`503`", "`M_UNAVAILABLE`", "incremental `/sync`"], do: assert(flat =~ word, "the Changed entry mentions #{word}")
    assert flat =~ ~r/silent(ly)?/i
  end

  # ═══ (e) follow-ups ══════════════════════════════════════════════════════════════

  test "follow-ups (e): es is CLOSED by this story, KEEPING the original item and the earlier notes (the pinned words of the older suites stay)" do
    line = followup_line("es")
    [_id, text, _origin, status] = followup_cells("es")

    assert text =~ ~r/\*\*CLOSED by story #{@story} \(\d{4}-\d{2}-\d{2}\)/
    assert String.downcase(status) =~ "closed"
    assert line =~ ~r/Original item/i

    for word <- ["`history_visibility` / `guest_access` are stored, not enforced", "guest_access", "D8", "re-joined", "Note (sync-membership-partition", "Note (member-event-prev-content"] do
      assert line =~ word, "es keeps #{word}"
    end

    assert Regex.match?(~r/\bomit/i, line) and Regex.match?(~r/binding/i, line)
  end

  for id <- ~w(fg fk fl gf fc gb) do
    test "follow-ups (e): the existing row #{id} carries a '**Note (history-visibility-enforcement, <date>):**'" do
      line = followup_line(unquote(id))
      assert line =~ ~r/\*\*Note \(#{@story}, [^)]+\):\*\*/
    end
  end

  test "follow-ups (e): the notes say what changed: fg (b) is gl (a), fk the fragment for /context, fl (a) the segments, gf world_readable, fc the 503, gb erasure" do
    assert followup_line("fg") =~ "`gl`"
    fk = followup_line("fk")
    assert fk =~ "`Room.DB.history_visibility_sql/0`" and fk =~ "events_before"
    assert followup_line("fl") =~ ~r/segments?/
    assert followup_line("gf") =~ "`world_readable`"
    assert followup_line("fc") =~ "`503`"
    assert followup_line("gb") =~ ~r/not erasure/
  end

  test "follow-ups (e): the new rows gj (content not validated), gk (read cost, the timestamp residual) and gl (leftovers) exist, are attributed to this story and non-gating" do
    for id <- ~w(gj gk gl) do
      [_id, text, origin, status] = followup_cells(id)
      assert origin =~ @story, "#{id} is attributed to the story"
      assert String.downcase(status) =~ "non-gating"
      assert text =~ ~r/visibility/i
    end

    gj = followup_line("gj")
    assert gj =~ "`PUT /state/m.room.history_visibility`" and gj =~ "guest_access" and gj =~ "`400 M_BAD_JSON`"
    gk = followup_line("gk")
    assert gk =~ "Q-hv2" and gk =~ "origin_server_ts" and gk =~ "statement timeout" and gk =~ "AC22 (12)"
    gl = followup_line("gl")
    for word <- ["(a)", "(b)", "(c)", "(d)", "(e)", "fg", "unsigned.membership", "count_thread_children"], do: assert(gl =~ word, "gl mentions #{word}")
  end

  test "follow-ups (e): the id line lists gj - gl for this story and continues at gm (the old 'gj onward' is gone, the earlier attributions stay)" do
    f = read(@followups)

    assert f =~ "`gj`-`gl`: #{@story}"
    assert f =~ ~r/unused:[^.]*`gm` onward/, "unused ids continue at gm"
    refute f =~ ~r/unused:[^.]*`gj` onward/, "the old `gj` onward note is gone"
    assert f =~ "`ge`-`gi`: membership-state-model", "the earlier attribution stays"
  end

  # ═══ (f) the removed phrases ═════════════════════════════════════════════════════

  test "(f): the phrases of the old state are gone: the known deviation (06-runtime, the /messages row) and `are stored, not enforced` outside the Original item of es" do
    scope = read(@scope)
    runtime = read(@runtime)
    followups = read(@followups)

    refute runtime =~ "known deviation under `invited` / `joined`"
    refute scope_row(@messages) =~ "known deviation under `invited` / `joined`"
    refute scope =~ "known deviation under `invited` / `joined`"

    phrase = "`history_visibility` / `guest_access` are stored, not enforced"
    refute scope =~ phrase
    refute runtime =~ phrase
    outside = followups |> String.replace(followup_line("es"), "")
    refute outside =~ phrase, "the phrase survives only inside the es row (its Original item)"
  end
end
