# Step 1c: Classify Story

```bash
mkdir -p $STEP_RESULTS_DIR/[STORY_ID]/
STORY_FLAGS=$(python3 skills/nebu-pipeline/scripts/classify_story.py --story [STORY_FILE])
```

Parse and store: `MATRIX=[.matrix]`, `UI=[.ui]`, `INFRA=[.infra]`, `SEC_REVIEW=[.security_review]`.
(`security_review` is derived from the story text and the Elixir security path patterns of `sec_prescan.py`; Step 7 re-checks it against the real diff.)
