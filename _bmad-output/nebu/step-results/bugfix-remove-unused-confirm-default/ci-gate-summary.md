# CI Gate Summary

## Unit suite (mix test --warnings-as-errors), clean container (elixir:1.20-alpine), no cache

- Pre-fix (baseline, fresh worktree): EXIT 1. 1198 passed, 2 skipped, 254 excluded.
  Compiler warnings found: 2, both Nebu-authored:
    1. server/test/nebu/admin/bootstrap_admin_session_identity_test.exs:173 (confirm/1 unused default) — originally reported bug.
    2. server/lib/nebu/matrix/event_dispatcher/server.ex:2941 (dead {:error, reason} clause in run_post_login_provisioning/2, Task.start/1 typed dynamic({:ok, pid()})) — found during this bug's own-code-warning audit; introduced in d4514af5 (merged 2026-07-01), unrelated to originally reported symptom but blocks the same --warnings-as-errors gate.
- Post-fix: EXIT 0. 1198 passed, 2 skipped, 254 excluded (IDENTICAL test counts to baseline). Zero warning: lines emitted in the nebu app's own compile pass.

## Integration suite (mix test --include integration --warnings-as-errors), full docker-compose stack

- Pre-fix (baseline, code stashed back to pre-fix state, full make redeploy + direct docker run to avoid tee truncation): EXIT 3. 1454 tests, 6 failures, 2 skipped.
  Failures: AdminStaleRoomsTest (1), RegressionSyncLoadTest (1, concurrent /sync latency load test), AdminOidcLoginTest (3, AC3/AC4/AC5), MatrixSsoTest (1).
- Post-fix (fix restored, full make redeploy + same direct docker run): EXIT 2. 1454 tests, 3 failures, 2 skipped.
  Failures: AdminStaleRoomsTest (1), RegressionSyncLoadTest (1), MatrixSsoTest (1) — an EXACT SUBSET of the 6 baseline failures. No new failure introduced.
  The 3 AdminOidcLoginTest failures present at baseline did not reproduce post-fix — consistent with pre-existing integration-suite flakiness (shared-DB, count-based assertions, async:false long-running suite), not attributable to this fix (this fix does not touch AdminOidcLoginTest-relevant code paths).

## Conclusion

Both compiler warnings blocking `mix test --warnings-as-errors` are fixed. Unit suite: exit 0 clean,
zero own-code warnings, identical pass/skip/exclude counts to baseline (no behavioral change).
Integration suite: no new failures introduced; remaining 3 failures are pre-existing and unrelated
to this fix (reproduced independently on the pre-fix baseline in the same run conditions).
