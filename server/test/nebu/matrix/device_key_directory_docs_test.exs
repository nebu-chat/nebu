defmodule Nebu.Matrix.DeviceKeyDirectoryDocsTest do
  @moduledoc """
  Static check (no DB, no network) for story `device-key-directory` (epic e2ee-client-support, REQ-2026-013): the documentation the story demands and the source-level rules that behavioural
  tests cannot show. The checks are LOOSE on purpose (regexes on the key claims, not on the wording).

    * ADR-011 stays (`m.room.encryption` is still rejected); the directory enables no E2EE room. `04-solution-strategy.md` names the pattern, `05-building-blocks.md` the modules, routes, table
      and migration, `07-deployment.md` the operator facts (node-local buckets N x, the commit lock, the sweep), `08-concepts.md` has a section "Device-key directory (story device-key-directory)"
      with the contract (errors, limits, the restriction, no oracle, the stream, the token group, the sync members, logging, erasure), `11-risks.md` the accepted residuals, `CHANGELOG.md` an
      entry, the GDPR runbook the table, `docs/matrix-api-scope.md` the two routes.
    * The story file has the `## Decisions` addendum (D1-D20) and scenario 3 is rewritten (left out, `failures` empty); the stub story `key-query-hardening` exists (REQ-2026-014).
    * Source rules: the claim is ONE `FOR UPDATE SKIP LOCKED` statement (no SELECT then UPDATE, no waiting lock), the rate buckets are taken BEFORE the claim, no process state keeps data of the
      stream or the claim (ADR-020), SQL stays inline (ADR-018), no log call, telemetry event or inspected term names key material, bodies or params.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)
  @lib Path.join(@root, "server/lib")
  @adr Path.join(@root, "docs/architecture/adr/ADR-011-managed-e2ee-key-escrow.md")
  @strategy Path.join(@root, "docs/architecture/04-solution-strategy.md")
  @blocks Path.join(@root, "docs/architecture/05-building-blocks.md")
  @deploy Path.join(@root, "docs/architecture/07-deployment.md")
  @concepts Path.join(@root, "docs/architecture/08-concepts.md")
  @risks Path.join(@root, "docs/architecture/11-risks.md")
  @changelog Path.join(@root, "CHANGELOG.md")
  @runbook Path.join(@root, "docs/compliance/gdpr-deletion-runbook.md")
  @scope Path.join(@root, "docs/matrix-api-scope.md")
  @story_file Path.join(@root, "docs/stories/e2ee-client-support/device-key-directory.md")
  @followup_file Path.join(@root, "docs/stories/e2ee-client-support/key-query-hardening.md")
  @story "device-key-directory"

  defp read(path), do: File.read!(path)
  defp squash(text), do: String.replace(text, ~r/\s+/, " ")

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

  defp dkd_section, do: squash(section(read(@concepts), ["device-key directory"]))

  defp unreleased do
    read(@changelog) |> String.split("## [Unreleased]", parts: 2) |> List.last() |> String.split(~r/\n## \[/, parts: 2) |> hd() |> squash()
  end

  defp decisions do
    [_, d] = read(@story_file) |> squash() |> String.split("## Decisions", parts: 2)
    [d, _] = String.split(d, "## Definition of Done", parts: 2)
    d
  end

  defp lib_sources, do: Path.wildcard(Path.join(@lib, "**/*.ex"))
  defp sources_naming(regex), do: Enum.filter(lib_sources(), &(read(&1) =~ regex))
  defp code_lines(file), do: file |> read() |> String.split("\n") |> Enum.reject(&Regex.match?(~r/^\s*(#|\*)/, &1))
  defp own_sources, do: Enum.filter(lib_sources(), &(Path.basename(&1) in ~w(http_key_directory.ex key_claim_store.ex device_list_store.ex)))

  describe "architecture docs" do
    test "ADR-011 carries the update: the directory enables no E2EE room, no key material is logged, m.room.encryption stays rejected" do
      adr = squash(read(@adr))
      assert adr =~ @story
      assert adr =~ ~r/keys\/claim/ and adr =~ ~r/device_lists|device_list_changes/
      assert adr =~ "m.room.encryption" and adr =~ ~r/abgelehnt|rejected|reject|ablehn/i
    end

    test "04-solution-strategy names the pattern: exactly once claim, PostgreSQL change stream, commit ordered position in the token" do
      text = squash(read(@strategy))
      [_, from] = Regex.split(~r/device-key directory/i, text, parts: 2)
      near = String.slice(from, 0, 1_200)
      assert near =~ ~r/exactly once/i and near =~ "PostgreSQL" and near =~ ~r/commit/i and near =~ ~r/token/i
    end

    test "05-building-blocks names the modules, both routes, the table, the migration and the story" do
      text = squash(read(@blocks))
      assert text =~ @story

      for term <- ["Nebu.Matrix.HttpKeyDirectory", "Nebu.Matrix.KeyClaimStore", "Nebu.Matrix.DeviceListStore", "keys/claim", "keys/changes", "device_list_changes", "000060"],
          do: assert(text =~ term, "05-building-blocks does not name #{term}")
    end

    test "07-deployment has the operator facts: node-local buckets (N x), the commit lock, the trigger lock at migration time, no pruning, the erasure sweep, no body logging" do
      sec = squash(section(read(@deploy), ["device-key directory"]))
      assert sec =~ "000060" and sec =~ "device_list_changes"
      assert sec =~ ~r/node[- ]local/i and sec =~ ~r/\bN (x|times|\x{00D7}) the (documented )?limit/u
      assert sec =~ ~r/COMMIT/ and sec =~ ~r/advisory lock/i
      assert sec =~ ~r/room_members/ and sec =~ ~r/trigger/i
      assert sec =~ ~r/DELETE\s+FROM\s+device_list_changes\s+WHERE\s+user_id\s+IN/i
      assert sec =~ ~r/never logged/i and sec =~ ~r/SHA-256 digest/ and sec =~ ~r/600 targets per minute, burst 1000/ and sec =~ ~r/keys_changes/
    end

    test "08-concepts has the section 'Device-key directory' with the contract: names, errors, tables, migration, ADRs" do
      sec = dkd_section()
      assert sec =~ @story

      for term <- ["device_list_changes", "Nebu.Matrix.KeyClaimStore", "Nebu.Matrix.DeviceListStore", "Nebu.Matrix.HttpKeyDirectory", "000060", "M_BAD_JSON", "M_NOT_JSON", "M_INVALID_PARAM", "M_MISSING_PARAM", "M_LIMIT_EXCEEDED", "ADR-011", "ADR-018", "ADR-020"],
          do: assert(sec =~ term, "the section does not mention #{term}")
    end

    test "08-concepts: the claim is exactly once (SKIP LOCKED, never a SELECT then UPDATE), upload order, verbatim, the fallback key is not consumed but marked used, failures stays empty" do
      sec = dkd_section()
      assert sec =~ "SKIP LOCKED" and sec =~ ~r/exactly once/i and sec =~ ~r/upload order/i and sec =~ ~r/verbatim/i
      assert sec =~ ~r/fallback key[^.]{0,160}NOT consumed[^.]{0,80}marked `?used/i
      assert sec =~ ~r/`?failures`? is always empty/i and sec =~ ~r/LEFT OUT/
    end

    test "08-concepts: the restriction (own devices, shared room, both join, request time), stricter than the spec, no oracle by bytes and statement counts" do
      sec = dkd_section()
      assert sec =~ ~r/BOTH sides are `join`/ and sec =~ ~r/request time/i and sec =~ ~r/stricter than the spec/i
      assert sec =~ ~r/BYTE-IDENTICALLY/ and sec =~ ~r/SAME number of statements/i
    end

    test "08-concepts: every limit with its number and the bucket rules (30 / minute burst 10, 10 / hour burst 5, 1000 targets, all-or-nothing before the claim, N x)" do
      sec = dkd_section()
      assert sec =~ ~r/30 requests per minute, burst 10/ and sec =~ ~r/10 per hour, burst 5/ and sec =~ ~r/1000 targets/
      assert sec =~ ~r/600 targets per minute, burst 1000/ and sec =~ ~r/SHA-256 digest/ and sec =~ ~r/second stage/
      assert sec =~ ~r/`keys_changes` \(60 per minute, burst 20/
      assert sec =~ ~r/all-or-nothing/i and sec =~ ~r/BEFORE the claim statement/ and sec =~ ~r/take_all/
      assert sec =~ ~r/EVERY valid target/ and sec =~ ~r/oracle/i
      assert sec =~ ~r/\bN x the documented limit/
    end

    test "08-concepts: /keys/changes (both tokens required, M_MISSING_PARAM / M_INVALID_PARAM, expired token answered conservatively, lists, own shared rooms only)" do
      sec = dkd_section()
      assert sec =~ ~r/sync `next_batch` tokens/ and sec =~ ~r/conservative/i and sec =~ ~r/always lists/i
      assert sec =~ ~r/`changed`[^.]{0,200}`left`/ and sec =~ ~r/OWN shared rooms/
    end

    test "08-concepts: the stream and the token (the latest change per user and room, positions assigned at COMMIT under one lock, the last token group .d<n>, rolling deploy)" do
      sec = dkd_section()
      assert sec =~ ~r/LATEST change per \(user, room\)/ and sec =~ ~r/AT COMMIT/ and sec =~ ~r/advisory lock/i and sec =~ "sync_global_pos_seq"
      assert sec =~ ~r/`?\.d<device-list pos>`?/ and sec =~ ~r/rolling deploy/i and sec =~ ~r/forged position/i
    end

    test "08-concepts: the sync members (signed_curve25519 always, fallback types per device, device-less legacy aggregate, initial / incremental / fallback rules)" do
      sec = dkd_section()
      assert sec =~ ~r/ALWAYS contains `signed_curve25519`/ and sec =~ ~r/PER DEVICE/ and sec =~ ~r/device-less request/i
      assert sec =~ ~r/initial sync lists no peer/i and sec =~ ~r/fallback of a request that carried a `since` lists every shared user/i
    end

    test "08-concepts: logging and erasure (no key material, tokens or claim bodies logged; the table is erased with the user)" do
      sec = dkd_section()
      assert sec =~ ~r/never logged/i and sec =~ "UserDeletion.erased_tables/0"
    end

    test "08-concepts: the GDPR inventory lists device_list_changes among the tables erased by the transaction" do
      inv = squash(section(read(@concepts), ["gdpr erasure inventory"]))
      assert inv =~ "device_list_changes"
    end

    test "11-risks: the row names the accepted residuals (node-local buckets, caller keyed buckets, the stricter restriction, left over-report, commit lock, no wake-up, key-query-hardening)" do
      row = read(@risks) |> String.split("\n") |> Enum.filter(&(&1 =~ @story)) |> Enum.join("\n") |> squash()
      assert row =~ ~r/node-local/i and row =~ ~r/N x/ and row =~ ~r/SHA-256 digest/ and row =~ ~r/600 targets per minute, burst 1000/
      assert row =~ ~r/stricter than the spec/i and row =~ ~r/over-report/i and row =~ ~r/advisory lock/i and row =~ ~r/no wake-up/i
      assert row =~ "key-query-hardening" and row =~ "REQ-2026-014"
    end

    test "docs/matrix-api-scope.md marks the claim and changes routes as done" do
      scope = read(@scope)
      assert scope =~ ~r/^\|\s*POST\s*\|\s*`\/_matrix\/client\/v3\/keys\/claim`\s*\|\s*✅/m
      assert scope =~ ~r/^\|\s*GET\s*\|\s*`\/_matrix\/client\/v3\/keys\/changes`\s*\|\s*✅/m
    end
  end

  describe "CHANGELOG and runbook" do
    test "the [Unreleased] entry names the routes, the migration, the limits, the per-device fallback types and the erasure" do
      u = unreleased()
      assert u =~ @story and u =~ "keys/claim" and u =~ "keys/changes" and u =~ "000060"
      assert u =~ ~r/exactly once/i and u =~ ~r/30 per minute/ and u =~ ~r/600 targets per minute, burst 1000/ and u =~ ~r/60 per minute, burst 20/ and u =~ ~r/10 per hour/ and u =~ ~r/per device/ and u =~ ~r/erasure/i
    end

    test "the GDPR runbook counts and sweeps device_list_changes" do
      text = squash(read(@runbook))
      assert text =~ ~r/SELECT\s+COUNT\(\*\)\s+FROM\s+device_list_changes\s+WHERE\s+user_id/i
      assert text =~ ~r/DELETE\s+FROM\s+device_list_changes\s+WHERE\s+user_id\s+IN/i
    end
  end

  describe "story files" do
    test "the story keeps the five scenarios, the traceability id, and scenario 3 is rewritten: left out, failures empty, no report of the target" do
      text = squash(read(@story_file))
      assert text =~ "traceability_id: REQ-2026-013"
      assert length(Regex.scan(~r/Scenario:/, text)) == 5
      [_, sc3] = Regex.split(~r/Scenario: Unknown or unauthorized device/, text, parts: 2)
      sc3 = String.slice(sc3, 0, 500)
      assert sc3 =~ ~r/no key for that device/ and sc3 =~ ~r/"failures" is empty/
      refute text =~ ~r/"failures" map reports the requested target\s*```/
    end

    test "## Decisions numbers D1 to D20 and records the scope split, the numbers, the deviations from the spec and the open questions" do
      d = decisions()
      for n <- 1..20, do: assert(d =~ ~r/\*\*D#{n} /, "decision D#{n} is missing")
      assert d =~ "key-query-hardening" and d =~ "REQ-2026-014"
      assert d =~ ~r/1000 targets/ and d =~ ~r/30 requests per minute, burst 10/ and d =~ ~r/10 per hour, burst 5/
      assert d =~ ~r/stricter than the (Matrix )?spec/i and d =~ "000060" and d =~ ~r/\.d<device-list pos>/ and d =~ ~r/Open questions for the owner/
      assert d =~ "`failures` is always `{}`"
    end

    test "the story has no open question left for the implementer" do
      text = read(@story_file)
      [_, oq] = String.split(text, "## Open Questions", parts: 2)
      assert squash(oq) =~ ~r/None open/
    end

    test "the stub story key-query-hardening exists: ready, REQ-2026-014, matrix, security review required, no UI, Gherkin scenarios for the four topics" do
      text = read(@followup_file)
      front = text |> String.split("---", parts: 3) |> Enum.at(1)
      # the stub was refined and implemented since (front matter `status: done`): ready or done
      assert front =~ ~r/^status: (ready|done)$/m

      for line <- ["story_id: key-query-hardening", "traceability_id: REQ-2026-014", "matrix: true", "security_review: required", "ui: false", "epic: e2ee-client-support"], do: assert(front =~ line)
      assert length(Regex.scan(~r/^\s+Scenario:/m, text)) >= 4
      for topic <- [~r/query/i, ~r/user-signing|user_signing/i, ~r/master key/i, ~r/signature/i], do: assert(text =~ topic)
    end
  end

  describe "source rules" do
    test "the three modules exist and the claim is ONE statement with FOR UPDATE SKIP LOCKED over ctid (no SELECT then UPDATE, no waiting lock)" do
      assert length(own_sources()) == 3
      [claim] = Enum.filter(own_sources(), &(Path.basename(&1) == "key_claim_store.ex"))
      code = claim |> code_lines() |> Enum.join("\n")
      assert code =~ "FOR UPDATE" and code =~ "SKIP LOCKED" and code =~ "ctid" and code =~ "claimed_at"
      refute code =~ ~r/pg_advisory_(xact_)?lock\(/, "the claim never takes a blocking lock"
      assert length(Regex.scan(~r/Ecto\.Adapters\.SQL\.query\(/, code)) == 1, "one statement serves the request"
      for lock <- Regex.scan(~r/FOR (?:NO KEY )?UPDATE(?: OF \w+)?(?! SKIP LOCKED)[^\n]*/, code) |> List.flatten(), do: assert(lock =~ "SKIP LOCKED", "a row lock without SKIP LOCKED: #{lock}")
    end

    test "the HTTP module checks the structure and the cap, then takes the buckets (take_all), and only then calls the claim" do
      [http] = Enum.filter(own_sources(), &(Path.basename(&1) == "http_key_directory.ex"))
      code = read(http)
      {claim_def, _} = :binary.match(code, "def claim(conn)")
      body = binary_part(code, claim_def, byte_size(code) - claim_def)
      {i_targets, _} = :binary.match(body, "targets(conn.body_params)")
      {i_cap, _} = :binary.match(body, "check_cap(")
      {i_charge, _} = :binary.match(body, "charge(user")
      {i_claim, _} = :binary.match(body, "KeyClaimStore.claim(")
      assert i_targets < i_cap and i_cap < i_charge and i_charge < i_claim
      assert code =~ "RateLimit.take_all("
    end

    test "no process state keeps stream or claim data: no ETS, persistent_term, Agent, GenServer, process dictionary or env write in the code that names the stream or the key tables" do
      files = sources_naming(~r/device_list_changes|device_one_time_keys|device_fallback_keys/)
      assert length(files) >= 4, "the scan is not vacuous: #{inspect(Enum.map(files, &Path.basename/1))}"

      for f <- files, line <- code_lines(f) do
        refute line =~ ~r/:ets\.|:persistent_term|Agent\.|GenServer\.|Process\.put|Process\.get|Application\.put_env|:counters\.|:atomics\./, "#{Path.basename(f)}: #{String.trim(line)}"
      end
    end

    test "SQL stays inline (ADR-018): no Ecto schema, changeset or repository / service module for the stream or the claim" do
      for f <- own_sources(), line <- code_lines(f) do
        refute line =~ ~r/use Ecto\.Schema|Ecto\.Changeset|import Ecto\.Query|defmodule .*(Repository|Service)\b/, "#{Path.basename(f)}: #{String.trim(line)}"
      end
    end

    test "no log call, telemetry event, IO output or inspected term in the new modules names keys, bodies, params, targets or tokens" do
      for f <- own_sources(), line <- code_lines(f) do
        if line =~ ~r/Logger\.(debug|info|warning|warn|error|notice)\(/ do
          interpolations = Regex.scan(~r/#\{([^}]*)\}/, line) |> Enum.map(&List.last/1)
          assert Enum.all?(interpolations, &(&1 =~ ~r/\Aerror_kind\(/)), "#{Path.basename(f)} logs more than the KIND of the failure: #{String.trim(line)}"
          refute line =~ ~r/inspect|conn\.|body_params|\bparams\b|metadata:/, "#{Path.basename(f)}: #{String.trim(line)}"
        end

        refute line =~ ~r/:telemetry\.|IO\.(puts|inspect)|IO\.warn/, "#{Path.basename(f)}: #{String.trim(line)}"
      end
    end

    test "the request logger captures no body of keys/claim and keys/upload and only parameter names of keys/changes (the shapes are known to RawBodyReader)" do
      raw = read(Path.join(@lib, "nebu/web/plugs/raw_body_reader.ex"))
      assert raw =~ "key_material_shape?" and raw =~ "key_changes_shape?"
      logger = read(Path.join(@lib, "nebu/web/plugs/request_logger.ex"))
      assert logger =~ "key_material_shape?" and logger =~ "key_changes_shape?"
    end

    test "the erasure inventory names the stream table and the sync fallback key types are read per device" do
      assert read(Path.join(@lib, "nebu/compliance/user_deletion.ex")) =~ "device_list_changes"
      protected = read(Path.join(@lib, "nebu/web/router/protected.ex"))
      assert protected =~ ~r/DeviceKeyStore\.unused_fallback_key_types\(user, did\)/
      assert protected =~ ~r/Map\.put_new\(otk_counts, "signed_curve25519", 0\)/
    end
  end
end
