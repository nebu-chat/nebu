# Pipeline Steps Specification

Prompts for the skill-driven steps of nebu-pipeline, selected by `select_pipeline_step.py --step <name>`.
The coordinator injects runtime values for `[BRACKETED]` placeholders; conditional blocks
(`[IF X — omit if none]`) are dropped when the variable is `none`/empty.

**Named agents carry their own prompt.** For `oracle-gate`, `test-review`, `dev-story`, `ux-gate`,
`code-review` and `security-review` the prompt lives in `.claude/agents/nebu-*.md` (source:
`skills/nebu-pipeline/install/agents/`). The coordinator sends ONLY a short launch message of
`KEY: value` lines (see `steps/*.md`) — never the report text or the story sections.

**ATDD.** In `ATDD_MODE: lean` (default) the `atdd` section below is NOT used: `atdd_scaffold.py` writes the scaffold, `@nebu-atdd` (prompt in `.claude/agents/nebu-atdd.md`; launch keys
`STORY_FILE`, `TEST_FILE`, `FEATURE_FILE`, `ORACLE_FILE`, `VERIFY_FILE` on retry) fills it and replies `DONE tests=N red=N`, `atdd_verify.py` checks it (see `steps/2-atdd.md`).
The section below is the `tea` prompt (BMAD skill) for `ATDD_MODE: tea`, stories without Gherkin and `--bug` runs.

## Digest contract (all report-writing agents)

The agent writes its full report to `REPORT_FILE` (inside `$STEP_RESULTS_DIR/[STORY_ID]/`) and replies with ONLY:

```
VERDICT: CLEAN | MINOR | MAJOR | CRITICAL      (dev-story: DONE | BLOCKED; ux: CLEAN | VIOLATIONS; Kassandra: CLEAN | HIGH | CRITICAL)
COUNTS: major=N minor=N info=N
REPORT: <path>
TOP: <≤3 MAJOR/CRITICAL titles, "; "-separated, or "-">
```

Report file: one finding per line `<SEV> | <file:line> | <issue> | <fix hint>`. Downstream steps pass the **file path**
(`TEST_REVIEW_FILE`, `ORACLE_FILE`, `CODE_REVIEW_FILE`, `REVIEW_DELTA_FILE`) to the next agent; the coordinator never
re-emits report content. If an agent replies with prose instead of a digest, the coordinator writes that reply to
`REPORT_FILE` once and continues (legacy behaviour).

---

## create-story

Read and follow .claude/skills/nebu-lean-story/SKILL.md.
Epic: [EPIC_NAME]
Story directory: [STORY_DIR]
User input: [USER_INPUT]
Work through this completely, then finish.

---

## oracle-gate

`spec_extract.py` runs first; with full coverage its draft is the Oracle context. Otherwise launch `@nebu-oracle` with: `STORY_FILE`, `REPORT_FILE` (= `$STEP_RESULTS_DIR/[STORY_ID]/oracle-context.md`), `SPEC_DRAFT_FILE`.
The prompt (MUST requirements, error codes, edge cases; max 40 lines) lives in the agent definition.

---

## atdd

Read and follow .claude/skills/bmad-testarch-atdd/SKILL.md.
Story: [STORY_FILE]. Read the acceptance criteria with:
`python3 skills/nebu-pipeline/scripts/extract_story_section.py --story [STORY_FILE] --sections "Story" "Acceptance Criteria" "Acceptance Tests"`
Generate failing acceptance tests for all acceptance criteria.
Tests MUST be failing before any implementation code exists.

[IF ORACLE_FILE — omit this block if none:]
Matrix spec requirements (from Oracle) are in [ORACLE_FILE] — read it.
Cover ALL spec-defined error codes, HTTP status codes, and edge cases
as separate failing tests.

Finish after generating the tests. Reply with ONE line: `DONE tests=<N> red=<N>` — no summary of the tests.

---

## test-review

`test_lint.py` runs first; `@nebu-test-reviewer` only when it reports `LLM_NEEDED: yes`. Launch keys: `STORY_FILE`, `CYCLE`, `REPORT_FILE` (= `…/test-review-findings.md`), `LINT_FILE`, `ORACLE_FILE`.
The prompt lives in the agent definition.

---

## dev-story

Launch `@nebu-dev-story` with: `STORY_FILE`, `CYCLE`, `TEST_REVIEW_FILE`, `ORACLE_FILE`, `CODE_REVIEW_FILE` (`none` in cycle 0).
The agent definition `.claude/agents/nebu-dev-story.md` carries the full prompt. Do NOT load `bmad-dev-story`.

---

## ci-gate

Cycle 0 (or Step 6b): run `make redeploy` to rebuild the server image, then `make test-integration` to run
the full Gherkin E2E test suite against a fresh database and real stack.
Cycles >= 1 (fast gate): only `make test-unit-elixir`; the full integration run is deferred to Step 6b.

Compare results against the baseline log from Step 1d
($STEP_RESULTS_DIR/[STORY_ID]/baseline-integration.log).
Report pass/fail per suite. If integration passes, also run `make test-unit-elixir`.
Finish after reporting.

---

## ux-gate

Launch `@nebu-ux-reviewer` with: `STORY_FILE`, `REPORT_FILE` (= `…/ux-findings.md`).
The prompt (headless accessibility audit) lives in the agent definition.

---

## code-review

Launch `@nebu-code-reviewer` with: `STORY_FILE`, `CYCLE`, `REPORT_FILE` (= `…/code-review-findings.md`), `PRESCAN_FILE` (= `…/review-prescan.md`, from `review_prescan.py`),
`TEST_REVIEW_FILE`, `ORACLE_FILE`, `CODE_REVIEW_FILE` (previous findings; `none` in cycle 0), `REVIEW_DELTA_FILE` (`none` = full review).
The prompt (review rules, delta mode) lives in the agent definition.

---

## security-review

Launch `@nebu-kassandra` with: `STORY_FILE`, `STORY_ID`, `DATE`, `EPIC`, `CANDIDATES_FILE` (= `…/sec-candidates.md`, from `sec_prescan.py`). The full review scope (per-story + epic)
lives in the agent definition `.claude/agents/nebu-kassandra.md`. Do NOT load `skills/nebu-agent-kassandra/SKILL.md`
or its `references/*.md` files — the scope is inlined in the agent body.

Scope: staged diff (`git diff --staged`). Report: `docs/stories/[EPIC]/security-reports/[STORY_ID]-security-review-[DATE].md`
(always written, even with zero findings — audit trail). Reply: digest (CLEAN | HIGH | CRITICAL).

---

## epic-security-review

Launch `@nebu-kassandra` (same agent) with: `EPIC_BASE` (base commit SHA for `git diff [EPIC_BASE]..HEAD`), `EPIC_ID`, `DATE`.
Report: `_bmad-output/implementation-artifacts/epic-[N]-security-review-[DATE].md` — mandatory audit artifact.
Reply: digest (CLEAN | HIGH | CRITICAL).

---

## arc42-update

Read and follow [ARC42_SKILL_PATH].
Story: [STORY_FILE]. Context: `python3 skills/nebu-pipeline/scripts/extract_story_section.py --story [STORY_FILE] --sections "Story" "Dev Notes"`
Staged changes: run `git diff --staged --name-only`.

Perform a delta update of the arc42 documentation.
Update only the sections affected by this story. No full rewrites.
Finish after the update. Reply with ONE line: `DONE sections=<list of updated sections>`.
