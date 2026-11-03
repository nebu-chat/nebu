# Step 5b: UX Gate (conditional — UI stories)

**Agent:** `@nebu-ux-reviewer` | **Model:** sonnet | **Fresh context** | **Conditional**

**Condition:** `UI` flag from Step 1c, plus staged files:
```bash
rtk git diff --staged --name-only | grep "server/lib/nebu/admin/"
```

**If `UI=false` and no admin files staged:** `⏭ Step 5b: UX Gate skipped — not a UI story.`

**If UI story:** launch `@nebu-ux-reviewer` with this launch message and nothing else:

```
STORY_FILE: [STORY_FILE]
REPORT_FILE: $STEP_RESULTS_DIR/[STORY_ID]/ux-findings.md
```

## Evaluate (script)

```bash
python3 skills/nebu-pipeline/scripts/pipeline_gates.py decide --step ux-gate --story [STORY_ID] --digest - <<'EOF'
<the agent's digest lines, verbatim>
EOF
```
`ACTION: NEXT` → `pipeline_state.py --file $STATE_FILE <STATE>`, show `MESSAGE`. `ACTION: ASK_USER` (violations are blocking) → show `MESSAGE`, stop and wait; "continue" → run `pipeline_state.py` with `STATE`.
Skipped (not a UI story): `pipeline_state.py --file $STATE_FILE --log "[STORY_ID] TIMESTAMP ux-gate → skipped (no UI)"`.
