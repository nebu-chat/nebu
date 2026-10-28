defmodule Nebu.Compliance.UserDeletionAdminGuardTest do
  @moduledoc """
  Delta review cycle 1 of story `gdpr-erasure-global-data` (Kassandra LOW-9), real database: the erasure is terminal, so the admin surface must not
  contradict it.

    * `Nebu.Admin.DB.set_is_active(user, true)` refuses a user with a `deletion_status` (`{:error, :erased}`, nothing written); deactivation stays possible,
      an active user and an unknown id behave as before (`:ok` / `{:error, :not_found}`).
    * `EventDispatcher.Server.reactivate_user/2` answers the refusal with a clean `Nebu.Matrix.Error` (`failed_precondition`, a readable message, no success audit
      row), not a crash and not a 500.
    * the admin user suggestions (`Nebu.Admin.DB.search_users/2`) never offer an erased id, even if `is_active` was set to true behind the guard's back.

  async: false (real `AuditWriter` seam via `E.setup_env!/0`, committed rows).
  """
  use ExUnit.Case, async: false

  alias Nebu.Compliance.UserDeletion
  alias Nebu.Compliance.UserDeletionTestSupport, as: E
  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration

  setup do
    {:ok, E.setup_env!()}
  end

  defp erase!(uid), do: UserDeletion.delete_user_keys(E.admin(), uid, "atdd erasure")

  test "set_is_active(erased, true) is refused and writes nothing; deactivation of an erased user is allowed", %{cid: cid} do
    a = E.seed_user!(cid, "a")
    assert {:ok, _} = erase!(a.uid)
    before = E.user_row(a.uid)

    assert {:error, :erased} = Nebu.Admin.DB.set_is_active(a.uid, true)
    assert E.user_row(a.uid) == before, "the refused reactivation changed nothing"
    assert :ok = Nebu.Admin.DB.set_is_active(a.uid, false)
  end

  test "an active, a deactivated (not erased) and an unknown user behave as before" do
    uid = T.provision_user!()
    assert :ok = Nebu.Admin.DB.set_is_active(uid, false)
    assert E.user_row(uid)["is_active"] == false
    assert :ok = Nebu.Admin.DB.set_is_active(uid, true)
    assert E.user_row(uid)["is_active"] == true
    assert {:error, :not_found} = Nebu.Admin.DB.set_is_active("@never-#{T.rand(5)}:test.local", true)
    assert {:error, :not_found} = Nebu.Admin.DB.set_is_active("@never-#{T.rand(5)}:test.local", false)
  end

  test "reactivate_user answers a clean failed_precondition error for an erased user and writes no success audit row", %{cid: cid} do
    a = E.seed_user!(cid, "a")
    assert {:ok, _} = erase!(a.uid)

    err =
      assert_raise Nebu.Matrix.Error, fn ->
        Nebu.Matrix.EventDispatcher.Server.reactivate_user(%Core.ReactivateUserRequest{user_id: a.uid}, E.admin_stream())
      end

    assert err.status == Nebu.Matrix.Status.failed_precondition()
    assert err.message =~ "erased" and err.message =~ "cannot be reactivated"
    assert E.audit_count(a.uid, "user_reactivated") == 0
    assert E.user_row(a.uid)["is_active"] == false
  end

  test "the admin user suggestions offer an active user and never an erased one", %{cid: cid} do
    a = E.seed_user!(cid, "a")
    b = E.seed_user!(cid, "b")
    assert {:ok, _} = erase!(a.uid)
    # an admin reactivation that bypassed the guard: is_active true again behind its back
    T.privileged_sql!("UPDATE users SET is_active = true WHERE user_id = $1", [a.uid])

    assert Enum.any?(Nebu.Admin.DB.search_users(b.uid, 50), &(&1.user_id == b.uid)), "control: an active user is suggested"
    assert E.user_row(a.uid)["is_active"] == true, "precondition: the erased user is is_active = true again"
    refute Enum.any?(Nebu.Admin.DB.search_users(a.uid, 50), &(&1.user_id == a.uid)), "an erased user is not suggested"
  end
end
