# Step 5: ci-gate — CI Verification

**Direct bash — no LLM. Mandatory.**

Rebuild the server image and run the full integration test suite against a fresh database.
This is the definitive quality gate — unit tests alone are not sufficient.

**Fast gate (`FAST_GATE_IN_CYCLES` on and `CYCLE_COUNT >= 1`):** a fix cycle only re-runs the unit suite.
Run `python3 skills/nebu-pipeline/scripts/test_digest.py --log $STEP_RESULTS_DIR/[STORY_ID]/unit.log -- make test-unit-elixir` (prints the digest: counts, failing tests with location, warnings — the full log stays on disk)
and skip the rebuild/integration below; the full gate is still owed once:
```bash
touch $STEP_RESULTS_DIR/[STORY_ID]/integration-stale   # full integration runs in Step 6b
```
Log `ci-gate → ✓ unit (fast gate, cycle [CYCLE_COUNT]; integration deferred to 6b)` and continue with Step 5b/6.
Cycle 0 always runs the full gate below.

```bash
# 1. Rebuild Docker image with the new code
make redeploy > $STEP_RESULTS_DIR/[STORY_ID]/redeploy.log 2>&1 || { tail -n 30 $STEP_RESULTS_DIR/[STORY_ID]/redeploy.log; echo "REDEPLOY FAILED"; }

# 2. Run full integration test suite (Gherkin E2E against real stack + fresh DB) — digest only, failures vs. the baseline
python3 skills/nebu-pipeline/scripts/test_digest.py --log $STEP_RESULTS_DIR/[STORY_ID]/ci-integration.log \
  --baseline $STEP_RESULTS_DIR/[STORY_ID]/baseline-integration.log -- make test-integration
INTEGRATION_EXIT=$?
```
(The wrapper's exit code is the exit code of `make`. The full log stays on disk; the digest prints the counts, `VS_BASELINE: new=N fixed=N same(pre-existing)=N` and only the NEW failures. Never print the full log into the context.)

**If `INTEGRATION_EXIT != 0`:**

The digest already compares against the baseline of Step 1d: `new=0` means every failure is pre-existing (still report it, but it is not caused by this story); `new>0` are the story's regressions.

```
🔴 CI Gate failed — integration tests failing after implementation.
See: $STEP_RESULTS_DIR/[STORY_ID]/ci-integration.log

Pipeline stopped. Fix the failing tests, then restart from Step 4 or Step 5.
Type "continue" to skip the CI gate (not recommended).
```
Stop and wait.

**If `INTEGRATION_EXIT == 0`:** additionally run the fast unit test suite:
```bash
python3 skills/nebu-pipeline/scripts/test_digest.py --log $STEP_RESULTS_DIR/[STORY_ID]/unit.log -- make test-unit-elixir
UNIT_EXIT=$?
[ $UNIT_EXIT -eq 0 ] && rm -f $STEP_RESULTS_DIR/[STORY_ID]/integration-stale   # integration is current again
```

```bash
python3 skills/nebu-pipeline/scripts/pipeline_state.py \
  --file $STATE_FILE \
  --step code-review --done ci-gate \
  --log "[STORY_ID] TIMESTAMP ci-gate → ✓ redeploy+integration+unit"
# or: --log "[STORY_ID] TIMESTAMP ci-gate → FAILED: [failing test name(s)]"
```

Show: `✓ Step 5: CI gate passed (full stack integration + unit tests).`
