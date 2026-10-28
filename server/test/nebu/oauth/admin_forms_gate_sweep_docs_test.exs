defmodule Nebu.OAuth.AdminFormsGateSweepDocsTest do
  @moduledoc """
  Static checks (no DB, no network) for story `admin-forms-gate-sweep`, AC8: the decision table (ADR-033 SO11), the operator text in 07-deployment (protection table,
  break-glass SQL for the storage target, manual verification), 11-risks, the follow-ups rows (`de` closed, the new rows) and the new audit action.
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

  test "ADR-033: SO11 has the table: the levels, the media forms with the marker page, the test connection fix, L1 / R2 audit, and the residuals (LiveView, bootstrap, logout)" do
    sec = between(read(@adr), "- **SO11 (the remaining admin forms", "- **SO8 ")

    for word <- ["`click_gate/2`", "`/admin/media/settings`", ":secret_required", "`log_settings_changed`", "set_room_auto_join/3", "LiveView", "bootstrap", "`GET /admin/logout`", "SO7", "(a)", "(b)", "(c)", "break-glass", "one marker per page"] do
      assert sec =~ word, word
    end
  end

  test "07-deployment: the protection table names the new forms; the storage target has its break-glass SQL; group D lists the media settings browser check" do
    d = read(@deploy)
    sec = between(d, "### Admin configuration forms and their protection", "### Preconditions")

    for word <- ["Media policy", "Media storage target", "Test connection", "Log retention", "Delete device", "`media_storage_config`", "fresh sign-in", "log_settings_changed", "secret key"] do
      assert sec =~ word, word
    end

    group_d = between(d, "**D. Admin**", "**E. Operator rehearsals")
    assert group_d =~ "media settings"
    assert group_d =~ "test connection"
  end

  test "follow-ups: de is closed by the story, the new rows exist; 11-risks and the AuditWriter name the story and the action" do
    f = read(@followups)
    assert f =~ "| de | **CLOSED by story admin-forms-gate-sweep"
    for id <- ["dj", "dk", "dl", "dm", "dn", "do"], do: assert(f =~ "| #{id} |", id)
    assert read(@risks) =~ "admin-forms-gate-sweep"
    assert read(@writer) =~ "log_settings_changed"
  end
end
