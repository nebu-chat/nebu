defmodule Nebu.Matrix.DeviceKeyDirectoryTest do
  @moduledoc """
  ATDD for story `device-key-directory` (REQ-2026-013) — Device-key directory: one-time key claim, device-list changes and the device-list stream.

  One end-to-end test per Gherkin scenario, tagged `@tag ac: "<scenario-slug>"` (REAL database, full `Nebu.Web.Router`, the real routes `POST /keys/claim` and
  `GET /keys/changes`). Red until the story is implemented: the routes do not exist yet. The depth (edge cases, oracle MUSTs, limits, stream, GDPR) is in the sibling
  suites `device_key_directory_*_test.exs`; these five tests are the story's acceptance path.
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
    # alice (the caller) and bob share a room, carol shares a room with bob only, dave shares nothing
    {:ok, w: DK.world!()}
  end

  # Scenario: Concurrent claims consume a one-time key exactly once
  #   Given device "@bob:nebu.test" "BOBDEV" has exactly one one-time key "signed_curve25519:AAAA" and no fallback key
  #   When two different users with a shared room claim a "signed_curve25519" key for "@bob:nebu.test" "BOBDEV" at the same time
  #   Then exactly one claim receives "signed_curve25519:AAAA" and no other claim receives it, and the device has zero one-time keys left
  @tag ac: "concurrent-claims-consume-a-one-time-key-exactly-once"
  test "Scenario: Concurrent claims consume a one-time key exactly once", %{w: w} do
    pub = DK.publish!(w.bob1, otks: ["AAAA"])
    assert DK.unclaimed(w.bob1.uid, w.bob1.dev) == 1

    # alice and carol both share a room with bob
    answers = S.race([fn -> DK.claim_one!(w.alice, w.bob1) end, fn -> DK.claim_one!(w.carol, w.bob1) end])

    received = Enum.reject(answers, &is_nil/1)
    assert received == [%{"signed_curve25519:AAAA" => pub.otks["signed_curve25519:AAAA"]}], "exactly one claim gets the key, the other is left out: #{inspect(answers)}"
    assert DK.unclaimed(w.bob1.uid, w.bob1.dev) == 0
    assert DK.claimed(w.bob1.uid, w.bob1.dev) == 1
    assert TD.sync(w.bob1)["device_one_time_keys_count"] == %{"signed_curve25519" => 0}
  end

  # Scenario: Fallback key is used when one-time keys are exhausted and is not consumed
  #   Given device "@bob:nebu.test" "BOBDEV" has no one-time keys left and a fallback key "signed_curve25519:FFFF"
  #   When I claim a "signed_curve25519" key for "@bob:nebu.test" "BOBDEV"
  #   Then the response contains the fallback key "signed_curve25519:FFFF" and a second claim also returns "signed_curve25519:FFFF"
  @tag ac: "fallback-key-is-used-when-one-time-keys-are-exhausted-and-is-not"
  test "Scenario: Fallback key is used when one-time keys are exhausted and is not consumed", %{w: w} do
    pub = DK.publish!(w.bob1, fallback: "FFFF")
    {fid, fobj} = pub.fallback
    assert fid == "signed_curve25519:FFFF"
    assert DK.unclaimed(w.bob1.uid, w.bob1.dev) == 0
    assert TD.sync(w.bob1)["device_unused_fallback_key_types"] == ["signed_curve25519"]

    first = DK.claim!(w.alice, DK.target(w.bob1))
    assert DK.got(first, w.bob1) == %{fid => fobj}, "the fallback key is returned verbatim (with fallback: true)"
    assert DK.claim_one!(w.alice, w.bob1) == %{fid => fobj}, "the fallback key is not consumed: a second claim returns it again"

    # not consumed, but marked used: its algorithm leaves the unused types of THAT device
    assert [_key_id, true] = DK.fallback_row(w.bob1.uid, w.bob1.dev)
    assert TD.sync(w.bob1)["device_unused_fallback_key_types"] == []
  end

  # Scenario: Unknown or unauthorized device is left out of the response
  #   Given "@dave:nebu.test" has no device "GHOSTDEV" and shares no room with me
  #   When I claim a "signed_curve25519" key for "@dave:nebu.test" "GHOSTDEV"
  #   Then the response contains no key for that device, "failures" is empty, and the answer is identical to the answer for a user I cannot claim from
  @tag ac: "unknown-or-unauthorized-device-is-left-out-of-the-response"
  test "Scenario: Unknown or unauthorized device is left out of the response", %{w: w} do
    # a user I cannot claim from: dave HAS keys (and a fallback key) but shares no room with alice
    DK.publish!(w.dave, otks: ["D1"], fallback: "DF")

    ghost = DK.claim(w.alice, %{w.dave.uid => %{"GHOSTDEV" => "signed_curve25519"}})
    assert ghost.status == 200
    assert TD.json(ghost) == %{"one_time_keys" => %{}, "failures" => %{}}, "no key for that device, failures is empty"

    real_but_unshared = DK.claim(w.alice, DK.target(w.dave))
    assert TD.shape(real_but_unshared) == TD.shape(ghost), "the answer does not depend on whether the device exists"
    assert DK.unclaimed(w.dave.uid, w.dave.dev) == 1, "the key of the unauthorized claim was not consumed"
    assert [_key_id, false] = DK.fallback_row(w.dave.uid, w.dave.dev), "the fallback key of the unauthorized claim stays unused"
  end

  # Scenario: Changed device lists are reported between two sync tokens
  #   Given I hold sync token "s100" and "@carol:nebu.test" shares a room with me
  #   When "@carol:nebu.test" adds or deletes a device after "s100" and I call GET /keys/changes with from "s100" and to the current token
  #   Then the response "changed" list contains "@carol:nebu.test"
  @tag ac: "changed-device-lists-are-reported-between-two-sync-tokens"
  test "Scenario: Changed device lists are reported between two sync tokens", %{w: w} do
    carol = DK.peer!(w.alice, "DKK")
    s100 = DK.token(w.alice)

    # carol adds a device (identity keys uploaded) after s100
    DK.publish!(carol)
    s101 = DK.token(w.alice)
    assert DK.changes!(w.alice, s100, s101) == %{"changed" => [carol.uid], "left" => []}

    # carol deletes a device after s101
    :ok = Nebu.Matrix.end_device_session(carol.uid, carol.dev)
    s102 = DK.token(w.alice)
    assert carol.uid in DK.changes!(w.alice, s101, s102)["changed"]

    # a user alice shares no room with never appears
    DK.publish!(w.dave)
    refute w.dave.uid in DK.changes!(w.alice, s100, DK.token(w.alice))["changed"]
  end

  # Scenario: Claims are rate limited per caller and target
  #   Given I have already claimed one-time keys for "@bob:nebu.test" "BOBDEV" up to the configured per-caller, per-target limit
  #   When I claim another one-time key for "@bob:nebu.test" "BOBDEV"
  #   Then the server rejects the claim with HTTP 429 and M_LIMIT_EXCEEDED and no one-time key is consumed
  @tag ac: "claims-are-rate-limited-per-caller-and-target"
  test "Scenario: Claims are rate limited per caller and target", %{w: w} do
    # the real limiter with a frozen clock: the per (caller, target user, device) bucket is 10 / hour, burst 5
    DK.enable_rate_limit()
    limit = DK.limits().target_burst
    DK.publish!(w.bob1, otks: for(i <- 1..(limit + 3), do: "K#{i}"))

    for i <- 1..limit, do: assert(map_size(DK.claim!(w.alice, DK.target(w.bob1))["one_time_keys"]) == 1, "claim #{i} is within the limit")
    assert DK.unclaimed(w.bob1.uid, w.bob1.dev) == 3

    refused = DK.claim(w.alice, DK.target(w.bob1))
    TD.assert_429(refused, "the claim beyond the per-target limit")
    assert TD.json(refused)["errcode"] == "M_LIMIT_EXCEEDED"
    assert DK.unclaimed(w.bob1.uid, w.bob1.dev) == 3, "no one-time key is consumed by the refused claim"
  end
end
