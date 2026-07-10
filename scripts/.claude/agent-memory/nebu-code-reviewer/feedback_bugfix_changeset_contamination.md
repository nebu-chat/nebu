---
name: bugfix-changeset-contamination
description: A single-bug pipeline's staged changeset also contained a second, unrelated in-flight story's WIP files (story md, feature, steps, test, pipeline-state) — review the WHOLE staged diff, not just the bug's own files
metadata:
  type: feedback
---

When reviewing a bug-fix pipeline changeset, `git diff --staged` may contain files that have nothing to do with the bug. Seen in `bugfix-bootstrap-scope-ignored` (an OIDC/admin fix): the staged set also included an entire unrelated `enhanced-logging/trace-map-zoom-pan` story (story.md, .feature, .steps.ts, LiveView test, and a bumped `pipeline-state.yaml` + that story's own `test-review-findings.md`). The dev-story note even admitted a "concurrently in-flight story's uncommitted WIP" existed — those WIP files were STAGED. The bug fix itself also sat on `feature/enhanced-logging`, an epic branch unrelated to the bug.

**Why:** Committing as-is bundles a second, possibly-incomplete/unreviewed story into the bug-fix commit — pollutes history and can merge unvetted work. Aligns with the repo's "unrelated work goes in its own branch/worktree" rule.

**How to apply:** Always run `git diff --staged --name-only` first and sanity-check that every staged path belongs to THIS story/bug. Flag cross-story/cross-epic file contamination as MAJOR (needs user decision to unstage) even when the bug's own files are clean. Don't tunnel-vision on the files the task narrative names. See [[test-review-minors-not-carried-through]].
