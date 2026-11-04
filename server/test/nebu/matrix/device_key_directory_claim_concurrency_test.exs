defmodule Nebu.Matrix.DeviceKeyDirectoryClaimConcurrencyTest do
  @moduledoc """
  Acceptance tests (REAL database, real concurrent connections) of the EXACTLY-ONCE rule of `POST /keys/claim` for story `device-key-directory` (REQ-2026-013): Gherkin scenario 1
  ("two different users with a shared room claim at the same time"), oracle edge case 1, and the "no waiting locks" rule of the sibling stories:

    * of N parallel claimers of the last one-time key exactly one gets it, the others get the fallback key or are left out, the count is 0; N claimers of M keys hand out M DISTINCT keys;
    * a fallback key is not consumed under concurrency either: every claimer of a fallback only device gets the identical key;
    * a one-time key row another transaction holds (`FOR UPDATE`, a device delete in flight) is SKIPPED, never waited for: the claim answers at once (a plain SELECT followed by an UPDATE would
      hand a key out twice, a waiting claim would hold a pooled connection).
  """
  use ExUnit.Case, async: false

  alias Nebu.Matrix.DeviceKeyDirectoryTestSupport, as: DK
  alias Nebu.Matrix.ModerationTestSupport, as: S
  alias Nebu.Matrix.ToDeviceTestSupport, as: TD
  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration

  setup do
    T.reset_rate_limits()
    Nebu.Test.ServerName.pin!(T.server_name())
    TD.disable_rate_limit()
    on_exit(fn -> T.restore_rate_limits() end)
    :ok
  end

  # bob (one device) and `n` claimers, every one of them sharing a room with bob
  defp crowd!(n) do
    bob = TD.user!("DKB")
    claimers = for _ <- 1..n, do: DK.peer!(bob, "DKC")
    {bob, claimers}
  end

  defp key_ids(answers), do: answers |> Enum.map(&DK.ids/1) |> Enum.reject(&is_nil/1) |> List.flatten()

  describe "Scenario 1 - two claimers of the last key" do
    test "alice and carol claim at the same time: exactly one gets signed_curve25519:AAAA, the other nothing, the device has zero keys left" do
      {bob, [alice, carol]} = crowd!(2)
      pub = DK.publish!(bob, otks: ["AAAA"])
      [a, b] = S.race([fn -> DK.claim_one!(alice, bob) end, fn -> DK.claim_one!(carol, bob) end])
      assert Enum.sort_by([a, b], &is_nil/1) |> Enum.map(&(&1 && Map.keys(&1))) == [["signed_curve25519:AAAA"], nil]
      assert Enum.find([a, b], & &1) == %{"signed_curve25519:AAAA" => pub.otks["signed_curve25519:AAAA"]}
      assert DK.unclaimed(bob.uid, bob.dev) == 0
    end

    test "20 rounds of two claimers for ONE key: never both, never neither" do
      {bob, [alice, carol]} = crowd!(2)

      for round <- 1..20 do
        DK.publish!(bob, keys: false, otks: ["R#{round}"])
        got = S.race([fn -> DK.claim_one!(alice, bob) end, fn -> DK.claim_one!(carol, bob) end]) |> Enum.reject(&is_nil/1)
        assert length(got) == 1, "round #{round}: #{inspect(got)}"
        assert DK.unclaimed(bob.uid, bob.dev) == 0
      end
    end

    test "a claim and the SAME caller's second claim at once (two requests of one account) also hand the key out once" do
      {bob, [alice]} = crowd!(1)
      DK.publish!(bob, otks: ["AAAA"])
      got = S.race([fn -> DK.claim_one!(alice, bob) end, fn -> DK.claim_one!(alice, bob) end]) |> Enum.reject(&is_nil/1)
      assert length(got) == 1
    end
  end

  describe "N claimers, M keys" do
    test "20 claimers of 10 keys with a fallback key: exactly the 10 keys are handed out, each once, everybody else gets the fallback key" do
      {bob, claimers} = crowd!(20)
      pub = DK.publish!(bob, otks: for(i <- 1..10, do: "K#{i}"), fallback: "FFFF")
      answers = S.race(for c <- claimers, do: fn -> DK.claim_one!(c, bob) end)
      ids = key_ids(answers)
      {fallbacks, otks} = Enum.split_with(ids, &(&1 == "signed_curve25519:FFFF"))
      assert length(answers) == 20 and length(ids) == 20, "every claimer got something"
      assert Enum.sort(otks) == Enum.sort(Map.keys(pub.otks)), "the ten keys, each exactly once: #{inspect(otks)}"
      assert length(fallbacks) == 10
      assert DK.unclaimed(bob.uid, bob.dev) == 0
    end

    test "20 claimers of 10 keys without a fallback key: ten keys handed out once each, ten claimers left out" do
      {bob, claimers} = crowd!(20)
      pub = DK.publish!(bob, otks: for(i <- 1..10, do: "K#{i}"))
      answers = S.race(for c <- claimers, do: fn -> DK.claim_one!(c, bob) end)
      assert Enum.sort(key_ids(answers)) == Enum.sort(Map.keys(pub.otks))
      assert Enum.count(answers, &is_nil/1) == 10
    end

    test "6 claimers of 6 keys: six distinct keys, each exactly once" do
      {bob, claimers} = crowd!(6)
      pub = DK.publish!(bob, otks: for(i <- 1..6, do: "K#{i}"))
      answers = S.race(for c <- claimers, do: fn -> DK.claim_one!(c, bob) end)
      assert Enum.sort(key_ids(answers)) == Enum.sort(Map.keys(pub.otks))
    end

    test "claimers of different devices of one user never take each other's keys (each device keeps exactly its own)" do
      {bob, claimers} = crowd!(8)
      bob2 = TD.device!(bob, "DKX")
      p1 = DK.publish!(bob, otks: for(i <- 1..4, do: "A#{i}"))
      p2 = DK.publish!(bob2, otks: for(i <- 1..4, do: "B#{i}"))

      answers = S.race(for {c, i} <- Enum.with_index(claimers), do: fn -> {if(rem(i, 2) == 0, do: :one, else: :two), DK.claim_one!(c, if(rem(i, 2) == 0, do: bob, else: bob2))} end)
      one = for {:one, a} <- answers, do: a
      two = for {:two, a} <- answers, do: a
      assert Enum.sort(key_ids(one)) == Enum.sort(Map.keys(p1.otks))
      assert Enum.sort(key_ids(two)) == Enum.sort(Map.keys(p2.otks))
    end
  end

  describe "the fallback key is not consumed under concurrency" do
    test "20 claimers of a device with only a fallback key all get the identical key, and it is marked used" do
      {bob, claimers} = crowd!(20)
      DK.publish!(bob, fallback: "FFFF")
      answers = S.race(for c <- claimers, do: fn -> DK.claim_one!(c, bob) end)
      assert answers |> Enum.map(&DK.ids/1) |> Enum.uniq() == [["signed_curve25519:FFFF"]]
      assert DK.fallback_row(bob.uid, bob.dev) == ["FFFF", true]
    end
  end

  describe "no waiting locks: a row another transaction holds is skipped" do
    defp otk_lock!(uid, dev, key_id) do
      DK.hold(fn -> T.sql!("SELECT key_id FROM device_one_time_keys WHERE user_id = $1 AND device_id = $2 AND key_id = $3 FOR UPDATE", [uid, dev, key_id]) end)
    end

    defp timed(fun) do
      started = System.monotonic_time(:millisecond)
      result = fun.()
      {result, System.monotonic_time(:millisecond) - started}
    end

    test "with K1 locked by another transaction a claim takes K2 at once, the next claim finds nothing at once, after the release K1 is claimable" do
      {bob, [alice]} = crowd!(1)
      DK.publish!(bob, otks: ["K1"])
      Process.sleep(8)
      DK.publish!(bob, keys: false, otks: ["K2"])
      held = otk_lock!(bob.uid, bob.dev, "K1")

      {first, ms1} = timed(fn -> DK.claim_one!(alice, bob) end)
      {second, ms2} = timed(fn -> DK.claim_one!(alice, bob) end)
      assert DK.ids(first) == ["signed_curve25519:K2"] and second == nil
      assert ms1 < 1_500 and ms2 < 1_500, "the claims did not wait for the lock (#{ms1} ms, #{ms2} ms)"

      DK.finish(held, :rollback)
      assert DK.claim_one!(alice, bob) |> DK.ids() == ["signed_curve25519:K1"]
    end

    test "a device delete in flight (its rows deleted, not committed) does not block a claim: the locked key is skipped, the claim answers at once" do
      {bob, [alice]} = crowd!(1)
      DK.publish!(bob, otks: ["K1"], fallback: "FFFF")
      held = DK.hold(fn -> Nebu.Matrix.DeviceKeyStore.delete_device!(bob.uid, bob.dev) end)
      {answer, ms} = timed(fn -> DK.claim!(alice, DK.target(bob)) end)
      assert ms < 1_500, "the claim waited #{ms} ms for the delete"
      assert Map.get(answer["one_time_keys"], bob.uid) in [nil, %{bob.dev => %{"signed_curve25519:FFFF" => DK.fallback_obj("FFFF")}}], "a locked key is never handed out: #{inspect(answer)}"
      DK.finish(held, :rollback)
      assert DK.claim_one!(alice, bob) |> DK.ids() == ["signed_curve25519:K1"], "the rolled back delete left the key claimable"
    end

    test "a claim that races a COMMITTED device delete hands out nothing afterwards and leaves no row behind" do
      {bob, [alice]} = crowd!(1)
      DK.publish!(bob, otks: ["K1", "K2"], fallback: "FFFF")
      held = DK.hold(fn -> Nebu.Matrix.DeviceKeyStore.delete_device!(bob.uid, bob.dev) end)
      DK.finish(held, :commit)
      assert DK.claim!(alice, DK.target(bob))["one_time_keys"] == %{}
      assert {DK.otk_total(bob.uid, bob.dev), DK.fallback_row(bob.uid, bob.dev)} == {0, nil}
    end

    test "a fallback row held by a transaction that REPLACES it (a new upload in flight) does not block the claim: the claim answers at once" do
      {bob, [alice]} = crowd!(1)
      DK.publish!(bob, fallback: "FFFF")
      held = DK.hold(fn -> T.sql!("SELECT 1 FROM device_fallback_keys WHERE user_id = $1 AND device_id = $2 FOR UPDATE", [bob.uid, bob.dev]) end)
      {answer, ms} = timed(fn -> DK.claim_one!(alice, bob) end)
      assert ms < 1_500, "the claim waited #{ms} ms for the held fallback row"
      assert DK.ids(answer) == ["signed_curve25519:FFFF"]
      DK.finish(held, :rollback)
    end
  end
end
