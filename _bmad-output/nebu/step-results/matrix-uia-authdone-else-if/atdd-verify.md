# atdd-verify (manual, tea/bug run)
atdd_verify.py could not run mix inside the sandbox (reported "no ExUnit summary"). Red run done in Docker instead:
server/test/nebu/matrix/uia_authdone_else_if_test.exs on HEAD ef0d86b6 = 3 tests, 2 failures (script text, CSP hash vs old script); the
frame-ancestors/CSP-guard test is green by design (pins unchanged behaviour). Green after the fix: 51 tests (this file + story-04 +
sso_login tests), 0 failures. Full-suite results: see the commit message / final report.
