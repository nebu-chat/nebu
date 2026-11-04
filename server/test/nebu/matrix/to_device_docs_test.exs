defmodule Nebu.Matrix.ToDeviceDocsTest do
  @moduledoc """
  Static check (no DB, no network) for story `to-device-messaging` (epic e2ee-client-support, REQ-2026-012): the documentation the story demands and the source-level rules that behavioural tests
  cannot show (the lessons of the sibling story's three security reviews are pinned here as rules of the code).

    * ADR-011 stays (`m.room.encryption` is still rejected); the to-device transport enables no E2EE room. `docs/architecture/04-solution-strategy.md` names the queue as a pattern,
      `05-building-blocks.md` the modules, the route and both tables, `07-deployment.md` the operator facts (the purge job, the TTLs, node-local limits, the erasure sweep of the messages a
      user sent), `08-concepts.md` has a section "To-device messaging (story to-device-messaging)" with the contract (errors, every limit and budget, the rate limit, acknowledgement on the next
      token, the recipient restriction, no oracle, `*`, eviction, wake-up, cluster safety, logging, erasure), `11-risks.md` the accepted residuals, `CHANGELOG.md` an entry, and the GDPR
      runbook the sweep. The story file has the `## Decisions` addendum.
    * Source rules (any location): the code that touches the to-device tables keeps no process state (no ETS, persistent_term, Agent, GenServer, counters, process dictionary, application env
      writes: the queue, the idempotency records and the acknowledgement position come from the database, so every node answers the same, ADR-020); the wake-up is the cluster-wide `:pg`
      broadcast; no blocking lock call (a request never waits for a lock while holding a pooled connection); SQL inline (ADR-018); no log call, telemetry event or inspected term names content.
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
  @story_file Path.join(@root, "docs/stories/e2ee-client-support/to-device-messaging.md")
  @story "to-device-messaging"
  @tables ~w(to_device_messages to_device_txns)

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

  defp td_section, do: squash(section(read(@concepts), ["to-device messaging"]))

  defp unreleased do
    read(@changelog) |> String.split("## [Unreleased]", parts: 2) |> List.last() |> String.split(~r/\n## \[/, parts: 2) |> hd() |> squash()
  end

  defp decisions do
    [_, d] = read(@story_file) |> squash() |> String.split("## Decisions", parts: 2)
    [d, _] = String.split(d, "## Definition of Done", parts: 2)
    d
  end

  defp risk_rows, do: read(@risks) |> String.split("\n") |> Enum.filter(&(&1 =~ @story)) |> Enum.join("\n") |> squash()

  defp rel(file), do: Path.relative_to(file, @root)
  defp lib_sources, do: Path.wildcard(Path.join(@lib, "**/*.ex"))
  defp sources_naming_tables, do: Enum.filter(lib_sources(), &(read(&1) =~ ~r/to_device_messages|to_device_txns/))
  defp to_device_sources, do: Enum.filter(lib_sources(), &(Path.basename(&1) =~ ~r/to_device/))
  # the node-local slots of the sends: a monitor based GenServer module of its own that names no table (the cluster-safe rule is about the DATA modules)
  defp gate_sources, do: Enum.filter(lib_sources(), &(read(&1) =~ "to_device_max_concurrent_sends_per_node" and read(&1) =~ "Process.monitor"))
  defp code_lines(file), do: file |> read() |> String.split("\n") |> Enum.reject(&Regex.match?(~r/^\s*(#|\*)/, &1))

  # ═══ docs ═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════

  describe "ADR-011" do
    test "carries the update: the to-device transport enables no E2EE room, the server never decrypts or logs the content, m.room.encryption stays rejected" do
      adr = squash(read(@adr))
      assert adr =~ @story, "the update names the story"
      assert adr =~ ~r/to-device|sendToDevice/i
      assert adr =~ ~r/opak|opaque/i, "the contents are opaque"
      assert adr =~ "m.room.encryption" and adr =~ ~r/abgelehnt|rejected|reject|ablehn/i, "ADR-011 itself stays: m.room.encryption is still rejected"
    end
  end

  describe "architecture docs" do
    test "04-solution-strategy lists the to-device queue as a pattern: PostgreSQL-backed, acknowledged by the next sync token, woken through :pg" do
      text = squash(read(@strategy))
      assert text =~ ~r/to-device/i
      [_, from] = Regex.split(~r/to-device/i, text, parts: 2)
      near = String.slice(from, 0, 900)
      assert near =~ "PostgreSQL" and near =~ ~r/next (sync )?token|`?since`? token/i and near =~ ~r/\bpg\b|:pg/
    end

    test "05-building-blocks names the modules, the route and both tables, the migration and the story" do
      text = squash(read(@blocks))
      assert text =~ @story
      for term <- ["Nebu.Matrix.HttpToDevice", "Nebu.Matrix.ToDeviceStore", "sendToDevice", "000059" | @tables], do: assert(text =~ term, "05-building-blocks does not name #{term}")
    end

    test "07-deployment has the operator facts: the purge job, the TTLs, node-local limits (N x), the sweep of the messages a user SENT" do
      sec = squash(section(read(@deploy), ["to-device"]))
      assert sec =~ "Nebu.Workers.ToDevicePurgeWorker"
      assert sec =~ ~r/7 days/ and sec =~ ~r/24 (hours|h)\b/, "the TTL of the messages (7 days) and of the idempotency records (24 hours)"
      assert sec =~ ~r/node[- ]local/i and sec =~ ~r/\bN (x|times|\x{00D7}) the (documented )?limit/u
      assert sec =~ ~r/DELETE\s+FROM\s+to_device_messages\s+WHERE\s+sender\s+IN/i, "the sweep also deletes the messages sent by erased users"
      assert sec =~ ~r/maintenance|logout|mass/i or sec =~ ~r/restart/i, "what a restart or a mass logout does to queued messages"
    end

    test "08-concepts has the section 'To-device messaging' with the contract of the story (names, errors, tables, migration)" do
      sec = td_section()
      assert sec =~ @story, "the heading or the text names the story"
      for term <- @tables ++ ["Nebu.Matrix.ToDeviceStore", "000059", "M_BAD_JSON", "M_NOT_JSON", "M_INVALID_PARAM", "M_TOO_LARGE", "M_LIMIT_EXCEEDED", "M_USER_DEACTIVATED", "ADR-011", "ADR-018", "ADR-020"],
          do: assert(sec =~ term, "the section does not mention #{term}")

      assert sec =~ ~r/opaque/i and sec =~ ~r/never.{0,60}(decrypt|log)/is
    end

    test "08-concepts: every limit and budget with its number (an aggregate for every per-item cap)" do
      sec = td_section()
      assert sec =~ "64 KiB", "the request body"
      assert sec =~ ~r/\b50\b.{0,60}(recipient )?entries|entries.{0,60}\b50\b/is and sec =~ ~r/`?\*`?.{0,60}(counts|counted).{0,30}(as )?one/is, "50 recipient entries, `*` counts as one"
      assert sec =~ ~r/\b500\b.{0,60}(per )?device|device.{0,60}\b500\b/is and sec =~ ~r/\b500 messages\b.{0,20}8 MiB/, "per device: 500 messages and 8 MiB"
      assert sec =~ ~r/\b2[ ,_.\x{202F}\x{00A0}]?000\b.{0,60}(per )?user|user.{0,60}\b2[ ,_.\x{202F}\x{00A0}]?000\b/isu and sec =~ "32 MiB", "per user: 2000 messages and 32 MiB"
      assert sec =~ ~r/\b100\b.{0,80}(per )?sender|sender.{0,80}\b100\b/is, "per sender and recipient device: 100"
      assert sec =~ ~r/\b200\b.{0,80}4 MiB|4 MiB.{0,80}\b200\b/is and sec =~ ~r/sender and recipient user/i, "per sender and recipient user: 200 messages and 4 MiB"
      assert sec =~ ~r/\b100\b.{0,80}targets|targets.{0,80}\b100\b/is, "at most 100 targets per request (the `*` fan-out)"
      assert sec =~ ~r/\b1[ ,_.\x{202F}\x{00A0}]?000\b.{0,80}(idempotency|transaction)|(idempotency|transaction).{0,80}\b1[ ,_.\x{202F}\x{00A0}]?000\b/isu, "1000 idempotency records per device"
      assert sec =~ ~r/100.{0,40}messages.{0,60}1 MiB|1 MiB.{0,60}100.{0,40}messages/is, "a sync response carries at most 100 messages and 1 MiB"
      assert sec =~ "7 days" and sec =~ ~r/24 hours/, "the TTLs"
      assert sec =~ ~r/128/, "the row overhead of the byte budgets"
      assert sec =~ ~r/60.{0,20}min.{0,40}burst.{0,10}\b30\b/is, "the sender rate limit: 60 per minute, burst 30, per user"
    end

    test "08-concepts: the concurrency bounds - 1 MiB of rows per request, 4 sends per user and 6 per node in flight (monitor based slots, 429 before the body), node-local" do
      sec = td_section()
      assert sec =~ ~r/1 MiB.{0,80}(rows|fan-out).{0,40}(per request|request)|(per request|request).{0,80}1 MiB.{0,40}(rows|fan-out)/is, "the rows of one request cost at most 1 MiB"
      assert sec =~ "to_device_max_concurrent_sends_per_node" and sec =~ "to_device_max_concurrent_sends_per_user"
      assert sec =~ ~r/\b4\b.{0,60}per user|per user.{0,60}\b4\b/is and sec =~ ~r/\b6\b.{0,60}per node|per node.{0,60}\b6\b/is
      assert sec =~ ~r/monitor|:DOWN/i, "the slots are monitor based"
      assert sec =~ ~r/rate limit is not a concurrency limit|concurrency limit/i
    end

    test "08-concepts: acknowledgement on the NEXT token (never on delivery), retries redeliver, initial / fallback / foreign tokens acknowledge nothing, late commits are never lost" do
      sec = td_section()
      assert sec =~ ~r/(never|not).{0,40}(on|at) delivery|only when.{0,80}(next|later).{0,60}(sync|token)/is
      assert sec =~ ~r/(older|earlier|previous).{0,40}(since|token).{0,80}(again|redeliver)/is
      assert sec =~ ~r/initial.{0,200}(nothing|no).{0,40}(acknowledg|delet)/is
      assert sec =~ ~r/(another|foreign|other) device.{0,120}(never|nothing)/is, "a token of another device acknowledges nothing"
      assert sec =~ ~r/(late|out[- ]of[- ]order).{0,80}commit|commit.{0,80}(late|out of order)/is
      assert sec =~ ~r/`?to_device`?.{0,80}\{"events": ?\[\]\}|always.{0,40}`?to_device/is, "to_device is always emitted"
    end

    test "08-concepts: the recipient restriction (shared room, join or invite, evaluated at send time, silent), no oracle, `*`, explicit wins, the sending device excluded" do
      sec = td_section()
      assert sec =~ ~r/shared room|share a room/i and sec =~ ~r/both sides? are `?join`?|`?join`? on both sides/i and sec =~ ~r/send time|at send/i
      assert sec =~ ~r/invitation.{0,80}(opens no|no send path|does not count)/is, "an invitation opens no send path"
      refute sec =~ ~r/(either side|`join` or `invite`)/, "the superseded 'join or invite' rule is gone from the contract"
      assert sec =~ ~r/silent/i and sec =~ ~r/(oracle|identical)/i
      assert sec =~ ~r/explicit.{0,80}wins|wins.{0,80}`?\*`?/is
      assert sec =~ ~r/sending device.{0,60}(exclud|not receive)|exclud.{0,60}sending device/is
      assert sec =~ ~r/deactivat.{0,120}(skip|not (queue|extend)|nothing new)/is, "a deactivated recipient receives nothing new, its queue is kept"
    end

    test "08-concepts: a full queue evicts the OLDEST, the sender is never told (no 429), the count is logged without content, one sender cannot fill another user's queue" do
      sec = td_section()
      assert sec =~ ~r/oldest/i and sec =~ ~r/evict/i
      assert sec =~ ~r/(never|not) (told|informed)|no 429|never.{0,20}429/is
      assert sec =~ ~r/count.{0,60}(without|no) content|without content/i
      assert sec =~ ~r/fair/i and sec =~ ~r/largest share/i, "the user-level eviction is fair: the largest share loses its oldest first"
    end

    test "08-concepts: authentication and the rate limit come BEFORE the body is read (401 for an anonymous request, 429 before parsing), try-locks, no waiting locks" do
      sec = td_section()
      assert sec =~ ~r/after.{0,60}authenticat|authenticat.{0,160}before.{0,80}(read|pars|body)/is
      assert sec =~ ~r/401/ and sec =~ ~r/429.{0,80}before.{0,60}(read|pars|body)|rate limit.{0,120}before.{0,60}(read|pars|body)/is
      assert sec =~ ~r/try[- ]?lock|lock_timeout|no waiting lock|never waits? for a lock/i
    end

    test "08-concepts: wake-up of exactly the target device through :pg, cluster safe (database state), node-local buckets (N x the limit)" do
      sec = td_section()
      assert sec =~ ~r/target device/i and sec =~ ~r/:pg|\bpg\b/
      assert sec =~ ~r/cluster/i and sec =~ ~r/database|PostgreSQL/
      assert sec =~ ~r/node[- ]local/i and sec =~ ~r/\bN (x|times|\x{00D7}) the (documented )?limit/u
    end

    test "08-concepts: the lifecycle - device removal purges queue and records, session revoke does not, deactivation keeps, erasure deletes (also the messages SENT), the TTL job is cluster safe" do
      sec = td_section()
      assert sec =~ ~r/(device (delete|deletion|removal)|logout).{0,200}(purge|delet)/is
      assert sec =~ ~r/(session.{0,80}revok|revok.{0,80}session).{0,200}(keep|stay|not purge|does not)/is
      assert sec =~ ~r/sender.{0,200}(erasure|erased)|(erasure|erased).{0,200}sender/is
      assert sec =~ "Nebu.Workers.ToDevicePurgeWorker" and sec =~ ~r/Oban/ and sec =~ ~r/leader|SKIP LOCKED|atomic/i
    end

    test "08-concepts: the client compatibility note (verification with a user you share a room with, between your own devices; in-room verification does not need it)" do
      sec = td_section()
      assert sec =~ ~r/compatib/i and sec =~ ~r/verification/i and sec =~ ~r/own devices|your own/i and sec =~ ~r/room you share|shares? (at least )?a room|shared room/i
    end

    test "08-concepts: the GDPR erasure paragraph names ToDeviceStore.send with its OWN fence key to_device_erasure (not sync_global) and that it refuses an erased user" do
      concepts = squash(read(@concepts))
      [_, inventory] = String.split(concepts, "### GDPR erasure inventory", parts: 2)
      para = String.slice(inventory, 0, 9000)
      assert para =~ "ToDeviceStore" and para =~ "to_device_erasure|", "the fence has its own key"
      assert para =~ ~r/ToDeviceStore.{0,300}to_device_erasure|to_device_erasure.{0,300}ToDeviceStore/is
      assert para =~ ~r/not the `sync_global`|does not take `sync_global`|OWN/, "the send no longer takes sync_global itself"
      assert para =~ ~r/ToDeviceStore.{0,400}(M_USER_DEACTIVATED|refuse)|(M_USER_DEACTIVATED|refuse).{0,400}ToDeviceStore/is
      assert para =~ ~r/sender/i and para =~ "to_device_messages"
    end

    test "11-risks: the to-device row names the accepted residuals (oldest eviction, node-local limits, the recipient restriction, the fan-out cap, RLS USING (true))" do
      rows = risk_rows()
      assert rows != "", "no row of the risk register names #{@story}"
      assert rows =~ ~r/evict/i and rows =~ ~r/oldest/i
      assert rows =~ ~r/node[- ]local/i and rows =~ ~r/\bN (x|times|\x{00D7}) the (documented )?limit/u
      assert rows =~ ~r/recipient restriction|shared room/i and rows =~ ~r/client/i
      assert rows =~ ~r/fan-out|targets/i
      assert rows =~ ~r/wake|rebuild/i and rows =~ ~r/(100|targets).{0,200}(wake|rebuild)|(wake|rebuild).{0,200}(100|targets)/is, "one request can wake (and make rebuild) up to 100 polls of a user's devices"
      assert rows =~ ~r/starv/i or rows =~ ~r/node slots?/i, "the node-wide send slots can be held by colluding accounts (accepted)"
      assert rows =~ ~r/RLS.{0,200}USING ?\(true\)|USING ?\(true\).{0,200}RLS/is and rows =~ ~r/accepted/i
      assert rows =~ ~r/ADR-011|E2EE/
    end

    test "the runbook sweep deletes both tables and the messages sent by erased users" do
      text = read(@runbook)
      assert text =~ ~r/DELETE\s+FROM\s+to_device_messages\s+WHERE\s+user_id\s+IN/i
      assert text =~ ~r/DELETE\s+FROM\s+to_device_txns\s+WHERE\s+user_id\s+IN/i
      assert text =~ ~r/DELETE\s+FROM\s+to_device_messages\s+WHERE\s+sender\s+IN/i, "the messages SENT by erased users (sender)"
    end
  end

  describe "migration number 000059 (000058 is the key backup of the sibling story, 000056 / 000057 live on another branch)" do
    defp lines_with(path, regex), do: read(path) |> String.split("\n") |> Enum.filter(&(&1 =~ regex)) |> Enum.join("\n") |> squash()

    test "the to-device entries of the docs name 000059 and no other migration number" do
      to_device_text = [
        {"CHANGELOG", lines_with(@changelog, ~r/sendToDevice/)},
        {"05-building-blocks", lines_with(@blocks, ~r/to-device|ToDevice|to_device/i)},
        {"08-concepts section", td_section()}
      ]

      for {label, text} <- to_device_text do
        assert text != "", "#{label}: no to-device text"
        refute text =~ ~r/000056|000057|000058/, "#{label} names a wrong number for the to-device migration"
      end

      assert unreleased() =~ "000059"
      assert td_section() =~ "000059"
    end
  end

  describe "CHANGELOG" do
    test "the [Unreleased] entry names the route, the tables, the limits and the migration" do
      u = unreleased()
      assert u =~ "sendToDevice" and u =~ "to_device" and u =~ "000059"
      assert u =~ ~r/to-device/i and u =~ ~r/(story|to-device-messaging)/
      assert u =~ ~r/recipient|shared room/i, "the client-visible consequence of the recipient restriction"
    end
  end

  describe "story Constraints and Decisions agree" do
    test "the Constraints block carries the owner and orchestrator decisions (superseded lines are marked, the old rules are gone)" do
      story = squash(read(@story_file))
      [_, rest] = String.split(story, "Constraints (", parts: 2)
      [cons, _] = String.split(rest, "## Acceptance Criteria", parts: 2)
      assert cons =~ ~r/SUPERSEDED/, "superseded lines are marked"
      assert cons =~ ~r/BOTH sides are `join`/ and cons =~ ~r/evicts its OLDEST/
      assert cons =~ ~r/SUPERSEDED[^.]{0,200}session revoke/ and cons =~ ~r/SUPERSEDED[^.]{0,200}access token/ and cons =~ ~r/SUPERSEDED[^.]{0,200}consistent with send-event/
      refute cons =~ ~r/share at least one room with the sender, plus/
      refute cons =~ ~r/per access token and device, like/
      refute cons =~ ~r/at most 500 queued messages per device \(`M_LIMIT_EXCEEDED` \/ 429\)/
    end
  end

  describe "story Decisions" do
    test "record the pinned rules, the ambiguous choices with their reasons and the open questions" do
      d = decisions()
      assert d =~ ~r/next token|next sync/i and d =~ ~r/ack/i
      assert d =~ ~r/evict/i and d =~ ~r/oldest/i
      assert d =~ ~r/per[- ]sender|sender.{0,40}share/i and d =~ "100"
      assert d =~ ~r/fan-out|targets/i
      assert d =~ ~r/try[- ]?lock|lock_timeout/i and d =~ "sync_global"
      assert d =~ "000059" and d =~ "Nebu.Workers.ToDevicePurgeWorker"
      assert d =~ ~r/recipient restriction/i and d =~ ~r/oracle/i
      assert d =~ ~r/BOTH sides are `join`/ and d =~ ~r/supersedes the orchestrator refinement/i
      assert d =~ ~r/FAIR/ and d =~ ~r/LARGEST share/ and d =~ "200 messages and 4 MiB" and d =~ ~r/accepted residual/i
      assert d =~ ~r/atdd_to_device_before_join/ and d =~ ~r/same statements/i
      assert d =~ ~r/open question/i
      assert d =~ ~r/node[- ]local/i
    end
  end

  # ═══ cycle 1: Kassandra (1 HIGH, 4 MEDIUM, 2 LOW) and the code review (6 MINOR) ═════════════════════════════════════════════════

  describe "cycle 1 docs" do
    test "08-concepts: the per-SENDER total (4000 messages / 16 MiB over ALL recipients), the 1 MiB device share, the fair DEVICE eviction" do
      sec = td_section()
      assert sec =~ ~r/\b4000\b.{0,80}16 MiB|16 MiB.{0,80}\b4000\b/is and sec =~ ~r/(over|across) all.{0,40}recipients|all its recipients/i, "per sender over all recipients: 4000 messages and 16 MiB"
      assert sec =~ ~r/(per sender and recipient device|sender and recipient device).{0,120}1 MiB|1 MiB.{0,80}sender and recipient device/is, "the byte share per sender and device"
      assert sec =~ ~r/DEVICE and (at )?the USER level|device and user level|device- and user-level/i and sec =~ ~r/(colluding|two).{0,80}(never|cannot)/is, "the fair eviction covers the device level"
    end

    test "08-concepts: the byte-cost bucket (4 MiB / min, burst 8 MiB, ASKED bytes, no oracle, rolled back, N x)" do
      sec = td_section()
      assert sec =~ ~r/byte-cost bucket/i and sec =~ ~r/4 MiB per minute/ and sec =~ ~r/burst 8 MiB/
      assert sec =~ ~r/ASKS to fan out|asks to fan out/ and sec =~ ~r/never with the accepted bytes|not with the accepted bytes/i
      assert sec =~ ~r/state independent|no oracle/i
      assert sec =~ ~r/rolled back/ and sec =~ ~r/(txn id|transaction id).{0,40}not burnt|not burnt/i and sec =~ ~r/charged as the burst/
      assert sec =~ ~r/byte-cost bucket.{0,700}N x/is, "node-local like the rate limit"
    end

    test "08-concepts: 2 s statement timeout, SKIP LOCKED, a delivery fault never fails /sync (200, empty to_device, position kept), 6 slots per node" do
      sec = td_section()
      assert sec =~ ~r/statement_timeout.{0,40}2 s|2 s.{0,60}statement[_ ]timeout/is
      assert sec =~ ~r/FOR UPDATE SKIP LOCKED/ and sec =~ ~r/(eviction|acknowledgement).{0,120}stamp|stamp.{0,120}SKIP LOCKED/is
      assert sec =~ ~r/never fails `?\/sync`?/ and sec =~ ~r/to_device: ?\{"events": ?\[\]\}/ and sec =~ ~r/position is kept|keeps? the position/i
      assert sec =~ ~r/\b6\b.{0,60}per node|per node.{0,60}\b6\b/is
      refute sec =~ ~r/\b32\b.{0,30}per node|per node.{0,30}\b32\b/is, "the old 32 node slots are superseded"
    end

    test "08-concepts: own erasure fence key, matched recipients only, FOR KEY SHARE, device delete locks the row first" do
      sec = td_section()
      assert sec =~ "to_device_erasure|<user>" and sec =~ ~r/OWN key/
      assert sec =~ ~r/(never|no) makes? a message skip|never make a message skip/i
      assert sec =~ ~r/only the recipients that passed the shared-room join|never one lock per requested id/i
      assert sec =~ "FOR KEY SHARE" and sec =~ ~r/device delete locks the device row first/i
    end

    test "08-concepts: about 16 devices (15 when the body is full) and the corrected position sentence" do
      sec = td_section()
      assert sec =~ ~r/about 16 devices/ and sec =~ ~r/\b15\b.{0,60}(fills|whole body|full)/is
      refute sec =~ "covers exactly the batch a response carried", "the sentence is superseded: the acknowledgement covers what the responses STAMPED"
      assert sec =~ ~r/covers exactly the messages the responses stamped/i
      assert sec =~ ~r/(lost|loses) (a|the) race|overlapping sync/i
      assert sec =~ ~r/never covers a (row|message) it did not carry/i, "the position claims only rows the response carried"
      refute sec =~ ~r/never exceeds its own stamps/i, "the old wording was inexact (stamps of already-stamped carried rows count as well)"
    end

    test "07-deployment: worst-case footprint, byte bucket N x, sequence reset note, the sender shares" do
      sec = squash(section(read(@deploy), ["to-device"]))
      assert sec =~ ~r/worst-case database footprint/i and sec =~ ~r/32 MiB/ and sec =~ ~r/16 MiB/ and sec =~ ~r/(users|sharing).{0,80}(room)/i
      assert sec =~ ~r/byte-cost bucket.{0,200}N x|N x.{0,200}byte-cost bucket/is
      assert sec =~ ~r/sequence reset|reset.{0,40}sequence/i and sec =~ "to_device_delivery_seq" and sec =~ ~r/stream_pos/
      assert sec =~ ~r/\bctid\b/ and sec =~ "oauth_cleanup"
      assert sec =~ ~r/6 sends per node/ and sec =~ ~r/2 s/
      assert sec =~ ~r/1 MiB.{0,60}sender and (recipient )?device|sender and (recipient )?device.{0,60}1 MiB/i, "the 1 MiB share per sender and device"
      assert sec =~ ~r/200 messages.{0,30}4 MiB.{0,80}sender and (recipient )?user|sender and (recipient )?user.{0,80}200 messages.{0,30}4 MiB/i, "200 messages / 4 MiB per sender and recipient user"
    end

    test "11-risks: no two-are-enough residual, 6 slots, follow-ups, accepted notes, corrected wording" do
      rows = risk_rows()
      refute rows =~ ~r/many colluding senders, each below its share, can still evict/i
      refute rows =~ ~r/two (colluding )?(co-members|senders) are enough|two are enough/i
      assert rows =~ ~r/only MANY senders|MANY senders/ and rows =~ ~r/(a single flooder or )?two colluding co-members cannot/i
      assert rows =~ ~r/send slots \(6\)/ and not (rows =~ ~r/send slots \(32\)/)
      assert rows =~ ~r/worst-case database footprint/i and rows =~ ~r/32 MiB/ and rows =~ ~r/16 MiB/
      assert rows =~ "Jason.Fragment" and rows =~ ~r/running counter/i and rows =~ ~r/follow-up/i
      assert rows =~ ~r/ctid/ and rows =~ "oauth_cleanup" and rows =~ ~r/\bCAS\b/
      assert rows =~ ~r/byte-cost bucket.{0,100}N x|N x.{0,100}byte-cost/is
      # corrected meanings of the delta code review (cycle 1)
      assert rows =~ ~r/never covers a (row|message) it did not carry/i and not (rows =~ ~r/never exceeds its own stamps/i), "(8) the position wording"
      assert rows =~ ~r/(explicit device|explicit entry|explicit device entry).{0,200}(429|lock.timeout)|(429|lock.timeout).{0,200}(explicit device|explicit entry)/is, "(11) an explicit device entry meets the delete as well as a `*`"
      assert rows =~ ~r/100 ?ms.{0,40}lock.timeout|lock.timeout.{0,40}100 ?ms/i
      assert rows =~ ~r/per statement/i and rows =~ ~r/(dozen|twelve|about 12|~12).{0,40}statements|statements.{0,40}(dozen|twelve)/i, "(4b) the 2 s timeout is per statement, a transaction runs about a dozen"
      assert rows =~ ~r/slot.{0,80}(whole|entire) (run|transaction|request)|(whole|entire) (run|transaction|request).{0,80}slot/i, "(4b) the slot is held for the whole run"
      refute rows =~ ~r/slot is never held for long/i
    end

    test "CHANGELOG: the new limits, the delivery fault behaviour, the byte bucket after the parse" do
      u = unreleased()
      assert u =~ ~r/byte-cost bucket/ and u =~ ~r/4000 messages/
      assert u =~ ~r/16 MiB/ and u =~ ~r/6 per node/ and u =~ ~r/2 s statement timeout/
      refute u =~ ~r/32 per node/
      assert u =~ ~r/empty `to_device`/
      assert u =~ ~r/byte-cost bucket.{0,400}after the (body is )?pars(e|ed|ing)|after the (body is )?pars(e|ed|ing).{0,400}byte-cost bucket/is, "the byte bucket fires after the parse"
      if u =~ "before the body", do: assert(u =~ ~r/only.{0,200}before the body/is, "only the request rate limit and the slot gate come before the body is read")
    end

    test "story Decisions record the cycle 1 rules, the deviation, the superseded numbers, the position rule" do
      d = decisions()
      assert d =~ ~r/cycle 1/i and d =~ ~r/superseded/i
      assert d =~ ~r/4000 messages/ and d =~ ~r/16 MiB/ and d =~ ~r/byte-cost bucket|byte bucket/i
      assert d =~ ~r/ASKS to fan out|asked bytes|bytes the request asks/i and d =~ ~r/deviation/i
      assert d =~ ~r/to_device_erasure/ and d =~ ~r/SKIP LOCKED/ and d =~ ~r/statement_timeout|statement timeout/i
      assert d =~ ~r/32 .{0,20}6|from 32 to 6|32 → 6|32 -> 6/i, "node slots 32 -> 6"
      assert d =~ ~r/FOR KEY SHARE/ and d =~ ~r/atdd_to_device_before_stamp/
      assert d =~ ~r/never covers a (row|message) it did not carry/i and not (d =~ ~r/never exceeds the highest stamp/i), "D21 position wording"
    end
  end

  describe "cycle 4 docs and source: the send is two transactions" do
    test "11-risks (12) is a changed note: key share only around the INSERT, the eviction in a second transaction, momentarily soft caps, a failed eviction waits for the next send" do
      rows = risk_rows()
      refute rows =~ ~r/follow-up idea: take the key share right before the INSERT/i, "the follow-up idea is done, not open"
      refute rows =~ ~r/holds `?FOR KEY SHARE`? on the target `?devices`? rows until its transaction commits/i
      assert rows =~ ~r/key.share.{0,300}(only )?(around|right before|immediately before).{0,40}INSERT/is, "the key-share window is only around the INSERT"
      assert rows =~ ~r/(second|separate) transaction/i and rows =~ ~r/eviction.{0,200}(second|separate) transaction|(second|separate) transaction.{0,200}eviction/is
      assert rows =~ ~r/(momentarily|briefly|temporarily) soft/i, "residual: the caps are momentarily soft"
      assert rows =~ ~r/(failed|timed.out) eviction.{0,160}(until|next send)/is, "residual: a failed eviction leaves the excess until the next send"
      assert rows =~ ~r/(closed|resolved|fixed)/i, "the starvation of the victim's bounded FOR UPDATE is marked closed"
    end

    test "08-concepts: the key share only around the INSERT, the eviction in a second transaction without a lock on devices, a failed eviction never fails the send" do
      sec = td_section()
      assert sec =~ ~r/FOR KEY SHARE.{0,200}(only )?(around|right before|immediately before).{0,40}INSERT/is
      assert sec =~ ~r/eviction.{0,250}(second|separate) transaction|(second|separate) transaction.{0,250}eviction/is
      assert sec =~ ~r/without any lock on `?devices`?|no lock on `?devices`?/i
      assert sec =~ ~r/(failed|timed.out) eviction.{0,120}never fails the send|eviction.{0,120}never fails the send/is
    end

    test "07-deployment: the send is two transactions, the caps are momentarily soft, a failed eviction leaves the excess until the next send" do
      sec = squash(section(read(@deploy), ["to-device"]))
      assert sec =~ ~r/(two|second|separate) transactions?/i and sec =~ ~r/eviction/i
      assert sec =~ ~r/(momentarily|briefly|temporarily) soft/i
      assert sec =~ ~r/(failed|timed.out) eviction.{0,120}(until|next send)/is
    end

    test "CHANGELOG: the soft eviction runs in a second transaction after the commit and never fails the send" do
      u = unreleased()
      assert u =~ ~r/eviction.{0,160}(second|separate) transaction|(second|separate) transaction.{0,160}eviction/is
      assert u =~ ~r/(failed|timed.out) eviction never fails the send|never fails the send/i
    end

    test "story Decisions D23 and following record the two phases, the key-share window, the synchronous best-effort phase 2 and the pins adapted" do
      d = decisions()
      assert d =~ ~r/D23|23\./ and d =~ ~r/cycle 4/i
      assert d =~ ~r/phase 1/i and d =~ ~r/phase 2/i and d =~ ~r/(second|separate) transaction/i
      assert d =~ ~r/KEY SHARE.{0,200}(immediately before|right before|only around).{0,60}INSERT/is
      assert d =~ ~r/best.effort/i and d =~ ~r/never fails the send|does not fail the send/i
      assert d =~ ~r/before the (response|answer)/i, "phase 2 runs in the request process before the response"
    end

    test "source: ToDeviceStore.send has two transactions (rows, then the eviction), the moduledoc says so, the eviction touches no devices row and takes no FOR KEY SHARE" do
      src = store_src()
      [_, rest] = String.split(src, "@moduledoc \"\"\"", parts: 2)
      [doc, _] = String.split(rest, "\"\"\"", parts: 2)
      assert squash(doc) =~ ~r/(second|two) transactions?|TWO transactions/i, "the moduledoc describes the two phases"

      code = code_lines(Path.join(@lib, "nebu/matrix/to_device_store.ex")) |> Enum.join("\n")
      [_, after_send] = String.split(code, "def send(sender, sender_device, event_type, txn_id, entries) do", parts: 2)
      send_and_helpers = String.slice(after_send, 0, 4_000)
      assert length(Regex.scan(~r/transact\(/, send_and_helpers)) >= 2, "rows and eviction are two transactions (send/5 and the helper it calls)"

      [_, evict_rest] = String.split(code, "defp evict(sender, us, ds) do", parts: 2)
      [evict_body, _] = String.split(evict_rest, "defp skip_locked", parts: 2)
      refute evict_body =~ ~r/\bdevices\b/, "phase 2 takes no lock on, and reads nothing of, the devices table"
      refute evict_body =~ "KEY SHARE"
    end
  end

  describe "cycle 1 source pins" do
    defp store_src, do: read(Path.join(@lib, "nebu/matrix/to_device_store.ex"))

    test "the moduledoc of ToDeviceStore states the budgets (per sender total, byte bucket, statement timeout, fair eviction, fence key)" do
      [_, rest] = String.split(store_src(), "@moduledoc \"\"\"", parts: 2)
      [doc, _] = String.split(rest, "\"\"\"", parts: 2)
      doc = squash(doc)

      for term <- ["4000 messages", "16 MiB", "4 MiB per minute", "burst 8 MiB", "statement_timeout", "2 s", "FAIRLY", "LARGEST share", "to_device_erasure|<user>", "SKIP LOCKED"],
          do: assert(doc =~ term, "the moduledoc does not state #{term}")
    end

    test "the purge worker goes through the facade Nebu.Matrix.purge_expired_to_device/0 and does not call ToDeviceStore itself; the facade delegates" do
      worker = read(Path.join(@lib, "nebu/workers/to_device_purge_worker.ex")) |> String.split("\n") |> Enum.reject(&Regex.match?(~r/^\s*(#|\*)/, &1)) |> Enum.join("\n")
      [_, code] = String.split(worker, "use Oban.Worker", parts: 2)
      assert code =~ "Nebu.Matrix.purge_expired_to_device()"
      refute code =~ "ToDeviceStore"
      facade = read(Path.join(@lib, "nebu/matrix.ex"))
      assert facade =~ ~r/def purge_expired_to_device\b/ and facade =~ ~r/ToDeviceStore\.purge_expired\b/
    end

    test "the erasure fence has its own key in the store AND in the erasure; the store takes no sync_global lock" do
      store = code_lines(Path.join(@lib, "nebu/matrix/to_device_store.ex")) |> Enum.join("\n")
      assert store =~ "to_device_erasure|"
      refute store =~ "sync_global|", "the store must not take the sync_global key"
      deletion = read(Path.join(@lib, "nebu/compliance/user_deletion.ex"))
      assert deletion =~ ~r/pg_advisory_xact_lock\(hashtextextended\('to_device_erasure\|'/, "the erasure takes the fence exclusively"
    end

    test "UserDeletion documents the exclusive to_device_erasure|<user> lock in its moduledoc and in the step 4a comment" do
      src = read(Path.join(@lib, "nebu/compliance/user_deletion.ex"))
      [_, rest] = String.split(src, "@moduledoc \"\"\"", parts: 2)
      [doc, _] = String.split(rest, "\"\"\"", parts: 2)
      assert doc =~ "to_device_erasure|", "the moduledoc (step 4a) lists the to-device fence"
      [_, after_4a] = String.split(src, "Step 4a", parts: 2)
      comment = after_4a |> String.split("\n") |> Enum.take_while(&(&1 =~ ~r/^\s*#/ or &1 =~ ~r/^\s*$/ or &1 =~ "Step 4a")) |> Enum.join("\n")
      assert comment =~ "to_device_erasure|", "the step 4a comment lists the to-device fence"
    end

    test "FOR UPDATE SKIP LOCKED in the acknowledgement, the stamp and the eviction; FOR KEY SHARE on the target devices; a statement_timeout set per transaction" do
      store = code_lines(Path.join(@lib, "nebu/matrix/to_device_store.ex")) |> Enum.join("\n")
      assert length(Regex.scan(~r/FOR UPDATE SKIP LOCKED/, store)) >= 4, "ack, stamp, eviction and purge each skip locked rows"
      assert length(Regex.scan(~r/FOR KEY SHARE/, store)) >= 1
      assert store =~ ~r/set_config\('statement_timeout'/
      assert store =~ ~r/:query_canceled/ and store =~ ":statement_timeout"
    end

    test "delete_device and delete_device! lock the device row FIRST (before the queue is deleted)" do
      src = read(Path.join(@lib, "nebu/matrix/device_key_store.ex"))
      [_, rest] = String.split(src, "def delete_device(user_id, device_id)", parts: 2)
      [body, _] = String.split(rest, "def delete_device!", parts: 2)
      assert body =~ ~r/lock_device_row!.{0,400}delete_device_rows!/s, "delete_device locks the devices row before it deletes"
      [_, rest2] = String.split(src, "def delete_device!(user_id, device_id, repo", parts: 2)
      [body2, rest3] = String.split(rest2, "defp delete_device_rows!", parts: 2)
      assert body2 =~ ~r/lock_device_row!.{0,400}delete_device_rows!/s, "delete_device! locks the devices row before it deletes"
      # the shared helper runs the DELETEs first and stamps the device list only afterwards (one lock order with put_device_keys)
      [rows_body, _] = String.split(rest3, "@doc", parts: 2)
      assert rows_body =~ ~r/DELETE FROM.{0,600}stamp_keys!/s, "delete_device_rows! deletes before it stamps"
      assert src =~ ~r/@device_tables .*device_keys/s
    end

    test "the sync route answers a to-device delivery error with an EMPTY to_device (no 503 for the delivery) and logs the kind only" do
      protected = read(Path.join(@lib, "nebu/web/router/protected.ex"))
      [_, rest] = String.split(protected, "defp finish_sync", parts: 2)
      [body, _] = String.split(rest, "\n  defp ", parts: 2)
      refute body =~ "503", "a delivery fault must not fail the sync"
      assert body =~ ~r/\[\]/ and body =~ ~r/to-device/
    end

    test "the send gate defaults to 6 slots per node and 4 per user" do
      gate = read(Path.join(@lib, "nebu/matrix/to_device_send_gate.ex"))
      assert gate =~ ~r/@default_per_node 6\b/ and gate =~ ~r/@default_per_user 4\b/
    end

    test "active_users locks only the ids that passed the shared-room join (a materialised candidate set, the lock function runs on the join result)" do
      store = read(Path.join(@lib, "nebu/matrix/to_device_store.ex"))
      assert store =~ ~r/WITH cand AS MATERIALIZED/ and store =~ ~r/locked AS MATERIALIZED/
    end
  end

  # ═══ source rules ═══════════════════════════════════════════════════════════════════════════════════════════════════════════

  describe "source: cluster safety (ADR-020), no process state in the code that touches the to-device tables" do
    @forbidden ~r/:ets\.|:persistent_term|\bAgent\.|\bGenServer\.|:counters\.|:atomics\.|Process\.(put|get)\(|Application\.put_env|:erlang\.put\(|Registry\.|Cachex|ConCache|Nebulex|:mnesia|:global\.|:pg\.(join|leave)/

    test "some module of server/lib names both tables (the scans below are not vacuous)" do
      text = sources_naming_tables() |> Enum.map(&read/1) |> Enum.join("\n")
      for t <- @tables, do: assert(text =~ t, "no code names #{t}")
      assert to_device_sources() != [], "no module named to_device*"
    end

    test "no ETS, persistent_term, Agent, GenServer, counters, process dictionary, env write, registry, distributed state" do
      for file <- (sources_naming_tables() ++ to_device_sources()) |> Enum.uniq() |> Kernel.--(gate_sources()), file |> code_lines() |> Enum.any?(&Regex.match?(@forbidden, &1)) do
        offenders = file |> code_lines() |> Enum.filter(&Regex.match?(@forbidden, &1))
        flunk("#{rel(file)} keeps process state: #{inspect(offenders)}")
      end
    end

    test "the wake-up is the cluster-wide :pg broadcast and nothing else (`:pg.get_members` to the user group), no direct node calls" do
      text = sources_naming_tables() |> Enum.map(&read/1) |> Enum.join("\n")
      assert text =~ ":pg.get_members", "a message must wake the long poll on any node"
      refute text =~ ~r/Node\.list|:rpc\.|:erpc\./
    end

    test "the sync wait loop wakes on a message for THIS device only (a `{:to_device, device}` clause that compares the device)" do
      server = read(Path.join(@lib, "nebu/matrix/event_dispatcher/server.ex"))
      assert server =~ ~r/\{:to_device,\s*\w+\}/, "no :to_device clause in the long-poll wait loop"
      assert server =~ ~r/\{:to_device,\s*(\w+)\}.{0,200}\1 == device_id|\{:to_device,\s*\^device_id\}/s, "the clause must compare the target device with this poll's device"
    end
  end

  describe "source: the send slots" do
    test "a module reads both seams, monitors the request process, handles :DOWN and names no to-device table; it is a child of the application" do
      slot_files = gate_sources()
      assert slot_files != [], "no module reads :to_device_max_concurrent_sends_per_node and monitors the request process"

      for f <- slot_files do
        src = read(f)
        assert src =~ "to_device_max_concurrent_sends_per_user", "#{rel(f)}: the per-user seam"
        assert src =~ ~r/:DOWN/, "#{rel(f)}: a monitor based slot frees on :DOWN"
        refute src =~ ~r/to_device_messages|to_device_txns/, "#{rel(f)}: the slot module holds no queue data"
        module = src |> then(&Regex.run(~r/defmodule ([\w.]+) do/, &1)) |> List.last()
        assert read(Path.join(@lib, "nebu/application.ex")) =~ module, "#{module} is not started by the application"
      end
    end

    test "the route takes a slot BEFORE the body is parsed (gate, then parse_to_device)" do
      protected = read(Path.join(@lib, "nebu/web/router/protected.ex"))
      assert protected =~ ~r/ToDeviceSendGate\.run.{0,600}parse_to_device/s
    end
  end

  describe "source: no waiting locks, bounded work, ADR-018" do
    test "no blocking lock call (pg_advisory_lock, pg_advisory_xact_lock, LOCK TABLE, FOR UPDATE / FOR SHARE without NOWAIT or SKIP LOCKED) in the to-device code" do
      sources = to_device_sources()
      assert sources != []

      for file <- sources, line <- code_lines(file) do
        refute line =~ ~r/pg_advisory_(xact_)?lock(_shared)?\s*\(|LOCK\s+TABLE/i, "#{rel(file)}: a blocking lock: #{String.trim(line)}"

        if line =~ ~r/FOR\s+(UPDATE|SHARE|NO KEY UPDATE)/i,
          do: assert(line =~ ~r/NOWAIT|SKIP\s+LOCKED/i, "#{rel(file)}: a row lock that waits: #{String.trim(line)}")
      end
    end

    test "the send path bounds its wait for rows another transaction holds (lock_timeout, NOWAIT or a try-lock) and takes the erasure fence as a TRY-lock" do
      text = to_device_sources() |> Enum.map(&read/1) |> Enum.join("\n")
      assert text =~ ~r/lock_timeout|NOWAIT/i
      assert text =~ ~r/pg_try_advisory_xact_lock(_shared)?\s*\(/i and text =~ "to_device_erasure|"
    end

    test "SQL stays inline (ADR-018): no Ecto schema, changeset or repository / service module for the queue" do
      for file <- to_device_sources() do
        src = read(file)
        refute src =~ ~r/use Ecto\.Schema|Ecto\.Changeset|schema\s+"to_device/, "#{rel(file)}: ADR-018 forbids Ecto schemas / changesets"
        refute Path.basename(file) =~ ~r/repository|_repo\.ex\z|service/, "#{rel(file)}: no repository / service layer (ADR-018)"
      end
    end

    test "a request body is parsed AFTER the authentication: the route calls the 64 KiB parser itself and JsonBody skips the path" do
      protected = read(Path.join(@lib, "nebu/web/router/protected.ex"))
      assert protected =~ ~r/sendToDevice/ and protected =~ ~r/JsonBody\.parse_to_device|parse_to_device\(/, "the route must read its body with its own capped parser"
      json_body = read(Path.join(@lib, "nebu/web/plugs/json_body.ex"))
      assert json_body =~ "sendToDevice" and json_body =~ ~r/65_?536/, "JsonBody names the path and the 64 KiB cap"
    end
  end

  describe "source: content is never logged" do
    test "no Logger call in the to-device code names content, bodies, params, entries or an inspected term" do
      assert to_device_sources() != []

      for file <- to_device_sources(),
          line <- code_lines(file),
          Regex.match?(~r/Logger\.(debug|info|notice|warning|warn|error|critical|alert|emergency|log)\b/, line) do
        refute line =~ ~r/content|body_params|raw_body|payload|entries|\bevents?\b|inspect\(|\bparams\b/i, "#{rel(file)}: a log call may name content: #{String.trim(line)}"
      end
    end

    test "no telemetry event, no `inspect` of a conn or request and no IO output in the to-device code" do
      for file <- to_device_sources(), line <- code_lines(file) do
        refute line =~ ~r/:telemetry\.execute|IO\.(puts|inspect)|inspect\((conn|params|body|content|entries)/, "#{rel(file)}: #{String.trim(line)}"
      end
    end

    test "the RequestLogger skips the body of the route through RawBodyReader.to_device_shape?/1" do
      logger = read(Path.join(@lib, "nebu/web/plugs/request_logger.ex"))
      assert logger =~ "to_device_shape?"
    end

    test "the route normalizer has the sendToDevice anchor (type and txn id replaced)" do
      normalizer = read(Path.join(@lib, "nebu/web/log_store/route_normalizer.ex"))
      assert normalizer =~ ~r/"sendToDevice"\s*=>\s*%\{1 => @event_type_placeholder, 2 => @txn_id_placeholder\}/
    end
  end
end
