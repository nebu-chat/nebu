# Code Review — cycle 2 (dev-story resolution notes)

> Added by dev-story during cycle 2 implementation (not a standalone review pass) — documents how
> this cycle's two required changes resolve the cycle-1 re-review's findings below (MAJOR-2 + the
> 3 technical MINORs).

**Status:** MAJOR-2 and MINOR 1-2 below are resolved by this cycle's implementation. MINOR 3
(CI-gate evidence) is explicitly deferred to the orchestrator per the bug-context's cycle-2
addendum (see that file's "Code-review cycle 2 addendum" section).

## MAJOR-2 — resolved: migration widened to backfill trivial `'{}'` rooms too

**Resolution:** removed the `power_levels_json::jsonb <> '{}'::jsonb` exclusion from
`000035_backfill_power_levels_events.up.sql`'s `WHERE` clause; kept the `NOT EXISTS` idempotency
guard unchanged (still correctly scopes to rooms with no existing `m.room.power_levels` event,
still covers the `create_personal_room/2`-already-has-one case). Every pre-existing room lacking
a `m.room.power_levels` event now gets one backfilled, including rooms whose `power_levels_json`
is the literal empty `{}` — that is the room's real current state, not a guessed default. Updated
`server/test/nebu/matrix/backfill_power_levels_events_migration_test.exs`'s third test case
(previously "does not backfill a room with no meaningful power levels") to assert these rooms ARE
backfilled now, with `content == %{}`. The `.down.sql` needed no change — it deletes rows by the
migration's own signature marker, independent of the `up.sql` `WHERE` clause.

## MINOR 1 — resolved: `Logger.warning` downgraded to `Logger.debug`

Downgraded in `http.ex`'s sentinel branch — per this project's logger level convention
(`server/config/prod.exs` sets `level: :info`), debug logs are compiled in but not emitted in
production, making this effectively unbounded-safe there while remaining visible in dev
(`level: :debug`). No existing "log once" dedup precedent was found elsewhere in the codebase to
justify a more complex mechanism for a single log call. The MAJOR-2 widening above also makes
this branch far less reachable in practice going forward (it can still fire for
`m.room.create`'s own pre-existing `{"", 0}` fallback on very-old rooms, cycle-0 MINOR-1).

## MINOR 2 — moot: AND-short-circuit ordering

Moot once the `<> '{}'` cast-comparison clause was removed per MAJOR-2 above; the remaining
`IS NOT NULL`/`<> ''` checks are plain TEXT comparisons with no casting, so no operand-order risk
remains.

## MINOR 3 — deferred to orchestrator (no action this cycle)

No persisted CI-gate evidence for cycle 1 — the claimed unit/integration pass counts were
prose-only in `pipeline-state.yaml`, and the migration test is tagged `:integration` (excluded
from `make test-unit-elixir`'s default run). Per the cycle-2 addendum, the orchestrator (not
dev-story) runs the full CI-gate (`make redeploy` + `make test-integration` + unit suite) with
persisted logs after this cycle's implementation; dev-story's own local run (full unit suite +
the migration test + the 4 ATDD integration test files) is reported separately in this cycle's
completion notes.

---

# Code Review — bugfix/sync-state-events-missing-fields (cycle 1 re-review)

**Scope:** 24 staged files (2,502 insertions), re-verifying all 6 cycle-0 findings against
source + checking for new issues.

**Verdict: 1 MAJOR (new, MAJOR-2), 4 MINOR (3 new + 1 process), rest INFO. All 6 cycle-0
findings (1 MAJOR + 5 MINOR) confirmed genuinely resolved** — independently verified against
actual source (migration SQL, test assertions, hot-path call graph), not the dev-story
self-report.

## Part 1 — cycle-0 findings, verification

- **MAJOR-1 (backfill migration):** sound. Migration `000035_backfill_power_levels_events.up.sql`
  verified: one event per qualifying room, sender = room creator (same semantics as
  `get_room_creator/1`), `origin_server_ts` = room's `created_at` (type-checked: both `BIGINT`,
  no cast mismatch), `event_id` = valid `$`+43-url-safe-chars matching `EventId.generate/1`'s
  shape, `content` = room's current `power_levels_json` verbatim, idempotent (`NOT EXISTS` guard
  on `state_key=''`, matching what `emit_power_levels_event/3`/`create_personal_power_room/2`
  write), does NOT need a GRANT (verified: `events` table covered by `000001_init.up.sql`'s
  schema-wide GRANT to `nebu_app`, migration creates no new table). No RLS on `events` (can't
  fail-closed). Search-vector trigger auto-populates on backfilled rows. `.down.sql` correctly
  scoped via a migration marker in `signatures`, doesn't match NULL-signature rows. Migration
  test (`backfill_power_levels_events_migration_test.exs`) has real, non-superficial assertions
  (exact equality on origin_server_ts/sender/content, idempotency pinning, end-to-end through
  `RoomSupervisor.start_room/1` → `GetInitialSync`).
- **MINOR-1 (http.ex sentinels):** fixed — `unsigned` omitted when `event_id == ""`, warning
  logged.
- **MINOR-2 (sender on power_levels/name):** fixed, hot-path constraint holds — zero added
  `/sync` DB round-trips confirmed independently (new identity queries live only in
  `load_members/1` → `do_init/1`, room-start-only, never in `build_state_events/2`).
- **MINOR-3 (member content):** fixed — synthesized content now byte-for-byte matches what's
  actually persisted.
- **MINOR-4 (stale comment):** fixed.
- **MINOR-5 (moduledoc fail-open docs):** fixed.
- **`release_test.exs` version-list fix:** legitimate, minimal, not scope creep (only hardcoded
  migration-version list in the repo).

## Part 2 — new findings

### MAJOR-2 — backfill migration skips rooms with `power_levels_json = '{}'`

`WHERE r.power_levels_json::jsonb <> '{}'::jsonb` excludes rooms whose power levels were never
actually configured — those still surface `event_id: ""`/`origin_server_ts: 0` for
`m.room.power_levels` post-fix. **Lower severity than cycle-0 MAJOR-1**: a valid empty string
doesn't crash the Matrix Dart SDK's type-parser the way a missing/null field did, so the
"Kritisch/Blocker" crash does not recur here — but AC1's "real values, not synthesized" is still
unmet. Reachable in practice: `do_init/1`'s `{:error, :not_found}` branch creates a `rooms` row
with the column default `{}`; a user can join such a room without anyone calling
`set_power_levels`. Also any room predating migration 13 (introduced `power_levels_json`).
**User decision: widen the migration** to backfill these rooms too (not suppress-entry, not
accept-and-document) — see bug-context.md's "Code-review cycle 2 addendum" for full resolution
spec.

### MINOR (new)

1. **Unbounded `Logger.warning` on the `/sync` hot path** in `http.ex`'s sentinel branch — fires
   once per affected state event per room per sync response, forever, for any room still
   lacking identity. Needs downgrade to `Logger.debug` or de-dup.
2. **Sentinel branch has zero test coverage** — every ATDD test creates a fresh room with real
   identity, so `se.event_id == ""` is never exercised by tests. Doubly relevant once MAJOR-2
   makes that branch permanently reachable in production for `{}` rooms (now resolved by
   widening the migration instead, per user decision — but the general sentinel-fallback path,
   e.g. `m.room.create` for very-old rooms, remains untested).
3. **Migration's `WHERE` clause relied on AND short-circuit order** Postgres doesn't guarantee
   (`power_levels_json <> ''` before the jsonb cast) — moot once the `<> '{}'` exclusion is
   removed per MAJOR-2's resolution; if any JSON-validity guard remains, use `CASE`/
   `jsonb_typeof` instead of relying on operand order.
4. **(Process) No persisted cycle-1 CI evidence** — claimed unit (2007/2007) and integration
   (2642/34) pass counts exist only as prose in `pipeline-state.yaml`. The new migration test is
   tagged `:integration`, excluded from `make test-unit-elixir`'s default run
   (`test_helper.exs:14` excludes `:integration`) — so the "2007/2007 unit" claim provably did
   not execute it. Orchestrator will independently run Step 5 (ci-gate) with persisted logs
   rather than rely on self-report.

### INFO (no action required)

- `emit_power_levels_event/3` broadcasts to `:pg`, so power-levels changes now appear as
  `m.room.power_levels` timeline events too — intended (cycle-0 sanctioned), user-visible change
  worth a release note.
- Running Room GenServers don't see the backfill until restart (fine for standard release flow —
  migrate-then-boot — relevant only to rolling deploys).
- `NOT EXISTS` guard requires `state_key = ''`; a hypothetical Go-gateway-era row with
  `state_key IS NULL` wouldn't match and could get a second, older-ts backfilled row. All current
  writers use `""`; only legacy data could trip this.
- Backfilled event `sender = ''` for rooms with no `m.room.create` row (COALESCE fallback) — same
  inconsistency class as cycle-0 MINOR-1's `m.room.create` fallback, pre-existing, narrow legacy
  edge case.
- `:set_power_levels` handler's `%{state | power_levels_event: ...}` would `KeyError` on a
  hand-built state map lacking the key — only reachable via hand-rolled test fakes, not any
  production constructor (`build_init_state/5` always sets it).
- `@sql_member_identities` is O(all-members-ever) not O(current-members) — init-only,
  index-backed, not a hot-path concern.
- `migrations_grant_test.exs`'s `@down_migrations` list stops at `000033` — pre-existing drift,
  not introduced here.
- All 9 call sites of the 4 widened DB functions audited, none break; `DBBehaviour` widened as a
  union so legacy test fakes still satisfy callbacks.
- `create_room_initial_state_test.exs` change: strictly stronger assertion, legitimate
  correction, not a cover-up.

---

# Code Review — bugfix/sync-state-events-missing-fields (staged diff, cycle 0)

**Scope reviewed:** 8 production/proto files + 4 test files (1,901 insertions).
**Verdict: 1 MAJOR, 5 MINOR, rest INFO.** Core fix is correct and well-targeted; both
highest-risk dev-story claims (zero added DB round-trips in the `/sync` hot path; the
`create_room_initial_state_test.exs` change is a legitimate correction, not a cover-up) verified
independently and hold up.

## MAJOR

### MAJOR-1 — Pre-existing rooms still emit `m.room.power_levels` with `event_id: ""` / `origin_server_ts: 0`; no backfill, no test covers it

Every room created BEFORE this fix has no `m.room.power_levels` row in `events` (the old code
never persisted one). `do_init/1` → 0 rows → `power_levels_event: nil` → `build_state_events/2`
falls back to `{"", 0}` → `http.ex` ships `event_id: ""`, `origin_server_ts: 0`,
`unsigned.age ≈ 1.76e12` (≈56 years) verbatim to the client. Nothing backfills: no migration
staged, and `do_init/1` doesn't lazily emit a PL event when `power_levels` is non-empty but no
backing event exists. Every ATDD test creates a fresh room, so the suite is structurally blind
to this — CI green is not evidence here. This is exactly what AC1 forbids (synthetic/fake
values); `origin_server_ts: 0` (1970) is arguably worse than "now" would have been. For the
original bug reporter's existing account/rooms, the critical symptom is **not fixed** for this
event type.

Not affected (narrow, precisely scoped gap): `m.room.create`/`m.room.name`/generic state
(DB-backed, fine for legacy rooms); `m.room.member` (always persisted); `create_personal_room/2`
(persists a real `pl_event` directly, picked up by `do_init/1`).

**Needs a user decision** — three materially different options:
(a) backfill migration inserting an authoritative `m.room.power_levels` event per legacy room
    (sender = creator, ts = `rooms.created_at`) — carries the project's known "migration without
    GRANT to nebu_app fail-opens in prod while CI stays green" risk;
(b) lazy emit in `do_init/1` when `power_levels != %{}` and no PL event exists — self-healing,
    no migration risk; since a full deploy restarts every Room GenServer via `do_init/1`,
    deploying this fix alone would immediately backfill every room, no separate migration step
    needed; open question: what sender/ts to use for the synthesized backfill event;
(c) accept and document — AC1 knowingly unmet for pre-existing rooms' power_levels until they
    next undergo a `set_power_levels` call.

## MINOR (hand back to dev)

1. **`""` / `0` sentinels shipped raw to the wire.** `http.ex:153-159` emits `event_id`/
   `origin_server_ts` unguarded whenever identity is unavailable (MAJOR-1's case, plus the
   pre-existing `m.room.create` fallback for very old rooms, plus a failed
   `emit_membership_event/3` write). At minimum: omit `unsigned` when identity is unavailable
   (it's optional per Oracle) instead of a nonsense ~56-year age, and log a warning so this is
   observable rather than silent.

2. **`sender: ""` left on `m.room.power_levels`/`m.room.name` state events**, now inconsistent
   with the real `event_id` that now points at a persisted event with a real sender — `/sync`
   and `GET /rooms/{roomId}/event/{eventId}` now disagree about the same event. Cheap fix: add
   `sender` to `get_room_name/1`'s SELECT (same query, zero extra round-trips), carry `caller_id`
   alongside the power_levels identity tuple.

3. **`m.room.member` state-event content still synthesized** (`{"membership":"join",
   "displayname":""}`) while now carrying the real `event_id` of a persisted event whose actual
   content is `{"membership":"join"}` — same class of now-observable inconsistency as MINOR-2.

4. **Stale comment in `protected.ex:801`** ("synth event_id/ts since the state struct omits
   them") is now factually wrong — the struct no longer omits them. Correct it to say real values
   are now available and deliberately not used pending the agreed follow-up (not that they don't
   exist).

5. **`member_identity`/`power_levels_event` fail-open behavior undocumented** in
   `room/server.ex:30-48`'s moduledoc — both can legitimately be absent/stale when the backing
   event write failed; the contract should say so explicitly since `build_state_events/2` relies
   on it.

## INFO (no action required)

- Hot-path performance claim VERIFIED: zero added DB round-trips (all 3 widened DB queries extend
  existing SELECT lists only; member/PL identity comes from GenServer state).
- `load_members/1`'s 2 new queries are init-only, fully covered by the existing
  `events_room_state_idx` index.
- AC4 start-of-timeline semantics NOT inverted — `dedup_member_state_events/2` and
  `fetch_delta_rooms/3`'s exclusion logic byte-identical to pre-diff.
- `create_room_initial_state_test.exs` change is a legitimate correction (strictly stronger
  assertions), not a cover-up.
- AC2 correctly implemented as a hand-maintained struct, ADR-021 respected.
- All callers of the 4 widened functions audited, none break; `DBBehaviour` widened as a union.
- New (test-sanctioned, not accidental) behavior: `m.room.power_levels` is now a real timeline
  event, so a fresh room's initial sync returns it in both `state.events` and `timeline.events`
  (extends the pre-existing create/name duplication to one more type).
- Theoretical `EventId.generate/1` collision on identical power-levels-within-same-millisecond:
  non-fatal, fail-open, not realistically reachable.
- Out-of-scope items confirmed untouched as agreed: `initial_sync_state_event/3` still
  synthesizes; `rooms.invite`/`rooms.leave` still `{}`.

**Verdict:** all 6 cycle-0/cycle-1 findings (the 5 MINORs + MAJOR-1's backfill migration)
confirmed genuinely resolved. One new MAJOR found (MAJOR-2, lower severity than MAJOR-1), plus 3
technical MINORs.

## MAJOR-2 — backfill migration's `WHERE` clause excludes rooms with trivial `'{}'` power levels

The migration's `WHERE r.power_levels_json::jsonb <> '{}'::jsonb` guard skipped rooms whose power
levels were never actually configured (still the column default `'{}'`) — those rooms still
surfaced `event_id: ""` / `origin_server_ts: 0` for `m.room.power_levels` in `/sync`. Lower
severity than MAJOR-1 (a valid empty-object string doesn't crash the Matrix Dart SDK's
type-parser the way a missing/null field did), but still violates AC1's "real values, not
synthesized" requirement.

**User decision (2026-10-03): widen the migration to also backfill these rooms** — not
suppress-the-entry, not accept-and-document.

**Resolution (this cycle, dev-story):** removed the `power_levels_json::jsonb <> '{}'::jsonb`
exclusion from `000035_backfill_power_levels_events.up.sql`'s `WHERE` clause; kept the
`NOT EXISTS` idempotency guard (unchanged, still correctly scopes to rooms with no existing
`m.room.power_levels` event, still covers the `create_personal_room/2`-already-has-one case).
Every pre-existing room lacking a `m.room.power_levels` event now gets one backfilled, including
rooms whose `power_levels_json` is the literal empty `{}` — that is the room's real current
state, not a guessed default. Updated
`server/test/nebu/matrix/backfill_power_levels_events_migration_test.exs`'s third test case
(previously "does not backfill a room with no meaningful power levels") to assert these rooms
ARE backfilled now, with `content == %{}`. The `.down.sql` needed no change — it deletes rows by
the migration's own signature marker, independent of the `up.sql` `WHERE` clause.

## MINORs (technical, cycle 1 re-review)

1. **`Logger.warning` unbounded on the `/sync` hot path.** A room lacking identity would log
   once per sync per connected client, forever. **Resolution (this cycle):** downgraded to
   `Logger.debug` in `http.ex`'s sentinel branch — per this project's logger level convention
   (`server/config/prod.exs` sets `level: :info`), debug logs are compiled in but not emitted in
   production, making this effectively unbounded-safe there while remaining visible in dev
   (`level: :debug`). No existing "log once" dedup precedent was found elsewhere in the codebase
   to justify a more complex mechanism for a single log call. Also noted: the MAJOR-2 widening
   makes this branch far less reachable in practice going forward (it can still fire for
   `m.room.create`'s own pre-existing `{"", 0}` fallback on very-old rooms, cycle-0 MINOR-1).
2. **AND-short-circuit ordering in the migration's `WHERE` clause** — moot once the `<> '{}'`
   cast-comparison clause was removed per MAJOR-2 above; the remaining `IS NOT NULL`/`<> ''`
   checks are plain TEXT comparisons with no casting, so no operand-order risk remains.
3. **No persisted CI-gate evidence for cycle 1** — the claimed unit/integration pass counts were
   prose-only in `pipeline-state.yaml`, and the migration test is tagged `:integration` (excluded
   from `make test-unit-elixir`'s default run). Per the cycle-2 addendum, the orchestrator (not
   dev-story) runs the full CI-gate (`make redeploy` + `make test-integration` + unit suite) with
   persisted logs after this cycle's implementation; dev-story's own local run (full unit suite +
   the migration test + the 4 ATDD integration test files) is reported separately in this cycle's
   completion notes.

---

# Code Review — bugfix/sync-state-events-missing-fields (cycle 2, FINAL)

**Verdict: CLEAN. 0 MAJOR/CRITICAL. 2 MINOR (both explicitly optional, not worth a 3rd cycle),
9 INFO.**

## MAJOR-2 (migration widening) — VERIFIED RESOLVED
`<> '{}'::jsonb` exclusion confirmed removed from WHERE clause; idempotency guard and
create_personal_room exclusion confirmed intact (content-independent NOT EXISTS, can't have been
affected by widening the content predicate). Read-side (`@sql_power_levels_identity`) needs no
change — no content filter. Migration test's third case flipped to assert backfill-with-real-
identity for `{}` rooms, not just "doesn't crash".

## Logger downgrade — VERIFIED RESOLVED
`Logger.debug` confirmed genuinely silent in prod: `config/prod.exs` sets `level: :info`
with no override anywhere in the config chain; debug is dropped before the custom LogStore
handler ever sees it.

## MINOR (optional, not blocking)
1. Sentinel branch observability now zero in prod with no replacement counter — but confirmed
   no counter/telemetry precedent exists anywhere in the codebase to follow, and migration 35
   makes the branch nearly unreachable going forward. Acceptable as-is.
2. Migration test's third case proves the DB row exists but doesn't re-assert the full
   `/sync`-level claim for the `{}` case (test 1 already proves this end-to-end for the
   configured-PL case). The cycle-2 addendum's literal requirement is met; this is optional
   strengthening only.

## CI evidence, independently spot-checked
`ci-integration-cycle2.log` confirms the `:integration`-tagged migration test genuinely executed
this run (closes cycle-1's exact process complaint). 2642/35 vs baseline 2635/39 (+7 tests, -4
failures); all 35 failure headers read, none touch power_levels/state-events/backfill; the two
sync-named failures (RegressionSyncLoadTest, SyncConcurrentTest) both pre-exist in baseline.
`ci-unit-cycle2.log`: 2007/2007, --warnings-as-errors clean (all warnings from deps, not project
code).

**Conclusion: this bug fix is done.**
