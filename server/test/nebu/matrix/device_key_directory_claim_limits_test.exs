defmodule Nebu.Matrix.DeviceKeyDirectoryClaimLimitsTest do
  @moduledoc """
  Acceptance tests (REAL database, real limiter with a FROZEN clock) of the limits of `POST /keys/claim` for story `device-key-directory` (REQ-2026-013): Gherkin scenario 5, oracle
  edge case 10 and the orchestrator decisions:

    * per caller user 30 requests / minute, burst 10 (counts REQUESTS, not targets);
    * per caller user 600 targets / minute, burst 1000 (counts the syntactically valid TARGETS of a request, whatever their state: no oracle; a cost above the burst is charged as the burst);
    * per (caller, target user, target device) 10 / hour, burst 5, for one-time and fallback claims alike, charged for EVERY valid target whatever its kind (unknown, unshared and
      keyless targets are charged too: a 429 that depends on the target's state would be an existence oracle);
    * the buckets of a request are taken in TWO stages, each ALL-OR-NOTHING, before the consuming statement: stage 1 the two caller buckets (requests, targets), stage 2 the per-target
      buckets (so a request refused in stage 1 creates no per-target row). Any bucket empty -> `429 M_LIMIT_EXCEEDED` with `retry_after_ms`, nothing consumed; a stage 2 refusal keeps
      the stage 1 tokens spent (they never depend on the state of a target); a 400 (structure, more than 1000 targets) charges nothing and comes first;
    * at most 1000 targets per request, `400 M_INVALID_PARAM` beyond.

  The buckets are node-local like every rate tier (N x the limit in a cluster, documented in 08-concepts and 07-deployment).
  """
  use ExUnit.Case, async: false

  alias Nebu.Matrix.DeviceKeyDirectoryTestSupport, as: DK
  alias Nebu.Matrix.ToDeviceTestSupport, as: TD
  alias Nebu.OAuth.TestSupport, as: T

  @moduletag :integration

  setup do
    T.reset_rate_limits()
    Nebu.Test.ServerName.pin!(T.server_name())
    TD.enable_rate_limit()
    on_exit(fn -> T.restore_rate_limits() end)
    {:ok, w: DK.world!()}
  end

  # a target nobody has: charges the caller bucket and a fresh target bucket
  defp fresh, do: %{"@gone-#{T.rand(5)}:test.local" => %{"D" => "signed_curve25519"}}
  defp status(w, targets), do: DK.claim(w.alice, targets).status
  defp advance(ms), do: DK.set_clock(DK.clock() + ms)

  describe "the per-caller bucket: 30 / minute, burst 10, counts requests" do
    test "ten requests pass, the eleventh is a 429 M_LIMIT_EXCEEDED with the exact envelope", %{w: w} do
      for i <- 1..10, do: assert(status(w, fresh()) == 200, "request #{i}")
      c = DK.claim(w.alice, fresh())
      body = c |> TD.assert_429("the eleventh claim") |> TD.json()
      assert body["retry_after_ms"] == 2000, "one token of 30 / minute is 2 s away"
      assert TD.json(c)["errcode"] == "M_LIMIT_EXCEEDED"
    end

    test "a request with 100 targets costs ONE request token (requests are counted, not targets)", %{w: w} do
      many = fn -> for(i <- 1..100, into: %{}, do: {"@gone#{i}-#{T.rand(4)}:test.local", %{"D" => "signed_curve25519"}}) end
      for i <- 1..10, do: assert(status(w, many.()) == 200, "request #{i}")
      assert status(w, many.()) == 429
    end

    test "the bucket refills at one token per two seconds: 1.9 s is too early, 2.1 s pays for one request, then it is empty again", %{w: w} do
      for _ <- 1..10, do: status(w, fresh())
      assert status(w, fresh()) == 429
      advance(1_900)
      assert status(w, fresh()) == 429
      advance(200)
      assert status(w, fresh()) == 200
      assert status(w, fresh()) == 429
    end

    test "the bucket never holds more than the burst: after a long pause exactly ten requests pass", %{w: w} do
      for _ <- 1..10, do: status(w, fresh())
      advance(3_600_000)
      results = for _ <- 1..12, do: status(w, fresh())
      assert Enum.count(results, &(&1 == 200)) == 10 and Enum.count(results, &(&1 == 429)) == 2
    end

    test "waiting for the announced retry_after_ms is enough for the next request", %{w: w} do
      for _ <- 1..10, do: status(w, fresh())
      body = DK.claim(w.alice, fresh()) |> TD.assert_429("limited") |> TD.json()
      advance(body["retry_after_ms"])
      assert status(w, fresh()) == 200
    end

    test "the bucket is per CALLER: an exhausted caller does not limit another user", %{w: w} do
      for _ <- 1..10, do: status(w, fresh())
      assert status(w, fresh()) == 429
      assert DK.claim(w.carol, fresh()).status == 200
    end

    test "a 429 consumes nothing: the keys of the target are all still there", %{w: w} do
      DK.publish!(w.bob1, otks: for(i <- 1..4, do: "K#{i}"))
      for _ <- 1..10, do: status(w, fresh())
      assert status(w, DK.target(w.bob1)) == 429
      assert DK.unclaimed(w.bob1.uid, w.bob1.dev) == 4
    end
  end

  describe "Scenario 5 - the per (caller, target user, device) bucket: 10 / hour, burst 5" do
    test "five claims for one device pass, the sixth is a 429 and no one-time key is consumed by it", %{w: w} do
      DK.publish!(w.bob1, otks: for(i <- 1..8, do: "K#{i}"))
      for i <- 1..5, do: assert(map_size(DK.claim!(w.alice, DK.target(w.bob1))["one_time_keys"]) == 1, "claim #{i}")
      assert DK.unclaimed(w.bob1.uid, w.bob1.dev) == 3
      TD.assert_429(DK.claim(w.alice, DK.target(w.bob1)), "the sixth claim")
      assert DK.unclaimed(w.bob1.uid, w.bob1.dev) == 3, "the refused claim consumed nothing"
    end

    test "fallback claims count like one-time claims: five fallback answers, then a 429", %{w: w} do
      DK.publish!(w.bob1, fallback: "FFFF")
      for i <- 1..5, do: assert(DK.claim_one!(w.alice, w.bob1) |> DK.ids() == ["signed_curve25519:FFFF"], "claim #{i}")
      TD.assert_429(DK.claim(w.alice, DK.target(w.bob1)), "the sixth claim")
    end

    test "one-time and fallback claims share ONE bucket: three of one kind and two of the other exhaust it", %{w: w} do
      DK.publish!(w.bob1, otks: ["A1", "A2", "A3"], fallback: "FFFF")
      for _ <- 1..5, do: DK.claim!(w.alice, DK.target(w.bob1))
      assert status(w, DK.target(w.bob1)) == 429
    end

    test "the bucket belongs to the (caller, user, DEVICE): another device of the same user and another caller each have their own", %{w: w} do
      DK.publish!(w.bob1, otks: for(i <- 1..8, do: "K#{i}"))
      DK.publish!(w.bob2, otks: ["B1"])
      for _ <- 1..5, do: DK.claim!(w.alice, DK.target(w.bob1))
      assert status(w, DK.target(w.bob1)) == 429
      assert DK.claim_one!(w.alice, w.bob2) |> DK.ids() == ["signed_curve25519:B1"], "another device of bob"
      other_caller = DK.peer!(w.bob1, "DKQ")
      assert DK.claim_one!(other_caller, w.bob1) |> map_size() == 1, "another caller has its own bucket for the same target"
    end

    test "the target bucket refills one token per six minutes: 5 min too early, 6.1 min pays for one claim", %{w: w} do
      DK.publish!(w.bob1, otks: for(i <- 1..8, do: "K#{i}"))
      for _ <- 1..5, do: DK.claim!(w.alice, DK.target(w.bob1))
      assert status(w, DK.target(w.bob1)) == 429
      advance(300_000)
      assert status(w, DK.target(w.bob1)) == 429
      advance(66_000)
      assert status(w, DK.target(w.bob1)) == 200
      assert status(w, DK.target(w.bob1)) == 429
    end

    test "the 429 of the target bucket announces when one token is back (about 6 minutes, in seconds and milliseconds)", %{w: w} do
      for _ <- 1..5, do: DK.claim!(w.alice, DK.target(w.bob1))
      body = DK.claim(w.alice, DK.target(w.bob1)) |> TD.assert_429("limited") |> TD.json()
      assert body["retry_after_ms"] in 300_000..365_000
    end

    test "EVERY kind of target is charged: unknown, unshared, invited, keyless, remote hit the same 429 at the same request (no oracle)", %{w: w} do
      invited = TD.user!("DKI")
      TD.invite_only!(w.alice, invited)

      kinds = [
        {"unknown device of a shared user", %{w.bob1.uid => %{"NOPE" => "signed_curve25519"}}},
        {"unknown user", %{"@gone-#{T.rand(4)}:test.local" => %{"D" => "signed_curve25519"}}},
        {"unshared user", DK.target(w.dave)},
        {"invited user", DK.target(invited)},
        {"keyless device", DK.target(w.bob2)},
        {"remote user", %{"@x:other.example" => %{"D" => "signed_curve25519"}}}
      ]

      for {label, target} <- kinds do
        T.reset_rate_limits()
        TD.enable_rate_limit()
        results = for _ <- 1..6, do: status(w, target)
        assert results == [200, 200, 200, 200, 200, 429], "#{label}: #{inspect(results)}"
      end
    end

    test "the target bucket is per device, not per algorithm: another algorithm of the same device is the same bucket", %{w: w} do
      for _ <- 1..5, do: DK.claim!(w.alice, DK.target(w.bob1, "alg_one"))
      assert status(w, DK.target(w.bob1, "alg_two")) == 429
    end
  end

  describe "all-or-nothing: one empty bucket refuses the WHOLE request" do
    test "one exhausted and one fresh device: a 429, the fresh device keeps keys and bucket, the caller request bucket is charged (stage 1)", %{w: w} do
      DK.publish!(w.bob1, otks: for(i <- 1..8, do: "K#{i}"))
      DK.publish!(w.bob2, otks: for(i <- 1..8, do: "L#{i}"))
      for _ <- 1..5, do: DK.claim!(w.alice, DK.target(w.bob1))
      TD.assert_429(DK.claim(w.alice, DK.targets([w.bob1, w.bob2])), "bob1 is exhausted")
      assert DK.unclaimed(w.bob2.uid, w.bob2.dev) == 8, "nothing of bob2 was consumed"
      # five claims used 5 of the 10 caller request tokens; the refused request (stage 2 refusal) keeps its stage 1 token (6 used): four more requests pass and empty the caller
      # bucket. Then the clock moves 2.1 s (one caller token is back; the target bucket of bob2 refills one token per SIX minutes, so nothing there) and a FIFTH request for bob2
      # must pass: that is only possible when the refused request did not leave bob2's target bucket charged (had the stage 2 refusal not refunded it, bob2 would hold 4 tokens
      # after the refusal, the four requests would empty it and the fifth would be a 429 of the target bucket)
      for i <- 1..4, do: assert(status(w, DK.target(w.bob2)) == 200, "claim #{i} of bob2")
      assert status(w, DK.target(w.bob2)) == 429, "the caller request bucket is empty"
      advance(2_100)
      assert status(w, DK.target(w.bob2)) == 200, "claim 5 of bob2: its target bucket still had all five tokens (the refused request refunded it)"
      assert status(w, DK.target(w.bob2)) == 429, "now the target bucket of bob2 is empty"
    end

    test "the buckets are checked BEFORE the consuming statement: a refused request issues no statement on the key tables", %{w: w} do
      DK.publish!(w.bob1, otks: for(i <- 1..8, do: "K#{i}"))
      for _ <- 1..5, do: DK.claim!(w.alice, DK.target(w.bob1))
      {conn, statements} = DK.all_statements(fn -> DK.claim(w.alice, DK.target(w.bob1)) end)
      assert conn.status == 429
      assert DK.key_statements(statements) == [], "no claim statement ran: #{inspect(statements)}"
    end

    test "the same holds when the CALLER bucket is the empty one", %{w: w} do
      DK.publish!(w.bob1, otks: ["K1"])
      for _ <- 1..10, do: status(w, fresh())
      {conn, statements} = DK.all_statements(fn -> DK.claim(w.alice, DK.target(w.bob1)) end)
      assert conn.status == 429
      assert DK.key_statements(statements) == []
      assert DK.unclaimed(w.bob1.uid, w.bob1.dev) == 1
    end

    test "the caller bucket alone refuses (fresh target buckets), and the target bucket alone refuses (caller tokens left)", %{w: w} do
      for _ <- 1..10, do: status(w, fresh())
      assert status(w, DK.target(w.bob2)) == 429
      T.reset_rate_limits()
      TD.enable_rate_limit()
      for _ <- 1..5, do: status(w, DK.target(w.bob2))
      assert status(w, DK.target(w.bob2)) == 429, "the target bucket alone refuses while the caller bucket has tokens"
    end
  end

  describe "the per-caller TARGETS budget: 600 / minute, burst 1000, the cost is the number of valid targets" do
    defp n_targets(n, tag), do: for(i <- 1..n, into: %{}, do: {"@gone#{tag}#{i}:test.local", %{"D" => "signed_curve25519"}})

    test "four requests of 250 targets pass, the fifth is a 429 (the budget is targets, not requests)", %{w: w} do
      for i <- 1..4, do: assert(status(w, n_targets(250, "a#{i}-")) == 200, "request #{i}")
      assert status(w, n_targets(250, "b")) == 429
    end

    test "the bucket refills 600 per minute: 10 targets per second", %{w: w} do
      assert status(w, n_targets(1000, "c")) == 200
      advance(30_100)
      assert status(w, n_targets(300, "d")) == 200
      assert status(w, n_targets(10, "e")) == 429
    end

    test "the 429 does not depend on the state of the targets: existing, keyless, unshared and unknown targets get the same answer", %{w: w} do
      DK.publish!(w.bob1, otks: ["K1"])
      assert status(w, targets_n(1000)) == 200
      answers =
        for target <- [DK.target(w.bob1), DK.target(w.bob2), DK.target(w.dave), fresh()] do
          c = DK.claim(w.alice, target)
          {c.status, TD.json(c)["errcode"], TD.json(c)["retry_after_ms"]}
        end

      assert Enum.uniq(answers) == [{429, "M_LIMIT_EXCEEDED", 1000}], inspect(answers)
      assert DK.unclaimed(w.bob1.uid, w.bob1.dev) == 1, "nothing was consumed"
    end
  end

  describe "the request cap (400 M_INVALID_PARAM beyond 1000 targets) comes before the buckets" do
    defp targets_n(n), do: for(i <- 1..n, into: %{}, do: {"@gone#{i}:test.local", %{"D#{i}" => "signed_curve25519"}})
    defp spread(n), do: for(i <- 1..n, into: %{}, do: {"@gone-#{rem(i, 10)}:test.local", Map.new(1..div(n, 10), fn j -> {"D#{i}-#{j}", "signed_curve25519"} end)})

    test "exactly 1000 targets are accepted and cost ONE request token (and the whole targets budget)", %{w: w} do
      assert status(w, targets_n(1000)) == 200
      assert status(w, fresh()) == 429, "the targets budget (1000, burst 1000) is spent: even one more target is refused"
      advance(1_000)
      for _ <- 1..9, do: assert(status(w, fresh()) == 200)
      assert status(w, fresh()) == 429, "the 1000-target request was one of the ten request tokens"
    end

    test "1001 targets: 400 M_INVALID_PARAM, nothing consumed, nothing charged", %{w: w} do
      DK.publish!(w.bob1, otks: ["K1"])
      body = Map.merge(targets_n(1000), DK.target(w.bob1))
      TD.assert_error(DK.claim(w.alice, body), 400, "M_INVALID_PARAM")
      assert DK.unclaimed(w.bob1.uid, w.bob1.dev) == 1
      for i <- 1..10, do: assert(status(w, fresh()) == 200, "request #{i}: the refused request charged no token")
    end

    test "the targets are counted over the whole object (users x devices), not per user", %{w: w} do
      assert status(w, spread(1000)) == 200
      T.reset_rate_limits()
      TD.enable_rate_limit()
      TD.assert_error(DK.claim(w.alice, spread(1010)), 400, "M_INVALID_PARAM")
    end

    test "the cap is checked before the rate limit: an exhausted caller still gets the 400, not a 429", %{w: w} do
      for _ <- 1..10, do: status(w, fresh())
      assert status(w, fresh()) == 429
      TD.assert_error(DK.claim(w.alice, targets_n(1001)), 400, "M_INVALID_PARAM")
    end

    test "a structure error is a 400 that charges nothing: twenty of them leave all ten request tokens", %{w: w} do
      for _ <- 1..20, do: TD.assert_error(TD.req(:post, DK.claim_path(), w.alice.at, %{"one_time_keys" => "x"}), 400, "M_BAD_JSON")
      for i <- 1..10, do: assert(status(w, fresh()) == 200, "request #{i}")
    end
  end

  describe "the switch" do
    test "with the limiter disabled (the harness switch) twenty claims pass: the limits are the limiter's, not a hard cap", %{w: w} do
      TD.disable_rate_limit()
      for i <- 1..20, do: assert(status(w, DK.target(w.bob1)) == 200, "request #{i}")
    end
  end
end
