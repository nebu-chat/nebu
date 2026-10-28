defmodule Nebu.OAuth.SpaceEditAuditDocsTest do
  @moduledoc """
  Static checks (no DB, no network) for story `space-edit-audit` (follow-up `dj`), AC9: 07-deployment (audit coverage and the D3 policy), ADR-033 SO11 (the audit inventory names
  the four actions), the follow-ups rows (`dj` closed, `dk` / `dl` / `dm` recorded as "decided: no audit") and the AuditWriter comment naming the story.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)
  @deploy Path.join(@root, "docs/architecture/07-deployment.md")
  @adr Path.join(@root, "docs/architecture/adr/ADR-033-authorization-server-broker-model.md")
  @followups Path.join(@root, "docs/stories/oauth-broker/follow-ups.md")
  @writer Path.join(@root, "server/lib/nebu/compliance/audit_writer.ex")

  @actions ["`space_name_changed`", "`space_topic_changed`", "`space_child_added`", "`space_child_removed`"]

  defp read(p), do: File.read!(p) |> String.replace(~r/\s+/, " ")

  defp between(text, from, to) do
    [_, rest] = String.split(text, from, parts: 2)
    assert String.contains?(rest, to), "the end marker #{inspect(to)} exists after #{inspect(from)}"
    [section | _] = String.split(rest, to, parts: 2)
    section
  end

  # The section "### Admin configuration forms and their protection" already mentions `events` / "logged" / "reversible" elsewhere, so the pins below use phrases
  # that only the space-edit-audit paragraph introduces (each is checked as a unique, new formulation).
  @section_from "### Admin configuration forms and their protection"
  @section_to "### Preconditions"

  test "07-deployment: the admin forms section names the four space actions, the entry point and the D3 policy (not atomic, a failed audit write is logged and does not undo the edit)" do
    sec = between(read(@deploy), @section_from, @section_to)

    for word <- @actions ++ ["Nebu.Matrix.set_space_state/5", "space-edit-audit"] do
      assert sec =~ word, word
    end

    assert sec =~ ~r/not atomic/i
    assert sec =~ ~r/(does not|doesn't|never) undo/i
    # unique phrases of the D3 paragraph (the words `events`, `logged`, `reversible` alone occur elsewhere in the section and prove nothing)
    assert sec =~ "primary record of a space edit"
    assert sec =~ "failed audit write is logged"
    assert sec =~ "non-destructive and reversible"
  end

  test "07-deployment: the table row of rooms / spaces points to the space audit rows" do
    sec = between(read(@deploy), @section_from, @section_to)
    [row] = Regex.run(~r/\| Delete device, force-leave[^|]*\|[^|]*\|[^|]*\|[^|]*\|/, sec)
    assert row =~ "space_name_changed"
    assert row =~ "space_child_removed"
  end

  test "07-deployment: the SIEM / audit coverage note says that a Matrix client edit (PUT state) is NOT an admin action and writes no space row" do
    sec = between(read(@deploy), @section_from, @section_to)
    assert sec =~ "PUT /_matrix/client/v3/rooms/"
    assert sec =~ "no space audit row" or sec =~ "writes no space row" or sec =~ "no audit row"
  end

  test "ADR-033: the SO11 audit inventory names the four space actions and the entry point (Nebu.Matrix.set_space_state/5, not Dispatcher.set_room_state/2)" do
    sec = between(read(@adr), "- **SO11 (the remaining admin forms", "- **SO8 ")

    for word <- @actions ++ ["`Nebu.Matrix.set_space_state/5`", "`Dispatcher.set_room_state/2`", "space-edit-audit"] do
      assert sec =~ word, word
    end

    refute sec =~ ~r/Not decided here[^.]*audit rows for space edits/i, "the space-edit audit is decided and implemented now, it must not stay in the `Not decided here` list"
    refute sec =~ "audit rows for space edits, `configure_logging`"
    assert sec =~ ~r/decided: no audit/i, "dk / dl / dm are recorded as decided without audit"
  end

  test "follow-ups: dj is closed by the story space-edit-audit" do
    assert read(@followups) =~ "| dj | **CLOSED by story space-edit-audit"
  end

  for id <- ["dk", "dl", "dm"] do
    test "follow-ups: #{id} is recorded as decided: no audit (owner decision 2026-10-15)" do
      f = read(@followups)
      assert [_, rest] = String.split(f, "| #{unquote(id)} | ", parts: 2)
      [row | _] = String.split(rest, " | ", parts: 2)
      assert row =~ ~r/decided: no audit/i, String.slice(row, 0, 120)
    end
  end

  test "AuditWriter: the allowlist comment names the story and the four actions" do
    w = read(@writer)
    assert w =~ "space-edit-audit"
    for a <- ["space_name_changed", "space_topic_changed", "space_child_added", "space_child_removed"], do: assert(w =~ a, a)
  end
end
