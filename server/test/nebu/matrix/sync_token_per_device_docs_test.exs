defmodule Nebu.Matrix.SyncTokenPerDeviceDocsTest do
  @moduledoc """
  Static check (no DB, no network) for story `sync-token-per-device`, Scenario 14 / D7: follow-up `fd` of `docs/stories/oauth-broker/follow-ups.md` is closed.

  The row becomes "**CLOSED by story sync-token-per-device (date): ...**" followed by the ORIGINAL text, so the docs tests that pin the `fd` text stay green:
  `sync_membership_partition_docs_test.exs` l.121 (`per user`, `device`, `` `sync_tokens` ``, `fall`; the row is attributed to `sync-membership-partition`) and l.233
  (`docs/architecture/07-deployment.md` still contains `` `fd` ``). Rows `cj`-`cm` carry this story's follow-ups (written 2026-10-26 with the story: this suite is
  GREEN for them from the start and pins them against loss), and the id line keeps `unused:[^.]*`gm` onward` (eight docs suites pin that pattern).

  The pins are facts and unique new terms, not whole sentences.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)
  @followups Path.join(@root, "docs/stories/oauth-broker/follow-ups.md")
  @deploy Path.join(@root, "docs/architecture/07-deployment.md")
  @scope Path.join(@root, "docs/matrix-api-scope.md")
  @story "sync-token-per-device"

  defp read(p), do: File.read!(p) |> String.replace(~r/\s+/, " ")

  defp line(id) do
    lines = @followups |> File.read!() |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "| #{id} | "))
    assert length(lines) == 1, "the follow-up row #{id} must exist exactly once (found #{length(lines)})"
    lines |> hd() |> String.replace(~r/\s+/, " ")
  end

  # the second cell of the row (the text), whitespace normalised
  defp text(id), do: line(id) |> String.split(" | ", parts: 3) |> Enum.at(1)
  defp cells(id), do: String.split(line(id), " | ")
  defp status(id), do: line(id) |> String.split(" | ") |> List.last() |> String.trim_trailing(" |")

  # ─── fd ─────────────────────────────────────────────────────────────────────────

  describe "follow-ups: row fd is closed by this story" do
    test "the row opens with the CLOSED marker of this story and a date, its status column is closed, and it keeps exactly 4 cells" do
      assert read(@followups) =~ ~r/\| fd \| \*\*CLOSED by story #{@story} \(\d{4}-\d{2}-\d{2}/, "the row opens with \"**CLOSED by story #{@story} (date)\""
      assert line("fd") =~ ~r/\| closed \|\s*\z/, "the status column is `closed` (it was `open, non-gating`)"
      refute line("fd") =~ "open, non-gating"
      assert length(cells("fd")) == 4, "a ` | ` inside the text shifts the table columns"
    end

    test "the ORIGINAL text stays (per user, device, `sync_tokens`, fall) and the row is still attributed to sync-membership-partition" do
      row = text("fd")

      assert row =~ "The since token is per user, not per device (pre-existing)"
      for word <- ["per user", "device", "`sync_tokens`", "fall"], do: assert(row =~ word, "fd mentions #{word}")
      assert line("fd") =~ "sync-membership-partition", "the origin cell is unchanged"
    end

    test "the closure names device-less, the rollout fallback, per-device account data / cross-signing positions, the own user on a fallback, the wake-up" do
      row = text("fd")

      assert row =~ ~r/device-less/i, "D2: requests without a device id keep the per-user token"
      assert row =~ ~r/rollout/i, "D3: one full initial sync per device after the update"
      assert row =~ ~r/global account data/i, "D9"
      assert row =~ ~r/cross-signing/i, "D9"
      assert row =~ ~r/position/i, "D9: per-device positions instead of the consume-once flags"
      assert row =~ ~r/device_lists\.changed/, "D10: the own user on a fallback"
      assert row =~ ~r/wake-?up/i, "D11"
      assert row =~ "`cj`" and row =~ "`cm`", "the follow-ups of this story"
    end

    # DELIBERATE amendment by story sync-stream-position (D17), old -> new: `fc` was pinned OPEN here (the edit of THIS story must not close it); story
    # sync-stream-position closes it. Its closure wording and status are pinned ONLY by `sync_stream_position_docs_test.exs`; what stays pinned here:
    # this story's edit did not lose the row, and `fe` stays CLOSED.
    test "no other row was closed or lost by the edit: fc still exists exactly once and fe stays CLOSED" do
      assert String.starts_with?(line("fc"), "| fc | ")
      assert line("fe") =~ ~r/\| fe \| \*\*CLOSED by story sync-wakeups-cluster-wide/
    end
  end

  # ─── cj - cm ────────────────────────────────────────────────────────────────────

  describe "follow-ups: rows cj, ck, cl and cm" do
    for {id, words, status_pattern} <- [
          {"cj", ["orphan", "(a)", "(b)", "(c)", "device-less", "`fc`"], "open, non-gating"},
          # DELIBERATE amendment by story gdpr-erasure-global-data (D6), old -> new: `ck` was pinned OPEN ("open, owner decision", the words OWNER DECISION);
          # the story CLOSES it (the owner decided "fix ck", 2026-10-27): the status column is `closed`, the original text stays. Its closure wording is pinned
          # ONLY by `compliance/user_deletion_docs_test.exs`; what stays pinned here: the row exists once, keeps 4 cells, its origin and its facts.
          {"ck", ["GDPR", "account_data", "cross_signing_keys", "HIGH"], "closed"},
          {"cl", ["device_unused_fallback_key_types", "per user", "per device"], "open, non-gating"},
          {"cm", ["device_lists", "`left`", "OWN user"], "open, non-gating"}
        ] do
      test "row #{id} exists once, has 4 cells, names this story, has its recorded status, and carries its facts" do
        id = unquote(id)
        assert length(cells(id)) == 4, "#{id}: exactly 4 cells"
        assert line(id) =~ @story, "#{id} is attributed to #{@story}"
        assert status(id) =~ unquote(status_pattern), "#{id}: status column #{inspect(status(id))}"
        for word <- unquote(words), do: assert(text(id) =~ word, "#{id} mentions #{word}")
      end
    end

    test "the four ids appear as rows exactly once each and nowhere else as a row start" do
      starts = @followups |> File.read!() |> String.split("\n") |> Enum.map(&Regex.run(~r/\A\| (\w+) \| /, &1)) |> Enum.reject(&is_nil/1) |> Enum.map(&List.last/1)
      for id <- ["cj", "ck", "cl", "cm", "fd"], do: assert(Enum.count(starts, &(&1 == id)) == 1, "#{id} must be a unique row id")
    end
  end

  describe "follow-ups: the id line" do
    test "still matches unused:[^.]*`gm` onward (eight docs suites pin it) and names cj - cm as used by this story" do
      f = read(@followups)
      assert f =~ ~r/unused:[^.]*`gm` onward/, "unused ids continue at gm"
      assert f =~ "`cj`, `ck`, `cl` and `cm`", "the four formerly unused ids are recorded"
      assert f =~ @story
      refute f =~ ~r/unused:[^.]*`c[jklm]`[^.]*`gm` onward/, "cj - cm are no longer listed as unused"
    end
  end

  # ─── release notes and scope ────────────────────────────────────────────────────

  describe "07-deployment: the release notes" do
    test "`fd` stays named but as CLOSED by this story: per device, device-less clients keep the per-user token, cj" do
      deploy = read(@deploy)

      assert deploy =~ "`fd`"
      assert deploy =~ ~r/`fd` closed by story #{@story}/, "the residual becomes a closure"
      assert deploy =~ ~r/device-less clients keep the per-user token/i
      assert deploy =~ "`cj`"
      refute deploy =~ "`fd` multi-device fallbacks", "no longer a residual of the leave guarantee"
      refute deploy =~ ~r/clients do not get leaves that happened while another session of the same user was syncing/, "the old release-note claim (the since token is per user) is gone"
    end

    test "the release note tells operators that after the update each client does ONE full sync (D3)" do
      assert read(@deploy) =~ ~r/after the update each client does one full (initial )?sync/i
    end
  end

  describe "matrix-api-scope: the /sync row" do
    defp sync_row do
      case @scope |> File.read!() |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "| GET | `/_matrix/client/v3/sync` |")) do
        nil -> flunk("the /sync row of docs/matrix-api-scope.md does not exist")
        row -> String.replace(row, ~r/\s+/, " ")
      end
    end

    test "the per-user since token is no longer a residual; the row names this story, the per-device token and positions, and the device-less exception" do
      row = sync_row()

      refute row =~ "`fd` (per-user since token", "the residual is dropped"
      assert row =~ @story
      assert row =~ ~r/per[- ]device/i
      assert row =~ ~r/position/i
      assert row =~ ~r/device-less/i
      assert row =~ ~r/wake-?up/i
    end

    test "global account data is no longer described as a consume-once flag without the device-less qualification" do
      refute sync_row() =~ "(consume-once `changed` flag; account-data-durability)"
    end

    test "the cross-signing paragraph says the own user is listed per device (every device, the uploader included)" do
      scope = read(@scope)
      assert [_, tail] = String.split(scope, "After a successful `device_signing/upload`, the uploading user's own ID is surfaced in", parts: 2)
      paragraph = String.slice(tail, 0, 900)
      assert paragraph =~ ~r/per device|every device|each device/i
    end
  end

  # ─── code-level docs ────────────────────────────────────────────────────────────

  describe "code docs" do
    test "the two store sources describe the new positions (the flag is no longer the whole story); wording and layout are free" do
      account = File.read!(Path.join(@root, "server/lib/nebu/matrix/account_data_store.ex"))
      cross = File.read!(Path.join(@root, "server/lib/nebu/matrix/cross_signing_key_store.ex"))

      assert account =~ "stream_pos"
      assert cross =~ "changed_pos"
    end
  end
end
