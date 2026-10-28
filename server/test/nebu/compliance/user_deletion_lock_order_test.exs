defmodule Nebu.Compliance.UserDeletionLockOrderTest do
  @moduledoc """
  Real-database lock order test for story `gdpr-erasure-global-data` (dev step, cycle 0): the erasure must not deadlock with the
  cross-signing reset writer (`protected.ex` `replace_with_approval/7`).

  That writer holds, in ONE transaction and in this order: the `uia_sessions` row of its approval (`Uia.consume/4`), the
  `cross_signing_keys` row and then the per-user `sync_global|` advisory lock (`CrossSigningKeyStore.lock_keys/1` since story
  cross-signing-upload-races, which then reads; formerly `get_keys_for_update/1`), then writes (`put_keys/2`). An erasure that took the
  advisory lock FIRST and then deleted the two rows would wait for a row the writer holds while the writer waits for the advisory lock: a lock cycle
  that PostgreSQL resolves after `deadlock_timeout` by aborting one side. The erasure therefore locks the two rows before the advisory lock.

  async: false (real `AuditWriter` seam via `E.setup_env!/0`, committed rows, own connections).
  """
  use ExUnit.Case, async: false

  alias Nebu.Compliance.UserDeletion
  alias Nebu.Compliance.UserDeletionTestSupport, as: E
  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration

  setup do
    {:ok, E.setup_env!()}
  end

  test "an erasure racing a cross-signing reset writer waits for its rows, then both commit (no lock cycle)", %{cid: cid} do
    a = E.seed_user!(cid, "a")
    assert E.count("uia_sessions", a.uid) >= 1 and E.count("cross_signing_keys", a.uid) == 1, "precondition: both rows exist"

    parent = self()

    # the writer, in the lock order of replace_with_approval/7: uia row, cross-signing row, (wait), advisory lock, key write, commit
    writer =
      Task.async(fn ->
        Nebu.Repo.transaction(fn ->
          %{rows: [[backend]]} = T.sql!("SELECT pg_backend_pid()")
          T.sql!("UPDATE uia_sessions SET consumed = TRUE WHERE user_id = $1", [a.uid])
          T.sql!("SELECT 1 FROM cross_signing_keys WHERE user_id = $1 FOR UPDATE", [a.uid])
          send(parent, {:holding, backend})

          receive do
            :go -> :ok
          after
            30_000 -> Nebu.Repo.rollback(:atdd_timeout)
          end

          T.sql!(E.lock_user_sql(), [a.uid])
          :written
        end)
      end)

    assert_receive {:holding, backend}, 15_000
    erasure = Task.async(fn -> UserDeletion.delete_user_keys(E.admin(), a.uid, "atdd lock order") end)

    # the erasure waits for the rows the writer holds, and does NOT hold the advisory lock meanwhile (the writer can take it)
    E.await_blocked!(erasure, backend, "the erasure")
    send(writer.pid, :go)

    assert {:ok, :written} = Task.await(writer, 20_000), "the writer got the advisory lock (the erasure did not hold it while waiting for the rows)"
    assert {:ok, %{keys_deleted_at: _}} = Task.await(erasure, 30_000), "the erasure was not the victim of a deadlock"

    assert E.count("uia_sessions", a.uid) == 0
    assert E.count("cross_signing_keys", a.uid) == 0
  end
end
