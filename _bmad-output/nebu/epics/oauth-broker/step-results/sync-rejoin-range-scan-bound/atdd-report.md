# ATDD report: sync-rejoin-range-scan-bound (red phase), 2026-10-27

(Saved by the orchestrator from the ATDD agent's hand-back, because the agent's harness forbade writing report files. Real files written by the agent: `reference-impl.diff` (never committed, 207 lines: db.ex, server.ex, follow-ups.md, 06-runtime.md, matrix-api-scope.md) and `mutation-results.txt`.)

Worktree `open-chat-oauth`, HEAD `8991debc`. Staged: `git add docs/stories server/test` only; nothing committed, no `server/lib`, no docs edit, `.oauth-ci/` untouched. Nothing existing was amended: no existing test contradicted the story, all existing suites ran green on the reference unchanged.

## 1. New files (71 tests, all `@moduletag :integration` except docs, `async: false` except docs, names < 200 chars, `--warnings-as-errors` clean on 1.19 and 1.20)

| file | tests | covers |
|---|---|---|
| `server/test/nebu/matrix/room/sync_rejoin_range_scan_bound_db_test.exs` | 31 | D1/D2 contract and bounds, differential oracle (8 fixtures x viewers a/b/c x limits 3/20 x every base), special-branch bounds, legacy events, ties, floor, row probes |
| `server/test/nebu/matrix/sync_rejoin_range_scan_bound_http_test.exs` | 14 | Gherkin 1-6, replay equality, statement probe, rows through the real `/sync`, logs |
| `server/test/nebu/matrix/sync_rejoin_range_scan_bound_dispatcher_test.exs` | 18 | gate, base 0, seam, 503, replay arguments, D4 |
| `server/test/nebu/matrix/sync_rejoin_range_scan_bound_docs_test.exs` | 8 | D8 (static, runs in the unit job) |

All new functions are reached through `apply/3` or a spy, so the red state fails at runtime, never at compile time.

- **DB suite:** contract (shape, one statement with the `/* history_visibility */` marker and no values in the text; `Room.DB` exports the function, `DBBehaviour` does not list it); D2 (i)/(ii) bounds for both branches incl. the special branch and legacy NULL-position events; D2 (iii) newest `limit + 1` by position across several visible segments, ties of one millisecond cut by position; differential oracle against the plain read over hv `joined`, `shared`, `world_readable`, `invited`, a mixed fixture, three re-joins, invite -> join -> leave -> invite -> join, and a long fixture where the floor is active; D2 (iv) skew pair (late commit 1 s before the base event is delivered; floor inclusive; lookback exactly 64 pinned from both sides), lookback counts positions, specials not floored, base 0 no floor, fewer than 64 events at the base, a skew fixture documenting the residual; D7 (1) row probes.
- **HTTP suite:** scenario 1 (hv joined, cursor = leave, 30 hidden events: exactly the join and 2 messages, not limited, newly joined; hv `invited` variant; rows probe 20 vs 400), scenario 2 (replay equality twice; replay plus new events recomputes `limited`; D7 (2) statement probe: same statement count and texts for 20 and 400, ONE room read judged by the visibility fragment), scenario 3 (newest 20, `limited`, `prev_batch` paged back via `/messages`; exactly 20 not limited), scenario 4 (join base with leave and re-join between syncs), scenario 5 (invite -> join -> leave -> invite -> join, sync after each step, each visible message exactly once, replay equals original), scenario 6 (late commit stamped 1 s before the cursor's newest event delivered once), logs (this story adds no line).
- **Dispatcher suite (real stack + `GateSpy` / `NoSegSpy`):** gate cases (class join unchanged -> plain; leave/invite -> segmented with args `(room, user, base pos, head, 20)`; join base with leave+re-join since; join base with profile change only (broad gate, OQ2); member position AT the base -> plain, one below -> segmented; class leave/invite with base AT member position (cq (a)) -> segmented; legacy member event without position -> plain; `head <= base` reads nothing); base 0 (gated room read by `fetch_visible_events(room, viewer, "b", 20, "", head)` incl. legacy events, ungated room keeps plain range); seam (double without the function answers via its plain read); 503 (failing segmented read -> 503 `M_UNAVAILABLE`, one value-free ERROR line, token and cursor rows byte-identical, same token delivers later, non-gated room unaffected); replay arguments; D4.
- **Docs suite:** (f) CLOSED marker with story name + date then `**Original item:**` + verbatim original; closure names gate, segment, floor, 64, residual and `cq` (b), replay, design (2) rejected, design (1) needed the floor, join-base case; items (a)-(e),(g) intact; status `open, non-gating`; `cq` one row; id line byte-identical (2680 bytes, SHA-256 `1773564f8df3a19fcc78a3f298bf4410f889e21edb93fbf56a2cc474075ba778`) plus both older pins; `gk`: "segment-driven where a hidden stretch is possible", old "is not segment-driven" sentence gone, (4) kept; one `06-runtime.md` paragraph; `/sync` row names re-join, "segmented", cost bound, keeps `does not move the anchor` and `s2_`.

## 2. Contract pinned

- **Function:** `Room.DB.fetch_visible_events_in_range_segmented(room_id, viewer, after_pos, head, limit)` -> `{:ok, newest_first}`: at most `limit + 1` events, newest first by `room_pos`, the 7 string keys of the plain read, `{:error, _}` on DB error. One statement, bound params only, hv marker. Not a `DBBehaviour` callback.
- **Bounds:** `after_pos < room_pos <= head` in both branches; a row without position is never returned.
- **Floor:** `origin_server_ts >=` min over events at positions `after_pos - 63 .. after_pos`; inclusive; ordinary events only; `after_pos = 0` no floor. 64 pinned by the skew pair.
- **Cut:** per-segment `LIMIT limit + 1`, then overall `limit + 1` by position; ties cut by position.
- **Gate:** `base.class != "join"` OR (viewer's newest member event has a `room_pos` AND `> base.pos`) -> segmented; else plain; `head <= base.pos` reads nothing.
- **Base 0:** gated -> head-bounded page read (legacy included); ungated -> plain `(0, head]`.
- **Arguments:** segmented read gets (room, trusted user id, the base of the token presented, i.e. previous generation on replay, head read, 20).
- **Seam:** db module without the function answers a gated room through its own plain read; real `Room.DB` never falls back.
- **Failure:** 503 `{"errcode":"M_UNAVAILABLE","error":"Core is temporarily unavailable"}`, one existing value-free ERROR line, nothing persisted, no new log line.
- **Answer meaning unchanged:** `limited` iff a 21st visible event exists; cursor to head; `newly_joined_room_ids` untouched.

Unit fakes that fall back to the plain read: only `SyncMembershipPartitionTest.FakeDB` (5 gated reads). All other fakes never reach a gated room and stay green unchanged.

## 3. Red evidence (`.oauth-ci/quick.sh`, 1.20, `--warnings-as-errors --include integration`)

`22/71 passed, 49 failed`, no warnings: UndefinedFunctionError for the new function, segmented read not called (gate, 503, replay, base 0), rows grow with hidden history (3 HTTP row probes), docs not edited (6). 22 deliberate green pins (plain-read cases, D4/D5/D6, guard test that the plain read touches >= 600 rows, id line, items (a)-(e),(g), delivery-semantics scenarios where the plain read already returns the same events; for those the cost is what fails in red). Unit job on the worktree (1.20, no DB): 6683/6689, the 6 failures being the docs tests.

## 4. Green evidence (reference copy, own PG `atdd-rj-pg`, removed with `docker rm -fv`)

- 4 new files: 71 passed (repeated), `--warnings-as-errors`.
- Existing suites on the reference with no amendment, 0 failures: group A 460, group B 360, group C 240.
- Unit job on the reference, no DB: 1.19 `6696 tests, 0 failures`; 1.20 only `adr_033_test` fails because the scratch copy lacks `_bmad-output` (passes 90/90 with it).
- 1.19 with DB: 344 tests, 0 failures.

## 5. Mutation table

61 mutants, all killed except MD21 (position bounds as plain index conditions: ALIVE on the long-lived DB because of plan lottery, KILLED on a fresh DB). Groups: position bounds MD01-05/27/28/16/29; floor and lookback MD06-11/25/17; cut/order MD12-15/26; visibility MD18-20; plan shape MD21-24; gate/dispatcher MS01-15 (MS03 and MS15 were first ALIVE, tests added); docs MX01-14. Detail in `mutation-results.txt`.

## 6. Gaps for the orchestrator

1. The bound holds only for one plan shape. Measured: position bounds as plain conditions -> 4293 rows (N=600); special-events join with room_id indexable -> 2843; floor as `ORDER BY room_pos DESC LIMIT 64` -> bitmap scan of the whole room 603; `min()` over the position window rewritten into a timestamp-index walk; without `SET LOCAL enable_seqscan = off` a fixture-sized table flaps to seq scan. Shapes that pass all four regimes (in `reference-impl.diff`): position bounds as `COALESCE(e.room_pos, 0) > $3 AND <= $4`; special events by `LATERAL ... LIMIT 1` on `event_id` with `room_id` post-filtered; floor as `min()` over `events` at `room_pos BETWEEN $3 - 63 AND $3` in a subquery with `OFFSET 0`. Tests pin rows behaviour, not SQL text.
2. Cost of NEW visible events is plan dependent (up to 678 rows for 600 new visible events with bitmap scans); per-segment LIMIT pinned only with bitmap scans off. Residual: a shared room with M new visible events, replayed: O(M) rows worst plan vs 21 for the plain read.
3. Floor = positions `after_pos - 63 .. after_pos`, equal to "64 highest" while positions are gapless.
4. Ties: cut by position (`ORDER BY origin_server_ts DESC, room_pos DESC`) so the oracle equality holds.
5. Gate input: the partition's `latest` member event is chosen by `origin_server_ts`, not position; under skew a higher-position member event with an older timestamp could be missed. `max(latest.room_pos, previous.room_pos)` is available at no cost. Not pinned beyond the listed cases.
6. Base 0 as pinned in section 2.
7. D7 (2) "exactly one position statement per moved room" cannot be counted by substring; pinned: identical statement count and texts for N=20 and 400, ONE room read judged by the visibility fragment.
8. D10 (3): new file instead of amending `sync_stream_position_http_test.exs`.
9. "Real `Room.DB` never falls back" only covered by `function_exported?` plus the unchanged `viewer_read/3`.
10. Scenario 1 syncs the leave first (newly_joined requires a non-join base); scenario 4 is the join-base variant.
11. `gk` row says the range read "is not segment-driven (`cq` (f))": dev must replace that sentence (tested).
12. Pre-existing observation outside this story: at debug level the HTTP request logger prints the full exchange incl. `since=<token>` in the query string and the sync response body (chat content). The existing "logs" test in `sync_stream_position_http_test.exs` is vacuous (test config logs at `:warning`). The new logs test lowers the level and sets those request lines aside.
13. `nebu-oauth-pg` polluted by the red run as usual; agent containers removed; scratch copies `ref-rejoin`, `ref-rejoin-119` remain in the scratchpad.

---

# ATDD fix pass (after test review), 2026-10-27 (orchestrator transcription of the agent's report)

All 3 MAJOR and 11 MINOR findings addressed plus I5/I7. Tests grew 71 -> 82 (DB 39, HTTP 14, dispatcher 20, docs 9). Red: 22/82 pass, 60 fail (same kind of deliberate pins). Green on the reference (fresh PG): 82/82; existing groups A 460 / B 360 / C 240 unchanged, 0 failures; 1.19 with DB 252, 0 failures; unit job no DB 1.19 `6697 tests, 0 failures` (1.20: 1 OAuthFreshnessTest log-capture crosstalk, green alone).

- M1: D-A5 gate (reference gate = `max(latest.room_pos, previous.room_pos)`), skew test + 2 variants (F below base, F NULL position); mutants "latest only" and "previous only" killed.
- M2: decoy-room test in the DB suite; mutants room_id removed from lateral (killed) and floor probe (killed); "room_id removed from the special branch" ALIVE = equivalent mutant (`hv_special` holds only events of the asked room, PK lookup).
- M3 accepted residual: fixture with 25 newer events and a late commit (segmented answer = newest 21 by position among the 25, late commit absent; plain read returns it; page read has it); docs pins for the segment-overflow residual and the D-A2 cost residual in the cq (f) closure and the 06-runtime paragraph; mutants MX15-17 killed.
- D-A3 gap fixtures (NULL position and deleted event in the floor window): floor rises to ts(18), nothing lost without skew.
- m1 ANALYZE before each measurement, both worlds built first; m2 unique term pin `sync-rejoin-range-scan-bound` in the /sync row; m3 random infix tie ids; m4 title; m5 no `with_read_timeout` during a gated sync + no `statement_timeout` statement; m7 three same-ms fixtures; m8 join-class base-0 test; m9 logs capture restricted to `EventDispatcher.Server`/`Room.DB` lines; m10 moduledoc; m11 bulk rooms cleaned.
- New test (MD21 needed it): deterministic plan-shape test in the DB suite: in a rolled-back privileged transaction (`enable_seqscan` off, `events_room_id_ts_idx` dropped, ACCESS EXCLUSIVE) the EXPLAIN may contain at most one scan of `events_room_pos_idx` (the floor window). Same technique as the `history_visibility_db_test` explain pins. MD21 and MD23 die by it.
- Mutation table: 69 mutants, all killed except MD32 (equivalent, above) and MD21 in the aged-DB full re-run (killed by the plan-shape test on its own).
