defmodule Nebu.OAuth.OAuthClientStoreTest do
  @moduledoc """
  Acceptance tests for story `oauth-metadata-dcr-admin-approval` — static source invariants of
  `Nebu.OAuth.ClientStore` (ADR-018 inline SQL, ADR-020 cluster safety, MUST-NOT-delete).

  Behaviour is asserted end-to-end in `oauth_dcr_integration_test.exs` (atomic dedup incl.
  concurrent POSTs), `000040_oauth_clients_test.exs` (ON CONFLICT DO NOTHING) and
  `oauth_admin_test.exs` (already-decided clients are never overwritten). This file therefore
  does NOT duplicate those as function-export or SQL-grep checks (test-review m6); it only pins
  what behaviour tests cannot see — architecture rules about HOW the module is written:

    * `approved` / `rejected` registrations are NEVER deleted by application code (Matrix spec:
      "MUST NOT delete registrations with an active session"); the only DELETEs are the TTL purge and
      the admin bulk removal of `pending` rows (decision cycle 0, story oauth-dcr-abuse-hardening AH8, see
      `oauth_pending_protection_test.exs`)
    * no ORM / Ecto.Schema / repository layer (ADR-018)
    * no application-level locks or process registration (ADR-020)
    * no auto-approval switch exists anywhere in lib/ (decision Phil, 2026-10-07)
  """
  use ExUnit.Case, async: true

  @store_path Path.expand("../../../lib/nebu/oauth/client_store.ex", __DIR__)

  describe "ADR-018 / ADR-020 / MUST-NOT-delete — source invariants of ClientStore" do
    setup do
      assert File.exists?(@store_path), "server/lib/nebu/oauth/client_store.ex is missing"
      {:ok, src: File.read!(@store_path)}
    end

    # Story oauth-dcr-abuse-hardening (AH8, AC14.2): the admin bulk removal is the second DELETE.
    test "the only DELETEs are the purge and the bulk removal of PENDING rows; decided registrations are never deleted", %{src: src} do
      statements = Regex.scan(~r/DELETE\s+FROM\s+oauth_clients.*?"""/is, src)
      assert length(statements) == 2, "exactly two DELETE statements expected (purge, bulk), got #{length(statements)}"
      for [s] <- statements, do: assert(s =~ ~r/WHERE\s+status\s*=\s*'pending'/i, "every DELETE must be restricted to pending rows")
      refute src =~ ~r/Repo\.delete/
      assert src =~ ~r/bulk/i and src =~ ~r/SKIP\s+LOCKED/i
    end

    test "no Ecto.Schema / repository layer (ADR-018: SQL inline)", %{src: src} do
      refute src =~ "use Ecto.Schema"
      refute src =~ ~r/import\s+Ecto\.Query/
    end

    test "no application-level locks or process registration (ADR-020)", %{src: src} do
      refute src =~ ~r/Process\.register|:global\.|GenServer\.start_link/
    end
  end

  describe "ADR-020 — domain layout (code-review 10)" do
    test "Nebu.OAuth.Config lives inside the OAuth domain directory, not in a generic config/ dir" do
      lib = Path.expand("../../../lib/nebu", __DIR__)
      assert File.exists?(Path.join(lib, "oauth/config.ex"))
      # Explicit rename guard: the module moved from config/oauth_config.ex (code-review 10); the
      # legacy path must not reappear next to it.
      refute File.exists?(Path.join(lib, "config/oauth_config.ex"))
      assert File.read!(Path.join(lib, "oauth/config.ex")) =~ "defmodule Nebu.OAuth.Config do"
    end
  end

  describe "AC4 — no dcr_policy switch exists (decision Phil, 2026-10-07)" do
    # Matches the SWITCH as an identifier / config key (:dcr_policy, "dcr_policy", dcr_policy:,
    # auto_approve = ..., auto_approve(...), :auto_approve*), not prose — a comment or @doc that
    # merely explains "there is no dcr_policy" must not fail this test.
    @switch ~r/[:"']dcr_policy\b|\bdcr_policy[:"']|\bdcr_policy\s*=|:auto_approve\w*|\bauto_approve\w*\s*(=|\(|:)/i

    test "no lib file introduces a dcr_policy / auto_approve setting (comments ignored)" do
      lib = Path.expand("../../../lib", __DIR__)

      offenders =
        Path.wildcard(Path.join(lib, "**/*.ex"))
        |> Enum.filter(fn f ->
          code = f |> File.read!() |> String.replace(~r/#[^\n]*/, "")
          Regex.match?(@switch, code)
        end)

      assert offenders == [], "found forbidden auto-approval switch in: #{inspect(offenders)}"
    end

    test "the switch pattern itself detects identifier/config-key usages but not prose" do
      for hit <- [":dcr_policy", ~s("dcr_policy"), "dcr_policy: :auto", "auto_approve = true", "auto_approve(client)", ":auto_approve_all"],
          do: assert(Regex.match?(@switch, hit), "pattern must match #{inspect(hit)}")

      refute Regex.match?(@switch, "there is no dcr_policy and nothing is auto approved")
    end
  end
end
