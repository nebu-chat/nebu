## Session — bugfix-unsigned-replaces-state (security-review, staged diff)

**Scope:** 13-file staged diff implementing Matrix CS API v1.19 `unsigned.replaces_state`
(proto/core.proto, lib/pb/core.pb.ex, matrix/event_dispatcher/server.ex, matrix/http.ex,
matrix/room/db.ex, matrix/room/server.ex, migration 000036 up/down, 5 test files).
Reviewed on branch `bugfix/upcloud-s3-iam-sts-endpoints`. Report:
`docs/stories/security-reports/bugfix-unsigned-replaces-state-security-review-2026-10-07.md`.

**Finding summary:** 0 CRITICAL, 0 HIGH, 2 MEDIUM, 4 LOW, 2 INFO. Verdict APPROVED.

- F-1 MEDIUM — migration 000036's inclusion list (`m.room.message` only) leaves pre-fix
  `state_key=''` rows of STATE-typed events authoritative in `get_room_name/1`,
  `get_generic_state_events/1`, `Admin.DB.get_space/1`. Remediation = operator DETECTION query
  + manual review, NOT a wider blind `IN (…)` list.
- F-2 MEDIUM (PRE-EXISTING, not closed by this diff) — `search/db.ex:34,62`
  `(enc.state_key = '' OR enc.state_key IS NULL)` matches the NEW NULL shape too, so
  `PUT …/send/m.room.encryption/{txnId}` by any PL-0 member permanently disables compliance
  search for a room. Needs its own bugfix: deny `m.room.encryption` in `send_event/2`, then
  tighten the predicate to `= ''` (in that order — never the predicate alone).
- F-3 LOW `get_room_create_event/1` no state_key filter (safe only via `ORDER BY ts ASC`).
- F-4 LOW `@sql_member_identities` no state_key filter.
- F-5 LOW unbatched full-table UPDATE in a boot-time migration (+ rolling-deploy window).
- F-6 LOW unbounded UNNEST array on the `/sync` state path (other 3 call sites capped at 100).
- F-7/F-8 INFO (down-migration re-corruption, Postgrex error in Logger.warning — both benign).

**New patterns discovered:** two, curated into MEMORY.md (#96, #97).

**Accepted risks this session:** none.

**Follow-up:**
1. F-2 as its own `/nebu-pipeline --bug` — behaviour change to a security control, must not ride
   this story.
2. F-1's detection query into the migration header + release notes before any traffic-carrying
   deployment upgrades.
3. F-3/F-4 to batch with MEMORY #91's two parked `room/db.ex` LOWs.
4. The commit message should state this is a SECURITY fix (P-1), not only a v1.19 compliance fix.
