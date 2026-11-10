# test-cleanup-rls-noop-delete: before / after evidence

Method: ONE fresh stack (`docker compose down --volumes`, `up -d --wait`, minio on 19000/19001). A probe script runs each of the 14 suites ALONE
(`mix test --include integration <file>` in the Makefile's `elixir:1.19-alpine` container) and, after each suite, lists what is still in the database:
`server_config` rows that are not in the fresh baseline (or have another value) and `audit_log` rows written since the suite started. The state is reset
with the superuser (`psql -U nebu`) between suites, so each suite is judged on its own. "Before" = HEAD f9f58c45 test code, "after" = the fixed tests.
Probe and raw output: scratchpad `rp/` (`before.txt`, `before_mod.txt`, `after.txt`, `after_ls.txt`, `guard_before.log`).
Roles on the stack: `nebu_app` (runtime, RLS applies, not the table owner), `nebu_migrate` (owner, bypasses RLS).

| suite | left behind BEFORE | left behind AFTER |
|---|---|---|
| web/log_store_test | `log_collect_debug=false`, `log_collect_info=false`, `log_retention_debug_days=second-value`, `log_retention_debug_max_count=second-value`, `log_retention_info_days=second-value`, `log_retention_info_max_count=750` | nothing (first after-run still left `log_collect_debug/info=false`: the DEBUG broadcast test wrote them with no cleanup at all; fixed, `after_ls.txt` clean) |
| web/log_store/handler_test | `log_collect_debug=false`, `log_collect_info=false` | nothing |
| web/log_store/writer_test | `log_collect_info=true`, `log_collect_debug=false` (info persistence stays ON for the live stack) | nothing |
| admin/logs_live_test | `log_collect_debug=false` (+ `bootstrap_completed=true`) | nothing of ours; `bootstrap_completed=true` stays by design (the suite sets its own bootstrap precondition, like the sibling admin suites; not a DELETE cleanup) |
| admin/admin_scope_mode_test | `admin_oidc_refresh_mode=offline` | nothing |
| admin/logs_controller_test | `log_collect_debug=true`, `log_collect_info=false`, 4 retention keys `""` | nothing |
| oauth/oauth_config_test | `oauth_enabled=false` (key was absent before; the old on_exit wrote it) | nothing (key absent again) |
| matrix/sso_scope_mode_test | `matrix_oidc_refresh_mode=offline` | nothing |
| matrix/matrix_user_id_test, matrix/sso_login_configured_claim_device_test | nothing on a seeded DB (`oidc_user_id_claim` exists, the upsert-restore worked); the `nil` branch (key absent) ended in a no-op DELETE | nothing; absent key is removed again, claim cache invalidated |
| media_admin_actions_test | 5 `audit_log` rows (`media_blocked/unblocked/deleted/rescanned/infected_override`, one each, from the two allowlist tests) | none |
| workers/media_cleanup_worker_integration_test | 15 `audit_log` rows (`media_deleted` 9, `media_hard_deleted` 6) | none |
| workers/media_released_auto_delete_worker_integration_test | 1 `audit_log` row (`media_released_auto_deleted`) | none |
| matrix/moderation_routes_http_test | 3 rows for its own `!audit-pin-*` room (`room_member_banned/kicked/unbanned`, one each; the other ~480 rows are ordinary room traffic of the other tests, not cleaned by design) | none for `!audit-pin-*` |

All 14 suites: 0 failures before and after (test counts identical: 13, 15, 5, 28, 6, 26+1 skipped, 42, 2, 21, 5, 30, 8, 1, 133).

## Guard test (`server/test/nebu/test_cleanup_rls_guard_test.exs`)

Before the fix (tests of HEAD, guard added): `2 tests, 1 failure`, 23 offending lines in 15 files (`guard_before.log`). After: `2 tests, 0 failures`.

## Outside server/test (reported, not changed)

- `e2e/fixtures/db.ts` (lines 319, 367, 818) deletes `server_config` rows through `psql` as the privileged `nebu` role (docker exec `psql -U nebu`, or `NEBU_DB_URL` of the
  privileged role in CI): not a no-op. `e2e/tests/features/admin/bootstrap.spec.ts`, `Makefile` (line 283) and `CONTRIBUTING.md` (line 192) only mention such a DELETE in comments / docs
  (run by hand as the superuser).
- `tests/`, `test/`, `scripts/`: no match.
