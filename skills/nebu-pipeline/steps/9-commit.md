# Step 9: commit

**One script call — no LLM, no hand-built commit steps.**

```bash
python3 skills/nebu-pipeline/scripts/finish_story.py --story [STORY_ID] [--epic <name>] [--bug]
```
It resolves all paths itself (`pipeline_env.py`) and runs in order: `commit_summary.py` (writes `commit-message.txt`: `<type>(<scope>): <title>`, a pipeline line, `Refs: REQ-ID`)
→ `update_sprint_status.py` (+ story frontmatter `status:`) and `git add` of both → `git commit -F` (no `Co-Authored-By` line) → traceability entry (`generate_traceability.py`, silent for legacy
stories without `traceability_id`, staged for the next commit) → `baseline-store` (only when the last integration run was on the final code: no `integration-stale` marker) → `pipeline_state.py --commit`
(zero the YAML fields, journal line `committed ✓ (COMPACT)`).

Output: `SUBJECT`, `CYCLES`/`DEFERRED_MINOR`/`REQ_ID`, one `✓` line per stage, the commit SHA and a `CONTEXT_HINT`. `STAGE_FAILED: <name>` + the tail of the output → show it, stop, user decides
(the stages before it are done and idempotent). `WARN:` lines (traceability/baseline) never block.
- Look at the subject first with `--dry-run` only if you doubt it; edit `commit-message.txt` and use `--no-commit` followed by `git commit -F …` only when the subject is plainly wrong.
- Show: `✓ Step 9: Committed. Pipeline state cleared.` and, when `CONTEXT_HINT` is present, pass it to the user in one sentence (see *Context hygiene* in the router).
