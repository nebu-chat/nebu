defmodule Nebu.Matrix.DeviceKeyDirectoryStreamTest do
  @moduledoc """
  Acceptance tests (REAL database) of the device-list change STREAM for story `device-key-directory` (REQ-2026-013, decisions D10 and D11): the table `device_list_changes` (migration 000060),
  who stamps it and the commit ordering of its positions.

    * every writer of a device-list change stamps `(user, '')` with kind `keys`: identity keys that are new or different, the delete of a device that had keys, the rename of a device with keys,
      a cross-signing key upload; NOT: an identical re-upload, one-time / fallback keys, a keyless device appearing, disappearing or being renamed;
    * every membership join / leave of `room_members`, by ANY writer (a trigger), stamps `(user, room)` with kind `join` / `leave`;
    * the table keeps the LATEST change per (user, room): bounded by users and memberships;
    * positions come from `sync_global_pos_seq` and are assigned AT COMMIT under one lock: a writer that stamped early and commits late gets the HIGHER position, so a reader that already saw a
      later change never misses it (pinned with a transaction held open between two syncs); a rolled back writer leaves no row.
  """
  use ExUnit.Case, async: false

  alias Nebu.Matrix.DeviceKeyDirectoryTestSupport, as: DK
  alias Nebu.Matrix.DeviceKeyStore
  alias Nebu.Matrix.ModerationTestSupport, as: S
  alias Nebu.Matrix.ToDeviceTestSupport, as: TD
  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration

  setup do
    T.reset_rate_limits()
    Nebu.Test.ServerName.pin!(T.server_name())
    TD.disable_rate_limit()
    on_exit(fn -> T.restore_rate_limits() end)
    {:ok, u: TD.user!("DKU")}
  end

  defp seq_value, do: T.sql!("SELECT last_value FROM sync_global_pos_seq").rows |> hd() |> hd()

  describe "the writers of a device-list change stamp (user, '') with kind keys" do
    test "the first upload of identity keys stamps a position that is above the sequence value before the write", %{u: u} do
      before = seq_value()
      DK.publish!(u)
      assert DK.stream_kind(u.uid) == "keys"
      assert DK.keys_pos(u.uid) > before
    end

    test "an IDENTICAL re-upload leaves the position untouched, DIFFERENT keys move it", %{u: u} do
      DK.publish!(u)
      first = DK.keys_pos(u.uid)
      DK.publish!(u)
      assert DK.keys_pos(u.uid) == first
      DK.publish!(u, keys: "2")
      assert DK.keys_pos(u.uid) > first
    end

    test "one-time and fallback key uploads, and a keyless device appearing, stamp nothing", %{u: u} do
      DK.publish!(u, keys: false, otks: ["A1"], fallback: "FFFF")
      TD.device!(u, "DKX")
      assert DK.stream_rows(u.uid) |> Enum.filter(fn [room, _, _] -> room == "" end) == []
    end

    test "deleting a device that had identity keys stamps; deleting a keyless device does not", %{u: u} do
      keyed = TD.device!(u, "DKK")
      keyless = TD.device!(u, "DKL")
      DK.publish!(keyed)
      pos = DK.keys_pos(u.uid)
      :ok = Nebu.Matrix.end_device_session(keyless.uid, keyless.dev)
      assert DK.keys_pos(u.uid) == pos
      :ok = Nebu.Matrix.end_device_session(keyed.uid, keyed.dev)
      assert DK.keys_pos(u.uid) > pos
    end

    test "the raising delete of the OAuth teardown transaction stamps as well; its rollback leaves the position alone", %{u: u} do
      DK.publish!(u)
      pos = DK.keys_pos(u.uid)
      assert {:error, :undo} =
               Nebu.Repo.transaction(fn ->
                 :ok = DeviceKeyStore.delete_device!(u.uid, u.dev)
                 Nebu.Repo.rollback(:undo)
               end)

      assert DK.keys_pos(u.uid) == pos
      assert {:ok, :ok} = Nebu.Repo.transaction(fn -> DeviceKeyStore.delete_device!(u.uid, u.dev) end)
      assert DK.keys_pos(u.uid) > pos
    end

    test "ONE lock order: a re-key that holds the device_keys row and then stamps does not deadlock with a delete of the same device (the delete stamps AFTER its DELETEs)", %{u: u} do
      DK.publish!(u)
      parent = self()

      # the lock order of put_device_keys/4: the device_keys row FOR UPDATE first, the stream row (user, '') second; the test paces the two steps
      rekey =
        Task.async(fn ->
          Nebu.Repo.transaction(fn ->
            T.sql!("SELECT 1 FROM device_keys WHERE user_id = $1 AND device_id = $2 FOR UPDATE", [u.uid, u.dev])
            %{rows: [[backend]]} = T.sql!("SELECT pg_backend_pid()")
            send(parent, {:locked, backend})

            receive do
              :go -> Nebu.Matrix.DeviceListStore.stamp_keys!(Nebu.Repo, u.uid)
            after
              30_000 -> Nebu.Repo.rollback(:timeout)
            end

            :done
          end)
        end)

      assert_receive {:locked, backend}, 15_000
      delete = Task.async(fn -> DeviceKeyStore.delete_device(u.uid, u.dev) end)
      Nebu.Compliance.UserDeletionTestSupport.await_blocked!(delete, backend, "the delete of a device whose key row a re-key holds")
      send(rekey.pid, :go)

      assert {:ok, :done} = Task.await(rekey, 20_000), "the re-key was not aborted by a deadlock"
      assert :ok = Task.await(delete, 20_000)
      assert T.sql!("SELECT count(*) FROM devices WHERE user_id = $1 AND device_id = $2", [u.uid, u.dev]).rows == [[0]], "the delete was not aborted: the device is gone"
      assert T.sql!("SELECT count(*) FROM device_keys WHERE user_id = $1 AND device_id = $2", [u.uid, u.dev]).rows == [[0]]
      assert is_integer(DK.keys_pos(u.uid))
    end

    test "renaming a device with keys stamps, a keyless rename and the rename of a foreign or unknown device do not", %{u: u} do
      keyless = TD.device!(u, "DKL")
      assert :ok = DeviceKeyStore.rename_device(keyless.uid, keyless.dev, "Phone")
      assert :error = DeviceKeyStore.rename_device(u.uid, "NOSUCHDEVICE", "Phone")
      assert DK.stream_row(u.uid) == nil
      DK.publish!(u)
      pos = DK.keys_pos(u.uid)
      assert :ok = DeviceKeyStore.rename_device(u.uid, u.dev, "Laptop")
      assert DK.keys_pos(u.uid) > pos
    end

    test "a cross-signing key upload stamps; a failed one (erased user) leaves no row", %{u: u} do
      assert :ok = Nebu.Matrix.CrossSigningKeyStore.put_keys(u.uid, T.cross_signing_keys(u.uid, "1"))
      assert DK.stream_kind(u.uid) == "keys"
      erased = TD.user!("DKE")
      T.sql!("UPDATE users SET deletion_status = 'keys_deleted' WHERE user_id = $1", [erased.uid])
      assert {:error, _} = Nebu.Matrix.CrossSigningKeyStore.put_keys(erased.uid, T.cross_signing_keys(erased.uid, "1"))
      assert DK.stream_count(erased.uid) == 0
    end

    test "the latest change per (user, room) is kept: ten changes leave one row, the position only grows", %{u: u} do
      positions =
        for i <- 1..10 do
          DK.publish!(u, keys: "v#{i}")
          DK.keys_pos(u.uid)
        end

      assert DK.stream_count(u.uid) == 1
      assert positions == Enum.sort(positions) and length(Enum.uniq(positions)) == 10
    end

    test "two changes of one user inside ONE transaction leave one row with one position", %{u: u} do
      assert {:ok, _} =
               Nebu.Repo.transaction(fn ->
                 DeviceKeyStore.put_device_keys(u.uid, u.dev, DK.device_keys(u, "a"))
                 DeviceKeyStore.put_device_keys(u.uid, u.dev, DK.device_keys(u, "b"))
               end)

      assert DK.stream_count(u.uid) == 1 and is_integer(DK.keys_pos(u.uid))
    end

    test "a transaction that is rolled back leaves no row and no position behind", %{u: u} do
      held = DK.hold(fn -> DeviceKeyStore.put_device_keys(u.uid, u.dev, DK.device_keys(u, "r")) end)
      DK.finish(held, :rollback)
      assert DK.stream_count(u.uid) == 0
    end
  end

  describe "membership stamps (a trigger on room_members: every writer is covered)" do
    test "a join through the API stamps (user, room) with kind join, a leave with kind leave and a higher position, a rejoin with join again", %{u: u} do
      owner = TD.user!("DKO")
      room = S.public_room(owner)
      S.join!(u, room)
      join_pos = DK.stream_pos(u.uid, room)
      assert DK.stream_kind(u.uid, room) == "join" and is_integer(join_pos)
      S.leave!(u, room)
      assert DK.stream_kind(u.uid, room) == "leave" and DK.stream_pos(u.uid, room) > join_pos
      leave_pos = DK.stream_pos(u.uid, room)
      S.join!(u, room)
      assert DK.stream_kind(u.uid, room) == "join" and DK.stream_pos(u.uid, room) > leave_pos
    end

    test "a row written by plain SQL is covered: insert = join, left_at set = leave, left_at cleared = join, other updates nothing", %{u: u} do
      owner = TD.user!("DKO")
      room = S.public_room(owner)
      T.sql!("INSERT INTO room_members (room_id, user_id, joined_at) VALUES ($1, $2, 1)", [room, u.uid])
      assert DK.stream_kind(u.uid, room) == "join"
      p1 = DK.stream_pos(u.uid, room)
      T.sql!("UPDATE room_members SET joined_at = 2 WHERE room_id = $1 AND user_id = $2", [room, u.uid])
      assert DK.stream_pos(u.uid, room) == p1, "a joined_at change is no membership change"
      T.sql!("UPDATE room_members SET left_at = 5 WHERE room_id = $1 AND user_id = $2", [room, u.uid])
      assert {DK.stream_kind(u.uid, room), DK.stream_pos(u.uid, room) > p1} == {"leave", true}
      p2 = DK.stream_pos(u.uid, room)
      T.sql!("UPDATE room_members SET left_at = NULL WHERE room_id = $1 AND user_id = $2", [room, u.uid])
      assert {DK.stream_kind(u.uid, room), DK.stream_pos(u.uid, room) > p2} == {"join", true}
    end

    test "a member row that is inserted already LEFT stamps nothing", %{u: u} do
      owner = TD.user!("DKO")
      room = S.public_room(owner)
      T.sql!("INSERT INTO room_members (room_id, user_id, joined_at, left_at) VALUES ($1, $2, 1, 2)", [room, u.uid])
      assert DK.stream_row(u.uid, room) == nil
    end

    test "key stamps and membership stamps of one user are separate rows: (user, '') and (user, room)", %{u: u} do
      owner = TD.user!("DKO")
      room = S.public_room(owner)
      S.join!(u, room)
      DK.publish!(u)
      assert DK.stream_rows(u.uid) |> Enum.map(fn [r, k, _] -> {r, k} end) == Enum.sort([{"", "keys"}, {room, "join"}])
    end
  end

  describe "positions are commit ordered (D10)" do
    setup %{u: u} do
      alice = TD.user!("DKA")
      pa = TD.user!("DKP")
      pb = TD.user!("DKQ")
      TD.share!(alice, pa)
      TD.share!(alice, pb)
      {:ok, alice: alice, pa: pa, pb: pb, u: u}
    end

    test "a writer that stamped FIRST but commits LAST gets the higher position", %{pa: pa, pb: pb} do
      held = DK.hold(fn -> DeviceKeyStore.put_device_keys(pa.uid, pa.dev, DK.device_keys(pa)) end)
      DK.publish!(pb)
      assert DK.keys_pos(pa.uid) == nil, "the held transaction has not committed: no row is visible"
      DK.finish(held, :commit)
      assert DK.keys_pos(pa.uid) > DK.keys_pos(pb.uid)
    end

    test "a reader that already saw the LATER change does not miss the earlier-written one (/sync)", %{alice: alice, pa: pa, pb: pb} do
      t0 = DK.token(alice)
      held = DK.hold(fn -> DeviceKeyStore.put_device_keys(pa.uid, pa.dev, DK.device_keys(pa)) end)
      DK.publish!(pb)
      first = DK.sync(alice, t0)
      assert DK.dl_changed(first) == [pb.uid]
      DK.finish(held, :commit)
      second = DK.sync(alice, TD.next(first))
      assert DK.dl_changed(second) == [pa.uid], "the late commit comes with the NEXT sync: #{inspect(DK.dl(second))}"
      assert DK.dl_pos(TD.next(second)) > DK.dl_pos(TD.next(first))
    end

    test "the same for /keys/changes: the range after the token of the first answer contains the late commit", %{alice: alice, pa: pa, pb: pb} do
      t0 = DK.token(alice)
      held = DK.hold(fn -> DeviceKeyStore.put_device_keys(pa.uid, pa.dev, DK.device_keys(pa)) end)
      DK.publish!(pb)
      t1 = DK.token(alice)
      assert DK.changes!(alice, t0, t1)["changed"] == [pb.uid]
      DK.finish(held, :commit)
      assert DK.changes!(alice, t1, DK.token(alice))["changed"] == [pa.uid]
    end

    test "the same for a membership change: a join that commits after a later key change is delivered by the next sync", %{alice: alice, pb: pb, u: u} do
      room = S.public_room(alice)
      t0 = DK.token(alice)
      held = DK.hold(fn -> T.sql!("INSERT INTO room_members (room_id, user_id, joined_at) VALUES ($1, $2, 1)", [room, u.uid]) end)
      DK.publish!(pb)
      first = DK.sync(alice, t0)
      assert DK.dl_changed(first) == [pb.uid]
      DK.finish(held, :commit)
      assert DK.dl_changed(DK.sync(alice, TD.next(first))) == [u.uid]
    end

    test "an open writer does not block readers: a sync and a changes call answer while it is held", %{alice: alice, pa: pa} do
      t0 = DK.token(alice)
      held = DK.hold(fn -> DeviceKeyStore.put_device_keys(pa.uid, pa.dev, DK.device_keys(pa)) end)
      started = System.monotonic_time(:millisecond)
      assert DK.dl(DK.sync(alice, t0)) == %{"changed" => [], "left" => []}
      assert DK.changes!(alice, t0, DK.token(alice)) == %{"changed" => [], "left" => []}
      assert System.monotonic_time(:millisecond) - started < 3_000
      DK.finish(held, :rollback)
    end

    test "an open writer does not block ANOTHER writer's commit (the position is assigned at commit, the lock is not held while the writer thinks)", %{pa: pa, pb: pb} do
      held = DK.hold(fn -> DeviceKeyStore.put_device_keys(pa.uid, pa.dev, DK.device_keys(pa)) end)
      started = System.monotonic_time(:millisecond)
      DK.publish!(pb)
      assert System.monotonic_time(:millisecond) - started < 3_000
      DK.finish(held, :rollback)
    end

    # a privileged deferred trigger that fires AFTER the stamp trigger (name order) and keeps the committing transaction, which holds the commit lock, busy for `seconds`
    defp slow_commit_after_stamp!(seconds) do
      name = "zzz_atdd_dk_slow_" <> T.rand(4)
      T.privileged_sql!("CREATE FUNCTION #{name}() RETURNS trigger AS $$ BEGIN PERFORM pg_sleep(#{seconds}); RETURN NULL; END $$ LANGUAGE plpgsql")

      T.privileged_sql!(
        "CREATE CONSTRAINT TRIGGER #{name} AFTER INSERT OR UPDATE ON device_list_changes DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN (NEW.pos IS NULL) EXECUTE FUNCTION #{name}()"
      )

      remove = fn ->
        T.privileged_sql!("DROP TRIGGER IF EXISTS #{name} ON device_list_changes")
        T.privileged_sql!("DROP FUNCTION IF EXISTS #{name}()")
      end

      ExUnit.Callbacks.on_exit(remove)
      remove
    end

    test "a token taken while a writer is IN its commit (position stamped, not yet visible) never makes the change unreachable", %{alice: alice, pa: pa} do
      remove = slow_commit_after_stamp!(1.5)
      writer = Task.async(fn -> DK.publish!(pa) end)
      assert :ok = S.wait_until(fn -> T.sql!("SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND classid = 4760 AND granted").rows == [[1]] end, 10_000), "the writer is in its commit"
      t0 = DK.token(alice)
      visible_at_t0 = DK.keys_pos(pa.uid) != nil
      Task.await(writer, 30_000)
      remove.()
      body = DK.sync(alice, t0)
      assert visible_at_t0 or pa.uid in DK.dl_changed(body), "the change is neither in the state the token stands for nor reported after it: #{inspect(DK.dl(body))}"
      assert DK.dl_pos(t0) > DK.keys_pos(pa.uid) or pa.uid in DK.dl_changed(body)
    end

    test "positions are unique and increasing over many concurrent writers (no two users share a position)", %{u: _u} do
      users = for _ <- 1..12, do: TD.user!("DKW")
      S.race(for w <- users, do: fn -> DK.publish!(w) end)
      positions = for w <- users, do: DK.keys_pos(w.uid)
      assert Enum.all?(positions, &is_integer/1) and length(Enum.uniq(positions)) == 12
    end
  end
end
