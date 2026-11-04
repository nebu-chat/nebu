defmodule Nebu.Matrix.KeyQueryHardeningTest do
  @moduledoc """
  Acceptance tests (REAL database, full `Nebu.Web.Router`) for story `key-query-hardening` (REQ-2026-014): `POST /keys/query` shows only the caller and the users who share a
  room in which BOTH are joined (D1), `user_signing_keys` only to their owner (D2), the display name comes from `devices` (D3), cross-user signatures are stored apart and
  visible to the signer only (D4), `POST /keys/signatures/upload` decides who may sign what (D5), verifies every signature with Ed25519 over the canonical JSON (D6), drops
  the cross-user signatures of a replaced master key (D7), has limits (D8), is erased with the user (D9), stamps the signer in the device-list stream (D10) and never logs
  bodies (D11).

  One test per Gherkin scenario, tagged `@tag ac: "<scenario-slug>"`; the tests tagged `oracle-...` pin the MUSTs of the oracle context and the decisions that no scenario covers.

  The signatures in these tests are REAL Ed25519 signatures: every user gets generated key pairs, the signed message is `Nebu.Matrix.CanonicalJson.encode!/1` of the object without
  `signatures` and `unsigned`, the signature is unpadded base64. Users, devices and shared rooms come from the helpers of the sibling suites
  (`ToDeviceTestSupport`, `DeviceKeyDirectoryTestSupport`). The cross-signing keys are seeded through the real writer `CrossSigningKeyStore.put_keys/2`.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Nebu.Compliance.UserDeletion
  alias Nebu.Compliance.UserDeletionTestSupport, as: E
  alias Nebu.Matrix.CanonicalJson
  alias Nebu.Matrix.CrossSigningKeyStore, as: Store
  alias Nebu.Matrix.DeviceKeyDirectoryTestSupport, as: DK
  alias Nebu.Matrix.ModerationTestSupport, as: S
  alias Nebu.Matrix.ToDeviceTestSupport, as: TD
  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration

  @query "/_matrix/client/v3/keys/query"
  @sig_upload "/_matrix/client/v3/keys/signatures/upload"

  setup do
    T.reset_rate_limits()
    Nebu.Test.ServerName.pin!(T.server_name())
    TD.disable_rate_limit()
    on_exit(fn -> T.restore_rate_limits() end)
    :ok
  end

  # ── key material: real Ed25519 ──────────────────────────────────────────────

  defp b64(bin), do: Base.encode64(bin, padding: false)

  defp keypair do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    %{priv: priv, b64: b64(pub)}
  end

  # unpadded base64 Ed25519 signature over the canonical JSON of the object without `signatures` and `unsigned`
  defp sig(obj, kp) do
    msg = obj |> Map.drop(["signatures", "unsigned"]) |> CanonicalJson.encode!()
    b64(:crypto.sign(:eddsa, :none, msg, [kp.priv, :ed25519]))
  end

  # the object with ONE signature of `signer` by the key `key_id` (without the `ed25519:` prefix) made with `kp`
  defp signed(obj, signer, key_id, kp), do: Map.put(obj, "signatures", %{signer => %{"ed25519:" <> key_id => sig(obj, kp)}})

  defp device_obj(uid, dev, kp, extra) do
    Map.merge(
      %{
        "user_id" => uid,
        "device_id" => dev,
        "algorithms" => ["m.olm.v1.curve25519-aes-sha2", "m.megolm.v1.aes-sha2"],
        "keys" => %{"curve25519:#{dev}" => b64(:crypto.strong_rand_bytes(32)), "ed25519:#{dev}" => kp.b64}
      },
      extra
    )
  end

  defp cs_obj(uid, usage, kp), do: %{"user_id" => uid, "usage" => [usage], "keys" => %{("ed25519:" <> kp.b64) => kp.b64}}

  # a user with ONE device (real device keys uploaded through the route) and a full set of cross-signing keys
  # (master signed by the device, self-signing and user-signing key signed by the master). The map is a device map (`uid`, `dev`, `at`) plus the key material.
  defp person!(prefix, extra \\ %{}) do
    d = TD.user!(prefix)
    msk = keypair()
    ssk = keypair()
    usk = keypair()
    dkp = keypair()
    dev_obj = device_obj(d.uid, d.dev, dkp, extra)
    DK.upload!(d, %{"device_keys" => signed(dev_obj, d.uid, d.dev, dkp)})

    master = cs_obj(d.uid, "master", msk)
    ssk_obj = cs_obj(d.uid, "self_signing", ssk)
    usk_obj = cs_obj(d.uid, "user_signing", usk)

    :ok =
      Store.put_keys(d.uid, %{
        "master_key" => signed(master, d.uid, d.dev, dkp),
        "self_signing_key" => signed(ssk_obj, d.uid, msk.b64, msk),
        "user_signing_key" => signed(usk_obj, d.uid, msk.b64, msk)
      })

    Map.merge(d, %{msk: msk, ssk: ssk, usk: usk, dkp: dkp, dev_obj: dev_obj, master: master, ssk_obj: ssk_obj, usk_obj: usk_obj})
  end

  # a second device of the person with real device keys
  defp extra_device!(p, extra \\ %{}) do
    d = TD.device!(p, "KQX")
    kp = keypair()
    obj = device_obj(p.uid, d.dev, kp, extra)
    DK.upload!(d, %{"device_keys" => signed(obj, p.uid, d.dev, kp)})
    Map.merge(d, %{dkp: kp, dev_obj: obj})
  end

  defp nobody, do: "@nobody-#{T.rand(5)}:#{T.server_name()}"

  # ── requests ────────────────────────────────────────────────────────────────

  defp query(caller, users), do: TD.req(:post, @query, caller.at, %{"device_keys" => Map.new(users, &{&1, []})})

  defp query!(caller, users) do
    c = query(caller, users)
    assert c.status == 200, "keys/query: #{c.status} #{String.slice(c.resp_body, 0, 300)}"
    TD.json(c)
  end

  defp sigs(caller, body), do: TD.req(:post, @sig_upload, caller.at, body)

  defp sigs!(caller, body) do
    c = sigs(caller, body)
    assert c.status == 200, "keys/signatures/upload: #{c.status} #{String.slice(c.resp_body, 0, 300)}"
    json = TD.json(c)
    assert Map.keys(json) == ["failures"], "the answer is exactly `failures`: #{c.resp_body}"
    json["failures"]
  end

  # what the viewer sees on the master key of `uid`
  defp master_sigs(body, uid), do: get_in(body, ["master_keys", uid, "signatures"]) || %{}
  defp device_sigs(body, uid, dev), do: get_in(body, ["device_keys", uid, dev, "signatures"]) || %{}

  defp failure(failures, uid, key_id), do: get_in(failures, [uid, key_id])

  defp assert_failure(failures, uid, key_id, errcode) do
    f = failure(failures, uid, key_id)
    assert is_map(f), "expected a failure for #{uid} #{key_id}, got #{inspect(failures)}"
    assert f["errcode"] == errcode, "expected #{errcode} for #{key_id}, got #{inspect(f)}"
    assert is_binary(f["error"]) and f["error"] != ""
    f
  end

  # alice signs the master key of `target` with her user-signing key
  defp usk_signature_on_master(signer, target), do: signed(target.master, signer.uid, signer.usk.b64, signer.usk)
  defp sign_master!(signer, target), do: sigs!(signer, %{target.uid => %{target.msk.b64 => usk_signature_on_master(signer, target)}})

  defp advance(ms), do: DK.set_clock(DK.clock() + ms)

  defp logged(fun), do: TD.with_log_level(:debug, fn -> capture_log([level: :debug], fun) end)

  # ── scenarios ───────────────────────────────────────────────────────────────

  # Scenario: Query of a user I share no room with leaves the user out
  #   Given "@erin:nebu.test" has a device with identity keys and cross-signing keys and shares no joined room with me
  #   When I POST /keys/query for "@erin:nebu.test"
  #   Then the response contains no device keys, master key or self-signing key for "@erin:nebu.test" and is byte-identical to the answer for an unknown user
  @tag ac: "query-of-a-user-i-share-no-room-with-leaves-the-user-out"
  test "Scenario: Query of a user I share no room with leaves the user out" do
    alice = person!("KQA")
    erin = person!("KQE")

    c = query(alice, [erin.uid])
    assert c.status == 200
    body = TD.json(c)

    assert body["device_keys"] == %{}, "no device keys of a stranger: #{c.resp_body}"
    assert body["master_keys"] == %{}
    assert body["self_signing_keys"] == %{}
    assert body["user_signing_keys"] == %{}
    assert body["failures"] == %{}
    assert c.resp_body == query(alice, [nobody()]).resp_body, "byte-identical to the answer for an unknown user"
  end

  # Scenario: A pending invite or a left room does not make a user visible
  #   Given "@carol:nebu.test" was only invited to my room or left it
  #   When I POST /keys/query for "@carol:nebu.test"
  #   Then the answer is byte-identical to the answer for an unknown user
  @tag ac: "a-pending-invite-or-a-left-room-does-not-make-a-user-visible"
  test "Scenario: A pending invite or a left room does not make a user visible" do
    alice = person!("KQA")
    invited = person!("KQI")
    leaver = person!("KQL")
    TD.invite_only!(alice, invited)
    room = TD.share!(alice, leaver)

    assert query!(alice, [leaver.uid])["master_keys"] |> Map.keys() == [leaver.uid], "precondition: a joined member is visible"
    S.leave!(leaver, room)

    unknown = query(alice, [nobody()]).resp_body
    assert query(alice, [invited.uid]).resp_body == unknown, "a pending invite does not count"
    assert query(alice, [leaver.uid]).resp_body == unknown, "a user who left does not count"
  end

  # Scenario: My own keys are visible without any shared room
  #   Given I have a device, a master key, a self-signing key and a user-signing key and share no room with anybody
  #   When I POST /keys/query for myself
  #   Then all four are returned
  @tag ac: "my-own-keys-are-visible-without-any-shared-room"
  test "Scenario: My own keys are visible without any shared room" do
    alice = person!("KQA")
    body = query!(alice, [alice.uid])

    assert get_in(body, ["device_keys", alice.uid, alice.dev, "keys", "ed25519:#{alice.dev}"]) == alice.dkp.b64
    assert get_in(body, ["master_keys", alice.uid, "keys"]) == alice.master["keys"]
    assert get_in(body, ["self_signing_keys", alice.uid, "keys"]) == alice.ssk_obj["keys"]
    assert get_in(body, ["user_signing_keys", alice.uid, "keys"]) == alice.usk_obj["keys"]
  end

  # Scenario: The user-signing key is only visible to its owner
  #   Given "@bob:nebu.test" shares a room with me and both of us have cross-signing keys
  #   When I POST /keys/query for myself and for "@bob:nebu.test"
  #   Then "user_signing_keys" contains my key and does not contain the key of "@bob:nebu.test"
  @tag ac: "the-user-signing-key-is-only-visible-to-its-owner"
  test "Scenario: The user-signing key is only visible to its owner" do
    alice = person!("KQA")
    bob = person!("KQB")
    TD.share!(alice, bob)

    body = query!(alice, [alice.uid, bob.uid])
    assert Map.keys(body["user_signing_keys"]) == [alice.uid]
    assert body["user_signing_keys"][alice.uid]["keys"] == alice.usk_obj["keys"]
    assert Enum.sort(Map.keys(body["master_keys"])) == Enum.sort([alice.uid, bob.uid]), "the master keys of both are visible"
    assert Enum.sort(Map.keys(body["self_signing_keys"])) == Enum.sort([alice.uid, bob.uid])
  end

  # Scenario: A device rename shows in the next query
  #   Given "@bob:nebu.test" shares a room with me and has a device with a display name
  #   When "@bob:nebu.test" renames the device and I POST /keys/query again
  #   Then "unsigned.device_display_name" shows the new name
  @tag ac: "a-device-rename-shows-in-the-next-query"
  test "Scenario: A device rename shows in the next query" do
    alice = person!("KQA")
    bob = person!("KQB")
    TD.share!(alice, bob)
    path = "/_matrix/client/v3/devices/#{TD.seg(bob.dev)}"

    assert TD.req(:put, path, bob.at, %{"display_name" => "Bobs Phone"}).status == 200
    assert get_in(query!(alice, [bob.uid]), ["device_keys", bob.uid, bob.dev, "unsigned", "device_display_name"]) == "Bobs Phone"

    assert TD.req(:put, path, bob.at, %{"display_name" => "Bobs Tablet"}).status == 200
    assert get_in(query!(alice, [bob.uid]), ["device_keys", bob.uid, bob.dev, "unsigned", "device_display_name"]) == "Bobs Tablet"
  end

  # Scenario: A signature on another user's master key is stored and visible to the signer only
  #   Given "@bob:nebu.test" shares a room with me and I have a user-signing key
  #   When I POST /keys/signatures/upload with my valid signature over the master key of "@bob:nebu.test"
  #   Then "failures" is empty, my query of "@bob:nebu.test" shows my signature and Bob's own signatures on his master key, and a third user's and Bob's own query do not show my signature
  @tag ac: "a-signature-on-another-user-s-master-key-is-stored-and-visible-to-the"
  test "Scenario: A signature on another user's master key is stored and visible to the signer only" do
    alice = person!("KQA")
    bob = person!("KQB")
    carol = person!("KQC")
    TD.share!(alice, bob)
    TD.share!(bob, carol)

    assert sign_master!(alice, bob) == %{}, "failures is empty"

    mine = master_sigs(query!(alice, [bob.uid]), bob.uid)
    assert get_in(mine, [alice.uid, "ed25519:" <> alice.usk.b64]) == sig(bob.master, alice.usk), "the signer sees her signature"
    assert get_in(mine, [bob.uid, "ed25519:" <> bob.dev]) == sig(bob.master, bob.dkp), "and the own signatures of Bob on his master key"

    for {label, viewer} <- [{"a third user", carol}, {"Bob himself", bob}] do
      seen = master_sigs(query!(viewer, [bob.uid]), bob.uid)
      refute Map.has_key?(seen, alice.uid), "#{label} must not see the signature of Alice: #{inspect(seen)}"
      assert get_in(seen, [bob.uid, "ed25519:" <> bob.dev]) == sig(bob.master, bob.dkp), "#{label} still sees the own signatures of Bob"
    end

    assert sign_master!(alice, bob) == %{}, "the same signature again is idempotent"
  end

  # Scenario: A signature on the master key of a user I share no room with is refused like an unknown user
  #   Given "@erin:nebu.test" shares no joined room with me
  #   When I POST /keys/signatures/upload with a signature over the master key of "@erin:nebu.test" and with one over an unknown user's key
  #   Then "failures" reports the identical M_FORBIDDEN for both and nothing is stored
  @tag ac: "a-signature-on-the-master-key-of-a-user-i-share-no-room-with-is"
  test "Scenario: A signature on the master key of a user I share no room with is refused like an unknown user" do
    alice = person!("KQA")
    erin = person!("KQE")
    ghost = nobody()
    ghost_kp = keypair()
    ghost_master = cs_obj(ghost, "master", ghost_kp)

    failures =
      sigs!(alice, %{
        erin.uid => %{erin.msk.b64 => usk_signature_on_master(alice, erin)},
        ghost => %{ghost_kp.b64 => signed(ghost_master, alice.uid, alice.usk.b64, alice.usk)}
      })

    erin_failure = assert_failure(failures, erin.uid, erin.msk.b64, "M_FORBIDDEN")
    ghost_failure = assert_failure(failures, ghost, ghost_kp.b64, "M_FORBIDDEN")
    assert erin_failure == ghost_failure, "identical failure for a stranger and an unknown user (no oracle)"

    # nothing was stored: once Erin shares a room with me, her master key carries no signature of mine
    TD.share!(alice, erin)
    refute Map.has_key?(master_sigs(query!(alice, [erin.uid]), erin.uid), alice.uid)
  end

  # Scenario: A signature on a foreign device is refused per entry while valid entries still apply
  #   Given the request signs my own device and a device of "@bob:nebu.test"
  #   When I POST /keys/signatures/upload
  #   Then the own device signature is stored and "failures" names the foreign device with M_FORBIDDEN
  @tag ac: "a-signature-on-a-foreign-device-is-refused-per-entry-while-valid"
  test "Scenario: A signature on a foreign device is refused per entry while valid entries still apply" do
    alice = person!("KQA")
    bob = person!("KQB")
    TD.share!(alice, bob)

    failures =
      sigs!(alice, %{
        alice.uid => %{alice.dev => signed(alice.dev_obj, alice.uid, alice.ssk.b64, alice.ssk)},
        bob.uid => %{bob.dev => signed(bob.dev_obj, alice.uid, alice.ssk.b64, alice.ssk)}
      })

    assert Map.keys(failures) == [bob.uid], "only the foreign device fails: #{inspect(failures)}"
    assert Map.keys(failures[bob.uid]) == [bob.dev]
    assert_failure(failures, bob.uid, bob.dev, "M_FORBIDDEN")

    own = device_sigs(query!(alice, [alice.uid]), alice.uid, alice.dev)
    assert get_in(own, [alice.uid, "ed25519:" <> alice.ssk.b64]) == sig(alice.dev_obj, alice.ssk), "the own device signature is stored"
    assert get_in(own, [alice.uid, "ed25519:" <> alice.dev]) == sig(alice.dev_obj, alice.dkp), "next to the signature the device made itself"

    foreign = device_sigs(query!(alice, [bob.uid]), bob.uid, bob.dev)
    refute Map.has_key?(foreign, alice.uid), "nothing is stored on the foreign device: #{inspect(foreign)}"
  end

  # Scenario: An invalid signature is rejected
  #   Given I upload a signature that does not verify against the signing key, one with an unknown signing key id and one over an object whose key differs from the stored key
  #   When I POST /keys/signatures/upload
  #   Then "failures" reports M_INVALID_SIGNATURE for each of these entries and nothing is stored
  @tag ac: "an-invalid-signature-is-rejected"
  test "Scenario: An invalid signature is rejected" do
    alice = person!("KQA")
    second = extra_device!(alice)
    before = query(alice, [alice.uid]).resp_body

    # (1) a signature that does not verify: made by a key that is not the self-signing key it names
    forged = Map.put(alice.dev_obj, "signatures", %{alice.uid => %{("ed25519:" <> alice.ssk.b64) => sig(alice.dev_obj, keypair())}})
    # (2) an unknown signing key id (the signature itself is valid for the device key)
    unknown_id = Map.put(alice.master, "signatures", %{alice.uid => %{"ed25519:NOSUCHDEVICE" => sig(alice.master, alice.dkp)}})
    # (3) a valid signature over an object whose content differs from the stored device keys
    changed = Map.put(second.dev_obj, "algorithms", ["m.olm.v1.curve25519-aes-sha2"])
    changed = signed(changed, alice.uid, alice.ssk.b64, alice.ssk)

    failures = sigs!(alice, %{alice.uid => %{alice.dev => forged, alice.msk.b64 => unknown_id, second.dev => changed}})

    for key_id <- [alice.dev, alice.msk.b64, second.dev], do: assert_failure(failures, alice.uid, key_id, "M_INVALID_SIGNATURE")
    assert query(alice, [alice.uid]).resp_body == before, "nothing is stored for any of the three"
  end

  # Scenario: The unsigned member and the key order do not break a valid signature
  #   Given a client signs an object with an "unsigned" member, more than 32 keys and a non-ASCII value in canonical JSON
  #   When I POST /keys/signatures/upload
  #   Then the signature verifies and is stored
  @tag ac: "the-unsigned-member-and-the-key-order-do-not-break-a-valid-signature"
  test "Scenario: The unsigned member and the key order do not break a valid signature" do
    extra = for(i <- 0..39, into: %{}, do: {"k#{i}", "v#{i}"}) |> Map.put("note", "größe ✓ 日本語")
    alice = person!("KQA", extra)
    assert map_size(alice.dev_obj) > 32, "precondition: more than 32 keys (Erlang maps stop being ordered)"

    obj = alice.dev_obj |> signed(alice.uid, alice.ssk.b64, alice.ssk) |> Map.put("unsigned", %{"device_display_name" => "Pünktchen ✓"})

    assert sigs!(alice, %{alice.uid => %{alice.dev => obj}}) == %{}

    stored = device_sigs(query!(alice, [alice.uid]), alice.uid, alice.dev)
    assert get_in(stored, [alice.uid, "ed25519:" <> alice.ssk.b64]) == sig(alice.dev_obj, alice.ssk)
    assert get_in(query!(alice, [alice.uid]), ["device_keys", alice.uid, alice.dev, "note"]) == "größe ✓ 日本語"
  end

  # Scenario: A malformed entry is an M_INVALID_PARAM failure, a malformed body a 400
  #   Given an entry that is not an object, and separately a body that is not a JSON object
  #   When I POST /keys/signatures/upload
  #   Then the entry fails with M_INVALID_PARAM in "failures" and the body is answered 400 M_NOT_JSON or M_BAD_JSON
  @tag ac: "a-malformed-entry-is-an-m-invalid-param-failure-a-malformed-body-a-400"
  test "Scenario: A malformed entry is an M_INVALID_PARAM failure, a malformed body a 400" do
    alice = person!("KQA")
    second = extra_device!(alice)

    failures =
      sigs!(alice, %{
        alice.uid => %{
          "NOTANOBJECT" => "a string",
          "NULLENTRY" => nil,
          "LISTENTRY" => [1, 2],
          alice.dev => Map.put(alice.dev_obj, "signatures", "not a map"),
          alice.msk.b64 => Map.put(alice.master, "signatures", %{}),
          second.dev => Map.put(second.dev_obj, "signatures", %{"@someone-else:test.local" => %{"ed25519:X" => "AAAA"}})
        }
      })

    for key_id <- ["NOTANOBJECT", "NULLENTRY", "LISTENTRY", alice.dev, alice.msk.b64, second.dev] do
      assert_failure(failures, alice.uid, key_id, "M_INVALID_PARAM")
    end

    for raw <- ["[1,2]", ~s("a string"), "{not json", "null"] do
      c = TD.req(:post, @sig_upload, alice.at, {:raw, raw})
      assert c.status == 400, "body #{raw}: #{c.status} #{c.resp_body}"
      assert TD.json(c)["errcode"] in ["M_NOT_JSON", "M_BAD_JSON"], "body #{raw}: #{c.resp_body}"
    end
  end

  # Scenario: The request sizes are bounded and the endpoint is rate limited
  #   Given a request with 201 signed objects, and a client that sends 21 uploads at once
  #   When I POST /keys/signatures/upload
  #   Then the large request is answered 400 M_INVALID_PARAM before any verification and the 21st upload is answered 429 M_LIMIT_EXCEEDED
  @tag ac: "the-request-sizes-are-bounded-and-the-endpoint-is-rate-limited"
  test "Scenario: The request sizes are bounded and the endpoint is rate limited" do
    alice = person!("KQA")
    bob = person!("KQB")
    TD.enable_rate_limit()

    # tier keys_signatures: 60 / min, burst 20, frozen clock: the 21st request in a row is refused
    for i <- 1..20, do: assert(sigs(alice, %{}).status == 200, "upload #{i}")
    c = TD.assert_429(sigs(alice, %{}), "the 21st upload")
    assert TD.json(c)["errcode"] == "M_LIMIT_EXCEEDED"
    assert sigs(bob, %{}).status == 200, "the bucket is per user"

    advance(3_600_000)

    # junk entries: a request that were verified would answer 200 with 201 failures
    junk = fn user, from, to -> Map.new(from..to, &{"K#{&1}", "junk #{user}"}) end
    TD.assert_error(sigs(alice, %{alice.uid => junk.(1, 1, 201)}), 400, "M_INVALID_PARAM")
    TD.assert_error(sigs(alice, %{alice.uid => junk.(1, 1, 100), bob.uid => junk.(2, 101, 201)}), 400, "M_INVALID_PARAM")

    ok = sigs(alice, %{alice.uid => junk.(1, 1, 200)})
    assert ok.status == 200, "exactly 200 signed objects are fine: #{ok.status} #{String.slice(ok.resp_body, 0, 200)}"
    assert map_size(TD.json(ok)["failures"][alice.uid]) == 200
  end

  # Scenario: Replacing a master key drops the cross-user signatures made on the old one
  #   Given I stored a signature over the master key of "@bob:nebu.test"
  #   When "@bob:nebu.test" uploads a new master key
  #   Then my query of "@bob:nebu.test" no longer shows my signature
  @tag ac: "replacing-a-master-key-drops-the-cross-user-signatures-made-on-the"
  test "Scenario: Replacing a master key drops the cross-user signatures made on the old one" do
    alice = person!("KQA")
    bob = person!("KQB")
    TD.share!(alice, bob)
    assert sign_master!(alice, bob) == %{}
    assert Map.has_key?(master_sigs(query!(alice, [bob.uid]), bob.uid), alice.uid), "precondition: the signature is visible"

    new_msk = keypair()
    new_master = cs_obj(bob.uid, "master", new_msk)

    :ok =
      Store.put_keys(bob.uid, %{
        "master_key" => signed(new_master, bob.uid, bob.dev, bob.dkp),
        "self_signing_key" => signed(bob.ssk_obj, bob.uid, new_msk.b64, new_msk),
        "user_signing_key" => signed(bob.usk_obj, bob.uid, new_msk.b64, new_msk)
      })

    body = query!(alice, [bob.uid])
    assert get_in(body, ["master_keys", bob.uid, "keys"]) == new_master["keys"], "precondition: the new master key is served"
    refute Map.has_key?(master_sigs(body, bob.uid), alice.uid), "the signature on the old key is gone: #{inspect(master_sigs(body, bob.uid))}"
  end

  # Scenario: Erasing a user deletes the signatures it made and the ones made on its keys
  #   Given I signed the master key of "@bob:nebu.test" and Bob signed mine
  #   When the GDPR erasure of "@bob:nebu.test" runs
  #   Then no signature row of either direction remains for Bob
  @tag ac: "erasing-a-user-deletes-the-signatures-it-made-and-the-ones-made-on"
  test "Scenario: Erasing a user deletes the signatures it made and the ones made on its keys" do
    E.setup_env!()
    TD.disable_rate_limit()
    alice = person!("KQA")
    bob = person!("KQB")
    carol = person!("KQC")
    TD.share!(alice, bob)
    TD.share!(alice, carol)

    assert sign_master!(alice, bob) == %{}, "Alice signs the master key of Bob"
    assert sign_master!(bob, alice) == %{}, "Bob signs the master key of Alice"
    assert sign_master!(alice, carol) == %{}, "Alice signs the master key of the bystander"

    # the table is the implementation's choice: every table of the schema whose name says `signature` and every text column of it
    assert signature_rows(bob.uid) >= 2, "precondition: a row per direction names Bob"
    carol_before = signature_rows(carol.uid)
    assert carol_before >= 1, "precondition: the bystander's row exists"

    assert {:ok, _} = UserDeletion.delete_user_keys(E.admin(), bob.uid, "atdd erasure")

    assert signature_rows(bob.uid) == 0, "no signature row of either direction remains for Bob"
    assert signature_rows(carol.uid) == carol_before, "the bystander's signature row is untouched"
  end

  # rows of the signature tables that name `uid` in any text column (a row naming it twice counts twice)
  defp signature_rows(uid) do
    columns =
      T.sql!(
        """
        SELECT table_name, column_name FROM information_schema.columns
        WHERE table_schema NOT IN ('pg_catalog', 'information_schema') AND table_name LIKE '%signature%' AND data_type IN ('text', 'character varying')
        """
      ).rows

    Enum.reduce(columns, 0, fn [table, column], acc ->
      acc + (T.sql!("SELECT count(*) FROM \"#{table}\" WHERE \"#{column}\" = $1", [uid]).rows |> hd() |> hd())
    end)
  end

  # ── oracle and decision pins (no scenario covers them) ──────────────────────

  @tag ac: "oracle-user-signing-key-self-not-queried"
  test "oracle R3/D2: when I do not query myself, user_signing_keys is empty (not even my own key)" do
    alice = person!("KQA")
    bob = person!("KQB")
    TD.share!(alice, bob)

    body = query!(alice, [bob.uid])
    assert body["user_signing_keys"] == %{}
    assert Map.keys(body["master_keys"]) == [bob.uid]
  end

  @tag ac: "oracle-no-oracle-for-malformed-remote-and-keyless-ids"
  test "oracle R1/R6/D1: malformed, remote and keyless user ids are left out byte-identically to an unknown user, failures stays empty" do
    alice = person!("KQA")
    keyless = TD.user!("KQK")
    TD.share!(alice, keyless)
    unknown = query(alice, [nobody()])
    assert unknown.status == 200
    assert TD.json(unknown)["failures"] == %{}

    for id <- ["not-a-user-id", "@remote:other.example", "@:", "", keyless.uid] do
      c = query(alice, [id])
      assert c.status == 200, "#{inspect(id)}: #{c.status} #{c.resp_body}"
      assert c.resp_body == unknown.resp_body, "#{inspect(id)} answers differently from an unknown user: #{c.resp_body}"
    end
  end

  @tag ac: "oracle-m-invalid-param-query-user-cap"
  test "oracle D8: /keys/query answers 400 M_INVALID_PARAM beyond 1000 queried users, 1000 are fine" do
    alice = person!("KQA")
    users = fn n -> Enum.map(1..n, &"@bulk#{&1}:#{T.server_name()}") end

    assert query(alice, users.(1000)).status == 200
    TD.assert_error(query(alice, users.(1001)), 400, "M_INVALID_PARAM")
  end

  @tag ac: "oracle-third-user-signature-invisible"
  test "oracle D4: a signature by a third user on Bob's master key is never shown to me" do
    alice = person!("KQA")
    bob = person!("KQB")
    carol = person!("KQC")
    TD.share!(alice, bob)
    TD.share!(bob, carol)

    assert sign_master!(carol, bob) == %{}

    seen = master_sigs(query!(alice, [bob.uid]), bob.uid)
    refute Map.has_key?(seen, carol.uid), "Alice sees the signature of Carol: #{inspect(seen)}"
    assert Map.has_key?(master_sigs(query!(carol, [bob.uid]), bob.uid), carol.uid), "Carol sees her own"
  end

  @tag ac: "oracle-m-forbidden-foreign-ssk-usk-and-own-usk-ssk"
  test "oracle R7/D5: foreign self-signing and user-signing keys and my own through this endpoint are M_FORBIDDEN" do
    alice = person!("KQA")
    bob = person!("KQB")
    TD.share!(alice, bob)

    failures =
      sigs!(alice, %{
        bob.uid => %{
          bob.ssk.b64 => signed(bob.ssk_obj, alice.uid, alice.usk.b64, alice.usk),
          bob.usk.b64 => signed(bob.usk_obj, alice.uid, alice.usk.b64, alice.usk)
        },
        alice.uid => %{
          alice.ssk.b64 => signed(alice.ssk_obj, alice.uid, alice.dev, alice.dkp),
          alice.usk.b64 => signed(alice.usk_obj, alice.uid, alice.dev, alice.dkp)
        }
      })

    assert_failure(failures, bob.uid, bob.ssk.b64, "M_FORBIDDEN")
    assert_failure(failures, bob.uid, bob.usk.b64, "M_FORBIDDEN")
    assert_failure(failures, alice.uid, alice.ssk.b64, "M_FORBIDDEN")
    assert_failure(failures, alice.uid, alice.usk.b64, "M_FORBIDDEN")
  end

  @tag ac: "oracle-own-master-signed-by-own-device"
  test "oracle R7/R10/D5 (b): my own master key signed by one of my devices is stored" do
    alice = person!("KQA")
    second = extra_device!(alice)

    assert sigs!(alice, %{alice.uid => %{alice.msk.b64 => signed(alice.master, alice.uid, second.dev, second.dkp)}}) == %{}

    seen = master_sigs(query!(alice, [alice.uid]), alice.uid)
    assert get_in(seen, [alice.uid, "ed25519:" <> second.dev]) == sig(alice.master, second.dkp)
    assert get_in(seen, [alice.uid, "ed25519:" <> alice.dev]) == sig(alice.master, alice.dkp), "the signature of the first device stays"
  end

  @tag ac: "oracle-device-list-stream-stamps-the-signer"
  test "oracle D10: a stored cross-user signature stamps the signer's key row, not the target's" do
    alice = person!("KQA")
    other_device = extra_device!(alice)
    bob = person!("KQB")
    TD.share!(alice, bob)
    token = DK.token(other_device)
    alice_before = DK.keys_pos(alice.uid)
    bob_before = DK.keys_pos(bob.uid)

    assert sign_master!(alice, bob) == %{}

    assert DK.keys_pos(alice.uid) > alice_before, "the signer's key row is stamped"
    assert DK.keys_pos(bob.uid) == bob_before, "the target is not stamped (the signature is invisible to everybody else)"
    assert alice.uid in DK.dl_changed(DK.sync(other_device, token)), "the signer's other device sees the change in device_lists.changed"
  end

  @tag ac: "oracle-own-master-signature-stamps-the-signer"
  test "oracle D10 (b): a stored signature on my own master key stamps my key row, an identical one does not" do
    alice = person!("KQA")
    second = extra_device!(alice)
    token = DK.token(alice)
    before = DK.keys_pos(alice.uid)

    assert sigs!(alice, %{alice.uid => %{alice.msk.b64 => signed(alice.master, alice.uid, second.dev, second.dkp)}}) == %{}

    stamped = DK.keys_pos(alice.uid)
    assert stamped > before, "the signer's key row is stamped"
    assert alice.uid in DK.dl_changed(DK.sync(alice, token)), "the signer's other device sees the change in device_lists.changed"

    assert sigs!(alice, %{alice.uid => %{alice.msk.b64 => signed(alice.master, alice.uid, second.dev, second.dkp)}}) == %{}
    assert DK.keys_pos(alice.uid) == stamped, "an identical signature changes nothing and stamps nothing"
  end

  @tag ac: "oracle-identical-cross-user-signature-stamps-nothing"
  test "oracle D10: uploading an identical cross-user signature again stamps nothing" do
    alice = person!("KQA")
    bob = person!("KQB")
    TD.share!(alice, bob)

    assert sign_master!(alice, bob) == %{}
    stamped = DK.keys_pos(alice.uid)
    assert stamped > 0

    assert sign_master!(alice, bob) == %{}, "the second upload is accepted"
    assert DK.keys_pos(alice.uid) == stamped, "the signer's key row is not stamped again"
    assert Map.has_key?(master_sigs(query!(alice, [bob.uid]), bob.uid), alice.uid), "the signature is still stored"
  end

  @tag ac: "oracle-unchanged-master-keeps-the-cross-user-signatures"
  test "oracle D7: a put_keys with an UNCHANGED master key keeps the cross-user signatures" do
    alice = person!("KQA")
    bob = person!("KQB")
    TD.share!(alice, bob)
    assert sign_master!(alice, bob) == %{}
    assert Map.has_key?(master_sigs(query!(alice, [bob.uid]), bob.uid), alice.uid), "precondition: the signature is visible"

    # the master key stays, the self-signing key is replaced
    new_ssk = keypair()
    new_ssk_obj = cs_obj(bob.uid, "self_signing", new_ssk)

    :ok =
      Store.put_keys(bob.uid, %{
        "master_key" => signed(bob.master, bob.uid, bob.dev, bob.dkp),
        "self_signing_key" => signed(new_ssk_obj, bob.uid, bob.msk.b64, bob.msk),
        "user_signing_key" => signed(bob.usk_obj, bob.uid, bob.msk.b64, bob.msk)
      })

    body = query!(alice, [bob.uid])
    assert get_in(body, ["self_signing_keys", bob.uid, "keys"]) == new_ssk_obj["keys"], "precondition: the replacement was stored"
    assert Map.has_key?(master_sigs(body, bob.uid), alice.uid), "the signature on the unchanged master key stays: #{inspect(master_sigs(body, bob.uid))}"
  end

  # Security review L1: the cross-user signature is bound to the KEY, not only to its id
  @tag ac: "oracle-same-id-other-key-drops-the-cross-user-signatures"
  test "security L1: a master key replaced by ANOTHER public key under the SAME id drops the cross-user signature" do
    alice = person!("KQA")
    bob = person!("KQB")
    TD.share!(alice, bob)
    assert sign_master!(alice, bob) == %{}
    assert Map.has_key?(master_sigs(query!(alice, [bob.uid]), bob.uid), alice.uid), "precondition: the signature is visible"

    count = fn ->
      {:ok, %{rows: [[n]]}} = Ecto.Adapters.SQL.query(Nebu.Repo, "SELECT count(*) FROM cross_signing_user_signatures WHERE target_user_id = $1", [bob.uid])
      n
    end

    assert count.() == 1

    # an UNCHANGED re-upload (same id AND key) keeps the row
    :ok =
      Store.put_keys(bob.uid, %{
        "master_key" => signed(bob.master, bob.uid, bob.dev, bob.dkp),
        "self_signing_key" => signed(bob.ssk_obj, bob.uid, bob.msk.b64, bob.msk),
        "user_signing_key" => signed(bob.usk_obj, bob.uid, bob.msk.b64, bob.msk)
      })

    assert count.() == 1
    assert Map.has_key?(master_sigs(query!(alice, [bob.uid]), bob.uid), alice.uid), "an unchanged re-upload keeps the signature"

    # the same key id, another public key
    other = keypair()
    new_master = %{"user_id" => bob.uid, "usage" => ["master"], "keys" => %{("ed25519:" <> bob.msk.b64) => other.b64}}

    :ok =
      Store.put_keys(bob.uid, %{
        "master_key" => signed(new_master, bob.uid, bob.dev, bob.dkp),
        "self_signing_key" => signed(bob.ssk_obj, bob.uid, bob.msk.b64, bob.msk),
        "user_signing_key" => signed(bob.usk_obj, bob.uid, bob.msk.b64, bob.msk)
      })

    body = query!(alice, [bob.uid])
    assert get_in(body, ["master_keys", bob.uid, "keys"]) == new_master["keys"], "precondition: the new key is served"
    refute Map.has_key?(master_sigs(body, bob.uid), alice.uid), "the stale signature is gone from the query"
    assert count.() == 0, "and the row is deleted"
  end

  # Security review L2: at most 4 signatures by the caller per object; signatures of other users are ignored
  @tag ac: "oracle-signature-cap-per-object"
  test "security L2: an object with 5 signatures by the caller is M_INVALID_PARAM; a foreign garbage signature next to a valid one still stores" do
    alice = person!("KQA")
    second = extra_device!(alice)

    five = for i <- 1..5, into: %{}, do: {"ed25519:KEY#{i}", sig(alice.master, alice.dkp)}
    failures = sigs!(alice, %{alice.uid => %{alice.msk.b64 => Map.put(alice.master, "signatures", %{alice.uid => five})}})
    assert_failure(failures, alice.uid, alice.msk.b64, "M_INVALID_PARAM")

    mixed =
      Map.put(alice.master, "signatures", %{
        alice.uid => %{("ed25519:" <> second.dev) => sig(alice.master, second.dkp)},
        "@someone-else:test.local" => %{"ed25519:X" => "garbage"}
      })

    assert sigs!(alice, %{alice.uid => %{alice.msk.b64 => mixed}}) == %{}
    stored = master_sigs(query!(alice, [alice.uid]), alice.uid)
    assert get_in(stored, [alice.uid, "ed25519:" <> second.dev]) == sig(alice.master, second.dkp), "the valid caller signature is stored"
    refute Map.has_key?(stored, "@someone-else:test.local"), "the foreign signature is not stored"
  end

  @tag ac: "oracle-no-bodies-in-logs"
  test "oracle D11: the bodies of keys/query and keys/signatures/upload never reach a log line" do
    alice = person!("KQA")
    canary = "CANARY-" <> T.rand(8)

    log =
      logged(fn ->
        query(alice, ["@u-#{canary}:test.local"])
        sigs(alice, %{alice.uid => %{"K-#{canary}" => %{"x-#{canary}" => canary}}, "@v-#{canary}:test.local" => %{"L-#{canary}" => "s-#{canary}"}})
      end)

    assert log =~ "query" or log =~ "signatures", "the request lines are there (the check is not vacuous): #{String.slice(log, 0, 300)}"
    refute log =~ canary, "a canary of a request body reached the log: #{String.slice(log, 0, 400)}"
    refute log =~ alice.at, "the access token reached the log"
  end

  # ── second pass: closes the three MINOR gaps of the pre-dev test review ─────

  # a query with the `device_keys` request map given verbatim (`uid => [device ids]`)
  defp query_devices(caller, request), do: TD.req(:post, @query, caller.at, %{"device_keys" => request})

  defp query_devices!(caller, request) do
    c = query_devices(caller, request)
    assert c.status == 200, "keys/query: #{c.status} #{String.slice(c.resp_body, 0, 300)}"
    TD.json(c)
  end

  # (1) D1 visibility: the shared-room predicate needs BOTH sides joined, in either direction

  @tag ac: "a-pending-invite-or-a-left-room-does-not-make-a-user-visible"
  test "D1: when I left the shared room while the other user is still joined, the user is no longer visible" do
    alice = person!("KQA")
    bob = person!("KQB")
    room = S.invite_room(bob, [alice])

    assert Map.keys(query!(alice, [bob.uid])["master_keys"]) == [bob.uid], "precondition: a joined peer is visible"
    S.leave!(alice, room)

    unknown = query(alice, [nobody()]).resp_body
    assert query(alice, [bob.uid]).resp_body == unknown, "the viewer left, the target is still joined: answers like an unknown user"
  end

  @tag ac: "a-pending-invite-or-a-left-room-does-not-make-a-user-visible"
  test "D1: when I am only invited to the room of the other user, the user is not visible (reverse invite)" do
    alice = person!("KQA")
    bob = person!("KQB")
    room = TD.invite_only!(bob, alice)

    unknown = query(alice, [nobody()]).resp_body
    assert query(alice, [bob.uid]).resp_body == unknown, "I am the invitee in the room of Bob: answers like an unknown user"

    S.join!(alice, room)
    assert Map.keys(query!(alice, [bob.uid])["master_keys"]) == [bob.uid], "control: once I joined, Bob is visible"
  end

  @tag ac: "query-of-a-user-i-share-no-room-with-leaves-the-user-out"
  test "D1: a room in which only one side is joined does not make the user visible, whichever side it is" do
    alice = person!("KQA")
    bob = person!("KQB")
    carol = person!("KQC")
    _own_room = S.make_room(alice, %{"preset" => "private_chat"})
    bobs_public_room = S.public_room(bob)
    _carols_private_room = S.make_room(carol, %{"preset" => "private_chat"})

    unknown = query(alice, [nobody()]).resp_body
    assert query(alice, [bob.uid]).resp_body == unknown, "Bob is joined in a public room I am not in"
    assert query(alice, [carol.uid]).resp_body == unknown, "Carol is alone in a private room"
    assert query(bob, [alice.uid]).resp_body == query(bob, [nobody()]).resp_body, "Alice is alone in her own room: invisible to Bob as well"

    S.join!(alice, bobs_public_room)
    assert Map.keys(query!(alice, [bob.uid])["master_keys"]) == [bob.uid], "control: once I joined the room of Bob, he is visible"
  end

  # (2) D1/R1 with explicit device ids

  @tag ac: "query-of-a-user-i-share-no-room-with-leaves-the-user-out"
  test "D1/R1: explicit device ids of a stranger answer byte-identically to an unknown user, those of a visible peer are served" do
    alice = person!("KQA")
    bob = person!("KQB")
    erin = person!("KQE")
    TD.share!(alice, bob)

    visible = query_devices!(alice, %{bob.uid => [bob.dev]})
    assert get_in(visible, ["device_keys", bob.uid, bob.dev, "keys", "ed25519:#{bob.dev}"]) == bob.dkp.b64, "control: the device of a visible peer is served"

    unknown = query_devices(alice, %{nobody() => [erin.dev]}).resp_body
    assert query_devices(alice, %{erin.uid => [erin.dev]}).resp_body == unknown, "the real device id of a stranger"
    assert query_devices(alice, %{erin.uid => ["NOSUCHDEVICE"]}).resp_body == unknown, "an unknown device id of a stranger"

    stranger = TD.json(query_devices(alice, %{erin.uid => [erin.dev]}))
    for map <- ["device_keys", "master_keys", "self_signing_keys", "user_signing_keys", "failures"], do: assert(stranger[map] == %{}, "#{map} of a stranger")
  end

  @tag ac: "oracle-no-oracle-for-malformed-remote-and-keyless-ids"
  test "oracle R1/D1: one request with a visible peer, a stranger and an unknown user answers with the visible peer only" do
    alice = person!("KQA")
    bob = person!("KQB")
    erin = person!("KQE")
    ghost = nobody()
    TD.share!(alice, bob)

    mixed = query_devices!(alice, %{bob.uid => [], erin.uid => [erin.dev], ghost => ["GHOSTDEV"]})

    assert Map.keys(mixed["device_keys"]) == [bob.uid], "device keys: #{inspect(mixed["device_keys"])}"
    assert Map.keys(mixed["master_keys"]) == [bob.uid]
    assert Map.keys(mixed["self_signing_keys"]) == [bob.uid]
    assert mixed["user_signing_keys"] == %{}
    assert mixed["failures"] == %{}
    assert mixed == query!(alice, [bob.uid]), "the stranger and the unknown user add nothing to the answer for the visible peer alone"

    mixed_ids = query_devices!(alice, %{bob.uid => [bob.dev], erin.uid => [erin.dev], ghost => ["GHOSTDEV"]})
    assert Map.keys(mixed_ids["device_keys"]) == [bob.uid], "explicit device ids in the mixed request: #{inspect(mixed_ids["device_keys"])}"
    assert Map.keys(mixed_ids["master_keys"]) == [bob.uid]
  end

  # (3) D6/R10: the verification key must be of the right type, a valid signature by another stored key of the caller is not enough

  @tag ac: "an-invalid-signature-is-rejected"
  test "D6/R10: a valid signature on a device by a device key instead of the self-signing key is M_INVALID_SIGNATURE and stores nothing" do
    alice = person!("KQA")
    second = extra_device!(alice)
    before = query(alice, [alice.uid]).resp_body

    by_device_key = signed(second.dev_obj, alice.uid, alice.dev, alice.dkp)
    assert by_device_key["signatures"][alice.uid]["ed25519:" <> alice.dev] == sig(second.dev_obj, alice.dkp), "the signature itself is a valid Ed25519 one"

    failures = sigs!(alice, %{alice.uid => %{second.dev => by_device_key}})
    assert_failure(failures, alice.uid, second.dev, "M_INVALID_SIGNATURE")
    assert query(alice, [alice.uid]).resp_body == before, "nothing is stored"

    assert sigs!(alice, %{alice.uid => %{second.dev => signed(second.dev_obj, alice.uid, alice.ssk.b64, alice.ssk)}}) == %{}, "control: the self-signing key is accepted"
    stored = device_sigs(query!(alice, [alice.uid]), alice.uid, second.dev)
    assert get_in(stored, [alice.uid, "ed25519:" <> alice.ssk.b64]) == sig(second.dev_obj, alice.ssk)
  end

  @tag ac: "an-invalid-signature-is-rejected"
  test "D6/R10: a valid signature on my own master key by my self-signing key instead of a device key is M_INVALID_SIGNATURE and stores nothing" do
    alice = person!("KQA")
    second = extra_device!(alice)
    before = query(alice, [alice.uid]).resp_body

    by_ssk = signed(alice.master, alice.uid, alice.ssk.b64, alice.ssk)
    assert by_ssk["signatures"][alice.uid]["ed25519:" <> alice.ssk.b64] == sig(alice.master, alice.ssk), "the signature itself is a valid Ed25519 one"

    failures = sigs!(alice, %{alice.uid => %{alice.msk.b64 => by_ssk}})
    assert_failure(failures, alice.uid, alice.msk.b64, "M_INVALID_SIGNATURE")
    assert query(alice, [alice.uid]).resp_body == before, "nothing is stored"

    assert sigs!(alice, %{alice.uid => %{alice.msk.b64 => signed(alice.master, alice.uid, second.dev, second.dkp)}}) == %{}, "control: a device key is accepted"
    stored = master_sigs(query!(alice, [alice.uid]), alice.uid)
    assert get_in(stored, [alice.uid, "ed25519:" <> second.dev]) == sig(alice.master, second.dkp)
    refute Map.has_key?(stored[alice.uid], "ed25519:" <> alice.ssk.b64), "the self-signing signature was not stored: #{inspect(stored)}"
  end

  @tag ac: "an-invalid-signature-is-rejected"
  test "D6/R10: a valid signature on a foreign master key by my self-signing key or my device key instead of my user-signing key is M_INVALID_SIGNATURE and stores nothing" do
    alice = person!("KQA")
    bob = person!("KQB")
    carol = person!("KQC")
    TD.share!(alice, bob)
    TD.share!(alice, carol)
    before = query(alice, [bob.uid, carol.uid]).resp_body

    by_ssk = signed(bob.master, alice.uid, alice.ssk.b64, alice.ssk)
    by_device = signed(carol.master, alice.uid, alice.dev, alice.dkp)
    assert by_ssk["signatures"][alice.uid]["ed25519:" <> alice.ssk.b64] == sig(bob.master, alice.ssk), "the signature itself is a valid Ed25519 one"
    assert by_device["signatures"][alice.uid]["ed25519:" <> alice.dev] == sig(carol.master, alice.dkp), "the signature itself is a valid Ed25519 one"

    failures = sigs!(alice, %{bob.uid => %{bob.msk.b64 => by_ssk}, carol.uid => %{carol.msk.b64 => by_device}})
    assert_failure(failures, bob.uid, bob.msk.b64, "M_INVALID_SIGNATURE")
    assert_failure(failures, carol.uid, carol.msk.b64, "M_INVALID_SIGNATURE")
    assert query(alice, [bob.uid, carol.uid]).resp_body == before, "nothing is stored"

    assert sign_master!(alice, bob) == %{}, "control: the user-signing key is accepted"
    stored = master_sigs(query!(alice, [bob.uid]), bob.uid)
    assert get_in(stored, [alice.uid, "ed25519:" <> alice.usk.b64]) == sig(bob.master, alice.usk)
    refute Map.has_key?(stored[alice.uid], "ed25519:" <> alice.ssk.b64), "the self-signing signature was not stored: #{inspect(stored)}"
  end
end
