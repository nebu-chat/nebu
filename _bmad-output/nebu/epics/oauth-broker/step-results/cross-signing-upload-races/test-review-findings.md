# Test review: cross-signing-upload-races (pre-dev, step 3), 2026-10-28

(Saved by the orchestrator from the test reviewer's hand-back; the reviewer's harness was read-only. Condensed, all findings kept.)

49 tests reviewed (2 new files + the one-line change in `sync_rejoin_range_scan_bound_docs_test.exs`). **0 MAJOR, 9 MINOR, 8 INFO. Ready for dev.** Static review only; no docker or mix was run by the reviewer.

Every Gherkin scenario and decision D1-D8 / D-A1..D-A5 has a real test (D3 by source pin + mutant M19). No test is vacuous in the sense "passes without the race"; every wait is bounded (PG detects a deadlock in about 1 s); no suite hang. 42/42 mutants killed, the table covers the story. Test names at most 184 characters. Status/error codes match the premise code (first/idempotent upload 200, legacy replacement 403 M_FORBIDDEN, OAuth replacement 401 flows [m.oauth], erased user 403 M_USER_DEACTIVATED, failed read 500 M_UNKNOWN, merge failure entry M_INVALID_SIGNATURE in a 200). Id-line pin and `@original_g` verified against the current follow-ups.md.

## MINOR

- **MINOR-1** Log-material check partly vacuous in the scenario 5 upload pin: only the first request is inside `capture_log`; `other = T.device_signing_upload(w.s.at, new_keys)` runs outside, so the replacement path with a failed read is not log-checked. Fix: wrap both requests.
- **MINOR-2** `capture_log` only at `:warning` (config/test.exs): an info/debug line with key material would escape. Use `level: :debug` as `user_deletion_log_test.exs` does.
- **MINOR-3** `break_master_read!/0` (column-level REVOKE/GRANT on `cross_signing_keys`): (a) `on_exit(restore)` is registered AFTER the two privileged statements; (b) REVOKE and GRANT run on two connections, not atomic; (c) no guard against a non-test database, and a role-wide REVOKE persists if the BEAM is hard-killed. Fix: register on_exit first, one transaction/DO block, idempotent `restore_master_read!/0` in `setup_all`, assert `current_database()` looks like a test DB.
- **MINOR-4** Nothing deterministically kills the mutant "decision read and first-upload write in separate transactions" (D2). Fix: a source pin (the `put_keys` call and `lock_keys` sit in the same `Nebu.Repo.transaction` fun in `do_persist_cross_signing/3`) or record as accepted gap.
- **MINOR-5** Scenario 4 `:upload` writer is an idempotent re-upload against a stored row, not a first upload on an absent row (the Gherkin says first upload). Add a `:first_upload` kind with a fresh user or narrow the claim.
- **MINOR-6** "get_keys_for_update/1, if kept, delegates" is silently vacuous if the dev removes the function (D-A2), and M07's kill evaporates; make it an explicit conditional. `oauth_account_cross_signing_test.exs` ~621-636 still pins `get_keys_for_update/1` with `function_exported?`: the dev amends it (D-A2).
- **MINOR-7** Merge-failure raise branches weakly pinned: `{:raised, _reason} -> :ok` in the undecodable-row merge test accepts any raise (FunctionClauseError would pass). Pin `Exception.message(reason) =~ "merge failed"` as the column-fault merge test does.
- **MINOR-8** `seq() - before == 1` and `changed_pos == before + 1` are wrong on a never-drawn sequence (`last_value` stays 1 until the first draw): read `CASE WHEN is_called THEN last_value ELSE 0 END`.
- **MINOR-9** Source/docs pins brittle in places (exact parameter lists in `function_source/2`, literal `CrossSigningKeyStore.lock_keys(` so an alias fails, `def lock_keys(user_id) when is_binary(user_id)` and the spec text, `refute body =~ "get_keys_for_update"` scans comments). Acceptable given D6; the dev must read a failure there as a pin, not a bug. The id-line SHA pin is intentionally brittle: a later story that takes a follow-up id must amend this suite and the rejoin suite.

## INFO

1. Red tests fail for the right reason on today's code, except the seven non-existence `lock_keys/1` store tests, which die with `UndefinedFunctionError` shown as the misleading "did not wait for it": add `assert function_exported?(Store, :lock_keys, 1)` to `lock_keys_task/1` or a shared setup.
2. The OAuth variants never reach the "failure entry" branch on a correct implementation (the queued merge usually wins the row lock); the disjunction is right, the emulated variant covers the failure entry.
3. Scenario 4 pins are green on today's code by design (D-A5); the first simulated writer locks a uia row that does not exist; the second ignores the return of `Uia.mint_session/3` (assert `uia_count == 1` first); the 4-round barrier test is a probabilistic detector only.
4. Not asserted: the `error` text of 500/403, the challenge `params.m.oauth.url`/`session`, a Matrix-JSON 500 body for the merge raise, the 400 M_MISSING_PARAM branch against stored keys (covered elsewhere), approval rollback when the read inside `replace_with_approval/7` fails (unreachable by a column fault).
5. `legacy!/1` depends on the OIDC provisioning cache accepting the primed token after `deletion_status` is set.
6. `lock_keys/1` outside a transaction is untested (the xact advisory lock would be a silent no-op).
7. Device id collision odds about 1/65k (4 hex chars).
8. Rejoin diff correct and minimal.

## Requested before / during dev

MINOR-1, MINOR-8, MINOR-3, MINOR-7 (worth applying), plus INFO-1 and INFO-3 (cheap); MINOR-2, 4, 5, 6 as small additions; flag MINOR-9 and the `oauth_account_cross_signing_test.exs` amendment to the dev.
