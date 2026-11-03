# Step 6b: Final integration gate (conditional)

**Direct bash — no LLM.** Needed only if a fast-gate cycle changed code after the last full integration run.

```bash
test -f $STEP_RESULTS_DIR/[STORY_ID]/integration-stale && echo stale || echo fresh
```
`fresh` → `⏭ Step 6b: Integration already ran on the final code.`
`stale` → run the full gate of Step 5 (read `steps/5-ci-gate.md` if not already loaded) (`make redeploy`, `make test-integration` → `ci-integration.log`, compare with the baseline,
then `rm -f …/integration-stale`). On failure handle exactly like Step 5 (stop; the fix goes back to Step 4). It runs BEFORE
security-review so Kassandra reviews the final, verified code. Log `ci-gate-final → ✓ integration on final code`.
