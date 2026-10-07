---
ui: false
security_review: optional
---

# Bug: `/sync` state.events missing event_id/origin_server_ts/unsigned

## Story

As any spec-compliant Matrix client calling the default (undocumented-flag-free) `GET /client/v3/sync`,
every entry in `rooms.join.<room_id>.state.events` must carry the same required
`ClientEventWithoutRoomID` fields the spec mandates for `timeline.events` — `event_id` and
`origin_server_ts` are non-nullable there regardless of whether the event appears in the
state or timeline section of the response. Today they are silently dropped for state events,
so every standard SDK that type-parses state events (e.g. the Matrix Dart SDK used by
nebu-app, matrix-7.2.1) throws on the very first sync of any room, and the sync loop's
higher-level exception handling then still advances `next_batch`, making every later
incremental sync return empty too — the account looks "roomless" when it isn't.

## User report (German, verbatim)

"/sync liefert in rooms.join.*.state.events Events ohne event_id/origin_server_ts — bricht
jeden Standard-Matrix-Client. Schweregrad: Kritisch/Blocker. Ein Event erscheint in derselben
Sync-Response zweimal — einmal in rooms.join.<room_id>.timeline.events (vollständig) und
einmal in rooms.join.<room_id>.state.events (unvollständig). Betrifft alle State-Events in
state.events, nicht nur m.room.create — gleiches Bild bei m.room.power_levels, m.room.name,
m.room.canonical_alias im gleichen Payload. Fix-Vorschlag: beim Serialisieren von
rooms.join.*.state.events dieselbe vollständige Event-Repräsentation verwenden wie für
timeline.events."

The report additionally hypothesized that passing `org.matrix.msc4222.use_state_after=true`
(as Element Web does) exercises a second, correct server-side code path. **Investigation
found this premise to be wrong — see below.** Treat it as disproven, not as verified context.

## Verified architecture context

(Full investigation: read-only agent sweep of `server/lib/nebu/matrix/`, `server/lib/nebu/web/`,
`server/proto/core.proto`, `server/test/`, git history, and the bundled Matrix spec reference.)

**Endpoint:** `server/lib/nebu/web/router/protected.ex:46` (`GET /client/v3/sync`) → `do_sync/1`
(lines 56-105) → `Nebu.Matrix.EventDispatcher.Server.get_sync_delta/2` or `.get_initial_sync/2`
→ `Nebu.Matrix.Http.sync_response/2`. **There is no `use_state_after`/MSC4222 branch anywhere
in the codebase** — `conn.query_params` is only ever read for `since` and `timeout`. Confirmed
by repo-wide grep for `use_state_after`/`msc4222`/`4222`: zero implementation hits. The only
hit is in the bundled spec reference doc
(`skills/nebu-agent-oracle/matrix-spec/v1.18/changelog/v1.16/checklist.md:22`), listed as an
**unchecked, not-yet-implemented** item. Element Web sending that flag changes nothing
server-side today; Element is simply more lenient than the Matrix Dart SDK about missing
`event_id`/`origin_server_ts` on state events. **There is exactly one code path, used by both
initial and incremental sync, and it is the broken one.**

**The CORRECT path — `timeline.events`:** `server/lib/nebu/matrix/http.ex`, `build_joined_rooms/1`,
timeline block at lines 153-165, mapping a `%Core.Event{}` struct
(`server/proto/core.proto:192-202`, compiled `server/lib/pb/core.pb.ex`) directly to:
```elixir
%{
  "event_id" => te.event_id,
  "type" => te.event_type,
  "sender" => te.sender_id,
  "room_id" => te.room_id,
  "content" => decode_content(te.content),
  "origin_server_ts" => te.origin_ts,
  "unsigned" => %{"age" => max(1, now_ms - te.origin_ts)}
}
|> put_state_key(te.state_key)
```
`Core.Event` is produced by `event_map_to_core_event/1`
(`server/lib/nebu/matrix/event_dispatcher/server.ex:1378-1409`), mapped straight from the raw
`events` table row — `event_id`, `origin_server_ts` etc. all present natively.

**The BROKEN path — `state.events`:** same function, same call site, lines 141-149:
```elixir
%{
  "type" => se.type,
  "state_key" => se.state_key,
  "content" => decode_content(se.content),
  "sender" => se.sender
}
```
`se` is a `%Core.SyncRoomStateEvent{}` — **structurally missing the fields**, not just an
accidental serialization gap. Proto (`server/proto/core.proto:381-386`):
```proto
message SyncRoomStateEvent {
  string type      = 1;
  string state_key = 2;
  bytes  content   = 3;
  string sender    = 4;
}
```
It has no `event_id`, no `origin_server_ts`, no unsigned-related field — physically impossible
to emit them from this struct as-is.

**Where `Core.SyncRoomStateEvent` values come from** — `build_state_events/2`
(`server/lib/nebu/matrix/event_dispatcher/server.ex:2783-2864`), called from `get_room_state`,
`get_initial_sync`, and `fetch_delta_rooms`:
- `m.room.create` (2808-2813): via `Nebu.Matrix.Room.DB.get_room_create_event/1` /
  `get_room_creator/1` — DB-backed, but the helper only ever `SELECT`s content/sender.
- `m.room.member` (2815-2825): **fully synthesized from in-memory GenServer room state**
  (`state.members`) — hardcodes `"membership" => "join"`, `"displayname" => ""`. Not read from
  the persisted join event at all; no event identity is available at this call site today.
- `m.room.power_levels` (2827-2832): same pattern, from in-memory `state.power_levels`. No
  backing event row looked up at this call site either.
- `m.room.name` (2834-2844): via `get_room_name/1`, DB-backed, scalar-only `SELECT`.
- Generic state (2849-2861, Story 9-7): via `Nebu.Matrix.Room.DB.get_generic_state_events/1`.

**Smoking gun — the DB layer already has the data, it's just never selected.**
`server/lib/nebu/matrix/room/db.ex:1171-1203`, `get_generic_state_events/1`:
```sql
SELECT DISTINCT ON (event_type, state_key)
  event_type, state_key, content::text, sender
FROM events
WHERE room_id = $1 AND state_key IS NOT NULL
  AND event_type NOT IN ('m.room.member', 'm.room.power_levels', 'm.room.create', 'm.room.name')
ORDER BY event_type, state_key, origin_server_ts DESC
```
`origin_server_ts` is right there in the `ORDER BY`, and `event_id` is the row's primary key —
both exist and are queryable but the `SELECT` list (and the 4-tuple row destructuring in the
caller) never pulls them. Same scalar-only pattern in the sibling helpers `get_room_creator/1`
(db.ex:736-747) and `get_room_name/1` (db.ex:837-853).

**Existing in-repo precedent for this exact struct gap — informative, not to be copied
wholesale:** `GET /rooms/{roomId}/initialSync` and `GET /rooms/{roomId}/members` hit the same
`Core.SyncRoomStateEvent` gap and work around it with a synthesizing flattener,
`initial_sync_state_event/3` (`server/lib/nebu/web/router/protected.ex:800-824`):
```elixir
"event_id" => "$synth_" <> Base.url_encode64(se.type <> "|" <> se.state_key, padding: false),
"origin_server_ts" => now
```
This produces a stable-but-fake `event_id` and a **wrong** `origin_server_ts` (request time,
not the real event time). It satisfies schema-presence but not semantic correctness, and
`/sync`'s `build_joined_rooms/1` doesn't call it at all today (its state block just omits the
fields outright). **Do not extend this synthetic pattern into `/sync`** — see Acceptance
Criteria below for why real values are required here.

**`rooms.invite.*.invite_state.events` / `rooms.leave.*.state.events` — explicitly OUT of
scope, not the same bug:** `Nebu.Matrix.Http.sync_response/2` (http.ex:121-137) hardcodes
`"invite" => %{}, "leave" => %{}` — the `Core.SyncRoom` proto carries no membership field at
all yet, so these sections never emit *any* events, broken or otherwise. This is a separate,
larger, already-tracked gap (documented in the module's own moduledoc as MINOR-2). Do not
conflate it with this bug or expand scope to cover it.

**Test coverage gap, confirmed:** `matrix_client_compat_test.exs:695` only asserts
`is_list(room["state"]["events"])` (shape, not fields). `spaces_state_events_integration_test.exs`
and `spaces_foundation_integration_test.exs` assert on `type`/`state_key`/`content` only;
`event_id` is asserted solely on the PUT response, never on the state event as it appears
inside `/sync`. **No existing test currently fails because of this bug** — it's a true
coverage gap, not a regression of a prior assertion.

**History:** single commit (`6f94c20c`, Go→Elixir gateway migration) touches `http.ex`; the
state/timeline split has existed unchanged since then — not a recent regression. Prior sync
fixes (`4c4d40bb`, `deffe0e9`) addressed `state_key` handling but never `event_id`/
`origin_server_ts`/`unsigned` on state events.

## Scope boundary

**In scope:** `rooms.join.<room_id>.state.events` in `GET /client/v3/sync` (both initial and
incremental/delta sync — one shared code path, so one fix covers both).

**Out of scope:** `rooms.invite.*`/`rooms.leave.*` (pre-existing separate gap, always `{}`,
do not touch). Any live MSC4222 `use_state_after`/`state_after` implementation (not implemented,
not requested — the bug report's premise about a second working path was wrong). StackIT/AWS/k8s
or any unrelated deployment surface.

## Acceptance Criteria

**AC1 (core fix, ExUnit-testable):** Every entry in `rooms.join.<room_id>.state.events` in both
initial sync (no `since`) and incremental sync (`since` present) includes `event_id` (string)
and `origin_server_ts` (integer, epoch milliseconds) — and these must be the **real** values
from the underlying persisted event, not synthesized/fake ones, for every state event type:
`m.room.create`, `m.room.member`, `m.room.power_levels`, `m.room.name`, `m.room.canonical_alias`,
and any other generic state event.

**AC1 exception, Oracle-confirmed (do not treat as a gap):** `dedup_member_state_events/2`
(`server/lib/nebu/matrix/event_dispatcher/server.ex:2731-2749`, pre-existing, Element-compat,
matches on `state_key` independent of `event_id`) strips a user's own `m.room.member` entry
from `state.events` whenever that same join/membership event already falls inside the returned
`timeline.events` window (always true for a freshly created small room's very first sync, since
the join event is one of the first few timeline events). **This is spec-compliant, not a bug** —
confirmed against CS API v1.18 `/sync` `state` field definition (local bundle
`client-server-api/index.html:15366-15374`): `state` = "updates to the state... up to the
**start** of `timeline`" — a membership change occurring *inside* the timeline window is by
definition not part of `state`. The own-membership MUST-include rule (`:14966-14975`) is
satisfied once the event reaches the client via `timeline.events`; the "regardless of
redundancy" clause there is scoped strictly to `limited:true` gap-backfill (events the server
omitted entirely), not to same-response state-vs-timeline placement. **Do not modify
`dedup_member_state_events/2` as part of this fix** — leave its logic untouched. Any test
asserting `m.room.member`'s presence must assert the correct conditional placement: absent from
`state.events` AND present in `timeline.events` with real `event_id`/`origin_server_ts` when the
join event falls inside the window; present in `state.events` with real identity when it does
not (e.g. `limited:true`/historic-join cases). A weaker "present somewhere, state OR timeline"
assertion is explicitly insufficient (Oracle: would mask a regression where the event wrongly
appears in both).

Rationale for requiring real values over the existing
synthetic-fallback precedent (`initial_sync_state_event/3`): `origin_server_ts` drives client-side
ordering/display and a fake "now" timestamp actively misleads clients (e.g. a years-old
`m.room.create` would appear to have just happened), and `event_id` is used by clients to
reference/dedupe/redact — a non-stable or made-up ID breaks those operations silently instead
of loudly. A parsing fix that trades one spec violation for a semantic-correctness regression
is not an acceptable fix for a "Kritisch/Blocker" bug.

**AC2 (schema widening, the enabling change for AC1):** `Core.SyncRoomStateEvent`
(`server/proto/core.proto:381-386`) gains `event_id` (string) and `origin_server_ts` (int64/
equivalent) fields; regenerate the compiled `server/lib/pb/core.pb.ex`. Thread real values
through from each producer in `build_state_events/2`
(`server/lib/nebu/matrix/event_dispatcher/server.ex:2783-2864`):
- `m.room.create`, `m.room.name`, generic state: DB-backed already — extend the `SELECT` lists
  and row-destructuring in `get_room_create_event/1`/`get_room_creator/1` (db.ex:736-747),
  `get_room_name/1` (db.ex:837-853), and `get_generic_state_events/1` (db.ex:1171-1203) to also
  return `event_id`/`origin_server_ts` (both columns already exist on `events` and are used
  elsewhere in the same queries, e.g. the `ORDER BY origin_server_ts DESC` in
  `get_generic_state_events/1` — this part is a narrow, low-risk SQL change).
- `m.room.member`, `m.room.power_levels`: currently synthesized purely from in-memory GenServer
  room state (`state.members`, `state.power_levels`) with no event identity available at the
  call site. The GenServer already processes the backing event (with its real `event_id`/
  `origin_server_ts`) at the moment it applies that membership/power-levels change into its
  in-memory state — capture both fields into the `state.members`/`state.power_levels` map
  entries at that point (rather than adding a per-sync DB round trip, which would be a
  cluster-safety/hot-path concern) so `build_state_events/2` can read them back out directly.
  Oracle Gate and dev-story should confirm the exact update site(s) where `state.members`/
  `state.power_levels` are currently populated and extend those, not re-derive by a fresh query.

**AC2 addendum, discovered during ATDD round 2 (required scope, not optional):**
`m.room.power_levels` currently has **no backing persisted event at all**. `Nebu.Matrix.Room.Server`'s
`handle_call({:set_power_levels, ...})` (`server/lib/nebu/matrix/room/server.ex:330-348`) only
writes `rooms.power_levels_json` via `db_module().set_power_levels/2` — unlike `:join`'s
`emit_membership_event/3`, it never calls `insert_event`. AC2's premise ("the GenServer already
processes the backing event... at the moment it applies the change") does **not** hold for
power_levels as written today. Dev-story must add real event emission at this call site
(mirroring `emit_membership_event/3`'s pattern) as part of AC2 — without it, `m.room.power_levels`
can never acquire a real `event_id`/`origin_server_ts` no matter how the read/threading side is
implemented. The existing ATDD assertions (requiring a real, DB-matching `event_id` for
`m.room.power_levels`) already force this; flagging explicitly so it isn't mistaken for a
pure read-side threading change.

**AC3 (parity, not strictly spec-required but should be done for consistency):** State events
also include `unsigned` (object, at minimum `age` in ms) the same way `timeline.events` does —
confirm with Oracle Gate whether `unsigned` is optional per `ClientEventWithoutRoomID` (expected:
yes, optional) before treating this as blocking; implement it regardless since it is trivial
once `origin_server_ts` is real, and several client SDKs read `unsigned.age` opportunistically
even though it's not mandatory.

**AC4 (regression guard):** `timeline.events` serialization, `rooms.invite`/`rooms.leave`
(still empty `{}`), and all currently-passing sync/room/spaces tests remain green. No new
required env var or config.

**AC5 (test coverage, closes the gap found in investigation):** New/extended ExUnit coverage
in `server/test/nebu/matrix/` asserting that `rooms.join.<room_id>.state.events[*]` carries a
non-nil, correctly-typed `event_id` and `origin_server_ts` whose value matches the real
persisted event (not a placeholder) — for at least `m.room.create`, `m.room.member`,
`m.room.power_levels`, and one generic state event type (e.g. `m.room.name` or
`m.room.canonical_alias`) — covering both initial sync and incremental/delta sync. For
`m.room.member` specifically, assert the AC1-exception-conditional placement (see AC1) rather
than unconditional `state.events` presence — this requires correcting two round-1 ATDD
assertions (`matrix_client_compat_test.exs`, the "5 rooms" test and the "initial sync (no
since)" test, both using `@sync_fields_expected_types`/`assert_real_state_event_fields`) that
currently assert unconditional member presence in `state.events`; see Dev Notes.

## Code-review cycle 1 addendum (user decision, 2026-10-03)

Code-review found MAJOR-1: rooms created BEFORE this fix have no `m.room.power_levels` row in
`events` at all (the old code never persisted one), so after the fix they still surface
`event_id: ""`/`origin_server_ts: 0` (epoch 1970) in `/sync` — exactly the class of bug this
fix exists to close, just scoped to pre-existing rooms, and invisible to ATDD since every test
creates a fresh room. **User decision: backfill migration** (not lazy-emit-on-restart, not
accept-and-document). AC1/AC2 now include this as required scope:

**AC2 addendum 2 (backfill migration, required):** add a migration under
`server/priv/migrations/` that inserts one authoritative `m.room.power_levels` event per
pre-existing room lacking one — `sender` = room creator, `origin_server_ts` = the room's
`created_at`, `event_id` via the same generation scheme `EventId.generate/1` uses elsewhere
(or an equivalent deterministic/valid id), `content` = that room's current `power_levels_json`
(so the backfilled event matches the room's actual current power levels, not a guessed
default). Check `server/priv/migrations/` naming convention (numbered, paired `.up.sql`/
`.down.sql`) and the project's `MigrationsGrantTest` convention — this migration INSERTs into
the existing `events` table (no new table), so the GRANT-on-new-table requirement likely does
not apply, but verify `nebu_app` already has INSERT on `events` (it must, since normal event
writes already depend on it) rather than assuming. The project has a known gotcha: "a new
migration with no GRANT to `nebu_app` silently fail-opens in prod while CI stays green" — treat
any GRANT-adjacent decision here with that in mind even though this migration likely doesn't
need one. Add/extend a test confirming the migration runs cleanly against a representative
legacy-shaped DB fixture (a room with `power_levels` set but no `m.room.power_levels` event row)
and that post-migration `/sync` for that room now carries real identity.

**Also fold in the 5 MINOR findings from code-review cycle 0** (full detail in
`code-review-findings.md`, step-results dir): (1) `http.ex` ships `""`/`0` sentinels raw to the
wire when identity is unavailable — omit `unsigned` in that case (it's optional per Oracle) and
log a warning instead of a ~56-year fake age; (2) `sender: ""` on `m.room.power_levels`/
`m.room.name` state events is now inconsistent with their real `event_id` — add `sender` to
`get_room_name/1`'s SELECT and carry `caller_id` alongside the power-levels identity tuple;
(3) `m.room.member`'s synthesized content (`displayname: ""`) is now inconsistent with the real
persisted event's actual content — align them; (4) stale/now-incorrect comment in
`protected.ex:801` about the state struct "omitting" identity fields; (5) document the
fail-open semantics of `member_identity`/`power_levels_event` in `room/server.ex`'s moduledoc.

## Code-review cycle 2 addendum (user decision, 2026-10-03)

Cycle-1 code-review confirmed all 6 cycle-0 findings genuinely resolved, but found MAJOR-2:
the backfill migration's `WHERE r.power_levels_json::jsonb <> '{}'::jsonb` guard skips rooms
whose power levels were never actually configured (still the column default `{}`) — those rooms
still surface `event_id: ""`/`origin_server_ts: 0` for `m.room.power_levels` in `/sync`. Lower
severity than cycle-0's MAJOR-1 (a valid empty string doesn't crash the Matrix Dart SDK's
type-parser the way a missing/null field did), but still violates AC1's "real values, not
synthesized" requirement. **User decision: widen the migration to also backfill these rooms**
(not suppress-the-entry, not accept-and-document).

**AC2 addendum 3 (required):** remove the `power_levels_json::jsonb <> '{}'::jsonb` exclusion
from migration `000035_backfill_power_levels_events.up.sql`'s `WHERE` clause (keep the
`NOT EXISTS` idempotency guard and the `create_personal_room/2`-already-has-one exclusion —
those stay correct and necessary) so every pre-existing room lacking a `m.room.power_levels`
event gets one backfilled, with `content` = that room's actual `power_levels_json` verbatim
(which will legitimately be `{}` for these rooms — that's fine, it's the room's REAL current
state, just a trivial one, not a guessed default). Update/extend the migration's own test
(`backfill_power_levels_events_migration_test.exs`) accordingly — its third test case
("does not backfill a room with no meaningful power levels") currently asserts the OLD,
now-superseded behavior and must be changed to assert these rooms ARE backfilled too (with
`content == %{}`).

**Also fold in 3 technical MINORs from the cycle-1 re-review (code-review-findings.md has full
detail):**
1. `Logger.warning` in `http.ex`'s sentinel branch is unbounded on the `/sync` hot path — add
   rate limiting/sampling or downgrade to `Logger.debug` + a counter, so a room lacking identity
   doesn't log once per sync per connected client forever. (Note: once this migration widening
   lands, this branch should become far less reachable in practice — but still worth guarding,
   since `m.room.create`'s own pre-existing `{"", 0}` fallback for very-old rooms, cycle-0
   MINOR-1, can still hit it.)
2. The migration's `WHERE r.power_levels_json <> '' AND r.power_levels_json::jsonb <> '{}'::jsonb`
   relied on AND short-circuit ordering Postgres doesn't guarantee — moot once the `<> '{}'`
   clause is removed per the widening above, but if any JSON-validity guard remains for other
   reasons, use a `CASE`/`jsonb_typeof` guard instead of relying on operand order.
3. **No persisted CI-gate evidence exists for cycle 1** — the claimed unit/integration pass
   counts were prose-only in pipeline-state.yaml, and the new migration test is tagged
   `:integration` (excluded from `make test-unit-elixir`'s default run), so the "2007/2007 unit"
   claim did not actually execute it. **This cycle, the orchestrator (not dev-story) will run
   Step 5 (ci-gate) directly via `make redeploy` + `make test-integration` + unit suite with
   persisted logs** — dev-story does not need to re-prove this itself, just implement the
   migration widening + Logger fix and ensure its own local test run is green before handing back.

## Dev Notes

- Oracle Gate: confirm `ClientEventWithoutRoomID`'s exact required-vs-optional field list
  (expect: `event_id`/`origin_server_ts`/`sender`/`type`/`content` required, `state_key` required
  only for state events, `unsigned` optional) before finalizing AC3's priority.
- `initial_sync_state_event/3` (protected.ex:800-824) is a useful reference for the target JSON
  shape (flattening a `SyncRoomStateEvent` into Matrix state-event JSON) but its synthetic
  `event_id`/`origin_server_ts` values must NOT be reused or extended to `/sync` — see AC1
  rationale. Once this bug is fixed, that helper itself is arguably now also wrong/inconsistent
  (`/initialSync` and `/members` would still return synthetic values) — flag as a loud follow-up
  note in the PR/story rather than silently expanding this bug's scope to fix those too.
- A stale, unrelated worktree exists at `.claude/worktrees/bugfix+fluffychat-element-sync`
  (branch `worktree-bugfix+fluffychat-element-sync`) — unrelated to this bug (references a
  different bug, `bugfix-account-data-sync-wake`, from 2026-07-06); do not touch it.
- This bug fix is being committed directly on branch `bugfix/upcloud-s3-iam-sts-endpoints` per
  explicit user instruction, not a fresh `bugfix/<slug>` branch — do not create/switch branches.
- **Test fix required before dev-story (ATDD round 3 scope):** `matrix_client_compat_test.exs`'s
  `assert_real_state_event_fields/2` (and the "5 rooms" test's own inline type-coverage loop)
  must stop asserting unconditional `m.room.member` presence in `state.events`. Replace with:
  check whether the member's own join event is present in `timeline.events` for that sync
  (mirroring production's own `dedup_member_state_events/2` predicate — match by `state_key`);
  if present there, assert ABSENT from `state.events` and assert real `event_id`/
  `origin_server_ts` on the `timeline.events` entry instead; if not present there (e.g. a
  padded/aged room, or `limited:true`), assert present in `state.events` with real identity as
  originally written. Do not weaken to "present somewhere" (Oracle: that would mask a regression
  where the event wrongly appears in both places).
- Oracle flagged one non-blocking edge case, optional: `dedup_member_state_events/2` matches by
  `state_key` only — a user whose membership went e.g. `invite` → `join` within the same
  timeline window would have its stale `invite` state entry also dropped. Likely harmless
  (timeline replay still lands on the correct final state) but worth a regression test if time
  allows; not required for this bug fix.
