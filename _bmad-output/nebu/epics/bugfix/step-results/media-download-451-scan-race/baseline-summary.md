Baseline (make test-integration, before any lib change; 2nd run — 1st run was killed 137 while an ATDD agent ran docker tests in parallel):
3265 tests, 63 failures, 4 skipped. 31 = new ATDD tests (media_download_stall_test.exs, expected red). 32 PRE-EXISTING failures, none in media:
admin_rooms_fallback_name_test (12), temporary_capture_manager_test (3), trace_map_node_controls_test (3), admin_oidc_login_test (3),
matrix_client_compat_test (2), war_room_test (2), log_store/retention_test (1), sync_concurrent_test (1), sso_login_test (1),
regression_sync_load_test (1), matrix_sso_test (1), config_controller_test (1), admin_stale_rooms_test (1).

CI gate (after dev-story; 1st run killed 137 right after `make redeploy`, 2nd run `make test-integration` alone): 3272 tests, 29 failures, 4 skipped.
All 29 in pre-existing unrelated areas (admin rooms/OIDC/logs-live/sync/SSO/log retention); 0 in media; all 42+ new stall tests green.
Only name not in baseline: LogStore.RetentionTest "AC8: DEBUG max-count cap" (498 != 500, same flaky family as baseline's INFO max-count failure) — unrelated.
