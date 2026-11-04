# test-lint — device-key-directory: 5 scenarios, 5 ExUnit tests, 0 e2e files
MINOR | _bmad-output/nebu/epics/e2ee-client-support/step-results/device-key-directory/oracle-context.md | spec error code M_BAD_JSON is not referenced by any test | add a test for it or note why it does not apply
MINOR | _bmad-output/nebu/epics/e2ee-client-support/step-results/device-key-directory/oracle-context.md | spec error code M_FORBIDDEN is not referenced by any test | add a test for it or note why it does not apply
MINOR | _bmad-output/nebu/epics/e2ee-client-support/step-results/device-key-directory/oracle-context.md | spec error code M_INVALID_PARAM is not referenced by any test | add a test for it or note why it does not apply
MINOR | _bmad-output/nebu/epics/e2ee-client-support/step-results/device-key-directory/oracle-context.md | spec error code M_INVALID_SIGNATURE is not referenced by any test | add a test for it or note why it does not apply
MINOR | _bmad-output/nebu/epics/e2ee-client-support/step-results/device-key-directory/oracle-context.md | spec error code M_MISSING_PARAM is not referenced by any test | add a test for it or note why it does not apply

## Resolution (orchestrator, no reviewer agent)
- M_BAD_JSON, M_INVALID_PARAM, M_MISSING_PARAM: covered by the ~285 older tests (claim_http, claim_limits, changes_http, logging); the lint only inspects the 5 scaffold tests.
- M_FORBIDDEN, M_INVALID_SIGNATURE: belong to `/keys/signatures/upload` (cross-user master-key signature, signature check), moved to follow-up story `key-query-hardening` (REQ-2026-014) by the oracle SCOPE SPLIT. Not applicable here.
