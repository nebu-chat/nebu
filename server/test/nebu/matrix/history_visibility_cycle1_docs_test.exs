defmodule Nebu.Matrix.HistoryVisibilityCycle1DocsTest do
  @moduledoc """
  Static checks (no network) for story `history-visibility-enforcement`, security cycle 1 (decisions 1-7 of
  `_bmad-output/nebu/epics/oauth-broker/step-results/history-visibility-enforcement/code-review-findings.md`): the reworded docs rows
  name the new bounds (cap, tier, timeout, linear cost), the `gj` validation, the read-markers rule, the clock-skew clamp option and the
  Q-hv1 wording. The pins are facts and unique terms; the earlier pins of `history_visibility_docs_test.exs` stay untouched.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)
  @scope Path.join(@root, "docs/matrix-api-scope.md")
  @deploy Path.join(@root, "docs/architecture/07-deployment.md")
  @runtime Path.join(@root, "docs/architecture/06-runtime.md")
  @followups Path.join(@root, "docs/stories/oauth-broker/follow-ups.md")
  @changelog Path.join(@root, "CHANGELOG.md")

  defp flat(text), do: String.replace(text, ~r/\s+/, " ")
  defp lines(p), do: p |> File.read!() |> String.split("\n")

  defp row(path, prefix) do
    line = Enum.find(lines(path), &String.starts_with?(&1, prefix))
    assert line, "no row starting with #{prefix}"
    flat(line)
  end

  defp cells(id), do: row(@followups, "| #{id} | ") |> String.trim_leading("| ") |> String.trim_trailing(" |") |> String.split(" | ")

  test "scope doc: the PUT state row names the validation, the cap and the moderation charge" do
    put = row(@scope, "| PUT | `/_matrix/client/v3/rooms/{roomId}/state/{eventType}/{stateKey}` | ")

    for word <- ["`400 M_BAD_JSON`", "`429 M_LIMIT_EXCEEDED`", "256", "`moderation`", "`m.room.join_rules`", "`m.room.guest_access`", "`gj`"] do
      assert put =~ word, "the PUT state row mentions #{word}"
    end
  end

  test "scope doc: the request read rows name the 2 s statement timeout; /read_markers checks visibility" do
    for prefix <- [
          "| GET | `/_matrix/client/v3/rooms/{roomId}/messages` | ",
          "| GET | `/_matrix/client/v3/rooms/{roomId}/event/{eventId}` | ",
          "| GET | `/_matrix/client/v1/rooms/{roomId}/relations/{eventId}` | ",
          "| POST | `/_matrix/client/v3/search` | "
        ] do
      assert row(@scope, prefix) =~ "2 s statement timeout"
    end

    assert row(@scope, "| GET | `/_matrix/client/v3/rooms/{roomId}/messages` | ") =~ "NUL"
    markers = row(@scope, "| POST | `/_matrix/client/v3/rooms/{roomId}/read_markers` | ")
    assert markers =~ "may see" and markers =~ "no existence oracle"
  end

  test "follow-ups: gj is CLOSED by the security cycle, gk names the exploits, the bounds and the clamp, gl (c) the /redact oracle" do
    [_id, gj_text, _origin, gj_status] = cells("gj")
    assert gj_text =~ "**CLOSED by story history-visibility-enforcement, security cycle 1"
    assert String.downcase(gj_status) =~ "closed"

    gk = Enum.join(cells("gk"), " | ")
    for word <- ["exploit A", "exploit B", "pool", "O(B log B)", "256", "`moderation`", "2 s statement timeout", "clamp", "`last_ts`"], do: assert(gk =~ word, "gk mentions #{word}")

    assert Enum.join(cells("gl"), " ") =~ "`/redact`"
  end

  test "07-deployment: the limits and the Q-hv1 wording (a changed-back room is not listed)" do
    deploy = File.read!(@deploy) |> flat()
    assert [_, sec] = String.split(deploy, "**History visibility (story history-visibility-enforcement, follow-up `es`).**", parts: 2)
    assert sec =~ "changed back" and sec =~ "NOT listed"
    assert sec =~ "256" and sec =~ "`429 M_LIMIT_EXCEEDED`" and sec =~ "2 s"
  end

  test "06-runtime: the bounds of the fragment (O(B log B), the cap, the request statement timeout, not on /sync)" do
    runtime = File.read!(@runtime) |> flat()
    assert runtime =~ "O(B log B)" and runtime =~ "statement_timeout = '2s'" and runtime =~ "256"
    assert runtime =~ "the `/sync` reads are not"
  end

  test "CHANGELOG: a Changed entry names the gj validation, the cap and the read markers" do
    [_, unreleased] = String.split(File.read!(@changelog), "## [Unreleased]", parts: 2)
    [unreleased | _] = String.split(unreleased, ~r/\n## \[/, parts: 2)
    entry = unreleased |> String.split(~r/\n- /) |> Enum.find(&(&1 =~ "security cycle 1" and &1 =~ "M_BAD_JSON"))
    assert entry, "the Changed entry of the security cycle"
    for word <- ["`429 M_LIMIT_EXCEEDED`", "`moderation`", "`POST /read_markers`", "`gj`"], do: assert(flat(entry) =~ word)
  end
end
