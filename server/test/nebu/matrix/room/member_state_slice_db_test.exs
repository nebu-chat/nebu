defmodule Nebu.Matrix.Room.MemberStateSliceDbTest do
  @moduledoc """
  Real-database tests for story `membership-state-model` (follow-ups `fb`, `fl` (c)), AC4 (the bound) and AC5 (a), (b): the two new reads of `Nebu.Matrix.Room.DB`
  (ADR-018, inline parameter-bound SQL), against `Nebu.Repo`. NO fakes: a fake that returns pre-sorted rows proves nothing about the SQL (the D3 tie order, both
  JSONB forms, the filters and the cap in SQL are decided by the statement).

    * `member_state_slice(room_id, opts)` (D1, D4) -> `{:ok, [%{event_id, state_key, sender, content, origin_server_ts, membership}]}`: ONE statement (it carries the
      marker comment `/* member_state_slice */`), the latest `m.room.member` event per `state_key` of ONE room in the D3 order (`origin_server_ts DESC`, the most
      restrictive membership first, `event_id DESC`), `membership` NORMALISED (unknown / missing / unparseable / non-string -> `leave`), `content` the decoded
      map of either JSONB form (`%{}` when it is no object), the list ordered join, invite, ban, knock, leave and `state_key` ascending (the D6 order).
      Options: `:membership` / `:not_membership` (a membership string or nil; a slot is kept when it matches the first AND does not match the second, on the
      NORMALISED value), `:other_cap` (default 10 000: the test seam of the story's cap; the module attribute is the default).
      The cap applies to the NON-joined slots only, AFTER the filters, in SQL, in the priority invite > ban > knock > leave, newest `origin_server_ts` first
      within a class, `state_key` ascending as the last tie-break; joined slots are never capped.
    * `direct_invitees(room_id)` (D9) -> `{:ok, MapSet.t()}`: the users whose OWN latest `invite` event in the room carried `is_direct: true` (a boolean `true`),
      in either JSONB form, ONE statement.

  Every id is random; `@moduletag :integration`, `async: false` (statement counting uses the telemetry event of the repo).
  """
  use ExUnit.Case, async: false

  import Nebu.Matrix.MembershipStateTestSupport, only: [bulk_members!: 5, count_statements: 1, count_statements: 3, slice_count: 1, listing: 1, put_string_member!: 5]

  alias Nebu.Matrix.Room.DB
  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration

  @server "test.local"
  @keys [:content, :event_id, :membership, :origin_server_ts, :sender, :state_key]

  defp slice(room, opts \\ []), do: apply(DB, :member_state_slice, [room, opts])
  defp direct(room), do: apply(DB, :direct_invitees, [room])

  defp room! do
    room = "!ms#{T.rand(6)}:#{@server}"
    assert {:ok, _} = DB.insert_room(room)
    room
  end

  defp uid(label), do: "@#{label}#{T.rand(4)}:#{@server}"
  defp event_id(prefix), do: "$#{prefix}#{T.rand(8)}"

  # a member event through the real writer (the content a JSONB OBJECT)
  defp member!(room, user, membership, ts, opts \\ []) do
    id = Keyword.get(opts, :id, event_id("m"))
    content = Map.merge(%{"membership" => membership}, Keyword.get(opts, :extra, %{}))

    assert :ok =
             DB.insert_event(%{
               "event_id" => id,
               "room_id" => room,
               "sender" => Keyword.get(opts, :sender, user),
               "type" => "m.room.member",
               "state_key" => user,
               "content" => content,
               "origin_server_ts" => ts
             })

    id
  end

  # security cycle 3 (MINOR-6): runs `fun` while another connection holds an ACCESS EXCLUSIVE lock on `events` (every read of it waits
  # until its statement timeout); the lock is released afterwards, also when `fun` raises
  defp with_events_locked(fun) do
    parent = self()

    holder =
      Task.async(fn ->
        T.with_privileged_conn(fn conn ->
          Postgrex.transaction(conn, fn tx ->
            Postgrex.query!(tx, "LOCK TABLE events IN ACCESS EXCLUSIVE MODE", [])
            send(parent, :locked)

            receive do
              :release -> :ok
            after
              30_000 -> :ok
            end
          end)
        end)
      end)

    assert_receive :locked, 10_000

    try do
      fun.()
    after
      send(holder.pid, :release)
      Task.await(holder, 30_000)
    end
  end

  defp slot_keys(slots), do: Enum.map(slots, & &1.state_key)
  defp by_user(slots), do: Map.new(slots, &{&1.state_key, &1})

  # ═══ AC5 (a), (b): the contract ═════════════════════════════════════════════════════════════════

  describe "AC5 (a) - the latest member event per user in the D3 order, normalised, both JSONB forms" do
    test "the latest event wins by origin_server_ts; a user with a single event is listed; other rooms and other event types are ignored" do
      room = room!()
      other = room!()
      u1 = uid("a")
      u2 = uid("b")
      member!(room, u1, "leave", 1_000)
      newest = member!(room, u1, "join", 2_000)
      only = member!(room, u2, "invite", 1_500, sender: uid("inviter"))
      member!(other, u1, "ban", 9_000)
      assert :ok = DB.insert_event(%{"event_id" => event_id("n"), "room_id" => room, "sender" => u1, "type" => "m.room.name", "state_key" => "", "content" => %{"name" => "x"}, "origin_server_ts" => 9_001})

      assert {:ok, slots} = slice(room)

      assert slot_keys(slots) == [u1, u2], "join first, then invite"
      assert %{event_id: ^newest, membership: "join", origin_server_ts: 2_000, sender: ^u1, content: %{"membership" => "join"}} = by_user(slots)[u1]
      assert %{event_id: ^only, membership: "invite", origin_server_ts: 1_500} = by_user(slots)[u2]
      for slot <- slots, do: assert(Enum.sort(Map.keys(slot)) == @keys, "exactly the six keys")
    end

    test "the D3 tie: the SAME origin_server_ts decides by the rank (ban < leave < invite < knock < join), then event_id DESC" do
      room = room!()
      [ban_u, leave_u, invite_u, knock_u, same_u] = for l <- ~w(a b c d e), do: uid(l)

      # every join has the GREATER event id: only the rank can pick the other membership
      for {u, m} <- [{ban_u, "ban"}, {leave_u, "leave"}, {invite_u, "invite"}, {knock_u, "knock"}] do
        member!(room, u, "join", 5_000, id: "$zz" <> T.rand(6))
        member!(room, u, m, 5_000, id: "$aa" <> T.rand(6))
      end

      # insertion order reversed for one user: the answer is the same
      member!(room, ban_u, "join", 5_000, id: "$zy" <> T.rand(6))
      # two events of the SAME membership at the same ts: event_id DESC
      member!(room, same_u, "join", 5_000, id: "$aa1" <> T.rand(6))
      winner = member!(room, same_u, "join", 5_000, id: "$bb1" <> T.rand(6))

      assert {:ok, slots} = slice(room)
      by = by_user(slots)

      assert {by[ban_u].membership, by[leave_u].membership, by[invite_u].membership, by[knock_u].membership} == {"ban", "leave", "invite", "knock"}
      assert by[same_u].event_id == winner, "event_id DESC is the last tie-break"
      assert by[ban_u].event_id |> String.starts_with?("$aa")
    end

    test "unknown, non-string, missing and unparseable memberships read as leave; both JSONB forms decode alike; unparseable content is %{}" do
      room = room!()
      [unknown, nonstring, missing, string_obj, unparseable] = for l <- ~w(a b c d e), do: uid(l)
      member!(room, unknown, "banished", 1_000)
      member!(room, nonstring, 42, 1_000)
      assert :ok = DB.insert_event(%{"event_id" => event_id("x"), "room_id" => room, "sender" => missing, "type" => "m.room.member", "state_key" => missing, "content" => %{"displayname" => "x"}, "origin_server_ts" => 1_000})
      put_string_member!(room, string_obj, %{"membership" => "invite", "is_direct" => true}, uid("inviter"), 1_000)
      put_string_member!(room, unparseable, "{not json", unparseable, 1_000)

      assert {:ok, slots} = slice(room)
      by = by_user(slots)

      assert by[unknown].membership == "leave" and by[nonstring].membership == "leave" and by[missing].membership == "leave"
      assert by[unknown].content == %{"membership" => "banished"}, "the stored content is served as stored"
      assert by[nonstring].content == %{"membership" => 42}
      assert by[string_obj].membership == "invite" and by[string_obj].content == %{"membership" => "invite", "is_direct" => true}, "a JSON-string row decodes like an object row"
      assert by[unparseable].membership == "leave" and by[unparseable].content == %{}
    end

    test "the order is join, invite, ban, knock, leave, then state_key ascending within a class" do
      room = room!()
      users = for l <- ~w(m a z c b), do: {uid(l), l}
      memberships = %{"m" => "leave", "a" => "join", "z" => "join", "c" => "ban", "b" => "invite"}

      for {u, l} <- users, do: member!(room, u, memberships[l], 1_000)
      extra_leave = uid("a0")
      member!(room, extra_leave, "leave", 1_000)
      knock = uid("k")
      member!(room, knock, "knock", 1_000)

      assert {:ok, slots} = slice(room)

      assert Enum.map(slots, & &1.membership) == ["join", "join", "invite", "ban", "knock", "leave", "leave"]
      joins = slots |> Enum.filter(&(&1.membership == "join")) |> slot_keys()
      assert joins == Enum.sort(joins)
      leaves = slots |> Enum.filter(&(&1.membership == "leave")) |> slot_keys()
      assert leaves == Enum.sort(leaves)
    end

    test "a slice never carries another room's slots: two rooms with the same users and different memberships" do
      room = room!()
      other = room!()
      [u1, u2] = [uid("a"), uid("b")]
      member!(room, u1, "join", 100)
      member!(room, u2, "ban", 100)
      member!(other, u1, "ban", 200)
      member!(other, u2, "join", 200)
      member!(other, uid("only-other"), "invite", 200)

      assert {:ok, mine} = slice(room)
      assert {:ok, theirs} = slice(other)

      assert Enum.map(mine, &{&1.state_key, &1.membership}) == [{u1, "join"}, {u2, "ban"}]
      assert length(theirs) == 3 and Enum.all?(theirs, &(&1.origin_server_ts == 200))
    end

    test "(b) an empty room (no member event) answers {:ok, []}; a room id that does not exist answers {:ok, []} too (no row is created)" do
      room = room!()
      unknown = "!nope#{T.rand(6)}:#{@server}"

      assert slice(room) == {:ok, []}
      assert slice(unknown) == {:ok, []}
      assert T.sql!("SELECT count(*) FROM rooms WHERE room_id = $1", [unknown]).rows == [[0]]
    end
  end

  # ═══ the filters and the cap, in SQL ════════════════════════════════════════════════════════════

  describe "the filters (D6) and the cap (D4) are applied in SQL" do
    defp fixture! do
      room = room!()
      joined = for l <- ~w(j1 j2 j3), do: uid(l)
      invited = for l <- ~w(i1 i2), do: uid(l)
      banned = for l <- ~w(b1 b2), do: uid(l)
      knocked = [uid("k1")]
      left = for l <- ~w(l1 l2 l3 l4), do: uid(l)

      for {users, m, base} <- [{joined, "join", 100}, {invited, "invite", 200}, {banned, "ban", 300}, {knocked, "knock", 400}, {left, "leave", 500}],
          {u, i} <- Enum.with_index(users),
          do: member!(room, u, m, base + i * 10)

      %{room: room, joined: joined, invited: invited, banned: banned, knocked: knocked, left: left}
    end

    test "membership and not_membership: the first must match, the second must not (AND), on the normalised value" do
      f = fixture!()

      assert {:ok, bans} = slice(f.room, membership: "ban")
      assert slot_keys(bans) == Enum.sort(f.banned)
      assert {:ok, not_leave} = slice(f.room, not_membership: "leave")
      assert Enum.sort(slot_keys(not_leave)) == Enum.sort(f.joined ++ f.invited ++ f.banned ++ f.knocked)
      assert {:ok, both} = slice(f.room, membership: "join", not_membership: "leave")
      assert slot_keys(both) == Enum.sort(f.joined)
      assert {:ok, []} = slice(f.room, membership: "ban", not_membership: "ban")
      assert {:ok, []} = slice(f.room, membership: "knock", not_membership: "knock")
      assert {:ok, [_one]} = slice(f.room, membership: "knock")
      assert {:ok, inv} = slice(f.room, membership: "invite", not_membership: "join")
      assert slot_keys(inv) == Enum.sort(f.invited)
    end

    test "the filter works on the LATEST event of a user: an older ban of a user who joined again is not a ban" do
      room = room!()
      u = uid("u")
      member!(room, u, "ban", 100)
      member!(room, u, "join", 200)

      assert {:ok, []} = slice(room, membership: "ban")
      assert {:ok, [%{membership: "join"}]} = slice(room, membership: "join")
    end

    test "the cap counts the NON-joined slots only: joined slots are never capped; the priority is invite > ban > knock > leave" do
      f = fixture!()

      # 9 non-joined slots (2 + 2 + 1 + 4); joined: 3
      assert {:ok, zero} = slice(f.room, other_cap: 0)
      assert slot_keys(zero) == Enum.sort(f.joined), "cap 0: only the joined slots"

      assert {:ok, four} = slice(f.room, other_cap: 4)
      assert Enum.sort(slot_keys(four)) == Enum.sort(f.joined ++ f.invited ++ f.banned), "cap 4: the invites and the bans"

      assert {:ok, five} = slice(f.room, other_cap: 5)
      assert Enum.sort(slot_keys(five)) == Enum.sort(f.joined ++ f.invited ++ f.banned ++ f.knocked), "cap 5: + the knock"

      assert {:ok, six} = slice(f.room, other_cap: 6)
      newest_leave = List.last(f.left)
      assert Enum.sort(slot_keys(six)) == Enum.sort(f.joined ++ f.invited ++ f.banned ++ f.knocked ++ [newest_leave]), "cap 6: + the NEWEST leave"

      assert {:ok, all} = slice(f.room, other_cap: 9)
      assert length(all) == 12
      assert {:ok, over} = slice(f.room, other_cap: 1_000)
      assert length(over) == 12
    end

    test "within a class the newest origin_server_ts comes first; equal timestamps break by state_key ascending (deterministic)" do
      room = room!()
      a = "@aa#{T.rand(3)}:#{@server}"
      b = "@bb#{T.rand(3)}:#{@server}"
      c = "@cc#{T.rand(3)}:#{@server}"
      d = "@dd#{T.rand(3)}:#{@server}"
      member!(room, d, "leave", 100)
      member!(room, c, "leave", 300)
      member!(room, b, "leave", 300)
      member!(room, a, "leave", 200)

      assert {:ok, one} = slice(room, other_cap: 1)
      assert slot_keys(one) == [b], "equal timestamps: the smaller state_key wins the last place"
      assert {:ok, two} = slice(room, other_cap: 2)
      assert slot_keys(two) == [b, c], "the two newest (equal ts): b before c by state_key"
      assert {:ok, three} = slice(room, other_cap: 3)
      assert slot_keys(three) == [a, b, c] |> Enum.sort()
      assert {:ok, again} = slice(room, other_cap: 2)
      assert again == two, "deterministic"
    end

    test "the filters are applied BEFORE the cap: ?membership=leave with cap 3 returns the 3 newest leaves although higher classes exist; not_membership=invite keeps the bans first" do
      f = fixture!()

      assert {:ok, leaves} = slice(f.room, membership: "leave", other_cap: 3)
      assert slot_keys(leaves) == f.left |> Enum.take(-3) |> Enum.sort(), "3 leaves (not 3 - 5 = 0 after a cap-then-filter)"

      assert {:ok, not_invite} = slice(f.room, not_membership: "invite", other_cap: 3)
      assert Enum.sort(slot_keys(not_invite)) == Enum.sort(f.joined ++ f.banned ++ f.knocked), "bans, then the knock; the leaves lose"
      assert {:ok, bans} = slice(f.room, membership: "ban", other_cap: 2)
      assert slot_keys(bans) == Enum.sort(f.banned)
    end

    test "joined slots survive any filter-cap combination: membership=join with cap 0 still lists every join" do
      f = fixture!()

      assert {:ok, joins} = slice(f.room, membership: "join", other_cap: 0)
      assert slot_keys(joins) == Enum.sort(f.joined)
    end
  end

  # ═══ AC4: the real bound, ONE statement, the index ══════════════════════════════════════════════

  describe "AC4 - the bound of 10 000 non-joined slots (D4)" do
    @tag timeout: 120_000
    test "(a) 3 joined + 10 005 non-joined (distinct timestamps): 3 joined and EXACTLY 10 000 others, invite > ban > leave, newest first, deterministic" do
      room = room!()
      on_exit(fn -> assert {:ok, _} = Ecto.Adapters.SQL.query(Nebu.Repo, "DELETE FROM events WHERE room_id = $1", [room], []) end)
      joined = for l <- ~w(j1 j2 j3), do: uid(l)
      for {u, i} <- Enum.with_index(joined), do: member!(room, u, "join", 1_000 + i)
      sender = uid("s")
      base = System.system_time(:millisecond) - 500_000

      invites = bulk_members!(room, 100, ["invite"], base - 400_000, sender)
      bans = bulk_members!(room, 100, ["ban"], base - 300_000, sender)
      leaves = bulk_members!(room, 9_805, ["leave"], base, sender)
      newest_leaves = leaves |> Enum.sort_by(&elem(&1, 2), :desc) |> Enum.take(9_800) |> MapSet.new(&elem(&1, 0))
      expected = MapSet.union(MapSet.new(invites ++ bans, &elem(&1, 0)), newest_leaves)

      assert {:ok, first} = slice(room)
      assert {:ok, second} = slice(room)

      assert Enum.count(first, &(&1.membership == "join")) == 3
      others = Enum.reject(first, &(&1.membership == "join"))
      assert length(others) == 10_000
      assert MapSet.new(others, & &1.state_key) == expected
      assert first == second, "deterministic across two calls"
    end

    test "(b) ?membership=ban returns every ban although the leaves alone exceed the cap (filter before cap)" do
      room = room!()
      on_exit(fn -> assert {:ok, _} = Ecto.Adapters.SQL.query(Nebu.Repo, "DELETE FROM events WHERE room_id = $1", [room], []) end)
      base = System.system_time(:millisecond) - 500_000
      bans = bulk_members!(room, 7, ["ban"], base - 100_000, uid("s"))
      _leaves = bulk_members!(room, 10_020, ["leave"], base, uid("s"))

      assert {:ok, listed} = slice(room, membership: "ban")
      assert MapSet.new(listed, & &1.state_key) == MapSet.new(bans, &elem(&1, 0)) and length(listed) == 7
      assert {:ok, leaves} = slice(room, membership: "leave")
      assert length(leaves) == 10_000, "10 020 leaves, 10 000 listed"
    end

    test "(c) the slice is ONE statement behind the 2 s SET LOCAL (it carries the marker comment /* member_state_slice */)" do
      room = room!()
      u = uid("u")
      member!(room, u, "join", 100)

      {result, statements} = count_statements(fn -> slice(room, membership: "join", not_membership: "leave", other_cap: 5) end)

      assert {:ok, [_one]} = result
      # security cycle 1 (M-1; old -> new): the read runs in a transaction that first sets `statement_timeout = '2s'` (begin / commit are not counted): the SET
      # LOCAL and ONE slice statement (the marker comment) are the only statements
      assert length(statements) == 2, "SET LOCAL + ONE slice statement: #{listing(statements)}"
      assert slice_count(statements) == 1, "it carries the marker comment /* member_state_slice */"
      assert Enum.count(statements, &(&1 =~ ~r/SET LOCAL statement_timeout\s*=\s*'2s'/)) == 1

      # MINOR 4: both statements sit INSIDE one transaction, in this order (SET LOCAL only lasts until its end)
      {_result, with_tx} = count_statements(fn -> slice(room, membership: "join") end, [], keep_tx: true)
      assert [begin, set_local, slice_sql, commit] = with_tx, "BEGIN, SET LOCAL, slice, COMMIT: #{listing(with_tx)}"
      assert String.downcase(begin) == "begin" and String.downcase(commit) == "commit"
      assert set_local =~ ~r/SET LOCAL statement_timeout/ and slice_sql =~ "member_state_slice"
    end

    test "(MINOR 2) the strict predecessor lookup runs BEGIN, SET LOCAL statement_timeout = '2s', the lookup, COMMIT; the lenient one stays ONE statement" do
      room = room!()
      u = uid("p")
      first = member!(room, u, "invite", 100)
      second = member!(room, u, "join", 200)
      slots = [{second, room, "m.room.member", u, 200}]

      {strict, with_tx} = count_statements(fn -> apply(DB, :fetch_state_predecessors, [slots, [strict: true]]) end, [], keep_tx: true)
      {lenient, plain} = count_statements(fn -> apply(DB, :fetch_state_predecessors, [slots]) end, [], keep_tx: true)

      assert {:ok, %{^second => %{event_id: ^first}}} = strict
      assert %{^second => %{event_id: ^first}} = lenient
      assert [begin, set_local, lookup, commit] = with_tx, listing(with_tx)
      assert String.downcase(begin) == "begin" and set_local =~ ~r/SET LOCAL statement_timeout\s*=\s*'2s'/ and lookup =~ "/* state_predecessors */" and String.downcase(commit) == "commit"
      assert [only] = plain, "the lenient lookup is exactly one statement: #{listing(plain)}"
      assert only =~ "/* state_predecessors */"
      assert apply(DB, :fetch_state_predecessors, [[], [strict: true]]) == {:ok, %{}}
    end

    @tag timeout: 60_000
    test "(MINOR 2) a strict predecessor lookup that waits longer than the 2 s statement timeout answers {:error, 57014}" do
      room = room!()
      u = uid("p")
      member!(room, u, "invite", 100)
      second = member!(room, u, "join", 200)

      result = with_events_locked(fn -> apply(DB, :fetch_state_predecessors, [[{second, room, "m.room.member", u, 200}], [strict: true]]) end)

      assert {:error, %Postgrex.Error{postgres: %{pg_code: "57014"}}} = result
    end

    @tag timeout: 60_000
    test "(M-1) a slice that waits longer than the 2 s statement timeout (an ACCESS EXCLUSIVE lock on events) answers {:error, 57014} after about 2 s, never a partial list" do
      room = room!()
      member!(room, uid("a"), "join", 100)

      {result, elapsed} =
        with_events_locked(fn ->
          started = System.monotonic_time(:millisecond)
          {slice(room), System.monotonic_time(:millisecond) - started}
        end)

      assert {:error, %Postgrex.Error{postgres: %{pg_code: "57014"}}} = result
      assert elapsed >= 1_800 and elapsed < 8_000, "the timeout is 2 s: waited #{elapsed} ms"
      assert {:ok, [_one]} = slice(room), "control: the read works again once the lock is gone"
    end

    test "(c) the statement uses events_room_state_idx (EXPLAIN of the REAL statement with the real parameters, sequential scans disabled)" do
      room = room!()
      member!(room, uid("u"), "join", 100)
      id = "ms-explain-#{T.rand(6)}"
      parent = self()

      :ok =
        :telemetry.attach(
          id,
          [:nebu, :repo, :query],
          fn _event, _measurements, %{query: query, params: params}, _config ->
            if String.contains?(query, "/* member_state_slice */"), do: send(parent, {:slice_statement, query, params})
          end,
          nil
        )

      try do
        assert {:ok, _} = slice(room)
      after
        :telemetry.detach(id)
      end

      assert_received {:slice_statement, query, params}
      refute query =~ ~r/SELECT\s+\*/i, "the statement names its columns"

      plan =
        T.with_privileged_conn(fn conn ->
          Postgrex.transaction(conn, fn tx ->
            Postgrex.query!(tx, "SET LOCAL enable_seqscan = off", [])

            # the planner of a tiny fixture may prefer another room-prefixed index: inside this rolled-back transaction every other non-unique index of `events` is
            # dropped, so the plan shows whether events_room_state_idx CAN serve the statement
            %{rows: others} =
              Postgrex.query!(
                tx,
                "SELECT c.relname FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid WHERE i.indrelid = 'events'::regclass AND NOT i.indisunique AND c.relname <> 'events_room_state_idx'",
                []
              )

            for [name] <- others, do: Postgrex.query!(tx, ~s(DROP INDEX "#{name}"), [])
            %{rows: rows} = Postgrex.query!(tx, "EXPLAIN " <> query, params)
            Postgrex.rollback(tx, Enum.map_join(rows, "\n", &hd/1))
          end)
        end)

      assert {:error, text} = plan
      assert text =~ "events_room_state_idx", "the index serves the scan: #{text}"
    end
  end

  # ═══ direct_invitees/1 (D9) ═════════════════════════════════════════════════════════════════════

  describe "direct_invitees/1 (D9)" do
    test "the users whose OWN latest invite event had is_direct: true (a later join does not matter; a later non-direct re-invite removes the user); both JSONB forms; other rooms ignored" do
      room = room!()
      other = room!()
      [joined_direct, plain, reinvited, string_form, text_true, other_room_only] = for l <- ~w(a b c d e f), do: uid(l)

      member!(room, joined_direct, "invite", 100, extra: %{"is_direct" => true}, sender: uid("inviter"))
      member!(room, joined_direct, "join", 200)
      member!(room, plain, "invite", 100)
      member!(room, reinvited, "invite", 100, extra: %{"is_direct" => true})
      member!(room, reinvited, "leave", 150)
      member!(room, reinvited, "invite", 200)
      put_string_member!(room, string_form, %{"membership" => "invite", "is_direct" => true}, uid("inviter"), 100)
      member!(room, text_true, "invite", 100, extra: %{"is_direct" => "true"})
      member!(other, other_room_only, "invite", 100, extra: %{"is_direct" => true})

      assert {:ok, set} = direct(room)

      assert MapSet.equal?(set, MapSet.new([joined_direct, string_form])), "got #{inspect(MapSet.to_list(set))}"
      assert {:ok, empty} = direct(room!())
      assert MapSet.size(empty) == 0
    end

    test "ONE statement" do
      room = room!()
      member!(room, uid("a"), "invite", 100, extra: %{"is_direct" => true})

      {result, statements} = count_statements(fn -> direct(room) end)

      assert {:ok, _set} = result
      assert length(statements) == 1, listing(statements)
    end
  end
end
