# Test review (pre-dev) oauth-client-revocation: 0 MAJOR, 10 MINOR. Fix in the staged tests as part of dev.
1 race_test.exs:74,101,126 "other side blocked" proven by Task.yield(..,700): poll pg_stat_activity/pg_locks (wait_event_type='Lock') bounded, then release.
2 oauth_client_revocation_test.exs:229-246 (AC3.3/3.4) oauth_end_client_sessions orders by user_id; block the user of the LAST sorted pair so partial rollback is really exercised.
3 oauth_client_revocation_test.exs:194,210-265 rollback fixtures need a jwt_device_binding (T.insert_jwt_binding!) and assert TokenDenylist.revoked? false + binding kept after a rolled-back revoke (CR4 after-commit only).
4 oauth_admin_clients_test.exs:676 refute(log =~ "none"|"empty"|"cors") substring: match exact header=value / WARNING line only; :675 loose.
5 revoked-status app-level paths untested: approve POST/confirm GET and reject POST on a revoked client; bulk removal of a domain holding approved/revoked rows (they survive) (oauth_admin_test.exs:900-925, admin_clients:426).
6 check order: marker before typed host (no marker + WRONG host -> re-auth 303), CSRF before fetch metadata; test :707 does not exercise its name.
7 e2e: add keyboard-only scenario (confirm page -> type host -> Enter -> toast) + label/aria assertions for confirm_host and reason (like @ac-bulk-remove-keyboard).
8 e2e/fixtures/oauth-admin.ts:45-52 fixed 6 s waitFor for the optional Dex grant screen: wait for either the grant button or the target URL.
9 admin_clients_test.exs:509 pins flash wording /audit/i: assert only that an error flash is set.
10 browser_post_strict_test.exs:66 add comma-merged duplicated form ("same-origin, same-origin") for mode/dest/user too.
INFO: capture_log level: :debug needs Logger level admitting debug (oauth_client_revocation_test:534, admin_clients:890; Phoenix param logging/filter_parameters could trip `_csrf_token`/reason strings: if so it is a real finding to fix in lib); some on_exit delete env instead of restore (fine if config/test.exs sets none); approve confirm page should keep the consequence text ("It will be able to sign in your users."); adr_033_test pins for AC12 not staged (add if any pin says "a decision is final"/"UPDATE is final": ADR line ~135).
