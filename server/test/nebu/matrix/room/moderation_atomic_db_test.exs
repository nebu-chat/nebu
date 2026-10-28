defmodule Nebu.Matrix.Room.ModerationAtomicDbTest do
  @moduledoc """
  Story `moderation-routes-atomic-ban`, REAL database, `Room.Server` and `Room.DB` directly: AC5 (a), (d) (one transaction, nothing half done),
  AC6 (the BINDING gate test of `ex` L-1 and the stamp rule), AC9 (the decline writer) and AC15 (crash / restart). `async: false`.

  ## Decisions of the ATDD step (ambiguities of the story)

    * The failing write INSIDE the transaction (AC5 (a)) is a real database failure, not a fake: a `BEFORE INSERT` trigger on `events` that raises for ONE
      room (created through the privileged connection like `OAuthTestSupport.block_deletes!/..`, dropped in `on_exit`). The member delete and the
      invitation reject have then really run inside the transaction when the insert fails, so a surviving active row / pending invitation proves the
      rollback. The story's alternative (pre-inserting the identical event) would leave a stray event row behind.
    * `Room.DB.apply_member_change/4` and `Room.Server.moderate/5` are reached through `apply/3` with a variable name, so the file compiles before the
      functions exist (CI compiles with `--warnings-as-errors`); the shapes pinned are the ones the story names: `apply_member_change(room, user,
      signed_event | nil, remove_member: bool, reject_invitation: bool)` -> `:ok | {:error, reason}`, `moderate(room, action, sender, target, reason)`
      -> `:ok` or `{:ok, _}` on success, `{:error, atom}` otherwise.
    * AC15 "killed DURING a moderation call": the db hook kills the room process right BEFORE the transaction runs (the hook cannot reach into the
      transaction); the call answers 503, the database is exactly as before and a restarted process reloads that state.
    * AC6 (a): the invite event 100 ms ahead of the clock is written directly (a member event of the owner for the target) together with a row-only
      pending invitation; every event of the room is deleted in `on_exit` (follow-up `fj`).
    * AC6 (c) is a property over a long sequence without any clock wait: after each step the new event of the slot is recorded; at the end the slot sorted
      by `(origin_server_ts, event_id)` has no tie and equals the write order.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Nebu.Matrix.ModerationTestSupport

  alias Nebu.Matrix.ModerationTestSupport.Gap
  alias Nebu.Matrix.Room.DB
  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration

  setup do
    T.reset_rate_limits()
    Nebu.Test.ServerName.pin!(T.server_name())
    seams = for {app, key} <- [compliance: :audit_writer, room_manager: :db_module], do: {app, key, Application.fetch_env(app, key)}

    # config/test.exs runs a NoOp audit writer: these audit assertions need the real one. The PRIOR value was snapshotted above and is restored.
    Application.put_env(:compliance, :audit_writer, Nebu.Compliance.AuditWriter)

    on_exit(fn ->
      T.restore_rate_limits()

      for {app, key, previous} <- seams do
        case previous do
          {:ok, value} -> Application.put_env(app, key, value)
          :error -> Application.delete_env(app, key)
        end
      end
    end)

    {:ok, a: user!("MAA"), b: user!("MAB"), c: user!("MAC")}
  end

  # ─── helpers ─────────────────────────────────────────────────────────────────

  # a function that may not exist yet: never a compile warning
  defp call(mod, fun, args), do: apply(mod, fun, args)

  defp moderate(room, action, sender, target, reason), do: call(Nebu.Matrix.Room.Server, :moderate, [room, action, uid_of(sender), uid_of(target), reason])

  defp moderated_ok?(:ok), do: true
  defp moderated_ok?(_), do: false

  # an INSERT trigger on `events` that raises for ONE room: the insert of every event of the room fails (dropped in on_exit)
  defp block_events!(room) do
    name = "atdd_mod_block_" <> T.rand(5)

    T.privileged_sql!(
      "CREATE FUNCTION #{name}() RETURNS trigger AS $$ BEGIN IF NEW.room_id = '#{room}' THEN RAISE EXCEPTION 'atdd: insert blocked'; END IF; RETURN NEW; END $$ LANGUAGE plpgsql"
    )

    T.privileged_sql!("CREATE TRIGGER #{name} BEFORE INSERT ON events FOR EACH ROW EXECUTE FUNCTION #{name}()")

    remove = fn ->
      T.privileged_sql!("DROP TRIGGER IF EXISTS #{name} ON events")
      T.privileged_sql!("DROP FUNCTION IF EXISTS #{name}()")
    end

    on_exit(remove)
    remove
  end

  # a signed-looking leave event as the room process would build it (the transaction only inserts it)
  defp leave_event(room, sender, target, ts) do
    %{
      "event_id" => "$" <> T.rand(16),
      "room_id" => room,
      "sender" => uid_of(sender),
      "type" => "m.room.member",
      "state_key" => uid_of(target),
      "content" => %{"membership" => "leave"},
      "origin_server_ts" => ts,
      "signatures" => %{"nebu" => Base.encode64(:crypto.strong_rand_bytes(64))}
    }
  end

  # a member with a pending invitation row (a legacy half state a transaction has to close)
  defp member_with_pending_row(a, b) do
    room = public_room(a)
    join!(b, room)
    row_only_invitation!(room, a, b)
    assert active_row?(room, b.uid) and invitation_state(room, b.uid) == :pending
    room
  end

  # ═══ AC5 (a): one transaction ═══════════════════════════════════════════════════

  describe "AC5 (a) - Room.DB.apply_member_change/4 is ONE transaction" do
    test "healthy: the member row is closed, the pending invitation rejected and the event inserted together (positive control)", %{a: a, b: b} do
      room = member_with_pending_row(a, b)
      event = leave_event(room, a, b, ts_after(room))

      assert :ok = call(DB, :apply_member_change, [room, b.uid, event, [remove_member: true, reject_invitation: true]])

      refute active_row?(room, b.uid)
      assert invitation_state(room, b.uid) == :rejected
      assert Enum.any?(member_events(room, b.uid), &(&1.event_id == event["event_id"]))
    end

    test "an event insert that fails INSIDE the transaction rolls back the member delete and the reject: the row stays active, the invitation pending, no event exists", %{a: a, b: b} do
      room = member_with_pending_row(a, b)
      events_before = event_count(room)
      event = leave_event(room, a, b, ts_after(room))
      remove = block_events!(room)

      assert {:error, _reason} = call(DB, :apply_member_change, [room, b.uid, event, [remove_member: true, reject_invitation: true]])

      assert active_row?(room, b.uid), "the soft delete was rolled back"
      assert invitation_state(room, b.uid) == :pending, "the reject was rolled back"
      assert event_count(room) == events_before
      assert Enum.filter(member_events(room, b.uid), &(&1.event_id == event["event_id"])) == []

      # a retry once the failure is gone starts from the unchanged state and succeeds
      remove.()
      assert :ok = call(DB, :apply_member_change, [room, b.uid, event, [remove_member: true, reject_invitation: true]])
      refute active_row?(room, b.uid)
      assert invitation_state(room, b.uid) == :rejected
    end

    test "a missing member row is no error (remove_member on a non-member), a nil event writes nothing, the invitation of a non-member is rejected", %{a: a, b: b} do
      room = public_room(a)
      row_only_invitation!(room, a, b)
      events = event_count(room)
      assert :ok = call(DB, :apply_member_change, [room, b.uid, nil, [remove_member: true, reject_invitation: true]])
      assert event_count(room) == events
      assert invitation_state(room, b.uid) == :rejected
    end

    test "the single-flag forms: [reject_invitation: true] leaves the active member row alone, [remove_member: true] leaves the invitation pending", %{a: a, b: b} do
      room = member_with_pending_row(a, b)
      events = event_count(room)

      assert :ok = call(DB, :apply_member_change, [room, b.uid, nil, [reject_invitation: true]])
      assert active_row?(room, b.uid), "reject only: the member row stays active"
      assert invitation_state(room, b.uid) == :rejected

      room2 = member_with_pending_row(a, b)
      assert :ok = call(DB, :apply_member_change, [room2, b.uid, nil, [remove_member: true]])
      refute active_row?(room2, b.uid), "remove only: the member row is closed"
      assert invitation_state(room2, b.uid) == :pending, "remove only: the invitation stays pending"
      assert event_count(room) == events
    end
  end

  describe "AC5 (a) - through the route: a failing write is a 500 and changes, broadcasts, audits and leaks nothing" do
    test "state unchanged, no :pg event, no audit row, the ERROR log names room and error class only, a retry succeeds", %{a: a, b: b} do
      room = member_with_pending_row(a, b)
      reason = marker("secret-reason")
      remove = block_events!(room)
      :pg.join("room:#{room}", self())
      events = event_count(room)

      log =
        capture_log([level: :debug], fn ->
          conn = kick(a, room, b, %{"reason" => reason})
          assert conn.status == 500, "#{conn.status} #{String.slice(conn.resp_body, 0, 160)}"
          assert T.json(conn)["errcode"] == "M_UNKNOWN"
          refute_echo(conn, [b.uid, reason, room])
        end)

      assert in_set?(room, b.uid), "the in-memory state is unchanged"
      assert active_row?(room, b.uid)
      assert invitation_state(room, b.uid) == :pending
      assert event_count(room) == events
      assert audit_rows(room) == []
      refute_receive {:new_event, _}, 200
      assert log =~ room, "the ERROR log names the room"
      assert log =~ "P0", "and the SQLSTATE class of the failure (a PL/pgSQL exception is P0001)"
      refute log =~ b.uid
      refute log =~ reason

      remove.()
      ok!(kick(a, room, b, %{"reason" => reason}), "the retry with the healthy database")
      # positive control of the refute above: the subscription works and the committed kick IS broadcast
      assert_receive {:new_event, %{"type" => "m.room.member", "state_key" => target}}, 2_000
      assert target == b.uid
      :pg.leave("room:#{room}", self())
      refute in_set?(room, b.uid)
      assert length(audit_rows(room)) == 1
    end

    test "the same for a ban and an unban: nothing half done (the member stays joined, no event without removal)", %{a: a, b: b, c: c} do
      room = public_room(a)
      join!(b, room)
      join!(c, room)
      ok!(ban(a, room, c), "setup ban")
      remove = block_events!(room)

      assert ban(a, room, b).status == 500
      assert in_set?(room, b.uid) and active_row?(room, b.uid) and membership(room, b.uid) == "join"
      assert unban(a, room, c).status == 500
      assert membership(room, c.uid) == "ban"
      assert audit_rows(room) |> Enum.map(& &1.action) == ["room_member_banned"], "only the committed setup ban is audited"

      remove.()
      ok!(ban(a, room, b), "retry ban")
      ok!(unban(a, room, c), "retry unban")
    end
  end

  # ═══ AC5 (d): the five sources agree ═════════════════════════════════════════════

  describe "AC5 (d) - after a committed ban the five sources agree" do
    test "in-memory set, room_members, room_invitations, the latest member event (ban) and the target's /sync partition (leave class)", %{a: a, b: b} do
      room = member_with_pending_row(a, b)
      token = snapshot!(b, anchor_room!(b))

      ok!(ban(a, room, b), "ban")

      refute in_set?(room, b.uid)
      refute active_row?(room, b.uid)
      assert invitation_state(room, b.uid) == :rejected
      assert membership(room, b.uid) == "ban"
      assert {:ok, "ban"} = DB.get_member_membership(room, b.uid)
      body = sync(b, token)
      assert in_section?(body, "leave", room)
      refute in_section?(body, "join", room)
    end
  end

  # ═══ AC6: event order, the BINDING gate test of `ex` (L-1) ═══════════════════════

  # an invite-only room whose invitation of `t` is written 250 ms AHEAD of the clock (the createRoom chain in miniature): the row-only pending
  # invitation plus the invite member event; every event of the room is deleted afterwards (fj)
  defp room_with_future_invite(owner, t, ahead_ms \\ 250) do
    room = make_room(owner, %{"preset" => "private_chat"})
    on_exit(fn -> assert {:ok, _} = Ecto.Adapters.SQL.query(Nebu.Repo, "DELETE FROM events WHERE room_id = $1", [room]) end)
    row_only_invitation!(room, owner, t)
    ts = System.system_time(:millisecond) + ahead_ms
    insert_member_event!(room, t, "invite", owner, ts)
    {room, ts}
  end

  describe "AC6 (a) - the gate test: invite 250 ms ahead, the target joins, the moderator bans AT ONCE" do
    test "the ban is newer than the join, the latest membership is ban for every reader, the re-join is 403 \"You are banned from this room\"", %{a: a, b: b} do
      {room, invite_ts} = room_with_future_invite(a, b)

      join_conn = join(b, room)
      assert join_conn.status == 200, "#{join_conn.status} #{String.slice(join_conn.resp_body, 0, 160)}"
      ok!(ban(a, room, b), "ban at once")

      [invite_ev, join_ev, ban_ev] = member_events(room, b.uid)
      assert {invite_ev.content["membership"], join_ev.content["membership"], ban_ev.content["membership"]} == {"invite", "join", "ban"}
      assert invite_ev.ts == invite_ts
      assert join_ev.ts > invite_ev.ts
      assert ban_ev.ts > join_ev.ts, "the ban is stamped after the join (the old code stamped it at the clock, BEFORE the join)"

      assert {:ok, "ban"} = DB.get_member_membership(room, b.uid)
      assert {:ok, %{membership: "ban"}} = DB.latest_member_event(room, b.uid)
      assert_err(join(b, room), 403, "M_FORBIDDEN", "You are banned from this room")
    end

    test "the sync partition of the target agrees: an incremental sync from before delivers the room as left, never as joined", %{a: a, b: b} do
      token = snapshot!(b, anchor_room!(b))
      {room, _} = room_with_future_invite(a, b)
      assert join(b, room).status == 200
      ok!(ban(a, room, b), "ban at once")
      body = sync(b, token)
      assert in_section?(body, "leave", room)
      refute in_section?(body, "join", room)
    end
  end

  describe "AC6 (b) - the same for kick and for unban after a ban that is itself ahead of the clock" do
    test "kick right after the join: latest membership is leave by the kicker (newer than the join), the re-join of an invite room is 403", %{a: a, b: b} do
      {room, _} = room_with_future_invite(a, b)
      assert join(b, room).status == 200
      ok!(kick(a, room, b), "kick at once")

      [_invite, join_ev, leave_ev] = member_events(room, b.uid)
      assert leave_ev.content["membership"] == "leave" and leave_ev.sender == a.uid
      assert leave_ev.ts > join_ev.ts
      assert membership(room, b.uid) == "leave"
      assert_err(join(b, room), 403, "M_FORBIDDEN", "You are not invited to this room")
    end

    test "unban right after a ban that is ahead: the leave is newer than the ban and is the latest membership", %{a: a, b: b} do
      {room, _} = room_with_future_invite(a, b)
      assert join(b, room).status == 200
      ok!(ban(a, room, b), "ban at once")
      ok!(unban(a, room, b), "unban at once")

      events = member_events(room, b.uid)
      assert Enum.map(events, & &1.content["membership"]) == ["invite", "join", "ban", "leave"]
      assert List.last(events).ts > Enum.at(events, 2).ts
      assert membership(room, b.uid) == "leave"
    end
  end

  describe "AC6 (c) - every member event written by moderate, write_invite and write_decline is at least latest + 1 of the slot" do
    test "a long sequence without clock waits: the slot sorted by (ts, event_id) has no tie and equals the write order", %{a: a, b: b} do
      room = make_room(a, %{"preset" => "private_chat"})

      steps = [
        {"invite", fn -> invite(a, room, b) end},
        {"join", fn -> join(b, room) end},
        {"kick", fn -> kick(a, room, b) end},
        {"invite", fn -> invite(a, room, b) end},
        {"decline", fn -> leave(b, room) end},
        {"invite", fn -> invite(a, room, b) end},
        {"revoke", fn -> kick(a, room, b) end},
        {"ban", fn -> ban(a, room, b) end},
        {"unban", fn -> unban(a, room, b) end},
        {"invite", fn -> invite(a, room, b) end},
        {"join", fn -> join(b, room) end},
        {"ban of a member", fn -> ban(a, room, b) end},
        {"unban", fn -> unban(a, room, b) end}
      ]

      written =
        Enum.reduce(steps, [], fn {label, step}, order ->
          conn = step.()
          assert conn.status == 200, "#{label}: #{conn.status} #{String.slice(conn.resp_body, 0, 160)}"
          new = Enum.reject(member_events(room, b.uid), &(&1.event_id in order))
          assert length(new) == 1, "#{label} wrote #{length(new)} events"
          order ++ Enum.map(new, & &1.event_id)
        end)

      sorted = member_events(room, b.uid)
      assert Enum.map(sorted, & &1.event_id) == written, "the slot in timestamp order is the write order"
      ts = Enum.map(sorted, & &1.ts)
      assert ts == Enum.sort(Enum.uniq(ts)), "no tie"
    end
  end

  # ═══ Room.DB.banned_members/1 and latest_member_event/2 (D11, D2) ═══════════════════════════

  # a member event stored as a JSONB STRING that contains the JSON text (the Postgrex double encoding both readers must understand)
  defp insert_string_form_event!(room, sender, uid, membership, ts) do
    id = "$" <> T.rand(12)
    text = Jason.encode!(%{"membership" => membership})

    T.sql!(
      "INSERT INTO events (event_id, room_id, sender, event_type, content, origin_server_ts, signatures, state_key) VALUES ($1, $2, $3, 'm.room.member', to_jsonb($4::text), $5, '{}'::jsonb, $6)",
      [id, room, uid_of(sender), text, ts, uid_of(uid)]
    )

    id
  end

  defp banned_ids(room) do
    {:ok, list} = call(DB, :banned_members, [room])
    list |> Enum.map(& &1.user_id) |> Enum.sort()
  end

  describe "Room.DB.banned_members/1 (D11): the users whose LATEST member event is a ban, in the D3 tie order, both JSONB forms" do
    test "lists exactly the banned users with the ban's string reason; a later leave or invite lifts the ban", %{a: a, b: b, c: c} do
      room = public_room(a)
      for u <- [b, c], do: join!(u, room)
      ok!(ban(a, room, b, %{"reason" => "spam"}), "ban b")
      ok!(ban(a, room, c), "ban c")

      assert {:ok, list} = call(DB, :banned_members, [room])
      assert Enum.sort_by(list, & &1.user_id) |> Enum.map(&{&1.user_id, &1.reason}) == Enum.sort([{b.uid, "spam"}, {c.uid, nil}])

      ok!(unban(a, room, c), "unban c")
      assert banned_ids(room) == [b.uid], "a later leave lifts the ban"

      insert_member_event!(room, b, "invite", a, ts_after(room))
      assert banned_ids(room) == [], "a later invite lifts the ban"
    end

    test "a ban stored as a JSONB STRING (double encoding) is listed and read as the latest membership with its event_id", %{a: a, b: b} do
      room = public_room(a)
      id = insert_string_form_event!(room, a, b, "ban", ts_after(room))

      assert {:ok, [%{user_id: uid}]} = call(DB, :banned_members, [room])
      assert uid == b.uid
      assert {:ok, %{membership: "ban", event_id: ^id}} = DB.latest_member_event(room, b.uid)
    end

    test "latest_member_event/2 returns the event_id of the latest member event for both JSONB forms", %{a: a, b: b, c: c} do
      room = public_room(a)
      object_id = insert_member_event!(room, b, "invite", a, ts_after(room))
      string_id = insert_string_form_event!(room, a, c, "invite", ts_after(room))

      assert {:ok, %{membership: "invite", event_id: ^object_id}} = DB.latest_member_event(room, b.uid)
      assert {:ok, %{membership: "invite", event_id: ^string_id}} = DB.latest_member_event(room, c.uid)
    end

    test "a ban and a leave with the SAME origin_server_ts: the ban wins (D3), also in the string form", %{a: a, b: b, c: c} do
      room = public_room(a)
      ts = ts_after(room)
      insert_member_event!(room, b, "leave", a, ts)
      insert_member_event!(room, b, "ban", a, ts)
      insert_string_form_event!(room, a, c, "leave", ts)
      insert_string_form_event!(room, a, c, "ban", ts)

      assert banned_ids(room) == Enum.sort([b.uid, c.uid])
      assert {:ok, %{membership: "ban"}} = DB.latest_member_event(room, b.uid)
      assert {:ok, %{membership: "ban"}} = DB.latest_member_event(room, c.uid)
    end
  end

  # ═══ AC9: the decline writer ═════════════════════════════════════════════════════

  describe "AC9 (a) - the decline goes through the room process: the self-leave and the row reject are ONE transaction" do
    test "a pending invitee's POST /leave writes the self-leave (stamped after the invite) and rejects the row", %{a: a, b: b} do
      room = make_room(a, %{"preset" => "private_chat"})
      invite!(a, room, b)
      ok!(leave(b, room), "decline")

      assert [invite_ev, leave_ev] = member_events(room, b.uid)
      assert leave_ev.content == %{"membership" => "leave"} and leave_ev.sender == b.uid
      assert leave_ev.ts > invite_ev.ts
      assert invitation_state(room, b.uid) == :rejected
    end

    test "when the event cannot be written the invitation is NOT rejected (atomic): the decline fails", %{a: a, b: b} do
      room = make_room(a, %{"preset" => "private_chat"})
      invite!(a, room, b)
      remove = block_events!(room)

      conn = leave(b, room)
      assert conn.status == 500, "the decline must not claim success: #{conn.status}"
      assert T.json(conn)["errcode"] == "M_UNKNOWN"
      assert invitation_state(room, b.uid) == :pending, "reject + event are one transaction"
      assert memberships(room, b.uid) == ["invite"]

      remove.()
      ok!(leave(b, room), "the retry")
      assert invitation_state(room, b.uid) == :rejected
    end
  end

  describe "AC9 (b) - the room process is started for a decline that has something to decline" do
    test "with the process STOPPED before the decline: it is started and the decline is written through it", %{a: a, b: b} do
      room = make_room(a, %{"preset" => "private_chat"})
      invite!(a, room, b)
      {:ok, pid} = Nebu.Matrix.Room.RoomSupervisor.lookup_room(room)
      :ok = Horde.DynamicSupervisor.terminate_child(Nebu.Matrix.Room.HordeSupervisor, pid)
      :ok = wait_until(fn -> Nebu.Matrix.Room.RoomSupervisor.lookup_room(room) == {:error, :not_found} end, 2_000)

      ok!(leave(b, room), "decline with the room process stopped")

      assert {:ok, _pid} = Nebu.Matrix.Room.RoomSupervisor.lookup_room(room), "the process was started"
      assert [_invite, leave_ev] = member_events(room, b.uid)
      assert leave_ev.sender == b.uid and leave_ev.content["membership"] == "leave"
      assert invitation_state(room, b.uid) == :rejected
    end

    test "nothing to decline: a stranger's leave of a stopped room and of an unknown room id start no process and create no rooms row", %{a: a, b: b} do
      room = public_room(a)
      {:ok, pid} = Nebu.Matrix.Room.RoomSupervisor.lookup_room(room)
      :ok = Horde.DynamicSupervisor.terminate_child(Nebu.Matrix.Room.HordeSupervisor, pid)
      :ok = wait_until(fn -> Nebu.Matrix.Room.RoomSupervisor.lookup_room(room) == {:error, :not_found} end, 2_000)
      unknown = "!" <> T.rand(8) <> ":" <> T.server_name()
      events = event_count(room)

      # the status of a leave with nothing to leave is not defined by the story (200 / 403 / 404 are all existing behaviours): only the side effects are pinned
      assert leave(b, room).status in [200, 403, 404]
      assert Nebu.Matrix.Room.RoomSupervisor.lookup_room(room) == {:error, :not_found}, "nothing to decline: no process is started"
      assert event_count(room) == events

      assert leave(b, unknown).status in [200, 403, 404]
      assert Nebu.Matrix.Room.RoomSupervisor.lookup_room(unknown) == {:error, :not_found}
      assert rooms_row_count(unknown) == 0
    end
  end

  describe "AC9 (c) - a ban committed between the leave decision and the write (deterministic gap)" do
    setup do
      Gap.install!()
      :ok
    end

    test "the decline is 403 \"You are banned from this room\" and NO leave event is written", %{a: a, b: b} do
      room = make_room(a, %{"preset" => "private_chat"})
      invite!(a, room, b)
      Gap.arm(:delete_member, room, b.uid, self())

      task =
        Task.async(fn ->
          Process.put(:atdd_gap_victim, true)
          leave(b, room)
        end)

      assert_receive {:gap, victim, :delete_member}, 10_000, "the leave never reached the write"
      ok!(ban(a, room, b), "ban inside the gap")
      send(victim, :go)

      conn = Task.await(task, 20_000)
      assert_err(conn, 403, "M_FORBIDDEN", "You are banned from this room")
      assert memberships(room, b.uid) == ["invite", "ban"], "no self-leave newer than the ban"
      assert membership(room, b.uid) == "ban"
    end
  end

  describe "AC9 (d) - an archived room keeps the out-of-process decline (pinned)" do
    test "the process cannot start for an archived room: the decline is still written and the invitation rejected", %{a: a, b: b} do
      room = make_room(a, %{"preset" => "private_chat"})
      invite!(a, room, b)
      assert :ok = Nebu.Admin.DB.archive_room_atomic(room)
      {:ok, pid} = Nebu.Matrix.Room.RoomSupervisor.lookup_room(room)
      :ok = Horde.DynamicSupervisor.terminate_child(Nebu.Matrix.Room.HordeSupervisor, pid)
      :ok = wait_until(fn -> Nebu.Matrix.Room.RoomSupervisor.lookup_room(room) == {:error, :not_found} end, 2_000)

      ok!(leave(b, room), "decline in an archived room")

      assert [invite_ev, leave_ev] = member_events(room, b.uid)
      assert leave_ev.sender == b.uid and leave_ev.ts > invite_ev.ts
      assert invitation_state(room, b.uid) == :rejected
      assert Nebu.Matrix.Room.RoomSupervisor.lookup_room(room) == {:error, :not_found}, "an archived room is not started"
    end
  end

  # ═══ AC11 (backstop) ════════════════════════════════════════════════════════════

  describe "AC11 - the size backstop on the real room process" do
    test "moderate/5 called directly with a 70 000-byte reason is {:error, :event_too_large}: nothing written, the member stays", %{a: a, b: b} do
      room = public_room(a)
      join!(b, room)
      before = footprint(room, b.uid)

      for action <- [:kick, :ban] do
        assert {:error, :event_too_large} = moderate(room, action, a, b, String.duplicate("r", 70_000))
      end

      assert footprint(room, b.uid) == before
    end

    test "an unban through moderate/5 carries the reason on the leave event", %{a: a, b: b} do
      room = public_room(a)
      join!(b, room)
      ok!(ban(a, room, b), "ban")
      assert moderated_ok?(moderate(room, :unban, a, b, "welcome back"))
      assert List.last(member_events(room, b.uid)).content == %{"membership" => "leave", "reason" => "welcome back"}
    end

    test "the dispatcher maps the oversize to 413 M_TOO_LARGE", %{a: a, b: b} do
      room = public_room(a)
      join!(b, room)
      req = %Core.BanUserRequest{room_id: room, caller_id: a.uid, target_id: b.uid, reason: String.duplicate("r", 70_000)}

      assert {:error, {413, "M_TOO_LARGE", _text}} =
               Nebu.Matrix.Http.call_core(fn -> Nebu.Matrix.EventDispatcher.Server.ban_user(req, Nebu.Matrix.Http.stream(a.uid)) end)

      assert membership(room, b.uid) == "join"
    end
  end

  # ═══ AC15: crash / restart ═══════════════════════════════════════════════════════

  describe "AC15 - crash / restart (the Room-State convention)" do
    test "after a committed ban and kick the killed room process restarts: members exclude both, the ban is enforced, the invitation stays rejected", %{a: a, b: b, c: c} do
      room = public_room(a)
      join!(b, room)
      join!(c, room)
      row_only_invitation!(room, a, c)
      ok!(ban(a, room, b), "ban")
      ok!(kick(a, room, c), "kick")

      kill_and_restart!(room)

      members = Nebu.Matrix.Room.Server.get_state(room).members
      assert MapSet.member?(members, a.uid)
      refute MapSet.member?(members, b.uid)
      refute MapSet.member?(members, c.uid)
      assert_err(join(b, room), 403, "M_FORBIDDEN", "You are banned from this room")
      assert invitation_state(room, c.uid) == :rejected
      assert membership(room, c.uid) == "leave"
    end

    test "a process killed DURING a moderation call (before the transaction commits) leaves the database exactly as before and the restart reloads it", %{a: a, b: b} do
      room = member_with_pending_row(a, b)
      db_state = fn -> {event_count(room), member_events(room, b.uid), active_row?(room, b.uid), invitation_state(room, b.uid)} end
      before = db_state.()

      Application.put_env(:nebu, :atdd_mod_kill_room, room)
      on_exit(fn -> Application.delete_env(:nebu, :atdd_mod_kill_room) end)
      Application.put_env(:room_manager, :db_module, Nebu.Matrix.Room.ModerationAtomicDbTest.KillingDB)

      conn = kick(a, room, b)
      assert conn.status == 503, "#{conn.status} #{String.slice(conn.resp_body, 0, 160)}"
      assert T.json(conn)["errcode"] == "M_UNAVAILABLE"
      assert db_state.() == before, "nothing was committed"
      assert audit_rows(room) == []

      Application.delete_env(:nebu, :atdd_mod_kill_room)
      Application.put_env(:room_manager, :db_module, DB)
      {:ok, _pid} = Nebu.Matrix.Room.RoomSupervisor.start_room(room)
      assert in_set?(room, b.uid), "the restarted process reloads the unchanged member set"
      ok!(kick(a, room, b), "the retry after the restart")
      assert invitation_state(room, b.uid) == :rejected
    end
  end

  defmodule KillingDB do
    @moduledoc false
    alias Nebu.Matrix.Room.DB

    for {name, arity} <- DB.__info__(:functions), name != :apply_member_change do
      args = Macro.generate_arguments(arity, __MODULE__)
      def unquote(name)(unquote_splicing(args)), do: apply(DB, unquote(name), unquote(args))
    end

    def apply_member_change(room, user, event, opts) do
      if Application.get_env(:nebu, :atdd_mod_kill_room) == room, do: Process.exit(self(), :kill)
      apply(DB, :apply_member_change, [room, user, event, opts])
    end
  end
end
