---
name: nebu-pipeline
description: Orchestrates the full Nebu dev lifecycle with TDD-first order, dev↔review cycles, conditional security and UX gates, and full resume capability via pipeline-state.yaml. Use --resume, --from <step>, or --bug.
---

# Nebu Pipeline

Orchestrates the complete Nebu development lifecycle. Thin and deterministic — owns sequencing and cycle logic only. Step agent prompts live in `pipeline-steps-spec.md`; select them with `select_pipeline_step.py`.

## Core Principles

- **TDD-First:** Tests are generated (ATDD), reviewed for quality, then implementation follows. No code before reviewed failing tests exist.
- **Resumable:** Every step writes `pipeline-state.yaml` before executing. Interrupted runs restart from their exact checkpoint.
- **Cyclic:** Code-review findings below MAJOR threshold go back to dev-story. The dev agent fixes, not the reviewer.
- **Declarative:** This workflow calls agents and TEA skills. It decides the sequence; they carry the domain intelligence.

## Path Configuration

Resolved at pipeline start from the `--epic` flag. All step commands use these variables — they override any hardcoded paths shown in the steps below.

**Named epic (`--epic <name>`, e.g. `--epic matrix-presence`):**
- `STATE_FILE` = `_bmad-output/nebu/epics/<name>/pipeline-state.yaml`
- `STEP_RESULTS_DIR` = `_bmad-output/nebu/epics/<name>/step-results/`
- `SPRINT_STATUS` = `_bmad-output/nebu/epics/<name>/sprint-status.yaml`
- `STORY_DIR` = `docs/stories/<name>/`
- `TRACEABILITY_MATRIX` = `_bmad-output/nebu/epics/<name>/traceability-matrix.yaml`

**Legacy numbered epic (no `--epic` flag, story ID like `"14-4"`):**
- `STATE_FILE` = `_bmad-output/nebu/pipeline-state.yaml`
- `STEP_RESULTS_DIR` = `_bmad-output/nebu/step-results/`
- `SPRINT_STATUS` = `_bmad-output/implementation-artifacts/sprint-status.yaml`
- `STORY_DIR` = `docs/stories/mvp/epic-{N}/` or `docs/stories/phase2/` (derived from story ID prefix)
- `TRACEABILITY_MATRIX` = `_bmad-output/nebu/traceability-matrix.yaml`

Ensure the configured directories exist before writing state:
```bash
mkdir -p $(dirname $STATE_FILE)
mkdir -p $STEP_RESULTS_DIR
```

## Pipeline State File

`{project-root}/_bmad-output/nebu/pipeline-state.yaml` — written before and after every step.

```yaml
# Nebu Pipeline State — written by nebu-pipeline, read by all nebu agents.
# Do not edit manually during an active pipeline run.
# last_updated: 2026-05-06
# [9-19] 2026-05-06T14:23Z code-review → 2 MINOR → cycle 1
# [9-19] 2026-05-06T14:15Z ci-gate → ✓ build+unit-go+unit-elixir+e2e+integration
# [9-19] 2026-05-06T14:05Z dev-story → done (cycle 0)
# [9-19] 2026-05-06T13:55Z test-review → CLEAN (0 MAJOR)
# [9-19] 2026-05-06T13:50Z atdd → 4 failing tests
# [9-19] 2026-05-06T13:45Z create-story → 9-19-sync-gap-fixes.md
# [9-19] 2026-05-06T13:44Z pipeline started
story: "9-19"
current_step: "code-review"
completed:
  - create-story
  - atdd
  - test-review
  - dev-story
  - ci-gate
cycle_count: 1
blocked_reason: null
last_updated: "2026-05-06T14:23Z"
```

**State updates use `pipeline_state.py` — never manually read or rewrite the file:**

```bash
python3 skills/nebu-pipeline/scripts/pipeline_state.py \
  --file $STATE_FILE \
  --step NEXT_STEP --done COMPLETED_STEP \
  --log "[STORY_ID] TIMESTAMP step → outcome"
```

Flags: `--story ID` · `--step STEP` · `--done STEP` (repeatable) · `--cycles N` · `--blocked REASON|null` · `--timestamp ISO` · `--commit` (zero YAML fields, keep all log lines). Combine in one call.

## Pipeline Log

Log entries are **prepended** directly below the `# last_updated:` comment line — newest first.

Format: `# [STORY_ID] YYYY-MM-DDTHH:MMZ step → compact outcome`

The log is **permanent and additive** — every step adds one line. Lines are never deleted or replaced. Only the YAML fields are zeroed on commit; all comment/log lines stay.

---

## Activation

**`nebu-pipeline`** (no args) — New story (legacy numbered epic). Ask for story description or file. Resolves paths to legacy state locations.

**`nebu-pipeline --epic <name>`** — New story in named epic. Resolves paths to `_bmad-output/nebu/epics/<name>/`. Ask for story description.

Then initialize state (the story ID is only known after Step 1 creates the file — use `pending`):

```bash
python3 skills/nebu-pipeline/scripts/pipeline_state.py \
  --file $STATE_FILE \
  --story pending --step create-story \
  --log "[pending] TIMESTAMP pipeline started"
```

**`nebu-pipeline --resume`** — Read `$STATE_FILE` (from `--epic` flag or legacy location). Print current state (story, step, cycle count). Ask user to confirm. Skip completed steps and continue from `current_step`.

**`nebu-pipeline --epic <name> --resume`** — Resume a named-epic pipeline.

**`nebu-pipeline --from <step>`** — Start at the named step. Ask for story context if needed.

**`nebu-pipeline --bug <description>`** — Bug-fix flow: skip `create-story`, start from `atdd` with the bug as context (write the failing regression test first, then fix).

Valid step names: `create-story` `atdd` `test-review` `dev-story` `ci-gate` `code-review` `security-review` `arc42-update` `commit`

---

## Story File Location

```
docs/stories/
  mvp/                     ← legacy numbered epics 1–9 (do not move)
    epic-1/ ... epic-9/
  phase2/                  ← legacy numbered epics 10+ (do not move)
    epic-10/ ... epic-15/
  phase3/                  ← legacy numbered epics 16+ (do not move)
  <epic-name>/             ← new named epics (one dir per feature domain)
    story-slug.md
```

**Named epic stories** (`--epic <name>`): `docs/stories/<name>/<story-slug>.md`

Story slug is lowercase, hyphen-separated, describes the behavior: `typing-indicators.md`, `gdpr-erasure.md`.

**When creating a story** (Step 1):
- Named epic: verify the file landed in `$STORY_DIR`. If not, move with `git mv`.
- Legacy epic: verify in `docs/stories/mvp/epic-{N}/` or `phase2/`.

**`STORY_FILE`** throughout the pipeline resolves to `$STORY_DIR/<slug>.md` for named epics, or the legacy path for numbered epics.

---

## Architecture: Native Subagents (Coordinator Pattern)

This SKILL is a **thin coordinator**. Domain intelligence lives in named subagents under `.claude/agents/nebu-*.md`.
Each subagent loads only the skills it needs (via `skills:` frontmatter) and only the MCP tools it uses.

| Step | Native Subagent | Skills loaded |
|---|---|---|
| create-story | `@nebu-lean-story` | (none — haiku, lean) |
| atdd | `/bmad-testarch-atdd` skill | code-review-checklist |
| test-review | `@nebu-test-reviewer` | code-review-checklist |
| dev-story | `@nebu-dev-story` | cluster-safety, no-domain-model, sql-placement |
| ci-gate | Direct bash (no LLM) | — |
| code-review | `@nebu-code-reviewer` | code-review-checklist, cluster-safety, no-domain-model, sql-placement |
| security-review | `@nebu-kassandra` | security-rules |
| arc42-update | Direct file edit | — |
| oracle-check | `@nebu-oracle` (conditional) | matrix-spec-rules |
| ux-review | `@nebu-ux-reviewer` (conditional) | ux-conventions |

**Automatic invariant check:** After `@nebu-dev-story` stops, the `SubagentStop` hook fires
`skills/nebu-pipeline/scripts/invariant_check.py` automatically — no explicit pipeline step needed.
If the script exits 2 (violations found), the pipeline receives an error and must not proceed to code-review.

## How Steps Are Invoked

Each step follows the same pattern:

1. Extract story context with `extract_story_section.py`
2. Fetch the agent prompt with `select_pipeline_step.py --step <name>`
3. Inject runtime values into the prompt (substitute `[PLACEHOLDERS]`; drop `[IF X — omit if null]` blocks when the variable is null/empty)
4. Launch the named subagent (see table above) with the assembled prompt
5. Save the output as a named variable (carries to subsequent steps)
6. Update `pipeline-state.yaml`

---

## Pipeline Steps

### Step 1: create-story (lean)

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

---

### Step 1c: Classify Story

```bash
# Ensure step-results directory exists (creation point when story already exists)
mkdir -p _bmad-output/nebu/step-results/[STORY_ID]/

STORY_FLAGS=$(python3 skills/nebu-pipeline/scripts/classify_story.py --story [STORY_FILE])
```

Parse and store: `MATRIX=[.matrix]`, `UI=[.ui]`, `SEC_REVIEW=[.security_review]`.

---

### Step 1b: Oracle Gate (conditional — Matrix features only)

**Agent:** `nebu-agent-oracle` | **Model:** sonnet | **Fresh context**

**If `MATRIX=false`:** `⏭ Step 1b: Oracle Gate skipped — not a Matrix feature.` Set `ORACLE_CONTEXT = null`.

**If `MATRIX=true`:**

```bash
ORACLE_INPUT=$(python3 skills/nebu-pipeline/scripts/extract_story_section.py \
  --story [STORY_FILE] --sections "Story" "Acceptance Criteria")

STEP_DESC=$(python3 skills/nebu-pipeline/scripts/select_pipeline_step.py --step oracle-gate)
```

Inject `[STEP_DESC]` into subagent, substituting `[ORACLE_INPUT]`.

Write output to disk (authoritative source for subsequent steps):
```bash
# [paste oracle-gate output here — the sub-agent's full response]
tee $STEP_RESULTS_DIR/[STORY_ID]/oracle-context.md
```

```bash
python3 skills/nebu-pipeline/scripts/pipeline_state.py \
  --file $STATE_FILE \
  --log "[STORY_ID] TIMESTAMP oracle-gate → spec context captured"
# or: --log "[STORY_ID] TIMESTAMP oracle-gate → skipped (no Matrix feature)"
```

Show: `✓ Step 1b: Oracle consulted — Matrix spec context captured.`

---

### Step 1d: Baseline Integration Test

**Direct bash — no LLM. Mandatory.**

Run the full integration test suite against the current codebase BEFORE any code changes.
This establishes a clean baseline and surfaces pre-existing failures that are NOT caused by this story.

```bash
make redeploy
make test-integration 2>&1 | tee $STEP_RESULTS_DIR/[STORY_ID]/baseline-integration.log
BASELINE_EXIT=$?
```

**If `BASELINE_EXIT != 0`:**
```
⚠ Baseline integration tests failing BEFORE any changes.
This means pre-existing failures exist in the codebase.
Document these as known failures and continue — do NOT abort the story.
Failing tests at baseline will be clearly distinguished from story-introduced failures in Step 5.
```
Log the result:
```bash
python3 skills/nebu-pipeline/scripts/pipeline_state.py \
  --file $STATE_FILE \
  --log "[STORY_ID] TIMESTAMP baseline-integration → ⚠ FAILING (pre-existing)"
```

**If `BASELINE_EXIT == 0`:**
```bash
python3 skills/nebu-pipeline/scripts/pipeline_state.py \
  --file $STATE_FILE \
  --log "[STORY_ID] TIMESTAMP baseline-integration → ✓ clean"
```

Show: `✓ Step 1d: Baseline integration test complete.`

---

### Step 2: atdd — Generate Failing Tests

**Skill:** `bmad-testarch-atdd` | **Model:** sonnet | **Fresh context** | **Mandatory**

**Skip if:** Pure infrastructure story (Dockerfile-only, migration-only with no logic). Show: `⏭ Step 2: Infra-only story — ATDD skipped.`

```bash
ATDD_INPUT=$(python3 skills/nebu-pipeline/scripts/extract_story_section.py \
  --story [STORY_FILE] --sections "Story" "Acceptance Criteria" "Acceptance Tests")

# Read oracle context from file (written by Step 1b — empty string if gate was skipped)
ORACLE_CONTEXT=$(cat $STEP_RESULTS_DIR/[STORY_ID]/oracle-context.md 2>/dev/null || echo "")

STEP_DESC=$(python3 skills/nebu-pipeline/scripts/select_pipeline_step.py --step atdd)
```

Inject `[STEP_DESC]` into subagent, substituting `[ATDD_INPUT]`; `[ORACLE_CONTEXT]` → value or drop block if empty.

```bash
python3 skills/nebu-pipeline/scripts/pipeline_state.py \
  --file $STATE_FILE \
  --step test-review --done atdd \
  --log "[STORY_ID] TIMESTAMP atdd → N failing tests"
# or: --log "[STORY_ID] TIMESTAMP atdd → skipped (infra)"
```

Show: `✓ Step 2: Failing acceptance tests generated.`

---

### Step 3: test-review — Pre-Dev Test Quality Gate

**Skill:** `bmad-testarch-test-review` | **Model:** sonnet | **Fresh context** | **Mandatory**

This is the TDD gate. Poor tests produce poor implementations — review before dev starts.

```bash
AC_SECTION=$(python3 skills/nebu-pipeline/scripts/extract_story_section.py \
  --story [STORY_FILE] --sections "Story" "Acceptance Criteria")

STEP_DESC=$(python3 skills/nebu-pipeline/scripts/select_pipeline_step.py --step test-review)
```

Inject `[STEP_DESC]` into subagent, substituting `[AC_SECTION]`.

Write output to disk:
```bash
tee $STEP_RESULTS_DIR/[STORY_ID]/test-review-findings.md
```

**If MAJOR findings:**
```
⚠ Pre-dev test-review found MAJOR gaps (see above).
Fix coverage before dev starts — bad tests produce bad implementations.
Type "continue" to proceed anyway, or fix the gaps and restart Step 2.
```
Stop and wait.

```bash
python3 skills/nebu-pipeline/scripts/pipeline_state.py \
  --file $STATE_FILE \
  --step dev-story --done test-review \
  --log "[STORY_ID] TIMESTAMP test-review → CLEAN (0 MAJOR)"
# or: --log "[STORY_ID] TIMESTAMP test-review → N MAJOR [user continued]"
```

Show: `✓ Step 3: Pre-dev test quality verified.`

---

### Step 4: dev-story — Implementation

**Agent:** `@nebu-dev-story` | **Model:** inherit (sonnet) | **Fresh context**

The full prompt lives in the agent definition `.claude/agents/nebu-dev-story.md`
(conventions, workflow, non-negotiable rules). Do NOT load `bmad-dev-story` —
the 485-line skill is replaced by the lean agent body + convention skills
(`elixir-otp`, `cluster-safety`, `no-domain-model`, `sql-placement`).

```bash
# Read step results from disk — authoritative, survives context compression
TEST_REVIEW_FINDINGS=$(cat $STEP_RESULTS_DIR/[STORY_ID]/test-review-findings.md 2>/dev/null || echo "")
ORACLE_CONTEXT=$(cat $STEP_RESULTS_DIR/[STORY_ID]/oracle-context.md 2>/dev/null || echo "")
CODE_REVIEW_FINDINGS=$(cat $STEP_RESULTS_DIR/[STORY_ID]/code-review-findings.md 2>/dev/null || echo "")
```

Launch `@nebu-dev-story`, substituting:
- `[STORY_FILE]` → path
- `[TEST_REVIEW_FINDINGS]` → value or drop block if empty
- `[ORACLE_CONTEXT]` → value or drop block if empty
- `[CODE_REVIEW_FINDINGS]` → value or drop block if empty (cycle 0)
- `[CYCLE_COUNT]` → current cycle number

**Context fallback (cycle > 0):** If the previous cycle's issues suggest the agent misunderstood story intent, replace `[STORY_FILE]` with full story content — see **Context Fallback Rule**.

After completion:
```bash
rtk git add .
rtk git status
```

```bash
python3 skills/nebu-pipeline/scripts/pipeline_state.py \
  --file $STATE_FILE \
  --step ci-gate --done dev-story \
  --log "[STORY_ID] TIMESTAMP dev-story → done (cycle [CYCLE_COUNT])"
```

Show: `✓ Step 4: Implementation complete. Cycle: [CYCLE_COUNT]`

---

### Step 5: ci-gate — CI Verification

**Direct bash — no LLM. Mandatory.**

Rebuild the server image and run the full integration test suite against a fresh database.
This is the definitive quality gate — unit tests alone are not sufficient.

```bash
# 1. Rebuild Docker image with the new code
make redeploy

# 2. Run full integration test suite (Gherkin E2E against real stack + fresh DB)
make test-integration 2>&1 | tee $STEP_RESULTS_DIR/[STORY_ID]/ci-integration.log
INTEGRATION_EXIT=$?
```

**If `INTEGRATION_EXIT != 0`:**

Compare failures against the baseline log from Step 1d:
```bash
diff $STEP_RESULTS_DIR/[STORY_ID]/baseline-integration.log \
     $STEP_RESULTS_DIR/[STORY_ID]/ci-integration.log | grep "^>" | head -20
```

```
🔴 CI Gate failed — integration tests failing after implementation.
See: $STEP_RESULTS_DIR/[STORY_ID]/ci-integration.log

Pipeline stopped. Fix the failing tests, then restart from Step 4 or Step 5.
Type "continue" to skip the CI gate (not recommended).
```
Stop and wait.

**If `INTEGRATION_EXIT == 0`:** additionally run the fast unit test suite:
```bash
python3 skills/nebu-agent-testing/scripts/ci_gate.py --story [STORY_ID] 2>/dev/null || \
  make test-unit-elixir
```

```bash
python3 skills/nebu-pipeline/scripts/pipeline_state.py \
  --file $STATE_FILE \
  --step code-review --done ci-gate \
  --log "[STORY_ID] TIMESTAMP ci-gate → ✓ redeploy+integration+unit"
# or: --log "[STORY_ID] TIMESTAMP ci-gate → FAILED: [failing test name(s)]"
```

Show: `✓ Step 5: CI gate passed (full stack integration + unit tests).`

---

### Step 5b: UX Gate (conditional — UI stories)

**Agent:** `nebu-agent-ux` | **Model:** sonnet | **Fresh context** | **Conditional**

**Condition:** Use `UI` flag from Step 1c and check staged files:
```bash
rtk git diff --staged --name-only | grep "gateway/internal/admin/"
```

**If `UI=false` and no admin/ files staged:** `⏭ Step 5b: UX Gate skipped — not a UI story.`

**If UI story detected:**

```bash
STORY_SECTIONS=$(python3 skills/nebu-pipeline/scripts/extract_story_section.py \
  --story [STORY_FILE] --sections "Story" "Acceptance Criteria")

STEP_DESC=$(python3 skills/nebu-pipeline/scripts/select_pipeline_step.py --step ux-gate)
```

Inject `[STEP_DESC]` into subagent, substituting `[STORY_SECTIONS]`.

**If blocking violations:**
```
⚠ UX Gate found accessibility violations (blocking).
Fix violations before code-review. Type "continue" to proceed with open violations.
```
Stop and wait.

```bash
python3 skills/nebu-pipeline/scripts/pipeline_state.py \
  --file $STATE_FILE \
  --log "[STORY_ID] TIMESTAMP ux-gate → CLEAN"
# or: --log "[STORY_ID] TIMESTAMP ux-gate → skipped (no UI)"
# or: --log "[STORY_ID] TIMESTAMP ux-gate → N violations [user continued]"
```

Show: `✓ Step 5b: UX audit passed.`

---

### Step 6: code-review — Implementation Review

**Skill:** `bmad-code-review` | **Model:** opus | **Fresh context**

Track `CYCLE_COUNT` — starts at 0, read from pipeline-state.yaml on resume.

```bash
AC_SECTION=$(python3 skills/nebu-pipeline/scripts/extract_story_section.py \
  --story [STORY_FILE] --sections "Story" "Acceptance Criteria")

# Read findings from disk
TEST_REVIEW_FINDINGS=$(cat $STEP_RESULTS_DIR/[STORY_ID]/test-review-findings.md 2>/dev/null || echo "")
ORACLE_CONTEXT=$(cat $STEP_RESULTS_DIR/[STORY_ID]/oracle-context.md 2>/dev/null || echo "")

STEP_DESC=$(python3 skills/nebu-pipeline/scripts/select_pipeline_step.py --step code-review)
```

Inject `[STEP_DESC]` into subagent, substituting:
- `[AC_SECTION]` → value
- `[TEST_REVIEW_FINDINGS]` → value or drop block if empty
- `[ORACLE_CONTEXT]` → value or drop block if empty
- `[CYCLE_COUNT]` → current cycle number

Write output to disk (overwritten each cycle — always the latest review):
```bash
tee $STEP_RESULTS_DIR/[STORY_ID]/code-review-findings.md
```

```bash
rtk git add .
```

#### Evaluate findings:

**If MAJOR or CRITICAL findings:**
```
⚠ Code-review found MAJOR/CRITICAL issues (see report above).
Choose:
  (a) "fix" — hand back to dev agent for a fix cycle
  (b) "accept [reason]" — accept with written justification
  (c) "stop" — pause pipeline
```
Stop and wait.
- `fix` → increment `CYCLE_COUNT`, update state, return to Step 4
- `accept [reason]` → record justification, continue to Step 7

**If only MINOR/INFO findings and `CYCLE_COUNT < 3`:**
```
Code-review found [N] MINOR findings. Sending back to dev agent for fixing.
Cycle [CYCLE_COUNT + 1] starting...
```
Increment `CYCLE_COUNT`. Update state. Return to Step 4. After dev completes, return here.

**If `CYCLE_COUNT >= 3` with same findings still present:**
```
⚠ Review cycle limit reached (3 rounds). Issues persist.
Type "accept" to proceed with open minors, or "stop" to investigate.
```
Stop and wait.

**If no findings (or INFO only):** `✓ Step 6: Code-review clean.`

```bash
# CLEAN path:
python3 skills/nebu-pipeline/scripts/pipeline_state.py \
  --file $STATE_FILE \
  --step security-review --done code-review \
  --log "[STORY_ID] TIMESTAMP code-review → CLEAN (cycle [CYCLE_COUNT])"

# MINOR path (cycle back to dev-story):
python3 skills/nebu-pipeline/scripts/pipeline_state.py \
  --file $STATE_FILE \
  --step dev-story --cycles [CYCLE_COUNT+1] \
  --log "[STORY_ID] TIMESTAMP code-review → N MINOR → cycle [CYCLE_COUNT+1]"

# MAJOR blocked / accepted: adjust --step and --log accordingly
```

---

### Step 7: security-review (SEC Gate 1 — conditional)

**Agent:** `@nebu-kassandra` | **Model:** opus | **Fresh context** | **Conditional**

The full review scope (per-story output format, severity definitions, epic-review
extension) lives in the agent definition `.claude/agents/nebu-kassandra.md`.
Do NOT load `skills/nebu-agent-kassandra/SKILL.md` or its `references/*.md` files —
the scope is inlined in the agent body (saves ~180 lines of reference loading per run).

**Decision:** Use `SEC_REVIEW` flag from Step 1c.
- `required` → run
- `optional` → ask: "Story marked optional — run security review now? [Y/n]"
- `not-needed` → `⏭ Step 7: Security review skipped (flagged not-needed).`

**If running:**

```bash
SEC_CONTEXT=$(python3 skills/nebu-pipeline/scripts/extract_story_section.py \
  --story [STORY_FILE] --sections "Story" "Acceptance Criteria")
```

Launch `@nebu-kassandra`, substituting `[SEC_CONTEXT]`, `[STORY_ID]`, `[DATE]`.

**If CRITICAL:**
```
🔴 Kassandra found CRITICAL findings — report: [path]
Pipeline stopped. Choose:
  (a) Fix and restart from Step 4
  (b) Accept with written justification
  (c) Move to follow-up story in next epic
Type "continue" to commit with open CRITICAL (strongly discouraged).
```
Stop and wait.

**If HIGH:** Check `blocking_severity` in `.claude/security-agent.yaml` (default: `CRITICAL`). If set to `HIGH`, treat as CRITICAL above. Otherwise warn and continue.

**If CLEAN:**
```bash
rtk git add .
```
Show: `✓ Step 7: Kassandra — clean.`

```bash
python3 skills/nebu-pipeline/scripts/pipeline_state.py \
  --file $STATE_FILE \
  --step arc42-update --done security-review \
  --log "[STORY_ID] TIMESTAMP security-review → Kassandra CLEAN"
# or: --log "[STORY_ID] TIMESTAMP security-review → skipped (not-needed)"
# or: --log "[STORY_ID] TIMESTAMP security-review → CRITICAL blocked"
```

---

### Step 8: arc42-update — Documentation Delta

**Agent:** `nebu-agent-arc42` (if available) or `bmad-maintain-arc42` (fallback) | **Model:** haiku | **Fresh context** | **Mandatory**

```bash
ls _bmad/memory/nebu-agent-arc42/ 2>/dev/null && echo "available"
# Sets ARC42_SKILL_PATH:
#   available → "skills/nebu-agent-arc42/SKILL.md"
#   fallback  → ".claude/skills/bmad-maintain-arc42/SKILL.md"

ARC42_CONTEXT=$(python3 skills/nebu-pipeline/scripts/extract_story_section.py \
  --story [STORY_FILE] --sections "Story" "Dev Notes")

STAGED_FILES=$(rtk git diff --staged --name-only)

STEP_DESC=$(python3 skills/nebu-pipeline/scripts/select_pipeline_step.py --step arc42-update)
```

Inject `[STEP_DESC]` into subagent, substituting `[ARC42_SKILL_PATH]`, `[ARC42_CONTEXT]`, `[STAGED_FILES]`.

After completion:
```bash
rtk git diff --name-only docs/
```

If no `docs/` changes and story has architecture-relevant changes (new endpoints, services, data models, gRPC handlers, or middleware):
```
⚠ Step 8 — Arc42 not updated.
docs/ unchanged despite architecture-relevant changes.
Type "continue [reason]" to proceed.
```
Stop and wait.

```bash
rtk git add docs/
```

```bash
python3 skills/nebu-pipeline/scripts/pipeline_state.py \
  --file $STATE_FILE \
  --step commit --done arc42-update \
  --log "[STORY_ID] TIMESTAMP arc42-update → done"
# or: --log "[STORY_ID] TIMESTAMP arc42-update → no arch changes"
```

Show: `✓ Step 8: Arc42 documentation updated.`

---

### Step 9: commit

**Pre-commit: update sprint-status.yaml**

```bash
python3 skills/nebu-pipeline/scripts/update_sprint_status.py \
  --file $SPRINT_STATUS \
  --story [STORY_ID] \
  --summary "[SUMMARY]"
```

Summary examples: `ATDD+Dev+Code CLEAN`, `2 MINOR fixed — 1 cycle`, `HIGH fixed, Kassandra 2 rounds`

```bash
rtk git add $SPRINT_STATUS
```

**Commit:**
```bash
rtk git commit -m "$(cat <<'EOF'
[STORY_SUMMARY]
EOF
)"
```

No `Co-Authored-By` line.

**Post-commit: generate ISO traceability entry (no LLM — pure script):**

```bash
# TRACEABILITY_MATRIX resolves to _bmad-output/nebu/epics/<name>/traceability-matrix.yaml
# (named epic) or _bmad-output/nebu/traceability-matrix.yaml (legacy).
python3 skills/nebu-pipeline/scripts/generate_traceability.py \
  --story [STORY_FILE] \
  --commit HEAD \
  --matrix $TRACEABILITY_MATRIX
```

Skips silently for legacy stories without a `traceability_id` frontmatter field.
Idempotent — re-running for the same REQ-ID does nothing.

```bash
rtk git add $TRACEABILITY_MATRIX 2>/dev/null || true
```

**Write final log entry and clear YAML fields:**

```bash
python3 skills/nebu-pipeline/scripts/pipeline_state.py \
  --file $STATE_FILE \
  --commit \
  --log "[STORY_ID] TIMESTAMP committed ✓ ([COMPACT_SUMMARY])"
```

Compact summary examples: `ATDD+Code CLEAN`, `2 MINOR fixed 1 cycle+Kassandra CLEAN`, `MAJOR fixed 2 cycles+Kassandra HIGH resolved`

Show: `✓ Step 9: Committed. Pipeline state cleared.`

---

### Step 10: epic-check

**Named epic:** count stories in `$STORY_DIR` and check `Status:` in each file:
```bash
find $STORY_DIR -name "*.md" | sort | while read f; do grep "^Status:" "$f"; done
```
Epic is complete when all story files have `Status: done`.

**Legacy numbered epic:** read the sprint-status.yaml:
```bash
rtk read $SPRINT_STATUS
```
Check if the story just committed is the last story of the epic (entry immediately before `epic-{N}-retrospective` in the YAML).

**If epic complete → SEC Gate 2 (mandatory):**

Determine the epic base commit:
```bash
rtk git log --grep="epic-{N-1}-retrospective\|retrospektive" --oneline
```

If unclear, ask: "Epic diff base? (commit SHA or tag)"

Launch `@nebu-kassandra` — the epic-review scope is inlined in the agent definition
`.claude/agents/nebu-kassandra.md`. Do NOT load `skills/nebu-agent-kassandra/SKILL.md`
or its `references/*.md` files.

Substitute `[EPIC_BASE]` (base commit SHA), `[SEC_CONTEXT]` (epic context: stories
covered, scope description), and `{N}` (epic number).

- **CRITICAL or HIGH:** Stop. User chooses: create follow-up stories in next epic, or accept as risk with written justification.
- **CLEAN:** Continue to retrospective.

```
🏁 Epic complete!
Security review artifact: epic-{N}-security-review-[DATE].md
Run /bmad-testarch-trace for the epic traceability matrix.
Retrospective next.
```

Stop and wait for user.

**If epic still running:**
```
✅ Story done. Start next story? [Y/n]
```
- `Y` → restart from Step 1 (create-story)
- `n` → end pipeline

---

## Context Fallback Rule

**Never reduce story context between retries. Only ever expand it.**

Each step extracts a targeted subset of the story. If a step produces output suggesting the agent lacked sufficient story knowledge — wrong implementation direction, bug from misunderstood requirements, reviewer noting divergence from story intent, or agent explicitly asking for more context — expand before retrying:

```bash
FULL_STORY=$(python3 skills/nebu-pipeline/scripts/extract_story_section.py \
  --story [STORY_FILE] --all)
```

Pass `[FULL_STORY]` in place of the narrower variable. The `--all` flag extracts all `##` sections in document order.

**Signals that trigger a context fallback (any step):**
- Agent output contradicts the story's stated user goal
- Bug-fix cycle where the root cause is requirements-related
- Reviewer: "implementation doesn't match the story intent"
- Agent asks for more context or story background
- Two consecutive review cycles with the same misunderstanding

**Rule:** a retry with expanded context is always valid. A retry with reduced context is never valid.

---

## Error Handling

| Situation | Response |
|---|---|
| Agent fails | Show full error. Stop, user decides. |
| git command fails | Show git error. Stop, wait for user. |
| `$SPRINT_STATUS` missing | `ℹ sprint-status.yaml not found — epic check skipped.` |
| `select_pipeline_step.py` returns error | Report missing step name and stop. |
| ATDD skill unavailable | `⚠ ATDD skill not found — TEA Gate skipped. Acceptance tests must exist manually before dev starts.` |
| `bmad-testarch-test-review` unavailable | `⚠ Test-review skill not found — pre-dev quality check skipped.` |
| `nebu-agent-testing` unavailable | Fall back to inline CI execution (build → unit-go → unit-elixir → docker compose down --volumes && up -d --wait → make test-e2e → docker compose down → make test-integration). |
| `pipeline-state.yaml` missing on `--resume` | `⚠ No pipeline-state.yaml found — cannot resume. Start a new story.` |
| 3+ review cycles, same issues | Escalate to user. Do not loop indefinitely. |

---

## Model Reference

| Step | Skill / Agent | Model |
|---|---|---|
| create-story | nebu-lean-story | haiku |
| Oracle Gate (1b, conditional) | nebu-agent-oracle | sonnet |
| atdd | bmad-testarch-atdd | sonnet |
| test-review (pre-dev) | bmad-testarch-test-review | sonnet |
| dev-story | @nebu-dev-story (lean prompt + elixir-otp/cluster-safety/no-domain-model/sql-placement skills) | inherit |
| ci-gate | nebu-agent-testing | haiku |
| UX Gate (5b, conditional) | nebu-agent-ux | sonnet |
| code-review | bmad-code-review | opus |
| security-review (conditional) | @nebu-kassandra (scope inlined in agent body + security-rules skill) | opus |
| epic-review (SEC Gate 2) | @nebu-kassandra (scope inlined in agent body + security-rules skill) | opus |
| arc42-update | nebu-agent-arc42 / bmad-maintain-arc42 | haiku |

---

## Guidelines

- Print a short status line after every step.
- Pass story context to all agents — they don't share memory.
- Steps run **sequentially** — no parallel agent launches.
- `ORACLE_CONTEXT` carries from Step 1b through dev-story and code-review.
- `TEST_REVIEW_FINDINGS` carry from Step 3 through dev-story and code-review.
- `CODE_REVIEW_FINDINGS` carry through the full dev↔review cycle.
- `rtk git add .` runs after code-review unconditionally.
- The pipeline does not fix issues itself. The reviewer identifies; the dev agent fixes.
- Story context extraction: see **Context Fallback Rule**. If any step seems to have too little context, use `--all` for that step's retry.
