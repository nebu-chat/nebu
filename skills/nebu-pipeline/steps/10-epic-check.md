# Step 10: epic-check

**Script decides completeness, next story and diff base:**
```bash
python3 skills/nebu-pipeline/scripts/epic_status.py --epic <name>        # named epic
python3 skills/nebu-pipeline/scripts/epic_status.py --legacy <N>         # legacy numbered epic
```
Prints `STORIES: total=N done=N open=N`, `OPEN`, `NEXT`, `COMPLETE: yes|no`, `BASE: <sha>|unclear`, `BASE_SOURCE`.
(Finished = `done`/`superseded`/…; files without a status — reports, notes — are ignored.)

**`COMPLETE: no`:**
```
✅ Story done. Next open story: [NEXT]. Start it? [Y/n]
```
- `Y` → restart from Step 1 (create-story) · `n` → end pipeline

**`COMPLETE: yes` → SEC Gate 2 (mandatory):**

Epic base commit = `BASE` of the script. `BASE: unclear` → ask: "Epic diff base? (commit SHA or tag)".

Launch `@nebu-kassandra` (epic-review scope is inlined in `.claude/agents/nebu-kassandra.md`; do NOT load
`skills/nebu-agent-kassandra/SKILL.md` or its `references/*.md`) with this launch message and nothing else:

```
EPIC_BASE: [BASE]
EPIC_ID: [EPIC]
DATE: [YYYY-MM-DD]
```

She writes the mandatory audit report herself and replies with the digest (`VERDICT`, `COUNTS`, `REPORT`, `TOP`). Evaluate:
```bash
python3 skills/nebu-pipeline/scripts/pipeline_gates.py decide --step epic-security --story [EPIC] --apply $STATE_FILE --digest - <<'EOF'
<the agent's digest lines, verbatim>
EOF
```
`ASK_USER` (CRITICAL/HIGH) → show `MESSAGE`, stop: create follow-up stories in the next epic, or accept as risk with written justification. `NEXT` (CLEAN) → continue:

```
🏁 Epic complete!
Security review artifact: epic-[EPIC]-security-review-[DATE].md
Run /bmad-testarch-trace for the epic traceability matrix.
Retrospective next.
```
Stop and wait for the user.
