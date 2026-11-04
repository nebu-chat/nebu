defmodule Nebu.Matrix.ToDevicePurgeTest do
  @moduledoc """
  Acceptance tests for story `to-device-messaging` (epic e2ee-client-support, REQ-2026-012): the LIFECYCLE of the queue.

  Gherkin scenario 5 ("deleting a device drops its queued messages") and the oracle behaviours 16 and 17:

    * DEVICE REMOVAL: `DELETE /devices/{id}`, `POST /delete_devices`, `POST /logout`, `POST /logout/all`, the admin device revoke (`Nebu.Matrix.delete_user_device/2`), the OAuth logout
      and the admin deactivation purge the queued messages AND the idempotency records of the removed device(s) (they go through `DeviceKeyStore.delete_device`, one place). Other devices of
      the user, other users, and the messages the removed device SENT (they live in the recipients' queues) are untouched. A device created later with the same id starts with an empty queue,
      and a device that does not exist (any more) is skipped by the sender like an unknown one.
    * TTL: a message older than 7 days is never delivered (decided by the delivery itself, the sweep is housekeeping only), an idempotency record is kept 24 hours. The sweep is the Oban cron
      worker `Nebu.Workers.ToDevicePurgeWorker` (the pattern of the other periodic cleanups: Cron enqueues from the leader, the purge is batched atomic SQL that concurrent runs split between
      them, no node-local state): one `perform/1` purges any backlog (batched inside), removes exactly the expired rows and returns `:ok`; two concurrent runs lose nothing and delete nothing fresh.
  """
  use ExUnit.Case, async: false

  alias Nebu.Matrix.ModerationTestSupport, as: S
  alias Nebu.Matrix.ToDeviceTestSupport, as: TD
  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration
  @worker Nebu.Workers.ToDevicePurgeWorker
  @day 86_400

  setup do
    T.reset_rate_limits()
    Nebu.Test.ServerName.pin!(T.server_name())
    TD.disable_rate_limit()
    T.put_env_scoped(:uia_fresh_auth_seconds, 86_400)
    on_exit(fn -> T.restore_rate_limits() end)
    :ok
  end

  # alice (sender), bob with devices B1 and B2 (each has two messages queued by alice; B1 sent one message to alice, so it has an idempotency record)
  defp world! do
    alice = TD.user!("TDA")
    bob1 = TD.user!("TDB")
    bob2 = TD.device!(bob1, "TDC")
    TD.share!(alice, bob1)
    for n <- 1..2, do: TD.tell!(alice, bob1, "m.dummy", %{"n" => n})
    for n <- 3..4, do: TD.tell!(alice, bob2, "m.dummy", %{"n" => n})
    TD.tell!(bob1, alice, "m.dummy", %{"from" => "bob1"})
    assert {TD.queue_count(bob1.uid, bob1.dev), TD.queue_count(bob2.uid, bob2.dev), TD.txn_count(bob1.uid, bob1.dev)} == {2, 2, 1}
    %{alice: alice, bob1: bob1, bob2: bob2}
  end

  defp assert_purged(w) do
    assert TD.queue_count(w.bob1.uid, w.bob1.dev) == 0, "the queue of the removed device is gone"
    assert TD.txn_count(w.bob1.uid, w.bob1.dev) == 0, "its idempotency records are gone"
  end

  defp assert_others_intact(w) do
    assert TD.queue_count(w.bob2.uid, w.bob2.dev) == 2, "the other device of the user keeps its queue"
    assert TD.queue_count(w.alice.uid) == 1, "the message the removed device SENT stays in the recipient's queue"
  end

  # ═══ Scenario 5: device removal ═════════════════════════════════════════════════════════════════════════════════════════════

  describe "Scenario 5 - deleting a device drops its queued messages" do
    test "Gherkin: DELETE /devices/{id} (by another device of the user): the queue and the txn records of that device are deleted, the others stay" do
      w = world!()
      assert T.matrix_request(:delete, "/_matrix/client/v3/devices/" <> w.bob1.dev, w.bob2.at, body: %{}).status == 200
      assert_purged(w)
      assert_others_intact(w)
    end

    test "POST /delete_devices removes the queues of every listed device, not of the unlisted ones" do
      w = world!()
      assert T.matrix_request(:post, "/_matrix/client/v3/delete_devices", w.bob2.at, body: %{"devices" => [w.bob1.dev]}).status == 200
      assert_purged(w)
      assert_others_intact(w)
    end

    test "POST /logout (the device's own token) ends that device only" do
      w = world!()
      assert T.matrix_request(:post, "/_matrix/client/v3/logout", w.bob1.at, body: %{}).status == 200
      assert_purged(w)
      assert_others_intact(w)
    end

    test "POST /logout/all removes the queues and records of every device of the user, and of nobody else" do
      w = world!()
      carol = TD.user!("TDK")
      TD.share!(w.alice, carol)
      TD.tell!(w.alice, carol, "m.dummy", %{"n" => 9})

      assert T.matrix_request(:post, "/_matrix/client/v3/logout/all", w.bob2.at, body: %{}).status == 200
      assert TD.queue_count(w.bob1.uid) == 0
      assert TD.txn_count(w.bob1.uid) == 0
      assert TD.queue_count(carol.uid) == 1, "another user's queue is untouched"
      assert TD.queue_count(w.alice.uid) == 1, "what bob sent stays"
    end

    test "the admin device revoke (Nebu.Matrix.delete_user_device/2, the function behind the Admin UI) purges the device's queue" do
      w = world!()
      assert :ok = Nebu.Matrix.delete_user_device(w.bob1.uid, w.bob1.dev)
      assert_purged(w)
      assert_others_intact(w)
    end

    test "an admin DEACTIVATION is reversible: the queue is kept (until the TTL), nothing new is queued for the inactive user, and a reactivation resumes" do
      w = world!()
      carol = TD.user!("TDK")
      TD.share!(w.alice, carol)
      TD.tell!(w.alice, carol, "m.dummy", %{"n" => 9})

      admin = %{http_request_headers: %{"x-user-id" => "@admin:test.local", "x-system-role" => "admin"}}
      assert %Core.DeactivateUserResponse{ok: true} = Nebu.Matrix.EventDispatcher.Server.deactivate_user(%Core.DeactivateUserRequest{user_id: w.bob1.uid}, admin)
      assert {TD.queue_count(w.bob1.uid, w.bob1.dev), TD.queue_count(w.bob2.uid, w.bob2.dev)} == {2, 2}, "the queue stays: a deactivation is reversible (the erasure deletes it)"

      baseline = TD.shape(TD.put_send(w.alice, "m.dummy", TD.txn(), TD.msg(carol, %{"n" => 10})))
      carol_rows = TD.queue_count(carol.uid)
      c = TD.put_send(w.alice, "m.dummy", TD.txn(), TD.star(w.bob1, %{"n" => 10}))
      assert TD.shape(c) == baseline, "the sender is not told that the recipient is inactive (status, body and headers equal a delivered request)"
      assert elem(baseline, 0) == 200
      assert TD.queue_count(w.bob1.uid) == 4, "nothing is queued for a deactivated user"
      assert TD.queue_count(carol.uid) == carol_rows, "other users are untouched"

      assert %Core.ReactivateUserResponse{ok: true} = Nebu.Matrix.EventDispatcher.Server.reactivate_user(%Core.ReactivateUserRequest{user_id: w.bob1.uid}, admin)
      TD.send!(w.alice, "m.dummy", TD.txn(), TD.star(w.bob1, %{"n" => 11}))
      assert TD.queue_count(w.bob1.uid) == 6
    end

    test "the removed device's token is dead and sending to it afterwards is skipped silently (identical 200 {}), nothing is queued" do
      w = world!()
      assert T.matrix_request(:post, "/_matrix/client/v3/logout", w.bob1.at, body: %{}).status == 200
      c = TD.put_send(w.alice, "m.dummy", TD.txn(), TD.msg(w.bob1, %{"n" => 5}))
      assert {c.status, c.resp_body} == {200, "{}"}
      assert TD.queue_count(w.bob1.uid, w.bob1.dev) == 0
      assert TD.sync_conn(w.bob1, timeout: 0).status == 401
    end

    test "a device re-created with the SAME id starts with an empty queue (nothing of the old life is delivered)" do
      w = world!()
      assert T.matrix_request(:delete, "/_matrix/client/v3/devices/" <> w.bob1.dev, w.bob2.at, body: %{}).status == 200
      reborn = %{w.bob1 | at: T.legacy_session!(w.bob1.uid, w.bob1.dev, expires_at: S.session_expiry()).at}
      :ok = Nebu.Matrix.DeviceKeyStore.upsert_device(reborn.uid, reborn.dev)

      assert TD.events(TD.sync(reborn)) == []
      TD.tell!(w.alice, reborn, "m.dummy", %{"n" => 6})
      assert Enum.map(TD.events(TD.sync(reborn)), & &1["content"]["n"]) == [6]
    end

    test "IDOR: deleting ANOTHER user's device is refused (404) and its queue is not purged" do
      w = world!()
      mallory = TD.user!("TDM")
      c = T.matrix_request(:delete, "/_matrix/client/v3/devices/" <> w.bob1.dev, mallory.at, body: %{})
      assert c.status == 404
      assert TD.queue_count(w.bob1.uid, w.bob1.dev) == 2
      c = T.matrix_request(:post, "/_matrix/client/v3/delete_devices", mallory.at, body: %{"devices" => [w.bob1.dev]})
      assert c.status == 200, "a foreign device id in delete_devices is skipped silently"
      assert TD.queue_count(w.bob1.uid, w.bob1.dev) == 2, "a foreign device id in delete_devices deletes nothing"
    end

    test "deleting a device that does not exist is idempotent and touches no queue" do
      w = world!()
      assert T.matrix_request(:delete, "/_matrix/client/v3/devices/NO-SUCH-" <> T.rand(3), w.bob2.at, body: %{}).status == 200
      assert {TD.queue_count(w.bob1.uid, w.bob1.dev), TD.queue_count(w.bob2.uid, w.bob2.dev)} == {2, 2}
    end

    test "an OAuth device (an OAuth session): the OAuth logout purges its queue too (the teardown inside the transaction)" do
      T.enable_oauth()
      priv = T.setup_idp!()
      cid = T.oauth_client!(["https://app.example.com/cb"])
      on_exit(&T.clear_oauth_config/0)

      dev = "TDO" <> String.upcase(T.rand(3))
      s = T.session!(cid, "https://app.example.com/cb", priv, authorize: %{"scope" => T.matrix_scope(T.stable_prefix(), dev)})
      oauth_dev = %{uid: s.user_id, dev: dev, at: s.at}
      alice = TD.user!("TDA")
      TD.share!(alice, oauth_dev)
      TD.tell!(alice, oauth_dev, "m.dummy", %{"n" => 1})
      assert TD.queue_count(oauth_dev.uid, oauth_dev.dev) == 1

      assert T.matrix_request(:post, "/_matrix/client/v3/logout", oauth_dev.at, body: %{}).status == 200
      assert TD.queue_count(oauth_dev.uid, oauth_dev.dev) == 0
    end

    test "revoking only the SESSIONS of an OAuth device (refresh-token reuse; the device and its keys stay) keeps the queue: the client resumes with it" do
      T.enable_oauth()
      priv = T.setup_idp!()
      cid = T.oauth_client!(["https://app.example.com/cb"])
      on_exit(&T.clear_oauth_config/0)

      dev = "TDO" <> String.upcase(T.rand(3))
      s = T.session!(cid, "https://app.example.com/cb", priv, authorize: %{"scope" => T.matrix_scope(T.stable_prefix(), dev)})
      oauth_dev = %{uid: s.user_id, dev: dev, at: s.at}
      alice = TD.user!("TDA")
      TD.share!(alice, oauth_dev)
      TD.tell!(alice, oauth_dev, "m.dummy", %{"n" => 1})

      assert :ok = Nebu.Matrix.oauth_revoke_device_session(oauth_dev.uid, oauth_dev.dev)
      assert T.sql!("SELECT count(*) FROM devices WHERE user_id = $1 AND device_id = $2", [oauth_dev.uid, oauth_dev.dev]).rows == [[1]], "the device stays"
      assert TD.queue_count(oauth_dev.uid, oauth_dev.dev) == 1, "so does its queue (only the DEVICE's removal purges it)"
    end
  end

  # ═══ TTL ═════════════════════════════════════════════════════════════════════════════════════════════════════════════════════

  describe "oracle behaviour 17: messages older than 7 days are gone, fresh ones are untouched" do
    test "delivery never returns an expired message, with no sweep having run (the TTL is decided by the read)" do
      f = world!()
      TD.age_queue!(f.bob1.uid, f.bob1.dev, 7 * @day + 60)
      assert TD.events(TD.sync(f.bob1)) == [], "older than 7 days: not delivered"
      assert Enum.map(TD.events(TD.sync(f.bob2)), & &1["content"]["n"]) == [3, 4]
    end

    test "6 days 23 hours old is still delivered (the boundary is 7 days)" do
      f = world!()
      TD.age_queue!(f.bob1.uid, f.bob1.dev, 7 * @day - 3600)
      assert Enum.map(TD.events(TD.sync(f.bob1)), & &1["content"]["n"]) == [1, 2]
    end

    test "an expired message does not end a long poll (it is not pending): the poll waits for its timeout" do
      f = world!()
      TD.age_queue!(f.bob1.uid, f.bob1.dev, 8 * @day)
      since = TD.next(TD.sync(f.bob1))
      started = System.monotonic_time(:millisecond)
      body = TD.sync(f.bob1, since, timeout: 700)
      assert TD.events(body) == []
      assert System.monotonic_time(:millisecond) - started >= 500
    end

    test "the TTL seam (:to_device_ttl_seconds) moves the boundary" do
      f = world!()
      TD.seam(:ttl_seconds, 3600)
      TD.age_queue!(f.bob1.uid, f.bob1.dev, 7200)
      assert TD.events(TD.sync(f.bob1)) == []
      assert length(TD.events(TD.sync(f.bob2))) == 2
    end
  end

  describe "the purge worker" do
    test "wiring: an Oban cron entry runs Nebu.Workers.ToDevicePurgeWorker, queue oauth_cleanup (the existing limit-1 housekeeping queue), max_attempts 3" do
      oban = Application.get_env(:nebu, Oban)
      {_plugin, cron_opts} = Enum.find(oban[:plugins], fn {mod, _} -> mod == Oban.Plugins.Cron end)
      assert Enum.any?(cron_opts[:crontab], fn {_expr, worker} -> worker == @worker end), "no cron entry for #{inspect(@worker)}"
      assert Code.ensure_loaded?(@worker), "#{inspect(@worker)} is missing"
      opts = apply(@worker, :__opts__, [])
      assert to_string(opts[:queue]) == "oauth_cleanup"
      assert opts[:max_attempts] == 3
    end

    test "perform/1 deletes exactly the expired messages (older than 7 days) and the expired idempotency records (older than 24 hours); fresh ones stay; returns :ok" do
      w = world!()
      TD.age_queue!(w.bob1.uid, w.bob1.dev, 8 * @day)
      TD.age_txns!(w.bob1.uid, w.bob1.dev, 25 * 3600)
      TD.tell!(w.bob2, w.alice, "m.dummy", %{"from" => "bob2"})
      assert TD.txn_count(w.bob2.uid, w.bob2.dev) == 1

      assert :ok = apply(@worker, :perform, [%Oban.Job{}])
      assert TD.queue_count(w.bob1.uid, w.bob1.dev) == 0
      assert TD.txn_count(w.bob1.uid, w.bob1.dev) == 0
      assert TD.queue_count(w.bob2.uid, w.bob2.dev) == 2, "fresh messages are untouched"
      assert TD.txn_count(w.bob2.uid, w.bob2.dev) == 1, "a fresh record is untouched"
      assert TD.queue_count(w.alice.uid) == 2, "alice's queue (sent by bob) is fresh"
    end

    test "a record 23 hours old and a message 6 days old survive the purge" do
      w = world!()
      TD.age_queue!(w.bob1.uid, w.bob1.dev, 6 * @day)
      TD.age_txns!(w.bob1.uid, w.bob1.dev, 23 * 3600)
      assert :ok = apply(@worker, :perform, [%Oban.Job{}])
      assert TD.queue_count(w.bob1.uid, w.bob1.dev) == 2
      assert TD.txn_count(w.bob1.uid, w.bob1.dev) == 1
    end

    test "one run purges a backlog of 12 000 expired rows (batched inside), and a second run finds nothing" do
      f = pair_with_many!(99)
      for n <- 1..120, do: TD.send!(f.alice, "m.dummy", TD.txn(), TD.star(f.many, %{"n" => n}))
      assert TD.queue_count(f.many.uid) == 12_000

      TD.age_user_queue!(f.many.uid, 9 * @day)
      assert :ok = apply(@worker, :perform, [%Oban.Job{}])
      assert TD.queue_count(f.many.uid) == 0
      assert :ok = apply(@worker, :perform, [%Oban.Job{}])
    end

    test "two concurrent runs (two nodes) lose nothing and delete nothing fresh: every expired row is gone, every fresh row stays" do
      f = pair_with_many!(99)
      for n <- 1..30, do: TD.send!(f.alice, "m.dummy", TD.txn(), TD.star(f.many, %{"n" => n}))
      TD.age_user_queue!(f.many.uid, 9 * @day)
      fresh = TD.user!("TDF")
      TD.share!(f.alice, fresh)
      for n <- 1..5, do: TD.tell!(f.alice, fresh, "m.dummy", %{"n" => n})

      results = for _ <- 1..4, do: Task.async(fn -> apply(@worker, :perform, [%Oban.Job{}]) end)
      assert Enum.map(results, &Task.await(&1, 60_000)) == [:ok, :ok, :ok, :ok]
      assert TD.queue_count(f.many.uid) == 0
      assert TD.queue_count(fresh.uid) == 5
    end

    test "the worker keeps no node-local state: the TTL is read from the database clock and the seam, a purge on a node that never sent anything works" do
      w = world!()
      TD.age_queue!(w.bob1.uid, w.bob1.dev, 8 * @day)
      # a fresh process (as another node would be) does the purge
      assert :ok = Task.await(Task.async(fn -> apply(@worker, :perform, [%Oban.Job{}]) end), 30_000)
      assert TD.queue_count(w.bob1.uid, w.bob1.dev) == 0
    end
  end

  # a sender alice and a user with `n` devices (rows in `devices` only) sharing a room, with queue seams raised so that a backlog can build up
  defp pair_with_many!(n) do
    alice = TD.user!("TDA")
    many = TD.user!("TDM")
    TD.share!(alice, many)
    for i <- 1..n, do: :ok = Nebu.Matrix.DeviceKeyStore.upsert_device(many.uid, "MANY#{String.pad_leading(Integer.to_string(i), 3, "0")}")
    TD.seam(:max_per_device, 1_000_000)
    TD.seam(:max_per_sender_device, 1_000_000)
    TD.seam(:max_per_sender_user, 1_000_000)
    TD.seam(:max_per_sender_total, 1_000_000)
    TD.seam(:max_bytes_per_sender_total, 1_000_000_000)
    TD.seam(:max_bytes_per_sender_device, 1_000_000_000)
    TD.seam(:max_bytes_per_sender_user, 1_000_000_000)
    TD.seam(:max_per_user, 1_000_000)
    TD.seam(:max_bytes_per_device, 1_000_000_000)
    TD.seam(:max_bytes_per_user, 1_000_000_000)
    TD.seam(:max_targets_per_request, 1_000)
    %{alice: alice, many: many}
  end
end
