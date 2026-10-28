defmodule Nebu.OAuth.MediaRetentionAuditAtomicDocsTest do
  @moduledoc """
  Static checks (no DB, no network) for story `media-retention-audit-atomic`, AC8: 07-deployment (the policy per direction, what the admin sees, the per-key
  controller limitation, the audits that stay best-effort), ADR-033 SO11 and ADR-027 as far as they describe the media policy audit, follow-ups `dn`
  (partly closed, the rest "not implemented, owner: only the three retention values"), and the audit writer carve-out.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)
  @deploy Path.join(@root, "docs/architecture/07-deployment.md")
  @adr033 Path.join(@root, "docs/architecture/adr/ADR-033-authorization-server-broker-model.md")
  @adr027 Path.join(@root, "docs/architecture/adr/ADR-027-media-config-table.md")
  @followups Path.join(@root, "docs/stories/oauth-broker/follow-ups.md")
  @writer Path.join(@root, "server/lib/nebu/compliance/audit_writer.ex")

  defp read(p), do: File.read!(p) |> String.replace(~r/\s+/, " ")

  defp between(text, from, to) do
    [_, rest] = String.split(text, from, parts: 2)
    assert String.contains?(rest, to), "the end marker #{inspect(to)} exists after #{inspect(from)}"
    [section | _] = String.split(rest, to, parts: 2)
    section
  end

  test "07-deployment: the media policy row names the one transaction, the policy per direction and what the admin sees" do
    row = between(read(@deploy), "| Media policy (`/admin/media/settings`)", "| Media storage target |")

    for word <- ["`media_config_updated`", "`released_delete_after_days`", "`deleted_days`", "`infected_days`", "one transaction", "shortening", "lengthening", "Failed to save media settings"] do
      assert row =~ word, word
    end
  end

  test "07-deployment: the section names the per-key limitation of the controller and the audits that stay best-effort (owner decision: only the three retention values)" do
    sec = between(read(@deploy), "### Admin configuration forms and their protection", "### Preconditions")

    for word <- ["media-retention-audit-atomic", "best-effort", "`media_storage_config_updated`", "`room_auto_join_changed`", "`max_upload_size_bytes`"] do
      assert sec =~ word, word
    end

    assert sec =~ ~r/per[- ]key/, "the limitation of the controller (one upsert per key, no cross-key atomicity) is named"
  end

  test "07-deployment: the operator rehearsal of group E covers the unwritable audit table for the media retention values" do
    e = between(read(@deploy), "**E. Operator rehearsals", "**F. Legacy SSO confirmation page")
    assert e =~ "media-retention-audit-atomic"
    assert e =~ "`deleted_days`"
  end

  test "ADR-033 SO11: the atomic audit of the media retention values is decided (story named), no longer listed as open" do
    sec = between(read(@adr033), "- **SO11 (the remaining admin forms", "- **SO8 ")

    for word <- ["media-retention-audit-atomic", "shortening"] do
      assert sec =~ word, word
    end

    refute sec =~ "the atomic audit of the media policy, the discarded pinned SSRF target", "the old \"not decided here\" entry for the media policy audit is gone"
  end

  test "ADR-027: the audit sentence names the story for the three retention values; the other keys stay best-effort" do
    sec = between(read(@adr027), "Every configuration change writes a `media_config_updated` audit-log entry", "A direct consequence")

    for word <- ["media-retention-audit-atomic", "best-effort"] do
      assert sec =~ word, word
    end
  end

  test "follow-ups: dn is PARTLY closed by the story; the rest is recorded as not implemented with the owner decision" do
    raw = File.read!(@followups)
    [row] = Regex.run(~r/^\| dn \|[^\n]*/m, raw)

    assert row =~ ~r/PARTLY CLOSED.*media-retention-audit-atomic/
    assert row =~ "implemented for the three retention values"
    assert row =~ "not implemented, owner: only the three retention values"
    assert row =~ "`room_auto_join_changed`"
    assert row =~ "storage target"
  end

  test "the AuditWriter carve-out paragraph names Nebu.Media.Config and the story as a caller of log/6 inside a transaction" do
    carve_out = between(read(@writer), "Carve-out (", "Error policy:")

    assert carve_out =~ "Nebu.Media.Config"
    assert carve_out =~ "media-retention-audit-atomic"
  end
end
