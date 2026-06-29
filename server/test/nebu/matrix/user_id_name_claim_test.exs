defmodule Nebu.Matrix.UserIdNameClaimTest do
  @moduledoc """
  RED-phase ATDD test for bug `bugfix-oidc-bootstrap-only-e2e-regressions`, AC5
  (claim-mapping resolution path).

  ## Background

  AC4 ensures the Matrix SSO request carries `profile` so the `name` claim is
  present in the verified token. AC5 is the downstream invariant: with
  `oidc_user_id_claim = "name"` configured, the MXID must derive from the `name`
  claim, NOT fall back to `sub`. This is the regression `df249f8c` previously fixed
  (MXID = `@<sub>` when `name` was missing because `profile` was not requested).

  ## What is under test

  `Nebu.Matrix.UserId.from_claims/2` — the single source of truth for
  claims→MXID, used by BOTH `POST /login` and `OidcPlug`. It reads the configured
  claim from `Nebu.Matrix.OidcClaimCache.get/0`, whose DB read is injectable via
  the `:matrix, :oidc_claim_reader` seam (a 0-arity fun) — the same seam
  `oidc_claim_cache_test` uses. We pin it to `"name"` and reset the cache so the
  configured claim resolves to `name`.

  This test is a UNIT-LEVEL REGRESSION GUARD: `UserId.from_claims/2` already
  honours the configured claim, so this is likely ALREADY GREEN. It guards against
  a future regression where the `name`→`sub` fallback re-appears. It complements
  AC4 (which guarantees the `name` claim is actually present in the token).

  ## Crash/restart — NOT APPLICABLE

  Pure function over claims + a cached config read (Persistenz Option C).
  """
  use ExUnit.Case, async: false

  alias Nebu.Matrix.UserId

  @server_name "test.local"

  setup do
    # Inject the configured claim via the OidcClaimCache reader seam and reset the
    # persistent_term cache so the next get/0 re-reads through the seam.
    Application.put_env(:matrix, :oidc_claim_reader, fn -> "name" end)
    Nebu.Matrix.OidcClaimCache.reset_for_test()

    on_exit(fn ->
      Application.delete_env(:matrix, :oidc_claim_reader)
      Nebu.Matrix.OidcClaimCache.reset_for_test()
    end)

    :ok
  end

  # ════════════════════════════════════════════════════════════════════════════
  # AC5 — MXID derives from the configured `name` claim, not `sub`
  # ════════════════════════════════════════════════════════════════════════════

  describe "AC5 — oidc_user_id_claim = name → MXID from name, not sub" do
    test "from_claims/2 builds @alice (from name) not @abc (from sub)" do
      claims = %{"sub" => "abc", "name" => "alice"}

      assert UserId.from_claims(claims, @server_name) == "@alice:#{@server_name}",
             "with oidc_user_id_claim=name the localpart must derive from the `name` claim " <>
               "(alice), not the opaque `sub` (abc)"
    end

    test "localpart/1 returns the sanitized name, not sub" do
      claims = %{"sub" => "abc", "name" => "Alice"}

      # sanitize downcases — the value comes from `name`, proving it is not `sub`.
      assert UserId.localpart(claims) == "alice"
      refute UserId.localpart(claims) == "abc"
    end
  end
end
