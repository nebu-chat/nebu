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
- `TRACEABILITY_MATRIX` = `_bmad-output/nebu/epics/<name>/traceability-matrix.yaml`

**Legacy numbered epic (`--epic N`):**
- `EPIC_ID` = `N`
- `STORY_DIR` = `docs/stories/mvp/epic-N/` (or `phase2/` for N ≥ 10)
- `STATE_FILE` = `_bmad-output/nebu/pipeline-state.yaml`
- `SPRINT_STATUS` = `_bmad-output/implementation-artifacts/sprint-status.yaml`
- `STEP_RESULTS_DIR` = `_bmad-output/nebu/step-results/`
- `TRACEABILITY_MATRIX` = `_bmad-output/nebu/traceability-matrix.yaml`

Pass `--epic <name>` to all `nebu-pipeline` sub-agent invocations so they resolve paths consistently.

---

## Step 0: Discover Pending Stories

```bash
python3 skills/nebu-pipeline/scripts/epic_status.py --epic <name>      # legacy numbered epic: --legacy <N>
```
Prints `STORIES: total=N done=N open=N`, `OPEN: slug, slug, …` (in file order), `NEXT`, `COMPLETE`, `BASE`. Stories with status `done`/`superseded` are finished; every other status
(`ready-for-dev`, `in-progress`, `review`) is pending; files without a `status:` (reports, notes) are ignored. No `find`/`grep` loop needed.

Show the pending list with index and title (`title:` of the story frontmatter):
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

Spawn a sub-agent (`model: sonnet` — it only orchestrates) with this prompt (no other context from previous stories):

```
Read and follow skills/nebu-pipeline/SKILL.md.

Story file: [STORY_FILE]
Story ID: [STORY_ID]
Epic: [EPIC_ID]

The story file already exists. Start from Step 1c (classify).
Skip Step 1 (create-story) — the story is already written.

[IF NAMED EPIC: Path configuration — use these values throughout all steps:]
[  STATE_FILE          = _bmad-output/nebu/epics/[EPIC_ID]/pipeline-state.yaml]
[  STEP_RESULTS_DIR    = _bmad-output/nebu/epics/[EPIC_ID]/step-results/]
[  SPRINT_STATUS       = _bmad-output/nebu/epics/[EPIC_ID]/sprint-status.yaml]
[  STORY_DIR           = docs/stories/[EPIC_ID]/]
[  TRACEABILITY_MATRIX = _bmad-output/nebu/epics/[EPIC_ID]/traceability-matrix.yaml]
[IF LEGACY EPIC: omit the path configuration block — use legacy default paths]

Run all pipeline steps: 1c → 1b → 1d → 2 → 3 → 4 → 5 → 5b → 6 → 6b → 7 → 8 → 9 (see the Tuning table in SKILL.md for the cycle and gate defaults).
Read each step's file (skills/nebu-pipeline/steps/<file>.md, see the step table in SKILL.md) right before you run it. Launch agents with file paths only
(never paste story text or reports); they answer with a 4-line digest and write reports to $STEP_RESULTS_DIR/[STORY_ID]/.

Cycle behavior (code-review MINOR findings): auto-cycle back to dev-story without asking, at most MAX_AUTO_MINOR_CYCLES times; leftover MINORs are deferred (deferred-minor.md), not looped.
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

The epic base commit is `BASE` of `epic_status.py` (named epic: parent of the first commit that added a story file; legacy: the previous epic's retrospective commit).
`BASE: unclear` → ask: "Epic base commit SHA or tag for `git diff [BASE]..HEAD`?"

Spawn `@nebu-kassandra` sub-agent (model: opus, fresh context) — the epic-review
scope is inlined in the agent definition `.claude/agents/nebu-kassandra.md`.
Do NOT load `skills/nebu-agent-kassandra/SKILL.md` or its `references/*.md` files.

Launch message (nothing else): `EPIC_BASE: <base commit SHA>`, `EPIC_ID: {N}`, `DATE: <YYYY-MM-DD>`. She writes the audit report herself and
replies with a 4-line digest (`VERDICT: CLEAN | HIGH | CRITICAL`, `COUNTS`, `REPORT`, `TOP`).

Evaluate with `pipeline_gates.py decide --step epic-security --story [EPIC_ID] --digest - <<'EOF' … EOF` (digest lines verbatim; `ACTION: ASK_USER` ⇒ the block below, `NEXT` ⇒ clean).

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

### Traceability Matrix — Bulk Backfill (one-time per epic)

After all stories are done, backfill the traceability matrix for any legacy
stories that don't have a `traceability_id` yet:

```bash
python3 skills/nebu-pipeline/scripts/generate_traceability.py \
  --bulk $STORY_DIR \
  --matrix $TRACEABILITY_MATRIX
```

This is a no-op for stories that already have entries. Use `--dry-run` first
to preview. Only `status: done` stories are migrated.

Then stage the results:
```bash
rtk git add $STORY_DIR $TRACEABILITY_MATRIX
```

### Epic Wrap-Up

```
🏁 Epic [EPIC_ID] complete!

Next steps (run these yourself):
  /bmad-retrospective            — epic retrospective
  /nebu-release close            — if this epic completes a release, close and tag

Security review artifact: _bmad-output/implementation-artifacts/epic-[EPIC_ID]-security-review-[DATE].md
Traceability matrix: $TRACEABILITY_MATRIX
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
