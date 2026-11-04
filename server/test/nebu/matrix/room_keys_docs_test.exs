defmodule Nebu.Matrix.RoomKeysDocsTest do
  @moduledoc """
  Static check (no DB, no network) for story `server-side-key-backup` (epic e2ee-client-support, REQ-2026-011): the documentation the story demands and the source-level rules
  that behavioural tests cannot show.

    * ADR-011 stays (Nebu keeps rejecting `m.room.encryption`); `docs/architecture/adr/ADR-011-managed-e2ee-key-escrow.md` gets the clarification that `room_keys/*` is no longer a stub but
      an opaque key backup store (story server-side-key-backup), that the server never decrypts, and that this enables no E2EE room.
    * `docs/architecture/05-building-blocks.md` names the store (routes and both tables) and `docs/architecture/08-concepts.md` has a section "Server-side key backup (story
      server-side-key-backup)" with the contract: error codes, the merge rule, the quotas (10 versions, 100 000 sessions per version, 8 KiB, 16 KiB, 5 MiB), the rate limit (writes only), the
      "never logged" rule and the erasure. (The erasure inventory, the runbook verification queries and the sweep of the older story are pinned by `user_deletion_docs_test.exs` /
      `user_deletion_sweep_test.exs`, which are driven by `erased_tables/0` and now cover both tables.)
    * `CHANGELOG.md` has an entry under `[Unreleased]` / Added.
    * The stub comments of `protected.ex` ("ACCEPTANCE STUB", "Every other room_keys/* route stays M_UNRECOGNIZED", ADR-011 as the reason for "nothing stored") are gone.
    * Source rules (any location): the code that touches the key backup tables keeps no process state (no ETS, persistent_term, Agent, GenServer, counters, process dictionary, application
      env writes): the etag and the count come from the database, so every node of a cluster answers the same (ADR-020); and no `Logger` call names a blob (`session_data`, `auth_data`).

  Cycle 2 (delta review): the documented numbers moved and are pinned again - 64 MiB budget (row cost 128 bytes + ids), write burst 5, bulk burst 3, a light bucket of 120 / min burst 30 for the
  version GETs, try-lock answers, one bulk read per user and two per node - and the 11-risks row records the honest peak memory and the accepted residuals; the operator SQL that prunes
  old soft-delete markers is EXECUTED against the database by `room_keys_prune_runbook_test.exs`. The tests marked "cycle 2 (deliberate)" below replace cycle-1 pins of the old numbers.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)
  @lib Path.join(@root, "server/lib")
  @adr Path.join(@root, "docs/architecture/adr/ADR-011-managed-e2ee-key-escrow.md")
  @blocks Path.join(@root, "docs/architecture/05-building-blocks.md")
  @concepts Path.join(@root, "docs/architecture/08-concepts.md")
  @changelog Path.join(@root, "CHANGELOG.md")
  @deploy Path.join(@root, "docs/architecture/07-deployment.md")
  @risks Path.join(@root, "docs/architecture/11-risks.md")
  @known Path.join(@root, "e2e/KNOWN-FAILURES.md")
  @story_file Path.join(@root, "docs/stories/e2ee-client-support/server-side-key-backup.md")
  @security_report Path.join(@root, "docs/stories/e2ee-client-support/security-reports/server-side-key-backup-security-review-2026-10-30.md")
  @protected Path.join(@lib, "nebu/web/router/protected.ex")
  @story "server-side-key-backup"
  @tables ~w(room_key_backup_versions room_key_backup_sessions)

  defp read(path), do: File.read!(path)
  defp squash(text), do: String.replace(text, ~r/\s+/, " ")

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

  defp lib_sources, do: Path.wildcard(Path.join(@lib, "**/*.ex"))
  defp key_backup_sources, do: Enum.filter(lib_sources(), &(read(&1) =~ "room_key_backup"))

  describe "ADR-011" do
    test "carries the clarification: room_keys is an opaque key backup store (story server-side-key-backup), the server never decrypts, m.room.encryption stays rejected" do
      adr = squash(read(@adr))
      assert adr =~ @story, "the clarification names the story"
      assert adr =~ "room_keys"
      assert adr =~ ~r/opak|opaque/i, "the blobs are opaque to the server"
      assert adr =~ ~r/entschl|decrypt/i, "the server never decrypts"
      assert adr =~ "m.room.encryption" and adr =~ ~r/abgelehnt|rejected|reject|ablehn/i, "ADR-011 itself stays: m.room.encryption is still rejected"
    end

    test "no longer calls room_keys/* a stub" do
      adr = squash(read(@adr))
      refute adr =~ "`room_keys/*`) bleiben aktiv", "the old sentence that lists room_keys/* among the stubs is replaced"
      refute adr =~ ~r/E2EE-Stubs[^.;]*room_keys/, "room_keys/* is not an E2EE stub any more"
    end
  end

  describe "architecture docs" do
    test "05-building-blocks names the store: the routes and both tables, and the story" do
      text = squash(read(@blocks))
      assert text =~ @story
      for table <- @tables, do: assert(text =~ table, "05-building-blocks does not name #{table}")
      assert text =~ "room_keys/version" and text =~ "room_keys/keys"
    end

    test "08-concepts has the section 'Server-side key backup' with the contract of the story" do
      sec = squash(section(read(@concepts), ["server-side key backup"]))
      assert sec =~ @story, "the heading or the text names the story"
      for table <- @tables, do: assert(sec =~ table, "the section does not name #{table}")

      for term <- ["M_WRONG_ROOM_KEYS_VERSION", "current_version", "M_FORBIDDEN", "M_MISSING_PARAM", "M_TOO_LARGE", "etag", "ADR-011", "ADR-018"],
          do: assert(sec =~ term, "the section does not mention #{term}")

      assert sec =~ ~r/soft[- ]delete/i, "the soft-delete marker (versions are never reused)"
      assert sec =~ ~r/opaque/i and sec =~ ~r/never.{0,40}(decrypt|log)/is
      assert sec =~ ~r/\b10\b.{0,25}versions/is, "the quota of 10 versions"
      assert sec =~ ~r/100[ ,_.\x{202F}\x{00A0}]?000.{0,20}sessions/iu, "100 000 sessions per version"
      assert sec =~ "8 KiB" and sec =~ "16 KiB" and sec =~ "5 MiB"
      # cycle 2 (deliberate, supersedes "60 / min, burst 30"): the write burst is 5
      assert sec =~ ~r/60.{0,20}min.{0,40}burst.{0,10}\b5\b/is, "the write rate limit: 60 per minute, burst 5"
      refute sec =~ ~r/60.{0,20}min.{0,40}burst.{0,10}30/is, "the cycle-1 burst of 30 is gone"
      assert sec =~ ~r/per[- ]user.{0,40}(counter|number)|(counter|number).{0,40}per[- ]user/is, "the version numbers are per-user counters"
      assert sec =~ ~r/foreign key|FK/i, "the session rows have a foreign key to their version"
      assert sec =~ ~r/erasure|erased/i and sec =~ "UserDeletion"
    end

    # cycle 1 (Kassandra review, orchestrator decisions): the documented contract changed in five places; "reads are not limited" and "anonymous keeps 1 MB" are SUPERSEDED.
    # Cycle 2 (deliberate): burst 10 -> 3, 256 MiB -> 64 MiB, "lock timeout 2 s answers 429" -> try-lock (own test below), "version reads unlimited" -> light bucket (own test below)
    test "08-concepts documents the cycle-1 decisions: bulk read bucket, single reads unlimited, authentication before the body, byte budget, row cap" do
      sec = squash(section(read(@concepts), ["server-side key backup"]))

      assert sec =~ ~r/bulk.{0,160}30.{0,30}min.{0,60}burst.{0,10}\b3\b/is, "the bulk reads have their own bucket (30 per minute, burst 3)"
      refute sec =~ ~r/bulk.{0,160}30.{0,30}min.{0,60}burst.{0,10}10/is, "the cycle-1 bulk burst of 10 is gone"
      assert sec =~ ~r/single.{0,160}(not|never|un)[- ]?(rate[- ])?limited|single.{0,160}unlimited/is, "the single-session read stays unlimited"
      assert sec =~ ~r/after.{0,50}authenticat|authenticat.{0,120}before.{0,80}(read|pars)|before the body/is, "the body is read only after the authentication"
      assert sec =~ ~r/401/, "an unauthenticated request is 401 without reading the body"
      refute sec =~ ~r/anonymous.{0,60}keep.{0,30}1 MB|1 MB default.{0,80}anonymous/is, "the cycle-0 rule 'anonymous requests keep the 1 MB cap' is superseded and must not stay as the contract"
      assert sec =~ "64 MiB" and sec =~ ~r/budget|aggregate/i, "the per-user byte budget (64 MiB since cycle 2)"
      refute sec =~ "256 MiB", "the cycle-1 budget of 256 MiB is gone from the contract"
      assert sec =~ ~r/\b1[ ,_.\x{202F}\x{00A0}]?000\b.{0,100}(rows?|markers?)|(rows?|markers?).{0,100}\b1[ ,_.\x{202F}\x{00A0}]?000\b/isu, "the cap of 1000 version rows including the markers"
      assert sec =~ ~r/marker.{0,200}(never pruned|not pruned|accepted growth|grow)|(never pruned|not pruned|accepted growth).{0,200}marker/is, "the accepted growth of the markers"
    end

    test "08-concepts says 'opaque', not 'stored verbatim' (the server re-encodes canonically)" do
      sec = squash(section(read(@concepts), ["server-side key backup"]))
      refute sec =~ ~r/verbatim/i
      assert sec =~ ~r/opaque/i
      blocks = read(@blocks) |> squash()
      [_, from] = String.split(blocks, @story, parts: 2)
      refute String.slice(from, 0, 1500) =~ ~r/verbatim/i
    end

    test "08-concepts: the GDPR erasure paragraph names RoomKeyBackupStore.create_version and put_sessions as sync_global users that refuse an erased user" do
      concepts = squash(read(@concepts))
      [_, inventory] = String.split(concepts, "### GDPR erasure inventory", parts: 2)
      para = String.slice(inventory, 0, 6000)
      assert para =~ "RoomKeyBackupStore.create_version" and para =~ "put_sessions"
      assert para =~ ~r/sync_global.{0,400}RoomKeyBackupStore|RoomKeyBackupStore.{0,400}sync_global/is
      assert para =~ ~r/RoomKeyBackupStore.{0,300}(M_USER_DEACTIVATED|refuse)|(M_USER_DEACTIVATED|refuse).{0,300}RoomKeyBackupStore/is
    end

    test "07-deployment: the old release note 'no server-side key backup ... acceptance stub' is marked historical or gone" do
      text = squash(read(@deploy))
      refute text =~ ~r/Nebu has no server-side key backup/, "the sentence is false since this story"
      refute text =~ ~r/stores nothing, so that Element Web.s first-login key setup/, "the stub description stays only as history"

      for [{idx, _}] <- Regex.scan(~r/acceptance stub/i, text, return: :index) do
        around = binary_part(text, max(idx - 700, 0), min(1400, byte_size(text) - max(idx - 700, 0)))
        assert around =~ ~r/historical|superseded|replaced by|since story|was an|former|until story/i and around =~ @story,
               "an 'acceptance stub' mention without a note that story #{@story} replaced it: #{String.slice(around, 600, 200)}"
      end
    end

    test "11-risks: the key backup row names the cycle-1 decisions (auth before parse, byte budget, lock timeout, bulk read bucket, marker growth)" do
      rows = read(@risks) |> String.split("\n") |> Enum.filter(&(&1 =~ @story)) |> Enum.join("\n") |> squash()
      assert rows != "", "no row of the risk register names #{@story}"
      assert rows =~ ~r/authenticat.{0,120}(pars|body)|(pars|body).{0,120}authenticat/is, "no pre-auth parse"
      assert rows =~ ~r/byte budget|64 MiB/i
      # (the register may still NAME the former 256 MiB: the honest peak below is stated against it)
      assert rows =~ ~r/lock[_ -]?timeout|try[- ]lock/i
      assert rows =~ ~r/bulk/i
      assert rows =~ ~r/marker/i and rows =~ ~r/accepted|grow/i, "accepted marker growth"
    end
  end

  describe "migration number 000058 (the cycle-0 number 000056 clashed with another story)" do
    test "no doc names 000056 for the key backup migration; the entry points name 000058" do
      for {label, path} <- [{"CHANGELOG", @changelog}, {"05-building-blocks", @blocks}, {"08-concepts", @concepts}, {"ADR-011", @adr}, {"KNOWN-FAILURES", @known}, {"07-deployment", @deploy}] do
        text = squash(read(path))
        refute text =~ ~r/room_key_backup.{0,200}000056|000056.{0,200}room_key_backup|key backup.{0,200}000056|000056.{0,200}key backup/is, "#{label} still names 000056 for the key backup"
      end

      assert squash(read(@changelog)) =~ "000058"
      assert squash(section(read(@concepts), ["server-side key backup"])) =~ "000058"
      assert squash(read(@adr)) =~ "000058"
    end
  end

  describe "story Decisions" do
    test "record the cycle-1 decisions and mark the cycle-0 rule 'anonymous keeps 1 MB' as superseded" do
      story = squash(read(@story_file))
      [_, decisions] = String.split(story, "## Decisions", parts: 2)
      [decisions, _] = String.split(decisions, "## Definition of Done", parts: 2)
      assert decisions =~ ~r/SUPERSEDED \(cycle 2\)[^\n]{0,600}256 MiB/, "the cycle-1 byte budget stays as history, labelled SUPERSEDED (cycle 2)"
      assert decisions =~ ~r/lock[_ -]?timeout/i
      assert decisions =~ ~r/bulk/i
      assert decisions =~ "000058"
      assert decisions =~ ~r/supersed/i, "the cycle-0 anonymous 1 MB decision is superseded"
      assert decisions =~ ~r/after.{0,40}authenticat|authenticat.{0,100}before/is
      assert decisions =~ ~r/1[ ,_.]?000.{0,80}(row|marker)|(row|marker).{0,80}1[ ,_.]?000/is
    end
  end

  describe "CHANGELOG, cycles 1 and 2" do
    test "the entry names the budget, the bulk read bucket and migration 000058" do
      unreleased = read(@changelog) |> String.split("## [Unreleased]", parts: 2) |> List.last() |> String.split(~r/\n## \[/, parts: 2) |> hd() |> squash()
      assert unreleased =~ "64 MiB", "cycle 2 (deliberate, supersedes 256 MiB)"
      refute unreleased =~ "256 MiB"
      assert unreleased =~ ~r/bulk/i
      assert unreleased =~ "000058"
      refute unreleased =~ ~r/reads are not limited/i, "the changelog still says that all reads are unlimited"
    end
  end

  # ═══ cycle 2 ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

  describe "cycle 2: 08-concepts documents the delta decisions" do
    test "the budget accounting: 64 MiB, the ids and the fixed 128 bytes per row on top of session_data, auth_data of live versions" do
      sec = squash(section(read(@concepts), ["server-side key backup"]))
      assert sec =~ "64 MiB"
      assert sec =~ "128", "the fixed per-row cost of 128 bytes"
      assert sec =~ ~r/octet_length|room_id.{0,80}session_id|ids?\b.{0,60}(count|bytes)/is, "the room and session id bytes count"
      assert sec =~ ~r/row.{0,80}128|128.{0,80}row/is
    end

    test "writers take the per-user lock with a TRY-lock: a busy lock is an immediate 429, lock_timeout is the row-lock safety net" do
      sec = squash(section(read(@concepts), ["server-side key backup"]))
      assert sec =~ ~r/try[- ]?lock|pg_try_advisory_xact_lock/i
      assert sec =~ "429" and sec =~ "retry_after_ms"
      assert sec =~ ~r/(at once|immediate)/i
      assert sec =~ ~r/row[- ]lock/i and sec =~ ~r/lock[_ -]?timeout/i, "the timeout stays as the safety net of row locks"
    end

    test "bulk reads: ONE in flight per user, TWO per node (the seam), 429 before any DB work, slots freed on process death" do
      sec = squash(section(read(@concepts), ["server-side key backup"]))
      assert sec =~ "room_keys_max_concurrent_bulk_reads_per_node"
      assert sec =~ ~r/(one|1).{0,60}(per user|user)/is and sec =~ ~r/(two|2).{0,60}(per node|node)/is
      assert sec =~ ~r/monitor|DOWN/i, "the slot is monitor based"
    end

    test "the light bucket of the version GETs: 120 per minute, burst 30, separate from the bulk and the write buckets" do
      sec = squash(section(read(@concepts), ["server-side key backup"]))
      assert sec =~ ~r/version.{0,200}120.{0,30}min.{0,60}burst.{0,10}30/is
    end

    test "the buckets are node-local: in a cluster the effective limit is N times the documented one" do
      sec = squash(section(read(@concepts), ["server-side key backup"]))
      assert sec =~ ~r/node[- ]local/i
      assert sec =~ ~r/\bN (x|times|\x{00D7}) the (documented )?limit/u, "the cluster consequence: N nodes allow N x the limit"
    end
  end

  describe "cycle 2: 11-risks records the honest peak memory and the accepted residuals" do
    defp risk_rows, do: read(@risks) |> String.split("\n") |> Enum.filter(&(&1 =~ @story)) |> Enum.join("\n") |> squash()

    test "peak memory of a bulk read: about 300-350 MiB before the lower budget, about 64 MiB x 2.5 after; streaming is a follow-up" do
      rows = risk_rows()
      assert rows =~ ~r/300.{0,6}350 ?MiB/, "the peak of one bulk read BEFORE the lower budget (a 256 MiB version)"
      assert rows =~ ~r/64 ?MiB.{0,12}(x|\x{00D7}|\*).{0,6}2[.,]5/u, "the peak AFTER the lower budget: 64 MiB x 2.5"
      assert rows =~ ~r/stream/i, "streaming the response is the recorded follow-up"
    end

    test "the single-flight rule and the node cap, the node-local buckets (cluster = N x limit)" do
      rows = risk_rows()
      assert rows =~ ~r/(one|1).{0,80}(per user)|single[- ]flight/i
      assert rows =~ ~r/(two|2).{0,60}(per node|node)/i
      assert rows =~ "room_keys_max_concurrent_bulk_reads_per_node"
      assert rows =~ ~r/node[- ]local/i
      assert rows =~ ~r/\bN (x|times|\x{00D7}) the (documented )?limit/u, "the cluster consequence: N nodes allow N x the limit"
    end

    test "the accepted RLS USING (true) and the O(scan) per write with the counter column as the follow-up" do
      rows = risk_rows()
      assert rows =~ ~r/RLS.{0,200}USING ?\(true\)|USING ?\(true\).{0,200}RLS/is
      assert rows =~ ~r/accepted/i
      assert rows =~ ~r/O\(scan\)|O\(rows\)|scan.{0,60}(per write|every write)|(per write|every write).{0,80}scan/is, "the byte check scans the user's rows on every write"
      assert rows =~ ~r/counter.{0,40}column|column.{0,40}counter|O\(1\)/i, "the O(1) counter column is the documented follow-up"
    end
  end

  describe "cycle 2: stale migration numbers in the story and the security report" do
    test "no `000056_room_key_backup` in the story file or the cycle-0 security report (the number is 000058)" do
      for {label, path} <- [{"story", @story_file}, {"security report", @security_report}] do
        text = read(path)
        refute text =~ "000056_room_key_backup", "#{label} still names the stale migration file 000056_room_key_backup"
      end

      assert read(@security_report) =~ "000058_room_key_backup", "the report names the migration by its real number"
    end
  end

  describe "cycle 2: story Decisions" do
    test "record the cycle-2 decisions: 64 MiB, single-flight 1/user 2/node, try-lock, row cost 128 + ids, version bucket 120/30, bursts 5 and 3, prune SQL, :version placeholder, decoded segments" do
      story = squash(read(@story_file))
      [_, decisions] = String.split(story, "## Decisions", parts: 2)
      [decisions, _] = String.split(decisions, "## Definition of Done", parts: 2)
      assert decisions =~ "64 MiB"
      assert decisions =~ "room_keys_max_concurrent_bulk_reads_per_node"
      assert decisions =~ ~r/try[- ]?lock|pg_try_advisory_xact_lock/i
      assert decisions =~ "128" and decisions =~ ~r/octet_length|ids?\b/i
      assert decisions =~ ~r/120.{0,40}30/ and decisions =~ ~r/burst.{0,12}\b5\b/i and decisions =~ ~r/burst.{0,12}\b3\b/i
      assert decisions =~ ~r/prune/i and decisions =~ ~r/marker/i
      assert decisions =~ ":version"
      assert decisions =~ ~r/decoded/i
      assert decisions =~ ~r/supersed/i, "the cycle-1 numbers (256 MiB, burst 10 / 30, waiting lock) are marked superseded"
    end
  end

  describe "cycle 2: the single-flight slots are monitor based node-local state in their own module (not a key backup data module)" do
    test "a module under server/lib reads the seam, monitors the request process, handles :DOWN and names no backup table" do
      slot_files = Enum.filter(lib_sources(), fn f -> read(f) =~ "room_keys_max_concurrent_bulk_reads_per_node" and read(f) =~ "Process.monitor" end)
      assert slot_files != [], "no module reads :room_keys_max_concurrent_bulk_reads_per_node and monitors the request process"

      for f <- slot_files do
        src = read(f)
        assert src =~ ~r/:DOWN/, "#{Path.relative_to(f, @root)}: a monitor based slot frees on :DOWN"
        refute src =~ "room_key_backup", "#{Path.relative_to(f, @root)}: the slot module holds no backup data (the cluster-safe rule is about the data modules)"
      end
    end
  end

  describe "architecture docs (merge rule)" do

    test "08-concepts documents the merge rule in the spec order" do
      sec = squash(section(read(@concepts), ["server-side key backup"]))
      assert sec =~ ~r/is_verified.{0,200}first_message_index.{0,200}forwarded_count/i, "verified, then the lower first_message_index, then the lower forwarded_count"
      assert sec =~ ~r/full tie|tie.{0,60}(keeps|kept)/i
    end
  end

  describe "CHANGELOG" do
    test "has an entry for the key backup under [Unreleased]" do
      text = read(@changelog)
      [_, rest] = String.split(text, "## [Unreleased]", parts: 2)
      unreleased = rest |> String.split(~r/\n## \[/, parts: 2) |> hd() |> squash()
      assert unreleased =~ "room_keys", "the entry names the routes"
      assert unreleased =~ @story or unreleased =~ ~r/key backup/i
      assert unreleased =~ ~r/room_key_backup|migration 0000(5[6-9]|[6-9]\d)/i, "the entry names the new tables or the migration number"
    end
  end

  describe "source" do
    test "the stub comments of the old POST /room_keys/version are gone from protected.ex" do
      src = squash(read(@protected))
      refute src =~ "ACCEPTANCE STUB"
      refute src =~ "Every other room_keys/* route stays M_UNRECOGNIZED"
      refute src =~ ~r/Nebu has no server-side key backup/
    end

    test "the key backup code exists (the scans below are not vacuous): some module of server/lib names both tables" do
      sources = key_backup_sources()
      assert sources != [], "no file under server/lib names room_key_backup_*"
      text = sources |> Enum.map(&read/1) |> Enum.join("\n")
      for table <- @tables, do: assert(text =~ table, "no code names #{table}")
    end

    test "cluster-safe: the code that touches the key backup tables keeps no process state (etag and count come from the database)" do
      forbidden = ~r/:ets\.|:persistent_term|\bAgent\.|\bGenServer\.|:counters\.|:atomics\.|Process\.(put|get)\(|Application\.put_env|:erlang\.put\(|Registry\.|Cachex|ConCache|Nebulex|:mnesia|:global\.|:pg\./
      assert key_backup_sources() != [], "no key backup code to scan"

      for file <- key_backup_sources() do
        offenders = file |> read() |> String.split("\n") |> Enum.reject(&Regex.match?(~r/^\s*#/, &1)) |> Enum.filter(&Regex.match?(forbidden, &1))
        assert offenders == [], "#{Path.relative_to(file, @root)} keeps process state: #{inspect(offenders)}"
      end
    end

    test "no Logger call anywhere names a blob (session_data, auth_data)" do
      for file <- lib_sources(),
          line <- file |> read() |> String.split("\n") |> Enum.reject(&Regex.match?(~r/^\s*#/, &1)),
          Regex.match?(~r/Logger\.(debug|info|notice|warning|warn|error|critical|alert|emergency|log)\b/, line) do
        refute line =~ ~r/session_data|auth_data/, "#{Path.relative_to(file, @root)}: a log call names a blob: #{String.trim(line)}"
      end
    end

    test "SQL stays inline in the handler (ADR-018): no Ecto schema or repository module for the key backup" do
      assert key_backup_sources() != [], "no key backup code to scan"

      for file <- key_backup_sources() do
        src = read(file)
        refute src =~ ~r/use Ecto\.Schema|Ecto\.Changeset|schema\s+"room_key_backup/, "#{Path.relative_to(file, @root)}: ADR-018 forbids Ecto schemas / changesets"
        refute Path.basename(file) =~ ~r/repository|_repo\.ex\z|service/, "#{Path.relative_to(file, @root)}: no repository / service layer (ADR-018)"
      end
    end
  end
end
