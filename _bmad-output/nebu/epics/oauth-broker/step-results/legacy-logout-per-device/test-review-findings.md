# Test review (pre-dev) legacy-logout-per-device: 3 MAJOR, 9 MINOR. Fix in the staged tests as part of dev.
M1 (LLPD:183,358,225; T.world_snapshot oauth_test_support.exs:2068): the central property is asserted only over matrix_sessions + device tables + jwt_device_bindings. The OLD path also ran destroy_session(user) (legacy `sessions` / `sync_tokens` rows + ETS for ALL devices, event_dispatcher/server.ex ~1889). Seed sessions + sync_tokens rows (pattern oauth_device_teardown_test.exs:340) for every device incl. O, L2, V and the unbound-JWT case, add them to world_snapshot, assert survivors unchanged and the own device's removed after commit; optionally /sync still works for O. An implementation that also calls destroy_session(user) must fail.
M2 (LLPD:115-136 hold_lock): "blocked" proven by Task.yield(t,500) == nil: poll pg_stat_activity (wait_event_type='Lock', query FROM devices; pattern oauth_client_revocation_race_test.exs:18,73) bounded, before running in_txn, for AC8.1-8.4, 8.6.
M3 (LLPD:558-568 AC8.6): assert exactly one teardown: results of the two tasks sort to [{:ok,:ended},{:ok,:unknown}] (facade) or count outcome=ended / outcome=unknown log lines.
m1 LLPD:523-556 real race: hold_lock with [logout(f.l.at), legacy_refresh(f.l.rt)] queued then assert the order-independent invariant (no matrix_sessions row of (U,L), device gone, every token 401); the "teardown wins" order must use the real end_legacy_device not raw SQL.
m2 AC7.2/7.3 rollback also for failed kill-switch and blocks on devices / device_one_time_keys / device_fallback_keys; AC7.2 assert explicit jti key stays absent.
m3 LLPD:652-660 AC10 count brittle: filter `[info]` AND "legacy logout" (a WARNING on error may contain the phrase).
m4 LLPD:682 unbound line only requires `outcome=`: pin outcome=ended; exercise log for take-over (outcome=unknown), bound-JWT failure, unbound failure.
m5 LL1 "never request input": send a body/query naming another device id/user ({"device_id": "<O>"}) for opaque AND JWT paths and assert ignored.
m6 LL3 JWT re-check branches: binding present but devices row missing; opaque user_id mismatch.
m7 T.device_state/rows_snapshot count/hash only: hash the key rows (SELECT * ordered) for survivor devices.
m8 setup on_exit deletes :oauth_repo/:oauth_session_repo/:uia_fresh_auth_seconds instead of restoring (convention, low risk). m9 LLPD:130-135 assert Task result shape before assert_logout_ok (no KeyError hiding the cause).
INFO: i2 dedupe the take-over INSERT helper; i3 near-vacuous pins `ll_bullet(3) =~ ~r/devices/`; e2e only bound-JWT path (OAuth device manual).
Note: the existing matrix_router_test F-1 logout test (unbound JWT, integration) will now return 500 if the denylist DB is unreachable (expected LL5/LL8).
