defmodule Nebu.Matrix.CrossSigningUploadRacesDocsTest do
  @moduledoc """
  Static check (no DB, no network) for story `cross-signing-upload-races` (epic oauth-broker, follow-up `cq` (g), REQ-2026-007), D6 and D5: the deliberate
  documentation and comment edits of the story, the lock-order statements, and the "no key material in a log line" rule.

    * `docs/stories/oauth-broker/follow-ups.md`: in row `cq`, item (g) becomes "(g) **CLOSED by story cross-signing-upload-races (date): ...** **Original item:**
      <the original text of (g), verbatim>"; the items (a)-(f) and the status `open, non-gating` stay; `cq` stays ONE row.
    * **The id line stays BYTE-IDENTICAL** (this story takes no id), pinned by length and SHA-256 like the suite of sync-rejoin-range-scan-bound; a LATER story
      that takes an id must amend both pins deliberately.
    * The lock-order statements: the `08-concepts` erasure paragraph ("Lock order"), the step 4a comment of `user_deletion.ex` and the store comments name
      `lock_keys/1` and the order row -> advisory -> read. The ORDER of the erasure itself stays: `lock_user_writers/1` locks `uia_sessions`, then
      `cross_signing_keys`, then the advisory lock (D1 keeps the documented order; the literal "advisory first" direction was rejected).
    * The handlers decide on `lock_keys/1` (no `get_keys_for_update/1` in `do_persist_cross_signing/3` and `replace_with_approval/7`); the comment "NOT
      protected here: the MERGE BASE" is replaced by the new protocol.
    * D5: no new log line in the store, and the log lines of the cross-signing handlers carry the error KIND only (never key material, key ids or signatures).

  The pins are facts and unique terms. They do NOT pin the state of any other follow-up row. The one older pin this story must amend (the `(g)` item text in
  `sync_rejoin_range_scan_bound_docs_test.exs`) is amended with it, in the same step.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)
  @followups Path.join(@root, "docs/stories/oauth-broker/follow-ups.md")
  @concepts Path.join(@root, "docs/architecture/08-concepts.md")
  @store Path.join(@root, "server/lib/nebu/matrix/cross_signing_key_store.ex")
  @protected Path.join(@root, "server/lib/nebu/web/router/protected.ex")
  @deletion Path.join(@root, "server/lib/nebu/compliance/user_deletion.ex")
  @story "cross-signing-upload-races"

  # the byte-identical id line (the line of the commit before this story; the same pin as sync-rejoin-range-scan-bound)
  @id_line_bytes 2680
  @id_line_sha256 "1773564f8df3a19fcc78a3f298bf4410f889e21edb93fbf56a2cc474075ba778"

  # the text of item (g) of row `cq` as it stands before this story (the closure keeps it verbatim after "**Original item:**")
  @original_g ~S"""
  (g) pre-existing first cross-signing upload race (Kassandra INFO-3 of sync-token-per-device): in `do_persist_cross_signing/3` the `FOR UPDATE` read of a NON-existent row locks nothing and the `sync_global|` advisory lock is taken only inside `put_keys/2` after the decision, so two concurrent first uploads both take the UIA-free branch and the second overwrites the first; taking the `sync_global|` lock before `get_keys_for_update/1` closes it. Same class (story gdpr-erasure-global-data, code review delta cycle 1, MINOR-1): the signature merge (`CrossSigningKeyStore.put_keys_no_flag/2`, `POST /keys/signatures/upload`) takes the row and advisory lock and the erasure guard, but `persist_single/3` reads its merge base with `get_keys/1` BEFORE that transaction and stores all three columns from it, so a cross-signing reset of the same user that commits in between is overwritten in the two columns the merge did not touch; the story that closes (g) should read the base under the lock there too.
  """

  defp squash(text), do: String.replace(text, ~r/\s+/, " ")
  defp read(path), do: File.read!(path)

  defp line(id) do
    lines = @followups |> read() |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "| #{id} | "))
    assert length(lines) == 1, "the follow-up row #{id} must exist exactly once (found #{length(lines)})"
    squash(hd(lines))
  end

  defp text(id), do: line(id) |> String.split(" | ", parts: 3) |> Enum.at(1)
  defp status(id), do: line(id) |> String.split(" | ") |> List.last() |> String.trim_trailing(" |")

  # the closure of (g): from "(g) **CLOSED" up to "**Original item:**"; the original: from there to the end of the cell ((g) is the last item)
  defp g_parts do
    row = text("cq")
    assert row =~ ~r/\(g\) \*\*CLOSED by story #{@story} \(\d{4}-\d{2}-\d{2}\)/, "item (g) opens with \"(g) **CLOSED by story #{@story} (date)\""
    [_before, from_g] = String.split(row, "(g) **CLOSED by story #{@story}", parts: 2)
    [closure, original] = String.split(from_g, "**Original item:**", parts: 2)
    {closure, String.trim(original)}
  end

  # a source file without comment markers joined into one text (the pins read the comment prose)
  defp comments(path) do
    path |> read() |> String.split("\n") |> Enum.filter(&(&1 =~ ~r/^\s*#/)) |> Enum.map(&String.replace(&1, ~r/^\s*#+\s?/, "")) |> Enum.join(" ") |> squash()
  end

  # the source of one function: from its head (a regex, so parameter names may change) up to the next top-level definition / doc / spec
  defp function_source(path, head) do
    src = read(path)
    assert [{start, _}] = Regex.run(head, src, return: :index), "the function #{inspect(head)} exists"
    rest = binary_part(src, start, byte_size(src) - start)

    # skip the head line itself, then cut at the next 2-space-indented definition
    [head_line | tail] = String.split(rest, "\n", parts: 2)
    tail = Enum.join(tail, "\n")

    stop =
      case Regex.run(~r/\n  (defp? |@doc |@spec )/, tail, return: :index) do
        [{i, _} | _] -> i
        nil -> byte_size(tail)
      end

    head_line <> "\n" <> binary_part(tail, 0, stop)
  end

  # the code of a source text: comment lines dropped (a comment may name the old function)
  defp code(text), do: text |> String.split("\n") |> Enum.reject(&(&1 =~ ~r/^\s*#/)) |> Enum.join("\n")

  # ─── follow-ups: cq (g) ────────────────────────────────────────────────────────

  describe "follow-ups: item (g) of row cq is closed by this story" do
    test "(g) opens with the CLOSED marker of this story and a date; the row keeps 4 cells and the status open, non-gating" do
      {_closure, _original} = g_parts()
      row = line("cq")
      assert length(String.split(row, " | ")) == 4, "a ` | ` inside the text shifts the table columns"
      assert status("cq") == "open, non-gating", "(a)-(f) stay open or closed as before: the row stays open"
    end

    test "after **Original item:** the ORIGINAL text of (g) stands verbatim" do
      {_closure, original} = g_parts()
      expected = squash(String.trim(@original_g))
      assert original in [expected, String.replace_prefix(expected, "(g) ", "")], "the original text of (g) must be kept word for word"
    end

    test "the closure names lock_keys/1, the lock order, the first-upload race, the merge base, the 500 and the erasure" do
      {closure, _original} = g_parts()

      pins = [
        {"lock_keys/1", "the new store function"},
        {~r/row.{0,120}advisory.{0,120}\bread\b/is, "the order row -> advisory -> read"},
        {~r/first upload/i, "the first upload race"},
        {~r/INFO-3/, "the Kassandra finding it closes"},
        {~r/merge base/i, "the merge base"},
        {~r/under the (per-user )?lock|under that lock|behind the (advisory )?lock/i, "read under the lock"},
        {~r/\b500\b/, "a failed read of the merge is a 500 (OQ2)"},
        {~r/erasure/i, "the erasure guard and the kept lock order"},
        {"`persist_single/3`", "the stale read of the merge path is gone"}
      ]

      for {pin, what} <- pins do
        case pin do
          p when is_binary(p) -> assert closure =~ p, "the closure of (g) names #{what}"
          p -> assert closure =~ p, "the closure of (g) names #{what}"
        end
      end
    end

    test "the other items (a)-(f) of row cq are intact, in their order; the row opens as before" do
      row = text("cq")

      items = [
        "(a) the partition read and the `:pg` room subscription are separate reads (former `fc` (g))",
        "(b) `/messages`, `/context`, the latest-per-slot reads, the D3 tie order and the history-visibility segments still order by `origin_server_ts`",
        "(c) events stored before migration 000053 have no position",
        # the closed (f) sits right behind (c), its original text runs up to "; (d)" (see sync_rejoin_range_scan_bound_docs_test.exs)
        "(f) **CLOSED by story sync-rejoin-range-scan-bound",
        "(d) the cursor storage is one row per (device, partition room) without a separate cap",
        "(e) a newly joined room keeps the joined-slice state of the incremental sync (`gg`)",
        "(g) **CLOSED by story #{@story}"
      ]

      for item <- items, do: assert(row =~ item, "item kept: #{String.slice(item, 0, 50)}")
      positions = for item <- items, do: :binary.match(row, item) |> elem(0)
      assert positions == Enum.sort(positions), "the order of the items is unchanged"
      assert row =~ ~r/\A\*\*Residuals of the per-room stream positions \(story sync-stream-position\)\.\*\*/
    end

    test "cq is still ONE row, no follow-up id was taken: the id line is byte-identical and the older pins match" do
      lines = @followups |> read() |> String.split("\n")
      assert length(Enum.filter(lines, &String.starts_with?(&1, "| cq | "))) == 1

      assert [id_line] = Enum.filter(lines, &String.starts_with?(&1, "**Follow-up ids.**")), "the id paragraph exists once, as ONE line"
      assert byte_size(id_line) == @id_line_bytes, "the id line changed length: this story takes no id and must not touch the line"
      assert :crypto.hash(:sha256, id_line) |> Base.encode16(case: :lower) == @id_line_sha256, "the id line is not byte-identical"

      file = read(@followups)
      assert file =~ ~r/unused:[^.]*`gm` onward/, "the pin of the older docs suites"
      assert file =~ "unused: `go` onward"
    end
  end

  # ─── 08-concepts: the lock-order passage ───────────────────────────────────────

  describe "08-concepts: the erasure paragraph states the lock order of the writers" do
    test "the Lock order passage names lock_keys/1 and row -> advisory -> read and keeps the erasure order" do
      paragraph = @concepts |> read() |> String.split(~r/\n[ \t]*\n/) |> Enum.map(&squash/1) |> Enum.find(&(&1 =~ "*Lock order:*"))
      assert paragraph, "the paragraph with the *Lock order:* statement exists"

      assert paragraph =~ "lock_keys/1", "the passage names the store function that every cross-signing decision uses"
      assert paragraph =~ ~r/row.{0,160}advisory.{0,200}\bread\b/is, "... and the order row lock -> advisory lock -> read"
      # the erasure's own order stays as the older suites pin it (user_deletion_docs_test.exs)
      assert paragraph =~ ~r/first locks the user's `uia_sessions` rows and `cross_signing_keys` row.{0,80}only THEN takes the per-user `sync_global` advisory lock/
    end
  end

  # ─── the code comments: the new protocol ───────────────────────────────────────

  describe "the store and the erasure comments name the protocol" do
    test "the store: lock_keys/1 is defined with a spec, named by the moduledoc, and the stale-merge-base comment is replaced" do
      src = read(@store)
      assert src =~ ~r/\n  def lock_keys\(\w+\)/, "lock_keys/1 is a public function of the store"
      assert src =~ ~r/@spec lock_keys\(.*\) ::/

      [_, moduledoc, _] = String.split(src, ~s("""), parts: 3)
      assert moduledoc =~ "`lock_keys/1`", "the moduledoc names the locked read"

      refute src =~ "NOT protected here: the MERGE BASE", "the comment is replaced by the new protocol"
      refute src =~ "`persist_single/3` reads the three keys with `get_keys/1` BEFORE this transaction"

      merge = comments(@store)
      assert merge =~ "lock_keys/1" and merge =~ ~r/row.{0,160}advisory.{0,200}\bread\b/is, "the comments state row -> advisory -> read"
    end

    test "the erasure: the step 4a comment names lock_keys/1 and the order row -> advisory -> read" do
      src = read(@deletion)
      [_, from_4a] = String.split(src, "Step 4a: serialise", parts: 2)
      [block, _] = String.split(from_4a, "defp lock_user_writers", parts: 2)
      block = block |> String.split("\n") |> Enum.map(&String.replace(&1, ~r/^\s*#+\s?/, "")) |> Enum.join(" ") |> squash()

      assert block =~ "lock_keys/1", "the step 4a comment names the writers' locked read"
      assert block =~ ~r/row.{0,200}advisory.{0,200}\bread\b/is
    end

    test "pin: the erasure still locks uia_sessions, cross_signing_keys, then the advisory lock (D1)" do
      body = function_source(@deletion, ~r/defp lock_user_writers\(/)
      positions = for needle <- ["FROM uia_sessions WHERE user_id = $1 FOR UPDATE", "FROM cross_signing_keys WHERE user_id = $1 FOR UPDATE", "pg_advisory_xact_lock"], do: :binary.match(body, needle) |> elem(0)
      assert positions == Enum.sort(positions), "the erasure's lock order is uia_sessions -> cross_signing_keys -> advisory lock"
    end
  end

  # ─── the handlers decide on lock_keys/1 ────────────────────────────────────────

  describe "the handlers" do
    defp heads, do: [~r/defp do_persist_cross_signing\(/, ~r/defp replace_with_approval\(/]

    test "do_persist_cross_signing/3 and replace_with_approval/7 decide on lock_keys/1, never on a row-only read" do
      for head <- heads() do
        body = function_source(@protected, head) |> code()
        # an alias is fine: `lock_keys(` qualified or imported
        assert body =~ ~r/\block_keys\(/, "#{inspect(head)} reads the stored keys with lock_keys/1"
        refute body =~ "get_keys_for_update", "#{inspect(head)} must not decide on a row-only read"
        refute body =~ ~r/\bget_keys\(/, "#{inspect(head)} must not decide on an unlocked read"
      end
    end

    # D2: the decision read and the first-upload write are ONE transaction (the lock lives until it ends): a read in a transaction of its own would
    # release the advisory lock before the write
    test "do_persist_cross_signing/3: lock_keys and the first-upload put_keys sit in the SAME single Nebu.Repo.transaction fun" do
      body = function_source(@protected, ~r/defp do_persist_cross_signing\(/) |> code()

      assert length(Regex.scan(~r/Nebu\.Repo\.transaction\(/, body)) == 1, "exactly one transaction decides and writes"
      assert [_, in_tx] = String.split(body, ~r/Nebu\.Repo\.transaction\(/, parts: 2)
      [tx_body, _after] = String.split(in_tx, ~r/\n\s+rescue\b/, parts: 2)

      [{lock_at, _}] = Regex.run(~r/\block_keys\(/, tx_body, return: :index)
      [{put_at, _}] = Regex.run(~r/\bput_keys\(/, tx_body, return: :index)
      assert lock_at < put_at, "the locked read comes first, the first-upload write after it, both inside the transaction fun"
    end
  end

  # ─── D5: logs ──────────────────────────────────────────────────────────────────

  describe "no key material in a log line (D5)" do
    test "pin: the store has no log line at all (the new locked read adds none)" do
      refute read(@store) =~ ~r/Logger\./
    end

    test "pin: every log line of the cross-signing handlers interpolates the error KIND only" do
      src = read(@protected)
      [_, from] = String.split(src, "defp do_device_signing_upload(conn) do", parts: 2)
      [region, _] = String.split(from, "defp deep_merge_sig_map(existing, new)", parts: 2)
      logs = Regex.scan(~r/Logger\.\w+\((?:"[^\n]*"|[^\n]*)\)/, region) |> Enum.map(&hd/1)
      assert logs != [], "the handlers log failures (the pin must see them)"

      for l <- logs do
        interpolations = Regex.scan(~r/#\{([^}]*)\}/, l) |> Enum.map(&Enum.at(&1, 1))
        assert Enum.all?(interpolations, &(&1 in ["error_kind(reason)", "inspect(e.__struct__)"])), "a log line interpolates more than the error kind: #{l}"
      end
    end
  end
end
