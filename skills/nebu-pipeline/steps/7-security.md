# Step 7: security-review (SEC Gate 1 — conditional)

**Script prescan decides and prepares; Kassandra only verifies.** **Agent:** `@nebu-kassandra` | **Model:** opus | **Fresh context**

The full review scope (per-story output format, severity definitions, epic-review extension) lives in the agent definition
`.claude/agents/nebu-kassandra.md`. Do NOT load `skills/nebu-agent-kassandra/SKILL.md` or its `references/*.md` files.

```bash
rtk git add .
python3 skills/nebu-pipeline/scripts/sec_prescan.py --report $STEP_RESULTS_DIR/[STORY_ID]/sec-candidates.md
```
Prints `CANDIDATES: N (high=H medium=M low=L)`, `SEC_SUGGEST: required|optional|not-needed`, `REPORT: <path>` — grep-level candidates (SQL/command/atom/XSS/redirect/SSRF,
timing compare, secrets in logs, weak crypto, cookies, new routes, sensitive migrations) with file:line and CWE.

**Decision** (`SEC_REVIEW` = flag from Step 1c, `SEC_SUGGEST` = diff-based suggestion; the stricter one wins):

| `SEC_REVIEW` | `SEC_SUGGEST` | Result |
|---|---|---|
| `required` | any | run |
| `not-needed` or `optional` | `required` | **run** (the diff touches security-relevant code the story did not flag) — log `security upgraded by prescan` |
| `optional` | `optional` | ask: "Story marked optional — run security review now? [Y/n]" |
| `optional` / `not-needed` | `not-needed` | skip: `⏭ Step 7: Security review skipped (not-needed, 0 high candidates).` |

**If running:** launch `@nebu-kassandra` with this launch message and nothing else:

```
STORY_FILE: [STORY_FILE]
STORY_ID: [STORY_ID]
EPIC: [EPIC_NAME]
DATE: [YYYY-MM-DD]
CANDIDATES_FILE: $STEP_RESULTS_DIR/[STORY_ID]/sec-candidates.md
```

She verifies the candidates first, then reviews what the prescan cannot see (authorisation logic, business flaws), writes the audit report herself and replies with the digest
(`VERDICT: CLEAN | HIGH | CRITICAL`, `COUNTS`, `REPORT`, `TOP`).

## Evaluate (script)

```bash
python3 skills/nebu-pipeline/scripts/pipeline_gates.py decide --step security-review --story [STORY_ID] --git-add . --apply $STATE_FILE --digest - <<'EOF'
<the agent's digest lines, verbatim>
EOF
```
`ACTION: NEXT` → the script already ran `git add .` (stages the report) and updated the state (`APPLIED`); show `MESSAGE`.
`ACTION: ASK_USER` (CRITICAL, or HIGH when `blocking_severity: HIGH` in `.claude/security-agent.yaml`) → show `MESSAGE`, stop and wait. (a) fix → `STATE_FIX`, back to Step 4;
(b) accept with justification / (c) follow-up story / `continue` → `STATE`.

**Skipped:** `pipeline_state.py --file $STATE_FILE --step arc42-update --done security-review --log "[STORY_ID] TIMESTAMP security-review → skipped (not-needed)"`.
