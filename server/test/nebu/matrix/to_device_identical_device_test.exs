defmodule Nebu.Matrix.ToDeviceIdenticalDeviceTest do
  @moduledoc """
  Acceptance tests for story `to-device-messaging` (epic e2ee-client-support, REQ-2026-012), test review finding M2: IDOR with an IDENTICAL device id on two users. OAuth device ids are chosen by the
  client (`device:XYZ` of the scope), so an attacker can pick the id of a victim's device. Every statement of the queue must therefore be scoped by the USER as well as by the device: sync
  delivery, the pending pre-check, the acknowledgement, the purge on device delete and logout, the transaction scope and the target resolution of a send.

  Two users U1 and U2 have a device with the same id `SAMEDEV...`; the sender shares a room with both.
  """
  use ExUnit.Case, async: false

  alias Nebu.Matrix.ToDeviceTestSupport, as: TD
  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration

  setup do
    T.reset_rate_limits()
    Nebu.Test.ServerName.pin!(T.server_name())
    TD.disable_rate_limit()
    T.put_env_scoped(:uia_fresh_auth_seconds, 86_400)
    on_exit(fn -> T.restore_rate_limits() end)
    :ok
  end

  # alice (sender) shares a room with u1 and u2; both have the device `id`; u1 additionally has a second device
  defp world! do
    id = "SAME" <> String.upcase(T.rand(3))
    alice = TD.user!("TDA")
    u1 = TD.user_with_device!(id)
    u2 = TD.user_with_device!(id)
    u1b = TD.device!(u1, "TDO")
    TD.share!(alice, u1)
    TD.share!(alice, u2)
    %{id: id, alice: alice, u1: u1, u1b: u1b, u2: u2}
  end

  defp ns(body), do: Enum.map(TD.events(body), & &1["content"]["n"])

  test "send to {u1, id} reaches only u1's device: u2's device of the same id gets nothing (delivery and queue are scoped by user)" do
    w = world!()
    TD.tell!(w.alice, w.u1, "m.dummy", %{"n" => 1})
    assert {TD.queue_count(w.u1.uid, w.id), TD.queue_count(w.u2.uid, w.id)} == {1, 0}
    assert ns(TD.sync(w.u1)) == [1]
    assert TD.events(TD.sync(w.u2)) == []
  end

  test "each of the two devices receives its own message, never the other's (same device id, same sender)" do
    w = world!()
    TD.tell!(w.alice, w.u1, "m.dummy", %{"n" => 1})
    TD.tell!(w.alice, w.u2, "m.dummy", %{"n" => 2})
    assert {ns(TD.sync(w.u1)), ns(TD.sync(w.u2))} == {[1], [2]}
  end

  test "the acknowledgement of u2's token deletes nothing of u1's same-id device, whatever the delivery stamps (u1 is delivered FIRST, u2 acknowledges a higher position)" do
    w = world!()
    TD.tell!(w.alice, w.u1, "m.dummy", %{"n" => 1})
    TD.tell!(w.alice, w.u2, "m.dummy", %{"n" => 2})
    first1 = TD.sync(w.u1)
    first2 = TD.sync(w.u2)
    assert {ns(first1), ns(first2)} == {[1], [2]}

    assert TD.events(TD.sync(w.u2, TD.next(first2))) == []
    assert TD.queue_count(w.u2.uid, w.id) == 0
    assert TD.queue_count(w.u1.uid, w.id) == 1, "u1's queue (same device id) is untouched by u2's acknowledgement"
    assert ns(TD.sync(w.u1, TD.next(first1))) == []
  end

  test "u2 presenting u1's token (a foreign core) acknowledges nothing of either" do
    w = world!()
    TD.tell!(w.alice, w.u1, "m.dummy", %{"n" => 1})
    TD.tell!(w.alice, w.u2, "m.dummy", %{"n" => 2})
    first2 = TD.sync(w.u2)
    first1 = TD.sync(w.u1)
    assert ns(TD.sync(w.u2, TD.next(first1))) == [2]
    assert {TD.queue_count(w.u1.uid, w.id), TD.queue_count(w.u2.uid, w.id)} == {1, 1}
    assert ns(first2) == [2]
  end

  test "the pending pre-check is scoped by user: u1's waiting message does not end u2's long poll (same device id)" do
    w = world!()
    since = TD.next(TD.sync(w.u2))
    TD.tell!(w.alice, w.u1, "m.dummy", %{"n" => 1})
    started = System.monotonic_time(:millisecond)
    body = TD.sync(w.u2, since, timeout: 800)
    assert TD.events(body) == []
    assert System.monotonic_time(:millisecond) - started >= 600, "u2 waited: nothing is pending for u2"
  end

  test "DELETE /devices/{id} is refused (404) while another user owns a device of that id (the existing guard): no queue of either user is touched" do
    w = world!()
    TD.tell!(w.alice, w.u1, "m.dummy", %{"n" => 1})
    TD.tell!(w.alice, w.u2, "m.dummy", %{"n" => 2})
    assert T.matrix_request(:delete, "/_matrix/client/v3/devices/" <> w.id, w.u1b.at, body: %{}).status == 404
    assert {TD.queue_count(w.u1.uid, w.id), TD.queue_count(w.u2.uid, w.id)} == {1, 1}
    assert ns(TD.sync(w.u2)) == [2]
  end

  test "the purge of u1's device (teardown by user and device) keeps u2's rows and records of the same device id" do
    w = world!()
    TD.tell!(w.alice, w.u1, "m.dummy", %{"n" => 1})
    TD.tell!(w.alice, w.u2, "m.dummy", %{"n" => 2})
    TD.tell!(w.u1, w.alice, "m.dummy", %{"from" => "u1"})
    TD.tell!(w.u2, w.alice, "m.dummy", %{"from" => "u2"})
    assert :ok = Nebu.Matrix.end_device_session(w.u1.uid, w.id)
    assert {TD.queue_count(w.u1.uid, w.id), TD.txn_count(w.u1.uid, w.id)} == {0, 0}
    assert {TD.queue_count(w.u2.uid, w.id), TD.txn_count(w.u2.uid, w.id)} == {1, 1}
  end

  test "POST /logout of u1's device purges only u1's rows of that device id" do
    w = world!()
    TD.tell!(w.alice, w.u1, "m.dummy", %{"n" => 1})
    TD.tell!(w.alice, w.u2, "m.dummy", %{"n" => 2})
    assert T.matrix_request(:post, "/_matrix/client/v3/logout", w.u1.at, body: %{}).status == 200
    assert {TD.queue_count(w.u1.uid, w.id), TD.queue_count(w.u2.uid, w.id)} == {0, 1}
  end

  test "the admin revoke (delete_user_device/2) of u1's device purges only u1's rows" do
    w = world!()
    TD.tell!(w.alice, w.u1, "m.dummy", %{"n" => 1})
    TD.tell!(w.alice, w.u2, "m.dummy", %{"n" => 2})
    assert :ok = Nebu.Matrix.delete_user_device(w.u1.uid, w.id)
    assert {TD.queue_count(w.u1.uid, w.id), TD.queue_count(w.u2.uid, w.id)} == {0, 1}
  end

  test "the transaction scope is (user, device, type, txn): u1 and u2 with the same device id and txn id are independent transactions" do
    w = world!()
    bob = TD.user!("TDB")
    TD.share!(w.u1, bob)
    TD.share!(w.u2, bob)
    t = TD.txn()
    TD.send!(w.u1, "m.dummy", t, TD.msg(bob, %{"from" => "u1"}))
    TD.send!(w.u2, "m.dummy", t, TD.msg(bob, %{"from" => "u2"}))
    assert Enum.sort(Enum.map(TD.events(TD.sync(bob)), & &1["content"]["from"])) == ["u1", "u2"]
    assert {TD.txn_count(w.u1.uid, w.id), TD.txn_count(w.u2.uid, w.id)} == {1, 1}
  end

  test "`*` of u1 and an explicit {u2, id} entry in one request: each user's devices get their own copy, nothing crosses" do
    w = world!()
    TD.send!(w.alice, "m.dummy", TD.txn(), TD.merge([TD.star(w.u1, %{"n" => 1}), TD.msg(w.u2, %{"n" => 2})]))
    assert {ns(TD.sync(w.u1)), ns(TD.sync(w.u1b)), ns(TD.sync(w.u2))} == {[1], [1], [2]}
  end

  test "a send from u1's device `id` never excludes u2's device of that id from a `*` to u2 (the sending device is excluded per USER)" do
    w = world!()
    TD.share!(w.u1, w.u2)
    TD.send!(w.u1, "m.dummy", TD.txn(), TD.star(w.u2, %{"n" => 1}))
    assert ns(TD.sync(w.u2)) == [1]
  end
end
