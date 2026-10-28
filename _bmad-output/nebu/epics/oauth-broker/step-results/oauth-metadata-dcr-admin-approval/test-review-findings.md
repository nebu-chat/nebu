# Test review (pre-dev) — oauth-metadata-dcr-admin-approval
Verdict: no missing AC coverage (AC1-AC8 all covered, spec error codes covered). 1 MAJOR, 6 MINOR, 6 INFO.

## MAJOR
M1. E2E steps flaky by construction: `locator.isVisible({timeout})` ignores the timeout (returns immediately). Used in confirmDialogIfAny(), rejectRow() (reason silently skipped), openPendingClients(), "decided every pending" loop. Fix: waitFor({state:'visible'}) with catch, or pin the UI contract and use expect().toBeVisible(); assert reason input visible whenever reason != ''.

## MINOR
m1. No test that register path (incl. GLOBAL bucket) survives deletion of ETS table :nebu_http_rate_limit_buckets (no 500, bucket recreated).
m2. Real config path untested (Nebu.OAuth.Config reading oauth_enabled/issuer from server_config, default false, non-https fail-closed); no test that runtime role may UPDATE server_config.oauth_enabled (000040 must extend the config_update_mutable policy; precedent: migration_oidc_scopes_mutable_test.exs).
m3. Global rate-limit test too weak: assert first_429 == 500 and all earlier non-429.
m4. E2E leaks state: oauth_enabled never reset (add After/AfterAll -> 'false', cleanup via clearOAuthClientsByNamePrefix; helper swallows DELETE failures and runtime role has no DELETE — use the privileged DB connection or document); "decide every pending" is destructive on a shared DB.
m5. Weak negatives: AC7 DEBUG `refute log =~ secret` passes vacuously (add positive assertion that a payload line / ***REDACTED*** appears); admin list `refute body =~ name` prefix collisions (use data-client-id); http-issuer test loose.
m6. Brittle static tests: client_store function_exported?/source greps duplicate behaviour tests; `dcr_policy|auto_approve` grep fails on a comment (narrow to identifiers/config keys); adr_033 regexes generic (add precise phrases: broker O2, https-for-all-URLs, title, ADR index entry); support restore helpers delete :rate_limit_disabled instead of restoring prior value.

## INFO
i3. Document in ATDD Decisions: malformed/array/empty JSON body => 400 invalid_request (OAuth shape); limiter runs BEFORE enabled-check and validation; admin list JSON wrapper keys.
