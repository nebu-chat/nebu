# CI-gate findings (cycle 0 → fix cycle 1) — device-key-directory
Source: isolated full gate run; failures that are NEW versus earlier gate logs and reproduce when run alone. All are regressions of EXISTING tests caused by the applied reference implementation. Do NOT weaken the existing tests silently: decide per item whether the code or the old pin is wrong, and justify in the digest.

MAJOR 1 | server/test/nebu/compliance/user_deletion_sweep_test.exs (3 tests: 77, 102, 137)
  The operator sweep SQL in docs/architecture/07-deployment.md and docs/compliance/gdpr-deletion-runbook.md does not delete from `device_list_changes`, although Nebu.Compliance.UserDeletion erases it (erased_tables/0). Both docs must list the same set of tables, and the sweep against a real DB must leave 0 rows of the erased user in device_list_changes. Fix the docs/sweep SQL (code is right).

MAJOR 2 | server/test/nebu/matrix/cross_signing_upload_races_test.exs:271 and :286
  Two concurrent first uploads of IDENTICAL keys / LEGACY callers must draw changed_pos exactly ONCE (`seq() - before == 1`); now 2 draws. Idempotent re-upload against stored keys must not draw a second changed_pos. Find why cross_signing_key_store.ex / device_list_store now draws an extra position (device-list change recorded for a no-op or inside the losing transaction) and make the idempotent/losing path draw nothing.

MAJOR 3 | server/test/nebu/matrix/to_device_sync_http_test.exs:233 (Scenario 3)
  A /sync without to-device traffic must keep the two-part token `<core>.<position>`; now the token is `s2_<core>|0|d8764` (three groups: the device-list position group is appended even when there is nothing to report). Keep the token format backward compatible: append the device-list group only when it carries information (traffic/changes), or otherwise reconcile with the story's stream tests (device_key_directory_stream_test/sync_http_test) — all of them must stay green.

Not a finding (flaky under load, passes alone): ToDeviceSendHttpTest "recipient restriction … joining opens it" (join! tick :timeout).
Known/unrelated: RoomsFallbackName, TraceMapNodeControls, TemporaryCapture, SsoLoginTest, ReleaseTest contiguity (migration 56/57 gap).
