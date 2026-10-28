defmodule Nebu.OAuth.OAuthClientRevocationDocsTest do
  @moduledoc """
  Static documentation checks (no DB, no network) for story `oauth-client-revocation` (P4), AC12: ADR-033 carries the
  decisions, `07-deployment.md` closes the gates and replaces the runbook SQL by the supported operations, the
  follow-ups file moves (aj, ag, ax closed; ba, bb, bc appended; au-az untouched).
  """
  use ExUnit.Case, async: true

  @docs Path.expand("../../../../docs", __DIR__)
  @adr Path.join(@docs, "architecture/adr/ADR-033-authorization-server-broker-model.md")
  @deploy Path.join(@docs, "architecture/07-deployment.md")
  @followups Path.join(@docs, "stories/oauth-broker/follow-ups.md")
  @config_runtime Path.expand("../../../config/runtime.exs", __DIR__)
  @compose Path.expand("../../../../docker-compose.yml", __DIR__)

  defp read!(path), do: File.read!(path)
  defp table_row(text, id), do: text |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "| #{id} |"))

  describe "AC12 — ADR-033" do
    test "has the section 'Client revocation and same-origin hardening (story oauth-client-revocation)' with CR1-CR12 and SO1-SO8" do
      adr = read!(@adr)
      assert adr =~ ~r/^#{"#"}{1,3}\s+Client revocation and same-origin hardening \(story oauth-client-revocation\)/m

      [_, section] = String.split(adr, ~r/^#{"#"}{1,3}\s+Client revocation and same-origin hardening \(story oauth-client-revocation\)[^\n]*\n/m, parts: 2)
      section = section |> String.split(~r/^## /m, parts: 2) |> hd()

      for id <- Enum.map(1..12, &"CR#{&1}") ++ Enum.map(1..8, &"SO#{&1}"),
          do: assert(section =~ ~r/\b#{id}\b/, "#{id} missing in the ADR section")

      assert section =~ "FOR SHARE", "the CR5 lock"
      assert section =~ ~r/lock order/i
      assert section =~ ~r/ADR-020/, "the cross-table lock note (CR5 / ADR-020)"
      assert section =~ ~r/BrowserPost/, "the single shared copy of the fetch-metadata checks"
      assert section =~ ~r/approved\s*(->|→)\s*revoked/, "the only new guard transition"
    end

    test "'Database invariants' and 'Approval page' point to the new section" do
      adr = read!(@adr)
      [_, rest] = String.split(adr, ~r/^#{"#"}{2,3} Database invariants[^\n]*\n/m, parts: 2)
      assert (rest |> String.split(~r/^##/m, parts: 2) |> hd()) =~ "oauth-client-revocation", "Database invariants must mention that a revoked row is never deleted / the new transition"
      [_, rest2] = String.split(adr, ~r/^#{"#"}{2,3} Approval page[^\n]*\n/m, parts: 2)
      assert (rest2 |> String.split(~r/^##/m, parts: 2) |> hd()) =~ "oauth-client-revocation", "Approval page must mention the confirm page and the fresh re-authentication"
    end
  end

  describe "AC12 — 07-deployment.md" do
    test "the preconditions rows aj and ag are closed (server side) by this story" do
      d = read!(@deploy)
      aj = table_row(d, "aj") || flunk("row aj missing")
      refute aj =~ "open (GATE)"
      assert aj =~ "oauth-client-revocation"
      ag = table_row(d, "ag") || flunk("row ag missing")
      assert ag =~ "oauth-client-revocation"
      assert ag =~ ~r/SO7|Element Web.*own origin|own origin/i, "the operator part: acknowledge SO7 or move Element Web to its own origin"
    end

    test "a 'Revoking a client' section after the activation steps names the UI path, the finality and the RPC" do
      d = read!(@deploy)
      assert d =~ ~r/^### Revoking a client/m
      {steps_at, _} = :binary.match(d, "### Activation steps and smoke test")
      {revoke_at, _} = :binary.match(d, "### Revoking a client")
      assert revoke_at > steps_at
      section = d |> String.split("### Revoking a client", parts: 2) |> List.last() |> String.split(~r/^### /m, parts: 2) |> hd()
      assert section =~ "Nebu.Release.revoke_oauth_client"
      assert section =~ ~r/bin\/nebu rpc/
      assert section =~ ~r/metadata hash|never re-?approv|final/i
      assert section =~ ~r/Approved Clients/i
    end

    test "the kill-switch runbook uses the supported RPC instead of raw SQL on matrix_sessions" do
      d = read!(@deploy)
      kill = d |> String.split("### Kill switch, caches and rollback", parts: 2) |> List.last() |> String.split(~r/^### /m, parts: 2) |> hd()
      assert kill =~ "Nebu.Release.revoke_all_oauth_sessions"
      refute d =~ "DELETE FROM matrix_sessions WHERE auth_api = 'oauth'", "the runbook SQL that left devices behind is gone (an / ai)"
    end

    test "NEBU_ADMIN_REAUTH_ALLOW_MISSING_AUTH_TIME is documented as off by default with its risk; SO7 and SO8 are in the risks / reverse proxy" do
      d = read!(@deploy)
      assert d =~ "NEBU_ADMIN_REAUTH_ALLOW_MISSING_AUTH_TIME"
      cfg = d |> String.split("NEBU_ADMIN_REAUTH_ALLOW_MISSING_AUTH_TIME", parts: 2) |> List.last() |> String.slice(0, 900)
      assert cfg =~ ~r/default|off|false/i and cfg =~ ~r/risk|auth_time/i

      risks = d |> String.split("### Accepted risks and release notes to acknowledge before activation", parts: 2) |> List.last() |> String.split(~r/^## /m, parts: 2) |> hd()
      assert risks =~ ~r/same[- ]origin/i and risks =~ "SO7"

      proxy = d |> String.split("### Reverse proxy", parts: 2) |> List.last() |> String.split(~r/^### /m, parts: 2) |> hd()
      assert proxy =~ ~r/element\.example\.com/, "SO8: an example server block that serves Element Web on its own hostname"
    end
  end

  describe "AC12 — follow-ups and configuration" do
    test "aj, ag and ax are closed by oauth-client-revocation; ba, bb, bc are appended; au-az are untouched" do
      f = read!(@followups)

      for id <- ~w(aj ag ax) do
        row = table_row(f, id) || flunk("row #{id} missing in follow-ups.md")
        assert row =~ "oauth-client-revocation", "#{id} must point to the story that closes it"
        assert row =~ ~r/closed|RESOLVED|resolved/i, "#{id} must be marked closed"
      end

      for id <- ~w(ba bb bc), do: assert(table_row(f, id), "follow-up #{id} not appended")
      assert (table_row(f, "ba") || "") =~ ~r/admin/i, "ba: configurable admin public URL / dedicated admin hostname (SO8)"
      assert (table_row(f, "bb") || "") =~ ~r/batch/i, "bb: batched revoke of very large clients (CR11)"
      assert (table_row(f, "bc") || "") =~ ~r/revoke-all|revoke all/i, "bc: optional UI for revoke-all"
      for id <- ~w(au av aw ay az), do: assert(table_row(f, id), "the earlier row #{id} must stay")
    end

    test "config/runtime.exs and docker-compose.yml carry the SO5 opt-out only for the dev stack" do
      assert read!(@config_runtime) =~ "NEBU_ADMIN_REAUTH_ALLOW_MISSING_AUTH_TIME"
      compose = read!(@compose)
      assert compose =~ ~r/NEBU_ADMIN_REAUTH_ALLOW_MISSING_AUTH_TIME:\s*"?true"?/, "dev Dex omits auth_time (dev's job, e2e relies on it)"
      assert compose =~ ~r/dev Dex omits auth_time/i
    end
  end
end
