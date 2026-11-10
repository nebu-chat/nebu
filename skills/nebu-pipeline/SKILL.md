---
name: nebu-pipeline
description: Orchestrates the full Nebu dev lifecycle with TDD-first order, dev↔review cycles, conditional security and UX gates, and full resume capability via pipeline-state.yaml. Use --resume, --from <step>, or --bug.
---

# Nebu Pipeline

Router for the Nebu development lifecycle. Thin and deterministic — owns sequencing and cycle logic only.
**Each step's instructions live in `skills/nebu-pipeline/steps/<file>.md`: Read that file right before you execute the step, never from memory.**
Agent prompts live in `.claude/agents/nebu-*.md`; skill-driven prompts in `pipeline-steps-spec.md` (`select_pipeline_step.py`).

## Core Principles

- **TDD-first:** tests are generated (ATDD), reviewed, then implementation follows. No code before reviewed failing tests exist.
- **Resumable:** every step writes `pipeline-state.yaml` before executing; interrupted runs restart from their checkpoint.
- **Cyclic:** code-review findings below MAJOR go back to dev-story. The dev agent fixes, the reviewer never does.
- **Script first:** everything that can be decided by a script is (path variables, scaffolds, lint, prescans, verdict → next-step decisions, commit message, epic status). The LLM is launched only for the judgement the scripts hand over.
- **Lean context:** agents get file *paths*, write reports to files and answer with a 4-line digest (see below). Never paste report or story text into this context or into a prompt.

## Tuning (token & runtime)

Phase-1 defaults. Change a value to tune; the *Legacy* column restores the previous behaviour.

| Setting | Default | Legacy | Effect |
|---|---|---|---|
| `MAX_AUTO_MINOR_CYCLES` | 1 | 3 | Automatic dev↔review cycles for MINOR-only findings; beyond that they are deferred and logged, not looped |
| `FAST_GATE_IN_CYCLES` | on | off | Cycles ≥1 run unit tests only; the full integration suite runs once before security-review (Step 6b) |
| `BASELINE_CACHE` | on | off | Step 1d reuses the previous story's final integration log while HEAD is unchanged |
| `DELTA_REVIEW` | on | off | Review cycles ≥1 review only the diff since the last review and verify the previous findings |
| `ARC42_MODE` | conditional | always | Step 8 runs only for architecture-relevant changes (`pipeline_gates.py arc42-relevant`) |
| `CODE_REVIEW_MODEL` | opus (cycle 0), sonnet (≥1) | opus | Model of `@nebu-code-reviewer` |
| `ATDD_MODE` | lean | tea | `lean`: `atdd_scaffold.py` → `@nebu-atdd` fills → `atdd_verify.py`. `tea`: the BMAD ATDD skill (9 step files). Stories without Gherkin and `--bug` runs always use `tea` |
| `TEST_REVIEW_LLM` | auto | always | `auto`: `test_lint.py` decides alone when it has no MINOR/JUDGE items; `always`: the reviewer agent runs every time (with the lint report as input) |
| `ORACLE_LLM` | auto | always | `auto`: `spec_extract.py` output is the Oracle context when it covers every endpoint of the story; `always`: `@nebu-oracle` runs (with the draft as head start) |
| `NEBU_READ_MAX_KB` / `NEBU_READ_GUARD` | 40 / on | `NEBU_READ_GUARD=off` | Hook `read_guard.py` refuses `Read` (and a plain `cat`) of code/log files above the size without `limit`; denials are logged to `.claude/metrics/guard.log` (`read_guard.py --summary`). Set as environment variables (e.g. in `.claude/settings.local.json` → `env`) |
| `SESSION_STORY_LIMIT` | 1 | unlimited | After this many committed stories per session, Step 9 ends with the advice to continue in a fresh session (`/clear` + `nebu-pipeline`; the state file resumes). See *Context hygiene* |
| `PRESCAN_SHORT_CIRCUIT` | on | off | Cycle 0: a MAJOR from `review_prescan.py` skips the LLM review and goes straight to the fix decision (the full review then happens in the next cycle) |

Run the orchestrating session on **sonnet** (`/model sonnet`). Measure with `token_metrics.py report`.

## Turn & context hygiene (orchestrator)

Measured on a 3-story session: the orchestrator was 46 % of all tokens. A turn costs about ten percent of the session context in cache reads, so cost = turns × context size
(context grew 82k → 479k; turns at 400k cost three times a turn at 130k). Poll turns were only 2 %, the cost is ~380 small tool calls.

- **One call per step end.** `decide … --apply $STATE_FILE [--git-add .]` instead of decide + state + `git add`; `finish_story.py` for all of Step 9. Never run `pipeline_state.py` or `git add` as separate calls where a step file shows the combined form.
- **No ad-hoc parsers.** Never write a Python heredoc to read a CI/test log or the state file. Failures of an existing log: `test_digest.py --parse FILE [--baseline BASE.log]` (counts, only new failures, 90 ms for 3.5 MB). Commands that run tests: `test_digest.py -- <command>`
  (also for project helpers such as `.e2ee-ci/quick.sh "mix test …"`), so the raw output never enters the context. No `cat` of story/state/report files — the scripts and digests carry what you need; `git status --short | head -20`, never plain `git status`.
- **Batch independent commands** into one Bash call (`a && b`), keep outputs short (`| tail`, `| head`).
- **Context hygiene.** `SESSION_STORY_LIMIT` (default 1): after the commit of a story pass the `CONTEXT_HINT` of `finish_story.py` to the user — a fresh session for the next story costs about one cache write
  of the system prompt (~50k), each further turn at +150 k context costs ~15 k more. Everything needed is on disk; `--resume` / the next `nebu-pipeline` call continues. Do not start the next story yourself when the limit is reached unless the user says so.
- **Keep ad-hoc work out of the pipeline session.** Branch analyses, ADR searches, log forensics and other side questions belong in a separate session; they inflate the context of every following pipeline turn.

## Path Configuration

Resolved at start from `--epic` — **by script, never by hand**:
```bash
python3 skills/nebu-pipeline/scripts/pipeline_env.py [--epic <name>] [--story <STORY_ID>] --mkdir     # prints STATE_FILE=… STEP_RESULTS_DIR=… SPRINT_STATUS=… STORY_DIR=… TRACEABILITY_MATRIX=… (+ RESULTS, STORY_FILE with --story)
```
All steps use these variables (they override any path shown in a step file). The rules the script implements:

**Named epic (`--epic <name>`):** `STATE_FILE` = `_bmad-output/nebu/epics/<name>/pipeline-state.yaml` · `STEP_RESULTS_DIR` = `…/<name>/step-results/` ·
`SPRINT_STATUS` = `…/<name>/sprint-status.yaml` · `STORY_DIR` = `docs/stories/<name>/` · `TRACEABILITY_MATRIX` = `…/<name>/traceability-matrix.yaml`
(all under `_bmad-output/nebu/epics/<name>/` except `STORY_DIR`).

**Legacy numbered epic (no `--epic`, story ID like `14-4`):** `STATE_FILE` = `_bmad-output/nebu/pipeline-state.yaml` · `STEP_RESULTS_DIR` = `_bmad-output/nebu/step-results/` ·
`SPRINT_STATUS` = `_bmad-output/implementation-artifacts/sprint-status.yaml` · `STORY_DIR` = `docs/stories/mvp/epic-{N}/` or `docs/stories/phase2/` · `TRACEABILITY_MATRIX` = `_bmad-output/nebu/traceability-matrix.yaml`.

`--mkdir` creates `$(dirname $STATE_FILE)`, `$STEP_RESULTS_DIR` (and the story's results dir).

## State & Log

`$STATE_FILE` holds YAML fields (`story`, `current_step`, `completed`, `cycle_count`, `blocked_reason`, `last_updated`) plus a **permanent, additive log**:
`# [STORY_ID] YYYY-MM-DDTHH:MMZ step → compact outcome`, newest first below `# last_updated:`. On commit only the YAML fields are zeroed.
**Never read or rewrite the file by hand — use `pipeline_state.py`** (it creates the file on the first call and replaces the literal word `TIMESTAMP` in `--log` with the current UTC time — never type a time yourself):

```bash
python3 skills/nebu-pipeline/scripts/pipeline_state.py --file $STATE_FILE \
  --step NEXT_STEP --done COMPLETED_STEP --log "[STORY_ID] TIMESTAMP step → outcome"
```
Flags: `--story ID` · `--step STEP` · `--done STEP` (repeatable) · `--cycles N` · `--blocked REASON|null` · `--timestamp ISO` · `--commit` (zero YAML fields, keep log). Combine in one call.

## Activation

- **`nebu-pipeline`** — new story, legacy numbered epic. Ask for the story description or file.
- **`nebu-pipeline --epic <name>`** — new story in a named epic.
- **`--resume`** (also `--epic <name> --resume`) — read `$STATE_FILE`, print story/step/cycle, ask to confirm, continue from `current_step`. Missing file → `⚠ No pipeline-state.yaml found — cannot resume. Start a new story.`
- **`--from <step>`** — start at the named step (ask for story context if needed).
- **`--bug <description>`** — skip create-story, start at `atdd` with the bug as context (failing regression test first).

Valid step names: `create-story` `atdd` `test-review` `dev-story` `ci-gate` `code-review` `security-review` `arc42-update` `commit`.
Initialize state for a new story (ID is only known after Step 1 — use `pending`):
```bash
python3 skills/nebu-pipeline/scripts/pipeline_state.py --file $STATE_FILE \
  --story pending --step create-story --log "[pending] TIMESTAMP pipeline started"
```

## Steps — Read the file before you run the step

| Step | Runs | Agent / mechanism | Model | File (`skills/nebu-pipeline/steps/`) |
|---|---|---|---|---|
| 1 create-story | always (not with `--bug` / epic runner) | `@nebu-lean-story` | haiku | `1-create-story.md` |
| 1c classify | always | script `classify_story.py` | — | `1c-classify.md` |
| 1b oracle | `MATRIX=true` | script `spec_extract.py`; `@nebu-oracle` only if coverage is not full | opus | `1b-oracle.md` |
| 1d baseline | always | bash (`BASELINE_CACHE`) | — | `1d-baseline.md` |
| 2 atdd | unless infra-only | scripts `atdd_scaffold.py` + `atdd_verify.py`; `@nebu-atdd` fills the scaffold (`ATDD_MODE`) | sonnet | `2-atdd.md` |
| 3 test-review | always | script `test_lint.py`; `@nebu-test-reviewer` only for JUDGE/MINOR items | sonnet | `3-test-review.md` |
| 4 dev-story | always, every cycle | `@nebu-dev-story` | sonnet | `4-dev-story.md` |
| 5 ci-gate | always (cycle ≥1: unit only) | bash via `test_digest.py` | — | `5-ci-gate.md` |
| 5b ux-gate | `UI=true` or admin files staged | `@nebu-ux-reviewer` | sonnet | `5b-ux-gate.md` |
| 6 code-review | always | script `review_prescan.py`, then `@nebu-code-reviewer` | opus / sonnet (≥1) | `6-code-review.md` |
| 6b final gate | only if `integration-stale` | bash | — | `6b-final-gate.md` (+ `5-ci-gate.md`) |
| 7 security | prescan + `SEC_REVIEW` decide (see file) | script `sec_prescan.py`, then `@nebu-kassandra` | opus | `7-security.md` |
| 8 arc42 | `ARC42_MODE` relevance check | skill `bmad-maintain-arc42` | haiku | `8-arc42.md` |
| 9 commit | always | script `finish_story.py` | — | `9-commit.md` |
| 10 epic-check | after commit | script `epic_status.py`; `@nebu-kassandra` (SEC Gate 2 on epic end) | opus | `10-epic-check.md` |

Order: 1 → 1c → 1b → 1d → 2 → 3 → 4 → 5 → 5b → 6 ⟲ (4) → 6b → 7 → 8 → 9 → 10. Steps run **sequentially**, never in parallel.
`steps/context-fallback.md` — read it when a retry needs more story context (never reduce context, only expand).

## How a step runs

1. Read the step file. 2. Launch the agent with a **launch message of `KEY: value` lines** (paths and numbers only — `STORY_FILE`, `CYCLE`, `REPORT_FILE`,
`ORACLE_FILE`, `TEST_REVIEW_FILE`, `CODE_REVIEW_FILE`, `REVIEW_DELTA_FILE`, and the script reports `LINT_FILE`, `PRESCAN_FILE`, `CANDIDATES_FILE`, `SPEC_DRAFT_FILE`, `TEST_FILE`, `FEATURE_FILE`, `VERIFY_FILE`; `none` = not applicable). The agent reads the story and earlier reports itself.
Skill-driven steps (create-story, atdd, arc42) use `select_pipeline_step.py --step <name>` as the prompt.
3. Evaluate the agent's reply. 4. Update state with `pipeline_state.py`.

**Digest contract.** Report-writing agents write the full report to `REPORT_FILE` (in `$STEP_RESULTS_DIR/[STORY_ID]/`) and reply with ONLY:
```
VERDICT: CLEAN | MINOR | MAJOR | CRITICAL     (dev: DONE | BLOCKED · ux: CLEAN | VIOLATIONS · Kassandra: CLEAN | HIGH | CRITICAL)
COUNTS: major=N minor=N info=N
REPORT: <path>
TOP: <≤3 MAJOR/CRITICAL titles, or ->
```
**Never judge a verdict yourself:** pass the digest to `pipeline_gates.py decide --step <test-review|dev-story|ux-gate|code-review|security-review|epic-security> --story <ID> --cycle N --digest - <<'EOF' … EOF` (or `--digest <file>` for a script digest saved with `| tee`).
**Pass `--apply $STATE_FILE` (and `--git-add .` where the step file says so):** on `NEXT`/`CYCLE`/`DEFER_MINOR` the script then updates the state (and stages) itself — one tool call per step end instead of three; `APPLIED` confirms it. It answers `ACTION: NEXT | CYCLE | DEFER_MINOR | ASK_USER | STOP`, a ready-to-run `STATE` (arguments for `pipeline_state.py --file $STATE_FILE`, needed by hand only for `ASK_USER`) and the `MESSAGE` to show; the cycle cap, MINOR deferral, security `blocking_severity` and the 3-round limit live in the script. Show `TOP` + the report path when the user must decide; do not read the report unless asked. If an agent answers in prose instead,
write that reply to `REPORT_FILE` once and continue. After `@nebu-dev-story` stops, the `SubagentStop` hook runs `invariant_check.py`; exit 2 → do not proceed to code-review.

## Error Handling

| Situation | Response |
|---|---|
| Agent fails | Show the full error. Stop, user decides. |
| git command fails | Show the git error. Stop, wait for user. |
| `$SPRINT_STATUS` missing | `ℹ sprint-status.yaml not found — epic check skipped.` |
| `select_pipeline_step.py` returns an error | Report the missing step name and stop. |
| Step file missing | Report its name and stop — never improvise the step. |
| ATDD skill unavailable | `⚠ ATDD skill not found — TEA Gate skipped. Acceptance tests must exist manually before dev starts.` |
| `bmad-testarch-test-review` unavailable | `⚠ Test-review skill not found — pre-dev quality check skipped.` |
| `nebu-agent-testing` unavailable | Inline CI: build → unit → `docker compose down --volumes && up -d --wait` → `make test-e2e` → `docker compose down` → `make test-integration`. |
| 3+ review cycles, same issues | Escalate to user. Do not loop indefinitely. |

## Guidelines

- Print one short status line after every step (`✓ Step N: …`).
- Agents share no memory: everything they need is in the launch message paths and files under `$STEP_RESULTS_DIR/[STORY_ID]/`.
- `ORACLE_FILE` carries from 1b through atdd, test-review, dev-story, code-review; `TEST_REVIEW_FILE` from 3 through dev-story and code-review; `CODE_REVIEW_FILE` through the dev↔review cycle.
- `git add .` runs after code-review unconditionally (the `decide --git-add .` flag of Steps 4, 6 and 7 does it).
- The pipeline does not fix issues itself. The reviewer identifies; the dev agent fixes.
