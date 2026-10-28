# Pipeline Steps Specification

Agent prompts for each nebu-pipeline step. Selected by `select_pipeline_step.py --step <name>`.
The coordinator (SKILL.md) injects runtime values for `[BRACKETED]` placeholders before
passing the prompt to the subagent. Conditional blocks (`[IF X — omit if null]`) are
evaluated by the coordinator: if the variable is null/empty, the entire block is dropped.

---

## create-story

Read and follow .claude/skills/nebu-lean-story/SKILL.md.
Epic: [EPIC_NAME]
Story directory: [STORY_DIR]
User input: [USER_INPUT]
Work through this completely, then finish.

---

## oracle-gate

Read and follow skills/nebu-agent-oracle/SKILL.md.
Load references/spec-lookup.md and references/test-guidance.md.

Story context:
[ORACLE_INPUT]

1. Which Matrix CS API endpoints, event types, and behavioral rules apply?
   List all MUST requirements.
2. Which spec-defined error codes, HTTP status codes, and edge cases MUST be test-covered?

Return compact Markdown (max 40 lines). Lists only, no prose. Then finish.

---

## atdd

Read and follow .claude/skills/bmad-testarch-atdd/SKILL.md.
Acceptance Criteria and existing test stubs:
[ATDD_INPUT]
Generate failing acceptance tests for all acceptance criteria.
Tests MUST be failing before any implementation code exists.

[IF ORACLE_CONTEXT — omit this block if null:]
Matrix spec requirements (from Oracle):
[ORACLE_CONTEXT]
Cover ALL spec-defined error codes, HTTP status codes, and edge cases
as separate failing tests.

Finish after generating the tests.

---

## test-review

Read and follow .claude/skills/bmad-testarch-test-review/SKILL.md.
Review all staged test files (git diff --staged).

Context: these are FAILING tests from ATDD, not yet validated by a green run.

Story and Acceptance Criteria (verify each has at least one test):
[AC_SECTION]

Check:
- Does each acceptance criterion have at least one test?
- Any hard waits, non-deterministic assertions, or brittle selectors?
- GenServer state stories: is there a crash/restart test?
- UI stories (ui: true in frontmatter): are Playwright tests present in e2e/tests/ or e2e/features/?
- Are Matrix spec error codes and HTTP status codes tested (not just the happy path)?

Classify each finding: MAJOR / MINOR / INFO.
MAJOR = missing AC coverage, missing crash/restart test for GenServer state,
        missing Playwright tests for a UI story.

Output the full report and finish.

---

## dev-story

The agent definition `.claude/agents/nebu-dev-story.md` carries the full prompt
(conventions, workflow, non-negotiable rules). Do NOT load `bmad-dev-story`.

Launch `@nebu-dev-story` with placeholders substituted:
- `[STORY_FILE]` → path
- `[TEST_REVIEW_FINDINGS]` → value or drop block if empty
- `[ORACLE_CONTEXT]` → value or drop block if empty
- `[CODE_REVIEW_FINDINGS]` → value or drop block if empty (cycle 0)
- `[CYCLE_COUNT]` → current cycle number

---

## ci-gate

Run `make redeploy` to rebuild the server image, then `make test-integration` to run
the full Gherkin E2E test suite against a fresh database and real stack.

Compare results against the baseline log from Step 1d
($STEP_RESULTS_DIR/[STORY_ID]/baseline-integration.log).
Report pass/fail per suite. If integration passes, also run `make test-unit-elixir`.
Finish after reporting.

---

## ux-gate

Read and follow skills/nebu-agent-ux/SKILL.md.
Run in --headless mode: accessibility audit on staged changes.

Story context:
[STORY_SECTIONS]

Audit changed templates against:
- PRD accessibility requirements (from your BOND.md)
- WCAG 2.1 AA baseline
- DaisyUI consistency with existing components

Return findings as: violations (blocking) | advisories (non-blocking).
Finish after the audit.

---

## code-review

Read and follow .claude/skills/bmad-code-review/SKILL.md.
Review all staged changes (git diff --staged).

IMPORTANT: Do NOT fix issues yourself.
Identify all issues, classify them (MAJOR / MINOR / INFO), return the full list.
The pipeline hands MINOR issues back to the dev agent for fixing.
Only MAJOR/CRITICAL issues require user decision.

Story and Acceptance Criteria (verify implementation covers each):
[AC_SECTION]

Test quality findings (from pre-dev test-review):
[TEST_REVIEW_FINDINGS]

[IF ORACLE_CONTEXT — omit this block if null:]
Matrix spec requirements (from Oracle):
[ORACLE_CONTEXT]
Verify the implementation satisfies ALL MUST requirements.
Missing error codes or wrong HTTP status = MAJOR.

Current review cycle: [CYCLE_COUNT] (escalate to user if same issues persist for 3+ cycles)

Output the full report. Classify every finding as MAJOR, MINOR, or INFO. Finish.

---

## security-review

Launch `@nebu-kassandra` — the full review scope (per-story + epic) lives in the
agent definition `.claude/agents/nebu-kassandra.md`. Do NOT load
`skills/nebu-agent-kassandra/SKILL.md` or its `references/*.md` files —
the scope is inlined in the agent body.

Substitute:
- `[SEC_CONTEXT]` → story sections (Story + Acceptance Criteria)

Scope: staged diff (`git diff --staged`)

Write the report to:
`docs/stories/[EPIC]/security-reports/[STORY_ID]-security-review-[DATE].md`
Always write the report, even if zero findings (audit trail).

Return: Classification (CRITICAL | HIGH | CLEAN) + report path + severity count.

---

## epic-security-review

Launch `@nebu-kassandra` — same agent as `security-review`, epic scope is in the
agent definition. Do NOT load `skills/nebu-agent-kassandra/SKILL.md` or its
`references/*.md` files.

Substitute:
- `[EPIC_BASE]` → base commit SHA for `git diff [EPIC_BASE]..HEAD`
- `[SEC_CONTEXT]` → epic context (stories covered, scope description)

Report path: `_bmad-output/implementation-artifacts/epic-[N]-security-review-[DATE].md`
Always write the report — this is a mandatory audit artifact.

Return: Classification (CRITICAL | HIGH | CLEAN) + report path.

---

## arc42-update

Read and follow [ARC42_SKILL_PATH].
Story context:
[ARC42_CONTEXT]
Staged changes: [STAGED_FILES]

Perform a delta update of the arc42 documentation.
Update only the sections affected by this story. No full rewrites.
Finish after the update.
