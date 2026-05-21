---
name: nebu-pipeline-epic
description: Runs a full epic by iterating through stories, each in a fully isolated story pipeline sub-agent. Use when you want to implement all pending stories of an epic without manual step-by-step control.
---

# Nebu Pipeline — Epic Mode

Thin coordinator. For each pending story it spawns an isolated `nebu-pipeline` sub-agent with a fresh context. The sub-agent owns the full story lifecycle (create-story through commit). This coordinator only decides: next story, wait for user, or epic-complete gates.

**Why isolation matters:** each story sub-agent starts with zero accumulated context from previous stories. It works only with what its own steps produce — no stale findings, no cross-story bleed.

---

## Activation

**`nebu-pipeline-epic`** — ask user for epic name or number, then start.

**`nebu-pipeline-epic --epic <name>`** — start or resume named epic (e.g. `--epic matrix-presence`).

**`nebu-pipeline-epic --epic N`** — legacy: start or resume numbered epic N.

**`nebu-pipeline-epic --epic <name> --from <story-slug>`** — skip all stories before the given slug.

---

## Path Resolution

Resolve before Step 0 based on whether the epic is named or numbered.

**Named epic (`--epic <name>`):**
- `EPIC_ID` = `<name>` (e.g. `matrix-presence`)
- `STORY_DIR` = `docs/stories/<name>/`
- `STATE_FILE` = `_bmad-output/nebu/epics/<name>/pipeline-state.yaml`
- `SPRINT_STATUS` = `_bmad-output/nebu/epics/<name>/sprint-status.yaml`
- `STEP_RESULTS_DIR` = `_bmad-output/nebu/epics/<name>/step-results/`

**Legacy numbered epic (`--epic N`):**
- `EPIC_ID` = `N`
- `STORY_DIR` = `docs/stories/mvp/epic-N/` (or `phase2/` for N ≥ 10)
- `STATE_FILE` = `_bmad-output/nebu/pipeline-state.yaml`
- `SPRINT_STATUS` = `_bmad-output/implementation-artifacts/sprint-status.yaml`
- `STEP_RESULTS_DIR` = `_bmad-output/nebu/step-results/`

Pass `--epic <name>` to all `nebu-pipeline` sub-agent invocations so they resolve paths consistently.

---

## Step 0: Discover Pending Stories

```bash
find $STORY_DIR -name "*.md" 2>/dev/null | sort
```

For each file, check its status:
```bash
grep "^Status:" [STORY_FILE]
```

- `Status: done` → skip (already committed)
- `Status: ready-for-dev` or `Status: in-progress` or no status → pending
- `Status: review` → treat as in-progress (pipeline will resume)

Show the pending list with index and title (H1 line of each file):
```
Pending stories for epic [EPIC_ID]:
  1. [STORY_FILE] — [H1 title]
  2. ...

Total: [N] stories pending. Start? [Y/n]
```

If `--from <story-slug>` was given: skip all stories before that slug in the sorted list.

---

## Step 1–N: Story Sub-Agent Loop

For each pending story in order:

### Launch

Print: `▶ [[INDEX]/[TOTAL]] Story [STORY_ID] starting — isolated sub-agent`

Spawn a sub-agent with this prompt (no other context from previous stories):

```
Read and follow skills/nebu-pipeline/SKILL.md.

Story file: [STORY_FILE]
Story ID: [STORY_ID]
Epic: [EPIC_ID]

The story file already exists. Start from Step 1c (classify).
Skip Step 1 (create-story) — the story is already written.

[IF NAMED EPIC: Path configuration — use these values throughout all steps:]
[  STATE_FILE       = _bmad-output/nebu/epics/[EPIC_ID]/pipeline-state.yaml]
[  STEP_RESULTS_DIR = _bmad-output/nebu/epics/[EPIC_ID]/step-results/]
[  SPRINT_STATUS    = _bmad-output/nebu/epics/[EPIC_ID]/sprint-status.yaml]
[  STORY_DIR        = docs/stories/[EPIC_ID]/]
[IF LEGACY EPIC: omit the path configuration block — use legacy default paths]

Run all pipeline steps: 1c → 1b → 2 → 3 → 4 → 5 → 5b → 6 → 7 → 8 → 9.
For each step, use select_pipeline_step.py and extract_story_section.py as defined in the pipeline.

Cycle behavior (code-review MINOR findings): auto-cycle back to dev-story without asking.
Stop and surface to user only for:
  - MAJOR or CRITICAL code-review findings (user chooses fix/accept/stop)
  - CRITICAL security-review findings
  - CI gate failure
  - Pre-dev test-review MAJOR gaps

Step results are written to $STEP_RESULTS_DIR/[STORY_ID]/.
Use these files — not in-memory variables — as the authoritative source when
passing findings between steps. This ensures no stale context bleeds between steps.

On completion return exactly:
  DONE:[STORY_ID]:[compact pipeline summary]
  BLOCKED:[reason]
  FAILED:[reason]
```

### Handle Result

**`DONE`:**
```bash
python3 skills/nebu-pipeline/scripts/pipeline_state.py \
  --file $STATE_FILE \
  --log "[STORY_ID] TIMESTAMP epic-loop → story done"
```
Print: `✓ [[INDEX]/[TOTAL]] Story [STORY_ID] done — [summary]`
Continue to next story.

**`BLOCKED`:**
```
⏸ Story [STORY_ID] blocked: [reason]
Resolve the issue, then type "continue" to resume from this story,
or "skip" to move to the next story.
```
Stop and wait. On "continue": re-spawn the sub-agent with `nebu-pipeline --resume` context.
On "skip": log the skip and move on.

**`FAILED`:**
```
🔴 Story [STORY_ID] failed: [reason]
Epic paused. Investigate, then type "retry" to re-run this story
or "skip" to move to the next story.
```
Stop and wait.

---

## Step N+1: Epic Complete

After all stories are done:

### SEC Gate 2 — Mandatory Epic Security Review

Determine the epic base commit:
- **Named epic:** look for the feature branch start commit or the first story commit:
  ```bash
  rtk git log --oneline docs/stories/[EPIC_ID]/ | tail -1
  ```
  Or ask: "Epic base commit SHA or tag for `git diff [BASE]..HEAD`?"
- **Legacy numbered epic:**
  ```bash
  rtk git log --grep="epic-[N-1]-retrospective\|retrospektive\|epic-[N-1]" --oneline | head -3
  ```

```bash
STEP_DESC=$(python3 skills/nebu-pipeline/scripts/select_pipeline_step.py --step epic-security-review)
```

Spawn Kassandra sub-agent (model: opus, fresh context):
```
[STEP_DESC]
```
Substituting `[EPIC_BASE]` → base commit SHA, `[DATE]` → today, `{EPIC_ID}` → epic name or number.

**If CRITICAL or HIGH:**
```
🔴 Epic SEC Gate 2 found issues — report: [path]
Choose:
  (a) Create follow-up stories in next epic
  (b) Accept as risk with written justification
  (c) Fix now and re-run SEC Gate 2
```
Stop and wait.

**If CLEAN:**
Print: `✓ Epic [N] SEC Gate 2 — Kassandra clean.`

### Epic Wrap-Up

```
🏁 Epic [EPIC_ID] complete!

Next steps (run these yourself):
  /bmad-testarch-trace           — requirements-to-tests traceability matrix
  /bmad-retrospective            — epic retrospective
  /nebu-release close            — if this epic completes a release, close and tag

Security review artifact: _bmad-output/implementation-artifacts/epic-[EPIC_ID]-security-review-[DATE].md
```

Stop and wait for user.

---

## Error Handling

| Situation | Response |
|---|---|
| Story file not found | Warn, ask user to confirm path, stop if unresolved |
| Sub-agent times out | Treat as BLOCKED, surface to user |
| pipeline-state.yaml conflict | Read current state, show to user, ask how to proceed |
| `find` returns no files | "No story files found for epic [EPIC_ID] — check docs/stories/ structure" |
| SEC Gate 2 sub-agent fails | Stop, surface error, user decides |

---

## Resuming an Interrupted Epic Run

If the epic was interrupted (e.g., after story 3 of 8):

1. Re-run `nebu-pipeline-epic --epic N`
2. The coordinator reads story statuses from `grep "^Status:"` per file
3. Done stories (Status: done) are automatically skipped
4. The first non-done story starts fresh as a new isolated sub-agent

No manual state tracking needed — the story files themselves are the source of truth.
