defmodule Nebu.Matrix.DeviceKeyDirectoryClaimHttpTest do
  @moduledoc """
  Acceptance tests (REAL database, full `Nebu.Web.Router`) of `POST /_matrix/client/v3/keys/claim` for story `device-key-directory` (epic e2ee-client-support, REQ-2026-013),
  Matrix CS v1.18 `#post_matrixclientv3keysclaim`. Gherkin scenarios 1 (sequential part; the concurrent part is `device_key_directory_claim_concurrency_test.exs`), 2 and 3;
  oracle edge cases 2 (upload order), 3 (fallback twice), 4 (a new fallback), 5, 7, 8, 9; the restriction (own devices, both sides `join`, evaluated at request time).

  The answer is `{"one_time_keys": ..., "failures": {}}`; every target that yields nothing is LEFT OUT (never a `failures` entry, never an empty user object).
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
    {:ok, w: DK.world!()}
  end

  defp types(device), do: TD.sync(device)["device_unused_fallback_key_types"]

  describe "Scenario 1 - a one-time key is handed out at most once (sequential)" do
    test "the only key goes to the first claim, the second finds the device empty, the device has zero one-time keys left", %{w: w} do
      pub = DK.publish!(w.bob1, otks: ["AAAA"])
      assert DK.claim_one!(w.alice, w.bob1) == %{"signed_curve25519:AAAA" => pub.otks["signed_curve25519:AAAA"]}
      assert DK.got(DK.claim!(w.alice, DK.target(w.bob1)), w.bob1) == nil, "no fallback key: the device is left out"
      assert {DK.unclaimed(w.bob1.uid, w.bob1.dev), TD.sync(w.bob1)["device_one_time_keys_count"]} == {0, %{"signed_curve25519" => 0}}
    end

    test "a second user with a shared room does not receive the key the first one took", %{w: w} do
      DK.publish!(w.bob1, otks: ["AAAA"])
      assert DK.claim_one!(w.alice, w.bob1) |> DK.ids() == ["signed_curve25519:AAAA"]
      assert DK.claim_one!(w.carol, w.bob1) == nil
    end

    test "three keys are handed out as three distinct keys, the fourth claim finds nothing", %{w: w} do
      DK.publish!(w.bob1, otks: ["K1", "K2", "K3"])
      got = for _ <- 1..4, do: DK.claim_one!(w.alice, w.bob1)
      handed = got |> Enum.reject(&is_nil/1) |> Enum.flat_map(&Map.keys/1)
      assert Enum.sort(handed) == ["signed_curve25519:K1", "signed_curve25519:K2", "signed_curve25519:K3"]
      assert List.last(got) == nil
      assert DK.unclaimed(w.bob1.uid, w.bob1.dev) == 0
    end

    test "only the claimed device loses a key: another device of the same user keeps its keys", %{w: w} do
      DK.publish!(w.bob1, otks: ["A1", "A2"])
      DK.publish!(w.bob2, otks: ["B1", "B2"])
      assert DK.claim_one!(w.alice, w.bob1) != nil
      assert {DK.unclaimed(w.bob1.uid, w.bob1.dev), DK.unclaimed(w.bob2.uid, w.bob2.dev)} == {1, 2}
    end

    test "a claimed key is never handed out again, not even when the client uploads the same key id again", %{w: w} do
      pub = DK.publish!(w.bob1, otks: ["AAAA"])
      assert DK.claim_one!(w.alice, w.bob1) != nil
      DK.upload!(w.bob1, %{"one_time_keys" => pub.otks})
      assert DK.claim_one!(w.alice, w.bob1) == nil
      assert DK.unclaimed(w.bob1.uid, w.bob1.dev) == 0
    end

    test "one request claims several devices of several users at once, each key exactly once", %{w: w} do
      DK.publish!(w.bob1, otks: ["A1"])
      DK.publish!(w.bob2, otks: ["B1"])
      DK.publish!(w.carol, otks: ["C1"])
      body = DK.claim!(w.alice, DK.targets([w.bob1, w.bob2]))
      assert DK.ids(DK.got(body, w.bob1)) == ["signed_curve25519:A1"] and DK.ids(DK.got(body, w.bob2)) == ["signed_curve25519:B1"]
      assert DK.unclaimed(w.bob1.uid, w.bob1.dev) + DK.unclaimed(w.bob2.uid, w.bob2.dev) == 0
      assert DK.unclaimed(w.carol.uid, w.carol.dev) == 1, "carol was not claimed"
    end
  end

  describe "Scenario 2 - the fallback key (not consumed, marked used)" do
    test "no one-time key left: the fallback key is returned under its own id, verbatim, and a second claim returns it again", %{w: w} do
      pub = DK.publish!(w.bob1, fallback: "FFFF")
      {fid, fobj} = pub.fallback
      assert fid == "signed_curve25519:FFFF"
      assert DK.claim_one!(w.alice, w.bob1) == %{fid => fobj}
      assert DK.claim_one!(w.alice, w.bob1) == %{fid => fobj}
    end

    test "the fallback key object keeps `fallback: true`, the key and the signatures exactly as uploaded", %{w: w} do
      pub = DK.publish!(w.bob1, fallback: "FFFF")
      [{_id, obj}] = DK.claim_one!(w.alice, w.bob1) |> Map.to_list()
      assert obj == elem(pub.fallback, 1)
      assert obj["fallback"] == true and obj["key"] == "fbk-FFFF" and is_map(obj["signatures"])
    end

    test "the claim marks the fallback key used: its algorithm leaves the unused types of THAT device, the key stays stored", %{w: w} do
      DK.publish!(w.bob1, fallback: "FFFF")
      DK.publish!(w.bob2, fallback: "GGGG")
      assert {types(w.bob1), types(w.bob2)} == {["signed_curve25519"], ["signed_curve25519"]}
      DK.claim_one!(w.alice, w.bob1)
      assert {types(w.bob1), types(w.bob2)} == {[], ["signed_curve25519"]}
      assert DK.fallback_row(w.bob1.uid, w.bob1.dev) == ["FFFF", true], "marked used, not deleted"
    end

    test "a one-time key is preferred over the fallback key and leaves the fallback unused", %{w: w} do
      DK.publish!(w.bob1, otks: ["AAAA"], fallback: "FFFF")
      assert DK.claim_one!(w.alice, w.bob1) |> DK.ids() == ["signed_curve25519:AAAA"]
      assert types(w.bob1) == ["signed_curve25519"], "no fallback was handed out"
      assert DK.claim_one!(w.alice, w.bob1) |> DK.ids() == ["signed_curve25519:FFFF"]
      assert types(w.bob1) == []
    end

    test "a NEW fallback key replaces it, puts the algorithm back into the unused list and the next claim returns the new key", %{w: w} do
      DK.publish!(w.bob1, fallback: "FFFF")
      DK.claim_one!(w.alice, w.bob1)
      assert types(w.bob1) == []
      pub = DK.publish!(w.bob1, keys: false, fallback: "NEW1")
      assert types(w.bob1) == ["signed_curve25519"]
      assert DK.claim_one!(w.alice, w.bob1) == %{"signed_curve25519:NEW1" => elem(pub.fallback, 1)}
    end

    test "one-time keys uploaded after the fallback was used are handed out again before the fallback", %{w: w} do
      DK.publish!(w.bob1, fallback: "FFFF")
      DK.claim_one!(w.alice, w.bob1)
      DK.publish!(w.bob1, keys: false, otks: ["LATE"])
      assert DK.claim_one!(w.alice, w.bob1) |> DK.ids() == ["signed_curve25519:LATE"]
      assert DK.claim_one!(w.alice, w.bob1) |> DK.ids() == ["signed_curve25519:FFFF"]
    end

    test "only the REQUESTED algorithm is answered: another algorithm gets neither the one-time nor the fallback key", %{w: w} do
      DK.publish!(w.bob1, otks: ["AAAA"], fallback: "FFFF")
      assert DK.claim_one!(w.alice, w.bob1, "other_alg") == nil
      assert {DK.unclaimed(w.bob1.uid, w.bob1.dev), types(w.bob1)} == {1, ["signed_curve25519"]}, "nothing was consumed or marked"
    end

    test "the server is algorithm agnostic: a one-time key of any algorithm is claimed by the same string", %{w: w} do
      DK.upload!(w.bob1, %{"one_time_keys" => %{"curve25519:ZZ" => "plain-key-string", "ed_test:Q1" => %{"key" => "q1"}}})
      assert DK.claim_one!(w.alice, w.bob1, "ed_test") == %{"ed_test:Q1" => %{"key" => "q1"}}
      assert DK.claim_one!(w.alice, w.bob1, "curve25519") == %{"curve25519:ZZ" => "plain-key-string"}
    end

    test "a fallback row stored before migration 000060 (no key id) is returned as <algorithm>:fallback", %{w: w} do
      T.sql!(
        "INSERT INTO device_fallback_keys (user_id, device_id, algorithm, key_json, used, created_at) VALUES ($1, $2, 'signed_curve25519', $3, false, 1)",
        [w.bob1.uid, w.bob1.dev, Jason.encode!(DK.fallback_obj("OLD"))]
      )

      T.sql!("UPDATE device_fallback_keys SET key_id = NULL WHERE user_id = $1 AND device_id = $2", [w.bob1.uid, w.bob1.dev])
      assert DK.claim_one!(w.alice, w.bob1) == %{"signed_curve25519:fallback" => DK.fallback_obj("OLD")}
    end
  end

  describe "oracle edge case 2 - one-time keys go out in upload order" do
    test "keys of two upload calls are claimed oldest first (the key ids sort the other way round)", %{w: w} do
      first = DK.publish!(w.bob1, otks: ["Z1", "Z2"])
      Process.sleep(8)
      second = DK.publish!(w.bob1, keys: false, otks: ["A1", "A2"])
      early = MapSet.new(Map.keys(first.otks))
      late = MapSet.new(Map.keys(second.otks))
      claimed = for _ <- 1..4, do: DK.claim_one!(w.alice, w.bob1) |> Map.keys() |> hd()
      assert MapSet.new(Enum.take(claimed, 2)) == early, "both keys of the first upload come first: #{inspect(claimed)}"
      assert MapSet.new(Enum.drop(claimed, 2)) == late
    end

    test "three uploads are consumed in the order of the uploads, one key each", %{w: w} do
      for id <- ["C3", "B2", "A1"] do
        DK.publish!(w.bob1, keys: false, otks: [id])
        Process.sleep(8)
      end

      assert for(_ <- 1..3, do: DK.claim_one!(w.alice, w.bob1) |> Map.keys() |> hd()) == ["signed_curve25519:C3", "signed_curve25519:B2", "signed_curve25519:A1"]
    end
  end

  describe "the key objects are returned verbatim" do
    test "a one-time key comes back equal to the uploaded one: unknown members and nested signatures, nothing added or removed", %{w: w} do
      obj = %{"key" => "k-verbatim", "signatures" => %{"@x:test.local" => %{"ed25519:D" => "s1", "ed25519:E" => "s2"}}, "extra_member" => %{"deep" => [1, 2, %{"x" => nil}]}, "unicode" => "ä☃"}
      DK.upload!(w.bob1, %{"one_time_keys" => %{"signed_curve25519:VERB" => obj}})
      assert DK.claim_one!(w.alice, w.bob1) == %{"signed_curve25519:VERB" => obj}
    end

    test "the server adds no `fallback` member to a one-time key, nor to a fallback key that was uploaded without one", %{w: w} do
      DK.upload!(w.bob1, %{"one_time_keys" => %{"signed_curve25519:PLAIN" => %{"key" => "p", "signatures" => %{}}}, "fallback_keys" => %{"signed_curve25519:NOFB" => %{"key" => "f", "signatures" => %{}}}})
      assert DK.claim_one!(w.alice, w.bob1) == %{"signed_curve25519:PLAIN" => %{"key" => "p", "signatures" => %{}}}
      assert DK.claim_one!(w.alice, w.bob1) == %{"signed_curve25519:NOFB" => %{"key" => "f", "signatures" => %{}}}
    end
  end

  describe "Scenario 3 - a target that yields nothing is LEFT OUT (failures stays empty)" do
    test "an unknown user and an unknown device of a shared user: no key, no entry for either, failures is {}", %{w: w} do
      body = DK.claim!(w.alice, %{w.bob1.uid => %{"GHOSTDEV" => "signed_curve25519"}, "@nobody-#{T.rand(4)}:test.local" => %{"X" => "signed_curve25519"}})
      assert body == %{"one_time_keys" => %{}, "failures" => %{}}
    end

    test "a user without a shared room (dave, GHOSTDEV) is left out, `failures` does not report the target", %{w: w} do
      body = DK.claim!(w.alice, %{w.dave.uid => %{"GHOSTDEV" => "signed_curve25519"}})
      assert body == %{"one_time_keys" => %{}, "failures" => %{}}
    end

    test "a remote user (another server name) is left out, failures stays empty (spec: keyed by server name, no federation)", %{w: w} do
      assert DK.claim!(w.alice, %{"@ghost:other.example" => %{"DEV" => "signed_curve25519"}}) == %{"one_time_keys" => %{}, "failures" => %{}}
    end

    test "a keyless device (a devices row without keys) is left out", %{w: w} do
      assert DK.got(DK.claim!(w.alice, DK.target(w.bob2)), w.bob2) == nil
    end

    test "a device with identity keys but no one-time and no fallback key is left out", %{w: w} do
      DK.publish!(w.bob1)
      assert DK.claim!(w.alice, DK.target(w.bob1))["one_time_keys"] == %{}
    end

    test "a user whose devices all yield nothing is absent: never an empty user object", %{w: w} do
      DK.publish!(w.carol, otks: ["C1"])
      body = DK.claim!(w.alice, DK.targets([w.bob1, w.bob2]))
      refute Map.has_key?(body["one_time_keys"], w.bob1.uid)
    end

    test "in a mixed request exactly the devices that yield a key are present", %{w: w} do
      DK.publish!(w.bob1, otks: ["A1"])
      DK.publish!(w.bob2)
      body = DK.claim!(w.alice, Map.merge(DK.targets([w.bob1, w.bob2]), %{w.dave.uid => %{"X" => "signed_curve25519"}, w.carol.uid => %{"Y" => "signed_curve25519"}}))
      assert Map.keys(body["one_time_keys"]) == [w.bob1.uid]
      assert Map.keys(body["one_time_keys"][w.bob1.uid]) == [w.bob1.dev]
    end

    test "invalid ids (no @, no colon, over 255 bytes, NUL) are left out silently, never an error", %{w: w} do
      body = DK.claim!(w.alice, %{"nonsense" => %{"D" => "signed_curve25519"}, "@nocolon" => %{"D" => "signed_curve25519"}, w.bob1.uid => %{String.duplicate("d", 300) => "signed_curve25519", "A\u0000B" => "signed_curve25519"}})
      assert body["one_time_keys"] == %{}
    end

    test "an empty one_time_keys object is a 200 with an empty answer", %{w: w} do
      assert DK.claim!(w.alice, %{}) == %{"one_time_keys" => %{}, "failures" => %{}}
    end

    test "the `timeout` member is accepted and ignored: integer, string, null, float: no error, no delay", %{w: w} do
      DK.publish!(w.bob1, otks: ["A1", "A2", "A3", "A4"])

      for timeout <- [10_000, "soon", nil, 1.5] do
        started = System.monotonic_time(:millisecond)
        assert DK.claim!(w.alice, DK.target(w.bob1), %{"timeout" => timeout})["one_time_keys"] |> map_size() == 1
        assert System.monotonic_time(:millisecond) - started < 3_000
      end
    end

    test "unknown members of the request body are ignored", %{w: w} do
      DK.publish!(w.bob1, otks: ["A1"])
      assert DK.claim!(w.alice, DK.target(w.bob1), %{"whatever" => [1, 2], "timeout" => 1})["one_time_keys"] |> map_size() == 1
    end
  end

  describe "the restriction: own devices, and users sharing a room where BOTH sides are join" do
    test "the caller's own other device can be claimed without any shared room", %{w: _w} do
      lone = TD.user!("DKL")
      second = TD.device!(lone, "DKM")
      DK.publish!(second, otks: ["S1"])
      assert DK.claim_one!(lone, second) |> DK.ids() == ["signed_curve25519:S1"]
    end

    test "a user in a shared room (both joined) can be claimed", %{w: w} do
      DK.publish!(w.bob1, otks: ["A1"])
      assert DK.claim_one!(w.alice, w.bob1) |> DK.ids() == ["signed_curve25519:A1"]
    end

    test "NEGATIVE: a user the caller shares no room with is left out and its key is NOT consumed", %{w: w} do
      DK.publish!(w.dave, otks: ["D1"], fallback: "DF")
      assert DK.claim_one!(w.alice, w.dave) == nil
      assert {DK.unclaimed(w.dave.uid, w.dave.dev), types(w.dave)} == {1, ["signed_curve25519"]}, "neither consumed nor marked used"
    end

    test "NEGATIVE: sharing a room only through a third user is no path (carol shares with bob, not alice)", %{w: w} do
      DK.publish!(w.carol, otks: ["C1"])
      assert DK.claim_one!(w.alice, w.carol) == nil
      assert DK.unclaimed(w.carol.uid, w.carol.dev) == 1
    end

    test "NEGATIVE: an invitation of the TARGET opens no path (the caller owns the room, the target is only invited)", %{w: w} do
      DK.publish!(w.dave, otks: ["D1"])
      TD.invite_only!(w.alice, w.dave)
      assert DK.claim_one!(w.alice, w.dave) == nil
      assert DK.unclaimed(w.dave.uid, w.dave.dev) == 1
    end

    test "NEGATIVE: an invitation of the CALLER opens no path (the target owns the room, the caller is only invited)", %{w: w} do
      DK.publish!(w.dave, otks: ["D1"])
      TD.invite_only!(w.dave, w.alice)
      assert DK.claim_one!(w.alice, w.dave) == nil
      assert DK.unclaimed(w.dave.uid, w.dave.dev) == 1
    end

    test "joining the invited room opens the path at once (evaluated now, not cached)", %{w: w} do
      DK.publish!(w.dave, otks: ["D1"])
      room = TD.invite_only!(w.alice, w.dave)
      assert DK.claim_one!(w.alice, w.dave) == nil
      S.join!(w.dave, room)
      assert DK.claim_one!(w.alice, w.dave) |> DK.ids() == ["signed_curve25519:D1"]
    end

    test "leaving the only shared room closes the path at once, keys stay unconsumed, rejoining reopens it", %{w: w} do
      DK.publish!(w.dave, otks: ["D1", "D2"])
      room = TD.share!(w.alice, w.dave)
      assert DK.claim_one!(w.alice, w.dave) |> map_size() == 1
      S.leave!(w.dave, room)
      assert DK.claim_one!(w.alice, w.dave) == nil
      assert DK.unclaimed(w.dave.uid, w.dave.dev) == 1
      S.invite!(w.alice, room, w.dave)
      assert DK.claim_one!(w.alice, w.dave) == nil, "an invitation again opens no path"
      S.join!(w.dave, room)
      assert DK.claim_one!(w.alice, w.dave) |> map_size() == 1
    end

    test "one remaining shared room is enough after leaving another", %{w: w} do
      DK.publish!(w.dave, otks: ["D1"])
      room1 = TD.share!(w.alice, w.dave)
      TD.share!(w.alice, w.dave)
      S.leave!(w.dave, room1)
      assert DK.claim_one!(w.alice, w.dave) |> DK.ids() == ["signed_curve25519:D1"]
    end

    test "the caller leaving the shared room closes the path as well", %{w: w} do
      DK.publish!(w.bob1, otks: ["A1"])
      [[room]] = T.sql!("SELECT room_id FROM room_members WHERE user_id = $1 AND room_id IN (SELECT room_id FROM room_members WHERE user_id = $2)", [w.alice.uid, w.bob1.uid]).rows
      S.leave!(w.alice, room)
      assert DK.claim_one!(w.alice, w.bob1) == nil
    end

    test "a request mixing an allowed and a forbidden target serves only the allowed one, consumes only its key", %{w: w} do
      DK.publish!(w.bob1, otks: ["A1"])
      DK.publish!(w.dave, otks: ["D1"])
      body = DK.claim!(w.alice, DK.targets([w.bob1, w.dave]))
      assert Map.keys(body["one_time_keys"]) == [w.bob1.uid]
      assert {DK.unclaimed(w.bob1.uid, w.bob1.dev), DK.unclaimed(w.dave.uid, w.dave.dev)} == {0, 1}
    end
  end

  describe "the status of both sides" do
    test "NEGATIVE: a deactivated or erased TARGET user is left out like an unknown one and its keys are not consumed", %{w: w} do
      DK.publish!(w.bob1, otks: ["A1"], fallback: "FFFF")

      for status <- [["is_active = false", nil], ["deletion_status = 'keys_deleted'", nil]] do
        T.sql!("UPDATE users SET is_active = true, deletion_status = NULL WHERE user_id = $1", [w.bob1.uid])
        T.sql!("UPDATE users SET #{hd(status)} WHERE user_id = $1", [w.bob1.uid])
        assert DK.claim!(w.alice, DK.target(w.bob1)) == %{"one_time_keys" => %{}, "failures" => %{}}, hd(status)
      end

      T.sql!("UPDATE users SET is_active = true, deletion_status = NULL WHERE user_id = $1", [w.bob1.uid])
      assert {DK.unclaimed(w.bob1.uid, w.bob1.dev), DK.fallback_row(w.bob1.uid, w.bob1.dev)} == {1, ["FFFF", false]}
      assert DK.claim_one!(w.alice, w.bob1) |> DK.ids() == ["signed_curve25519:A1"], "the keys were never touched"
    end

    test "NEGATIVE: a caller whose erasure is under way (an in-flight bearer) claims nothing, not even from its own device", %{w: w} do
      DK.publish!(w.bob1, otks: ["A1"])
      assert T.whoami(w.alice.at).status == 200, "precondition: the bearer is accepted and cached"
      T.sql!("UPDATE users SET deletion_status = 'keys_deleted' WHERE user_id = $1", [w.alice.uid])
      c = DK.claim(w.alice, DK.target(w.bob1))
      assert c.status in [401, 403] or (c.status == 200 and TD.json(c)["one_time_keys"] == %{}), "got #{c.status} #{c.resp_body}"
      assert DK.unclaimed(w.bob1.uid, w.bob1.dev) == 1
    end
  end

  describe "request validation: the structure is checked, the ids are not" do
    test "one_time_keys missing, null, an array, a string or a number: 400 M_BAD_JSON, nothing consumed", %{w: w} do
      DK.publish!(w.bob1, otks: ["A1"])

      for body <- [%{}, %{"one_time_keys" => nil}, %{"one_time_keys" => []}, %{"one_time_keys" => "x"}, %{"one_time_keys" => 5}, %{"timeout" => 1}] do
        c = TD.req(:post, DK.claim_path(), w.alice.at, body)
        TD.assert_error(c, 400, "M_BAD_JSON")
      end

      assert DK.unclaimed(w.bob1.uid, w.bob1.dev) == 1
    end

    test "a body that is not an object (array, string, number): 400 M_BAD_JSON", %{w: w} do
      for raw <- ["[]", "\"x\"", "7", "null"] do
        c = DK.claim_raw(w.alice, raw)
        assert c.status == 400, "#{raw}: #{c.resp_body}"
        assert TD.json(c)["errcode"] in ["M_BAD_JSON", "M_NOT_JSON"]
      end
    end

    test "malformed JSON: 400 M_NOT_JSON", %{w: w} do
      TD.assert_error(DK.claim_raw(w.alice, "{\"one_time_keys\": "), 400, "M_NOT_JSON")
    end

    test "a user entry that is no object, or an algorithm that is no string (number, null, object, list): 400 M_BAD_JSON", %{w: w} do
      DK.publish!(w.bob1, otks: ["A1"])

      for bad <- [%{w.bob1.uid => "x"}, %{w.bob1.uid => nil}, %{w.bob1.uid => [w.bob1.dev]}, %{w.bob1.uid => %{w.bob1.dev => 5}}, %{w.bob1.uid => %{w.bob1.dev => nil}}, %{w.bob1.uid => %{w.bob1.dev => %{}}}, %{w.bob1.uid => %{w.bob1.dev => ["signed_curve25519"]}}] do
        TD.assert_error(DK.claim(w.alice, bad), 400, "M_BAD_JSON")
      end

      body = %{w.bob1.uid => %{w.bob1.dev => "signed_curve25519"}, "@x:test.local" => "broken"}
      TD.assert_error(DK.claim(w.alice, body), 400, "M_BAD_JSON")
      assert DK.unclaimed(w.bob1.uid, w.bob1.dev) == 1, "a valid target in a request with a broken one is NOT served"
    end
  end

  describe "authentication" do
    test "no Authorization header: 401 M_MISSING_TOKEN", %{w: _w} do
      c = TD.req(:post, DK.claim_path(), nil, %{"one_time_keys" => %{}})
      TD.assert_error(c, 401, "M_MISSING_TOKEN")
    end

    test "a junk bearer token: 401 M_UNKNOWN_TOKEN and nothing is consumed", %{w: w} do
      DK.publish!(w.bob1, otks: ["A1"])
      c = TD.req(:post, DK.claim_path(), "junk-" <> T.rand(8), %{"one_time_keys" => DK.target(w.bob1)})
      TD.assert_error(c, 401, "M_UNKNOWN_TOKEN")
      assert DK.unclaimed(w.bob1.uid, w.bob1.dev) == 1
    end

    test "after the caller's device was deleted its token is dead: 401, the key it would have claimed is untouched", %{w: w} do
      DK.publish!(w.bob1, otks: ["A1"])
      assert :ok = Nebu.Matrix.end_device_session(w.alice.uid, w.alice.dev)
      TD.assert_error(DK.claim(w.alice, DK.target(w.bob1)), 401, "M_UNKNOWN_TOKEN")
      assert DK.unclaimed(w.bob1.uid, w.bob1.dev) == 1
    end

    test "the same device id on two users never mixes their keys (the own-device rule is by USER)", %{w: _w} do
      id = "SAME" <> String.upcase(T.rand(3))
      u1 = TD.user_with_device!(id)
      u2 = TD.user_with_device!(id)
      DK.publish!(u1, otks: ["U1K"])
      DK.publish!(u2, otks: ["U2K"])
      assert DK.claim_one!(u1, u1) |> DK.ids() == ["signed_curve25519:U1K"]
      assert DK.claim_one!(u1, u2) == nil, "u2's device with the identical id is not u1's own device and shares no room"
      assert DK.unclaimed(u2.uid, id) == 1
    end
  end
end
