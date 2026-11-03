# Step 1d: Baseline Integration Test

**Direct bash — no LLM. Mandatory.**

Establish the integration baseline BEFORE any code changes — it surfaces pre-existing failures that are NOT caused by this story.

**`BASELINE_CACHE` on:** first try to reuse the previous story's final integration log (same HEAD, clean code):
```bash
python3 skills/nebu-pipeline/scripts/pipeline_gates.py baseline-lookup \
  --dest $STEP_RESULTS_DIR/[STORY_ID]/baseline-integration.log
```
`HIT …` → skip the run below; failures recorded in the cached log count as pre-existing. Log
`baseline-integration → ✓ reused cached baseline`, show `✓ Step 1d: Baseline reused.`, continue with Step 2.
`MISS …` → run it:

```bash
make redeploy > $STEP_RESULTS_DIR/[STORY_ID]/redeploy.log 2>&1 || { tail -n 30 $STEP_RESULTS_DIR/[STORY_ID]/redeploy.log; echo "REDEPLOY FAILED"; }
make test-integration > $STEP_RESULTS_DIR/[STORY_ID]/baseline-integration.log 2>&1
BASELINE_EXIT=$?
tail -n 25 $STEP_RESULTS_DIR/[STORY_ID]/baseline-integration.log      # summary only — never print the full log into the context
```
(Redirect instead of `| tee`: keeps the full log out of the context, and `$?` is the exit code of `make`, not of `tee`.)

**If `BASELINE_EXIT != 0`:**
```
⚠ Baseline integration tests failing BEFORE any changes.
This means pre-existing failures exist in the codebase.
Document these as known failures and continue — do NOT abort the story.
Failing tests at baseline will be clearly distinguished from story-introduced failures in Step 5.
```
Log the result:
```bash
python3 skills/nebu-pipeline/scripts/pipeline_state.py \
  --file $STATE_FILE \
  --log "[STORY_ID] TIMESTAMP baseline-integration → ⚠ FAILING (pre-existing)"
```

**If `BASELINE_EXIT == 0`:**
```bash
python3 skills/nebu-pipeline/scripts/pipeline_state.py \
  --file $STATE_FILE \
  --log "[STORY_ID] TIMESTAMP baseline-integration → ✓ clean"
```

Show: `✓ Step 1d: Baseline integration test complete.`
