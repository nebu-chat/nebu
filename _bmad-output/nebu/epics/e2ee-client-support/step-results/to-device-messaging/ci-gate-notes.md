# CI gate notes: to-device-messaging (REQ-2026-012)

Run via the isolated helper (`.e2ee-ci/`), 2026-11-02. Redeploy ok.

## Integration (full run, 12045 tests, 27 failures)
All failures are known families or load-related; none touch to-device.
- ReleaseTest `list_up_migrations` (migration contiguity): 58/59 sit above the 56/57 gap that lives on
  bugfix/oauth-session-lifetime-and-consent. Resolves when the OAuth branch merges first.
- RoomsFallbackNameTest: 12
- TemporaryCaptureManagerTest: 3
- AdminOidcLoginTest: 3
- RetentionTest: 2
- WarRoomTest, AdminStaleRooms, TraceMapNodeControlsTest: known flaky families
- SyncRejoinRangeScanBoundHttpTest: 3 (row-count bound; passes alone, 14/14; load-dependent, known load family)

## Other gates
- e2e (admin UI etc., CI tag exclusions applied): 147 passed, 7 skipped, exit 0.
- unit_nodb on Elixir 1.19: 6882 tests, only release_test red (known contiguity guard).

## Lesson: 255-char test names
The first gate attempt aborted at compile time because of a test name over 255 chars. The CI image
(Elixir 1.19) enforces the limit, the helper `quick.sh` (Elixir 1.20) does not. Fixed. Keep `quick.sh`
on 1.20 and check such things with `unit_nodb.sh 1.19-alpine`.

## Release checkbox remaining
Manual Element Web <-> FluffyChat SAS verification (see 11-risks).

## Cycle 4 (two-phase send, Kassandra cycle-1 MEDIUM fixed)
- Gate: redeploy ok; full integration `.e2ee-ci/ci-gate-integration-c4.log`: 12063 tests, 26 failures, all known families (RoomsFallbackName 12, AdminOidcLogin 3, TemporaryCaptureManager 3, TraceMapNodeControls 3, Retention 1, SsoLogin 1, MatrixSso 1, WarRoom 1, ReleaseTest contiguity 1); none touch to-device. E2E not re-run for this delta (it changes only to_device_store.ex; the e2e run of the previous gate passed 147).
- unit_nodb 1.19: only release_test (and the MemberSliceGate load flake, passes alone).
- Reviews: delta code review (sonnet) 0 MAJOR, 2 MINOR docs (fixed); Kassandra delta APPROVED, MEDIUM closed, 2 LOW recorded in 11-risks (12a/12b).
