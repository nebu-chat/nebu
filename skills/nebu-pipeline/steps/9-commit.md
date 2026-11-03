# Step 9: commit

**Script derives summary, commit message and traceability — no LLM.**

```bash
python3 skills/nebu-pipeline/scripts/commit_summary.py --state-file $STATE_FILE --story [STORY_ID] --story-file [STORY_FILE] \
  --results-dir $STEP_RESULTS_DIR/[STORY_ID] [--bug] [--epic <name>]
```
Prints `SUMMARY` (for sprint-status), `COMPACT` (for the log), `SUBJECT`, `MESSAGE_FILE`, `CYCLES`, `DEFERRED_MINOR`, `REQ_ID`. It reads the story's lines from the state log and the staged files
and writes a conventional-commit draft (`<type>(<scope>): <title>`, a pipeline line, `Refs: REQ-ID`). Use it as is; edit the message file only when the subject is plainly wrong.

**Pre-commit: update sprint-status.yaml**
```bash
python3 skills/nebu-pipeline/scripts/update_sprint_status.py \
  --file $SPRINT_STATUS \
  --story [STORY_ID] \
  --summary "[SUMMARY]" \
  --story-file [STORY_FILE]
rtk git add $SPRINT_STATUS [STORY_FILE]
```

**Commit** (no `Co-Authored-By` line):
```bash
rtk git commit -F $STEP_RESULTS_DIR/[STORY_ID]/commit-message.txt
```

**Post-commit: generate ISO traceability entry (no LLM — pure script):**
```bash
# TRACEABILITY_MATRIX resolves to _bmad-output/nebu/epics/<name>/traceability-matrix.yaml
# (named epic) or _bmad-output/nebu/traceability-matrix.yaml (legacy).
python3 skills/nebu-pipeline/scripts/generate_traceability.py \
  --story [STORY_FILE] \
  --commit HEAD \
  --matrix $TRACEABILITY_MATRIX
rtk git add $TRACEABILITY_MATRIX 2>/dev/null || true
```
Skips silently for legacy stories without a `traceability_id` frontmatter field. Idempotent.

**Post-commit: cache the integration baseline for the next story (`BASELINE_CACHE`):**
```bash
test -f $STEP_RESULTS_DIR/[STORY_ID]/integration-stale || \
  python3 skills/nebu-pipeline/scripts/pipeline_gates.py baseline-store \
    --src $STEP_RESULTS_DIR/[STORY_ID]/ci-integration.log
```
(Only when the last integration run was on the final code; otherwise skipped silently.)

**Write final log entry and clear YAML fields:**
```bash
python3 skills/nebu-pipeline/scripts/pipeline_state.py \
  --file $STATE_FILE \
  --commit \
  --log "[STORY_ID] TIMESTAMP committed ✓ ([COMPACT])"
```

Show: `✓ Step 9: Committed. Pipeline state cleared.`
