defmodule Nebu.OAuth.OAuthFreshnessTest do
  @moduledoc """
  Acceptance tests for story `oauth-authorize-freshness` (P3), AC2.1 (FR2): the pure
  helper `Nebu.OAuth.Freshness`, extracted from `Nebu.OAuth.Account.freshness/2`.

  ## Contract pinned here (called via `apply/3`)

      Nebu.OAuth.Freshness.auth_time(claims :: map) :: integer | nil
        # the `auth_time` claim ONLY. An integer is returned as is, a float is TRUNCATED; everything
        # else (string, nil, missing, list, map, `iat`-only claims, a non-map) is absent => nil.
      Nebu.OAuth.Freshness.evaluate(auth_time :: integer | nil, requested_at :: integer) ::
          {:fresh, integer} | {:stale, integer} | :absent
        # fresh iff auth_time >= requested_at - 60 (constant skew); `{:fresh, min(t, now)}` (a future
        # value is clamped to now), `{:stale, t}` when older, `:absent` for nil.

  Pure: never logs, never raises (checked with `capture_log` and junk input). No DB.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  @mod Nebu.OAuth.Freshness

  defp auth_time(claims), do: apply(@mod, :auth_time, [claims])
  defp evaluate(t, requested_at), do: apply(@mod, :evaluate, [t, requested_at])
  defp now, do: System.system_time(:second)

  test "the module exists and exports auth_time/1 and evaluate/2" do
    assert {:module, @mod} = Code.ensure_loaded(@mod)
    assert function_exported?(@mod, :auth_time, 1)
    assert function_exported?(@mod, :evaluate, 2)
  end

  describe "AC2.1 auth_time/1: the claim only" do
    test "an integer is returned as is" do
      assert auth_time(%{"auth_time" => 1_700_000_000}) == 1_700_000_000
      assert auth_time(%{"auth_time" => 0}) == 0
    end

    test "a float is truncated" do
      assert auth_time(%{"auth_time" => 1_700_000_000.9}) == 1_700_000_000
      assert auth_time(%{"auth_time" => 1_700_000_000.0}) == 1_700_000_000
    end

    test "string, nil, list, map, boolean => absent (nil), never parsed" do
      for v <- ["1700000000", "", nil, [1_700_000_000], %{"x" => 1}, true, false] do
        assert auth_time(%{"auth_time" => v}) == nil, "auth_time #{inspect(v)} must count as absent"
      end
    end

    test "a missing claim => nil; `iat` / `exp` are NEVER a substitute (the id_token proves issuance, not login)" do
      assert auth_time(%{}) == nil
      assert auth_time(%{"iat" => now(), "exp" => now() + 3600, "sub" => "alex"}) == nil
    end

    test "a non-map input never raises" do
      for junk <- [nil, "x", 1, [], :atom] do
        assert auth_time(junk) == nil
      end
    end
  end

  describe "AC2.1 evaluate/2: the 60 s skew boundary" do
    test "requested_at - 60 is fresh, requested_at - 61 is stale" do
      requested_at = now() - 5_000
      assert {:fresh, t} = evaluate(requested_at - 60, requested_at)
      assert t == requested_at - 60

      assert {:stale, stale} = evaluate(requested_at - 61, requested_at)
      assert stale == requested_at - 61
    end

    test "a login at/after the request is fresh and returned unchanged" do
      requested_at = now() - 100
      assert {:fresh, ^requested_at} = evaluate(requested_at, requested_at)
      assert {:fresh, t} = evaluate(requested_at + 30, requested_at)
      assert t == requested_at + 30
    end

    test "a FUTURE auth_time is clamped to now (an IdP clock that runs ahead must not stay fresh longer)" do
      before = now()
      assert {:fresh, t} = evaluate(before + 7_200, before - 10)
      assert t >= before and t <= now(), "clamped to now, got #{t} (now #{now()})"
    end

    test "nil => :absent, whatever the request time" do
      assert evaluate(nil, 0) == :absent
      assert evaluate(nil, now()) == :absent
    end

    test "very old => stale with the value preserved" do
      assert {:stale, 1_000} = evaluate(1_000, now())
    end
  end

  test "never logs, never raises (FR2)" do
    log =
      capture_log(fn ->
        for t <- [nil, 0, -1, 1_700_000_000, now() + 99_999], r <- [0, now(), -5] do
          evaluate(t, r)
        end

        for junk <- [%{"auth_time" => "secret-looking"}, nil, "x", %{"auth_time" => [1]}], do: auth_time(junk)
      end)

    refute log =~ "secret-looking"
    assert log == "", "the helper must not log at all, got #{inspect(log)}"
  end
end
