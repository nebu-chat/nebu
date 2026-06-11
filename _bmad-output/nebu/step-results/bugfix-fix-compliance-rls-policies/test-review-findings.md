# Test Review — bugfix-fix-compliance-rls-policies

**Verdict: CLEAN after inline fixes (2 MAJOR fixed before dev start)**

## Issues found and fixed inline:

**[MAJOR-1 — FIXED] AC3 idempotency not tested**
Added `TestMigration_ComplianceRLSHardening_Idempotent` — reads raw SQL from embedded FS, executes it twice, asserts no error.

**[MAJOR-2 — FIXED] AC4 INSERT/SELECT not explicitly tested**
Added `TestMigration_ComplianceInsertSelectUnchanged` — explicitly asserts INSERT and SELECT via nebu_app succeed after migration 003.

**[MINOR-1 — FIXED] AC1 rejected status not covered**
Added `TestMigration_ComplianceRequestsRejectedUpdateBlocked` — tests that rejected rows are also immutable.

**[INFO-2 — FIXED] Stale error message in migrations_test.go**
Updated "four expected" → "six expected" in `TestFS_NoLegacyMigrationFiles`.

## Final test coverage:

| AC | Test(s) | Status |
|---|---|---|
| AC1 (pending allowed) | TestMigration_ComplianceRequestsUpdatePolicy | ✓ |
| AC1 (approved blocked) | TestMigration_ComplianceRequestsUpdatePolicyBlocked | ✓ |
| AC1 (rejected blocked) | TestMigration_ComplianceRequestsRejectedUpdateBlocked | ✓ |
| AC2 (active allowed) | TestMigration_ComplianceSessionsUpdatePolicy | ✓ |
| AC2 (revoked blocked) | TestMigration_ComplianceSessionsUpdatePolicyBlocked | ✓ |
| AC3 (idempotency) | TestMigration_ComplianceRLSHardening_Idempotent | ✓ |
| AC4 (INSERT/SELECT unchanged) | TestMigration_ComplianceInsertSelectUnchanged | ✓ |
