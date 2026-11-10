# Step 4: dev-story — Implementation

**Agent:** `@nebu-dev-story` | **Model:** sonnet | **Fresh context**

The full prompt lives in the agent definition `.claude/agents/nebu-dev-story.md` (conventions, workflow, non-negotiable rules,
output digest). Do NOT load `bmad-dev-story`.

Launch `@nebu-dev-story` with this launch message and nothing else (paths, never content):

```
STORY_FILE: [STORY_FILE]
CYCLE: [CYCLE_COUNT]
TEST_REVIEW_FILE: $STEP_RESULTS_DIR/[STORY_ID]/test-review-findings.md   (or none if the file does not exist)
ORACLE_FILE: $STEP_RESULTS_DIR/[STORY_ID]/oracle-context.md              (or none)
CODE_REVIEW_FILE: $STEP_RESULTS_DIR/[STORY_ID]/code-review-findings.md   (cycle > 0 only, else none)
```

**Context fallback:** the dev agent always reads the whole story file, so no extra input is needed — see `steps/context-fallback.md`.

The agent replies with the dev digest (`VERDICT: DONE | BLOCKED`, `TESTS`, `FILES`, `BLOCKER`). The `SubagentStop` hook runs `invariant_check.py`; exit 2 → do not proceed to code-review.

```bash
python3 skills/nebu-pipeline/scripts/pipeline_gates.py decide --step dev-story --story [STORY_ID] --cycle [CYCLE_COUNT] \
  --git-add . --apply $STATE_FILE --digest - <<'EOF'
<the agent's digest lines, verbatim>
EOF
```
`ACTION: NEXT` → the script already ran `git add .` and updated the state (`APPLIED`) — just show `MESSAGE` (`✓ Step 4: Implementation complete. Cycle: N`).
`ACTION: STOP` (`BLOCKED`) → show `MESSAGE` (the blocker), stop, user decides.
