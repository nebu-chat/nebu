defmodule Nebu.Matrix.Room.MembershipPartitionDbTest do
  @moduledoc """
  Real-database tests for story `sync-membership-partition` (epic oauth-broker, follow-ups `ev` + `ez`), AC1 and the SQL half of D13:
  the membership reads the `/sync` partition is built on. NO fakes: a fake that returns pre-sorted rows proves nothing about the SQL
  (a fake hid a real defect in two earlier stories), so the tie order, both JSONB forms, the window bounds, the candidate union, the
  one-statement property and the index usage are pinned here, against `Nebu.Repo`, with rows written through the real writers
  (`Room.DB.insert_room/1`, `insert_member/2`, `delete_member/2`, `insert_event/1`, `InviteDB.insert_invitation/3` / `reject_invitation/2` /
  `accept_invitation/2`) and, where a test needs an exact timestamp tie or the double-encoded JSONB string form, through the privileged
  role (`T.privileged_sql!/2`; the runtime role can INSERT events, the privileged role is used only to control the shape of the row).

  ## The reads under test (names and shapes: D2a of the story)

  All four reads live in `Nebu.Matrix.Room.DB` (ADR-018, inline parameter-bound SQL, NOT in `DBBehaviour`: the sync reaches them through
  `rooms_db_module()`), each returns `{:ok, value}` or `{:error, reason}`:

    * `membership_candidates(user_id)` (D2 (a)) -> `{:ok, [candidate]}`, ONE statement over `room_members` and `room_invitations` of the user
      (UNION ALL: a re-invited former member is TWO candidates of the same room, one of each kind). A candidate is a map with (at least) the keys

          %{room_id:, kind: :member | :invitation, active: boolean, pending: boolean, inviter_id: nil | id, invited_at: nil | ms}

      member rows: `kind: :member`, `active` = `left_at IS NULL`, `pending: false`, `inviter_id` / `invited_at` nil. Invitation rows:
      `kind: :invitation`, `active: false`, `pending` = neither accepted nor rejected, `inviter_id` / `invited_at` of the row. ACCEPTED
      invitation rows are NOT candidates (the member row decides). Another user's rows are never returned.
    * `latest_member_events(room_ids, user_id)` (D2 (b)) -> `{:ok, %{room_id => [event]}}`: ONE statement for all rooms, the (at most) two newest
      `m.room.member` events with `state_key = user_id` per room, NEWEST FIRST (`[L, P]`), in the tie order of D3
      (`origin_server_ts DESC, rank ASC, event_id DESC`, `rank(ban) = 0 < leave = 1 < invite = 2 < knock = 3 < join = 4`; an unknown / unparseable
      membership has rank 1 and counts as `leave`). `event` = `%{event_id:, origin_server_ts:, sender:, membership:, content:}`; `membership`
      is NORMALISED (one of "ban" "leave" "invite" "knock" "join", anything else is "leave"), `content` is the stored content decoded from
      BOTH JSONB forms (an object, or a double-encoded JSONB string). A room without a member event of the user may be absent or `[]`.
    * `invite_state_events(room_ids)` (D2 (c)) -> `{:ok, %{room_id => [stripped]}}`: ONE statement for all rooms: the room's FIRST `m.room.create`
      event, then the latest event with `state_key = ""` of each of `m.room.name`, `.avatar`, `.topic`, `.canonical_alias`, `.join_rules`,
      `.encryption` that exists, in that order, nothing else; `stripped` = a map with EXACTLY the string keys "type", "state_key", "sender",
      "content" (decoded, both forms). The inviter's member event is read with `latest_member_events/2` (the inviter as the user).
    * `leave_window_events(room_id, after_ts, before_ts)` (D2 (d)) -> `{:ok, [event_map]}`: the events of the room with
      `after_ts < origin_server_ts < before_ts` (STRICT at both ends), newest 20 by `(origin_server_ts DESC, event_id DESC)` (the raw order:
      the caller reverses), each with the columns of `fetch_events_since/3` (`event_id, room_id, sender, event_type, content, origin_server_ts, state_key`).
      (Superseded by story sync-stream-position, D10: `leave_window_events/5` with positions, see the amendment comment above the AC1 (d) describe.)
    * `latest_member_event(room_id, user_id)` (D13) -> `{:ok, %{membership:, origin_server_ts:, sender:} | nil}` (D3 order, normalised membership).
    * `InviteDB.pending_invitation(room_id, user_id)` (D13) -> `{:ok, invited_at | nil}` (a PENDING row only).

  Every id is random; `@moduletag :integration`, `async: false` (statement counting uses the telemetry event of
  the repo, filtered to the calling process).
  """
  use ExUnit.Case, async: false

  alias Nebu.Matrix.Room.DB
  alias Nebu.Matrix.Room.InviteDB
  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration

  @server "test.local"
  @rank %{"ban" => 0, "leave" => 1, "invite" => 2, "knock" => 3, "join" => 4}

  # ─── helpers ─────────────────────────────────────────────────────────────────

  defp db(fun, args), do: apply(DB, fun, args)
  defp pending_invitation(room, user), do: InviteDB.pending_invitation(room, user)

  defp room! do
    room = "!mp#{T.rand(6)}:#{@server}"
    assert {:ok, _} = DB.insert_room(room)
    room
  end

  defp user!, do: T.provision_user!()

  defp event_id(prefix \\ "m"), do: "$#{prefix}#{T.rand(8)}"

  # a member event through the real writer (content stored as a JSONB OBJECT)
  defp member_event!(room, user, membership, ts, opts \\ []) do
    id = Keyword.get(opts, :id, event_id())

    content =
      case Keyword.get(opts, :content) do
        nil -> %{"membership" => membership}
        content -> content
      end

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

  # the same event with the content stored as a double-encoded JSONB STRING (what an older writer produced): `to_jsonb(<json text>)`
  defp string_form_member_event!(room, user, content, ts, opts \\ []) do
    id = Keyword.get(opts, :id, event_id("s"))
    json_text = if is_binary(content), do: content, else: Jason.encode!(content)

    T.privileged_sql!(
      "INSERT INTO events (event_id, room_id, sender, event_type, content, origin_server_ts, state_key) VALUES ($1, $2, $3, 'm.room.member', to_jsonb($4::text), $5, $6)",
      [id, room, Keyword.get(opts, :sender, user), json_text, ts, user]
    )

    id
  end

  defp state_event!(room, type, key, content, ts, opts \\ []) do
    id = Keyword.get(opts, :id, event_id("e"))

    assert :ok =
             DB.insert_event(%{
               "event_id" => id,
               "room_id" => room,
               "sender" => Keyword.get(opts, :sender, "@creator:#{@server}"),
               "type" => type,
               "state_key" => key,
               "content" => content,
               "origin_server_ts" => ts
             })

    id
  end

  defp message_event!(room, ts, opts \\ []) do
    id = Keyword.get(opts, :id, event_id("x"))

    assert :ok =
             DB.insert_event(%{
               "event_id" => id,
               "room_id" => room,
               "sender" => "@creator:#{@server}",
               "type" => "m.room.message",
               "state_key" => nil,
               "content" => %{"msgtype" => "m.text", "body" => "m #{T.rand(4)}"},
               "origin_server_ts" => ts
             })

    id
  end

  defp join!(room, user), do: assert(:ok = DB.insert_member(room, user))
  defp leave!(room, user), do: assert(:ok = DB.delete_member(room, user))

  defp latest(rooms, user) do
    assert {:ok, map} = db(:latest_member_events, [rooms, user])
    assert is_map(map), "latest_member_events/2 answers {:ok, %{room_id => [event]}}"
    map
  end

  defp events_of(rooms, user, room), do: latest(rooms, user) |> Map.get(room, [])

  # the invitation row of (room, user): %{invited_at, accepted_at, rejected_at, inviter}
  defp invitation_row(room, user) do
    [[invited_at, accepted_at, rejected_at, inviter]] =
      T.sql!("SELECT invited_at, accepted_at, rejected_at, inviter_id FROM room_invitations WHERE room_id = $1 AND invitee_id = $2", [room, user]).rows

    %{invited_at: invited_at, accepted_at: accepted_at, rejected_at: rejected_at, inviter: inviter}
  end

  # base timestamp far away from "now" so that rows written through the real writers (which stamp the clock) never interleave with the
  # scripted timestamps of one test
  defp base_ts, do: 1_600_000_000_000 + :rand.uniform(1_000_000) * 10

  # ─── statement counting / plan capture (telemetry of the repo, only the calling process) ───

  def handle_query(_event, _measurements, %{query: query, params: params}, %{pid: pid}) do
    if self() == pid, do: send(pid, {:statement, query, params})
    :ok
  end

  def handle_query(_event, _measurements, _metadata, _config), do: :ok

  # runs `fun`, returns {result, [{sql, params}]} of the statements the calling process sent through Nebu.Repo
  defp capture_statements(fun) do
    id = "mp-db-#{T.rand(6)}"
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

  # the plan (JSON) of a captured statement with sequential scans DISABLED: a `Seq Scan` that survives is a scan that no index can serve
  # (with the switch off the planner takes any usable index, regardless of how small the tables of this database are)
  defp plan_nodes(sql, params) do
    {:ok, plan} =
      Nebu.Repo.transaction(fn ->
        Ecto.Adapters.SQL.query!(Nebu.Repo, "SET LOCAL enable_seqscan = off", [])
        %{rows: [[json]]} = Ecto.Adapters.SQL.query!(Nebu.Repo, "EXPLAIN (FORMAT JSON) " <> sql, params)
        json
      end)

    plan = if is_binary(plan), do: Jason.decode!(plan), else: plan
    collect_nodes(plan)
  end

  defp collect_nodes(list) when is_list(list), do: Enum.flat_map(list, &collect_nodes/1)

  defp collect_nodes(%{} = map) do
    own = if Map.has_key?(map, "Node Type"), do: [map], else: []
    own ++ Enum.flat_map(Map.values(map), &collect_nodes/1)
  end

  defp collect_nodes(_other), do: []

  defp seq_scans_on(nodes, relation), do: Enum.filter(nodes, &(&1["Node Type"] == "Seq Scan" and &1["Relation Name"] == relation))

  # ═══ AC1 (a): the candidates ═════════════════════════════════════════════════════

  describe "AC1 (a) - membership_candidates/1" do
    test "active, left, pending and rejected rows come back with their fields; an ACCEPTED invitation and another user's rows never do" do
      me = user!()
      other = user!()
      inviter = user!()

      active = room!()
      left = room!()
      pending = room!()
      rejected = room!()
      accepted = room!()
      others_room = room!()

      join!(active, me)
      join!(left, me)
      leave!(left, me)
      assert :ok = InviteDB.insert_invitation(pending, inviter, me)
      assert :ok = InviteDB.insert_invitation(rejected, inviter, me)
      assert :ok = InviteDB.reject_invitation(rejected, me)
      assert :ok = InviteDB.insert_invitation(accepted, inviter, me)
      assert :ok = InviteDB.accept_invitation(accepted, me)
      join!(others_room, other)
      assert :ok = InviteDB.insert_invitation(others_room, inviter, other)

      {result, statements} = capture_statements(fn -> db(:membership_candidates, [me]) end)
      assert {:ok, candidates} = result
      assert length(statements) == 1, "D2 (a): ONE statement for all candidates, got #{length(statements)}"
      by_room = Map.new(candidates, &{&1.room_id, &1})

      assert Enum.sort(Map.keys(by_room)) == Enum.sort([active, left, pending, rejected]), "exactly the rooms of the four kinds, got #{inspect(Map.keys(by_room))}"
      assert length(candidates) == 4

      assert %{kind: :member, active: true, pending: false, inviter_id: nil, invited_at: nil} = by_room[active]
      assert %{kind: :member, active: false, pending: false, inviter_id: nil, invited_at: nil} = by_room[left]

      pending_row = invitation_row(pending, me)
      assert %{kind: :invitation, active: false, pending: true} = by_room[pending]
      assert by_room[pending].inviter_id == inviter and by_room[pending].invited_at == pending_row.invited_at

      rejected_row = invitation_row(rejected, me)
      assert %{kind: :invitation, active: false, pending: false} = by_room[rejected]
      assert by_room[rejected].inviter_id == inviter and by_room[rejected].invited_at == rejected_row.invited_at

      for candidate <- candidates do
        for key <- [:active, :invited_at, :inviter_id, :kind, :pending, :room_id], do: assert(Map.has_key?(candidate, key), "the pinned key #{key}")
      end
    end

    test "review cycle 1 (Kassandra M-1): a member row carries left_at (nil while active, the end of the membership once left); an invitation row has left_at nil" do
      me = user!()
      inviter = user!()
      active = room!()
      left = room!()
      invited = room!()

      join!(active, me)
      join!(left, me)
      before_leave = System.system_time(:millisecond)
      leave!(left, me)
      after_leave = System.system_time(:millisecond)
      assert :ok = InviteDB.insert_invitation(invited, inviter, me)

      assert {:ok, candidates} = db(:membership_candidates, [me])
      by_room = Map.new(candidates, &{&1.room_id, &1})

      assert Map.fetch!(by_room[active], :left_at) == nil
      assert Map.fetch!(by_room[invited], :left_at) == nil
      for room <- [active, left], do: assert(is_integer(Map.fetch!(by_room[room], :joined_at)), "review cycle 2 (I-1): a member row carries joined_at")
      assert Map.fetch!(by_room[invited], :joined_at) == nil
      left_at = Map.fetch!(by_room[left], :left_at)
      assert is_integer(left_at) and left_at >= before_leave and left_at <= after_leave, "left_at is the clock of the soft delete, got #{inspect(left_at)}"
    end

    test "a re-invited former member (left row + pending invitation row) is TWO candidates of the room, one of each kind" do
      me = user!()
      inviter = user!()
      room = room!()

      join!(room, me)
      leave!(room, me)
      assert :ok = InviteDB.insert_invitation(room, inviter, me)

      assert {:ok, candidates} = db(:membership_candidates, [me])
      mine = Enum.filter(candidates, &(&1.room_id == room))

      assert Enum.sort_by(mine, & &1.kind) |> Enum.map(&{&1.kind, &1.active, &1.pending}) == [{:invitation, false, true}, {:member, false, false}]
    end

    test "a user without any row gets an empty list; a re-armed invitation shows the NEW invited_at" do
      stranger = user!()
      assert {:ok, []} = db(:membership_candidates, [stranger])

      me = user!()
      inviter = user!()
      room = room!()
      assert :ok = InviteDB.insert_invitation(room, inviter, me)
      first = invitation_row(room, me).invited_at
      assert :ok = InviteDB.reject_invitation(room, me)

      T.privileged_sql!("UPDATE room_invitations SET invited_at = invited_at - 5000 WHERE room_id = $1 AND invitee_id = $2", [room, me])
      assert :ok = InviteDB.insert_invitation(room, inviter, me)

      assert {:ok, [candidate]} = db(:membership_candidates, [me])
      assert candidate.pending == true
      assert candidate.invited_at >= first, "the re-arm refreshed invited_at"
    end
  end

  # ═══ AC1 (b): the latest two member events, the tie order, both JSONB forms ═══════

  describe "AC1 (b) - latest_member_events/2" do
    test "join (t1) < leave (t2): L = leave, P = join, newest first; a third older event is not returned (at most two per room)" do
      room = room!()
      user = user!()
      t = base_ts()
      first = member_event!(room, user, "invite", t, sender: "@a:#{@server}")
      join = member_event!(room, user, "join", t + 10)
      leave = member_event!(room, user, "leave", t + 20)

      assert [%{event_id: ^leave, membership: "leave", origin_server_ts: ts_l}, %{event_id: ^join, membership: "join", origin_server_ts: ts_p}] = events_of([room], user, room)
      assert ts_l == t + 20 and ts_p == t + 10
      refute first in Enum.map(events_of([room], user, room), & &1.event_id)
    end

    test "every event carries event_id, origin_server_ts, sender (the AUTHOR), membership and the decoded content" do
      room = room!()
      user = user!()
      kicker = user!()
      t = base_ts()
      id = member_event!(room, user, "leave", t, sender: kicker)

      assert [event] = events_of([room], user, room)
      assert %{event_id: ^id, origin_server_ts: ^t, sender: ^kicker, membership: "leave", content: %{"membership" => "leave"}} = event
    end

    test "same millisecond: the MOST RESTRICTIVE membership is the latest (ban > leave > invite > knock > join), whatever the event ids say" do
      user = user!()
      pairs = for restrictive <- ~w(ban leave invite knock), lax <- ~w(leave invite knock join), @rank[restrictive] < @rank[lax], do: {restrictive, lax}
      assert length(pairs) == 10

      for {restrictive, lax} <- pairs, ids <- [{"$aaa", "$zzz"}, {"$zzz", "$aaa"}] do
        room = room!()
        t = base_ts()
        {restrictive_prefix, lax_prefix} = ids
        restrictive_id = member_event!(room, user, restrictive, t, id: restrictive_prefix <> T.rand(6))
        _lax_id = member_event!(room, user, lax, t, id: lax_prefix <> T.rand(6))

        assert [%{event_id: ^restrictive_id, membership: ^restrictive} | _] = events_of([room], user, room),
               "#{restrictive} beats #{lax} in one millisecond (ids #{inspect(ids)})"
      end
    end

    test "join and ban in the SAME millisecond: L = ban, P = join (the case the partition and the join decision must agree on)" do
      room = room!()
      user = user!()
      t = base_ts()
      join = member_event!(room, user, "join", t, id: "$zzz" <> T.rand(6))
      ban = member_event!(room, user, "ban", t, id: "$aaa" <> T.rand(6))

      assert [%{event_id: ^ban, membership: "ban"}, %{event_id: ^join, membership: "join"}] = events_of([room], user, room)
    end

    test "invite and leave in the same millisecond: L = leave (a taken-back invitation is a leave)" do
      room = room!()
      user = user!()
      t = base_ts()
      invite = member_event!(room, user, "invite", t, id: "$zzz" <> T.rand(6), sender: "@a:#{@server}")
      leave = member_event!(room, user, "leave", t, id: "$aaa" <> T.rand(6), sender: "@a:#{@server}")

      assert [%{event_id: ^leave, membership: "leave"}, %{event_id: ^invite, membership: "invite"}] = events_of([room], user, room)
    end

    test "two events of the same rank in one millisecond: the larger event_id is the latest (deterministic, no arbitrary pick)" do
      room = room!()
      user = user!()
      t = base_ts()
      small = member_event!(room, user, "leave", t, id: "$aaa" <> T.rand(6))
      large = member_event!(room, user, "leave", t, id: "$zzz" <> T.rand(6))

      assert [%{event_id: ^large}, %{event_id: ^small}] = events_of([room], user, room)
    end

    test "the timestamp decides before the rank: a later join beats an earlier ban" do
      room = room!()
      user = user!()
      t = base_ts()
      ban = member_event!(room, user, "ban", t)
      join = member_event!(room, user, "join", t + 1)

      assert [%{event_id: ^join, membership: "join"}, %{event_id: ^ban, membership: "ban"}] = events_of([room], user, room)
    end

    test "both JSONB forms decode, is_direct is preserved; an unknown / non-string / missing membership counts as leave" do
      user = user!()
      inviter = "@a:#{@server}"
      t = base_ts()

      object_room = room!()
      object_id = member_event!(object_room, user, "invite", t, content: %{"membership" => "invite", "is_direct" => true}, sender: inviter)
      string_room = room!()
      string_id = string_form_member_event!(string_room, user, %{"membership" => "invite", "is_direct" => true}, t, sender: inviter)

      for {room, id} <- [{object_room, object_id}, {string_room, string_id}] do
        assert [%{event_id: ^id, membership: "invite", content: %{"membership" => "invite", "is_direct" => true}, sender: ^inviter}] = events_of([room], user, room)
      end

      # unknown / unparseable: no error (one bad row must not poison the whole read), rank 1 = leave
      for {label, writer} <- [
            unknown: fn room -> member_event!(room, user, "foo", t + 1, content: %{"membership" => "foo"}) end,
            non_string: fn room -> member_event!(room, user, "x", t + 1, content: %{"membership" => 5}) end,
            missing: fn room -> member_event!(room, user, "x", t + 1, content: %{"displayname" => "x"}) end,
            string_not_json: fn room -> string_form_member_event!(room, user, "this is not json", t + 1) end,
            string_not_object: fn room -> string_form_member_event!(room, user, "[1,2]", t + 1) end
          ] do
        room = room!()
        _older = member_event!(room, user, "join", t)
        bad = writer.(room)

        assert [%{event_id: ^bad, membership: "leave"}, %{membership: "join"}] = events_of([room], user, room), "#{label}: counts as leave and ranks above older events by time"
      end
    end

    test "an unknown membership ranks as leave in a tie: it beats invite and join, a ban beats it" do
      user = user!()
      t = base_ts()

      for {other, winner} <- [{"invite", :unknown}, {"join", :unknown}, {"ban", :other}] do
        room = room!()
        unknown = member_event!(room, user, "foo", t, content: %{"membership" => "foo"}, id: "$zzz" <> T.rand(6))
        known = member_event!(room, user, other, t, id: "$aaa" <> T.rand(6))
        expected = if winner == :unknown, do: unknown, else: known

        assert [%{event_id: ^expected} | _] = events_of([room], user, room), "unknown vs #{other}"
      end
    end

    test "only the user's own member events of the asked rooms: other users, types, NULL state_key, unlisted rooms never" do
      user = user!()
      other = user!()
      room = room!()
      unlisted = room!()
      t = base_ts()

      mine = member_event!(room, user, "join", t)
      member_event!(room, other, "ban", t + 5)
      state_event!(room, "m.room.name", "", %{"name" => "n"}, t + 6)
      message_event!(room, t + 7)
      T.privileged_sql!("INSERT INTO events (event_id, room_id, sender, event_type, content, origin_server_ts, state_key) VALUES ($1, $2, $3, 'm.room.member', $4, $5, NULL)", [event_id("n"), room, user, %{"membership" => "ban"}, t + 8])
      member_event!(unlisted, user, "ban", t + 9)

      map = latest([room], user)
      assert Map.keys(map) == [room], "rooms that were not asked for never appear"
      assert [%{event_id: ^mine}] = map[room]
    end

    test "a room without a member event is absent or empty; an empty room list is {:ok, %{}} without a statement" do
      user = user!()
      room = room!()
      assert Map.get(latest([room], user), room, []) == []

      {result, statements} = capture_statements(fn -> db(:latest_member_events, [[], user]) end)
      assert {:ok, map} = result
      assert map == %{}
      assert statements == [], "no round trip for an empty list"
    end

    test "300 candidate rooms are answered by ONE statement (and each room still gets its own two events)" do
      user = user!()
      tag = "mpb#{T.rand(5)}"
      t = base_ts()

      T.privileged_sql!("INSERT INTO rooms (room_id, visibility, created_at) SELECT '!#{tag}-' || n || ':#{@server}', 'private', $1 FROM generate_series(1, 300) n", [t])

      T.privileged_sql!(
        "INSERT INTO events (event_id, room_id, sender, event_type, content, origin_server_ts, state_key) " <>
          "SELECT '$#{tag}-' || n || '-' || k, '!#{tag}-' || n || ':#{@server}', $1::text, 'm.room.member', jsonb_build_object('membership', CASE WHEN k = 1 THEN 'join' ELSE 'leave' END), $2::bigint + k, $1::text " <>
          "FROM generate_series(1, 300) n, generate_series(1, 3) k",
        [user, t]
      )

      rooms = for n <- 1..300, do: "!#{tag}-#{n}:#{@server}"

      {result, statements} = capture_statements(fn -> db(:latest_member_events, [rooms, user]) end)

      assert {:ok, map} = result
      assert map_size(map) == 300
      assert Enum.all?(map, fn {_room, events} -> match?([%{membership: "leave"}, %{membership: "leave"}], events) end), "k = 3 and k = 2 are the newest two (both leave)"
      assert length(statements) == 1, "exactly ONE statement for the whole call, got #{length(statements)}"
    end
  end

  # ═══ AC1 (c): the stripped state batch ═══════════════════════════════════════════

  describe "AC1 (c) - invite_state_events/1" do
    test "the seven types in order, four string keys each; the LATEST of a slot, the FIRST create event" do
      room = room!()
      t = base_ts()
      creator = "@creator:#{@server}"

      state_event!(room, "m.room.create", "", %{"creator" => creator, "room_version" => "10", "marker" => "first"}, t)
      state_event!(room, "m.room.create", "", %{"creator" => creator, "room_version" => "10", "marker" => "second"}, t + 1)
      state_event!(room, "m.room.name", "", %{"name" => "old"}, t + 2)
      state_event!(room, "m.room.name", "", %{"name" => "new"}, t + 9)
      state_event!(room, "m.room.topic", "", %{"topic" => "t"}, t + 3)
      state_event!(room, "m.room.avatar", "", %{"url" => "mxc://x/y"}, t + 4)
      state_event!(room, "m.room.join_rules", "", %{"join_rule" => "invite"}, t + 5)
      state_event!(room, "m.room.canonical_alias", "", %{"alias" => "#a:#{@server}"}, t + 6)
      state_event!(room, "m.room.encryption", "", %{"algorithm" => "m.megolm.v1.aes-sha2"}, t + 7)
      # everything else is NOT stripped state of an invite
      state_event!(room, "m.room.power_levels", "", %{"users" => %{}}, t + 8)
      state_event!(room, "m.room.history_visibility", "", %{"history_visibility" => "invited"}, t + 8)
      state_event!(room, "m.room.guest_access", "", %{"guest_access" => "can_join"}, t + 8)
      state_event!(room, "m.room.name", "not-empty-key", %{"name" => "other slot"}, t + 10)
      member_event!(room, creator, "join", t + 11)
      message_event!(room, t + 12)

      assert {:ok, map} = db(:invite_state_events, [[room]])
      events = Map.fetch!(map, room)

      assert Enum.map(events, & &1["type"]) == ~w(m.room.create m.room.name m.room.avatar m.room.topic m.room.canonical_alias m.room.join_rules m.room.encryption)
      assert Enum.all?(events, &(Enum.sort(Map.keys(&1)) == ["content", "sender", "state_key", "type"])), "exactly the four stripped keys, got #{inspect(Enum.map(events, &Map.keys/1))}"
      assert Enum.all?(events, &(&1["state_key"] == "" and &1["sender"] == creator))

      by_type = Map.new(events, &{&1["type"], &1["content"]})
      assert by_type["m.room.create"]["marker"] == "first", "the room's FIRST create event"
      assert by_type["m.room.name"] == %{"name" => "new"}, "the LATEST event of the slot"
      assert by_type["m.room.join_rules"] == %{"join_rule" => "invite"}
    end

    test "one statement for several rooms; a room returns only what exists; a room without state is absent or empty" do
      t = base_ts()
      full = room!()
      sparse = room!()
      empty = room!()
      state_event!(full, "m.room.create", "", %{"creator" => "@c:#{@server}"}, t)
      state_event!(full, "m.room.name", "", %{"name" => "n"}, t + 1)
      state_event!(sparse, "m.room.join_rules", "", %{"join_rule" => "invite"}, t)

      {result, statements} = capture_statements(fn -> db(:invite_state_events, [[full, sparse, empty]]) end)

      assert {:ok, map} = result
      assert Enum.map(map[full], & &1["type"]) == ["m.room.create", "m.room.name"]
      assert Enum.map(map[sparse], & &1["type"]) == ["m.room.join_rules"], "no create event: the caller synthesizes it (D4), the read never invents one"
      assert Map.get(map, empty, []) == []
      assert length(statements) == 1
    end

    test "content stored as a double-encoded JSONB string decodes to a map (both forms)" do
      room = room!()
      t = base_ts()

      T.privileged_sql!(
        "INSERT INTO events (event_id, room_id, sender, event_type, content, origin_server_ts, state_key) VALUES ($1, $2, '@c:#{@server}', 'm.room.join_rules', to_jsonb($3::text), $4, '')",
        [event_id("s"), room, Jason.encode!(%{"join_rule" => "invite"}), t]
      )

      assert {:ok, %{^room => [%{"type" => "m.room.join_rules", "content" => %{"join_rule" => "invite"}}]}} = db(:invite_state_events, [[room]])
    end
  end

  # ═══ AC1 (d): the leave window read ══════════════════════════════════════════════

  # DELIBERATE amendment by story sync-stream-position (D10), old -> new: `leave_window_events/3` (timestamps) became `leave_window_events/5` (room, after_pos, before_pos,
  # after_ts, before_ts): the window is bounded by room POSITIONS and, as an extra restriction that can only shrink it, by the member row's clocks. These tests keep their
  # facts through the CLOCK bounds (positions wide open: `0` .. `@max_pos`); the position bounds, the 21st row and the order by position are pinned by
  # `room/sync_positions_db_test.exs`. The order is by position (insert order) now: the second sort key `event_id DESC` is gone, and the window answers the newest 21 rows (the caller
  # keeps 20 and reads the 21st as `limited`).
  @max_pos 9_223_372_036_854_775_807
  defp window(room, lo, hi), do: db(:leave_window_events, [room, 0, @max_pos, lo, hi])

  describe "AC1 (d) - leave_window_events/5 (clock bounds, positions open)" do
    test "an event exactly at the lower or the upper bound is NOT returned; the ones strictly between are, newest first" do
      room = room!()
      other_room = room!()
      lo = base_ts()
      hi = lo + 100

      at_lo = message_event!(room, lo)
      inside_a = message_event!(room, lo + 1)
      inside_b = message_event!(room, hi - 1)
      at_hi = message_event!(room, hi)
      after_hi = message_event!(room, hi + 1)
      foreign = message_event!(other_room, lo + 50)

      assert {:ok, events} = window(room, lo, hi)
      ids = Enum.map(events, & &1["event_id"])

      assert ids == [inside_b, inside_a]
      for excluded <- [at_lo, at_hi, after_hi, foreign], do: refute(excluded in ids)
    end

    test "more than 20 events in the window: the NEWEST 21 come back, newest first (the caller keeps 20: a 21st row means limited)" do
      room = room!()
      lo = base_ts()
      ids = for n <- 1..25, do: {n, message_event!(room, lo + n)}

      assert {:ok, events} = window(room, lo, lo + 1000)
      assert length(events) == 21
      assert Enum.map(events, & &1["event_id"]) == for({n, id} <- Enum.reverse(ids), n >= 5, do: id)
    end

    test "same timestamp: the POSITION (insert order) decides, event_id is no sort key any more; the rows have the fetch_events_since columns" do
      room = room!()
      lo = base_ts()
      # the id order is the OPPOSITE of the insert order: event_id DESC would answer [member, large, small]
      large = message_event!(room, lo + 5, id: "$zzz" <> T.rand(6))
      small = message_event!(room, lo + 5, id: "$aaa" <> T.rand(6))
      member = member_event!(room, "@m:#{@server}", "join", lo + 6)

      assert {:ok, events} = window(room, lo, lo + 100)
      assert Enum.map(events, & &1["event_id"]) == [member, small, large]
      for column <- ~w(content event_id event_type origin_server_ts room_id sender state_key), do: assert(Map.has_key?(hd(events), column), "the column #{column}")
      assert hd(events)["event_type"] == "m.room.member" and hd(events)["state_key"] == "@m:#{@server}"
    end

    test "an empty window is {:ok, []}" do
      room = room!()
      lo = base_ts()
      message_event!(room, lo)
      assert {:ok, []} = window(room, lo, lo + 1)
    end
  end

  # ═══ D13: the join decision reads ═══════════════════════════════════════════════

  describe "D13 - latest_member_event/2, pending_invitation/2" do
    test "latest_member_event/2: the D3 order, {:ok, nil} without a member event, normalised membership" do
      room = room!()
      user = user!()
      other = "@kicker:#{@server}"
      t = base_ts()

      assert {:ok, nil} = db(:latest_member_event, [room, user])

      member_event!(room, user, "join", t)
      assert {:ok, %{membership: "join", origin_server_ts: ^t, sender: ^user}} = db(:latest_member_event, [room, user])

      member_event!(room, user, "leave", t + 5, sender: other)
      assert {:ok, %{membership: "leave", origin_server_ts: ts, sender: ^other}} = db(:latest_member_event, [room, user])
      assert ts == t + 5

      # a ban in the same millisecond as a join: the ban
      tie_room = room!()
      member_event!(tie_room, user, "join", t, id: "$zzz" <> T.rand(6))
      member_event!(tie_room, user, "ban", t, id: "$aaa" <> T.rand(6), sender: other)
      assert {:ok, %{membership: "ban", sender: ^other}} = db(:latest_member_event, [tie_room, user])

      # unknown / unparseable counts as leave and never raises
      bad_room = room!()
      member_event!(bad_room, user, "foo", t, content: %{"membership" => "foo"})
      assert {:ok, %{membership: "leave"}} = db(:latest_member_event, [bad_room, user])
      bad_string = room!()
      string_form_member_event!(bad_string, user, "not json at all", t)
      assert {:ok, %{membership: "leave"}} = db(:latest_member_event, [bad_string, user])
    end

    test "latest_member_event/2 reads the double-encoded string form too" do
      room = room!()
      user = user!()
      string_form_member_event!(room, user, %{"membership" => "invite"}, base_ts(), sender: "@a:#{@server}")
      assert {:ok, %{membership: "invite", sender: "@a:" <> _}} = db(:latest_member_event, [room, user])
    end

    test "pending_invitation/2: invited_at for a PENDING row, nil for none / accepted / rejected / another invitee" do
      room = room!()
      me = user!()
      other = user!()
      inviter = user!()

      assert {:ok, nil} = pending_invitation(room, me)

      assert :ok = InviteDB.insert_invitation(room, inviter, me)
      row = invitation_row(room, me)
      assert {:ok, invited_at} = pending_invitation(room, me)
      assert invited_at == row.invited_at and is_integer(invited_at)
      assert {:ok, nil} = pending_invitation(room, other), "another invitee's row is not mine"

      assert :ok = InviteDB.accept_invitation(room, me)
      assert {:ok, nil} = pending_invitation(room, me)

      assert :ok = InviteDB.insert_invitation(room, inviter, me)
      assert {:ok, ts_rearmed} = pending_invitation(room, me)
      assert ts_rearmed >= invited_at
      assert :ok = InviteDB.reject_invitation(room, me)
      assert {:ok, nil} = pending_invitation(room, me)
    end
  end

  # ═══ D3: get_member_membership/2 ════════════════════════════════════════════════

  describe "D3 - get_member_membership/2 tie order" do
    test "a same-millisecond join + ban answers ban (join decision, Room.Server ban check, invite path), in either insertion order" do
      user = user!()

      # ten rooms, both insertion orders and both event-id orders: an arbitrary tie pick would be wrong in some of them
      for n <- 1..10 do
        room = room!()
        t = base_ts()
        join_id = if rem(n, 2) == 0, do: "$aaa", else: "$zzz"
        ban_id = if rem(n, 3) == 0, do: "$zzz", else: "$aaa"

        if rem(n, 4) < 2 do
          member_event!(room, user, "join", t, id: join_id <> T.rand(6))
          member_event!(room, user, "ban", t, id: ban_id <> T.rand(6))
        else
          member_event!(room, user, "ban", t, id: ban_id <> T.rand(6))
          member_event!(room, user, "join", t, id: join_id <> T.rand(6))
        end

        assert {:ok, "ban"} = DB.get_member_membership(room, user), "room #{n}"
      end
    end

    test "same-millisecond invite + leave and join + leave answer leave; the later timestamp still beats the rank" do
      user = user!()
      t = base_ts()

      for {a, b, expected} <- [{"invite", "leave", "leave"}, {"join", "leave", "leave"}, {"join", "invite", "invite"}] do
        room = room!()
        member_event!(room, user, a, t, id: "$zzz" <> T.rand(6))
        member_event!(room, user, b, t, id: "$aaa" <> T.rand(6))
        assert {:ok, ^expected} = DB.get_member_membership(room, user), "#{a} + #{b} in one millisecond"
      end

      room = room!()
      member_event!(room, user, "ban", t)
      member_event!(room, user, "join", t + 1)
      assert {:ok, "join"} = DB.get_member_membership(room, user)
    end
  end

  describe "review cycle 1 (MINOR-2) - get_member_membership/2 is NORMALISED like latest_member_events/2" do
    test "an unknown, non-string, missing or unparseable membership of the latest event is \"leave\", never nil; nil only without any member event" do
      user = user!()
      t = base_ts()

      cases = [
        {"unknown string", fn room -> member_event!(room, user, "bogus", t) end},
        {"non-string value", fn room -> member_event!(room, user, nil, t, content: %{"membership" => 5}) end},
        {"missing key", fn room -> member_event!(room, user, nil, t, content: %{"displayname" => "x"}) end},
        {"unparseable string form", fn room -> string_form_member_event!(room, user, "this is {not json", t) end}
      ]

      for {label, write} <- cases do
        room = room!()
        write.(room)
        assert {:ok, "leave"} = DB.get_member_membership(room, user), label
        assert {:ok, %{membership: "leave"}} = DB.latest_member_event(room, user), "#{label}: both readers agree"
      end

      assert {:ok, nil} = DB.get_member_membership(room!(), user), "nil means: never had a member event"
    end

    test "an unparseable LATEST event hides an older join (the corrupt row is not read as no ban / never a member)" do
      user = user!()
      room = room!()
      t = base_ts()
      member_event!(room, user, "join", t)
      string_form_member_event!(room, user, "{broken", t + 5)

      assert {:ok, "leave"} = DB.get_member_membership(room, user)
    end
  end

  # ═══ review cycle 1 (MINOR-4 / Kassandra L-3): the inviters' member events in ONE statement ═══

  describe "review cycle 1 - inviter_member_events/1 (optional batched read)" do
    test "the newest event of each (room, user) pair in ONE statement; normalised, tie order, both JSONB forms; absent pairs missing; [] without a statement" do
      a = user!()
      b = user!()
      room1 = room!()
      room2 = room!()
      room3 = room!()
      t = base_ts()

      member_event!(room1, a, "join", t)
      member_event!(room1, a, "leave", t + 10)
      member_event!(room2, a, "join", t)
      member_event!(room2, a, "ban", t)
      string_form_member_event!(room2, b, %{"membership" => "join", "is_direct" => true}, t + 1)
      # room3: nothing for a

      {result, statements} =
        capture_statements(fn -> db(:inviter_member_events, [[{room1, a}, {room2, a}, {room2, b}, {room3, a}]]) end)

      assert {:ok, map} = result
      assert length(statements) == 1, "ONE statement for all pairs, got #{length(statements)}"
      assert map[{room1, a}].membership == "leave" and map[{room1, a}].origin_server_ts == t + 10
      assert map[{room2, a}].membership == "ban", "same millisecond: the most restrictive is the latest"
      assert map[{room2, b}].content == %{"membership" => "join", "is_direct" => true}
      assert map[{room2, b}].sender == b
      refute Map.has_key?(map, {room3, a})
      assert {:ok, %{}} == db(:inviter_member_events, [[]])

      {sql, params} = hd(statements)
      assert seq_scans_on(plan_nodes(sql, params), "events") == [], "no Seq Scan of events"
    end

    test "300 pairs are answered by ONE statement (the invite-spam N+1 of the initial sync is gone)" do
      a = user!()
      rooms = for _ <- 1..300, do: room!()
      t = base_ts()
      for room <- rooms, do: member_event!(room, a, "join", t)

      {result, statements} = capture_statements(fn -> db(:inviter_member_events, [Enum.map(rooms, &{&1, a})]) end)
      assert {:ok, map} = result
      assert map_size(map) == 300
      assert length(statements) == 1
    end
  end

  # ═══ D2: the reads are served by the existing indexes (no migration) ═════════════

  describe "D2 - EXPLAIN of the partition reads" do
    test "with sequential scans disabled no Seq Scan survives in any of the four reads (an existing index serves each)" do
      user = user!()
      inviter = user!()
      room = room!()
      t = base_ts()
      join!(room, user)
      assert :ok = InviteDB.insert_invitation(room, inviter, user)
      member_event!(room, user, "join", t)
      state_event!(room, "m.room.create", "", %{"creator" => inviter}, t - 1)
      message_event!(room, t + 1)

      {_, candidate_statements} = capture_statements(fn -> assert {:ok, _} = db(:membership_candidates, [user]) end)
      {_, latest_statements} = capture_statements(fn -> assert {:ok, _} = db(:latest_member_events, [[room], user]) end)
      {_, state_statements} = capture_statements(fn -> assert {:ok, _} = db(:invite_state_events, [[room]]) end)
      {_, window_statements} = capture_statements(fn -> assert {:ok, _} = window(room, t - 5, t + 5) end)

      for {label, statements, tables} <- [
            {"membership_candidates", candidate_statements, ["room_members", "room_invitations"]},
            {"latest_member_events", latest_statements, ["events"]},
            {"invite_state_events", state_statements, ["events"]},
            {"leave_window_events", window_statements, ["events"]}
          ] do
        assert statements != [], "#{label} sent no statement through Nebu.Repo"

        if label == "latest_member_events" do
          for {sql, params} <- statements do
            index_names = for node <- plan_nodes(sql, params), name = node["Index Name"], do: name
            assert "events_room_state_idx" in index_names, "latest_member_events is served by events_room_state_idx, plan uses #{inspect(index_names)}"
          end
        end

        for {sql, params} <- statements, table <- tables do
          assert seq_scans_on(plan_nodes(sql, params), table) == [],
                 "#{label}: a Seq Scan of #{table} even with enable_seqscan off: no index can serve the predicate (rewrite it so that the existing index applies; no migration)\n#{sql}"
        end
      end
    end
  end
end
