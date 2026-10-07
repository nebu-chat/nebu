# Security Review — bugfix-sync-state-events-missing-fields

**Reviewer:** Kassandra (nebu-agent-kassandra, `references/security-review.md`)
**Diff scope:** `git diff --staged` on branch `bugfix/upcloud-s3-iam-sts-endpoints` — 24 files,
+2867/-96. Production surface: `server/lib/nebu/matrix/http.ex`,
`server/lib/nebu/matrix/event_dispatcher/server.ex`, `server/lib/nebu/matrix/room/server.ex`,
`server/lib/nebu/matrix/room/db.ex`, `server/lib/nebu/matrix/room/db_behaviour.ex`,
`server/lib/nebu/web/router/protected.ex`, `server/lib/pb/core.pb.ex`, `proto/core.proto`,
and the new data migration `server/priv/migrations/000035_backfill_power_levels_events.{up,down}.sql`.
**Date:** 2026-10-04
**Classification:** CLEAN (no CRITICAL, no HIGH)
**Verdict:** APPROVED — nothing blocks the commit.

Prior review context consumed and deliberately not re-derived: `bug-context.md` (3 dev-story
cycles, 2 user decisions) and `code-review-findings.md` (2 independent Opus code-review passes
covering GRANT/RLS implications, idempotency, hot-path DB round-trips, data-shape consistency).
This review applied a security-specific lens on top of those.

---

### Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| 1 | MEDIUM | `server/lib/nebu/matrix/room/server.ex:422-426` | Stale-identity retention: `power_levels_event: identity \|\| state.power_levels_event` keeps the PREVIOUS event's identity when `emit_power_levels_event/3` fails while `power_levels` advances — `/sync` then ships new authorization content under a different, older `event_id`, permanently | Make the `set_power_levels` UPDATE and the `insert_event` one DB transaction; failing that, set `power_levels_event: nil` on emit failure rather than keeping a provably-wrong identity |
| 2 | LOW | `000035_backfill_power_levels_events.up.sql:132-137`; `server/lib/nebu/matrix/room/db.ex:37-40` | `state_key = ''` equality filter on a NULLable column — the project's own defensive idiom (`search/db.ex:34,62`) is `(state_key = '' OR state_key IS NULL)`. MEMORY pattern #25 exists for exactly this column | Widen both the migration's `NOT EXISTS` guard and `@sql_power_levels_identity` to `(ex.state_key = '' OR ex.state_key IS NULL)` |
| 3 | LOW | `server/lib/nebu/matrix/room/db.ex:21-27,131-139` | `@sql_member_identities` returns one row per distinct `state_key` ever seen in the room (no membership predicate, no LIMIT) and filters in Elixir; runs on every `Room.Server` start, so a mass restart amplifies it across the 10-connection pool | Push the filter into SQL: `AND state_key = ANY($2)` with the already-loaded `user_ids` |
| 4 | LOW | `server/lib/nebu/matrix/http.ex:172-186` | `event_id: ""` sentinel is shipped to clients as a syntactically invalid Matrix event ID (spec requires a `$` prefix); several state events in one room can share `""`, so a client keying its event cache by `event_id` can collide them | Emit a deterministic `$`-prefixed id for the unavailable case, or omit the whole state entry, instead of a wire-visible empty string |

INFO items (no severity, recorded for the audit trail and future reviews) are in the Detail section.

---

### Detail

**Finding #1 — Stale power-levels identity survives a failed event write** [MEDIUM]

`handle_call({:set_power_levels, ...})` (`room/server.ex:403-432`) performs two independent
writes: `db_module().set_power_levels/2` (an `UPDATE rooms SET power_levels_json`) and then
`emit_power_levels_event/3` (an `INSERT INTO events`). The second is deliberately non-fatal.
On failure the handler does:

```elixir
power_levels: new_levels,
power_levels_event: identity || state.power_levels_event
```

so the CONTENT advances to the new power levels while the IDENTITY stays pinned to the previous
`m.room.power_levels` event. `build_state_events/2` then emits a `Core.SyncRoomStateEvent` whose
`content` is `state.power_levels` (new) and whose `event_id`/`origin_server_ts`/`sender` describe
a different, older event. `GET /rooms/{roomId}/event/{eventId}` for that id returns the OLD
content, so the two views of the same claimed event contradict each other.

This is not transient. `rooms.power_levels_json` (new) and the newest `events` row for
`m.room.power_levels` (old) have diverged in the database, so `do_init/1` reconstructs exactly
the same mismatch after every restart, forever.

Security relevance: a `/sync` state event is how a client learns the room's authorization table.
A client that dedupes or caches state by `event_id` — standard SDK behaviour, and the very reason
AC1 insisted on real rather than synthesized ids — sees an `event_id` it has already processed
and can discard the power-levels change. The user's rendered permission state then disagrees with
the server's. Server-side enforcement is unaffected (`PowerLevels.can?/3` reads
`state.power_levels` directly), so this is an integrity/misrepresentation issue, not an authz
bypass — hence MEDIUM, not HIGH.

Reachability is narrow: the only shipped callers of `Room.Server.set_power_levels/3` are
`create_room` (`event_dispatcher/server.ex:407`) and `upgrade_room` (`:4413`), both with a fresh
`room_id`, so an `event_id` primary-key collision cannot occur; the failure needs a genuine DB
error. That is a specific condition, not an impossible one.

Remediation: wrap the `UPDATE rooms SET power_levels_json` and the `INSERT INTO events` in a
single transaction so content and identity cannot diverge. If that is unwanted, change the
fallback to `power_levels_event: nil` — shipping the known-unavailable sentinel is strictly more
honest than shipping an identity the server knows is wrong.

**Finding #2 — `state_key = ''` equality filter on a NULLable column** [LOW]

`events.state_key` is nullable (`000001_init.up.sql:220`). The migration's idempotency guard and
the new runtime query both use bare equality:

```sql
-- 000035 up.sql
AND ex.state_key = ''
-- room/db.ex @sql_power_levels_identity
WHERE room_id = $1 AND event_type = 'm.room.power_levels' AND state_key = ''
```

In three-valued SQL logic a row with `state_key IS NULL` does not match, so `NOT EXISTS` returns
TRUE and the migration would insert a SECOND `m.room.power_levels` event for such a room.
`@sql_power_levels_identity` would then resolve identity to the synthetic backfill row and shadow
the real one.

Honest assessment of exploitability: I attempted to construct a confirmed writer of a
NULL-`state_key` `m.room.power_levels` row and could not. Git archaeology shows the erroneous
`"" -> nil` conversion in `insert_event/1` was already removed at `a5dccf51` (2026-05-05, story
9-7), while the first code path that ever persisted an `m.room.power_levels` event
(`create_personal_room`, `9e8a85df`) landed 2026-05-29 — after the removal. Pre-9-7 databases
predate the `state_key` column entirely and, per this bug's own premise, never emitted a
power-levels event at all. So this is a robustness/defense-in-depth gap, not a demonstrated
duplicate-insert bug.

It still earns a finding because the codebase already carries the correct idiom two files away
(`search/db.ex:34` and `:62` use `(enc.state_key = '' OR enc.state_key IS NULL)`), MEMORY pattern
#25 was recorded for precisely this column, and the fix is one clause in two places.

**Finding #3 — Unbounded member-identity fetch on every room start** [LOW]

```sql
SELECT DISTINCT ON (state_key) state_key, event_id, origin_server_ts
FROM events
WHERE room_id = $1 AND event_type = 'm.room.member'
ORDER BY state_key, origin_server_ts DESC
```

`DISTINCT ON (state_key)` returns one row for every user who has EVER had an `m.room.member`
event in the room, including everyone who left long ago; the current-member filter is then applied
in Elixir (`db.ex:135`, `Enum.filter` against a `MapSet` of `user_ids`). The query is index-covered
by `events_room_state_idx` so the plan is fine, but the row count transferred is governed by
lifetime churn rather than current membership, and `load_member_power_levels_identity/2` adds two
queries to a path (`do_init/1`) that previously issued three.

This matters at restart fan-out: a deploy or a Horde rebalance starts many `Room.Server` processes
at once against a 10-connection pool, so this is a ~67% increase in room-start query volume plus
unbounded row transfer per room. Attacker-independent and availability-only, hence LOW.

Remediation: add `AND state_key = ANY($2)` and pass `user_ids`, moving the filter into SQL and
bounding the result set to current membership.

**Finding #4 — `event_id: ""` is a wire-visible invalid Matrix event ID** [LOW]

`http.ex` now always emits `"event_id" => se.event_id`, and correctly suppresses `unsigned` plus
logs at `:debug` when `se.event_id == ""`. The empty string satisfies the Matrix Dart SDK's
type-parser (which is what this whole bug fix exists to unblock), but it is not a valid event ID —
the spec requires a `$` sigil. Two consequences worth naming:

1. Every identity-less state event in a room ships the SAME `""`, so a client keying its event or
   state cache by `event_id` can collapse distinct state events into one entry.
2. A client that round-trips the id (redaction, relation, read receipt, `/event/{eventId}`) acts
   on a reference the server cannot resolve.

Post-migration this branch should be close to unreachable — the only remaining producers are
`m.room.create` for a room with no persisted create event (the pre-existing cycle-0 MINOR-1
fallback at `event_dispatcher/server.ex:2826`) and a failed `insert_event`. It is the accepted
fail-open, documented in `room/server.ex`'s moduledoc, and I am not re-litigating the decision —
only the choice of sentinel value. A deterministic `$`-prefixed id (the shape
`initial_sync_state_event/3` already uses at `protected.ex:806`) or omitting the entry entirely
both avoid the cache-collision shape without reintroducing the original crash.

The `Logger.debug` guard itself is correctly built: `inspect(se.state_key)` escapes control
characters, so the one field on that line that could carry attacker-influenced bytes (a
`m.space.child` state_key from the URL path) cannot inject into the log stream — and that branch
is unreachable for generic state events anyway, since their `event_id` comes from a NOT NULL
column. The `Logger.debug`-in-prod reasoning in the comment is also correct: `config/prod.exs`
sets the primary logger level to `:info`, which filters before any handler runs, so the LogStore
handler (`log_store.ex:45`, attached with an empty config and therefore no level of its own)
never sees these entries in production.

---

### Verified clean — the five angles this review was specifically tasked with

**1. Migration inserting synthetic events via direct SQL — no forgery or audit-integrity gap.**

- *Invariant bypass:* the normal path's invariants are enforced ABOVE `insert_event/1`, not inside
  it — `insert_event/1` is a bare parameterized INSERT with no signature check, no access control
  and no rate limit. The migration therefore bypasses nothing that the Elixir path enforces at
  that layer. The two guardrails that matter for this event type are both intact and untouched:
  `m.room.power_levels` remains on `@initial_state_forbidden_types`
  (`event_dispatcher/server.ex:4642`) and remains absent from `@writable_state_types` (`:1927`),
  so the new emitter opened no forgery path through createRoom `initial_state` or the state-PUT
  endpoint. (MEMORY patterns #68/#72 — every event-writer path must be re-checked; done.)
- *The `signatures` marker is not client-forgeable.* Every `insert_event/1` call site builds
  `signatures` server-side as `%{"nebu" => Base.encode64(ed25519_sig)}`
  (`room/server.ex:598,644,696`; `event_dispatcher/server.ex:348,437,3304,3427,3514,3580,4289,4745`).
  No client-supplied map reaches that column — request bodies land under `content`. The
  `nebu_backfill_migration` key therefore cannot collide with a real signature (different key
  name, different JSON shape) and cannot be planted by a user to trick `.down.sql` into deleting a
  genuine event.
- *No signature-verification code path is broken.* `Nebu.Matrix.EventId.verify/2` has zero call
  sites in `lib/` (verified independently of the migration's own claim — only `event_id.ex`
  doctests and `nebu_event_id_test.exs` call it), and nothing in `lib/` performs Ed25519
  verification over `events.signatures`. The migration's `event_id` is deliberately NOT
  `EventId.generate/1`-reproducible (different preimage: a pipe-delimited string vs canonical
  JSON), which also makes a cross-scheme `event_id` collision structurally impossible — canonical
  JSON always begins with `{`.
- *Provenance accuracy:* `sender` = earliest `m.room.create` sender, `origin_server_ts` =
  `rooms.created_at`, `content` = `rooms.power_levels_json` verbatim. In the current codebase this
  attribution is ACCURATE, not a fabrication: `rooms.power_levels_json` has exactly one writer
  (`db.ex:403`), reachable only from `create_room` (creator, at creation) and `upgrade_room`
  (requester, who is also the new room's creator). The `SetPowerLevels` RPC handler
  (`event_dispatcher/server.ex:1412`) has NO HTTP route anywhere in the repository, so no
  third party can have changed a room's power levels before this deploy. See INFO-1 for the
  forward-looking caveat.

**2. Event-identity race conditions — no primitive to reference, redact or dedupe the wrong event,
beyond Finding #1.**

`member_identity` is mutated only inside `Room.Server`'s serialized `handle_call` callbacks: set on
`:join`, deleted on leave/kick/ban. Every member-add path goes through `Room.Server.join/2`
(`event_dispatcher/server.ex:388,716,3129,3195,4402`) or `create_personal_room`'s own
`persist_event` — there is no path that adds a member without emitting a backing `m.room.member`
event, so identity cannot be structurally absent for a live member. The restart restore is
room-scoped (`WHERE room_id = $1`) and filtered to current members, so no cross-room or
cross-user identity can leak in. `Room.Server` is a Horde singleton per room, so there is no
two-node interleaving on these fields (MEMORY pattern #79's shape does not apply). The one
remaining mismatch — content hardcoded to `{"membership":"join"}` while `event_id` could point at
a non-join membership event — requires a pre-existing divergence between `room_members` and
`events` and is not introduced by this diff.

**3. No new information disclosure.**

Every consumer of `build_state_events/2` is membership-gated: `/sync` operates on the caller's own
joined rooms; `get_room_state` enforces `MapSet.member?(state.members, caller_id)` unless the
caller is the internal `system` role (`event_dispatcher/server.ex:1868-1873`, Story 7-19 IDOR fix
preserved). The only non-member-reachable consumer is the space-hierarchy path
(`visible_summary_or_forbid!/2`, `room_visibility_summary/2`), and it never forwards a
`Core.SyncRoomStateEvent` — `build_room_summary/3` extracts derived scalars (name, topic, alias,
join_rule, history_visibility, room_type, avatar, member counts) plus `stripped_children_state/1`,
which emits `{type, state_key, content, sender}` for `m.space.child` only, exactly as before this
diff. No `event_id` and no `origin_server_ts` crosses the member boundary.

Comparing `m.room.power_levels` against the types that already carried real identity: it is not
meaningfully different. Its `sender` (previously hardcoded `""`, now the real setter) and its
timestamp are standard `ClientEventWithoutRoomID` fields that every room member is entitled to
per the CS API, and all three values are already derivable by a member from
`m.room.create` + the power-levels content itself. `get_room_name/1` likewise gained `sender`,
matching what `get_generic_state_events/1` has always exposed for every other state type — this
change makes the response set MORE internally consistent, not more revealing.

The new `m.room.power_levels` event is also broadcast via
`:pg.get_local_members("room:#{room_id}")`. That group is joined only for room ids the sync loop
already resolved from the caller's membership (`event_dispatcher/server.ex:2574-2580`), and the
broadcast is only a long-poll wakeup — the payload a client actually receives is re-fetched by the
membership-scoped `fetch_delta_rooms/3`. No fanout leak.

Search is unaffected: `events_search_vector_update()` indexes only `content->>'body'` (NULL for
power-levels content), and both search queries hard-filter `event_type = 'm.room.message'`
(`search/db.ex:26,51`).

**4. Migration privileges, GRANTs and availability.**

- GRANT claim independently verified against MEMORY pattern #88 ("new migration with no GRANT to
  `nebu_app` silently fail-opens in prod"): `000001_init.up.sql:672` issues
  `GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO nebu_app` at line 672,
  and `events` is created at line 211 of the SAME file — so the snapshot grant does cover it, and
  this migration creates no table and no sequence. No GRANT is required. The migration's own test
  executes the script through `Nebu.Repo` (the `nebu_app` role), which incidentally proves the
  grant rather than assuming it.
- The migration reads only `rooms` and `events` and writes only `events`. No credential, config,
  user, device or audit table is touched. `events` has no RLS policy and no append-only trigger,
  so neither the up INSERT nor the down DELETE fights a DB-level guard.
- Query plan: the `NOT EXISTS` probe is exactly covered by
  `events_room_state_idx (room_id, event_type, state_key, origin_server_ts DESC) WHERE state_key IS NOT NULL`;
  the creator `LATERAL` is served by `events_room_id_ts_idx (room_id, origin_server_ts)`. Cost is
  O(rooms × log events), not a cross product.
- Locking: `Nebu.Release.apply_migration/3` wraps each file in one transaction (`release.ex:168`).
  The INSERT takes `RowExclusiveLock` on `events` (compatible with concurrent reads and inserts)
  and `FOR KEY SHARE` on each referenced `rooms` row via the FK (compatible with non-key UPDATEs,
  which is all `UPDATE rooms SET power_levels_json/name/...` ever does). No `ACCESS EXCLUSIVE`
  lock, no index build, no table rewrite. No availability concern beyond a single transaction
  whose duration scales linearly with room count.
- `sha256(bytea)` is core PostgreSQL 11+; the project runs `postgres:16-alpine`. The base64
  translation (`encode` → strip `\n` → `translate('+/','-_')` → `rtrim('=')`) correctly reproduces
  `Base.url_encode64(_, padding: false)` for a 32-byte digest.

**5. Standard sweep — injection, authz, audit.**

- *Injection:* the migration is static SQL with zero parameters and zero user input. `content` is
  `r.power_levels_json::jsonb` — a server-written column with a single writer
  (`db.ex:403`, always `Jason.encode!/1` output), `NOT NULL DEFAULT '{}'`, so the cast cannot
  abort the deploy on malformed text. The cycle-1 concern about relying on `AND` short-circuit
  ordering is moot: the `<> '{}'::jsonb` clause was removed per AC2 addendum 3, and the remaining
  `IS NOT NULL AND <> ''` guards are both type-safe. All new runtime SQL is parameterized via
  `Ecto.Adapters.SQL.query/3`.
- *Authz:* no permission or membership check was weakened. The two authorization helpers touched
  for tuple-shape compatibility stay fail-closed in every branch —
  `check_parent_space_membership/2` (`event_dispatcher/server.ex:2039-2062`) retains an explicit
  `{:error, _reason} -> raise not_found` clause alongside `{:error, :not_found}`, so a transient
  DB error denies rather than permits; `parent_space_create_event_exists?/1` (`:4727-4733`) ends in
  a `_ -> false` catch-all feeding a `with ... else _ -> false`. The `change_state` power check in
  `handle_call({:set_power_levels, ...})` is unchanged and still runs before any write.
- *Audit:* no new audit action is introduced, so `AuditWriter.@known_actions` correctly needs no
  update — the new artifact is a Matrix room event, not an `audit_log` row. MEMORY pattern #49's
  trap ("merging branches that add audit actions silently breaks the audit trail") does not fire
  here. Checked explicitly rather than assumed.

---

### INFO — recorded for future reviews, no action required now

**INFO-1 — Backfill attribution is accurate today and becomes wrong the day `SetPowerLevels` gets
a route.** The migration's `sender = room creator` / `ts = rooms.created_at` is correct only
because no shipped endpoint can change a room's power levels after creation. The proto
(`core.proto:354-359`), the handler (`event_dispatcher/server.ex:1412`) and the `change_state`
check all anticipate one. The backfill itself is a one-shot and post-deploy changes emit real
events, so no retroactive corruption is possible — but if a future story ever re-runs or re-derives
this backfill against a database where power levels HAVE changed hands, the event log would assert
that the room creator authorized a third party's escalation, at room-creation time. For a
compliance-native product that is a repudiation surface. Pin the backfill to this one deploy; do
not generalize the pattern.

**INFO-2 — Migration-origin event rows are structurally distinguishable from signed ones; register
the sink before it exists.** These rows carry (a) a `signatures` value that is not an Ed25519
signature and (b) an `event_id` not reproducible by `EventId.generate/1` (architecture rule #7).
Nothing consumes either today — this is MEMORY pattern #86's exact shape (persisted-but-not-yet-
reflected). The moment any feature verifies event integrity — compliance export signing, a
tamper-detection sweep, event-log attestation, or federation if it is ever reconsidered — these
rows must be handled explicitly, or they will read as tampered. The `nebu_backfill_migration`
marker is the right discriminator and should be the documented contract for that future consumer,
not just a `.down.sql` selector.

**INFO-3 — Power-level changes still produce no `audit_log` entry.** Pre-existing, not introduced
here (grep for `power_level` across `lib/nebu/compliance/` and `lib/nebu/admin/` returns nothing).
Worth naming now because this diff is the first time the project treats a power-levels change as a
first-class recorded artifact. If `SetPowerLevels` is ever routed, the admin-facing privilege
change should land in `audit_log` with a new `@known_actions` entry at the same time the route is
written — MEMORY pattern #49's standing rule.

**INFO-4 — Follow-up already flagged in-tree, repeated here so it is not lost.**
`initial_sync_state_event/3` (`protected.ex:800-824`) still synthesizes a fake `event_id` and a
`now` `origin_server_ts` for `/rooms/{roomId}/initialSync` and `/rooms/{roomId}/members`, even
though real identity is now available on `se`. The comment correctly documents this as deliberate
and out of scope. It is the same semantic-correctness defect this bug fix exists to close, now
surviving only on two other endpoints.

---

### Summary

CRITICAL: 0 — nothing blocks the commit
HIGH: 0 — nothing blocks the commit
MEDIUM: 1 — advisory, address before epic end (Finding #1)
LOW: 3 — advisory (Findings #2, #3, #4)
INFO: 4 — recorded for the audit trail and future reviews

**Verdict:** APPROVED.

The specific worries the review was commissioned on — migration-forged provenance, a
`signatures`-marker collision, a stale-`event_id` race, new information disclosure through
`m.room.power_levels`, migration-time privilege or availability abuse, and an audit-allowlist
regression — were each investigated to a concrete mechanism and each came back clean. The one
real finding is adjacent to, not inside, those: the fail-open branch in `set_power_levels` keeps an
identity the server already knows is wrong instead of admitting it does not have one, and because
the two writes are not transactional that lie persists in the database across restarts.
