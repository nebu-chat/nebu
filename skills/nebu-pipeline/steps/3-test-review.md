# Step 3: test-review — Pre-Dev Test Quality Gate

**Script first (`test_lint.py`), LLM only for what the script cannot decide.** **Agent:** `@nebu-test-reviewer` | **Model:** sonnet | **Mandatory**

This is the TDD gate. Poor tests produce poor implementations — review before dev starts.

```bash
python3 skills/nebu-pipeline/scripts/test_lint.py --story [STORY_FILE] --oracle-file [ORACLE_FILE or omit] \
  --report $STEP_RESULTS_DIR/[STORY_ID]/test-review-findings.md | tee $STEP_RESULTS_DIR/[STORY_ID]/test-lint.digest
```
Digest: `VERDICT`, `COUNTS` (incl. `judge=N`), `REPORT`, `TOP`, `LLM_NEEDED: yes|no`. The script decides coverage (every scenario has a test), leftover placeholders,
hard waits, brittle selectors, global state in async tests, missing assertions, crash/restart and e2e tests, Oracle error codes without a test.

- **`LLM_NEEDED: no`** and `TEST_REVIEW_LLM` is `auto` (default) → the report is final, no agent run. Go to *Evaluate*.
- **`LLM_NEEDED: yes`** (MINOR/JUDGE items exist) or `TEST_REVIEW_LLM: always` → launch `@nebu-test-reviewer`; it takes the script findings as final and only judges the JUDGE items:
```
STORY_FILE: [STORY_FILE]
CYCLE: 0
REPORT_FILE: $STEP_RESULTS_DIR/[STORY_ID]/test-review-findings.md
LINT_FILE: $STEP_RESULTS_DIR/[STORY_ID]/test-lint.md
ORACLE_FILE: [ORACLE_FILE or none]
```
  Before launching: `cp $STEP_RESULTS_DIR/[STORY_ID]/test-review-findings.md $STEP_RESULTS_DIR/[STORY_ID]/test-lint.md` (the agent overwrites the findings file).

## Evaluate

```bash
python3 skills/nebu-pipeline/scripts/pipeline_gates.py decide --step test-review --story [STORY_ID] --cycle 0 --apply $STATE_FILE --digest $STEP_RESULTS_DIR/[STORY_ID]/test-lint.digest
# agent ran: pass its digest instead →  decide … --digest - <<'EOF'
<the agent's digest lines, verbatim>
EOF
```
Prints `ACTION`, `STATE`, `MESSAGE`. `NEXT` → the state is already updated (`APPLIED`); show `MESSAGE`. `ASK_USER` (MAJOR gaps) → show `MESSAGE`, stop and wait:
"continue" → run `pipeline_state.py` with `STATE`; otherwise the user fixes the gaps and Step 2 restarts.
