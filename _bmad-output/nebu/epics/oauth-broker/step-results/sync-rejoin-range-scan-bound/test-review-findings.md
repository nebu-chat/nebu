# Test review: sync-rejoin-range-scan-bound (pre-dev, step 3), 2026-10-27

(Saved by the orchestrator from the test reviewer's hand-back; the reviewer's harness was read-only. Condensed, all findings kept.)

71 tests reviewed (4 files). Strong structure (61-mutant table, 4-regime row probes). Verdict: **NOT READY for dev: 3 MAJOR, 11 MINOR, 9 INFO.** No docker/tests were run by the reviewer.

## MAJOR

- **M1. D-A5 has no test** (gate uses `max(latest.room_pos, previous.room_pos)`). Dispatcher test gate describe lines 192-325 only vary one member event or all of them. The partition picks `latest`/`previous` by timestamp, so under skew a member event with a higher position and older timestamp sits in `previous`; a `latest`-only gate reads the room with the plain (unbounded) walk. Fixture: viewer joins with member event F (newest ts, LOW position), base = initial sync (class join, base >= pos(F)), then member event N (HIGH position, older ts); expect exactly one segmented read, no plain read; self-check `pos_of(F) <= base < pos_of(N)`. Variant: `latest` has NULL room_pos (legacy), `previous` above base -> segmented. Add mutants "gate uses latest only" (must die), "previous only".
- **M2. No cross-room isolation test.** The mutation table has no "room_id bound removed" mutant (3 places: ordinary LATERAL, floor probe, special-events branch). `raw_room!` cleans events after each test, and the last visible segment of an hv `joined` room has `hi = 9223372036854775807`, so a missing room filter is not caught on a fresh DB. Fix: decoy room Y (same positions ~100, timestamps 1..80, shared hv, viewer is member) next to the `skew_room!` fixture; assert every returned event has room X, the floor is not lowered by Y (`below = late!(f, floor_ts - 1)` must stay refuted); add 3 mutants (room_id removed from lateral, floor probe, specials).
- **M3. Skew + >= 21 visible events: the segmented read can drop an event the plain read returns.** Per-segment cut is by timestamp (`ORDER BY origin_server_ts DESC, room_pos DESC LIMIT $5`), final cut by position. A late commit with the highest position but an old timestamp (inside the lookback) is never read when a segment holds >= limit+1 newer-by-ts events. Not the D2 (iv) floor residual; no fixture and no docs sentence.

## MINOR

m1 HTTP row probes (`http_test` 228-242, 344-361, 442-461) measure n=20 and n=400 worlds at different times without ANALYZE/bitmap control; build both worlds first or ANALYZE before each measurement. m2 docs pin on the `/sync` row partly vacuous (`re-join`, `bounded` already present): pin `sync-rejoin-range-scan-bound` in the row. m3 fixed event ids `"$tie00".."$tie29"` are global primary keys: add a per-run random infix. m4 title at `db_test` 218 overclaims (floor probe asserted at base 0): add case with `after_pos > 0` and an unstamped event in the window. m5 no assertion that `/sync` has no statement timeout (D1 (3)): `refute ... =~ "statement_timeout"` plus mutant "wrapped in with_read_timeout". m6 D-A2 (O(M) residual) and D-A3 (gap in the floor window) not pinned: docs regex pins and a gap fixture. m7 differential has no same-millisecond boundary fixture (message/join/leave/hv change in the same ms). m8 base 0 on a gated `join` room re-sends up to 20 delivered events; only the leave class is tested: add a join-class variant documenting it. m9 logs test regex is brittle (words `segment|floor|lookback|rejoin`): limit the capture to the story's modules, keep value checks. m10 `ANALYZE events` is a global side effect: document in moduledoc. m11 `bulk!` rooms in HTTP/dispatcher suites stay in the shared DB: reuse `cleanup_room_events_on_exit`.

## INFO

I1 generic-plan regime probably theoretical (unnamed statements), MD21 is only reliable on a fresh DB: dev must run the DB suite on a fresh DB before declaring green. I2 guard test (plain read touches >= 600 rows) is intentional. I3 `@describetag` instead of `@moduletag` in the dispatcher suite. I4 D10 (4) gate tests are integration tests with spies, the unit job only exercises the seam fallback through existing fakes. I5 "floor active" label in the differential is misleading (no skew -> the floor cuts nothing). I6 RowSpy runs each range read twice (custom/generic). I7 escaped backslash in an assertion message at `http_test` 338. I8 row probe counts heap fetches, not index entries. I9 no worst-case test for `segments x (limit + 1)`.

## Planner luck / leaks / time

Deterministic by design (`enable_seqscan = off`, pinned `plan_cache_mode`, 4 regimes); residual: ANALYZE sampling, autovacuum can flip the "stale" label (harmless), MD21 only on a fresh DB. No blocking state leak (spies LIFO restore, Logger level restored in `after`, ETS owned by the test process, rate limits restored). No fixed sleeps. No containers started by the tests.

## Requested before dev

1. M1 test + mutants. 2. M2 decoy-room test + 3 mutants. 3. Decide M3 (document and pin, or change the segment order), add the fixture. 4. Apply m1, m2, m5, m6 (rest optional).
