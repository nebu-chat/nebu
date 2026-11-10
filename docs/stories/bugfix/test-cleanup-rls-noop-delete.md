---
story: test-cleanup-rls-noop-delete
epic: bugfix
status: done
security_review: none
matrix: false
ui: false
---

# Bugfix — test cleanup through a no-op `DELETE FROM server_config` / `audit_log` (follow-up K of the flake triage)

Follow-up K of the `oauth-pages-redesign` flake triage, left open by `integration-test-flakes-fix` (D), which fixed only the five suites that were
provably breaking other tests. Test-only change under `server/test`; `server/lib` and the migrations are not touched.

## Problem

`server_config` has `FORCE ROW LEVEL SECURITY` and no DELETE policy; `audit_log` has a `FOR DELETE USING (false)` policy and the runtime role `nebu_app` is not the
table owner (migrations run as `nebu_migrate`). A cleanup `DELETE FROM server_config ...` / `DELETE FROM audit_log ...` through `Nebu.Repo` therefore affects 0 rows
(and the result is ignored): values a test wrote stay for the rest of the run and for the live server on the same database. About 20 suites still clean up like that
(log_store, log_store handler / writer, logs_live, logs_controller, admin / matrix scope-mode, oauth_config, the oidc user-id claim suites, the media audit suites,
moderation routes).

## Acceptance criteria

```gherkin
Scenario: A suite that writes server_config keys leaves them as it found them
  Given a database in which a test suite writes server_config keys (policy keys, scope modes, user-id claim, oauth token settings)
  When the suite has finished
  Then every key it touched has its previous value again (privileged restore: an absent key is absent again)
  And no value written by the suite is visible to the next suite or to the live server

Scenario: A suite that writes audit rows removes exactly its own rows
  Given a suite that creates audit_log rows for its own target ids
  When it cleans up
  Then those rows are really gone (privileged delete scoped to the suite's own target ids), not left behind by a silently ineffective DELETE

Scenario: The no-op cleanup cannot come back
  When a test file under server/test contains a plain `DELETE FROM server_config` or `DELETE FROM audit_log` that does not go through the privileged helper
  Then a guard test fails and names the file and line
```

## Out of scope

`server/lib`, migrations, suites already fixed by `integration-test-flakes-fix` (they stay as they are), anything outside `server/test` (tests/, e2e helpers are only
inspected and reported).

## Notes

- One helper, `Nebu.OAuth.TestSupport.restore_server_config_on_exit!/1` (next to `privileged_sql!/2`, the support module every cleanup of this kind already uses):
  snapshots the rows of the given keys with the privileged (migrate) role and registers an `on_exit` that deletes those keys again and re-inserts the snapshot.
- The "failing test first" is the reproduction on a fresh database (`_bmad-output/nebu/step-results/test-cleanup-rls-noop-delete/repro-evidence.md`): a probe runs
  each suite alone and lists what is still in `server_config` / `audit_log` afterwards (red before, clean after).
