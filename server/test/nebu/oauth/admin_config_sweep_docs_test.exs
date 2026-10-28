defmodule Nebu.OAuth.AdminConfigSweepDocsTest do
  @moduledoc """
  Static checks (no DB, no network) for story `admin-config-privileged-forms-sweep`, AC8: the decision table of the sweep (ADR-033 SO10), the
  documented lock-out recovery and the protection list in 07-deployment, group D, and the follow-ups rows (`cw` closed, the new rows).
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

  test "ADR-033: SO10 names every form, its level and the reason (marker vs strict-only, the lock-out argument for scopes and refresh mode)" do
    a = read(@adr)
    sec = between(a, "- **SO10 (sweep of the other privileged admin forms", "- **SO8 ")
    for word <- ["role mapping", "claim mapping", "OIDC scopes", "refresh mode", "`:marker`", "`:click`", "lock", "SO7", "`sso_redirect_schemes_changed`", "`oidc_claim_mapping_changed`", "`admin_group_claim_changed`", "bootstrap"] do
      assert sec =~ word, word
    end
  end

  test "07-deployment: the protection list names the four forms and the lock-out recovery by SQL; group D lists the mapping pages" do
    d = read(@deploy)
    sec = between(d, "### Admin configuration forms and their protection", "### Preconditions")
    for word <- ["Role mapping", "Claim mapping", "OIDC scopes", "OIDC refresh mode", "fresh sign-in", "locks ALL administrators out", "UPDATE server_config", "admin_group_claim", "oidc_user_id_claim"] do
      assert sec =~ word, word
    end

    group_d = between(d, "**D. Admin**", "**E. Operator rehearsals")
    assert group_d =~ "claim mapping"
    assert group_d =~ "role mapping"
    assert group_d =~ "scopes"
  end

  test "follow-ups: cw is closed by the story, the new rows exist; 11-risks records the sweep" do
    f = read(@followups)
    assert f =~ "| cw | **CLOSED by story admin-config-privileged-forms-sweep"
    assert f =~ "| de |"
    assert f =~ "| df |"
    assert read(@risks) =~ "admin-config-privileged-forms-sweep"
  end
end
