defmodule Nebu.OAuth.ConsentGrantStoreTest do
  @moduledoc """
  Story `persistent-consent-grants` (REQ-2026-003): `Nebu.OAuth.ConsentGrantStore`, the table `oauth_consent_grants` as seen through its API
  (real database, `--include integration`). The flows through the HTTP endpoints are in `consent_grant_flow_test.exs`.

  Decisions pinned here:

    * ONE row per (user, client). An Allow REPLACES scope and redirect URI with what the user just allowed (it never merges a grant the user
      did not just click): a narrower Allow narrows the grant, a broader one widens it, another redirect URI moves it. `created_at` (first Allow) is
      never rewritten, `granted_at` is the latest Allow.
    * The scope is stored normalised (sorted unique tokens, NO device token) whatever the caller passes.
    * The identity binding `client_approved_at` is read from the client row INSIDE the statement that writes the grant, and the write only happens
      for an `approved` client. A grant for a pending / rejected / revoked / unknown client is never created.
    * `skip_consent?/4` is ONE statement that joins the client row: the grant and the client's approval are read together, so a revocation that has
      committed can never be missed by a second, later statement (the revoke wins the race). It is true only when the client is `approved`, the
      binding equals the client's CURRENT `approved_at`, the redirect URI is equal and the requested scope is covered.
    * An unreadable table never raises and never skips: `{:error, :storage}` (the caller shows the consent screen).
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  alias Nebu.OAuth.ConsentGrantTestSupport, as: G
  alias Nebu.OAuth.TestSupport, as: T

  @other "https://other.example.com/cb"

  setup do
    env = G.setup_env!()
    uid = T.provision_user!()
    on_exit(fn -> G.cleanup_grants([uid]) end)
    {:ok, Map.merge(env, %{uid: uid})}
  end

  describe "upsert/1" do
    test "creates ONE row with the normalised scope (no device token), the redirect URI and the client's approval time as binding", %{uid: uid, cid: cid} do
      G.upsert!(%{user_id: uid, client_id: cid, scope: G.scope("DEV-ONE"), redirect_uri: G.https()})

      assert [row] = G.grant_rows(uid)
      assert row["user_id"] == uid and row["client_id"] == cid
      assert row["scope"] == G.remembered_scope()
      refute row["scope"] =~ "DEV-ONE"
      refute row["scope"] =~ "device"
      assert row["redirect_uri"] == G.https()
      assert row["client_approved_at"] == T.client_row(cid)["approved_at"], "the binding is the client's approved_at"
      assert DateTime.diff(DateTime.utc_now(), row["created_at"]) in 0..10
      assert DateTime.diff(DateTime.utc_now(), row["granted_at"]) in 0..10
    end

    test "an unordered scope with duplicates is stored sorted and unique", %{uid: uid, cid: cid} do
      u = T.unstable_prefix()
      G.upsert!(%{user_id: uid, client_id: cid, scope: "#{u}device:X #{u}api:* openid #{u}api:* openid", redirect_uri: G.https()})
      assert G.grant_row(uid, cid)["scope"] == "openid #{u}api:*"
    end

    test "a second Allow REPLACES scope and redirect URI (narrower, then broader, then another URI); still one row, created_at kept, granted_at advanced", %{uid: uid, cid: cid} do
      G.upsert!(%{user_id: uid, client_id: cid, scope: G.scope("D1", openid: true), redirect_uri: G.https()})
      T.privileged_sql!("UPDATE oauth_consent_grants SET created_at = now() - interval '2 days', granted_at = now() - interval '2 days' WHERE user_id = $1", [uid])
      before = G.grant_row(uid, cid)

      G.upsert!(%{user_id: uid, client_id: cid, scope: G.scope("D2", openid: false), redirect_uri: G.https()})
      assert [row] = G.grant_rows(uid)
      assert row["scope"] == G.remembered_scope(openid: false), "the Allow replaced the scope: a narrower Allow narrows"
      assert row["created_at"] == before["created_at"], "created_at is the FIRST Allow and is never rewritten"
      assert DateTime.compare(row["granted_at"], before["granted_at"]) == :gt
      assert DateTime.diff(DateTime.utc_now(), row["granted_at"]) in 0..10

      G.upsert!(%{user_id: uid, client_id: cid, scope: G.scope("D3", openid: true), redirect_uri: G.https()})
      assert G.grant_row(uid, cid)["scope"] == G.remembered_scope(openid: true), "a broader Allow widens"

      G.upsert!(%{user_id: uid, client_id: cid, scope: G.scope("D3"), redirect_uri: @other})
      assert [row] = G.grant_rows(uid)
      assert row["redirect_uri"] == @other, "the grant moves to the redirect URI the user just allowed"
      assert row["user_id"] == uid and row["client_id"] == cid
    end

    test "separate users and separate clients have separate rows", %{uid: uid, cid: cid} do
      other_user = T.provision_user!()
      other_client = T.oauth_client!([G.https()], client_name: "Second App")
      on_exit(fn -> G.cleanup_grants([other_user]) end)

      for {u, c} <- [{uid, cid}, {other_user, cid}, {uid, other_client}] do
        G.upsert!(%{user_id: u, client_id: c, scope: G.scope(), redirect_uri: G.https()})
      end

      assert G.grant_count(uid) == 2
      assert G.grant_count(other_user) == 1
      assert G.grant_count_for_client(cid) == 2
      assert G.grant_count_for_client(other_client) == 1
    end

    test "writes NOTHING for a pending, rejected, revoked or unknown client, and never raises", %{uid: uid} do
      pending = T.oauth_client!([G.https()], status: "pending")
      rejected = T.oauth_client!([G.https()], status: "rejected")
      revoked = T.oauth_client!([G.https()], status: "revoked")

      for c <- [pending, rejected, revoked, "no-such-client-" <> T.rand()] do
        assert {:error, _} = G.upsert(%{user_id: uid, client_id: c, scope: G.scope(), redirect_uri: G.https()}), "client #{c}"
      end

      assert G.grant_count(uid) == 0
    end

    test "writes nothing when nothing would be granted (empty scope, device-only scope, empty redirect URI)", %{uid: uid, cid: cid} do
      u = T.unstable_prefix()

      for attrs <- [%{scope: ""}, %{scope: "#{u}device:ONLY"}, %{scope: nil}, %{redirect_uri: ""}] do
        full = Map.merge(%{user_id: uid, client_id: cid, scope: G.scope(), redirect_uri: G.https()}, attrs)
        assert {:error, _} = G.upsert(full), inspect(attrs)
      end

      assert G.grant_count(uid) == 0
    end

    test "24 concurrent Allows of the same user and client end in ONE row, every call answers :ok (ON CONFLICT, no unique violation)", %{uid: uid, cid: cid} do
      results =
        for i <- 1..24 do
          Task.async(fn ->
            G.upsert(%{user_id: uid, client_id: cid, scope: G.scope("DEV#{i}", openid: rem(i, 2) == 0), redirect_uri: if(rem(i, 3) == 0, do: @other, else: G.https())})
          end)
        end
        |> Task.await_many(30_000)

      assert Enum.all?(results, &(&1 == :ok)), inspect(results)
      assert [row] = G.grant_rows(uid)
      assert row["scope"] in [G.remembered_scope(openid: true), G.remembered_scope(openid: false)]
      assert row["redirect_uri"] in [G.https(), @other]
    end
  end

  describe "skip_consent?/4" do
    setup %{uid: uid, cid: cid} do
      G.upsert!(%{user_id: uid, client_id: cid, scope: G.scope("D1"), redirect_uri: G.https()})
      :ok
    end

    test "true for the same user, client, scope and redirect URI, whatever the device of the new login", %{uid: uid, cid: cid} do
      assert G.skip?(uid, cid, G.scope("A-NEW-DEVICE"), G.https())
      assert G.skip?(uid, cid, G.scope("D1"), G.https())
    end

    test "true for a narrower scope, false for a broader one or another Matrix prefix", %{uid: uid, cid: cid} do
      assert G.skip?(uid, cid, G.scope("N", openid: false), G.https())
      T.privileged_sql!("UPDATE oauth_consent_grants SET scope = $2 WHERE user_id = $1", [uid, G.remembered_scope(openid: false)])
      refute G.skip?(uid, cid, G.scope("N", openid: true), G.https()), "openid was never granted"
      refute G.skip?(uid, cid, G.scope("N", openid: false, prefix: :stable), G.https()), "another prefix is another token"
    end

    test "false for another redirect URI (exact comparison, no normalisation)", %{uid: uid, cid: cid} do
      refute G.skip?(uid, cid, G.scope(), @other)
      refute G.skip?(uid, cid, G.scope(), G.https() <> "/")
      refute G.skip?(uid, cid, G.scope(), String.upcase(G.https()))
      refute G.skip?(uid, cid, G.scope(), G.https() <> "?x=1")
    end

    test "false for another user and for another client", %{uid: uid, cid: cid} do
      refute G.skip?(T.provision_user!(), cid, G.scope(), G.https())
      other_client = T.oauth_client!([G.https()])
      refute G.skip?(uid, other_client, G.scope(), G.https())
      assert G.skip?(uid, cid, G.scope(), G.https())
    end

    test "false when the binding does not match the client's current approval (the client was approved AGAIN)", %{uid: uid, cid: cid} do
      T.privileged_sql!("UPDATE oauth_consent_grants SET client_approved_at = client_approved_at - interval '1 minute' WHERE user_id = $1", [uid])
      refute G.skip?(uid, cid, G.scope(), G.https())
    end

    test "false for a revoked client although the grant row still exists (the revocation wins, no second statement involved)", %{uid: uid, cid: cid} do
      assert G.skip?(uid, cid, G.scope(), G.https())
      :ok = T.mark_revoked!(cid)
      assert G.grant_count(uid) == 1, "precondition: a bare status UPDATE leaves the grant row"
      refute G.skip?(uid, cid, G.scope(), G.https())

      # even when the registration is approved again, the surviving grant belongs to the OLD approval
      G.reapprove!(cid)
      refute G.skip?(uid, cid, G.scope(), G.https())
    end

    test "false for a rejected or pending client row with a grant row (a grant never authorises an unapproved client)", %{uid: uid} do
      for status <- ["pending", "rejected"] do
        c = T.oauth_client!([G.https()], status: status)
        T.privileged_sql!("INSERT INTO oauth_consent_grants (user_id, client_id, scope, redirect_uri, client_approved_at) VALUES ($1, $2, $3, $4, now())", [uid, c, G.remembered_scope(), G.https()])
        refute G.skip?(uid, c, G.scope(), G.https()), status
      end
    end

    test "ONE statement reads grant and client together (the revoke race): a single query touches oauth_consent_grants and it also names oauth_clients", %{uid: uid, cid: cid} do
      id = "grant-skip-" <> T.rand()
      me = self()
      :telemetry.attach(id, [:nebu, :repo, :query], fn _e, _m, meta, _c -> if self() == me, do: send(me, {:q, meta[:query]}) end, nil)

      try do
        assert G.skip?(uid, cid, G.scope(), G.https())
      after
        :telemetry.detach(id)
      end

      queries = drain([])
      grant_queries = Enum.filter(queries, &(&1 =~ "oauth_consent_grants"))
      assert length(grant_queries) == 1, "exactly one statement reads the grants, got #{inspect(queries)}"
      assert hd(grant_queries) =~ "oauth_clients", "that statement joins the client row (status and approval time)"
    end

    test "{:error, :storage} when the table cannot be read; never a raise, never true", %{uid: uid, cid: cid} do
      G.with_table_unreadable(fn ->
        assert {:error, :storage} = G.call(:skip_consent?, [uid, cid, G.scope(), G.https()])
      end)

      assert G.skip?(uid, cid, G.scope(), G.https()), "readable again"
    end
  end

  describe "list_for_user/1" do
    test "returns the user's own, currently valid grants with the claimed client name; nobody else's", %{uid: uid, cid: cid} do
      other_user = T.provision_user!()
      second = T.oauth_client!([G.https()], client_name: "Second App")
      on_exit(fn -> G.cleanup_grants([other_user]) end)

      G.upsert!(%{user_id: uid, client_id: cid, scope: G.scope(), redirect_uri: G.https()})
      G.upsert!(%{user_id: uid, client_id: second, scope: G.scope("D2", openid: false), redirect_uri: G.https()})
      G.upsert!(%{user_id: other_user, client_id: cid, scope: G.scope(), redirect_uri: G.https()})

      assert {:ok, list} = G.call(:list_for_user, [uid])
      assert list |> Enum.map(& &1.client_id) |> Enum.sort() == Enum.sort([cid, second])
      mine = Enum.find(list, &(&1.client_id == cid))
      assert mine.client_name == "Grant Test App"
      assert mine.scope == G.remembered_scope()
      assert mine.redirect_uri == G.https()
      assert match?(%DateTime{}, mine.granted_at)
      assert {:ok, []} = G.call(:list_for_user, [T.provision_user!()])
    end

    test "does not list a grant of a revoked client or a stale binding", %{uid: uid, cid: cid} do
      second = T.oauth_client!([G.https()])
      third = T.oauth_client!([G.https()])
      for c <- [cid, second, third], do: G.upsert!(%{user_id: uid, client_id: c, scope: G.scope(), redirect_uri: G.https()})

      :ok = T.mark_revoked!(second)
      T.privileged_sql!("UPDATE oauth_consent_grants SET client_approved_at = client_approved_at - interval '1 hour' WHERE client_id = $1", [third])

      assert {:ok, [only]} = G.call(:list_for_user, [uid])
      assert only.client_id == cid
    end

    test "{:error, :storage} when the table cannot be read", %{uid: uid} do
      G.with_table_unreadable(fn -> assert {:error, :storage} = G.call(:list_for_user, [uid]) end)
    end
  end

  describe "withdraw/2" do
    test "deletes exactly the user's grant for that client: {:ok, :withdrawn} once, then {:ok, :not_found}", %{uid: uid, cid: cid} do
      other_user = T.provision_user!()
      second = T.oauth_client!([G.https()])
      on_exit(fn -> G.cleanup_grants([other_user]) end)
      for {u, c} <- [{uid, cid}, {uid, second}, {other_user, cid}], do: G.upsert!(%{user_id: u, client_id: c, scope: G.scope(), redirect_uri: G.https()})

      assert {:ok, :withdrawn} = G.call(:withdraw, [uid, cid])
      assert G.grant_count(uid, cid) == 0
      assert G.grant_count(uid, second) == 1, "the user's grant of another client stays"
      assert G.grant_count(other_user, cid) == 1, "another user's grant of the same client stays"
      assert {:ok, :not_found} = G.call(:withdraw, [uid, cid])
    end

    test "an unknown client id or user id is :not_found, never an error", %{uid: uid} do
      assert {:ok, :not_found} = G.call(:withdraw, [uid, "no-such-client"])
      assert {:ok, :not_found} = G.call(:withdraw, ["@nobody:test.local", "no-such-client"])
    end

    test "{:error, :storage} when the table cannot be written", %{uid: uid, cid: cid} do
      G.with_table_unreadable(fn -> assert {:error, :storage} = G.call(:withdraw, [uid, cid]) end)
    end
  end

  describe "the table is unreachable" do
    test "upsert answers {:error, _} without raising and creates nothing", %{uid: uid, cid: cid} do
      G.with_table_unreadable(fn -> assert {:error, _} = G.upsert(%{user_id: uid, client_id: cid, scope: G.scope(), redirect_uri: G.https()}) end)
      assert G.grant_count(uid) == 0
    end
  end

  defp drain(acc) do
    receive do
      {:q, q} -> drain([q | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
