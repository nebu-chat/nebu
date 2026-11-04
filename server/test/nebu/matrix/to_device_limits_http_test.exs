defmodule Nebu.Matrix.ToDeviceLimitsHttpTest do
  @moduledoc """
  Acceptance tests for story `to-device-messaging` (epic e2ee-client-support, REQ-2026-012): the LIMITS. Every per-item cap of the story has an aggregate cap (lesson of the sibling
  story): body 64 KiB and 50 recipient entries per request; per recipient device 500 messages and 8 MiB; per recipient USER 2000 messages and 32 MiB; per SENDER and recipient device
  100 messages (one sender cannot fill another user's queue); at most 100 targets per request (the `*` fan-out); 1000 idempotency records per device; a sender rate limit of 60 per
  minute, burst 30, per USER (tier `to_device`). All seams `:nebu, :to_device_<name>` are read at request time; the defaults are proven by tests of the DEFAULT numbers.

  Decisions pinned here (see the story file, `## Decisions`):

    * A full queue evicts its OLDEST messages (device count, device bytes, user count, user bytes) and the sender is NEVER told: the answer is the same `200 {}`, never a 429 (a 429
      would reveal the recipient's state and let one sender's flood block the others). The count is logged without content.
    * The byte budgets count the canonical JSON bytes of the content plus 128 per row (`TD.cost/1`); exact fit and one byte less are pinned.
    * Rate limiting comes BEFORE any body parse, authentication before both: an exhausted bucket answers 429 for a malformed or oversize body without reading it, a refused request
      (400) still costs its token, a 429 touches no table. The limiter is per user (not per IP) and separate from the other tiers.
    * An oversize or too-wide request is refused whole (413, nothing queued, its txn id not burnt); it is never truncated.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

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

  defp pair! do
    alice = TD.user!("TDA")
    bob1 = TD.user!("TDB")
    bob2 = TD.device!(bob1, "TDC")
    TD.share!(alice, bob1)
    %{alice: alice, bob1: bob1, bob2: bob2}
  end

  defp sender_for!(bob) do
    s = TD.user!("TDS")
    TD.share!(s, bob)
    s
  end

  defp ns(body), do: Enum.map(TD.events(body), & &1["content"]["n"])

  # what a device would be sent now (an initial sync: nothing is acknowledged, at most one batch)
  defp peek(device), do: ns(TD.sync(device))

  # all delivered contents of a device in order (the token chain: acknowledges)
  defp all_ns(device) do
    {events, _} = TD.drain(device, nil)
    Enum.map(events, & &1["content"]["n"])
  end

  # a body of EXACTLY `size` bytes: one message to bob's first device, padded with ASCII (or two-byte characters)
  defp body_of_size(f, size, char \\ "a") do
    prefix = ~s({"messages":{"#{f.bob1.uid}":{"#{f.bob1.dev}":{"p":")
    suffix = ~s("}}}})
    room = size - byte_size(prefix) - byte_size(suffix)
    width = byte_size(char)
    pad = String.duplicate(char, div(room, width)) <> String.duplicate("a", rem(room, width))
    body = prefix <> pad <> suffix
    assert byte_size(body) == size
    body
  end

  # ═══ the request ═════════════════════════════════════════════════════════════════════════════════════════════════════════════

  describe "the request body: at most 64 KiB (413 M_TOO_LARGE)" do
    test "exactly 65 536 bytes is accepted and delivered; 65 537 is 413 M_TOO_LARGE, nothing queued, its txn id not burnt" do
      f = pair!()
      ok = TD.put_send(f.alice, "m.dummy", TD.txn(), {:raw, body_of_size(f, 65_536)})
      assert {ok.status, ok.resp_body} == {200, "{}"}
      assert [%{"content" => %{"p" => pad}}] = TD.events(TD.sync(f.bob1))
      assert byte_size(pad) > 65_000

      t = TD.txn()
      too_big = TD.put_send(f.alice, "m.dummy", t, {:raw, body_of_size(f, 65_537)})
      TD.assert_error(too_big, 413, "M_TOO_LARGE")
      assert TD.queue_count(f.bob1.uid, f.bob1.dev) == 1, "only the first one is queued"
      assert TD.txn_count(f.alice.uid, f.alice.dev) == 1, "the refused request recorded no transaction"

      assert TD.put_send(f.alice, "m.dummy", t, {:raw, body_of_size(f, 1_000)}).status == 200, "the same txn id works with a body that fits"
    end

    test "the limit counts BYTES, not characters: 65 536 bytes of two-byte characters pass, one more byte is 413" do
      f = pair!()
      assert TD.put_send(f.alice, "m.dummy", TD.txn(), {:raw, body_of_size(f, 65_536, "é")}).status == 200
      TD.assert_error(TD.put_send(f.alice, "m.dummy", TD.txn(), {:raw, body_of_size(f, 65_537, "é")}), 413, "M_TOO_LARGE")
    end

    test "a much larger body (2 MB, above the generic 1 MB cap too) is 413 M_TOO_LARGE as well, never 400 / 5xx" do
      f = pair!()
      TD.assert_error(TD.put_send(f.alice, "m.dummy", TD.txn(), {:raw, body_of_size(f, 2_000_000)}), 413, "M_TOO_LARGE")
      assert TD.queue_count(f.bob1.uid) == 0
    end

    test "a body that is too large AND malformed is a 413 (the cap is applied while reading, before the JSON is looked at)" do
      f = pair!()
      TD.assert_error(TD.put_send(f.alice, "m.dummy", TD.txn(), {:raw, "{" <> String.duplicate("x", 70_000)}), 413, "M_TOO_LARGE")
    end

    test "the fan-out sends the body once: a 64 KiB content to `*` of two devices is one request of 64 KiB" do
      f = pair!()
      raw = ~s({"messages":{"#{f.bob1.uid}":{"*":{"p":"#{String.duplicate("a", 65_000)}"}}}})
      assert byte_size(raw) <= 65_536
      assert TD.put_send(f.alice, "m.dummy", TD.txn(), {:raw, raw}).status == 200
      assert TD.queue_count(f.bob1.uid) == 2
    end
  end

  describe "at most 50 recipient entries per request, `*` counts as one (413 M_TOO_LARGE)" do
    defp unknown_entries(n), do: Map.new(1..n, fn i -> {"@nobody#{i}-#{TD.txn()}:test.local", %{"DEV" => %{"i" => i}}} end)

    test "50 entries (unknown recipients count too) pass, 51 are refused WHOLE: not even the real recipient of the request is served" do
      f = pair!()
      c50 = TD.put_send(f.alice, "m.dummy", TD.txn(), unknown_entries(50))
      assert {c50.status, c50.resp_body} == {200, "{}"}

      messages = Map.merge(unknown_entries(50), TD.msg(f.bob1, %{"n" => 1}))
      assert map_size(messages) == 51
      t = TD.txn()
      TD.assert_error(TD.put_send(f.alice, "m.dummy", t, messages), 413, "M_TOO_LARGE")
      assert TD.queue_count(f.bob1.uid) == 0, "no truncation: the request is refused as a whole"
      assert TD.txn_count(f.alice.uid, f.alice.dev) == 1, "the refused request recorded no transaction"
    end

    test "malformed ids count as entries too (no oracle in the count): 51 malformed entries are 413" do
      f = pair!()
      bad = fn n -> Map.new(1..n, fn i -> {"not-a-user-#{i}", %{"D" => %{}}} end) end
      assert TD.put_send(f.alice, "m.dummy", TD.txn(), bad.(50)).status == 200
      TD.assert_error(TD.put_send(f.alice, "m.dummy", TD.txn(), bad.(51)), 413, "M_TOO_LARGE")
    end

    test "entries are (user, device) pairs: 25 users x 2 devices = 50 pass, 26 x 2 = 52 do not" do
      f = pair!()
      two = fn n -> Map.new(1..n, fn i -> {"@nobody#{i}-#{TD.txn()}:test.local", %{"D1" => %{}, "D2" => %{}}} end) end
      assert TD.put_send(f.alice, "m.dummy", TD.txn(), two.(25)).status == 200
      TD.assert_error(TD.put_send(f.alice, "m.dummy", TD.txn(), two.(26)), 413, "M_TOO_LARGE")
    end

    test "`*` counts ONE entry however many devices it expands to: `*` of a user with three devices + 49 others = 50" do
      f = pair!()
      bob3 = TD.device!(f.bob1, "TDD")
      messages = Map.merge(unknown_entries(49), TD.star(f.bob1, %{"n" => 1}))
      assert map_size(messages) == 50
      assert TD.put_send(f.alice, "m.dummy", TD.txn(), messages).status == 200
      assert TD.queue_count(f.bob1.uid) == 3
      assert TD.queue_count(bob3.uid, bob3.dev) == 1
    end

    test "`*` and an explicit device of the same user are TWO entries" do
      f = pair!()
      messages = Map.merge(unknown_entries(49), %{f.bob1.uid => %{"*" => %{}, f.bob1.dev => %{}}})
      TD.assert_error(TD.put_send(f.alice, "m.dummy", TD.txn(), messages), 413, "M_TOO_LARGE")
    end

    test "a user with an EMPTY device object adds no entry: 100 of them still pass" do
      f = pair!()
      empties = Map.new(1..100, fn i -> {"@empty#{i}-#{TD.txn()}:test.local", %{}} end)
      assert TD.put_send(f.alice, "m.dummy", TD.txn(), empties).status == 200
    end
  end

  # ═══ the queue budgets ═══════════════════════════════════════════════════════════════════════════════════════════════════════

  describe "per recipient device: 500 messages (the oldest is evicted, the sender is never told)" do
    test "the DEFAULT: six senders put 504 messages on one device: 500 remain, the 4 oldest are gone, every answer is 200 {}" do
      f = pair!()
      senders = [f.alice | for(_ <- 1..5, do: sender_for!(f.bob1))]

      answers =
        for n <- 1..504 do
          sender = Enum.at(senders, rem(n, 6))
          TD.put_send(sender, "m.dummy", TD.txn(), TD.msg(f.bob1, %{"n" => n}))
        end

      assert Enum.all?(answers, &({&1.status, &1.resp_body} == {200, "{}"})), "never a 429 or an error for the sender of a message to a full queue"
      assert TD.queue_count(f.bob1.uid, f.bob1.dev) == 500
      assert all_ns(f.bob1) == Enum.to_list(5..504)
    end

    test "the seam: with a cap of 5, eight messages leave the NEWEST five, in order" do
      f = pair!()
      TD.seam(:max_per_device, 5)
      for n <- 1..8, do: TD.tell!(f.alice, f.bob1, "m.dummy", %{"n" => n})
      assert TD.queue_count(f.bob1.uid, f.bob1.dev) == 5
      assert peek(f.bob1) == [4, 5, 6, 7, 8]
    end

    test "the cap is per DEVICE: a device that is not full keeps everything; `*` fills each device independently" do
      f = pair!()
      TD.seam(:max_per_device, 3)
      for n <- 1..5, do: TD.send!(f.alice, "m.dummy", TD.txn(), TD.star(f.bob1, %{"n" => n}))
      TD.tell!(f.alice, f.bob2, "m.dummy", %{"n" => 6})
      assert peek(f.bob1) == [3, 4, 5]
      assert peek(f.bob2) == [4, 5, 6]
    end

    test "eviction logs the COUNT without content (a canary in the evicted content never reaches the log)" do
      f = pair!()
      canary = "EVICT-CANARY-" <> T.rand(6)
      for n <- 1..8, do: TD.tell!(f.alice, f.bob1, "m.dummy", %{"n" => n, "secret" => canary})
      TD.seam(:max_per_device, 3)

      log =
        TD.debug_log(fn ->
          TD.tell!(f.alice, f.bob1, "m.dummy", %{"n" => 9, "secret" => canary})
        end)

      assert log =~ ~r/to-device.{0,80}evict\w*.{0,40}\b6\b/i, "the log names the number of evicted messages: #{String.slice(log, 0, 300)}"
      refute log =~ canary
      assert peek(f.bob1) == [7, 8, 9]
    end

    test "already delivered (unacknowledged) messages are evicted like the others, the queue stays within its cap" do
      f = pair!()
      TD.seam(:max_per_device, 4)
      for n <- 1..4, do: TD.tell!(f.alice, f.bob1, "m.dummy", %{"n" => n})
      first = TD.sync(f.bob1)
      assert ns(first) == [1, 2, 3, 4]
      for n <- 5..6, do: TD.tell!(f.alice, f.bob1, "m.dummy", %{"n" => n})
      assert TD.queue_count(f.bob1.uid, f.bob1.dev) == 4
      assert ns(TD.sync(f.bob1, TD.next(first))) == [5, 6]
    end
  end

  describe "per recipient device: 8 MiB (bytes of content + 128 per row)" do
    test "the DEFAULT: 144 messages of 60 000 content bytes (nine senders) leave exactly as many as fit 8 MiB, the oldest are gone" do
      f = pair!()
      senders = [f.alice | for(_ <- 1..8, do: sender_for!(f.bob1))]
      content = fn n -> %{"n" => n, "pad" => String.duplicate("x", 60_000 - 20)} end
      fit = div(TD.defaults().max_bytes_per_device, TD.cost(content.(1)))
      assert fit in 130..145

      # (a sender holds at most 1 MiB = 17 of these per device: nine senders x 16)
      for n <- 1..144 do
        sender = Enum.at(senders, rem(n, 9))
        assert TD.put_send(sender, "m.dummy", TD.txn(), TD.msg(f.bob1, content.(n))).status == 200
      end

      assert TD.queue_count(f.bob1.uid, f.bob1.dev) == fit
      {events, _} = TD.drain(f.bob1, nil, 20)
      assert Enum.map(events, & &1["content"]["n"]) == Enum.to_list((144 - fit + 1)..144)
    end

    test "the seam, exact fit: a budget of exactly four rows keeps four, one byte less keeps three" do
      f = pair!()
      content = fn n -> %{"n" => n, "pad" => String.duplicate("y", 500)} end
      cost = TD.cost(content.(1))

      TD.seam(:max_bytes_per_device, 4 * cost)
      for n <- 1..6, do: TD.tell!(f.alice, f.bob1, "m.dummy", content.(n))
      assert peek(f.bob1) == [3, 4, 5, 6]

      TD.seam(:max_bytes_per_device, 4 * cost - 1)
      TD.tell!(f.alice, f.bob1, "m.dummy", content.(7))
      assert peek(f.bob1) == [5, 6, 7]
    end

    test "the row overhead of 128 bytes counts: a budget of the pure content bytes of four rows keeps fewer than four" do
      f = pair!()
      content = fn n -> %{"n" => n, "pad" => String.duplicate("z", 300)} end
      raw = byte_size(Jason.encode!(content.(1)))
      TD.seam(:max_bytes_per_device, 4 * raw + 100)
      for n <- 1..6, do: TD.tell!(f.alice, f.bob1, "m.dummy", content.(n))
      assert TD.queue_count(f.bob1.uid, f.bob1.dev) == 3, "4 * (content + 128) does not fit 4 * content + 100"
    end
  end

  describe "per recipient USER: 2000 messages / 32 MiB over all devices (the oldest of the user are evicted)" do
    test "the count over devices: a cap of 4 rows for the user keeps the newest four of the user, whichever device they are on" do
      f = pair!()
      TD.seam(:max_per_user, 4)
      targets = [f.bob1, f.bob2]
      for n <- 1..6, do: TD.tell!(f.alice, Enum.at(targets, rem(n, 2)), "m.dummy", %{"n" => n})
      assert TD.queue_count(f.bob1.uid) == 4
      assert peek(f.bob1) == [4, 6]
      assert peek(f.bob2) == [3, 5]
    end

    test "`*` to three devices with a user cap of 6: the oldest message's rows go, every device keeps the two newest messages" do
      f = pair!()
      bob3 = TD.device!(f.bob1, "TDD")
      TD.seam(:max_per_user, 6)
      for n <- 1..3, do: TD.send!(f.alice, "m.dummy", TD.txn(), TD.star(f.bob1, %{"n" => n}))
      assert TD.queue_count(f.bob1.uid) == 6
      for d <- [f.bob1, f.bob2, bob3], do: assert(peek(d) == [2, 3], "device #{d.dev}")
    end

    test "the bytes over devices: a budget of five rows" do
      f = pair!()
      content = fn n -> %{"n" => n, "pad" => String.duplicate("u", 200)} end
      TD.seam(:max_bytes_per_user, 5 * TD.cost(content.(1)))
      for n <- 1..8, do: TD.tell!(f.alice, Enum.at([f.bob1, f.bob2], rem(n, 2)), "m.dummy", content.(n))
      assert TD.queue_count(f.bob1.uid) == 5
      assert peek(f.bob1) == [4, 6, 8]
      assert peek(f.bob2) == [5, 7]
    end

    test "the user byte budget boundary: exactly five rows fit, one byte less keeps four" do
      f = pair!()
      content = fn n -> %{"n" => n, "pad" => String.duplicate("u", 200)} end
      TD.seam(:max_bytes_per_user, 5 * TD.cost(content.(1)) - 1)
      for n <- 1..8, do: TD.tell!(f.alice, Enum.at([f.bob1, f.bob2], rem(n, 2)), "m.dummy", content.(n))
      assert TD.queue_count(f.bob1.uid) == 4
      assert {peek(f.bob1), peek(f.bob2)} == {[6, 8], [5, 7]}
    end

    test "another user's queue is not touched by the budget of this user" do
      f = pair!()
      carol = TD.user!("TDK")
      TD.share!(f.alice, carol)
      TD.seam(:max_per_user, 2)
      TD.tell!(f.alice, carol, "m.dummy", %{"n" => 1})
      for n <- 1..5, do: TD.tell!(f.alice, f.bob1, "m.dummy", %{"n" => n})
      assert TD.queue_count(carol.uid) == 1
      assert TD.queue_count(f.bob1.uid) == 2
    end
  end

  describe "per SENDER and recipient device: 100 messages (one sender cannot fill another user's queue)" do
    test "the DEFAULT: alice sends 120, carol had 5 queued before: alice keeps her newest 100, carol's 5 are untouched" do
      f = pair!()
      carol = sender_for!(f.bob1)
      for n <- 1..5, do: TD.tell!(carol, f.bob1, "m.dummy", %{"n" => -n})
      for n <- 1..120, do: TD.tell!(f.alice, f.bob1, "m.dummy", %{"n" => n})

      assert TD.queue_count(f.bob1.uid, f.bob1.dev) == 105
      assert all_ns(f.bob1) == [-1, -2, -3, -4, -5] ++ Enum.to_list(21..120)
    end

    test "the share is per device: `*` messages of one sender leave 100 on EACH device" do
      f = pair!()
      for n <- 1..105, do: TD.send!(f.alice, "m.dummy", TD.txn(), TD.star(f.bob1, %{"n" => n}))
      assert {TD.queue_count(f.bob1.uid, f.bob1.dev), TD.queue_count(f.bob2.uid, f.bob2.dev)} == {100, 100}
    end

    test "a flooding sender cannot push others out of a FULL queue (cap 5, share 2): it keeps its own last two" do
      f = pair!()
      b = sender_for!(f.bob1)
      c = sender_for!(f.bob1)
      d = sender_for!(f.bob1)
      TD.seam(:max_per_device, 5)
      TD.seam(:max_per_sender_device, 2)

      TD.tell!(f.alice, f.bob1, "m.dummy", %{"n" => 1})
      TD.tell!(f.alice, f.bob1, "m.dummy", %{"n" => 2})
      TD.tell!(b, f.bob1, "m.dummy", %{"n" => 3})
      TD.tell!(b, f.bob1, "m.dummy", %{"n" => 4})
      TD.tell!(c, f.bob1, "m.dummy", %{"n" => 5})
      assert TD.queue_count(f.bob1.uid, f.bob1.dev) == 5, "the queue is full"

      for n <- 6..12, do: TD.tell!(d, f.bob1, "m.dummy", %{"n" => n})

      # d's first two messages fill the device beyond its cap: the device cap is FAIR now (largest share first, older first on a tie): alice's and b's OLDEST (1, 3) go,
      # one each (shares of 2 > the shares of c and d); from the third on d is over its own share and only d's own oldest go. The newest of every earlier sender survive
      # (2, 4, 5), d keeps its newest two.
      assert peek(f.bob1) == [2, 4, 5, 11, 12]
    end

    test "the share is per SENDER USER: two devices of one sender share one allowance" do
      f = pair!()
      alice2 = TD.device!(f.alice, "TDE")
      TD.seam(:max_per_sender_device, 3)
      for n <- 1..4, do: TD.tell!(Enum.at([f.alice, alice2], rem(n, 2)), f.bob1, "m.dummy", %{"n" => n})
      assert peek(f.bob1) == [2, 3, 4]
    end
  end

  # ═══ the fan-out ═════════════════════════════════════════════════════════════════════════════════════════════════════════════

  describe "per SENDER and recipient USER: 200 messages / 4 MiB (the sender's own oldest go first)" do
    test "the DEFAULT: 150 `*` messages to three devices (450 rows): 100 per device, the user share cuts 300 to 200" do
      f = pair!()
      bob3 = TD.device!(f.bob1, "TDD")
      for n <- 1..150, do: TD.send!(f.alice, "m.dummy", TD.txn(), TD.star(f.bob1, %{"n" => n}))
      assert TD.queue_count(f.bob1.uid) == 200
      assert Enum.sum(for d <- [f.bob1, f.bob2, bob3], do: TD.queue_count(d.uid, d.dev)) == 200
    end

    test "the seam (5 rows): seven messages alternating over two devices keep alice's newest five, carol's rows at bob are untouched" do
      f = pair!()
      carol = sender_for!(f.bob1)
      TD.seam(:max_per_sender_user, 5)
      TD.tell!(carol, f.bob1, "m.dummy", %{"n" => -1})
      for n <- 1..7, do: TD.tell!(f.alice, Enum.at([f.bob1, f.bob2], rem(n, 2)), "m.dummy", %{"n" => n})
      assert TD.queue_count(f.bob1.uid) == 6
      assert {peek(f.bob1), peek(f.bob2)} == {[-1, 4, 6], [3, 5, 7]}
    end

    test "the byte share boundary: exactly three rows fit, one byte less keeps two" do
      f = pair!()
      content = fn n -> %{"n" => n, "pad" => String.duplicate("s", 300)} end
      TD.seam(:max_bytes_per_sender_user, 3 * TD.cost(content.(1)))
      for n <- 1..5, do: TD.tell!(f.alice, Enum.at([f.bob1, f.bob2], rem(n, 2)), "m.dummy", content.(n))
      assert TD.queue_count(f.bob1.uid) == 3
      TD.seam(:max_bytes_per_sender_user, 3 * TD.cost(content.(1)) - 1)
      TD.tell!(f.alice, f.bob1, "m.dummy", content.(6))
      assert TD.queue_count(f.bob1.uid) == 2
    end

    test "the share is per recipient USER: bob's cap does not cut what alice has queued for another user" do
      f = pair!()
      dave = TD.user!("TDD")
      TD.share!(f.alice, dave)
      TD.seam(:max_per_sender_user, 3)
      for n <- 1..5, do: TD.tell!(f.alice, f.bob1, "m.dummy", %{"n" => n})
      for n <- 1..3, do: TD.tell!(f.alice, dave, "m.dummy", %{"n" => n})
      assert {TD.queue_count(f.bob1.uid), TD.queue_count(dave.uid)} == {3, 3}
    end
  end

  describe "FAIR eviction at the user level: the LARGEST share loses its oldest first" do
    defp spread(sender, n_range, f, offset \\ 0), do: for(n <- n_range, do: TD.tell!(sender, Enum.at([f.bob1, f.bob2], rem(n + offset, 2)), "m.dummy", %{"n" => n}))

    test "message cap: a victim's 3 OLDER messages survive a flood of 12 (cap 10), the flooder keeps its newest 7" do
      f = pair!()
      victim = sender_for!(f.bob1)
      TD.seam(:max_per_user, 10)
      for n <- 1..3, do: TD.tell!(victim, f.bob1, "m.dummy", %{"n" => -n})
      spread(f.alice, 1..12, f)

      assert TD.queue_count(f.bob1.uid) == 10
      assert peek(f.bob1) == [-1, -2, -3, 6, 8, 10, 12]
      assert peek(f.bob2) == [7, 9, 11]
    end

    test "byte budget: the same flood against a victim below its share (budget of ten rows)" do
      f = pair!()
      victim = sender_for!(f.bob1)
      # equal byte size whatever the number (the pad shrinks as the number grows)
      content = fn n -> %{"n" => n, "pad" => String.duplicate("f", 200 - String.length(Integer.to_string(n)))} end
      TD.seam(:max_bytes_per_user, 10 * TD.cost(content.(1)))
      for n <- 1..3, do: TD.tell!(victim, f.bob1, "m.dummy", content.(-n))
      for n <- 1..12, do: TD.tell!(f.alice, Enum.at([f.bob1, f.bob2], rem(n, 2)), "m.dummy", content.(n))

      assert TD.queue_count(f.bob1.uid) == 10
      assert Enum.take(peek(f.bob1), 3) == [-1, -2, -3]
      assert peek(f.bob2) == [7, 9, 11]
    end

    test "two flooders and a victim (cap 10): each flood keeps its 4 newest, the victim's 2 rows stay" do
      f = pair!()
      victim = sender_for!(f.bob1)
      flooder2 = sender_for!(f.bob1)
      TD.seam(:max_per_user, 10)
      for n <- 1..2, do: TD.tell!(victim, f.bob1, "m.dummy", %{"n" => -n})

      for n <- 1..8 do
        TD.tell!(f.alice, f.bob1, "m.dummy", %{"n" => n})
        TD.tell!(flooder2, f.bob1, "m.dummy", %{"n" => 100 + n})
      end

      assert TD.queue_count(f.bob1.uid) == 10
      assert peek(f.bob1) == [-1, -2, 5, 105, 6, 106, 7, 107, 8, 108]
    end

    test "the cut falls INSIDE a tie of shares (cap 11): the OLDER row of the tied pair goes first" do
      f = pair!()
      victim = sender_for!(f.bob1)
      flooder2 = sender_for!(f.bob1)
      TD.seam(:max_per_user, 11)
      for n <- 1..2, do: TD.tell!(victim, f.bob1, "m.dummy", %{"n" => -n})

      for n <- 1..8 do
        TD.tell!(f.alice, f.bob1, "m.dummy", %{"n" => n})
        TD.tell!(flooder2, f.bob1, "m.dummy", %{"n" => 100 + n})
      end

      # 18 rows, 7 to go: ranks 8, 7, 6 of both floods (6 rows), then ONE of the two rank-5 rows: the older one (alice's n=4)
      assert peek(f.bob1) == [-1, -2, 104, 5, 105, 6, 106, 7, 107, 8, 108]
    end

    test "the sender that holds the most rows loses ITS oldest, not the newcomer's" do
      f = pair!()
      big = sender_for!(f.bob1)
      TD.seam(:max_per_user, 10)
      for n <- 1..8, do: TD.tell!(big, f.bob1, "m.dummy", %{"n" => n})
      for n <- 101..104, do: TD.tell!(f.alice, f.bob1, "m.dummy", %{"n" => n})

      assert TD.queue_count(f.bob1.uid) == 10
      assert peek(f.bob1) == [3, 4, 5, 6, 7, 8, 101, 102, 103, 104]
    end

    test "a single sender over the user cap: plain oldest first" do
      f = pair!()
      TD.seam(:max_per_user, 4)
      spread(f.alice, 1..8, f)
      assert {peek(f.bob1), peek(f.bob2)} == {[6, 8], [5, 7]}
    end
  end

  describe "at most 100 targets per request (the `*` fan-out) - a request cannot become thousands of rows" do
    test "the DEFAULT: `*` to a user with 105 devices queues exactly 100 rows, the answer is the same 200 {}" do
      f = pair!()
      many = TD.user!("TDM")
      TD.share!(f.alice, many)
      for i <- 1..105, do: :ok = Nebu.Matrix.DeviceKeyStore.upsert_device(many.uid, "MANY#{String.pad_leading(Integer.to_string(i), 3, "0")}")
      assert T.sql!("SELECT count(*) FROM devices WHERE user_id = $1", [many.uid]).rows == [[106]]

      c = TD.put_send(f.alice, "m.dummy", TD.txn(), TD.star(many, %{"n" => 1}))
      assert {c.status, c.resp_body} == {200, "{}"}
      assert TD.queue_count(many.uid) == 100
    end

    test "the seam counts the targets of the whole request: a cap of 4 queues FOUR rows, the same four every time" do
      f = pair!()
      bob3 = TD.device!(f.bob1, "TDD")
      carol1 = TD.user!("TDK")
      carol2 = TD.device!(carol1, "TDL")
      carol3 = TD.device!(carol1, "TDM")
      TD.share!(f.alice, carol1)
      TD.seam(:max_targets_per_request, 4)
      devices = [f.bob1, f.bob2, bob3, carol1, carol2, carol3]
      reached = fn type -> for d <- devices, Enum.any?(TD.events(TD.sync(d)), &(&1["type"] == type)), do: d.dev end

      TD.send!(f.alice, "m.dummy", TD.txn(), TD.merge([TD.star(f.bob1, %{"n" => 1}), TD.star(carol1, %{"n" => 1})]))
      TD.send!(f.alice, "m.room_key_request", TD.txn(), TD.merge([TD.star(f.bob1, %{"n" => 2}), TD.star(carol1, %{"n" => 2})]))
      first = reached.("m.dummy")
      assert length(first) == 4 and TD.queue_count(f.bob1.uid) + TD.queue_count(carol1.uid) == 8
      assert reached.("m.room_key_request") == first, "the kept targets are chosen deterministically"
    end

    test "the cap does not reduce an explicit short list: three explicit devices with a cap of 3 are all served" do
      f = pair!()
      bob3 = TD.device!(f.bob1, "TDD")
      TD.seam(:max_targets_per_request, 3)
      TD.send!(f.alice, "m.dummy", TD.txn(), TD.merge([TD.msg(f.bob1, %{"n" => 1}), TD.msg(f.bob2, %{"n" => 1}), TD.msg(bob3, %{"n" => 1})]))
      assert TD.queue_count(f.bob1.uid) == 3
      assert {TD.queue_count(f.bob1.uid, f.bob1.dev), TD.queue_count(f.bob2.uid, f.bob2.dev), TD.queue_count(bob3.uid, bob3.dev)} == {1, 1, 1}
    end
  end

  describe "the rows of ONE request cost at most 1 MiB (content + 128 per row): a big content cannot fan out to 100 devices" do
    defp many_devices!(sender, n) do
      many = TD.user!("TDM")
      TD.share!(sender, many)
      for i <- 1..(n - 1), do: :ok = Nebu.Matrix.DeviceKeyStore.upsert_device(many.uid, "MANY#{String.pad_leading(Integer.to_string(i), 3, "0")}")
      many
    end

    test "the DEFAULT: `*` of 60 000 bytes to 40 devices queues as many rows as fit 1 MiB, 1 KB reaches all 40" do
      f = pair!()
      many = many_devices!(f.alice, 40)
      big = %{"pad" => String.duplicate("x", 60_000 - 10)}
      fit = div(TD.defaults().max_fanout_bytes_per_request, TD.cost(big))
      assert fit in 10..30

      c = TD.put_send(f.alice, "m.dummy", TD.txn(), TD.star(many, big))
      assert {c.status, c.resp_body} == {200, "{}"}
      assert TD.queue_count(many.uid) == fit

      small = %{"pad" => String.duplicate("y", 1_000)}
      TD.send!(f.alice, "m.dummy", TD.txn(), TD.star(many, small))
      assert TD.queue_count(many.uid) == fit + 40
    end

    test "the seam: a budget of two rows queues two of three devices; below one row still queues ONE" do
      f = pair!()
      bob3 = TD.device!(f.bob1, "TDD")
      content = %{"pad" => String.duplicate("z", 500)}
      all3 = TD.merge([TD.msg(f.bob1, content), TD.msg(f.bob2, content), TD.msg(bob3, content)])

      TD.seam(:max_fanout_bytes_per_request, 2 * TD.cost(content))
      TD.send!(f.alice, "m.dummy", TD.txn(), all3)
      assert TD.queue_count(f.bob1.uid) == 2

      TD.seam(:max_fanout_bytes_per_request, 2 * TD.cost(content) - 1)
      TD.send!(f.alice, "m.dummy", TD.txn(), all3)
      assert TD.queue_count(f.bob1.uid) == 3, "one byte less than two rows: exactly ONE more row"

      TD.seam(:max_fanout_bytes_per_request, 10)
      TD.send!(f.alice, "m.dummy", TD.txn(), all3)
      assert TD.queue_count(f.bob1.uid) == 4, "below one row still ONE more row"
    end
  end

  describe "the idempotency records are bounded: 1000 per sending device" do
    test "the seam: with a cap of 5 the newest five transactions are remembered, an older one is forgotten (its replay queues again)" do
      f = pair!()
      TD.seam(:max_txns_per_device, 5)
      txns = for _ <- 1..8, do: TD.txn()
      for t <- txns, do: TD.send!(f.alice, "m.dummy", t, TD.msg(f.bob1, %{"t" => t}))
      assert TD.txn_count(f.alice.uid, f.alice.dev) == 5

      before = TD.queue_count(f.bob1.uid, f.bob1.dev)
      TD.send!(f.alice, "m.dummy", List.last(txns), TD.msg(f.bob1, %{"again" => true}))
      assert TD.queue_count(f.bob1.uid, f.bob1.dev) == before, "a remembered transaction is not queued again"
      TD.send!(f.alice, "m.dummy", hd(txns), TD.msg(f.bob1, %{"again" => true}))
      assert TD.queue_count(f.bob1.uid, f.bob1.dev) == before + 1, "a forgotten one is a new transaction"
    end

    test "records of other devices are not counted against this device's cap" do
      f = pair!()
      alice2 = TD.device!(f.alice, "TDE")
      TD.seam(:max_txns_per_device, 3)
      for _ <- 1..3, do: TD.send!(f.alice, "m.dummy", TD.txn(), TD.msg(f.bob1, %{}))
      for _ <- 1..3, do: TD.send!(alice2, "m.dummy", TD.txn(), TD.msg(f.bob1, %{}))
      assert {TD.txn_count(f.alice.uid, f.alice.dev), TD.txn_count(alice2.uid, alice2.dev)} == {3, 3}
    end
  end

  # ═══ the rate limit ══════════════════════════════════════════════════════════════════════════════════════════════════════════

  describe "the sender rate limit: 60 per minute, burst 30, per USER (oracle behaviour 15)" do
    setup do
      TD.enable_rate_limit()
      :ok
    end

    test "31 requests of one user: 30 pass, the 31st is 429 with retry_after_ms and Retry-After, nothing recorded" do
      f = pair!()
      for i <- 1..30, do: assert(TD.put_send(f.alice, "m.dummy", "t#{i}-#{TD.txn()}", TD.msg(f.bob1, %{"n" => i})).status == 200, "request #{i}")
      limited = TD.put_send(f.alice, "m.dummy", "last", TD.msg(f.bob1, %{"n" => 31}))
      TD.assert_429(limited, "31st request")
      assert TD.queue_count(f.bob1.uid, f.bob1.dev) == 30
      assert TD.txn_count(f.alice.uid, f.alice.dev) == 30
    end

    test "the bucket is per USER, not per IP (every request has its own address) and shared by the user's devices; other users are not affected" do
      f = pair!()
      alice2 = TD.device!(f.alice, "TDE")
      carol = sender_for!(f.bob1)
      for i <- 1..15, do: TD.send!(f.alice, "m.dummy", TD.txn(), TD.msg(f.bob1, %{"a" => i}))
      for i <- 1..15, do: TD.send!(alice2, "m.dummy", TD.txn(), TD.msg(f.bob1, %{"a2" => i}))
      TD.assert_429(TD.put_send(f.alice, "m.dummy", TD.txn(), %{}), "alice, device 1")
      TD.assert_429(TD.put_send(alice2, "m.dummy", TD.txn(), %{}), "alice, device 2")
      assert TD.put_send(carol, "m.dummy", TD.txn(), TD.msg(f.bob1, %{"c" => 1})).status == 200, "another user has a bucket of its own"
    end

    test "the refill is one token per second (60 / min): 999 ms later it is still 429, 1000 ms later one request passes, then 429 again" do
      f = pair!()
      for _ <- 1..30, do: TD.send!(f.alice, "m.dummy", TD.txn(), %{})
      TD.assert_429(TD.put_send(f.alice, "m.dummy", TD.txn(), %{}), "drained")
      TD.set_clock(5_000_999)
      TD.assert_429(TD.put_send(f.alice, "m.dummy", TD.txn(), %{}), "999 ms")
      TD.set_clock(5_001_000)
      assert TD.put_send(f.alice, "m.dummy", TD.txn(), %{}).status == 200
      TD.assert_429(TD.put_send(f.alice, "m.dummy", TD.txn(), %{}), "one token only")
    end

    test "the burst is 30 and not more: after a long pause (1 hour) the bucket holds 30 tokens, not 3600" do
      f = pair!()
      for _ <- 1..30, do: TD.send!(f.alice, "m.dummy", TD.txn(), %{})
      TD.set_clock(5_000_000 + 3_600_000)
      for _ <- 1..30, do: TD.send!(f.alice, "m.dummy", TD.txn(), %{})
      TD.assert_429(TD.put_send(f.alice, "m.dummy", TD.txn(), %{}), "31st after the pause")
    end

    test "a request costs ONE token however many devices it fans out to (a `*` request is one)" do
      f = pair!()
      for _ <- 1..30, do: TD.send!(f.alice, "m.dummy", TD.txn(), TD.star(f.bob1, %{"n" => 1}))
      TD.assert_429(TD.put_send(f.alice, "m.dummy", TD.txn(), %{}), "31st")
    end

    test "the limiter comes BEFORE the body: an exhausted user gets 429 for a malformed or oversize body (never read)" do
      f = pair!()
      for _ <- 1..30, do: TD.send!(f.alice, "m.dummy", TD.txn(), %{})

      for {label, body} <- [{"not JSON", {:raw, "{nope"}}, {"oversize", {:raw, body_of_size(f, 200_000)}}, {"wrong shape", {:body, %{"messages" => 5}}}] do
        c = TD.put_send(f.alice, "m.dummy", TD.txn(), body)
        TD.assert_429(c, label)
        assert match?(%Plug.Conn.Unfetched{}, c.body_params), "#{label}: the body was never read"
      end

      # story e2ee-compliance-channel-guard (D2): the type check is BEFORE the limiter, so an invalid type is the 400 even for an exhausted user (and consumes nothing)
      TD.assert_error(TD.put_send(f.alice, "bad type!", TD.txn(), %{}), 400, "M_INVALID_PARAM")
    end

    test "a refused BODY (400 / 413) still costs its token (the limiter is before the body): thirty bad requests exhaust the bucket" do
      f = pair!()
      for i <- 1..30 do
        {raw, status} = if rem(i, 2) == 0, do: {{:raw, "{nope"}, 400}, else: {{:raw, body_of_size(f, 70_000)}, 413}
        assert TD.put_send(f.alice, "m.dummy", TD.txn(), raw).status == status
      end

      TD.assert_429(TD.put_send(f.alice, "m.dummy", TD.txn(), TD.msg(f.bob1, %{"n" => 1})), "the valid request after thirty refused ones")
    end

    test "the bucket belongs to this endpoint: sync, account data, room send and key backup writes of the exhausted user are not limited by it" do
      f = pair!()
      for _ <- 1..30, do: TD.send!(f.alice, "m.dummy", TD.txn(), %{})
      TD.assert_429(TD.put_send(f.alice, "m.dummy", TD.txn(), %{}), "to-device")

      assert TD.sync_conn(f.alice, timeout: 0).status == 200
      ad = T.matrix_request(:put, "/_matrix/client/v3/user/#{Nebu.Matrix.ModerationTestSupport.enc(f.alice.uid)}/account_data/org.example.td", f.alice.at, body: %{"v" => 1})
      assert ad.status == 200
    end

    test "a 429 for a txn id does not burn it: after the refill the same txn id is delivered" do
      f = pair!()
      for _ <- 1..30, do: TD.send!(f.alice, "m.dummy", TD.txn(), %{})
      t = TD.txn()
      TD.assert_429(TD.put_send(f.alice, "m.dummy", t, TD.msg(f.bob1, %{"n" => 1})), "limited")
      TD.set_clock(5_001_000)
      TD.send!(f.alice, "m.dummy", t, TD.msg(f.bob1, %{"n" => 1}))
      assert [%{"content" => %{"n" => 1}}] = TD.events(TD.sync(f.bob1))
    end

    test "the limiter honours the global disable switch like the other tiers" do
      f = pair!()
      TD.disable_rate_limit()
      for _ <- 1..40, do: TD.send!(f.alice, "m.dummy", TD.txn(), %{})
    end
  end

  describe "a limited or refused request leaves no trace in the log of its content" do
    test "a canary in the content of a 413 / 400 / 429 request never reaches the log" do
      f = pair!()
      canary = "REFUSED-CANARY-" <> T.rand(6)

      log =
        capture_log([level: :debug], fn ->
          TD.with_log_level(:debug, fn ->
            TD.put_send(f.alice, "m.dummy", TD.txn(), {:raw, ~s({"messages":{"#{f.bob1.uid}":{"#{f.bob1.dev}":{"c":"#{canary}","pad":"#{String.duplicate("a", 70_000)}"}}}})})
            TD.put_send(f.alice, "m.dummy", TD.txn(), {:raw, ~s({"messages":{"#{f.bob1.uid}":{"#{f.bob1.dev}":"#{canary}"}}})})
          end)
        end)

      refute log =~ canary
    end
  end
end
