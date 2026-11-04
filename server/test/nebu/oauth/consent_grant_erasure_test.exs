defmodule Nebu.OAuth.ConsentGrantErasureTest do
  @moduledoc """
  Story `persistent-consent-grants` (REQ-2026-003), scenario 8: "GDPR erasure removes the user's consent grants". Real database, `--include integration`.

  A grant is personal data of the user (who allowed which app, with which scope, when): `oauth_consent_grants` is added to
  `Nebu.Compliance.UserDeletion.erased_tables/0`, so the erasure transaction deletes it (`WHERE user_id = $1`), a failing delete rolls the whole
  erasure back (step `delete_oauth_consent_grants`), and the schema recurrence guard / the sweep / the docs inventory follow from the list. The
  generic suites (`user_deletion_*_test.exs`, seed in `UserDeletionTestSupport.seed_user!/2`) are extended for the new table; this file pins the
  story's scenario end to end with a grant that was created by the REAL flow, and what must NOT happen.
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  alias Nebu.Compliance.UserDeletion
  alias Nebu.Compliance.UserDeletionTestSupport, as: E
  alias Nebu.OAuth.ConsentGrantTestSupport, as: G
  alias Nebu.OAuth.TestSupport, as: T

  setup do
    {:ok, E.setup_env!()}
  end

  defp erase!(uid), do: UserDeletion.delete_user_keys(E.admin(), uid, "atdd erasure")

  test "the table is part of the erasure inventory", %{} do
    assert "oauth_consent_grants" in UserDeletion.erased_tables()
    assert "oauth_consent_grants" in E.expected_erased()
  end

  test "scenario 8: alice allowed the app (real flow); alice is erased; no consent grant of alice remains, bob's grant is identical", %{cid: cid, priv: priv} do
    alice_sub = T.unique_sub()
    bob_sub = T.unique_sub()
    alice = T.user_id_for(%{"sub" => alice_sub})
    bob = T.user_id_for(%{"sub" => bob_sub})
    on_exit(fn -> G.cleanup_grants([alice, bob]) end)

    G.allow_new!(cid, priv, alice_sub)
    G.allow_new!(cid, priv, bob_sub)
    assert G.grant_count(alice) == 1
    bob_before = E.fp("oauth_consent_grants", bob)

    assert {:ok, %{keys_deleted_at: at}} = erase!(alice)
    assert is_integer(at)

    assert G.grant_count(alice) == 0, "no consent grant for alice remains"
    assert E.fp("oauth_consent_grants", bob) == bob_before, "bob's grant is byte-identical"
    assert G.grant_count(bob) == 1
  end

  test "a failing delete of the grants rolls the whole erasure back and names the step; a retry succeeds", %{cid: cid} do
    a = E.seed_user!(cid, "a")
    assert E.count("oauth_consent_grants", a.uid) == 1, "precondition: the seeded world has a grant"
    before = E.snapshot(a.uid, E.expected_erased() ++ ~w(users profiles user_keys room_members))
    remove = E.block!("oauth_consent_grants", "DELETE", a.uid)

    assert {:error, {:db_error, :raise_exception}} = erase!(a.uid)

    assert E.count("oauth_consent_grants", a.uid) == 1
    assert E.snapshot(a.uid, E.expected_erased() ++ ~w(users profiles user_keys room_members)) == before, "nothing changed"
    assert [[_actor, "attempted", _metadata, "step=delete_oauth_consent_grants"]] = E.audit_rows(a.uid, "user_keys_deletion_attempted")

    remove.()
    assert {:ok, _} = erase!(a.uid)
    assert E.count("oauth_consent_grants", a.uid) == 0
  end

  test "the grant row of the erased user cannot come back: a new Allow of an erased user is refused (terminal erasure) and stores nothing", %{cid: cid, priv: priv} do
    sub = T.unique_sub()
    uid = T.user_id_for(%{"sub" => sub})
    on_exit(fn -> G.cleanup_grants([uid]) end)
    G.allow_new!(cid, priv, sub)
    assert {:ok, _} = erase!(uid)

    login = G.login(cid, priv, sub)
    assert {:other, cb} = login.outcome, "an erased user gets neither a consent screen nor a code: #{G.describe(cb_of(login))}"
    {_base, _mode, params, _} = T.client_redirect(cb)
    assert params["error"] == "access_denied"
    refute Map.has_key?(params, "code")
    assert G.grant_count(uid) == 0
  end

  defp cb_of(login), do: login.cb
end
