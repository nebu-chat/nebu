defmodule Nebu.Compliance.UserDeletionRoomKeysTest do
  @moduledoc """
  Acceptance tests (REAL database) of the GDPR erasure part of story `server-side-key-backup` (epic e2ee-client-support, REQ-2026-011): "GDPR erasure must delete all key-backup
  versions and session rows of the erased user" (story constraint), in the framework of story `gdpr-erasure-global-data`.

    * `Nebu.Compliance.UserDeletion.erased_tables/0` names `room_key_backup_sessions` and `room_key_backup_versions` (the deleting code, the schema recurrence guard, the sweep and the
      docs inventory are all driven by that list; `UserDeletionTestSupport.expected_erased/0` carries them and `seed_user!/2` seeds a backup through the REAL routes, so every generic
      erasure test of `user_deletion_*_test.exs` - one erasure, rollback of a failing step per table, the sweep, the late retry - now covers the backup too).
    * One erasure deletes EVERY version row (the soft-delete marker of a deleted version included, it carries the user id) and every session row of the user, in the same transaction,
      and leaves every row of another user byte-identical and readable through the routes.
    * A write of an erased user's bearer that the provisioning cache still confirms (the in-flight request) is refused `403 M_USER_DEACTIVATED` (same answer as the account-data and
      cross-signing writers, a permanent condition, logged without error level and without blobs) and stores nothing: neither a new version (POST) nor a session (PUT keys).
    * The writers that CREATE rows (POST /version, PUT /keys*) serialise with the erasure through the per-user `sync_global` advisory lock (the SAME key as `AccountDataStore.put/3` and
      `CrossSigningKeyStore.put_keys/2`): while a transaction holds it they are answered `429 M_LIMIT_EXCEEDED` at once (cycle 2: a try-lock; cycle 1 waited), so an upload that is in flight never re-creates rows after
      the erasure deleted them and no waiter holds a pooled connection.
    * A race between an erasure and a burst of uploads never leaves a row of the erased user.

  `async: false` (real `AuditWriter` seam via `E.setup_env!/0`, committed rows, own connections).
  """
  use ExUnit.Case, async: false

  alias Nebu.Compliance.UserDeletion
  alias Nebu.Compliance.UserDeletionTestSupport, as: E
  alias Nebu.Matrix.RoomKeysTestSupport, as: RK
  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration

  @room "!erase:test.local"
  @algo RK.algorithm()
  @tables [RK.sessions_table(), RK.versions_table()]

  setup do
    env = E.setup_env!()
    # cycle 2: AFTER `setup_env!` (it resets the limiter to enabled with a frozen clock; the write burst is 5 now and these tests write more than that)
    RK.disable_rate_limit()
    {:ok, env}
  end

  # the answer of a request that must NOT wait for the lock (a try-lock): a task that is still waiting is a failure with a message
  defp served!({:ok, conn}, _what), do: conn
  defp served!(_waiting, what), do: flunk(what)

  defp erase!(uid), do: UserDeletion.delete_user_keys(E.admin(), uid, "atdd erasure")

  # an in-flight request: the bearer was confirmed (and cached) while the user was active, then the status is set
  defp in_flight_session!(uid) do
    session = T.legacy_session!(uid, "RKF" <> String.upcase(T.rand(3)))
    assert T.whoami(session.at).status == 200, "precondition: the session is accepted and the user is now in the provisioning cache"
    T.sql!("UPDATE users SET deletion_status = 'keys_deleted' WHERE user_id = $1", [uid])
    session
  end

  describe "the inventory" do
    test "erased_tables/0 names both tables of the key backup, the sessions BEFORE the versions" do
      erased = UserDeletion.erased_tables()
      for t <- @tables, do: assert(t in erased, "#{t} is not erased by the GDPR erasure")
      assert Enum.find_index(erased, &(&1 == "room_key_backup_sessions")) < Enum.find_index(erased, &(&1 == "room_key_backup_versions")), "session rows go before their versions"
      assert Enum.sort(erased) == Enum.sort(E.expected_erased()), "the inventory of the suites and the code agree"
    end

    test "the seeded world has a backup in both tables (so every generic erasure test proves something)", %{cid: cid} do
      a = E.seed_user!(cid, "a")
      assert RK.rows(RK.sessions_table(), a.uid) == 3
      assert RK.rows(RK.versions_table(), a.uid) == 3, "three version rows: the older one, the current one and the soft-delete marker of the deleted one"
      assert %{older: _, current: _, deleted: _} = a.backup
    end
  end

  describe "the erasure deletes the whole backup of the user and nothing of another user" do
    test "no version row (the marker of the deleted version included) and no session row of A is left; the blobs are gone; B is byte-identical and still readable", %{cid: cid} do
      a = E.seed_user!(cid, "a")
      b = E.seed_user!(cid, "b")
      b_session = T.legacy_session!(b.uid, b.dev)

      assert RK.row_text(RK.versions_table(), a.uid) =~ "cur-" <> a.canary, "precondition: A's auth_data is stored"
      assert RK.row_text(RK.sessions_table(), a.uid) =~ "ct-c1-" <> a.canary, "precondition: A's session blobs are stored"
      b_before = E.snapshot(b.uid, @tables)
      b_info = RK.info!(b_session.at)
      b_keys = RK.sessions!(b_session.at, b.backup.current)

      assert {:ok, %{keys_deleted_at: at}} = erase!(a.uid)
      assert is_integer(at)

      for t <- @tables do
        assert E.count(t, a.uid) == 0, "the erasure left rows of A in #{t}"
        assert RK.row_text(t, a.uid) == ""
      end

      assert E.snapshot(b.uid, @tables) == b_before, "B's key backup rows are byte-identical"
      assert RK.info!(b_session.at) == b_info
      assert RK.sessions!(b_session.at, b.backup.current) == b_keys
      assert map_size(b_keys) == 2
    end

    test "afterwards the erased user's bearer that is still cached reads nothing: no current version, 404 for the former numbers and their keys", %{cid: cid} do
      a = E.seed_user!(cid, "a")
      live = T.legacy_session!(a.uid, "RKC" <> String.upcase(T.rand(3)))
      assert T.whoami(live.at).status == 200, "precondition: the provisioning cache confirmed the bearer"
      assert {:ok, _} = erase!(a.uid)

      RK.assert_error(RK.get_version(live.at), 404, "M_NOT_FOUND")

      for v <- [a.backup.older, a.backup.current, a.backup.deleted] do
        RK.assert_error(RK.get_version(live.at, v), 404, "M_NOT_FOUND")
        RK.assert_error(RK.get_keys(live.at, v), 404, "M_NOT_FOUND")
      end
    end

    test "the erasure does not log or audit a blob (the seeded blobs are named in the secrets of the world)", %{cid: cid} do
      a = E.seed_user!(cid, "a")

      log = ExUnit.CaptureLog.capture_log([level: :debug], fn -> assert {:ok, _} = erase!(a.uid) end)

      T.refute_secrets_in_log(log, Map.take(a.secrets, [:backup_session, :backup_auth_data]))
    end
  end

  describe "a write of an erased user in flight is refused and stores nothing" do
    test "POST /version: 403 M_USER_DEACTIVATED, no version created, no error-level log, no blob in the log" do
      uid = T.provision_user!()
      session = in_flight_session!(uid)
      canary = "late-ad-" <> T.rand(6)

      log = ExUnit.CaptureLog.capture_log([level: :debug], fn -> send(self(), {:resp, RK.post_version(session.at, %{"algorithm" => @algo, "auth_data" => %{"c" => canary}})}) end)

      assert_received {:resp, resp}
      assert resp.status == 403 and RK.json(resp)["errcode"] == "M_USER_DEACTIVATED", "got #{resp.status} #{resp.resp_body}"
      assert E.count(RK.versions_table(), uid) == 0
      refute log =~ "[error]", "a permanent refusal is not an error-level event"
      refute log =~ canary
    end

    test "PUT /keys of a user who HAS a backup: 403 M_USER_DEACTIVATED for every shape, nothing stored, the stored session unchanged" do
      uid = T.provision_user!()
      live = T.legacy_session!(uid, "RKL" <> String.upcase(T.rand(3)))
      v = RK.create!(live.at)
      assert {1, _etag} = RK.count_etag!(RK.put_session(live.at, v, @room, "s", RK.kbd(10, 0, false, %{"c" => "OLD"})))
      session = in_flight_session!(uid)
      canary = "late-sd-" <> T.rand(6)

      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          bodies = [
            RK.put_session(session.at, v, @room, "s", RK.kbd(1, 0, true, %{"c" => canary})),
            RK.put_room(session.at, v, @room, %{"new1" => RK.kbd(1, 0, true, %{"c" => canary})}),
            RK.put_rooms(session.at, v, %{@room => %{"new2" => RK.kbd(1, 0, true, %{"c" => canary})}})
          ]

          send(self(), {:resp, bodies})
        end)

      assert_received {:resp, responses}

      for r <- responses do
        assert r.status == 403 and RK.json(r)["errcode"] == "M_USER_DEACTIVATED", "got #{r.status} #{r.resp_body}"
      end

      assert E.count(RK.sessions_table(), uid) == 1, "no session row was added"
      refute log =~ "[error]"
      refute log =~ canary
    end

    test "after the REAL erasure the bearer that is still cached cannot re-create a backup: POST /version is 403 M_USER_DEACTIVATED and no row appears", %{cid: cid} do
      a = E.seed_user!(cid, "a")
      live = T.legacy_session!(a.uid, "RKP" <> String.upcase(T.rand(3)))
      assert T.whoami(live.at).status == 200, "precondition: the provisioning cache confirmed the bearer"
      assert {:ok, _} = erase!(a.uid)

      resp = RK.post_version(live.at, %{"algorithm" => @algo, "auth_data" => RK.auth_data("late")})
      assert resp.status == 403 and RK.json(resp)["errcode"] == "M_USER_DEACTIVATED", "got #{resp.status} #{resp.resp_body}"
      for t <- @tables, do: assert(E.count(t, a.uid) == 0, "a late write re-created a row in #{t}")
    end

    test "control: an active user's POST and PUT are stored" do
      uid = T.provision_user!()
      s = T.legacy_session!(uid, "RKA" <> String.upcase(T.rand(3)))
      v = RK.create!(s.at)
      assert {1, _} = RK.count_etag!(RK.put_session(s.at, v, @room, "s", RK.kbd(1, 0, false)))
      assert E.count(RK.versions_table(), uid) >= 1 and E.count(RK.sessions_table(), uid) == 1
    end
  end

  # cycle 2 (deliberate, supersedes "POST /version / PUT /keys waits for a transaction that holds the user lock, then completes" and "a write that WAITED for the lock of an
  # erasure in progress is refused after the commit"): the writers take the per-user lock with `pg_try_advisory_xact_lock`, so while the erasure (or any transaction) holds it a
  # writer is answered 429 AT ONCE instead of waiting with a pooled connection. The serialisation with the erasure is unchanged: no writer runs while the lock is held, and one that
  # comes after the erasure's commit is refused as before.
  describe "the writers that create rows serialise with the erasure (the per-user sync_global advisory lock, a try-lock)" do
    test "POST /version while a transaction holds the user lock is 429 at once and creates no row; after it, it completes" do
      uid = T.provision_user!()
      s = T.legacy_session!(uid, "RKW" <> String.upcase(T.rand(3)))
      holder = E.hold(fn -> T.sql!(E.lock_user_sql(), [uid]) end)

      task = Task.async(fn -> RK.post_version(s.at, %{"algorithm" => @algo, "auth_data" => RK.auth_data("wait")}) end)
      resp = Task.yield(task, 1_500) || Task.shutdown(task, :brutal_kill)
      E.finish(holder, :rollback)

      conn = served!(resp, "POST /room_keys/version still waited for the lock after 1.5 s: it must be answered 429 at once")
      RK.assert_error(conn, 429, "M_LIMIT_EXCEEDED")
      assert E.count(RK.versions_table(), uid) == 0

      assert RK.post_version(s.at, %{"algorithm" => @algo, "auth_data" => RK.auth_data("wait")}).status == 200
      assert E.count(RK.versions_table(), uid) == 1
    end

    test "PUT /keys (every shape) while the user lock is held is 429 at once and stores nothing; after it, it completes" do
      uid = T.provision_user!()
      s = T.legacy_session!(uid, "RKX" <> String.upcase(T.rand(3)))
      v = RK.create!(s.at)

      shape_request = fn shape, i ->
        kbd = RK.kbd(i, 0, false)

        case shape do
          :rooms -> RK.put_rooms(s.at, v, %{@room => %{"s#{i}" => kbd}})
          :room -> RK.put_room(s.at, v, @room, %{"s#{i}" => kbd})
          :session -> RK.put_session(s.at, v, @room, "s#{i}", kbd)
        end
      end

      for {shape, i} <- Enum.with_index([:rooms, :room, :session]) do
        holder = E.hold(fn -> T.sql!(E.lock_user_sql(), [uid]) end)
        task = Task.async(fn -> shape_request.(shape, i) end)
        resp = Task.yield(task, 1_500) || Task.shutdown(task, :brutal_kill)
        E.finish(holder, :rollback)

        conn = served!(resp, "PUT /room_keys/keys (#{shape}) still waited for the lock after 1.5 s")
        RK.assert_error(conn, 429, "M_LIMIT_EXCEEDED")
        assert E.count(RK.sessions_table(), uid) == i, "a refused #{shape} write stored something"
        assert shape_request.(shape, i).status == 200
      end

      assert E.count(RK.sessions_table(), uid) == 3
    end

    test "a write while an erasure holds the lock is 429 at once; after the erasure commit the same write is 403 M_USER_DEACTIVATED" do
      uid = T.provision_user!()
      s = T.legacy_session!(uid, "RKY" <> String.upcase(T.rand(3)))
      v = RK.create!(s.at)
      assert T.whoami(s.at).status == 200

      holder =
        E.hold(fn ->
          T.sql!(E.lock_user_sql(), [uid])
          T.sql!("UPDATE users SET deletion_status = 'keys_deleted' WHERE user_id = $1", [uid])
        end)

      task = Task.async(fn -> RK.put_session(s.at, v, @room, "late", RK.kbd(1, 0, false)) end)
      resp = Task.yield(task, 1_500) || Task.shutdown(task, :brutal_kill)
      conn = served!(resp, "PUT /room_keys/keys still waited for the lock of the erasure after 1.5 s")
      RK.assert_error(conn, 429, "M_LIMIT_EXCEEDED")
      assert E.count(RK.sessions_table(), uid) == 0

      E.finish(holder, :commit)

      resp = RK.put_session(s.at, v, @room, "late", RK.kbd(1, 0, false))
      assert resp.status == 403 and RK.json(resp)["errcode"] == "M_USER_DEACTIVATED", "got #{resp.status} #{resp.resp_body}"
      assert E.count(RK.sessions_table(), uid) == 0
    end
  end

  describe "an erasure racing a burst of uploads" do
    test "3 rounds: after the erasure and 12 concurrent uploads / version creations have all finished, no row of the erased user is left in either table", %{cid: cid} do
      for round <- 1..3 do
        a = E.seed_user!(cid, "r#{round}")
        s = T.legacy_session!(a.uid, "RKR" <> String.upcase(T.rand(3)))
        assert T.whoami(s.at).status == 200

        jobs = [:erase | for(i <- 1..12, do: i)]

        results =
          jobs
          |> Task.async_stream(
            fn
              :erase -> {:erase, erase!(a.uid)}
              i when rem(i, 4) == 0 -> {:post, RK.post_version(s.at, %{"algorithm" => @algo, "auth_data" => RK.auth_data("race#{i}")})}
              i -> {:put, RK.put_session(s.at, a.backup.current, @room, "race#{i}", RK.kbd(i, 0, false))}
            end,
            max_concurrency: 8,
            ordered: false,
            timeout: 60_000
          )
          |> Enum.map(fn {:ok, r} -> r end)

        assert {:erase, {:ok, _}} = Enum.find(results, &match?({:erase, _}, &1))
        # cycle 2: 429 too (a try-lock: a writer that meets the erasure's lock is refused at once, and a refused writer stores nothing)
        for {kind, c} <- results, kind != :erase, do: assert(c.status in [200, 403, 404, 429], "#{kind}: unexpected #{c.status} #{c.resp_body}")
        for t <- @tables, do: assert(E.count(t, a.uid) == 0, "round #{round}: rows of the erased user left in #{t}")
      end
    end
  end
end
