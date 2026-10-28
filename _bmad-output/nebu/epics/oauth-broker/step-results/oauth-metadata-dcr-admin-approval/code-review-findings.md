# Code review cycle 2 — oauth-metadata-dcr-admin-approval
No CRITICAL, no MAJOR. Cycle-0 MINORs, UX findings and both user decisions verified correct.

## MINOR (fix now)
M1. server/lib/nebu/admin/oauth_registrations_controller.ex:68 calls Nebu.OAuth.ClientStore.page_size() directly (ADR-020 public-API rule). Add Nebu.OAuth.page_size/0 (or equivalent) and use the facade only.
M2. e2e/step-definitions/admin/oauth-client-approvals.steps.ts:31 still says "RED: fails until the dev step ships migration 000040 ..." — stale RED prose; reword to current contract.
M3. server/test/nebu/oauth/oauth_test_support.exs:251-255 cleanup_clients/1 DELETEs as nebu_app and swallows errors; RLS silently deletes 0 decided rows -> tests (oauth_admin_test, 000040_oauth_clients_test, oauth_pending_protection_test) leak approved/rejected rows into persistent DBs. Clean up as a privileged role if available (like e2e/fixtures/db.ts uses `nebu`) or make tests independent of leftovers + document; do not swallow errors silently.
M4. docs/stories/oauth-broker/oauth-metadata-dcr-admin-approval.md:573 and :793 still name server/lib/nebu/config/oauth_config.ex; file moved to server/lib/nebu/oauth/config.ex (line 693 correct). Fix.
M5. server/test/nebu/oauth/oauth_client_store_test.exs:50 `refute File.exists?(.../config/oauth_config.ex)` is a legacy path-pin; keep as an explicit rename guard with a comment, or drop.
INFO (no action): I1 migration edited in place -> stale DBs (reset volumes); I2 INSERT policy WITH CHECK (true), decided->decided flips allowed (runtime role is the approver); I3 bulk-reject follow-up; I4 conservative false rejects (\p{Cf}); I5 IP-literal/intranet client_uri host yields internal CSP origin on click (follow-up: reject IP literals/private ranges); I6 audit not transactional; I7 uncached config reads; I8 over-redaction; I9 re-stage pipeline-state.yaml; I10 e2e selectors OK.
