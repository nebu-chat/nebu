defmodule Nebu.Compliance.UserDeletionLogTest do
  @moduledoc """
  Gherkin scenario 9 / D7 of story `gdpr-erasure-global-data`: "No sensitive data in logs" LAW (tokens, credentials AND chat / account content). An erasure of a
  user with account data, key material and a display name, run once successfully and once with a forced failure, with logging captured at DEBUG level
  (`Logger.configure(level: :debug)` for the test; restored), must leave no canary in the captured log, in the `user_keys_deletion_attempted` audit row
  (`metadata`, `error_detail`), nor in the error the dispatcher raises.

  Canaries: the display name and avatar, the secret-storage / cross-signing / push-rule / `m.direct` content, the key objects, the message body, the IdP
  refresh token ciphertext inputs of the seeded consent request and code, the user's legacy access / refresh token and the authorization code. The user id
  itself is the retained pseudonym and may appear (the existing code logs it).

  The forced failure is a privileged trigger that raises a FIXED text on the deletion of `account_data` rows of the user (it carries nothing of the data).
  """
  use ExUnit.Case, async: false

  alias Nebu.Compliance.UserDeletion
  alias Nebu.Compliance.UserDeletionTestSupport, as: E
  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration

  setup do
    env = E.setup_env!()
    previous = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous) end)
    {:ok, env}
  end

  defp secrets_of(w, session) do
    Map.merge(w.secrets, %{
      access_token: session.at,
      refresh_token: session.rt,
      code: w.grant.code,
      verifier: w.grant.verifier,
      canary: w.canary
    })
  end

  defp dispatcher_erase(uid) do
    req = %Core.DeleteUserKeysRequest{admin_user_id: E.admin(), target_user_id: uid, reason: "atdd erasure reason"}
    Nebu.Matrix.EventDispatcher.Server.delete_user_keys(req, E.admin_stream())
  end

  describe "Scenario 9 - the erasure writes no personal data to logs" do
    test "a successful erasure (UserDeletion and the dispatcher with its session teardown): no canary in the debug log", %{cid: cid} do
      a = E.seed_user!(cid, "a")
      b = E.seed_user!(cid, "b")
      a_session = E.seed_sessions!(a)
      b_session = E.seed_sessions!(b)
      secrets = secrets_of(a, a_session)

      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          assert %Core.DeleteUserKeysResponse{status: "keys_deleted"} = dispatcher_erase(a.uid)
          assert {:error, :conflict} = UserDeletion.delete_user_keys(E.admin(), a.uid, "atdd second")
        end)

      T.refute_secrets_in_log(log, secrets)
      # B's data must not be logged by A's erasure either
      T.refute_secrets_in_log(log, Map.put(b.secrets, :b_access_token, b_session.at))
    end

    test "UserDeletion called directly: no canary in the debug log, and the success audit row carries only the reason", %{cid: cid} do
      a = E.seed_user!(cid, "a")
      session = E.seed_sessions!(a)

      log = ExUnit.CaptureLog.capture_log([level: :debug], fn -> assert {:ok, _} = UserDeletion.delete_user_keys(E.admin(), a.uid, "atdd direct") end)

      T.refute_secrets_in_log(log, secrets_of(a, session))
      [[_actor, "success", metadata, detail]] = E.audit_rows(a.uid, "user_keys_deleted")
      assert %{"reason" => "atdd direct"} == Jason.decode!(metadata), "the success audit metadata is exactly the reason"
      assert detail == nil
    end

    test "a forced failure: no canary in the debug log, in the attempted-audit row, in the raised error", %{cid: cid} do
      a = E.seed_user!(cid, "a")
      session = E.seed_sessions!(a)
      secrets = secrets_of(a, session)
      remove = E.block!("account_data", "DELETE", a.uid)

      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          error = assert_raise Nebu.Matrix.Error, fn -> dispatcher_erase(a.uid) end
          send(self(), {:message, error.message})
          assert {:error, _} = UserDeletion.delete_user_keys(E.admin(), a.uid, "atdd direct failure")
        end)

      assert_received {:message, message}
      assert log =~ "delete_user_keys failed", "the failure itself is still logged (the existing behaviour)"
      T.refute_secrets_in_log(log, secrets)
      T.refute_secrets_in_log(message, secrets)

      rows = E.audit_rows(a.uid, "user_keys_deletion_attempted")
      assert length(rows) == 2, "one attempted-audit row per failed attempt"

      for [_actor, "attempted", metadata, detail] <- rows do
        T.refute_secrets_in_log(metadata <> " " <> (detail || ""), secrets)
        assert metadata =~ "reason" and metadata =~ "error"
      end

      remove.()
    end

    test "a post-commit teardown FAILURE: the warnings carry no display name, device name, IP address or token", %{cid: cid} do
      a = E.seed_user!(cid, "a")
      session = E.seed_sessions!(a)
      secrets = secrets_of(a, session)
      remove_devices = E.block!("devices", "DELETE", a.uid)
      remove_sessions = T.block_session_deletes!(a.uid)

      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          assert %Core.DeleteUserKeysResponse{status: "keys_deleted"} = dispatcher_erase(a.uid)
        end)

      assert log =~ "[warning]" or log =~ "[error]", "precondition: the failing teardown is logged at all (else this test proves nothing)"
      T.refute_secrets_in_log(log, secrets)
      remove_devices.()
      remove_sessions.()
    end

    test "D10 refusal and D5 rejected persist of an erased user: the refused content, the room id and the user's data are in no log", %{cid: cid} do
      a = E.seed_user!(cid, "a")
      assert {:ok, _} = UserDeletion.delete_user_keys(E.admin(), a.uid, "atdd late writes")
      late = "late-content-" <> a.canary

      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          assert {:error, _} = Nebu.Matrix.AccountDataStore.put(a.uid, "m.late", Jason.encode!(%{"secret" => late}))
          assert {:error, _} = Nebu.Matrix.CrossSigningKeyStore.put_keys(a.uid, T.cross_signing_keys(a.uid, late))
          assert :ok = Nebu.Matrix.Session.PgStore.Postgres.persist_sync_position(a.uid, "CKLATE", %{mode: :initial, new_token: "s2_" <> late, last_event_id: nil, keep: [], rows: [%{room_id: a.room, pos: 1, class: "join", invite_marker: nil, base: nil}]})
        end)

      T.refute_secrets_in_log(log, Map.merge(a.secrets, %{late: late, room: a.room}))
    end

    test "a forced failure of the profile anonymisation: the display name is in no log and no audit row", %{cid: cid} do
      a = E.seed_user!(cid, "a")
      secrets = %{display: a.secrets.display, avatar: a.secrets.avatar, canary: a.canary}
      remove = E.block!("profiles", "UPDATE", a.uid)

      log = ExUnit.CaptureLog.capture_log([level: :debug], fn -> assert {:error, _} = UserDeletion.delete_user_keys(E.admin(), a.uid, "atdd profile failure") end)

      T.refute_secrets_in_log(log, secrets)
      for [_actor, _outcome, metadata, detail] <- E.audit_rows(a.uid, "user_keys_deletion_attempted"), do: T.refute_secrets_in_log(metadata <> " " <> (detail || ""), secrets)
      remove.()
    end
  end
end
