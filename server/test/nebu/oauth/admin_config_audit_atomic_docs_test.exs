defmodule Nebu.OAuth.AdminConfigAuditAtomicDocsTest do
  @moduledoc """
  Static checks (no DB, no network) for story `admin-config-audit-atomic`, AC7: the decision table (ADR-033 SO10 addendum), the operator text in
  07-deployment (what the admin sees, the SIEM note), 11-risks, the follow-ups rows (`dh` closed, `di` / `dd` partly) and the AuditWriter carve-out.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)
  @deploy Path.join(@root, "docs/architecture/07-deployment.md")
  @adr Path.join(@root, "docs/architecture/adr/ADR-033-authorization-server-broker-model.md")
  @risks Path.join(@root, "docs/architecture/11-risks.md")
  @followups Path.join(@root, "docs/stories/oauth-broker/follow-ups.md")
  @writer Path.join(@root, "server/lib/nebu/compliance/audit_writer.ex")

  defp read(p), do: File.read!(p) |> String.replace(~r/\s+/, " ")

  defp between(text, from, to) do
    [_, rest] = String.split(text, from, parts: 2)
    assert String.contains?(rest, to), "the end marker #{inspect(to)} exists after #{inspect(from)}"
    [section | _] = String.split(rest, to, parts: 2)
    section
  end

  test "ADR-033: the SO10 addendum has the table: which form is refused and which is applied without its row, and why" do
    sec = between(read(@adr), "- **SO10 addendum: atomic audit of the config saves", "- **SO8 ")

    for word <- ["`Nebu.Admin.DB.save_config_audited/2`", "one transaction", "role mapping", "claim mapping", "widening", "narrowing", "subset", "refresh mode", "kill switch", "reset_admin_group_claim/1", "peek_confirm/1", "`oauth_switch_changed`"] do
      assert sec =~ word, word
    end
  end

  test "07-deployment: the text names what the admin sees and the recovery without a working audit table; the SIEM note names both actions" do
    sec = between(read(@deploy), "### Admin configuration forms and their protection", "### Preconditions")

    for word <- ["not saved: the audit entry could not be written", "saved, but the audit entry could not be written", "subset", "SIEM", "`sso_redirect_origins_changed`", "`oauth_switch_changed`"] do
      assert sec =~ word, word
    end

    group_d = between(read(@deploy), "**D. Admin**", "**E. Operator rehearsals")
    assert group_d =~ "audit entry could not be written"
  end

  test "follow-ups: dh closed by the story, di and dd partly; 11-risks and the AuditWriter carve-out name the story" do
    f = read(@followups)
    assert f =~ "| dh | **CLOSED by story admin-config-audit-atomic"
    assert f =~ "| di | **PARTLY CLOSED by story admin-config-audit-atomic"
    assert f =~ "| dd | **PARTLY CLOSED by story admin-config-audit-atomic"
    assert read(@risks) =~ "admin-config-audit-atomic"
    assert read(@writer) =~ "Nebu.Admin.DB.save_config_audited"
  end
end
