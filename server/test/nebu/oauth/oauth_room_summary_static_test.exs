defmodule Nebu.OAuth.RoomSummaryStaticTest do
  @moduledoc """
  Static documentation checks (no DB, no network) for story `oauth-room-summary-unrecognized`,
  AC17 / "Doc edits": follow-ups gates ac and af closed, the deployment preconditions, the Matrix scope
  document, ADR-033, the oracle dev-support reference and the arc42 concepts chapter.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)

  defp read!(rel), do: File.read!(Path.join(@root, rel))

  defp row(text, id) do
    text |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "| #{id} |")) || flunk("no table row `| #{id} |`")
  end

  describe "AC17.1 — docs/stories/oauth-broker/follow-ups.md" do
    test "rows ac and af are closed by this story, row ad stays open and says why" do
      t = read!("docs/stories/oauth-broker/follow-ups.md")
      assert row(t, "ac") =~ ~r/\*\*Closed\*\* by story\s+oauth-room-summary-unrecognized/
      assert row(t, "af") =~ ~r/\*\*Closed\*\*\s+by story\s+oauth-room-summary-unrecognized/
      assert row(t, "ad") =~ ~r/\(G2\) stays open/
    end

    test "story-5 line (e) records that the M_UNRECOGNIZED part is closed and POST /register answers 403 (review m9)" do
      t = read!("docs/stories/oauth-broker/follow-ups.md")
      [line] = t |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "- (e) Known deviations pinned nowhere"))
      assert line =~ "M_UNRECOGNIZED part closed by P6b"
      assert line =~ "`POST /register` now answers `403 M_FORBIDDEN` for every caller, RU10a"
    end

    test "follow-up bf (GET /rooms/{id}/state[/...]) and the RU11a carve-out are recorded" do
      t = read!("docs/stories/oauth-broker/follow-ups.md")
      assert row(t, "bf") =~ "GET /rooms/{id}/state"
      assert row(t, "bf") =~ "RU11a"
      assert row(t, "bf") =~ "M_NOT_FOUND"
    end

    test "a new non-gating section lists the side findings (RU18 lazy room creation, RU6, restricted visibility, RU7)" do
      t = read!("docs/stories/oauth-broker/follow-ups.md")
      assert t =~ ~r/^## From story oauth-room-summary-unrecognized/m
      [_, section] = String.split(t, ~r/^## From story oauth-room-summary-unrecognized[^\n]*\n/m, parts: 2)
      section = section |> String.split(~r/^## /m, parts: 2) |> hd()
      assert section =~ ~r/RU18|lazy/i
      assert section =~ ~r/RU6|im\.nheko\.summary/
      assert section =~ ~r/restricted/i
      assert section =~ ~r/RU7|rate.limit/i
    end
  end

  describe "AC17.2 — docs/architecture/07-deployment.md" do
    test "precondition ac is closed; release notes announce the 404/405 M_UNRECOGNIZED answers; ae notes the 404 of /v3/versions" do
      t = read!("docs/architecture/07-deployment.md")
      assert row(t, "ac") =~ ~r/closed/i
      assert row(t, "ac") =~ "oauth-room-summary-unrecognized"
      assert t =~ ~r/unknown Matrix endpoints answer 404\/405\s+`M_UNRECOGNIZED`/
      assert t =~ ~r/\/v3\/versions.*404|404.*\/v3\/versions/s
    end
  end

  describe "AC17.3 — docs/matrix-api-scope.md" do
    test "room_summary is listed as supported (local only) and no longer a KNOWN GAP; the 404/405 rule replaces the old deviation text" do
      t = read!("docs/matrix-api-scope.md")
      assert t =~ ~r/\| GET \| `?\/_matrix\/client\/v1\/room_summary\/\{roomIdOrAlias\}`? \| ✅ \|/
      refute t =~ "KNOWN GAPS under the v1.15 claim: `room_summary`"
      assert t =~ "KNOWN GAPS under the v1.15 claim: (ad)"
      refute t =~ ~r/Known deviations, recorded and not pinned as correct: an unrouted endpoint answers `404 M_NOT_FOUND`/
      assert t =~ "an unrouted Matrix endpoint answers `404 M_UNRECOGNIZED`"
      assert t =~ "`POST /register` answers `403 M_FORBIDDEN`"
    end
  end

  describe "AC17.3b — scope document rules (review m9, RU11a)" do
    test "the media config rows say they answer 404 M_UNRECOGNIZED" do
      t = read!("docs/matrix-api-scope.md")

      rows =
        t
        |> String.split("\n")
        |> Enum.filter(&(&1 =~ ~r/^\| GET \| `\/_matrix\/(media\/v3|client\/v1\/media)\/config`/))

      assert length(rows) == 3
      for r <- rows, do: assert(r =~ "answers 404 M_UNRECOGNIZED", r)
    end

    test "the legend carries the 404 / 405 rule once, with the RU11a exception" do
      t = read!("docs/matrix-api-scope.md")
      [legend | _] = String.split(t, "\n---", parts: 2)
      assert legend =~ "an unrouted Matrix endpoint answers `404 M_UNRECOGNIZED`"
      assert legend =~ "`POST /register` answers `403 M_FORBIDDEN`"
      assert legend =~ "RU11a"
    end

    test "GET /rooms/{roomId}/state[/...] are listed as not implemented (🔲), no longer ✅ (RU11a, follow-up bf)" do
      t = read!("docs/matrix-api-scope.md")
      rows = t |> String.split("\n") |> Enum.filter(&(&1 =~ ~r/^\| GET \| `\/_matrix\/client\/v3\/rooms\/\{roomId\}\/state/))
      assert length(rows) == 2
      for r <- rows, do: assert(r =~ "🔲" and r =~ "RU11a", r)
    end
  end

  describe "AC17.4 — ADR-033" do
    test "section 'Room summary and `M_UNRECOGNIZED`' lists RU1..RU18 and the ac / af gate status" do
      t = read!("docs/architecture/adr/ADR-033-authorization-server-broker-model.md")
      assert t =~ ~r/^## Room summary and `M_UNRECOGNIZED`/m
      [_, section] = String.split(t, ~r/^## Room summary and `M_UNRECOGNIZED`[^\n]*\n/m, parts: 2)
      for n <- 1..18, do: assert(section =~ ~r/\bRU#{n}\b/, "RU#{n} missing")
      assert section =~ ~r/\bac\b/
      assert section =~ ~r/\baf\b/
      assert section =~ ~r/\bRU11a\b/
    end
  end

  describe "AC17.5 / AC17.6 — oracle dev-support reference and the arc42 concepts chapter" do
    test "dev-support documents the 404 / 405 M_UNRECOGNIZED rule and restricts the 400 usage" do
      t = read!("_bmad/memory/nebu-agent-oracle/references/dev-support.md")
      assert t =~ ~r/404 \/ 405: `M_UNRECOGNIZED`/
      assert t =~ "400: `M_UNRECOGNIZED` only where an endpoint defines it"
      assert t =~ ~r/Room summary/i
    end

    test "08-concepts has an 'Unrecognized endpoints (RU9-RU11)' paragraph" do
      t = read!("docs/architecture/08-concepts.md")
      assert t =~ "Unrecognized endpoints (RU9-RU11)"
      assert t =~ ~r/match.*authenticate.*dispatch/s
    end
  end
end
