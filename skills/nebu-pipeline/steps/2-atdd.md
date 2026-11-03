# Step 2: atdd — Generate Failing Tests

**`ATDD_MODE` lean (default):** script scaffold → `@nebu-atdd` (sonnet) fills it → script verify. **`tea`:** legacy BMAD skill `bmad-testarch-atdd` (see the end of this file).
**Mandatory.** Skip only for pure infrastructure stories (Dockerfile-only, migration-only without logic; `INFRA` flag of Step 1c): `⏭ Step 2: Infra-only story — ATDD skipped.`

## Lean mode

1. **Scaffold (script, no LLM):**
```bash
python3 skills/nebu-pipeline/scripts/atdd_scaffold.py --story [STORY_FILE] [--domain <admin|media|matrix|…>]
# --bug "<description>" instead of --story for `--bug` runs (one regression test, tag ac: "bug-<slug>")
```
   Prints JSON (`test_file`, `feature_file`, `scenarios`, `added`). `{"error": …}` (story without Gherkin scenarios) → use **tea mode** below for this story.
   `--domain` only when the story's domain is not derivable from its path; the script picks the test directory itself.
2. **Fill (LLM, sonnet):** launch `@nebu-atdd` with this launch message and nothing else:
```
STORY_FILE: [STORY_FILE]
TEST_FILE: [test_file]
FEATURE_FILE: [feature_file or none]
ORACLE_FILE: [ORACLE_FILE or none]
```
   It replies `DONE tests=N red=N` (or `BLOCKED …` → show, stop, user decides).
3. **Verify (script, no LLM):**
```bash
rtk git add .
python3 skills/nebu-pipeline/scripts/atdd_verify.py --story [STORY_FILE] --report $STEP_RESULTS_DIR/[STORY_ID]/atdd-verify.md
```
   Digest `VERDICT: CLEAN|MINOR|MAJOR`. `MAJOR` (scenario without test, placeholder left, no assertion, green/compile error instead of red) → relaunch `@nebu-atdd` **once** with
   `VERIFY_FILE: $STEP_RESULTS_DIR/[STORY_ID]/atdd-verify.md` added, then verify again. Still `MAJOR` → show `TOP` + report, stop, user decides.
   `MINOR` → continue (the test review sees the file).

```bash
python3 skills/nebu-pipeline/scripts/pipeline_state.py \
  --file $STATE_FILE \
  --step test-review --done atdd \
  --log "[STORY_ID] TIMESTAMP atdd → N failing tests (lean, verified)"
# or: --log "[STORY_ID] TIMESTAMP atdd → skipped (infra)"
```
Show: `✓ Step 2: Failing acceptance tests generated and verified.`

## Tea mode (`ATDD_MODE: tea`, a story without Gherkin scenarios, or a `--bug` run)

```bash
STEP_DESC=$(python3 skills/nebu-pipeline/scripts/select_pipeline_step.py --step atdd)
```
Inject `[STEP_DESC]` into the subagent, substituting `[STORY_FILE]` and `[ORACLE_FILE]` (drop the `[IF ORACLE_FILE]` block when `none`). Do NOT paste story sections or the oracle
content — the agent reads them itself. It replies `DONE tests=N red=N`. Then run the verify script above (without the retry loop) and update the state as shown.
