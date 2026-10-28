# Test review: sync-token-per-device (ATDD red suite), 2026-10-26

Reviewer: bmad-testarch-test-review (read-only). Worktree `open-chat-oauth`, branch `feature/migrate-to-oauth2`.
Scope: `server/test/nebu/migration/000052_sync_device_positions_test.exs`, `server/test/nebu/matrix/sync_token_per_device_{store,dispatcher,http,docs}_test.exs`,
amendments in `sync_membership_partition_http_test.exs`, `member_prev_content_http_test.exs`, `history_visibility_http_test.exs`.
Method: full read of all test files, story, ATDD report, oracle context; cross-checks against `server/lib` (`event_dispatcher/server.ex`,
`web/router/protected.ex`, `session/pg_store.ex`) and the test support modules. Not run (no docker, no DB). All 8 files parse with Elixir 1.20.4
(`Code.string_to_quoted!`); the `--warnings-as-errors` compile was NOT re-run here (needs deps), but a read-through found no unused helper,
unused alias or undefined-function call (new functions go through `apply/3`, the Spy has no `@behaviour`).

Verdict: coverage of the 14 Gherkin scenarios is complete and the suite is strong (the mutation table in the ATDD report is credible). 2 MAJOR findings, both in
the amendments of EXISTING tests (one test that becomes vacuous after the implementation and was missed, one timing margin that can fail a correct implementation).

## MAJOR

### M1. `sync_membership_partition_http_test.exs:1203` (AC22 503 test) becomes vacuous after the implementation and was not amended
`stored = fn -> T.sql!("SELECT since_token, last_event_id FROM sync_tokens WHERE user_id = $1 AND device_id = ''", [b.uid]).rows end` is read before and
after the failing request: `assert stored.() == before, "no token persisted on failure"` (l.1223). `b` is a device-bound session, so after this story its token
lives under the device key; the `''` row never exists, `before == []` and the assertion is `[] == []` for ANY implementation, including one that persists a
token (under the device key) on a 503. Today (red) it is meaningful, so nobody notices. The ATDD report only lists the L-2 anchor test (l.1302) as a
`device_id = ''` reader; l.1203 was missed (`grep "device_id = ''"` over `server/test` outside the new files finds exactly this line).
Fix: read by user only (`... WHERE user_id = $1`, as done for l.1302), and add a precondition `assert [_] = before` so the test cannot go vacuous again.

### M2. `sync_membership_partition_http_test.exs` AC10 ignored-users test: `assert ms < 150` against `timeout: 200` has a 50 ms margin
The amendment itself is justified (D11: the PUT of `m.ignored_user_list` is pending global account data, the next sync returns at once; the old
`ms >= 150` direction cannot hold any more) and it does not weaken coverage (the "waits when nothing is pending" property is pinned by the new suite:
`>= 250 ms` for timeout 300 in HTTP tests l.158, l.521, l.530). But an immediate answer is a full authenticated `/sync` (session lookup, positions, rooms,
~50 SQL statements). On a loaded CI runner (the repo has ~6 known flaky families in the full run) 150 ms is a realistic duration, so a CORRECT
implementation can fail this test. Skipping the wait is only observable if the timeout is large relative to the machine noise.
Fix: `timeout: 5_000` and `assert ms < 2_500` (same style as the new suite's `< 3_000` of 10_000); the rest of the test (no re-send, no leave) is unchanged.

## MINOR

### m1. `wait_polling/1` budget is 3 s and it is satisfied by ANY member of `user:<id>`
`S.wait_until(fn -> :pg.get_local_members("user:#{uid}") != [] end, 3_000)` is 3000 attempts of `Process.sleep(1)`: about 3 s. Before the sync Task joins the group
the route does authentication, the position read and the pending pre-check (3+ SQL round trips); under heavy load 3 s is not generous, and a miss shows as
"the sync never started polling" (a false failure). Raise to 10_000. Ordering is otherwise sound: the Task joins `user:<id>` BEFORE `sync_partition`, the
room groups and the first build (`server.ex` ~5986-5993), so a PUT or message sent after `wait_polling` is received or seen by the first build; no lost wake-up in the tests.
(A PUT between the route's pending pre-check and the group join is only repaired by the next sync: a design property of D11, not a test problem.)

### m2. Scenario 2 "bounded at the cause event" is asserted weakly
HTTP l.239-257 asserts `S.member_ev(S.leave_timeline(body, f.room), f.uid, membership)` (the leave/ban event is IN the window), not that the window ENDS at it
or that nothing newer is in it. The sibling suite `sync_membership_partition_http_test.exs` (~l.1290) asserts `List.last(timeline)["event_id"] == ban_id` and
`origin_server_ts <= left_at`. A device-B delivery that built the window from a wrong bound would pass here. Suggest: post one more message after the
cause and assert it is absent and the member event is the last one, for the three causes.

### m3. Source-text greps over-pin file layout (store static tests, docs "code docs", migration header)
- `store_test` l.522-539: `src =~ ":pg.get_members("`, `"pg_advisory_xact_lock(hashtextextended("`, `"sync_global|"`, `"sync_global_pos_seq"` in BOTH store sources, `"stream_pos"`/`"changed_pos"`.
- `docs_test` l.166-170: `refute route =~ ~r/device_id: "",\s*\n\s*full_state:/` (a formatting regex) and `route =~ "AccountDataStore.list_since"`.
- `migration_test` l.113: the header comment must name story, sequence and the four columns; static regexes that reject schema-qualified or `USING btree` DDL (l.84).
All of these are literally in the story contract, and the dynamic tests already pin the behaviour (pg_locks check of the exact key, wake-up recipients, the sequence in the migration test).
The greps fail a correct refactor (lock/sequence draw in a shared helper module, a split or reformatted route call). Keep only
`refute src =~ "get_local_members"` (the cluster-safety rule), drop or loosen the rest.

### m4. Spy-based dispatcher tests: exact call lists, partial seam
- `gets(calls) == [{:get, 2, [uid, dev]}]` and `[{:persist, 4, ...}]` (also at route level, l.302-303) pin that the route/core makes exactly ONE `get_since_token` call. D4 states "exactly one token upsert"; "exactly one get" is not in the story. A route that also reads the row fails a correct implementation. Prefer: all gets are `{:get, 2, [^uid, ^dev]}`, no `{:get, 1, _}`, no `{:persist, 3, _}` (the real D1/D2/D3 contract).
- The Spy implements only the six token functions but is installed as `:event_dispatcher, :pg_store_module`. If the dev routes `get_positions`/`advance_positions` through that seam (instead of the `PgStore` facade / `:session_manager` env named in the Sizing section) the Spy raises `UndefinedFunctionError`. Sizing makes the facade the contract, so this is only a note.
- The ETS table is owned by the test process while the Spy is installed globally via `Application.put_env`; a background process calling the Spy after the table died (between test exit and the `on_exit` restore) raises `badarg`. Unlikely; guard `log/1` or create the table in `setup_all`.

### m5. 413 test asserts the status only
HTTP l.375-376 asserts `conn.status == 413`; `protected.ex` l.939 answers `413 M_TOO_LARGE`. Add `assert T.json(conn)["errcode"] == "M_TOO_LARGE"`. (The limit 1_000_000 is matched correctly by 1_000_100 chars.) The 429 test asserts `M_LIMIT_EXCEEDED` but not `retry_after_ms` (pre-existing contract, optional).

### m6. Failure-direction coverage is narrower than the contract, and the failure test is intrusive
- Contract (Sizing / D9): `list_since` returns `{pos, []}` on a failed read, "both reads stay never-raising". Only `get_positions` and `advance_positions` failures are exercised (HTTP l.964: `sync_tokens` columns renamed). No test makes `list_since`, `changed_since?` or `pending_since?` fail (`grep "failed read|never-raising"` finds only moduledoc text). Extend the rename trick to `account_data.stream_pos` and `cross_signing_keys.changed_pos` (assert 200, `{pos, []}` / `false` at store level, and that the next sync still delivers).
- `ALTER TABLE sync_tokens RENAME COLUMN` on the shared throwaway database takes an ACCESS EXCLUSIVE lock and is a global state change; the `on_exit` restore swallows every error (`rescue _ -> :ok`), so a failed restore silently breaks every later test of the run with confusing `column does not exist` errors. At least re-raise/log when the restore fails.

### m7. Scenario 5 at route level is stochastic; the deterministic interleaving test models the route
HTTP l.458 (labelled "route level") writes through the STORE API (not HTTP) with `Process.sleep(rem(i*7,5))` jitter and 25 polls; it cannot deterministically catch the
race, and a wrong implementation can pass it. The deterministic test (`store_test` l.656) drives a test-local `request/4` helper that re-implements the
route's read/advance order, so it proves the store primitives, not the route. A route that wires the primitives into one shared max column is caught only by the
value assertions (`positions == {first_ad, 0}`, `{max_ad_pos, cs_pos}`; mutant M02), which is adequate. Say so in the moduledoc and drop "route level" from the describe name.

### m8. Statement-count re-pins (+3): reasonable, but comments are inaccurate and the pins couple to the reference SQL layout
Reasonable: +3 per `/sync`, constant (independent of the number of rooms: `member_prev_content` uses 3 rooms), the three numbers are mutually consistent
(initial 54->57 and 45->48; incremental 48->51), the `initial_sync_room` `{14, 3}` entry and the AC13 joined-room test are untouched, and the pins stay exact
(not loosened). Inaccurate: the added comments say "list_since / changed_since? REPLACE the flag readers one for one". True for the incremental path
(get_positions + pending_since? + advance_positions = +3, `changed_since?` replaces `consume_changed_flag`), but on the INITIAL path no cross-signing flag was ever read
(only with a `since`), so the +3 there is get_positions + advance_positions + `changed_since?` (new: D10 needs `cross_signing_pos`). The ATDD report says it right, the
file comments do not. The assertion message in `member_prev_content_http_test.exs` l.898 still says "the baseline of the code before the story: 57".
Coupling: a legitimate implementation that folds `get_positions` into `get_since_token`, or advances inside the token upsert (fewer statements), fails these tests; the Sizing
section already says "re-pin with a comment", acceptable under this repo's exact-count convention. Fix the comments only.

### m9. Docs tests carry cross-story tombstones
`docs_test` l.64-67 (`fc` stays `open`, `fe` stays CLOSED), l.73-86 (cj-cm status cells) and the sentence pin
`"After a successful `device_signing/upload`, the uploading user's own ID is surfaced in"` (l.148) break when the next stories (`fc`, closing/reformatting cj-cm) edit those rows.
This is the repo's docs-test convention (8 suites pin the id line), so INFO-level; note it for the `fc` story, which will fail the `fc ... open` assertion by design.

## INFO

### i1. Scenario -> test mapping (all 14 covered)
| # | Gherkin scenario | tests |
|---|---|---|
| 1 | two clients alternate | http l.135 (control), l.150, l.179, l.199, l.215 |
| 2 | leave / kick / ban to the other client (outline x3) | http l.239 (generated for leave, kick, ban) |
| 3 | global account data per device, echo, no repeat | http l.264, 277, 296, 304, 315, 327, 343, 353, 370, 385; store l.116-278 |
| 4 | own cross-signing change, every device once | http l.402, 420, 434, 446; store l.285-350 |
| 5 | interleaving, two columns | store l.656, 683, 698 (+ l.563 GREATEST per column); http l.458 (stochastic) |
| 6 | PUT wakes a waiting / following long-poll | http l.490, 501, 512, 525; store l.425-519 (recipients, after commit, none on failure, none for cross-signing), l.522 (static) |
| 7 | initial sync / fallback: real anchor + positions + D10 | http l.540, 563, 583, 596, 603; dispatcher l.120, 142, 159, 168, 181 |
| 8 | no device id keeps per-user behaviour | http l.621, 644, 668, 681; dispatcher l.132, 231, 307 |
| 9 | pre-change token falls back once | http l.700; dispatcher l.215 |
| 10 | foreign / malformed / empty / oversize since | http l.723, 738, 751, 776, 808, 820, 833; dispatcher l.253, 291 |
| 11 | deleted device's token -> 401 M_UNKNOWN_TOKEN, no row | http l.850 (POST /logout), l.863 (DELETE /devices/{A}); `assert_unknown_token` checks 401 + errcode + no soft_logout |
| 12 | re-created device id | http l.878 |
| 13 | device delete / logout / erasure removes rows | http l.894 (DELETE + delete_devices), 913 (erasure), 924 (/logout/all), 933 (deactivation); store l.621 |
| 14 | `fd` closed, cj-cm rows, id line | docs l.36-131 (+ 07-deployment, matrix-api-scope) |
Plus the migration file (19 tests: static DDL, introspection as runtime role, down/up on fresh and populated schema). No scenario without a test.
Decisions without a test (minor, for completeness): D2 lazy binding of a JWT switches to its device row (one fallback); D5 per-device anchor for an unresolved room; the
in-flight-vs-delete orphan row (accepted by the owner, cj (a)); OAuth token revocation as a device-teardown trigger (only legacy logout / DELETE devices / logout-all /
deactivation / erasure are exercised); two users with the SAME device id string (PK `(user_id, device_id)` makes this safe; a one-line test would pin the "key = user + device"
half of D1); "on any cluster node" of Scenario 6 (only the static `:pg.get_members` check; a multi-node test is impossible without `Node.start`, which the rules forbid).

### i2. Timing margins of the long-poll tests (judged for CI load)
| test (http l.) | wait / timeout | assertion | verdict |
|---|---|---|---|
| 158-160 alternation | timeout 300 | `ms >= 250` (lower bound) | safe (load only lengthens); timers do not fire early |
| 165-169 B woken by a message | 15 000 | `ms < 8_000` | safe |
| 490-498, 501-509, 681-693 woken by a PUT | 15 000 | `ms < 6_000` | safe, ~9 s margin |
| 512-523 pending pre-check | 10 000 | `ms < 3_000`, then `>= 250` of 300 | safe |
| 525-534 no spin | 5 000 / 300 | `< 3_000`, `>= 250` | safe |
| store 380, 396 second writer blocked | `Task.yield(.., 400) == nil` | false-PASS under load, never a false fail | acceptable |
| store 409 other user not blocked | 3 000 | generous | safe |
| store 444-474 wake after commit | commit trigger sleeps 0.5 s; reader reads at once | false-pass if the reader is >0.5 s late, never a false fail | acceptable |
| sync_membership_partition AC10 (amended) | 200 | `ms < 150` | NOT safe: see M2 |
Negative waits (`refute_receive .., 200/300`) are bounded and only weaken detection. The rate limiter is deterministic (frozen clock via `T.reset_rate_limits`; default `unique_ip` per request).
No fixed-sleep waits; the only `Process.sleep` is jitter inside the Scenario 5 writers (http l.468).

### i3. Other checks
- Test names: all `test "..."` names are under 200 chars including describe (max 199: http l.644 and l.751; 198: l.621 and l.833). No headroom: any describe/name edit crosses the limit.
- No global `Node.start`, no fixed cookies, no docker in tests (docker appears only in two moduledoc comments); random suffixes for the temporary triggers/functions; global env (`:event_dispatcher, :pg_store_module`, `:uia_fresh_auth_seconds`, rate-limit env) is restored in `on_exit`; all modules with global state are `async: false` (the docs test is `async: true`, read-only).
- Logging: assertion messages only print synthetic markers/ids; no chat content or credentials from real data; no `IO.puts/inspect/Logger` in the suite.
- Security: cross-device token reuse (http l.723, 738, dispatcher l.253), cross-user token reuse with a no-leak check and byte-identical rows of every X device (l.751), malformed / empty / 100 kB / overflowing-suffix `since` with byte-identical other rows (l.776), forged position suffix (l.820), request-parameter `device_id` ignored (l.808 + dispatcher l.291), cross-user account data marker (http l.385, store l.216), 401 M_UNKNOWN_TOKEN before any sync state is touched (l.850, 863). Good.
- Matrix codes / statuses: 200 for every `since` variant (the spec defines no M_UNKNOWN_POS for `/sync` v3), 401 M_UNKNOWN_TOKEN (errcode asserted, no soft_logout), 413 (status only: m5), 429 M_LIMIT_EXCEEDED. Consistent with the story's 200-fallback contract.
- Crash/restart: no GenServer state is introduced (state is PostgreSQL rows), so no crash/restart test is required; the relevant failure direction ("deliver again, never miss") is tested once (m6). A crash of the sync Task between the core's token upsert and `advance_positions` is equivalent to the tested failed-advance case.
- Oversize `since` (100 kB) is sent through `Plug.Test` directly into the router; a real HTTP listener may reject a very long request line before the router (not verified here). The test pins the router contract only; the story's "oversize -> 200" should say so.
- Existing-suite amendments: AC10 flip (justified, see M2), L-2 anchor read (justified and correct, still the exact `[[anchor_event]] =` match), both statement-count re-pins (justified, m8). Missed amendment: M1.
- The `rate behaviour` test (140 initial syncs) is green today and passes for any implementation that leaves the limiter alone; a regression control with real runtime cost. Keep or drop; not a defect.
- The `next_batch` shape pin `~r/\A[^.]+\.\d+\z/` (http l.199) pins a token format owned by an earlier story and is green today; harmless control.
- Scenario 7 "only newer account data, no repeat" after a FALLBACK is asserted via the position column (`elem(positions, 0) == max_ad_pos`), not via an empty `account_data` in the next response; after an initial sync it is asserted via the response (l.315). Fine.
- `hold/1` in the store test has no cleanup if an assertion fails before `release/2` (the holder waits 15 s, holding a pooled connection and the per-user lock; random users, so no cross-test effect).
