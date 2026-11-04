defmodule Nebu.Matrix.ToDeviceSenderBudgetTest do
  @moduledoc """
  Acceptance tests for story `to-device-messaging` (epic e2ee-client-support, REQ-2026-012), cycle 1 after the Kassandra review (HIGH #1, MEDIUM #2) and the orchestrator decisions:

    * PER-SENDER TOTAL BUDGET across ALL recipients: 4000 messages and 16 MiB (seams `:to_device_max_per_sender_total`, `:to_device_max_bytes_per_sender_total`); beyond it the sender's OWN
      oldest rows go first, whichever recipient they are queued for; another sender is unaffected. (Before: every cap was per recipient, one account could store 4 MiB x the number of users it
      shares a joined room with.)
    * BYTE-COST RATE BUCKET per sender: 4 MiB per minute, burst 8 MiB (seams `:to_device_rate_bytes_per_min`, `:to_device_rate_bytes_burst`), node-local (N x in a cluster). It is charged with the
      bytes the request ASKS to fan out (an explicit device: content + 128; a `*`: what it could reach, `max_targets` rows, never above the 1 MiB fan-out budget), NOT with the accepted bytes:
      an accepted-bytes cost would tell a delivered recipient from a skipped one by the 429 (no oracle). A refusal is `429 M_LIMIT_EXCEEDED` with `retry_after_ms`, the transaction is
      rolled back (the txn id is not burnt), a cost above the burst is charged as the burst (a request is never unsatisfiable).
    * PER SENDER AND DEVICE a BYTE share of 1 MiB (the count share of 100 stays).
    * The DEVICE queue (500 messages / 8 MiB) is evicted FAIRLY like the user queue: the oldest message of the sender with the LARGEST share goes first, so two colluding co-members cannot evict
      a victim sender's older messages from a victim device.

  The defaults are pinned by `to_device_routes_test.exs` (`ToDeviceStore.limits/0`).
  """
  use ExUnit.Case, async: false

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

  defp sender_for!(bob) do
    s = TD.user!("TDS")
    TD.share!(s, bob)
    s
  end

  # `n` recipients (one device each), all sharing a joined room with `sender`
  defp recipients!(sender, n), do: for(_ <- 1..n, do: (u = TD.user!("TDR"); TD.share!(sender, u); u))

  defp ns(body), do: Enum.map(TD.events(body), & &1["content"]["n"])
  defp peek(device), do: ns(TD.sync(device))

  # equal byte size whatever the number (the pad shrinks as the number grows)
  defp content(n, pad \\ 200), do: %{"n" => n, "pad" => String.duplicate("b", pad - String.length(Integer.to_string(n)))}

  # ═══ the per-sender total ═════════════════════════════════════════════════════════════════════════════════════════════════════

  describe "per SENDER over ALL recipients: 4000 messages / 16 MiB (the sender's own oldest go first, any recipient)" do
    test "message budget (seam 25): 60 sends over 6 users keep the newest 25 of the send order" do
      alice = TD.user!("TDA")
      users = recipients!(alice, 6)
      TD.seam(:max_per_sender_total, 25)

      for round <- 1..10, {u, i} <- Enum.with_index(users), do: TD.tell!(alice, u, "m.dummy", %{"n" => (round - 1) * 6 + i + 1})

      assert TD.sent_count(alice.uid) == 25
      kept = Enum.flat_map(users, &peek/1) |> Enum.sort()
      assert kept == Enum.to_list(36..60), "the newest 25 sends survive, whichever user they were queued for"
    end

    test "byte budget: exactly ten rows fit, one byte less keeps nine (budget over all recipients)" do
      alice = TD.user!("TDA")
      users = recipients!(alice, 3)
      cost = TD.cost(content(1))

      TD.seam(:max_bytes_per_sender_total, 10 * cost)
      for n <- 1..15, do: TD.tell!(alice, Enum.at(users, rem(n, 3)), "m.dummy", content(n))
      assert TD.sent_count(alice.uid) == 10

      TD.seam(:max_bytes_per_sender_total, 10 * cost - 1)
      TD.tell!(alice, hd(users), "m.dummy", content(16))
      assert TD.sent_count(alice.uid) == 9
    end

    test "a SECOND sender is unaffected by the first one's flood and by its eviction (own total, own rows)" do
      alice = TD.user!("TDA")
      users = recipients!(alice, 3)
      carol = TD.user!("TDK")
      TD.share!(carol, hd(users))
      TD.seam(:max_per_sender_total, 6)

      for n <- 1..4, do: TD.tell!(carol, hd(users), "m.dummy", %{"n" => -n})
      for n <- 1..20, do: TD.tell!(alice, Enum.at(users, rem(n, 3)), "m.dummy", %{"n" => n})

      assert {TD.sent_count(alice.uid), TD.sent_count(carol.uid)} == {6, 4}
      assert Enum.filter(peek(hd(users)), &(&1 < 0)) == [-1, -2, -3, -4]
    end

    test "the total counts the SENDER's rows only, other senders' rows at the same recipient do not count" do
      alice = TD.user!("TDA")
      bob = TD.user!("TDB")
      TD.share!(alice, bob)
      carol = sender_for!(bob)
      TD.seam(:max_per_sender_total, 3)
      for n <- 1..10, do: TD.tell!(carol, bob, "m.dummy", %{"n" => 100 + n})
      for n <- 1..3, do: TD.tell!(alice, bob, "m.dummy", %{"n" => n})
      assert {TD.sent_count(alice.uid), TD.sent_count(carol.uid)} == {3, 3}
    end

    test "the eviction is silent: every answer is the identical 200 {} (no 429 for the sender's own state)" do
      alice = TD.user!("TDA")
      [u] = recipients!(alice, 1)
      TD.seam(:max_per_sender_total, 2)
      answers = for n <- 1..6, do: TD.put_send(alice, "m.dummy", TD.txn(), TD.msg(u, %{"n" => n}))
      assert Enum.all?(answers, &({&1.status, &1.resp_body} == {200, "{}"}))
    end
  end

  # ═══ the sender's byte share per device ═══════════════════════════════════════════════════════════════════════════════════════

  describe "per SENDER and recipient device: a byte share of 1 MiB next to the 100 messages" do
    test "the seam (exact fit): three rows fit, one byte less keeps two; another sender at the same device is untouched" do
      f = pair!()
      carol = sender_for!(f.bob1)
      cost = TD.cost(content(1))
      TD.tell!(carol, f.bob1, "m.dummy", content(-1))

      TD.seam(:max_bytes_per_sender_device, 3 * cost)
      for n <- 1..5, do: TD.tell!(f.alice, f.bob1, "m.dummy", content(n))
      assert Enum.filter(peek(f.bob1), &(&1 > 0)) == [3, 4, 5]

      TD.seam(:max_bytes_per_sender_device, 3 * cost - 1)
      TD.tell!(f.alice, f.bob1, "m.dummy", content(6))
      assert Enum.filter(peek(f.bob1), &(&1 > 0)) == [5, 6]
      assert Enum.filter(peek(f.bob1), &(&1 < 0)) == [-1]
    end

    test "the DEFAULT: a sender holds at most 1 MiB of 60 000-byte messages (17) per device, whatever the 100 message share" do
      f = pair!()
      big = fn n -> %{"n" => n, "pad" => String.duplicate("x", 60_000 - 20)} end
      fit = div(TD.defaults().max_bytes_per_sender_device, TD.cost(big.(1)))
      assert fit in 15..18
      for n <- 1..(fit + 5), do: TD.tell!(f.alice, f.bob1, "m.dummy", big.(n))
      assert TD.queue_count(f.bob1.uid, f.bob1.dev) == fit
    end
  end

  defp pair! do
    alice = TD.user!("TDA")
    bob1 = TD.user!("TDB")
    bob2 = TD.device!(bob1, "TDC")
    TD.share!(alice, bob1)
    %{alice: alice, bob1: bob1, bob2: bob2}
  end

  # ═══ fair eviction at the DEVICE level ════════════════════════════════════════════════════════════════════════════════════════

  describe "the DEVICE cap is fair: the largest sender share loses its oldest first (two colluding co-members cannot evict a victim)" do
    test "cap 10: a victim's 3 older messages survive two flooders of 8, the floods are cut older first" do
      f = pair!()
      victim = sender_for!(f.bob1)
      flooder2 = sender_for!(f.bob1)
      TD.seam(:max_per_device, 10)
      for n <- 1..3, do: TD.tell!(victim, f.bob1, "m.dummy", %{"n" => -n})

      for n <- 1..8 do
        TD.tell!(f.alice, f.bob1, "m.dummy", %{"n" => n})
        TD.tell!(flooder2, f.bob1, "m.dummy", %{"n" => 100 + n})
      end

      assert TD.queue_count(f.bob1.uid, f.bob1.dev) == 10
      assert peek(f.bob1) == [-1, -2, -3, 105, 6, 106, 7, 107, 8, 108]
    end

    test "byte budget (ten rows): the same two flooders against a victim below its share" do
      f = pair!()
      victim = sender_for!(f.bob1)
      flooder2 = sender_for!(f.bob1)
      TD.seam(:max_bytes_per_device, 10 * TD.cost(content(1)))
      for n <- 1..3, do: TD.tell!(victim, f.bob1, "m.dummy", content(-n))

      for n <- 1..8 do
        TD.tell!(f.alice, f.bob1, "m.dummy", content(n))
        TD.tell!(flooder2, f.bob1, "m.dummy", content(100 + n))
      end

      assert TD.queue_count(f.bob1.uid, f.bob1.dev) == 10
      assert Enum.take(peek(f.bob1), 3) == [-1, -2, -3]
    end

    test "byte budget boundary: exactly ten rows fit, one byte less keeps nine (fair order)" do
      f = pair!()
      flooder = sender_for!(f.bob1)
      TD.seam(:max_bytes_per_device, 10 * TD.cost(content(1)) - 1)
      for n <- 1..4, do: TD.tell!(flooder, f.bob1, "m.dummy", content(-n))
      for n <- 1..9, do: TD.tell!(f.alice, f.bob1, "m.dummy", content(n))
      assert TD.queue_count(f.bob1.uid, f.bob1.dev) == 9
      assert Enum.take(peek(f.bob1), 4) == [-1, -2, -3, -4]
    end

    test "the sender with the LARGEST share is evicted at the device level, not the newcomer" do
      f = pair!()
      big = sender_for!(f.bob1)
      TD.seam(:max_per_device, 10)
      for n <- 1..8, do: TD.tell!(big, f.bob1, "m.dummy", %{"n" => n})
      for n <- 101..104, do: TD.tell!(f.alice, f.bob1, "m.dummy", %{"n" => n})
      assert peek(f.bob1) == [3, 4, 5, 6, 7, 8, 101, 102, 103, 104]
    end

    test "cap 11: the cut falls inside a tie of shares, the older row of the tied pair goes first" do
      f = pair!()
      victim = sender_for!(f.bob1)
      flooder2 = sender_for!(f.bob1)
      TD.seam(:max_per_device, 11)
      for n <- 1..2, do: TD.tell!(victim, f.bob1, "m.dummy", %{"n" => -n})

      for n <- 1..8 do
        TD.tell!(f.alice, f.bob1, "m.dummy", %{"n" => n})
        TD.tell!(flooder2, f.bob1, "m.dummy", %{"n" => 100 + n})
      end

      assert peek(f.bob1) == [-1, -2, 104, 5, 105, 6, 106, 7, 107, 8, 108]
    end

    test "a single sender over the device cap: plain oldest first" do
      f = pair!()
      TD.seam(:max_per_device, 4)
      for n <- 1..7, do: TD.tell!(f.alice, f.bob1, "m.dummy", %{"n" => n})
      assert peek(f.bob1) == [4, 5, 6, 7]
    end
  end

  # ═══ the byte-cost rate bucket ════════════════════════════════════════════════════════════════════════════════════════════════

  describe "the byte-cost rate bucket: 4 MiB per minute, burst 8 MiB per sender (charged with the bytes the request asks to fan out)" do
    setup do
      TD.enable_rate_limit()
      :ok
    end

    test "burst of three rows: the fourth send is 429, nothing stored, the txn id is usable after the refill" do
      f = pair!()
      c = content(1)
      TD.seam(:rate_bytes_burst, 3 * TD.cost(c))
      TD.seam(:rate_bytes_per_min, 6 * TD.cost(c))

      for n <- 1..3, do: TD.send!(f.alice, "m.dummy", TD.txn(), TD.msg(f.bob1, content(n)))
      t = TD.txn()
      refused = TD.put_send(f.alice, "m.dummy", t, TD.msg(f.bob1, content(4)))
      TD.assert_429(refused, "the byte bucket")
      assert TD.json(refused)["retry_after_ms"] == 10_000, "one missing row at 6 rows per minute: 10 s (not a fixed second)"
      assert Plug.Conn.get_resp_header(refused, "retry-after") in [[], ["10"]]
      assert TD.queue_count(f.bob1.uid, f.bob1.dev) == 3
      assert TD.txn_count(f.alice.uid, f.alice.dev) == 3, "the refused request recorded no transaction"

      TD.set_clock(5_010_000)
      TD.send!(f.alice, "m.dummy", t, TD.msg(f.bob1, content(4)))
      assert TD.queue_count(f.bob1.uid, f.bob1.dev) == 4, "the same txn id works after the refill"
    end

    test "the refill is exact: 999 ms still 429, 1000 ms passes (one row per second)" do
      f = pair!()
      c = content(1)
      TD.seam(:rate_bytes_burst, 2 * TD.cost(c))
      TD.seam(:rate_bytes_per_min, 60 * TD.cost(c))
      for n <- 1..2, do: TD.send!(f.alice, "m.dummy", TD.txn(), TD.msg(f.bob1, content(n)))
      TD.assert_429(TD.put_send(f.alice, "m.dummy", TD.txn(), TD.msg(f.bob1, content(3))), "drained")
      TD.set_clock(5_000_999)
      TD.assert_429(TD.put_send(f.alice, "m.dummy", TD.txn(), TD.msg(f.bob1, content(3))), "999 ms")
      TD.set_clock(5_001_000)
      TD.send!(f.alice, "m.dummy", TD.txn(), TD.msg(f.bob1, content(3)))
    end

    test "no oracle: delivered, unknown, unshared and unknown-device targets are all refused at the same request" do
      f = pair!()
      carol = TD.user!("TDK")
      c = content(1)
      TD.seam(:rate_bytes_burst, 3 * TD.cost(c))
      TD.seam(:rate_bytes_per_min, 60 * TD.cost(c))

      targets = [
        {"delivered", fn _s -> TD.msg(f.bob1, c) end},
        {"unknown user", fn _s -> TD.msg({"@nobody-#{T.rand(4)}:test.local", "D"}, c) end},
        {"unshared user", fn _s -> TD.msg(carol, c) end},
        {"unknown device", fn _s -> TD.msg({f.bob1.uid, "NOPE"}, c) end}
      ]

      for {label, messages} <- targets do
        sender = TD.user!("TDS")
        TD.share!(sender, f.bob1)
        statuses = for _ <- 1..4, do: TD.put_send(sender, "m.dummy", TD.txn(), messages.(sender)).status
        assert statuses == [200, 200, 200, 429], "#{label}: #{inspect(statuses)}"
      end
    end

    test "a `*` costs what it could reach: with 4 targets a burst of 8 rows takes two and refuses the third" do
      f = pair!()
      c = content(1)
      TD.seam(:max_targets_per_request, 4)
      TD.seam(:rate_bytes_burst, 8 * TD.cost(c))
      TD.seam(:rate_bytes_per_min, 60 * TD.cost(c))
      statuses = for n <- 1..3, do: TD.put_send(f.alice, "m.dummy", TD.txn(), TD.star(f.bob1, content(n))).status
      assert statuses == [200, 200, 429]
    end

    test "defaults: a `*` is charged at most 1 MiB: eight pass, the ninth is refused until 15 s later" do
      f = pair!()
      c = %{"pad" => String.duplicate("q", 11_000)}
      # row = 11 000 + 128 per target, 100 targets = 1.1 MB: capped at the fan-out budget of 1 MiB = 1 048 576 bytes per request
      for n <- 1..8, do: TD.send!(f.alice, "m.dummy", TD.txn(), TD.star(f.bob1, Map.put(c, "n", n)))
      TD.assert_429(TD.put_send(f.alice, "m.dummy", TD.txn(), TD.star(f.bob1, c)), "the ninth fan-out of 1 MiB")
      TD.set_clock(5_000_000 + 14_999)
      TD.assert_429(TD.put_send(f.alice, "m.dummy", TD.txn(), TD.star(f.bob1, c)), "14.999 s: 4 MiB per minute give back 1 MiB after 15 s")
      TD.set_clock(5_000_000 + 15_000)
      TD.send!(f.alice, "m.dummy", TD.txn(), TD.star(f.bob1, c))
    end

    test "a request above the burst is charged as the burst: it passes once, the next is refused" do
      f = pair!()
      TD.seam(:rate_bytes_burst, 1_000)
      big = %{"pad" => String.duplicate("z", 60_000)}
      TD.send!(f.alice, "m.dummy", TD.txn(), TD.msg(f.bob1, big))
      TD.assert_429(TD.put_send(f.alice, "m.dummy", TD.txn(), TD.msg(f.bob1, big)), "second")
    end

    test "the bucket belongs to the sender: another sender is unaffected, an empty request costs nothing" do
      f = pair!()
      carol = sender_for!(f.bob1)
      c = content(1)
      TD.seam(:rate_bytes_burst, TD.cost(c))
      TD.seam(:rate_bytes_per_min, 60 * TD.cost(c))
      TD.send!(f.alice, "m.dummy", TD.txn(), TD.msg(f.bob1, c))
      TD.assert_429(TD.put_send(f.alice, "m.dummy", TD.txn(), TD.msg(f.bob1, c)), "alice")
      assert TD.put_send(f.alice, "m.dummy", TD.txn(), %{}).status == 200, "an empty request costs no bytes"
      assert TD.put_send(carol, "m.dummy", TD.txn(), TD.msg(f.bob1, c)).status == 200
    end

    test "a duplicate (retried) transaction is not charged again" do
      f = pair!()
      c = content(1)
      TD.seam(:rate_bytes_burst, 2 * TD.cost(c))
      TD.seam(:rate_bytes_per_min, 60 * TD.cost(c))
      t = TD.txn()
      for _ <- 1..5, do: TD.send!(f.alice, "m.dummy", t, TD.msg(f.bob1, c))
      TD.send!(f.alice, "m.dummy", TD.txn(), TD.msg(f.bob1, content(2)))
    end

    test "the 429 rolls the request back: queue and records stay exactly as before" do
      f = pair!()
      c = content(1)
      TD.seam(:rate_bytes_burst, TD.cost(c))
      TD.seam(:rate_bytes_per_min, 60 * TD.cost(c))
      TD.send!(f.alice, "m.dummy", TD.txn(), TD.msg(f.bob1, c))
      before = {TD.queue_count(f.bob1.uid), TD.txn_count(f.alice.uid), TD.sent_count(f.alice.uid)}
      for _ <- 1..3, do: TD.assert_429(TD.put_send(f.alice, "m.dummy", TD.txn(), TD.msg(f.bob1, c)), "refused")
      assert {TD.queue_count(f.bob1.uid), TD.txn_count(f.alice.uid), TD.sent_count(f.alice.uid)} == before
    end
  end
end
