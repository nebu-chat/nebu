defmodule Nebu.Matrix.DeviceKeyDirectoryD1OptionalTest do
  @moduledoc """
  ONE pin test (kept in a file of its own, tagged `:d1_optional`) of the MUST-level spec bug D1 of the oracle context of story `device-key-directory` (REQ-2026-013, story Decisions D1):
  `POST /keys/query` returns `user_signing_keys` ONLY for the caller and only when the caller queries itself (Matrix CS v1.18 `#cross-signing`: the user-signing key is "only visible to
  the user that it belongs to"); before this story it was returned for ANY queried user.

  The change is trivially independent of the claim / changes work, so the reference implements it in a separate hunk. It was TAKEN into this story (this file runs and is green; story
  Decisions D1: taken), so the follow-up `key-query-hardening` does not repeat it. The rest of the query hardening (restriction to shared rooms, cross-user signatures)
  is NOT part of this story and has no test here.
  """
  use ExUnit.Case, async: false

  alias Nebu.Matrix.ToDeviceTestSupport, as: TD
  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration
  @moduletag :d1_optional

  setup do
    T.reset_rate_limits()
    Nebu.Test.ServerName.pin!(T.server_name())
    TD.disable_rate_limit()
    on_exit(fn -> T.restore_rate_limits() end)
    :ok
  end

  test "user_signing_keys contains the caller's own key when the caller queries itself and NEVER the key of another queried user" do
    alice = TD.user!("DKA")
    bob = TD.user!("DKB")
    TD.share!(alice, bob)
    :ok = Nebu.Matrix.CrossSigningKeyStore.put_keys(alice.uid, T.cross_signing_keys(alice.uid, "a"))
    :ok = Nebu.Matrix.CrossSigningKeyStore.put_keys(bob.uid, T.cross_signing_keys(bob.uid, "b"))

    query = fn who -> T.matrix_request(:post, "/_matrix/client/v3/keys/query", alice.at, body: %{"device_keys" => Map.new(who, &{&1, []})}) |> TD.json() end

    both = query.([alice.uid, bob.uid])
    assert Map.keys(both["user_signing_keys"]) == [alice.uid], "only the caller's own user-signing key: #{inspect(both["user_signing_keys"])}"
    assert both["user_signing_keys"][alice.uid]["keys"] == T.cross_signing_keys(alice.uid, "a")["user_signing_key"]["keys"]
    assert query.([bob.uid])["user_signing_keys"] == %{}, "bob's user-signing key is not served to alice"
    assert Map.keys(both["master_keys"]) |> Enum.sort() == Enum.sort([alice.uid, bob.uid]), "the master keys of both are unchanged by this decision (the query restriction is the follow-up story)"
  end
end
