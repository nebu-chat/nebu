# Step 1: create-story (lean)

**Agent:** `@nebu-lean-story` | **Model:** haiku | **Fresh context**

Lean story creation: the user provides a raw 1–3 sentence description. The agent
writes one story file with Gherkin acceptance criteria and an ISO traceability ID
(`REQ-<YYYY>-<NNN>`). No artifact loading, no web research, no git analysis.

```bash
STEP_DESC=$(python3 skills/nebu-pipeline/scripts/select_pipeline_step.py --step create-story)
```

Inject `[STEP_DESC]` into the `@nebu-lean-story` subagent, substituting:
- `[EPIC_NAME]` → the epic name (from `--epic` flag; for legacy numbered epics use `epic-<N>`)
- `[STORY_DIR]` → the story directory (`$STORY_DIR`)
- `[USER_INPUT]` → the raw story description from the user

After completion:
```bash
rtk git status
```

Note the created story file as `STORY_FILE`. Derive `STORY_ID` from the file basename
without the `.md` extension (e.g. `typing-indicators.md` → `typing-indicators`).

Update the pipeline state with the real story ID:

```bash
# Create step-results directory for this story — all step outputs persist here
mkdir -p $STEP_RESULTS_DIR/[STORY_ID]/

python3 skills/nebu-pipeline/scripts/pipeline_state.py \
  --file $STATE_FILE \
  --story [STORY_ID] --step atdd --done create-story \
  --log "[STORY_ID] TIMESTAMP create-story → [STORY_FILE basename]"
```

Show: `✓ Step 1: Story created → [STORY_FILE] ([TRACEABILITY_ID])`

## Story file location

```
docs/stories/
  mvp/ epic-1 … epic-9/        ← legacy numbered epics (do not move)
  phase2/ epic-10 … epic-15/   ← legacy numbered epics (do not move)
  phase3/                      ← legacy numbered epics 16+ (do not move)
  <epic-name>/story-slug.md    ← named epics (one dir per feature domain)
```

Story slug: lowercase, hyphen-separated, describes the behavior (`typing-indicators.md`). Named epic: verify the file landed in
`$STORY_DIR`, else `git mv`. Legacy epic: verify in `docs/stories/mvp/epic-{N}/` or `phase2/`.
`STORY_FILE` = `$STORY_DIR/<slug>.md` (named) or the legacy path.
