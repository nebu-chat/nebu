## Security Review — sync-stream-position (follow-up `fc` story 2 of 2, REQ-2026-003, epic oauth-broker)

**Diff scope:** staged diff in worktree `open-chat-oauth` (branch `feature/migrate-to-oauth2`, HEAD `e066d6f3`). It covers migration `000054_sync_room_cursors` (up/down), the new `Room.DB` reads (`room_heads/3`, `fetch_visible_events_in_range/5`, `fetch_visible_events/6` head bound, `leave_window_events/5`, `room_pos` in `latest_member_events/2`, `pagination_token/1`) and `Session.PgStore` + `Postgres` (`get_since_token` era columns, `get_positions/3`, `persist_sync_position/3`: guarded UPDATE + one unnest cursor statement in one transaction). In `EventDispatcher.Server` it covers the `s2_` nonce, `base_generation/2`, `cursor_base/2`, `write_cursor?/3`, `build_delta/3`, `fetch_delta_rooms/4`, `delta_events!/4`, `visible_range!/5`, `invite_new?/2`, `leave_new?/2`, `build_leave_room/3` by positions, `initial_delivery/3`, `persist_position!/3` and per-room D13. In `Router.Protected` it covers `get_positions/3` and `newly_joined_room_ids` from the core. Also in scope: proto field 7, docs and tests.
**Date:** 2026-10-27

### Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| 1 | MEDIUM | `server/lib/nebu/matrix/room/db.ex:2810-2830`, `server/lib/nebu/matrix/event_dispatcher/server.ex:6397-6403`, `:6131-6135` | CWE-400 / CWE-405. The incremental range read scans by position and filters each row ("scan the room in order and filter"). When a joined room has no base (newly joined, or replayed previous token with `prev_pos` NULL), it reads `(0, head]` with no statement timeout. A room where the viewer sees fewer than 21 events (hv `joined`/`invited`, few events since the join) costs a full backward scan with heap fetches of the room's whole positioned history. Replaying the previous `next_batch` makes this repeatable without bound. | For a room without a base, use the segment-driven initial page read (`fetch_visible_events/6` with the head bound, as D9 says: "as an initial-sync room"). Also run the range read under `with_read_timeout/1` (2 s), or make it segment-driven too. |
| 2 | LOW | `server/lib/nebu/matrix/session/pg_store/postgres.ex:46-61, 270-273` (`:initial` mode) | CWE-459 / data-retention residual of `cj` (a). The initial/fallback persist is an unconditional UPSERT of the token row, followed by inserting one cursor row per partition room. If logout, `/logout/all`, deactivation or GDPR erasure runs while the user's own initial sync is in flight, the commit re-creates a `sync_tokens` row and now also N `sync_room_cursors` rows (user id + the user's room ids). These rows belong to a deleted device or an erased user, and no cleanup path removes them. | Make the initial insert conditional on the session/device still existing (and on the user not being erased) in the same transaction, e.g. `INSERT ... SELECT ... WHERE EXISTS (...)`, answering `:stale` otherwise. Or record it explicitly on `cj` (a) / `ck` as accepted for the initial path. |

INFO observations (no severity, not blocking) are listed below.

### Detail

**Finding #1 — Unbounded filtered range scan, repeatable through the previous token** [MEDIUM]
`fetch_visible_events_in_range/5` is `WHERE e.room_id = $1 AND e.room_pos > $3 AND e.room_pos <= $4 AND <@sql_hv_visible> ORDER BY e.room_pos DESC LIMIT 21`. It walks `events_room_pos_idx` backwards, fetches every heap row, judges it with the hv predicate and stops only after 21 VISIBLE rows. Before this story, `read_visible_since` was segment-driven, and the DB module's own comment calls that out as a property: "never scan the room in order and filter: a backward page of a `joined` room never reads the invisible history before the viewer's join". The new read gives that property up. `delta_events!/4` uses `after_pos = 0` when the base is nil. `visible_range!/5` runs without `with_read_timeout` (no `statement_timeout`).
Exploit: an authenticated user joins (or creates and fills) a room with history visibility `joined` and a large positioned history, then lets it go quiet. On the next delta the room is "newly joined" (base nil), so the read is `(0, head]`. Only the join event and a few later events are visible, so the scan covers the whole history. The user then keeps presenting the PREVIOUS `next_batch` T1. `base_generation/2` answers `:previous`. `cursor_base/2` answers nil for the row created in the replaced generation (`gen == generation`, `prev_pos` NULL), so the full scan runs again. `write_cursor?/3` re-bases that row with `prev_* := nil` and `gen := g+1`, and the guarded UPDATE sets `prev_since_token := T1` again. So T1 stays a valid previous token on every replay, and each replay repeats the full scan. This is bounded only by the `/sync` rate limit (600/min per IP) and the pool size: one user can keep several of the 10 pool connections busy with long scans. No data is disclosed: the hv predicate is applied per row.
Fix: (a) for `base == nil`, call `visible_page!(room_id, viewer, "b", 20, "", head: head)` (segment-driven, head-bounded; already used by the initial sync), and reuse its `prev_batch`/`limited`. (b) Wrap `visible_range!/5` in `with_read_timeout/1`, so a slow room is the handled 503 rather than an unbounded statement. Optionally (c), lower-bound the range for a joined base whose class is not `join` by the viewer's join position.

**Finding #2 — Initial-mode upsert resurrects token + cursor rows after teardown/erasure** [LOW]
The delta path is now correct: it never inserts (guarded UPDATE, `:stale` on 0 rows, D20 (4)). The `:initial` path still upserts unconditionally. An initial sync or fallback reads the partition and the room pages (it can take seconds). A device teardown or `end_sessions_after_erasure/1` that commits in that window is undone by the commit: the user's room ids are written again under a deleted key. The FK only requires the `sync_tokens` row, which the same transaction re-creates. The pre-existing `cj` (a) race already left an orphan token row (user id, `last_event_id`). This story adds the room-membership list to it. It is not exploitable by a third party, and the window is narrow (the user's own request concurrent with their logout or erasure). For a compliance-native product it is still a retention gap: a later re-login with the same device id would also pick up the orphan row (an initial sync deletes and rewrites it, so there is no disclosure).

### Verification of the focus areas

1. **Token trust (D18).** The `s2_` nonce is `Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)` (128 bit, no user/event/position, no `.`). `base_generation/2` (`server.ex:6011`) matches it ONLY against the row returned by `get_since_token(user, device)` / `(user)` of the AUTHENTICATED key. To match, a token needs the `s2_` prefix (function-head pattern), `stream_version == 1` (`Map.get` default 0), and must equal `since_token` (current) or the binary `prev_since_token` (previous). Another device's or user's current/previous token, a forged `s2_`, an old base64 token and a `stream_version 0` row all give `:none` → `fallback_to_initial_sync/2`. That path writes only the caller's key (`:initial` mode, every statement keyed `$1/$2`). `get_positions/3` selects the previous positions only for `core_token == prev and != current`, on the caller's own row. The token is not a credential: every path is behind `OidcPlug`. The guarded UPDATE compares the client's token as a bound parameter (`$3`), never interpolated. Replaying the previous token re-reads only the caller's own deliverable events, and every read is re-judged against the CURRENT partition and visibility. It cannot skip another party's data or expose anything new (see INFO-1 for its indefinite validity).
2. **Cursor tables / IDOR.** `room_heads/3` joins `sync_room_cursors c ON c.user_id = $2 AND c.device_id = $3`. `user_id`/`device_id` come from `request.*`, which the HTTP layer fills from `conn.assigns` (unchanged since `fd`). The room ids come from the caller's own partition (`room_heads!/3` filters `class != :none`). `persist_sync_position/3` keys the UPDATE, the DELETE and the INSERT on `$1/$2`. The `room_id`s written are partition rooms only (`after_values` iterates the partition). No request input reaches a cursor. FK `(user_id, device_id) → sync_tokens ON DELETE CASCADE`: device teardown (`postgres.ex` DELETE by `(user, device)`), `/logout/all` and deactivation (`DELETE ... WHERE user_id = $1`) and GDPR erasure (`end_sessions_after_erasure/1` deletes `sync_tokens`) all remove the cursors. `ck` is NOT made worse by the table itself: it is covered by the cascade. The residual is Finding #2.
3. **History visibility / leave window / invites.**
   - The join range read applies `@sql_hv_join` + `@sql_hv_visible` per row (special events by their D5 verdict, others by segment; no verdict = FALSE). The head-bound initial page only adds a restriction (`room_pos <= head OR room_pos IS NULL`) in both UNION branches. A base of class `leave`/`invite` gives a range starting at the old head; the events in between are still hv-filtered, with the same verdict `/messages` would give.
   - Leave window: `room_pos > max(base.pos, P.room_pos) AND room_pos < L.room_pos AND origin_server_ts > joined_at AND origin_server_ts < left_at`. Nothing at or after L's position is ever read. `joined_at` is `NOT NULL` (000001) and reset on rejoin (`db.ex:57`), so the row clock lower bound is always present. A legacy P (NULL position) only drops a position bound that could not select pre-000053 events anyway (NULL `room_pos` never satisfies `>`). The bounds only shrink the window, as the security argument of the previous cycles requires.
   - Invites are taken from the partition only (ignored inviters stay class `:none`). The stripped `build_invite_rooms/2` is unchanged. A forgotten or un-ignored room has no base and is delivered once (D20 (2): the user's own decision). An invite room without a `rooms` row is never new (`Map.has_key?(heads, ...)`).
   - Key invariant: a wrong or stale cursor (the D21 (5) concurrent residual, a re-base error) can only cause re-delivery or loss of the caller's OWN visible events, never disclosure. Join reads are hv-filtered, and the leave window is clamped by L, P and the member-row clocks.
4. **Fail-closed / `:stale` / rollback.** A persist error (also a store without the callback, or an exception in the transaction) is a value-free ERROR line + `503 M_UNAVAILABLE`. Nothing is written (one transaction, `repo.rollback`), the old token stays valid. For `:stale` (the guard refused, or the device row is gone) nothing is written, the response is sent and the next request falls back. It never INSERTs on the delta path. A DB module without the position reads → 503 (`partition_read!`, `viewer_read` with an error fallback: no unfiltered read). `consistent_delivery/4` (re-read after the fetch, bounded rebuilds, 503) is kept and is also triggered by `moves_cursors?` (a superset of the old trigger).
5. **DoS / amplification.**
   - Statements: one `room_heads` for N rooms (PK lookup per room), one range read per MOVED room only, one guarded UPDATE, one unnest cursor statement whatever the room count (array params sized by the partition).
   - Cursor storage is one row per (device, partition room) without a cap (accepted, OQ4 / `cq` (d)). The real bound is joined/invited rooms × devices. Both are rate-limited (join/invite/createRoom limits, OIDC login), and the FK cascade cleans up (INFO-2).
   - Newest-20 truncation is bounded by `LIMIT 21`, but see Finding #1 for how long the scan behind it can be. The leave window has a simple `LIMIT 21` index range with no hv predicate.
   - Story-1 interplay: the read path takes no locks. The persist locks only the caller's own `sync_tokens` row (UPDATE row lock, short hold, no network call inside). It never touches the `rooms` row lock of the writers.
6. **Logging law.** The diff adds three log lines, all value-free: the `:stale` DEBUG line (static), the persist ERROR line (`db_error_class/1` yields only the pg code, exception module or atom, never a message or parameter) and the unresolved WARNING (count only). No token, cursor value, room/user id or content appears in them. The Task stacktrace keeps `strip_stacktrace_args/1`. `Nebu.Repo` `log: false` (no parameter logging of the arrays).
7. **OIDC scopes law.** Untouched (no OIDC/scope code in the diff).
8. **Migration 000054.** `GRANT SELECT, INSERT, UPDATE, DELETE ON sync_room_cursors TO nebu_app` is the minimal grant: no TRUNCATE, REFERENCES or TRIGGER, no ownership change. New columns inherit the `sync_tokens` grants. Constraints: PK `(user_id, device_id, room_id)`; the FK is the PK prefix, so the cascade uses the PK index. `gen`/`pos`/`class` are `NOT NULL`, the `prev_*` and `invite_marker` columns are nullable. The constant defaults are catalog-only. No RLS on `sync_tokens`, so none is needed on the child table (consistent with the parent, no RLS bypass). The migration is idempotent. The down migration drops the table first, then the columns.
9. **SQL injection / proto trust.** All values are bound. The only interpolations are compile-time fragments and the placeholder INDEX `$#{4 + length(cursor_params)}`, an integer computed from the code path, never a value. `room_heads` uses `ANY($1)`, the cursor write uses `unnest($5::text[] ...)`. Proto field 7 is an in-process `%Core.GetSyncDeltaResponse{}` built by the core from the caller's partition (`join_room_ids` with a non-`join` base). `Router.Protected` only passes it to `RoomAccountDataStore.list_for_sync(user, ...)`, which is keyed `WHERE user_id = $1` and restricted to rooms with `room_members ... left_at IS NULL` of that user. Even a wrong id could only select the caller's own room account data.

### Informational (no severity)

**INFO-1 — The previous token stays valid while it is replayed.** A previous-token request writes `prev_since_token := base`, so T1 survives every request made with T1. D8 says the previous token "is invalid as soon as a newer generation is written". That holds only when the client moves on to the new token. No security effect beyond Finding #1: the token is not a credential and everything it reaches is the caller's own. Doc wording only.

**INFO-2 — Cursor storage without a cap (accepted OQ4 / `cq` (d)).** Up to (partition rooms × devices) rows per user. The initial sync writes all of them in one statement. Both factors are rate-limited, and the rows cascade with the device. If device counts per user are ever unbounded (raw-JWT lazy binding, INFO-2 of the `fd` review), consider a per-user device cap rather than a cursor cap.

**INFO-3 — `class` has no CHECK constraint.** Only server code writes it (`Atom.to_string/1` of `:join | :invite | :leave`). An unexpected value would read as a class change: re-delivery of the caller's own data, no disclosure. `CHECK (class IN ('join','invite','leave'))` is cheap hardening.

**INFO-4 — D21 (5) concurrent same-base residual.** Two concurrent requests built from one base both pass the guard (current, then previous). The rows the second one does not rewrite keep the first one's advanced values under the second one's token, which can lose the caller's own events (correctness, `cj` (b), accepted). No cross-user or visibility effect, by the invariant in focus area 3.

### Summary

CRITICAL: 0 — block commit
HIGH: 0 — block commit
MEDIUM: 1 — advisory, address before epic end
LOW: 1 — advisory

**Verdict:** APPROVED (no CRITICAL/HIGH; MEDIUM-1 to be fixed or tracked as a follow-up before the epic ends)

## Delta review (cycle 1)

**Scope:** the staged diff after fix cycle 1 (dev report `_bmad-output/nebu/epics/oauth-broker/step-results/sync-stream-position/dev-report-cycle1.md`). The checks focus on `delta_events!/4` (new `base == nil` clause), `visible_page!/6` (`failure:`), the generation compare-and-set in `@advance_sync_generation_sql` (`postgres.ex:63-80, 283`; `server.ex:6123`), the CHECK constraints in `000054`, and the changed log lines.
**Date:** 2026-10-27

| # | Severity | Status | Location | Note |
|---|----------|--------|----------|------|
| 1 | MEDIUM | **CLOSED** | `server.ex:6415-6420` | A room without a base now uses `visible_page!(..., "b", 20, "", head: head, failure: :unavailable)` (`fetch_visible_events/6`). That read is segment-driven (one LATERAL index range per VISIBLE segment, `LIMIT` inside) and bounded by the head. It never walks the invisible history. |
| 1b | MEDIUM (new, residual of #1, recorded as `cq` (f)) | OPEN, non-blocking | `server.ex:6422-6426`, `db.ex:2810-2830` | The row-by-row range scan remains for a room WITH a base whose class is not `join` (re-join after leave, or join after invite). Replaying the previous token repeats it without bound. Details below. |
| 2 | LOW | ACCEPTED residual (`cj` (a) / `ck` notes) | `postgres.ex` `:initial` mode | Acceptance recorded. See (4). |
| INFO-3 | — | DONE | `000054...up.sql:30,33` | `CHECK (class IN ('join','invite','leave'))`; the same CHECK on `prev_class`, where NULL passes. |
| INFO-1 | — | DONE | story D8, `06-runtime.md`, `matrix-api-scope.md` | The wording now matches the behaviour. |

**(1) MEDIUM-1 closed. No unbounded scan is left for rooms WITHOUT a cursor.**
- For the replay path: `cursor_base/2` answers nil for a row of the replaced generation with `prev_pos` NULL. That nil is exactly the input of the new `base == nil` clause, so a replay of T1 now costs one segment-driven page read per replay. That is the same per-request cost as an initial-sync room, already accepted, and the 600/min `/sync` limit bounds it.
- The `head <= 0` clause (no positioned event) adds no statement.
- `{:error, :not_found}` cannot happen with `from_token = ""`. A read failure is the handled 503 (`failure: :unavailable`): nothing is persisted.

**Residual MEDIUM-1b — the range scan of a room WITH a non-`join` base (`cq` (f)).** I disagree with rating this INFO.
- Mechanism: a user who leaves a room has a base row `{pos: head_at_leave, class: "leave"}`. On re-join, `delta_events!/4` reads `(head_at_leave, head]` with `fetch_visible_events_in_range/5`. Under hv `joined` the whole time away is invisible, so the backward scan visits every row of that stretch. The same holds for invite → join under hv `joined`.
- Replay: the scan is not "once". With the previous token T1, `cursor_base/2` returns the row's `prev_*` (the leave base). `write_cursor?/3` re-bases the row with `prev_* := that base`, and the CAS update keeps `prev_since_token := T1`. Every replay of T1 repeats the full stretch scan, and there is no statement timeout.
- Conditions: a room with restricted hv and a long or busy absence (attacker-reachable: join a large public `joined` room early, leave, rejoin later; or fill an own room from a second account while away), then a replay loop. This is the same class and amplifier as MEDIUM-1 with one extra precondition, so MEDIUM is right, not INFO/LOW. It is acceptable as a TRACKED residual (non-blocking) only if `cq` (f) is resolved or explicitly owner-accepted before the epic gate.
- Fix suggestions, either of which is enough:
  - (a) Treat a base of class `invite`/`leave` like an absent base. The room is "newly joined" (it is already in `newly_joined_room_ids`). Use the segment-driven page read, adding a `room_pos > base.pos` bound (one more bound parameter in `read_visible_page`) so the device does not get duplicates.
  - (b) Clamp `after_pos` to the viewer's join position (`latest.room_pos` of the partition entry) only when the room's hv at that point is `joined`/`invited`.

**Not wrapping `visible_range!/5` in `with_read_timeout/1`: defensible** as a general rule (`gk` (4): a permanently slow room must not fail every member's `/sync`; a 503 loop would be worse than a slow answer). But then the scan itself has to be bounded by construction, which (a) above achieves. With the base-nil case fixed, the timeout is not needed for MEDIUM-1.

**(2) Generation compare-and-set: safe.**
- The guard is `AND ($7 IS NULL OR generation = $7)` on the row of the authenticated `(user_id, device_id)`. `$7 = ctx.generation` is read from the caller's own row at request start, always set by the dispatcher, and is a bound parameter.
- A client can force `:stale` only by racing two requests of its OWN device. The result is its own one-time fallback (an initial sync). A forged token already gives the same capability, so the CAS adds no new self-DoS lever, and the per-IP `/sync` limit still bounds it. No cross-user or cross-device effect: the key is the authenticated one, and other rows are untouched.
- Replay semantics are unchanged: a sequential retry with T1 reads and writes the same generation, so the CAS passes. A long-poll overtaken by another request of the same device becomes `:stale`: nothing is written, and the next request falls back instead of losing events.
- It closes the INFO-4 own-event loss of cycle 0.

**(3) hv safety of the base-nil page read.** It is the same statement as the initial sync page (`read_visible_page/6`): visible segments plus the D5 verdicts of the special events, with the head bound applied in both UNION branches.
- Legacy events (`room_pos IS NULL`, before 000053) are now included for a newly joined room, but they pass the same hv fragment as `/messages` and the initial sync. A newcomer under hv `joined` sees none of them. Under `shared` they are visible by spec.
- No disclosure beyond what `/messages` returns. The join/partition check and `consistent_delivery/4` are unchanged.

**(4) LOW-2 as an accepted residual: acceptable.** No third party can trigger it, the window is narrow, an initial sync under the key rewrites the rows, and every user-wide delete cascades. The dev's argument holds: "device still exists" has no single source across legacy sessions, OAuth sessions, raw-JWT bindings and the `''` key. It must stay visible on `cj` (a) / `ck` for the GDPR owner decision. Erasure should re-run the `sync_tokens` delete after `end_sessions_after_erasure/1` settles, or the erasure job should run once more: a cheap mitigation that fits the `ck` fix.

**(5) CHECK constraints.**
- Inline `CHECK` on `class` (NOT NULL) and on `prev_class` (nullable; a NULL passes, which is correct for "no previous row").
- The constraint is created together with the empty table, so there is no validation scan and no lock concern.
- The server only writes `Atom.to_string/1` of the three classes, so no legitimate write is refused.

**(6) Logging law.** No new log lines in this cycle. The three lines of cycle 0 are unchanged and value-free.
- Correction to cycle 0, focus area 6: the new call sites `visible_range!/5` and now `delta_events!/4` → `visible_page!(..., failure: :unavailable)` reach the PRE-EXISTING `history_read_failed!/3`. That line logs `"history visibility: the events of #{room_id} could not be read (#{db_error_class(reason)})"` (`server.ex:3418`).
- A room id is not a token, credential or chat content, and the line predates this story (`/messages`, initial sync). INFO only: if room ids should leave the logs in general, that is a project-wide pass, not this story.

### Summary (after cycle 1)

CRITICAL: 0 — block commit
HIGH: 0 — block commit
MEDIUM: 1 (1b, residual of #1 under the re-join / replay path, `cq` (f), tracked) — advisory, address before epic end
LOW: 1 (LOW-2, accepted residual on `cj` (a) / `ck`) — advisory
MEDIUM-1: CLOSED

**Verdict:** APPROVED (unchanged; MEDIUM-1b must be resolved or owner-accepted on `cq` (f) before the epic security gate)
