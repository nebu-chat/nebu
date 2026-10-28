---
story_id: sync-rejoin-range-scan-bound
title: "The incremental /sync range read never scans the invisible stretch of a re-join: a joined room whose cursor base is an invitation or a leave (or whose viewer changed membership since the base) is read through the segment-driven, position-bounded page, so replaying the previous next_batch costs a bounded number of rows independent of the history the viewer may not see (closes cq (f), Kassandra MEDIUM-1b)"
type: bugfix
severity: medium
epic: oauth-broker
status: done
security_review: required
matrix: false
ui: false
traceability_id: REQ-2026-006
created: 2026-10-27
branch: feature/migrate-to-oauth2
depends_on: sync-stream-position
sizing: small
---

# Story: the re-join range read is bounded by the visible segments (follow-up `cq` (f), security review MEDIUM-1b)

## Story

**As** the operator of a Nebu server whose users re-join rooms with restricted history visibility, **I want** the incremental
`/sync` of a re-joined room to read only the events the viewer may see, never walking the hidden history between the old cursor
and the re-join, **so that** a client replaying its previous `next_batch` in a loop (the previous token stays valid for one
generation, story sync-stream-position D8) cannot make the server repeat an unbounded scan on every request, while the user still
receives every visible event since the cursor exactly once.

Scope: one SQL read and the dispatcher's choice between two position reads (D1-D5), tests with a deterministic cost probe (D7),
docs and the closure of `cq` (f) (D8). No migration, no new route, no response-shape change, no new follow-up id.

## Premise check (2026-10-27, worktree `open-chat-oauth`, branch `feature/migrate-to-oauth2`, read-only)

What the code really does, with the places where it differs from the follow-up text:

- **The scan.** `delta_events!/4` (`event_dispatcher/server.ex`) with a base row calls `visible_range!/5` ->
  `Room.DB.fetch_visible_events_in_range/5` (`room/db.ex`): `WHERE room_id = $1 AND room_pos > $after AND room_pos <= $head AND
  <hv visible> ORDER BY room_pos DESC LIMIT 21`, i.e. it walks `events_room_pos_idx` backwards from the head and applies the
  visibility predicate (a binary search in the segment arrays of the fragment) PER ROW. A hidden row costs one index entry, one heap
  fetch and one predicate evaluation and does not count towards the 21. With fewer than 21 visible rows above the head the walk
  reaches the base position, so the cost is the number of events between the base and the head, hidden ones included. Replaying
  the previous token re-reads the previous base (`cursor_base/2`: `prev_*` of a row of the replaced generation), so the walk
  repeats per request. There is no statement timeout on purpose (`gk` (4)).
- **The page read it should resemble** (`visible_page!/6` -> `Room.DB.fetch_visible_events/6` -> `read_visible_page/6`) is driven
  by the visible history-visibility SEGMENTS (closed `origin_server_ts` ranges): one `LATERAL` index range over
  `events_room_id_ts_idx` per VISIBLE segment with `LIMIT` inside, plus the visible special events (the hv state events and the
  viewer's own member events, a small set read through `events_room_state_idx`). It never reads a hidden row. It is bounded by the
  head (`room_pos <= head OR room_pos IS NULL`, D12) but has no lower position bound.
- **Premise 1 differs: the stretch is not only "base class `leave` / `invite`".** The same walk happens for a base of class
  `join` when the user left and re-joined BETWEEN two syncs of the device (the partition then reports `join` both times, the
  device never saw the leave, the base is `join`, and under hv `joined` / `invited` everything written while away is hidden).
  The trigger is "the viewer's own membership changed inside `(base, head]`", of which a base of class `invite` / `leave` is the
  common case. An attacker needs no wait: leave and re-join through the API in a busy or self-filled room.
- **Premise 2 differs: candidate design (1) as written is a regression.** Adding `room_pos > base.pos` to the segment-driven page
  as a plain filter does not bound its scan: the `LATERAL` is ordered by `origin_server_ts`, the position bound is only a heap
  filter, and the newest rows come first. With fewer than 21 matches it keeps walking the visible segment BELOW the base, which is
  already-delivered history. In a `shared` room (one giant visible segment) a re-join with one new event would scan the whole room,
  where the current range read is cheap. The hidden stretch is skipped, the delivered history is not.
- **Premise 3 differs: candidate design (2), clamping the range start to the viewer's join position, drops visible events.**
  Under `shared` / `world_readable` the events between the base and the join are visible to the re-joined viewer and the current
  read delivers them (as part of the newest 20); the clamp would lose them, and "only when the hv at that point is `joined` /
  `invited`" needs the segment computation anyway. Rejected (D1).
- **Position order versus segment order.** Visibility is a function of `origin_server_ts` (segments), delivery order and the base are
  positions (`room_pos`). No index serves both: any exact "newest 21 visible events with `room_pos` in `(base, head]`" must either
  walk positions (and meets every hidden row) or walk timestamps (and meets every delivered row below the base). The bound has to
  come from the timestamp side, which means a time floor, which means a deliberate, documented skew-depth bound (D2).
- **Same-statement facts that help.** Positions are gapless per room (the trigger rolls back with the insert), the event at the base
  position exists and is found by the unique `events_room_pos_idx`, the viewer's latest member event (`entry.latest`, with
  `room_pos`, read by the partition) is already in the dispatcher, and `latest.room_pos > base.pos` is exactly "the viewer's own
  membership changed since the base".
- **Pre-existing and unchanged:** events committed between the leave event and the head read of the leave-delivering sync (inside
  `(L, base]`) are not delivered on a later re-join under `shared` (the range starts above the base); legacy events (`room_pos IS
  NULL`) are never part of a position range; `cq` (a) (the head is read after the partition, so for an invite / leave row it can
  already include the user's own join): the gate below keys on the class, so that case is covered.

## Decisions

- **D1 Design: a segment-driven, position-bounded range read for the rooms where a hidden stretch is possible (the "segmented
  range read"); the plain range read stays for every other room.** One new statement, `Room.DB.fetch_visible_events_in_range_segmented/5`
  (same arguments and the same answer as `fetch_visible_events_in_range/5`: `{:ok, newest_first}` of the NEWEST `limit + 1` visible
  events with `after_pos < room_pos <= head`, newest first by position, the caller delivers `limit` and reads the extra row as
  `limited`). It is the page read's shape (the visible segments drive, one `LATERAL` per visible segment, `LIMIT limit + 1` inside,
  plus the visible special events, the SAME fragment and verdicts) with the two position bounds in BOTH branches (D2) and a time
  floor (D2); the outer `ORDER BY room_pos DESC LIMIT limit + 1` restores stream order. Hidden rows are never read, so the cost is
  bounded by the segment structure, not by the hidden history. **Reasons:** (a) it is the construction the review asked for
  ("bounded by the segment-driven page"); (b) the visibility meaning is untouched (one fragment, one verdict per row); (c) only
  the rooms that need it change: the continuous-join range read keeps its exact stream-order semantics. **Rejected:**
  (1) the follow-up's design (1) as a plain `room_pos > base.pos` filter on the existing page read (Premise 2: unbounded over delivered
  history, a regression for `shared` rooms; the floor of D2 is what makes it bounded); (2) clamping to the join position (Premise 3:
  loses visible events under `shared` / `world_readable`); (3) a statement timeout (`gk` (4): a room that always timed out would
  fail every member's `/sync`; decision stays: NO `Room.DB.with_read_timeout/1` on `/sync`); (4) a hard budget on the rows examined by
  the position walk (a fixed K would deliver an empty or truncated timeline of a room that has visible events, with no
  `prev_batch` when nothing was delivered); (5) a persisted visibility map or a new index (migration, write-path cost, cluster
  state; the fragment already is the single source).

- **D2 The exact bounds of the segmented read.** All four apply to ORDINARY events in the `LATERAL` of each visible segment `s`; (i) and (ii)
  also apply to the visible special events:
  (i) `room_pos > after_pos` (the base: an event at or below it was delivered, or was hidden when the cursor was written);
  (ii) `room_pos <= head` (D12 exactness: the head READ is the bound, an event committed after it has a higher position and comes
  with the next sync; NO `OR room_pos IS NULL`: a legacy event is never part of a position range, D4 of sync-stream-position);
  (iii) `LIMIT limit + 1` per segment (and at the end);
  (iv) **the time floor** `origin_server_ts >= floor`, `floor = min(origin_server_ts)` of the 64 events with the highest
  `room_pos <= after_pos` (one backward probe of `events_room_pos_idx`, in the same statement; module attribute
  `@rejoin_floor_lookback 64`), applied as `BETWEEN GREATEST(s.lo, floor) AND s.hi`. The floor is what keeps the scan off the
  delivered history below the base (Premise 2); the lookback keeps late commits and clock skew of up to 64 positions deep
  (a writer that stamped before the newest events but committed after the cursor, the createRoom clock lead of about 70 ms) inside
  the read. **Documented residual (class `cq` (b), accepted, recorded in the closure of `cq` (f)):** an event committed after the
  cursor with a timestamp older than ALL of the 64 newest events at the cursor is not in the re-join timeline (it stays reachable
  by `/messages`). A special event is not floored (few: at most 256 hv events plus the viewer's own member events, so the join
  itself is never missed). A base position `0` (the room had no positioned event when the cursor was written) has no event to
  anchor the floor: it is read as an ABSENT base (the existing `base == nil` page read, legacy events included, same verdicts as
  `/messages`).

- **D3 The gate: which rooms use the segmented read.** In `delta_events!/4` (the clause with a base and `head > base.pos`): the
  segmented read when `base.class != "join"` OR the viewer's latest member event of the room has `room_pos > base.pos`
  (`entry.latest`; nil, or a legacy event without a position, counts as "no change since the base"); the plain range read
  otherwise. A wrong choice can only change the cost or the delivery shape, never visibility: both reads use the same fragment.
  The gate is conservative (a display-name change since the base also selects the segmented read; its result equals the plain read
  outside the D2 residual). The partition entries of the join rooms are passed to `fetch_delta_rooms/4` (or the positions of their
  latest member events: the implementer's choice, no new statement).

- **D4 `limited`, `prev_batch`, order, cursors: unchanged in meaning.** `visible_range!/5` takes the read as a parameter and keeps
  its contract: the newest `limit` of the `limit + 1` rows ascending by position, `limited` when the extra row exists (a 21st
  visible event since the base), `prev_batch` = `Room.DB.pagination_token(hd(events))` when limited, `""` otherwise. A re-join with
  at most 20 visible events since the cursor is NOT limited and carries them all; with more it is limited and
  `GET /messages?dir=b&from=<prev_batch>` pages backwards over the visible gap and then the history the client already has (the
  same semantics as an initial-sync room). The cursor moves to the head exactly as before; `newly_joined_room_ids` is untouched
  (base class `!= "join"`), the room's state shape (`gg`) too. An event already delivered (`room_pos <= base`) is never delivered
  twice, a hidden event never at all.

- **D5 Seams.** A db module that does not export the new function (the shared unit fakes `Nebu.Matrix.SyncPositionsFake`, other
  doubles) answers the gated rooms through its plain `fetch_visible_events_in_range/5`; the real `Nebu.Matrix.Room.DB` never falls
  back and a missing function there is the 503 (`viewer_read_unavailable`, as for the plain read). A failed read is the handled
  503 `M_UNAVAILABLE` with no token persisted (`history_read_failed!/3`, value-free log line, unchanged). No new log line.
  The new function is not a `DBBehaviour` callback (as the other position reads).

- **D6 Replay (D8 of sync-stream-position) is unchanged by construction and must be pinned.** The previous token selects the
  previous base (`cursor_base/2`); the gate and the read depend only on that base and the head, so the replay costs what the first
  request cost: bounded, independent of the hidden history. With no event committed in between, the replayed response equals the
  first one (`rooms.join.<room>.timeline.events`, `limited`, `prev_batch`, `newly_joined_room_ids`); with events committed in
  between it equals the first plus those events (recomputed `limited`). Cursor, token generation and compare-and-set logic are not
  touched.

- **D7 Cost test contract (deterministic, EXPLAIN-free).**
  (1) **Row probe** at the DB level (`room/sync_positions_db_test.exs` or a sibling): inside ONE `Nebu.Repo.transaction` read the
  `events` counters of `pg_stat_xact_user_tables` (`seq_tup_read + idx_tup_fetch`, per-transaction, updated immediately) before and
  after one `fetch_visible_events_in_range_segmented/5` call; the fixture is a room with hv `joined` where a viewer left, N events
  were written while away (N = 20 and N = 600; the same 70 events before the leave in both), and the viewer re-joined with a
  few visible events. Assert: the delta of N = 600 exceeds the delta of N = 20 by at most 10 rows, and the absolute delta for N =
  600 stays below 300. The SAME probe against the plain `fetch_visible_events_in_range/5` grows with N (assert `>= 600` in a
  guard test that documents why the old read is not the gated one; mutation check: dispatching the gated rooms to the plain read
  fails the HTTP test below).
  (2) **Statement probe** at the HTTP level (`sync_stream_position_http_test.exs`, the `Nebu.Matrix.MembershipStateTestSupport.count_statements/3`
  spy): the replay of the previous `next_batch` after a re-join with N = 20 and with N = 400 hidden events does the same number
  of statements (one head statement, one segmented read per moved room, the cursor persist), and the position statements
  (`room_pos`) are exactly one per moved room. Hidden events are inserted through the real writers or `Room.DB.insert_event/1`
  (positions by the trigger).
  (3) A skew-boundary pair pins D2 (iv): a late commit stamped 1 s before the base event but committed after the cursor IS
  delivered (inside the 64-position lookback); one stamped older than the oldest of the 64 events is NOT (documented residual).

- **D8 Docs and closure; NO new follow-up id.**
  - `docs/stories/oauth-broker/follow-ups.md`: in row `cq`, item (f) becomes "(f) **CLOSED by story sync-rejoin-range-scan-bound
    (2026-10-27): ...** **Original item:** <the current text of (f), verbatim>" (the closure names: the gate, the segmented read,
    the floor and its documented residual, the D6 replay guarantee, that the follow-up's design (2) was rejected and design (1)
    needed the floor, and that the stretch also existed for a `join` base). The items (a)-(e), (g) and the row status
    `open, non-gating` stay. Note on `gk`: (4) unchanged (no timeout on `/sync`), the range read of a room with a cursor is segment-
    driven where a hidden stretch is possible.
  - **The id line stays byte-identical** (the paragraph "Follow-up ids." near the top of the file; today it ends with the
    `cq` / `cn` sentences and contains `unused: `go` onward`). It is pinned by the docs suites (`unused:[^.]*`gm` onward` and
    `unused: `go` onward`, e.g. `user_deletion_docs_test.exs`); this story takes no id, so it does not touch the line.
  - `docs/architecture/06-runtime.md` (the "Incremental `/sync` by stream position" paragraph): the range read is the plain
    position range for a continuously joined room and the segmented read (visible segments, position bounds, time floor of 64
    positions) when the base is an invitation / leave or the viewer's membership changed since it; replay cost.
  - `docs/matrix-api-scope.md` (the `/sync` row): one sentence for the re-join read and its cost bound; the pinned token
    "does not move the anchor" and the existing `s2_` wording stay.
  - A docs test (`sync_rejoin_range_scan_bound_docs_test.exs`): (f) CLOSED with `Original item:` and the original (f) text, the
    other items and the status of `cq` intact, `cq` still one row, the id line unchanged and matching both pins, `gk` note,
    06-runtime and the `/sync` row name the segmented read.

- **D9 Security review required (Kassandra).** Trust boundaries: the per-device cursor rows (unchanged: keyed by the authenticated
  user and device, never by request input), the history-visibility verdict (the same fragment on a new candidate set: the bounds
  and the floor only SHRINK what is read, `NOT special` rows and special rows use the same `hv_*` CTEs; no new disclosure; the
  differential test of D10 pins it), fail-closed reads (503, nothing persisted), DoS (the amplification of MEDIUM-1b: the cost per
  replay is now bounded by `segments x (limit + 1)`, the 64-row floor probe, the specials and the fragment's O(B log B) inputs,
  the viewer's own member events being the `gk` residual (uncapped); none of it depends on the number of hidden ordinary events),
  the 600 / min `/sync` limit unchanged, logging (no new line). Expected: MEDIUM-1b closed.

- **D10 Test list (ATDD).**
  1. Differential (DB, real PostgreSQL): for hv `joined`, `shared`, `invited`, `world_readable` and mixed sequences, with multiple
     re-joins and invite -> join -> leave -> invite -> join, the segmented read equals the plain range read (the oracle) for every
     base position, on fixtures with no skew (same events, same order, same `limit + 1` cut). A skew fixture documents the D2
     residual.
  2. The cost probes of D7 (1) and (3).
  3. HTTP (`sync_stream_position_http_test.exs`, two opaque sessions, the fixtures of that suite): scenarios 1-5 below; the replay
     equality; the statement probe of D7 (2); a `join` base with leave + re-join between two syncs; `newly_joined_room_ids` and
     the room account data of a re-joined room; `limited` / `prev_batch` of a re-join with 25 visible events, the gap by
     `/messages`.
  4. Dispatcher unit tests with the fake modules: the gate (`class != join`, member position above / not above the base, nil /
     legacy position, base position 0 = absent-base read), the seam (a fake without the new function uses the plain range read),
     a failing segmented read is the 503 with nothing persisted.
  5. Docs test (D8).
  Mutation checks to run by the dev: gate removed (the HTTP probe fails), the floor removed (the DB probe grows with the delivered
  history of a `shared` room: add that fixture), a bound moved out of the special branch (the differential test fails).

## Non-goals

- (g) the first cross-signing upload race (`cq` (g), Kassandra INFO-3 of sync-token-per-device): a separate story.
- `/messages` and `/context`: unchanged (still ordered by `origin_server_ts`; a position-based token stays `cq` (b)).
- Position-based tokens, `room_pos` tie-breaks, a backfill of legacy events (`cq` (b), (c)).
- A statement timeout on `/sync` reads (`gk` (4): no), a cap on the viewer's own member events (the `gk` residual).
- The events in `(leave event, base]` that a `shared` re-join does not deliver (pre-existing, unchanged), the partition / `:pg`
  gap `cq` (a).

## Acceptance Criteria

```gherkin
Feature: the incremental /sync of a re-joined room never scans the hidden history between the cursor and the re-join

  Scenario: A re-join after a long hidden absence delivers only the visible events and costs the same as after a short one
    Given a device synced a room with history visibility joined, the user left, many events were written while away and the user re-joined with two visible events since
    When the device calls /sync with its next_batch
    Then the room carries exactly the two visible events and the join, limited is false, the room is in newly_joined_room_ids and the read touched a number of rows that does not depend on the number of hidden events

  Scenario: Replaying the previous next_batch repeats a bounded read and returns the identical response
    Given a device received the response of an invite to join sequence in a room with history visibility joined and many hidden events, and then replays the next_batch it presented
    When the replay is served
    Then the response equals the first one, and its statements and rows read are the same for 20 and for 400 hidden events

  Scenario: A shared room delivers the newest 20 since the cursor with a usable prev_batch and no event twice
    Given a device's cursor is a leave and the room (history visibility shared) received 25 visible events before the user re-joined
    When the device calls /sync with its next_batch
    Then the room carries the newest 20 events with limited true, GET /messages dir b from the prev_batch returns the older ones, and no event at or below the cursor is delivered again

  Scenario: A leave and re-join between two syncs is read like a re-join
    Given a device's cursor is a join, the user then left and re-joined a hidden-history room with many events written while away and the device never synced in between
    When the device calls /sync with its next_batch
    Then it receives only the events the user may see since the cursor exactly once, and the read does not scan the hidden stretch

  Scenario: Invite, join, leave, invite and join again deliver each visible event once
    Given a device syncs after each step of invite, join, leave, a second invite and a second join of the same room while messages are written throughout
    When the device syncs after every step
    Then every visible message is delivered exactly once in total, no hidden message is delivered, and replaying the previous next_batch after the last step equals the original response

  Scenario: A late commit inside the lookback is delivered after a re-join
    Given a message is committed after the device's cursor with a timestamp one second before the cursor's newest event while the user then re-joins
    When the device calls /sync with its next_batch
    Then the message is delivered exactly once
```

## Definition of Done

- [ ] All Gherkin scenarios have failing tests (ATDD)
- [ ] All tests pass (green)
- [ ] Code review clean (0 MAJOR)
- [ ] Security review (if required) clean

## Open Questions

- **OQ1 The residual of D2 (iv).** Accept that an event committed after the cursor with a timestamp older than all 64 newest events at
  the cursor is missing from a re-join timeline (reachable by `/messages`), i.e. the same class as `cq` (b)? Recommendation: accept;
  the exact alternative needs a read that is O(hidden history) or a position-based visibility map (D1 (5)). The lookback
  length (64) is a tuning value, not a security value.
- **OQ2 Gate breadth.** D3 also selects the segmented read after a profile change (a member event with a higher position). The
  alternative "only when the base class is not `join`" leaves the `join` base leave-and-re-join (Premise 1) unbounded.
  Recommendation: keep the broader gate.

## Orchestrator decisions on the open questions (2026-10-27)

- **OQ1: accepted (D9 of this section).** The D2 (iv) residual (an event committed after the cursor with a timestamp older than all 64 newest events at the cursor is
  missing from a re-join timeline, still reachable by `/messages`) is accepted as class `cq` (b). It is recorded in the closure text of `cq` (f); the lookback 64 stays a
  tuning value. The dev states in the report whether the lookback proved sufficient in the differential test (skew-boundary pair).
- **OQ2: keep the broader gate (D3).** Cost safety beats the minimal gate.
- Test-fake seam (D5) is kept; the ATDD agent lists in its report which unit fakes fall back to the plain read.

## Orchestrator decisions after ATDD (2026-10-27)

- **D-A1 (plan shape, ATDD gap 1).** The bound must hold independent of the planner. The three shapes in `reference-impl.diff` are the starting point for the dev, not the SQL text of record: position bounds as `COALESCE(e.room_pos, 0) > $3 AND <= $4` (keeps the partial position index out of the segment scans), special events by a `LATERAL ... LIMIT 1` on `event_id` with `room_id` post-filtered, the floor as `min()` over `events` at `room_pos BETWEEN $3 - 63 AND $3` in a subquery with `OFFSET 0`. A different statement is fine if the row-probe tests stay green on a fresh and a long-lived DB.
- **D-A2 (new-event cost, ATDD gap 2).** Accepted residual: cost of NEW visible events since the cursor may be O(M) rows in a bad plan (M = new visible events), never O(hidden history). Must be stated in the closure text and in 06-runtime.
- **D-A3 (floor window, gap 3).** Confirmed: positions `after_pos - 63 .. after_pos`; with gaps the window holds fewer events (higher floor, slightly larger residual, no visibility risk). State in the code comment.
- **D-A4 (ties, gap 4).** Confirmed: cut by position.
- **D-A5 (gate input, gap 5).** The gate uses `max(latest.room_pos, previous.room_pos)` of the viewer's member events in the partition entry, not only `latest` (chosen by timestamp). The ATDD fix pass adds a skew gate test for it.
- **D-A6.** Gaps 6-11 confirmed as pinned. The `gk` sentence is replaced by the dev.
- **D-A7 (log observation, gap 12).** Out of scope for this story (no new follow-up id, the id line stays byte-identical). Kassandra verifies the claim (debug request logger printing `since=` token and sync body) and reports it; the orchestrator tells the owner.

## Orchestrator decisions after test review (2026-10-27)

- **D-T1 (skew plus overflow, review M3).** Accepted residual, not a redesign: the per-segment cut is by timestamp, the final cut by position, so when one visible segment holds at least `limit + 1` newer-by-timestamp events a late commit with the highest position but an old timestamp (inside the lookback) is not read. It happens only in a `limited` window and the event stays reachable through `/messages`; same class as `cq` (b). The closure text of `cq` (f) and the 06-runtime paragraph name it (pinned by the docs suite), together with the D-A2 residual (cost of NEW visible events up to O(M), never O(hidden history)).
- **D-T2.** Cross-room isolation and the D-A5 gate are pinned by new tests (ATDD fix pass); the dev must run the DB suite on a fresh database before declaring green (MD21 is only reliable there).
