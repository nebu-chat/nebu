# Dev report cycle 0: sync-rejoin-range-scan-bound (cq (f)), 2026-10-27

Worktree `open-chat-oauth`, branch feature/migrate-to-oauth2. Story status left `ready`. Staged with `git add docs proto server` (not `_bmad-output`), nothing committed. No migration, no new dependency, `.oauth-ci/` untouched.

## Built

- `server/lib/nebu/matrix/room/db.ex`: `Room.DB.fetch_visible_events_in_range_segmented/5` (one statement, bound params only, `/* history_visibility */` fragment, `@rejoin_floor_lookback 64`). Per visible segment a LATERAL `ORDER BY origin_server_ts DESC, room_pos DESC LIMIT limit+1` with `COALESCE(room_pos,0) > $3 AND <= $4` and `origin_server_ts BETWEEN GREATEST(s.lo, floor) AND s.hi`; specials by `LATERAL ... WHERE event_id = sp.event_id AND position bounds LIMIT 1` with `y.room_id = $1` post-filtered, no floor; floor = `min(origin_server_ts)` over `room_pos BETWEEN $3-63 AND $3` of the room, behind `OFFSET 0`, MATERIALIZED CTE; outer `ORDER BY room_pos DESC LIMIT limit+1`. The doc comment names the floor window (gaps -> fewer rows, higher floor, no visibility risk), the segment cut (D-T1 residual), the D-A2 cost residual and why each plan-shape device is there (D-A1). Not a DBBehaviour callback.
- `server/lib/nebu/matrix/event_dispatcher/server.ex`: `build_delta/3` computes `member_positions` (per joined partition entry: max integer `room_pos` of `latest` and `previous`, nil when none; D-A5) and passes it through `fetch_delta_rooms/5` to `delta_events!/5`. Gate: `gated? = base.class != "join" or (is_integer(member_pos) and member_pos > base.pos)`; `head <= base.pos` reads nothing; gated and base 0 -> `paged_events!` (= `fetch_visible_events(room, viewer, "b", 20, "", head)`); otherwise `visible_range!/6` with `segmented?` (segmented via `viewer_read` with fallback to the plain read for a test module without the function; real `Room.DB` never falls back; failure -> existing `history_read_failed!` 503, no new log line, no `statement_timeout`/`with_read_timeout`). `limited`/`prev_batch`/cursors/`newly_joined_room_ids` untouched.
- Docs: new paragraph in `docs/architecture/06-runtime.md` right behind "Incremental /sync by stream position"; one sentence in the `/sync` row of `docs/matrix-api-scope.md` (names the story, "segmented", the bound; `does not move the anchor` and `s2_` kept); `gk` sentence replaced (keeps (4)); `cq` (f) closed in `docs/stories/oauth-broker/follow-ups.md` as `(f) **CLOSED by story ... (2026-10-27): ...** **Original item:** <verbatim>` naming gate, segment, floor, 64, replay, design (1)/(2), the join-base case, residuals (floor, D-T1 skew+overflow, D-A2 cost, `cq` (b)). Items (a)-(e),(g), status `open, non-gating`, the id line (byte-identical, SHA pin green) untouched, no new id.
- Extra (not requested): `mutation-dev.txt` in this directory (my mutants).

## Deviations from the reference

- Statement shape equals the reference (it already satisfied D-A1); comments and docs are my own. Gate: reference passed `rejoin_range?` twice and built the max map over the whole partition; mine builds it only for `class: :join` entries (others are gated by class anyway) with `Enum.max(..., fn -> nil end)`. `delta_events!` is one cond (no duplicate `rejoin_range?` evaluation). `paged_events!/3` extracted as in the reference. The reference's docs text was not used (it was a different, shorter closure; mine satisfies the pinned docs suite).

## Test amendments

None. The staged tests were not edited.

## Verification

- 4 new files on a FRESH DB (`docker rm -fv nebu-oauth-pg` first), `--warnings-as-errors --include integration`: 82/82 (first run 75/82 with only the 7 docs tests red before the docs; then 9/9 docs green). The plan-shape test and the four-regime row probes are green on the fresh DB.
- Full suite with `--include integration` on a fresh DB: 11251/11285 passed, 8 skipped. 34 failures, none in this story's files or its code path: known flaky families (RoomsFallbackName x11, WarRoom, TemporaryCapture x3, TraceMapNodeControls x2, SsoLogin, AdminOidcLogin x3, load test), plus `CreateRoomInputValidationTest` AC10 (ETS table on_exit race), `MembershipStateModelDocsTest` 07-deployment (b) (57014 query_canceled on a big fixture, load), and 10 `MemberPrevContentHttpTest` tests (`tick/0` `:timeout`, the documented fj-family on a reused DB). The three non-listed families pass alone on a fresh DB: `member_prev_content_http`, `membership_state_model_docs`, `create_room_input_validation` together: 136/136.
- Groups (sync, partition, history-visibility, wake-ups, session, stream-position, membership, position db files: 62 files) on a fresh DB: 982/983; the one failure is `RegressionSyncLoadTest` (median 374 ms vs 150 ms budget). It fails identically on the unmodified baseline (386 ms, scratch copy of HEAD lib): a machine-load / parked-in-CI test, not this change.
- Unit job no DB: Elixir 1.19: 6697 tests, 0 failures. Elixir 1.20: 6689/6690, the failure was the timing test `MemberSliceGateTest` throughput sanity; it passes alone (13/13, twice) and on the baseline.
- `.oauth-ci/namelen.py` on the 4 new files: silent. No compile warnings (`--warnings-as-errors`).
- Mutants of the new code (own PG `dev-mut-pg` + scratch copy, 30 mutants, run against the 3 integration suites, baseline 73/73): 28 KILLED, 2 ALIVE.
  - Gate: never segmented, always segmented, class ignored, member position ignored, latest-only, previous-only, `>=` at base, base-0 rule removed, seam fallback removed, plain read for gated rooms: all killed.
  - Bounds: lateral lower/head, special lower/head removed: killed. Floor removed, floor max, lookback 63, lookback 65, floor window without the base position: killed. room_id removed from lateral and from the floor probe: killed. Per-segment limit, outer limit, outer order by timestamp, NOT special removed, hidden segments read, special verdict ignored, plain position bounds (without COALESCE): killed (the last by the plan-shape test only).
  - ALIVE: DB11 `y.room_id = $1` removed in the special branch (equivalent: `hv_special` only holds ids of the asked room's events, event_id is the primary key; same as the ATDD's MD32), DB20 `OFFSET 0` fence on the floor probe removed (the row probes stay green on a fresh DB; the fence is defensive per D-A1 and measured by the ATDD agent to matter under other planner states; no test pins it).

## Lookback 64

Sufficed: the differential fixtures (no skew) and the skew-boundary pair (late commit stamped 1 s before the base event delivered; older than the whole window not) are green with 64; 63 and 65 are killed. It stays a tuning value.

## Known flaky

See above (tick/0 timeouts of MemberPrevContentHttpTest on a long full run, load-test latency, MemberSliceGateTest throughput, RoomsFallbackName family). The new suites were stable in 4 runs (fresh DB each).

## Residuals / for the reviewers

- Accepted and documented (code comment, 06-runtime, cq (f) closure): floor residual (skew deeper than 64 positions), D-T1 (skew + >= limit+1 newer-by-timestamp events in one segment, only `limited`), D-A2 (O(M) rows for M NEW visible events in a bad plan, never O(hidden history)). The viewer's own member events stay uncapped (`gk`).
- The bound relies on three plan-shape devices (COALESCE bounds, PK LATERAL for specials, position-range floor behind OFFSET 0). Pinned by the row probes (4 regimes) and the EXPLAIN plan-shape test, which is reliable on a fresh DB only (D-T2); the `OFFSET 0` fence itself is unpinned (mutant alive).
- Gate input `member_positions` ignores partition entries without events or with legacy NULL positions (nil -> not gated, per D3). A gated base-0 join-class room re-sends up to 20 delivered events (documented by the ATDD m8 test, same as before for an absent base).
- The `/sync` log law: no new log line; D-A7 (debug request logger prints `since=` token and sync body) was not touched, as decided; Kassandra verifies it.
- Shared DB `nebu-oauth-pg` removed at the end (state polluted by runs); all my containers and the network removed; scratch copies deleted.
