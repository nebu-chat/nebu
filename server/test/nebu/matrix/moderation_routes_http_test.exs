defmodule Nebu.Matrix.ModerationRoutesHttpTest do
  @moduledoc """
  Story `moderation-routes-atomic-ban` (epic oauth-broker, follow-ups `ex`, `ew`, the revoke part of `fb`), HTTP half: AC1, AC2 (HTTP part),
  AC3, AC4, AC11 (HTTP part), AC12, AC13, AC14 and the twelve Oracle tests AC19 (a) - (l). Real stack: `Nebu.Web.Router` through
  `Plug.Test`, the real `Nebu.Repo`, real `Room.Server` / Horde / `:pg`, users and legacy sessions as in the sibling suites (random
  localparts, `:server_name` pinned). Everything the real SQL decides is asserted against the real database (no fake hides a statement);
  the atomicity, the event order and the crash / restart claims are in `room/moderation_atomic_db_test.exs`, the races in
  `moderation_concurrency_test.exs`.

  The shared helpers are `Nebu.Matrix.ModerationTestSupport` (`moderation_test_support.exs`, loaded by `test_helper.exs`).

  ## Decisions of the ATDD step (ambiguities of the story)

    * The rate-limit bucket key of the tier is `{"moderation", user_id}` (the shape of the `invite` / `join` buckets: tier name = bucket family).
    * A refusal of the room process that the story names only by its fixed text is asserted by that text and the errcode (`M_FORBIDDEN`),
      never by an internal atom. The 500 of a failed write is asserted as `500` + the generic `M_UNKNOWN` envelope (`Http.map_error/1` answers
      every internal error with the same text) without a client value in it.
    * `{"reason": ""}` and `{"reason": null}` count as absent (D10); the 400 texts of D10 are asserted verbatim.
    * Statement counting (`no users read on the ban path`) filters by the test process and the room process, like `member_prev_content_http_test`.
    * Where a test needs "ordered writes of the same user" it uses `tick/0` ONLY in rooms the test owns; the moderation events themselves are
      stamped by the server (`max(now, latest + 1)`), so no assertion depends on the clock.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Nebu.Matrix.ModerationTestSupport

  alias Nebu.Matrix.Room.DB
  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration
  @moduletag timeout: 180_000

  @actions ~w(kick ban unban)a

  @not_member "You are not a member of this room"
  @not_lower "You cannot act on a user whose power level is not lower than yours"
  @not_in_room "The user is not in this room"
  @banned_target "The user is banned from this room: unban them instead"
  @not_banned "The user is not banned from this room"
  @foreign_ban "Only users of this server can be banned"
  @join_banned "You are banned from this room"
  @join_not_invited "You are not invited to this room"
  @invite_banned "The invited user is banned from this room"
  @sender_text "Your user id exceeds 255 bytes: sign in again"

  defp power_text(action), do: "You do not have a high enough power level to #{action} from this room."

  setup do
    assert System.get_env("NEBU_RATE_LIMIT_DISABLED") != "true",
           "this suite requires the limiter ENABLED: NEBU_RATE_LIMIT_DISABLED must not be \"true\" in the test harness"

    T.reset_rate_limits()
    Nebu.Test.ServerName.pin!(T.server_name())

    tier_keys = [:rate_limit_moderation_per_min, :rate_limit_moderation_burst]
    saved = for key <- tier_keys, do: {key, Application.fetch_env(:nebu_http, key)}
    seams = for {app, key} <- [event_dispatcher: :rooms_db_module, event_dispatcher: :messages_db_module, room_manager: :db_module, compliance: :audit_writer], do: {app, key, Application.fetch_env(app, key)}

    # the test environment runs a NoOp audit writer (config/test.exs): the audit assertions need the real one. The PRIOR value was snapshotted
    # above and is restored in on_exit, so the real writer never leaks into a later suite.
    Application.put_env(:compliance, :audit_writer, Nebu.Compliance.AuditWriter)

    on_exit(fn ->
      T.restore_rate_limits()

      for {key, previous} <- saved do
        case previous do
          {:ok, value} -> Application.put_env(:nebu_http, key, value)
          :error -> Application.delete_env(:nebu_http, key)
        end
      end

      for {app, key, previous} <- seams do
        case previous do
          {:ok, value} -> Application.put_env(app, key, value)
          :error -> Application.delete_env(app, key)
        end
      end
    end)

    {:ok, a: user!("MRA"), b: user!("MRB"), c: user!("MRC"), d: user!("MRD")}
  end

  # nothing written: the footprint of (room, target) is identical before and after `fun`; returns the result of `fun`
  defp unchanged(room, target, fun) do
    before = footprint(room, uid_of(target))
    result = fun.()
    assert footprint(room, uid_of(target)) == before, "a refused request must write NOTHING (no event, member row, invitation row, audit row)"
    result
  end

  # a target in the state the action needs: joined (kick, ban) or banned (unban)
  defp target_for(:unban, owner, room) do
    t = user!("MRT")
    join!(t, room)
    ok!(ban(owner, room, t), "setup ban")
    t
  end

  defp target_for(_action, _owner, room) do
    t = user!("MRT")
    join!(t, room)
    t
  end

  # ═══ AC1 (a): the three routes exist ═══════════════════════════════════════════

  describe "AC1 (a) - the routes exist and answer 200 {} (no longer M_UNRECOGNIZED)" do
    test "POST /kick of a joined member: 200 {} application/json", %{a: a, b: b} do
      room = public_room(a)
      join!(b, room)
      conn = kick(a, room, b)
      ok!(conn, "kick")
      refute conn.resp_body =~ "M_UNRECOGNIZED"
    end

    test "POST /ban of a joined member: 200 {} application/json", %{a: a, b: b} do
      room = public_room(a)
      join!(b, room)
      conn = ban(a, room, b)
      ok!(conn, "ban")
      refute conn.resp_body =~ "M_UNRECOGNIZED"
    end

    test "POST /unban of a banned user: 200 {} application/json", %{a: a, b: b} do
      room = public_room(a)
      join!(b, room)
      ok!(ban(a, room, b), "ban")
      conn = unban(a, room, b)
      ok!(conn, "unban")
      refute conn.resp_body =~ "M_UNRECOGNIZED"
    end
  end

  # ═══ AC1 (b): the D6 order, first failure wins, nothing written ════════════════

  describe "AC1 (b) - the D6 order of the three routes (each case its own test, nothing written)" do
    for action <- @actions do
      test "#{action}: an empty `moderation` bucket answers 429 (Retry-After, retry_after_ms) even for a non-JSON body, nothing written", %{a: a} do
        action = unquote(action)
        room = public_room(a)
        t = target_for(action, a, room)
        seed("moderation", a, 0)

        unchanged(room, t, fn -> assert_429(act_raw(action, a, enc(room), "not json"), "empty bucket, #{action}") end)
        unchanged(room, t, fn -> assert_429(act(action, a, room, %{"user_id" => t.uid}), "empty bucket, valid body, #{action}") end)

        # positive control: with a token left the validation is what answers
        seed("moderation", a, 5)
        assert_err(act_raw(action, a, enc(room), "not json"), 400, "M_NOT_JSON")
      end

      test "#{action}: a body that is not JSON is 400 M_NOT_JSON", %{a: a} do
        action = unquote(action)
        room = public_room(a)
        t = target_for(action, a, room)
        unchanged(room, t, fn -> assert_err(act_raw(action, a, enc(room), "not json"), 400, "M_NOT_JSON") end)
      end

      test "#{action}: JSON that is not an object ([1], \"x\", 5, null) is 400 M_BAD_JSON", %{a: a} do
        action = unquote(action)
        room = public_room(a)
        t = target_for(action, a, room)

        for raw <- ["[1]", "\"x\"", "5", "null"] do
          unchanged(room, t, fn -> assert_err(act_raw(action, a, enc(room), raw), 400, "M_BAD_JSON") end)
        end
      end

      test "#{action}: {} and {\"user_id\": null} are 400 M_MISSING_PARAM \"user_id is required\"", %{a: a} do
        action = unquote(action)
        room = public_room(a)
        t = target_for(action, a, room)

        for body <- [%{}, %{"user_id" => nil}] do
          unchanged(room, t, fn -> assert_err(act(action, a, room, body), 400, "M_MISSING_PARAM", "user_id is required") end)
        end
      end

      test "#{action}: a user_id that is not a string is 400 M_BAD_JSON \"user_id must be a string\"", %{a: a} do
        action = unquote(action)
        room = public_room(a)
        t = target_for(action, a, room)

        for value <- [5, true, ["@x:y"], %{"a" => 1}] do
          unchanged(room, t, fn -> assert_err(act(action, a, room, %{"user_id" => value}), 400, "M_BAD_JSON", "user_id must be a string") end)
        end
      end

      test "#{action}: \"@bad id\", \"alice\", \"\" and a 256-byte user id are 400 M_INVALID_PARAM \"user_id is not a valid user id\"", %{a: a} do
        action = unquote(action)
        room = public_room(a)
        t = target_for(action, a, room)
        too_long = "@" <> String.duplicate("l", 256 - 2 - byte_size(T.server_name())) <> ":" <> T.server_name()
        assert byte_size(too_long) == 256

        for value <- ["@bad id:" <> T.server_name(), "alice", "", too_long] do
          unchanged(room, t, fn ->
            conn = act(action, a, room, %{"user_id" => value})
            assert_err(conn, 400, "M_INVALID_PARAM", "user_id is not a valid user id")
            refute_echo(conn, [value])
          end)
        end
      end

      test "#{action}: a 256-byte SESSION user id is 403 M_FORBIDDEN with the event-size-limit text, nothing is written", %{a: a} do
        action = unquote(action)
        long = long_user!(256)
        room = public_room(a)
        t = target_for(action, a, room)
        unchanged(room, t, fn -> assert_err(act(action, long, room, %{"user_id" => t.uid}), 403, "M_FORBIDDEN", @sender_text) end)
      end

      test "#{action}: an unknown room id is 404 M_NOT_FOUND \"Room not found\" and NO rooms row exists for it afterwards", %{a: a, b: b} do
        action = unquote(action)
        unknown = "!" <> T.rand(8) <> ":" <> T.server_name()
        assert_err(act(action, a, unknown, %{"user_id" => b.uid}), 404, "M_NOT_FOUND", "Room not found")
        assert rooms_row_count(unknown) == 0, "no rooms row is created for an unknown room id"
        assert Nebu.Matrix.Room.RoomSupervisor.lookup_room(unknown) == {:error, :not_found}, "no room process is started either"
      end

      test "#{action}: a room whose process is NOT running is 404 (parity with /invite and /join), nothing is written", %{a: a} do
        action = unquote(action)
        room = public_room(a)
        t = target_for(action, a, room)
        {:ok, pid} = Nebu.Matrix.Room.RoomSupervisor.lookup_room(room)
        :ok = Horde.DynamicSupervisor.terminate_child(Nebu.Matrix.Room.HordeSupervisor, pid)
        :ok = wait_until(fn -> Nebu.Matrix.Room.RoomSupervisor.lookup_room(room) == {:error, :not_found} end, 2_000)

        events = event_count(room)
        assert_err(act(action, a, room, %{"user_id" => t.uid}), 404, "M_NOT_FOUND", "Room not found")
        assert event_count(room) == events
        assert Nebu.Matrix.Room.RoomSupervisor.lookup_room(room) == {:error, :not_found}, "the route starts no room process"
      end
    end
  end

  # ═══ AC1 (c), (d): error bodies, unknown keys ══════════════════════════════════

  describe "AC1 (c) - every error body is exactly {errcode, error}, a fixed text without the target id or the reason" do
    test "each refusal carries no client value (target id, reason, room id) and has exactly two keys", %{a: a, b: b, c: c, d: d} do
      room = public_room(a)
      join!(b, room)
      join!(c, room)
      reason = marker("reason-secret")
      ok!(ban(a, room, d), "setup ban of d")
      outsider = user!("MRO")
      foreign = "@someone-" <> T.rand(3) <> ":other.example"

      refusals = [
        {:kick, outsider, c, 403, @not_member},
        {:kick, c, b, 403, power_text(:kick)},
        {:kick, a, a, 403, @not_lower},
        {:kick, a, d, 403, @banned_target},
        {:kick, a, foreign, 403, @not_in_room},
        {:ban, outsider, c, 403, @not_member},
        {:ban, c, b, 403, power_text(:ban)},
        {:ban, a, a, 403, @not_lower},
        {:ban, a, foreign, 403, @foreign_ban},
        {:unban, outsider, d, 403, @not_member},
        {:unban, c, d, 403, power_text(:unban)},
        {:unban, a, c, 403, @not_banned}
      ]

      for {action, sender, target, status, text} <- refusals do
        conn = act(action, sender, room, %{"user_id" => uid_of(target), "reason" => reason})
        assert_err(conn, status, "M_FORBIDDEN", text)
        refute_echo(conn, [uid_of(target), reason, room])
      end
    end
  end

  describe "AC1 (d) - the 3pid keys and any other unknown body keys are ignored (only user_id and reason are read)" do
    test "a ban body with 3pid keys and an unknown key is 200 and bans exactly the user_id", %{a: a, b: b, c: c} do
      room = public_room(a)
      join!(b, room)
      join!(c, room)

      body = %{"medium" => "email", "address" => "x@y.z", "id_server" => "id.example", "id_access_token" => "t", "foo" => %{"bar" => 1}}
      ok!(ban(a, room, b, body), "ban with extra keys")
      assert membership(room, b.uid) == "ban"
      assert membership(room, c.uid) == "join", "only the user_id was acted on"
    end

    test "the same extra keys on kick and unban are ignored", %{a: a, b: b, c: c} do
      room = public_room(a)
      join!(b, room)
      join!(c, room)
      extra = %{"medium" => "email", "address" => "x@y.z", "unknown" => [1, 2]}
      ok!(kick(a, room, b, extra), "kick with extra keys")
      ok!(ban(a, room, c), "setup ban")
      ok!(unban(a, room, c, extra), "unban with extra keys")
      assert membership(room, b.uid) == "leave"
      assert membership(room, c.uid) == "leave"
    end
  end

  # ═══ AC2 (HTTP part): the moderation tier ══════════════════════════════════════

  describe "AC2 - the per-user `moderation` tier (HTTP)" do
    test "with rate 1 and burst 2 the THIRD /ban of a user is 429 and writes nothing; another user is not affected", %{a: a, b: b, c: c, d: d} do
      Application.put_env(:nebu_http, :rate_limit_moderation_per_min, 1)
      Application.put_env(:nebu_http, :rate_limit_moderation_burst, 2)
      room = public_room(a)
      [t1, t2, t3] = for _ <- 1..3, do: user!("MRT")
      for t <- [t1, t2, t3], do: join!(t, room)
      join!(b, room)

      ok!(ban(a, room, t1), "first ban")
      ok!(ban(a, room, t2), "second ban")
      unchanged(room, t3, fn -> assert_429(ban(a, room, t3), "third ban") end)
      assert membership(room, t3.uid) == "join"

      # another user has his own bucket (b is joined at level 0: the 403 is the authorization answer, not a 429)
      assert_err(ban(b, room, t3), 403, "M_FORBIDDEN", power_text(:ban))
      assert tokens("moderation", c, 2) == 2.0 and tokens("moderation", d, 2) == 2.0
    end

    test "kick, ban and unban draw from the SAME bucket: two moderations of any kind empty it", %{a: a} do
      Application.put_env(:nebu_http, :rate_limit_moderation_per_min, 1)
      Application.put_env(:nebu_http, :rate_limit_moderation_burst, 2)
      room = public_room(a)
      [t1, t2] = for _ <- 1..2, do: user!("MRT")
      for t <- [t1, t2], do: join!(t, room)

      ok!(kick(a, room, t1), "kick")
      ok!(ban(a, room, t2), "ban")
      assert_429(unban(a, room, t2), "unban draws from the bucket the kick and the ban emptied")
      assert_429(kick(a, room, t1), "kick")
      assert_429(ban(a, room, t1), "ban")
    end

    test "the invite and join buckets are untouched by moderation, and the moderation bucket by invites and joins", %{a: a, b: b, c: c} do
      room = public_room(a)
      join!(b, room)
      ok!(ban(a, room, b), "ban")
      assert tokens("invite", a, 50) == 50.0, "a ban costs no invite unit"
      assert tokens("join", a, 30) == 30.0, "a ban costs no join unit"

      # vice versa: empty invite and join buckets do not block moderation
      join!(c, room)
      seed("invite", a, 0)
      seed("join", a, 0)
      ok!(kick(a, room, c), "kick with empty invite and join buckets")

      # and an invite / join costs no moderation unit
      before = tokens("moderation", a, 60)
      assert_429(invite(a, room, c), "the empty invite bucket refuses the invite")
      assert tokens("moderation", a, 60) == before
    end

    test "with :rate_limit_disabled the tier is disabled: an empty bucket does not refuse", %{a: a, b: b} do
      room = public_room(a)
      join!(b, room)
      seed("moderation", a, 0)
      Application.put_env(:nebu_http, :rate_limit_disabled, true)
      ok!(ban(a, room, b), "ban with the limiter disabled")
    end
  end

  # ═══ AC3: authorization ═════════════════════════════════════════════════════════

  describe "AC3 - a sender who is not joined is 403 \"You are not a member of this room\", nothing written" do
    for action <- @actions, state <- [:never_joined, :left, :banned, :only_invited] do
      test "#{action}: sender #{state}", %{a: a, c: c} do
        action = unquote(action)
        room = public_room(a)
        t = target_for(action, a, room)

        case unquote(state) do
          :never_joined ->
            :ok

          :left ->
            join!(c, room)
            leave!(c, room)

          :banned ->
            join!(c, room)
            ok!(ban(a, room, c), "setup: ban the sender")

          :only_invited ->
            invite!(a, room, c)
        end

        unchanged(room, t, fn -> assert_err(act(action, c, room, %{"user_id" => t.uid}), 403, "M_FORBIDDEN", @not_member) end)
      end
    end
  end

  describe "AC3 - a sender below the action level is 403 with the power level text, nothing written" do
    for action <- @actions do
      test "#{action}: a joined user at the default level 0 (level required 50)", %{a: a, c: c} do
        action = unquote(action)
        room = public_room(a)
        t = target_for(action, a, room)
        join!(c, room)
        unchanged(room, t, fn -> assert_err(act(action, c, room, %{"user_id" => t.uid}), 403, "M_FORBIDDEN", power_text(action)) end)
      end
    end

    test "unban needs BOTH the ban and the kick level: refused at 60 with kick 75 / ban 50 and with kick 50 / ban 75, allowed at both levels", %{a: a, c: c} do
      for {overrides, level, expected} <- [
            {%{"kick" => 75, "ban" => 50}, 60, 403},
            {%{"kick" => 50, "ban" => 75}, 60, 403},
            {%{"kick" => 75, "ban" => 50}, 75, 200},
            {%{"kick" => 50, "ban" => 75}, 75, 200}
          ] do
        room = level_room(a, %{c.uid => level}, overrides)
        join!(c, room)
        t = user!("MRT")
        join!(t, room)
        ok!(ban(a, room, t), "setup ban by the owner")

        conn = unchanged_if_refused(room, t, expected, fn -> unban(c, room, t) end)

        if expected == 403 do
          assert_err(conn, 403, "M_FORBIDDEN", power_text(:unban))
        else
          ok!(conn, "unban at #{level}")
          assert membership(room, t.uid) == "leave"
        end
      end
    end
  end

  defp unchanged_if_refused(room, t, 403, fun), do: unchanged(room, t, fun)
  defp unchanged_if_refused(_room, _t, _status, fun), do: fun.()

  # unban acts on banned users: the owner bans the PL-50 peer first; kick and ban act on the joined peer
  defp equal_level_peer(:unban, owner, room, peer) do
    ok!(ban(owner, room, peer), "setup: the owner bans the PL-50 peer")
    peer
  end

  defp equal_level_peer(_action, _owner, _room, peer), do: peer

  describe "AC3 - a target at an EQUAL or higher level is 403 \"You cannot act on a user whose power level is not lower than yours\"" do
    for action <- @actions do
      test "#{action}: PL 50 against PL 50, PL 50 against the creator at 100, the sender himself", %{a: a, b: b, c: c} do
        action = unquote(action)
        room = level_room(a, %{b.uid => 50, c.uid => 50})
        join!(b, room)
        join!(c, room)

        peer = equal_level_peer(action, a, room, c)

        unchanged(room, peer, fn -> assert_err(act(action, b, room, %{"user_id" => peer.uid}), 403, "M_FORBIDDEN", @not_lower) end)
        unchanged(room, a, fn -> assert_err(act(action, b, room, %{"user_id" => a.uid}), 403, "M_FORBIDDEN", @not_lower) end)
        unchanged(room, b, fn -> assert_err(act(action, b, room, %{"user_id" => b.uid}), 403, "M_FORBIDDEN", @not_lower) end)
      end
    end
  end

  describe "AC3 - trusted_private_chat: equal levels (100), neither can act on the other; private_chat: 100 against 0" do
    test "a trusted_private_chat DM: no revoke of the pending partner, after the join neither can kick or ban", %{a: a, b: b} do
      room = make_room(a, %{"preset" => "trusted_private_chat", "is_direct" => true, "invite" => [b.uid]})

      unchanged(room, b, fn -> assert_err(kick(a, room, b), 403, "M_FORBIDDEN", @not_lower) end)
      assert invitation_state(room, b.uid) == :pending, "the invitation is not revoked"

      join!(b, room)
      unchanged(room, b, fn -> assert_err(kick(a, room, b), 403, "M_FORBIDDEN", @not_lower) end)
      unchanged(room, b, fn -> assert_err(ban(a, room, b), 403, "M_FORBIDDEN", @not_lower) end)
      unchanged(room, a, fn -> assert_err(kick(b, room, a), 403, "M_FORBIDDEN", @not_lower) end)
      unchanged(room, a, fn -> assert_err(ban(b, room, a), 403, "M_FORBIDDEN", @not_lower) end)
    end

    test "a private_chat room: the creator (100) can kick, ban a member (0) and revoke a pending invitee", %{a: a, b: b, c: c, d: d} do
      room = make_room(a, %{"preset" => "private_chat", "invite" => [b.uid, c.uid, d.uid]})
      join!(b, room)
      join!(c, room)
      ok!(kick(a, room, b), "kick of a member")
      ok!(ban(a, room, c), "ban of a member")
      ok!(kick(a, room, d), "revocation of the pending invitee d")
    end
  end

  # ═══ AC4 (a): kick of a member ═══════════════════════════════════════════════════

  describe "AC4 (a) - kick of a member" do
    test "the member row is closed, the target leaves the member set, a pending row of him is rejected, ONE leave event {membership leave} (+ reason) with sender = kicker and state_key = target", %{a: a, b: b} do
      room = public_room(a)
      join!(b, room)
      row_only_invitation!(room, a, b)
      assert invitation_state(room, b.uid) == :pending
      before = member_events(room, b.uid)
      assert length(before) == 1

      ok!(kick(a, room, b, %{"reason" => "be nice"}), "kick")

      refute in_set?(room, b.uid)
      refute active_row?(room, b.uid)
      assert invitation_state(room, b.uid) == :rejected

      [join_ev, leave_ev] = member_events(room, b.uid)
      assert join_ev == hd(before)
      assert leave_ev.sender == a.uid
      assert leave_ev.content == %{"membership" => "leave", "reason" => "be nice"}
      assert leave_ev.ts > join_ev.ts
      assert T.sql!("SELECT event_type FROM events WHERE event_id = $1", [leave_ev.event_id]).rows == [["m.room.member"]]
    end

    test "a kick without a reason writes the content exactly {membership leave}", %{a: a, b: b} do
      room = public_room(a)
      join!(b, room)
      ok!(kick(a, room, b), "kick")
      assert [_join, leave_ev] = member_events(room, b.uid)
      assert leave_ev.content == %{"membership" => "leave"}
    end

    test "the kicked user can re-join a public room", %{a: a, b: b} do
      room = public_room(a)
      join!(b, room)
      ok!(kick(a, room, b), "kick")
      tick()
      assert join(b, room).status == 200
      assert in_set?(room, b.uid)
      assert membership(room, b.uid) == "join"
    end

    test "the kicked user cannot re-join an invite-only room without a new invitation, and can with one", %{a: a, b: b} do
      room = invite_room(a, [b])
      ok!(kick(a, room, b), "kick")
      assert_err(join(b, room), 403, "M_FORBIDDEN", @join_not_invited)
      invite!(a, room, b)
      tick()
      assert join(b, room).status == 200
    end
  end

  # ═══ AC4 (b), (c): revocation, kick of none / banned ═════════════════════════════

  describe "AC4 (b) - the revocation: a kick of a pending invitee" do
    test "with an invite event: the row is rejected, the leave event has sender != state_key, his /join is 403, his /sync no longer lists the invitation", %{a: a, b: b} do
      anchor = anchor_room!(b)
      token = snapshot!(b, anchor)
      room = make_room(a, %{"preset" => "private_chat"})
      invite!(a, room, b)
      s1 = sync(b, token)
      assert in_section?(s1, "invite", room), "positive control: the invitation is listed"

      tick()
      ok!(kick(a, room, b, %{"reason" => "changed my mind"}), "revoke")

      assert invitation_state(room, b.uid) == :rejected
      assert [invite_ev, leave_ev] = member_events(room, b.uid)
      assert invite_ev.content["membership"] == "invite"
      assert leave_ev.sender == a.uid and leave_ev.sender != b.uid
      assert leave_ev.content == %{"membership" => "leave", "reason" => "changed my mind"}
      assert leave_ev.ts > invite_ev.ts
      assert_err(join(b, room), 403, "M_FORBIDDEN", @join_not_invited)

      s2 = sync(b, next(s1))
      refute in_section?(s2, "invite", room), "the invitation is gone from rooms.invite"
      refute in_section?(sync(b), "invite", room)
    end

    test "a row-only invitation (written through InviteDB like upgrade_room does) is revoked the same way: a leave event is written, the row rejected", %{a: a, b: b} do
      room = make_room(a, %{"preset" => "private_chat"})
      row_only_invitation!(room, a, b)
      assert member_events(room, b.uid) == []

      ok!(kick(a, room, b), "revoke a row-only invitation")

      assert invitation_state(room, b.uid) == :rejected
      assert [leave_ev] = member_events(room, b.uid)
      assert leave_ev.sender == a.uid and leave_ev.content["membership"] == "leave"
      assert_err(join(b, room), 403, "M_FORBIDDEN", @join_not_invited)
    end

    test "a TAKEN-BACK invitation (a pending row behind a leave event at least as new, D13) counts as `none`: 403 \"The user is not in this room\", nothing written", %{a: a, b: b} do
      room = make_room(a, %{"preset" => "private_chat"})
      row_only_invitation!(room, a, b)
      insert_member_event!(room, b, "leave", b, ts_after(room))
      assert invitation_state(room, b.uid) == :pending

      unchanged(room, b, fn -> assert_err(kick(a, room, b), 403, "M_FORBIDDEN", @not_in_room) end)
    end

    test "an invitation that is already accepted or rejected is no pending invitation: kick is 403 \"The user is not in this room\"", %{a: a, b: b} do
      room = make_room(a, %{"preset" => "private_chat"})
      invite!(a, room, b)
      tick()
      assert leave(b, room).status == 200, "the invitee declines"
      assert invitation_state(room, b.uid) == :rejected
      unchanged(room, b, fn -> assert_err(kick(a, room, b), 403, "M_FORBIDDEN", @not_in_room) end)
    end
  end

  describe "AC4 (c) - kick of `none` and of a banned user" do
    test "a user who was never there, who left, an unknown local id and a foreign id: 403 \"The user is not in this room\", nothing written", %{a: a, b: b, c: c} do
      room = public_room(a)
      join!(c, room)
      leave!(c, room)
      unknown_local = T.user_id_for(%{"sub" => "atdd-nobody-" <> T.rand(4)})
      foreign = "@someone-" <> T.rand(3) <> ":other.example"

      for target <- [b, c, unknown_local, foreign] do
        unchanged(room, target, fn -> assert_err(kick(a, room, target), 403, "M_FORBIDDEN", @not_in_room) end)
      end
    end

    test "a banned user: 403 \"The user is banned from this room: unban them instead\"; the ban stays the latest membership", %{a: a, b: b} do
      room = public_room(a)
      join!(b, room)
      ok!(ban(a, room, b), "ban")
      ban_ev = List.last(member_events(room, b.uid))

      unchanged(room, b, fn -> assert_err(kick(a, room, b), 403, "M_FORBIDDEN", @banned_target) end)
      assert membership(room, b.uid) == "ban"
      assert List.last(member_events(room, b.uid)) == ban_ev
    end
  end

  # ═══ AC4 (d), (e): ban ═══════════════════════════════════════════════════════════

  describe "AC4 (d) - ban" do
    test "of a member: the ban event exists, the member is out of the set and the row closed", %{a: a, b: b} do
      room = public_room(a)
      join!(b, room)
      ok!(ban(a, room, b, %{"reason" => "spam"}), "ban")
      refute in_set?(room, b.uid)
      refute active_row?(room, b.uid)
      assert membership(room, b.uid) == "ban"
      assert %{sender: sender, content: %{"membership" => "ban", "reason" => "spam"}} = List.last(member_events(room, b.uid))
      assert sender == a.uid
    end

    test "of a pending invitee: the row is rejected, the latest membership is ban", %{a: a, b: b} do
      room = make_room(a, %{"preset" => "private_chat"})
      invite!(a, room, b)
      ok!(ban(a, room, b), "ban of an invitee")
      assert invitation_state(room, b.uid) == :rejected
      assert membership(room, b.uid) == "ban"
      assert memberships(room, b.uid) == ["invite", "ban"], "exactly ONE new event (invite -> ban)"
    end

    test "of a local user who left: 200, the latest membership is ban", %{a: a, b: b} do
      room = public_room(a)
      join!(b, room)
      leave!(b, room)
      ok!(ban(a, room, b), "ban of a user who left")
      assert membership(room, b.uid) == "ban"
      assert memberships(room, b.uid) == ["join", "leave", "ban"], "exactly ONE new event (leave -> ban)"
    end

    test "PRE-EMPTIVE: a local id with NO users row is banned (200, the ban event exists); the account created later cannot join and cannot be invited", %{a: a} do
      room = public_room(a)
      sub = "atdd-pre-" <> T.rand(5)
      uid = T.user_id_for(%{"sub" => sub})
      assert T.sql!("SELECT count(*) FROM users WHERE user_id = $1", [uid]).rows == [[0]], "premise: no users row"

      ok!(ban(a, room, uid), "pre-emptive ban")
      assert membership(room, uid) == "ban"
      assert T.sql!("SELECT count(*) FROM users WHERE user_id = $1", [uid]).rows == [[0]], "the ban path creates no users row"

      provisioned = T.provision_user!(sub)
      assert provisioned == uid
      later = %{uid: uid, at: T.legacy_session!(uid, "MRP" <> String.upcase(T.rand(3))).at}
      assert_err(join(later, room), 403, "M_FORBIDDEN", @join_banned)
      assert_err(invite(a, room, later), 403, "M_FORBIDDEN", @invite_banned)
    end

    test "of a foreign id: 403 \"Only users of this server can be banned\", nothing written", %{a: a} do
      room = public_room(a)
      foreign = "@someone-" <> T.rand(3) <> ":other.example"
      unchanged(room, foreign, fn -> assert_err(ban(a, room, foreign), 403, "M_FORBIDDEN", @foreign_ban) end)
    end

    test "no users-table read happens on the ban path (statement capture of the request and the room process)", %{a: a, b: b} do
      room = public_room(a)
      join!(b, room)
      sub = "atdd-nouser-" <> T.rand(5)
      uid = T.user_id_for(%{"sub" => sub})
      {:ok, room_pid} = Nebu.Matrix.Room.RoomSupervisor.lookup_room(room)

      for target <- [b.uid, uid] do
        req = %Core.BanUserRequest{room_id: room, caller_id: a.uid, target_id: target, reason: ""}

        {result, statements} =
          capture_statements(fn -> Nebu.Matrix.Http.call_core(fn -> Nebu.Matrix.EventDispatcher.Server.ban_user(req, Nebu.Matrix.Http.stream(a.uid)) end) end, [room_pid])

        assert {:ok, %Core.BanUserResponse{}} = result
        reads = Enum.filter(statements, &Regex.match?(~r/\b(from|join)\s+"?users"?\b/i, &1))
        assert reads == [], "the ban path must not read the users table: #{inspect(Enum.map(reads, &String.slice(&1, 0, 80)))}"
        assert statements != [], "positive control: the ban ran statements"
      end
    end
  end

  describe "AC4 (e) - ban of an already banned user" do
    test "is 200 and writes NO new event, also with another reason; the first ban's reason stands", %{a: a, b: b} do
      room = public_room(a)
      join!(b, room)
      ok!(ban(a, room, b, %{"reason" => "first"}), "first ban")
      events = event_count(room)
      member = member_events(room, b.uid)

      ok!(ban(a, room, b), "second ban")
      ok!(ban(a, room, b, %{"reason" => "second"}), "third ban with another reason")
      assert event_count(room) == events
      assert member_events(room, b.uid) == member
      assert List.last(member).content["reason"] == "first"
    end

    test "REPAIR of a legacy half state: an active room_members row and a pending invitation behind a latest ban are closed, still no event", %{a: a, b: b} do
      room = public_room(a)
      join!(b, room)
      ok!(ban(a, room, b), "ban")
      # the legacy half state of the old non-atomic code (N-6), written directly: an active row, a pending invitation, the latest event is the ban
      assert :ok = DB.insert_member(room, b.uid)
      row_only_invitation!(room, a, b)
      assert active_row?(room, b.uid) and invitation_state(room, b.uid) == :pending
      # a restart of the room process loads the active row into the in-memory member set: the member set ALSO holds the banned user
      kill_and_restart!(room)
      assert in_set?(room, b.uid), "premise: the legacy half state is in the member set"
      assert membership(room, b.uid) == "ban"
      events = event_count(room)

      ok!(ban(a, room, b), "repeated ban repairs")

      refute in_set?(room, b.uid), "the leftover member is out of the in-memory set"
      refute active_row?(room, b.uid), "the leftover member row is closed"
      assert invitation_state(room, b.uid) == :rejected, "the leftover invitation is rejected"
      assert event_count(room) == events, "no event is written"
      assert membership(room, b.uid) == "ban"
    end
  end

  # ═══ AC4 (f), (g): unban, reason ═════════════════════════════════════════════════

  describe "AC4 (f) - unban" do
    test "of a banned user: ONE leave event (sender = unbanner, the reason), a pending row rejected; the user can join a public room", %{a: a, b: b} do
      room = public_room(a)
      join!(b, room)
      ok!(ban(a, room, b), "ban")
      row_only_invitation!(room, a, b)
      before = length(member_events(room, b.uid))

      ok!(unban(a, room, b, %{"reason" => "forgiven"}), "unban")

      assert invitation_state(room, b.uid) == :rejected
      events = member_events(room, b.uid)
      assert length(events) == before + 1
      assert %{sender: sender, content: %{"membership" => "leave", "reason" => "forgiven"}} = List.last(events)
      assert sender == a.uid
      tick()
      assert join(b, room).status == 200
    end

    test "in an invite-only room the unbanned user needs a NEW invitation", %{a: a, b: b} do
      room = invite_room(a, [b])
      ok!(ban(a, room, b), "ban")
      ok!(unban(a, room, b), "unban")
      assert_err(join(b, room), 403, "M_FORBIDDEN", @join_not_invited)
      invite!(a, room, b)
      tick()
      assert join(b, room).status == 200
    end

    test "of a member, of a pending invitee and of a user who never was there: 403 \"The user is not banned from this room\", nothing written", %{a: a, b: b, c: c, d: d} do
      room = public_room(a)
      join!(b, room)
      invite!(a, room, c)

      for target <- [b, c, d] do
        unchanged(room, target, fn -> assert_err(unban(a, room, target), 403, "M_FORBIDDEN", @not_banned) end)
      end
    end
  end

  describe "AC4 (g) - the reason is stored exactly as sent, absent for \"\", null and no key" do
    for action <- @actions do
      test "#{action}: a multi-byte reason and a reason of exactly 1024 bytes are stored verbatim", %{a: a} do
        action = unquote(action)
        room = public_room(a)

        for reason <- ["Grüße, 日本語 \u{1F600} ok", String.duplicate("€", 341) <> "x", String.duplicate("r", 1024)] do
          t = target_for(action, a, room)
          conn = act(action, a, room, %{"user_id" => t.uid, "reason" => reason})
          ok!(conn, "#{action} with a #{byte_size(reason)}-byte reason")
          assert List.last(member_events(room, t.uid)).content["reason"] == reason
        end
      end

      test "#{action}: \"\", null and an absent reason write no `reason` key", %{a: a} do
        action = unquote(action)
        room = public_room(a)

        for extra <- [%{"reason" => ""}, %{"reason" => nil}, %{}] do
          t = target_for(action, a, room)
          ok!(act(action, a, room, Map.put(extra, "user_id", t.uid)), "#{action} #{inspect(extra)}")
          refute Map.has_key?(List.last(member_events(room, t.uid)).content, "reason"), "#{inspect(extra)}"
        end
      end
    end
  end

  # ═══ AC11 (HTTP part): reason validation ═════════════════════════════════════════

  describe "AC11 - reason validation (all three routes, nothing written, before any room check)" do
    for action <- @actions do
      test "#{action}: a reason that is a number, an array or an object is 400 M_BAD_JSON \"reason must be a string\"", %{a: a} do
        action = unquote(action)
        room = public_room(a)
        t = target_for(action, a, room)

        for value <- [5, ["x"], %{}, true] do
          unchanged(room, t, fn -> assert_err(act(action, a, room, %{"user_id" => t.uid, "reason" => value}), 400, "M_BAD_JSON", "reason must be a string") end)
        end
      end

      test "#{action}: a reason with U+0000 is 400 M_BAD_JSON \"reason must not contain NUL\" (not a 500)", %{a: a} do
        action = unquote(action)
        room = public_room(a)
        t = target_for(action, a, room)
        body = ~s({"user_id": #{Jason.encode!(t.uid)}, "reason": "a\\u0000b"})
        unchanged(room, t, fn -> assert_err(act_raw(action, a, enc(room), body), 400, "M_BAD_JSON", "reason must not contain NUL") end)
      end

      test "#{action}: 1025 and 1026 bytes (342 x euro) are 400 M_INVALID_PARAM \"reason exceeds 1024 bytes\" (bytes, not code points)", %{a: a} do
        action = unquote(action)
        room = public_room(a)
        t = target_for(action, a, room)

        for reason <- [String.duplicate("r", 1025), String.duplicate("€", 342)] do
          unchanged(room, t, fn ->
            conn = act(action, a, room, %{"user_id" => t.uid, "reason" => reason})
            assert_err(conn, 400, "M_INVALID_PARAM", "reason exceeds 1024 bytes")
            refute_echo(conn, [reason])
          end)
        end
      end

      test "#{action}: the reason is validated after the user_id and before the room lookup", %{a: a} do
        action = unquote(action)
        room = public_room(a)
        t = target_for(action, a, room)
        assert_err(act(action, a, room, %{"user_id" => "alice", "reason" => 5}), 400, "M_INVALID_PARAM", "user_id is not a valid user id")
        unknown = "!" <> T.rand(8) <> ":" <> T.server_name()
        assert_err(act(action, a, unknown, %{"user_id" => t.uid, "reason" => 5}), 400, "M_BAD_JSON", "reason must be a string")
      end
    end
  end

  # ═══ AC12: the sync side is fed ══════════════════════════════════════════════════

  describe "AC12 (a), (b) - the target's /sync after a kick or a ban" do
    test "kick: a long-poll started BEFORE the kick returns at once with the room in rooms.leave (kick event last); a later message is in no section", %{a: a, b: b} do
      room = public_room(a)
      join!(b, room)
      token = snapshot!(b, anchor_room!(b))

      poll = Task.async(fn -> sync_conn(b, since: token, timeout: 10_000) end)
      :ok = wait_until(fn -> :pg.get_members("user:#{b.uid}") != [] end, 5_000)
      ok!(kick(a, room, b, %{"reason" => "see you"}), "kick")

      conn = Task.await(poll, 3_000)
      assert conn.status == 200
      body = T.json(conn)
      assert in_section?(body, "leave", room)
      last = List.last(leave_timeline(body, room))
      assert last["type"] == "m.room.member" and last["state_key"] == b.uid
      assert last["sender"] == a.uid
      assert last["content"] == %{"membership" => "leave", "reason" => "see you"}

      say!(a, room, marker("after-kick"))
      later = sync(b, next(body))
      for name <- ["join", "leave", "invite"], do: refute(in_section?(later, name, room), "the room is in no section of his later sync (#{name})")
      assert in_section?(sync(a), "join", room), "positive control: the room is delivered to the member"
    end

    test "ban: the room is in rooms.leave with the ban event last (membership ban, sender, reason), delivered at once; a later message is in no section", %{a: a, b: b} do
      room = public_room(a)
      join!(b, room)
      token = snapshot!(b, anchor_room!(b))

      poll = Task.async(fn -> sync_conn(b, since: token, timeout: 10_000) end)
      :ok = wait_until(fn -> :pg.get_members("user:#{b.uid}") != [] end, 5_000)
      ok!(ban(a, room, b, %{"reason" => "spam"}), "ban")

      conn = Task.await(poll, 3_000)
      body = T.json(conn)
      assert in_section?(body, "leave", room)
      last = List.last(leave_timeline(body, room))
      assert last["content"] == %{"membership" => "ban", "reason" => "spam"}
      assert last["sender"] == a.uid and last["state_key"] == b.uid

      say!(a, room, marker("after-ban"))
      later = sync(b, next(body))
      for name <- ["join", "leave", "invite"], do: refute(in_section?(later, name, room), "the room is in no section of his later sync (#{name})")
    end
  end

  describe "AC12 (c) - a revoked invitee" do
    test "the room leaves rooms.invite and appears ONCE in rooms.leave with the revocation (sender = the kicker)", %{a: a, b: b} do
      room = make_room(a, %{"preset" => "private_chat"})
      token = snapshot!(b, anchor_room!(b))
      invite!(a, room, b)
      s1 = sync(b, token)
      assert in_section?(s1, "invite", room)

      tick()
      ok!(kick(a, room, b), "revoke")
      s2 = sync(b, next(s1))
      refute in_section?(s2, "invite", room)
      assert in_section?(s2, "leave", room)
      ev = member_ev(leave_timeline(s2, room), b.uid, "leave")
      assert ev["sender"] == a.uid

      s3 = sync(b, next(s2))
      refute in_section?(s3, "leave", room), "the leave is delivered once"
    end
  end

  describe "AC12 (d) - the events carry unsigned.prev_content / prev_sender of their predecessor" do
    test "a kick: prev_content is the join, prev_sender the target", %{a: a, b: b} do
      room = public_room(a)
      join!(b, room)
      token = snapshot!(a, anchor_room!(a))
      ok!(kick(a, room, b), "kick")
      body = sync(a, token)
      ev = member_ev(join_timeline(body, room), b.uid, "leave")
      assert ev, "the kick event is in the kicker's timeline"
      assert unsigned_of(ev)["prev_content"] == %{"membership" => "join"}
      assert unsigned_of(ev)["prev_sender"] == b.uid
      assert is_binary(unsigned_of(ev)["replaces_state"])
    end

    test "a revocation: prev_content is the invite, prev_sender the inviter", %{a: a, b: b} do
      room = make_room(a, %{"preset" => "private_chat"})
      invite!(a, room, b)
      token = snapshot!(a, anchor_room!(a))
      ok!(kick(a, room, b), "revoke")
      ev = member_ev(join_timeline(sync(a, token), room), b.uid, "leave")
      assert ev
      assert unsigned_of(ev)["prev_content"]["membership"] == "invite"
      assert unsigned_of(ev)["prev_sender"] == a.uid
    end

    test "an unban: prev_content is the ban", %{a: a, b: b} do
      room = public_room(a)
      join!(b, room)
      ok!(ban(a, room, b), "ban")
      token = snapshot!(a, anchor_room!(a))
      ok!(unban(a, room, b), "unban")
      ev = member_ev(join_timeline(sync(a, token), room), b.uid, "leave")
      assert ev
      assert unsigned_of(ev)["prev_content"] == %{"membership" => "ban"}
      assert unsigned_of(ev)["prev_sender"] == a.uid
    end
  end

  describe "AC12 (e) - forget" do
    test "a banned user may POST /forget the room (200) and it is hidden afterwards; an unban followed by a re-invite makes it visible again in rooms.invite", %{a: a, b: b} do
      room = public_room(a)
      join!(b, room)
      token = snapshot!(b, anchor_room!(b))
      ok!(ban(a, room, b), "ban")
      assert in_section?(sync(b, token), "leave", room), "positive control: the ban is delivered as a leave"

      ok!(forget(b, room), "forget of a banned room")
      for body <- [sync(b), sync(b, token)] do
        for name <- ["join", "leave", "invite"], do: refute(in_section?(body, name, room), "hidden after the forget (#{name})")
      end

      ok!(unban(a, room, b), "unban")
      tick()
      invite!(a, room, b)
      assert in_section?(sync(b), "invite", room), "a re-invite clears the forget"
    end
  end

  # ═══ AC13: bans are carried into the upgraded room ═══════════════════════════════

  defp upgrade(user, room), do: T.matrix_request(:post, path(room, "upgrade"), user.at, body: %{"new_version" => "10"})

  defp upgrade!(user, room) do
    conn = upgrade(user, room)
    assert conn.status == 200, "upgrade: #{conn.status} #{String.slice(conn.resp_body, 0, 200)}"
    T.json(conn)["replacement_room"]
  end

  defp events_of(room, type) do
    T.sql!("SELECT event_id, sender, state_key, content, origin_server_ts FROM events WHERE room_id = $1 AND event_type = $2 ORDER BY origin_server_ts, event_id", [room, type]).rows
    |> Enum.map(fn [id, sender, key, content, ts] -> %{event_id: id, sender: sender, state_key: key, content: content_of(content), ts: ts} end)
  end

  describe "AC13 - the upgrade carries the bans (D11)" do
    test "two bans (reason, pre-emptive) and a kick: two ban events by the upgrader BEFORE the join rule, banned cannot join, kicked can, bans_carried 2", %{a: a, b: b, c: c, d: d} do
      room = public_room(a)
      for u <- [b, c, d], do: join!(u, room)
      ok!(ban(a, room, b, %{"reason" => "spam"}), "ban with a reason")
      pre_sub = "atdd-upg-" <> T.rand(5)
      pre = T.user_id_for(%{"sub" => pre_sub})
      ok!(ban(a, room, pre), "pre-emptive ban")
      ok!(kick(a, room, c), "kick")

      new_room = upgrade!(a, room)

      bans = events_of(new_room, "m.room.member") |> Enum.filter(&(&1.content["membership"] == "ban"))
      assert Enum.sort(Enum.map(bans, & &1.state_key)) == Enum.sort([b.uid, pre])
      assert Enum.all?(bans, &(&1.sender == a.uid)), "the bans are issued in the upgrader's own name"
      assert Enum.find(bans, &(&1.state_key == b.uid)).content == %{"membership" => "ban", "reason" => "spam"}
      assert Enum.find(bans, &(&1.state_key == pre)).content == %{"membership" => "ban"}

      assert [join_rules] = events_of(new_room, "m.room.join_rules")
      assert Enum.all?(bans, &(&1.ts <= join_rules.ts)), "the bans are not stamped after the copied join rule"

      # the stamps may tie within one millisecond: the insertion order (transaction id of the row) proves "BEFORE"
      xmin = fn id -> T.sql!("SELECT xmin::text::bigint FROM events WHERE event_id = $1", [id]).rows |> hd() |> hd() end
      assert Enum.all?(bans, &(xmin.(&1.event_id) < xmin.(join_rules.event_id))), "the bans are written BEFORE the copied join rule"

      assert_err(join(b, new_room), 403, "M_FORBIDDEN", @join_banned)
      assert T.provision_user!(pre_sub) == pre
      pre_user = %{uid: pre, at: T.legacy_session!(pre, "MRU" <> String.upcase(T.rand(3))).at}
      assert_err(join(pre_user, new_room), 403, "M_FORBIDDEN", @join_banned)
      assert join(c, new_room).status == 200, "the kicked user can join the (public) new room"

      assert [%{metadata: metadata}] =
               T.sql!("SELECT metadata FROM audit_log WHERE action = 'room_upgraded' AND target_id = $1 AND outcome = 'success'", [room]).rows
               |> Enum.map(fn [m] -> %{metadata: content_of(m)} end)

      assert metadata["bans_carried"] == 2
      assert metadata["new_room_id"] == new_room
      assert audit_rows(new_room) == [], "the upgrade copies are not audited as room_member_banned"
    end

    test "a legacy ban reason that fails D10 (2 000 bytes, a non-string) is carried WITHOUT the reason", %{a: a, b: b, c: c} do
      room = public_room(a)
      for u <- [b, c], do: join!(u, room)
      ok!(ban(a, room, b), "ban b")
      ok!(ban(a, room, c), "ban c")
      # rewrite the two ban events' reasons directly (what an older code path could have stored)
      long = String.duplicate("r", 2_000)
      later = ts_after(room)
      insert_member_event!(room, b, "ban", a, later, %{"reason" => long})
      insert_member_event!(room, c, "ban", a, later, %{"reason" => 5})

      new_room = upgrade!(a, room)
      bans = events_of(new_room, "m.room.member") |> Enum.filter(&(&1.content["membership"] == "ban"))
      assert length(bans) == 2
      for ban_ev <- bans, do: assert(ban_ev.content == %{"membership" => "ban"}, "the invalid legacy reason is dropped")
    end

    test "the banned users of the old room get NO row-only invitation and no invite event in the new room; the old members do (AC19 j)", %{a: a, b: b, c: c, d: d} do
      room = public_room(a)
      for u <- [b, c, d], do: join!(u, room)
      ok!(ban(a, room, b), "ban b")

      new_room = upgrade!(a, room)

      assert invitation_state(new_room, b.uid) == :none, "ban -> invite must never happen"
      assert Enum.filter(member_events(new_room, b.uid), &(&1.content["membership"] == "invite")) == []
      assert invitation_state(new_room, c.uid) == :pending
      assert invitation_state(new_room, d.uid) == :pending
    end

    test "a failing banned_members/1 read fails the upgrade with 500 BEFORE the tombstone: the old room has no tombstone, no new room is left behind", %{a: a, b: b} do
      room = public_room(a)
      join!(b, room)
      ok!(ban(a, room, b), "ban")
      rooms_before = T.sql!("SELECT count(*) FROM events WHERE sender = $1 AND event_type = 'm.room.create'", [a.uid]).rows

      inject_faulty_db!(:banned_members)
      conn = upgrade(a, room)
      assert conn.status == 500, "#{conn.status} #{String.slice(conn.resp_body, 0, 200)}"
      assert T.json(conn)["errcode"] == "M_UNKNOWN"

      assert events_of(room, "m.room.tombstone") == [], "the tombstone is not written"
      assert T.sql!("SELECT count(*) FROM events WHERE sender = $1 AND event_type = 'm.room.create'", [a.uid]).rows == rooms_before, "no new room"
    end

    test "a failing ban copy fails the upgrade (500): the new room has no join rule and no invitation (closed)", %{a: a, b: b, c: c} do
      room = public_room(a)
      for u <- [b, c], do: join!(u, room)
      ok!(ban(a, room, b), "ban")

      inject_faulty_db!({:apply_member_change_for_ban, room})
      conn = upgrade(a, room)
      assert conn.status == 500, "#{conn.status} #{String.slice(conn.resp_body, 0, 200)}"

      assert [[metadata]] = T.sql!("SELECT metadata FROM audit_log WHERE action = 'room_upgraded' AND target_id = $1 AND outcome = 'failure'", [room]).rows
      new_room = content_of(metadata)["new_room_id"]
      assert is_binary(new_room)
      assert events_of(new_room, "m.room.join_rules") == [], "the new room has no join rule: nobody can join"
      assert T.sql!("SELECT count(*) FROM room_invitations WHERE room_id = $1", [new_room]).rows == [[0]]
    end
  end

  # a db module that delegates EVERYTHING to Room.DB except one injected fault; installed into every seam a dev could have used for
  # the read / the writes (the dispatcher's rooms and messages seams and the room process' db module)
  defp inject_faulty_db!(fault) do
    Application.put_env(:nebu, :atdd_mod_fault, fault)
    on_exit(fn -> Application.delete_env(:nebu, :atdd_mod_fault) end)

    for {app, key} <- [event_dispatcher: :rooms_db_module, event_dispatcher: :messages_db_module, room_manager: :db_module] do
      Application.put_env(app, key, Nebu.Matrix.ModerationRoutesHttpTest.FaultyDB)
    end
  end

  defmodule FaultyDB do
    @moduledoc false
    alias Nebu.Matrix.Room.DB

    for {name, arity} <- DB.__info__(:functions), name not in [:banned_members, :apply_member_change] do
      args = Macro.generate_arguments(arity, __MODULE__)
      def unquote(name)(unquote_splicing(args)), do: apply(DB, unquote(name), unquote(args))
    end

    def banned_members(room_id) do
      case Application.get_env(:nebu, :atdd_mod_fault) do
        :banned_members -> {:error, :atdd_read_failed}
        _ -> apply(DB, :banned_members, [room_id])
      end
    end

    def apply_member_change(room_id, user_id, event, opts) do
      case {Application.get_env(:nebu, :atdd_mod_fault), event} do
        {{:apply_member_change_for_ban, old_room}, %{"content" => %{"membership" => "ban"}}} when room_id != old_room -> {:error, :atdd_write_failed}
        _ -> apply(DB, :apply_member_change, [room_id, user_id, event, opts])
      end
    end
  end

  # ═══ AC14: audit ═════════════════════════════════════════════════════════════════

  defmodule RaisingAudit do
    @moduledoc false
    def log(_actor, _action, _type, _target, _metadata, _outcome, _detail \\ nil), do: raise("atdd: the audit writer raised")
  end

  defmodule ErrorAudit do
    @moduledoc false
    def log(_actor, _action, _type, _target, _metadata, _outcome, _detail \\ nil), do: {:error, :audit_write_failed}
  end

  describe "AC14 - audit rows (D12)" do
    test "a committed kick, ban and unban write exactly one row each: actor, resource room, the room id, metadata exactly the user id (kick: + invitation_revoked), outcome success", %{a: a, b: b, c: c, d: d} do
      room = invite_room(a, [b, c])
      invite!(a, room, d)

      ok!(kick(a, room, b), "kick of a member")
      ok!(kick(a, room, d), "revocation")
      ok!(ban(a, room, c), "ban")
      ok!(unban(a, room, c), "unban")

      rows = audit_rows(room)
      assert Enum.map(rows, & &1.action) == ["room_member_kicked", "room_member_kicked", "room_member_banned", "room_member_unbanned"]

      for row <- rows do
        assert row.actor == a.uid
        assert row.target_type == "room"
        assert row.target_id == room
        assert row.outcome == "success"
      end

      [kick_member, kick_revoke, banned, unbanned] = rows
      assert kick_member.metadata == %{"user_id" => b.uid, "invitation_revoked" => false}
      assert kick_revoke.metadata == %{"user_id" => d.uid, "invitation_revoked" => true}
      assert banned.metadata == %{"user_id" => c.uid}
      assert unbanned.metadata == %{"user_id" => c.uid}
    end

    test "the three actions are in the AuditWriter allowlist (log/6 returns :ok for them, never :audit_unknown_action)", %{a: a} do
      room = "!audit-pin-" <> T.rand(6) <> ":" <> T.server_name()

      for action <- ~w(room_member_kicked room_member_banned room_member_unbanned) do
        result = Nebu.Compliance.AuditWriter.log(a.uid, action, "room", room, %{"user_id" => "@x:y"}, "success")
        assert result == :ok, "#{action} must be a known action and be written, got #{inspect(result)}"
      end

      on_exit(fn -> Ecto.Adapters.SQL.query(Nebu.Repo, "DELETE FROM audit_log WHERE target_id = $1", [room]) end)
    end

    test "no row for a refusal and none for the ban no-op", %{a: a, b: b, c: c} do
      room = public_room(a)
      join!(b, room)
      join!(c, room)
      assert_err(kick(c, room, b), 403, "M_FORBIDDEN", power_text(:kick))
      assert_err(unban(a, room, b), 403, "M_FORBIDDEN", @not_banned)
      assert audit_rows(room) == []

      ok!(ban(a, room, b), "ban")
      ok!(ban(a, room, b), "the no-op")
      assert Enum.map(audit_rows(room), & &1.action) == ["room_member_banned"], "the idempotent ban is not audited"
    end

    test "a failing audit writer (it raises, or it returns an error) does not fail the action: 200 and a value-free ERROR log", %{a: a} do
      for writer <- [RaisingAudit, ErrorAudit] do
        room = public_room(a)
        t = user!("MRT")
        join!(t, room)
        reason = marker("audit-reason")

        log =
          capture_log([level: :debug], fn ->
            Application.put_env(:compliance, :audit_writer, writer)

            try do
              ok!(ban(a, room, t, %{"reason" => reason}), "ban with a failing audit writer (#{inspect(writer)})")
            after
              Application.put_env(:compliance, :audit_writer, Nebu.Compliance.AuditWriter)
            end
          end)

        assert membership(room, t.uid) == "ban", "the action stands"
        assert log =~ "[error]", "the failure is logged at ERROR"
        refute log =~ reason, "no reason text in any log line"
        refute log =~ t.uid, "no target id in any log line"
      end
    end

    test "no reason text appears in the audit row or in any log line of kick, ban and unban", %{a: a, b: b, c: c} do
      room = public_room(a)
      join!(b, room)
      join!(c, room)
      reason = marker("sensitive-reason")

      log =
        capture_log([level: :debug], fn ->
          ok!(kick(a, room, b, %{"reason" => reason}), "kick")
          ok!(ban(a, room, c, %{"reason" => reason}), "ban")
          ok!(unban(a, room, c, %{"reason" => reason}), "unban")
        end)

      refute log =~ reason
      for row <- audit_rows(room), do: refute(inspect(row) =~ reason)
      assert length(audit_rows(room)) == 3
    end
  end

  # ═══ AC19: the Oracle tests ══════════════════════════════════════════════════════

  describe "AC19 (a) - self-moderation and the banned sender" do
    test "a self-kick of the PL-100 creator is 403 \"You cannot act on a user whose power level is not lower than yours\" (Nebu choice), nothing written", %{a: a} do
      room = public_room(a)
      unchanged(room, a, fn -> assert_err(kick(a, room, a), 403, "M_FORBIDDEN", @not_lower) end)
    end

    test "a self-ban is the same 403", %{a: a} do
      room = public_room(a)
      unchanged(room, a, fn -> assert_err(ban(a, room, a), 403, "M_FORBIDDEN", @not_lower) end)
    end

    test "an unban by a BANNED sender of another banned user is 403 \"You are not a member of this room\"", %{a: a, b: b, c: c} do
      room = public_room(a)
      join!(b, room)
      join!(c, room)
      ok!(ban(a, room, b), "ban b")
      ok!(ban(a, room, c), "ban c")
      unchanged(room, c, fn -> assert_err(unban(b, room, c), 403, "M_FORBIDDEN", @not_member) end)
    end
  end

  describe "AC19 (b) - the levels of non-members count" do
    test "an unban of a banned user whose `users` level is >= the sender's is 403 (target not lower)", %{a: a, b: b, c: c} do
      room = level_room(a, %{b.uid => 50, c.uid => 50})
      join!(b, room)
      join!(c, room)
      ok!(ban(a, room, c), "the owner bans the PL-50 user")
      unchanged(room, c, fn -> assert_err(unban(b, room, c), 403, "M_FORBIDDEN", @not_lower) end)
      assert membership(room, c.uid) == "ban"
    end

    test "a pre-emptive ban of a non-member listed in `users` at a level >= the sender's is 403 (target not lower)", %{a: a, b: b} do
      listed = T.user_id_for(%{"sub" => "atdd-listed-" <> T.rand(4)})
      room = level_room(a, %{b.uid => 50, listed => 50})
      join!(b, room)
      unchanged(room, listed, fn -> assert_err(ban(b, room, listed), 403, "M_FORBIDDEN", @not_lower) end)
      assert membership(room, listed) == nil
    end
  end

  describe "AC19 (c) - boundaries and users_default" do
    test "a sender EXACTLY at the kick level (60) / ban level (70) is allowed, one below (59 / 69) is refused", %{a: a} do
      senders = for {name, level} <- [k60: 60, k59: 59, b70: 70, b69: 69], into: %{}, do: {name, {user!("MRS"), level}}
      room = level_room(a, Map.new(senders, fn {_n, {u, level}} -> {u.uid, level} end), %{"kick" => 60, "ban" => 70})
      for {_name, {u, _}} <- senders, do: join!(u, room)

      [t1, t2, t3, t4] = for _ <- 1..4, do: target_for(:kick, a, room)
      {k60, _} = senders.k60
      {k59, _} = senders.k59
      {b70, _} = senders.b70
      {b69, _} = senders.b69

      ok!(kick(k60, room, t1), "kick at exactly the kick level")
      unchanged(room, t2, fn -> assert_err(kick(k59, room, t2), 403, "M_FORBIDDEN", power_text(:kick)) end)
      ok!(ban(b70, room, t3), "ban at exactly the ban level")
      unchanged(room, t4, fn -> assert_err(ban(b69, room, t4), 403, "M_FORBIDDEN", power_text(:ban)) end)
    end

    test "a non-zero users_default (10) counts as the target's level: a sender at 10 cannot kick a default user, at 11 with kick 10 he can", %{a: a} do
      s10 = user!("MRS")
      s11 = user!("MRS")
      room = level_room(a, %{s11.uid => 11}, %{"users_default" => 10, "kick" => 10, "ban" => 10})
      join!(s10, room)
      join!(s11, room)
      t1 = target_for(:kick, a, room)
      t2 = target_for(:kick, a, room)

      unchanged(room, t1, fn -> assert_err(kick(s10, room, t1), 403, "M_FORBIDDEN", @not_lower) end)
      ok!(kick(s11, room, t2), "a sender at 11 against a default user at 10")
    end
  end

  describe "AC19 (d) - the inviter with only the invite level cannot revoke" do
    test "a plain member (invite level 0, below kick) who invited b cannot kick-revoke him: 403 with the power level text, the row stays pending", %{a: a, b: b, c: c} do
      room = public_room(a)
      join!(c, room)
      invite!(c, room, b)
      assert invitation_state(room, b.uid) == :pending
      unchanged(room, b, fn -> assert_err(kick(c, room, b), 403, "M_FORBIDDEN", power_text(:kick)) end)
      assert invitation_state(room, b.uid) == :pending
    end
  end

  describe "AC19 (e) - a pre-emptive ban event has no unsigned.prev_content / prev_sender" do
    test "in /sync and in /messages (the spec: absent = the previous membership was leave)", %{a: a} do
      room = public_room(a)
      uid = T.user_id_for(%{"sub" => "atdd-nopred-" <> T.rand(5)})
      token = snapshot!(a, anchor_room!(a))
      ok!(ban(a, room, uid), "pre-emptive ban")
      assert [only] = member_events(room, uid)
      assert only.content["membership"] == "ban"

      sync_ev = member_ev(join_timeline(sync(a, token), room), uid, "ban")
      assert sync_ev, "the ban event is in the moderator's incremental sync"
      for key <- ["prev_content", "prev_sender"], do: refute(Map.has_key?(unsigned_of(sync_ev), key), "sync: no #{key}")

      msg_ev = member_ev(messages(a, room), uid, "ban")
      assert msg_ev, "the ban event is in /messages"
      for key <- ["prev_content", "prev_sender"], do: refute(Map.has_key?(unsigned_of(msg_ev), key), "messages: no #{key}")
    end
  end

  describe "AC19 (f) - a second /unban right after the first" do
    test "is 403 \"The user is not banned from this room\", the event count is unchanged, no second audit row", %{a: a, b: b} do
      room = public_room(a)
      join!(b, room)
      ok!(ban(a, room, b), "ban")
      ok!(unban(a, room, b), "first unban")
      events = event_count(room)
      audits = audit_rows(room)

      assert_err(unban(a, room, b), 403, "M_FORBIDDEN", @not_banned)
      assert event_count(room) == events
      assert audit_rows(room) == audits
    end
  end

  describe "AC19 (g) - authentication" do
    for action <- @actions do
      test "#{action}: no access token is 401 M_MISSING_TOKEN, an invalid token 401 M_UNKNOWN_TOKEN, nothing is written and no moderation unit is charged", %{a: a, b: b} do
        action = unquote(action)
        room = public_room(a)
        t = target_for(action, a, room)
        body = Jason.encode!(%{"user_id" => t.uid})

        before = {tokens("moderation", a, 60), tokens("moderation", b, 60)}

        unchanged(room, t, fn ->
          no_token =
            Plug.Test.conn(:post, path(room, to_string(action)), body)
            |> Plug.Conn.put_req_header("content-type", "application/json")
            |> Map.put(:remote_ip, T.unique_ip())
            |> Nebu.Web.Router.call(Nebu.Web.Router.init([]))

          assert_err(no_token, 401, "M_MISSING_TOKEN")

          bad_token = act(action, %{at: "not-a-token-" <> T.rand(6)}, room, %{"user_id" => t.uid})
          assert_err(bad_token, 401, "M_UNKNOWN_TOKEN")
        end)

        assert {tokens("moderation", a, 60), tokens("moderation", b, 60)} == before, "the auth plug runs first: nobody was charged"
      end
    end
  end

  describe "AC19 (h) - /forget after a kick" do
    test "a kicked (not banned) user: 200 and hidden; a still-joined user: 400 M_BAD_STATE", %{a: a, b: b, c: c} do
      room = public_room(a)
      join!(b, room)
      join!(c, room)
      token = snapshot!(b, anchor_room!(b))
      ok!(kick(a, room, b), "kick")

      assert in_section?(sync(b, token), "leave", room), "positive control: the kick is delivered as a leave"
      ok!(forget(b, room), "forget after a kick")

      for body <- [sync(b), sync(b, token)] do
        for name <- ["join", "leave", "invite"], do: refute(in_section?(body, name, room), "hidden (#{name})")
      end

      conn = forget(c, room)
      assert_err(conn, 400, "M_BAD_STATE")
    end
  end

  describe "AC19 (i) - after an unban" do
    test "a member can invite the user again (200, a new invite event stamped after the unban leave); his direct join of an invite-only room without the invitation is 403, with it 200", %{a: a, b: b} do
      room = invite_room(a, [b])
      ok!(ban(a, room, b), "ban")
      ok!(unban(a, room, b), "unban")
      unban_ev = List.last(member_events(room, b.uid))

      assert_err(join(b, room), 403, "M_FORBIDDEN", @join_not_invited)

      assert invite(a, room, b).status == 200, "the unbanned user can be invited again"
      invite_ev = List.last(member_events(room, b.uid))
      assert invite_ev.content["membership"] == "invite"
      assert invite_ev.ts > unban_ev.ts, "the invite is stamped after the unban leave"

      tick()
      assert join(b, room).status == 200
    end
  end

  describe "AC19 (k) - percent-encoded room ids in the path" do
    for action <- @actions do
      test "#{action}: !abc%3Aserver and the fully encoded %21abc%3Aserver work like /invite, an encoding of an unknown room is 404", %{a: a} do
        action = unquote(action)
        room = public_room(a)

        for form <- [String.replace(room, ":", "%3A"), URI.encode_www_form(room)] do
          t = target_for(action, a, room)
          conn = act_raw(action, a, form, Jason.encode!(%{"user_id" => t.uid}))
          ok!(conn, "#{action} with the path form #{form}")
        end

        unknown = "!" <> T.rand(8) <> ":" <> T.server_name()
        t = user!("MRT")

        for form <- [String.replace(unknown, ":", "%3A"), URI.encode_www_form(unknown)] do
          assert_err(act_raw(action, a, form, Jason.encode!(%{"user_id" => t.uid})), 404, "M_NOT_FOUND", "Room not found")
        end
      end
    end
  end

  describe "AC19 (l) - a ban of a joined user writes EXACTLY ONE member event" do
    test "join -> ban, no separate leave before it; its unsigned.prev_content is the join", %{a: a, b: b} do
      room = public_room(a)
      join!(b, room)
      token = snapshot!(a, anchor_room!(a))
      ok!(ban(a, room, b), "ban of a joined user")

      assert memberships(room, b.uid) == ["join", "ban"], "exactly one new member event"
      ev = member_ev(join_timeline(sync(a, token), room), b.uid, "ban")
      assert ev
      assert unsigned_of(ev)["prev_content"] == %{"membership" => "join"}
      assert unsigned_of(ev)["prev_sender"] == b.uid
    end
  end

  # ═══ statement capture (telemetry of the repo, the test process and the given room process) ═══

  def handle_query(_event, _measurements, %{query: query}, %{pid: pid, allow: allow}) do
    mine? = self() == pid or pid in (Process.get(:"$callers") || []) or self() in allow
    if mine?, do: send(pid, {:statement, query})
    :ok
  end

  def handle_query(_event, _measurements, _metadata, _config), do: :ok

  defp capture_statements(fun, allow) do
    id = "mod-http-#{T.rand(6)}"
    :ok = :telemetry.attach(id, [:nebu, :repo, :query], &__MODULE__.handle_query/4, %{pid: self(), allow: allow})

    try do
      result = fun.()
      {result, drain([])}
    after
      :telemetry.detach(id)
    end
  end

  defp drain(acc) do
    receive do
      {:statement, query} -> drain([query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
