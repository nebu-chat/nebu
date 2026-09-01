---
story_id: 4b-media-scan-worker
title: "Async Scan Worker: MediaScanWorker Scan Flow + Retry/Discard"
epic: media-security-admin-control
status: done
security_review: required
ui: false
created: 2026-07-12
branch: feature/advanced-media-management
target_release: 0.3.0
---

## Summary

Story 2b transitions an upload from `:reserved` to `:quarantined` and enqueues an async scan
job by `media_id` — but it deliberately stops there ("queue/worker contract owned by Story
4b"). Story 3 provides `Nebu.Media.ClamAV.scan_binary/1`, an in-process TCP client for clamd
that returns `{:ok, :clean}` / `{:ok, {:infected, signature}}` / `{:error, reason}` for an
in-memory binary. Neither story wires the two together.

This story adds that missing link: `Nebu.Workers.MediaScanWorker`, an Oban worker that picks
up a `:quarantined` media id, transitions it to `:scanning`, fetches and decrypts its bytes
from S3/MinIO, calls `ClamAV.scan_binary/1`, and drives the state machine to whichever
terminal outcome the scan produces — `:released` (clean), `:infected` (malware found), or,
after retries are exhausted, `scan_failed` (Story 4a's dead-letter state).

**Oban is not yet a dependency of this codebase** (confirmed: absent from `server/mix.exs`
and from `server/lib/nebu/`/`server/test/`; `Nebu.Compliance.SessionExpiryWorker` is a plain
`GenServer` with a `Process.send_after` tick, not an Oban worker). Per ADR-025's own framing
("Formalizes a decision already made and referenced throughout... 4b, 7, 8a/8c, 10a, 13c")
and Story 2e's explicit dependency note ("Story 4b... is built before this story and already
adds the Oban dependency, Postgres-backed job tables, and the app's Oban supervisor entry —
this story only adds a new worker module and a new cron-table entry, it does not re-introduce
Oban itself"), **this story is where the Oban dependency, its Postgres-backed job tables, and
the application's Oban supervisor entry are introduced for the whole codebase.** Every later
story that needs a background job (2e's cleanup cron, 8a/8c's retention crons, 10a's stats
rollup, 13c) builds on the plumbing landed here rather than adding it again.

## User Story

As the Nebu platform, I want every `:quarantined` upload to be scanned by ClamAV asynchronously,
with the result reliably driving the file to `:released`, `:infected`, or (after exhausting
retries on a scanner error) `scan_failed`, so that no file is ever served to a Matrix client
before it has been checked for malware, and a transient clamd outage neither loses the scan
job nor blocks the file in quarantine forever.

## Acceptance Criteria

1. **AC1 — Oban dependency + schema + supervisor entry (first introduction in this
   codebase).** `server/mix.exs` gains `{:oban, "~> 2.18"}` (or the newest 2.x release
   available at implementation time). A new raw-SQL migration pair (next available number
   after whichever migration is HEAD at merge time — `1a`'s `000022_media_state_machine_
   foundation` is the last one currently proposed, so this would be `000023_oban_jobs` unless
   another story's migration lands first) creates Oban's standard Postgres schema
   (`oban_jobs` table, `oban_job_state`/`oban_peers` support objects, indexes, notify
   trigger) **translated into Nebu's raw numbered-SQL migration convention** — Nebu does not
   run `mix ecto.migrate` against `Ecto.Migration` modules, so the usual `Oban.Migration.up/1`
   Ecto-migration helper cannot be used directly; the dev agent must adapt Oban's officially
   published schema SQL for the pinned version into an `.up.sql`/`.down.sql` pair, granting
   `nebu_app` the same privileges the existing migrations grant (see
   `Nebu.Matrix.MigrationsGrantTest`'s convention). `Nebu.Application`'s supervision tree
   gains an `{Oban, Application.fetch_env!(:nebu, Oban)}` child (see Technical Requirements
   for exact placement/ordering relative to `Nebu.Repo`).
2. **AC2 — Queue + cron plugin configuration.** `server/config/config.exs` gains:
   ```elixir
   config :nebu, Oban,
     repo: Nebu.Repo,
     plugins: [
       {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(60)},
       {Oban.Plugins.Pruner, max_age: :timer.hours(24) |> div(1000)}
     ],
     queues: [media_scan: [limit: 10, shutdown_grace_period: :timer.seconds(30)]]
   ```
   `rescue_after` (60 min) is comfortably above the epic's stated max expected scan duration
   (30–60 min) so a crashed node's orphaned `executing` jobs are rescued rather than stuck
   forever (ADR-025). The `crontab:` key is left for later stories (2e, 8a/8c, 10a) to append
   entries to — this story does not add a cron entry of its own, `MediaScanWorker` is enqueued
   on-demand by 2b's upload handler, not on a schedule.
3. **AC3 — `Nebu.Workers.MediaScanWorker` module + `:quarantined → :scanning` entry
   transition.** `use Oban.Worker, queue: :media_scan, max_attempts: 5`. `perform/1` receives
   `%{"media_id" => media_id}` in `job.args` (enqueued by 2b as `%{media_id: media_id}` —
   Oban serializes args through JSON, so the worker reads the string key). The very first
   thing `perform/1` does is `Nebu.Media.StateMachine.transition(media_id, :scanning,
   {:system, nil})` — if this returns `{:error, {:invalid_transition, from, :scanning}}`
   (e.g. the file was admin-blocked or deleted between enqueue and pickup), the worker logs
   and returns `:ok` (treats it as a no-op, not a retryable failure — the job's purpose no
   longer applies).
4. **AC4 — Fetch, decrypt, decompress.** The worker fetches the ciphertext via
   `Nebu.Media.Storage.get(storage_key)`, decrypts it with `Nebu.Media.Crypto.decrypt/3`
   using the row's stored AES key/nonce material, and — only when the row's `compressed`
   flag is `true` — runs `:zlib.gunzip/1` on the decrypted plaintext. The result is the
   original binary, entirely in memory (no temp file), exactly as Story 3's `scan_binary/1`
   expects (ADR-029's compression-before-encryption ordering means decompression is always
   the last of these three steps, after decryption).
5. **AC5 — Clean result → `:released` + broadcast.** `{:ok, :clean}` from `scan_binary/1`
   transitions `:scanning → :released` via `Nebu.Media.StateMachine.transition/4` (actor
   `{:system, nil}`), then broadcasts on `"media:#{media_id}"` (see AC8 for the exact
   payload/topic contract).
6. **AC6 — Infected result → `:infected` + persisted signature + broadcast.**
   `{:ok, {:infected, signature}}` transitions `:scanning → :infected`, passing
   `%{clamav_signature: signature, scanned_at: DateTime.utc_now()}` as `transition/4`'s
   `metadata` argument so it lands in `media_state_transitions.metadata`, **and** persists
   the same signature into `media_files.scan_metadata` (a plain
   `UPDATE media_files SET scan_metadata = $2 WHERE media_id = $1` executed by the worker
   itself is **not** a violation of Story 1b's state-mutation invariant — that check only
   scans for `UPDATE ... SET ... state`, and `scan_metadata` is a non-state column; still,
   prefer doing this write in the same DB transaction the state transition needs, see
   Technical Requirements). Then broadcasts on `"media:#{media_id}"` (AC8).
7. **AC7 — `:file_too_large` is a skip, not an error.** `{:error, :file_too_large}` from
   `scan_binary/1` (Story 3's own size-limit guard, a *different* threshold than 2b's upload
   size cap — do not conflate them) transitions `:scanning → :released` with
   `transition/4`'s metadata set to `%{skipped: "size_limit"}`, and broadcasts on
   `"media:#{media_id}"` exactly like AC5 — it is a terminal, non-retried outcome, not a
   scan failure. (See Dev Agent Guardrails for why this story does **not** additionally call
   `Nebu.Compliance.AuditWriter` for this case.)
8. **AC8 — Broadcast on every terminal transition this worker produces (`:released`,
   `:infected`, `scan_failed`) — hard cross-story requirement for Story 2d.** Story 2d's
   download-stall mechanism subscribes to `"media:#{media_id}"` on `Nebu.PubSub` and expects
   a broadcast for **any** transition out of `:quarantined`/`:scanning` into a terminal
   state — not only the clean-scan path the epic's own prose happens to spell out. This
   worker MUST call
   `Phoenix.PubSub.broadcast(Nebu.PubSub, "media:#{media_id}", {:media_state_transition,
   media_id, new_state})` (the exact topic/registry/payload shape 2d's story already
   documents and tests against) after **every** one of: the clean-scan `:released` (AC5),
   the size-skip `:released` (AC7), the `:infected` transition (AC6), and the exhausted-
   retries `scan_failed` transition (AC9). A stalled downloader must be woken promptly on
   any of these four outcomes, not just the happy path — omitting the broadcast on
   `:infected` or `scan_failed` would leave a stalled client sitting out the full stall
   window even though the file became permanently unavailable (or definitively failed)
   seconds in.
9. **AC9 — Scanner error → retry, then discard to `scan_failed` after `max_attempts`.**
   `{:error, reason}` (any reason other than `:file_too_large`) transitions
   `:scanning → :quarantined` (a normal, valid 1b guard-table edge) and then:
   - if `job.attempt < job.max_attempts`: returns `{:error, reason}` so Oban retries with
     its default exponential backoff (no custom `backoff/1` override needed — the default
     curve already satisfies ADR-025's "backoff: exponential").
   - if `job.attempt >= job.max_attempts` (this is the last attempt): instead of returning
     `{:error, reason}` (which would leave the file sitting in `:quarantined` with the job
     silently discarded and no further notice), the worker performs
     `Nebu.Media.StateMachine.transition(media_id, :scan_failed, {:system, nil}, %{reason:
     inspect(reason)})`, broadcasts per AC8, and returns `{:discard, reason}` — Oban finalizes
     the job as `discarded` immediately rather than scheduling a retry that will never
     happen. A file never gets "stuck" silently in `:quarantined` after retries are
     genuinely exhausted.
10. **AC10 — Every state transition this worker performs writes exactly one
    `media_state_transitions` row (actor_type `:system`), for free, via `Nebu.Media.
    StateMachine.transition/4` (Story 1b) — this worker never issues a raw SQL `UPDATE`
    against `media_files.state`.**

## Acceptance Tests

Test file: `server/test/nebu/workers/media_scan_worker_test.exs`, `use Oban.Testing, repo:
Nebu.Repo` (`Oban.Testing.perform_job/3` to invoke `perform/1` directly, matching the
convention Story 2e's own test file already commits to for Oban workers). Storage/Crypto/
ClamAV/StateMachine are swapped for injectable fakes via the existing `:media_storage_module`
/`:media_db_module`-style app-env seams (`Nebu.Web.MediaFakes`), extended with a
`:media_clamav_module`/`:media_state_machine_module` seam if the worker needs to call them
indirectly for testability.

1. `test "clean scan transitions quarantined media to released and broadcasts on media:#{id}"`
   — seeds a `:quarantined` row, fake `ClamAV.scan_binary/1` returns `{:ok, :clean}`;
   `perform_job(MediaScanWorker, %{"media_id" => id})` returns `:ok`; asserts the fake
   StateMachine recorded `:quarantined → :scanning → :released`; asserts (via a subscribed
   test process) a `{:media_state_transition, ^id, :released}` broadcast was received on
   `"media:#{id}"`.
2. `test "infected scan transitions to infected, persists the ClamAV signature, and
   broadcasts"` — fake `scan_binary/1` returns `{:ok, {:infected, "Eicar-Test-Signature"}}`;
   asserts the transition to `:infected` carried `clamav_signature: "Eicar-Test-Signature"`
   in its metadata, asserts `media_files.scan_metadata` (via the fake DB) was updated with
   the same signature, and asserts a `{:media_state_transition, ^id, :infected}` broadcast
   fired.
3. `test "a transient scanner error retries, then a clean result on a later attempt
   releases the file"` — first `perform_job/3` call: fake `scan_binary/1` returns
   `{:error, :clamd_timeout}`; asserts the job returns `{:error, :clamd_timeout}` (Oban.Testing
   records this as a retryable failure, not a discard) and the fake StateMachine shows
   `:scanning → :quarantined`; second `perform_job/3` call (simulating Oban's retry) with the
   fake reconfigured to return `{:ok, :clean}` and `job.attempt` bumped to `2`: asserts the
   final state is `:released` and exactly one broadcast fired (from the second call only).
4. `test "exhausted retries (attempt == max_attempts) transitions to scan_failed, broadcasts,
   and the job is discarded rather than retried again"` — calls `perform_job/3` with
   `attempt: 5, max_attempts: 5` and a fake `scan_binary/1` that keeps returning
   `{:error, :clamd_down}`; asserts the return value is `{:discard, :clamd_down}`; asserts the
   fake StateMachine recorded a final `:quarantined → :scan_failed` transition (system actor,
   metadata containing the reason); asserts a `{:media_state_transition, ^id, :scan_failed}`
   broadcast fired; asserts no further Oban job for this `media_id` is enqueued (Oban's own
   `discard` semantics — `assert_enqueued`/queue-inspection shows no pending retry).
5. `test "all three terminal outcomes (released, infected, scan_failed) broadcast on
   media:#{id} — none of them is silently missing the broadcast"` — a table-driven test
   parametrized over the three scenarios above (clean / infected / exhausted-retry),
   asserting in every case that a subscriber on `"media:#{id}"` receives exactly one
   `{:media_state_transition, id, expected_state}` message and none receives zero messages —
   this is the explicit regression guard for AC8/the 2d coordination requirement, kept as its
   own test so a future change to any one branch's broadcast call is caught even if that
   branch's own dedicated test (1/2/4) is weakened.
6. `test "file_too_large is a skip, not a scan failure: transitions to released with
   scan_metadata skipped: size_limit, and broadcasts, with zero retries"` — fake
   `scan_binary/1` returns `{:error, :file_too_large}`; asserts the job returns `:ok` (not
   `{:error, _}` — Oban must not retry this), the transition metadata is `%{skipped:
   "size_limit"}`, and a `:released` broadcast fired.
7. `test "perform/1 with a media_id no longer in a scannable state (e.g. already
   admin_blocked) is a no-op, not a crash or a retry"` — fake StateMachine's
   `:quarantined → :scanning` call (the very first thing perform/1 does) returns
   `{:error, {:invalid_transition, :admin_blocked, :scanning}}`; asserts `perform/1` returns
   `:ok`, no scan is attempted (fake `ClamAV.scan_binary/1` is never called), and no
   broadcast fires.
8. `test "decrypt/decompress pipeline: worker calls Storage.get, then Crypto.decrypt, then
   conditionally :zlib.gunzip, before calling scan_binary/1"` — asserts call order via the
   injected fakes' call log; asserts `:zlib.gunzip/1` is only invoked when the seeded row has
   `compressed: true`, and the raw decrypted bytes are passed unchanged to `scan_binary/1`
   when `compressed: false`.

## Technical Requirements

### Oban dependency, schema, and supervisor wiring (new to this codebase)

- `server/mix.exs`: add `{:oban, "~> 2.18"}` to `deps/0`.
- `server/priv/migrations/000023_oban_jobs.up.sql` / `.down.sql` (number bumps if another
  story's migration lands first — verify the actual HEAD file under
  `server/priv/migrations/` before assigning a number; do not silently collide with an
  in-flight migration number from a parallel story). Contents: Oban's officially published
  Postgres schema for the pinned `oban` version (the `oban_jobs` table with its
  `oban_job_state` enum, indexes, and the `oban_jobs_notify` trigger/function Oban's
  `Oban.Plugins.Cron`/insert-notification path relies on), hand-translated into a raw
  `.up.sql`/`.down.sql` pair with the same `nebu_migrate`-owns-DDL / explicit `GRANT` to
  `nebu_app` pattern the existing `000012`–`000022` migrations use — **not** generated via
  `mix ecto.gen.migration` + `Oban.Migration.up/1`, since Nebu's migration runner is not
  Ecto-Migration-based (see `1a`'s note on this same distinction for `media_files`).
- `server/lib/nebu/application.ex`: add `{Oban, Application.fetch_env!(:nebu, Oban)}` to the
  supervision tree, positioned **after** `Nebu.Repo` starts (Oban needs a working DB
  connection pool to poll `oban_jobs`) and independent of the `Nebu.PubSub`/`Nebu.Admin.PubSub`
  ordering already documented there.
- `server/config/config.exs`: the `config :nebu, Oban, ...` block from AC2.

### Worker module

`server/lib/nebu/workers/media_scan_worker.ex`:

```elixir
defmodule Nebu.Workers.MediaScanWorker do
  use Oban.Worker, queue: :media_scan, max_attempts: 5

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"media_id" => media_id}, attempt: attempt, max_attempts: max_attempts}) do
    case state_machine().transition(media_id, :scanning, {:system, nil}) do
      {:error, {:invalid_transition, _from, :scanning}} ->
        :ok  # no longer scannable (admin_blocked/deleted between enqueue and pickup) — no-op

      {:ok, :scanning} ->
        scan_and_transition(media_id, attempt, max_attempts)
    end
  end

  defp scan_and_transition(media_id, attempt, max_attempts) do
    with {:ok, row} <- db().lookup_for_scan(media_id),
         {:ok, ciphertext} <- storage().get(row.storage_key),
         {:ok, plaintext} <- crypto().decrypt(ciphertext, row.aes_key, row.nonce),
         bytes <- maybe_gunzip(plaintext, row.compressed) do
      case clamav().scan_binary(bytes) do
        {:ok, :clean} ->
          release(media_id, %{})

        {:ok, {:infected, signature}} ->
          infect(media_id, signature)

        {:error, :file_too_large} ->
          release(media_id, %{skipped: "size_limit"})

        {:error, reason} ->
          scan_error(media_id, reason, attempt, max_attempts)
      end
    end
  end

  defp release(media_id, metadata) do
    {:ok, :released} = state_machine().transition(media_id, :released, {:system, nil}, metadata)
    broadcast(media_id, :released)
    :ok
  end

  defp infect(media_id, signature) do
    metadata = %{clamav_signature: signature, scanned_at: DateTime.utc_now()}
    {:ok, :infected} = state_machine().transition(media_id, :infected, {:system, nil}, metadata)
    db().update_scan_metadata(media_id, metadata)
    broadcast(media_id, :infected)
    :ok
  end

  defp scan_error(media_id, reason, attempt, max_attempts) do
    {:ok, :quarantined} = state_machine().transition(media_id, :quarantined, {:system, nil}, %{reason: inspect(reason)})

    if attempt >= max_attempts do
      {:ok, :scan_failed} =
        state_machine().transition(media_id, :scan_failed, {:system, nil}, %{reason: inspect(reason)})
      broadcast(media_id, :scan_failed)
      {:discard, reason}
    else
      {:error, reason}
    end
  end

  defp maybe_gunzip(bytes, true), do: :zlib.gunzip(bytes)
  defp maybe_gunzip(bytes, false), do: bytes

  defp broadcast(media_id, new_state) do
    Phoenix.PubSub.broadcast(Nebu.PubSub, "media:#{media_id}", {:media_state_transition, media_id, new_state})
  end

  defp state_machine, do: Application.get_env(:nebu, :media_state_machine_module, Nebu.Media.StateMachine)
  defp db, do: Application.get_env(:nebu, :media_db_module, Nebu.Media.DB)
  defp storage, do: Application.get_env(:nebu, :media_storage_module, Nebu.Media.Storage)
  defp crypto, do: Application.get_env(:nebu, :media_crypto_module, Nebu.Media.Crypto)
  defp clamav, do: Application.get_env(:nebu, :media_clamav_module, Nebu.Media.ClamAV)
end
```

(Illustrative — adapt to the exact `Nebu.Media.DB`/fake-seam naming already established by
2b/1c; the load-bearing points are the transition sequence, the `attempt >= max_attempts`
discard branch, and the broadcast call after every one of the four terminal outcomes.)

### PubSub broadcast contract — must match Story 2d exactly

Topic: `"media:#{media_id}"` on `Nebu.PubSub` (the app's main `Phoenix.PubSub` registry
started in `Nebu.Application` — **not** `Nebu.Admin.PubSub`). Payload:
`{:media_state_transition, media_id, new_state}` where `new_state` is one of the atoms
`:released | :infected | :scan_failed`. This is the exact shape Story 2d's story file already
documents as its "recommended payload shape" and writes its stall-mechanism subscriber
against — 2d explicitly flagged that its own tests (mid-wait `:infected`/`:admin_blocked`
broadcasts resolving promptly) are a regression this story must not reintroduce by only
broadcasting on the clean-scan path. Do not invent a different tuple shape or topic
convention; if a genuine reason arises to change it, update 2d's story file in the same
change, not silently.

### Job enqueue call site (Story 2b, already written — confirm, do not modify without cause)

2b's `store_and_quarantine/...` seam calls (per 2b's own Technical Requirements, "Enqueue the
Oban scan job (queue/worker name from Story 4b)"):

```elixir
%{media_id: media_id}
|> Nebu.Workers.MediaScanWorker.new()
|> Oban.insert()
```

This story defines that contract (queue `:media_scan`, worker module name, and the
`%{media_id: media_id}` args shape) for 2b to call into — if 2b already landed with a
placeholder/fake enqueue call, reconcile the args key/queue name against what is defined
here, not the other way around.

### Retry/backoff configuration (ADR-025)

`max_attempts: 5` on the worker; Oban's built-in default `backoff/1` (exponential, no custom
override needed) satisfies ADR-025's "backoff: exponential" requirement. `Oban.Plugins.
Lifeline` with `rescue_after: :timer.minutes(60)` rescues jobs orphaned by a node crash
mid-scan (comfortably above the epic's stated 30–60 minute max scan duration). Queue-level
`shutdown_grace_period: :timer.seconds(30)` lets an in-flight scan finish cleanly on a
graceful node shutdown instead of being killed mid-request to clamd.

## File List

| File | Change Type |
|---|---|
| `server/mix.exs` | UPDATE — add `{:oban, "~> 2.18"}` |
| `server/priv/migrations/000023_oban_jobs.up.sql` (number TBD, see Technical Requirements) | NEW |
| `server/priv/migrations/000023_oban_jobs.down.sql` | NEW |
| `server/lib/nebu/application.ex` | UPDATE — add the `Oban` supervisor child |
| `server/config/config.exs` | UPDATE — add `config :nebu, Oban, ...` (AC2) |
| `server/lib/nebu/workers/media_scan_worker.ex` | NEW |
| `server/lib/nebu/media/db.ex` | UPDATE — add `lookup_for_scan/1` (returns storage_key/aes key material/compressed) and `update_scan_metadata/2`, if not already covered by an existing lookup |
| `server/test/nebu/workers/media_scan_worker_test.exs` | NEW |
| `server/test/nebu/media/media_fakes.exs` | UPDATE (if needed) — extend fakes for the state-machine/clamav/db seams this worker uses |

## Dev Agent Guardrails

### Do Not Change

- **The broadcast-on-all-terminal-outcomes requirement (AC8) is a hard cross-story
  dependency for Story 2d — do not skip or narrow it even though the epic's own prose (the
  "Scope" bullets for Story 4b) only spells out a broadcast for the clean-scan path.** Story
  2d's stall mechanism has already been written against a broadcast on `:released`,
  `:infected`, and `scan_failed` alike, and its own story file explicitly calls out that a
  4b landing with only the happy-path broadcast would silently break its "prompt deny
  response" acceptance tests (3/4 in 2d's file). Treat AC8/Acceptance Test 5 as non-negotiable
  scope, not an enhancement to consider cutting under time pressure.
- **Do not call `Nebu.Compliance.AuditWriter` from this worker.** The epic's own prose for
  Story 4b mentions "+ Audit-Log-Eintrag" for the `:file_too_large` skip path, but the
  compliance-audit bridge for this worker's outcomes (`:infected`, `scan_failed`) is
  explicitly Story 4c's scope ("Bei `:infected` und bei `scan_failed`... schreibt der Worker
  **zusätzlich**... einen Eintrag in `Nebu.Compliance.AuditWriter`" — 4c's scope bullet, not
  4b's), including the `@known_actions` registration this project has previously broken by
  merging an audit action without updating the allowlist. This story's AC7/`scan_metadata:
  %{skipped: "size_limit"}` write to `media_state_transitions` already satisfies the
  observability need for the skip case; leave the decision of whether a dedicated
  `AuditWriter` action is also wanted for that case to whoever implements 4c, rather than
  adding a new `Nebu.Compliance` call here on this story's own initiative.
- **Do not implement `scan_failed`'s guard-table edges** — that is Story 4a's scope
  (`ALTER TYPE ... ADD VALUE 'scan_failed'` + the `Nebu.Media.StateMachine` guard-table
  entries for `quarantined/scanning → scan_failed`). This story is a *caller* of those edges,
  not their author; if 4a has not landed by the time this story is implemented, add the
  missing guard-table entries as a small, clearly-flagged addition rather than duplicating
  4a's migration.
- **Do not touch the download-gate handler** (`Nebu.Media.download/3,4`, Story 1c/2d's
  scope) — this worker only produces the state transitions and broadcasts that handler
  consumes.
- **Do not touch `Nebu.Media.upload_async/3` or its persist-transition-enqueue seam**
  (Story 2b's scope) beyond reconciling the exact enqueue args/queue name this story defines
  (see Technical Requirements — "Job enqueue call site").
- **Do not add a bespoke retry/backoff mechanism.** ADR-025's entire rationale for choosing
  Oban over a bespoke GenServer-based queue is that retry/backoff/dead-letter semantics come
  for free — reinventing any part of that here defeats the point of this story introducing
  Oban in the first place.
- **`server/lib/nebu/media/state_machine.ex`, `crypto.ex`, `storage.ex`** — call their public
  APIs; do not reimplement encryption, storage I/O, or transition-guard logic inline in the
  worker.

## Dependencies

- **Depends on:**
  - **3 — `Nebu.Media.ClamAV` GenServer** — provides `scan_binary/1`, the scan primitive this
    worker calls.
  - **1a / 1b — `media_files` schema + `Nebu.Media.StateMachine`** — the columns
    (`storage_key`, `scan_metadata`, `compressed`) and the guarded `transition/4` this worker
    uses as its sole state-mutation path.
  - **4a — `scan_failed` ENUM value + guard-table edges** — the terminal dead-letter state
    this worker transitions to on exhausted retries.
  - **2b — `PUT` upload handler** — produces the `:quarantined` rows and enqueues the Oban
    job this worker consumes; also the call site this story's exact enqueue contract
    (queue name, worker module, args shape) must reconcile with.
  - **12 — Gzip compression at rest** — the decompression step (AC4) is the inverse of 12's
    compression step; this story calls `:zlib.gunzip/1` as a caller, it does not implement
    compression.
- **Enables:**
  - **2d — Download-stall mechanism** — the PubSub broadcast this story lands on all three
    terminal states (AC8) is exactly what turns 2d's stall mechanism from "only wakes on the
    happy path" into "wakes promptly on every outcome," per 2d's own coordination note.
  - **4c — Compliance-audit bridge** — extends this worker's `:infected`/`scan_failed`
    branches with an additional `Nebu.Compliance.AuditWriter` call; this story's transition
    call sites are the exact insertion points 4c hooks into.
  - **Story 10 (Scan Health & Alerts Dashboard)** — all of its sub-stories (health metrics,
    alerting, the `media_scan_stats` rollup) observe the state transitions and Oban queue this
    story creates; none of Story 10 can be meaningfully built before this story lands.
  - **2e, 8a/8c, 10a, 13c** — every later Oban-based worker/cron in this epic builds on the
    Oban dependency, migration, and supervisor wiring this story introduces (AC1/AC2), rather
    than re-adding it.
