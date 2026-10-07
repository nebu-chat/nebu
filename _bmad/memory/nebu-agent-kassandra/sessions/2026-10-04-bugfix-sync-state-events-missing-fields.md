## Session — bugfix-sync-state-events-missing-fields (security-review, staged diff)

**Scope:** staged diff on `bugfix/upcloud-s3-iam-sts-endpoints` (24 files, +2867/-96). Production
surface: `matrix/http.ex` (/sync state.events serialization), `matrix/event_dispatcher/server.ex`
(`build_state_events/2` + 2 authz tuple-shape sites), `matrix/room/server.ex` (new
`emit_power_levels_event/3`, `member_identity`/`power_levels_event` GenServer fields, restart
restore), `matrix/room/db.ex` + `db_behaviour.ex` (4 widened queries), `web/router/protected.ex`
(comment only), `pb/core.pb.ex` + `proto/core.proto` (struct widening), and NEW data migration
`priv/migrations/000035_backfill_power_levels_events.{up,down}.sql`.

Report: `docs/stories/security-reports/bugfix-sync-state-events-missing-fields-security-review-2026-10-04.md`

**Finding summary:** 0 CRITICAL, 0 HIGH, 1 MEDIUM, 3 LOW, 4 INFO. Verdict APPROVED / CLEAN.

- MEDIUM F-1: `room/server.ex:422-426` `power_levels_event: identity || state.power_levels_event`
  — on `emit_power_levels_event/3` failure the CONTENT advances but the IDENTITY stays pinned to
  the previous event. Non-transactional pair (`UPDATE rooms SET power_levels_json` + `INSERT INTO
  events`) → divergence persists in the DB and is faithfully rebuilt by `do_init/1` after every
  restart. Fix: one transaction, or `nil` on failure.
- LOW F-2: `state_key = ''` equality on a nullable column in BOTH the migration's `NOT EXISTS`
  guard and the new `@sql_power_levels_identity`. MEMORY #25. Could not prove a historical
  NULL-state_key `m.room.power_levels` writer (archaeology: `""->nil` removed at a5dccf51
  2026-05-05; first PL-event writer `create_personal_room` landed 9e8a85df 2026-05-29) → robustness,
  not a demonstrated bug. Fix is one clause; codebase idiom already exists at `search/db.ex:34,62`.
- LOW F-3: `@sql_member_identities` = `DISTINCT ON (state_key)` over ALL members ever, filtered in
  Elixir; +2 queries per `Room.Server` start on a 10-conn pool. Fix: `AND state_key = ANY($2)`.
- LOW F-4: `event_id: ""` sentinel is a wire-visible invalid Matrix event ID (no `$` sigil) and is
  shared across several state events in a room → client event-cache collision.

**New patterns discovered (curated into MEMORY.md as #90, #91):**
1. A pure-SQL data migration that hand-reproduces the OUTPUT FORMAT of an application-layer id
   generator without reproducing its SEMANTICS, plus a non-signature in the `signatures` column.
   Safe only while three legs hold (no `EventId.verify/2` callers in `lib/`; no Ed25519 verify over
   `events`; the marker is not client-reachable). Leg 3 verified structurally, not just claimed:
   every `insert_event/1` call site builds `signatures` server-side — request bodies land under
   `content`. The expiry condition is a FUTURE integrity-verification consumer. MEMORY #86 shape.
2. Fail-open secondary write that keeps a KNOWN-WRONG cached identity (`identity || old`) instead of
   nil-ing it. "Keep the old value" is the wrong fail-open when the field is an IDENTITY for content
   that just changed — it manufactures a durable lie. Prefer transaction, else nil.

**Verified-clean reusable facts (don't re-derive):**
- `000001_init.up.sql:672` blanket `GRANT ... ON ALL TABLES TO nebu_app` is at line 672 and `events`
  is created at line 211 of the SAME file → post-000001 migrations that only INSERT into `events`
  genuinely need no GRANT (MEMORY #88 does not fire). Verified, not assumed.
- `events` has NO RLS policy and NO append-only trigger (unlike `media_state_transitions`, MEMORY
  #85). `Nebu.Release.apply_migration/3` wraps each file in ONE transaction, simple protocol.
- `SetPowerLevels` RPC handler (`event_dispatcher/server.ex:1412`) has NO HTTP route anywhere in the
  repo — `Room.Server.set_power_levels/3` is reachable only from `create_room` and `upgrade_room`.
  This is what makes the backfill's creator/created_at attribution accurate TODAY.
- `m.room.power_levels` is still on `@initial_state_forbidden_types` (`:4642`) and absent from
  `@writable_state_types` (`:1927`) — MEMORY #68/#72 guardrails intact.
- All `build_state_events/2` consumers are membership-gated; the hierarchy path forwards only
  `build_room_summary/3` scalars + `stripped_children_state/1` ({type,state_key,content,sender}) —
  no `event_id`/`origin_server_ts` crosses the member boundary.
- `config/prod.exs` sets primary logger level `:info`; `LogStore.Handler` is attached with an EMPTY
  config (`log_store.ex:45`, no own level) → primary-level filtering runs first, so `Logger.debug`
  genuinely never reaches the operational log store in prod. The hot-path-debug-log argument in
  `http.ex` is sound.
- `events_search_vector_update()` indexes only `content->>'body'`; both search queries hard-filter
  `event_type = 'm.room.message'` → new power-levels events are not searchable.
- `:pg` "room:<id>" groups are joined only for membership-derived room_ids and carry a wakeup only
  (payload re-fetched by membership-scoped `fetch_delta_rooms/3`) → no fanout leak.
- No new audit action → `AuditWriter.@known_actions` correctly untouched (MEMORY #49 checked, not
  assumed). Power-level changes remain absent from `audit_log` entirely — pre-existing.

**Accepted risks this session:** none newly accepted.

**Follow-up:**
- F-1 (MEDIUM) before epic end.
- F-2/F-3 are one-line SQL hardenings; batch them with the next touch of `room/db.ex`.
- Watch-flag: if `SetPowerLevels` ever gets an HTTP route, (a) the backfill's attribution premise
  expires (INFO-1) and (b) the privilege change needs an `audit_log` action + `@known_actions` entry
  in the same story (MEMORY #49).
- Watch-flag: the first feature that verifies event integrity must handle `nebu_backfill_migration`
  rows explicitly or they read as tampered (INFO-2).
- `initial_sync_state_event/3` (`protected.ex:800-824`) still synthesizes fake identity for
  `/initialSync` and `/members` — agreed out of scope, deliberately documented in-tree.
