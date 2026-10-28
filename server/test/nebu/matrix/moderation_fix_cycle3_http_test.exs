defmodule Nebu.Matrix.ModerationFixCycle3HttpTest do
  @moduledoc """
  Story `moderation-routes-atomic-ban`, review cycle 3 (Kassandra L-1, I-2, I-3, I-4; code review MINOR-1, INFO-1, INFO-4), REAL database through
  `Nebu.Web.Router`. `async: false`.

    * L-1 (follow-up `fu`): an upgrade by a requester who is not a member, or who is banned (a half state at level 100), is 403 before
      anything is written; a ban that cannot be carried (a state key above 255 bytes) is refused before the tombstone too.
    * MINOR-1 (the `:event_dispatcher, :room_terminate_fun` seam): a stop that fails while the process keeps running is a 500 with the old
      room archived (`old_room_archived` in the failure audit row); a stop that answers an error after the process ended is a success.
      A failing archive and a failing members read after the tombstone are 500s that never populate the new room.
    * INFO-4: the cap seam takes only a positive integer ("5" and 0 leave the default).
    * I-3: a decline whose invitation was revoked AND whose room was archived in the gap is a no-op (no second leave).
  """
  use ExUnit.Case, async: false

  import Nebu.Matrix.ModerationTestSupport

  alias Nebu.Matrix.ModerationTestSupport.Gap
  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration
  @moduletag timeout: 120_000

  setup do
    T.reset_rate_limits()
    Nebu.Test.ServerName.pin!(T.server_name())

    keys = [
      event_dispatcher: :rooms_db_module,
      event_dispatcher: :admin_db_module,
      event_dispatcher: :room_terminate_fun,
      nebu: :upgrade_max_carried_bans,
      nebu: :atdd_c3_fault,
      compliance: :audit_writer
    ]

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

    {:ok, a: user!("MEA"), b: user!("MEB"), c: user!("MEC")}
  end

  defp upgrade(user, room), do: T.matrix_request(:post, path(room, "upgrade"), user.at, body: %{"new_version" => "10"})
  defp tombstones(room), do: T.sql!("SELECT count(*) FROM events WHERE room_id = $1 AND event_type = 'm.room.tombstone'", [room]).rows
  defp room_status(room), do: T.sql!("SELECT status FROM rooms WHERE room_id = $1", [room]).rows

  defp failure_metadata(room) do
    assert [[metadata]] = T.sql!("SELECT metadata FROM audit_log WHERE action = 'room_upgraded' AND target_id = $1 AND outcome = 'failure'", [room]).rows
    content_of(metadata)
  end

  defp nothing_written!(room) do
    assert tombstones(room) == [[0]], "nothing is tombstoned"
    assert room_status(room) == [["active"]], "the room is not archived"
    assert {:ok, _pid} = Nebu.Matrix.Room.RoomSupervisor.lookup_room(room), "the room process still runs"
  end

  # ═══ L-1: the requester must be a member and not banned; every ban must be carriable ════════════════════

  describe "L-1 the requester and the bans before the tombstone" do
    test "a requester at level 100 who is not a member is 403 \"You are not a member of this room\", nothing written", %{a: a, b: b} do
      room = level_room(a, %{b.uid => 100})
      assert_err(upgrade(b, room), 403, "M_FORBIDDEN", "You are not a member of this room")
      nothing_written!(room)
    end

    test "a BANNED requester at level 100 (a half state: still in the member set) is 403 \"You are banned from this room\", nothing written", %{a: a, b: b} do
      room = level_room(a, %{b.uid => 100})
      join!(b, room)
      insert_member_event!(room, b, "ban", a, ts_after(room))
      assert in_set?(room, b.uid), "premise: the member set still holds him"
      assert_err(upgrade(b, room), 403, "M_FORBIDDEN", "You are banned from this room")
      nothing_written!(room)
    end

    test "a ban that cannot be carried (a state key above 255 bytes) is refused before the tombstone (500), nothing written", %{a: a} do
      room = public_room(a)
      long = "@" <> String.duplicate("l", 260) <> ":" <> T.server_name()
      insert_member_event!(room, long, "ban", a, ts_after(room))
      conn = upgrade(a, room)
      assert conn.status == 500 and T.json(conn)["errcode"] == "M_UNKNOWN"
      refute conn.resp_body =~ long
      nothing_written!(room)
    end
  end

  # ═══ INFO-4: the cap seam ═══════════════════════════════════════════════════════════════════════════

  describe "INFO-4 the cap seam" do
    test "\"5\" and 0 are ignored: the default cap applies and an upgrade with two bans works", %{a: a, b: b, c: c} do
      for junk <- ["5", 0] do
        Application.put_env(:nebu, :upgrade_max_carried_bans, junk)
        room = public_room(a)
        join!(b, room)
        join!(c, room)
        ok!(ban(a, room, b), "ban b")
        ok!(ban(a, room, c), "ban c")
        conn = upgrade(a, room)
        assert conn.status == 200, "cap #{inspect(junk)}: #{conn.status} #{String.slice(conn.resp_body, 0, 120)}"
      end
    end
  end

  # ═══ MINOR-1: the stop of the old room and the other failures after the tombstone ═══════════════════

  defmodule FaultyAdminDB do
    @moduledoc false
    for {name, arity} <- Nebu.Admin.DB.__info__(:functions), name != :archive_room_atomic do
      args = Macro.generate_arguments(arity, __MODULE__)
      def unquote(name)(unquote_splicing(args)), do: apply(Nebu.Admin.DB, unquote(name), unquote(args))
    end

    def archive_room_atomic(_room_id), do: {:error, :atdd_archive_failed}
  end

  defmodule FaultyMembersDB do
    @moduledoc false
    alias Nebu.Matrix.Room.DB

    for {name, arity} <- DB.__info__(:functions), name != :load_members do
      args = Macro.generate_arguments(arity, __MODULE__)
      def unquote(name)(unquote_splicing(args)), do: apply(DB, unquote(name), unquote(args))
    end

    def load_members(room_id) do
      if Application.get_env(:nebu, :atdd_c3_fault) == room_id, do: {:error, :atdd_members_failed}, else: DB.load_members(room_id)
    end
  end

  defp new_room_events(room) do
    new_room = failure_metadata(room)["new_room_id"]
    T.sql!("SELECT count(*) FROM events WHERE room_id = $1", [new_room]).rows
  end

  describe "MINOR-1 failures after the tombstone" do
    test "a stop that fails while the process keeps running: 500, the old room archived, old_room_archived true in the failure audit row", %{a: a, b: b} do
      room = public_room(a)
      join!(b, room)
      Application.put_env(:event_dispatcher, :room_terminate_fun, fn _pid -> {:error, :boom} end)

      on_exit(fn ->
        with {:ok, pid} <- Nebu.Matrix.Room.RoomSupervisor.lookup_room(room), do: Horde.DynamicSupervisor.terminate_child(Nebu.Matrix.Room.HordeSupervisor, pid)
      end)

      conn = upgrade(a, room)
      assert conn.status == 500 and T.json(conn)["errcode"] == "M_UNKNOWN"
      assert room_status(room) == [["archived"]]
      assert {:ok, _pid} = Nebu.Matrix.Room.RoomSupervisor.lookup_room(room), "premise: the process still runs"
      assert failure_metadata(room)["old_room_archived"] == true
      assert new_room_events(room) == [[0]], "the new room is never populated"
    end

    test "a stop that answers an error after the process ended is a success (the re-check finds no process)", %{a: a, b: b} do
      room = public_room(a)
      join!(b, room)

      Application.put_env(:event_dispatcher, :room_terminate_fun, fn pid ->
        :ok = Horde.DynamicSupervisor.terminate_child(Nebu.Matrix.Room.HordeSupervisor, pid)
        :ok = wait_until(fn -> Nebu.Matrix.Room.RoomSupervisor.lookup_room(room) == {:error, :not_found} end, 2_000)
        {:error, :not_found}
      end)

      conn = upgrade(a, room)
      assert conn.status == 200, "#{conn.status} #{String.slice(conn.resp_body, 0, 160)}"
      assert invitation_state(T.json(conn)["replacement_room"], b.uid) == :pending
    end

    test "a failing archive: 500, old_room_archived false, the new room is never populated", %{a: a, b: b} do
      room = public_room(a)
      join!(b, room)
      Application.put_env(:event_dispatcher, :admin_db_module, FaultyAdminDB)

      conn = upgrade(a, room)
      assert conn.status == 500
      assert failure_metadata(room)["old_room_archived"] == false
      assert new_room_events(room) == [[0]]
      assert room_status(room) == [["active"]]
    end

    test "a failing members read after the freeze: 500, old_room_archived true, the new room is never populated", %{a: a, b: b} do
      room = public_room(a)
      join!(b, room)
      Application.put_env(:event_dispatcher, :rooms_db_module, FaultyMembersDB)
      Application.put_env(:nebu, :atdd_c3_fault, room)

      conn = upgrade(a, room)
      assert conn.status == 500
      assert failure_metadata(room)["old_room_archived"] == true
      assert new_room_events(room) == [[0]]
      assert room_status(room) == [["archived"]]
    end
  end

  # ═══ I-3: the decline no-op in a room archived in the gap ═══════════════════════════════════════════

  describe "I-3 decline no-op in an archived room" do
    setup do
      Gap.install!()
      :ok
    end

    test "a revocation and the archive in the gap: the decline is 200 and writes no second leave", %{a: a, b: b} do
      room = make_room(a, %{"preset" => "private_chat"})
      invite!(a, room, b)
      Gap.arm(:delete_member, room, b.uid, self())

      task =
        Task.async(fn ->
          Process.put(:atdd_gap_victim, true)
          leave(b, room)
        end)

      assert_receive {:gap, victim, :delete_member}, 10_000
      ok!(kick(a, room, b), "revocation inside the gap")
      assert :ok = Nebu.Admin.DB.archive_room_atomic(room)
      send(victim, :go)

      ok!(Task.await(task, 20_000), "the decline")
      assert memberships(room, b.uid) == ["invite", "leave"], "one leave only"
      assert List.last(member_events(room, b.uid)).sender == a.uid
    end
  end
end
