defmodule Nebu.Compliance.UserDeletionDeviceKeyDirectoryTest do
  @moduledoc """
  Acceptance tests (REAL database) of the GDPR erasure part of story `device-key-directory` (epic e2ee-client-support, REQ-2026-013, decision D13), in the framework of story
  `gdpr-erasure-global-data`:

    * `Nebu.Compliance.UserDeletion.erased_tables/0` names `device_list_changes` (the deleting code, the schema recurrence guard, the sweep and the docs inventory are driven by that
      list; `UserDeletionTestSupport.expected_erased/0` carries it and `seed_user!/2` seeds the stream through the REAL writers, so every generic erasure test of `user_deletion_*_test.exs`
      covers it too: one erasure, rollback of a failing step per table, the sweep, the late retry);
    * one erasure deletes EVERY stream row of the user (its key changes and its membership changes of every room), and no row of another user;
    * the claim keeps no state of its own: the keys of an erased user (one-time, fallback, device keys) are gone with the existing tables, a claim for them answers like for any unknown
      device, and the bearer of an erased caller can no longer claim;
    * the peers' reads stay valid: `/keys/changes` and `/sync` of a peer neither fail nor list the erased user for changes that were erased;
    * the runbook sweep (SQL for the cases where the erasure ran before the table existed) names the table.

  `async: false` (real `AuditWriter` seam via `E.setup_env!/0`, committed rows, own connections).
  """
  use ExUnit.Case, async: false

  alias Nebu.Compliance.UserDeletion
  alias Nebu.Compliance.UserDeletionTestSupport, as: E
  alias Nebu.Matrix.DeviceKeyDirectoryTestSupport, as: DK
  alias Nebu.Matrix.ToDeviceTestSupport, as: TD
  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration

  @root Path.expand("../../../..", __DIR__)

  setup do
    Nebu.Test.ServerName.pin!(T.server_name())
    env = E.setup_env!()
    TD.disable_rate_limit()
    {:ok, env}
  end

  defp erase!(uid), do: UserDeletion.delete_user_keys(E.admin(), uid, "atdd erasure")

  # alice and the victim share TWO rooms; the victim has device keys (one device with keys, one-time and fallback keys) and cross-signing keys; carol is an unrelated bystander with rows
  defp world! do
    alice = TD.user!("DKA")
    victim = TD.user!("DKV")
    bystander = TD.user!("DKC")
    room1 = TD.share!(alice, victim)
    room2 = TD.share!(alice, victim)
    TD.share!(alice, bystander)
    DK.publish!(victim, otks: ["V1", "V2"], fallback: "VF")
    DK.publish!(bystander, otks: ["C1"])
    :ok = Nebu.Matrix.CrossSigningKeyStore.put_keys(victim.uid, T.cross_signing_keys(victim.uid, "v"))
    %{alice: alice, victim: victim, bystander: bystander, rooms: [room1, room2]}
  end

  describe "the inventory" do
    test "erased_tables/0 names device_list_changes and the suites' inventory agrees" do
      erased = UserDeletion.erased_tables()
      assert "device_list_changes" in erased
      assert Enum.sort(erased) == Enum.sort(E.expected_erased())
    end

    test "the seed of the generic erasure world writes stream rows through the real writers (the generic tests are not vacuous for this table)", %{cid: cid} do
      w = E.seed_user!(cid, "dkd")
      assert E.count("device_list_changes", w.uid) >= 1
    end
  end

  describe "one erasure deletes the stream rows of the user" do
    test "the key change row and the membership rows of BOTH rooms are gone, the bystander's rows are untouched" do
      w = world!()
      assert DK.stream_rows(w.victim.uid) |> Enum.map(fn [r, k, _] -> {r, k} end) == Enum.sort([{"", "keys"}, {Enum.at(w.rooms, 0), "join"}, {Enum.at(w.rooms, 1), "join"}]), "precondition: the stream has the rows"
      bystander_before = DK.stream_rows(w.bystander.uid)
      assert {:ok, _} = erase!(w.victim.uid)
      assert DK.stream_count(w.victim.uid) == 0
      assert DK.stream_rows(w.bystander.uid) == bystander_before
      assert E.count("device_list_changes", w.victim.uid) == 0
    end

    test "the erased user's keys are gone with it: a claim for its device answers like for an unknown device and consumes nothing for anybody else" do
      w = world!()
      assert DK.claim_one!(w.alice, w.victim) |> map_size() == 1, "precondition: the keys can be claimed"
      assert {:ok, _} = erase!(w.victim.uid)
      assert DK.claim!(w.alice, DK.target(w.victim)) == %{"one_time_keys" => %{}, "failures" => %{}}
      assert {DK.otk_total(w.victim.uid, w.victim.dev), DK.fallback_row(w.victim.uid, w.victim.dev)} == {0, nil}
      assert DK.claim_one!(w.alice, w.bystander) |> map_size() == 1
    end

    test "the bearer of an erased caller claims nothing (refused or an empty answer), and nothing is consumed" do
      w = world!()
      assert {:ok, _} = erase!(w.alice.uid)
      c = DK.claim(w.alice, DK.target(w.bystander))
      assert c.status in [401, 403] or (c.status == 200 and TD.json(c)["one_time_keys"] == %{}), "got #{c.status} #{c.resp_body}"
      assert DK.unclaimed(w.bystander.uid, w.bystander.dev) == 1
    end

    test "a peer's reads keep working after the erasure: /keys/changes answers 200 for an old token and a sync answers 200 with device_lists" do
      w = world!()
      from = DK.token(w.alice)
      assert {:ok, _} = erase!(w.victim.uid)
      body = DK.changes!(w.alice, from, DK.token(w.alice))
      assert w.victim.uid not in body["changed"], "the erased changes are gone from the stream: #{inspect(body)}"
      assert is_map(DK.sync(w.alice, from)["device_lists"])
    end

    test "the erased user cannot re-enter the stream through a late cross-signing upload (the writer refuses an erased user)" do
      w = world!()
      assert {:ok, _} = erase!(w.victim.uid)
      assert {:error, _} = Nebu.Matrix.CrossSigningKeyStore.put_keys(w.victim.uid, T.cross_signing_keys(w.victim.uid, "late"))
      assert DK.stream_rows(w.victim.uid) |> Enum.filter(fn [r, _, _] -> r == "" end) == []
    end

    test "a second erasure of the same user is harmless (idempotent) and leaves the table clean" do
      w = world!()
      assert {:ok, _} = erase!(w.victim.uid)
      _ = erase!(w.victim.uid)
      assert DK.stream_count(w.victim.uid) == 0
    end
  end

  describe "documentation of the erasure" do
    defp read(rel), do: File.read!(Path.join(@root, rel)) |> String.replace(~r/\s+/, " ")

    test "the GDPR runbook sweep names device_list_changes" do
      text = read("docs/compliance/gdpr-deletion-runbook.md")
      assert text =~ "device_list_changes"
      assert text =~ ~r/DELETE\s+FROM\s+device_list_changes\s+WHERE\s+user_id\s+IN/i
    end

    test "07-deployment lists device_list_changes among the tables of the erasure sweep" do
      assert read("docs/architecture/07-deployment.md") =~ "device_list_changes"
    end
  end
end
