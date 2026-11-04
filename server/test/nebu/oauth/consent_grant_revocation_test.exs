defmodule Nebu.OAuth.ConsentGrantRevocationTest do
  @moduledoc """
  Story `persistent-consent-grants` (REQ-2026-003), scenario 6 and the deletion paths that belong to the admin side: revoking a client
  (`Nebu.OAuth.ClientStore.revoke/3`, CR4 of `oauth-client-revocation`) and the identity binding of a grant.

  ## What "the SAME client" means (decision, verified in code)

  A revocation is final for a registration: the guard trigger of 000046 forbids `revoked -> approved`, and a re-registration with the same
  metadata hits the revoked row (never approved again, CR6); changed metadata is a NEW `client_id` (no grant of it exists). So scenario 6 can only
  happen through the OWNER OVERRIDE the revocation story names (the trigger is disabled for one privileged transaction) or a surviving row after a
  race. Two independent layers keep a grant from being inherited:

    1. the grants of the client are DELETED in the revoke transaction (same transaction, so a failed audit or a failed delete rolls the revocation
       back and the grants stay, atomically);
    2. every grant carries `client_approved_at`, the `approved_at` of the registration at the time of the Allow; a client that is approved again has
       a new `approved_at`, so even a surviving row (a race, a restored backup, an operator's SQL) never matches.

  Grants of other clients and other users are never touched by a revocation.
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  alias Nebu.OAuth.ConsentGrantTestSupport, as: G
  alias Nebu.OAuth.TestSupport, as: T

  @https G.https()

  setup do
    env = G.setup_env!()
    sub = T.unique_sub()
    uid = T.user_id_for(%{"sub" => sub})
    on_exit(fn -> G.cleanup_grants([uid]) end)
    {:ok, Map.merge(env, %{sub: sub, uid: uid})}
  end

  describe "scenario 6 - a revoked client asks for consent again after re-approval" do
    test "allowed, revoked (real cascade), approved again: authorizing with the same scope shows the consent screen", %{cid: cid, priv: priv, sub: sub, uid: uid} do
      G.allow_new!(cid, priv, sub)
      assert G.grant_count(uid, cid) == 1

      G.revoke!(cid)
      assert G.grant_count(uid, cid) == 0, "the revocation deleted the grant"
      assert T.client_row(cid)["status"] == "revoked"

      G.reapprove!(cid)
      assert T.client_row(cid)["status"] == "approved"

      G.login(cid, priv, sub) |> G.assert_consent!()
    end

    test "even a SURVIVING grant row (written for the old approval) is not honoured after the client is approved again", %{cid: cid, priv: priv, sub: sub, uid: uid} do
      old = T.client_row(cid)["approved_at"]
      G.allow_new!(cid, priv, sub)
      G.revoke!(cid)
      G.reapprove!(cid)

      # the operator's SQL / a restored backup: a row with the OLD approval time
      :ok = G.insert_grant!(uid, cid, %{binding_sql: "'#{DateTime.to_iso8601(old)}'::timestamptz"})
      assert G.grant_count(uid, cid) == 1
      assert DateTime.compare(T.client_row(cid)["approved_at"], old) == :gt, "precondition: the new approval has a later approved_at"

      G.login(cid, priv, sub) |> G.assert_consent!()
    end

    test "the first Allow after the re-approval remembers again, bound to the NEW approval, and the next login skips", %{cid: cid, priv: priv, sub: sub, uid: uid} do
      G.allow_new!(cid, priv, sub)
      G.revoke!(cid)
      G.reapprove!(cid)

      G.allow_new!(cid, priv, sub)
      assert G.grant_row(uid, cid)["client_approved_at"] == T.client_row(cid)["approved_at"]
      G.login(cid, priv, sub) |> G.assert_skipped!()
    end
  end

  describe "the revoke transaction" do
    test "deletes the grants of EVERY user of the client and nobody else's", %{cid: cid, priv: priv, sub: sub, uid: uid} do
      other_client = T.oauth_client!([@https], client_name: "Second App")
      users = for _ <- 1..3, do: T.provision_user!()
      on_exit(fn -> G.cleanup_grants(users) end)

      for u <- [uid | users], do: G.seed_grant!(u, cid)
      G.seed_grant!(uid, other_client)
      assert G.grant_count_for_client(cid) == 4

      G.revoke!(cid)

      assert G.grant_count_for_client(cid) == 0
      assert G.grant_count(uid, other_client) == 1, "the grant of another client stays"
      G.login(other_client, priv, sub) |> G.assert_skipped!()
    end

    test "a failing audit rolls the revocation back: the client stays approved and the grants stay (one transaction)", %{cid: cid, priv: priv, sub: sub, uid: uid} do
      G.allow_new!(cid, priv, sub)

      assert {:error, {:audit, _}} = Nebu.OAuth.ClientStore.revoke(cid, "@admin:test.local", audit: fn _pairs -> {:error, :atdd_audit_down} end)

      assert T.client_row(cid)["status"] == "approved"
      assert G.grant_count(uid, cid) == 1, "the grant was deleted INSIDE the transaction, so the rollback restored it"
      G.login(cid, priv, sub) |> G.assert_skipped!()
    end

    test "a grant table that cannot be written fails the revocation closed: nothing is revoked, nothing half-deleted", %{cid: cid, priv: priv, sub: sub, uid: uid} do
      G.allow_new!(cid, priv, sub)

      result = G.with_table_unreadable(fn -> Nebu.OAuth.ClientStore.revoke(cid, "@admin:test.local", []) end)

      assert {:error, _} = result
      assert T.client_row(cid)["status"] == "approved"
      assert G.grant_count(uid, cid) == 1
    end

    test "a code minted by the skip path just before the revocation cannot be redeemed afterwards", %{cid: cid, priv: priv, sub: sub} do
      G.allow_new!(cid, priv, sub)
      login = G.login(cid, priv, sub)
      %{"code" => code} = G.assert_skipped!(login)

      G.revoke!(cid)

      conn = G.redeem(login, code)
      assert conn.status in [400, 401], "got #{G.describe(conn)}"
      assert T.json(conn)["error"] in ["invalid_grant", "invalid_client"]
    end
  end

  describe "a grant never authorises an unapproved client" do
    test "a revoked client with a surviving grant is refused at authorize (403 client_rejected page, no redirect)", %{cid: cid, priv: priv, sub: sub, uid: uid} do
      G.allow_new!(cid, priv, sub)
      :ok = T.mark_revoked!(cid)
      assert G.grant_count(uid, cid) == 1, "precondition: a bare status change leaves the grant"

      conn = T.authorize(T.authorize_params(cid, @https, %{"scope" => G.scope()}))
      assert conn.status == 403
      assert conn.resp_body =~ "client_rejected"
      assert T.location(conn) == nil
    end

    test "revoked between authorize and the callback with a surviving grant: the callback refuses (403), no code, no consent row", %{cid: cid, priv: priv, sub: sub} do
      G.allow_new!(cid, priv, sub)
      flow = T.start_flow(cid, @https, %{"scope" => G.scope("REVDEV0001")})
      :ok = T.mark_revoked!(cid)

      cb = T.finish_flow(flow, priv, claims: %{"sub" => sub, "auth_time" => System.system_time(:second)})
      assert cb.status == 403
      assert cb.resp_body =~ "client_rejected"
      assert T.count_for("oauth_consent_requests", cid) == 0
      assert T.count_for("oauth_codes", cid) == 1, "only the code of the very first Allow exists"
    end
  end
end
