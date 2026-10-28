defmodule Nebu.Matrix.MembershipStateUpgradeHttpTest do
  @moduledoc """
  Story `membership-state-model` (follow-up `fb`, the upgrade part), AC6 and the Oracle tests AC16 (b), (e), (f), (g): `POST /rooms/{roomId}/upgrade` writes REAL
  invite events (sender = the upgrader, `state_key` = the old member, `is_direct` carried from the invitee's own invite in the old room) next to the invitation
  rows, through the room-process invite writer of the new room; a failing write of one member's event rejects that member's row again and the upgrade goes on.
  Real stack (`Nebu.Web.Router` + `Plug.Test`, real `Nebu.Repo`, real `Room.Server` under Horde). `async: false`.

  ## Decisions of the ATDD step (ambiguities of the story)

    * AC6 (d): the failing write of B's invite event is injected through the room process' db module (`:room_manager, :db_module`, `InviteRoomDB`: the
      `apply_member_change/4` of an invite write for B fails); "ONE WARNING" counts the `[warning]` lines that name the new room id (the room process' own
      ERROR line is not a warning).
    * AC6 (e): `Room.DB.direct_invitees/1` is reached through `rooms_db_module()` (`DirectDB`), next to `banned_members/1`.
    * AC6 (f): the wake is checked through a `:pg` member of the group `"user:<id>"` of the test process; the event must exist when the wake arrives.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Nebu.Matrix.ModerationTestSupport
  import Nebu.Matrix.MembershipStateTestSupport
  import Nebu.Matrix.PowerLevelsTestSupport, only: [install_env!: 3, install_room_db!: 1, upgrade_audit: 1]
  import Nebu.Matrix.RedactionTestSupport, only: [running?: 1, room_status: 1]

  alias Nebu.Matrix.MembershipStateTestSupport.Hooks
  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration

  @invite %{"membership" => "invite"}
  @direct_invite %{"membership" => "invite", "is_direct" => true}

  setup do
    setup_env!()
    on_exit(&Hooks.disarm_all/0)
    {:ok, a: user!("MUA"), b: user!("MUB"), c: user!("MUC"), d: user!("MUD")}
  end

  defp upgrade(user, room), do: T.matrix_request(:post, path(room, "upgrade"), user.at, body: %{"new_version" => "10"})

  defp upgrade!(user, room) do
    conn = upgrade(user, room)
    assert conn.status == 200, "upgrade: #{conn.status} #{String.slice(conn.resp_body, 0, 200)}"
    T.json(conn)["replacement_room"]
  end

  defp invite_events(room, uid), do: room |> member_events(uid) |> Enum.filter(&(&1.content["membership"] == "invite"))

  defp put_account_data!(user, type, content) do
    conn = T.matrix_request(:put, "/_matrix/client/v3/user/#{enc(user.uid)}/account_data/#{type}", user.at, body: content)
    assert conn.status == 200, "account data #{type}: #{conn.status}"
  end

  defp element_dm(partner_uid) do
    %{
      "preset" => "trusted_private_chat",
      "visibility" => "private",
      "invite" => [partner_uid],
      "is_direct" => true
    }
  end

  # a public room: A (creator), B and C joined, D joined and banned
  defp public_with_ban!(a, b, c, d) do
    room = public_room(a)
    for u <- [b, c, d], do: join!(u, room)
    ok!(ban(a, room, d, %{"reason" => "spam"}), "ban D")
    room
  end

  # ═══ AC6 (a): real invite events ════════════════════════════════════════════════════════════════

  describe "AC6 (a) - the old members are invited by real invite events in the upgrader's name" do
    test "B and C each have a pending row AND an invite event (sender A, content {membership: invite}); the banned D has neither row nor invite event", %{a: a, b: b, c: c, d: d} do
      room = public_with_ban!(a, b, c, d)

      new_room = upgrade!(a, room)

      for u <- [b, c] do
        assert invitation_state(new_room, u.uid) == :pending, "#{u.uid}: the row"
        assert [event] = invite_events(new_room, u.uid), "#{u.uid}: exactly one invite event"
        assert event.sender == a.uid and event.content == @invite
        assert memberships(new_room, u.uid) == ["invite"]
      end

      assert invitation_state(new_room, d.uid) == :none, "ban -> invite must never happen: no row"
      assert invite_events(new_room, d.uid) == [], "and no invite event"
      assert memberships(new_room, d.uid) == ["ban"], "only the carried ban"
      refute member_events(new_room, a.uid) == [], "control: the upgrader's own join exists"
      assert invite_events(new_room, a.uid) == [], "the upgrader is not invited"
    end

    test "B's next /sync lists the new room in rooms.invite with the stripped real invite event; B's join has the invite as predecessor", %{a: a, b: b, c: c, d: d} do
      room = public_with_ban!(a, b, c, d)
      anchor = anchor_room!(b)
      token = snapshot!(b, anchor)

      new_room = upgrade!(a, room)
      body = sync(b, token)

      assert in_section?(body, "invite", new_room), "the invitation is delivered"
      events = get_in(body, ["rooms", "invite", new_room, "invite_state", "events"])
      assert ev = Enum.find(events, &(&1["type"] == "m.room.member" and &1["state_key"] == b.uid)), "B's invite event is in invite_state"
      assert ev["sender"] == a.uid and ev["content"] == @invite

      [invite_row] = invite_events(new_room, b.uid)
      join!(b, new_room)
      [_invite, join_row] = member_events(new_room, b.uid)
      conn = T.matrix_request(:get, path(new_room, "event/#{enc(join_row.event_id)}"), b.at)
      assert conn.status == 200
      unsigned = T.json(conn)["unsigned"]
      assert unsigned["prev_content"]["membership"] == "invite"
      assert unsigned["replaces_state"] == invite_row.event_id
      assert unsigned["prev_sender"] == a.uid
    end
  end

  # ═══ AC6 (b): is_direct ═════════════════════════════════════════════════════════════════════════

  describe "AC6 (b) - is_direct is carried from the invitee's OWN invite in the old room" do
    test "a DM (createRoom is_direct, B invited and joined) upgraded by A: B's new invite carries is_direct: true", %{a: a, b: b} do
      dm = make_room(a, element_dm(b.uid))
      join!(b, dm)
      assert [%{content: %{"is_direct" => true}}] = invite_events(dm, b.uid), "fixture: B's invite in the old room was direct"

      new_room = upgrade!(a, dm)

      assert [event] = invite_events(new_room, b.uid)
      assert event.content == @direct_invite and event.sender == a.uid
    end

    test "the same DM upgraded by B instead: A's new invite has NO is_direct (gi (b): A has no invite event in the old room)", %{a: a, b: b} do
      dm = make_room(a, element_dm(b.uid))
      join!(b, dm)

      new_room = upgrade!(b, dm)

      assert [event] = invite_events(new_room, a.uid), "A is invited"
      assert event.content == @invite and event.sender == b.uid
    end

    test "a plain room: no invite of the new room carries is_direct", %{a: a, b: b, c: c, d: d} do
      room = public_with_ban!(a, b, c, d)

      new_room = upgrade!(a, room)

      for u <- [b, c], do: assert(Enum.all?(invite_events(new_room, u.uid), &(not Map.has_key?(&1.content, "is_direct"))))
    end
  end

  # ═══ AC6 (c): stamps ════════════════════════════════════════════════════════════════════════════

  describe "AC6 (c) - the stamps" do
    # T-10: the new room holds no member event of an invitee before the invite (the carried bans are other users'), so "each after the invitee's latest member
    # event" is trivially the first stamp here; the max(now, not_before, latest + 1) rule itself is pinned by server_member_stamp_test.exs and the writer suites.
    test "the invite events are stamped strictly after every other event of the new room (the copied state); the member stamps of each user strictly increase", %{a: a, b: b, c: c, d: d} do
      room = public_with_ban!(a, b, c, d)

      new_room = upgrade!(a, room)

      invites = for u <- [b, c], do: List.first(invite_events(new_room, u.uid))

      others =
        T.sql!(
          "SELECT max(origin_server_ts) FROM events WHERE room_id = $1 AND NOT (event_type = 'm.room.member' AND state_key = ANY($2))",
          [new_room, [b.uid, c.uid]]
        ).rows
        |> List.first()
        |> List.first()

      for invite <- invites, do: assert(invite.ts > others, "the invite (#{invite.ts}) is stamped after the copied state (#{others})")

      for u <- [a, b, c, d] do
        stamps = new_room |> member_events(u.uid) |> Enum.map(& &1.ts)
        assert stamps == Enum.sort(Enum.uniq(stamps)), "#{u.uid}: strictly increasing member stamps"
      end
    end
  end

  # ═══ AC6 (d), (e): failures ═════════════════════════════════════════════════════════════════════

  describe "AC6 (d), (e) - failures" do
    test "(d) a failing invite event for B: the upgrade answers 200, B's row is rejected again (no event), C is invited normally, ONE value-free WARNING", %{a: a, b: b, c: c} do
      room = public_room(a)
      for u <- [b, c], do: join!(u, room)
      install_room_db!(Hooks.InviteRoomDB)
      Hooks.arm(:atdd_ms_invite, %{user: b.uid})

      {conn, log} = with_log(fn -> upgrade(a, room) end)

      assert conn.status == 200, "#{conn.status} #{String.slice(conn.resp_body, 0, 200)}"
      new_room = T.json(conn)["replacement_room"]
      assert invitation_state(new_room, b.uid) == :rejected, "B's row is rejected again"
      assert member_events(new_room, b.uid) == [], "no invite event for B"
      assert invitation_state(new_room, c.uid) == :pending, "C is invited normally"
      assert [%{content: @invite}] = invite_events(new_room, c.uid)

      warnings = log |> String.split("\n") |> Enum.filter(&(&1 =~ "[warning]" and &1 =~ new_room))
      assert length(warnings) == 1, "exactly ONE warning that names the new room: #{inspect(warnings)}"
      [line] = warnings
      refute line =~ "%{" or line =~ "{:", "no inspect of a term: #{line}"
      # coupling note: the refusal of the room process is the atom :write_failed and `db_error_class(atom)` is `inspect(atom)`
      assert line =~ "write_failed", "the refusal atom of the room process"
      for u <- [a, b, c], do: refute(log =~ u.uid, "no user id anywhere in the captured log")
    end

    # security cycle 1 (MINOR-6): after the FIRST `:room_unavailable` the invitation loop stops: the member whose write died is rejected again, the members after him
    # get NO row and no event, and ONE value-free line names the number skipped
    test "(d) the new room's process dies in the first invite write (the call exits, :room_unavailable): the upgrade answers 200, that row is rejected, the rest is skipped, ONE line names the number", %{a: a, b: b, c: c, d: d} do
      room = public_room(a)
      for u <- [b, c, d], do: join!(u, room)
      install_room_db!(Hooks.InviteRoomDB)
      Hooks.arm(:atdd_ms_invite, %{kill_first: :counters.new(1, [])})

      {conn, log} = with_log(fn -> upgrade(a, room) end)

      assert conn.status == 200, "#{conn.status} #{String.slice(conn.resp_body, 0, 200)}"
      new_room = T.json(conn)["replacement_room"]
      # security cycle 2 (AC19 (j)): the loop runs in state_key ASCENDING order: the first member's write is the one that dies, the other two are skipped
      [first | rest] = Enum.sort([b.uid, c.uid, d.uid])
      assert invitation_state(new_room, first) == :rejected, "the FIRST member (state_key ascending) is the one whose write died: rejected again"
      for uid <- rest, do: assert(invitation_state(new_room, uid) == :none, "#{uid}: skipped, no row")
      for u <- [b, c, d], do: assert(member_events(new_room, u.uid) == [], "no invite event for #{u.uid}")

      lines = log |> String.split("\n") |> Enum.filter(&(&1 =~ "[warning]" and &1 =~ new_room))
      assert [line] = lines, "ONE line: #{inspect(lines)}"
      assert line =~ "2" and line =~ ~r/skipped/i, "it names the number skipped"
      for u <- [a, b, c, d], do: refute(log =~ u.uid, "no user id anywhere in the log")
    end

    # security cycle 1 (MINOR-7): the pure read of the is_direct flags happens BEFORE anything is written
    test "(e) a failing direct_invitees/1 read: 500 and NOTHING written (no tombstone, old room active and running, no new room, no row or event); value-free log", %{a: a, b: b, c: c} do
      room = public_room(a)
      for u <- [b, c], do: join!(u, room)
      creates_before = T.sql!("SELECT count(*) FROM events WHERE event_type = 'm.room.create' AND sender = $1", [a.uid]).rows
      install_env!(:event_dispatcher, :rooms_db_module, Hooks.DirectDB)
      Hooks.arm(:atdd_ms_direct, %{room: room, fail: true})

      {conn, log} = with_log(fn -> upgrade(a, room) end)

      assert_err(conn, 500, "M_UNKNOWN")
      assert T.sql!("SELECT count(*) FROM events WHERE room_id = $1 AND event_type = 'm.room.tombstone'", [room]).rows == [[0]], "no tombstone"
      assert room_status(room) == "active" and running?(room), "the old room is neither archived nor stopped"
      assert T.sql!("SELECT count(*) FROM events WHERE event_type = 'm.room.create' AND sender = $1", [a.uid]).rows == creates_before, "no new room was created"
      assert T.sql!("SELECT count(*) FROM room_invitations WHERE inviter_id = $1", [a.uid]).rows == [[0]], "no invitation row of the upgrader"
      assert T.sql!("SELECT count(*) FROM events WHERE sender = $1 AND event_type = 'm.room.member' AND content->>'membership' = 'invite'", [a.uid]).rows == [[0]]
      assert log =~ room and log =~ "atdd_injected"
      for u <- [a, b, c], do: refute(log =~ u.uid)
    end
  end

  # ═══ AC6 (f), (g): the wake, the audit ══════════════════════════════════════════════════════════

  describe "AC6 (f), (g) - the wake and the audit row" do
    test "(f) the wake reaches a sync task subscribed through :pg (cluster-wide group); the invite EVENT already exists when it arrives", %{a: a, b: b, c: c} do
      room = public_room(a)
      for u <- [b, c], do: join!(u, room)
      parent = self()

      # a stand-in for B's long-poll task: it reads the database at the moment the wake arrives and reports what it saw
      watcher =
        spawn_link(fn ->
          :ok = :pg.join("user:" <> b.uid, self())
          send(parent, :watching)

          receive do
            {:new_invite, new_room} -> send(parent, {:woken, new_room, member_events(new_room, b.uid)})
          after
            15_000 -> send(parent, :no_wake)
          end
        end)

      assert_receive :watching, 5_000

      new_room = upgrade!(a, room)

      assert_receive {:woken, ^new_room, seen}, 15_000
      assert [%{content: @invite}] = Enum.filter(seen, &(&1.content["membership"] == "invite")), "the event was written BEFORE the wake"
      assert is_pid(watcher)
    end

    test "(g) the room_upgraded audit row is unchanged (the same metadata keys, no new key) and the upgrade reads no invitation counts", %{a: a, b: b, c: c, d: d} do
      room = public_with_ban!(a, b, c, d)
      # the test environment runs a NoOp audit writer: the real one is installed (the prior value is snapshotted before, restored on exit)
      install_env!(:compliance, :audit_writer, Nebu.Compliance.AuditWriter)

      {new_room, statements} = count_statements(fn -> upgrade!(a, room) end, [room])

      assert [row] = upgrade_audit(room)
      assert row.outcome == "success"
      assert row.metadata == %{"new_room_id" => new_room, "new_version" => "10", "bans_carried" => 1, "power_levels_carried" => true}
      assert Enum.filter(statements, &(&1 =~ "room_invitations" and &1 =~ ~r/count\(/i)) == [], "no count read: the upgrade's invitations are not charged to the caps"
    end
  end

  # ═══ AC16 ═══════════════════════════════════════════════════════════════════════════════════════

  # S-5 (test review, decided: a TRUE non-goal): the OLD room of an upgrade is archived, tombstoned and its process stopped. Its answers stay EXACTLY as they are
  # today (known, unchanged, `gi`): `/members` and `/initialSync` cannot start an archived room and answer 404 M_NOT_FOUND "Room not found"; the initial /sync
  # lists it in no section; a never-member is refused alike. Nothing here reads an archived room from the database.
  describe "S-5 - the archived, tombstoned old room after an upgrade (known, unchanged: gi)" do
    test "/members and /initialSync answer an old member 404 M_NOT_FOUND (a never-member 403), the initial /sync lists no archived room, no write", %{a: a, b: b, c: c, d: d} do
      room = public_with_ban!(a, b, c, d)
      stranger = user!("MUS")
      new_room = upgrade!(a, room)
      events_before = event_count(room)

      assert_err(members_conn(b, room), 404, "M_NOT_FOUND", "Room not found")
      assert_err(T.matrix_request(:get, path(room, "initialSync"), b.at), 404, "M_NOT_FOUND", "Room not found")

      # security cycle 1 (L-1; INFO-5, labelled) and security cycle 2 (AC19 (g): old member 404, never-member 403): a never-member is gated BEFORE the start attempt: the fixed 403 (not the 404 an archived room answers its old members)
      assert_err(members_conn(stranger, room), 403, "M_FORBIDDEN", "You are not a member of this room")
      assert_err(T.matrix_request(:get, path(room, "initialSync"), stranger.at), 403, "M_FORBIDDEN", "You are not a member of this room")

      body = sync(b)
      refute in_section?(body, "join", room) or in_section?(body, "leave", room) or in_section?(body, "invite", room), "the archived old room is in no section"
      assert in_section?(body, "invite", new_room), "control: the new room is delivered"
      assert event_count(room) == events_before, "reading an archived room writes nothing"
      assert room_rows(room) == 1
    end
  end

  describe "AC16 - the Oracle tests of the upgrade" do
    test "(b) the invite_state of an upgrade invitation holds m.room.create and B's real invite event in STRIPPED form: exactly type, state_key, sender, content", %{a: a, b: b, c: c, d: d} do
      room = public_with_ban!(a, b, c, d)
      anchor = anchor_room!(b)
      token = snapshot!(b, anchor)

      new_room = upgrade!(a, room)
      events = get_in(sync(b, token), ["rooms", "invite", new_room, "invite_state", "events"])

      assert Enum.any?(events, &(&1["type"] == "m.room.create")), "m.room.create is part of the invite state (v1.16 MUST)"
      assert invite = Enum.find(events, &(&1["type"] == "m.room.member" and &1["state_key"] == b.uid))
      assert Enum.sort(Map.keys(invite)) == ["content", "sender", "state_key", "type"], "stripped: no event_id, no unsigned"
      assert invite["sender"] == a.uid and invite["content"] == @invite
      for ev <- events, do: assert(Enum.sort(Map.keys(ev)) == ["content", "sender", "state_key", "type"])
    end

    test "(e) after the upgrade A's client-side POST /invite for B (already invited) answers 200 {} and writes no second event; for a user the upgrade did NOT invite it is a normal invite", %{a: a, b: b, c: c} do
      room = public_room(a)
      for u <- [b, c], do: join!(u, room)
      leave!(c, room)

      new_room = upgrade!(a, room)
      assert invite_events(new_room, c.uid) == [], "fixture: C left before the upgrade and was not invited"
      [already] = invite_events(new_room, b.uid)

      again = invite(a, new_room, b)
      assert again.status == 200 and T.json(again) == %{}, "already invited: 200 {}"
      assert invite_events(new_room, b.uid) == [already], "no second invite event for B"

      fresh = invite(a, new_room, c)
      assert fresh.status == 200 and T.json(fresh) == %{}
      assert [%{content: @invite, sender: sender}] = invite_events(new_room, c.uid)
      assert sender == a.uid
    end

    test "(f) B ignores A before A upgrades: B's row and invite event are written, B's /sync does NOT list the new room in rooms.invite; C (not ignoring) gets it", %{a: a, b: b, c: c} do
      room = public_room(a)
      for u <- [b, c], do: join!(u, room)
      put_account_data!(b, "m.ignored_user_list", %{"ignored_users" => %{a.uid => %{}}})

      new_room = upgrade!(a, room)

      assert invitation_state(new_room, b.uid) == :pending, "written regardless of the ignore list"
      assert [%{content: @invite}] = invite_events(new_room, b.uid)
      refute in_section?(sync(b), "invite", new_room), "suppressed on the sync side"
      assert in_section?(sync(c), "invite", new_room), "positive control: C is not ignoring and receives it"
    end

    test "(g) m.invite_permission_config {default_action: block} of C before the upgrade: C's invitation IS written and delivered (the `fh` pin: invite blocking is not applied)", %{a: a, b: b, c: c} do
      room = public_room(a)
      for u <- [b, c], do: join!(u, room)
      put_account_data!(c, "m.invite_permission_config", %{"default_action" => "block"})

      new_room = upgrade!(a, room)

      assert invitation_state(new_room, c.uid) == :pending
      assert [%{content: @invite}] = invite_events(new_room, c.uid)
      assert in_section?(sync(c), "invite", new_room), "delivered although the config says block (`fh`)"
    end

    test "(gi a) a pending invitee of the OLD room is not invited into the new room (only joined members are)", %{a: a, b: b, c: c} do
      room = public_room(a)
      join!(b, room)
      invite!(a, room, c)

      new_room = upgrade!(a, room)

      assert invitation_state(new_room, b.uid) == :pending
      assert invitation_state(new_room, c.uid) == :none and member_events(new_room, c.uid) == []
    end
  end
end
