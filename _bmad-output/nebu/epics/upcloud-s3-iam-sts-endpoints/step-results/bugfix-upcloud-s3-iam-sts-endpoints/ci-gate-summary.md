# CI Gate: bugfix-upcloud-s3-iam-sts-endpoints

## Fixed-code run (`ci-integration-retry.log`)
`make test-integration` (stack already redeployed with fix): **2635 tests, 34 failures, 3 skipped**, exit 2.

(First attempt, `ci-integration.log`, was externally killed ~9min in during `make redeploy && make test-integration` — unrelated to the suite itself; the already-up, healthy stack from that attempt was reused for the retry.)

## Baseline run (`baseline-integration.log`)
Code stashed back to unmodified `main`-equivalent state, full `make redeploy && make test-integration`: **2632 tests, 32 failures, 3 skipped**, exit 2.

(2635 vs 2632 = the 3 new `iam-sts-AT1/AT2/AT3` tests added by this bug fix — expected, not a discrepancy.)

## Comparison

Diffed failing test names between the two runs (see `comm -23`/`comm -13` output). Neither "only in fixed" nor "only in baseline" list contains any test referencing `StorageConfig`, `Media.Storage`, `ex_aws`, S3, MinIO, `iam_endpoint`, `sts_endpoint`, `runtime.exs`, or any Terraform-touched path — i.e. the actual surface this bug fix changes is fully green in both runs.

All 34 fixed-run failures and all 32 baseline-run failures belong to the same already-documented-flaky cluster:
- `Nebu.Admin.LogsLive.TraceMapTest` / `TraceMapNodeControlsTest` / `TraceMapNodeControlsContractTest` / `WarRoomTest` (admin LiveView log/tracemap suite — known test-fixture brittleness, see project memory `project_e2e_suite_health.md`)
- `Nebu.Web.SyncConcurrentTest` / `Nebu.Web.RegressionSyncLoadTest` (concurrency/latency timing assertions — inherently non-deterministic under load)
- `Nebu.Matrix.MatrixSsoTest` / `Nebu.Matrix.SsoLoginTest` / `Nebu.Admin.AdminLoginNoEnvOidcTest` / `Nebu.Admin.ConfigControllerTest` (OIDC/SSO env-config cluster)
- `Nebu.Admin.TemporaryCaptureManagerTest`, `Nebu.Admin.AdminStaleRoomsTest`, `Nebu.Web.LogStore.RetentionTest` (scattered singletons, same cluster's blast radius)

The specific failing subset differs between the two runs of effectively-identical-except-for-this-diff code (confirmed non-deterministic — matches the pattern already recorded for this exact cluster in the `bugfix-missing-migration-table-grants` pipeline run, 2026-10-01).

## Verdict

**CI gate: PASS.** No regression attributable to this bug fix. The 34 failures in the fixed-code run are pre-existing flakiness, not caused by this change.
