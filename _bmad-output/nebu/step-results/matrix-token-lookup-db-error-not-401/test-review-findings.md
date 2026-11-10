# test-lint — matrix-token-lookup-db-error-not-401: 6 scenarios, 17 ExUnit tests, 0 e2e files
MINOR | server/test/nebu/web/oidc_plug_lookup_failure_test.exs:175 | test without assertion: "AC1: every fault form on the client route (whoami) answers 5" | assert the observable outcome
MINOR | server/test/nebu/web/oidc_plug_lookup_failure_test.exs:184 | test without assertion: "AC1: every fault form on the media routes answers 503 M_UNKN" | assert the observable outcome
MINOR | server/test/nebu/web/oidc_plug_lookup_failure_test.exs:223 | test without assertion: "AC6: unknown (random 64 hex) tokens get the same 503 under e" | assert the observable outcome
MINOR | server/test/nebu/web/oidc_plug_lookup_failure_test.exs:232 | test without assertion: "AC6: malformed opaque tokens (non-hex, short, long) get the " | assert the observable outcome
MINOR | server/test/nebu/web/oidc_plug_lookup_failure_test.exs:320 | test without assertion: "AC1: a VALID token under every fault form answers 503 (not 4" | assert the observable outcome
MINOR | _bmad-output/nebu/step-results/matrix-token-lookup-db-error-not-401/oracle-context.md | spec error code M_LIMIT_EXCEEDED is not referenced by any test | add a test for it or note why it does not apply
MINOR | _bmad-output/nebu/step-results/matrix-token-lookup-db-error-not-401/oracle-context.md | spec error code M_NOT_YET_UPLOADED is not referenced by any test | add a test for it or note why it does not apply
MINOR | _bmad-output/nebu/step-results/matrix-token-lookup-db-error-not-401/oracle-context.md | spec error code M_RESOURCE_LIMIT_EXCEEDED is not referenced by any test | add a test for it or note why it does not apply
MINOR | _bmad-output/nebu/step-results/matrix-token-lookup-db-error-not-401/oracle-context.md | spec error code M_TOO_LARGE is not referenced by any test | add a test for it or note why it does not apply
MINOR | _bmad-output/nebu/step-results/matrix-token-lookup-db-error-not-401/oracle-context.md | spec error code M_UNAVAILABLE is not referenced by any test | add a test for it or note why it does not apply
