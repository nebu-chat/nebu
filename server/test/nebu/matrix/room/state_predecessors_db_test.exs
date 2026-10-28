defmodule Nebu.Matrix.Room.StatePredecessorsDbTest do
  @moduledoc """
  Real-database tests for story `member-event-prev-content` (epic oauth-broker, follow-up `ff`), AC1 and AC8: the ONE statement that
  answers "which event did THIS state event replace at its `(room_id, event_type, state_key)` slot, and what was its content / who sent it".
  NO fakes: a fake that returns ready predecessors proves nothing about the SQL (a fake hid a real defect in two earlier stories), so the
  D3 tie order, both JSONB forms, the unknown-membership rank, the one-statement property, the failure path and the index usage are pinned
  here against `Nebu.Repo`. Rows are written through the real writer (`Room.DB.insert_event/1`, content as a JSONB object) and, where a test
  needs the double-encoded JSONB string form or a precisely tied timestamp, through the privileged role (`T.privileged_sql!/2`: used only to
  control the shape of the row).

  ## The function under test (names pinned by the ATDD step; the story fixes D3 / D10)

  `Nebu.Matrix.Room.DB.fetch_state_predecessors/1` (the RENAMED, widened `fetch_replaces_state/1`; the old name is removed):

      fetch_state_predecessors([{event_id, room_id, event_type, state_key, origin_server_ts}])
        :: %{event_id => %{event_id: predecessor_id, content: map, sender: sender}}

  A slot without a predecessor is ABSENT from the map (never nil, never an empty entry); `[]` answers `%{}` without a statement; a DB error
  answers `%{}` and logs ONE warning with the slot count and no content. The statement carries the marker comment `/* state_predecessors */`
  (the HTTP suite counts statements with it).

  ## The order (D3, a NEBU rule: the spec orders state by the room DAG, which Nebu does not have)

  The predecessor of `X` is the row `P` of X's slot with the largest key `(origin_server_ts, r, event_id)` strictly smaller than X's key,
  where `r = 4 - rank(membership)` for `m.room.member` (rank ban 0 < leave 1 < invite 2 < knock 3 < join 4, unknown = 1: so in one millisecond
  the `ban` is the LATEST and the `join` the earliest, exactly the sync partition's `ORDER BY origin_server_ts DESC, rank ASC, event_id DESC`)
  and `r = 0` for every other type (today's `(origin_server_ts, event_id)` order).

  Every id is random, `@moduletag :integration`, `async: false` (statement counting uses the telemetry event of the repo, filtered to the
  calling process).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Nebu.Matrix.Room.DB
  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration

  @server "test.local"
  @db_source Path.expand("../../../../lib/nebu/matrix/room/db.ex", __DIR__)
  @lib Path.expand("../../../../lib", __DIR__)

  # ─── helpers ─────────────────────────────────────────────────────────────────

  # the function under test is called through apply/3: a module that does not export it yet must fail the TEST, never abort the compile
  defp predecessors(slots), do: apply(DB, :fetch_state_predecessors, [slots])

  defp room! do
    room = "!sp#{T.rand(6)}:#{@server}"
    assert {:ok, _} = DB.insert_room(room)
    room
  end

  defp user_id, do: "@sp#{T.rand(6)}:#{@server}"

  # far away from "now" so that nothing written through the real writers (they stamp the clock) interleaves with the scripted timestamps
  defp base_ts, do: 1_600_000_000_000 + :rand.uniform(1_000_000) * 10

  # two random event ids whose lexical order is known: {smaller, larger}
  defp id_pair, do: {"$a#{T.rand(8)}", "$z#{T.rand(8)}"}

  defp event_id(prefix \\ "e"), do: "$#{prefix}#{T.rand(8)}"

  # a state event through the real writer (content as a JSONB OBJECT). Returns the facts a slot tuple needs.
  defp put!(room, type, state_key, content, ts, opts \\ []) do
    id = Keyword.get(opts, :id, event_id())
    sender = Keyword.get(opts, :sender, "@creator:#{@server}")

    assert :ok =
             DB.insert_event(%{
               "event_id" => id,
               "room_id" => room,
               "sender" => sender,
               "type" => type,
               "state_key" => state_key,
               "content" => content,
               "origin_server_ts" => ts
             })

    %{id: id, room: room, type: type, state_key: state_key, ts: ts, sender: sender, content: content}
  end

  defp member!(room, user, membership, ts, opts \\ []) do
    content = Keyword.get(opts, :content, %{"membership" => membership})
    put!(room, "m.room.member", user, content, ts, Keyword.merge([sender: user], Keyword.delete(opts, :content)))
  end

  # the same row with the content stored as a double-encoded JSONB STRING (what an older writer produced): `to_jsonb(<json text>)`
  defp string_form!(room, type, state_key, content_text, ts, opts) do
    id = Keyword.get(opts, :id, event_id("s"))
    sender = Keyword.get(opts, :sender, state_key)

    T.privileged_sql!(
      "INSERT INTO events (event_id, room_id, sender, event_type, content, origin_server_ts, state_key) VALUES ($1, $2, $3, $4, to_jsonb($5::text), $6, $7)",
      [id, room, sender, type, content_text, ts, state_key]
    )

    %{id: id, room: room, type: type, state_key: state_key, ts: ts, sender: sender, content: content_text}
  end

  defp slot(%{id: id, room: room, type: type, state_key: sk, ts: ts}), do: {id, room, type, sk, ts}

  # the predecessor entry of ONE event (nil: absent), asked on its own
  defp pred(ev) do
    result = predecessors([slot(ev)])
    assert is_map(result), "fetch_state_predecessors/1 answers a map keyed by the requested event id, got #{inspect(result)}"
    Map.get(result, ev.id)
  end

  defp pred_id(ev) do
    case pred(ev) do
      nil -> nil
      %{event_id: id} -> id
    end
  end

  # ─── statement counting / plan capture (telemetry of the repo, only the calling process) ───

  def handle_query(_event, _measurements, %{query: query, params: params}, %{pid: pid}) do
    if self() == pid, do: send(pid, {:statement, query, params})
    :ok
  end

  def handle_query(_event, _measurements, _metadata, _config), do: :ok

  defp capture_statements(fun) do
    id = "sp-db-#{T.rand(6)}"
    :ok = :telemetry.attach(id, [:nebu, :repo, :query], &__MODULE__.handle_query/4, %{pid: self()})

    try do
      result = fun.()
      {result, drain_statements([])}
    after
      :telemetry.detach(id)
    end
  end

  defp drain_statements(acc) do
    receive do
      {:statement, query, params} -> drain_statements([{query, params} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # who is the LAST member event of `user` in `room` for the two readers of "the latest membership" (the sync partition and the join decision)
  defp assert_both_readers_say_last(room, user, last) do
    assert {:ok, membership} = DB.get_member_membership(room, user)
    assert membership == last.membership, "get_member_membership/2 reads #{inspect(membership)}, the lookup calls #{last.membership} the LAST member event"

    assert {:ok, by_room} = DB.latest_member_events([room], user)
    assert [newest | _] = Map.fetch!(by_room, room)
    assert newest.event_id == last.id, "latest_member_events/2 reads another member event than the one the lookup calls LAST"
  end

  # 300 slots in 3 rooms: per room 50 state slots written twice (the second write has a predecessor, the first has none), ONE slot per event
  defp seed_300_slots! do
    base = base_ts()

    slots =
      for room <- [room!(), room!(), room!()], n <- 1..50, reduce: [] do
        acc ->
          type = "m.nebu.sp.slot#{n}"
          first = put!(room, type, "", %{"n" => n, "w" => 1, "m" => T.rand(3)}, base + n * 2)
          second = put!(room, type, "", %{"n" => n, "w" => 2, "m" => T.rand(3)}, base + n * 2 + 1)
          [{second.id, room, type, "", second.ts}, {first.id, room, type, "", first.ts} | acc]
      end

    assert length(slots) == 300
    Enum.reverse(slots)
  end

  # ═══ AC1 (a): the predecessor entry carries event id, content and sender ═══════

  describe "AC1 (a) - the entry" do
    test "invite (is_direct, sender @a) then join (sender @b): the join's entry is the invite's id, content and sender; the invite has no entry" do
      room = room!()
      a = user_id()
      b = user_id()
      t = base_ts()
      invite = member!(room, b, "invite", t, sender: a, content: %{"membership" => "invite", "is_direct" => true})
      join = member!(room, b, "join", t + 1)

      result = predecessors([slot(invite), slot(join)])

      assert result == %{join.id => %{event_id: invite.id, content: %{"membership" => "invite", "is_direct" => true}, sender: a}}
    end

    test "a predecessor whose content is {} IS an entry with content %{} (absence means 'no predecessor', nothing else)" do
      room = room!()
      first = put!(room, "m.room.topic", "", %{}, base_ts())
      second = put!(room, "m.room.topic", "", %{"topic" => "x"}, first.ts + 1)

      assert pred(second) == %{event_id: first.id, content: %{}, sender: first.sender}
      assert pred(first) == nil
    end

    test "slots are isolated by room, type and state_key: an earlier row of ANOTHER room / type / state_key is never the predecessor" do
      room = room!()
      other_room = room!()
      t = base_ts()
      put!(other_room, "m.room.topic", "", %{"topic" => "other room"}, t)
      put!(room, "m.room.name", "", %{"name" => "other type"}, t + 1)
      put!(room, "m.room.topic", "other-key", %{"topic" => "other key"}, t + 2)
      lone = put!(room, "m.room.topic", "", %{"topic" => "lone"}, t + 3)

      assert pred(lone) == nil
      assert predecessors([slot(lone)]) == %{}
    end
  end

  # ═══ AC1 (b): the D3 tie order for member slots ═════════════════════════════════

  describe "AC1 (b) - the D3 tie order (a Nebu rule)" do
    for {label, ban_first_by_id} <- [{"ban id smaller", true}, {"ban id larger", false}] do
      test "join and ban of one user in the SAME millisecond (#{label}): the ban's predecessor is the join, the join's is the event before both; both readers say ban is last" do
        room = room!()
        user = user_id()
        t = base_ts()
        {small, large} = id_pair()
        {ban_id, join_id} = if unquote(ban_first_by_id), do: {small, large}, else: {large, small}
        invite = member!(room, user, "invite", t - 10, sender: "@inviter:#{@server}")
        join = member!(room, user, "join", t, id: join_id)
        ban = member!(room, user, "ban", t, id: ban_id, sender: "@moderator:#{@server}")

        assert pred(ban) == %{event_id: join.id, content: %{"membership" => "join"}, sender: user}, "the ban is the successor of the join, whatever the event ids"
        assert pred_id(join) == invite.id, "the join's predecessor is the event BEFORE both"
        assert_both_readers_say_last(room, user, %{membership: "ban", id: ban.id})
      end
    end

    test "join and ban of one user in the same millisecond with NO earlier event: the join has no predecessor" do
      room = room!()
      user = user_id()
      t = base_ts()
      join = member!(room, user, "join", t)
      ban = member!(room, user, "ban", t, sender: "@moderator:#{@server}")

      assert pred_id(ban) == join.id
      assert pred(join) == nil
    end

    for {label, invite_first_by_id} <- [{"invite id smaller", true}, {"invite id larger", false}] do
      test "invite + join of one user in the SAME millisecond (#{label}): the invite is the SUCCESSOR of the join (the accepted D3 caveat join -> invite), both readers say invite is last" do
        room = room!()
        user = user_id()
        t = base_ts()
        {small, large} = id_pair()
        {invite_id, join_id} = if unquote(invite_first_by_id), do: {small, large}, else: {large, small}
        leave = member!(room, user, "leave", t - 10)
        join = member!(room, user, "join", t, id: join_id)
        invite = member!(room, user, "invite", t, id: invite_id, sender: "@inviter:#{@server}", content: %{"membership" => "invite", "is_direct" => true})

        # DOCUMENTED CAVEAT (D3 / follow-ups eu + fc): the spec's m.room.member table says join -> invite "must never happen"; Nebu's tie order
        # (most restrictive is latest) makes exactly that transition for a same-millisecond pair. D4 stops NEW ties of the join writer; legacy rows
        # and the writers that stay with `eu` can still produce it. Accepted: the partition and the lookup agree. This assertion PINS the caveat.
        assert pred(invite) == %{event_id: join.id, content: %{"membership" => "join"}, sender: user}
        assert pred_id(join) == leave.id
        assert_both_readers_say_last(room, user, %{membership: "invite", id: invite.id})
      end
    end

    test "all five memberships in ONE millisecond: the chain is join, knock, invite, leave, ban (the most restrictive is the latest), whatever the ids" do
      room = room!()
      user = user_id()
      t = base_ts()

      events =
        for m <- Enum.shuffle(["ban", "leave", "invite", "knock", "join"]), into: %{} do
          {m, member!(room, user, m, t)}
        end

      assert pred(events["join"]) == nil
      assert pred_id(events["knock"]) == events["join"].id
      assert pred_id(events["invite"]) == events["knock"].id
      assert pred_id(events["leave"]) == events["invite"].id
      assert pred_id(events["ban"]) == events["leave"].id
      assert_both_readers_say_last(room, user, %{membership: "ban", id: events["ban"].id})
    end

    test "two member events of the SAME rank in one millisecond are ordered by event_id (the larger id is the later), like the partition" do
      room = room!()
      user = user_id()
      t = base_ts()
      {small, large} = id_pair()
      first = member!(room, user, "leave", t, id: small)
      second = member!(room, user, "leave", t, id: large)

      assert pred(first) == nil
      assert pred_id(second) == first.id
      assert_both_readers_say_last(room, user, %{membership: "leave", id: second.id})
    end

    test "the timestamp decides before the rank: a LATER join is the successor of an earlier ban of another millisecond" do
      room = room!()
      user = user_id()
      t = base_ts()
      ban = member!(room, user, "ban", t, sender: "@moderator:#{@server}")
      join = member!(room, user, "join", t + 1)

      assert pred_id(join) == ban.id
      assert pred(ban) == nil
    end
  end

  # ═══ AC1 (c): non-member slots keep the (ts, event_id) order ════════════════════

  describe "AC1 (c) - a non-member slot tie" do
    test "two m.room.topic rows with the same timestamp: the larger event id is the later one; a third row is preceded by the larger" do
      room = room!()
      t = base_ts()
      {small, large} = id_pair()
      first = put!(room, "m.room.topic", "", %{"topic" => "one"}, t, id: small)
      second = put!(room, "m.room.topic", "", %{"topic" => "two"}, t, id: large)
      third = put!(room, "m.room.topic", "", %{"topic" => "three"}, t + 1)

      assert pred(first) == nil
      assert pred(second) == %{event_id: first.id, content: %{"topic" => "one"}, sender: first.sender}
      assert pred_id(third) == second.id
    end
  end

  # ═══ AC1 (d): both JSONB forms, unparseable content ═════════════════════════════

  describe "AC1 (d) - the content of the predecessor in both JSONB forms" do
    test "an object-form and a double-encoded string-form predecessor decode to the same map" do
      room = room!()
      t = base_ts()
      content = %{"topic" => "form-#{T.rand(4)}", "nested" => %{"k" => [1, 2, 3]}}
      object_form = put!(room, "m.room.topic", "", content, t)
      string_form = string_form!(room, "m.room.topic", "", Jason.encode!(content), t + 1, sender: "@creator:#{@server}")
      newest = put!(room, "m.room.topic", "", %{"topic" => "newest"}, t + 2)

      assert pred(string_form) == %{event_id: object_form.id, content: content, sender: object_form.sender}
      assert pred(newest) == %{event_id: string_form.id, content: content, sender: string_form.sender}
    end

    test "an UNPARSEABLE string content decodes to %{} and, as a member event, ranks as leave (between invite and ban, not as join / invite)" do
      room = room!()
      user = user_id()
      t = base_ts()
      {small, large} = id_pair()
      join = member!(room, user, "join", t)
      # the unparseable row has the SMALLER id: were it ranked as `invite` it would sort before the real invite of the same millisecond
      broken = string_form!(room, "m.room.member", user, "this is not json {", t, id: small)
      invite = member!(room, user, "invite", t, id: large)
      ban = member!(room, user, "ban", t, sender: "@moderator:#{@server}")

      assert pred_id(broken) == invite.id, "rank leave (3): after the invite (2) of the same millisecond, whatever the ids"
      assert pred_id(invite) == join.id
      assert pred(ban) == %{event_id: broken.id, content: %{}, sender: broken.sender}, "the unparseable content is %{}, the row is the ban's predecessor"
      assert_both_readers_say_last(room, user, %{membership: "ban", id: ban.id})
    end

    test "a non-string / unknown membership value ranks as leave as well (an object content, membership 5)" do
      room = room!()
      user = user_id()
      t = base_ts()
      {small, large} = id_pair()
      join = member!(room, user, "join", t)
      weird = member!(room, user, "ignored", t, id: small, content: %{"membership" => 5})
      invite = member!(room, user, "invite", t, id: large)

      assert pred_id(invite) == join.id
      assert pred(weird) == %{event_id: invite.id, content: %{"membership" => "invite"}, sender: user}
    end

    test "VALID double-encoded string-form member rows rank by their membership (join < invite < ban), not as leave: the chain is string join, object invite, string ban" do
      room = room!()
      user = user_id()
      t = base_ts()
      {small, large} = id_pair()
      # ids chosen so that treating every string as `leave` (rank 1) flips the answers
      string_join = string_form!(room, "m.room.member", user, ~s({"membership":"join"}), t, id: large)
      string_ban = string_form!(room, "m.room.member", user, ~s({"membership":"ban"}), t, id: small, sender: "@moderator:#{@server}")
      object_invite = member!(room, user, "invite", t)

      assert pred(string_join) == nil
      assert pred_id(object_invite) == string_join.id
      assert pred(string_ban) == %{event_id: object_invite.id, content: %{"membership" => "invite"}, sender: user}
      assert_both_readers_say_last(room, user, %{membership: "ban", id: string_ban.id})
    end
  end

  # ═══ AC1 (e): an event id without a row ═════════════════════════════════════════

  describe "AC1 (e) - a slot whose event_id has no row in events" do
    test "is ordered as an UNKNOWN membership (rank 1 = leave) and returns the row before it" do
      room = room!()
      user = user_id()
      t = base_ts()
      {small, _large} = id_pair()
      member!(room, user, "invite", t - 5)
      member!(room, user, "join", t)
      invite = member!(room, user, "invite", t)
      leave = member!(room, user, "leave", t, id: small)
      member!(room, user, "ban", t, sender: "@moderator:#{@server}")
      missing = "$zz-missing-#{T.rand(6)}"

      assert %{event_id: leave_id} = pred(%{id: missing, room: room, type: "m.room.member", state_key: user, ts: t})
      assert leave_id == leave.id, "rank leave (3), key (t, 3, $zz...): the same-millisecond leave with the smaller id is the largest key below it; the invite (2) is below the leave, the ban (4) is above"
      refute leave_id == invite.id
    end

    test "a non-member slot without a row is ordered like every other: the latest earlier row of the slot" do
      room = room!()
      t = base_ts()
      earlier = put!(room, "m.room.topic", "", %{"topic" => "earlier"}, t)

      assert pred_id(%{id: "$zz-nonmember-#{T.rand(6)}", room: room, type: "m.room.topic", state_key: "", ts: t + 1}) == earlier.id
    end
  end

  # ═══ AC1 (f): ONE statement ═════════════════════════════════════════════════════

  describe "AC1 (f) - one statement for any number of slots" do
    test "300 slots in 3 rooms run exactly ONE statement; the result equals 300 single-slot calls; the first write of a slot is absent" do
      slots = seed_300_slots!()

      {batched, statements} = capture_statements(fn -> predecessors(slots) end)
      assert length(statements) == 1, "ONE statement for 300 slots in 3 rooms, got #{length(statements)}"

      singles = Enum.reduce(slots, %{}, fn slot, acc -> Map.merge(acc, predecessors([slot])) end)

      assert batched == singles, "the batch answers exactly what 300 single calls answer"
      assert map_size(batched) == 150, "the 150 second writes have a predecessor, the 150 first writes have none"

      for {event_id, entry} <- batched do
        assert Enum.sort(Map.keys(entry)) == [:content, :event_id, :sender], "exactly the three keys for #{event_id}"
        assert entry.content["w"] == 1
      end
    end

    test "an empty slot list answers %{} without any statement" do
      {result, statements} = capture_statements(fn -> predecessors([]) end)

      assert result == %{}
      assert statements == []
    end

    test "the old function name is gone (renamed, no alias, no second query)" do
      assert Code.ensure_loaded?(DB)
      assert function_exported?(DB, :fetch_state_predecessors, 1)
      refute function_exported?(DB, :fetch_replaces_state, 1)
    end

    test "the statement carries the marker comment /* state_predecessors */ (the statement counts of the HTTP suite match it)" do
      room = room!()
      first = put!(room, "m.room.topic", "", %{"topic" => "a"}, base_ts())
      second = put!(room, "m.room.topic", "", %{"topic" => "b"}, first.ts + 1)

      {_result, [{sql, _params}]} = capture_statements(fn -> predecessors([slot(second)]) end)

      assert sql =~ "/* state_predecessors */"
    end
  end

  # ═══ AC1 (g) + AC8: the failure path ════════════════════════════════════════════

  describe "AC1 (g) / AC8 - a real DB error" do
    test "answers %{} and logs exactly ONE warning that names the slot count (61) and contains NO content value" do
      marker = "mkpred-#{T.rand(8)}"
      room = room!()
      t = base_ts()
      first = put!(room, "m.room.topic", "", %{"topic" => marker}, t)
      current_marker = "mkcur-#{T.rand(8)}"
      second = put!(room, "m.room.topic", "", %{"topic" => current_marker}, t + 1)
      filler = for n <- 1..60, do: {"$missing#{n}-#{T.rand(4)}", room, "m.nebu.sp.filler#{n}", "", t + 5}
      slots = [slot(second) | filler]
      assert length(slots) == 61

      # a real error of the statement itself, on the connection the call uses: inside a transaction an earlier failed statement aborts the
      # transaction, so the lookup is answered with "current transaction is aborted" (25P02) by PostgreSQL
      log =
        capture_log(fn ->
          outcome =
            Nebu.Repo.transaction(fn ->
              assert {:error, _} = Ecto.Adapters.SQL.query(Nebu.Repo, "SELECT 1 / 0", [])
              Nebu.Repo.rollback(predecessors(slots))
            end)

          send(self(), {:outcome, outcome})
        end)

      assert_received {:outcome, {:error, result}}
      assert result == %{}, "a failed lookup answers %{} (the response simply has no predecessor keys)"

      assert length(Regex.scan(~r/\[warning\]/, log)) == 1, "exactly ONE warning, got:\n#{log}"
      refute log =~ "[error]"
      assert log =~ ~r/\b61\b/, "the warning names the slot count"
      refute log =~ marker, "the warning must contain NO content value (No Sensitive Data in Logs Law)"
      refute log =~ first.id
      refute log =~ current_marker
    end

    test "the warning of fetch_state_predecessors/1 interpolates only the slot count and the SQLSTATE code: no inspect(reason), no content, rows, params or sender (source pin)" do
      src = File.read!(@db_source)
      assert [_, rest] = String.split(src, "def fetch_state_predecessors(slots)", parts: 2), "db.ex defines fetch_state_predecessors/1"
      body = rest |> String.split(~r/\n  (@doc|@spec|@sql_|def |defp )/, parts: 2) |> hd()

      assert body =~ "Logger.warning", "a DB failure is logged (observable, not silently 'no predecessors')"
      refute body =~ ~r/inspect\(\s*reason\s*\)/, "a Postgrex error can carry data (its message, constraint / detail text): log the SQLSTATE code (reason.postgres.code) only"

      interpolations = Regex.scan(~r/#\{([^}]*)\}/, body) |> Enum.map(&List.last/1)

      for expr <- interpolations do
        assert expr =~ ~r/\Alength\(slots\)\z/ or expr =~ ~r/code/, "an interpolation of the warning may be the slot count or the error code only, got: #\{#{expr}}"
        refute expr =~ ~r/content|rows|params|sender|row\b|reason\)/, "an interpolation of the warning must not carry data: #\{#{expr}}"
      end
    end
  end

  # ═══ AC1 (h): the plan ══════════════════════════════════════════════════════════

  describe "AC1 (h) - EXPLAIN (ANALYZE, BUFFERS)" do
    test "the statement for 300 slots has no Seq Scan on events even with enable_seqscan off (an index serves every read of events)" do
      slots = seed_300_slots!()
      {_result, [{sql, params}]} = capture_statements(fn -> predecessors(slots) end)

      # with sequential scans switched off the planner takes any usable index: a Seq Scan that survives is a scan no index can serve
      {:ok, plan_lines} =
        Nebu.Repo.transaction(fn ->
          Ecto.Adapters.SQL.query!(Nebu.Repo, "SET LOCAL enable_seqscan = off", [])
          %{rows: rows} = Ecto.Adapters.SQL.query!(Nebu.Repo, "EXPLAIN (ANALYZE, BUFFERS) " <> sql, params)
          Enum.map(rows, fn [line] -> line end)
        end)

      plan = Enum.join(plan_lines, "\n")
      refute plan =~ ~r/Seq Scan on events/, "a Seq Scan of events: no index can serve the predicate (rewrite it so that events_room_state_idx applies; no migration)\n#{plan}"
      # Which of the two indexes serves the slot read depends on the table statistics of the moment (events_room_state_idx, or events_room_id_ts_idx
      # with an incremental sort), so BOTH are accepted and no other access path. The REAL evidence for D11 (no whole-room timestamp walk on a big
      # table) is the EXPLAIN (ANALYZE, BUFFERS) on the seeded 500-room database that the dev records in the Completion Notes.
      assert plan =~ ~r/(Index (Only )?Scan( Backward)?|Bitmap Index Scan) using events_(room_state|room_id_ts)_idx/, "the slot lookup is served by events_room_state_idx / events_room_id_ts_idx\n#{plan}"
    end
  end

  # ═══ AC1 (i), (j): unban and revocation ═════════════════════════════════════════

  describe "AC1 (i) / (j) - a leave by ANOTHER user" do
    test "ban then leave by another user (unban, sender != state_key): the leave's predecessor is the ban, content {membership: ban}, sender the banner" do
      room = room!()
      user = user_id()
      banner = "@banner:#{@server}"
      t = base_ts()
      member!(room, user, "join", t)
      ban = member!(room, user, "ban", t + 10, sender: banner)
      unban = member!(room, user, "leave", t + 20, sender: banner)

      assert pred(unban) == %{event_id: ban.id, content: %{"membership" => "ban"}, sender: banner}
      refute unban.sender == user
    end

    test "invite then leave by another user (revocation, sender != state_key): the leave's predecessor is the invite with sender = the inviter" do
      room = room!()
      user = user_id()
      inviter = "@inviter:#{@server}"
      t = base_ts()
      invite = member!(room, user, "invite", t, sender: inviter, content: %{"membership" => "invite", "is_direct" => true})
      revoke = member!(room, user, "leave", t + 5, sender: inviter)

      assert pred(revoke) == %{event_id: invite.id, content: %{"membership" => "invite", "is_direct" => true}, sender: inviter}
      refute revoke.sender == user
    end
  end

  # ═══ AC1 (k): no deduplication of identical contents ════════════════════════════

  describe "AC1 (k) - the same content twice" do
    test "topic A, then topic A again: the second event's predecessor is the first, with content A (identical contents are not deduplicated)" do
      room = room!()
      t = base_ts()
      content = %{"topic" => "same-#{T.rand(4)}"}
      first = put!(room, "m.room.topic", "", content, t)
      second = put!(room, "m.room.topic", "", content, t + 1)

      assert pred(second) == %{event_id: first.id, content: content, sender: first.sender}
    end
  end

  # ═══ AC1 (l): a non-state event of a state type ═════════════════════════════════

  describe "AC1 (l) - a NON-state event of a state type" do
    test "an m.room.topic row with state_key NULL never gets a predecessor and never counts as one: a state topic after it is preceded by the EARLIER state topic" do
      room = room!()
      t = base_ts()
      state_one = put!(room, "m.room.topic", "", %{"topic" => "state one"}, t)

      # the non-state send path stores state_key NULL; callers never ask for it, and when asked anyway (nil key) it has no predecessor
      non_state = put!(room, "m.room.topic", nil, %{"topic" => "NOT state"}, t + 1)
      state_two = put!(room, "m.room.topic", "", %{"topic" => "state two"}, t + 2)

      assert pred(state_two) == %{event_id: state_one.id, content: %{"topic" => "state one"}, sender: state_one.sender}
      refute pred_id(state_two) == non_state.id, "a row without a state_key is not a state event and never a predecessor"
      assert pred(non_state) == nil, "a non-state event never gets a predecessor, even when its slot is asked for"
      assert pred(state_one) == nil
    end
  end

  # ═══ AC1 (m): redaction guard ═══════════════════════════════════════════════════

  # story state-writer-redaction (DELIBERATE re-pin, test review MAJOR-1; old -> new): the pin said "server/lib has no redaction path" and refuted the literal
  # `m.room.redaction` in EVERY file of server/lib. Redaction ships now, so the literal is allowed ONLY in the files of the redaction path (an ALLOW-LIST: a new
  # file that handles the type is a finding); the compliance guard stays unchanged and is the one that matters (D6: the stored row of a redacted event is never
  # changed, content stays server-readable: no `UPDATE events`, no `events SET content` anywhere in server/lib, comments included). The redaction-event writes
  # are pinned by state_writer_redaction_unit_test.exs (AC12 (a)); state events cannot be redacted (D4), so a predecessor's `prev_content` is never a redacted form.
  # NOTE FOR THE DEV: do not write the literal `m.room.redaction` in a comment or doc of a file outside the allow-list, nor `UPDATE events` / `events SET content`
  # anywhere. The statement's marker comment `/* state_predecessors */` is a pinned name too (the HTTP suite counts statements with it).
  @redaction_files ~w(
    nebu/matrix/room/server.ex
    nebu/matrix/redaction.ex
    nebu/matrix/event_dispatcher/server.ex
    nebu/matrix/http.ex
    nebu/matrix/room/db.ex
    nebu/matrix/room/power_level.ex
    nebu/compliance/audit_writer.ex
    nebu/web/log_store/route_normalizer.ex
    nebu/web/router/protected.ex
  )

  describe "AC1 (m) - redaction guard" do
    test "server/lib: the redaction event type appears only in the allow-listed files of the redaction path; nothing ever rewrites events.content" do
      sources = Path.wildcard(Path.join(@lib, "**/*.ex"))
      assert sources != []

      for path <- sources do
        src = File.read!(path)
        rel = Path.relative_to(path, @lib)

        if rel not in @redaction_files,
          do: refute(src =~ "m.room.redaction", "#{rel} handles the redaction event type but is not on the allow-list of the redaction path (story state-writer-redaction)")

        refute src =~ ~r/UPDATE\s+events\b/i, "#{rel} rewrites events: the stored row of a redacted event must never change (compliance, D6)"
        refute src =~ ~r/events\s+SET\s+content/i
      end
    end
  end
end
