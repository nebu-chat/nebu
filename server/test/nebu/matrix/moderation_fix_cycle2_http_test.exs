defmodule Nebu.Matrix.ModerationFixCycle2HttpTest do
  @moduledoc """
  Story `moderation-routes-atomic-ban`, review cycle 2 (Kassandra L-5: freeze first; code review MINOR-4), REAL database through
  `Nebu.Web.Router`, the real `Room.Server` / `Room.DB`. `async: false`.

    * L-5 (i): the upgrade archives and stops the old room right after the tombstone and reads its bans and members ONCE afterwards:
      a ban, a join and an invite committed in the window before the freeze end at `ban` / are carried / are refused; after the freeze
      the old room takes no moderation.
    * L-5 (i), failure after the freeze: a failing ban copy fails the upgrade (500) with no invitation in the new room (no banned user
      is invited) and the old room archived and stopped.
    * L-5 (iii): an ARCHIVED room refuses every moderation, invite-event and decline write, also while its process still runs (moderation and the invite event
      answer 404 like a room that is not running, nothing written); the archived-room decline still works.
    * MINOR-4: `Room.DB.banned_members/1` reads the `reason` from both JSONB forms; a non-string reason is nil; an unparseable string
      body is no ban and never an error.
  """
  use ExUnit.Case, async: false

  import Nebu.Matrix.ModerationTestSupport

  alias Nebu.Matrix.Room.DB
  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration
  @moduletag timeout: 120_000

  setup do
    T.reset_rate_limits()
    Nebu.Test.ServerName.pin!(T.server_name())

    keys = [event_dispatcher: :rooms_db_module, room_manager: :db_module, nebu: :atdd_c2_hook, nebu: :atdd_c2_fail_ban_copy, compliance: :audit_writer]
    seams = for {app, key} <- keys, do: {app, key, Application.fetch_env(app, key)}
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

    {:ok, a: user!("MDA"), b: user!("MDB"), c: user!("MDC"), d: user!("MDD")}
  end

  defp upgrade(user, room), do: T.matrix_request(:post, path(room, "upgrade"), user.at, body: %{"new_version" => "10"})

  defp room_status(room), do: T.sql!("SELECT status FROM rooms WHERE room_id = $1", [room]).rows

  # delegates to Room.DB; (1) the FIRST banned_members/1 read of the armed room (the cheap pre-tombstone read) runs the armed hook right
  # after it answered: the window in which the old room still accepts changes; (2) `:atdd_c2_fail_ban_copy` = the old room id makes the
  # ban copies into any OTHER room fail (installed into the room process seam too)
  defmodule WindowDB do
    @moduledoc false
    alias Nebu.Matrix.Room.DB

    for {name, arity} <- DB.__info__(:functions), name not in [:banned_members, :apply_member_change] do
      args = Macro.generate_arguments(arity, __MODULE__)
      def unquote(name)(unquote_splicing(args)), do: apply(DB, unquote(name), unquote(args))
    end

    def banned_members(room_id) do
      result = DB.banned_members(room_id)

      case Application.get_env(:nebu, :atdd_c2_hook) do
        {^room_id, hook} ->
          Application.delete_env(:nebu, :atdd_c2_hook)
          hook.()

        _ ->
          :ok
      end

      result
    end

    def apply_member_change(room_id, user_id, event, opts) do
      case {Application.get_env(:nebu, :atdd_c2_fail_ban_copy), event} do
        {old_room, %{"content" => %{"membership" => "ban"}}} when is_binary(old_room) and room_id != old_room -> {:error, :atdd_copy_failed}
        _ -> DB.apply_member_change(room_id, user_id, event, opts)
      end
    end
  end

  defp install_window_db!(room_manager? \\ false) do
    Application.put_env(:event_dispatcher, :rooms_db_module, WindowDB)
    if room_manager?, do: Application.put_env(:room_manager, :db_module, WindowDB)
  end

  # ═══ L-5 (i): the window before the freeze ═══════════════════════════════════════════════════════

  describe "L-5 freeze first" do
    test "window ban / join / invite: ban carried, banned user never invited, joiner invited, banned join and invite refused; frozen room takes no moderation", %{a: a, b: b, c: c, d: d} do
      room = public_room(a)
      join!(b, room)
      join!(c, room)
      install_window_db!()
      parent = self()

      hook = fn ->
        :ok = Nebu.Matrix.Room.Server.moderate(room, :ban, a.uid, b.uid, "in the window")
        send(parent, {:window, :join_banned, join(b, room).status})
        send(parent, {:window, :invite_banned, invite(a, room, b).status})
        send(parent, {:window, :join_new, join(d, room).status})
      end

      Application.put_env(:nebu, :atdd_c2_hook, {room, hook})

      conn = upgrade(a, room)
      assert conn.status == 200, "#{conn.status} #{String.slice(conn.resp_body, 0, 200)}"
      new_room = T.json(conn)["replacement_room"]

      assert_received {:window, :join_banned, 403}
      assert_received {:window, :invite_banned, 403}
      assert_received {:window, :join_new, 200}

      assert membership(new_room, b.uid) == "ban", "the ban of the window is carried"
      assert invitation_state(new_room, b.uid) == :none, "a banned user is never invited (no window with a pending row)"
      assert_err(join(b, new_room), 403, "M_FORBIDDEN", "You are banned from this room")
      assert invitation_state(new_room, c.uid) == :pending
      assert invitation_state(new_room, d.uid) == :pending, "the member who joined in the window is invited: the members are read after the freeze"

      # the bans precede the copied join rule and every invitation
      [[ban_xmin]] = T.sql!("SELECT max(xmin::text::bigint) FROM events WHERE room_id = $1 AND event_type = 'm.room.member' AND content->>'membership' = 'ban'", [new_room]).rows
      [[rule_xmin]] = T.sql!("SELECT min(xmin::text::bigint) FROM events WHERE room_id = $1 AND event_type = 'm.room.join_rules'", [new_room]).rows
      assert ban_xmin < rule_xmin

      # frozen: archived, process stopped, no moderation possible any more
      assert room_status(room) == [["archived"]]
      assert Nebu.Matrix.Room.RoomSupervisor.lookup_room(room) == {:error, :not_found}
      before = footprint_db(room, c.uid)
      assert_err(ban(a, room, c), 404, "M_NOT_FOUND", "Room not found")
      assert footprint_db(room, c.uid) == before
    end

    test "a failing ban copy after the freeze: 500, no invitation in the new room, old room archived and stopped", %{a: a, b: b, c: c} do
      room = public_room(a)
      join!(b, room)
      join!(c, room)
      ok!(ban(a, room, b), "ban before the upgrade")
      install_window_db!(true)
      Application.put_env(:nebu, :atdd_c2_hook, {room, fn -> :ok = Nebu.Matrix.Room.Server.moderate(room, :ban, a.uid, c.uid, nil) end})
      Application.put_env(:nebu, :atdd_c2_fail_ban_copy, room)

      conn = upgrade(a, room)
      assert conn.status == 500, "#{conn.status} #{String.slice(conn.resp_body, 0, 200)}"
      assert T.json(conn)["errcode"] == "M_UNKNOWN"

      assert [[metadata]] = T.sql!("SELECT metadata FROM audit_log WHERE action = 'room_upgraded' AND target_id = $1 AND outcome = 'failure'", [room]).rows
      new_room = content_of(metadata)["new_room_id"]
      assert T.sql!("SELECT count(*) FROM room_invitations WHERE room_id = $1", [new_room]).rows == [[0]], "nobody is invited, the banned users included"
      assert T.sql!("SELECT count(*) FROM events WHERE room_id = $1 AND event_type = 'm.room.join_rules'", [new_room]).rows == [[0]], "no join rule: nobody can join"
      assert room_status(room) == [["archived"]]
      assert Nebu.Matrix.Room.RoomSupervisor.lookup_room(room) == {:error, :not_found}
      assert membership(room, c.uid) == "ban", "the old room keeps both bans"
    end
  end

  defp footprint_db(room, uid), do: {event_count(room), member_events(room, uid), active_row?(room, uid), invitation_state(room, uid)}

  # ═══ L-5 (iii): an archived room refuses every moderation, invite-event and decline write ═══════════════════════════════════

  describe "L-5 (iii) archived room, process running" do
    test "moderation is refused: 404 Room not found, {:error, :room_archived} in the process, nothing written", %{a: a, b: b} do
      room = public_room(a)
      join!(b, room)
      assert :ok = Nebu.Admin.DB.archive_room_atomic(room)
      assert {:ok, _pid} = Nebu.Matrix.Room.RoomSupervisor.lookup_room(room), "premise: the process still runs"
      before = footprint_db(room, b.uid)

      for action <- [:kick, :ban] do
        assert_err(act(action, a, room, %{"user_id" => b.uid}), 404, "M_NOT_FOUND", "Room not found")
        assert {:error, :room_archived} = Nebu.Matrix.Room.Server.moderate(room, action, a.uid, b.uid, nil)
      end

      assert footprint_db(room, b.uid) == before
      assert in_set?(room, b.uid), "the member set is unchanged"
    end

    test "the invite is 404 with its row rejected and no event; the decline of a pending invitee still works", %{a: a, b: b, c: c} do
      room = make_room(a, %{"preset" => "private_chat"})
      invite!(a, room, c)
      assert :ok = Nebu.Admin.DB.archive_room_atomic(room)
      assert {:ok, _pid} = Nebu.Matrix.Room.RoomSupervisor.lookup_room(room)

      assert_err(invite(a, room, b), 404, "M_NOT_FOUND", "Room not found")
      assert invitation_state(room, b.uid) == :rejected, "the row this call wrote is rejected again"
      assert member_events(room, b.uid) == []

      ok!(leave(c, room), "the decline in the archived room")
      assert [_invite, leave_ev] = member_events(room, c.uid)
      assert leave_ev.sender == c.uid and leave_ev.content["membership"] == "leave"
      assert invitation_state(room, c.uid) == :rejected
    end
  end

  # ═══ MINOR-4: the reason of a carried ban, both JSONB forms ══════════════════════════════════════════

  defp insert_raw_member_event!(room, uid, content_sql, param, ts) do
    id = "$" <> T.rand(12)

    T.sql!(
      "INSERT INTO events (event_id, room_id, sender, event_type, content, origin_server_ts, signatures, state_key) VALUES ($1, $2, $3, 'm.room.member', #{content_sql}, $5, '{}'::jsonb, $6)",
      [id, room, "@x:test.local", param, ts, uid_of(uid)]
    )

    id
  end

  describe "MINOR-4 banned_members/1 reasons" do
    test "string-form reason, non-string reasons nil, an unparseable string body is no ban and no error", %{a: a, b: b, c: c, d: d} do
      room = public_room(a)
      e = user!("MDE")
      ts = ts_after(room)
      insert_raw_member_event!(room, b, "to_jsonb($4::text)", Jason.encode!(%{"membership" => "ban", "reason" => "string form"}), ts)
      insert_raw_member_event!(room, c, "$4::jsonb", Jason.encode!(%{"membership" => "ban", "reason" => %{"a" => 1}}), ts)
      insert_raw_member_event!(room, d, "to_jsonb($4::text)", Jason.encode!(%{"membership" => "ban", "reason" => 5}), ts)
      insert_raw_member_event!(room, e, "to_jsonb($4::text)", "{not json", ts)

      assert {:ok, list} = DB.banned_members(room)
      by_user = Map.new(list, &{&1.user_id, &1.reason})
      assert by_user == %{b.uid => "string form", c.uid => nil, d.uid => nil}, "the unparseable body is no ban"
    end
  end
end
