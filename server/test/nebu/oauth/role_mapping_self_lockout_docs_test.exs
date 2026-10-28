defmodule Nebu.OAuth.RoleMappingSelfLockoutDocsTest do
  @moduledoc """
  Static checks (no DB, no network) for story `role-mapping-self-lockout-guard`, AC8: the decision in ADR-033 (SO10 addendum), the operator text
  in 07-deployment (protection table, group D), 11-risks and the follow-ups row (`dg` closed).
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)
  @deploy Path.join(@root, "docs/architecture/07-deployment.md")
  @adr Path.join(@root, "docs/architecture/adr/ADR-033-authorization-server-broker-model.md")
  @risks Path.join(@root, "docs/architecture/11-risks.md")
  @followups Path.join(@root, "docs/stories/oauth-broker/follow-ups.md")

  defp read(p), do: File.read!(p) |> String.replace(~r/\s+/, " ")

  defp between(text, from, to) do
    [_, rest] = String.split(text, from, parts: 2)
    [section | _] = String.split(rest, to, parts: 2)
    section
  end

  test "ADR-033: the SO10 addendum names the guard, where the claims come from, the fingerprint, the refusal without override and its limits" do
    sec = between(read(@adr), "- **SO10 (sweep of the other privileged admin forms", "- **SO8 ")
    for word <- ["self-lock-out", "`claims_fp`", "SHA-256", "more than 32 distinct values", "`:undecidable`", "`:unknown`", "`claims_fp_path`", "protocol and identity claims", "no override", "`Nebu.Release.reset_admin_group_claim/1`", "other administrators lose access"] do
      assert sec =~ word, word
    end
  end

  test "07-deployment: the protection list and the lock-out recovery describe the guard; group D has the browser check" do
    d = read(@deploy)
    sec = between(d, "### Admin configuration forms and their protection", "### Preconditions")
    for word <- ["not in your own sign-in token", "more than 32 distinct values", "did not record", "other administrators lose access"] do
      assert sec =~ word, word
    end

    group_d = between(d, "**D. Admin**", "**E. Operator rehearsals")
    assert group_d =~ "not in your own sign-in token"
  end

  test "follow-ups: dg is closed by the story; 11-risks records it" do
    assert read(@followups) =~ "| dg | **CLOSED by story role-mapping-self-lockout-guard"
    assert read(@risks) =~ "role-mapping-self-lockout-guard"
  end
end
