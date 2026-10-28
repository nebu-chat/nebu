defmodule Nebu.Compliance.UserDeletionTerminalTest do
  @moduledoc """
  Review cycle 0 of story `gdpr-erasure-global-data` (Kassandra HIGH-1 / HIGH-2, decisions D16 / D17), real database:

    * D16: the `users` PII columns (display name, avatar and email ciphertexts) are NOT crypto-shredded by the key deletion (the display name and avatar are
      encrypted with the server-wide `pii_encryption_key`): the erasure sets them to NULL, and the readers of those columns cope with NULL.
    * D17: the erasure is terminal for authentication: `is_active = false` and `deactivated_at`, and every authentication gate treats a `deletion_status` as
      deactivated, so an admin reactivation cannot revive an erased user, a freshly IdP-signed JWT (OidcPlug), an SSO `/login` and an OAuth session issue are
      refused, and `Profile.DB.upsert_profile/3` can never revert `Deleted User` (it writes nothing for an erased user and, like the initial-sync persist, locks the
      `users` row `FOR SHARE`, so an upsert that races the erasure waits for its commit).

  async: false (real `AuditWriter` seam via `E.setup_env!/0`, committed rows, own connections, the provisioning cache TTL of the OIDC plug).
  """
  use ExUnit.Case, async: false

  alias Nebu.Compliance.UserDeletion
  alias Nebu.Compliance.UserDeletionTestSupport, as: E
  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration

  setup do
    # the provisioning cache of the OIDC plug (60 s per node) would serve a bearer that an earlier request confirmed: off, so that the gates are what is tested
    Application.put_env(:nebu_http, :provision_cache_ttl_ms, 0)
    on_exit(fn -> Application.delete_env(:nebu_http, :provision_cache_ttl_ms) end)
    {:ok, E.setup_env!()}
  end

  defp erase!(uid), do: UserDeletion.delete_user_keys(E.admin(), uid, "atdd erasure")

  describe "D16 - the users PII columns" do
    test "the erasure sets every PII ciphertext column of the users row to NULL; another user's row is untouched", %{cid: cid} do
      a = E.seed_user!(cid, "a")
      b = E.seed_user!(cid, "b")
      before = E.user_row(a.uid)
      for col <- E.users_pii_columns() ++ E.users_free_text_columns(), do: assert(before[col] != nil, "precondition: users.#{col} holds data")
      b_before = E.user_row(b.uid)

      assert {:ok, _} = erase!(a.uid)

      row = E.user_row(a.uid)
      for col <- E.users_pii_columns() ++ E.users_free_text_columns(), do: assert(row[col] == nil, "users.#{col} must be NULL after the erasure")
      assert row["personal_room_id"] == before["personal_room_id"], "personal_room_id (a pointer to a retained room) stays"
      assert row["deletion_status"] == "keys_deleted" and is_integer(row["keys_deleted_at"]) and is_integer(row["anonymized_at"])
      assert row["user_id"] == a.uid and row["system_role"] == before["system_role"] and row["signing_key_id"] == before["signing_key_id"], "the pseudonymous identity row stays"
      assert E.user_row(b.uid) == b_before, "another user's row is byte-identical"
    end

    test "the token validator reads a NULL display name column without crashing (NULL-safe reader)", %{cid: _cid} do
      uid = T.provision_user!()
      T.sql!("UPDATE users SET display_name_encrypted = NULL, display_name_nonce = NULL WHERE user_id = $1", [uid])

      assert {:ok, %{display_name: "", is_active: true, is_new: false}} = Nebu.Matrix.Session.TokenValidator.validate(uid, "user", "x", "x@example.com")
    end
  end

  describe "D17 - the erasure is terminal for authentication" do
    test "is_active = false and deactivated_at are set; an earlier deactivation time is kept", %{cid: cid} do
      a = E.seed_user!(cid, "a")
      c = E.seed_user!(cid, "c")
      T.sql!("UPDATE users SET is_active = false, deactivated_at = 4242 WHERE user_id = $1", [c.uid])
      assert E.user_row(a.uid)["is_active"] == true and E.user_row(a.uid)["deactivated_at"] == nil, "precondition"

      assert {:ok, %{keys_deleted_at: at}} = erase!(a.uid)
      assert {:ok, _} = erase!(c.uid)

      assert E.user_row(a.uid)["is_active"] == false
      assert E.user_row(a.uid)["deactivated_at"] == at, "deactivated_at is the time of the erasure"
      assert E.user_row(c.uid)["deactivated_at"] == 4242, "an earlier deactivation time is kept"
    end

    test "an admin reactivation does not revive an erased user: no gate lets the account in", %{cid: cid} do
      a = E.seed_user!(cid, "a")
      assert {:ok, _} = erase!(a.uid)

      # cycle 2 (LOW-9), old -> new: `Admin.DB.set_is_active/2` refuses an erased user now (pinned in user_deletion_admin_guard_test.exs); the gates must hold even if
      # is_active = true is written behind that guard (a restore, a manual UPDATE), so the reactivation is simulated with a privileged UPDATE
      T.privileged_sql!("UPDATE users SET is_active = true WHERE user_id = $1", [a.uid])
      assert E.user_row(a.uid)["is_active"] == true, "precondition: is_active = true was written"

      assert {:error, :deactivated} = Nebu.Matrix.Session.TokenValidator.validate(a.uid, "user", "Real Name", "real@example.com")
      assert Nebu.Matrix.active?(a.uid) == false
      assert {:ok, false} = Nebu.Matrix.OAuthSession.user_active(a.uid)
      assert {:error, :inactive} = Nebu.Matrix.OAuthSession.issue(%{user_id: a.uid})
      assert {:error, :deactivated} = Nebu.Matrix.account_profile(a.uid)
      assert {:ok, []} = Nebu.Matrix.Room.DB.invitable_local_users([a.uid]), "an erased user cannot be invited"

      # a control that proves the gates are the cause: an active user passes the same gates
      b = E.seed_user!(cid, "b")
      assert {:ok, %{user_id: uid}} = Nebu.Matrix.Session.TokenValidator.validate(b.uid, "user", "x", "x@example.com")
      assert uid == b.uid and Nebu.Matrix.active?(b.uid)
      assert {:ok, true} = Nebu.Matrix.OAuthSession.user_active(b.uid)
    end

    test "an admin reactivation does not revive the account identity of the OAuth account pages either", %{cid: _cid} do
      sub = T.unique_sub()
      uid = T.provision_user!(sub)
      assert {:ok, %{user_id: ^uid}} = Nebu.Matrix.account_identity(%{"sub" => sub}), "precondition: an active user has an account identity"
      assert {:ok, _} = erase!(uid)

      T.privileged_sql!("UPDATE users SET is_active = true WHERE user_id = $1", [uid])
      assert {:error, :deactivated} = Nebu.Matrix.account_identity(%{"sub" => sub})
    end

    test "a freshly IdP-signed JWT, an SSO login and the account identity of the erased user are refused; the profile still reads Deleted User", %{priv: priv} do
      sub = T.unique_sub()
      uid = T.provision_user!(sub)
      :ok = Nebu.Matrix.Profile.DB.upsert_profile(uid, "Real-" <> sub, "mxc://test.local/real-" <> sub)

      assert T.whoami(T.unbound_jwt!(priv, sub)).status == 200, "precondition: the raw IdP JWT of an active user is accepted"
      assert {:ok, _} = erase!(uid)

      jwt = T.whoami(T.unbound_jwt!(priv, sub))
      assert jwt.status == 401, "a fresh IdP JWT of an erased user is refused, got #{jwt.status}"

      login = T.legacy_login(priv, sub)
      assert login.status == 403 and T.json(login)["errcode"] == "M_USER_DEACTIVATED", "SSO /login of an erased user: 403 M_USER_DEACTIVATED, got #{login.status}"

      assert {:error, :deactivated} = Nebu.Matrix.account_identity(%{"sub" => sub})

      assert E.profile(uid) == %{displayname: "Deleted User", avatar_url: nil}, "no login attempt reverted the anonymisation"
      assert E.user_row(uid)["display_name_encrypted"] == nil, "and no login re-provisioned the PII"
    end

    test "Profile.DB.upsert_profile writes nothing for an erased user and answers :ok; an active user is written as before", %{cid: cid} do
      a = E.seed_user!(cid, "a")
      b = E.seed_user!(cid, "b")
      assert {:ok, _} = erase!(a.uid)

      assert :ok = Nebu.Matrix.Profile.DB.upsert_profile(a.uid, "Real Name", "mxc://test.local/real")
      assert E.profile(a.uid) == %{displayname: "Deleted User", avatar_url: nil}

      assert :ok = Nebu.Matrix.Profile.DB.upsert_profile(b.uid, "New B", "mxc://test.local/newb")
      assert E.profile(b.uid) == %{displayname: "New B", avatar_url: "mxc://test.local/newb"}
    end

    test "an upsert that starts while the erasure holds the users row WAITS for its commit and then writes nothing", %{cid: cid} do
      a = E.seed_user!(cid, "a")
      original = E.profile(a.uid)

      # the erasure's own write of the users row, in a transaction that stays open
      erasure = E.hold(fn -> T.sql!("UPDATE users SET deletion_status = 'deletion_in_progress' WHERE user_id = $1 AND deletion_status IS NULL", [a.uid]) end)
      upsert = Task.async(fn -> Nebu.Matrix.Profile.DB.upsert_profile(a.uid, "Late Name", "mxc://test.local/late") end)

      E.await_blocked!(upsert, erasure.backend, "the profile upsert")
      assert E.profile(a.uid) == original, "nothing is written while the upsert waits"

      E.finish(erasure, :commit)
      assert :ok = Task.await(upsert, 30_000)
      assert E.profile(a.uid) == original, "the upsert saw the committed status: the profile was not overwritten"
    end
  end
end
