defmodule Nebu.Matrix.ModerationFixCycle1HttpTest do
  @moduledoc """
  Story `moderation-routes-atomic-ban`, review cycle 1 (Kassandra M-1, L-2, L-3, I-6; code review M3, M4, M5, M6, I1), REAL database through
  `Nebu.Web.Router` and the real `Room.Server` / `Room.DB`. `async: false`.

    * M-1: a ban committed in the old room AFTER the upgrade's first (pre-tombstone) bans read (a seam right after that read) is
      carried into the new room (since review cycle 2 by the ONE authoritative read after the freeze): the target is neither invited
      nor joined there.
    * L-3 / M4: the cap of carried bans (lowered through `:nebu, :upgrade_max_carried_bans`): refused with 403 BEFORE the tombstone.
    * L-2 / M3: a kick of a member behind a latest `ban` (a half state) is refused "unban them instead", also by a sender with the kick
      level but not the ban level (kick 10, ban 50); the ban stays the latest membership.
    * I-6: `Room.DB.apply_member_change/4` waits at most 1 s per row lock (`lock_timeout`, review cycle 2), then fails and changes nothing.
    * M5: a revocation committed between the invitation row and the room call: the invite is 403, no invite event after the revocation.
    * M6: a revocation committed between the decline decision and the room call: the decline is 200 and writes no second leave.
    * I1: `Room.DB.latest_member_event/2` returns the binary event id of the latest member event.
  """
  use ExUnit.Case, async: false

  import Nebu.Matrix.ModerationTestSupport

  alias Nebu.Matrix.ModerationTestSupport.Gap
  alias Nebu.Matrix.Room.DB
  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration
  @moduletag timeout: 120_000

  setup do
    T.reset_rate_limits()
    Nebu.Test.ServerName.pin!(T.server_name())
    seams = for {app, key} <- [event_dispatcher: :rooms_db_module, nebu: :upgrade_max_carried_bans, nebu: :atdd_late_ban, compliance: :audit_writer], do: {app, key, Application.fetch_env(app, key)}

    # config/test.exs runs a NoOp audit writer: the `bans_carried` assertion needs the real one (the prior value is restored below)
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

    {:ok, a: user!("MCA"), b: user!("MCB"), c: user!("MCC")}
  end

  defp upgrade(user, room), do: T.matrix_request(:post, path(room, "upgrade"), user.at, body: %{"new_version" => "10"})

  defp tombstones(room), do: T.sql!("SELECT count(*) FROM events WHERE room_id = $1 AND event_type = 'm.room.tombstone'", [room]).rows

  # ═══ Kassandra M-1: a ban committed during the upgrade is carried ═══════════════════════════════════

  # delegates everything to Room.DB; the FIRST banned_members/1 read of the armed room (the pre-tombstone check) runs the armed hook
  # right after the real read (a ban that commits in the old room before the freeze, while its process still accepts moderation)
  defmodule LateBanDB do
    @moduledoc false
    alias Nebu.Matrix.Room.DB

    for {name, arity} <- DB.__info__(:functions), name != :banned_members do
      args = Macro.generate_arguments(arity, __MODULE__)
      def unquote(name)(unquote_splicing(args)), do: apply(DB, unquote(name), unquote(args))
    end

    def banned_members(room_id) do
      result = DB.banned_members(room_id)

      case Application.get_env(:nebu, :atdd_late_ban) do
        {^room_id, hook} ->
          Application.delete_env(:nebu, :atdd_late_ban)
          hook.()

        _ ->
          :ok
      end

      result
    end
  end

  describe "Kassandra M-1 - a ban committed in the old room after the upgrade read its bans" do
    test "the late ban is carried into the new room: the target (a member of the snapshot) is neither invited nor joined there, bans_carried counts it", %{a: a, b: b, c: c} do
      room = public_room(a)
      join!(b, room)
      join!(c, room)

      Application.put_env(:event_dispatcher, :rooms_db_module, LateBanDB)
      Application.put_env(:nebu, :atdd_late_ban, {room, fn -> :ok = Nebu.Matrix.Room.Server.moderate(room, :ban, a.uid, b.uid, "late") end})

      conn = upgrade(a, room)
      assert conn.status == 200, "#{conn.status} #{String.slice(conn.resp_body, 0, 200)}"
      new_room = T.json(conn)["replacement_room"]
      assert Application.get_env(:nebu, :atdd_late_ban) == nil, "positive control: the hook ran (the ban committed after the first read)"
      assert membership(room, b.uid) == "ban"

      assert invitation_state(new_room, b.uid) != :pending, "the late-banned user holds no pending invitation in the new room"
      assert membership(new_room, b.uid) == "ban"
      assert %{sender: sender, content: %{"membership" => "ban", "reason" => "late"}} = List.last(member_events(new_room, b.uid))
      assert sender == a.uid
      refute in_set?(new_room, b.uid)
      assert_err(join(b, new_room), 403, "M_FORBIDDEN", "You are banned from this room")

      assert invitation_state(new_room, c.uid) == :pending, "positive control: the other member is invited"

      assert [[metadata]] = T.sql!("SELECT metadata FROM audit_log WHERE action = 'room_upgraded' AND target_id = $1 AND outcome = 'success'", [room]).rows
      assert content_of(metadata)["bans_carried"] == 1
    end
  end

  # ═══ Kassandra L-3 / review M4: the cap of carried bans ═══════════════════════════════════════════

  describe "Kassandra L-3 - an upgrade carries at most the configured number of bans" do
    test "above the cap: 403 M_FORBIDDEN with a fixed text BEFORE anything is written (no tombstone, no new room); at the cap the upgrade works", %{a: a, b: b, c: c} do
      Application.put_env(:nebu, :upgrade_max_carried_bans, 1)
      room = public_room(a)
      join!(b, room)
      join!(c, room)
      ok!(ban(a, room, b), "ban b")
      ok!(ban(a, room, c), "ban c")
      creates = fn -> T.sql!("SELECT count(*) FROM events WHERE sender = $1 AND event_type = 'm.room.create'", [a.uid]).rows end
      before = creates.()

      conn = upgrade(a, room)
      body = assert_err(conn, 403, "M_FORBIDDEN", "The room has too many bans to be upgraded")
      refute inspect(body) =~ b.uid
      assert tombstones(room) == [[0]], "nothing is tombstoned"
      assert creates.() == before, "no new room is left behind"

      ok!(unban(a, room, c), "unban c: one ban left, at the cap")
      conn = upgrade(a, room)
      assert conn.status == 200, "#{conn.status} #{String.slice(conn.resp_body, 0, 200)}"
      new_room = T.json(conn)["replacement_room"]
      assert membership(new_room, b.uid) == "ban"
    end
  end

  # ═══ Kassandra L-2 / review M3: a kick cannot lift a ban ════════════════════════════════════════════

  describe "Kassandra L-2 - a kick of a member behind a latest ban" do
    test "is refused \"unban them instead\" for a sender with the kick level but not the ban level (kick 10, ban 50, sender 20); the ban stays the latest membership", %{a: a, b: b, c: c} do
      room = level_room(a, %{c.uid => 20}, %{"kick" => 10, "ban" => 50})
      join!(b, room)
      join!(c, room)
      ok!(ban(a, room, b), "ban")
      # the half state: an active member row behind the latest ban, loaded into the member set by a restart
      assert :ok = DB.insert_member(room, b.uid)
      kill_and_restart!(room)
      assert in_set?(room, b.uid), "premise: the half state is in the member set"
      ban_ev = List.last(member_events(room, b.uid))

      assert_err(kick(c, room, b), 403, "M_FORBIDDEN", "The user is banned from this room: unban them instead")
      assert_err(kick(a, room, b), 403, "M_FORBIDDEN", "The user is banned from this room: unban them instead")
      assert membership(room, b.uid) == "ban"
      assert List.last(member_events(room, b.uid)) == ban_ev, "no leave was written"

      # the repair stays the repeated ban
      ok!(ban(a, room, b), "repair")
      refute in_set?(room, b.uid)
      refute active_row?(room, b.uid)
    end
  end

  # ═══ Kassandra I-6: lock_timeout inside the member transaction ═════════════════════════════════════════

  describe "Kassandra I-6 - apply_member_change/4 waits at most 1 s for a row lock" do
    test "a pending invitation row locked by another transaction: the change fails with 55P03 within the bound and changes nothing; the kick through the route is 500", %{a: a, b: b} do
      room = public_room(a)
      join!(b, room)
      row_only_invitation!(room, a, b)
      parent = self()

      holder =
        Task.async(fn ->
          Nebu.Repo.transaction(fn ->
            {:ok, _} = Ecto.Adapters.SQL.query(Nebu.Repo, "SELECT 1 FROM room_invitations WHERE room_id = $1 AND invitee_id = $2 FOR UPDATE", [room, b.uid])
            send(parent, :locked)

            receive do
              :release -> :ok
            after
              15_000 -> :ok
            end
          end)
        end)

      assert_receive :locked, 5_000
      started = System.monotonic_time(:millisecond)
      assert {:error, %Postgrex.Error{postgres: %{pg_code: "55P03"}}} = DB.apply_member_change(room, b.uid, nil, remove_member: true, reject_invitation: true)
      waited = System.monotonic_time(:millisecond) - started
      # review cycle 2 (Kassandra I-11): lock_timeout 1 s per wait (was 2 s)
      assert waited < 2_500, "bounded by lock_timeout 1 s (waited #{waited} ms)"
      assert active_row?(room, b.uid) and invitation_state(room, b.uid) == :pending, "rolled back"

      conn = kick(a, room, b)
      assert conn.status == 500, "#{conn.status} #{String.slice(conn.resp_body, 0, 120)}"
      assert in_set?(room, b.uid)

      send(holder.pid, :release)
      Task.await(holder, 20_000)
      ok!(kick(a, room, b), "the kick once the lock is gone")
      assert invitation_state(room, b.uid) == :rejected
    end
  end

  # ═══ review M5 / M6: revocations racing the invite event and the decline ═══════════════════════════

  describe "review M5 / M6 - a revocation in the gap" do
    setup do
      Gap.install!()
      :ok
    end

    defp in_gap(fun, room, target, request, gap_action) do
      Gap.arm(fun, room, target.uid, self())

      task =
        Task.async(fn ->
          Process.put(:atdd_gap_victim, true)
          request.()
        end)

      assert_receive {:gap, victim, ^fun}, 10_000, "the request never reached the gap"
      gap_action.()
      send(victim, :go)
      Task.await(task, 20_000)
    end

    test "M5: a kick-revoke between the invitation row and the room call: the invite is 403 \"The user is not in this room\", no invite event after the revocation", %{a: a, b: b} do
      room = public_room(a)

      conn = in_gap(:insert_invitation_capped, room, b, fn -> invite(a, room, b) end, fn -> ok!(kick(a, room, b), "revocation inside the gap") end)

      assert_err(conn, 403, "M_FORBIDDEN", "The user is not in this room")
      assert memberships(room, b.uid) == ["leave"], "the revocation stays the latest (and only) member event"
      assert invitation_state(room, b.uid) == :rejected
    end

    test "M6: a kick-revoke between the decline decision and the room call: the decline is 200 and writes no second leave (the revocation stays the latest)", %{a: a, b: b} do
      room = make_room(a, %{"preset" => "private_chat"})
      invite!(a, room, b)

      conn = in_gap(:delete_member, room, b, fn -> leave(b, room) end, fn -> ok!(kick(a, room, b), "revocation inside the gap") end)

      ok!(conn, "the decline")
      assert memberships(room, b.uid) == ["invite", "leave"], "one leave only"
      assert List.last(member_events(room, b.uid)).sender == a.uid, "the kicker's revocation is the latest membership"
      assert invitation_state(room, b.uid) == :rejected
    end
  end

  # ═══ review I1: the event id of the latest member event ══════════════════════════════════════════

  describe "review I1 - Room.DB.latest_member_event/2" do
    test "returns the binary event id of the latest member event the server wrote (the join basis depends on it)", %{a: a, b: b} do
      room = public_room(a)
      join!(b, room)
      join_id = List.last(member_events(room, b.uid)).event_id

      assert {:ok, %{event_id: event_id, membership: "join"}} = DB.latest_member_event(room, b.uid)
      assert is_binary(event_id) and event_id == join_id
    end
  end
end
