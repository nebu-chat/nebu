defmodule Nebu.Compliance.UserDeletionDocsTest do
  @moduledoc """
  Static check (no DB, no network) for the documentation half (D6) of story `gdpr-erasure-global-data` (epic oauth-broker, follow-up `ck`, REQ-2026-005):

    * `docs/architecture/08-concepts.md`: an inventory section (a heading that contains "erasure" and "inventory") names EVERY table of the inventory (erased,
      ended by the session teardown, retained on purpose) and gives each retained table its reason; the "Erasure / deactivation, known limitations" paragraph
      loses limitation (a) (global `account_data` is deleted now).
    * `docs/stories/oauth-broker/follow-ups.md`: `ck` is CLOSED by this story in the usual format (status `closed`, the original text stays), `cj` (a) carries a
      note for the erasure part, one NEW row records the missing admin route / stale runbook text (D9), the id line stays intact (eight suites pin
      `unused:[^.]*`gm` onward`) and names the new row's id.
    * `docs/architecture/06-runtime.md` (the erasure paragraph), `docs/compliance/gdpr-deletion-runbook.md` (verification queries for the newly covered tables, the
      pipeline row of `DeleteUserKeys`), `docs/architecture/07-deployment.md` (the release note: behaviour change, the one-off sweep of D8; the sweep SQL itself is
      pinned and RUN by `user_deletion_sweep_test.exs`).

  The table lists come from the SAME sources as the real-database suites (`UserDeletion.erased_tables/0`, `UserDeletionTestSupport`), so a new table breaks the docs
  test together with the schema guard. Pins are facts and unique terms, not whole sentences. The old staged pin of `ck` (`sync_token_per_device_docs_test.exs`:
  status "open, owner decision") is amended deliberately by this story.
  """
  use ExUnit.Case, async: true

  alias Nebu.Compliance.UserDeletionTestSupport, as: E

  @root Path.expand("../../../..", __DIR__)
  @concepts Path.join(@root, "docs/architecture/08-concepts.md")
  @runtime Path.join(@root, "docs/architecture/06-runtime.md")
  @deploy Path.join(@root, "docs/architecture/07-deployment.md")
  @runbook Path.join(@root, "docs/compliance/gdpr-deletion-runbook.md")
  @followups Path.join(@root, "docs/stories/oauth-broker/follow-ups.md")
  @story "gdpr-erasure-global-data"

  defp read(path), do: File.read!(path)
  defp squash(text), do: String.replace(text, ~r/\s+/, " ")

  defp inventory_tables, do: Enum.uniq(apply(Nebu.Compliance.UserDeletion, :erased_tables, []) ++ E.expected_erased() ++ E.teardown_tables() ++ Map.keys(E.retained_reasons()))

  # the text of the first section whose heading contains `words` (all, case-insensitive) up to the next heading of the same or a higher level
  defp section(text, words) do
    lines = String.split(text, "\n")

    start =
      Enum.find_index(lines, fn l ->
        case Regex.run(~r/\A(\#{2,6}) (.*)\z/, l) do
          [_, _, title] -> Enum.all?(words, &(String.downcase(title) =~ &1))
          _ -> false
        end
      end)

    if is_nil(start), do: flunk("no heading containing #{inspect(words)}")
    [_, hashes, _] = Regex.run(~r/\A(\#{2,6}) (.*)\z/, Enum.at(lines, start))
    level = String.length(hashes)

    rest = Enum.drop(lines, start + 1)
    body = Enum.take_while(rest, fn l -> not (Regex.match?(~r/\A\#{1,6} /, l) and String.length(hd(Regex.run(~r/\A(\#+)/, l))) <= level) end)
    Enum.join([Enum.at(lines, start) | body], "\n")
  end

  # the row of the follow-up table that starts with `| id | `
  defp row(id) do
    rows = @followups |> read() |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "| #{id} | "))
    assert length(rows) == 1, "the follow-up row #{id} must exist exactly once (found #{length(rows)})"
    squash(hd(rows))
  end

  defp cells(row), do: String.split(row, " | ")
  defp status(row), do: row |> cells() |> List.last() |> String.trim_trailing(" |")

  # ═══ 08-concepts ═════════════════════════════════════════════════════════════════════════════════════════════════════════

  describe "08-concepts: the erasure inventory" do
    test "a section 'erasure ... inventory' names the story, the one transaction, the retained events and the anonymised profile" do
      sec = squash(section(read(@concepts), ["erasure", "inventory"]))
      assert sec =~ @story
      assert sec =~ ~r/same transaction|one transaction|single transaction/i
      assert sec =~ ~r/room history preservation|events .{0,60}(retained|not (erased|deleted))/i
      assert sec =~ "Deleted User" and sec =~ "anonymized_at"
      assert sec =~ "deactivation" and sec =~ ~r/reversible|keeps/i, "deactivation keeps the data"
    end

    test "the `devices` line says that LEGACY devices are removed by the teardown (D12)" do
      lines = section(read(@concepts), ["erasure", "inventory"]) |> String.split("\n")
      assert Enum.any?(lines, &(&1 =~ "`devices`" and &1 =~ ~r/legacy/i)), "no line names `devices` together with legacy devices"
    end

    test "it names EVERY table of the inventory (erased, ended by the session teardown, retained on purpose)" do
      sec = section(read(@concepts), ["erasure", "inventory"])
      for table <- inventory_tables(), do: assert(sec =~ "`#{table}`", "the inventory section does not name the table `#{table}` (in backticks)")
    end

    test "every table retained on purpose carries its reason on the line that names it" do
      lines = section(read(@concepts), ["erasure", "inventory"]) |> String.split("\n")

      for table <- Map.keys(E.retained_reasons()) do
        line = Enum.find(lines, &(&1 =~ "`#{table}`" and String.length(&1) >= 60 and &1 =~ ~r/retain|kept|stays|not erased|not deleted|dormant/i))
        assert line, "table #{table} is retained on purpose but no line of the inventory gives a reason (retained / kept / stays / dormant)"
      end
    end

    test "it describes the recurrence guard (a test that fails for a new per-user table) and the erased_tables list" do
      sec = squash(section(read(@concepts), ["erasure", "inventory"]))
      assert sec =~ ~r/recurrence guard/i and sec =~ "UserDeletion" and sec =~ "erased_tables"
      assert sec =~ ~r/new (per-user )?table|new migration/i
    end

    test "the sweep for users erased before the release is mentioned (D8)" do
      sec = squash(section(read(@concepts), ["erasure", "inventory"]))
      assert sec =~ ~r/\bsweep\b/i and sec =~ "keys_deleted", "the one-off sweep for users with deletion_status keys_deleted"
    end
  end

  describe "08-concepts: Erasure / deactivation, known limitations" do
    test "the paragraph stays, limitation (a) is gone, the other limitations stay" do
      text = squash(section(read(@concepts), ["erasure", "deactivation", "limitations"]))
      refute text =~ "global `account_data` rows are not deleted by erasure", "limitation (a) is fixed by this story"
      refute text =~ ~r/\(a\) global .account_data. rows are not deleted/i
      assert text =~ "`cj` (c)", "(b) stays"
      assert text =~ "M_UNRECOGNIZED" and text =~ ~r/room-fetch timeout/ and text =~ "sync filters"
      assert text =~ ~r/account_data|account data/ and text =~ ~r/erasure/i
    end
  end

  # ═══ follow-ups ══════════════════════════════════════════════════════════════════════════════════════════════════════════

  describe "follow-ups: ck is closed" do
    test "the row opens with the CLOSED marker of this story and a date, its status is closed, 4 cells, the original text stays" do
      ck = row("ck")
      assert ck =~ ~r/\A\| ck \| \*\*CLOSED by story #{@story} \(\d{4}-\d{2}-\d{2}/, "the row opens with \"**CLOSED by story #{@story} (date)\""
      assert ck =~ ~r/\| closed \|\s*\z/, "the status column is `closed`"
      refute status(ck) =~ "open"
      assert length(cells(ck)) == 4, "a ` | ` inside the text shifts the table columns"
      assert ck =~ "GDPR erasure leaves the global account data", "the ORIGINAL text stays"
      # review cycle 0 (MINOR-7), old -> new: the file convention is `Original item:` (43 rows), not `ORIGINAL TEXT:`
      assert ck =~ "Original item: **GDPR erasure leaves" and not (ck =~ "ORIGINAL TEXT")
      assert ck =~ "sync-token-per-device", "the origin cell is unchanged"
    end

    test "the closure names the tables, the one transaction, the guard, the in-flight initial sync, the one-off sweep and the profile" do
      ck = row("ck")
      for term <- ["account_data", "cross_signing_keys", "device_keys"], do: assert(ck =~ term, "ck mentions #{term}")
      assert ck =~ ~r/same transaction|one transaction/i
      assert ck =~ ~r/guard/i, "the schema recurrence guard"
      assert ck =~ ~r/initial sync/i and ck =~ "`cj` (a)", "the in-flight initial sync, cj (a)"
      assert ck =~ ~r/sweep|one-off/i, "D8"
      assert ck =~ ~r/Deleted User|profile/i, "D9"
    end

    test "cj (a) carries a note for the erasure part, and keeps its 4 cells" do
      cj = row("cj")
      assert length(cells(cj)) == 4
      assert cj =~ @story
      [_before, note] = String.split(cj, @story, parts: 2)
      assert note =~ ~r/erasure/i and note =~ ~r/initial sync|sync_tokens|token/i
    end
  end

  describe "follow-ups: the new row (D9) and the id line" do
    # D15: the new follow-up row for the missing admin route / stale runbook text has the id `cn`
    defp new_row do
      r = row("cn")
      assert r =~ "DELETE /api/v1/admin/users/{userId}" and r =~ @story, "row cn records the missing DELETE /api/v1/admin/users/{userId} pipeline found by #{@story}"
      refute String.starts_with?(r, "| ck | ") or String.starts_with?(r, "| cj | ")
      r
    end

    test "exists once with a unique id, 4 cells, an open status; says the pipeline is not in the Elixir server" do
      r = new_row()
      assert length(cells(r)) == 4
      assert status(r) =~ ~r/\Aopen/i
      assert r =~ ~r/not (implemented|in the Elixir server)|missing|no route|does not exist/i
      assert r =~ ~r/runbook/i

      assert String.starts_with?(r, "| cn | "), "D15: the id is cn (the only free id that is not reserved)"
    end

    test "the id line stays intact (`gm` onward is pinned by eight suites) and names the new row and the story" do
      f = squash(read(@followups))
      assert f =~ ~r/unused:[^.]*`gm` onward/
      assert f =~ "Reserved for the backlog story: bv, bw, bm, bn, bo"
      assert f =~ "`cj`, `ck`, `cl` and `cm`"

      _ = new_row()
      id_line = @followups |> read() |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "**Follow-up ids.**")) |> squash()
      assert id_line =~ "`cn`" and id_line =~ @story, "the id line records `cn` as used by #{@story}"
    end
  end

  # ═══ 06-runtime ══════════════════════════════════════════════════════════════════════════════════════════════════════════

  describe "06-runtime: the erasure paragraph" do
    test "says what the transaction deletes now (account data, cross-signing, device keys, ...), the profile, the post-commit teardown" do
      text = squash(read(@runtime))
      [_, para] = Regex.run(~r/(GDPR key erasure \(delete_user_keys\/2\).{0,2500})/, text)
      for term <- ["account_data", "cross_signing_keys", "device_keys"], do: assert(para =~ term, "06-runtime: the erasure paragraph does not mention #{term}")
      assert para =~ ~r/transaction/i and para =~ ~r/anonymi[sz]/i and para =~ "Deleted User"
      assert para =~ ~r/after the commit/i, "the teardown stays post-commit, best effort"
    end
  end

  # ═══ runbook ═════════════════════════════════════════════════════════════════════════════════════════════════════════════

  describe "runbook: verification queries and the DeleteUserKeys row" do
    test "the Verification Queries section checks every newly covered table (a count that must be 0)" do
      sec = section(read(@runbook), ["verification", "queries"])

      for table <- apply(Nebu.Compliance.UserDeletion, :erased_tables, []) do
        assert sec =~ ~r/\b#{table}\b/, "the runbook verification queries do not check #{table}"
      end

      assert sec =~ ~r/COUNT\(\*\)/i
    end

    test "the DeleteUserKeys pipeline row no longer claims keys only: it names the account data / cross-signing deletion" do
      row = read(@runbook) |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "| 5 | "))
      assert row, "the pipeline table has no step 5 row"
      assert row =~ ~r/account data|account_data/i and row =~ ~r/cross-signing|cross_signing/i
    end
  end

  # ═══ 07-deployment ═══════════════════════════════════════════════════════════════════════════════════════════════════════

  describe "07-deployment: the release note" do
    defp note do
      paragraphs = @deploy |> read() |> String.split(~r/\n\s*\n/)

      case Enum.find(paragraphs, &(&1 =~ @story and &1 =~ ~r/erasure/i)) do
        nil -> flunk("docs/architecture/07-deployment.md has no paragraph about #{@story} and the erasure (the release note)")
        p -> squash(p)
      end
    end

    test "tells operators what changes: account data, cross-signing keys, device keys and the other tables; behaviour note, migration stated" do
      n = note()
      for term <- ["account_data", "cross_signing_keys", "device_keys"], do: assert(n =~ term, "the release note does not mention #{term}")
      assert n =~ "migration 000055", "D11: the note names the migration"
      assert n =~ ~r/polic(y|ies)/i and n =~ ~r/oauth_codes/, "D11: policy only, for oauth_codes"
      assert n =~ ~r/no table rewrite/i
      assert n =~ ~r/behaviou?r/i
    end

    test "tells operators about the one-off sweep for users erased before (OQ-A / D8): one-off, idempotent, after the deploy, keys_deleted" do
      n = note()
      assert n =~ ~r/one-off/i and n =~ ~r/idempotent/i and n =~ "keys_deleted"
      assert n =~ ~r/after the (deploy|update|rollout)/i
      assert n =~ "`devices`", "D13: the sweep also deletes the devices rows of the erased users"
      # review cycle 0 (D18 (a)), old -> new: the sweep now ALSO deletes the other teardown tables (it is the retry path of a failed teardown); the note
      # said they were "not swept" (D13)
      refute n =~ ~r/other teardown tables.{0,80}not swept/i, "the other teardown tables ARE swept now (D18 (a))"
      assert n =~ ~r/teardown tables/i and n =~ ~r/retry path/i, "the sweep is the retry path of a failed teardown"
    end
  end

  # ═══ review cycle 0 (D16 - D19) ══════════════════════════════════════════════════════════════════════════════════════════

  describe "review cycle 0: the docs say what the code does" do
    test "08-concepts Three PII Tiers: the display name / avatar are NOT shredded by the key deletion, the erasure NULLs the columns (D16)" do
      tiers = section(read(@concepts), ["three", "pii", "tiers"]) |> squash()
      assert tiers =~ ~r/server-wide/i and tiers =~ "pii_encryption_key", "Tier 1 is encrypted with the server-wide key"
      assert tiers =~ ~r/NULL/, "the erasure sets the ciphertext columns to NULL"
      assert tiers =~ ~r/backups?/i, "irrecoverable only once the backups have expired"
    end

    test "08-concepts inventory: the users line says the PII columns are NULLed (not crypto-shredded) and is_active = false (D16, D17)" do
      lines = section(read(@concepts), ["erasure", "inventory"]) |> String.split("\n")
      users = Enum.find(lines, &String.starts_with?(&1, "- `users`:"))
      assert users, "no `users` line"
      assert users =~ "NULL" and users =~ "is_active = false" and users =~ ~r/not crypto-shredded/i
      refute users =~ ~r/PII columns are crypto-shredded/i
    end

    test "08-concepts inventory: terminal for authentication, the 403, the lock order in the order of the code, the failing step in the audit (D17, D18)" do
      sec = squash(section(read(@concepts), ["erasure", "inventory"]))
      assert sec =~ ~r/terminal for authentication/i and sec =~ "deletion_status IS NOT NULL" and sec =~ ~r/reactivation/i
      assert sec =~ "403 M_USER_DEACTIVATED"
      assert sec =~ "step=<name>" and sec =~ "error_detail"
      # the lock order: the row locks BEFORE the advisory lock, and the key steps before both
      assert sec =~ ~r/first locks the user's `uia_sessions` rows and `cross_signing_keys` row.{0,80}only THEN takes the per-user `sync_global` advisory lock/
      assert sec =~ ~r/the private keys set to NULL, the row locks and the advisory lock/
      refute sec =~ "The transaction first takes the per-user", "the old, wrong order statement is gone"
    end

    test "06-runtime: the erasure paragraph states the order (keys, row locks, THEN the advisory lock) and the terminal status (D17)" do
      text = squash(read(@runtime))
      [_, para] = Regex.run(~r/(GDPR key erasure \(delete_user_keys\/2\).{0,2500})/, text)
      assert para =~ ~r/private keys set to NULL, the row locks.{0,80}THEN the per-user `sync_global` advisory lock/
      assert para =~ "is_active = false" and para =~ ~r/terminal for authentication/
    end

    test "the runbook has a backup / retention paragraph (restore re-runs the erasure or the sweep) and the PII / teardown verification queries (D19, D16, D18)" do
      rb = read(@runbook)
      sec = squash(section(rb, ["backups"]))
      assert sec =~ ~r/retention/i and sec =~ ~r/restore/i and sec =~ ~r/sweep/i and sec =~ ~r/WAL/
      assert rb =~ "pii_gone" and rb =~ "is_active = false"
      for t <- ~w(devices matrix_sessions sessions jwt_device_bindings sync_tokens), do: assert(rb =~ "SELECT COUNT(*) FROM #{t} WHERE user_id", "no verification count for #{t}")
      assert squash(rb) =~ ~r/read_receipts.{0,80}no index/i, "the read_receipts scan is stated (D19)"
    end

    test "07-deployment note: terminal, PII NULLed, 403, fail closed with the step, the privilege check, the read_receipts scan (D16 - D19)" do
      n = note()
      assert n =~ ~r/terminal/i and n =~ "`is_active = false`" and n =~ ~r/NOT crypto-shredded|not crypto-shredded/i
      assert n =~ "403 M_USER_DEACTIVATED"
      assert n =~ "oauth_codes_not_erased" and n =~ "step=<name>"
      assert n =~ "has_table_privilege" and n =~ "account_data" and n =~ "cross_signing_keys"
      assert n =~ ~r/read_receipts.{0,120}without an index/i
    end

    test "follow-ups: the avatar media row (LOW-6) and the unguarded writers row (LOW-4) exist once, open, 4 cells; the id line stays valid" do
      for {id, term} <- [{"gm", "avatar"}, {"gn", "not guarded"}] do
        r = row(id)
        assert length(cells(r)) == 4 and status(r) =~ ~r/\Aopen/i
        assert r =~ @story and r =~ term, "row #{id} records #{term} found by #{@story}"
      end

      f = squash(read(@followups))
      assert f =~ ~r/unused:[^.]*`gm` onward/, "the eight suites that pin the id line stay green"
      assert f =~ ~r/unused: `go` onward/, "gm and gn are used now: the unused ids continue at go"
      id_line = @followups |> read() |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "**Follow-up ids.**")) |> squash()
      # delta review cycle 1 (MINOR-2): the line lists gm / gn as USED and no longer claims that it "keeps its gm onward pins"
      assert id_line =~ "`gm`-`gn`: security review of gdpr-erasure-global-data"
      refute id_line =~ "keeps its `gm` onward pins"
    end
  end

  describe "delta cycle 1: the windows, the admin group, the free-text columns, the pointers" do
    test "08-concepts: limitation (f) and the terminal paragraph say 60 s on a node whose cache confirmed the user, not only one request (LOW-8)" do
      text = squash(section(read(@concepts), ["erasure", "inventory"]))
      assert text =~ ~r/up to 60 s/ and text =~ ~r/raw IdP JWT/ and text =~ "`gn`" and text =~ ":pg"
      limits = squash(section(read(@concepts), ["erasure", "deactivation", "limitations"]))
      assert limits =~ ~r/up to 60 s/ and limits =~ "`gn`"
      refute limits =~ "The window is that one in-flight request"
    end

    test "07-deployment and the runbook say the same, and the runbook tells the operator to remove an erased administrator from the IdP admin group" do
      assert note() =~ ~r/up to 60 s/ and note() =~ "`gn`"
      rb = squash(read(@runbook))
      assert rb =~ ~r/up to 60 s/i and rb =~ ~r/Remove an erased administrator from the IdP admin group/
      assert rb =~ ~r/cannot be reactivated/
    end

    test "the follow-up row gn carries the cache eviction broadcast over :pg; cq (g) names the stale merge base of the signature merge" do
      gn = row("gn")
      assert gn =~ ":pg" and gn =~ ~r/eviction/i and gn =~ ~r/60 s/
      cq = row("cq")
      assert cq =~ "put_keys_no_flag" and cq =~ ~r/merge base/i
    end

    test "08-concepts: the users line NULLs last_seen_at / deactivation_reason and keeps only personal_room_id; the media_files line points at gm" do
      lines = section(read(@concepts), ["erasure", "inventory"]) |> String.split("\n")
      users = Enum.find(lines, &String.starts_with?(&1, "- `users`:"))
      assert users =~ "`last_seen_at`" and users =~ "`deactivation_reason`" and users =~ "`personal_room_id`"
      refute users =~ ~r/residuals that stay: `personal_room_id`, `deactivation_reason`/
      media = Enum.find(lines, &String.starts_with?(&1, "- `media_files`:"))
      assert media =~ "`gm`"
    end
  end
end
