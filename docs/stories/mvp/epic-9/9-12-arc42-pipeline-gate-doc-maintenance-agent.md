---
security_review: not-needed
---

# Story 9.12: arc42-Dokumentationspflege als Standard-Pipeline-Gate ab Epic 10

Status: backlog

## Story

**As a** maintainer,
**I want** the `bmad-generate-arc42` skill to run automatically at the end of every epic and produce a verifiable freshness signal in CI,
**so that** architecture documentation never drifts more than one epic behind the implementation without a blocking CI warning.

**Size:** S

---

## Background

Story 9.11 delivered the `/bmad-generate-arc42` skill and the initial `docs/` tree. The CI `docs` job was intentionally added with `allow_failure: true` as a soft gate to avoid blocking merges during the initial setup. This story converts the doc gate from optional to mandatory:

1. **`CLAUDE.md` & `bmad-pipeline`** - doc generation becomes a required epic-end step
2. **CI hardening** - `allow_failure: true` → `false`
3. **Delta skill** - `bmad-maintain-arc42` for lightweight per-story updates (no full regeneration overhead)
4. **Staleness threshold** - 180 days → 60 days (error, not warning)

---

## Acceptance Criteria

**AC1 - `CLAUDE.md` pipeline gate updated:**
The Epic Completion section in `CLAUDE.md` lists `/bmad-generate-arc42` as a required step before the epic retrospective, alongside `/bmad-testarch-trace`:
```
| End of epic | `/bmad-generate-arc42` | SM | **Yes** |
```

**AC2 - `bmad-pipeline` skill updated:**
`bmad-pipeline`'s workflow includes a doc-generation step at the epic-end gate. The step:
- Invokes `/bmad-generate-arc42`
- Verifies `docs/.arc42-manifest.json` `generated_at` is within the last 24 h
- Fails the gate if the manifest is absent or stale

**AC3 - CI gate hardened:**
In both `.github/workflows/ci.yml` and `.gitlab-ci.yml`, the `docs` job's `allow_failure` flag changes:
```yaml
# before
allow_failure: true
# after
allow_failure: false
```
A PR with stale or missing docs blocks merge.

**AC4 - `bmad-maintain-arc42` delta skill installed:**
`.claude/skills/bmad-maintain-arc42/` exists with `customize.toml` and skill workflow. The skill:
- Runs `git diff <manifest.generated_at>..HEAD -- _bmad-output/planning-artifacts/` to identify changed source files
- Only re-generates arc42 sections whose source artifact changed
- Updates `docs/.arc42-manifest.json` with per-file `generated_at`
- Invokable via `/bmad-maintain-arc42`
- Intended for per-PR doc delta updates between full epic runs

**AC5 - Staleness threshold tightened:**
In `scripts/verify-docs.sh`, the staleness threshold for `editable: false` files changes from 180 days (warning) to 60 days (CI-blocking error). Comment in script: `# ~2 epic cadence; increase if release cadence slows`.

**AC6 - All checks pass:**
`scripts/verify-docs.sh` exits 0 after a fresh `/bmad-generate-arc42` run.
`make test-integration` (or CI equivalent) is green with the hardened `docs` job.

---

## Acceptance Tests

### Tests written FIRST (before implementation code):

**1. `test_claude_md_has_arc42_gate` - Bash**
- When: `grep -q "bmad-generate-arc42" CLAUDE.md`
- Then: exits 0

**2. `test_ci_docs_job_not_allow_failure` - Bash**
- When: `grep -A5 "docs:" .github/workflows/ci.yml | grep -q "allow_failure: false"`
- Then: exits 0 (same check for `.gitlab-ci.yml`)

**3. `test_maintain_skill_exists` - Bash**
- When: `[[ -d .claude/skills/bmad-maintain-arc42 ]]`
- Then: true; `customize.toml` and skill file present

**4. `test_staleness_threshold_60_days` - Bash**
- When: `grep -q "60" scripts/verify-docs.sh`
- Then: exits 0 (threshold present in script)

**5. `test_verify_docs_passes_after_generate` - Bash**
- Given: `/bmad-generate-arc42` has just run
- When: `scripts/verify-docs.sh`
- Then: exits 0

---

## Dev Notes

- Update `CLAUDE.md` TEA Quick Reference table (add `/bmad-generate-arc42` row) and the Epic Completion section
- `bmad-pipeline` skill update: add `doc_gate` step after `testarch-trace` step, before retrospective
- The delta skill can use `git log --since="<manifest_generated_at>" --name-only -- _bmad-output/planning-artifacts/` to detect which source artifacts changed
- `allow_failure: false` flip is a one-liner in each CI file
- CI job name stays `docs` - no rename needed
