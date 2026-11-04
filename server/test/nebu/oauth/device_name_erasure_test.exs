defmodule Nebu.OAuth.DeviceNameErasureTest do
  @moduledoc """
  Story `oauth-device-default-display-name` (REQ-2026-004), GDPR: the default name adds NO personal data and NO new storage, so the erasure of a user
  (the dispatcher RPC `delete_user_keys`: the erasure transaction plus the post-commit teardown that deletes the `devices` rows) is unchanged. Pinned end to end with devices that were named by the REAL flow: after the erasure the
  user's device rows (and with them the names) are gone and another user's device (same client, same device id) is byte-identical. The name lives in
  `devices.display_name`, so no erasure code is needed for it.
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  alias Nebu.Compliance.UserDeletionTestSupport, as: E
  alias Nebu.OAuth.DeviceNameTestSupport, as: D

  setup do
    {:ok, E.setup_env!()}
  end

  # the dispatcher RPC: the erasure transaction PLUS the post-commit session teardown that deletes the `devices` rows (display name, last IP)
  defp erase!(uid) do
    req = %Core.DeleteUserKeysRequest{admin_user_id: E.admin(), target_user_id: uid, reason: "atdd erasure"}
    Nebu.Matrix.EventDispatcher.Server.delete_user_keys(req, E.admin_stream())
  end

  test "alice is erased: her OAuth-named devices are gone, bob's device (same client, same device id) is untouched", %{cid: cid, priv: priv} do
    alice = D.session!(cid, priv, "ERASEDEV01")
    bob = D.session!(cid, priv, "ERASEDEV01")
    alice_second = D.session!(cid, priv, "ERASEDEV02", sub: alice.sub)

    assert D.name_of(alice.user_id, "ERASEDEV01") =~ " (ASEDEV01)"
    assert D.name_of(alice_second.user_id, "ERASEDEV02") =~ " (ASEDEV02)"
    bob_before = D.device_row(bob.user_id, "ERASEDEV01")
    assert bob_before["display_name"] =~ " (ASEDEV01)"

    assert %Core.DeleteUserKeysResponse{status: "keys_deleted", keys_deleted_at: at} = erase!(alice.user_id)
    assert is_integer(at)

    assert D.names_of(alice.user_id) == %{}, "no device of alice (and so no default name) remains"
    assert D.device_row(bob.user_id, "ERASEDEV01") == bob_before
  end
end
