# Security Review — bugfix-unsigned-replaces-state

**Reviewer:** Kassandra (nebu-agent-kassandra, `security-review`)
**Diff scope:** `git diff --staged` — 13 files implementing Matrix CS API v1.19 `unsigned.replaces_state`
(`proto/core.proto`, `server/lib/pb/core.pb.ex`, `server/lib/nebu/matrix/event_dispatcher/server.ex`,
`server/lib/nebu/matrix/http.ex`, `server/lib/nebu/matrix/room/db.ex`,
`server/lib/nebu/matrix/room/server.ex`,
`server/priv/migrations/000036_backfill_nonstate_events_null_state_key.{up,down}.sql`, 5 test files)
**Branch:** `bugfix/upcloud-s3-iam-sts-endpoints`
**Date:** 2026-10-07

---

## Headline

**No CRITICAL and no HIGH finding in the staged diff. Verdict: APPROVED.**

More than that: **this diff silently closes a pre-existing HIGH-severity state-forgery
primitive** that nobody in three code-review cycles named as such. The `do_send_event/7`
`state_key || ""` → `state_key` change (cycle 2) is not only the enabling fix for
`is_state_event` — it is the fix for a live privilege-escalation class on `main` today.
See *Positive finding P-1*.

The findings below are the residue that fix does **not** reach, plus three same-class
latent queries elsewhere in `room/db.ex`.

---

## Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| F-1 | MEDIUM | `server/priv/migrations/000036_…up.sql:151-156` | Migration's inclusion list (`m.room.message` only) leaves pre-fix `state_key = ''` rows of **state-typed** events authoritative in `get_room_name/1`, `get_generic_state_events/1`, `Nebu.Admin.DB.get_space/1` — a row planted before the deploy keeps granting room-rename / join_rule / history_visibility / E2EE-flip forgery | Ship an operator **detection** query + documented review step; do not widen the blind migration |
| F-2 | MEDIUM | `server/lib/nebu/matrix/search/db.ex:30-35, 58-63` (PRE-EXISTING, NOT closed by this diff) | `(enc.state_key = '' OR enc.state_key IS NULL)` matches the *new* NULL shape too, so any PL-0 joined member can permanently disable server-side compliance search for a room with one `PUT …/send/m.room.encryption/{txnId}` | Add the `m.room.encryption` guard to the non-state `send_event/2` path (MEMORY #72's own rule); tighten the search predicate to `enc.state_key = ''` |
| F-3 | LOW | `server/lib/nebu/matrix/room/db.ex:838-847` (`get_room_create_event/1`) | No `state_key` filter at all — same bug class as the cycle-2 `get_room_name/1` regression; non-exploitable today **only** because of `ORDER BY origin_server_ts ASC LIMIT 1` + server-assigned timestamps | Add `AND state_key = ''` |
| F-4 | LOW | `server/lib/nebu/matrix/room/db.ex:26-31` (`@sql_member_identities`) | No `state_key IS NOT NULL` filter; a forged `/send/m.room.member/…` row now forms its own `NULL` `DISTINCT ON` group | Add `AND state_key IS NOT NULL` |
| F-5 | LOW | `server/priv/migrations/000036_…up.sql:151-156` | Unbatched full-table `UPDATE events` inside a boot-time migration transaction (`Nebu.Release.migrate/0`) — startup stall, WAL burst and table/index bloat proportional to total message count | Batch, or document expected runtime + an out-of-band run procedure |
| F-6 | LOW | `server/lib/nebu/matrix/room/db.ex:1318-1352` (`fetch_replaces_state/1`) | UNNEST array length is unbounded on the `/sync` state path (one slot per member + per generic state event, per room, per sync); `/messages`, `/event/{id}`, relations are capped at 100 | Chunk `slots` (e.g. 1000) before the query, or assert the room-size cap covers it |
| F-7 | INFO | `server/priv/migrations/000036_…down.sql:38-45` | Rollback re-corrupts correctly-NULL `m.room.message` rows written after the fix, re-admitting the newest message per room into `get_generic_state_events/1` as a bogus state event | Already documented loudly; optionally gate behind an explicit operator flag |
| F-8 | INFO | `server/lib/nebu/matrix/room/db.ex:1354-1364` | `Logger.warning(… inspect(reason))` can surface a `Postgrex.Error` carrying the static SQL text | Acceptable — no bound parameters, no PII, no secrets reach the log |

---

## Detail

### F-1 — Migration 000036's inclusion list leaves the dangerous half uncorrected [MEDIUM]

**What was asked (review brief question 6):** *does leaving `m.reaction` and other non-`m.room.message`
non-state types in their corrupted `state_key = ''` form have any security implication beyond
"cosmetic/non-destructive"?*

**Answer: for `m.reaction` specifically — no, the code-review's classification is correct.
For the type class as a whole — yes.** No state-derivation query in `lib/` reads `m.reaction`,
so a corrupted reaction row is genuinely inert. But the inclusion list does not distinguish
"inert non-state type" from "state type that was written through the non-state path", and the
latter is the row that matters.

The corruption vector is the generic non-state endpoint
`PUT /_matrix/client/v3/rooms/{roomId}/send/{eventType}/{txnId}`
(`protected.ex:681-709`). Traced end to end, pre-fix:

1. `protected.ex:695-702` builds `%Core.SendEventRequest{is_state_event: false}` — the client
   never controls that flag (verified: this is the **only** construction site of
   `Core.SendEventRequest` in `lib/`), but it also controls `event_type` **with no allowlist and
   no denylist anywhere on this path**.
2. `event_dispatcher/server.ex:167-169` → `state_key = nil`; membership check only.
3. `room/server.ex:465` → `power_level_action = :send_event` → `events_default = 0` → **any joined
   member passes**.
4. Pre-fix `room/server.ex:700` → `"state_key" => state_key || ""` → `insert_event/1` persists the
   literal `''`.
5. `''` is `NOT NULL`, so the row is picked up by every state-derivation query in the codebase.

Consumers that then treat the forged row as the room's authoritative state:

| Query | Filter | Authorization-relevant consumer |
|---|---|---|
| `Room.DB.get_room_name/1` (db.ex:965-972) | `state_key = ''` | room name for every member — the bypass cycle 3 closed |
| `Room.DB.get_generic_state_events/1` (db.ex:1388-1402) | `state_key IS NOT NULL` | `JoinRules.check_join_allowed/3` (`join_rules.ex:130-139`) — **`restricted` join-policy bypass**; `room_visible?/3` (`server.ex:2301-2305`) — **private room's summary exposed to non-members via `join_rule == "public"` or `history_visibility == "world_readable"`**; `m.room.encryption` → Element flips to Megolm → **ADR-011 managed decryption broken** |
| `Nebu.Admin.DB.get_space/1` (admin/db.ex:682-688) | `state_key = ''` | `m.room.topic` shown in the Admin UI |
| `@sql_power_levels_identity` (db.ex:40-44) | `state_key = ''` | identity only (`event_id`/`sender`), not the PL table — integrity, not escalation |

**What the diff fixes:** step 4. Post-fix the row persists as SQL `NULL`, which fails
`state_key = ''` **and** `state_key IS NOT NULL`. Every row in the table above stops matching.
I verified this independently rather than trusting cycle 3's trace, and it holds for all four
consumers, not just `get_room_name/1`. The regression test at
`matrix_client_compat_test.exs:2599-2640` is well-targeted (it asserts the bypass endpoint still
returns 200 *and* that the name does not change — i.e. it proves closure, not merely absence).

**What the diff does not fix:** rows already in the table. Migration 000036's inclusion list is
exactly `('m.room.message')`, so a `m.room.name` / `m.room.join_rules` /
`m.room.history_visibility` / `m.room.encryption` row planted through `/send/…` **before** the
deploy keeps its `state_key = ''` and stays authoritative forever.

Cycle 3 was right to flip exclusion→inclusion: an exclusion list blindly destroys legitimate
custom state events, and that is the worse failure direction. The gap is not the design, it is
that the fail-safe design was shipped **without the compensating detection step**.

**Severity:** MEDIUM, not HIGH — post-deploy an attacker gains no new capability; exploitation
requires a row planted during the pre-fix window. For any deployment that has carried real
traffic, treat it as a data-remediation item with a deadline, not as "nothing to do".

**Remediation (concrete):** add to the migration header, and to the release notes, this
operator detection query — it is read-only and safe to run before and after the deploy:

```sql
SELECT room_id, event_type, state_key, event_id, sender, origin_server_ts
FROM events
WHERE state_key = ''
  AND event_type IN ('m.room.name','m.room.topic','m.room.join_rules',
                     'm.room.history_visibility','m.room.canonical_alias',
                     'm.room.avatar','m.room.guest_access','m.room.encryption',
                     'm.space.child','m.space.parent')
  AND event_id NOT IN (
        -- rows whose slot was also legitimately written at least once; manual review
        SELECT event_id FROM events WHERE false
      )
ORDER BY room_id, event_type, origin_server_ts DESC;
```

Every row returned must be reviewed by hand against that room's `:change_state` power level at
the time it was written. There is no stored discriminator between a `/state/` write and a
`/send/` write — that is precisely why a blind migration must not guess, and why a human gate is
the correct remediation rather than a wider `IN (…)` list.

### F-2 — The non-state `/send` path is the fourth E2EE write path, and `search/db.ex` still honours it [MEDIUM, PRE-EXISTING]

MEMORY #72's rule reads: *"the E2EE-off invariant must be enforced on EVERY path that can write
a state event into `events`."* Three paths enforce it:

* `protected.ex:1871-1872` — `PUT /state/m.room.encryption/…` → 403
* `@initial_state_forbidden_types` (`server.ex:4955`) — createRoom `initial_state`
* `copy_state_events` (`server.ex:5106-5113`) — room upgrade excludes it

The fourth path — `PUT …/send/m.room.encryption/{txnId}` — has **no guard at all**
(`send_event/2`, `server.ex:156-218`, and `Room.Server.handle_call({:send_event, …})`,
`room/server.ex:453-499`, both verified: membership + power level only, zero event-type checks).

Before this diff that was a full HIGH (see P-1). After this diff the `/sync` leg is closed —
the row persists NULL, `get_generic_state_events/1`'s `state_key IS NOT NULL` drops it, and
`Http.put_state_key/2` omits `state_key` on the timeline copy, so no Matrix client will treat it
as state. **But `search/db.ex` is the one query in the codebase that deliberately accepts both
shapes:**

```sql
AND enc.event_type = 'm.room.encryption'
AND (enc.state_key = '' OR enc.state_key IS NULL)   -- db.ex:34 and :62
```

The `OR … IS NULL` arm matches the new, post-fix forged row exactly. Net effect: any joined
member at `events_default = 0` can, with one request and no special privilege, **permanently and
irreversibly disable server-side full-text search for an entire room**. Nebu implements no
redaction endpoint and no event-delete path, so there is no way to undo it from the API.

For a product positioned as compliance-native, server-side message search is a compliance
control, and a low-privilege user silently switching it off in a room is discovery evasion — not
merely a feature outage. The failure direction is fail-closed (less data returned, not more),
which is why this is MEDIUM rather than HIGH.

**Remediation:**
1. Add `m.room.encryption` to a denylist in `send_event/2` (`server.ex`, before the
   `Room.Server.send_event/6` call) — this is the missing fourth enforcement point MEMORY #72
   already prescribed, and it is a one-line change with a one-line test.
2. Tighten `search/db.ex:34` and `:62` to `AND enc.state_key = ''`. The `OR … IS NULL` arm only
   ever matched corruption; once (1) and the `do_send_event/7` fix are both in, it has no
   legitimate row to match.

Do **not** ship (2) without (1): removing the `IS NULL` arm alone would turn the search-disable
primitive back into a search-stays-enabled-while-clients-encrypt state, which is worse.

### F-3 — `get_room_create_event/1` has no `state_key` filter [LOW]

```sql
WHERE room_id = $1 AND event_type = 'm.room.create'
ORDER BY origin_server_ts ASC LIMIT 1
```

Same class as the cycle-2 `get_room_name/1` regression, and the only member of the
`build_state_events/2` identity-query family with no `state_key` predicate at all. It is not
exploitable today, and the reason is worth recording precisely because it is accidental: the
ordering is `ASC` (oldest wins) and `origin_server_ts` is server-assigned
(`Nebu.DB.Helpers.now_ms()`), so a forged `/send/m.room.create/…` row can never sort ahead of the
genuine create event. The create content feeds `room_type_from_create/1` (space-vs-room
classification) and the `m.room.create` entry in `/sync` state.events.

**Remediation:** `AND state_key = ''`. Defense in depth — the day someone changes that `ASC` to
`DESC` (e.g. "support room-version upgrades in place"), this reopens with no test to catch it.

### F-4 — `@sql_member_identities` has no `state_key` predicate [LOW]

```sql
SELECT DISTINCT ON (state_key) state_key, event_id, origin_server_ts
FROM events WHERE room_id = $1 AND event_type = 'm.room.member'
ORDER BY state_key, origin_server_ts DESC
```

A forged `/send/m.room.member/…` row now lands with `state_key = NULL` and forms its own
`DISTINCT ON` group. Inert: the consumer (`Room.Server.do_init/1`'s `member_identity` map) keys
by Matrix user id, and no real user id is `nil`. Membership itself is GenServer-authoritative
(MEMORY #68), so there is no forgery here either way. Flagged only to keep the family complete.

**Remediation:** `AND state_key IS NOT NULL`.

### F-5 — Unbatched full-table UPDATE in a boot-time migration [LOW]

`UPDATE events SET state_key = NULL WHERE state_key = '' AND event_type IN ('m.room.message')`
rewrites **every historical message row** in a single transaction. `Nebu.Release.migrate/0` runs
migrations at release start (`release.ex:47`, `183-185`), so on a deployment with millions of
messages this is a multi-minute startup stall plus a WAL burst and heavy dead-tuple churn.

Two mitigating facts verified: (a) no concurrent writer updates `events`, so there is no lock
contention beyond `ROW EXCLUSIVE`, and (b) `events_room_state_idx` is `WHERE state_key IS NOT
NULL`, so the operation actually *shrinks* that index. The risk is availability at deploy time,
not correctness.

**Remediation:** either batch (`UPDATE … WHERE event_id IN (SELECT event_id … LIMIT 10000)` in a
loop with a `VACUUM` between) or add an explicit header note stating expected runtime by table
size and an out-of-band run procedure for large installations.

Related, same file: there is a **rolling-deploy window**. If the migration runs while an old node
is still serving, messages written by that node after the UPDATE scan keep `state_key = ''` and
stay misclassified. Consequence is bounded (one bogus `m.room.message` "state event" per room in
`/sync` state.events, plus a `replaces_state` pointing at another message the caller can already
read) — integrity, not authorization. Worth one sentence in the deploy runbook: migrate after the
last pre-fix node is drained, or re-run the (idempotent) UPDATE once afterwards.

### F-6 — Unbounded UNNEST array on the `/sync` state path [LOW]

`attach_replaces_state_to_state_events/2` (`server.ex:3245-3258`) builds one slot per
`Core.SyncRoomStateEvent`, i.e. `1 create + N members + 1 power_levels + name + generic`. For a
large room that is `N` slots in one `UNNEST`, with one index probe each, **per room, per
`/sync`** — and `get_initial_sync/2` fans this out across every joined room via
`Task.async_stream`. A user in 50 rooms of 5 000 members costs ~250 000 LATERAL probes per
initial sync, against a `/sync` tier of 600/min (and MEMORY #95: that tier is not actually
isolated — all tiers share one per-IP bucket).

The amplification is proportional to work `build_state_events/2` already does (it builds all
those structs regardless), so this is not a new order of magnitude — hence LOW. The other three
call sites are properly bounded: `/messages` clamps `limit` to 1-100 (`protected.ex:1948-1955`),
relations to 1-100, `/sync` timeline to 20, `/event/{id}` to 1.

**Remediation:** `Enum.chunk_every(slots, 1000)` with a `Map.merge` fold inside
`fetch_replaces_state/1`, or document the room-size cap that makes it moot.

### F-7 / F-8 — INFO

**F-7:** the `.down.sql` re-corrupts post-fix-correct NULL `m.room.message` rows. Its own header
documents this at length and scopes it to a same-deploy-window emergency. The security effect of
running it late is that the newest message per room re-enters `get_generic_state_events/1` as a
bogus state event — integrity/cosmetic, no authorization consequence. Accept as documented.

**F-8:** `Logger.warning("fetch_replaces_state: … #{inspect(reason)}")` — a `Postgrex.Error`
carries the static SQL string but **not** the bound parameters, so no `event_id`, `room_id` or
`state_key` reaches the log from this site. Acceptable. The log-level split (warning for a real
DB error in `Room.DB`, debug for the expected FakeDB/no-Repo path in `EventDispatcher`) is the
right way round.

---

## Positive findings — verified clean, recorded for the audit trail

**P-1 — This diff closes a pre-existing HIGH that nobody named.**
On `main` today, `do_send_event/7`'s `state_key || ""` makes
`PUT …/send/{anyEventType}/{txnId}` a **generic state-event forgery primitive available to every
joined member at power level 0**. It bypasses `set_room_state/2`'s `@writable_state_types`
allowlist *and* its `:change_state` check, and reaches: room rename, `m.room.join_rules` (→
`restricted` membership-policy bypass), `m.room.history_visibility` (→ a private room's
name/topic/alias/member-count exposed to non-members through the space hierarchy), and
`m.room.encryption` (→ ADR-011 managed decryption broken). Cycle 2 found the *symptom*
(misclassified messages leaking `state_key`); the same one-character fix closes the
privilege-escalation class. This should be called out in the commit message — operators need to
know this is a security fix, not only a v1.19 compliance fix.

**P-2 — `is_state_event` trust boundary is sound (review brief question 3).**
Set in exactly one place, `event_map_to_core_event/1` (`server.ex:1418`), as
`Map.get(event, "state_key") != nil` — the nil-ness of the raw `events.state_key` column, read
back out of Postgres. It is never read from a request, never defaulted from a client value, and
`Core.Event` is a plain Elixir struct with no wire decoding (`lib/pb/core.pb.ex` is hand-written
`defstruct`, no `use Protobuf`), so there is no deserialization path by which a client could
inject it. The sibling `Core.SendEventRequest.is_state_event` *is* a request field, but its only
construction site in `lib/` is `protected.ex:695-702`, which hardcodes `false`. No spoofing path.
Proto field numbers 10/11 on `Event` are fresh — no collision.

**P-3 — `fetch_replaces_state/1` is injection-free and room-isolated (question 5).**
All five inputs are bound parameters (`$1::text[]` … `$5::bigint[]`); nothing is interpolated
into the SQL. The five arrays are built in one `Enum.reduce`, so they are always equal length —
no `UNNEST` NULL-padding skew. The LATERAL pins `e2.room_id = req.room_id`, and `req.room_id`
originates either from the room currently being serialized for an authorized member
(`attach_replaces_state_to_state_events/2`) or from the event row itself, which was fetched
through an already-membership-scoped query (`fetch_events/4`, `fetch_event/2`,
`fetch_events_by_relation/5` — all take `room_id`). No cross-room result is reachable; no IDOR.
Result rows are joined back by `event_id` (a primary key), so no mis-attribution.

**P-4 — `replaces_state` leaks nothing beyond spec (question 4).**
The field carries only an `event_id` from the *same room* at the *same slot*. Nebu enforces no
history-visibility gate on `/messages` or `/event/{eventId}` (verified: `get_event/2` checks
`MapSet.member?(state.members, user_id)` only; `history_visibility/1` is consulted solely by
`room_visible?/3` for space-hierarchy exposure), so a joined member can already fetch any event
in the room, including pre-join ones and redacted ones. `replaces_state` therefore grants no
read the caller did not already have. AC4's "not visibility-gated" is both spec-mandated and,
here, informationally free.

**P-5 — Migration 000036's GRANT reasoning is correct (question 2).**
Verified independently rather than from the header comment: `events` is created at
`000001_init.up.sql:211` and the blanket `GRANT … ON ALL TABLES IN SCHEMA public TO nebu_app` is
at line 672 of the *same* file, so `events` is covered — MEMORY #88's post-000001 new-table GRANT
trap does not fire, and the migration creates no table or sequence of its own. It runs as
`NEBU_DB_URL_MIGRATE` (`release.ex:183`), falling back to `NEBU_DB_URL`; both roles can execute
it. The SQL is fully static — no parameters, no interpolation, no injection surface. It is
genuinely idempotent (its own `WHERE` clause is self-extinguishing). No privilege escalation, no
new grant, no RLS interaction (`events` has neither RLS nor an append-only trigger, MEMORY #90).

---

## Summary

CRITICAL: 0 — commit not blocked
HIGH: 0 — commit not blocked
MEDIUM: 2 — F-1 (advisory, remediate before epic end), F-2 (pre-existing, raise as its own bugfix)
LOW: 4 — F-3, F-4, F-5, F-6
INFO: 2 — F-7, F-8

**Verdict: APPROVED.**

### Recommended follow-ups (not blocking this commit)

1. **F-2 is its own `/nebu-pipeline --bug`:** `m.room.encryption` must be denied on the non-state
   `send_event/2` path. It is a behaviour change to a security control and must not ride along on
   this story (MEMORY #95's own rule).
2. **F-1's detection query** belongs in the migration header and the release notes before this
   ships to any deployment that has carried production traffic.
3. **F-3 / F-4** are a two-line batch for the next `room/db.ex` touch — together with the two
   sibling LOWs MEMORY #91 already parked there.
4. The commit message should say this is a **security fix**, not only a v1.19 compliance fix
   (P-1).
