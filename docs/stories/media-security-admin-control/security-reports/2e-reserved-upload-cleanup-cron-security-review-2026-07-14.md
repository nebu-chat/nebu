# Security Review — `2e-reserved-upload-cleanup-cron`

- **Epic:** media-security-admin-control
- **Reviewer:** Kassandra (adversarial security review)
- **Date:** 2026-07-14
- **Story security_review flag:** required (new background-worker + new dependency/attack-surface: Oban)
- **Scope:** staged diff — `server/lib/nebu/workers/media_reserved_upload_cleanup_worker.ex` (NEW), `server/lib/nebu/media/state_machine.ex`, `server/lib/nebu/application.ex`, `server/config/config.exs`, `server/mix.exs`, `server/mix.lock`, `server/priv/migrations/000026_oban_jobs.up/down.sql` (NEW), `server/priv/migrations/000027_media_files_uploader_user_id_nullable.up/down.sql` (NEW), `server/test/nebu/workers/media_reserved_upload_cleanup_worker_test.exs` (NEW), `server/test/nebu/media/state_machine_test.exs`, `server/test/nebu/matrix/migrations_grant_test.exs`, `server/test/nebu/release_test.exs`

## VERDICT

**0 CRITICAL — 0 HIGH.** Nothing in this diff blocks the pipeline.

Findings: **2 LOW, several INFO/positive.** The prior cycle's CRITICAL
(NOT-NULL violation on `uploader_user_id`) and MAJOR (`LIMIT 1000` starvation)
fixes were independently re-verified against the current code and are both
correct. The two new LOW findings are downstream consequences of the CRITICAL
fix itself — nulling `uploader_user_id` on hard-delete: **F-1** is a
behavior/semantics regression in the async-PUT ownership check (a cleaned-up
reservation now returns `403` to *everyone including the original owner*,
opening a weak, ID-entropy-gated existence oracle); **F-2** is a forward-looking
watch-flag — the *same* nulling `UPDATE` is shared with the currently-callerless
`deleted -> hard_deleted` edge, where it will one day destroy the last record of
who uploaded *real content* with no copy in the audit ledger. Neither blocks 2e.
The Oban bootstrap — the headline new attack surface — is clean: no
HTTP-reachable enqueue path exists, and the worker ignores job args entirely, so
attacker-influenced `args`/`worker`/`media_id`/actor cannot reach the transition.

---

## What the story does (verified against code, not the summary)

`Nebu.Workers.MediaReservedUploadCleanupWorker.perform/1`
(media_reserved_upload_cleanup_worker.ex:73) runs on an
`Oban.Plugins.Cron` `"*/15 * * * *"` schedule. It computes
`expiry_threshold_ms = now_ms - unused_expires_ms()` (reading the shared
`:nebu_http, :media_unused_expires_ms` key, default 86_400_000; **no new config
value** — AC1 ✓), runs a single parameterized SQL scan
`SELECT media_id FROM media_files WHERE state = 'reserved' AND uploaded_at < $1
LIMIT 1000` (the expiry predicate is **in the WHERE clause, bounded before the
cap** — the MAJOR fix, verified), then `Enum.reduce_while`s each row through
`StateMachine.transition(media_id, :hard_deleted, {:system, nil})`
(state transition **only** via the StateMachine — AC3 ✓; `{:invalid_transition,_,_}`
is a `:cont` no-op, any other `{:error, reason}` **halts and propagates** so Oban
retries — AC5 ✓). The guard table gains exactly one edge:
`reserved: [:quarantined, :hard_deleted]` (AC4 ✓). `write_transition/6`
(state_machine.ex:181) now branches: for `to_state == :hard_deleted` it uses
`@sql_update_state_hard_deleted` which additionally `SET uploader_user_id = NULL,
hard_deleted_at = now()`; migration 000027 drops the `NOT NULL` on
`uploader_user_id` so that write is legal (the CRITICAL fix, verified). The row
is **never physically deleted** and `media_state_transitions` is only ever
INSERTed into — ADR-031 immutability intact. Oban is bootstrapped: `{:oban,
"~> 2.18"}` (2.23.0), raw-SQL migration 000026 (`oban_jobs`/`oban_peers` +
minimal GRANTs), supervisor child gated behind `Nebu.Repo` config
(application.ex), and base `config.exs` Oban config.

---

## Findings

### F-1 (LOW) — nulling `uploader_user_id` on hard-delete turns the async-PUT ownership guard into a `403` for the true owner and a weak "reservation-existed-here" existence oracle

**Location:** `server/lib/nebu/media/state_machine.ex:80-84`
(`@sql_update_state_hard_deleted` — `SET uploader_user_id = NULL`),
consumed at `server/lib/nebu/media.ex:349`
(`row.uploader_user_id != user -> 403`), reachable via
`Nebu.Media.DB.lookup_reservation/2` (db.ex:119-128, which returns a row for
**any** `state`, with no state/deleted filter).

**Mechanism.** `upload_async/3` (the `PUT /_matrix/media/v3/upload/...` handler)
evaluates its `cond` in this order (media.ex:348-360): ownership (`403`) →
expiry (`404`) → wrong-state (`409`). Once this cron hard-deletes an expired
reservation, that row has `uploader_user_id = NULL` and `state = :hard_deleted`,
but **still exists** (DB-Record-Invariante). A subsequent PUT to that `media_id`
therefore hits `row.uploader_user_id != user` first → `nil != user` → **`true`
for every caller, including the reservation's original owner** → `403
M_FORBIDDEN "You did not create this media reservation"`.

Two observable consequences:

- **Owner-facing semantic regression.** Before 2e no reservation was ever
  hard-deleted, so an expired reservation stayed `:reserved` and its owner got
  `404` via the expiry branch. After 2e the owner of a *cleaned-up* reservation
  gets a misleading `403` claiming they didn't create it — which they did. Wrong
  error class, and it contradicts the handler's own AC7 ordering intent (expiry
  is meant to yield `404`).
- **Weak existence oracle.** `403` (a hard-deleted/existing row whose owner is
  now NULL) is now distinguishable from `404 M_NOT_FOUND` (the
  `{:error, :not_found}` branch — a `media_id` that never existed). Because the
  row persists forever, this signal is permanent: `403` uniquely fingerprints
  "a reservation once existed at this `media_id` and was reclaimed."

**Why only LOW.** `media_id` is 128 bits of unguessable entropy and is only ever
disclosed to the reserving user in the `POST /create` response — an attacker
cannot enumerate the space, and for their *own* `media_id` the `403` reveals
nothing they didn't already know. Access is correctly *denied* in every case
(no bytes served, no cross-user data exposure). This is primarily a
correctness/UX regression with a thin, entropy-gated confidentiality dimension —
not an exploitable disclosure.

**Remediation.** Make the PUT handler treat a terminal/reclaimed reservation as
gone rather than mis-attributing ownership. Cleanest: in `upload_async/3`, order
a `row.state in [:hard_deleted, :deleted] -> 404 M_NOT_FOUND` branch **before**
the ownership check (a reclaimed reservation is semantically "not found",
matching the expiry branch and closing the oracle). Alternatively, guard the
ownership comparison against a NULL uploader
(`row.uploader_user_id && row.uploader_user_id != user`) and fall through to the
`404` expiry/`409` state branches. Add a regression test: PUT against a
hard-deleted reservation (as the original owner) asserts `404`, not `403`.

---

### F-2 (LOW / forward-looking watch-flag) — the shared hard-delete `UPDATE` nulls the uploader identity with no copy in the audit ledger; safe for `reserved` today, an accountability gap the day `deleted -> hard_deleted` is wired for real content

**Location:** `server/lib/nebu/media/state_machine.ex:80-84`
(`@sql_update_state_hard_deleted`) + `:182` (`if to_state == :hard_deleted`),
and the guard table's `deleted: [:hard_deleted]` edge (state_machine.ex:64,
currently **no caller**).

**Mechanism.** `write_transition/6` selects `@sql_update_state_hard_deleted` for
*any* transition whose `to_state == :hard_deleted` — it is not scoped to the
`reserved -> hard_deleted` edge this story introduces. The guard table already
contains a second edge into that terminal state, `deleted -> hard_deleted`,
which has no caller yet but is the obvious home for a future GDPR-erasure /
infected-or-admin-blocked purge story. When that path is wired, the *same*
`SET uploader_user_id = NULL` will fire — but this time against a row that held
**real uploaded content** (bytes, `storage_key`, a genuine uploader). Critically,
`media_state_transitions` **never records `uploader_user_id`** (the genesis and
transition INSERTs store `actor_*`, not the uploader), so once `media_files`
is nulled, *the system retains no record of who uploaded the erased content* —
a potential accountability gap for a compliance/moderation investigation into
why that content existed.

For **this** story the finding is inert: a `:reserved` row is byte-less,
never-uploaded, and its uploader was never in the audit ledger to begin with, so
clearing it is aligned with the GDPR Art. 17 framing and loses nothing that was
ever recorded. Hence LOW, not a blocker.

**Remediation.** Do not let the `deleted -> hard_deleted` content-erasure path
inherit this nulling silently. When that story lands, decide explicitly whether
the uploader identity must survive erasure for accountability, and if so capture
`uploader_user_id` into the `media_state_transitions.metadata` JSONB **before**
the column is nulled (the transition INSERT already accepts `metadata`). At
minimum, add a comment on `@sql_update_state_hard_deleted` flagging that it is
edge-agnostic so the next author re-evaluates the audit implication for content
rows. Recorded as a MEMORY pattern.

---

## INFO / Positives (verified, no action required)

- **Oban is not a new *reachable* attack surface (concern #2 — verified).** The
  ONLY producer of `oban_jobs` rows is `Oban.Plugins.Cron`, which inserts a fixed
  `worker` (`Nebu.Workers.MediaReservedUploadCleanupWorker`) with empty
  `args {}`. Grep confirms **no `Oban.insert` call exists anywhere in `lib/`** —
  the sole reference is a *docstring* in `media/scan_enqueue.ex`, which is a
  committed **no-op stub** (`Logger.debug(... "no-op, Oban not yet wired — Story
  4b")`) that does not touch Oban at all. No authenticated or unauthenticated
  HTTP handler can enqueue anything. There is no attacker-influenced
  `args`/`worker` path into `oban_jobs`.
- **Even a hypothetical forged job cannot influence the transition (concern
  #3 — verified).** `perform/1` pattern-matches `%Oban.Job{}` and reads **no
  fields from it** — `media_id` comes solely from the server-side SQL SELECT and
  the actor is the hard-coded literal `{:system, nil}`. A crafted job (were one
  ever injectable) still could not steer `media_id`, the target state, or the
  actor tuple.
- **Actor shape is the sanctioned system shape.** `{:system, nil}` passes
  `transition/4`'s guards; `{:system, non_nil}` and `{:admin, nil}` are both
  rejected with `:invalid_actor` before any DB call (state_machine.ex:146-152).
  `dump_actor_id(nil) -> nil -> SQL NULL` — no spurious admin identity attaches
  to a system-driven purge (AC5-adjacent, correct).
- **`DROP NOT NULL` opens no NULL-deref anywhere (concern #4 — all six readers
  audited).** Every reader of `uploader_user_id` was checked: `media.ex:216,293`
  are *writes* (fresh non-null rows); `media.ex:349` is the `!=` comparison
  handled in F-1 (valid on `nil`, no crash); `db.ex:80/92`
  `count_pending_reservations` filters `state = 'reserved'` so a NULLed
  hard-deleted row is excluded regardless (this is precisely the intended quota
  reclaim); `db.ex:122-123` and `db.ex:234` read the value into a map where `nil`
  is inert. Elixir does not fault on `nil` in any of these contexts. No
  `CaseClauseError`/500 introduced.
- **GRANTs are minimal and non-escalating (concern #4).** 000026 grants exactly
  `SELECT, INSERT, UPDATE, DELETE` on `oban_jobs` + `oban_peers` and
  `USAGE, SELECT` on `oban_jobs_id_seq` to `nebu_app` — the least Oban needs to
  function. No `GRANT ALL`, no role/ownership change, no `BYPASSRLS`, no touching
  of any existing table's grants. 000027 is an `ALTER TABLE … ALTER COLUMN` only
  (no `CREATE TABLE`), so it correctly adds no GRANT (media_files is already
  covered by 000001's blanket grant). The down-migration contains no GRANT
  (asserted by `migrations_grant_test.exs`).
- **Idempotency / concurrency / split-brain safety (concern #3 — verified).**
  `transition/4` re-selects the row `FOR UPDATE` and re-checks the guard table
  inside the transaction, so a race loser deterministically gets
  `{:invalid_transition, :hard_deleted, :hard_deleted}` → treated as a `:cont`
  no-op. Even if `Oban.Plugins.Cron` leader election (via `oban_peers`,
  `Oban.Peers.Database`) were to split-brain and two nodes each fired the cron,
  the SAME row cannot be double-hard-deleted destructively — the second
  transition is a rejected no-op, and each transition is its own committed
  `Repo.transaction`, so a mid-job halt+retry re-scans and skips already-purged
  rows. No double-processing that matters.
- **No unbounded scan / no DoS amplification (concern re: resource exhaustion).**
  `LIMIT 1000` caps each tick's candidate set at the SQL layer; the
  `media_cleanup` queue is `limit: 10`; the cron inserts one job per 15 min.
  Reserved-row accumulation is itself bounded by Story 2a's
  `max_pending_per_user` cap, so a single client cannot cheaply manufacture an
  expensive backlog. The worker is explicitly best-effort — the PUT handler's own
  live expiry check (media.ex:352,367-369) remains the authoritative
  enforcement, so a slow drain never serves an expired reservation.
- **Type-correct expiry bind.** `media_files.uploaded_at` is `BIGINT`
  (milliseconds, 000001_init.up.sql:298); the worker binds the integer
  `expiry_threshold_ms` against `uploaded_at < $1` — no timestamp/epoch
  mismatch, no injection (parameterized).
- **ADR-031 respected.** The worker only INSERTs `media_state_transitions` rows
  (via StateMachine) and UPDATEs `media_files.state` — never a raw
  UPDATE/DELETE (asserted by the worker's own "never issues a raw UPDATE/DELETE"
  test) and never a DELETE/UPDATE against the append-only transitions ledger
  (which keeps its `no_update`/`no_delete` RLS policies from 000022).
- **Oban infra tables intentionally have no RLS — correct, not a gap.** Unlike
  `media_state_transitions`/`audit_log` (append-only compliance ledgers that
  carry RLS), `oban_jobs`/`oban_peers` are transient operational tables that Oban
  itself must `UPDATE`/`DELETE` continuously (job state churn, leadership lease
  renewal); they hold no user/compliance data and an append-only policy would
  break the queue. Absence of RLS here is consistent with the codebase's
  non-compliance tables and is the correct posture. (Noted only to pre-empt the
  MEMORY "Missing RLS on new tables" pattern — it does not apply to job-queue
  infra.)
- **The prior CRITICAL fix is genuinely correct.** Migration 000027 drops the
  `NOT NULL`, and `state_machine_test.exs` now has a **real-DB round-trip** test
  (`reserved -> hard_deleted` seeds a genuine row, transitions it for real,
  asserts `uploader_user_id` NULLed + `hard_deleted_at` stamped + row still
  present) — closing exactly the blind spot the worker's `FakeStateMachine`
  unit tests structurally could not cover.
- **Test coverage is strong.** Worker tests cover: transition-on-expiry,
  non-expired untouched, idempotent repeated runs, idempotent race (loser
  no-op), never-raw-UPDATE/DELETE, TTL-not-cadence (AC6), and
  non-`invalid_transition` failure propagates (AC5). `release_test.exs` and
  `migrations_grant_test.exs` are updated for 000026/000027.

---

## Cross-references (my MEMORY.md)

- **Vestigial legacy boolean shadowing a new enum** (1c, 2026-07-13) → verified
  benign here: the hard-delete UPDATE does not touch the legacy `deleted`
  boolean, so a hard-deleted row has `state='hard_deleted'` with a stale
  `deleted=false`. Harmless — the download gate is a `:released`-only allowlist,
  and `deleted` has no runtime reader. No revival of `UPDATE … SET deleted=true`
  in this diff.
- **Fail-closed teardown scoped to the logical entity, not the acting row, under
  concurrency** (server-paced-session-refresh #79) → does NOT recur: the worker's
  destructive step is `StateMachine.transition`, whose `SELECT … FOR UPDATE` +
  guard-table re-check makes the write atomic on the exact row; the race loser is
  a rejected no-op, not a cross-actor clobber.
- **New finding F-2** is a new pattern candidate: *an edge-agnostic terminal-state
  `UPDATE` that clears accountability columns is safe for a byte-less/never-owned
  edge but becomes an audit gap when a sibling edge (real content erasure) is
  later wired through the same code — capture identity into the immutable ledger
  before nulling.* To be curated at session close.
