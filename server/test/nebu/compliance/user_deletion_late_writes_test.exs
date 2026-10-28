defmodule Nebu.Compliance.UserDeletionLateWritesTest do
  @moduledoc """
  D10 of story `gdpr-erasure-global-data` (OQ-C, decided DONE by D15): in-flight WRITES of the user being erased. A `PUT account_data` or a key upload authenticated before the
  erasure commit could insert a row AFTER the erasure transaction, because `AccountDataStore.put/3` and `CrossSigningKeyStore.put_keys/2` did not look at `deletion_status`.
  Both now check it inside their existing transaction (they already hold the `sync_global` advisory lock): one added predicate, no extra statement
  (`INSERT ... SELECT ... WHERE NOT EXISTS (SELECT 1 FROM users WHERE user_id = $1 AND deletion_status IS NOT NULL)`; a write that stores nothing answers `{:error, _}`).

  ## Contract pinned here

    * For a user whose `deletion_status` is not NULL both functions answer `{:error, _}` (never `:ok`: a client would be told "stored" for nothing) and store no row.
    * A user WITHOUT a `users` row, and every active user, are unaffected (`:ok`, row stored): many unit tests write account data for ids that were never provisioned.
    * A write that was waiting for the user lock held by the erasure sees the committed status after it gets the lock (it is refused), a write that got the lock
      first commits and is erased by the erasure (the D1 test of `user_deletion_concurrency_test.exs`).
  """
  use ExUnit.Case, async: false

  alias Nebu.Compliance.UserDeletion
  alias Nebu.Compliance.UserDeletionTestSupport, as: E
  alias Nebu.Matrix.{AccountDataStore, CrossSigningKeyStore}
  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration

  setup do
    {:ok, E.setup_env!()}
  end

  defp json(tag), do: Jason.encode!(%{"late" => tag})

  test "after the erasure a PUT account_data stores nothing and does not answer :ok", %{cid: cid} do
    a = E.seed_user!(cid, "a")
    assert {:ok, _} = UserDeletion.delete_user_keys(E.admin(), a.uid, "atdd")

    assert {:error, _} = AccountDataStore.put(a.uid, "m.late", json("late-" <> a.canary))
    assert E.count("account_data", a.uid) == 0
  end

  test "after the erasure a cross-signing key upload stores nothing and does not answer :ok", %{cid: cid} do
    a = E.seed_user!(cid, "a")
    assert {:ok, _} = UserDeletion.delete_user_keys(E.admin(), a.uid, "atdd")

    assert {:error, _} = CrossSigningKeyStore.put_keys(a.uid, T.cross_signing_keys(a.uid, "late" <> a.canary))
    assert E.count("cross_signing_keys", a.uid) == 0
  end

  test "an active user and a user without a users row are not affected", %{cid: _cid} do
    uid = T.provision_user!()
    assert :ok = AccountDataStore.put(uid, "m.fine", json("x"))
    assert :ok = CrossSigningKeyStore.put_keys(uid, T.cross_signing_keys(uid, "fine"))
    assert E.count("account_data", uid) == 1 and E.count("cross_signing_keys", uid) == 1

    unknown = "@never-provisioned-#{T.rand(5)}:test.local"
    assert :ok = AccountDataStore.put(unknown, "m.fine", json("y"))
    assert E.count("account_data", unknown) == 1
    T.sql!("DELETE FROM account_data WHERE user_id = $1", [unknown])
  end

  test "a write that waits for the user lock of an erasure in progress is refused after the commit and stores nothing", %{cid: _cid} do
    uid = T.provision_user!()

    # the first two writes of the erasure: the status and the user lock, in a transaction that stays open
    erasure =
      E.hold(fn ->
        T.sql!("UPDATE users SET deletion_status = 'deletion_in_progress' WHERE user_id = $1", [uid])
        T.sql!(E.lock_user_sql(), [uid])
      end)

    put = Task.async(fn -> AccountDataStore.put(uid, "m.late", json("race")) end)
    keys = Task.async(fn -> CrossSigningKeyStore.put_keys(uid, T.cross_signing_keys(uid, "race")) end)
    E.await_blocked!([put, keys], erasure.backend, "the writers")

    E.finish(erasure, :commit)

    assert {:error, _} = Task.await(put, 30_000)
    assert {:error, _} = Task.await(keys, 30_000)
    assert E.count("account_data", uid) == 0 and E.count("cross_signing_keys", uid) == 0
  end
end
