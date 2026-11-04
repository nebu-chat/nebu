defmodule Nebu.Matrix.DeviceKeyDirectoryClaimOracleTest do
  @moduledoc """
  Acceptance tests (REAL database) of the "no existence oracle" rule of `POST /keys/claim` for story `device-key-directory` (REQ-2026-013, oracle edge case 6, orchestrator decision
  "identical output, status and equal statement counts"), and of the IDOR rules around it:

    * a target that cannot be claimed because it does not exist (unknown user, unknown device, keyless device), because the caller may not reach it (no shared room, an invitation only,
      a remote user, a malformed id) or because it has nothing to give is answered BYTE-IDENTICALLY (status, body, every header but the per-request ones);
    * the request runs the SAME statements for every kind of target (one set based claim, no early return, no statement per target), pinned by counting;
    * no spelling variant of an id (case, wildcard, whitespace) reaches another user's or device's keys;
    * two users with the SAME device id (the id is client chosen with the OAuth `device:` scope) never get each other's keys.
  """
  use ExUnit.Case, async: false

  alias Nebu.Matrix.DeviceKeyDirectoryTestSupport, as: DK
  alias Nebu.Matrix.ToDeviceTestSupport, as: TD
  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration

  setup do
    T.reset_rate_limits()
    Nebu.Test.ServerName.pin!(T.server_name())
    TD.disable_rate_limit()
    on_exit(fn -> T.restore_rate_limits() end)
    w = DK.world!()
    # every target kind, each WITH real one-time and fallback keys where a device exists (so "nothing to give" is never the reason)
    DK.publish!(w.bob1, otks: ["A1"], fallback: "AF")
    DK.publish!(w.dave, otks: ["D1"], fallback: "DF")
    invited = TD.user!("DKI")
    DK.publish!(invited, otks: ["I1"], fallback: "IF")
    TD.invite_only!(w.alice, invited)
    # warm up the provisioning cache of the caller: the statement counts below compare steady state requests
    DK.claim!(w.alice, %{})
    {:ok, w: w, invited: invited}
  end

  # the kinds of target that must be indistinguishable from each other (none of them yields a key)
  defp kinds(w, invited) do
    [
      {"unknown local user", %{"@nobody-#{T.rand(5)}:test.local" => %{"DEV" => "signed_curve25519"}}},
      {"unknown device of a user in a shared room", %{w.bob1.uid => %{"NOSUCHDEVICE" => "signed_curve25519"}}},
      {"keyless device of a user in a shared room", DK.target(w.bob2)},
      {"existing keys of a user without a shared room", DK.target(w.dave)},
      {"existing keys of a user who is only invited", DK.target(invited)},
      {"a remote user", %{"@bob:other.example" => %{"DEV" => "signed_curve25519"}}},
      {"a syntactically invalid user id", %{"not-a-user-id" => %{"DEV" => "signed_curve25519"}}},
      {"an algorithm nobody has", %{w.bob1.uid => %{w.bob1.dev => "no_such_alg"}}}
    ]
  end

  describe "byte-identical answers" do
    test "every kind of unreachable or empty target is answered with the same status, body and headers", %{w: w, invited: invited} do
      shapes = for {label, targets} <- kinds(w, invited), do: {label, TD.shape(DK.claim(w.alice, targets))}
      [{_, first} | rest] = shapes
      assert {200, %{"one_time_keys" => %{}, "failures" => %{}}} = {elem(first, 0), Jason.decode!(elem(first, 1))}

      for {label, shape} <- rest, do: assert(shape == first, "#{label} differs from the first kind: #{inspect(shape)} vs #{inspect(first)}")
    end

    test "the answer for a user without a shared room is identical before and after that user publishes keys (nothing in the answer depends on the target's keys)", %{w: w} do
      ghost = TD.user!("DKG")
      before = TD.shape(DK.claim(w.alice, DK.target(ghost)))
      DK.publish!(ghost, otks: ["G1"], fallback: "GF")
      assert TD.shape(DK.claim(w.alice, DK.target(ghost))) == before
    end

    test "a request with only unreachable targets and one with an empty object differ only in nothing: both are the same 200 shape", %{w: w, invited: invited} do
      assert TD.shape(DK.claim(w.alice, %{})) == TD.shape(DK.claim(w.alice, DK.target(invited)))
    end

    test "the same holds for a request that ALSO contains a served target: the unreachable targets add nothing to the answer", %{w: w, invited: invited} do
      DK.publish!(w.bob1, otks: ["A2"])
      served = DK.claim!(w.alice, DK.target(w.bob1))
      DK.publish!(w.bob1, keys: false, otks: ["A3"])

      mixed =
        DK.claim!(w.alice, Map.merge(DK.target(w.bob1), Map.merge(DK.target(w.dave), Map.merge(DK.target(invited), %{"@x:other.example" => %{"Z" => "signed_curve25519"}}))))

      assert map_size(served["one_time_keys"]) == 1 and map_size(mixed["one_time_keys"]) == 1
      assert Map.keys(mixed["one_time_keys"]) == [w.bob1.uid]
    end
  end

  describe "equal statement counts" do
    defp counts(w, targets) do
      {conn, statements} = DK.all_statements(fn -> DK.claim(w.alice, targets) end)
      assert conn.status == 200
      {length(statements), length(DK.key_statements(statements))}
    end

    test "every kind of target runs exactly the same number of statements (and of key statements)", %{w: w, invited: invited} do
      all = for {label, targets} <- kinds(w, invited), do: {label, counts(w, targets)}
      [{_, first} | rest] = all
      for {label, c} <- rest, do: assert(c == first, "#{label}: #{inspect(c)} statements, the first kind ran #{inspect(first)}")
    end

    test "a target that IS served runs the same statements as one that is not (no early return for a forbidden or empty target)", %{w: w} do
      DK.publish!(w.bob1, otks: ["B1", "B2", "B3"])
      served = counts(w, DK.target(w.bob1))
      refused = counts(w, DK.target(w.dave))
      assert served == refused
      assert elem(served, 1) >= 1, "the claim statement runs even for a request that serves nothing"
    end

    test "the work is set based: 1 target and 40 mixed targets run the same number of statements", %{w: w, invited: invited} do
      one = counts(w, DK.target(w.dave))
      many = for(i <- 1..30, into: %{}, do: {"@gone#{i}-#{T.rand(3)}:test.local", %{"D#{i}" => "signed_curve25519"}}) |> Map.merge(DK.targets([w.bob1, w.bob2, w.dave, invited]))
      assert counts(w, many) == one
    end
  end

  describe "no spelling variant reaches another user's keys" do
    test "the user id is matched exactly: another case, a trailing space or a percent encoded id yields nothing and consumes nothing", %{w: w} do
      uid = w.bob1.uid
      variants = [String.upcase(uid), uid <> " ", " " <> uid, String.replace(uid, "@", "%40"), String.replace(uid, ":", "%3A"), uid <> "\u0000"]

      for v <- variants do
        assert DK.got(DK.claim!(w.alice, %{v => %{w.bob1.dev => "signed_curve25519"}}), v, w.bob1.dev) == nil, "variant #{inspect(v)} must not match"
      end

      assert DK.unclaimed(uid, w.bob1.dev) == 1
    end

    test "the device id is matched exactly: another case and the wildcard `*` yield nothing, the key stays", %{w: w} do
      for d <- [String.downcase(w.bob1.dev), w.bob1.dev <> " ", "*", ""] do
        assert DK.claim!(w.alice, %{w.bob1.uid => %{d => "signed_curve25519"}})["one_time_keys"] == %{}, "device #{inspect(d)}"
      end

      assert DK.unclaimed(w.bob1.uid, w.bob1.dev) == 1
    end

    test "the algorithm is matched exactly: another case and a prefix yield nothing", %{w: w} do
      for a <- ["SIGNED_CURVE25519", "signed_curve", "signed_curve25519:", "signed_curve25519:A1"] do
        assert DK.claim!(w.alice, DK.target(w.bob1, a))["one_time_keys"] == %{}, "algorithm #{inspect(a)}"
      end

      assert DK.unclaimed(w.bob1.uid, w.bob1.dev) == 1
    end
  end

  describe "IDOR: two users with the SAME device id" do
    defp world_same_id! do
      id = "SAME" <> String.upcase(T.rand(3))
      alice = TD.user!("DKA")
      u1 = TD.user_with_device!(id)
      u2 = TD.user_with_device!(id)
      TD.share!(alice, u1)
      DK.publish!(u1, otks: ["U1A", "U1B"], fallback: "U1F")
      DK.publish!(u2, otks: ["U2A", "U2B"], fallback: "U2F")
      %{id: id, alice: alice, u1: u1, u2: u2}
    end

    test "alice shares a room with u1 only: the claim of {u1, id} returns u1's key, the claim of {u2, id} returns nothing and u2's keys are untouched", %{w: _w} do
      x = world_same_id!()
      assert DK.claim_one!(x.alice, x.u1) |> map_size() == 1
      assert DK.claim_one!(x.alice, x.u2) == nil
      assert {DK.unclaimed(x.u1.uid, x.id), DK.unclaimed(x.u2.uid, x.id)} == {1, 2}
      assert DK.fallback_row(x.u2.uid, x.id) == ["U2F", false]
    end

    test "a request naming BOTH users with the same device id serves only the reachable one, the key of u1 never appears under u2", %{w: _w} do
      x = world_same_id!()
      body = DK.claim!(x.alice, %{x.u1.uid => %{x.id => "signed_curve25519"}, x.u2.uid => %{x.id => "signed_curve25519"}})
      assert Map.keys(body["one_time_keys"]) == [x.u1.uid]
      assert body["one_time_keys"][x.u1.uid][x.id] |> Map.keys() |> hd() =~ ~r/U1/
    end

    test "u2 cannot claim u1's keys by naming u1 (no shared room), and u2's own claim of its own id is its own key", %{w: _w} do
      x = world_same_id!()
      assert DK.claim_one!(x.u2, x.u1) == nil
      assert DK.claim_one!(x.u2, x.u2) |> Map.keys() |> hd() =~ ~r/U2/
      assert DK.unclaimed(x.u1.uid, x.id) == 2
    end

    test "the fallback key of u1 is marked used by a claim of u1 only: u2's fallback stays unused (per user AND device)", %{w: _w} do
      x = world_same_id!()
      for _ <- 1..3, do: DK.claim_one!(x.alice, x.u1)
      assert {DK.fallback_row(x.u1.uid, x.id), DK.fallback_row(x.u2.uid, x.id)} == {["U1F", true], ["U2F", false]}
      assert TD.sync(x.u2)["device_unused_fallback_key_types"] == ["signed_curve25519"]
    end
  end
end
