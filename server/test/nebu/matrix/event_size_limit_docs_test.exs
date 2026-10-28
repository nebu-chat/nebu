defmodule Nebu.Matrix.EventSizeLimitDocsTest do
  @moduledoc """
  Static checks (no network; two queries against the real database, tagged `:integration`) for story `event-size-limit` (epic oauth-broker, follow-up `ep`),
  AC9 and AC11 (Q-uid):

    * (a) `docs/matrix-api-scope.md`: the rows `POST /createRoom`, `PUT .../send/{eventType}/{txnId}`, `PUT .../state/{eventType}/{stateKey}` (and the
      no-stateKey row by reference) name `413 M_TOO_LARGE`, `65536`, `255 bytes`, "canonical", label the status code a Nebu DECISION (Synapse parity, the
      spec names no code, `400 M_TOO_LARGE` the table-conformant alternative) AND the size accounting a Nebu INTERPRETATION (no reserve for PDU keys because
      Nebu does not federate); one sentence names the 1 MB body answer;
    * (b) `docs/stories/oauth-broker/follow-ups.md`: `ep` CLOSED (CLOSED style, status `closed`, "Original item" keeps the old words and sources), notes on
      `en`, `fi` (g), `fl` (e), `ey`, `ff`, `ex`, `eq`, new rows `fn`, `fo`, `fp`, the id line (`fn`-`fp`: this story, unused from `fq`);
    * (c) `docs/architecture/07-deployment.md`: the release note "Event size limits (story event-size-limit, follow-up `ep`)" and the two operator queries
      Q-size and Q-uid (also RUN here inside a rolled-back transaction with fixture rows, the way the story says they were checked);
    * (d) `CHANGELOG.md` `[Unreleased]` `### Changed`: one warning entry;
    * (e) `server/lib` no longer says that the byte limit is a pending follow-up.

  The pins are facts and unique new terms, not whole sentences. The `fn` onward id-line assertions of the six older docs suites are DELIBERATELY re-pinned to
  `fq` onward (each with a comment naming this story); the old `fn` onward is refuted HERE.

  Pure file reads: `async: true` (the two query tests are `:integration`, they only read and roll back).
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)
  @scope Path.join(@root, "docs/matrix-api-scope.md")
  @followups Path.join(@root, "docs/stories/oauth-broker/follow-ups.md")
  @deploy Path.join(@root, "docs/architecture/07-deployment.md")
  @changelog Path.join(@root, "CHANGELOG.md")
  @lib Path.join(@root, "server/lib")
  @story "event-size-limit"

  defp read(p), do: File.read!(p) |> String.replace(~r/\s+/, " ")
  defp lines(p), do: p |> File.read!() |> String.split("\n")

  defp followup_line(id) do
    line = Enum.find(lines(@followups), &String.starts_with?(&1, "| #{id} | "))
    assert line, "the follow-up row #{id} does not exist"
    String.replace(line, ~r/\s+/, " ")
  end

  defp scope_row(prefix) do
    row = Enum.find(lines(@scope), &String.starts_with?(&1, prefix))
    assert row, "the scope doc has no row starting with #{prefix}"
    String.replace(row, ~r/\s+/, " ")
  end

  # ═══ (a) the scope doc ═══════════════════════════════════════════════════════════

  @rows [
    {"POST /createRoom", "| POST | `/_matrix/client/v3/createRoom` | "},
    {"PUT .../send", "| PUT | `/_matrix/client/v3/rooms/{roomId}/send/{eventType}/{txnId}` | "},
    {"PUT .../state/{stateKey}", "| PUT | `/_matrix/client/v3/rooms/{roomId}/state/{eventType}/{stateKey}` | "}
  ]

  for {label, prefix} <- @rows do
    test "scope doc (a): the #{label} row names 413 M_TOO_LARGE, 65536, 255 bytes, canonical JSON" do
      row = scope_row(unquote(prefix))

      for term <- ["413", "M_TOO_LARGE", "65536", "255 bytes"], do: assert(row =~ term, "#{unquote(label)} mentions #{term}")
      assert row =~ ~r/canonical/i
    end

    test "scope doc (a): the #{label} row labels the status code a Nebu decision (Synapse parity, no code in the spec, 400 M_TOO_LARGE the table-conformant alternative) and the size accounting a Nebu interpretation" do
      row = scope_row(unquote(prefix))

      assert row =~ ~r/Nebu decision/i, "the status code is a Nebu decision"
      assert row =~ "Synapse"
      assert row =~ "`400 M_TOO_LARGE`", "the table-conformant alternative is named"
      assert row =~ ~r/Nebu interpretation/i, "the accounting is a Nebu interpretation"
      assert row =~ "`event_id`" and row =~ "`signatures`", "the stored client-format event plus event_id and signatures"
      assert row =~ ~r/federat/i and row =~ ~r/reserve/i, "no reserve for PDU keys because Nebu does not federate"
    end
  end

  test "scope doc (a): the PUT .../state/{eventType} row (no stateKey) refers to the 413 rule of the row above" do
    row = scope_row("| PUT | `/_matrix/client/v3/rooms/{roomId}/state/{eventType}` | ")
    assert row =~ "413" and row =~ "M_TOO_LARGE"
  end

  test "scope doc (a): one sentence names the answer for a body above the 1 MB parser cap: M_TOO_LARGE, \"Request body is too large\"" do
    doc = read(@scope)
    assert doc =~ "Request body is too large"
    window = Regex.scan(~r/.{0,300}Request body is too large.{0,300}/s, doc) |> List.flatten() |> Enum.join(" ")
    assert window =~ "M_TOO_LARGE" and window =~ ~r/1 MB/
  end

  test "scope doc (a): the createRoom row names the three createRoom sources of an oversized event: initial_state, creation_content, power_level_content_override (refused before the room exists)" do
    row = scope_row("| POST | `/_matrix/client/v3/createRoom` | ")
    for term <- ["initial_state", "creation_content", "power_level_content_override"], do: assert(row =~ term)
    assert row =~ ~r/before the room exists|creates nothing|nothing is created/i
  end

  # ═══ (b) follow-ups ══════════════════════════════════════════════════════════════

  test "follow-ups (b): ep is CLOSED by this story (CLOSED style, status closed) and keeps its original words and sources" do
    f = read(@followups)

    assert f =~ ~r/\| ep \| \*\*CLOSED by story #{@story} \(\d{4}-\d{2}-\d{2}\)/, "the CLOSED prefix like ea / ev / ez / ff"
    line = followup_line("ep")
    assert line =~ ~r/\| closed \|\s*\z/, "the status column says closed, no longer open"
    refute line =~ ~r/\| open, non-gating \(INFO\) \|\s*\z/
    assert line =~ ~r/Original item/i

    # hidden pins of OLDER suites on this row, visible here (test review MINOR-11): "NEXT story" (membership_write_limits_cycle1_docs_test),
    # `power_level_content_override` (create_room_presets_docs_test); the CLOSED rewrite keeps the old text, so all of them stay
    for word <- ["65536", "M_TOO_LARGE", "initial_state", "JsonBody", "power_level_content_override", "invite_state", "prev_content", "create-room-input-validation", "member-event-prev-content", "NEXT story"] do
      assert line =~ word, "ep keeps #{word}"
    end

    assert line =~ @story
  end

  for {id, patterns} <- [
        {"en", ["/send", {:re, "depth", "i"}, {:re, "NUL", ""}, "avatar_url", {:re, "inspect\\(reason\\)", ""}]},
        {"fi", ["(g)", {:re, "write[- ]time", "i"}, {:re, "legacy", "i"}]},
        {"fl", ["(e)", "65536", {:re, "130", ""}]},
        {"ey", ["`ep`", {:re, "closed", "i"}, "M-2", "L-1"]},
        {"ff", ["`ep`", {:re, "closed", "i"}, "L-2", "prev_content"]},
        {"ex", ["EventSize", "reason"]},
        {"eq", ["EventSize", {:re, "power[- ]level", "i"}]}
      ] do
    test "follow-ups (b): the existing row #{id} carries a '**Note (event-size-limit, <date>):**' with the facts of this story" do
      row = followup_line(unquote(id))

      assert row =~ ~r/\*\*Note \(#{@story}, [^)]+\):\*\*/, "#{unquote(id)}: the note is labelled like the other notes of this file"

      for pattern <- unquote(Macro.escape(patterns)) do
        case pattern do
          p when is_binary(p) -> assert row =~ p, "#{unquote(id)} mentions #{p}"
          {:re, source, opts} -> assert row =~ Regex.compile!(source, opts), "#{unquote(id)} matches /#{source}/"
        end
      end
    end
  end

  test "follow-ups (b): the new rows fn (canonical JSON numbers and escapes), fo (encode / decode round trips) and fp (state slots per room) exist and are attributed to this story, open and non-gating" do
    fn_row = followup_line("fn")
    fo_row = followup_line("fo")
    fp_row = followup_line("fp")

    for row <- [fn_row, fo_row, fp_row] do
      assert row =~ @story, "attributed to #{@story}"
      assert row =~ ~r/open, non-gating/i
    end

    for word <- ["CanonicalJson", "float", "lowercase", "Synapse"], do: assert(fn_row =~ word, "fn mentions #{word}")
    for word <- ["EventId.generate", "prev_content", ~r/round trip/i], do: assert(fo_row =~ word, "fo mentions #{inspect(word)}")
    for word <- ["state slots", "/sync", "m.space.child", ~r/budget/i], do: assert(fp_row =~ word, "fp mentions #{inspect(word)}")
  end

  test "follow-ups (b): the id line lists fn - fp for this story and continues at ga (story moderation-routes-atomic-ban used fq - fu; the old 'fn onward' is gone)" do
    f = read(@followups)

    assert f =~ "`fn`-`fp`: #{@story}"
    # story moderation-routes-atomic-ban (DELIBERATE re-pin, AC18; old -> new): `fq` - `fr` are used by that story, the unused ids continue at `fs` ("`fq` onward" before)
    # moderation-routes-atomic-ban review cycles 1 / 2 (DELIBERATE re-pin): `fs`-`fu` are used, unused ids continue at `fv`
    # story power-levels-enforcement (DELIBERATE re-pin, AC15 / AC16; old -> new): `fv`-`fz` are used by that story, the unused ids continue at `ga` ("`fv` onward" before)
    # story state-writer-redaction (DELIBERATE re-pin, AC15 (a); old -> new): `ga`-`gd` are used by that story, the unused ids continue at `ge` ("`ga` onward" before; the old note is refuted by state_writer_redaction_docs_test.exs)
    # story membership-state-model (DELIBERATE re-pin, AC15 (a); old -> new): `ge`-`gi` are used by that story, the unused ids continue at `gj` ("`ge` onward" before; the old note is refuted by membership_state_model_docs_test.exs)
    # story history-visibility-enforcement (DELIBERATE re-pin, AC21 (a); old -> new): `gj`-`gl` are used by that story, the unused ids continue at `gm` ("`gj` onward" before; the old note is refuted by history_visibility_docs_test.exs)
    assert f =~ ~r/unused:[^.]*`gm` onward/, "unused ids continue at gm"
    refute f =~ ~r/unused:[^.]*`fn` onward/, "the old `fn` onward note is gone"
    assert f =~ "`fk`-`fl`: member-event-prev-content", "the earlier attribution stays"
  end

  # ═══ (c) 07-deployment ═══════════════════════════════════════════════════════════

  test "07-deployment (c): the release note 'Event size limits' names the 413s and their texts, Synapse parity, the 1 MB envelope, unchanged existing events and the read-side budgets" do
    doc = read(@deploy)

    assert doc =~ "**Event size limits (story #{@story}, follow-up `ep`).**"
    note = doc |> String.split("**Event size limits (story #{@story}, follow-up `ep`).**", parts: 2) |> List.last() |> binary_slice(0, 6_000)

    for term <- ["413", "M_TOO_LARGE", "65536", "255 bytes", "Synapse", "Request body is too large", "Event exceeds the maximum size of 65536 bytes", "State key exceeds 255 bytes", "Event type exceeds 255 bytes"] do
      assert note =~ term, "the release note mentions #{term}"
    end

    assert note =~ ~r/Element/ and note =~ ~r/far below|a few KB/i, "Element's normal events are far below the limit (e2e run B)"
    assert note =~ ~r/(not|never) (changed|deleted)|NOT changed/, "existing events are not changed or deleted"
    assert note =~ ~r/64 KiB/ and note =~ ~r/8 MiB/, "the read-side invite budgets stay"
    assert note =~ ~r/user id/i and note =~ "255", "user ids derived from IdP claims are bounded (D12)"
    assert note =~ ~r/twice|two (new )?writes/i, "a room admin cleans a legacy slot with two writes"
    assert note =~ "`upgrade_room`" and note =~ ~r/reduced/i
  end

  @concepts Path.join(@root, "docs/architecture/08-concepts.md")

  test "07-deployment and 08-concepts keep the phrases that older suites pin next to the new note (test review MINOR-11): the optional stripped state is bounded, `m.room.create` above 64 KiB is reduced" do
    for doc <- [read(@deploy), read(@concepts)] do
      assert doc =~ ~r/optional stripped state is bounded/i
      assert doc =~ ~r/create and member content stays unbounded until `ep`|`m\.room\.create` above 64 KiB is reduced/i
    end
  end

  # the fenced ```sql block that follows the paragraph starting with `anchor`
  defp sql_after(anchor) do
    raw = File.read!(@deploy)
    assert {at, _} = :binary.match(raw, anchor), "07-deployment has no paragraph #{anchor}"
    rest = binary_part(raw, at, byte_size(raw) - at)
    assert [_, after_fence] = String.split(rest, "```sql\n", parts: 2), "no sql block after #{anchor}"
    [sql | _] = String.split(after_fence, "\n```", parts: 2)
    sql
  end

  test "07-deployment (c): the Q-size query is read-only, an upper-bound estimate with the 268-byte envelope, run off-peak with a read-only role" do
    raw = File.read!(@deploy)
    assert raw =~ "*Q-size: events above the size limits (candidates)*"

    sql = sql_after("*Q-size: events above the size limits (candidates)*")
    assert sql =~ ~r/^\s*SELECT/i
    refute sql =~ ~r/\b(INSERT|UPDATE|DELETE|DROP|ALTER|TRUNCATE)\b/i
    assert sql =~ "octet_length(e.content::text)" and sql =~ "65536" and sql =~ "268", "the fixed envelope + event_id + signatures is 268 bytes"
    assert sql =~ "octet_length(e.event_type) > 255" and sql =~ "octet_length(coalesce(e.state_key, '')) > 255"

    paragraph = raw |> String.split("*Q-size: events above the size limits (candidates)*", parts: 2) |> List.last() |> binary_slice(0, 2_500) |> String.replace(~r/\s+/, " ")
    assert paragraph =~ ~r/sequential scan/i and paragraph =~ ~r/off-peak/i and paragraph =~ ~r/read-only/i
    assert paragraph =~ ~r/upper[- ]bound/i, "every event above the limit is listed, plus some just below it"
    assert paragraph =~ ~r/rolled-back transaction/i and paragraph =~ "70 000" and paragraph =~ "1 000"
  end

  # CODE REVIEW CYCLE 1 (Kassandra #1) changed D12 deliberately: natural ids are at most 254 bytes, every id of 255 bytes or more is hashed to EXACTLY 255 bytes
  # (domain separation by length), so an account created before with an id of >= 255 bytes gets a NEW id at its next login: Q-uid lists `>= 255` (was `> 255`)
  test "07-deployment (c): the Q-uid query lists accounts whose user id has 255 bytes or more, expected none; such an account gets a new id at its next login (D12)" do
    doc = read(@deploy)
    assert doc =~ "*Q-uid: accounts whose user id has 255 bytes or more*"
    sql = sql_after("*Q-uid: accounts whose user id has 255 bytes or more*")

    assert sql =~ "octet_length(user_id) >= 255" and sql =~ ~r/FROM users/i
    refute sql =~ ~r/\b(INSERT|UPDATE|DELETE|DROP|ALTER|TRUNCATE)\b/i

    para = doc |> String.split("*Q-uid: accounts whose user id has 255 bytes or more*", parts: 2) |> List.last() |> binary_slice(0, 2_000)
    assert para =~ ~r/expected none/i and para =~ ~r/next login|sign in again/i and para =~ ~r/new id/i
  end

  @tag :integration
  test "07-deployment (c): the Q-size query, RUN inside a rolled-back transaction, lists the 70 000 byte, 256-byte state_key and 256-byte type fixtures, not the 1 000 byte one" do
    sql = sql_after("*Q-size: events above the size limits (candidates)*") |> String.trim() |> String.trim_trailing(";")
    suffix = Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    room = "!qsize#{suffix}:test.local"

    result =
      Nebu.Repo.transaction(fn ->
        q = fn statement, params -> Ecto.Adapters.SQL.query!(Nebu.Repo, statement, params) end
        q.("INSERT INTO rooms (room_id, created_at) VALUES ($1, 0)", [room])

        for {n, id, key} <- [{70_000, "big", ""}, {1_000, "small", ""}, {10, "key", String.duplicate("k", 256)}] do
          q.(
            "INSERT INTO events (event_id, room_id, sender, event_type, content, origin_server_ts, signatures, state_key) VALUES ($1, $2, '@q:test.local', 'm.room.topic', $3, 1, '{}', $4)",
            ["$#{id}#{suffix}", room, %{"pad" => String.duplicate("a", n)}, key]
          )
        end

        # and a fourth, a 256-byte event TYPE with a tiny content: the `event_type` arm of the query
        q.(
          "INSERT INTO events (event_id, room_id, sender, event_type, content, origin_server_ts, signatures, state_key) VALUES ($1, $2, '@q:test.local', $3, '{}', 1, '{}', '')",
          ["$type#{suffix}", room, String.duplicate("t", 256)]
        )

        Nebu.Repo.rollback({:rows, q.(sql, []).rows})
      end)

    assert {:error, {:rows, rows}} = result
    listed = for [room_id, event_id | _] <- rows, room_id == room, do: event_id
    assert Enum.sort(listed) == Enum.sort(["$big#{suffix}", "$key#{suffix}", "$type#{suffix}"]),
           "the 70 000 byte event, the 256-byte state_key and the 256-byte type are listed, the 1 000 byte event is not: #{inspect(listed)}"

    assert Ecto.Adapters.SQL.query!(Nebu.Repo, "SELECT count(*) FROM rooms WHERE room_id = $1", [room]).rows == [[0]], "rolled back"
  end

  @tag :integration
  test "07-deployment (c): the Q-uid query, RUN inside a rolled-back transaction, lists fixture accounts of 255 and 256 bytes and not one of 254 bytes" do
    sql = sql_after("*Q-uid: accounts whose user id has 255 bytes or more*") |> String.trim() |> String.trim_trailing(";")
    suffix = Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    id = fn total -> "@q" <> suffix <> String.duplicate("u", total - 3 - 8 - 10) <> ":test.local" end

    result =
      Nebu.Repo.transaction(fn ->
        q = fn statement, params -> Ecto.Adapters.SQL.query!(Nebu.Repo, statement, params) end

        for total <- [254, 255, 256] do
          q.("INSERT INTO users (user_id, created_at) VALUES ($1, 0)", [id.(total)])
        end

        Nebu.Repo.rollback({:rows, q.(sql, []).rows})
      end)

    assert {:error, {:rows, rows}} = result
    assert byte_size(id.(256)) == 256 and byte_size(id.(255)) == 255 and byte_size(id.(254)) == 254
    listed = for [user_id, bytes] <- rows, String.contains?(user_id, suffix), do: {user_id, bytes}
    assert Enum.sort(listed) == Enum.sort([{id.(255), 255}, {id.(256), 256}])
  end

  # ═══ (d) CHANGELOG ═══════════════════════════════════════════════════════════════

  test "CHANGELOG (d): [Unreleased] ### Changed has a warning entry: 413 M_TOO_LARGE (65 536 canonical bytes, 255 bytes), the 1 MB envelope, user ids, upgrade_room, existing events unchanged" do
    changelog = File.read!(@changelog)
    assert [_, from_unreleased] = String.split(changelog, "## [Unreleased]", parts: 2)
    [unreleased | _] = String.split(from_unreleased, ~r/\n## \[/, parts: 2)

    assert [_, from_changed] = String.split(unreleased, "### Changed", parts: 2)
    [changed | _] = String.split(from_changed, ~r/\n### /, parts: 2)

    entry =
      changed
      |> String.split(~r/\n- /)
      |> Enum.find(&(&1 =~ "M_TOO_LARGE" and &1 =~ "65 536"))

    assert entry, "a Changed entry about the event size limits"
    flat = String.replace(entry, ~r/\s+/, " ")

    assert flat =~ "⚠", "behaviour change: the warning sign like the other entries"
    for term <- ["413", "255 bytes", "PUT", "/send", "createRoom", "1 MB", "`upgrade_room`", "Q-size", "`ep`"], do: assert(flat =~ term, "the entry mentions #{term}")
    assert flat =~ ~r/user ids?/i and flat =~ ~r/existing events/i
  end

  # ═══ code review cycle 1 ═════════════════════════════════════════════════════════

  test "scope doc (M4): the appended size-limit paragraphs are separated from the text before them (no run-together sentences)" do
    for {label, prefix} <- @rows ++ [{"no stateKey", "| PUT | `/_matrix/client/v3/rooms/{roomId}/state/{eventType}` | "}] do
      row = scope_row(prefix)
      assert row =~ ~r/[.)] \*\*Size limits \(story event-size-limit/ or row =~ ~r/\. Same size limits/, "#{label}: the size-limit text starts a new sentence"
      refute row =~ ~r/[a-z)] \*\*Size limits/, "#{label}: run together with the previous text"
      refute row =~ ~r/row above Same size limits/
    end
  end

  test "07-deployment (M5, Kassandra #1): hashed and natural user ids are disjoint by length (254 / exactly 255 bytes), no shared namespace, and an oversized server name refuses to start" do
    doc = read(@deploy)
    note = doc |> String.split("**Event size limits (story #{@story}, follow-up `ep`).**", parts: 2) |> List.last() |> binary_slice(0, 9_000)

    assert note =~ "254 bytes" and note =~ ~r/EXACTLY 255 bytes/
    assert note =~ ~r/disjoint by length/ and note =~ ~r/no longer share a namespace/
    assert note =~ ~r/REFUSES TO START/ and note =~ "235 bytes"
    assert note =~ ~r/Admin can still remove/i
  end

  # story moderation-routes-atomic-ban (DELIBERATE re-pin, AC18; old -> new): the gate item (check_stored before signing, a byte cap on `reason`) was
  # OPEN on the `ex` row; the ban route story SATISFIES it (EventSize.check_stored/1 on every member event, a 1024-byte cap and a NUL refusal on
  # `reason`). The row still carries the words of the item (inside the kept original text) and now says that the item is satisfied.
  test "follow-ups (Kassandra #4): the ex row says the gate item for kick / ban is satisfied: check_stored before signing and a 1024-byte cap on reason" do
    row = followup_line("ex")
    assert row =~ "check_stored" and row =~ ~r/byte cap/
    assert row =~ ~r/gate items? (are|is) satisfied/i, "the gate item is satisfied by story moderation-routes-atomic-ban"
    assert row =~ "1024", "the reason cap"
    assert row =~ "EventSize.check_stored/1"
  end

  # ═══ (e) the stale comments of server/lib ═════════════════════════════════════════

  test "server/lib (e): the invite budget comments no longer call the byte limit a pending follow-up; they say 'defence in depth for rows written before story event-size-limit'" do
    files = Path.wildcard(Path.join(@lib, "**/*.ex"))
    assert length(files) > 100, "positive control: the lib tree was found"
    sources = for f <- files, into: %{}, do: {Path.relative_to(f, @lib), File.read!(f)}

    for {file, src} <- sources do
      refute src =~ "until follow-up `ep`", "#{file} still says 'until follow-up `ep`'"
      refute src =~ "is follow-up `ep`", "#{file} still says 'is follow-up `ep`'"
      refute src =~ "as written until `ep`", "#{file} still says 'as written until `ep`'"
    end

    server = sources["nebu/matrix/event_dispatcher/server.ex"]
    assert server =~ ~r/defence in depth[^\n]*(\n\s*#[^\n]*){0,3}[^\n]*#{@story}|#{@story}[^\n]*(\n\s*#[^\n]*){0,3}[^\n]*defence in depth/i, "the budget comments name the story"
  end
end
