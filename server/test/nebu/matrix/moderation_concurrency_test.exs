defmodule Nebu.Matrix.ModerationConcurrencyTest do
  @moduledoc """
  Story `moderation-routes-atomic-ban` (follow-up `ex`, Kassandra M-1 / N-1 / N-1b), the gate evidence: AC7 (the races), AC8 (c) (the M-1 sequence made
  deterministic) and AC10 (b) (the join basis, deterministic). REAL database, real `Room.Server` under Horde, the full router; `async: false`.

  Every race scenario runs `@rounds` (default 50, the story's minimum; the environment variable `NEBU_MODERATION_RACE_ROUNDS` can only RAISE it) rounds
  with FRESH users and rooms, the racing requests start together behind a barrier (`ModerationTestSupport.race/1`) and the INVARIANTS are asserted
  after each round, never a particular interleaving. A failing round prints its member-event sequence (membership and timestamps only, no content).

  The per-user rate limits are disabled for the races (a round makes dozens of requests; the limits have their own tests); the pending-invitation caps
  stay on (fresh targets per round keep them out of the way).

  The deterministic gap tests use `ModerationTestSupport.Gap` (two delegating db modules that block ONE armed call of the victim process): the
  moderation commits inside the gap, the victim is released and must decide on the new state.

  ## Decisions of the ATDD step (ambiguities of the story)

    * AC7 (b) races the invite ROUTE of ten members against the ban; createRoom's step-8 path (`write_invite/5`, the same call) cannot race a ban of
      a room that does not exist yet and is pinned by the existing `create_room_invites*` suites and the gap tests below.
    * A 503 `M_LIMIT_EXCEEDED` of the invite writer (the 2 s advisory lock timeout) is tolerated in the invite race (time based, nothing written); every
      other status than 200 / 403 fails the round.
    * AC10 (b) "two changes in a row": each of the two gaps is a kick followed by a re-invite (a revocation alone would end the join with the 403 of the
      second decision, not with the 503).
  """
  use ExUnit.Case, async: false

  import Nebu.Matrix.ModerationTestSupport

  alias Nebu.Matrix.ModerationTestSupport.Gap
  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration
  @moduletag :concurrency
  @moduletag timeout: 900_000

  @rounds max(50, String.to_integer(System.get_env("NEBU_MODERATION_RACE_ROUNDS", "50")))

  setup do
    T.reset_rate_limits()
    Nebu.Test.ServerName.pin!(T.server_name())
    Application.put_env(:nebu_http, :rate_limit_disabled, true)
    on_exit(fn -> T.restore_rate_limits() end)
    :ok
  end

  # ─── round helpers ───────────────────────────────────────────────────────────

  # the member-event sequence of a round, for the failure message only: "join@123 ban@125"
  defp seq(room, uid), do: room |> member_events(uid) |> Enum.map_join(" ", &"#{&1.content["membership"]}@#{&1.ts}")

  defp expect!(condition, round, room, uid, what) do
    assert condition, "round #{round}: #{what} (member events: #{seq(room, uid)})"
  end

  defp only_statuses!(convs, allowed, round, room, uid, what) do
    bad = convs |> Enum.reject(&(&1.status in allowed)) |> Enum.map(&{&1.status, String.slice(&1.resp_body, 0, 80)})
    expect!(bad == [], round, room, uid, "#{what}: unexpected answers #{inspect(bad)}")
  end

  # the invariants every scenario ends with: the target is not joined anywhere, the latest membership says `membership`
  defp final_state!(round, room, t, membership) do
    expect!(not in_set?(room, t.uid), round, room, t.uid, "the target is in the in-memory member set")
    expect!(not active_row?(room, t.uid), round, room, t.uid, "the target has an active room_members row")
    expect!(membership(room, t.uid) == membership, round, room, t.uid, "the latest membership is #{inspect(membership(room, t.uid))}, expected #{membership}")
    expect!(invitation_state(room, t.uid) != :pending, round, room, t.uid, "a pending invitation survived")
  end

  defp strictly_increasing?(events), do: events |> Enum.map(& &1.ts) |> then(&(&1 == Enum.sort(Enum.uniq(&1))))

  # ═══ AC7 (a): ban vs ten concurrent joins ═══════════════════════════════════════

  describe "AC7 (a) - ban against 10 concurrent POST /join of the target (public room)" do
    test "after every round the target is out of the set and the rows, the latest membership is ban, the next join is 403" do
      for round <- 1..@rounds do
        mod = user!("RAM")
        t = user!("RAT")
        room = public_room(mod)

        results = race([fn -> ban(mod, room, t) end | for(_ <- 1..10, do: fn -> join(t, room) end)])
        [ban_conn | join_convs] = results

        expect!(ban_conn.status == 200, round, room, t.uid, "the ban answered #{ban_conn.status}")
        only_statuses!(join_convs, [200, 403], round, room, t.uid, "joins")
        final_state!(round, room, t, "ban")
        expect!(join(t, room).status == 403, round, room, t.uid, "the next join was not refused")
      end
    end
  end

  # ═══ AC7 (b): ban vs ten concurrent invites by different members ════════════════

  describe "AC7 (b) - ban against 10 concurrent POST /invite of the target by 10 different members (invite-only room)" do
    test "no pending row, latest ban, join 403; every 200 invite was written BEFORE the ban, every later one is 403" do
      owner = user!("RBO")
      members = for _ <- 1..10, do: user!("RBM")

      for round <- 1..@rounds do
        t = user!("RBT")
        room = make_room(owner, %{"preset" => "private_chat", "invite" => Enum.map(members, & &1.uid)})
        for m <- members, do: join_now!(m, room)

        results = race([fn -> ban(owner, room, t) end | for(m <- members, do: fn -> invite(m, room, t) end)])
        [ban_conn | invite_convs] = results

        expect!(ban_conn.status == 200, round, room, t.uid, "the ban answered #{ban_conn.status}")

        # 503 M_LIMIT_EXCEEDED = the advisory lock timeout of the row write: time based, nothing written. Any OTHER 503 (M_UNAVAILABLE) fails the round.
        lock_timeout? = &(&1.status == 503 and String.contains?(&1.resp_body, "M_LIMIT_EXCEEDED"))
        lock_timeouts = Enum.count(invite_convs, lock_timeout?)
        only_statuses!(Enum.reject(invite_convs, lock_timeout?), [200, 403], round, room, t.uid, "invites")
        expect!(lock_timeouts <= 3, round, room, t.uid, "too many lock timeouts (#{lock_timeouts})")

        final_state!(round, room, t, "ban")
        expect!(join(t, room).status == 403, round, room, t.uid, "a join of the banned target was not refused")

        events = member_events(room, t.uid)
        ban_ev = List.last(events)
        expect!(ban_ev.content["membership"] == "ban", round, room, t.uid, "the last event is not the ban")
        invites = Enum.filter(events, &(&1.content["membership"] == "invite"))
        expect!(Enum.all?(invites, &(&1.ts < ban_ev.ts)), round, room, t.uid, "an invite event is not older than the ban event")
        expect!(strictly_increasing?(events), round, room, t.uid, "the slot has a timestamp tie")
        expect!(length(invites) <= Enum.count(invite_convs, &(&1.status == 200)), round, room, t.uid, "more invite events than answered 200")
      end
    end
  end

  # ═══ AC7 (c): ban vs the target's decline ═══════════════════════════════════════

  describe "AC7 (c) - ban against the decline (POST /leave) of a pending invitee" do
    test "latest ban, no self-leave newer than the ban" do
      for round <- 1..@rounds do
        owner = user!("RCO")
        t = user!("RCT")
        room = make_room(owner, %{"preset" => "private_chat"})
        invite!(owner, room, t)

        [ban_conn, leave_conn] = race([fn -> ban(owner, room, t) end, fn -> leave(t, room) end])

        expect!(ban_conn.status == 200, round, room, t.uid, "the ban answered #{ban_conn.status}")
        only_statuses!([leave_conn], [200, 403], round, room, t.uid, "the decline")
        final_state!(round, room, t, "ban")

        events = member_events(room, t.uid)
        ban_ev = List.last(events)
        expect!(ban_ev.content["membership"] == "ban", round, room, t.uid, "the last event is not the ban")
        own_leaves = Enum.filter(events, &(&1.content["membership"] == "leave" and &1.sender == t.uid))
        expect!(Enum.all?(own_leaves, &(&1.ts < ban_ev.ts)), round, room, t.uid, "a self-leave is newer than the ban")
        expect!(strictly_increasing?(events), round, room, t.uid, "the slot has a timestamp tie")
      end
    end
  end

  # ═══ AC7 (d): kick-revoke vs the invitee's join ═════════════════════════════════

  describe "AC7 (d) - kick-revoke against the invitee's POST /join (invite-only room)" do
    test "never revoked AND joined: either the join won and the kick removed him again with a newer leave, or the revocation won and the join is 403" do
      for round <- 1..@rounds do
        owner = user!("RDO")
        t = user!("RDT")
        room = make_room(owner, %{"preset" => "private_chat"})
        invite!(owner, room, t)

        [kick_conn, join_conn] = race([fn -> kick(owner, room, t) end, fn -> join(t, room) end])

        expect!(kick_conn.status == 200, round, room, t.uid, "the kick answered #{kick_conn.status}")
        only_statuses!([join_conn], [200, 403], round, room, t.uid, "the join")
        final_state!(round, room, t, "leave")

        events = member_events(room, t.uid)
        last = List.last(events)
        expect!(last.sender == owner.uid, round, room, t.uid, "the last leave is not the kick")
        expect!(strictly_increasing?(events), round, room, t.uid, "the slot has a timestamp tie")

        joins = Enum.filter(events, &(&1.content["membership"] == "join"))

        if join_conn.status == 200 do
          expect!(length(joins) == 1 and hd(joins).ts < last.ts, round, room, t.uid, "the join won but the kick is not newer")
        else
          expect!(joins == [], round, room, t.uid, "the join was refused but a join event exists")
        end
      end
    end
  end

  # ═══ AC7 (e): ban vs the target's own leave as a member ═════════════════════════

  describe "AC7 (e) - ban against the target's own POST /leave as a member" do
    test "latest ban" do
      for round <- 1..@rounds do
        mod = user!("REM")
        t = user!("RET")
        room = public_room(mod)
        join_now!(t, room)

        [ban_conn, leave_conn] = race([fn -> ban(mod, room, t) end, fn -> leave(t, room) end])

        expect!(ban_conn.status == 200, round, room, t.uid, "the ban answered #{ban_conn.status}")
        only_statuses!([leave_conn], [200, 403], round, room, t.uid, "the leave")
        final_state!(round, room, t, "ban")
        events = member_events(room, t.uid)
        expect!(strictly_increasing?(events), round, room, t.uid, "the slot has a timestamp tie")
      end
    end
  end

  # ═══ AC7 (f): two moderators ban and unban ══════════════════════════════════════

  describe "AC7 (f) - two moderators ban and unban concurrently" do
    test "the final latest membership equals the last committed action, the member set and the rows agree, the slot is strictly ordered" do
      for round <- 1..@rounds do
        owner = user!("RFO")
        m1 = user!("RF1")
        m2 = user!("RF2")
        t = user!("RFT")
        room = level_room(owner, %{m1.uid => 50, m2.uid => 50})
        for u <- [m1, m2, t], do: join_now!(u, room)
        banned_first? = rem(round, 2) == 0
        if banned_first?, do: ok!(ban(owner, room, t), "setup ban")

        [ban_conn, unban_conn] = race([fn -> ban(m1, room, t) end, fn -> unban(m2, room, t) end])
        expect!(ban_conn.status == 200, round, room, t.uid, "the ban answered #{ban_conn.status}")

        events = member_events(room, t.uid)
        expect!(strictly_increasing?(events), round, room, t.uid, "the slot has a timestamp tie")
        names = Enum.map(events, & &1.content["membership"])

        if banned_first? do
          expect!(unban_conn.status == 200, round, room, t.uid, "unban of a banned user answered #{unban_conn.status}")
          expect!(names in [["join", "ban", "leave"], ["join", "ban", "leave", "ban"]], round, room, t.uid, "unexpected sequence #{inspect(names)}")
        else
          only_statuses!([unban_conn], [200, 403], round, room, t.uid, "the unban")

          expect!(
            (unban_conn.status == 200 and names == ["join", "ban", "leave"]) or (unban_conn.status == 403 and names == ["join", "ban"]),
            round,
            room,
            t.uid,
            "unban #{unban_conn.status} with sequence #{inspect(names)}"
          )
        end

        final_state!(round, room, t, List.last(names))
      end
    end
  end

  # ═══ AC8 (c) and the other gap cases of the invite writer ═══════════════════════

  describe "AC8 (c) - the M-1 sequence, deterministic: a ban commits between the outside checks and the room call of POST /invite" do
    setup do
      Gap.install!()
      :ok
    end

    defp invite_in_gap(inviter, room, target, fun, in_gap) do
      Gap.arm(fun, room, target.uid, self())

      task =
        Task.async(fn ->
          Process.put(:atdd_gap_victim, true)
          invite(inviter, room, target)
        end)

      assert_receive {:gap, victim, ^fun}, 10_000, "the invite never reached the row write"
      in_gap.()
      send(victim, :go)
      Task.await(task, 20_000)
    end

    test "a ban in the gap: the invite is 403 \"banned\", no pending row, no invite event, the latest membership is ban" do
      owner = user!("GBO")
      t = user!("GBT")
      room = public_room(owner)

      conn = invite_in_gap(owner, room, t, :insert_invitation_capped, fn -> ok!(ban(owner, room, t), "ban inside the gap") end)

      assert_err(conn, 403, "M_FORBIDDEN", "The invited user is banned from this room")
      assert invitation_state(room, t.uid) == :rejected, "the row this call created is not pending"
      assert memberships(room, t.uid) == ["ban"], "no invite event was written, the ban is the only member event"
      assert membership(room, t.uid) == "ban"
      assert_err(join(t, room), 403, "M_FORBIDDEN", "You are banned from this room")
    end

    test "a pre-existing pending row (row-only invitation) and a ban in the gap: the row is rejected too" do
      owner = user!("GPO")
      t = user!("GPT")
      room = make_room(owner, %{"preset" => "private_chat"})
      row_only_invitation!(room, owner, t)

      conn = invite_in_gap(owner, room, t, :insert_invitation, fn -> ok!(ban(owner, room, t), "ban inside the gap") end)

      assert conn.status == 403
      assert invitation_state(room, t.uid) == :rejected
      assert memberships(room, t.uid) == ["ban"]
    end

    test "the inviter is kicked in the gap: 403, the row THIS call created is rejected, no invite event" do
      owner = user!("GKO")
      inviter = user!("GKI")
      t = user!("GKT")
      room = public_room(owner)
      join!(inviter, room)

      conn = invite_in_gap(inviter, room, t, :insert_invitation_capped, fn -> ok!(kick(owner, room, inviter), "kick of the inviter inside the gap") end)

      assert conn.status == 403, "#{conn.status} #{String.slice(conn.resp_body, 0, 120)}"
      assert invitation_state(room, t.uid) == :rejected, "a row created by the refused call is rejected"
      assert member_events(room, t.uid) == []
    end

    test "the same refusal for a PRE-EXISTING pending row leaves it pending (only a ban rejects it)" do
      owner = user!("GQO")
      inviter = user!("GQI")
      t = user!("GQT")
      room = public_room(owner)
      join!(inviter, room)
      row_only_invitation!(room, owner, t)

      conn = invite_in_gap(inviter, room, t, :insert_invitation, fn -> ok!(kick(owner, room, inviter), "kick of the inviter inside the gap") end)

      assert conn.status == 403
      assert invitation_state(room, t.uid) == :pending, "the older invitation is not this call's to undo"
      assert member_events(room, t.uid) == []
    end
  end

  # ═══ AC10 (b): the join basis ═══════════════════════════════════════════════════

  describe "AC10 (b) - the join decision is re-run when the membership changes between the decision and the room call" do
    setup do
      Gap.install!()
      :ok
    end

    defp join_in_gaps(user, room, gaps, in_gap) do
      Gap.arm(:latest_member_event, room, user.uid, self(), gaps)

      task =
        Task.async(fn ->
          Process.put(:atdd_gap_victim, true)
          join(user, room)
        end)

      for n <- 1..gaps do
        assert_receive {:gap, victim, :latest_member_event}, 10_000, "the join never reached gap #{n}"
        in_gap.(n)
        send(victim, :go)
      end

      Task.await(task, 30_000)
    end

    test "a kick-revoke in the gap: the retry re-decides and answers 403 \"You are not invited to this room\", nothing joined" do
      owner = user!("JRO")
      t = user!("JRT")
      room = invite_room(owner, [])
      invite!(owner, room, t)

      conn = join_in_gaps(t, room, 1, fn _ -> ok!(kick(owner, room, t), "revocation inside the gap") end)

      assert_err(conn, 403, "M_FORBIDDEN", "You are not invited to this room")
      refute in_set?(room, t.uid)
      assert membership(room, t.uid) == "leave"
    end

    test "a re-invite committed in the gap (kick, then invite): the retry joins" do
      owner = user!("JIO")
      t = user!("JIT")
      room = invite_room(owner, [])
      invite!(owner, room, t)

      conn =
        join_in_gaps(t, room, 1, fn _ ->
          ok!(kick(owner, room, t), "revocation inside the gap")
          invite!(owner, room, t)
        end)

      assert conn.status == 200, "#{conn.status} #{String.slice(conn.resp_body, 0, 120)}"
      assert in_set?(room, t.uid)
      assert membership(room, t.uid) == "join"
    end

    test "two changes in a row (kick and re-invite in each gap): 503 M_UNAVAILABLE \"The membership changed ...\"" do
      owner = user!("J2O")
      t = user!("J2T")
      room = invite_room(owner, [])
      invite!(owner, room, t)

      conn =
        join_in_gaps(t, room, 2, fn _ ->
          ok!(kick(owner, room, t), "revocation inside the gap")
          invite!(owner, room, t)
        end)

      assert_err(conn, 503, "M_UNAVAILABLE", "The membership changed during the join, try again")
      refute in_set?(room, t.uid)
      refute active_row?(room, t.uid)
      assert membership(room, t.uid) == "invite", "the join wrote nothing: the latest event is still the last invite"
    end
  end

  # AC9 (c) lives in room/moderation_atomic_db_test.exs next to the decline tests.
  test "the gap modules delegate every function of the real db modules (a new Room.DB function is never hidden)" do
    for {gap, real} <- [{Nebu.Matrix.ModerationTestSupport.Gap.RoomsDB, Nebu.Matrix.Room.DB}, {Nebu.Matrix.ModerationTestSupport.Gap.InviteDB, Nebu.Matrix.Room.InviteDB}] do
      assert real.__info__(:functions) -- gap.__info__(:functions) == []
    end
  end
end
