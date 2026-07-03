# Code-review verdict: 0 MAJOR, 1 MINOR, 5 INFO

## MINOR-1
run_post_login_provisioning/2's dead-code removal deletes the only observability for
Task.start/1 itself failing to spawn (VM-level resource exhaustion). No deploy config,
dashboard, or doc references the removed log string. The new comment overstates
certainty ("cannot... in practice") — soften wording or add a backlog note. Not
blocking.

## INFO (5, no action needed)
1. Comment accurate, well-sourced, follows repo convention (tags bugfix slug).
2. @spec unchanged, :ok return preserved, all 3 callers discard return value anyway.
3. All 11 confirm(...) call sites pass "instance_admin" explicitly — zero-risk cleanup.
4. No monitoring/alerting config depends on the removed log message string.
5. No doc drift (06-runtime.md / 08-concepts.md describe purpose/callers only).

## Out of scope note
scripts/verify-ci-config.sh is also modified in the working tree (unrelated,
pre-existing before this session) — must not be bundled into this bug's commit.

Verdict: cycle back to dev-story to address MINOR-1 (soften comment wording), then
proceed to security-review.
