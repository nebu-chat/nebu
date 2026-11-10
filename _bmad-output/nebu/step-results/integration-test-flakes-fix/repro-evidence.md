# integration-test-flakes-fix: before / after evidence

Method: a FRESH stack per run (`docker compose down --volumes`, `up -d --wait`, minio on 19000/19001), then `mix test --include integration <files>` in the Makefile's
`elixir:1.19-alpine` container. "Before" runs use the original test code (HEAD 00a0d28d, or an untracked copy of the original file) with the state that triggers
the defect injected through psql; "after" runs use the fixed code with the same injection. Logs: scratchpad `fl/` (`summary.txt`, `<name>.log`).

| item | reproduction (before, red) | after (green) |
|---|---|---|
| A war room uuid in URL | `war_room_test.exs:1079`, `war_room_sessions.id` default forced to `41413f41-...` (a `?` byte): `FunctionClauseError Floki.DeepText.get_text` (1 test, 1 failure). Default forced to `ff2f41ff-2f41-...` (`/` + non-UTF-8 bytes): `ExUnit.CLIFormatter` crashes in `:io.put_chars`, no summary, exit 1. Default uuid `2f3f2f23-...`: passes by luck (as in 80 % of real runs) | both forced ids: 1 test, 0 failures (`A_after_query_byte`, `A_after_slash_nonutf8`) |
| B rate-limit clock leak | new `rate_limit_helper_restore_test.exs` (unit, no stack): `:rate_limit_clock_fn was :error before the test and is {:ok, #Function<... reset_rate_limits/0>} after the cleanup of enable_rate_limit/0` (1 of 2 failed: ToDevice red, RoomKeys already correct) | 2 tests, 0 failures |
| C tick/0 | new `moderation_tick_test.exs`, event stamped 1.2 s ahead: `MatchError no match of right hand side value: :timeout` in `ModerationTestSupport.tick/0`; second test red (`tick/1` undefined) | 2 tests, 0 failures |
| D server_config / audit_log cleanup | triage isolation logs on the same tree (`iso/summary.txt`): `tcm` 2/9 red (audit rows of earlier runs, stale capture cache), `tracemap_boot` 3/16 red. Retention: orig `retention_test.exs:321` (INFO cap test) then `SELECT key,value FROM server_config`: `log_retention_info_max_count = 500` LEFT BEHIND | `trace_map_node_controls_test` alone fresh: 16/16 green; `temporary_capture_manager_test` alone: 9/9 green; retention cap test: all 6 policy keys neutral afterwards (`log_retention_info_max_count` empty); retention + sweeper: 11/11 green |
| E bootstrap precondition | triage: `tracemap` 16/16 red, `warroom_live` 6/13 red on a fresh DB; layouts indicator orig on fresh DB: 1 red (`{:redirect, "/admin/bootstrap"}`); `AdminOidcLoginTest "on_mount denies an admin whose capped session has expired"` red on a fresh DB (`bootstrap_completed: false` halts the mount: a 4th suite with the same defect, found in this run, fixed too) | war room page alone fresh 13/13; trace map alone 16/16; layouts 7/7; admin oidc login 34/34 |
| F shared-table assumptions | `admin_oidc_login_test` with 600 users sorting first: AC3, AC4, AC5 red (operator not in the first 500); `log_store/war_room_test` with an active session left behind: 2 `unique_violation war_room_sessions_single_active_idx`; `logs_live/war_room_test` ordering test with a foreign ended session: red | oidc 34/34, log_store war room 16/16, ordering test green, `matrix_client_compat_test` 68/68 (one assertion that compared the room name was adapted to the unique name: found by the first after-run, red 1/230, fixed) |
| F no deterministic repro | alert_notifier (job picked up by Oban before the assertion), membership_state_model_docs (pool/transaction timeout under load), matrix_client_compat on a REUSED database (needs more than 20 earlier runs of the file) | fixed by reading the defect; sso_login, alert_notifier, membership docs, member_prev_content, sync_membership_partition green in `F_misc_after` (230 tests, the single failure was the client-compat assertion above) |
| J perf opt-in | `make test-integration` ran RegressionSyncLoadTest (median 414-439 ms vs 150 ms) in every run | `make test-perf`: `Excluding [:test, :cluster, :integration, :no_repo]`, `Including [:perf]`, 2 tests (13540 excluded): the 150 ms budget still fails on this host (439 ms), the gate throughput test passes. `--include integration` must NOT be added (it pulls in the whole suite: found in the first J run) |

## CI gate (two fresh-DB full runs, `docker compose down --volumes` between)

Baseline (HEAD, `matrix-uia-authdone-else-if/ci-integration2.log`): 13448 tests, 31 failures. A first attempt after the fixes (`ci-integration-attempt0.log`, 17 failures) found three
more consequences, all fixed before the gate runs: B changed the clock of the to-device rate-limit suites (the helpers expect the base instant 5_000_000: 3 red, fixed), RetentionTest
INFO cap (seed in the future), LogStoreTest AC9 (active war room session left by another file).

| run | tests | failures | which |
|---|---|---|---|
| ci-integration1 | 13450 | 12 | RoomsFallbackNameTest x12 only (story G), `VS_BASELINE new=0 fixed=19` |
| ci-integration2 | 13450 | 12 | RoomsFallbackNameTest x12 only (story G), `VS_BASELINE new=0 fixed=19` |

`make test-unit-elixir`: exit 0. RegressionSyncLoadTest does not appear in either integration log (tag :perf).
