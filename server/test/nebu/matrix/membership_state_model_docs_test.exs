defmodule Nebu.Matrix.MembershipStateModelDocsTest do
  @moduledoc """
  Static checks (no network) for story `membership-state-model` (epic oauth-broker, follow-ups `fb`, `fl` (c)), AC13, AC14 and AC15 (a):

    * (a) `docs/matrix-api-scope.md`: the `/members`, `/initialSync`, `/sync` and `/upgrade` rows, the corrected `joined_members` row (not routed: `404 M_UNRECOGNIZED`,
      follow-up `gh`), and the LABELS of AC14 word for word (they are the contract of the story's "labelled" decisions: the dev copies them);
    * (b) `docs/architecture/07-deployment.md`: the paragraph "Room membership state" with the operator query **Q-ms** (its SQL is executed here, against fixture rows in a
      rolled-back transaction);
    * (c) `CHANGELOG.md` `[Unreleased]`; (d) `docs/stories/oauth-broker/follow-ups.md`: `fb` CLOSED (the "Original item" text and every note stay: the pinned words of the older
      docs suites), the notes on `et`, `fl`, `fg`, `fi`, `fe`, `fp`, `fc`, `fh`, the new rows `ge` - `gi`, the id line (`ge`-`gi`: this story, unused from `gj`);
    * (e) the removed phrases are refuted; the old `ge` onward of the id line is refuted HERE (the ten older docs suites carried the re-pin `gj` onward; story history-visibility-enforcement moved it to `gm`).

  The pins are facts and unique new terms, not whole sentences, so the wording stays free; the LABELS are pinned word for word. The file reads are `async`-safe; the one
  database test (Q-ms) only works inside a transaction it rolls back.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)
  @scope Path.join(@root, "docs/matrix-api-scope.md")
  @deploy Path.join(@root, "docs/architecture/07-deployment.md")
  @followups Path.join(@root, "docs/stories/oauth-broker/follow-ups.md")
  @changelog Path.join(@root, "CHANGELOG.md")
  @runtime_doc Path.join(@root, "docs/architecture/06-runtime.md")
  @decisions Path.join(@root, "docs/architecture/09-decisions.md")
  @compose Path.join(@root, "docker-compose.yml")
  @story "membership-state-model"

  @members "| GET | `/_matrix/client/v3/rooms/{roomId}/members` | "
  @initial_sync "| GET | `/_matrix/client/v3/rooms/{roomId}/initialSync` | "
  @joined_members "| GET | `/_matrix/client/v3/rooms/{roomId}/joined_members` | "
  @sync "| GET | `/_matrix/client/v3/sync` | "
  @upgrade "| POST | `/_matrix/client/v3/rooms/{roomId}/upgrade` | "

  @title "**Room membership state (story membership-state-model, follow-ups `fb`, `fl`).**"

  # the labels of AC14, verbatim
  @labels [
    "membership and not_membership combine as AND: Synapse parity",
    "`at` is ignored: the current state is returned",
    "a user who left gets `403` on `/members` (spec: the members when you left): Nebu restriction",
    "member slots other than `join` are capped at 10 000 per room in the `/sync` state, `/members` and `/initialSync`: Nebu bound",
    "the incremental `/sync` state keeps the joined slice of the room process: member changes reach clients in the timeline, except in a `limited: true` delta",
    "the spec text says 'or'",
    "400 for values outside the enum: Nebu choice",
    "`visibility` is always `private`: known deviation (`gf`)",
    "the `state` of `/initialSync` is the full current state, `messages.chunk` may repeat state events",
    "`unsigned.replaces_state` / `prev_sender`: Synapse-compatible extension",
    "state = current member state minus the timeline slots",
    "invite blocking (`m.invite_permission_config`) is not applied, also not to upgrade invitations (`fh`)",
    "GET state is not implemented (`bf`)",
    "a member without a member event is served synthesized: legacy",
    "state is event-based; legacy half states are visible as such (Q-half)",
    "the upgrade invites the old joined members as real invite events in the upgrader's name: Nebu addition (the spec has no invite step)",
    "the upgrade's invitations are not charged to the pending caps"
  ]

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

  defp note_of(id) do
    row = followup_line(id)
    assert row =~ ~r/\*\*Note \(#{@story}, \d{4}-\d{2}-\d{2}\):\*\*/, "#{id}: a note labelled like the other notes of this file"
    [_, note] = String.split(row, "**Note (#{@story}, ", parts: 2)
    note
  end

  # From the bold title of the paragraph to the next markdown heading or bold paragraph title
  defp membership_section(normalise? \\ true) do
    raw = File.read!(@deploy)

    case :binary.match(raw, @title) do
      {at, _} ->
        rest = binary_part(raw, at, byte_size(raw) - at)
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

  # ═══ (a) the scope doc: the rows ════════════════════════════════════════════════════════════════

  test "scope doc (a): the /members row: the member EVENTS (latest per user, every membership), the filters, real ids, unsigned, the unknown room 403 without a row; the old sentence is gone" do
    row = scope_row(@members)

    assert String.starts_with?(row, @members <> "✅ |")
    assert row =~ @story
    assert row =~ ~r/member events/i and row =~ ~r/latest[^.]{0,40}per user/i and row =~ "`invite`" and row =~ "`ban`" and row =~ "`leave`"
    assert row =~ "`membership`" and row =~ "`not_membership`" and row =~ "`at`"
    assert row =~ "M_INVALID_PARAM" and row =~ "403 M_FORBIDDEN" and row =~ "You are not a member of this room"
    assert row =~ ~r/unknown room[^.]{0,80}`403`/i and row =~ ~r/no `rooms` row/i
    assert row =~ "`unsigned`" and row =~ "`age`" and row =~ "`replaces_state`" and row =~ "`prev_content`"
    assert row =~ "`room_id`" and row =~ ~r/real (event )?ids?/i
    assert row =~ "`fb`" and row =~ "`fl`" and row =~ "`gf`"
    assert row =~ "10 000"
    refute row =~ "no `unsigned` on them"
    refute row =~ "no predecessor statement"
  end

  test "scope doc (a): the /initialSync row: the event-based state with unsigned, no peeking (gf), the visibility label, the ignored limit, the full-state label" do
    row = scope_row(@initial_sync)

    assert String.starts_with?(row, @initial_sync <> "✅ |")
    assert row =~ @story and row =~ ~r/event-based/i and row =~ "`unsigned`" and row =~ ~r/real (event )?ids?/i
    assert row =~ "no peeking (`gf`)"
    assert row =~ "`visibility` is always `private`: known deviation (`gf`)"
    assert row =~ "the `state` of `/initialSync` is the full current state, `messages.chunk` may repeat state events"
    assert row =~ "`limit`" and row =~ ~r/ignored/i, "the ignored limit is recorded"
    assert row =~ "10 000"
    refute row =~ "The `state` block is unchanged"
    refute row =~ "no predecessor statement"
  end

  test "scope doc (a): the /sync row: the initial state lists every member slot from the member events, the incremental state keeps the joined slice, the cap" do
    row = scope_row(@sync)

    assert row =~ "the initial `/sync` state lists every member slot (join, invite, ban, knock, leave) from the member events"
    assert row =~ "the incremental `/sync` state keeps the joined slice of the room process"
    assert row =~ "member slots other than `join` are capped at 10 000 per room in the `/sync` state, `/members` and `/initialSync`: Nebu bound"
    assert row =~ @story and row =~ "`gg`"
    refute row =~ "`/members` and `/initialSync` state events carry no `unsigned`"
  end

  test "scope doc (a): the /upgrade row: real invite events in the upgrader's name (is_direct carried, the wake cluster-wide), not charged to the caps, the old 'row-only' wording is gone" do
    row = scope_row(@upgrade)

    assert row =~ "the upgrade invites the old joined members as real invite events in the upgrader's name"
    assert row =~ "the upgrade's invitations are not charged to the pending caps"
    assert row =~ "is_direct" and row =~ "`gi`" and row =~ @story
    assert row =~ "invite blocking (`m.invite_permission_config`) is not applied, also not to upgrade invitations (`fh`)"
    refute row =~ "row-only invitation"
  end

  test "scope doc (a): the joined_members row is 🔲 'not routed' (404 M_UNRECOGNIZED, gh); the 'Compact map of joined members' claim is gone" do
    row = scope_row(@joined_members)

    assert String.starts_with?(row, @joined_members <> "🔲 |")
    assert row =~ "not routed" and row =~ "`404 M_UNRECOGNIZED`" and row =~ "`gh`"
    refute row =~ "✅"
    refute read(@scope) =~ "Compact map of joined members"
  end

  # ═══ AC14: the labels ═══════════════════════════════════════════════════════════════════════════

  for label <- @labels do
    test "scope doc AC14: the label #{inspect(String.slice(label, 0, 60))} is pinned verbatim" do
      assert read(@scope) =~ unquote(label), "the scope doc carries the label word for word"
    end
  end

  test "scope doc AC14: the labels sit where the story puts them (the members row: AND / at / leaver / enum / Synapse extension / bf / legacy; the initialSync row: peeking, visibility)" do
    members = scope_row(@members)

    for label <- [
          "membership and not_membership combine as AND: Synapse parity",
          "the spec text says 'or'",
          "`at` is ignored: the current state is returned",
          "a user who left gets `403` on `/members` (spec: the members when you left): Nebu restriction",
          "400 for values outside the enum: Nebu choice",
          "`unsigned.replaces_state` / `prev_sender`: Synapse-compatible extension",
          "a member without a member event is served synthesized: legacy",
          "state is event-based; legacy half states are visible as such (Q-half)"
        ] do
      assert members =~ label, "the /members row carries #{inspect(label)}"
    end

    sync = scope_row(@sync)
    assert sync =~ "state = current member state minus the timeline slots"
    assert sync =~ "except in a `limited: true` delta"
  end

  # ═══ (b) 07-deployment ══════════════════════════════════════════════════════════════════════════

  test "07-deployment (b): the paragraph says what Element shows now (Invited, Banned users after a reload), who sees bans and reasons, the cap, the upgrade events, no migration" do
    sec = membership_section()

    for word <- ["\"Invited\"", "\"Banned users\"", "every joined member", "10 000", "`reason`", "no migration", "`fb`", "`fl`", "Room.DB.member_state_slice/2"] do
      assert sec =~ word, "the paragraph mentions #{word}"
    end

    assert sec =~ ~r/reload/i and sec =~ ~r/Clear cache/i
    assert sec =~ ~r/upgrade[^.]{0,80}real invite events/i
    assert sec =~ ~r/existing row-only invitations stay valid/i
    assert sec =~ ~r/never logged/i or sec =~ ~r/not logged/i
  end

  test "07-deployment (b): the operator query Q-ms is described (rooms above the cap, a rolled-back transaction with fixture rows) and shown as a SQL block" do
    sec = membership_section()

    assert sec =~ "**Q-ms**"
    assert sec =~ ~r/rolled-back transaction/i and sec =~ ~r/fixture rows/i
    assert sec =~ "```sql"
    assert sec =~ "SELECT room_id, count(*)"
    assert sec =~ "HAVING count(*) > 10000"
  end

  @tag :integration
  # story events-room-position: the bulk fixture below is slow under the position trigger (see the comment there); the per-test
  # bound is raised above the 90 s statement bound, so that the statement bound is the effective one
  @tag timeout: 180_000
  test "07-deployment (b): the Q-ms SQL lists a room with more than 10 000 non-join member slots and not a room with exactly 10 000 or with joined latest events (rolled-back transaction, fixture rows)" do
    sql =
      case Regex.run(~r/```sql\n(.*?)```/s, membership_section(false)) do
        [_, block] -> block
        nil -> flunk("the membership paragraph has no SQL block")
      end

    assert sql =~ ~r/\A\s*(SELECT|WITH)/i, "Q-ms is read-only"
    refute sql =~ ~r/\b(INSERT|UPDATE|DELETE|DROP|ALTER|TRUNCATE)\b/i

    suffix = Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    rooms = for kind <- ~w(over exact joined mixed), into: %{}, do: {kind, "!qms#{kind}#{suffix}:test.local"}
    now = System.system_time(:millisecond)

    # `n` users per room whose ONLY member event has the membership `m`, or (older: leave, newer: `m`) when `older?`
    # `membership` is one membership for every user, or a list that the users cycle through (the "mixed" room)
    insert = fn room, n, membership, older? ->
      Ecto.Adapters.SQL.query!(Nebu.Repo, "INSERT INTO rooms (room_id, visibility, created_at, power_levels_json) VALUES ($1, 'private', $2, '{}')", [room, now])

      users = for i <- 1..n, do: "@qms#{i}#{suffix}:test.local"
      kinds = users |> Enum.with_index() |> Enum.map(fn {_u, i} -> if is_list(membership), do: Enum.at(membership, rem(i, length(membership))), else: membership end)

      # Re-pinned deliberately (story events-room-position, Test list item 5): the position trigger of migration 000053 updates the
      # room's `rooms` row once per inserted event, and 10 000+ updates of ONE row inside ONE transaction walk its growing version
      # chain (about 1 s -> 11 s for this fixture alone), which crossed the default 15 s query timeout under full-suite load. Real
      # writers insert one or a few events per transaction; only this bulk fixture needs the longer bound (90 s per statement; the
      # test's own ExUnit timeout is raised to 180 s by its @tag, above the default 60 s).
      for {ts, ms, tag} <- (if older?, do: [{now - 10_000, List.duplicate("leave", n), "o"}, {now, kinds, "n"}], else: [{now, kinds, "n"}]) do
        Ecto.Adapters.SQL.query!(
          Nebu.Repo,
          """
          INSERT INTO events (event_id, room_id, sender, event_type, content, origin_server_ts, signatures, state_key)
          SELECT '$qms' || $5 || md5(u || $1), $1, u, 'm.room.member', jsonb_build_object('membership', m), $2::bigint, NULL, u
          FROM unnest($3::text[], $4::text[]) AS x(u, m)
          """,
          [room, ts, users, ms, tag <> suffix],
          timeout: :timer.seconds(90)
        )
      end
    end

    result =
      Nebu.Repo.transaction(fn ->
        insert.(rooms["over"], 10_001, "leave", false)
        insert.(rooms["exact"], 10_000, "ban", false)
        # 10 001 users whose OLDER event is a leave and whose LATEST event is a join: no non-join slot
        insert.(rooms["joined"], 10_001, "join", true)
        # invites, bans and leaves mixed (none is a join), 10 002 slots
        insert.(rooms["mixed"], 10_002, ["invite", "ban", "leave"], false)

        listed = Ecto.Adapters.SQL.query!(Nebu.Repo, sql, []).rows
        Nebu.Repo.rollback({:listed, listed})
      end)

    assert {:error, {:listed, listed}} = result
    listed_rooms = Enum.map(listed, &List.first/1)

    assert rooms["over"] in listed_rooms, "Q-ms lists the room with 10 001 non-join slots"
    assert rooms["mixed"] in listed_rooms, "and the room with 10 002 mixed non-join slots"
    refute rooms["exact"] in listed_rooms, "not a room with exactly 10 000 (HAVING count(*) > 10000)"
    refute rooms["joined"] in listed_rooms, "not a room whose LATEST events are joins (the older leaves do not count)"
    assert Enum.find(listed, &(List.first(&1) == rooms["over"])) |> Enum.at(1) == 10_001, "the count column"
    assert Ecto.Adapters.SQL.query!(Nebu.Repo, "SELECT count(*) FROM events WHERE room_id = $1", [rooms["over"]]).rows == [[0]], "the fixture rows were rolled back"
  end


  # ═══ security cycle 1: the members_read tier, the statement timeout, Q-ms2, 06-runtime, 09-decisions ═══════════════

  # AC18 (k): these words are in the scope-doc rows of /members and /initialSync, in 07-deployment (the membership paragraph) and in the CHANGELOG
  @ac18_words [
    "`members_read`",
    "60 per minute, burst 30",
    "`NEBU_RATE_LIMIT_MEMBERS_READ_PER_MIN`",
    "`NEBU_RATE_LIMIT_MEMBERS_READ_BURST`",
    "the initial `/sync` is not charged",
    "divergence from the spec (no rate limit listed)",
    "statement_timeout",
    "503 M_UNAVAILABLE",
    "O(member events",
    "Q-ms2"
  ]

  for {doc, label} <- [{:scope, "the scope doc /members + /initialSync rows"}, {:deploy, "07-deployment (the membership paragraph)"}, {:changelog, "the CHANGELOG [Unreleased] Changed entry"}] do
    test "AC18 (k): #{label} contain the security-cycle words word for word" do
      text =
        case unquote(doc) do
          :scope -> scope_row(@members) <> " " <> scope_row(@initial_sync)
          :deploy -> membership_section()
          :changelog -> unreleased_section("Changed") |> String.replace(~r/\s+/, " ")
        end

      for word <- @ac18_words, do: assert(text =~ word, "#{unquote(label)}: #{inspect(word)}")
    end
  end

  # security cycle 2 (AC19 (h), D18 - D20)
  test "AC19 (h): 07-deployment names the statement count, the node-wide limit (3 concurrent per node, node-local), the degradation, the Q-ms2 caveats and the dead new room of an upgrade" do
    sec = membership_section()

    # security cycle 3 (L-4, DELIBERATE re-pin, old -> new): "joined-only until the read succeeds" -> "joined-only until the client's next initial or `full_state` sync"
    for word <- ["3 concurrent per node", "node-local", "joined-only until the client's next initial or `full_state` sync", "off-peak", "read-only role", "uninvited"], do: assert(sec =~ word, "07-deployment: #{inspect(word)}")
    assert sec =~ ~r/two more statements per joined room/i and sec =~ "`SET LOCAL`" and sec =~ "`BEGIN` / `COMMIT`"
    refute sec =~ "fails as a whole", "the initial /sync degrades one room instead (D18)"
    refute sec =~ ~r/one more statement per joined room/i

    [_, after_title] = String.split(sec, "**Q-ms2**", parts: 2)
    [caveats | _] = String.split(after_title, "```sql", parts: 2)
    assert caveats =~ "off-peak" and caveats =~ "read-only role", "the Q-ms2 caveats stand next to the query"
  end

  test "AC19 (h): 08-concepts and the RateLimitTiers moduledoc say 'room membership tiers' and '60 per minute, burst 30'; the scope doc carries the degradation label and the archived-room answers" do
    concepts = read(Path.join(@root, "docs/architecture/08-concepts.md"))
    assert concepts =~ "room membership tiers" and concepts =~ "60 per minute, burst 30" and concepts =~ "`members_read`"
    refute concepts =~ "Rate limiting (per user) - room membership writes"

    moduledoc = read(Path.join(@root, "server/lib/nebu/web/rate_limit_tiers.ex"))
    assert moduledoc =~ "membership tiers (writes: invite, join, moderation; read: members_read" and moduledoc =~ "60 per minute, burst 30"

    assert scope_row(@sync) =~ "joined-only until the client's next initial or `full_state` sync"
    assert scope_row(@members) =~ "old members of an archived room: 404; never-members: 403, no existence signal"
  end

  test "AC19 (h): the member_state_slice/2 @doc no longer says ONE statement (one slice statement inside a timed transaction)" do
    db = File.read!(Path.join(@root, "server/lib/nebu/matrix/room/db.ex"))
    assert [_, from_doc] = String.split(db, ~r/@doc """\n\s*The member slice of `room_id`/, parts: 2), "the @doc of member_state_slice/2"
    [doc | _] = String.split(from_doc, "def member_state_slice", parts: 2)

    refute doc =~ "ONE statement"
    assert doc =~ "statement_timeout"
  end

  test "07-deployment (b): the tier is per node, charged before the room is resolved, the 2 s timeout is never a degraded answer, a never-member does not start a stopped room (L-1)" do
    sec = membership_section()

    assert sec =~ ~r/per node/i and sec =~ ~r/before the room is resolved|charged first/i
    assert sec =~ ~r/never a degraded answer/i
    assert sec =~ ~r/stopped room[^.]*(only for a joined member|never-member[^.]*(no|without) (a )?start)/i
    assert sec =~ "NEBU_RATE_LIMIT_DISABLED" and sec =~ "`gg`"
  end

  test "docker-compose (security cycle 1): the two members_read variables are passed through in the empty default form and the comment names the tier and the five tiers" do
    compose = File.read!(@compose)

    for name <- ["NEBU_RATE_LIMIT_MEMBERS_READ_PER_MIN", "NEBU_RATE_LIMIT_MEMBERS_READ_BURST"] do
      assert compose =~ ~s(#{name}: "${#{name}:-}"), "#{name} is passed through with the empty default"
    end

    [_, from_comment] = String.split(compose, "# Per-user limits of the room membership writes", parts: 2)
    [block | _] = String.split(from_comment, "NEBU_RATE_LIMIT_CREATE_ROOM_PER_MIN", parts: 2)
    assert block =~ "members_read" and block =~ "the five tiers"
    refute block =~ "the four tiers"
  end

  test "06-runtime and 09-decisions (MINOR-2): the passages that said /members and /initialSync carry no unsigned / synthetic ids are rewritten and name this story" do
    runtime = read(@runtime_doc)
    decisions = read(@decisions)

    refute runtime =~ "`/members` and `/initialSync` state blocks run no predecessor statement and carry no `unsigned`"
    assert runtime =~ ~r/only for the incremental `\/sync` and the/, "the GenServer-state passage names the paths that still use the joined slice"
    assert runtime =~ @story and runtime =~ "member EVENTS from the database" and runtime =~ ~r/ONE batched predecessor statement each/
    refute runtime =~ "**GenServer state-backed** (`m.room.member`, `m.room.power_levels`)", "the member slots are no longer purely process-state backed"

    refute decisions =~ "still generate synthetic event IDs"
    refute decisions =~ "see `initial_sync_state_event/3`"
    assert decisions =~ @story and decisions =~ "real event ids" and decisions =~ "synthesized id"
  end

  @tag :integration
  test "07-deployment (b): the Q-ms2 SQL lists the rooms by their TOTAL member-event count (history included, not users), highest first, at most 20 (rolled-back transaction, fixture rows)" do
    blocks = Regex.scan(~r/```sql\n(.*?)```/s, membership_section(false), capture: :all_but_first) |> Enum.map(&List.first/1)
    assert length(blocks) >= 2, "Q-ms and Q-ms2 are two SQL blocks"
    sql = Enum.at(blocks, 1)
    assert sql =~ ~r/\A\s*(SELECT|WITH)/i, "Q-ms2 is read-only"
    refute sql =~ ~r/\b(INSERT|UPDATE|DELETE|DROP|ALTER|TRUNCATE)\b/i
    assert sql =~ ~r/GROUP BY room_id/i and sql =~ ~r/ORDER BY[^;]*DESC/i and sql =~ ~r/LIMIT 20/i

    suffix = Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    top = "!qms2top#{suffix}:test.local"
    second = "!qms2second#{suffix}:test.local"
    now = System.system_time(:millisecond)

    # `n` member events of the room, TWO per user (history: an older and a newer event): the count is events, not users
    insert = fn room, n ->
      Ecto.Adapters.SQL.query!(Nebu.Repo, "INSERT INTO rooms (room_id, visibility, created_at, power_levels_json) VALUES ($1, 'private', $2, '{}')", [room, now])

      Ecto.Adapters.SQL.query!(
        Nebu.Repo,
        """
        INSERT INTO events (event_id, room_id, sender, event_type, content, origin_server_ts, signatures, state_key)
        SELECT '$qms2' || md5($1 || $3 || g::text), $1, 'a', 'm.room.member', jsonb_build_object('membership', CASE WHEN g % 2 = 0 THEN 'join' ELSE 'leave' END), $2::bigint, NULL, 'u' || (g / 2)
        FROM generate_series(1, $4::int) AS g
        """,
        [room, now, suffix, n]
      )
    end

    result =
      Nebu.Repo.transaction(fn ->
        # the fixtures are bigger than anything else in the database (the query lists the top 20 of the whole table)
        [[current_top]] = Ecto.Adapters.SQL.query!(Nebu.Repo, "SELECT coalesce(max(c), 0) FROM (SELECT count(*) AS c FROM events WHERE event_type = 'm.room.member' GROUP BY room_id) t", []).rows
        n = current_top + 10
        if n > 400_000, do: Nebu.Repo.rollback({:too_big, n})
        insert.(top, n)
        insert.(second, n - 5)
        listed = Ecto.Adapters.SQL.query!(Nebu.Repo, sql, []).rows
        Nebu.Repo.rollback({:listed, n, listed})
      end)

    assert {:error, {:listed, n, listed}} = result
    assert length(listed) <= 20
    assert [[^top, ^n], [^second, second_count] | _] = Enum.map(listed, &Enum.take(&1, 2)), "the two fixture rooms come first, the larger first"
    assert second_count == n - 5
  end

  # ═══ (c) CHANGELOG ══════════════════════════════════════════════════════════════════════════════

  test "CHANGELOG (c): [Unreleased] ### Changed names the initial /sync state, /members (filters, real ids, unsigned, unknown room 403), /initialSync and the upgrade invite events" do
    changed = unreleased_section("Changed")
    entry = changed |> String.split(~r/\n- /) |> Enum.find(&(&1 =~ @story))

    assert entry, "a Changed entry naming the story"
    flat = String.replace(entry, ~r/\s+/, " ")

    for term <- ["initial `/sync`", "/members", "`membership`", "`not_membership`", "`unsigned`", "`/initialSync`", "`403`", "invite events", "`fb`"] do
      assert flat =~ term, "the entry mentions #{term}"
    end
  end

  test "CHANGELOG (c): [Unreleased] ### Fixed names the corrected joined_members claim of the scope doc" do
    fixed = unreleased_section("Fixed") |> String.replace(~r/\s+/, " ")

    assert fixed =~ "joined_members" and fixed =~ "scope doc" and fixed =~ @story
  end

  # ═══ (d) follow-ups ═════════════════════════════════════════════════════════════════════════════

  test "follow-ups (d): fb is CLOSED by this story (CLOSED style, status closed), keeps the Original item text and the notes, and the words the older docs suites pin" do
    f = read(@followups)
    assert f =~ ~r/\| fb \| \*\*CLOSED by story #{@story} \(\d{4}-\d{2}-\d{2}\)/, "the CLOSED prefix like ea / ep / ex / eq"

    line = followup_line("fb")
    assert line =~ ~r/\| closed \|\s*\z/, "the status column says closed"
    refute line =~ ~r/\| open[^|]*\|\s*\z/
    assert line =~ ~r/Original item/i, "the original text stays"
    assert line =~ "create-room-invites-direct", "the origin cell still names the story that raised it"

    # the words pinned by create_room_invites_docs_test, member_prev_content_docs_test, membership_write_limits_docs_test, moderation_routes_docs_test, sync_membership_partition_docs_test
    for word <- ["build_state_events", "kick_user", "revoke", "strictly greater", "trusted_private_chat", "upgrade", "predecessor", "not marked", "`fi`", "membership-state-model", "synthesized"] do
      assert line =~ word, "fb keeps #{inspect(word)}"
    end

    assert line =~ ~r/invite events/i and line =~ "`/members`" and line =~ "`/initialSync`", "what was done"
  end

  for {id, patterns} <- [
        {"et", ["`ge`", "split"]},
        {"fl", ["(c)", "`unsigned.age`", "`/members`", "`/initialSync`"]},
        {"fg", ["(a)", "(f)", "`ge`", "`lazy_load_members`"]},
        {"fi", ["event-backed", "`gi` (c)"]},
        {"fe", ["`:pg.get_members/1`", "upgrade"]},
        {"fp", ["10 000", "non-joined"]},
        {"fc", ["initial `/sync`", "`state`"]},
        {"fh", ["upgrade invitations", "`gi` (d)"]}
      ] do
    test "follow-ups (d): the existing row #{id} carries a '**Note (membership-state-model, <date>):**' with the facts of this story" do
      note = note_of(unquote(id))
      for pattern <- unquote(patterns), do: assert(note =~ pattern, "#{unquote(id)}: the note mentions #{pattern}")
    end
  end

  test "follow-ups (d): the rows et and fl keep the words the older docs suites pin" do
    et = followup_line("et")
    for word <- ["visibility", "unban", "m.room.join_rules", "membership-state-model", "owner decision"], do: assert(et =~ word, "et keeps #{word}")

    fl = followup_line("fl")

    for word <- ["unsigned.membership", "/members", "/initialSync", "redact", "`age` on `/messages`", "(e)", "65536", "130", "`unsigned.redacted_because`"] do
      assert fl =~ word, "fl keeps #{word}"
    end
  end

  test "follow-ups (d): the new rows ge, gf, gg, gh, gi exist, are open and non-gating (ge: owner decision), attributed to this story and name their facts" do
    for {id, words} <- [
          {"ge", ["`Room.Server.write_state/5`", "`m.room.join_rules`", "`write_invite/5`", "`Room.Server.moderate/6`", "`Room.DB.member_state_slice/2`", "owner decision", "Admin"]},
          {"gf", ["left", "`403`", "`at`", "peeking", "visibility", "private"]},
          {"gg", ["`lazy_load_members`", "incremental", "`/members`", "paging", "displayname"]},
          {"gh", ["joined_members", "`404 M_UNRECOGNIZED`", "not routed"]},
          {"gi", ["pending invitees", "`is_direct`", "uncapped", "`fh`"]}
        ] do
      [_, text, origin, status] = followup_cells(id)
      assert origin =~ @story, "#{id} is attributed to this story"
      assert String.downcase(status) =~ "open" and String.downcase(status) =~ "non-gating", "#{id} is open and non-gating"
      for word <- words, do: assert(String.downcase(text) =~ String.downcase(word), "#{id} mentions #{word}")
    end

    assert String.downcase(Enum.at(followup_cells("ge"), 3)) =~ "owner decision"
  end

  test "follow-ups (d): the id line lists ge - gi for this story and continues at gj (the old 'ge onward' is refuted, the earlier attributions stay)" do
    f = read(@followups)

    assert f =~ "`ge`-`gi`: #{@story}"
    # story history-visibility-enforcement (DELIBERATE re-pin, AC21 (a); old -> new): `gj`-`gl` are used by that story, the unused ids continue at `gm` ("`gj` onward" before; the old note is refuted by history_visibility_docs_test.exs)
    assert f =~ ~r/unused:[^.]*`gm` onward/, "unused ids continue at gm"
    refute f =~ ~r/unused:[^.]*`ge` onward/, "the old `ge` onward note is gone"
    assert f =~ "`ga`-`gd`: state-writer-redaction", "the earlier attribution stays"
    assert f =~ "`fv`-`fz`: power-levels-enforcement"
  end

  # ═══ (e) the removed phrases ════════════════════════════════════════════════════════════════════

  test "(e): the phrases of the old state are gone from the docs (Compact map of joined members, no unsigned on /members, the open fb row)" do
    scope = read(@scope)
    followups = read(@followups)

    refute scope =~ "Compact map of joined members"
    refute scope =~ "no `unsigned` on them (no `replaces_state`"
    refute scope =~ "`upgrade_room` still writes no invite event"
    refute followups =~ ~r/\| fb \| \*\*Membership state model\.\*\*/, "fb no longer starts with its open title"
    refute followups =~ ~r/\| fb \| \*\*[^|]*\|[^|]*\| open/, "fb is not an open row"
  end
end
