defmodule Nebu.Compliance.UserDeletionConcurrencyTest do
  @moduledoc """
  Real-database concurrency tests (REAL concurrency: every "transaction" is a `Nebu.Repo.transaction/1` of its own Task, i.e. its own pooled connection
  of the RUNTIME role, committed or rolled back for real; no sandbox) for story `gdpr-erasure-global-data` (follow-up `ck`):

    * D1: the erasure takes the per-user `sync_global` advisory lock (the one of `AccountDataStore.put/3` and `CrossSigningKeyStore.put_keys/2`)
      BEFORE it deletes `account_data` / `cross_signing_keys`: a writer that holds the lock (a PUT in flight) makes the erasure wait, and what that
      writer committed is erased.
    * D5 (Gherkin scenario 7): the initial / fallback persist of a `/sync` (`Nebu.Matrix.Session.PgStore.Postgres.persist_sync_position/3`, mode
      `:initial`) creates no `sync_tokens` / `sync_room_cursors` row for a user whose `deletion_status` is not NULL; the guard takes a `FOR SHARE` lock
      on the `users` row, so a persist that races the erasure WAITS for its commit and then sees the new status; an active user persists exactly as before,
      in the same number of statements.

  ## Contract pinned here

    * A guarded (rejected) persist answers `:ok` (the caller's response is not made worse than today) and writes nothing; the persist API is the
      existing `persist_sync_position(user_id, device_id, spec)` with the `:initial` spec of story sync-stream-position (D21).
    * "waited" is proved structurally (`pg_stat_activity.wait_event_type = 'Lock'` + `pg_blocking_pids/1`), never with a sleep as the assertion.
    * The guard's lock is simulated by the erasure's own first write (`UPDATE users SET deletion_status = 'deletion_in_progress'`) in a held transaction, so
      the test does not depend on where the erasure takes its advisory lock.
  """
  use ExUnit.Case, async: false

  alias Nebu.Compliance.UserDeletion
  alias Nebu.Compliance.UserDeletionTestSupport, as: E
  alias Nebu.Matrix.Session.PgStore.Postgres, as: Store
  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration

  setup do
    {:ok, E.setup_env!()}
  end

  defp erase!(uid), do: UserDeletion.delete_user_keys(E.admin(), uid, "atdd erasure")

  defp spec(rooms, token \\ nil) do
    %{
      mode: :initial,
      new_token: token || "s2_" <> T.rand(11),
      last_event_id: nil,
      keep: [],
      rows: Enum.map(rooms, fn room -> %{room_id: room, pos: 3, class: "join", invite_marker: nil, base: nil} end)
    }
  end

  defp token_rows(uid), do: T.sql!("SELECT device_id, since_token, stream_version, generation FROM sync_tokens WHERE user_id = $1 ORDER BY device_id", [uid]).rows
  defp cursor_rows(uid), do: T.sql!("SELECT device_id, room_id, gen, pos, class FROM sync_room_cursors WHERE user_id = $1 ORDER BY device_id, room_id", [uid]).rows

  # ═══ D1: the per-user advisory lock ═══════════════════════════════════════════════════════════════════════════════════════

  describe "D1 - the erasure serialises with the account data and cross-signing writers" do
    test "a writer that holds the per-user lock makes the erasure wait; what it committed is erased", %{cid: cid} do
      a = E.seed_user!(cid, "a")

      # a PUT account_data / a key upload in flight: it holds the user lock, and its rows commit with it
      writer =
        E.hold(fn ->
          T.sql!(E.lock_user_sql(), [a.uid])

          T.sql!(
            "INSERT INTO account_data (user_id, type, content_json, changed, stream_pos, created_at, updated_at) VALUES ($1, 'm.late', $2, TRUE, nextval('sync_global_pos_seq'), $3, $3)",
            [a.uid, Jason.encode!(%{"late" => "late-#{a.canary}"}), System.system_time(:millisecond)]
          )

          T.sql!("UPDATE cross_signing_keys SET master_key_json = $2, changed_pos = nextval('sync_global_pos_seq') WHERE user_id = $1", [a.uid, Jason.encode!(%{"late" => a.canary})])
        end)

      erasure = Task.async(fn -> erase!(a.uid) end)
      E.await_blocked!(erasure, writer.backend, "the erasure")
      assert E.count("account_data", a.uid) == 6, "the erasure has not deleted anything while the writer holds the lock (the late row is not visible yet)"

      E.finish(writer, :commit)
      assert {:ok, %{keys_deleted_at: _}} = Task.await(erasure, 30_000)

      assert E.count("account_data", a.uid) == 0, "the row the writer committed before the erasure took the lock is erased too"
      assert E.count("cross_signing_keys", a.uid) == 0
    end
  end

  # ═══ D5: the initial / fallback persist and an erased user ════════════════════════════════════════════════════════════════

  describe "Scenario 7 - an in-flight initial sync cannot re-create rows" do
    test "an active user persists the token row and the cursor rows as before", %{cid: _cid} do
      uid = T.provision_user!()
      rooms = ["!r1#{T.rand(4)}:test.local", "!r2#{T.rand(4)}:test.local"]
      s = spec(rooms, "s2_active")

      assert :ok = Store.persist_sync_position(uid, "DEV1", s)

      assert token_rows(uid) == [["DEV1", "s2_active", 1, 1]]
      assert cursor_rows(uid) == Enum.map(Enum.sort(rooms), &["DEV1", &1, 1, 3, "join"])
    end

    test "for an erased user the persist writes no token row and no cursor row and answers :ok", %{cid: cid} do
      a = E.seed_user!(cid, "a")
      assert {:ok, _} = erase!(a.uid)
      assert token_rows(a.uid) == []

      log = ExUnit.CaptureLog.capture_log([level: :debug], fn -> send(self(), {:r, Store.persist_sync_position(a.uid, "DEV1", spec([a.room], "s2_late"))}) end)

      assert_received {:r, :ok}
      assert token_rows(a.uid) == [], "no sync token row of an erased user"
      assert cursor_rows(a.uid) == [], "no cursor row (the user's room ids) of an erased user"
      refute log =~ "[error]"
      refute log =~ a.room, "no error / room id is logged by the rejected persist"
    end

    test "the persist also refuses while the status is deletion_in_progress; an existing token row is not rewritten", %{cid: _cid} do
      uid = T.provision_user!()
      assert :ok = Store.persist_sync_position(uid, "DEV1", spec(["!x#{T.rand(4)}:test.local"], "s2_before"))
      before = {token_rows(uid), cursor_rows(uid)}
      T.sql!("UPDATE users SET deletion_status = 'deletion_in_progress' WHERE user_id = $1", [uid])

      assert :ok = Store.persist_sync_position(uid, "DEV1", spec(["!y#{T.rand(4)}:test.local"], "s2_after"))
      assert :ok = Store.persist_sync_position(uid, "DEV2", spec(["!y#{T.rand(4)}:test.local"], "s2_dev2"))

      assert {token_rows(uid), cursor_rows(uid)} == before, "nothing of the late persists was written: no new device row, the old row untouched"
    end

    test "a persist that starts while the erasure holds the users row WAITS for its commit, then writes nothing", %{cid: _cid} do
      uid = T.provision_user!()

      # the erasure's own first write, in a transaction that stays open (what the erasure holds until its commit)
      erasure = E.hold(fn -> T.sql!("UPDATE users SET deletion_status = 'deletion_in_progress' WHERE user_id = $1 AND deletion_status IS NULL", [uid]) end)
      persist = Task.async(fn -> Store.persist_sync_position(uid, "DEV1", spec(["!z#{T.rand(4)}:test.local"], "s2_race")) end)

      E.await_blocked!(persist, erasure.backend, "the initial persist")
      assert token_rows(uid) == [], "nothing is written while the persist waits"

      E.finish(erasure, :commit)

      assert :ok = Task.await(persist, 30_000)
      assert token_rows(uid) == [], "the persist saw the committed status of the erasure: no token row"
      assert cursor_rows(uid) == [], "and no cursor row (no foreign key error either)"
    end

    test "the guard lock is a share lock: persists of the same active user do not block each other", %{cid: _cid} do
      uid = T.provision_user!()
      holder = E.hold(fn -> T.sql!("SELECT 1 FROM users WHERE user_id = $1 FOR SHARE", [uid]) end)

      other = Task.async(fn -> Store.persist_sync_position(uid, "DEV9", spec(["!s#{T.rand(4)}:test.local"], "s2_share")) end)
      assert {:ok, :ok} = Task.yield(other, 5_000) || flunk("the persist of an active user waits for another share lock: the guard locks too hard")

      E.finish(holder, :rollback)
      assert [["DEV9", "s2_share", 1, 1]] = token_rows(uid)
    end

    test "the active-user path costs 2 statements (token upsert, one cursor statement), whatever the number of rooms", %{cid: _cid} do
      uid = T.provision_user!()
      counts = for n <- [1, 5, 25], do: statements(fn -> Store.persist_sync_position(uid, "DEV#{n}", spec(for(i <- 1..n, do: "!c#{i}#{T.rand(3)}:test.local"))) end)

      assert counts == [2, 2, 2], "the guard lives in the SAME statement as the token upsert (INSERT ... SELECT ... WHERE EXISTS): no extra round trip, got #{inspect(counts)}"
    end

    test "the rejected persist of an erased user costs no more statements than the active one", %{cid: cid} do
      a = E.seed_user!(cid, "a")
      assert {:ok, _} = erase!(a.uid)
      assert statements(fn -> Store.persist_sync_position(a.uid, "DEV1", spec([a.room])) end) <= 2
    end
  end

  # the number of statements (without begin / commit) the Repo runs for `fun` in this process
  defp statements(fun) do
    me = self()
    id = "atdd-ck-count-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      id,
      [:nebu, :repo, :query],
      fn _event, _measurements, meta, _config ->
        if self() == me and meta[:query] not in ["begin", "commit", "rollback"], do: send(me, {:stmt, meta[:query]})
      end,
      nil
    )

    try do
      assert :ok = fun.()
    after
      :telemetry.detach(id)
    end

    drain([]) |> length()
  end

  defp drain(acc) do
    receive do
      {:stmt, q} -> drain([q | acc])
    after
      0 -> acc
    end
  end
end
