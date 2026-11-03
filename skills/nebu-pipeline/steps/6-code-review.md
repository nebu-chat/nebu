# Step 6: code-review — Implementation Review

**Script prescan first, then the LLM.** **Agent:** `@nebu-code-reviewer` | **Model:** opus (cycle 0 / FULL) · sonnet (delta) | **Fresh context**

Track `CYCLE_COUNT` — starts at 0, read from pipeline-state.yaml on resume. Findings of every cycle overwrite
`$STEP_RESULTS_DIR/[STORY_ID]/code-review-findings.md` (the reviewer writes it; the coordinator never copies it).

```bash
rtk git add .
python3 skills/nebu-pipeline/scripts/review_prescan.py --oracle-file [ORACLE_FILE or omit] --report $STEP_RESULTS_DIR/[STORY_ID]/review-prescan.md | tee $STEP_RESULTS_DIR/[STORY_ID]/review-prescan.digest
```
Deterministic convention checks on the added lines (migration naming/pairing/contiguity, edited shipped migrations, `Code.eval*`, unsafe `binary_to_term`, `String.to_atom`,
leftover `IO.inspect`/`dbg`, skipped tests; HINTs for SQL interpolation, secrets in logs, spec error codes never produced). Digest `VERDICT` (MAJOR/MINOR/CLEAN), `COUNTS` (+`hints=N`).

**Short circuit (`PRESCAN_SHORT_CIRCUIT` on, `CYCLE_COUNT == 0`, prescan `VERDICT: MAJOR`):** do not launch the reviewer — the deterministic MAJORs already decide the cycle.
`cp $STEP_RESULTS_DIR/[STORY_ID]/review-prescan.md $STEP_RESULTS_DIR/[STORY_ID]/code-review-findings.md`, **skip `review-mark`** (no full LLM review happened, so the next cycle
must review in full) and go to *Evaluate* with `--digest $STEP_RESULTS_DIR/[STORY_ID]/review-prescan.digest`.

**Delta review (`DELTA_REVIEW` on and `CYCLE_COUNT >= 1`):** the full change was already reviewed — review only what the fix cycle changed.
```bash
python3 skills/nebu-pipeline/scripts/pipeline_gates.py review-delta \
  --mark $STEP_RESULTS_DIR/[STORY_ID]/reviewed-tree.txt \
  --out  $STEP_RESULTS_DIR/[STORY_ID]/review-delta.diff
```
`DELTA <n> lines -> <path>` → `REVIEW_DELTA_FILE = <path>`, launch the reviewer with `model: sonnet`.
`FULL` (no mark / delta too large) → full review on the default model, `REVIEW_DELTA_FILE = none`.
`EMPTY` → the dev cycle changed nothing: stop and ask the user. Cycle 0 always reviews in full.

Launch `@nebu-code-reviewer` with this launch message and nothing else (paths, never content):

```
STORY_FILE: [STORY_FILE]
CYCLE: [CYCLE_COUNT]
REPORT_FILE: $STEP_RESULTS_DIR/[STORY_ID]/code-review-findings.md
PRESCAN_FILE: $STEP_RESULTS_DIR/[STORY_ID]/review-prescan.md
TEST_REVIEW_FILE: $STEP_RESULTS_DIR/[STORY_ID]/test-review-findings.md   (or none)
ORACLE_FILE: $STEP_RESULTS_DIR/[STORY_ID]/oracle-context.md              (or none)
CODE_REVIEW_FILE: $STEP_RESULTS_DIR/[STORY_ID]/code-review-previous.md        (delta review only, else none)
REVIEW_DELTA_FILE: [path or none]
```
For a delta review run `cp $STEP_RESULTS_DIR/[STORY_ID]/code-review-findings.md $STEP_RESULTS_DIR/[STORY_ID]/code-review-previous.md` first — the reviewer overwrites the findings file.
On a context fallback add `FULL_STORY: yes` (see `steps/context-fallback.md`). After the launch (not on a short circuit):

```bash
rtk git add .
python3 skills/nebu-pipeline/scripts/pipeline_gates.py review-mark \
  --file $STEP_RESULTS_DIR/[STORY_ID]/reviewed-tree.txt
```

## Evaluate (script — do not reason about the verdict yourself)

```bash
python3 skills/nebu-pipeline/scripts/pipeline_gates.py decide --step code-review --story [STORY_ID] --cycle [CYCLE_COUNT] \
  --max-minor [MAX_AUTO_MINOR_CYCLES] --digest - <<'EOF'
<the agent's digest lines, verbatim>
EOF
```
Output lines `ACTION`, `STATE`, `STATE_FIX`, `STATE_ACCEPT`, `COPIED`, `MESSAGE`:

| `ACTION` | You do |
|---|---|
| `NEXT` (CLEAN) | run `pipeline_state.py --file $STATE_FILE <STATE>`, show `MESSAGE` → Step 6b/7 |
| `CYCLE` (MINOR, below the cap) | run `pipeline_state.py` with `STATE`, show `MESSAGE` → back to Step 4 with the new `CYCLE_COUNT` |
| `DEFER_MINOR` (MINOR at the cap) | the script already wrote `deferred-minor.md` (`COPIED`); run `pipeline_state.py` with `STATE`, show `MESSAGE` → Step 6b/7; mention the deferred count in the commit summary |
| `ASK_USER` (MAJOR/CRITICAL, or the 3-round limit) | show `MESSAGE` verbatim and wait. `fix` → `pipeline_state.py` with `STATE_FIX`, back to Step 4. `accept [reason]` → `STATE_ACCEPT` (add the reason to the log text), continue. `stop` → pause |

Show `✓ Step 6: …` as given in `MESSAGE`. Substitute `[STORY_ID]` nowhere by hand: `STATE` is ready to run (the word `TIMESTAMP` is replaced by `pipeline_state.py`).
