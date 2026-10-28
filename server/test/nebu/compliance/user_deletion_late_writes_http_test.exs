defmodule Nebu.Compliance.UserDeletionLateWritesHttpTest do
  @moduledoc """
  Review cycle 0 of story `gdpr-erasure-global-data` (decision D18 (b), (c)), real database:

    * D18 (c): the refusal of a write of a user whose erasure is under way or done (`{:error, :user_erased}` of the two stores) is a PERMANENT condition: the
      handlers answer `403 M_USER_DEACTIVATED` (like the deactivated-account answer of `/login`), log it at info with the error kind only and never at error level
      (it was `500 M_UNKNOWN` + `Logger.error`, which clients retry). The request is authenticated (a bearer that the provisioning cache of the OIDC plug confirmed
      before the status was set: the in-flight request of the story), so the handler, not the gate, answers.
    * D18 (b): the third writer of `cross_signing_keys`, the signature merge (`CrossSigningKeyStore.merge_signatures/4` since story cross-signing-upload-races, which also takes the submitted
      object; `POST /keys/signatures/upload` names the SIGNED user, which the handler limits to the caller), takes the same protocol as `put_keys/2`: the per-user `sync_global|` advisory lock and the
      `deletion_status` predicate. A merge into the keys of an erased user stores nothing and answers `:not_found`.

  async: false (real `AuditWriter` seam via `E.setup_env!/0`, committed rows, `Logger` level, own connections).
  """
  use ExUnit.Case, async: false

  alias Nebu.Compliance.UserDeletionTestSupport, as: E
  alias Nebu.Matrix.CrossSigningKeyStore
  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration

  setup do
    env = E.setup_env!()
    previous = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous) end)
    {:ok, env}
  end

  defp account_data_put(token, uid, type, body),
    do: T.matrix_request(:put, "/_matrix/client/v3/user/#{URI.encode_www_form(uid)}/account_data/#{type}", token, body: body)

  # an in-flight request: the bearer was confirmed (and cached) while the user was active, then the status is set
  defp in_flight_session!(uid) do
    session = T.legacy_session!(uid, "INFL" <> String.upcase(T.rand(3)))
    assert T.whoami(session.at).status == 200, "precondition: the session is accepted and the user is now in the provisioning cache"
    T.sql!("UPDATE users SET deletion_status = 'keys_deleted' WHERE user_id = $1", [uid])
    session
  end

  describe "D18 (c) - the refusal is 403 M_USER_DEACTIVATED, logged at info" do
    test "PUT account_data of an erased user in flight: 403 M_USER_DEACTIVATED, nothing stored, no error-level log, no content in the log" do
      uid = T.provision_user!()
      session = in_flight_session!(uid)
      secret = "late-secret-" <> T.rand(6)

      log = ExUnit.CaptureLog.capture_log([level: :debug], fn -> send(self(), {:resp, account_data_put(session.at, uid, "m.late", %{"secret" => secret})}) end)

      assert_received {:resp, resp}
      assert resp.status == 403 and T.json(resp)["errcode"] == "M_USER_DEACTIVATED", "got #{resp.status} #{resp.resp_body}"
      assert E.count("account_data", uid) == 0
      assert log =~ "refused: user_erased"
      refute log =~ "[error]", "a permanent refusal is not an error-level event"
      refute log =~ secret
    end

    test "the first cross-signing upload of an erased user in flight: 403 M_USER_DEACTIVATED, nothing stored, no error-level log" do
      uid = T.provision_user!()
      session = in_flight_session!(uid)

      log = ExUnit.CaptureLog.capture_log([level: :debug], fn -> send(self(), {:resp, T.device_signing_upload(session.at, T.cross_signing_keys(uid, "late"))}) end)

      assert_received {:resp, resp}
      assert resp.status == 403 and T.json(resp)["errcode"] == "M_USER_DEACTIVATED", "got #{resp.status} #{resp.resp_body}"
      assert E.count("cross_signing_keys", uid) == 0
      assert log =~ "refused: user_erased"
      refute log =~ "[error]"
    end

    test "control: an active user's PUT account_data is stored (200)" do
      uid = T.provision_user!()
      session = T.legacy_session!(uid, "CTRL" <> String.upcase(T.rand(3)))

      assert account_data_put(session.at, uid, "m.fine", %{"x" => 1}).status == 200
      assert E.count("account_data", uid) == 1
    end
  end

  describe "D18 (b) - the signature merge" do
    defp master_key_id(uid) do
      %{"keys" => keys} = CrossSigningKeyStore.get_keys(uid)["master_key"]
      keys |> Map.keys() |> hd() |> String.split(":", parts: 2) |> List.last()
    end

    defp signatures(tag), do: %{"@signer:test.local" => %{"ed25519:SIGNER" => "sig-" <> tag}}

    # story cross-signing-upload-races: the submitted object is required (the store repeats the object check under the lock); these tests submit
    # the stored master object itself
    defp master_object(uid), do: CrossSigningKeyStore.get_keys(uid)["master_key"]

    test "a merge into the keys of an erased user stores nothing and answers :not_found; an active user's merge works" do
      a = T.provision_user!()
      b = T.provision_user!()
      for uid <- [a, b], do: assert(:ok = CrossSigningKeyStore.put_keys(uid, T.cross_signing_keys(uid, "m" <> T.rand(3))))
      a_key = master_key_id(a)
      b_key = master_key_id(b)
      a_obj = master_object(a)
      b_obj = master_object(b)

      # the in-flight case: the keys were read, the status is set (the erasure's own status write) before the merge's write
      T.sql!("UPDATE users SET deletion_status = 'keys_deleted' WHERE user_id = $1", [a])
      before = E.fp("cross_signing_keys", a)

      assert :not_found = CrossSigningKeyStore.merge_signatures(a, a_key, signatures("late"), a_obj)
      assert E.fp("cross_signing_keys", a) == before, "the row of the erased user was not touched"

      assert :ok = CrossSigningKeyStore.merge_signatures(b, b_key, signatures("fine"), b_obj)
      assert CrossSigningKeyStore.get_keys(b)["master_key"]["signatures"] == signatures("fine"), "the control merge is stored"
    end

    test "a merge does not re-create the row of an erased user whose keys were deleted meanwhile" do
      a = T.provision_user!()
      assert :ok = CrossSigningKeyStore.put_keys(a, T.cross_signing_keys(a, "gone"))
      key = master_key_id(a)
      obj = master_object(a)
      T.sql!("UPDATE users SET deletion_status = 'keys_deleted' WHERE user_id = $1", [a])
      T.sql!("DELETE FROM cross_signing_keys WHERE user_id = $1", [a])

      assert :not_found = CrossSigningKeyStore.merge_signatures(a, key, signatures("x"), obj)
      assert E.count("cross_signing_keys", a) == 0
    end

    test "the merge takes the per-user lock: it WAITS for a transaction that holds it", %{cid: _cid} do
      uid = T.provision_user!()
      assert :ok = CrossSigningKeyStore.put_keys(uid, T.cross_signing_keys(uid, "lk"))
      key = master_key_id(uid)
      obj = master_object(uid)

      holder = E.hold(fn -> T.sql!(E.lock_user_sql(), [uid]) end)
      merge = Task.async(fn -> CrossSigningKeyStore.merge_signatures(uid, key, signatures("lk"), obj) end)

      E.await_blocked!(merge, holder.backend, "the signature merge")
      E.finish(holder, :rollback)

      assert :ok = Task.await(merge, 30_000)
      assert CrossSigningKeyStore.get_keys(uid)["master_key"]["signatures"] == signatures("lk")
    end
  end
end
